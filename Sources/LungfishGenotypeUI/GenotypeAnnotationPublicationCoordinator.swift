import Darwin
import Foundation
import LungfishIO

enum GenotypeAnnotationPublicationFaultPoint: Equatable, Sendable {
    case beforeProvenancePublication
    case commitDirectorySync
}

typealias GenotypeAnnotationPublicationFaultInjector =
    @Sendable (GenotypeAnnotationPublicationFaultPoint) -> Error?

struct GenotypeAnnotationPublicationSnapshot: Sendable {
    let annotationData: Data?
    let provenanceData: Data?
}

struct GenotypeAnnotationPublicationPayload: Sendable {
    let annotationData: Data
    let provenanceData: Data
}

struct GenotypeAnnotationPublicationTransactionError: Error, LocalizedError {
    let primaryError: Error
    let rollbackError: Error?

    var errorDescription: String? {
        guard let rollbackError else { return primaryError.localizedDescription }
        return "\(primaryError.localizedDescription) Rollback also failed: \(rollbackError.localizedDescription)"
    }
}

private enum GenotypeAnnotationPublicationCoordinatorError: Error, LocalizedError {
    case unsafeFile(String)
    case systemFailure(operation: String, path: String, code: Int32)

    var errorDescription: String? {
        switch self {
        case .unsafeFile(let path):
            return "Genotype annotation publication requires a real regular file: \(path)"
        case let .systemFailure(operation, path, code):
            return "Could not \(operation) at \(path) (errno \(code): \(String(cString: strerror(code))))."
        }
    }
}

/// Publishes `annotations.json` and its provenance record as one unit.
///
/// Each file goes through ``DurableReplace`` inside one ``DurableReplace/transaction(_:)``, so a name
/// holds a complete old or new file at every step, both files and the folder are synced, and one
/// full flush follows the pair (plan decisions S1, V1 and V2). A failure after either publication
/// puts back every file that no longer holds what the snapshot read. The bundle opens the way
/// `DurableReplace` opens a folder, anchored at the outermost `.lungfish*` component, so a link
/// below that anchor is refused (V3).
struct GenotypeAnnotationPublicationCoordinator {
    let bundleURL: URL
    let annotationFilename: String
    let provenanceFilename: String
    let faultInjector: GenotypeAnnotationPublicationFaultInjector?

    func transact(
        prepare: (GenotypeAnnotationPublicationSnapshot) throws -> GenotypeAnnotationPublicationPayload?
    ) throws -> GenotypeAnnotationPublicationPayload? {
        let publicationLock = try ONTGenotypeBundlePublicationLock.acquire(for: bundleURL)
        defer { publicationLock.release() }

        let directoryFD = try openBundleDirectory()
        defer { Darwin.close(directoryFD) }

        // An ExFAT swap that stopped halfway leaves its old file under a tombstone and nothing under
        // the name. Restore it first, or the snapshot would see nothing and an edit built from
        // nothing would replace it.
        for filename in [annotationFilename, provenanceFilename] {
            try DurableReplace.recover(named: filename, in: bundleURL)
        }

        let snapshot = GenotypeAnnotationPublicationSnapshot(
            annotationData: try readRegularFile(annotationFilename, directoryFD: directoryFD),
            provenanceData: try readRegularFile(provenanceFilename, directoryFD: directoryFD)
        )
        guard let payload = try prepare(snapshot) else { return nil }

        do {
            try DurableReplace.transaction {
                try publish(payload.annotationData, filename: annotationFilename, directoryFD: directoryFD)
                if let error = faultInjector?(.beforeProvenancePublication) { throw error }
                try publish(payload.provenanceData, filename: provenanceFilename, directoryFD: directoryFD)
                if let error = faultInjector?(.commitDirectorySync) { throw error }
                guard Darwin.fsync(directoryFD) == 0 else {
                    throw systemError("synchronize annotation publication directory", bundleURL.path)
                }
            }
            return payload
        } catch {
            // Nothing may have changed yet, so only a restored or failed file wraps the error.
            let outcome = rollBack(snapshot, directoryFD: directoryFD)
            guard outcome.restored || outcome.error != nil else { throw error }
            throw GenotypeAnnotationPublicationTransactionError(
                primaryError: error,
                rollbackError: outcome.error
            )
        }
    }

    /// Opens the bundle the way ``DurableReplace`` opens its folder, so the descriptor and every
    /// publication agree on which folder the bundle is.
    private func openBundleDirectory() throws -> Int32 {
        do {
            return try NoFollowFileSystem.openDestinationFolder(bundleURL)
        } catch {
            throw GenotypeAnnotationPublicationCoordinatorError.systemFailure(
                operation: "open bundle directory without following links below its anchor",
                path: bundleURL.path,
                code: (error as? POSIXError)?.code.rawValue ?? EIO
            )
        }
    }

    private func readRegularFile(_ filename: String, directoryFD: Int32) throws -> Data? {
        return try GenotypeAnnotationPublicationFileAccess.readFileIfPresent(
            named: filename,
            inBundleAt: bundleURL,
            openedBundleDirectoryFD: directoryFD
        )
    }

