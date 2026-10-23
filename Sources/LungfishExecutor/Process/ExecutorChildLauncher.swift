// ExecutorChildLauncher.swift - The Linux executor's launcher for the portable layer's readers (lane K3B)
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

/// How one child of ``ExecutorChildLauncher`` ended, kept for the command's report.
struct ReaderChildEnd: Codable, Equatable, Sendable {
    var label: String
    /// The absolute program that ran, the decompressor when it served the reader's gzip request.
    var executable: String
    var arguments: [String]
    var pid: Int32
    var exitCode: Int32?
    var signal: Int32?
    var isSuccess: Bool
    /// True when the stream had not ended within the drain grace after the child exited, so its group was stopped.
    var drainExpired: Bool
    /// True when a cancel or the executor's signal stopped the child.
    var stopped: Bool
    var escalatedToSIGKILL: Bool
}

/// The ends of every child a launcher started, in the order they were reaped.
final class ReaderChildLog: Sendable {
    private let ends = Mutex<[ReaderChildEnd]>([])

    func append(_ end: ReaderChildEnd) {
        ends.withLock { $0.append(end) }
    }

    var all: [ReaderChildEnd] { ends.withLock { $0 } }
}

/// Starts the portable layer's children for the Linux executor (`docs/contracts/RUNNING-A-TOOL.md`, The Linux executor's
/// launcher).
///
/// SWIFT ruling rule 4: "The reader's pigz child (Cf-10). It runs in a group of its own, registered with the cancel
/// path." Each child is a tracked child of `controller` and leads its own process group, so `stopTree` signals it in the
/// tool's SIGTERM, grace and SIGKILL sequence, `reapAdoptedOrphans` never reaps it and the end-of-step check fails a step
/// that leaves it running. Its stdin is `/dev/null`, its stdout a pipe the caller reads and its stderr `/dev/null`, since
/// the seam discards it. Its environment is exactly the request's and no `PATH` lookup is made.
///
/// The portable reader asks for `/usr/bin/gzip -dc <file>`, the Mac's route. With `decompressor` set the launcher starts
/// that absolute program with the same arguments instead, the image manifest's `pigz` (K2.4). `pigz -dc` decodes
/// concatenated members and BGZF as `gzip -dc` does (C3-facts F-A2).
struct ExecutorChildLauncher: PortableChildLauncher {
    /// How long the stream may stay open after the child exits (`RUNNING-A-TOOL.md`, the drain grace).
    static let defaultDrainGraceSeconds = 5.0

    let controller: StepController
    let decompressor: String?
    let graceSeconds: Double
    let drainGraceSeconds: Double
    let log: ReaderChildLog

    init(
        controller: StepController,
        decompressor: String? = nil,
        graceSeconds: Double = StepCommand.defaultGraceSeconds,
        drainGraceSeconds: Double = ExecutorChildLauncher.defaultDrainGraceSeconds,
        log: ReaderChildLog = ReaderChildLog()
    ) {
        self.controller = controller
        self.decompressor = decompressor
        self.graceSeconds = graceSeconds
        self.drainGraceSeconds = drainGraceSeconds
        self.log = log
    }

    /// Whether `request` is the portable reader's gzip decompression, the one request `decompressor` serves.
    static func isGzipDecompression(_ request: PortableChildRequest) -> Bool {
        request.executableURL.lastPathComponent == "gzip" && request.arguments.count == 2 && request.arguments[0] == "-dc"
    }

    /// The absolute program this launcher starts for `request`.
    func executable(for request: PortableChildRequest) -> String {
        if let decompressor, Self.isGzipDecompression(request) {
            return decompressor
        }
        return request.executableURL.path
    }

    func start(_ request: PortableChildRequest) throws -> any PortableChild {
        let program = executable(for: request)
        guard program.hasPrefix("/") else {
            throw ExecutorSpawn.Failure(reason: "The program \(program) is not an absolute path.")
        }
        let stdin = try ExecutorSpawn.openNullForReading()
        defer { close(stdin) }
        let stderr = try ExecutorSpawn.openNullForWriting()
        defer { close(stderr) }
        let started = try controller.spawnTrackedReadingStdout(
            executable: program, arguments: request.arguments, environment: request.environment,
            stdin: stdin, stderr: stderr
        )
        let child = ExecutorChild(
            pid: started.pid, pipeEnd: started.stdout, label: request.label, executable: program,
            arguments: request.arguments, launcher: self
        )
        controller.watchExit(of: started.pid) { child.markExited() }
        return child
    }

