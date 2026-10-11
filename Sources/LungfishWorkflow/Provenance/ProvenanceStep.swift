// ProvenanceStep.swift - One tool invocation recorded in a provenance envelope
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishIO

// MARK: - ProvenanceStep

public struct ProvenanceStep: Codable, Sendable, Equatable, Identifiable {
    public let id: UUID
    public let toolName: String
    public let toolVersion: String
    public let githubReleaseVersion: String?
    public let argv: [String]
    public let durableReplayArgv: [String]?
    public let reproducibleCommand: String
    public let resolvedOptions: [String: ParameterValue]
    public let runtimeIdentity: ProvenanceRuntimeIdentity?
    public let inputs: [ProvenanceFileDescriptor]
    public let outputs: [ProvenanceFileDescriptor]
    public let exitStatus: Int?
    public let wallTimeSeconds: TimeInterval?
    public let peakMemoryBytes: UInt64?
    public let stderr: String?
    public let dependsOn: [UUID]
    public let startedAt: Date?
    public let completedAt: Date?
    /// The id of the step this step ran under, such as the `lungfish-cli` step whose import ran it.
    /// Nil for a step that ran on its own, and in every record written before schema version 2.
    public let parentStepID: UUID?
    /// The managed tool the step ran, by its lock id, when the writer knew it.
    public let managedToolID: ManagedToolID?
    /// What `toolVersion` is known from: a probe's output, a lock pin or a gap. A record holding
    /// evidence this build cannot read keeps the rest of the step and reads it as not recorded.
    public let toolVersionEvidence: ToolVersionEvidence?

    private enum CodingKeys: String, CodingKey {
        case id
        case toolName
        case toolVersion
        case githubReleaseVersion
        case argv
        case command
        case durableReplayArgv
        case reproducibleCommand
        case resolvedOptions
        case runtimeIdentity
        case inputs
        case outputs
        case exitStatus
        case exitCode
        case wallTimeSeconds
        case wallTime
        case peakMemoryBytes
        case stderr
        case dependsOn
        case startedAt
        case completedAt
        case startTime
        case endTime
        case parentStepID
        case managedToolID
        case toolVersionEvidence
    }

    public init(
        id: UUID = UUID(),
        toolName: String,
        toolVersion: String = "unknown",
        githubReleaseVersion: String? = nil,
        argv: [String] = [],
        durableReplayArgv: [String]? = nil,
        reproducibleCommand: String? = nil,
        resolvedOptions: [String: ParameterValue] = [:],
        runtimeIdentity: ProvenanceRuntimeIdentity? = nil,
        inputs: [ProvenanceFileDescriptor] = [],
        outputs: [ProvenanceFileDescriptor] = [],
        exitStatus: Int? = nil,
        wallTimeSeconds: TimeInterval? = nil,
        peakMemoryBytes: UInt64? = nil,
        stderr: String? = nil,
        dependsOn: [UUID] = [],
        startedAt: Date? = nil,
        completedAt: Date? = nil,
        parentStepID: UUID? = nil,
        managedToolID: ManagedToolID? = nil,
        toolVersionEvidence: ToolVersionEvidence? = nil
    ) {
        self.id = id
        self.toolName = ProvenanceName.required(toolName)
        self.toolVersion = ProvenanceVersion.required(toolVersion)
        self.githubReleaseVersion = githubReleaseVersion
        self.argv = argv
        self.durableReplayArgv = durableReplayArgv
        self.reproducibleCommand = reproducibleCommand ?? argv.map(shellEscape).joined(separator: " ")
        self.resolvedOptions = resolvedOptions
        self.runtimeIdentity = runtimeIdentity
        self.inputs = inputs
        self.outputs = outputs
        self.exitStatus = exitStatus
        self.wallTimeSeconds = wallTimeSeconds
        self.peakMemoryBytes = peakMemoryBytes
        self.stderr = stderr
        self.dependsOn = dependsOn
        self.startedAt = startedAt
        self.completedAt = completedAt
        self.parentStepID = parentStepID
        self.managedToolID = managedToolID
        self.toolVersionEvidence = toolVersionEvidence
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        toolName = ProvenanceName.required(try container.decodeIfPresent(String.self, forKey: .toolName))
        toolVersion = ProvenanceVersion.required(try container.decodeIfPresent(String.self, forKey: .toolVersion))
        githubReleaseVersion = try container.decodeIfPresent(String.self, forKey: .githubReleaseVersion)
        argv = try container.decodeIfPresent([String].self, forKey: .argv)
            ?? container.decodeIfPresent([String].self, forKey: .command)
            ?? []
        durableReplayArgv = try container.decodeIfPresent([String].self, forKey: .durableReplayArgv)
        reproducibleCommand = try container.decodeIfPresent(String.self, forKey: .reproducibleCommand)
            ?? argv.map(shellEscape).joined(separator: " ")
        resolvedOptions = try container.decodeIfPresent([String: ParameterValue].self, forKey: .resolvedOptions) ?? [:]
        runtimeIdentity = try container.decodeIfPresent(ProvenanceRuntimeIdentity.self, forKey: .runtimeIdentity)
        inputs = try container.decodeIfPresent([ProvenanceFileDescriptor].self, forKey: .inputs) ?? []
        outputs = try container.decodeIfPresent([ProvenanceFileDescriptor].self, forKey: .outputs) ?? []
        exitStatus = try container.decodeIfPresent(Int.self, forKey: .exitStatus)
            ?? container.decodeIfPresent(Int.self, forKey: .exitCode)
        wallTimeSeconds = try container.decodeIfPresent(TimeInterval.self, forKey: .wallTimeSeconds)
            ?? container.decodeIfPresent(TimeInterval.self, forKey: .wallTime)
        peakMemoryBytes = try container.decodeIfPresent(UInt64.self, forKey: .peakMemoryBytes)
        stderr = try container.decodeIfPresent(String.self, forKey: .stderr)
        dependsOn = try container.decodeIfPresent([UUID].self, forKey: .dependsOn) ?? []
        startedAt = try container.decodeIfPresent(Date.self, forKey: .startedAt)
            ?? container.decodeIfPresent(Date.self, forKey: .startTime)
        completedAt = try container.decodeIfPresent(Date.self, forKey: .completedAt)
            ?? container.decodeIfPresent(Date.self, forKey: .endTime)
        parentStepID = try container.decodeIfPresent(UUID.self, forKey: .parentStepID)
        managedToolID = try container.decodeIfPresent(ManagedToolID.self, forKey: .managedToolID)
        // A later build may record a kind of evidence this one does not know. The step still reads.
        toolVersionEvidence = try? container.decodeIfPresent(ToolVersionEvidence.self, forKey: .toolVersionEvidence)
    }

