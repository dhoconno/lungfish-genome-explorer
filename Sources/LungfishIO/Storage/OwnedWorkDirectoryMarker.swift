import Darwin
import Foundation

public struct FileSystemObjectIdentity: Codable, Equatable, Hashable, Sendable {
    public let device: UInt64
    public let inode: UInt64

    public init(device: UInt64, inode: UInt64) {
        self.device = device
        self.inode = inode
    }

    public static func noFollow(_ url: URL) throws -> Self {
        let standardized = url.standardizedFileURL
        guard standardized.isFileURL, !standardized.path.utf8.contains(0) else {
            throw OwnedWorkDirectoryMarkerError.unsafePath(url.path)
        }
        if standardized.path == "/" {
            let descriptor: Int32
            do {
                descriptor = try NoFollowFileSystem.openDirectoryHierarchy(standardized)
            } catch {
                throw OwnedWorkDirectoryMarkerError.unsafePath(standardized.path)
            }
            defer { Darwin.close(descriptor) }
            var info = stat()
            guard Darwin.fstat(descriptor, &info) == 0 else {
                throw OwnedWorkDirectoryMarkerError.systemFailure(
                    path: standardized.path,
                    operation: "inspect filesystem identity",
                    code: errno
                )
            }
            return Self(info)
        }

        let parentURL = standardized.deletingLastPathComponent()
        let leafName = standardized.lastPathComponent
        guard DurableAtomicFileStore.isSinglePathComponent(leafName) else {
            throw OwnedWorkDirectoryMarkerError.unsafePath(standardized.path)
        }
        let parentDescriptor: Int32
        do {
            parentDescriptor = try NoFollowFileSystem.openDirectoryHierarchy(parentURL)
        } catch {
            throw OwnedWorkDirectoryMarkerError.unsafePath(parentURL.path)
        }
        defer { Darwin.close(parentDescriptor) }
        var info = stat()
        let status = leafName.withCString {
            Darwin.fstatat(parentDescriptor, $0, &info, AT_SYMLINK_NOFOLLOW)
        }
        guard status == 0 else {
            throw OwnedWorkDirectoryMarkerError.systemFailure(
                path: standardized.path,
                operation: "inspect filesystem identity",
                code: errno
            )
        }
        return Self(device: UInt64(info.st_dev), inode: UInt64(info.st_ino))
    }

    init(_ info: stat) {
        self.init(device: UInt64(info.st_dev), inode: UInt64(info.st_ino))
    }

    public init(from info: stat) {
        self.init(info)
    }
}

public struct OwnedProcessIdentity: Codable, Equatable, Sendable {
    public let processIdentifier: Int32
    public let processStartTime: UInt64
    public let bootSessionID: String

    public init(
        processIdentifier: Int32,
        processStartTime: UInt64,
        bootSessionID: String
    ) {
        self.processIdentifier = processIdentifier
        self.processStartTime = processStartTime
        self.bootSessionID = bootSessionID
    }

    public static func current() throws -> Self {
        guard let identity = try inspect(
            processIdentifier: ProcessInfo.processInfo.processIdentifier
        ) else {
            throw OwnedWorkDirectoryMarkerError.systemFailure(
                path: "current-process",
                operation: "read process identity",
                code: ESRCH
            )
        }
        return identity
    }

