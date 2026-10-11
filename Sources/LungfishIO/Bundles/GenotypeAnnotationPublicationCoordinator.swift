import Darwin
import Foundation
import LungfishCore

public enum GenotypeAnnotationPublicationFaultPoint: Equatable, Sendable {
    case beforeProvenancePublication
    case commitDirectorySync
}

public typealias GenotypeAnnotationPublicationFaultInjector =
    @Sendable (GenotypeAnnotationPublicationFaultPoint) -> Error?

public struct GenotypeAnnotationPublicationSnapshot: Sendable {
    public let annotationData: Data?
    public let provenanceData: Data?

    public init(annotationData: Data?, provenanceData: Data?) {
        self.annotationData = annotationData
        self.provenanceData = provenanceData
    }
}

public struct GenotypeAnnotationPublicationPayload: Sendable {
    public let annotationData: Data
    public let provenanceData: Data

    public init(annotationData: Data, provenanceData: Data) {
        self.annotationData = annotationData
        self.provenanceData = provenanceData
    }

    /// The payload of a coordinator that has no record name, whose record
    /// the caller publishes alongside `annotations.json`.
    public init(annotationData: Data) {
        self.init(annotationData: annotationData, provenanceData: Data())
    }
}

/// How a coordinator publishes the record under its record name.
public enum GenotypeAnnotationRecordPublication: Equatable, Sendable {
    /// The coordinator publishes the payload's record bytes over the file under the name.
    case payload
    /// `alongside` publishes the record over the file under the name, and its writer may write or
    /// remove the record's companion files beside it. A rollback puts back the record and every
    /// companion as the snapshot read them, so a companion the snapshot did not find is removed.
    case alongside
    /// `alongside` publishes a record that must be new and never replaces a file, with any
    /// companion files its writer adds. A rollback removes the record and its companions only once
    /// `alongside` returned, so a file another writer put there stays.
    case alongsideNew
}

public struct GenotypeAnnotationPublicationTransactionError: Error, LocalizedError {
    public let primaryError: Error
    public let rollbackError: Error?

    public init(primaryError: Error, rollbackError: Error?) {
        self.primaryError = primaryError
        self.rollbackError = rollbackError
    }

    public var errorDescription: String? {
        guard let rollbackError else { return primaryError.localizedDescription }
        return "\(primaryError.localizedDescription) Rollback also failed: \(rollbackError.localizedDescription)"
    }
}

private enum GenotypeAnnotationPublicationCoordinatorError: Error, LocalizedError {
    case unsafeFile(String)
    case systemFailure(operation: String, path: String, code: Int32)
    case changedByAnotherWriter(String)

    var errorDescription: String? {
        switch self {
        case .unsafeFile(let path):
            return "Genotype annotation publication requires a real regular file: \(path)"
        case let .systemFailure(operation, path, code):
            return "Could not \(operation) at \(path) (errno \(code): \(String(cString: strerror(code))))."
        case .changedByAnotherWriter(let path):
            return "\(path) holds bytes another writer published, so the rollback left them in place."
        }
    }
}

/// Publishes `annotations.json` and its provenance record as one unit.
///
/// Each file goes through ``DurableReplace`` inside one ``DurableReplace/transaction(_:)``, so a name
/// holds a complete old or new file at every step, both files and the folder are synced, and one
/// full flush follows the pair (plan decisions S1, V1 and V2). A failure after either publication
/// puts back every file that holds what this publication wrote, or that holds nothing, and leaves
/// a file another writer changed in the meantime, reporting it. The bundle opens the way
/// `DurableReplace` opens a folder, anchored at the outermost `.lungfish*` component, so a link
/// below that anchor is refused (V3).
///
/// The GUI annotation store, the CLI genotype annotation commands and the AI haplotyping publisher
/// all publish through it (row B8). A CLI command's record goes out through `ProvenanceWriter` in
/// `alongside`, so it keeps the writer's bytes and signing, and a coordinator without a record name
/// publishes `annotations.json` only, for a caller whose record lives in another folder. The writer
/// also writes `<record>.signature.json` and `<record>.pub` beside the record when a signing key is
/// set and removes them when none is. The CLI names those two files as the record's companions, so
/// a rollback undoes them with the record and never leaves a record beside another run's signature.
public struct GenotypeAnnotationPublicationCoordinator {
    public let bundleURL: URL
    public let annotationFilename: String
    public let provenanceFilename: String?
    public let recordPublication: GenotypeAnnotationRecordPublication
    /// Files beside the record that its writer writes or removes in `alongside`. A rollback undoes
    /// them whenever it undoes the record.
    public let recordCompanionFilenames: [String]
    public let faultInjector: GenotypeAnnotationPublicationFaultInjector?

    public init(
        bundleURL: URL,
        annotationFilename: String,
        provenanceFilename: String?,
        recordPublication: GenotypeAnnotationRecordPublication = .payload,
        recordCompanionFilenames: [String] = [],
        faultInjector: GenotypeAnnotationPublicationFaultInjector?
    ) {
        self.bundleURL = bundleURL
        self.annotationFilename = annotationFilename
        self.provenanceFilename = provenanceFilename
        self.recordPublication = recordPublication
        self.recordCompanionFilenames = recordCompanionFilenames
        self.faultInjector = faultInjector
    }

    /// Takes the bundle's publication lock, then publishes what `prepare` returns.
    public func transact(
        prepare: (GenotypeAnnotationPublicationSnapshot) throws -> GenotypeAnnotationPublicationPayload?
    ) throws -> GenotypeAnnotationPublicationPayload? {
        let publicationLock = try ONTGenotypeBundlePublicationLock.acquire(for: bundleURL)
        defer { publicationLock.release() }
        return try publish(alongside: {}, prepare: prepare)
    }

