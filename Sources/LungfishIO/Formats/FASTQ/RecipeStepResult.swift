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
    /// Stderr captured from the actual process, kept whole up to 10,240
    /// characters and otherwise cut by ``ProvenanceStderr`` to the whole lines
    /// within its first 2,048 and last 8,192 characters when the step is made. A
    /// step read from disk keeps the stderr it holds, because cutting it again
    /// would drop more of a record that an earlier version already cut.
    public let stderr: String?
    /// Actual process start timestamp, when captured.
    public let startedAt: Date?
    /// Actual process completion timestamp, when captured.
    public let completedAt: Date?
    /// Database files the step read, by their identity, before its tool ran.
    public let databases: [RecipeDatabaseRecord]
    /// The switch whose value turned this step off, so that it did not run. Nil for a step that ran and for every
    /// record written before 2026-10-22 (CHTC lane C2-MERGED, QA review point 9).
    public let turnedOffBy: RecipeSwitchSetting?

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
        case databases
        case turnedOffBy
    }

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
        completedAt: Date? = nil,
        databases: [RecipeDatabaseRecord] = [],
        turnedOffBy: RecipeSwitchSetting? = nil
    ) {
        self.init(
            stepName: stepName,
            tool: tool,
            toolVersion: toolVersion,
            commandLine: commandLine,
            commandArguments: commandArguments,
            inputReadCount: inputReadCount,
            outputReadCount: outputReadCount,
            durationSeconds: durationSeconds,
            auxiliaryOutputPaths: auxiliaryOutputPaths,
            auxiliaryCommandPathRewrites: auxiliaryCommandPathRewrites,
            logicalComponents: logicalComponents,
            executionOutputFiles: executionOutputFiles,
            exitStatus: exitStatus,
            keepingStderr: ProvenanceStderr.normalized(stderr),
            startedAt: startedAt,
            completedAt: completedAt,
            databases: databases,
            turnedOffBy: turnedOffBy
        )
    }

    /// Every field as given, with the stderr rule not applied to `keepingStderr`.
    /// A copy of a step that already holds its stderr uses this, so the copy keeps
    /// that stderr whole.
    private init(
        stepName: String,
        tool: String,
        toolVersion: String?,
        commandLine: String?,
        commandArguments: [String]?,
        inputReadCount: Int?,
        outputReadCount: Int?,
        durationSeconds: Double,
        auxiliaryOutputPaths: [String],
        auxiliaryCommandPathRewrites: [String: String],
        logicalComponents: [RecipeLogicalComponent],
        executionOutputFiles: [RecipeStepOutputFile],
        exitStatus: Int?,
        keepingStderr stderr: String?,
        startedAt: Date?,
        completedAt: Date?,
        databases: [RecipeDatabaseRecord],
        turnedOffBy: RecipeSwitchSetting?
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
        self.stderr = stderr
        self.startedAt = startedAt
        self.completedAt = completedAt
        self.databases = databases
        self.turnedOffBy = turnedOffBy
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
        stderr = try container.decodeIfPresent(String.self, forKey: .stderr)
        startedAt = try container.decodeIfPresent(Date.self, forKey: .startedAt)
        completedAt = try container.decodeIfPresent(Date.self, forKey: .completedAt)
        databases = try container.decodeIfPresent([RecipeDatabaseRecord].self, forKey: .databases) ?? []
        turnedOffBy = try container.decodeIfPresent(RecipeSwitchSetting.self, forKey: .turnedOffBy)
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
        if !databases.isEmpty {
            try container.encode(databases, forKey: .databases)
        }
        try container.encodeIfPresent(turnedOffBy, forKey: .turnedOffBy)
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
            keepingStderr: stderr,
            startedAt: startedAt,
            completedAt: completedAt,
            databases: databases,
            turnedOffBy: turnedOffBy
        )
    }

    /// Timestamp-derived wall time when actual execution evidence is available,
    /// otherwise the duration stored by legacy metadata.
    public var effectiveDurationSeconds: Double {
        guard let startedAt, let completedAt else { return durationSeconds }
        return completedAt.timeIntervalSince(startedAt)
    }

    /// The result of a step that a switch turned off: it names the switch, ran no tool and took no time.
    public static func turnedOff(stepName: String, by setting: RecipeSwitchSetting) -> RecipeStepResult {
        RecipeStepResult(stepName: stepName, tool: "none", durationSeconds: 0, turnedOffBy: setting)
    }

    /// Whether the step ran, false for a step a switch turned off.
    public var didRun: Bool { turnedOffBy == nil }

    /// Whether this physical step includes a deduplication operation. A step a switch turned off never does, whatever
    /// its name says.
    public var didApplyDeduplication: Bool {
        guard didRun else { return false }
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
        guard didRun else { return false }
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

    /// Reads removed (positive) or added (negative) by this step.
    public var readsRemoved: Int? {
        guard let i = inputReadCount, let o = outputReadCount else { return nil }
        return i - o
    }
}
