// RecipeStepResult.swift - Per-step statistics for a processing recipe applied during ingestion
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishCore
import os.log

/// Per-step statistics for a processing recipe applied during ingestion.
public struct RecipeStepResult: Codable, Sendable {
    /// Human-readable step name (e.g. "Human read scrub", "Deduplicate").
    public let stepName: String
    /// Tool identifier (e.g. "sra-human-scrubber", "clumpify").
    public let tool: String
    /// Tool version string at time of execution.
    public let toolVersion: String?
    /// Command line used to execute the step (for reproducibility/auditing).
    public let commandLine: String?
    /// Exact argv used to execute the step when available, including the executable as argv[0].
    public let commandArguments: [String]?
    /// Number of reads (or read pairs for interleaved) entering this step.
    public let inputReadCount: Int?
    /// Number of reads (or read pairs) after this step.
    public let outputReadCount: Int?
    /// Wall-clock seconds this step took.
    public let durationSeconds: Double
    /// Additional files emitted by the step and retained with the final bundle.
    public let auxiliaryOutputPaths: [String]
    /// Rewrites from exact execution-time paths to durable replay paths for auxiliary outputs.
    public let auxiliaryCommandPathRewrites: [String: String]
    /// Ordered logical recipe components represented by this physical step.
    public let logicalComponents: [RecipeLogicalComponent]
    /// Primary output files snapshotted at execution time before intermediate cleanup.
    public let executionOutputFiles: [RecipeStepOutputFile]
    /// Actual process exit status, when the process ran and reported one.
    public let exitStatus: Int?
    /// Bounded, normalized stderr captured from the actual process.
    public let stderr: String?
    /// Actual process start timestamp, when captured.
    public let startedAt: Date?
    /// Actual process completion timestamp, when captured.
    public let completedAt: Date?

    private enum CodingKeys: String, CodingKey {
        case stepName
        case tool
        case toolVersion
        case commandLine
        case commandArguments
        case inputReadCount
        case outputReadCount
        case durationSeconds
        case auxiliaryOutputPaths
        case auxiliaryCommandPathRewrites
        case logicalComponents
        case executionOutputFiles
        case exitStatus
        case stderr
        case startedAt
        case completedAt
    }

    private static let maxStderrLength = 10_240
    private static let stderrTruncationMarker = "\n... [truncated]"
    private static let deduplicationComponentID = "fastp-dedup"
    private static let trimmingComponentID = "fastp-trim"
    private static let legacyFusedFastpLabel = "remove pcr duplicates + adapter + quality trim"

    public init(
        stepName: String,
        tool: String,
        toolVersion: String? = nil,
        commandLine: String? = nil,
        commandArguments: [String]? = nil,
        inputReadCount: Int? = nil,
        outputReadCount: Int? = nil,
        durationSeconds: Double,
        auxiliaryOutputPaths: [String] = [],
        auxiliaryCommandPathRewrites: [String: String] = [:],
        logicalComponents: [RecipeLogicalComponent] = [],
        executionOutputFiles: [RecipeStepOutputFile] = [],
        exitStatus: Int? = nil,
        stderr: String? = nil,
        startedAt: Date? = nil,
        completedAt: Date? = nil
    ) {
        self.stepName = stepName
        self.tool = tool
        self.toolVersion = toolVersion
        self.commandLine = commandLine
        self.commandArguments = commandArguments
        self.inputReadCount = inputReadCount
        self.outputReadCount = outputReadCount
        self.durationSeconds = durationSeconds
        self.auxiliaryOutputPaths = auxiliaryOutputPaths
        self.auxiliaryCommandPathRewrites = auxiliaryCommandPathRewrites
        self.logicalComponents = logicalComponents
        self.executionOutputFiles = executionOutputFiles
        self.exitStatus = exitStatus
        self.stderr = Self.normalizedStderr(stderr)
        self.startedAt = startedAt
        self.completedAt = completedAt
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        stepName = try container.decode(String.self, forKey: .stepName)
        tool = try container.decode(String.self, forKey: .tool)
        toolVersion = try container.decodeIfPresent(String.self, forKey: .toolVersion)
        commandLine = try container.decodeIfPresent(String.self, forKey: .commandLine)
        commandArguments = try container.decodeIfPresent([String].self, forKey: .commandArguments)
        inputReadCount = try container.decodeIfPresent(Int.self, forKey: .inputReadCount)
        outputReadCount = try container.decodeIfPresent(Int.self, forKey: .outputReadCount)
        durationSeconds = try container.decode(Double.self, forKey: .durationSeconds)
        auxiliaryOutputPaths = try container.decodeIfPresent([String].self, forKey: .auxiliaryOutputPaths) ?? []
        auxiliaryCommandPathRewrites = try container.decodeIfPresent(
            [String: String].self,
            forKey: .auxiliaryCommandPathRewrites
        ) ?? [:]
        logicalComponents = try container.decodeIfPresent(
            [RecipeLogicalComponent].self,
            forKey: .logicalComponents
        ) ?? []
        executionOutputFiles = try container.decodeIfPresent(
            [RecipeStepOutputFile].self,
            forKey: .executionOutputFiles
        ) ?? []
        exitStatus = try container.decodeIfPresent(Int.self, forKey: .exitStatus)
        stderr = Self.normalizedStderr(try container.decodeIfPresent(String.self, forKey: .stderr))
        startedAt = try container.decodeIfPresent(Date.self, forKey: .startedAt)
        completedAt = try container.decodeIfPresent(Date.self, forKey: .completedAt)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(stepName, forKey: .stepName)
        try container.encode(tool, forKey: .tool)
        try container.encodeIfPresent(toolVersion, forKey: .toolVersion)
        try container.encodeIfPresent(commandLine, forKey: .commandLine)
        try container.encodeIfPresent(commandArguments, forKey: .commandArguments)
        try container.encodeIfPresent(inputReadCount, forKey: .inputReadCount)
        try container.encodeIfPresent(outputReadCount, forKey: .outputReadCount)
        try container.encode(durationSeconds, forKey: .durationSeconds)
        if !auxiliaryOutputPaths.isEmpty {
            try container.encode(auxiliaryOutputPaths, forKey: .auxiliaryOutputPaths)
        }
        if !auxiliaryCommandPathRewrites.isEmpty {
            try container.encode(auxiliaryCommandPathRewrites, forKey: .auxiliaryCommandPathRewrites)
        }
        if !logicalComponents.isEmpty {
            try container.encode(logicalComponents, forKey: .logicalComponents)
        }
        if !executionOutputFiles.isEmpty {
            try container.encode(executionOutputFiles, forKey: .executionOutputFiles)
        }
        try container.encodeIfPresent(exitStatus, forKey: .exitStatus)
        try container.encodeIfPresent(stderr, forKey: .stderr)
        try container.encodeIfPresent(startedAt, forKey: .startedAt)
        try container.encodeIfPresent(completedAt, forKey: .completedAt)
    }

