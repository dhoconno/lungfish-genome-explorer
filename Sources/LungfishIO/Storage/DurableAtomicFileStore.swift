import Darwin
import Foundation

/// Exclusively publishes immutable files and makes both file contents and the
/// containing directory entry durable before returning.
public struct DurableAtomicFileStore: Sendable {
    public enum StoreError: Error, LocalizedError, Equatable {
        case invalidFileName(String)
        case unsafeDirectory(String)
        case destinationExists(String)
        case rollbackQuarantineRetained(path: String, operation: String, code: Int32)
        case rollbackRemovalDurabilityUncertain(path: String, operation: String, code: Int32)
        case systemFailure(path: String, operation: String, code: Int32)

        public var errorDescription: String? {
            switch self {
            case .invalidFileName(let name):
                return "Durable file name must be a single path component: \(name)"
            case .unsafeDirectory(let path):
                return "Durable file parent must be a real directory without symbolic links: \(path)"
            case .destinationExists(let path):
                return "Durable file already exists: \(path)"
            case .rollbackQuarantineRetained(let path, let operation, let code):
                return "Durable rollback retained recoverable data at \(path) after \(operation) failed (errno \(code))."
            case .rollbackRemovalDurabilityUncertain(let path, let operation, let code):
                return "Durable rollback removal at \(path) has uncertain durability after \(operation) failed (errno \(code))."
            case .systemFailure(let path, let operation, let code):
                return "Could not \(operation) \(path) (errno \(code))."
            }
        }
    }

    public struct Operations: Sendable {
        public typealias Synchronizer = @Sendable (Int32) -> Int32
        public typealias EntryRemover = @Sendable (Int32, String) -> Int32

        public var syncFile: Synchronizer
        public var syncDirectory: Synchronizer
        public var syncRollbackDirectory: Synchronizer
        public var removeRollbackFile: EntryRemover
        public var beforeRollbackDetach: @Sendable () -> Void

        public init(
            syncFile: @escaping Synchronizer = { Darwin.fsync($0) },
            syncDirectory: @escaping Synchronizer = { Darwin.fsync($0) },
            syncRollbackDirectory: @escaping Synchronizer = { Darwin.fsync($0) },
            removeRollbackFile: @escaping EntryRemover = { descriptor, name in
                name.withCString { Darwin.unlinkat(descriptor, $0, 0) }
            },
            beforeRollbackDetach: @escaping @Sendable () -> Void = {}
        ) {
            self.syncFile = syncFile
            self.syncDirectory = syncDirectory
            self.syncRollbackDirectory = syncRollbackDirectory
            self.removeRollbackFile = removeRollbackFile
            self.beforeRollbackDetach = beforeRollbackDetach
        }
    }

    private let operations: Operations

    public init(operations: Operations = .init()) {
        self.operations = operations
    }

    /// Creates `fileName` without replacing any existing filesystem object.
    ///
    /// Publication uses a same-directory temporary regular file, file fsync,
    /// exclusive rename, and parent-directory fsync. A failure removes only a
    /// filesystem object still proven to be this invocation's own file.
    @discardableResult
    public func create(_ data: Data, named fileName: String, in directoryURL: URL) throws -> URL {
        let directoryDescriptor: Int32
        do {
            directoryDescriptor = try NoFollowFileSystem.openDirectoryHierarchy(directoryURL)
        } catch {
            throw StoreError.unsafeDirectory(directoryURL.path)
        }
        defer { Darwin.close(directoryDescriptor) }
        return try create(
            data,
            named: fileName,
            inOpenDirectory: directoryDescriptor,
            displayedAt: directoryURL
        )
    }

