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
    case rollbackQuarantineRetained(path: String, operation: String, code: Int32)
    case rollbackRemovalDurabilityUncertain(path: String, operation: String, code: Int32)
    case creationAndRollbackFailed(
        path: String,
        initiatingError: String,
        rollbackError: String
    )
    case cleanupQuarantineRetained(path: String, operation: String, code: Int32)
    case cleanupQuarantineLocationUncertain(
        lastKnownPath: String,
        operation: String,
        code: Int32
    )
    case cleanupRemovalDurabilityUncertain(path: String, operation: String, code: Int32)
    case systemFailure(path: String, operation: String, code: Int32)

    public var errorDescription: String? {
        switch self {
        case .invalidRequest(let detail): return "Invalid owned work-directory request: \(detail)"
        case .unsafePath(let path): return "Owned work-directory path is unsafe: \(path)"
        case .missingMarker(let path): return "Owned work-directory marker is missing: \(path)"
        case .invalidMarker(let detail): return "Owned work-directory marker is invalid: \(detail)"
        case .identityMismatch(let path): return "Owned work-directory identity no longer matches: \(path)"
        case .rollbackQuarantineRetained(let path, let operation, let code):
            return "Owned work-directory rollback retained a recoverable quarantine at \(path) after \(operation) failed (errno \(code))."
        case .rollbackRemovalDurabilityUncertain(let path, let operation, let code):
            return "Owned work-directory rollback removal at \(path) has uncertain durability after \(operation) failed (errno \(code))."
        case .creationAndRollbackFailed(
            let path,
            let initiatingError,
            let rollbackError
        ):
            return "Owned work-directory creation or binding failed at \(path): \(initiatingError) Rollback also failed and retained or left an uncertain disposition: \(rollbackError)"
        case .cleanupQuarantineRetained(let path, let operation, let code):
            return "Temporary cleanup retained recoverable or partially cleaned data at \(path) after \(operation) failed (errno \(code))."
        case .cleanupQuarantineLocationUncertain(let path, let operation, let code):
            return "Temporary cleanup can no longer verify its quarantine at the last known path \(path) after \(operation) failed (errno \(code))."
        case .cleanupRemovalDurabilityUncertain(let path, let operation, let code):
            return "Temporary cleanup removal at \(path) has uncertain durability after \(operation) failed (errno \(code))."
        case .systemFailure(let path, let operation, let code):
            return "Could not \(operation) \(path) (errno \(code))."
        }
    }
}

public enum OwnedWorkDirectoryMarkerStore {
    public struct RollbackOperations: Sendable {
        public typealias Synchronizer = @Sendable (Int32) -> Int32
        public typealias EntryRemover = @Sendable (Int32, String) -> Int32
        public typealias ChildOpener = @Sendable (Int32, String) -> Int32

        public var syncParent: Synchronizer
        public var removeMarker: EntryRemover
        public var removeDirectory: EntryRemover
        public var openChild: ChildOpener

        public init(
            syncParent: @escaping Synchronizer = { Darwin.fsync($0) },
            removeMarker: @escaping EntryRemover = { descriptor, name in
                name.withCString { Darwin.unlinkat(descriptor, $0, 0) }
            },
            removeDirectory: @escaping EntryRemover = { descriptor, name in
                name.withCString { Darwin.unlinkat(descriptor, $0, AT_REMOVEDIR) }
            }
        ) {
            self.syncParent = syncParent
            self.removeMarker = removeMarker
            self.removeDirectory = removeDirectory
            self.openChild = { descriptor, name in
                name.withCString {
                    Darwin.openat(
                        descriptor,
                        $0,
                        O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
                    )
                }
            }
        }
    }

