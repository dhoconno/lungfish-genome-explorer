import Darwin
import Foundation
import LungfishIO

public enum FullLengthONTMHCAlignmentDirectoryPublicationMode: String, Codable, Sendable, Equatable {
    case create
    case replace
}

public struct FullLengthONTMHCAlignmentDirectoryPublicationRecord: Sendable, Equatable {
    public let toolName: String
    public let toolVersion: String
    public let mode: FullLengthONTMHCAlignmentDirectoryPublicationMode
    public let argv: [String]
    public let sourceDirectoryURL: URL
    public let finalDirectoryURL: URL
    public let atomicMechanism: String
    public let exitStatus: Int32
    public let errorMessage: String?
    public let startedAt: Date
    public let completedAt: Date
    public let wallTime: TimeInterval

    public init(
        mode: FullLengthONTMHCAlignmentDirectoryPublicationMode,
        sourceDirectoryURL: URL,
        finalDirectoryURL: URL,
        exitStatus: Int32,
        errorMessage: String?,
        startedAt: Date,
        completedAt: Date,
        atomicMechanism: String = "renameatx_np",
        toolVersion: String = WorkflowRun.currentAppVersion
    ) {
        let sourceURL = sourceDirectoryURL.standardizedFileURL
        let destinationURL = finalDirectoryURL.standardizedFileURL
        self.toolName = "lungfish-internal publish-alignment-directory"
        self.toolVersion = toolVersion
        self.mode = mode
        self.argv = [
            "lungfish-internal", "publish-alignment-directory",
            "--mode", mode.rawValue,
            sourceURL.path,
            destinationURL.path,
        ]
        self.sourceDirectoryURL = sourceURL
        self.finalDirectoryURL = destinationURL
        self.atomicMechanism = atomicMechanism
        self.exitStatus = exitStatus
        self.errorMessage = errorMessage
        self.startedAt = startedAt
        self.completedAt = completedAt
        self.wallTime = completedAt.timeIntervalSince(startedAt)
    }
}

public struct FullLengthONTMHCAlignmentDirectoryPublicationError: Error, LocalizedError, Sendable, Equatable {
    public let record: FullLengthONTMHCAlignmentDirectoryPublicationRecord

    public init(record: FullLengthONTMHCAlignmentDirectoryPublicationRecord) {
        self.record = record
    }

    public var errorDescription: String? {
        record.errorMessage ?? "Atomic alignment directory publication failed."
    }
}

struct FullLengthONTMHCAlignmentDirectorySnapshotter {
    static let replacedArtifactNames: Set<String> = [
        "genotyping-evidence.bam",
        "genotyping-evidence.bam.bai",
    ]

    private let fileManager: FileManager

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    func snapshot(existingDirectoryURL: URL?, to stagingDirectoryURL: URL) throws {
        try fileManager.createDirectory(
            at: stagingDirectoryURL,
            withIntermediateDirectories: false
        )
        guard let existingDirectoryURL else { return }
        for entry in try fileManager.contentsOfDirectory(
            at: existingDirectoryURL,
            includingPropertiesForKeys: nil
        ) where !Self.replacedArtifactNames.contains(entry.lastPathComponent) {
            try fileManager.copyItem(
                at: entry,
                to: stagingDirectoryURL.appendingPathComponent(entry.lastPathComponent)
            )
        }
    }
}

public protocol FullLengthONTMHCAlignmentPublicationLock: AnyObject, Sendable {
    var lockURL: URL { get }
    func release()
}

public enum FullLengthONTMHCAlignmentPublicationLockError: Error, LocalizedError, Sendable, Equatable {
    case lockHeld(String)
    case unsafeLockFile(String)
    case systemFailure(path: String, code: Int32)

    public var errorDescription: String? {
        switch self {
        case .lockHeld(let path):
            return "Alignment publication lock is already held: \(path)"
        case .unsafeLockFile(let path):
            return "Alignment publication lock must be a real regular file: \(path)"
        case .systemFailure(let path, let code):
            return "Could not acquire alignment publication lock at \(path) (errno \(code))."
        }
    }
}

final class DarwinFullLengthONTMHCAlignmentPublicationLock: FullLengthONTMHCAlignmentPublicationLock, @unchecked Sendable {
    let lockURL: URL

    private let stateLock = NSLock()
    private var descriptor: Int32

    private init(lockURL: URL, descriptor: Int32) {
        self.lockURL = lockURL
        self.descriptor = descriptor
    }

