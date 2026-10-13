// AnalysisResultIndexing.swift - The viewer index builder a finalize calls in process, keyed by analysis kind (E6)
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishIO
import Synchronization

/// Builds the viewer index of a result in process, such as `kraken2.sqlite` or `esviritu.sqlite`,
/// so a new result never needs a lazy build at first view (E6).
///
/// The executor is given one builder and passes it the analysis kind of each request. The command
/// line conforms over the `build-db` cores, and a builder throws for a kind it does not index.
public protocol AnalysisResultIndexing: Sendable {
    func buildIndex(_ request: AnalysisResultIndexRequest) async throws -> AnalysisResultIndex
}

/// One viewer index to build.
public struct AnalysisResultIndexRequest: Sendable {
    /// The analysis kind, which picks the index.
    public let toolID: AnalysisToolID
    /// The result folder, the batch root when the layout has one.
    public let resultDirectory: URL
    public let layout: AnalysisRunLayout
    /// Files the run's records already name with a digest and a size, such as the outputs of a step
    /// a unit handed to the root record. A builder whose cleanup removes one of them names it with
    /// that descriptor and reads no removed file to hash it (2.8 T5 as amended in 2.9, P1).
    public let recordedFiles: [ProvenanceFileDescriptor]
    private let logHandler: @Sendable (CLIEventLogLevel, String) -> Void
    private let stepRecorder: @Sendable (ProvenanceStep) -> Void

    public init(
        toolID: AnalysisToolID,
        resultDirectory: URL,
        layout: AnalysisRunLayout,
        recordedFiles: [ProvenanceFileDescriptor] = [],
        log: @escaping @Sendable (CLIEventLogLevel, String) -> Void = { _, _ in },
        recordStep: @escaping @Sendable (ProvenanceStep) -> Void = { _ in }
    ) {
        self.toolID = toolID
        self.resultDirectory = resultDirectory
        self.layout = layout
        self.recordedFiles = recordedFiles
        self.logHandler = log
        self.stepRecorder = recordStep
    }

    /// Writes a log line to the run's events. A warning line also becomes one of the run's warnings.
    public func log(_ level: CLIEventLogLevel, _ message: String) {
        logHandler(level, message)
    }

    /// Hands a step of the build to the run's root record as soon as it ends whole, such as the
    /// database build with the digest and size of the database it wrote, so a cancel later in the
    /// finalize keeps it (2.9 R6). The root record uses its descriptors as they are and hashes
    /// nothing again. Hand the steps over in the order they ran, and never one whose outputs are
    /// partial. A step handed over here and also listed in ``AnalysisResultIndex/steps`` is named
    /// once.
    public func recordStep(_ step: ProvenanceStep) {
        stepRecorder(step)
    }
}

/// What an index build wrote, for the root record.
public struct AnalysisResultIndex: Sendable, Equatable {
    /// The index database and any sidecar it wrote, listed as outputs of the root record.
    public var outputs: [AnalysisRunOutput]
    /// The steps of the build in the order they ran, such as the index build itself and a recorded
    /// BAM move. The finalize context records each one the builder did not hand over through
    /// ``AnalysisResultIndexRequest/recordStep(_:)`` once the build returns, so the root record
    /// names every step of the build once.
    public var steps: [ProvenanceStep]
    /// Problems that left the index usable, each a warning of the run.
    public var warnings: [String]

    public init(outputs: [AnalysisRunOutput] = [], steps: [ProvenanceStep] = [], warnings: [String] = []) {
        self.outputs = outputs
        self.steps = steps
        self.warnings = warnings
    }
}

/// The steps of one index build on their way to the root record. Each is recorded once, by its id,
/// whether the builder handed it over as it ended or only listed it in the index it returned.
final class AnalysisResultIndexStepRecorder: Sendable {
    private let recorder: @Sendable (ProvenanceStep) -> Void
    private let recordedIDs = Mutex<Set<UUID>>([])

    init(_ recorder: @escaping @Sendable (ProvenanceStep) -> Void) {
        self.recorder = recorder
    }

    /// Records `step` unless a step with its id was recorded already.
    func record(_ step: ProvenanceStep) {
        guard recordedIDs.withLock({ $0.insert(step.id).inserted }) else { return }
        recorder(step)
    }
}
