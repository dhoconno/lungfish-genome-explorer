// AnalysisRunContexts.swift - What the executor hands a tool in each phase of an analysis run
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishIO

/// What ``AnalysisRunTool/plan(_:context:)`` gets in phase P0.
public struct AnalysisRunPlanningContext: Sendable {
    /// The project the result folder will belong to, when it belongs to one.
    public let projectURL: URL?
    private let logHandler: @Sendable (CLIEventLogLevel, String) -> Void

    public init(
        projectURL: URL?,
        log: @escaping @Sendable (CLIEventLogLevel, String) -> Void = { _, _ in }
    ) {
        self.projectURL = projectURL
        self.logHandler = log
    }

    /// Writes a log line to the run's events. A warning line also becomes one of the run's warnings.
    public func log(_ level: CLIEventLogLevel, _ message: String) {
        logHandler(level, message)
    }
}

/// What ``AnalysisRunTool/run(_:context:)`` gets in phase P2.
///
/// Every method may be called from any thread, such as a `ToolProcess` queue.
public struct AnalysisRunUnitContext: Sendable {
    /// The run's result folder, the batch root when the layout has one.
    public let rootDirectory: URL
    /// The project the result folder belongs to, when it belongs to one.
    public let projectURL: URL?
    private let progressHandler: @Sendable (Double, String) -> Void
    private let logHandler: @Sendable (CLIEventLogLevel, String) -> Void
    private let inputRecorder: @Sendable (ProvenanceFileDescriptor) -> Void
    private let stepRecorder: @Sendable (ProvenanceStep) -> Void
    private let optionsRecorder: @Sendable (AnalysisRootRecordOptions) -> Void
    private let replayRecorder: @Sendable ([String]) -> Void
    private let failureDetailRecorder: @Sendable (String) -> Void

    public init(
        rootDirectory: URL,
        projectURL: URL?,
        progress: @escaping @Sendable (Double, String) -> Void = { _, _ in },
        log: @escaping @Sendable (CLIEventLogLevel, String) -> Void = { _, _ in },
        recordInput: @escaping @Sendable (ProvenanceFileDescriptor) -> Void = { _ in },
        recordStep: @escaping @Sendable (ProvenanceStep) -> Void = { _ in },
        recordOptions: @escaping @Sendable (AnalysisRootRecordOptions) -> Void = { _ in },
        recordDurableReplayArgv: @escaping @Sendable ([String]) -> Void = { _ in },
        recordFailureDetail: @escaping @Sendable (String) -> Void = { _ in }
    ) {
        self.rootDirectory = rootDirectory
        self.projectURL = projectURL
        self.progressHandler = progress
        self.logHandler = log
        self.inputRecorder = recordInput
        self.stepRecorder = recordStep
        self.optionsRecorder = recordOptions
        self.replayRecorder = recordDurableReplayArgv
        self.failureDetailRecorder = recordFailureDetail
    }

    /// Reports how far the unit is, `fraction` from 0 to 1. The executor maps it onto the run as
    /// `(index + fraction) / count`.
    public func progress(_ fraction: Double, _ message: String) {
        progressHandler(fraction, message)
    }

    /// Writes a log line to the run's events. A warning line also becomes one of the run's
    /// warnings, so a unit that ends with a warning returns
    /// ``AnalysisUnitOutcome/completedWithWarning(_:reason:)`` instead of logging it too.
    public func log(_ level: CLIEventLogLevel, _ message: String) {
        logHandler(level, message)
    }

    /// Hands the executor the text that says why this unit failed, such as the last lines of its
    /// tool's log, for the `detail` of the run's `failed` line (UX D11). Record it before the unit
    /// returns ``AnalysisUnitOutcome/failed(reason:)`` or throws. The last value recorded wins.
    ///
    /// The executor sends it only when the run fails from its units and this unit is the one that
    /// failed, a run of one unit or a batch whose policy stops at the first failed unit, so the
    /// detail always belongs to the reason in the line's `error`. A cancel, a refused plan, a folder
    /// that could not be prepared, a failed finalize, a completed run and a batch where several
    /// units failed send none. The executor bounds and cleans the text first (the last 20 lines of
    /// at most 400 characters, at most 4 KB, no colour codes or other control characters but tabs)
    /// and writes it into no record.
    public func recordFailureDetail(_ text: String) {
        failureDetailRecorder(text)
    }

    /// Adds an input to the root record, as a descriptor the tool has already taken, such as the
    /// one its materialization step took. A local file needs an absolute path, a SHA-256 and a size.
    ///
    /// The executor never hashes a recorded descriptor again. A cancelled or failed run's record
    /// holds what the units recorded before they stopped, so record a descriptor as soon as it is
    /// taken.
    public func recordInput(_ descriptor: ProvenanceFileDescriptor) {
        inputRecorder(descriptor)
    }