    static func acquire(artifactsDirectoryURL: URL) throws -> DarwinFullLengthONTMHCAlignmentPublicationLock {
        try FullLengthONTMHCAlignmentSafety().requireDirectoryNoFollow(
            artifactsDirectoryURL,
            role: "artifacts directory for publication lock"
        )
        let lockURL = artifactsDirectoryURL.appendingPathComponent(".alignments-publication.lock")
        let flags = O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC
        let descriptor = Darwin.open(lockURL.path, flags, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else {
            if errno == ELOOP {
                throw FullLengthONTMHCAlignmentPublicationLockError.unsafeLockFile(lockURL.path)
            }
            throw FullLengthONTMHCAlignmentPublicationLockError.systemFailure(
                path: lockURL.path,
                code: errno
            )
        }

        var info = stat()
        guard Darwin.fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG else {
            Darwin.close(descriptor)
            throw FullLengthONTMHCAlignmentPublicationLockError.unsafeLockFile(lockURL.path)
        }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            let code = errno
            Darwin.close(descriptor)
            if code == EWOULDBLOCK || code == EAGAIN {
                throw FullLengthONTMHCAlignmentPublicationLockError.lockHeld(lockURL.path)
            }
            throw FullLengthONTMHCAlignmentPublicationLockError.systemFailure(
                path: lockURL.path,
                code: code
            )
        }
        return DarwinFullLengthONTMHCAlignmentPublicationLock(
            lockURL: lockURL,
            descriptor: descriptor
        )
    }

    func release() {
        let descriptorToClose = stateLock.withLock { () -> Int32 in
            let current = descriptor
            descriptor = -1
            return current
        }
        guard descriptorToClose >= 0 else { return }
        _ = flock(descriptorToClose, LOCK_UN)
        Darwin.close(descriptorToClose)
    }

    deinit {
        release()
    }
}

protocol FullLengthONTMHCRunLock: AnyObject, Sendable {
    var lockURL: URL { get }
    func release()
}

enum FullLengthONTMHCRunLockError: Error, LocalizedError, Sendable, Equatable {
    case lockHeld(String)
    case unsafeLockFile(String)
    case unsafeParentDirectory(String)
    case systemFailure(path: String, code: Int32)

    var errorDescription: String? {
        switch self {
        case .lockHeld(let path):
            return "Full-length ONT MHC run lock is already held: \(path)"
        case .unsafeLockFile(let path):
            return "Full-length ONT MHC run lock must be a real regular file: \(path)"
        case .unsafeParentDirectory(let path):
            return "Full-length ONT MHC output parent hierarchy contains a symlink or special file: \(path)"
        case .systemFailure(let path, let code):
            return "Could not acquire full-length ONT MHC run lock at \(path) (errno \(code))."
        }
    }
}

final class DarwinFullLengthONTMHCRunLock: FullLengthONTMHCRunLock, @unchecked Sendable {
    let lockURL: URL

    private let stateLock = NSLock()
    private var descriptor: Int32

    private init(lockURL: URL, descriptor: Int32) {
        self.lockURL = lockURL
        self.descriptor = descriptor
    }

    static func lockURL(for outputDirectoryURL: URL) -> URL {
        let outputURL = outputDirectoryURL.standardizedFileURL
        return outputURL.deletingLastPathComponent().appendingPathComponent(
            ".\(outputURL.lastPathComponent).full-length-ont-mhc-run.lock"
        )
    }

