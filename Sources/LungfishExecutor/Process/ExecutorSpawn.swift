// ExecutorSpawn.swift - posix_spawn, descriptor hygiene and exit observation for the Linux executor
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
#if canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#elseif canImport(Darwin)
import Darwin
#endif

/// How a child ended, in the shell's terms.
enum ChildTermination: Equatable, Sendable {
    /// The child called exit with this code, kept to 8 bits as `wait(2)` and every shell report it.
    case exited(code: Int32)
    /// A signal ended the child.
    case signaled(signal: Int32)
}

/// A reaped child's end and its peak resident memory in bytes.
struct ChildExit: Equatable, Sendable {
    var termination: ChildTermination
    /// `ru_maxrss` of the child, in bytes on every platform. Linux reports KiB, so the value is multiplied by 1024 there.
    var peakResidentBytes: UInt64
}

/// The POSIX process calls of the executor's launcher (`docs/contracts/RUNNING-A-TOOL.md`, The Linux executor's launcher).
///
/// Linux has no `POSIX_SPAWN_CLOEXEC_DEFAULT` and musl lacks `posix_spawn_file_actions_addclosefrom_np`, so the
/// executor marks every inherited descriptor from 3 up close-on-exec at start and opens its own with `O_CLOEXEC`. A child
/// then holds only the three descriptors the spawn installs. macOS takes the same route, so the parity tests prove it.
enum ExecutorSpawn {
    struct Failure: Error, Equatable, Sendable {
        let reason: String
    }

    /// Signals reset to their default action in each child, those of `Sources/LungfishCore/Process/ToolProcessSpawn.swift`.
    static let defaultedSignals: [Int32] = [SIGPIPE, SIGINT, SIGTERM, SIGCHLD, SIGHUP, SIGQUIT]

    /// The folder that lists this process's open descriptors.
    static var descriptorFolder: String {
        #if os(Linux)
        return "/proc/self/fd"
        #else
        return "/dev/fd"
        #endif
    }

