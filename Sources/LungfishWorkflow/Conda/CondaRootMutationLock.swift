@preconcurrency import Foundation
import Darwin

public enum CondaRootMutationLockError: Error, LocalizedError, Sendable {
    case readOnlyRoot
    case openFailed(path: String, errno: Int32)
    case lockFailed(path: String, errno: Int32)

    public var errorDescription: String? {
        switch self {
        case .readOnlyRoot:
            return "conda root is read-only; reinstall as the admin user"
        case .openFailed(let path, let code):
            return "Could not open conda install lock at \(path): \(String(cString: strerror(code)))"
        case .lockFailed(let path, let code):
            return "Could not lock conda root at \(path): \(String(cString: strerror(code)))"
        }
    }
}

public final class CondaRootMutationLock: @unchecked Sendable {
    public static let filename = ".install.lock"

    private let fd: Int32
    private var released = false

    private init(fd: Int32) {
        self.fd = fd
    }

    deinit {
        release()
    }

    @discardableResult
    public static func withExclusiveLock<T>(
        root: URL,
        waitMessageWriter: (String) -> Void = CondaRootMutationLock.writeWaitMessageToStderr,
        _ operation: () throws -> T
    ) throws -> T {
        let lock = try acquire(root: root, waitMessageWriter: waitMessageWriter)
        defer { lock.release() }
        return try operation()
    }

    public static func withExclusiveLock(
        root: URL,
        waitMessageWriter: (String) -> Void = CondaRootMutationLock.writeWaitMessageToStderr
    ) throws {
        let lock = try acquire(root: root, waitMessageWriter: waitMessageWriter)
        lock.release()
    }

    @discardableResult
    public static func withExclusiveLock<T>(
        root: URL,
        waitMessageWriter: (String) -> Void = CondaRootMutationLock.writeWaitMessageToStderr,
        _ operation: () async throws -> T
    ) async throws -> T {
        let lock = try acquire(root: root, waitMessageWriter: waitMessageWriter)
        defer { lock.release() }
        return try await operation()
    }

    @discardableResult
    public static func acquire(
        root: URL,
        waitMessageWriter: (String) -> Void = CondaRootMutationLock.writeWaitMessageToStderr
    ) throws -> CondaRootMutationLock {
        let resolvedRoot = root.standardizedFileURL
        let fm = FileManager.default
        if !fm.fileExists(atPath: resolvedRoot.path) {
            try fm.createDirectory(at: resolvedRoot, withIntermediateDirectories: true)
        }

        guard rootIsWritable(resolvedRoot) else {
            throw CondaRootMutationLockError.readOnlyRoot
        }

        let lockURL = resolvedRoot.appendingPathComponent(filename)
        let lockPath = lockURL.path
        let fd = open(lockPath, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR | S_IRGRP | S_IROTH)
        guard fd >= 0 else {
            let code = errno
            if code == EACCES || code == EPERM || code == EROFS {
                throw CondaRootMutationLockError.readOnlyRoot
            }
            throw CondaRootMutationLockError.openFailed(path: lockPath, errno: code)
        }

        if flock(fd, LOCK_EX | LOCK_NB) != 0 {
            let code = errno
            if code == EWOULDBLOCK || code == EAGAIN {
                let pid = readLockHolderPIDWithRetry(from: lockURL)
                waitMessageWriter("waiting for conda lock held by pid \(pid)")
                if flock(fd, LOCK_EX) != 0 {
                    let blockingCode = errno
                    close(fd)
                    throw CondaRootMutationLockError.lockFailed(path: lockPath, errno: blockingCode)
                }
            } else {
                close(fd)
                throw CondaRootMutationLockError.lockFailed(path: lockPath, errno: code)
            }
        }

        ftruncate(fd, 0)
        let pidLine = "\(getpid())\n"
        _ = pidLine.withCString { write(fd, $0, strlen($0)) }
        fsync(fd)
        return CondaRootMutationLock(fd: fd)
    }

    public func release() {
        guard !released else { return }
        released = true
        ftruncate(fd, 0)
        _ = flock(fd, LOCK_UN)
        close(fd)
    }

    private static func rootIsWritable(_ root: URL) -> Bool {
        access(root.path, W_OK) == 0
    }

    private static func readLockHolderPIDWithRetry(from url: URL) -> Int32 {
        for _ in 0..<50 {
            if let pid = readLockHolderPID(from: url), pid > 0 {
                return pid
            }
            usleep(20_000)
        }
        return 0
    }

    private static func readLockHolderPID(from url: URL) -> Int32? {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            return nil
        }
        return Int32(text.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    public static func writeWaitMessageToStderr(_ message: String) {
        FileHandle.standardError.write(Data((message + "\n").utf8))
    }
}
