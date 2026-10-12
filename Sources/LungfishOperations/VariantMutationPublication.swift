import Foundation
import LungfishIO
import LungfishWorkflow

/// Coordinates SQLite recovery with all bundle provenance artifacts. Databases
/// are restored through SQLite; their pathnames are never unlinked or replaced.
final class VariantMutationPublication: @unchecked Sendable {
    private let fileManager: FileManager
    private let witnessLock = NSLock()
    private var provenanceWitness: ProvenancePublicationRollbackWitness
    private let provenanceSnapshot: ProvenancePublicationSnapshot
    let inputDirectory: URL
    private var databases: [String: VariantDatabase] = [:]
    private var snapshots: [String: URL] = [:]
    private var baselineVersions: [String: Int64] = [:]

    init(databaseURLs: [URL], bundleURL: URL, fileManager: FileManager) throws {
        self.fileManager = fileManager
        inputDirectory = bundleURL.appendingPathComponent(".mutation-inputs/\(UUID())", isDirectory: true)
        provenanceSnapshot = try ProvenancePublicationSnapshot(
            urls: ProvenancePublicationArtifacts.bundleRootArtifacts(for: bundleURL),
            backupNamePrefix: "variant-provenance-recovery", fileManager: fileManager)
        provenanceWitness = try provenanceSnapshot.captureRollbackWitness()
        do {
            try fileManager.createDirectory(at: inputDirectory, withIntermediateDirectories: true)
            for (index, url) in databaseURLs.enumerated() where databases[url.path] == nil {
                let database = try VariantDatabase(url: url, readWrite: true)
                baselineVersions[url.path] = try database.publicationDataVersion()
                let snapshot = inputDirectory.appendingPathComponent("\(index)-\(url.lastPathComponent)")
                try database.writePublicationSnapshot(to: snapshot)
                databases[url.path] = database
                snapshots[url.path] = snapshot
            }
            let recovery = snapshots.map { ["database": $0.key, "snapshot": $0.value.path] }
            try JSONSerialization.data(withJSONObject: recovery, options: [.prettyPrinted, .sortedKeys])
                .write(to: inputDirectory.appendingPathComponent("recovery-manifest.json"), options: .atomic)
            try provenanceSnapshot.writeRecoveryManifest()
        } catch {
            provenanceSnapshot.discard()
            try? fileManager.removeItem(at: inputDirectory)
            throw error
        }
    }

    /// Writer callbacks synchronously update only this lock-protected witness;
    /// SQLite handles and lifecycle state remain confined to the owning worker.
    func observeProvenance(_ mutation: ProvenanceWriterMutation) throws {
        try witnessLock.withLock {
            provenanceWitness = try provenanceSnapshot.refreshingRollbackWitness(provenanceWitness, after: mutation)
        }
    }

    func database(at url: URL) -> VariantDatabase { databases[url.path]! }

    func inputDescriptor(for url: URL) throws -> ProvenanceFileDescriptor {
        let snapshot = snapshots[url.path]!
        let record = try ProvenanceFileDescriptor.file(url: snapshot, format: .unknown, role: .input)
        return ProvenanceFileDescriptor(path: record.path, checksumSHA256: record.checksumSHA256,
            fileSize: record.fileSize, format: record.format, role: .input, originPath: url.path)
    }

    func checkpoint() throws {
        for database in databases.values { try database.checkpointForPublication() }
    }

    func commit(retainConsumedInputs: Bool = true) {
        provenanceSnapshot.discard()
        if !retainConsumedInputs { try? fileManager.removeItem(at: inputDirectory) }
    }

    func rollback(after originalError: Error) throws -> Never {
        var failures: [String] = []
        // Check every database before changing any of them. A later writer's
        // state and receipts must remain together for explicit recovery.
        for (path, database) in databases {
            do {
                guard try database.publicationDataVersion() == baselineVersions[path] else {
                    failures.append("\(path): another SQLite connection committed after the input snapshot")
                    continue
                }
            } catch { failures.append("\(path): cannot verify SQLite revision: \(error)") }
        }
        do {
            let changed = try provenanceSnapshot.changedArtifacts(comparedTo: witnessLock.withLock { provenanceWitness })
            if !changed.isEmpty { failures.append("Provenance ownership changed: " + changed.map(\.path).joined(separator: ", ")) }
        } catch { failures.append("Cannot verify provenance ownership: \(error)") }
        if !failures.isEmpty { try recoveryRequired(after: originalError, failures: failures) }
        // SQLite backup owns its destination write lock while copying. The
        // revision preflight does not exclude a noncooperating writer racing
        // between this check and backup initialization; it is not a distributed
        // transaction or a cross-process lock over the provenance files.
        for (path, database) in databases {
            do { try database.restorePublicationSnapshot(from: snapshots[path]!) }
            catch { failures.append("\(path): \(String(reflecting: error))") }
        }
        do {
            let preserved = try provenanceSnapshot.restore(ifCurrentMatches: witnessLock.withLock { provenanceWitness })
            guard preserved.isEmpty else { throw ProvenancePublicationPreservedChangesError(urls: preserved) }
        }
        catch { failures.append("Provenance: \(String(reflecting: error))") }
        if !failures.isEmpty {
            try recoveryRequired(after: originalError, failures: failures)
        }
        commit(retainConsumedInputs: false)
        throw originalError
    }

    private func recoveryRequired(after originalError: Error, failures: [String]) throws -> Never {
        let restoration = NSError(domain: "VariantMutationPublication", code: 1,
            userInfo: [NSLocalizedDescriptionKey: failures.joined(separator: "; ")])
        throw ScientificPublicationRecoveryRequired(originalError: originalError, restorationError: restoration,
            recoveryURLs: [inputDirectory, provenanceSnapshot.recoveryDirectoryURL])
    }
}
