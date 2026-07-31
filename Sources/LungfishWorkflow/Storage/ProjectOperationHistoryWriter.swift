import Darwin
import Foundation
import LungfishIO

public enum ProjectOperationHistoryWriterError: Error, LocalizedError, Equatable {
    case unsafeProject(String)
    case unsafeHistory(String)
    case operationAlreadyExists(UUID)
    case operationDoesNotExist(UUID)
    case invalidPayloadName(String)
    case publicationDurabilityUncertain(path: String, code: Int32)
    case rollbackQuarantineRetained(path: String, operation: String, code: Int32)
    case rollbackRemovalDurabilityUncertain(path: String, operation: String, code: Int32)
    case systemFailure(path: String, operation: String, code: Int32)

    public var errorDescription: String? {
        switch self {
        case .unsafeProject(let path): return "Operation-history project is unsafe: \(path)"
        case .unsafeHistory(let path): return "Operation-history path is unsafe: \(path)"
        case .operationAlreadyExists(let id): return "Operation history already exists for \(id)."
        case .operationDoesNotExist(let id): return "Operation history does not exist for \(id)."
        case .invalidPayloadName(let name): return "Invalid operation-history payload name: \(name)"
        case .publicationDurabilityUncertain(let path, let code):
            return "Operation history was published at \(path), but its directory-entry durability is uncertain (errno \(code))."
        case .rollbackQuarantineRetained(let path, let operation, let code):
            return "Operation-history rollback retained a recoverable quarantine at \(path) after \(operation) failed (errno \(code))."
        case .rollbackRemovalDurabilityUncertain(let path, let operation, let code):
            return "Operation-history rollback removal at \(path) has uncertain durability after \(operation) failed (errno \(code))."
        case .systemFailure(let path, let operation, let code):
            return "Could not \(operation) \(path) (errno \(code))."
        }
    }
}

/// Authoritative append-only layout for compact project operation records.
public struct ProjectOperationHistoryWriter: Sendable {
    public static let historyDirectoryName = ".lungfish-operation-history"

    struct Operations: Sendable {
        var beforePublish: @Sendable (URL, URL) throws -> Void
        var publishSyncParent: @Sendable (Int32) -> Int32
        var rollbackSyncParent: @Sendable (Int32) -> Int32
        var rollbackRemovePayload: @Sendable (Int32, String) -> Int32
        var rollbackRemoveDirectory: @Sendable (Int32, String) -> Int32

        init(
            beforePublish: @escaping @Sendable (URL, URL) throws -> Void = { _, _ in },
            publishSyncParent: @escaping @Sendable (Int32) -> Int32 = {
                Darwin.fsync($0)
            },
            rollbackSyncParent: @escaping @Sendable (Int32) -> Int32 = {
                Darwin.fsync($0)
            },
            rollbackRemovePayload: @escaping @Sendable (Int32, String) -> Int32 = {
                descriptor,
                name in
                name.withCString { Darwin.unlinkat(descriptor, $0, 0) }
            },
            rollbackRemoveDirectory: @escaping @Sendable (Int32, String) -> Int32 = {
                descriptor,
                name in
                name.withCString { Darwin.unlinkat(descriptor, $0, AT_REMOVEDIR) }
            }
        ) {
            self.beforePublish = beforePublish
            self.publishSyncParent = publishSyncParent
            self.rollbackSyncParent = rollbackSyncParent
            self.rollbackRemovePayload = rollbackRemovePayload
            self.rollbackRemoveDirectory = rollbackRemoveDirectory
        }
    }

    public let projectURL: URL
    private let atomicFileStore: DurableAtomicFileStore
    private let operations: Operations

    public init(
        projectURL: URL,
        atomicFileStore: DurableAtomicFileStore = .init()
    ) {
        self.projectURL = projectURL.standardizedFileURL
        self.atomicFileStore = atomicFileStore
        self.operations = .init()
    }

    init(
        projectURL: URL,
        atomicFileStore: DurableAtomicFileStore = .init(),
        operations: Operations
    ) {
        self.projectURL = projectURL.standardizedFileURL
        self.atomicFileStore = atomicFileStore
        self.operations = operations
    }

