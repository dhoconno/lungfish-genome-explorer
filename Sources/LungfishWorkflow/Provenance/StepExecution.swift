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

    /// The step this step ran under, when a writer recorded it as part of another step, such as the
    /// `lungfish-cli` step whose import ran it (plan decision S6). Nil for a step that ran on its own.
    public var parentStepID: UUID?

    /// The managed tool the step ran, by its lock id, when the writer knew it.
    public var managedToolID: ManagedToolID?

    /// What `toolVersion` is known from: a probe's output, a lock pin or a gap.
    public var toolVersionEvidence: ToolVersionEvidence?

    /// True when LGE read the step's standard output in the app and kept no file of it, as for the
    /// `samtools coverage` and `samtools view` passes of a mapping summary. Nil for every other step and
    /// in every record written before 2.13. Never written as false.
    public var stdoutReadInProcess: Bool?

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
        parentStepID: UUID? = nil,
        managedToolID: ManagedToolID? = nil,
        toolVersionEvidence: ToolVersionEvidence? = nil,
        stdoutReadInProcess: Bool? = nil,
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
        self.parentStepID = parentStepID
        self.managedToolID = managedToolID
        self.toolVersionEvidence = toolVersionEvidence
        self.stdoutReadInProcess = stdoutReadInProcess
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