    /// Sets `FD_CLOEXEC` on every descriptor from 3 up that this process has open, and returns how many it marked.
    @discardableResult
    static func markInheritedDescriptorsCloseOnExec() -> Int {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: descriptorFolder)) ?? []
        var marked = 0
        for name in names {
            guard let fd = Int32(name), fd >= 3 else { continue }
            let flags = fcntl(fd, F_GETFD)
            guard flags != -1 else { continue }
            if flags & FD_CLOEXEC == 0, fcntl(fd, F_SETFD, flags | FD_CLOEXEC) == 0 {
                marked += 1
            }
        }
        return marked
    }

    /// Opens `/dev/null` for reading, close-on-exec, above the standard descriptors.
    static func openNullForReading() throws(Failure) -> Int32 {
        try openDescriptor("/dev/null", flags: O_RDONLY, mode: 0)
    }

    /// Creates or truncates `path` for writing, close-on-exec, above the standard descriptors.
    static func openForWriting(_ path: String) throws(Failure) -> Int32 {
        try openDescriptor(path, flags: O_WRONLY | O_CREAT | O_TRUNC, mode: 0o644)
    }

    /// Opens `/dev/null` for writing, close-on-exec, above the standard descriptors.
    static func openNullForWriting() throws(Failure) -> Int32 {
        try openDescriptor("/dev/null", flags: O_WRONLY, mode: 0)
    }

    /// Makes a pipe whose two ends are close-on-exec and above the standard descriptors. The caller holds the spawn lock
    /// (`StepController.spawnTrackedReadingStdout`), so no spawn of this process sees an end before its flag is set, which
    /// is what `pipe2(O_CLOEXEC)` gives on Linux, on every platform.
    /// Call it only from `StepController.spawnTrackedReadingStdout`, which holds the lock.
    static func openPipe() throws(Failure) -> (read: Int32, write: Int32) {
        var ends: [Int32] = [-1, -1]
        guard pipe(&ends) == 0 else {
            throw Failure(reason: "Could not make a pipe. \(String(cString: strerror(errno)))")
        }
        let read: Int32
        do throws(Failure) {
            read = try closeOnExecAboveStandard(ends[0])
        } catch {
            close(ends[1])
            throw error
        }
        do throws(Failure) {
            return (read, try closeOnExecAboveStandard(ends[1]))
        } catch {
            close(read)
            throw error
        }
    }

    /// Sets `FD_CLOEXEC` on `fd` and moves a standard descriptor (0, 1 or 2) to the lowest free number from 3 up. Closes
    /// `fd` when the result is another descriptor or the call failed.
    private static func closeOnExecAboveStandard(_ fd: Int32) throws(Failure) -> Int32 {
        let result = fd >= 3 ? (fcntl(fd, F_SETFD, FD_CLOEXEC) == 0 ? fd : -1) : fcntl(fd, F_DUPFD_CLOEXEC, 3)
        let saved = errno
        if result != fd {
            close(fd)
        }
        guard result >= 0 else {
            throw Failure(reason: "Could not mark a pipe end close-on-exec. \(String(cString: strerror(saved)))")
        }
        return result
    }

    private static func openDescriptor(_ path: String, flags: Int32, mode: mode_t) throws(Failure) -> Int32 {
        let fd = open(path, flags | O_CLOEXEC, mode)
        guard fd >= 0 else {
            throw Failure(reason: "Could not open \(path). \(String(cString: strerror(errno)))")
        }
        guard fd < 3 else { return fd }
        // A process started with a standard descriptor closed gets it back from open. posix_spawn's dup2 onto the same
        // number would keep the close-on-exec flag, so move it above 2.
        let moved = fcntl(fd, F_DUPFD_CLOEXEC, 3)
        let saved = errno
        close(fd)
        guard moved >= 0 else {
            throw Failure(reason: "Could not move the descriptor of \(path). \(String(cString: strerror(saved)))")
        }
        return moved
    }

    /// Starts `executable` as the leader of its own process group, with an empty signal mask, default dispositions for
    /// `defaultedSignals`, the three descriptors given as 0, 1 and 2 and exactly `environment`. No PATH lookup is made.
    /// A `workingDirectory` is set by the spawn's file actions, never by a process-wide `chdir` (SWIFT ruling N8).
    static func spawn(
        executable: String,
        arguments: [String],
        environment: [String: String],
        stdin: Int32,
        stdout: Int32,
        stderr: Int32,
        workingDirectory: String? = nil
    ) throws(Failure) -> pid_t {
        #if os(Linux)
        var attributes = posix_spawnattr_t()
        var actions = posix_spawn_file_actions_t()
        #else
        var attributes: posix_spawnattr_t?
        var actions: posix_spawn_file_actions_t?
        #endif
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        let flags = Int32(POSIX_SPAWN_SETPGROUP) | Int32(POSIX_SPAWN_SETSIGDEF) | Int32(POSIX_SPAWN_SETSIGMASK)
        posix_spawnattr_setflags(&attributes, Int16(flags))
        posix_spawnattr_setpgroup(&attributes, 0)
        var defaults = sigset_t()
        sigemptyset(&defaults)
        for signal in defaultedSignals {
            sigaddset(&defaults, signal)
        }
        posix_spawnattr_setsigdefault(&attributes, &defaults)
        var mask = sigset_t()
        sigemptyset(&mask)
        posix_spawnattr_setsigmask(&attributes, &mask)

        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_adddup2(&actions, stdin, 0)
        posix_spawn_file_actions_adddup2(&actions, stdout, 1)
        posix_spawn_file_actions_adddup2(&actions, stderr, 2)
        if let workingDirectory {
            #if os(Linux)
            // Musl gets _GNU_SOURCE from the Clang importer and glibc declares this under __USE_MISC, so the Linux
            // modules import it with no wrapper.
            let added = posix_spawn_file_actions_addchdir_np(&actions, workingDirectory)
            #else
            let added = posix_spawn_file_actions_addchdir(&actions, workingDirectory)
            #endif
            guard added == 0 else {
                throw Failure(reason: "Could not start \(executable) in its working folder. \(String(cString: strerror(added)))")
            }
        }

        let argv = ([executable] + arguments).map { strdup($0) }
        let envp = environment.keys.sorted().map { strdup("\($0)=\(environment[$0] ?? "")") }
        defer {
            argv.forEach { free($0) }
            envp.forEach { free($0) }
        }
        var pid: pid_t = 0
        let result = posix_spawn(&pid, executable, &actions, &attributes, argv + [nil], envp + [nil])
        guard result == 0 else {
            throw Failure(reason: "posix_spawn of \(executable) failed. \(String(cString: strerror(result)))")
        }
        return pid
    }

    /// Blocks until `pid` has exited, without reaping it, so its process ID and group ID stay reserved while the
    /// executor stops what the child left behind. Retried on EINTR. Returns false when the child is not waitable.
    @discardableResult
    static func waitForExitWithoutReaping(_ pid: pid_t) -> Bool {
        while true {
            var info = siginfo_t()
            if waitid(P_PID, id_t(pid), &info, WEXITED | WNOWAIT) == 0 {
                return true
            }
            if errno == EINTR {
                continue
            }
            return false
        }
    }

    /// Reaps `pid` with `wait4`, blocking until it exits, and returns how it ended with its peak resident bytes.
    static func reap(_ pid: pid_t) -> ChildExit? {
        var status: Int32 = 0
        var usage = rusage()
        while true {
            let reaped = wait4(pid, &status, 0, &usage)
            if reaped == pid {
                return ChildExit(termination: decode(status: status), peakResidentBytes: peakResidentBytes(usage))
            }
            if reaped == -1 && errno == EINTR {
                continue
            }
            return nil
        }
    }

    /// Reaps `pid` only when it has already exited (`waitpid(pid, WNOHANG)`). Never waits for any other process.
    static func reapIfExited(_ pid: pid_t) -> Bool {
        var status: Int32 = 0
        while true {
            let reaped = waitpid(pid, &status, WNOHANG)
            if reaped == pid { return true }
            if reaped == -1 && errno == EINTR { continue }
            return false
        }
    }

    /// Decodes a `wait` status without the C macros, which Swift does not import.
    static func decode(status: Int32) -> ChildTermination {
        let low = status & 0x7F
        if low == 0 {
            return .exited(code: (status >> 8) & 0xFF)
        }
        return .signaled(signal: low)
    }

    /// `ru_maxrss` in bytes. Linux reports KiB (getrusage(2)) and Darwin bytes.
    static func peakResidentBytes(_ usage: rusage) -> UInt64 {
        let value = UInt64(max(0, usage.ru_maxrss))
        #if os(Linux)
        return value * 1024
        #else
        return value
        #endif
    }
}
