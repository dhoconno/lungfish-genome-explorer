// ProvenanceStep.swift - One tool invocation recorded in a provenance envelope
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation

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
        completedAt: Date? = nil
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
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(toolName, forKey: .toolName)
        try container.encode(toolVersion, forKey: .toolVersion)
        try container.encodeIfPresent(githubReleaseVersion, forKey: .githubReleaseVersion)
        try container.encode(argv, forKey: .argv)
        try container.encode(argv, forKey: .command)
        try container.encodeIfPresent(durableReplayArgv, forKey: .durableReplayArgv)
        try container.encode(reproducibleCommand, forKey: .reproducibleCommand)
        try container.encode(resolvedOptions, forKey: .resolvedOptions)
        try container.encodeIfPresent(runtimeIdentity, forKey: .runtimeIdentity)
        try container.encode(inputs, forKey: .inputs)
        try container.encode(outputs, forKey: .outputs)
        try container.encodeIfPresent(exitStatus, forKey: .exitStatus)
        try container.encodeIfPresent(exitStatus, forKey: .exitCode)
        try container.encodeIfPresent(wallTimeSeconds, forKey: .wallTimeSeconds)
        try container.encodeIfPresent(wallTimeSeconds, forKey: .wallTime)
        try container.encodeIfPresent(peakMemoryBytes, forKey: .peakMemoryBytes)
        try container.encodeIfPresent(stderr, forKey: .stderr)
        try container.encode(dependsOn, forKey: .dependsOn)
        try container.encodeIfPresent(startedAt, forKey: .startedAt)
        try container.encodeIfPresent(completedAt, forKey: .completedAt)
        try container.encodeIfPresent(startedAt, forKey: .startTime)
        try container.encodeIfPresent(completedAt, forKey: .endTime)
    }
}
