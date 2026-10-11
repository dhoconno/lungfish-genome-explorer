// AnalysisRunFinalization.swift - What a tool's finalize hands back for the root record, the source records and the last event
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation

/// What ``AnalysisRunTool/finalize(_:context:)`` wrote and what the rest of the run does with it.
public struct AnalysisRunFinalization: Sendable {
    /// Run-level files the root record lists as outputs, such as the summary, the batch manifest
    /// and the viewer index. The executor hashes each once, when it writes the root record.
    public var outputs: [AnalysisRunOutput]
    /// Run-level steps of the root record, such as the index build, a recorded BAM move or a
    /// cleanup, and for an engine that runs many tools in one process the steps of its trace.
    public var steps: [ProvenanceStep]
    /// Records the executor writes into source bundles after the root record (phase P5), such as
    /// an `analyses-manifest.json` entry.
    public var sourceRecords: [any AnalysisSourceRecord]
    /// Typed artifacts of the `complete` event, beside the result folder and the root record.
    public var artifacts: [CLIEventArtifact]
    /// The message of the `complete` event, such as how many reads were classified. Nil lets the
    /// executor say the run finished.
    public var completionDetail: String?
    /// Warnings the finalize found, such as an index that could not be built. Each becomes a
    /// warning line, and the run still completes.
    public var warnings: [String]

    public init(
        outputs: [AnalysisRunOutput] = [],
        steps: [ProvenanceStep] = [],
        sourceRecords: [any AnalysisSourceRecord] = [],
        artifacts: [CLIEventArtifact] = [],
        completionDetail: String? = nil,
        warnings: [String] = []
    ) {
        self.outputs = outputs
        self.steps = steps
        self.sourceRecords = sourceRecords
        self.artifacts = artifacts
        self.completionDetail = completionDetail
        self.warnings = warnings
    }
}
