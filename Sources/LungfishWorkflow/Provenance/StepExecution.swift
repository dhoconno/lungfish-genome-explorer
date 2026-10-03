// StepExecution.swift - Record of a single tool invocation within a workflow run
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishIO
import LungfishCore

// MARK: - StepExecution

/// Record of a single tool invocation within a workflow run.
///
/// Each `StepExecution` captures the exact command, tool version,
/// container image digest, and input/output file checksums needed
/// to reproduce that step.
public struct StepExecution: Codable, Sendable, Identifiable, Equatable {
    /// Unique identifier for this step.
    public let id: UUID

    /// Tool name (e.g., "samtools", "bcftools", "fastp").
    public let toolName: String

    /// Tool version string (e.g., "1.21").
    public let toolVersion: String

    /// Human-friendly GitHub release tag for GitHub-hosted workflows/tools, when known.
    public let githubReleaseVersion: String?

    /// Container image reference, if the tool ran in a container.
    public let containerImage: String?

    /// Immutable SHA256 digest of the container image used.
    public let containerDigest: String?

    /// Full command-line as executed (argv).
    public let command: [String]

    /// Durable argv suitable for replay when execution used temporary materialized paths.
    public let durableReplayArgv: [String]?

    /// Resolved invocation metadata retained by canonical provenance when available.
    public let resolvedOptions: [String: ParameterValue]?

    /// Runtime used for this specific tool invocation, when distinct evidence is available.
    public let runtimeIdentity: ProvenanceRuntimeIdentity?

    /// Input files consumed by this step.
    public let inputs: [FileRecord]

    /// Output files produced by this step.
    public var outputs: [FileRecord]

    /// Process exit code.
    public var exitCode: Int32?

    /// Wall-clock execution time in seconds.
    public var wallTime: TimeInterval?

    /// Peak memory usage in bytes (if available).
    public var peakMemoryBytes: UInt64?

    /// Standard error output (truncated to 10 KB for storage).
    public var stderr: String?

    /// IDs of upstream steps this step depends on (DAG edges).
    public let dependsOn: [UUID]

    /// When this step started.
    public let startTime: Date

    /// When this step completed.
    public var endTime: Date?

    public init(
        id: UUID = UUID(),
        toolName: String,
        toolVersion: String,
        githubReleaseVersion: String? = nil,
        containerImage: String? = nil,
        containerDigest: String? = nil,
        command: [String],
        durableReplayArgv: [String]? = nil,
        resolvedOptions: [String: ParameterValue]? = nil,
        runtimeIdentity: ProvenanceRuntimeIdentity? = nil,
        inputs: [FileRecord],
        outputs: [FileRecord] = [],
        exitCode: Int32? = nil,
        wallTime: TimeInterval? = nil,
        peakMemoryBytes: UInt64? = nil,
        stderr: String? = nil,
        dependsOn: [UUID] = [],
        startTime: Date = Date(),
        endTime: Date? = nil
    ) {
        self.id = id
        self.toolName = toolName
        self.toolVersion = toolVersion
        self.githubReleaseVersion = githubReleaseVersion
        self.containerImage = containerImage
        self.containerDigest = containerDigest
        self.command = command
        self.durableReplayArgv = durableReplayArgv
        self.resolvedOptions = resolvedOptions
        self.runtimeIdentity = runtimeIdentity
        self.inputs = inputs
        self.outputs = outputs
        self.exitCode = exitCode
        self.wallTime = wallTime
        self.peakMemoryBytes = peakMemoryBytes
        self.stderr = stderr
        self.dependsOn = dependsOn
        self.startTime = startTime
        self.endTime = endTime
    }

    /// Whether this step succeeded.
    public var isSuccess: Bool { exitCode == 0 }

    /// The command as a single shell-escaped string.
    public var commandString: String {
        command.map { shellEscape($0) }.joined(separator: " ")
    }
}