    static func acquire(outputDirectoryURL: URL) throws -> DarwinFullLengthONTMHCRunLock {
        let outputURL = outputDirectoryURL.standardizedFileURL
        let parentDescriptor = try prepareOutputParentHierarchy(for: outputURL)
        defer { Darwin.close(parentDescriptor) }
        let lockURL = lockURL(for: outputURL)
        let flags = O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC
        let descriptor = lockURL.lastPathComponent.withCString {
            Darwin.openat(parentDescriptor, $0, flags, S_IRUSR | S_IWUSR)
        }
        guard descriptor >= 0 else {
            if errno == ELOOP {
                throw FullLengthONTMHCRunLockError.unsafeLockFile(lockURL.path)
            }
            throw FullLengthONTMHCRunLockError.systemFailure(path: lockURL.path, code: errno)
        }

        var info = stat()
        guard Darwin.fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG else {
            Darwin.close(descriptor)
            throw FullLengthONTMHCRunLockError.unsafeLockFile(lockURL.path)
        }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            let code = errno
            Darwin.close(descriptor)
            if code == EWOULDBLOCK || code == EAGAIN {
                throw FullLengthONTMHCRunLockError.lockHeld(lockURL.path)
            }
            throw FullLengthONTMHCRunLockError.systemFailure(path: lockURL.path, code: code)
        }
        return DarwinFullLengthONTMHCRunLock(lockURL: lockURL, descriptor: descriptor)
    }

    private static func prepareOutputParentHierarchy(for outputURL: URL) throws -> Int32 {
        let requestedParentURL = outputURL.deletingLastPathComponent().standardizedFileURL
        var existingAncestorURL = requestedParentURL
        var missingComponents: [String] = []

        while true {
            var info = stat()
            if Darwin.lstat(existingAncestorURL.path, &info) == 0 {
                guard info.st_mode & S_IFMT == S_IFDIR else {
                    throw FullLengthONTMHCRunLockError.unsafeParentDirectory(existingAncestorURL.path)
                }
                break
            }
            let code = errno
            guard code == ENOENT else {
                throw FullLengthONTMHCRunLockError.systemFailure(
                    path: existingAncestorURL.path,
                    code: code
                )
            }
            let component = existingAncestorURL.lastPathComponent
            let ancestor = existingAncestorURL.deletingLastPathComponent().standardizedFileURL
            guard !component.isEmpty, ancestor.path != existingAncestorURL.path else {
                throw FullLengthONTMHCRunLockError.unsafeParentDirectory(requestedParentURL.path)
            }
            missingComponents.insert(component, at: 0)
            existingAncestorURL = ancestor
        }

        let canonicalAncestorURL = existingAncestorURL.resolvingSymlinksInPath().standardizedFileURL
        let directoryFlags = O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        var currentDescriptor = Darwin.open(canonicalAncestorURL.path, directoryFlags)
        guard currentDescriptor >= 0 else {
            let code = errno
            if code == ELOOP || code == ENOTDIR {
                throw FullLengthONTMHCRunLockError.unsafeParentDirectory(existingAncestorURL.path)
            }
            throw FullLengthONTMHCRunLockError.systemFailure(
                path: existingAncestorURL.path,
                code: code
            )
        }

        var canonicalParentURL = canonicalAncestorURL
        do {
            for component in missingComponents {
                let createStatus = component.withCString {
                    Darwin.mkdirat(
                        currentDescriptor,
                        $0,
                        S_IRWXU | S_IRGRP | S_IXGRP | S_IROTH | S_IXOTH
                    )
                }
                if createStatus != 0, errno != EEXIST {
                    throw FullLengthONTMHCRunLockError.systemFailure(
                        path: canonicalParentURL.appendingPathComponent(component).path,
                        code: errno
                    )
                }

                let nextDescriptor = component.withCString {
                    Darwin.openat(currentDescriptor, $0, directoryFlags)
                }
                guard nextDescriptor >= 0 else {
                    let code = errno
                    let unsafeURL = canonicalParentURL.appendingPathComponent(component)
                    if code == ELOOP || code == ENOTDIR {
                        throw FullLengthONTMHCRunLockError.unsafeParentDirectory(unsafeURL.path)
                    }
                    throw FullLengthONTMHCRunLockError.systemFailure(
                        path: unsafeURL.path,
                        code: code
                    )
                }
                Darwin.close(currentDescriptor)
                currentDescriptor = nextDescriptor
                canonicalParentURL.appendPathComponent(component, isDirectory: true)
            }

            let resolvedRequestedParent = requestedParentURL.resolvingSymlinksInPath().standardizedFileURL
            guard resolvedRequestedParent.path == canonicalParentURL.standardizedFileURL.path else {
                throw FullLengthONTMHCRunLockError.unsafeParentDirectory(requestedParentURL.path)
            }
            var descriptorInfo = stat()
            var pathInfo = stat()
            guard Darwin.fstat(currentDescriptor, &descriptorInfo) == 0,
                  descriptorInfo.st_mode & S_IFMT == S_IFDIR,
                  Darwin.lstat(requestedParentURL.path, &pathInfo) == 0,
                  pathInfo.st_mode & S_IFMT == S_IFDIR,
                  pathInfo.st_dev == descriptorInfo.st_dev,
                  pathInfo.st_ino == descriptorInfo.st_ino else {
                throw FullLengthONTMHCRunLockError.unsafeParentDirectory(requestedParentURL.path)
            }
            return currentDescriptor
        } catch {
            Darwin.close(currentDescriptor)
            throw error
        }
    }

    func release() {
        let descriptorToClose = stateLock.withLock { () -> Int32 in
            let current = descriptor
            descriptor = -1
            return current
        }
        guard descriptorToClose >= 0 else { return }
        _ = flock(descriptorToClose, LOCK_UN)
        Darwin.close(descriptorToClose)
    }

    deinit {
        release()
    }
}
