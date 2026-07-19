import Darwin
import Foundation

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
