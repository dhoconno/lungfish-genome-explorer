// StepController.swift - Runs one tool to its end: the wait thread, the cancel path, the grace and the sweep
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Dispatch
import Foundation
import LungfishPortable
import Synchronization
#if canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#elseif canImport(Darwin)
import Darwin
#endif

/// One tool to run, as the plan's step gives it.
struct StepSpec: Sendable {
    var executable: String
    var arguments: [String]
    /// The whole environment. Nothing is inherited.
    var environment: [String: String]
    var stdoutPath: String
    var stderrPath: String
    /// Files hashed after the sweep when the step succeeds.
    var outputs: [String]
    var graceSeconds: Double
    var deadlineSeconds: Double?
    /// How often the run reaps adopted orphans that have exited while the tool runs.
    var sweepIntervalSeconds: Double
    /// The child's working folder, set in the spawn. Nil keeps the executor's.
    var workingDirectory: String? = nil
    /// Descriptors the caller opened for stdout and stderr and keeps open, used in place of the two paths. The controller
    /// never closes them (RUNNING-A-TOOL.md, Output into a descriptor you own).
    var ownedStdout: Int32? = nil
    var ownedStderr: Int32? = nil
}

/// How one step ended.
struct StepResult: Sendable {
    enum Outcome: String, Sendable {
        case succeeded, failed, interrupted
    }

    var outcome: Outcome = .failed
    var reason: String?
    var signal: Int32?
    var toolPID: pid_t?
    var exit: ChildExit?
    var escalatedToSIGKILL = false
    var stoppedProcesses: [pid_t] = []
    var adoptedOrphansReaped = 0
    var outputs: [StepRecord.Output] = []
    var wallSeconds: Double = 0
}

/// The launcher's state for one run: the tracked children and the cancel path.
///
/// One lock is held across `posix_spawn` and the insert into the tracked set, and the sweep takes the same lock, so a
/// child is never mistaken for an adopted orphan (SWIFT ruling N4). An adopted orphan is a process whose parent is the
/// executor and whose PID is not tracked, and it is reaped by its own PID with `waitpid(pid, WNOHANG)`. The executor
/// never calls `waitpid(-1)` or `wait()`, never sets SIGCHLD to `SIG_IGN`, never reads `cgroup.procs` and never signals
/// a PID it did not find under its own PID or in the group of a child it started. Each tracked child has one dedicated
/// thread that blocks in `waitid(WNOWAIT)`, so no cooperative thread blocks and the child stays a zombie, holding its PID
/// and group ID, until the sweep is over and `wait4` reaps it with its exit status and peak resident memory.
final class StepController: Sendable {
    private struct State {
        var tracked: Set<pid_t> = []
        var exited: Set<pid_t> = []
        var interruptSignal: Int32?
        var adoptedReaped = 0
    }

    private let state = Mutex(State())
    private let wake = DispatchSemaphore(value: 0)
    let executorPID: pid_t = getpid()

    /// The first termination signal received, if any.
    var interruptSignal: Int32? { state.withLock { $0.interruptSignal } }

    /// Records the first termination signal and wakes the run. Safe from any thread.
    func interrupt(_ signal: Int32) {
        state.withLock { if $0.interruptSignal == nil { $0.interruptSignal = signal } }
        wake.signal()
    }

    /// Spawns a child and adds it to the tracked set under the one lock.
    func spawnTracked(
        executable: String,
        arguments: [String],
        environment: [String: String],
        stdin: Int32,
        stdout: Int32,
        stderr: Int32,
        workingDirectory: String? = nil
    ) throws(ExecutorSpawn.Failure) -> pid_t {
        try state.withLock { (current: inout State) throws(ExecutorSpawn.Failure) -> pid_t in
            let pid = try ExecutorSpawn.spawn(
                executable: executable, arguments: arguments, environment: environment,
                stdin: stdin, stdout: stdout, stderr: stderr, workingDirectory: workingDirectory
            )
            current.tracked.insert(pid)
            return pid
        }
    }