    @discardableResult
    public static func createDirectory(
        _ request: OwnedWorkDirectoryCreationRequest,
        atomicFileStore: DurableAtomicFileStore = .init(),
        rollbackOperations: RollbackOperations = .init()
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

        var createdInfo = stat()
        let inspectCreatedStatus = childName.withCString {
            Darwin.fstatat(
                parentDescriptor,
                $0,
                &createdInfo,
                AT_SYMLINK_NOFOLLOW
            )
        }
        guard inspectCreatedStatus == 0,
              createdInfo.st_mode & S_IFMT == S_IFDIR else {
            throw OwnedWorkDirectoryMarkerError.systemFailure(
                path: childURL.path,
                operation: "inspect newly created owned work directory",
                code: errno == 0 ? EINVAL : errno
            )
        }
        let childIdentity = FileSystemObjectIdentity(createdInfo)
        let childDescriptor = rollbackOperations.openChild(
            parentDescriptor,
            childName
        )
        guard childDescriptor >= 0 else {
            let openingError = OwnedWorkDirectoryMarkerError.systemFailure(
                path: childURL.path,
                operation: "open owned work directory",
                code: errno
            )
            try rethrowAfterRollback(
                openingError,
                named: childName,
                parentDescriptor: parentDescriptor,
                childDescriptor: nil,
                expectedIdentity: childIdentity,
                displayedAt: childURL,
                operations: rollbackOperations
            )
        }
        defer { Darwin.close(childDescriptor) }

        var childInfo = stat()
        guard Darwin.fstat(childDescriptor, &childInfo) == 0 else {
            let inspectionError = OwnedWorkDirectoryMarkerError.systemFailure(
                path: childURL.path,
                operation: "inspect owned work directory",
                code: errno
            )
            try rethrowAfterRollback(
                inspectionError,
                named: childName,
                parentDescriptor: parentDescriptor,
                childDescriptor: childDescriptor,
                expectedIdentity: childIdentity,
                displayedAt: childURL,
                operations: rollbackOperations
            )
        }
        guard childInfo.st_mode & S_IFMT == S_IFDIR,
              FileSystemObjectIdentity(childInfo) == childIdentity else {
            try rethrowAfterRollback(
                OwnedWorkDirectoryMarkerError.unsafePath(childURL.path),
                named: childName,
                parentDescriptor: parentDescriptor,
                childDescriptor: childDescriptor,
                expectedIdentity: childIdentity,
                displayedAt: childURL,
                operations: rollbackOperations
            )
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
            try rethrowAfterRollback(
                error,
                named: childName,
                parentDescriptor: parentDescriptor,
                childDescriptor: childDescriptor,
                expectedIdentity: childIdentity,
                displayedAt: childURL,
                operations: rollbackOperations
            )
        }
    }

