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

    /// Wait without blocking a cooperative executor or deferring cancellation
    /// until another process releases its lock.
    fileprivate static func acquireCancellable(
        root: URL, waitMessageWriter: @Sendable (String) -> Void
    ) async throws -> CondaRootMutationLock {
        try Task.checkCancellation()
        let root = root.standardizedFileURL
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        guard rootIsWritable(root) else { throw CondaRootMutationLockError.readOnlyRoot }
        let path = root.appendingPathComponent(filename).path
        let fd = open(path, O_CREAT | O_RDWR | O_CLOEXEC, S_IRUSR | S_IWUSR | S_IRGRP | S_IROTH)
        guard fd >= 0 else { throw CondaRootMutationLockError.openFailed(path: path, errno: errno) }
        do {
            var reportedWait = false
            while flock(fd, LOCK_EX | LOCK_NB) != 0 {
                let code = errno
                guard code == EWOULDBLOCK || code == EAGAIN || code == EINTR else {
                    throw CondaRootMutationLockError.lockFailed(path: path, errno: code)
                }
                if !reportedWait { waitMessageWriter("Waiting for the managed tool to become available…"); reportedWait = true }
                try await Task.sleep(for: .milliseconds(100))
                try Task.checkCancellation()
            }
            try Task.checkCancellation()
            ftruncate(fd, 0)
            let pidLine = "\(getpid())\n"
            _ = pidLine.withCString { write(fd, $0, strlen($0)) }
            fsync(fd)
            return CondaRootMutationLock(fd: fd)
        } catch {
            close(fd)
            throw error
        }
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

/// A process-safe lock for one managed environment. Plugin-pack installation
/// holds this lock across the conda mutation, source-overlay publication, and
/// final readiness check, rather than only while micromamba is running.
public final class CondaEnvironmentMutationLock: @unchecked Sendable {
    private let rootLock: CondaRootMutationLock

    private init(rootLock: CondaRootMutationLock) {
        self.rootLock = rootLock
    }

    deinit {
        release()
    }

    @discardableResult
    public static func acquire(
        root: URL,
        environment: String,
        waitMessageWriter: (String) -> Void = CondaRootMutationLock.writeWaitMessageToStderr
    ) throws -> CondaEnvironmentMutationLock {
        let lockRoot = root.standardizedFileURL
            .appendingPathComponent(".environment-mutation-locks", isDirectory: true)
            .appendingPathComponent(lockDirectoryName(for: environment), isDirectory: true)
        return CondaEnvironmentMutationLock(
            rootLock: try CondaRootMutationLock.acquire(
                root: lockRoot,
                waitMessageWriter: waitMessageWriter
            )
        )
    }

    public func release() {
        rootLock.release()
    }

    /// Scientific execution holds this environment-only lease until completion.
    /// Installers use the same lock path, so repair cannot replace a live runtime.
    public static func acquireCancellable(
        root: URL,
        environment: String,
        waitMessageWriter: @escaping @Sendable (String) -> Void = CondaRootMutationLock.writeWaitMessageToStderr
    ) async throws -> CondaEnvironmentMutationLock {
        let lockRoot = root.standardizedFileURL
            .appendingPathComponent(".environment-mutation-locks", isDirectory: true)
            .appendingPathComponent(lockDirectoryName(for: environment), isDirectory: true)
        return try await CondaEnvironmentMutationLock(rootLock: .acquireCancellable(root: lockRoot, waitMessageWriter: waitMessageWriter))
    }

    private static func lockDirectoryName(for environment: String) -> String {
        let encoded = environment.utf8.map { String(format: "%02x", $0) }.joined()
        return encoded.isEmpty ? "empty" : encoded
    }
}

/// The shared mutation lease for one or more conda environments.
///
/// Every participant that can replace or alter an environment acquires these
/// locks in the same order: lexicographically sorted environment locks first,
/// then the conda-root lock. Holding the root lock first and subsequently
/// waiting for an environment lock would invert that order and can deadlock
/// against a pack install that already owns the environment lease.
public final class CondaEnvironmentMutationTransaction: @unchecked Sendable {
    public let root: URL
    public let environments: [String]

    private let environmentLocks: [CondaEnvironmentMutationLock]
    private let rootLock: CondaRootMutationLock
    private var released = false

    private init(
        root: URL,
        environments: [String],
        environmentLocks: [CondaEnvironmentMutationLock],
        rootLock: CondaRootMutationLock
    ) {
        self.root = root
        self.environments = environments
        self.environmentLocks = environmentLocks
        self.rootLock = rootLock
    }

    deinit {
        release()
    }

    /// Acquires leases in a consistent order. Waiting for another operation
    /// remains cancellable, including when a scientific run owns an environment.
    public static func acquire(
        root: URL,
        environments: [String]
    ) async throws -> CondaEnvironmentMutationTransaction {
        let resolvedRoot = root.standardizedFileURL
        let resolvedEnvironments = Array(Set(environments.filter { !$0.isEmpty })).sorted()
        var environmentLocks: [CondaEnvironmentMutationLock] = []

        do {
            for environment in resolvedEnvironments {
                try Task.checkCancellation()
                let lock = try await CondaEnvironmentMutationLock.acquireCancellable(
                    root: resolvedRoot, environment: environment)
                environmentLocks.append(lock)
                try Task.checkCancellation()
            }

            // This must remain after every per-environment lock acquisition.
            let rootLock = try await CondaRootMutationLock.acquireCancellable(
                root: resolvedRoot, waitMessageWriter: CondaRootMutationLock.writeWaitMessageToStderr)
            return CondaEnvironmentMutationTransaction(
                root: resolvedRoot,
                environments: resolvedEnvironments,
                environmentLocks: environmentLocks,
                rootLock: rootLock
            )
        } catch {
            for lock in environmentLocks.reversed() {
                lock.release()
            }
            throw error
        }
    }

    /// Returns whether this transaction may be reused by an operation on the
    /// specified root/environment without trying to reacquire its own locks.
    public func covers(root: URL, environment: String) -> Bool {
        self.root == root.standardizedFileURL && environments.contains(environment)
    }

    public func release() {
        guard !released else { return }
        released = true
        rootLock.release()
        for lock in environmentLocks.reversed() {
            lock.release()
        }
    }
}
