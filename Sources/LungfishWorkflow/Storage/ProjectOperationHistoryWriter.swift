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

    public let projectURL: URL
    private let atomicFileStore: DurableAtomicFileStore

    public init(
        projectURL: URL,
        atomicFileStore: DurableAtomicFileStore = .init()
    ) {
        self.projectURL = projectURL.standardizedFileURL
        self.atomicFileStore = atomicFileStore
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
        let mkdirStatus = operationName.withCString {
            Darwin.mkdirat(descriptors.history, $0, S_IRWXU)
        }
        guard mkdirStatus == 0 else {
            if errno == EEXIST {
                throw ProjectOperationHistoryWriterError.operationAlreadyExists(operationID)
            }
            throw ProjectOperationHistoryWriterError.systemFailure(
                path: operationDirectoryURL(for: operationID).path,
                operation: "create operation-history directory",
                code: errno
            )
        }

        let operationURL = operationDirectoryURL(for: operationID)
        let operationDescriptor = operationName.withCString {
            Darwin.openat(
                descriptors.history,
                $0,
                O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
            )
        }
        guard operationDescriptor >= 0 else {
            _ = operationName.withCString {
                Darwin.unlinkat(descriptors.history, $0, AT_REMOVEDIR)
            }
            throw ProjectOperationHistoryWriterError.unsafeHistory(operationURL.path)
        }
        defer { Darwin.close(operationDescriptor) }
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
                    displayedAt: operationURL
                )
            }
            return operationURL
        } catch {
            for name in payloads.keys {
                _ = name.withCString { Darwin.unlinkat(operationDescriptor, $0, 0) }
            }
            _ = operationName.withCString {
                Darwin.unlinkat(descriptors.history, $0, AT_REMOVEDIR)
            }
            _ = Darwin.fsync(descriptors.history)
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
        guard !name.isEmpty, name != ".", name != "..", !name.contains("/") else {
            throw ProjectOperationHistoryWriterError.invalidPayloadName(name)
        }
    }
}
