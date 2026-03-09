// ProvenanceRecord.swift - Provenance data model for reproducibility tracking
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation

// MARK: - WorkflowRun

/// A complete record of a multi-step workflow execution.
///
/// `WorkflowRun` captures everything needed to reproduce an analysis:
/// tool versions, container digests, exact commands, input/output checksums,
/// and the dependency DAG between steps. It serves as the source of truth
/// from which Nextflow, Snakemake, shell, and Python scripts are generated.
public struct WorkflowRun: Codable, Sendable, Identifiable {
    /// Unique identifier for this run.
    public let id: UUID

    /// Human-readable name (e.g., "VCF Import", "SPAdes Assembly").
    public let name: String

    /// When the run started.
    public let startTime: Date

    /// When the run completed (nil if still running or failed).
    public var endTime: Date?

    /// Final status of the run.
    public var status: RunStatus

    /// Lungfish app version that performed this run.
    public let appVersion: String

    /// Host OS description (e.g., "macOS 26.1 (arm64)").
    public let hostOS: String

    /// Ordered list of execution steps.
    public var steps: [StepExecution]

    /// Top-level parameters the user configured (workflow-level, not per-step).
    public var parameters: [String: ParameterValue]

    public init(
        id: UUID = UUID(),
        name: String,
        startTime: Date = Date(),
        endTime: Date? = nil,
        status: RunStatus = .running,
        appVersion: String = Self.currentAppVersion,
        hostOS: String = Self.currentHostOS,
        steps: [StepExecution] = [],
        parameters: [String: ParameterValue] = [:]
    ) {
        self.id = id
        self.name = name
        self.startTime = startTime
        self.endTime = endTime
        self.status = status
        self.appVersion = appVersion
        self.hostOS = hostOS
        self.steps = steps
        self.parameters = parameters
    }

    /// Total wall-clock time for the entire run.
    public var wallTime: TimeInterval? {
        guard let end = endTime else { return nil }
        return end.timeIntervalSince(startTime)
    }

    /// All output files produced by any step in this run.
    public var allOutputFiles: [FileRecord] {
        steps.flatMap(\.outputs)
    }

    /// All input files consumed by the first steps (no upstream dependency).
    public var primaryInputFiles: [FileRecord] {
        let stepsWithNoDeps = steps.filter(\.dependsOn.isEmpty)
        return stepsWithNoDeps.flatMap(\.inputs)
    }

    // MARK: - System Info Helpers

    public static var currentAppVersion: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0"
        return "Lungfish \(version) (\(build))"
    }

    public static var currentHostOS: String {
        let info = ProcessInfo.processInfo
        let os = info.operatingSystemVersion
        #if arch(arm64)
        let arch = "arm64"
        #else
        let arch = "x86_64"
        #endif
        return "macOS \(os.majorVersion).\(os.minorVersion).\(os.patchVersion) (\(arch))"
    }
}

// MARK: - RunStatus

/// Status of a workflow run.
public enum RunStatus: String, Codable, Sendable {
    case running
    case completed
    case failed
    case cancelled
}

// MARK: - StepExecution

/// Record of a single tool invocation within a workflow run.
///
/// Each `StepExecution` captures the exact command, tool version,
/// container image digest, and input/output file checksums needed
/// to reproduce that step.
public struct StepExecution: Codable, Sendable, Identifiable {
    /// Unique identifier for this step.
    public let id: UUID

    /// Tool name (e.g., "samtools", "bcftools", "fastp").
    public let toolName: String

    /// Tool version string (e.g., "1.21").
    public let toolVersion: String

    /// Container image reference, if the tool ran in a container.
    public let containerImage: String?

    /// Immutable SHA256 digest of the container image used.
    public let containerDigest: String?

    /// Full command-line as executed (argv).
    public let command: [String]

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
        containerImage: String? = nil,
        containerDigest: String? = nil,
        command: [String],
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
        self.containerImage = containerImage
        self.containerDigest = containerDigest
        self.command = command
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
        command.map { arg in
            if arg.contains(" ") || arg.contains("\"") || arg.contains("'") ||
               arg.contains("$") || arg.contains("`") || arg.contains("\\") {
                return "'\(arg.replacingOccurrences(of: "'", with: "'\\''"))'"
            }
            return arg
        }.joined(separator: " ")
    }
}

// MARK: - FileRecord

/// Metadata for an input or output file in a provenance record.
public struct FileRecord: Codable, Sendable, Equatable {
    /// Original file path (relative to project root when possible).
    public let path: String

    /// SHA-256 checksum of the file contents.
    public let sha256: String?

    /// File size in bytes.
    public let sizeBytes: UInt64?

    /// File format identifier.
    public let format: FileFormat?

    /// Role of this file in the step.
    public let role: FileRole

    public init(
        path: String,
        sha256: String? = nil,
        sizeBytes: UInt64? = nil,
        format: FileFormat? = nil,
        role: FileRole = .input
    ) {
        self.path = path
        self.sha256 = sha256
        self.sizeBytes = sizeBytes
        self.format = format
        self.role = role
    }

    /// The filename component of the path.
    public var filename: String {
        URL(fileURLWithPath: path).lastPathComponent
    }
}

// MARK: - FileFormat

/// Recognized genomic file formats.
public enum FileFormat: String, Codable, Sendable {
    case fasta
    case fastq
    case bam
    case cram
    case sam
    case vcf
    case bcf
    case gff3
    case bed
    case bigBed
    case bigWig
    case genBank
    case html
    case json
    case text
    case unknown
}

// MARK: - FileRole

/// Role of a file in a workflow step.
public enum FileRole: String, Codable, Sendable {
    case input
    case output
    case reference
    case index
    case log
    case report
}

// Note: Uses ParameterValue from WorkflowParameters.swift for workflow parameters.