    /// Descriptor-relative variant for callers that must keep the parent bound
    /// to the same inode throughout a larger transaction.
    @discardableResult
    public func create(
        _ data: Data,
        named fileName: String,
        inOpenDirectory directoryDescriptor: Int32,
        displayedAt directoryURL: URL
    ) throws -> URL {
        guard Self.isSinglePathComponent(fileName) else {
            throw StoreError.invalidFileName(fileName)
        }
        var directoryInfo = stat()
        guard Darwin.fstat(directoryDescriptor, &directoryInfo) == 0,
              directoryInfo.st_mode & S_IFMT == S_IFDIR else {
            throw StoreError.unsafeDirectory(directoryURL.path)
        }
        let destinationURL = directoryURL.appendingPathComponent(fileName)
        let temporaryName = ".\(fileName).tmp-\(UUID().uuidString.lowercased())"
        let descriptor = temporaryName.withCString {
            Darwin.openat(
                directoryDescriptor,
                $0,
                O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
                S_IRUSR | S_IWUSR
            )
        }
        guard descriptor >= 0 else {
            throw StoreError.systemFailure(
                path: directoryURL.appendingPathComponent(temporaryName).path,
                operation: "create temporary durable file",
                code: errno
            )
        }

        var descriptorIsOpen = true
        var published = false
        var publishedIdentity: FileSystemObjectIdentity?
        defer {
            if descriptorIsOpen {
                Darwin.close(descriptor)
            }
            if !published {
                _ = temporaryName.withCString { Darwin.unlinkat(directoryDescriptor, $0, 0) }
            }
        }

        do {
            try Self.writeAll(data, descriptor: descriptor, path: destinationURL.path)
            guard operations.syncFile(descriptor) == 0 else {
                throw StoreError.systemFailure(
                    path: destinationURL.path,
                    operation: "fsync durable file",
                    code: errno
                )
            }
            var temporaryInfo = stat()
            guard Darwin.fstat(descriptor, &temporaryInfo) == 0,
                  temporaryInfo.st_mode & S_IFMT == S_IFREG else {
                throw StoreError.systemFailure(
                    path: destinationURL.path,
                    operation: "inspect durable file identity",
                    code: errno == 0 ? EIO : errno
                )
            }
            publishedIdentity = FileSystemObjectIdentity(temporaryInfo)
            guard Darwin.close(descriptor) == 0 else {
                descriptorIsOpen = false
                throw StoreError.systemFailure(
                    path: destinationURL.path,
                    operation: "close durable file",
                    code: errno
                )
            }
            descriptorIsOpen = false

            let renameStatus = temporaryName.withCString { temporary in
                fileName.withCString { destination in
                    Darwin.renameatx_np(
                        directoryDescriptor,
                        temporary,
                        directoryDescriptor,
                        destination,
                        UInt32(RENAME_EXCL)
                    )
                }
            }
            guard renameStatus == 0 else {
                if errno == EEXIST {
                    throw StoreError.destinationExists(destinationURL.path)
                }
                throw StoreError.systemFailure(
                    path: destinationURL.path,
                    operation: "publish durable file exclusively",
                    code: errno
                )
            }
            published = true

            guard operations.syncDirectory(directoryDescriptor) == 0 else {
                let code = errno
                if let publishedIdentity,
                   try rollbackPublishedFile(
                       named: fileName,
                       expectedIdentity: publishedIdentity,
                       inDirectory: directoryDescriptor,
                       displayedAt: directoryURL
                   ) {
                    published = false
                }
                throw StoreError.systemFailure(
                    path: directoryURL.path,
                    operation: "fsync durable file parent",
                    code: code
                )
            }
            return destinationURL
        } catch {
            throw error
        }
    }

    private static func writeAll(_ data: Data, descriptor: Int32, path: String) throws {
        try data.withUnsafeBytes { rawBuffer in
            guard var cursor = rawBuffer.baseAddress else { return }
            var remaining = rawBuffer.count
            while remaining > 0 {
                let count = Darwin.write(descriptor, cursor, remaining)
                if count < 0 {
                    if errno == EINTR { continue }
                    throw StoreError.systemFailure(
                        path: path,
                        operation: "write durable file",
                        code: errno
                    )
                }
                guard count > 0 else {
                    throw StoreError.systemFailure(
                        path: path,
                        operation: "write durable file",
                        code: EIO
                    )
                }
                remaining -= count
                cursor = cursor.advanced(by: count)
            }
        }
    }

    static func isSinglePathComponent(_ value: String) -> Bool {
        !value.isEmpty
            && value != "."
            && value != ".."
            && !value.contains("/")
            && !value.utf8.contains(0)
    }

    private static func identity(
        named fileName: String,
        inDirectory directoryDescriptor: Int32
    ) -> FileSystemObjectIdentity? {
        var info = stat()
        let status = fileName.withCString {
            Darwin.fstatat(directoryDescriptor, $0, &info, AT_SYMLINK_NOFOLLOW)
        }
        guard status == 0 else { return nil }
        return FileSystemObjectIdentity(info)
    }

