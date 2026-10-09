// ToolProcessSpawn.swift - posix_spawn, exit observation and process groups for ToolProcess
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import Darwin

/// The low-level process calls behind ToolProcess.
///
/// Every stage is spawned with posix_spawn as the leader of its own process
/// group, with only descriptors 0, 1 and 2 open (POSIX_SPAWN_CLOEXEC_DEFAULT),
/// default dispositions for the signals an app tends to ignore (SIGPIPE
/// above all, so `yes | head` ends as a shell would) and an empty signal mask.
/// Exit is observed with `waitid(WNOWAIT)`, which leaves the stage a zombie
/// until the run is over. While it is a zombie its process ID, and so its
/// process group ID, cannot be reused, which makes every later `killpg` and
/// tree walk reach only this run's processes. The run reaps it last.
enum ToolProcessSpawner {
    struct Failure: Error {
        let reason: String
    }

    /// Signals reset to their default action in the child.
    private static let defaultedSignals: [Int32] = [SIGPIPE, SIGINT, SIGTERM, SIGCHLD, SIGHUP, SIGQUIT]

    static func spawn(
        executable: URL,
        arguments: [String],
        environment: [String: String],
        workingDirectory: URL?,
        stdin: Int32,
        stdout: Int32,
        stderr: Int32
    ) throws(Failure) -> pid_t {
        let path = executable.path
        if let workingDirectory {
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: workingDirectory.path, isDirectory: &isDirectory),
                  isDirectory.boolValue else {
                throw Failure(reason: "The working directory \(workingDirectory.path) does not exist.")
            }
        }

        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        let flags = POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_CLOEXEC_DEFAULT
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

        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_adddup2(&actions, stdin, 0)
        posix_spawn_file_actions_adddup2(&actions, stdout, 1)
        posix_spawn_file_actions_adddup2(&actions, stderr, 2)
        if let workingDirectory {
            posix_spawn_file_actions_addchdir(&actions, workingDirectory.path)
        }

        let argv = cStrings([path] + arguments)
        let envp = cStrings(environment.map { "\($0.key)=\($0.value)" })
        defer {
            argv.forEach { free($0) }
            envp.forEach { free($0) }
        }

        var pid: pid_t = 0
        let result = posix_spawn(&pid, path, &actions, &attributes, argv + [nil], envp + [nil])
        guard result == 0 else {
            throw Failure(reason: "posix_spawn of \(path) failed. \(String(cString: strerror(result)))")
        }
        return pid
    }

    private static func cStrings(_ values: [String]) -> [UnsafeMutablePointer<CChar>?] {
        values.map { strdup($0) }
    }

    enum ExitPoll {
        case running
        case exited(ToolProcessTermination)
        /// The child was reaped elsewhere, for example because the app set
        /// SIGCHLD to SIG_IGN, so its status is unknown.
        case lost
    }

    /// Reports whether `pid` has exited without reaping it.
    static func peekExit(_ pid: pid_t) -> ExitPoll {
        while true {
            var info = siginfo_t()
            if waitid(P_PID, id_t(pid), &info, WEXITED | WNOHANG | WNOWAIT) == 0 {
                guard info.si_pid == pid else { return .running }
                switch info.si_code {
                case CLD_EXITED:
                    return .exited(.exited(code: info.si_status))
                case CLD_KILLED, CLD_DUMPED:
                    return .exited(.signaled(signal: info.si_status))
                default:
                    return .running
                }
            }
            if errno == EINTR {
                continue
            }
            return .lost
        }
    }

    /// Reaps `pid`, which must be a zombie this run spawned.
    static func reap(_ pid: pid_t) {
        var status: Int32 = 0
        while waitpid(pid, &status, WNOHANG) == -1 && errno == EINTR {}
    }

    /// Members of process group `pgid` other than its leader that are still
    /// running, which after the leader exits means orphaned descendants.
    static func liveGroupMembers(_ pgid: pid_t) -> [pid_t] {
        var capacity = 64
        while true {
            var pids = [pid_t](repeating: 0, count: capacity)
            let bytes = pids.withUnsafeMutableBytes { raw in
                proc_listpids(UInt32(PROC_PGRP_ONLY), UInt32(pgid), raw.baseAddress, Int32(raw.count))
            }
            guard bytes > 0 else { return [] }
            let count = Int(bytes) / MemoryLayout<pid_t>.size
            if count >= capacity {
                capacity *= 2
                continue
            }
            return pids.prefix(count).filter { $0 > 0 && $0 != pgid && isRunning($0) }
        }
    }

    private static func isRunning(_ pid: pid_t) -> Bool {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, pointer, size)
        }
        return result == size && info.pbi_status != UInt32(SZOMB)
    }
}