    /// Returns the complete identity of a live process, or `nil` when the PID
    /// no longer exists. A caller must compare every field; PID alone is never
    /// sufficient authority.
    public static func inspect(processIdentifier pid: Int32) throws -> Self? {
        var processInfo = proc_bsdinfo()
        errno = 0
        let result = withUnsafeMutablePointer(to: &processInfo) { pointer in
            proc_pidinfo(
                pid,
                PROC_PIDTBSDINFO,
                0,
                pointer,
                Int32(MemoryLayout<proc_bsdinfo>.size)
            )
        }
        guard result == Int32(MemoryLayout<proc_bsdinfo>.size) else {
            if errno == ESRCH {
                return nil
            }
            throw OwnedWorkDirectoryMarkerError.systemFailure(
                path: "pid:\(pid)",
                operation: "read process start identity",
                code: errno
            )
        }

        var bootSessionSize = 0
        guard sysctlbyname(
            "kern.bootsessionuuid",
            nil,
            &bootSessionSize,
            nil,
            0
        ) == 0, bootSessionSize > 1 else {
            throw OwnedWorkDirectoryMarkerError.systemFailure(
                path: "kern.bootsessionuuid",
                operation: "read boot session identity",
                code: errno
            )
        }
        var bootSessionBytes = [UInt8](repeating: 0, count: bootSessionSize)
        let bootStatus = bootSessionBytes.withUnsafeMutableBytes { bytes in
            sysctlbyname(
                "kern.bootsessionuuid",
                bytes.baseAddress,
                &bootSessionSize,
                nil,
                0
            )
        }
        guard bootStatus == 0 else {
            throw OwnedWorkDirectoryMarkerError.systemFailure(
                path: "kern.bootsessionuuid",
                operation: "read boot session identity",
                code: errno
            )
        }
        let bootID = String(
            decoding: bootSessionBytes.prefix { $0 != 0 },
            as: UTF8.self
        )
        guard UUID(uuidString: bootID) != nil else {
            throw OwnedWorkDirectoryMarkerError.systemFailure(
                path: "kern.bootsessionuuid",
                operation: "validate boot session identity",
                code: EINVAL
            )
        }

        let processStart = UInt64(processInfo.pbi_start_tvsec) * 1_000_000
            + UInt64(processInfo.pbi_start_tvusec)
        return Self(
            processIdentifier: pid,
            processStartTime: processStart,
            bootSessionID: bootID
        )
    }
}

public struct OwnedWorkDirectoryMarker: Codable, Equatable, Sendable {
    public enum State: String, Codable, Equatable, Sendable {
        case active
        case completed
        case failed
    }

    public static let schemaVersion = 2
    public static let fileName = ".lungfish-owned-work-directory.json"

    public let schemaVersion: Int
    public let projectIdentity: FileSystemObjectIdentity
    public let directoryIdentity: FileSystemObjectIdentity
    public let runID: UUID
    public let processIdentifier: Int32
    public let processStartTime: UInt64
    public let bootSessionID: String
    public let state: State
    public let lockRelativePath: String?
    public let keepIntermediates: Bool
    public let toolName: String
    public let toolVersion: String

    public init(
        projectIdentity: FileSystemObjectIdentity,
        directoryIdentity: FileSystemObjectIdentity,
        runID: UUID,
        processIdentifier: Int32,
        processStartTime: UInt64,
        bootSessionID: String,
        state: State,
        lockRelativePath: String?,
        keepIntermediates: Bool,
        toolName: String,
        toolVersion: String
    ) {
        self.schemaVersion = Self.schemaVersion
        self.projectIdentity = projectIdentity
        self.directoryIdentity = directoryIdentity
        self.runID = runID
        self.processIdentifier = processIdentifier
        self.processStartTime = processStartTime
        self.bootSessionID = bootSessionID
        self.state = state
        self.lockRelativePath = lockRelativePath
        self.keepIntermediates = keepIntermediates
        self.toolName = toolName
        self.toolVersion = toolVersion
    }

    public func matchesProcessIdentity(_ identity: OwnedProcessIdentity) -> Bool {
        processIdentifier == identity.processIdentifier
            && processStartTime == identity.processStartTime
            && bootSessionID == identity.bootSessionID
    }
}

public struct OwnedWorkDirectoryCreationRequest: Sendable {
    public let projectURL: URL
    public let parentDirectoryURL: URL
    public let prefix: String
    public let runID: UUID
    public let processIdentity: OwnedProcessIdentity
    public let state: OwnedWorkDirectoryMarker.State
    public let lockRelativePath: String?
    public let keepIntermediates: Bool
    public let toolName: String
    public let toolVersion: String

    public init(
        projectURL: URL,
        parentDirectoryURL: URL,
        prefix: String,
        runID: UUID,
        processIdentity: OwnedProcessIdentity,
        state: OwnedWorkDirectoryMarker.State,
        lockRelativePath: String?,
        keepIntermediates: Bool,
        toolName: String,
        toolVersion: String
    ) {
        self.projectURL = projectURL
        self.parentDirectoryURL = parentDirectoryURL
        self.prefix = prefix
        self.runID = runID
        self.processIdentity = processIdentity
        self.state = state
        self.lockRelativePath = lockRelativePath
        self.keepIntermediates = keepIntermediates
        self.toolName = toolName
        self.toolVersion = toolVersion
    }
}