    /// Rollback never unlinks the destination pathname directly. It first
    /// detaches that entry exclusively, then proves the quarantined inode is
    /// the file published by this invocation.
    private func rollbackPublishedFile(
        named fileName: String,
        expectedIdentity: FileSystemObjectIdentity,
        inDirectory directoryDescriptor: Int32,
        displayedAt directoryURL: URL
    ) throws -> Bool {
        guard Self.identity(
            named: fileName,
            inDirectory: directoryDescriptor
        ) == expectedIdentity else {
            return false
        }

        operations.beforeRollbackDetach()
        let quarantineName =
            ".\(fileName).rollback-pending-\(UUID().uuidString.lowercased())"
        let quarantineURL = directoryURL.appendingPathComponent(quarantineName)
        let renameStatus = fileName.withCString { source in
            quarantineName.withCString { quarantine in
                Darwin.renameatx_np(
                    directoryDescriptor,
                    source,
                    directoryDescriptor,
                    quarantine,
                    UInt32(RENAME_EXCL)
                )
            }
        }
        guard renameStatus == 0 else {
            let code = errno
            if code == ENOENT { return false }
            throw StoreError.rollbackQuarantineRetained(
                path: directoryURL.appendingPathComponent(fileName).path,
                operation: "detach durable file into rollback quarantine",
                code: code
            )
        }

        guard Self.identity(
            named: quarantineName,
            inDirectory: directoryDescriptor
        ) == expectedIdentity else {
            // A substitution won the race after the first identity check.
            // Restore it only if its original name is still unoccupied;
            // otherwise leave the quarantine as recoverable evidence.
            let restoreStatus = quarantineName.withCString { quarantine in
                fileName.withCString { destination in
                    Darwin.renameatx_np(
                        directoryDescriptor,
                        quarantine,
                        directoryDescriptor,
                        destination,
                        UInt32(RENAME_EXCL)
                    )
                }
            }
            guard restoreStatus == 0 else {
                throw StoreError.rollbackQuarantineRetained(
                    path: quarantineURL.path,
                    operation: "restore substituted durable rollback quarantine",
                    code: errno
                )
            }
            guard operations.syncRollbackDirectory(directoryDescriptor) == 0 else {
                throw StoreError.rollbackRemovalDurabilityUncertain(
                    path: directoryURL.appendingPathComponent(fileName).path,
                    operation: "fsync restored durable rollback entry",
                    code: errno
                )
            }
            return false
        }

        guard operations.syncRollbackDirectory(directoryDescriptor) == 0 else {
            throw StoreError.rollbackQuarantineRetained(
                path: quarantineURL.path,
                operation: "fsync durable rollback quarantine parent",
                code: errno
            )
        }
        let unlinkStatus = operations.removeRollbackFile(
            directoryDescriptor,
            quarantineName
        )
        guard unlinkStatus == 0 else {
            throw StoreError.rollbackQuarantineRetained(
                path: quarantineURL.path,
                operation: "remove durable rollback quarantine",
                code: errno
            )
        }
        guard operations.syncRollbackDirectory(directoryDescriptor) == 0 else {
            throw StoreError.rollbackRemovalDurabilityUncertain(
                path: quarantineURL.path,
                operation: "fsync durable rollback quarantine removal",
                code: errno
            )
        }
        return true
    }
}

public enum NoFollowFileSystem {
    /// Opens an absolute directory path one component at a time without
    /// following caller-controlled symbolic links. The caller owns the
    /// returned descriptor and must close it.
    public static func openDirectoryHierarchy(_ url: URL) throws -> Int32 {
        let requested = url.standardizedFileURL
        // `/var` and `/tmp` are immutable compatibility links installed by
        // macOS itself. Canonicalize only these two platform aliases before
        // performing descriptor-relative no-follow traversal; arbitrary
        // caller-controlled symbolic links remain rejected.
        let traversalPath: String
        if requested.path == "/var" || requested.path.hasPrefix("/var/") {
            traversalPath = "/private" + requested.path
        } else if requested.path == "/tmp" || requested.path.hasPrefix("/tmp/") {
            traversalPath = "/private" + requested.path
        } else {
            traversalPath = requested.path
        }
        guard requested.isFileURL, traversalPath.hasPrefix("/") else {
            throw POSIXError(.EINVAL)
        }
        var descriptor = Darwin.open("/", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }

        do {
            let components = NSString(string: traversalPath).pathComponents
            for component in components.dropFirst() where component != "/" {
                let next = component.withCString {
                    Darwin.openat(
                        descriptor,
                        $0,
                        O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
                    )
                }
                guard next >= 0 else {
                    throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                }
                Darwin.close(descriptor)
                descriptor = next
            }
            var info = stat()
            guard Darwin.fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFDIR else {
                throw POSIXError(.ENOTDIR)
            }
            return descriptor
        } catch {
            Darwin.close(descriptor)
            throw error
        }
    }

    static func readRegularFile(
        named fileName: String,
        inDirectory directoryDescriptor: Int32,
        displayPath: String,
        maximumSize: Int = 1_048_576
    ) throws -> Data {
        let descriptor = fileName.withCString {
            Darwin.openat(
                directoryDescriptor,
                $0,
                O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC
            )
        }
        guard descriptor >= 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        defer { Darwin.close(descriptor) }

        var info = stat()
        guard Darwin.fstat(descriptor, &info) == 0,
              info.st_mode & S_IFMT == S_IFREG,
              info.st_size >= 0,
              info.st_size <= maximumSize else {
            throw POSIXError(.EINVAL)
        }

        var result = Data()
        result.reserveCapacity(Int(info.st_size))
        var buffer = [UInt8](repeating: 0, count: 16_384)
        while true {
            let count = buffer.withUnsafeMutableBytes { rawBuffer in
                Darwin.read(descriptor, rawBuffer.baseAddress, rawBuffer.count)
            }
            if count < 0 {
                if errno == EINTR { continue }
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            if count == 0 { break }
            guard result.count + count <= maximumSize else {
                throw POSIXError(.EFBIG)
            }
            result.append(buffer, count: count)
        }
        return result
    }
}
