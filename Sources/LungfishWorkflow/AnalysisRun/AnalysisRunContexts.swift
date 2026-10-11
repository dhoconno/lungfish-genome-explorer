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

    public init(
        rootDirectory: URL,
        projectURL: URL?,
        progress: @escaping @Sendable (Double, String) -> Void = { _, _ in },
        log: @escaping @Sendable (CLIEventLogLevel, String) -> Void = { _, _ in },
        recordInput: @escaping @Sendable (ProvenanceFileDescriptor) -> Void = { _ in },
        recordStep: @escaping @Sendable (ProvenanceStep) -> Void = { _ in },
        recordOptions: @escaping @Sendable (AnalysisRootRecordOptions) -> Void = { _ in }
    ) {
        self.rootDirectory = rootDirectory
        self.projectURL = projectURL
        self.progressHandler = progress
        self.logHandler = log
        self.inputRecorder = recordInput
        self.stepRecorder = recordStep
        self.optionsRecorder = recordOptions
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
    private let logHandler: @Sendable (CLIEventLogLevel, String) -> Void
    private let progressHandler: @Sendable (String) -> Void

    public init(
        rootDirectory: URL,
        layout: AnalysisRunLayout,
        projectURL: URL?,
        toolID: AnalysisToolID,
        indexing: (any AnalysisResultIndexing)?,
        log: @escaping @Sendable (CLIEventLogLevel, String) -> Void = { _, _ in },
        progress: @escaping @Sendable (String) -> Void = { _ in }
    ) {
        self.rootDirectory = rootDirectory
        self.layout = layout
        self.projectURL = projectURL
        self.toolID = toolID
        self.indexing = indexing
        self.logHandler = log
        self.progressHandler = progress
    }

    /// Writes a log line to the run's events. A warning line also becomes one of the run's warnings.
    public func log(_ level: CLIEventLogLevel, _ message: String) {
        logHandler(level, message)
    }

    /// Says what the finalize is doing. The units have used the whole progress range, so the
    /// executor reports it at the end of the range.
    public func progress(_ message: String) {
        progressHandler(message)
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
