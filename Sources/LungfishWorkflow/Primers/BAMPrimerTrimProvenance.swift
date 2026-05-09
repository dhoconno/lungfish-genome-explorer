// BAMPrimerTrimProvenance.swift - JSON sidecar describing a BAM primer-trim run
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation

/// Provenance record describing a single BAM primer-trim run.
///
/// Written as a JSON sidecar next to the trimmed BAM by
/// `BAMPrimerTrimPipeline`, using snake_case wire keys so the file is readable
/// from non-Swift tooling. Round-trips losslessly through `JSONEncoder` and
/// `JSONDecoder` when both use `.iso8601` date handling.
public struct BAMPrimerTrimProvenance: Codable, Sendable, Equatable {
    /// Short operation identifier, e.g. `"primer-trim"`.
    public let operation: String

    /// Reference to the primer scheme used for this run.
    public let primerScheme: PrimerSchemeRef

    /// Project-relative path to the source BAM that was trimmed.
    public let sourceBAMRelativePath: String

    /// Version string reported by the invoked `ivar` binary.
    public let ivarVersion: String

    /// Literal argument list passed to `ivar trim` (excluding the program name).
    public let ivarTrimArgs: [String]

    /// Wall-clock timestamp at which the pipeline wrote this record.
    public let timestamp: Date

    /// Provenance schema version. Version 2 includes file records and step traces.
    public let schemaVersion: Int

    /// User-visible workflow name.
    public let workflowName: String

    /// Lungfish version that produced the workflow output.
    public let workflowVersion: String

    /// Reproducible top-level command or workflow invocation.
    public let command: [String]

    /// Resolved user-visible options, including defaults.
    public let resolvedOptions: [String: String]

    /// Input files consumed by the primer-trim workflow.
    public let inputFiles: [FileRecord]

    /// Final output files produced by the primer-trim workflow.
    public let outputFiles: [FileRecord]

    /// Runtime identity for managed or bundled native tools.
    public let runtimeIdentity: [String: String]

    /// Ordered native tool invocations used to create the trimmed BAM.
    public let steps: [StepExecution]

    /// Total workflow wall time in seconds.
    public let wallTimeSeconds: TimeInterval?

    /// Workflow exit status; zero means the output sidecar describes a successful run.
    public let exitStatus: Int32?

    /// Captured stderr from successful steps when useful.
    public let stderr: String?

    /// Minimal reference to the primer scheme whose BED drove the trim.
    public struct PrimerSchemeRef: Codable, Sendable, Equatable {
        /// Human-readable bundle name (manifest `name`).
        public let bundleName: String

        /// Origin of the bundle (e.g. `"built-in"`, `"imported"`).
        public let bundleSource: String

        /// Bundle version string if declared; `nil` when the manifest omits it.
        public let bundleVersion: String?

        /// Canonical reference accession the primer coordinates were authored against.
        public let canonicalAccession: String

        enum CodingKeys: String, CodingKey {
            case bundleName = "bundle_name"
            case bundleSource = "bundle_source"
            case bundleVersion = "bundle_version"
            case canonicalAccession = "canonical_accession"
        }
    }

    enum CodingKeys: String, CodingKey {
        case operation
        case primerScheme = "primer_scheme"
        case sourceBAMRelativePath = "source_bam"
        case ivarVersion = "ivar_version"
        case ivarTrimArgs = "ivar_trim_args"
        case timestamp
        case schemaVersion = "schema_version"
        case workflowName = "workflow_name"
        case workflowVersion = "workflow_version"
        case command
        case resolvedOptions = "resolved_options"
        case inputFiles = "input_files"
        case outputFiles = "output_files"
        case runtimeIdentity = "runtime_identity"
        case steps
        case wallTimeSeconds = "wall_time_seconds"
        case exitStatus = "exit_status"
        case stderr
    }

