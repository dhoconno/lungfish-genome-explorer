import Foundation
import LungfishIO
import LungfishWorkflow

/// A worker owns only this operation's private staging directory. Publishing
/// keeps the old database until the caller's provenance/manifest commit succeeds.
struct OperationImportStaging: Sendable {
    let directory: URL

    init(parentDirectory: URL, operationID: UUID) throws {
        directory = parentDirectory.appendingPathComponent(".import-\(operationID.uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    func cleanup() throws {
        if FileManager.default.fileExists(atPath: directory.path) {
            try FileManager.default.removeItem(at: directory)
        }
    }

    /// Finalizes private files after the scientific publication has committed.
    func finishCommittedImport(cleanupAction: (() throws -> Void)? = nil) -> String? {
        do {
            if let cleanupAction { try cleanupAction() }
            else { try cleanup() }
            return nil
        } catch {
            return "Import committed, but private staging could not be removed at \(directory.path): \(error.localizedDescription)"
        }
    }

    struct RecoveryRequired: Error, LocalizedError {
        let directory: URL
        let originalErrorDescription: String
        let restorationErrorDescription: String
        private(set) var additionalRecoveryURLs: [URL]

        init(directory: URL, originalError: Error, restorationError: Error, additionalRecoveryURLs: [URL] = []) {
            self.directory = directory
            originalErrorDescription = String(reflecting: originalError)
            restorationErrorDescription = String(reflecting: restorationError)
            self.additionalRecoveryURLs = additionalRecoveryURLs
        }

        func retainingRecoveryURLs(_ urls: [URL]) -> RecoveryRequired {
            var result = self
            for url in urls where !result.additionalRecoveryURLs.contains(url) {
                result.additionalRecoveryURLs.append(url)
            }
            return result
        }

        var errorDescription: String? {
            "Import publication failed: \(originalErrorDescription). Restoration failed: \(restorationErrorDescription). Recovery artifacts retained at: "
                + ([directory] + additionalRecoveryURLs).map(\.path).joined(separator: ", ")
        }
    }

    struct SQLitePublication {
        let staging: OperationImportStaging
        let filename: String
        let destination: URL
        fileprivate let previousHandle: SQLitePublicationHandle?
        fileprivate let previousIdentity: SQLiteFileIdentity?
        fileprivate let baselineVersion: Int64?
        var stagedURL: URL { staging.directory.appendingPathComponent(filename) }
        private var previousSnapshotURL: URL { staging.directory.appendingPathComponent("previous-" + filename) }

        func publish(beforeRollback: () throws -> Void = {}, commit: () throws -> Void) throws {
            let candidate = staging.directory.appendingPathComponent("publication-" + filename)
            try SQLitePublicationHandle(url: stagedURL).writeSnapshot(to: candidate)
            guard let previousHandle else {
                let publication = try ScientificFilePublicationTransaction(protectedURLs: [destination], fileDestinations: [destination])
                do {
                    try publication.publish(stagedURL: candidate, to: destination, replacingExisting: false)
                    try commit()
                    publication.commit()
                } catch {
                    let original = error
                    do { try beforeRollback() }
                    catch {
                        throw RecoveryRequired(directory: staging.directory, originalError: original, restorationError: error,
                            additionalRecoveryURLs: [publication.recoveryDirectoryURL] + publication.displacedArtifactURLs)
                    }
                    do { try publication.rollback(after: original) }
                    catch let recovery as ScientificPublicationRecoveryRequired {
                        throw RecoveryRequired(directory: staging.directory, originalError: original, restorationError: recovery,
                            additionalRecoveryURLs: recovery.recoveryURLs)
                    }
                }
                return
            }
            do {
                try verifyExistingRevision(previousHandle)
                try previousHandle.restoreSnapshot(from: candidate)
                try commit()
            } catch {
                let original = error
                do {
                    // This is a conservative preflight, not a cross-process lock
                    // across SQLite backup and filesystem provenance publication.
                    try beforeRollback()
                    try verifyExistingRevision(previousHandle)
                    try previousHandle.restoreSnapshot(from: previousSnapshotURL)
                } catch {
                    throw RecoveryRequired(directory: staging.directory, originalError: original, restorationError: error)
                }
                throw original
            }
        }

        private func verifyExistingRevision(_ handle: SQLitePublicationHandle) throws {
            guard try SQLiteFileIdentity(url: destination) == previousIdentity,
                  try handle.dataVersion() == baselineVersion else {
                throw NSError(domain: "SQLiteImportPublication", code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "Another writer changed the destination after the retry snapshot."])
            }
        }
    }

    fileprivate struct SQLiteFileIdentity: Equatable {
        let device: UInt64
        let inode: UInt64
        init(url: URL) throws {
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            guard attributes[.type] as? FileAttributeType == .typeRegular,
                  let device = attributes[.systemNumber] as? NSNumber,
                  let inode = attributes[.systemFileNumber] as? NSNumber else { throw CocoaError(.fileReadCorruptFile) }
            self.device = device.uint64Value
            self.inode = inode.uint64Value
        }
    }

    func prepareSQLiteCopy(filename: String, from destination: URL) throws -> SQLitePublication {
        guard FileManager.default.fileExists(atPath: destination.path) else {
            return SQLitePublication(staging: self, filename: filename, destination: destination,
                previousHandle: nil, previousIdentity: nil, baselineVersion: nil)
        }
        let identity = try SQLiteFileIdentity(url: destination)
        let handle = try SQLitePublicationHandle(url: destination, writable: true)
        let version = try handle.dataVersion()
        let snapshot = directory.appendingPathComponent("previous-" + filename)
        try handle.writeSnapshot(to: snapshot)
        do {
            guard try SQLiteFileIdentity(url: destination) == identity, try handle.dataVersion() == version else {
                throw NSError(domain: "SQLiteImportPublication", code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "Another writer changed the destination during the retry snapshot."])
            }
        } catch {
            // Inspection can fail after a coherent snapshot was taken (for
            // example, another process removed the original pathname). Retain
            // that snapshot as well as explicit revision-conflict snapshots.
            throw RecoveryRequired(directory: directory, originalError: error, restorationError: error)
        }
        try FileManager.default.copyItem(at: snapshot, to: directory.appendingPathComponent(filename))
        return SQLitePublication(staging: self, filename: filename, destination: destination,
            previousHandle: handle, previousIdentity: identity, baselineVersion: version)
    }

}
