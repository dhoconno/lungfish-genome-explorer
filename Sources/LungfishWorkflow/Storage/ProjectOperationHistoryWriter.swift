import Darwin
import Foundation
import LungfishIO

public enum ProjectOperationHistoryWriterError: Error, LocalizedError, Equatable {
    case unsafeProject(String)
    case unsafeHistory(String)
    case operationAlreadyExists(UUID)
    case operationDoesNotExist(UUID)
    case invalidPayloadName(String)
    case systemFailure(path: String, operation: String, code: Int32)

    public var errorDescription: String? {
        switch self {
        case .unsafeProject(let path): return "Operation-history project is unsafe: \(path)"
        case .unsafeHistory(let path): return "Operation-history path is unsafe: \(path)"
        case .operationAlreadyExists(let id): return "Operation history already exists for \(id)."
        case .operationDoesNotExist(let id): return "Operation history does not exist for \(id)."
        case .invalidPayloadName(let name): return "Invalid operation-history payload name: \(name)"
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

        init(
            beforePublish: @escaping @Sendable (URL, URL) throws -> Void = { _, _ in }
        ) {
            self.beforePublish = beforePublish
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
                    Darwin.renameatx_np(
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
            guard Darwin.fsync(descriptors.history) == 0 else {
                throw ProjectOperationHistoryWriterError.systemFailure(
                    path: operationURL.deletingLastPathComponent().path,
                    operation: "fsync published operation-history directory",
                    code: errno
                )
            }
            return operationURL
        } catch {
            // Publication is all-or-nothing. Only this invocation's hidden
            // staging directory is eligible for rollback; a concurrently
            // published final directory is never touched.
            rollbackStagingDirectory(
                named: stagingName,
                payloadNames: Array(payloads.keys),
                expectedIdentity: stagingIdentity,
                historyDescriptor: descriptors.history,
                stagingDescriptor: operationDescriptor
            )
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
        stagingDescriptor: Int32
    ) {
        let quarantineName =
            ".lungfish-history-rollback-pending-\(UUID().uuidString.lowercased())"
        let detachStatus = stagingName.withCString { staging in
            quarantineName.withCString { quarantine in
                Darwin.renameatx_np(
                    historyDescriptor,
                    staging,
                    historyDescriptor,
                    quarantine,
                    UInt32(RENAME_EXCL)
                )
            }
        }
        guard detachStatus == 0 else { return }

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
            _ = quarantineName.withCString { quarantine in
                stagingName.withCString { staging in
                    Darwin.renameatx_np(
                        historyDescriptor,
                        quarantine,
                        historyDescriptor,
                        staging,
                        UInt32(RENAME_EXCL)
                    )
                }
            }
            _ = Darwin.fsync(historyDescriptor)
            return
        }

        for name in payloadNames {
            _ = name.withCString { Darwin.unlinkat(stagingDescriptor, $0, 0) }
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
        guard finalStatus == 0,
              FileSystemObjectIdentity(from: finalInfo) == expectedIdentity else {
            return
        }
        _ = quarantineName.withCString {
            Darwin.unlinkat(historyDescriptor, $0, AT_REMOVEDIR)
        }
        _ = Darwin.fsync(historyDescriptor)
    }
}
