import Foundation

/// Owns publication receipts for a payload and all of its provenance artifacts.
/// The snapshot remains on disk until commit or a complete rollback.
public final class ScientificFilePublicationTransaction: @unchecked Sendable {
    private let lock = NSLock()
    private let snapshot: ProvenancePublicationSnapshot
    private var witness: ProvenancePublicationRollbackWitness
    private var displaced: [URL] = []

    public init(protectedURLs: [URL], fileDestinations: [URL]) throws {
        for url in fileDestinations {
            let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            if FileManager.default.fileExists(atPath: url.path), values?.isRegularFile != true || values?.isSymbolicLink == true {
                throw CocoaError(.fileWriteFileExists, userInfo: [NSFilePathErrorKey: url.path])
            }
        }
        snapshot = try ProvenancePublicationSnapshot(urls: protectedURLs, backupNamePrefix: "lungfish-publication-recovery")
        witness = try snapshot.captureRollbackWitness()
        do { try snapshot.writeRecoveryManifest() }
        catch { snapshot.discard(); throw error }
    }

    public var recoveryDirectoryURL: URL { snapshot.recoveryDirectoryURL }

    /// Exact files retained by this active transaction until commit or rollback.
    /// Payload verification can distinguish these from unrelated nearby files.
    public var displacedArtifactURLs: [URL] { lock.withLock { displaced } }

    public func publish(stagedURL: URL, to destination: URL, replacingExisting: Bool = true) throws {
        try lock.withLock {
            let result = try snapshot.publishReplacement(from: stagedURL, to: destination,
                replacingExisting: replacingExisting, witness: witness)
            witness = result.witness
            if let previous = result.displacedURL { displaced.append(previous) }
        }
    }

    public func observe(_ mutation: ProvenanceWriterMutation) throws {
        try lock.withLock { witness = try snapshot.refreshingRollbackWitness(witness, after: mutation) }
    }

    /// Checks the already observed ownership witness before a paired database
    /// owner restores anything. This does not adopt the current paths as owned.
    public func validateCurrentOwnership() throws {
        try lock.withLock {
            let changed = try snapshot.changedArtifacts(comparedTo: witness)
            guard changed.isEmpty else { throw ProvenancePublicationPreservedChangesError(urls: changed) }
        }
    }

    public func commit() {
        for url in displaced { try? FileManager.default.removeItem(at: url) }
        snapshot.discard()
    }

    public func rollback(after originalError: Error) throws -> Never {
        do {
            let preserved = try snapshot.restore(ifCurrentMatches: lock.withLock { witness })
            guard preserved.isEmpty else { throw ProvenancePublicationPreservedChangesError(urls: preserved) }
        } catch {
            throw ScientificPublicationRecoveryRequired(originalError: originalError, restorationError: error,
                recoveryURLs: [snapshot.recoveryDirectoryURL] + displaced)
        }
        commit()
        throw originalError
    }
}

public struct ScientificPublicationRecoveryRequired: Error, LocalizedError {
    public let originalErrorDescription: String
    public let restorationErrorDescription: String
    public let recoveryURLs: [URL]

    public init(originalError: Error, restorationError: Error, recoveryURLs: [URL]) {
        originalErrorDescription = String(reflecting: originalError)
        restorationErrorDescription = String(reflecting: restorationError)
        self.recoveryURLs = recoveryURLs
    }

    public var errorDescription: String? {
        "Publication failed: \(originalErrorDescription). Restoration failed: \(restorationErrorDescription). Recovery artifacts retained at: "
            + recoveryURLs.map(\.path).joined(separator: ", ")
    }
}
