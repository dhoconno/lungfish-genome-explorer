// ToolProcessExecution+Observation.swift - The one provenance observation of a finished ToolProcess run
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import Synchronization

extension ToolProcessExecution {
    /// Where a run's observation starts its clocks, taken in `init` only
    /// when an observer is bound.
    struct ObservationAnchor: Sendable {
        /// The run's place in the order runs with an observer were built.
        let sequenceNumber: UInt64
        /// The wall-clock time, read through ``ProvenanceTimeSource`` so a
        /// test can pin it for the task that builds the run.
        let wallClock: Date
        /// The monotonic instant at the same moment, on the clock the run
        /// measures its launches and exits with.
        let instant: ContinuousClock.Instant
    }

    /// Counts the runs built with an observer in this process.
    private static let observedRunCount = Atomic<UInt64>(0)

    static func makeObservationAnchor() -> ObservationAnchor {
        ObservationAnchor(
            sequenceNumber: observedRunCount.wrappingAdd(1, ordering: .relaxed).newValue,
            wallClock: ProvenanceTimeSource.current.wallClockNow(),
            instant: ContinuousClock.now
        )
    }

    /// Delivers the run's one observation to the observer bound when the run
    /// was built, and does nothing without one. Runs on `queue` once the run
    /// is over and before `onComplete` wakes anything waiting on the run. It
    /// holds no lock, because the lock is not recursive and an observer may
    /// read the run's handle.
    func deliverObservation() {
        guard let observer, let anchor = observationAnchor else { return }
        observer.deliver(observation(anchor: anchor))
    }

    /// Builds the observation of the finished run. Launched stages come from
    /// ``launchedStageResults(_:)``, the helper ``outcome()`` reads, so the
    /// observation and the result or error never disagree.
    func observation(anchor: ObservationAnchor) -> ToolProcessRunObservation {
        let run = state.withLock { $0 }
        let launched = launchedStageResults(run)
        var resultsByStage: [Int: ToolProcessResult] = [:]
        for entry in launched {
            resultsByStage[entry.stage] = entry.result
        }
        // The rule of ToolPipelineResult.failedStageIndices over the same
        // results, mapped back to stage indices.
        let failedOnTheirOwn = Set(
            ToolPipelineResult(stages: launched.map { $0.result }, wallTime: .zero)
                .failedStageIndices
                .map { launched[$0].stage }
        )
        let stages = specs.indices.map { index -> ToolProcessRunObservation.Stage in
            let spec = specs[index]
            let record = run.stages[index]
            guard let result = resultsByStage[index], let launchedAt = record.launchedAt else {
                let failure = run.launchFailure.flatMap { $0.stage == index ? $0.reason : nil }
                return ToolProcessRunObservation.Stage(
                    index: index,
                    stageCount: specs.count,
                    label: spec.label,
                    argv: spec.argv,
                    workingDirectory: spec.workingDirectory,
                    ending: failure.map { .launchFailed(reason: $0) } ?? .notLaunched,
                    startedAt: nil,
                    wallTime: nil,
                    stop: record.stop,
                    outputComplete: nil,
                    failedOnItsOwn: failure != nil,
                    stderr: nil,
                    environmentChange: spec.environmentChange,
                    identityHint: spec.identityHint,
                    observedPeakMemoryBytes: nil
                )
            }
            let sinceAnchor = max(.zero, anchor.instant.duration(to: launchedAt))
            return ToolProcessRunObservation.Stage(
                index: index,
                stageCount: specs.count,
                label: spec.label,
                argv: spec.argv,
                workingDirectory: spec.workingDirectory,
                ending: (record.exit?.lost ?? false) ? .statusLost : .terminated(result.termination),
                startedAt: anchor.wallClock.addingTimeInterval(Self.seconds(sinceAnchor)),
                wallTime: result.wallTime,
                stop: result.stop,
                // The reader of a streamed stdout is judged after the run
                // ends, so the run cannot record it (decision P3).
                outputComplete: spec.stdout == .stream ? nil : result.outputComplete,
                failedOnItsOwn: failedOnTheirOwn.contains(index),
                stderr: spec.stderr.isCaptured
                    ? .init(captured: result.stderr, earlierBytesDropped: result.stderrTruncated)
                    : nil,
                environmentChange: spec.environmentChange,
                identityHint: spec.identityHint,
                observedPeakMemoryBytes: nil
            )
        }
        return ToolProcessRunObservation(
            sequenceNumber: anchor.sequenceNumber,
            startedAt: anchor.wallClock,
            wallTime: Self.runWallTime(run),
            stop: run.runStop,
            stages: stages
        )
    }
}
