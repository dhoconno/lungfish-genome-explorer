// ToolProcessExecution+Lifecycle.swift - Exits, draining, stops, limits and outcome of a ToolProcess run
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import Darwin
import os
import Synchronization

extension ToolProcessExecution {
    // MARK: - Exit

    /// Watches a stage for exit with a process source, without polling.
    ///
    /// The exit can come before the source is registered with the kernel.
    /// The registration handler looks once the source is registered, which
    /// covers an exit before that point, and libdispatch reports an exit
    /// that already happened when it registers (ESRCH) as an exit event.
    /// After an exit event the status is waitable at once in practice, and
    /// should it not be yet, ``exitReported(_:)`` looks again shortly.
    func watchExit(_ index: Int, pid: pid_t) {
        let source = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: queue)
        source.setEventHandler { [weak self] in
            self?.exitReported(index)
        }
        source.setRegistrationHandler { [weak self] in
            self?.checkExit(index)
        }
        state.withLock { $0.stages[index].exitSource = source }
        source.activate()
    }

    /// The kernel reported the stage's exit. Records it, looking again every
    /// few milliseconds until waitid reports it.
    private func exitReported(_ index: Int) {
        guard !checkExit(index) else { return }
        queue.asyncAfter(deadline: .now() + .milliseconds(5)) { [weak self] in
            self?.exitReported(index)
        }
    }

    /// Records the stage's exit if it has happened, without reaping it.
    /// Runs on `queue`. Returns true once the exit is recorded.
    @discardableResult
    private func checkExit(_ index: Int) -> Bool {
        let (pid, known) = state.withLock { ($0.stages[index].pid, $0.stages[index].exit != nil) }
        if known { return true }
        let termination: ToolProcessTermination
        var lost = false
        switch ToolProcessSpawner.peekExit(pid) {
        case .running:
            return false
        case .exited(let observed):
            termination = observed
        case .lost:
            termination = .exited(code: -1)
            lost = true
            Self.logger.error("\(self.specs[index].label, privacy: .public) (pid \(pid)) was reaped outside ToolProcess, so its status is unknown")
        }
        let now = clock.now
        let source = state.withLock { run -> DispatchSourceProcess? in
            run.stages[index].exit = ExitRecord(termination: termination, at: now, lost: lost)
            let source = run.stages[index].exitSource
            run.stages[index].exitSource = nil
            return source
        }
        source?.cancel()
        Self.logger.info("\(self.specs[index].label, privacy: .public) ended with \(String(describing: termination), privacy: .public)")
        stageExited(index, termination: termination)
        return true
    }

    private func stageExited(_ index: Int, termination: ToolProcessTermination) {
        if observers.failurePolicy == .stopAllOnFailure, specs.count > 1,
           Self.failsPipeline(termination, stage: index, stageCount: specs.count) {
            let targets = state.withLock { run -> [Int] in
                guard run.runStop == nil, run.policyFailure == nil, run.launchFailure == nil,
                      run.stages[index].stop == nil else { return [] }
                run.policyFailure = index
                return Self.claimRunningStages(&run, stop: .pipelineStageFailed(stage: index))
            }
            if !targets.isEmpty {
                Self.logger.warning("Stage \(index) of the pipeline failed, stopping stages \(targets.map(String.init).joined(separator: ", "), privacy: .public)")
            }
            targets.forEach(terminateStage)
        }
        evaluateCompletion()
    }

    /// A stage killed by SIGPIPE is judged by the stage it wrote to, which
    /// stops the pipeline itself if it fails, so only other failures stop it here.
    static func failsPipeline(_ termination: ToolProcessTermination, stage: Int, stageCount: Int) -> Bool {
        if termination == .exited(code: 0) { return false }
        if termination == .signaled(signal: SIGPIPE) && stage < stageCount - 1 { return false }
        return true
    }

    // MARK: - Streams and completion

    func streamClosed(feeder: Bool) {
        state.withLock { run in
            if feeder {
                run.openFeeders -= 1
            } else {
                run.openDrains -= 1
            }
        }
        evaluateCompletion()
    }

    func recordActivity() {
        let now = limitClock.now
        lastActivity.withLock { $0 = now }
    }

    private enum CompletionStep {
        case none
        case beginDrainPhase([ToolProcessInputFeeder], watchGroups: Bool, cutShortFor: ToolProcessStop?)
        case complete((@Sendable () -> Void)?, reap: [pid_t], unregister: [pid_t])
    }

    func evaluateCompletion() {
        let now = clock.now
        let step = state.withLock { run -> CompletionStep in
            guard !run.completed, run.allLaunchedStagesExited else { return .none }
            if !run.drainPhaseStarted {
                run.drainPhaseStarted = true
                return .beginDrainPhase(
                    run.feeders,
                    watchGroups: run.stages.contains { $0.writesFile && $0.signalable },
                    cutShortFor: run.runStop
                )
            }
            let groupsSettled = run.stages.allSatisfy {
                !$0.writesFile || !$0.signalable || $0.groupSettled || $0.groupAbandoned
            }
            guard run.openDrains == 0, run.openFeeders == 0, run.pendingKills == 0, groupsSettled else {
                return .none
            }
            run.completed = true
            run.finishedAt = now
            let onComplete = run.onComplete
            run.onComplete = nil
            return .complete(
                onComplete,
                reap: run.stages.filter(\.signalable).map(\.pid),
                unregister: run.stages.filter(\.launched).map(\.pid)
            )
        }
        switch step {
        case .none:
            break
        case .beginDrainPhase(let feeders, let watchGroups, let stop):
            // Every stage has exited, so nothing reads stdin any more.
            feeders.forEach { $0.stop() }
            if let stop {
                // The run is already being stopped, so descendants get no grace.
                queue.async { [weak self] in
                    self?.cutShort(stop: stop, reason: "the run is stopping")
                }
            } else {
                queue.asyncAfter(deadline: .now() + Self.dispatchInterval(limits.drainGrace)) { [weak self] in
                    self?.cutShort(stop: nil, reason: "the drain grace period ran out")
                }
            }
            if watchGroups {
                queue.async { [weak self] in
                    self?.pollGroups()
                }
            }
            evaluateCompletion()
        case .complete(let onComplete, let reap, let unregister):
            // Unregister first, so app quit can no longer signal these
            // groups, then reap. Reaping last keeps every pid and group ID
            // reserved until nothing can send a signal to it any more.
            unregister.forEach { NativeProcessRegistry.shared.unregister(processGroupLeader: $0) }
            reap.forEach(ToolProcessSpawner.reap)
            // A reader of a streamed stdout stops waiting once nothing is
            // left in the pipe, even if a process outside the run holds it.
            stdoutChannel.runEnded()
            // Finish behind every event already queued, so a run whose streams
            // are not captured still delivers its started events first.
            queue.async {
                onComplete?()
            }
        }
    }

    /// Waits for every stage that writes a file to have no running process
    /// left in its group, because such a process could still be writing the
    /// file after the run returned. A descendant that left the group with
    /// setsid or setpgid is not listed, so it can escape this wait.
    private func pollGroups() {
        let watched = state.withLock { run -> [(Int, pid_t)] in
            guard !run.completed else { return [] }
            return run.stages.indices.compactMap { index in
                let stage = run.stages[index]
                guard stage.writesFile, stage.signalable, !stage.groupSettled, !stage.groupAbandoned else { return nil }
                return (index, stage.pid)
            }
        }
        guard !watched.isEmpty else { return }
        let settled = watched.filter { ToolProcessSpawner.liveGroupMembers($0.1).isEmpty }.map(\.0)
        if !settled.isEmpty {
            state.withLock { run in
                settled.forEach { run.stages[$0].groupSettled = true }
            }
            evaluateCompletion()
        }
        if settled.count < watched.count {
            queue.asyncAfter(deadline: .now() + .milliseconds(25)) { [weak self] in
                self?.pollGroups()
            }
        }
    }

    /// How long descendants still holding output when the drain grace period
    /// runs out have between SIGTERM and SIGKILL. The run is over for them,
    /// so they get a short fixed grace, independent of the spec's
    /// ``ToolProcessSpec/terminationGracePeriod``, which applies to a
    /// cancellation and a timeout only.
    static let leftoverTerminationGrace: Duration = .milliseconds(200)

    /// Cuts short every stage whose output has not settled. Its open streams
    /// are marked abandoned, its process group and tree are terminated
    /// through ``ProcessGroupTerminator``, SIGKILL following after a grace
    /// period, and once they are gone its streams are closed. The grace is
    /// the spec's termination grace when the run is stopping (`stop` is set),
    /// and ``leftoverTerminationGrace`` when only the drain grace ran out.
    /// Runs on `queue`.
    private func cutShort(stop: ToolProcessStop?, reason: String) {
        let targets = state.withLock { run -> [(index: Int, pid: pid_t?, drains: [ToolProcessStreamDrain])] in
            guard !run.completed else { return [] }
            var targets: [(index: Int, pid: pid_t?, drains: [ToolProcessStreamDrain])] = []
            for index in run.stages.indices {
                let stage = run.stages[index]
                guard stage.launched else { continue }
                let openDrains = stage.drains.filter { !$0.isClosed }
                let unsettledGroup = stage.writesFile && stage.signalable && !stage.groupSettled && !stage.groupAbandoned
                guard !openDrains.isEmpty || unsettledGroup else { continue }
                if unsettledGroup {
                    run.stages[index].groupAbandoned = true
                }
                if let stop, run.stages[index].stop == nil {
                    run.stages[index].stop = stop
                }
                if stage.signalable {
                    run.pendingKills += 1
                }
                targets.append((index, stage.signalable ? stage.pid : nil, openDrains))
            }
            return targets
        }
        guard !targets.isEmpty else { return }
        Self.logger.warning("Cutting output short for \(targets.map { self.specs[$0.index].label }.joined(separator: ", "), privacy: .public) because \(reason, privacy: .public)")
        for target in targets {
            target.drains.forEach { $0.markAbandoned() }
            guard let pid = target.pid else {
                target.drains.forEach { $0.abandon() }
                continue
            }
            let grace = stop == nil ? Self.leftoverTerminationGrace : specs[target.index].terminationGracePeriod
            // The leader is an unreaped zombie, so this group ID is still ours.
            ProcessGroupTerminator.terminate(processGroupLeader: pid, gracePeriod: grace) { [self] in
                queue.async { [self] in
                    target.drains.forEach { $0.abandon() }
                    state.withLock { $0.pendingKills -= 1 }
                    evaluateCompletion()
                }
            }
        }
    }

    // MARK: - Stops and limits

    func requestStop(_ stop: ToolProcessStop) {
        enum StopStep {
            case none
            case terminate([Int])
            case cutShort
        }
        let step = state.withLock { run -> StopStep in
            guard !run.completed, run.runStop == nil else { return .none }
            if run.allLaunchedStagesExited {
                // Every stage has exited and only draining is left. A limit
                // has nothing left to stop, but cancellation still ends the
                // wait for descendants and kills them.
                guard stop == .cancelled else { return .none }
                run.runStop = stop
                return run.drainPhaseStarted ? .cutShort : .none
            }
            run.runStop = stop
            return .terminate(Self.claimRunningStages(&run, stop: stop))
        }
        switch step {
        case .none:
            return
        case .terminate(let stages):
            Self.logger.warning("Stopping \(self.specs.map(\.label).joined(separator: " | "), privacy: .public) (\(String(describing: stop), privacy: .public))")
            stages.forEach(terminateStage)
        case .cutShort:
            queue.async { [weak self] in
                self?.cutShort(stop: stop, reason: "the run was cancelled")
            }
        }
    }

    /// Marks every launched stage that has not exited and is not already
    /// being stopped with `stop`, counts its termination as pending and
    /// returns their indices.
    static func claimRunningStages(_ run: inout RunState, stop: ToolProcessStop) -> [Int] {
        var claimed: [Int] = []
        for index in run.stages.indices {
            let stage = run.stages[index]
            guard stage.launched, stage.exit == nil, stage.stop == nil else { continue }
            run.stages[index].stop = stop
            run.pendingKills += 1
            claimed.append(index)
        }
        return claimed
    }

    /// Terminates a claimed stage's group and tree. The termination waits
    /// on a shared timer, not a thread, and ends as soon as the group and
    /// tree are gone, so a tool that honours SIGTERM does not cost the grace.
    func terminateStage(_ index: Int) {
        let pid = state.withLock { $0.stages[index].pid }
        ProcessGroupTerminator.terminate(processGroupLeader: pid, gracePeriod: specs[index].terminationGracePeriod) { [self] in
            queue.async { [self] in
                state.withLock { $0.pendingKills -= 1 }
                evaluateCompletion()
            }
        }
    }

    func scheduleLimitCheck() {
        guard limits.wallClock != nil || limits.idle != nil else { return }
        checkLimits()
    }

    /// Checks the limits on the suspending clock, so time the Mac spends
    /// asleep never counts against a run. DispatchTime does not advance
    /// during sleep either, so the rechecks line up with it.
    private func checkLimits() {
        let (finished, limitStart) = state.withLock { run in
            (run.completed || run.runStop != nil || run.allLaunchedStagesExited, run.limitStart)
        }
        guard !finished, let limitStart else { return }
        let now = limitClock.now
        var next: SuspendingClock.Instant?
        if let wallClock = limits.wallClock {
            let deadline = limitStart.advanced(by: wallClock)
            if now >= deadline {
                requestStop(.timedOut(.wallClock(wallClock)))
                return
            }
            next = deadline
        }
        if let idle = limits.idle {
            let deadline = lastActivity.withLock { $0 }.advanced(by: idle)
            if now >= deadline {
                requestStop(.timedOut(.idle(idle)))
                return
            }
            next = min(next ?? deadline, deadline)
        }
        guard let next else { return }
        let delay = Self.dispatchInterval(now.duration(to: next))
        queue.asyncAfter(deadline: .now() + delay) { [weak self] in
            self?.checkLimits()
        }
    }

    // MARK: - Outcome

    func outcome() throws(ToolProcessError) -> ToolPipelineResult {
        let run = state.withLock { $0 }
        var results: [ToolProcessResult] = []
        for (index, stage) in run.stages.enumerated() {
            guard stage.launched, let exit = stage.exit, let launchedAt = stage.launchedAt else { continue }
            let stdout = stage.drains.first { $0.stream == .stdout }?.captured()
            let stderr = stage.drains.first { $0.stream == .stderr }?.captured()
            results.append(
                ToolProcessResult(
                    label: specs[index].label,
                    pid: stage.pid,
                    termination: exit.termination,
                    stop: stage.stop,
                    stdout: stdout?.data ?? Data(),
                    stderr: stderr?.data ?? Data(),
                    stdoutTruncated: stdout?.truncated ?? false,
                    stderrTruncated: stderr?.truncated ?? false,
                    outputDrainTimedOut: (stdout?.abandoned ?? false) || (stderr?.abandoned ?? false) || stage.groupAbandoned,
                    outputReadFailed: (stdout?.readFailed ?? false) || (stderr?.readFailed ?? false),
                    wallTime: launchedAt.duration(to: exit.at)
                )
            )
        }
        switch run.runStop {
        case .cancelled:
            throw .cancelled(results: results)
        case .timedOut(let timeout):
            throw .timedOut(timeout, results: results)
        case .pipelineStageFailed, nil:
            break
        }
        if let failure = run.launchFailure {
            throw .launchFailed(label: failure.label, reason: failure.reason, results: results)
        }
        let wallTime: Duration
        if let startedAt = run.startedAt, let finishedAt = run.finishedAt {
            wallTime = startedAt.duration(to: finishedAt)
        } else {
            wallTime = .zero
        }
        return ToolPipelineResult(stages: results, wallTime: wallTime)
    }

    // MARK: - Duration conversion

    static func seconds(_ duration: Duration) -> TimeInterval {
        let components = duration.components
        return Double(components.seconds) + Double(components.attoseconds) / 1e18
    }

    static func dispatchInterval(_ duration: Duration) -> DispatchTimeInterval {
        let nanoseconds = seconds(duration) * 1e9
        // Round up so a check never fires just before its deadline.
        return .nanoseconds(Int(min(max(nanoseconds.rounded(.up), 0), Double(Int32.max) * 1e9)))
    }
}