    /// Writes each fact under its canonical key only (schema version 2). The decoder keeps reading
    /// the version 1 aliases `command`, `exitCode`, `wallTime`, `startTime` and `endTime`.
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(toolName, forKey: .toolName)
        try container.encode(toolVersion, forKey: .toolVersion)
        try container.encodeIfPresent(githubReleaseVersion, forKey: .githubReleaseVersion)
        try container.encode(argv, forKey: .argv)
        try container.encodeIfPresent(durableReplayArgv, forKey: .durableReplayArgv)
        try container.encode(reproducibleCommand, forKey: .reproducibleCommand)
        try container.encode(resolvedOptions, forKey: .resolvedOptions)
        try container.encodeIfPresent(runtimeIdentity, forKey: .runtimeIdentity)
        try container.encode(inputs, forKey: .inputs)
        try container.encode(outputs, forKey: .outputs)
        try container.encodeIfPresent(exitStatus, forKey: .exitStatus)
        try container.encodeIfPresent(wallTimeSeconds, forKey: .wallTimeSeconds)
        try container.encodeIfPresent(peakMemoryBytes, forKey: .peakMemoryBytes)
        try container.encodeIfPresent(stderr, forKey: .stderr)
        try container.encode(dependsOn, forKey: .dependsOn)
        try container.encodeIfPresent(startedAt, forKey: .startedAt)
        try container.encodeIfPresent(completedAt, forKey: .completedAt)
        try container.encodeIfPresent(parentStepID, forKey: .parentStepID)
        try container.encodeIfPresent(managedToolID, forKey: .managedToolID)
        try container.encodeIfPresent(toolVersionEvidence, forKey: .toolVersionEvidence)
    }

    /// This step with `outputs` in place of its own and every other field kept, the fields schema
    /// version 2 added among them. A site that narrows a step to some of its outputs calls this
    /// instead of rebuilding the step field by field, which drops every field it does not name.
    public func withOutputs(_ outputs: [ProvenanceFileDescriptor]) -> ProvenanceStep {
        ProvenanceStep(
            id: id,
            toolName: toolName,
            toolVersion: toolVersion,
            githubReleaseVersion: githubReleaseVersion,
            argv: argv,
            durableReplayArgv: durableReplayArgv,
            reproducibleCommand: reproducibleCommand,
            resolvedOptions: resolvedOptions,
            runtimeIdentity: runtimeIdentity,
            inputs: inputs,
            outputs: outputs,
            exitStatus: exitStatus,
            wallTimeSeconds: wallTimeSeconds,
            peakMemoryBytes: peakMemoryBytes,
            stderr: stderr,
            dependsOn: dependsOn,
            startedAt: startedAt,
            completedAt: completedAt,
            parentStepID: parentStepID,
            managedToolID: managedToolID,
            toolVersionEvidence: toolVersionEvidence
        )
    }
}