    public func operationDirectoryURL(for operationID: UUID) -> URL {
        projectURL
            .appendingPathComponent(Self.historyDirectoryName, isDirectory: true)
            .appendingPathComponent(operationID.uuidString.lowercased(), isDirectory: true)
    }

    @discardableResult
    public func createOperation(
        operationID: UUID,
        payloads: [String: Data]
    ) throws -> URL {
        try payloads.keys.forEach(validatePayloadName)
        let descriptors = try openOrCreateHistory()
        defer {
            Darwin.close(descriptors.history)
            Darwin.close(descriptors.project)
        }

        let operationName = operationID.uuidString.lowercased()
        let stagingName = ".\(operationName).staging-\(UUID().uuidString.lowercased())"
        let mkdirStatus = stagingName.withCString {
            Darwin.mkdirat(descriptors.history, $0, S_IRWXU)
        }
        guard mkdirStatus == 0 else {
            throw ProjectOperationHistoryWriterError.systemFailure(
                path: operationDirectoryURL(for: operationID)
                    .deletingLastPathComponent()
                    .appendingPathComponent(stagingName).path,
                operation: "create operation-history staging directory",
                code: errno
            )
        }

        let operationURL = operationDirectoryURL(for: operationID)
        let stagingURL = operationURL.deletingLastPathComponent()
            .appendingPathComponent(stagingName, isDirectory: true)
        let operationDescriptor = stagingName.withCString {
            Darwin.openat(
                descriptors.history,
                $0,
                O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
            )
        }
        guard operationDescriptor >= 0 else {
            // Without an open descriptor there is no inode authority for
            // rollback. Leave the hidden staging entry recoverable.
            throw ProjectOperationHistoryWriterError.unsafeHistory(stagingURL.path)
        }
        defer { Darwin.close(operationDescriptor) }
        var stagingInfo = stat()
        guard Darwin.fstat(operationDescriptor, &stagingInfo) == 0,
              stagingInfo.st_mode & S_IFMT == S_IFDIR else {
            throw ProjectOperationHistoryWriterError.unsafeHistory(stagingURL.path)
        }
        let stagingIdentity = FileSystemObjectIdentity(from: stagingInfo)
        var publishedFinalIdentity: FileSystemObjectIdentity?
        do {
            guard Darwin.fsync(descriptors.history) == 0 else {
                throw ProjectOperationHistoryWriterError.systemFailure(
                    path: operationURL.deletingLastPathComponent().path,
                    operation: "fsync operation-history root",
                    code: errno
                )
            }
            for name in payloads.keys.sorted() {
                try atomicFileStore.create(
                    payloads[name]!,
                    named: name,
                    inOpenDirectory: operationDescriptor,
                    displayedAt: stagingURL
                )
            }
            guard Darwin.fsync(operationDescriptor) == 0 else {
                throw ProjectOperationHistoryWriterError.systemFailure(
                    path: stagingURL.path,
                    operation: "fsync operation-history staging directory",
                    code: errno
                )
            }
            try operations.beforePublish(stagingURL, operationURL)
            let renameStatus = stagingName.withCString { staging in
                operationName.withCString { final in
                    PortableExclusiveRename.renameatxNP(
                        descriptors.history,
                        staging,
                        descriptors.history,
                        final,
                        UInt32(RENAME_EXCL)
                    )
                }
            }
            guard renameStatus == 0 else {
                if errno == EEXIST {
                    throw ProjectOperationHistoryWriterError.operationAlreadyExists(operationID)
                }
                throw ProjectOperationHistoryWriterError.systemFailure(
                    path: operationURL.path,
                    operation: "publish operation-history directory exclusively",
                    code: errno
                )
            }
            // The open operation descriptor remains bound to this inode after
            // rename. From this point onward the final entry may be published;
            // a failed parent sync must preserve it and report uncertainty
            // instead of trying to roll back the now-vanished staging name.
            publishedFinalIdentity = stagingIdentity
            guard operations.publishSyncParent(descriptors.history) == 0 else {
                throw ProjectOperationHistoryWriterError.publicationDurabilityUncertain(
                    path: operationURL.path,
                    code: errno
                )
            }
            return operationURL
        } catch {
            if publishedFinalIdentity != nil {
                throw error
            }
            // Publication is all-or-nothing. Only this invocation's hidden
            // staging directory is eligible for rollback; a concurrently
            // published final directory is never touched.
            do {
                try rollbackStagingDirectory(
                    named: stagingName,
                    payloadNames: Array(payloads.keys),
                    expectedIdentity: stagingIdentity,
                    historyDescriptor: descriptors.history,
                    stagingDescriptor: operationDescriptor,
                    displayedAt: stagingURL
                )
            } catch {
                throw error
            }
            throw error
        }
    }