    /// The first line `<program> --version` prints, run through this launcher, or nil when it printed none or failed. The
    /// record's reader tool fields take it until the image manifest carries the version (K5.3).
    func versionLine(of program: String) -> String? {
        let request = PortableChildRequest(
            executableURL: URL(fileURLWithPath: program), arguments: ["--version"], environment: [:],
            label: "\(URL(fileURLWithPath: program).lastPathComponent) --version"
        )
        guard let child = try? start(request) else { return nil }
        let data = child.readStdout(filling: 4096)
        guard (try? child.waitForExit())?.isSuccess == true else { return nil }
        let first = String(decoding: data, as: UTF8.self).split(separator: "\n").first
        return first.map { $0.trimmingCharacters(in: .whitespaces) }
    }
}

/// One child of ``ExecutorChildLauncher``. `readStdout` and `waitForExit` run on the caller's thread, the step's reader
/// thread, so no cooperative thread blocks on the pipe (`RUNNING-A-TOOL.md`). `cancel` may come from any thread.
final class ExecutorChild: PortableChild, Sendable {
    private struct State {
        var exitedAt: ContinuousClock.Instant?
        var endOfStream = false
        var readFailed = false
        var drainExpired = false
        var stopRequestedAt: ContinuousClock.Instant?
        var escalated = false
        var reaping = false
        var finished: PortableChildExit?
    }

    private enum Step {
        case bytes(Int), idle, finished
    }

    let pid: pid_t
    private let pipeEnd: Int32
    private let label: String
    private let executable: String
    private let arguments: [String]
    private let launcher: ExecutorChildLauncher
    private let exited = DispatchSemaphore(value: 0)
    private let state = Mutex(State())

    init(pid: pid_t, pipeEnd: Int32, label: String, executable: String, arguments: [String], launcher: ExecutorChildLauncher) {
        self.pid = pid
        self.pipeEnd = pipeEnd
        self.label = label
        self.executable = executable
        self.arguments = arguments
        self.launcher = launcher
    }

    /// Called by the controller's watch thread once `waitid(WNOWAIT)` saw the child exit.
    func markExited() {
        state.withLock { if $0.exitedAt == nil { $0.exitedAt = .now } }
        exited.signal()
    }