    /// Spawns a child whose stdout is the write end of a new pipe and adds it to the tracked set, all under the one lock,
    /// and returns its PID with the read end. The write end is closed once the child holds it, so the reader sees the end
    /// of the stream when the child and whatever inherited the pipe have closed it.
    func spawnTrackedReadingStdout(
        executable: String,
        arguments: [String],
        environment: [String: String],
        stdin: Int32,
        stderr: Int32
    ) throws(ExecutorSpawn.Failure) -> (pid: pid_t, stdout: Int32) {
        try state.withLock { (current: inout State) throws(ExecutorSpawn.Failure) -> (pid: pid_t, stdout: Int32) in
            let pipe = try ExecutorSpawn.openPipe()
            defer { close(pipe.write) }
            do throws(ExecutorSpawn.Failure) {
                let pid = try ExecutorSpawn.spawn(
                    executable: executable, arguments: arguments, environment: environment,
                    stdin: stdin, stdout: pipe.write, stderr: stderr
                )
                current.tracked.insert(pid)
                return (pid, pipe.read)
            } catch {
                close(pipe.read)
                throw error
            }
        }
    }

    /// Starts the dedicated thread that marks `pid` exited, without reaping it, and then calls `exited`.
    func watchExit(of pid: pid_t, then exited: @escaping @Sendable () -> Void = {}) {
        let thread = Thread { [self] in
            ExecutorSpawn.waitForExitWithoutReaping(pid)
            state.withLock { _ = $0.exited.insert(pid) }
            wake.signal()
            exited()
        }
        thread.name = "lungfish-executor wait \(pid)"
        thread.start()
    }

    /// Reaps a tracked child whose exit the watch thread saw and drops it from the tracked set.
    func reapTracked(_ pid: pid_t) -> ChildExit? {
        let exit = ExecutorSpawn.reap(pid)
        state.withLock {
            $0.tracked.remove(pid)
            $0.exited.remove(pid)
        }
        return exit
    }

    /// Reaps every adopted orphan that has exited. Holds the spawn lock so a new child is never taken for one.
    @discardableResult
    func reapAdoptedOrphans() -> Int {
        state.withLock { current in
            var count = 0
            for entry in ProcessTable.snapshot()
            where entry.parent == executorPID && !current.tracked.contains(entry.pid) && !entry.isLive {
                if ExecutorSpawn.reapIfExited(entry.pid) {
                    count += 1
                }
            }
            current.adoptedReaped += count
            return count
        }
    }

    /// The live processes under the executor's PID and in the groups of its tracked children.
    func liveCandidates() -> [ProcessEntry] {
        let groups = state.withLock { $0.tracked }
        return ProcessTable.liveDescendants(of: executorPID, groups: groups, in: ProcessTable.snapshot())
    }

    /// Sends SIGTERM to every tracked group and every live candidate, waits up to `grace` for them to end while it
    /// reaps adopted orphans, then sends SIGKILL to whatever is left. Returns once nothing is left or SIGKILL had 10 s.
    func stopTree(grace: Double, into result: inout StepResult) {
        let tracked = state.withLock { $0.tracked }
        var signaled: Set<pid_t> = []
        func send(_ signal: Int32) {
            // The table is read before anything is signalled. A process killed first would re-parent its children, and
            // without a subreaper (macOS) a detached child would then fall out of the walk before it is signalled.
            let candidates = liveCandidates()
            for entry in candidates {
                _ = kill(entry.pid, signal)
                signaled.insert(entry.pid)
            }
            for group in tracked {
                _ = killpg(group, signal)
            }
        }
        func waitUntilGone(seconds: Double, signal: Int32) -> Bool {
            let end = ContinuousClock.now + .milliseconds(Int64(seconds * 1000))
            while true {
                reapAdoptedOrphans()
                let live = liveCandidates()
                let leadersExited = state.withLock { $0.tracked.isSubset(of: $0.exited) }
                if live.isEmpty && leadersExited {
                    return true
                }
                for entry in live where !signaled.contains(entry.pid) {
                    _ = kill(entry.pid, signal)
                    signaled.insert(entry.pid)
                }
                if ContinuousClock.now >= end {
                    return false
                }
                _ = wake.wait(timeout: .now() + .milliseconds(50))
            }
        }
        send(SIGTERM)
        if !waitUntilGone(seconds: grace, signal: SIGTERM) {
            result.escalatedToSIGKILL = true
            send(SIGKILL)
            _ = waitUntilGone(seconds: 10, signal: SIGKILL)
        }
        result.stoppedProcesses = signaled.subtracting(tracked).sorted()
    }

    /// Runs one step to its end and reports how it ended. The sweep runs before any output is counted or hashed.
    func run(_ spec: StepSpec) -> StepResult {
        let started = ContinuousClock.now
        var result = runToEnd(spec, started: started)
        result.wallSeconds = Self.seconds(since: started)
        return result
    }