    /// Creates a provenance record from the pipeline's observed values.
    /// - Parameters:
    ///   - operation: Short operation identifier, e.g. `"primer-trim"`.
    ///   - primerScheme: Minimal reference to the primer scheme used.
    ///   - sourceBAMRelativePath: Project-relative path to the source BAM.
    ///   - ivarVersion: Version string reported by `ivar`.
    ///   - ivarTrimArgs: Literal argument list passed to `ivar trim`.
    ///   - timestamp: Wall-clock timestamp for the run.
    public init(
        operation: String,
        primerScheme: PrimerSchemeRef,
        sourceBAMRelativePath: String,
        ivarVersion: String,
        ivarTrimArgs: [String],
        timestamp: Date,
        schemaVersion: Int = 2,
        workflowName: String = "lungfish bam primer-trim",
        workflowVersion: String = WorkflowRun.currentAppVersion,
        command: [String] = [],
        resolvedOptions: [String: String] = [:],
        inputFiles: [FileRecord] = [],
        outputFiles: [FileRecord] = [],
        runtimeIdentity: [String: String] = [:],
        steps: [StepExecution] = [],
        wallTimeSeconds: TimeInterval? = nil,
        exitStatus: Int32? = nil,
        stderr: String? = nil
    ) {
        self.operation = operation
        self.primerScheme = primerScheme
        self.sourceBAMRelativePath = sourceBAMRelativePath
        self.ivarVersion = ivarVersion
        self.ivarTrimArgs = ivarTrimArgs
        self.timestamp = timestamp
        self.schemaVersion = schemaVersion
        self.workflowName = workflowName
        self.workflowVersion = workflowVersion
        self.command = command
        self.resolvedOptions = resolvedOptions
        self.inputFiles = inputFiles
        self.outputFiles = outputFiles
        self.runtimeIdentity = runtimeIdentity
        self.steps = steps
        self.wallTimeSeconds = wallTimeSeconds
        self.exitStatus = exitStatus
        self.stderr = stderr
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        operation = try container.decode(String.self, forKey: .operation)
        primerScheme = try container.decode(PrimerSchemeRef.self, forKey: .primerScheme)
        sourceBAMRelativePath = try container.decode(String.self, forKey: .sourceBAMRelativePath)
        ivarVersion = try container.decode(String.self, forKey: .ivarVersion)
        ivarTrimArgs = try container.decode([String].self, forKey: .ivarTrimArgs)
        timestamp = try container.decode(Date.self, forKey: .timestamp)
        schemaVersion = try container.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        workflowName = try container.decodeIfPresent(String.self, forKey: .workflowName) ?? "lungfish bam primer-trim"
        workflowVersion = try container.decodeIfPresent(String.self, forKey: .workflowVersion) ?? "unknown"
        command = try container.decodeIfPresent([String].self, forKey: .command) ?? []
        resolvedOptions = try container.decodeIfPresent([String: String].self, forKey: .resolvedOptions) ?? [:]
        inputFiles = try container.decodeIfPresent([FileRecord].self, forKey: .inputFiles) ?? []
        outputFiles = try container.decodeIfPresent([FileRecord].self, forKey: .outputFiles) ?? []
        runtimeIdentity = try container.decodeIfPresent([String: String].self, forKey: .runtimeIdentity) ?? [:]
        steps = try container.decodeIfPresent([StepExecution].self, forKey: .steps) ?? []
        wallTimeSeconds = try container.decodeIfPresent(TimeInterval.self, forKey: .wallTimeSeconds)
        exitStatus = try container.decodeIfPresent(Int32.self, forKey: .exitStatus)
        stderr = try container.decodeIfPresent(String.self, forKey: .stderr)
    }

    /// Returns a copy whose top-level outputs point at the final stored BAM/BAI.
    public func relocatingFinalOutputs(outputBAMURL: URL, outputBAMIndexURL: URL) -> BAMPrimerTrimProvenance {
        let existingBAM = outputFiles.first { $0.role == .output && $0.format == .bam }
        let existingIndex = outputFiles.first { $0.role == .index }
        let finalOutputs = [
            relocatedFileRecord(
                url: outputBAMURL,
                format: .bam,
                role: .output,
                preserving: existingBAM
            ),
            relocatedFileRecord(
                url: outputBAMIndexURL,
                format: existingIndex?.format,
                role: .index,
                preserving: existingIndex
            )
        ]
        return BAMPrimerTrimProvenance(
            operation: operation,
            primerScheme: primerScheme,
            sourceBAMRelativePath: sourceBAMRelativePath,
            ivarVersion: ivarVersion,
            ivarTrimArgs: ivarTrimArgs,
            timestamp: timestamp,
            schemaVersion: schemaVersion,
            workflowName: workflowName,
            workflowVersion: workflowVersion,
            command: command,
            resolvedOptions: resolvedOptions,
            inputFiles: inputFiles,
            outputFiles: finalOutputs,
            runtimeIdentity: runtimeIdentity,
            steps: steps,
            wallTimeSeconds: wallTimeSeconds,
            exitStatus: exitStatus,
            stderr: stderr
        )
    }

    private func relocatedFileRecord(
        url: URL,
        format: FileFormat?,
        role: FileRole,
        preserving existing: FileRecord?
    ) -> FileRecord {
        let computed = ProvenanceRecorder.fileRecord(url: url, format: format, role: role)
        guard computed.sha256 == nil, computed.sizeBytes == nil, let existing else {
            return computed
        }
        return FileRecord(
            path: computed.path,
            sha256: existing.sha256,
            sizeBytes: existing.sizeBytes,
            format: computed.format ?? existing.format,
            role: computed.role
        )
    }
}