    /// Loops `read(2)` until `count` bytes arrived or the stream ended, retrying EINTR. Fewer bytes mean the end, which
    /// also comes from a read error, a cancel, the executor's signal or a stream still open a drain grace after the exit.
    func readStdout(filling count: Int) -> Data {
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 65_536)
        while data.count < count {
            if launcher.controller.interruptSignal != nil {
                requestStop()
            }
            if state.withLock({ $0.stopRequestedAt != nil }) {
                break
            }
            switch readStep(into: &buffer, maximum: min(buffer.count, count - data.count)) {
            case .bytes(let got): data.append(contentsOf: buffer[0..<got])
            case .idle: continue
            case .finished: return data
            }
        }
        return data
    }

    /// Sends SIGTERM to the child's group and returns at once. `waitForExit` sends SIGKILL after the grace.
    func cancel() {
        requestStop()
    }

    /// Takes the exit from the controller's watch thread, drains the stream for up to the drain grace, stops a group that
    /// still holds it, reaps with `wait4`, drops the PID from the tracked set and closes the pipe.
    func waitForExit() throws -> PortableChildExit {
        if let finished = state.withLock({ $0.finished }) {
            return finished
        }
        waitForLeader()
        drain()
        if state.withLock({ $0.drainExpired }) {
            stopLingeringGroup()
        }
        state.withLock { $0.reaping = true }
        let end = launcher.controller.reapTracked(pid)
        close(pipeEnd)
        let flags = state.withLock { $0 }
        var record = ReaderChildEnd(
            label: label, executable: executable, arguments: arguments, pid: pid, isSuccess: false,
            drainExpired: flags.drainExpired, stopped: flags.stopRequestedAt != nil, escalatedToSIGKILL: flags.escalated
        )
        guard let end else {
            state.withLock { $0.finished = PortableChildExit(status: -1, isSuccess: false) }
            launcher.log.append(record)
            throw ExecutorSpawn.Failure(reason: "The executor could not wait for \(label).")
        }
        let status: Int32
        switch end.termination {
        case .exited(let code):
            status = code
            record.exitCode = code
        case .signaled(let signal):
            // The Mac's `ToolProcessResult.status` is the signal number, so the reason text is equal.
            status = signal
            record.signal = signal
        }
        record.isSuccess = end.termination == .exited(code: 0) && flags.endOfStream && !flags.readFailed
            && !flags.drainExpired && flags.stopRequestedAt == nil
        let result = PortableChildExit(status: status, isSuccess: record.isSuccess)
        state.withLock { $0.finished = result }
        launcher.log.append(record)
        return result
    }

    /// One poll of up to 100 ms and at most one read.
    private func readStep(into buffer: inout [UInt8], maximum: Int) -> Step {
        if state.withLock({ $0.endOfStream || $0.readFailed }) || drainGraceExpired() {
            return .finished
        }
        var poller = pollfd(fd: pipeEnd, events: Int16(POLLIN), revents: 0)
        let ready = poll(&poller, 1, 100)
        if ready == 0 || (ready < 0 && errno == EINTR) {
            return .idle
        }
        if ready < 0 {
            state.withLock { $0.readFailed = true }
            return .finished
        }
        let got = buffer.withUnsafeMutableBytes { read(pipeEnd, $0.baseAddress, maximum) }
        if got > 0 {
            return .bytes(got)
        }
        if got < 0 && errno == EINTR {
            return .idle
        }
        state.withLock {
            if got == 0 { $0.endOfStream = true } else { $0.readFailed = true }
        }
        return .finished
    }

    /// True once the child has exited and the stream stayed open for the drain grace since.
    private func drainGraceExpired() -> Bool {
        let grace = Self.duration(launcher.drainGraceSeconds)
        return state.withLock { current in
            if !current.drainExpired, !current.endOfStream, let exitedAt = current.exitedAt, ContinuousClock.now - exitedAt >= grace {
                current.drainExpired = true
            }
            return current.drainExpired
        }
    }

    /// Reads and discards the rest of the stream until it ends, fails or runs past the drain grace.
    private func drain() {
        var buffer = [UInt8](repeating: 0, count: 65_536)
        while true {
            if case .finished = readStep(into: &buffer, maximum: buffer.count) {
                return
            }
        }
    }

    /// Sends SIGTERM to the group once. The lock keeps the signal before the reap, so the group ID is still the child's.
    private func requestStop() {
        state.withLock { current in
            guard current.stopRequestedAt == nil, !current.reaping else { return }
            current.stopRequestedAt = .now
            _ = killpg(pid, SIGTERM)
        }
    }

    /// Waits for the child to exit. After a cancel or the executor's signal it sends SIGKILL to the group once the grace
    /// has passed.
    private func waitForLeader() {
        let grace = Self.duration(launcher.graceSeconds)
        while state.withLock({ $0.exitedAt == nil }) {
            if launcher.controller.interruptSignal != nil {
                requestStop()
            }
            state.withLock { current in
                if !current.escalated, let asked = current.stopRequestedAt, ContinuousClock.now - asked >= grace {
                    current.escalated = true
                    _ = killpg(pid, SIGKILL)
                }
            }
            _ = exited.wait(timeout: .now() + .milliseconds(100))
        }
    }

    /// Stops what is left of the child's group after the drain grace: SIGTERM, the grace, then SIGKILL. The child has
    /// exited but is not reaped, so its group ID cannot have been reused. A descendant that left the group is found by the
    /// end-of-step check, which reports the lingering reason.
    private func stopLingeringGroup() {
        let pid = self.pid
        func groupGone() -> Bool {
            !ProcessTable.snapshot().contains { $0.group == pid && $0.isLive }
        }
        _ = killpg(pid, SIGTERM)
        if !Self.waitUntil(seconds: launcher.graceSeconds, groupGone) {
            state.withLock { $0.escalated = true }
            _ = killpg(pid, SIGKILL)
            _ = Self.waitUntil(seconds: 10, groupGone)
        }
    }

    private static func duration(_ seconds: Double) -> Duration {
        .milliseconds(Int64(seconds * 1000))
    }

    private static func waitUntil(seconds: Double, _ condition: () -> Bool) -> Bool {
        let end = ContinuousClock.now + duration(seconds)
        while !condition() {
            if ContinuousClock.now >= end {
                return false
            }
            usleep(20_000)
        }
        return true
    }
}