    @discardableResult
    public func append(
        _ data: Data,
        named payloadName: String,
        toOperation operationID: UUID
    ) throws -> URL {
        try validatePayloadName(payloadName)
        let descriptors = try openOrCreateHistory()
        defer {
            Darwin.close(descriptors.history)
            Darwin.close(descriptors.project)
        }
        let operationName = operationID.uuidString.lowercased()
        let operationDescriptor = operationName.withCString {
            Darwin.openat(
                descriptors.history,
                $0,
                O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
            )
        }
        guard operationDescriptor >= 0 else {
            if errno == ENOENT {
                throw ProjectOperationHistoryWriterError.operationDoesNotExist(operationID)
            }
            throw ProjectOperationHistoryWriterError.unsafeHistory(
                operationDirectoryURL(for: operationID).path
            )
        }
        defer { Darwin.close(operationDescriptor) }
        return try atomicFileStore.create(
            data,
            named: payloadName,
            inOpenDirectory: operationDescriptor,
            displayedAt: operationDirectoryURL(for: operationID)
        )
    }

    private func openOrCreateHistory() throws -> (project: Int32, history: Int32) {
        let projectDescriptor: Int32
        do {
            projectDescriptor = try NoFollowFileSystem.openDirectoryHierarchy(projectURL)
        } catch {
            throw ProjectOperationHistoryWriterError.unsafeProject(projectURL.path)
        }

        let historyName = Self.historyDirectoryName
        let mkdirStatus = historyName.withCString {
            Darwin.mkdirat(
                projectDescriptor,
                $0,
                S_IRWXU | S_IRGRP | S_IXGRP | S_IROTH | S_IXOTH
            )
        }
        if mkdirStatus != 0, errno != EEXIST {
            let code = errno
            Darwin.close(projectDescriptor)
            throw ProjectOperationHistoryWriterError.systemFailure(
                path: projectURL.appendingPathComponent(historyName).path,
                operation: "create operation-history root",
                code: code
            )
        }
        let historyDescriptor = historyName.withCString {
            Darwin.openat(
                projectDescriptor,
                $0,
                O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
            )
        }
        guard historyDescriptor >= 0 else {
            Darwin.close(projectDescriptor)
            throw ProjectOperationHistoryWriterError.unsafeHistory(
                projectURL.appendingPathComponent(historyName).path
            )
        }
        var info = stat()
        guard Darwin.fstat(historyDescriptor, &info) == 0,
              info.st_mode & S_IFMT == S_IFDIR else {
            Darwin.close(historyDescriptor)
            Darwin.close(projectDescriptor)
            throw ProjectOperationHistoryWriterError.unsafeHistory(
                projectURL.appendingPathComponent(historyName).path
            )
        }
        guard Darwin.fsync(projectDescriptor) == 0 else {
            let code = errno
            Darwin.close(historyDescriptor)
            Darwin.close(projectDescriptor)
            throw ProjectOperationHistoryWriterError.systemFailure(
                path: projectURL.path,
                operation: "fsync project operation-history entry",
                code: code
            )
        }
        return (projectDescriptor, historyDescriptor)
    }

    private func validatePayloadName(_ name: String) throws {
        guard !name.isEmpty,
              name != ".",
              name != "..",
              !name.contains("/"),
              !name.utf8.contains(0) else {
            throw ProjectOperationHistoryWriterError.invalidPayloadName(name)
        }
    }

