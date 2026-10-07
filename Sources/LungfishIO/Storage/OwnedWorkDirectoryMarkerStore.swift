import Darwin
import Foundation
import LungfishCore

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
        // Physical paths: a project bound as `/tmp/X.lungfish` and a parent
        // spelled `/private/tmp/X.lungfish/Analyses` name the same tree. The
        // no-follow walks below still open each by its own spelling and
        // reject a parent reached through a symlink.
        guard CanonicalFilePath.isPath(parentURL, within: projectURL) else {
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
        // Physical paths, as in `createDirectory`: the spellings may differ
        // (`/tmp` against `/private/tmp`) while naming the same directories.
        guard CanonicalFilePath.path(for: directoryURL.deletingLastPathComponent())
                == CanonicalFilePath.path(for: parentURL),
              CanonicalFilePath.isPath(parentURL, within: projectURL) else {
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
                PortableRename.renameatxNP(
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
                    PortableRename.renameatxNP(
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
