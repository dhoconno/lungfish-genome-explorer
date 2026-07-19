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
    case missingParentDirectory(String)
    case systemFailure(path: String, code: Int32)

    var errorDescription: String? {
        switch self {
        case .lockHeld(let path):
            return "Full-length ONT MHC run lock is already held: \(path)"
        case .unsafeLockFile(let path):
            return "Full-length ONT MHC run lock must be a real regular file: \(path)"
        case .missingParentDirectory(let path):
            return "Full-length ONT MHC output parent directory must exist before locking: \(path)"
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
        let parentURL = outputURL.deletingLastPathComponent()
        do {
            try FullLengthONTMHCAlignmentSafety().requireDirectoryNoFollow(
                parentURL,
                role: "full-length ONT MHC output parent directory"
            )
        } catch {
            throw FullLengthONTMHCRunLockError.missingParentDirectory(parentURL.path)
        }
        let lockURL = lockURL(for: outputURL)
        let flags = O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC
        let descriptor = Darwin.open(lockURL.path, flags, S_IRUSR | S_IWUSR)
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