    /// Adds a step to the root record, such as the unit's tool run with the outputs it wrote. Its
    /// descriptors are used as they are, as for ``recordInput(_:)``.
    public func recordStep(_ step: ProvenanceStep) {
        stepRecorder(step)
    }

    /// Adds options to the root record, such as the Bracken resolution the unit settled, the
    /// inputs it materialized or the read-set plan it made from them (E13). The executor merges
    /// them into the plan's options by the rule ``AnalysisRootRecordOptions`` states, as they
    /// arrive, so a failed or cancelled run's record holds what the units recorded before they
    /// stopped. Record them as soon as they are known. In a batch a unit adds only run-level
    /// values, and its own record keeps the facts of its sample.
    public func recordOptions(_ options: AnalysisRootRecordOptions) {
        optionsRecorder(options)
    }

    /// Sets the argv a replay of the run runs, when the unit learned it only while it ran, such as
    /// the command with a virtual bundle replaced by the file the unit materialized from it, which
    /// the result folder keeps (E3). The root record names it in place of the request's
    /// ``AnalysisRunRequest/durableReplayArgv``, also when the run fails or is cancelled after the
    /// unit recorded it. The last value recorded wins.
    public func recordDurableReplayArgv(_ argv: [String]) {
        replayRecorder(argv)
    }
}

/// What ``AnalysisRunTool/finalize(_:context:)`` gets in phase P3.
public struct AnalysisRunFinalizeContext: Sendable {
    /// The run's result folder, the batch root when the layout has one.
    public let rootDirectory: URL
    public let layout: AnalysisRunLayout
    /// The project the result folder belongs to, when it belongs to one.
    public let projectURL: URL?
    public let toolID: AnalysisToolID
    private let indexing: (any AnalysisResultIndexing)?
    private let finalizeShare: Double
    private let logHandler: @Sendable (CLIEventLogLevel, String) -> Void
    private let progressHandler: @Sendable (Double, String) -> Void

    /// `finalizeShare` is the tool's ``AnalysisRunTool/finalizeProgressShare``, and `progress` takes
    /// the fraction of the whole run, from `1 - finalizeShare` to 1.
    public init(
        rootDirectory: URL,
        layout: AnalysisRunLayout,
        projectURL: URL?,
        toolID: AnalysisToolID,
        indexing: (any AnalysisResultIndexing)?,
        finalizeShare: Double = 0,
        log: @escaping @Sendable (CLIEventLogLevel, String) -> Void = { _, _ in },
        progress: @escaping @Sendable (Double, String) -> Void = { _, _ in }
    ) {
        self.rootDirectory = rootDirectory
        self.layout = layout
        self.projectURL = projectURL
        self.toolID = toolID
        self.indexing = indexing
        self.finalizeShare = AnalysisRunJournal.clampedShare(finalizeShare)
        self.logHandler = log
        self.progressHandler = progress
    }

    /// Writes a log line to the run's events. A warning line also becomes one of the run's warnings.
    public func log(_ level: CLIEventLogLevel, _ message: String) {
        logHandler(level, message)
    }

    /// Says what the finalize is doing, at the start of its share of the progress range. A tool with
    /// no share, such as Kraken2, has used the whole range in its units, so the executor reports it at
    /// the end of the range.
    public func progress(_ message: String) {
        progress(0, message)
    }

    /// Reports how far the finalize is, `fraction` from 0 to 1 of its own share of the progress
    /// range. The executor maps it onto the run as `1 - share + share * fraction` (W3), so with no
    /// share every fraction is the end of the range.
    public func progress(_ fraction: Double, _ message: String) {
        let clamped = fraction.isFinite ? min(max(fraction, 0), 1) : 0
        progressHandler(1 - finalizeShare + finalizeShare * clamped, message)
    }

    /// Builds the viewer index of the result in process, through the index builder the executor
    /// was given for this analysis kind (E6). Add the index's outputs and steps to the
    /// finalization so the root record names them.
    ///
    /// - Throws: ``AnalysisRunError/noResultIndexer(_:)`` when the executor has no index builder,
    ///   or the builder's error.
    public func buildIndex() async throws -> AnalysisResultIndex {
        guard let indexing else {
            throw AnalysisRunError.noResultIndexer(toolID)
        }
        let logHandler = logHandler
        return try await indexing.buildIndex(
            AnalysisResultIndexRequest(
                toolID: toolID,
                resultDirectory: rootDirectory,
                layout: layout,
                log: logHandler
            )
        )
    }
}