    public func replacingAuxiliaryOutputs(
        paths: [String],
        commandPathRewrites: [String: String]
    ) -> RecipeStepResult {
        RecipeStepResult(
            stepName: stepName,
            tool: tool,
            toolVersion: toolVersion,
            commandLine: commandLine,
            commandArguments: commandArguments,
            inputReadCount: inputReadCount,
            outputReadCount: outputReadCount,
            durationSeconds: durationSeconds,
            auxiliaryOutputPaths: paths,
            auxiliaryCommandPathRewrites: commandPathRewrites,
            logicalComponents: logicalComponents,
            executionOutputFiles: executionOutputFiles,
            exitStatus: exitStatus,
            stderr: stderr,
            startedAt: startedAt,
            completedAt: completedAt
        )
    }

    /// Timestamp-derived wall time when actual execution evidence is available,
    /// otherwise the duration stored by legacy metadata.
    public var effectiveDurationSeconds: Double {
        guard let startedAt, let completedAt else { return durationSeconds }
        return completedAt.timeIntervalSince(startedAt)
    }

    /// Whether this physical step includes a deduplication operation.
    public var didApplyDeduplication: Bool {
        if !logicalComponents.isEmpty {
            return logicalComponentTypeIDs.contains(Self.deduplicationComponentID)
        }

        let name = stepName.lowercased()
        let arguments = commandArguments ?? []
        return name.contains("dedup")
            || name.contains("duplicate")
            || arguments.contains(where: { $0.lowercased() == "--dedup" })
    }

    /// Whether this physical step combines deduplication with trimming or filtering.
    public var didApplyDeduplicationAndTrimmingInCombinedPass: Bool {
        if !logicalComponents.isEmpty {
            return logicalComponentTypeIDs.contains(Self.deduplicationComponentID)
                && logicalComponentTypeIDs.contains(Self.trimmingComponentID)
        }

        let normalizedTool = tool.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let normalizedName = stepName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let hasKnownFusedFastpName = normalizedTool == "fastp"
            && normalizedName == Self.legacyFusedFastpLabel
        let arguments = commandArguments?.map { $0.lowercased() } ?? []
        let hasDedupArgument = arguments.contains("--dedup")
        let trimArgumentPrefixes = [
            "--adapter_sequence",
            "--average_qual",
            "--cut_",
            "--length_required",
            "--qualified_quality_phred",
            "--trim_"
        ]
        let hasTrimArgument = arguments.contains { argument in
            trimArgumentPrefixes.contains { prefix in argument.hasPrefix(prefix) }
        }

        return hasKnownFusedFastpName || (hasDedupArgument && hasTrimArgument)
    }

    private var logicalComponentTypeIDs: Set<String> {
        Set(logicalComponents.map { $0.typeID.lowercased() })
    }

    private static func normalizedStderr(_ stderr: String?) -> String? {
        guard let stderr else { return nil }
        let bounded: String
        if stderr.count > maxStderrLength {
            bounded = String(stderr.prefix(maxStderrLength)) + stderrTruncationMarker
        } else {
            bounded = stderr
        }
        return bounded.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : bounded
    }

    /// Reads removed (positive) or added (negative) by this step.
    public var readsRemoved: Int? {
        guard let i = inputReadCount, let o = outputReadCount else { return nil }
        return i - o
    }
}