public enum OwnedWorkDirectoryMarkerError: Error, LocalizedError, Equatable {
    case invalidRequest(String)
    case unsafePath(String)
    case missingMarker(String)
    case invalidMarker(String)
    case identityMismatch(String)
    case systemFailure(path: String, operation: String, code: Int32)

    public var errorDescription: String? {
        switch self {
        case .invalidRequest(let detail): return "Invalid owned work-directory request: \(detail)"
        case .unsafePath(let path): return "Owned work-directory path is unsafe: \(path)"
        case .missingMarker(let path): return "Owned work-directory marker is missing: \(path)"
        case .invalidMarker(let detail): return "Owned work-directory marker is invalid: \(detail)"
        case .identityMismatch(let path): return "Owned work-directory identity no longer matches: \(path)"
        case .systemFailure(let path, let operation, let code):
            return "Could not \(operation) \(path) (errno \(code))."
        }
    }
}

public enum OwnedWorkDirectoryMarkerStore {
    @discardableResult
    public static func createDirectory(
        _ request: OwnedWorkDirectoryCreationRequest,
        atomicFileStore: DurableAtomicFileStore = .init()
    ) throws -> URL {
        try validate(request)

        let projectURL = request.projectURL.standardizedFileURL
        let parentURL = request.parentDirectoryURL.standardizedFileURL
        let projectPath = projectURL.path
        guard parentURL.path == projectPath || parentURL.path.hasPrefix(projectPath + "/") else {
            throw OwnedWorkDirectoryMarkerError.invalidRequest(
                "parent is outside the bound project"
            )
        }

        let projectDescriptor: Int32
        do {
            projectDescriptor = try NoFollowFileSystem.openDirectoryHierarchy(projectURL)
        } catch {
            throw OwnedWorkDirectoryMarkerError.unsafePath(parentURL.path)
        }
        let parentDescriptor: Int32
        do {
            parentDescriptor = try NoFollowFileSystem.openDirectoryHierarchy(parentURL)
        } catch {
            Darwin.close(projectDescriptor)
            throw OwnedWorkDirectoryMarkerError.unsafePath(parentURL.path)
        }
        defer {
            Darwin.close(parentDescriptor)
            Darwin.close(projectDescriptor)
        }

        var projectInfo = stat()
        var parentInfo = stat()
        guard Darwin.fstat(projectDescriptor, &projectInfo) == 0,
              Darwin.fstat(parentDescriptor, &parentInfo) == 0 else {
            throw OwnedWorkDirectoryMarkerError.systemFailure(
                path: parentURL.path,
                operation: "inspect owned directory parent",
                code: errno
            )
        }
        let projectIdentity = FileSystemObjectIdentity(projectInfo)

        let childName = "\(request.prefix)\(UUID().uuidString)"
        guard childName.withCString({
            Darwin.mkdirat(parentDescriptor, $0, S_IRWXU)
        }) == 0 else {
            throw OwnedWorkDirectoryMarkerError.systemFailure(
                path: parentURL.appendingPathComponent(childName).path,
                operation: "create owned work directory",
                code: errno
            )
        }
        let childURL = parentURL.appendingPathComponent(childName, isDirectory: true)

        let childDescriptor = childName.withCString {
            Darwin.openat(
                parentDescriptor,
                $0,
                O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
            )
        }
        guard childDescriptor >= 0 else {
            // Without an open descriptor there is no authoritative inode to
            // bind rollback to. Leave the entry recoverable.
            throw OwnedWorkDirectoryMarkerError.systemFailure(
                path: childURL.path,
                operation: "open owned work directory",
                code: errno
            )
        }
        defer { Darwin.close(childDescriptor) }

        var childInfo = stat()
        guard Darwin.fstat(childDescriptor, &childInfo) == 0 else {
            throw OwnedWorkDirectoryMarkerError.systemFailure(
                path: childURL.path,
                operation: "inspect owned work directory",
                code: errno
            )
        }
        let childIdentity = FileSystemObjectIdentity(childInfo)
        guard childInfo.st_mode & S_IFMT == S_IFDIR else {
            rollbackNewDirectory(
                named: childName,
                parentDescriptor: parentDescriptor,
                childDescriptor: childDescriptor,
                expectedIdentity: childIdentity
            )
            throw OwnedWorkDirectoryMarkerError.unsafePath(childURL.path)
        }

        let marker = OwnedWorkDirectoryMarker(
            projectIdentity: projectIdentity,
            directoryIdentity: childIdentity,
            runID: request.runID,
            processIdentifier: request.processIdentity.processIdentifier,
            processStartTime: request.processIdentity.processStartTime,
            bootSessionID: request.processIdentity.bootSessionID,
            state: request.state,
            lockRelativePath: request.lockRelativePath,
            keepIntermediates: request.keepIntermediates,
            toolName: request.toolName,
            toolVersion: request.toolVersion
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]

        do {
            let data = try encoder.encode(marker)
            try atomicFileStore.create(
                data,
                named: OwnedWorkDirectoryMarker.fileName,
                inOpenDirectory: childDescriptor,
                displayedAt: childURL
            )
            guard Darwin.fsync(parentDescriptor) == 0 else {
                throw OwnedWorkDirectoryMarkerError.systemFailure(
                    path: parentURL.path,
                    operation: "fsync owned directory parent",
                    code: errno
                )
            }
            let validated = try load(from: childURL, expectedProjectURL: projectURL)
            guard validated == marker else {
                throw OwnedWorkDirectoryMarkerError.invalidMarker(
                    "published marker changed during creation"
                )
            }
            return childURL
        } catch {
            rollbackNewDirectory(
                named: childName,
                parentDescriptor: parentDescriptor,
                childDescriptor: childDescriptor,
                expectedIdentity: childIdentity
            )
            _ = Darwin.fsync(parentDescriptor)
            throw error
        }
    }

