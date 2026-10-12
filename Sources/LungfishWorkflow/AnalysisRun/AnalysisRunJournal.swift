// AnalysisRunJournal.swift - The run state of one analysis run, its events, warnings and the record entries tools hand over
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishIO
import Synchronization

/// The state of one `AnalysisRunExecutor.execute` call. Each call makes its own and drops it when
/// the call returns, so the executor itself holds no run state (SWIFT X3).
///
/// Tools call in from `ToolProcess` queues, so the state sits behind a lock. Every line goes out
/// under that lock and then the lock of the run's event sink, which delivers one line at a time,
/// and no path takes the two the other way. The run's last line seals the stream, so a tool
/// callback that fires after the run ended, such as a handler on a `ToolProcess` queue or a
/// context a tool kept, writes no line and adds no warning.
final class AnalysisRunJournal: Sendable {
    private struct State {
        var warnings: [String] = []
        var inputs: [ProvenanceFileDescriptor] = []
        var steps: [ProvenanceStep] = []
        /// The root record's options, the plan's with every later contribution merged in.
        var options = AnalysisRootRecordOptions()
        /// The replay argv a unit recorded, which replaces the request's.
        var durableReplayArgv: [String]?
        /// The failure detail each unit recorded, by the unit's index, the last one it recorded.
        var failureDetails: [Int: String] = [:]
        /// Set once the last line went out. Every later line is dropped.
        var sealed = false
    }

    private let events: AnalysisRunEvents
    private let state = Mutex(State())

    init(events: AnalysisRunEvents) {
        self.events = events
    }

    func emit(_ event: CLIEvent, artifacts: [CLIEventArtifact] = []) {
        state.withLock { state in
            guard !state.sealed else { return }
            events.emit(event, artifacts: artifacts)
        }
    }

    /// Writes a log line. A warning line also joins the run's warnings, under the same lock as its
    /// delivery, so the report lists the warnings in the order their lines went out.
    func log(_ level: CLIEventLogLevel, _ message: String) {
        state.withLock { state in
            guard !state.sealed else { return }
            if level == .warning {
                state.warnings.append(message)
            }
            events.emit(.log(level: level, message: message))
        }
    }

    /// Writes the run's last line and seals the stream, under the lock every line takes, and
    /// returns the run's warnings as they stand then. No line goes out after it.
    func finish(_ event: CLIEvent, artifacts: [CLIEventArtifact] = []) -> [String] {
        state.withLock { state in
            if !state.sealed {
                events.emit(event, artifacts: artifacts)
                state.sealed = true
            }
            return state.warnings
        }
    }

    func warn(_ message: String) {
        log(.warning, message)
    }

    func recordInput(_ descriptor: ProvenanceFileDescriptor) {
        state.withLock { $0.inputs.append(descriptor) }
    }

    func recordStep(_ step: ProvenanceStep) {
        state.withLock { $0.steps.append(step) }
    }

    /// Merges options into the root record's, in the order they arrive (see
    /// ``AnalysisRootRecordOptions``). The executor records the plan's first.
    func recordOptions(_ options: AnalysisRootRecordOptions) {
        state.withLock { $0.options = $0.options.merging(options) }
    }

    func recordDurableReplayArgv(_ argv: [String]) {
        state.withLock { $0.durableReplayArgv = argv }
    }

    /// Keeps the failure detail of unit `index` as the unit handed it over. The executor bounds it
    /// only when it sends it.
    func recordFailureDetail(_ text: String, unit index: Int) {
        state.withLock { $0.failureDetails[index] = text }
    }

    /// The failure detail unit `index` recorded last, unbounded, or nil.
    func failureDetail(unit index: Int) -> String? {
        state.withLock { $0.failureDetails[index] }
    }

    var warnings: [String] {
        state.withLock { $0.warnings }
    }

    var recordedDurableReplayArgv: [String]? {
        state.withLock { $0.durableReplayArgv }
    }

    var recordedInputs: [ProvenanceFileDescriptor] {
        state.withLock { $0.inputs }
    }

    var recordedSteps: [ProvenanceStep] {
        state.withLock { $0.steps }
    }

    var recordedOptions: AnalysisRootRecordOptions {
        state.withLock { $0.options }
    }

    // MARK: Contexts

    func planningContext(projectURL: URL?) -> AnalysisRunPlanningContext {
        AnalysisRunPlanningContext(projectURL: projectURL, log: { level, message in self.log(level, message) })
    }

    func unitContext(
        index: Int,
        count: Int,
        rootDirectory: URL,
        projectURL: URL?,
        finalizeShare: Double = 0
    ) -> AnalysisRunUnitContext {
        AnalysisRunUnitContext(
            rootDirectory: rootDirectory,
            projectURL: projectURL,
            progress: { fraction, message in
                self.emit(.progress(
                    fraction: Self.runFraction(
                        index: index, count: count, unitFraction: fraction, finalizeShare: finalizeShare
                    ),
                    message: message
                ))
            },
            log: { level, message in self.log(level, message) },
            recordInput: { descriptor in self.recordInput(descriptor) },
            recordStep: { step in self.recordStep(step) },
            recordOptions: { options in self.recordOptions(options) },
            recordDurableReplayArgv: { argv in self.recordDurableReplayArgv(argv) },
            recordFailureDetail: { text in self.recordFailureDetail(text, unit: index) }
        )
    }

    func finalizeContext(
        rootDirectory: URL,
        layout: AnalysisRunLayout,
        projectURL: URL?,
        toolID: AnalysisToolID,
        indexing: (any AnalysisResultIndexing)?,
        finalizeShare: Double = 0
    ) -> AnalysisRunFinalizeContext {
        AnalysisRunFinalizeContext(
            rootDirectory: rootDirectory,
            layout: layout,
            projectURL: projectURL,
            toolID: toolID,
            indexing: indexing,
            finalizeShare: finalizeShare,
            recordedSteps: { self.recordedSteps },
            log: { level, message in self.log(level, message) },
            progress: { fraction, message in self.emit(.progress(fraction: fraction, message: message)) }
        )
    }

    /// A unit's progress on the run's scale, `(index + fraction) / count` of the range the units own,
    /// `1 - finalizeShare` (W3), with the fraction held to 0...1 and a value that is not a number read
    /// as 0.
    static func runFraction(index: Int, count: Int, unitFraction: Double, finalizeShare: Double = 0) -> Double {
        let fraction = unitFraction.isFinite ? min(max(unitFraction, 0), 1) : 0
        return (Double(index) + fraction) / Double(max(count, 1)) * (1 - clampedShare(finalizeShare))
    }

    /// A tool's finalize share held to 0 up to 0.99, and a value that is not a number read as 0.
    static func clampedShare(_ share: Double) -> Double {
        share.isFinite ? min(max(share, 0), 0.99) : 0
    }
}