    private func runToEnd(_ spec: StepSpec, started: ContinuousClock.Instant) -> StepResult {
        var result = StepResult()
        var descriptors: [Int32] = []
        defer { descriptors.forEach { close($0) } }
        let pid: pid_t
        do throws(ExecutorSpawn.Failure) {
            descriptors.append(try ExecutorSpawn.openNullForReading())
            var stdout = spec.ownedStdout ?? -1
            if spec.ownedStdout == nil {
                stdout = try ExecutorSpawn.openForWriting(spec.stdoutPath)
                descriptors.append(stdout)
            }
            var stderr = spec.ownedStderr ?? -1
            if spec.ownedStderr == nil {
                stderr = try ExecutorSpawn.openForWriting(spec.stderrPath)
                descriptors.append(stderr)
            }
            pid = try spawnTracked(
                executable: spec.executable, arguments: spec.arguments, environment: spec.environment,
                stdin: descriptors[0], stdout: stdout, stderr: stderr, workingDirectory: spec.workingDirectory
            )
        } catch {
            result.reason = error.reason
            return result
        }
        descriptors.forEach { close($0) }
        descriptors.removeAll()
        result.toolPID = pid
        watchExit(of: pid)

        enum Cause {
            case exited, interrupted(Int32), deadline
        }
        let deadline = spec.deadlineSeconds.map { started + .milliseconds(Int64($0 * 1000)) }
        var cause = Cause.exited
        while true {
            let (signal, done) = state.withLock { ($0.interruptSignal, $0.exited.contains(pid)) }
            if let signal {
                cause = .interrupted(signal)
                break
            }
            if done {
                break
            }
            if let deadline, ContinuousClock.now >= deadline {
                cause = .deadline
                break
            }
            _ = wake.wait(timeout: .now() + .milliseconds(Int(spec.sweepIntervalSeconds * 1000)))
            reapAdoptedOrphans()
        }

        var lingering = false
        switch cause {
        case .interrupted(let signal):
            stopTree(grace: spec.graceSeconds, into: &result)
            result.outcome = .interrupted
            result.signal = signal
            result.reason = "The executor received \(ExecutorSignals.name(signal)) and stopped the step."
        case .deadline:
            stopTree(grace: spec.graceSeconds, into: &result)
            result.reason = "The tool ran past its deadline of \(Self.format(spec.deadlineSeconds ?? 0)) seconds. The executor stopped it."
        case .exited:
            if !liveCandidates().isEmpty {
                lingering = true
                stopTree(grace: spec.graceSeconds, into: &result)
            }
        }
        result.exit = ExecutorSpawn.reap(pid)
        state.withLock {
            $0.tracked.remove(pid)
            $0.exited.remove(pid)
        }
        reapAdoptedOrphans()
        result.adoptedOrphansReaped = state.withLock { $0.adoptedReaped }
        guard case .exited = cause else { return result }

        if lingering {
            result.reason = StepReason.lingeringProcess
        } else if let exit = result.exit, exit.termination == .exited(code: 0) {
            finishOutputs(spec.outputs, into: &result)
        } else if case .signaled(let signal)? = result.exit?.termination {
            result.reason = "A signal (\(signal)) ended the tool."
        } else if case .exited(let code)? = result.exit?.termination {
            result.reason = "The tool exited with status \(code)."
        } else {
            result.reason = "The tool's exit status could not be read."
        }
        return result
    }

    /// Counts and hashes each output of a step whose tool exited 0 and left nothing running.
    private func finishOutputs(_ paths: [String], into result: inout StepResult) {
        var outputs: [StepRecord.Output] = []
        for path in paths {
            var info = stat()
            guard stat(path, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else {
                result.reason = "The tool exited 0 but did not write the output \(path)."
                return
            }
            do {
                let digest = try PortableDigest.sha256Hex(ofFileAt: URL(fileURLWithPath: path))
                outputs.append(StepRecord.Output(path: path, bytes: UInt64(info.st_size), sha256: digest))
            } catch {
                result.reason = "The output \(path) could not be read. \(error)"
                return
            }
        }
        result.outputs = outputs
        result.outcome = .succeeded
    }

    static func seconds(since start: ContinuousClock.Instant) -> Double {
        let elapsed = ContinuousClock.now - start
        return Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
    }

    /// A whole number without a fraction, and any other value as Swift prints it. A value `Int` cannot hold, such as the
    /// 1e300 a flag may carry, keeps its exponent form, since `Int(seconds)` traps there.
    static func format(_ seconds: Double) -> String {
        seconds == seconds.rounded() && abs(seconds) < 1e15 ? String(Int(seconds)) : String(seconds)
    }
}
