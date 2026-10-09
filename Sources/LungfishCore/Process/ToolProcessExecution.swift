// ToolProcessExecution.swift - The engine behind ToolProcess.run and runPipeline
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import Darwin
import os
import Synchronization

/// Runs one or more stages connected stdout to stdin, and decides when the
/// run is over.
///
/// A run is over when every launched stage has exited, every captured stream
/// and stdin feed has closed, every termination has finished and every stage
/// that writes an output file has no running process left in its group. A
/// stream or group that has not settled when the drain grace period runs out
/// is cut short and its group killed. Then every stage is reaped. Mutable
/// state lives in one Mutex. Exit checks, reads and event delivery run on one
/// serial queue, and terminations, which sleep, run on GCD threads.
final class ToolProcessExecution: Sendable {
    struct Limits: Sendable {
        var wallClock: Duration?
        var idle: Duration?
        var drainGrace: Duration
    }

    struct Observers: Sendable {
        var failurePolicy: ToolPipelineFailurePolicy
        var onLaunch: (@Sendable (Int, Int32) -> Void)?
        var onEvent: (@Sendable (Int, ToolProcessEvent) -> Void)?
    }

    struct ExitRecord {
        var termination: ToolProcessTermination
        var at: ContinuousClock.Instant
        /// The status came from elsewhere, so the pid is not ours to signal or reap.
        var lost: Bool
    }

    struct StageRecord {
        var pid: pid_t = 0
        var launchedAt: ContinuousClock.Instant?
        var exit: ExitRecord?
        var exitSource: DispatchSourceProcess?
        var drains: [ToolProcessStreamDrain] = []
        var writesFile = false
        var groupSettled = false
        var groupAbandoned = false
        var stop: ToolProcessStop?

        var launched: Bool { pid > 0 }
        var signalable: Bool { launched && !(exit?.lost ?? false) }
    }

    struct RunState {
        var stages: [StageRecord]
        var feeders: [ToolProcessInputFeeder] = []
        var openFeeders = 0
        var openDrains = 0
        var pendingKills = 0
        var startedAt: ContinuousClock.Instant?
        var limitStart: SuspendingClock.Instant?
        var finishedAt: ContinuousClock.Instant?
        var launchesFinished = false
        var launchFailure: (stage: Int, label: String, reason: String)?
        var runStop: ToolProcessStop?
        /// The stage whose failure stopped the pipeline under stopAllOnFailure.
        var policyFailure: Int?
        var drainPhaseStarted = false
        var drainGraceExpired = false
        var completed = false
        var continuation: CheckedContinuation<Void, Never>?

        var allLaunchedStagesExited: Bool {
            launchesFinished && stages.allSatisfy { !$0.launched || $0.exit != nil }
        }
    }

    enum StageLaunchError: Error {
        case failed(String)
    }

    static let logger = Logger(subsystem: LogSubsystem.core, category: "ToolProcess")

    let specs: [ToolProcessSpec]
    let limits: Limits
    let observers: Observers
    let queue: DispatchQueue
    let clock = ContinuousClock()
    let limitClock = SuspendingClock()
    let state: Mutex<RunState>
    let lastActivity: Mutex<SuspendingClock.Instant>

    init(specs: [ToolProcessSpec], limits: Limits, observers: Observers) {
        self.specs = specs
        self.limits = limits
        self.observers = observers
        self.queue = DispatchQueue(label: "org.lungfish.tool-process", qos: Self.qualityOfService(Task.currentPriority))
        self.state = Mutex(RunState(stages: Array(repeating: StageRecord(), count: specs.count)))
        self.lastActivity = Mutex(SuspendingClock().now)
    }

    /// The queue's QoS follows the calling task's priority, so a run started
    /// from a user-initiated task is not starved behind utility work.
    static func qualityOfService(_ priority: TaskPriority) -> DispatchQoS {
        switch priority.rawValue {
        case TaskPriority.userInitiated.rawValue...: return .userInitiated
        case TaskPriority.medium.rawValue...: return .default
        case TaskPriority.utility.rawValue...: return .utility
        default: return .background
        }
    }

    // MARK: - Run

    func run() async throws(ToolProcessError) -> ToolPipelineResult {
        if Task.isCancelled {
            throw .cancelled(results: [])
        }
        await withTaskCancellationHandler {
            self.launchAll()
            await self.waitForCompletion()
        } onCancel: {
            self.requestStop(.cancelled)
        }
        return try outcome()
    }

