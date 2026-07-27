import Darwin
import Foundation

public enum OwnedRunLockProbe: String, Equatable, Sendable {
    case missing
    case unlocked
    case held
}

public enum OwnedRunLockError: Error, LocalizedError, Equatable, Sendable {
    case lockHeld(String)
    case unsafeLockFile(String)
    case unsafeParentDirectory(String)
    case systemFailure(path: String, code: Int32)

    public var errorDescription: String? {
        switch self {
        case .lockHeld(let path): return "Run lock is already held: \(path)"
        case .unsafeLockFile(let path): return "Run lock must be a real regular file: \(path)"
        case .unsafeParentDirectory(let path):
            return "Run lock parent contains a symbolic link or special file: \(path)"
        case .systemFailure(let path, let code):
            return "Could not access run lock at \(path) (errno \(code))."
        }
    }
}

/// Shared nonblocking advisory lock used by owned workflow runs.
public final class OwnedRunLock: @unchecked Sendable {
    public let lockURL: URL
    private let stateLock = NSLock()
    private var descriptor: Int32

    private init(lockURL: URL, descriptor: Int32) {
        self.lockURL = lockURL
        self.descriptor = descriptor
    }

    public static func acquire(at lockURL: URL) throws -> OwnedRunLock {
        let descriptor = try openLock(at: lockURL, createIfMissing: true)
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            let code = errno
            Darwin.close(descriptor)
            if code == EWOULDBLOCK || code == EAGAIN {
                throw OwnedRunLockError.lockHeld(lockURL.path)
            }
            throw OwnedRunLockError.systemFailure(path: lockURL.path, code: code)
        }
        return OwnedRunLock(lockURL: lockURL.standardizedFileURL, descriptor: descriptor)
    }

    public static func probe(at lockURL: URL) throws -> OwnedRunLockProbe {
        let descriptor: Int32
        do {
            descriptor = try openLock(at: lockURL, createIfMissing: false)
        } catch OwnedRunLockError.systemFailure(_, let code) where code == ENOENT {
            return .missing
        }
        defer { Darwin.close(descriptor) }
        if flock(descriptor, LOCK_EX | LOCK_NB) == 0 {
            _ = flock(descriptor, LOCK_UN)
            return .unlocked
        }
        if errno == EWOULDBLOCK || errno == EAGAIN {
            return .held
        }
        throw OwnedRunLockError.systemFailure(path: lockURL.path, code: errno)
    }

    public func release() {
        let value = stateLock.withLock { () -> Int32 in
            let current = descriptor
            descriptor = -1
            return current
        }
        guard value >= 0 else { return }
        _ = flock(value, LOCK_UN)
        Darwin.close(value)
    }

    /// Capability check used by lock-aware revalidation. Callers cannot forge
    /// an instance because acquisition is the only public constructor.
    public func authorizesRevalidation(of candidate: URL) -> Bool {
        stateLock.withLock {
            descriptor >= 0
                && lockURL.standardizedFileURL
                    == candidate.standardizedFileURL
        }
    }

    deinit { release() }

    private static func openLock(at lockURL: URL, createIfMissing: Bool) throws -> Int32 {
        let standardized = lockURL.standardizedFileURL
        guard DurableAtomicFileStore.isSinglePathComponent(standardized.lastPathComponent) else {
            throw OwnedRunLockError.unsafeLockFile(lockURL.path)
        }
        let parent = standardized.deletingLastPathComponent()
        let parentDescriptor: Int32
        do {
            parentDescriptor = try NoFollowFileSystem.openDirectoryHierarchy(parent)
        } catch {
            throw OwnedRunLockError.unsafeParentDirectory(parent.path)
        }
        defer { Darwin.close(parentDescriptor) }

        let flags = O_RDWR | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC
            | (createIfMissing ? O_CREAT : 0)
        let descriptor = standardized.lastPathComponent.withCString {
            Darwin.openat(parentDescriptor, $0, flags, S_IRUSR | S_IWUSR)
        }
        guard descriptor >= 0 else {
            if errno == ELOOP || errno == ENOTDIR {
                throw OwnedRunLockError.unsafeLockFile(standardized.path)
            }
            throw OwnedRunLockError.systemFailure(path: standardized.path, code: errno)
        }

        var info = stat()
        guard Darwin.fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG else {
            Darwin.close(descriptor)
            throw OwnedRunLockError.unsafeLockFile(standardized.path)
        }
        return descriptor
    }
}