    /// Binds a directory created by a workflow to the same identity-safe marker
    /// contract used by `createDirectory`. The directory must be the exact child
    /// of the requested parent and the marker must not already exist.
    public static func bindExistingDirectory(
        _ directoryURL: URL,
        request: OwnedWorkDirectoryCreationRequest,
        atomicFileStore: DurableAtomicFileStore = .init(),
        rollbackOperations: RollbackOperations = .init()
    ) throws {
        try validate(request)
        let directoryURL = directoryURL.standardizedFileURL
        let parentURL = request.parentDirectoryURL.standardizedFileURL
        let projectURL = request.projectURL.standardizedFileURL
        guard directoryURL.deletingLastPathComponent() == parentURL,
              parentURL.path == projectURL.path
                || parentURL.path.hasPrefix(projectURL.path + "/") else {
            throw OwnedWorkDirectoryMarkerError.invalidRequest(
                "existing directory is not an exact child of the bound parent"
            )
        }

        let parentDescriptor: Int32
        do {
            parentDescriptor = try NoFollowFileSystem.openDirectoryHierarchy(parentURL)
        } catch {
            throw OwnedWorkDirectoryMarkerError.unsafePath(parentURL.path)
        }
        defer { Darwin.close(parentDescriptor) }
        let directoryName = directoryURL.lastPathComponent
        var expectedDirectoryInfo = stat()
        let inspectStatus = directoryName.withCString {
            Darwin.fstatat(
                parentDescriptor,
                $0,
                &expectedDirectoryInfo,
                AT_SYMLINK_NOFOLLOW
            )
        }
        guard inspectStatus == 0,
              expectedDirectoryInfo.st_mode & S_IFMT == S_IFDIR else {
            throw OwnedWorkDirectoryMarkerError.unsafePath(directoryURL.path)
        }
        let expectedDirectoryIdentity = FileSystemObjectIdentity(
            expectedDirectoryInfo
        )
        let projectDescriptor: Int32
        do {
            projectDescriptor = try NoFollowFileSystem.openDirectoryHierarchy(projectURL)
        } catch {
            try rethrowAfterRollback(
                OwnedWorkDirectoryMarkerError.unsafePath(projectURL.path),
                named: directoryName,
                parentDescriptor: parentDescriptor,
                childDescriptor: nil,
                expectedIdentity: expectedDirectoryIdentity,
                displayedAt: directoryURL,
                operations: rollbackOperations
            )
        }
        defer { Darwin.close(projectDescriptor) }
        let directoryDescriptor = rollbackOperations.openChild(
            parentDescriptor,
            directoryName
        )
        guard directoryDescriptor >= 0 else {
            let openingError = OwnedWorkDirectoryMarkerError.systemFailure(
                path: directoryURL.path,
                operation: "open owned work directory for binding",
                code: errno
            )
            try rethrowAfterRollback(
                openingError,
                named: directoryName,
                parentDescriptor: parentDescriptor,
                childDescriptor: nil,
                expectedIdentity: expectedDirectoryIdentity,
                displayedAt: directoryURL,
                operations: rollbackOperations
            )
        }
        defer { Darwin.close(directoryDescriptor) }

        var directoryInfo = stat()
        var projectInfo = stat()
        guard Darwin.fstat(directoryDescriptor, &directoryInfo) == 0,
              Darwin.fstat(projectDescriptor, &projectInfo) == 0,
              directoryInfo.st_mode & S_IFMT == S_IFDIR,
              FileSystemObjectIdentity(directoryInfo)
                == expectedDirectoryIdentity else {
            try rethrowAfterRollback(
                OwnedWorkDirectoryMarkerError.systemFailure(
                    path: directoryURL.path,
                    operation: "inspect existing owned work directory",
                    code: errno == 0 ? ESTALE : errno
                ),
                named: directoryName,
                parentDescriptor: parentDescriptor,
                childDescriptor: directoryDescriptor,
                expectedIdentity: expectedDirectoryIdentity,
                displayedAt: directoryURL,
                operations: rollbackOperations
            )
        }
        let marker = OwnedWorkDirectoryMarker(
            projectIdentity: FileSystemObjectIdentity(projectInfo),
            directoryIdentity: FileSystemObjectIdentity(directoryInfo),
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
            try atomicFileStore.create(
                encoder.encode(marker),
                named: OwnedWorkDirectoryMarker.fileName,
                inOpenDirectory: directoryDescriptor,
                displayedAt: directoryURL
            )
            guard rollbackOperations.syncParent(parentDescriptor) == 0 else {
                throw OwnedWorkDirectoryMarkerError.systemFailure(
                    path: parentURL.path,
                    operation: "fsync bound owned directory parent",
                    code: errno
                )
            }
            guard try load(from: directoryURL, expectedProjectURL: projectURL) == marker else {
                throw OwnedWorkDirectoryMarkerError.invalidMarker(
                    "published marker changed while binding existing directory"
                )
            }
        } catch {
            try rethrowAfterRollback(
                error,
                named: directoryName,
                parentDescriptor: parentDescriptor,
                childDescriptor: directoryDescriptor,
                expectedIdentity: expectedDirectoryIdentity,
                displayedAt: directoryURL,
                operations: rollbackOperations
            )
        }
    }

