// ProvenanceStep.swift - One tool invocation recorded in a provenance envelope
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishIO

// MARK: - ProvenanceStep

/// One tool invocation. A site that rebuilds a step from another copies it with ``with(_:)`` and sets
/// only what differs, so every field a later schema adds survives the copy. The id, tool name and tool
/// version are fixed once the step is made.
public struct ProvenanceStep: Codable, Sendable, Equatable, Identifiable {
    public let id: UUID
    public let toolName: String
    public let toolVersion: String
    public var githubReleaseVersion: String?
    public var argv: [String]
    public var durableReplayArgv: [String]?
    public var reproducibleCommand: String
    public var resolvedOptions: [String: ParameterValue]
    public var runtimeIdentity: ProvenanceRuntimeIdentity?
    public var inputs: [ProvenanceFileDescriptor]
    public var outputs: [ProvenanceFileDescriptor]
    public var exitStatus: Int?
    public var wallTimeSeconds: TimeInterval?
    public var peakMemoryBytes: UInt64?
    public var stderr: String?
    public var dependsOn: [UUID]
    public var startedAt: Date?
    public var completedAt: Date?
    /// The id of the step this step ran under, such as the `lungfish-cli` step whose import ran it.
    /// Nil for a step that ran on its own, and in every record written before schema version 2.
    public var parentStepID: UUID?
    /// The managed tool the step ran, by its lock id, when the writer knew it.
    public var managedToolID: ManagedToolID?
    /// What `toolVersion` is known from: a probe's output, a lock pin, a source build or a gap. A
    /// record holding evidence this build cannot read keeps the rest of the step and reads it as
    /// not recorded.
    public var toolVersionEvidence: ToolVersionEvidence?
    /// What ToolProcess observed about the step's launch, when the writer declared the step around it:
    /// how it ended, why ToolProcess stopped it, whether its output was complete, the environment its
    /// adapter changed and its place in the run. Nil for a step nobody observed, and a record holding an
    /// observation this build cannot read keeps the rest of the step.
    public var observation: ProvenanceStepObservation?
    /// The record that holds this step whole, written only on a copy whose inputs the record of a BAM or BAM
    /// index of `build-db esviritu` narrowed to the file's lineage. The copy keeps its `id`. Nil on every other
    /// step, and a record holding a narrowing this build cannot read keeps the rest of the step.
    public var narrowedFrom: ProvenanceStepNarrowing?

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
        case observation
        case narrowedFrom
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
        toolVersionEvidence: ToolVersionEvidence? = nil,
        observation: ProvenanceStepObservation? = nil,
        narrowedFrom: ProvenanceStepNarrowing? = nil
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
        self.observation = observation
        self.narrowedFrom = narrowedFrom
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
        // So may an observation in a shape this build does not know. It reads as not observed.
        observation = try? container.decodeIfPresent(ProvenanceStepObservation.self, forKey: .observation)
        // And so may a narrowing. The step reads as one no file's record narrowed.
        narrowedFrom = try? container.decodeIfPresent(ProvenanceStepNarrowing.self, forKey: .narrowedFrom)
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
        try container.encodeIfPresent(observation, forKey: .observation)
        try container.encodeIfPresent(narrowedFrom, forKey: .narrowedFrom)
    }

    /// A copy of this step with `change` applied, keeping every field `change` leaves alone, the fields
    /// schema version 2 added among them. A site that rebuilds a step calls this and sets only what it
    /// changes, never the initializer field by field, which drops every field it does not name.
    public func with(_ change: (inout ProvenanceStep) throws -> Void) rethrows -> ProvenanceStep {
        var copy = self
        try change(&copy)
        return copy
    }

    /// This step with `outputs` in place of its own and every other field kept.
    public func withOutputs(_ outputs: [ProvenanceFileDescriptor]) -> ProvenanceStep {
        with { $0.outputs = outputs }
    }
}
