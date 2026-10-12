// AnalysisResultIndexing.swift - The viewer index builder a finalize calls in process, keyed by analysis kind (E6)
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishIO

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

    public init(
        toolID: AnalysisToolID,
        resultDirectory: URL,
        layout: AnalysisRunLayout,
        recordedFiles: [ProvenanceFileDescriptor] = [],
        log: @escaping @Sendable (CLIEventLogLevel, String) -> Void = { _, _ in }
    ) {
        self.toolID = toolID
        self.resultDirectory = resultDirectory
        self.layout = layout
        self.recordedFiles = recordedFiles
        self.logHandler = log
    }

    /// Writes a log line to the run's events. A warning line also becomes one of the run's warnings.
    public func log(_ level: CLIEventLogLevel, _ message: String) {
        logHandler(level, message)
    }
}

/// What an index build wrote, for the root record.
public struct AnalysisResultIndex: Sendable, Equatable {
    /// The index database and any sidecar it wrote, listed as outputs of the root record.
    public var outputs: [AnalysisRunOutput]
    /// The steps of the build, such as the index build itself and a recorded BAM move.
    public var steps: [ProvenanceStep]
    /// Problems that left the index usable, each a warning of the run.
    public var warnings: [String]

    public init(outputs: [AnalysisRunOutput] = [], steps: [ProvenanceStep] = [], warnings: [String] = []) {
        self.outputs = outputs
        self.steps = steps
        self.warnings = warnings
    }
}