    private func waitForCompletion() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let resumeNow = state.withLock { run -> Bool in
                if run.completed { return true }
                run.continuation = continuation
                return false
            }
            if resumeNow {
                // Behind every event already queued.
                queue.async {
                    continuation.resume()
                }
            }
        }
    }

    // MARK: - Launch

    private func launchAll() {
        let startedAt = clock.now
        let limitStart = limitClock.now
        state.withLock {
            $0.startedAt = startedAt
            $0.limitStart = limitStart
        }
        lastActivity.withLock { $0 = limitStart }

        var upstreamRead: Int32?
        for index in specs.indices {
            if state.withLock({ $0.runStop != nil || $0.policyFailure != nil }) {
                break
            }
            do {
                upstreamRead = try launchStage(index, upstreamRead: upstreamRead)
            } catch {
                // launchStage closed every descriptor of this stage, the
                // upstream read end included.
                upstreamRead = nil
                let reason: String
                switch error {
                case .failed(let text): reason = text
                }
                state.withLock { $0.launchFailure = (index, specs[index].label, reason) }
                Self.logger.error("Could not launch \(self.specs[index].label, privacy: .public). \(reason, privacy: .public)")
                break
            }
        }
        if let upstreamRead {
            close(upstreamRead)
        }

        let toTerminate = state.withLock { run -> [Int] in
            run.launchesFinished = true
            guard let failure = run.launchFailure else { return [] }
            return Self.claimRunningStages(&run, stop: .pipelineStageFailed(stage: failure.stage))
        }
        toTerminate.forEach(terminateStage)
        scheduleLimitCheck()
        evaluateCompletion()
    }

    /// Launches one stage and returns the read end of its stdout pipe when a
    /// later stage reads it.
    private func launchStage(_ index: Int, upstreamRead: Int32?) throws(StageLaunchError) -> Int32? {
        let spec = specs[index]
        let isLast = index == specs.count - 1
        var childFDs: [Int32] = []
        var parentFDs: [Int32] = []
        var captures: [(stream: ToolProcessStream, fd: Int32, limit: Int?)] = []
        var feed: (fd: Int32, data: Data)?
        var downstreamRead: Int32?

        func closeAll() {
            (childFDs + parentFDs).forEach { close($0) }
        }

        func childOutput(_ output: ToolProcessOutput, stream: ToolProcessStream) throws(ToolProcessDescriptors.OpenError) -> Int32 {
            switch output {
            case .capture(let limit):
                let pipe = try ToolProcessDescriptors.makePipe()
                parentFDs.append(pipe.read)
                captures.append((stream, pipe.read, limit))
                return pipe.write
            case .file(let url):
                return try ToolProcessDescriptors.openForWriting(url.path)
            case .discard:
                return try ToolProcessDescriptors.openForWriting("/dev/null")
            }
        }

        let stdinFD: Int32
        let stdoutFD: Int32
        let stderrFD: Int32
        do throws(ToolProcessDescriptors.OpenError) {
            if let upstreamRead {
                stdinFD = upstreamRead
            } else {
                switch spec.stdin {
                case .null:
                    stdinFD = try ToolProcessDescriptors.openForReading("/dev/null")
                case .file(let url):
                    stdinFD = try ToolProcessDescriptors.openForReading(url.path)
                case .data(let data):
                    let pipe = try ToolProcessDescriptors.makePipe()
                    parentFDs.append(pipe.write)
                    feed = (pipe.write, data)
                    stdinFD = pipe.read
                }
            }
            childFDs.append(stdinFD)
            if isLast {
                stdoutFD = try childOutput(spec.stdout, stream: .stdout)
            } else {
                let pipe = try ToolProcessDescriptors.makePipe()
                parentFDs.append(pipe.read)
                downstreamRead = pipe.read
                stdoutFD = pipe.write
            }
            childFDs.append(stdoutFD)
            stderrFD = try childOutput(spec.stderr, stream: .stderr)
            childFDs.append(stderrFD)
        } catch {
            closeAll()
            throw .failed(error.reason)
        }

        let launchedAt = clock.now
        let pid: pid_t
        do throws(ToolProcessSpawner.Failure) {
            pid = try ToolProcessSpawner.spawn(
                executable: spec.executableURL,
                arguments: spec.arguments,
                environment: spec.environment,
                workingDirectory: spec.workingDirectory,
                stdin: stdinFD,
                stdout: stdoutFD,
                stderr: stderrFD
            )
        } catch {
            closeAll()
            throw .failed(error.reason)
        }
        // The child holds its own copies now. Closing ours leaves the child's
        // group and tree as the only writers, so end of file means they are done.
        childFDs.forEach { close($0) }

        NativeProcessRegistry.shared.register(processGroupLeader: pid)
        observers.onLaunch?(index, pid)
        Self.logger.info("Launched \(spec.label, privacy: .public) as pid \(pid)")
        if let onEvent = observers.onEvent {
            let argv = spec.argv
            queue.async { onEvent(index, .started(pid: pid, argv: argv)) }
        }

        var onLine: (@Sendable (ToolProcessStream, String) -> Void)?
        if let onEvent = observers.onEvent {
            onLine = { stream, line in onEvent(index, .output(stream: stream, line: line)) }
        }
        let drains = captures.map { capture in
            ToolProcessStreamDrain(
                stream: capture.stream,
                fd: capture.fd,
                limit: capture.limit,
                maxLineBytes: spec.maxLineBytes,
                queue: queue,
                onLine: onLine,
                onActivity: { [weak self] in self?.recordActivity() },
                onClosed: { [weak self] in self?.streamClosed(feeder: false) }
            )
        }
        let feeder = feed.map {
            ToolProcessInputFeeder(fd: $0.fd, data: $0.data, queue: queue) { [weak self] in
                self?.streamClosed(feeder: true)
            }
        }
        let writesFile = (isLast && Self.isFile(spec.stdout)) || Self.isFile(spec.stderr)
        let stop = state.withLock { run -> ToolProcessStop? in
            run.stages[index].pid = pid
            run.stages[index].launchedAt = launchedAt
            run.stages[index].drains = drains
            run.stages[index].writesFile = writesFile
            run.openDrains += drains.count
            if let feeder {
                run.feeders.append(feeder)
                run.openFeeders += 1
            }
            guard let stop = run.runStop ?? run.policyFailure.map({ .pipelineStageFailed(stage: $0) }) else { return nil }
            run.stages[index].stop = stop
            run.pendingKills += 1
            return stop
        }
        drains.forEach { $0.start() }
        feeder?.start()
        watchExit(index, pid: pid)
        if stop != nil {
            terminateStage(index)
        }
        return downstreamRead
    }

    private static func isFile(_ output: ToolProcessOutput) -> Bool {
        if case .file = output { return true }
        return false
    }
}