    /// Publishes what `prepare` returns for a caller that already holds the bundle's publication
    /// lock. `alongside` runs inside the transaction once `annotations.json` holds the new bytes
    /// and before the payload's record. It publishes the record when `recordPublication` says so,
    /// or one kept in another folder, and a throw there rolls the pair back.
    public func transact(
        assuming publicationLock: ONTGenotypeBundlePublicationLock,
        alongside: () throws -> Void = {},
        prepare: (GenotypeAnnotationPublicationSnapshot) throws -> GenotypeAnnotationPublicationPayload?
    ) throws -> GenotypeAnnotationPublicationPayload? {
        let expected = ONTGenotypeBundlePublicationLock.lockURL(for: bundleURL).standardizedFileURL
        guard publicationLock.lockURL.standardizedFileURL == expected else {
            throw GenotypeAnnotationSidecarPublicationError.mismatchedPublicationLock(
                expectedPath: expected.path,
                actualPath: publicationLock.lockURL.standardizedFileURL.path
            )
        }
        return try publish(alongside: alongside, prepare: prepare)
    }

    private func publish(
        alongside: () throws -> Void,
        prepare: (GenotypeAnnotationPublicationSnapshot) throws -> GenotypeAnnotationPublicationPayload?
    ) throws -> GenotypeAnnotationPublicationPayload? {
        let directoryFD = try openBundleDirectory()
        defer { Darwin.close(directoryFD) }

        // An ExFAT swap that stopped halfway leaves its old file under a tombstone and nothing under
        // the name. Restore it first, or the snapshot would see nothing and an edit built from
        // nothing would replace it.
        for filename in [annotationFilename, provenanceFilename].compactMap({ $0 }) + recordCompanionFilenames {
            try DurableReplace.recover(named: filename, in: bundleURL)
        }

        let snapshot = GenotypeAnnotationPublicationSnapshot(
            annotationData: try readRegularFile(annotationFilename, directoryFD: directoryFD),
            provenanceData: try provenanceFilename.flatMap { try readRegularFile($0, directoryFD: directoryFD) }
        )
        // Only a rollback reads the companions' bytes, so they stay out of the snapshot.
        let companions: [(name: String, data: Data?)] = try recordCompanionFilenames.map {
            ($0, try readRegularFile($0, directoryFD: directoryFD))
        }
        guard let payload = try prepare(snapshot) else { return nil }

        var publishedAlongside = false
        do {
            try DurableReplace.transaction {
                try publish(payload.annotationData, filename: annotationFilename, directoryFD: directoryFD)
                if let error = faultInjector?(.beforeProvenancePublication) { throw error }
                try alongside()
                publishedAlongside = true
                if let provenanceFilename, recordPublication == .payload {
                    try publish(payload.provenanceData, filename: provenanceFilename, directoryFD: directoryFD)
                }
                if let error = faultInjector?(.commitDirectorySync) { throw error }
                guard Darwin.fsync(directoryFD) == 0 else {
                    throw systemError("synchronize annotation publication directory", bundleURL.path)
                }
            }
            return payload
        } catch {
            // Nothing may have changed yet, so only a restored or failed file wraps the error.
            let outcome = rollBack(
                snapshot,
                companions: companions,
                payload: payload,
                publishedAlongside: publishedAlongside,
                directoryFD: directoryFD
            )
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

    /// Puts back, in one transaction, every file that holds what this publication wrote or that
    /// holds nothing, and syncs the folder. The record's companions go back whenever the record
    /// does, as `companions` holds them from before `prepare` ran. `restored` says whether any file
    /// had to change.
    private func rollBack(
        _ snapshot: GenotypeAnnotationPublicationSnapshot,
        companions: [(name: String, data: Data?)],
        payload: GenotypeAnnotationPublicationPayload,
        publishedAlongside: Bool,
        directoryFD: Int32
    ) -> (restored: Bool, error: Error?) {
        var errors: [Error] = []
        var restored = false
        // Each name, the bytes the snapshot read, and the bytes this publication wrote, where
        // `nil` means any bytes under the name are this publication's.
        var names: [(String, Data?, Data?)] = [(annotationFilename, snapshot.annotationData, payload.annotationData)]
        if let provenanceFilename {
            switch recordPublication {
            case .payload:
                names.append((provenanceFilename, snapshot.provenanceData, payload.provenanceData))
            case .alongside:
                names.append((provenanceFilename, snapshot.provenanceData, nil))
                names += companions.map { ($0.name, $0.data, nil) }
            case .alongsideNew where publishedAlongside:
                names.append((provenanceFilename, snapshot.provenanceData, nil))
                names += companions.map { ($0.name, $0.data, nil) }
            case .alongsideNew:
                break
            }
        }
        do {
            try DurableReplace.transaction {
                for (filename, data, published) in names {
                    do {
                        if try restore(data, replacing: published, as: filename, directoryFD: directoryFD) {
                            restored = true
                        }
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
    /// is `nil`. A name that still holds `data` is left alone. A name that holds `published`, holds
    /// nothing or cannot be read is put back, and the restore reports why it could not. A name
    /// that holds anything else was changed by another writer and is left alone with an error.
    /// A `published` of `nil` counts any bytes under the name as this publication's.
    private func restore(_ data: Data?, replacing published: Data?, as filename: String, directoryFD: Int32) throws -> Bool {
        let current: Data??
        do {
            current = .some(try readRegularFile(filename, directoryFD: directoryFD))
        } catch {
            current = .none
        }
        if case .some(let found) = current {
            if found == data { return false }
            if let found, let published, found != published {
                throw GenotypeAnnotationPublicationCoordinatorError.changedByAnotherWriter(
                    bundleURL.appendingPathComponent(filename).path
                )
            }
        }
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