    /// Atomically moves a marker from active to a terminal state. Terminal
    /// markers are immutable so a later run cannot rewrite prior disposition.
    public static func transition(
        _ directoryURL: URL,
        expectedProjectURL: URL,
        expectedRunID: UUID,
        to state: OwnedWorkDirectoryMarker.State,
        atomicFileStore: DurableAtomicFileStore = .init()
    ) throws {
        guard state != .active else {
            throw OwnedWorkDirectoryMarkerError.invalidRequest(
                "marker transition must end in a terminal state"
            )
        }
        let directoryURL = directoryURL.standardizedFileURL
        let directoryDescriptor: Int32
        do {
            directoryDescriptor = try NoFollowFileSystem.openDirectoryHierarchy(directoryURL)
        } catch {
            throw OwnedWorkDirectoryMarkerError.unsafePath(directoryURL.path)
        }
        defer { Darwin.close(directoryDescriptor) }
        let current = try load(
            fromOpenDirectory: directoryDescriptor,
            displayedAt: directoryURL,
            expectedProjectURL: expectedProjectURL.standardizedFileURL
        )
        guard current.runID == expectedRunID else {
            throw OwnedWorkDirectoryMarkerError.identityMismatch(directoryURL.path)
        }
        guard current.state == .active else {
            throw OwnedWorkDirectoryMarkerError.invalidMarker(
                "terminal marker state cannot be rewritten"
            )
        }
        let updated = OwnedWorkDirectoryMarker(
            projectIdentity: current.projectIdentity,
            directoryIdentity: current.directoryIdentity,
            runID: current.runID,
            processIdentifier: current.processIdentifier,
            processStartTime: current.processStartTime,
            bootSessionID: current.bootSessionID,
            state: state,
            lockRelativePath: current.lockRelativePath,
            keepIntermediates: current.keepIntermediates,
            toolName: current.toolName,
            toolVersion: current.toolVersion
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let replacementName = ".lungfish-owned-marker-transition-\(UUID().uuidString.lowercased())"
        try atomicFileStore.create(
            encoder.encode(updated),
            named: replacementName,
            inOpenDirectory: directoryDescriptor,
            displayedAt: directoryURL
        )
        var replacementPublished = false
        defer {
            if !replacementPublished {
                _ = replacementName.withCString {
                    Darwin.unlinkat(directoryDescriptor, $0, 0)
                }
            }
        }
        let status = replacementName.withCString { replacement in
            OwnedWorkDirectoryMarker.fileName.withCString { marker in
                Darwin.renameat(
                    directoryDescriptor,
                    replacement,
                    directoryDescriptor,
                    marker
                )
            }
        }
        guard status == 0 else {
            throw OwnedWorkDirectoryMarkerError.systemFailure(
                path: directoryURL.path,
                operation: "publish terminal owned marker state",
                code: errno
            )
        }
        replacementPublished = true
        guard Darwin.fsync(directoryDescriptor) == 0 else {
            throw OwnedWorkDirectoryMarkerError.systemFailure(
                path: directoryURL.path,
                operation: "fsync terminal owned marker state",
                code: errno
            )
        }
        guard try load(
            fromOpenDirectory: directoryDescriptor,
            displayedAt: directoryURL,
            expectedProjectURL: expectedProjectURL.standardizedFileURL
        ) == updated else {
            throw OwnedWorkDirectoryMarkerError.invalidMarker(
                "terminal marker changed during transition"
            )
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

    private static func rethrowAfterRollback(
        _ initiatingError: Error,
        named childName: String,
        parentDescriptor: Int32,
        childDescriptor: Int32?,
        expectedIdentity: FileSystemObjectIdentity,
        displayedAt childURL: URL,
        operations: RollbackOperations
    ) throws -> Never {
        do {
            try rollbackNewDirectory(
                named: childName,
                parentDescriptor: parentDescriptor,
                childDescriptor: childDescriptor,
                expectedIdentity: expectedIdentity,
                displayedAt: childURL,
                operations: operations
            )
        } catch let rollbackError {
            throw OwnedWorkDirectoryMarkerError.creationAndRollbackFailed(
                path: childURL.standardizedFileURL.path,
                initiatingError: initiatingError.localizedDescription,
                rollbackError: rollbackError.localizedDescription
            )
        }
        throw initiatingError
    }

    private static func rollbackNewDirectory(
        named childName: String,
        parentDescriptor: Int32,
        childDescriptor: Int32?,
        expectedIdentity: FileSystemObjectIdentity,
        displayedAt childURL: URL,
        operations: RollbackOperations
    ) throws {
        let quarantineName =
            ".lungfish-owned-rollback-pending-\(UUID().uuidString.lowercased())"
        let quarantineURL = childURL.deletingLastPathComponent()
            .appendingPathComponent(quarantineName, isDirectory: true)
        let detachStatus = childName.withCString { source in
            quarantineName.withCString { quarantine in
                PortableExclusiveRename.renameatxNP(
                    parentDescriptor,
                    source,
                    parentDescriptor,
                    quarantine,
                    UInt32(RENAME_EXCL)
                )
            }
        }
        guard detachStatus == 0 else {
            if errno == ENOENT { return }
            throw OwnedWorkDirectoryMarkerError.rollbackQuarantineRetained(
                path: childURL.path,
                operation: "detach owned work directory into rollback quarantine",
                code: errno
            )
        }

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
            let restoreStatus = quarantineName.withCString { quarantine in
                childName.withCString { destination in
                    PortableExclusiveRename.renameatxNP(
                        parentDescriptor,
                        quarantine,
                        parentDescriptor,
                        destination,
                        UInt32(RENAME_EXCL)
                    )
                }
            }
            guard restoreStatus == 0 else {
                throw OwnedWorkDirectoryMarkerError.rollbackQuarantineRetained(
                    path: quarantineURL.path,
                    operation: "restore substituted owned rollback quarantine",
                    code: errno
                )
            }
            guard operations.syncParent(parentDescriptor) == 0 else {
                throw OwnedWorkDirectoryMarkerError.rollbackRemovalDurabilityUncertain(
                    path: childURL.path,
                    operation: "fsync restored owned rollback entry",
                    code: errno
                )
            }
            return
        }

        guard operations.syncParent(parentDescriptor) == 0 else {
            throw OwnedWorkDirectoryMarkerError.rollbackQuarantineRetained(
                path: quarantineURL.path,
                operation: "fsync owned rollback quarantine parent",
                code: errno
            )
        }
        if let childDescriptor {
            let markerStatus = operations.removeMarker(
                childDescriptor,
                OwnedWorkDirectoryMarker.fileName
            )
            if markerStatus != 0, errno != ENOENT {
                throw OwnedWorkDirectoryMarkerError.rollbackQuarantineRetained(
                    path: quarantineURL.path,
                    operation: "remove marker from owned rollback quarantine",
                    code: errno
                )
            }
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
        guard finalStatus == 0 else {
            throw OwnedWorkDirectoryMarkerError.rollbackQuarantineRetained(
                path: quarantineURL.path,
                operation: "inspect owned rollback quarantine before removal",
                code: errno
            )
        }
        guard FileSystemObjectIdentity(finalInfo) == expectedIdentity else {
            throw OwnedWorkDirectoryMarkerError.rollbackQuarantineRetained(
                path: quarantineURL.path,
                operation: "revalidate owned rollback quarantine before removal",
                code: ESTALE
            )
        }
        guard operations.removeDirectory(parentDescriptor, quarantineName) == 0 else {
            throw OwnedWorkDirectoryMarkerError.rollbackQuarantineRetained(
                path: quarantineURL.path,
                operation: "remove owned rollback quarantine",
                code: errno
            )
        }
        guard operations.syncParent(parentDescriptor) == 0 else {
            throw OwnedWorkDirectoryMarkerError.rollbackRemovalDurabilityUncertain(
                path: quarantineURL.path,
                operation: "fsync owned rollback quarantine removal",
                code: errno
            )
        }
    }
}