    public static func load(
        from directoryURL: URL,
        expectedProjectURL: URL
    ) throws -> OwnedWorkDirectoryMarker {
        let directoryDescriptor: Int32
        do {
            directoryDescriptor = try NoFollowFileSystem.openDirectoryHierarchy(directoryURL)
        } catch {
            throw OwnedWorkDirectoryMarkerError.unsafePath(directoryURL.path)
        }
        defer { Darwin.close(directoryDescriptor) }
        return try load(
            fromOpenDirectory: directoryDescriptor,
            displayedAt: directoryURL,
            expectedProjectURL: expectedProjectURL
        )
    }

    /// Loads a marker while remaining bound to a directory descriptor already
    /// opened by a larger transaction. The caller retains ownership of it.
    static func load(
        fromOpenDirectory directoryDescriptor: Int32,
        displayedAt directoryURL: URL,
        expectedProjectURL: URL
    ) throws -> OwnedWorkDirectoryMarker {
        let projectDescriptor: Int32
        do {
            projectDescriptor = try NoFollowFileSystem.openDirectoryHierarchy(expectedProjectURL)
        } catch {
            throw OwnedWorkDirectoryMarkerError.unsafePath(directoryURL.path)
        }
        defer {
            Darwin.close(projectDescriptor)
        }

        var directoryInfo = stat()
        var projectInfo = stat()
        guard Darwin.fstat(directoryDescriptor, &directoryInfo) == 0,
              Darwin.fstat(projectDescriptor, &projectInfo) == 0 else {
            throw OwnedWorkDirectoryMarkerError.systemFailure(
                path: directoryURL.path,
                operation: "inspect owned marker identities",
                code: errno
            )
        }

        let data: Data
        do {
            data = try NoFollowFileSystem.readRegularFile(
                named: OwnedWorkDirectoryMarker.fileName,
                inDirectory: directoryDescriptor,
                displayPath: directoryURL.path
            )
        } catch let error as POSIXError where error.code == .ENOENT {
            throw OwnedWorkDirectoryMarkerError.missingMarker(directoryURL.path)
        } catch {
            throw OwnedWorkDirectoryMarkerError.invalidMarker(
                "marker must be a bounded regular file at \(directoryURL.path)"
            )
        }

        let marker: OwnedWorkDirectoryMarker
        do {
            marker = try JSONDecoder().decode(OwnedWorkDirectoryMarker.self, from: data)
        } catch {
            throw OwnedWorkDirectoryMarkerError.invalidMarker(error.localizedDescription)
        }
        guard marker.schemaVersion == OwnedWorkDirectoryMarker.schemaVersion,
              !marker.toolName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !marker.toolVersion.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw OwnedWorkDirectoryMarkerError.invalidMarker("unsupported schema or empty tool identity")
        }
        guard marker.directoryIdentity == FileSystemObjectIdentity(directoryInfo) else {
            throw OwnedWorkDirectoryMarkerError.identityMismatch(directoryURL.path)
        }
        guard marker.projectIdentity == FileSystemObjectIdentity(projectInfo) else {
            throw OwnedWorkDirectoryMarkerError.identityMismatch(expectedProjectURL.path)
        }
        try validateLockRelativePath(marker.lockRelativePath)
        return marker
    }

    private static func validate(_ request: OwnedWorkDirectoryCreationRequest) throws {
        guard DurableAtomicFileStore.isSinglePathComponent(request.prefix + "x"),
              !request.prefix.isEmpty else {
            throw OwnedWorkDirectoryMarkerError.invalidRequest("prefix is not a safe path prefix")
        }
        guard !request.toolName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !request.toolVersion.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw OwnedWorkDirectoryMarkerError.invalidRequest("tool name and version are required")
        }
        try validateLockRelativePath(request.lockRelativePath)
    }

    private static func validateLockRelativePath(_ path: String?) throws {
        guard let path else { return }
        let components = NSString(string: path).pathComponents
        guard !path.isEmpty,
              !path.utf8.contains(0),
              !path.hasPrefix("/"),
              !components.contains(".."),
              !components.contains(".") else {
            throw OwnedWorkDirectoryMarkerError.invalidRequest(
                "lock path must be project-relative without traversal"
            )
        }
    }

    private static func rollbackNewDirectory(
        named childName: String,
        parentDescriptor: Int32,
        childDescriptor: Int32,
        expectedIdentity: FileSystemObjectIdentity
    ) {
        let quarantineName =
            ".lungfish-owned-rollback-pending-\(UUID().uuidString.lowercased())"
        let detachStatus = childName.withCString { source in
            quarantineName.withCString { quarantine in
                Darwin.renameatx_np(
                    parentDescriptor,
                    source,
                    parentDescriptor,
                    quarantine,
                    UInt32(RENAME_EXCL)
                )
            }
        }
        guard detachStatus == 0 else { return }

        var quarantineInfo = stat()
        let inspectStatus = quarantineName.withCString {
            Darwin.fstatat(
                parentDescriptor,
                $0,
                &quarantineInfo,
                AT_SYMLINK_NOFOLLOW
            )
        }
        guard inspectStatus == 0,
              FileSystemObjectIdentity(quarantineInfo) == expectedIdentity else {
            _ = quarantineName.withCString { quarantine in
                childName.withCString { destination in
                    Darwin.renameatx_np(
                        parentDescriptor,
                        quarantine,
                        parentDescriptor,
                        destination,
                        UInt32(RENAME_EXCL)
                    )
                }
            }
            _ = Darwin.fsync(parentDescriptor)
            return
        }

        _ = OwnedWorkDirectoryMarker.fileName.withCString {
            Darwin.unlinkat(childDescriptor, $0, 0)
        }
        var finalInfo = stat()
        let finalStatus = quarantineName.withCString {
            Darwin.fstatat(
                parentDescriptor,
                $0,
                &finalInfo,
                AT_SYMLINK_NOFOLLOW
            )
        }
        guard finalStatus == 0,
              FileSystemObjectIdentity(finalInfo) == expectedIdentity else {
            return
        }
        _ = quarantineName.withCString {
            Darwin.unlinkat(parentDescriptor, $0, AT_REMOVEDIR)
        }
        _ = Darwin.fsync(parentDescriptor)
    }
}
