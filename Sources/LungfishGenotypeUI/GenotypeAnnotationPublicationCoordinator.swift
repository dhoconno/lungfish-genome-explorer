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

        let directoryFD = bundleURL.path.withCString {
            Darwin.open($0, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        }
        guard directoryFD >= 0 else {
            throw systemError("open bundle directory without following links", bundleURL.path)
        }
        defer { Darwin.close(directoryFD) }

        let snapshot = GenotypeAnnotationPublicationSnapshot(
            annotationData: try readRegularFile(annotationFilename, directoryFD: directoryFD),
            provenanceData: try readRegularFile(provenanceFilename, directoryFD: directoryFD)
        )
        guard let payload = try prepare(snapshot) else { return nil }

        var publicationStarted = false
        do {
            try atomicWrite(payload.annotationData, filename: annotationFilename, directoryFD: directoryFD)
            publicationStarted = true
            if let error = faultInjector?(.beforeProvenancePublication) { throw error }
            try atomicWrite(payload.provenanceData, filename: provenanceFilename, directoryFD: directoryFD)
            if let error = faultInjector?(.commitDirectorySync) { throw error }
            guard Darwin.fsync(directoryFD) == 0 else {
                throw systemError("synchronize annotation publication directory", bundleURL.path)
            }
            return payload
        } catch {
            guard publicationStarted else { throw error }
            let rollbackError = rollback(snapshot, directoryFD: directoryFD)
            throw GenotypeAnnotationPublicationTransactionError(
                primaryError: error,
                rollbackError: rollbackError
            )
        }
    }

    private func readRegularFile(_ filename: String, directoryFD: Int32) throws -> Data? {
        let url = bundleURL.appendingPathComponent(filename)
        let descriptor = filename.withCString {
            Darwin.openat(directoryFD, $0, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        }
        guard descriptor >= 0 else {
            if errno == ENOENT { return nil }
            if errno == ELOOP { throw GenotypeAnnotationPublicationCoordinatorError.unsafeFile(url.path) }
            throw systemError("open publication file without following links", url.path)
        }
        defer { Darwin.close(descriptor) }
        var status = stat()
        guard Darwin.fstat(descriptor, &status) == 0,
              status.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG) else {
            throw GenotypeAnnotationPublicationCoordinatorError.unsafeFile(url.path)
        }
        var data = Data()
        if status.st_size > 0, status.st_size <= Int.max {
            data.reserveCapacity(Int(status.st_size))
        }
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let count = buffer.withUnsafeMutableBytes {
                Darwin.read(descriptor, $0.baseAddress, $0.count)
            }
            if count == 0 { break }
            if count < 0 {
                if errno == EINTR { continue }
                throw systemError("read publication file", url.path)
            }
            data.append(contentsOf: buffer.prefix(count))
        }
        return data
    }

    private func atomicWrite(_ data: Data, filename: String, directoryFD: Int32) throws {
        try validateExistingRegularFile(filename, directoryFD: directoryFD)
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
            throw systemError("atomically publish file", bundleURL.appendingPathComponent(filename).path)
        }
        removeTemporary = false
    }

    private func validateExistingRegularFile(_ filename: String, directoryFD: Int32) throws {
        var status = stat()
        let result = filename.withCString {
            Darwin.fstatat(directoryFD, $0, &status, AT_SYMLINK_NOFOLLOW)
        }
        if result == 0 {
            guard status.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG) else {
                throw GenotypeAnnotationPublicationCoordinatorError.unsafeFile(
                    bundleURL.appendingPathComponent(filename).path
                )
            }
        } else if errno != ENOENT {
            throw systemError("inspect publication destination", bundleURL.appendingPathComponent(filename).path)
        }
    }

    private func rollback(
        _ snapshot: GenotypeAnnotationPublicationSnapshot,
        directoryFD: Int32
    ) -> Error? {
        var errors: [Error] = []
        for (filename, data) in [
            (annotationFilename, snapshot.annotationData),
            (provenanceFilename, snapshot.provenanceData),
        ] {
            do {
                if let data {
                    try atomicWrite(data, filename: filename, directoryFD: directoryFD)
                } else {
                    try removeRegularFileIfPresent(filename, directoryFD: directoryFD)
                }
            } catch {
                errors.append(error)
            }
        }
        if Darwin.fsync(directoryFD) != 0 {
            errors.append(systemError("synchronize rollback directory", bundleURL.path))
        }
        guard !errors.isEmpty else { return nil }
        return NSError(
            domain: "GenotypeAnnotationPublicationRollback",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: errors.map(\.localizedDescription).joined(separator: "; ")]
        )
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