    /// Publishes `data` as `filename` through ``DurableReplace``. It replaces regular files only, so
    /// a link that the earlier generation-based store left under the name first becomes a file
    /// that holds the bytes the link shows.
    private func publish(_ data: Data, filename: String, directoryFD: Int32) throws {
        if try entryKind(filename, directoryFD: directoryFD) == .trustedGenerationLink,
           let shown = try readRegularFile(filename, directoryFD: directoryFD) {
            try replaceLink(named: filename, with: shown, directoryFD: directoryFD)
        }
        try DurableReplace.replace(data, named: filename, in: bundleURL)
    }

    private func entryKind(_ filename: String, directoryFD: Int32) throws -> GenotypeAnnotationPublicationEntryKind {
        try GenotypeAnnotationPublicationFileAccess.entryKind(
            named: filename,
            inBundleAt: bundleURL,
            openedBundleDirectoryFD: directoryFD
        )
    }

    /// Replaces a trusted generation link with a regular file in one atomic rename, so the name
    /// reads the same bytes before and after. The generation folder keeps its copy.
    private func replaceLink(named filename: String, with data: Data, directoryFD: Int32) throws {
        let temporaryName = ".\(filename).\(UUID().uuidString).tmp"
        let temporaryURL = bundleURL.appendingPathComponent(temporaryName)
        let descriptor = temporaryName.withCString {
            Darwin.openat(
                directoryFD,
                $0,
                O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
                mode_t(0o600)
            )
        }
        guard descriptor >= 0 else { throw systemError("create publication staging file", temporaryURL.path) }
        var removeTemporary = true
        defer {
            Darwin.close(descriptor)
            if removeTemporary {
                temporaryName.withCString { _ = Darwin.unlinkat(directoryFD, $0, 0) }
            }
        }
        try data.withUnsafeBytes { bytes in
            guard let baseAddress = bytes.baseAddress else { return }
            var offset = 0
            while offset < bytes.count {
                let count = Darwin.write(descriptor, baseAddress.advanced(by: offset), bytes.count - offset)
                if count < 0 {
                    if errno == EINTR { continue }
                    throw systemError("write publication staging file", temporaryURL.path)
                }
                guard count > 0 else {
                    throw GenotypeAnnotationPublicationCoordinatorError.systemFailure(
                        operation: "write publication staging file",
                        path: temporaryURL.path,
                        code: EIO
                    )
                }
                offset += count
            }
        }
        guard Darwin.fsync(descriptor) == 0 else {
            throw systemError("synchronize publication staging file", temporaryURL.path)
        }
        let result = temporaryName.withCString { temporary in
            filename.withCString { final in
                Darwin.renameat(directoryFD, temporary, directoryFD, final)
            }
        }
        guard result == 0 else {
            throw systemError("replace linked file", bundleURL.appendingPathComponent(filename).path)
        }
        removeTemporary = false
    }

    /// Puts back every file that no longer holds what the snapshot read, in one transaction, and
    /// syncs the folder. `restored` says whether any file had to change.
    private func rollBack(
        _ snapshot: GenotypeAnnotationPublicationSnapshot,
        directoryFD: Int32
    ) -> (restored: Bool, error: Error?) {
        var errors: [Error] = []
        var restored = false
        do {
            try DurableReplace.transaction {
                for (filename, data) in [
                    (annotationFilename, snapshot.annotationData),
                    (provenanceFilename, snapshot.provenanceData),
                ] {
                    do {
                        if try restore(data, as: filename, directoryFD: directoryFD) { restored = true }
                    } catch {
                        errors.append(error)
                    }
                }
            }
        } catch {
            errors.append(error)
        }
        if Darwin.fsync(directoryFD) != 0 {
            errors.append(systemError("synchronize rollback directory", bundleURL.path))
        }
        guard !errors.isEmpty else { return (restored, nil) }
        return (restored, NSError(
            domain: "GenotypeAnnotationPublicationRollback",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: errors.map(\.localizedDescription).joined(separator: "; ")]
        ))
    }

    /// Returns whether `filename` had to change to hold `data` again, or to be absent when `data`
    /// is `nil`. A name that cannot be read counts as changed, and the restore reports why.
    private func restore(_ data: Data?, as filename: String, directoryFD: Int32) throws -> Bool {
        let matches: Bool
        do {
            matches = try readRegularFile(filename, directoryFD: directoryFD) == data
        } catch {
            matches = false
        }
        if matches { return false }
        if let data {
            try publish(data, filename: filename, directoryFD: directoryFD)
        } else {
            try removeRegularFileIfPresent(filename, directoryFD: directoryFD)
        }
        return true
    }

    private func removeRegularFileIfPresent(_ filename: String, directoryFD: Int32) throws {
        var status = stat()
        let result = filename.withCString {
            Darwin.fstatat(directoryFD, $0, &status, AT_SYMLINK_NOFOLLOW)
        }
        if result != 0 {
            if errno == ENOENT { return }
            throw systemError("inspect rollback destination", bundleURL.appendingPathComponent(filename).path)
        }
        guard status.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG) else {
            throw GenotypeAnnotationPublicationCoordinatorError.unsafeFile(
                bundleURL.appendingPathComponent(filename).path
            )
        }
        let unlinkResult = filename.withCString { Darwin.unlinkat(directoryFD, $0, 0) }
        guard unlinkResult == 0 else {
            throw systemError("remove newly published file during rollback", bundleURL.appendingPathComponent(filename).path)
        }
    }

    private func systemError(_ operation: String, _ path: String) -> Error {
        GenotypeAnnotationPublicationCoordinatorError.systemFailure(
            operation: operation,
            path: path,
            code: errno
        )
    }
}