    private func rollbackStagingDirectory(
        named stagingName: String,
        payloadNames: [String],
        expectedIdentity: FileSystemObjectIdentity,
        historyDescriptor: Int32,
        stagingDescriptor: Int32,
        displayedAt stagingURL: URL
    ) throws {
        let quarantineName =
            ".lungfish-history-rollback-pending-\(UUID().uuidString.lowercased())"
        let quarantineURL = stagingURL.deletingLastPathComponent()
            .appendingPathComponent(quarantineName, isDirectory: true)
        let detachStatus = stagingName.withCString { staging in
            quarantineName.withCString { quarantine in
                PortableExclusiveRename.renameatxNP(
                    historyDescriptor,
                    staging,
                    historyDescriptor,
                    quarantine,
                    UInt32(RENAME_EXCL)
                )
            }
        }
        guard detachStatus == 0 else {
            if errno == ENOENT { return }
            throw ProjectOperationHistoryWriterError.rollbackQuarantineRetained(
                path: stagingURL.path,
                operation: "detach operation-history staging rollback quarantine",
                code: errno
            )
        }

        var quarantineInfo = stat()
        let inspectStatus = quarantineName.withCString {
            Darwin.fstatat(
                historyDescriptor,
                $0,
                &quarantineInfo,
                AT_SYMLINK_NOFOLLOW
            )
        }
        guard inspectStatus == 0,
              FileSystemObjectIdentity(from: quarantineInfo) == expectedIdentity else {
            let restoreStatus = quarantineName.withCString { quarantine in
                stagingName.withCString { staging in
                    PortableExclusiveRename.renameatxNP(
                        historyDescriptor,
                        quarantine,
                        historyDescriptor,
                        staging,
                        UInt32(RENAME_EXCL)
                    )
                }
            }
            guard restoreStatus == 0 else {
                throw ProjectOperationHistoryWriterError.rollbackQuarantineRetained(
                    path: quarantineURL.path,
                    operation: "restore substituted history rollback quarantine",
                    code: errno
                )
            }
            guard operations.rollbackSyncParent(historyDescriptor) == 0 else {
                throw ProjectOperationHistoryWriterError.rollbackRemovalDurabilityUncertain(
                    path: stagingURL.path,
                    operation: "fsync restored history rollback entry",
                    code: errno
                )
            }
            return
        }

        guard operations.rollbackSyncParent(historyDescriptor) == 0 else {
            throw ProjectOperationHistoryWriterError.rollbackQuarantineRetained(
                path: quarantineURL.path,
                operation: "fsync history rollback quarantine parent",
                code: errno
            )
        }
        for name in payloadNames {
            let status = operations.rollbackRemovePayload(stagingDescriptor, name)
            if status != 0, errno != ENOENT {
                throw ProjectOperationHistoryWriterError.rollbackQuarantineRetained(
                    path: quarantineURL.path,
                    operation: "remove payload from history rollback quarantine",
                    code: errno
                )
            }
        }
        var finalInfo = stat()
        let finalStatus = quarantineName.withCString {
            Darwin.fstatat(
                historyDescriptor,
                $0,
                &finalInfo,
                AT_SYMLINK_NOFOLLOW
            )
        }
        guard finalStatus == 0 else {
            throw ProjectOperationHistoryWriterError.rollbackQuarantineRetained(
                path: quarantineURL.path,
                operation: "inspect history rollback quarantine before removal",
                code: errno
            )
        }
        guard FileSystemObjectIdentity(from: finalInfo) == expectedIdentity else {
            throw ProjectOperationHistoryWriterError.rollbackQuarantineRetained(
                path: quarantineURL.path,
                operation: "revalidate history rollback quarantine before removal",
                code: ESTALE
            )
        }
        guard operations.rollbackRemoveDirectory(
            historyDescriptor,
            quarantineName
        ) == 0 else {
            throw ProjectOperationHistoryWriterError.rollbackQuarantineRetained(
                path: quarantineURL.path,
                operation: "remove history rollback quarantine",
                code: errno
            )
        }
        guard operations.rollbackSyncParent(historyDescriptor) == 0 else {
            throw ProjectOperationHistoryWriterError.rollbackRemovalDurabilityUncertain(
                path: quarantineURL.path,
                operation: "fsync history rollback quarantine removal",
                code: errno
            )
        }
    }
}
