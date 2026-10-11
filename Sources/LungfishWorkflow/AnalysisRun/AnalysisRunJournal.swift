// AnalysisRunJournal.swift - The run state of one analysis run, its events, warnings and the record entries tools hand over
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishIO
import Synchronization

/// The state of one `AnalysisRunExecutor.execute` call. Each call makes its own and drops it when
/// the call returns, so the executor itself holds no run state (SWIFT X3).
///
/// Tools call in from `ToolProcess` queues, so the state sits behind a lock and every line goes
/// out through the run's event sink, which delivers one line at a time.
final class AnalysisRunJournal: Sendable {
    private struct State {
        var warnings: [String] = []
        var inputs: [ProvenanceFileDescriptor] = []
        var steps: [ProvenanceStep] = []
        /// The root record's options, the plan's with every later contribution merged in.
        var options = AnalysisRunRecordOptions()
    }

    private let events: AnalysisRunEvents
    private let state = Mutex(State())

    init(events: AnalysisRunEvents) {
        self.events = events
    }

    func emit(_ event: CLIEvent, artifacts: [CLIEventArtifact] = []) {
        events.emit(event, artifacts: artifacts)
    }

    /// Writes a log line. A warning line also joins the run's warnings, under the same lock as its
    /// delivery, so the report lists the warnings in the order their lines went out.
    func log(_ level: CLIEventLogLevel, _ message: String) {
        guard level == .warning else {
            events.emit(.log(level: level, message: message))
            return
        }
        state.withLock { state in
            state.warnings.append(message)
            events.emit(.log(level: .warning, message: message))
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
    /// ``AnalysisRunRecordOptions``). The executor records the plan's first.
    func recordOptions(_ options: AnalysisRunRecordOptions) {
        state.withLock { $0.options = $0.options.merging(options) }
    }

    var warnings: [String] {
        state.withLock { $0.warnings }
    }

    var recordedInputs: [ProvenanceFileDescriptor] {
        state.withLock { $0.inputs }
    }

    var recordedSteps: [ProvenanceStep] {
        state.withLock { $0.steps }
    }

    var recordedOptions: AnalysisRunRecordOptions {
        state.withLock { $0.options }
    }

    // MARK: Contexts

    func planningContext(projectURL: URL?) -> AnalysisRunPlanningContext {
        AnalysisRunPlanningContext(projectURL: projectURL, log: { level, message in self.log(level, message) })
    }

    func unitContext(index: Int, count: Int, rootDirectory: URL, projectURL: URL?) -> AnalysisRunUnitContext {
        AnalysisRunUnitContext(
            rootDirectory: rootDirectory,
            projectURL: projectURL,
            progress: { fraction, message in
                self.emit(.progress(
                    fraction: Self.runFraction(index: index, count: count, unitFraction: fraction),
                    message: message
                ))
            },
            log: { level, message in self.log(level, message) },
            recordInput: { descriptor in self.recordInput(descriptor) },
            recordStep: { step in self.recordStep(step) },
            recordOptions: { options in self.recordOptions(options) }
        )
    }

    func finalizeContext(
        rootDirectory: URL,
        layout: AnalysisRunLayout,
        projectURL: URL?,
        toolID: AnalysisToolID,
        indexing: (any AnalysisResultIndexing)?
    ) -> AnalysisRunFinalizeContext {
        AnalysisRunFinalizeContext(
            rootDirectory: rootDirectory,
            layout: layout,
            projectURL: projectURL,
            toolID: toolID,
            indexing: indexing,
            log: { level, message in self.log(level, message) },
            progress: { message in self.emit(.progress(fraction: 1, message: message)) }
        )
    }

    /// A unit's progress on the run's scale, `(index + fraction) / count`, with the fraction held
    /// to 0...1 and a value that is not a number read as 0.
    static func runFraction(index: Int, count: Int, unitFraction: Double) -> Double {
        let fraction = unitFraction.isFinite ? min(max(unitFraction, 0), 1) : 0
        return (Double(index) + fraction) / Double(max(count, 1))
    }
}
