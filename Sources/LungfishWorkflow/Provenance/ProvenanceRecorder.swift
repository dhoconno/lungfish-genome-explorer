// ProvenanceRecorder.swift - Captures and persists workflow provenance
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import os.log
import LungfishCore

private let logger = Logger(subsystem: LogSubsystem.workflow, category: "ProvenanceRecorder")

// MARK: - ProvenanceRecorder

/// Singleton actor that records tool execution provenance.
///
/// Every `NativeToolRunner` invocation calls `recordStep()` to capture
/// the exact command, tool version, inputs, outputs, and timing. Steps
/// are grouped into `WorkflowRun` records, which are persisted as JSON
/// sidecar files alongside output directories.
///
/// ## Usage
///
/// ```swift
/// // Start a new run
/// let runID = await ProvenanceRecorder.shared.beginRun(name: "VCF Import")
///
/// // Record a step
/// await ProvenanceRecorder.shared.recordStep(
///     runID: runID,
///     toolName: "bcftools",
///     toolVersion: "1.21",
///     command: ["bcftools", "view", "-Oz", "input.vcf"],
///     inputs: [FileRecord(path: "input.vcf")],
///     outputs: [FileRecord(path: "output.vcf.gz")],
///     exitCode: 0,
///     wallTime: 12.5
/// )
///
/// // Complete the run
/// await ProvenanceRecorder.shared.completeRun(runID, status: .completed)
///
/// // Persist to disk
/// try await ProvenanceRecorder.shared.save(runID: runID, to: outputDirectory)
/// ```
public actor ProvenanceRecorder {

    // MARK: - Shared Instance

    public static let shared = ProvenanceRecorder()

    // MARK: - Properties

    /// Active and recently completed workflow runs, keyed by run ID.
    private var runs: [UUID: WorkflowRun] = [:]

    /// Clocks timing the runs this recorder began, keyed by run ID. A step's
    /// end and the run's end are read from them, so a wall-clock step cannot
    /// make a run end before it began.
    private var runClocks: [UUID: ProvenanceRunClock] = [:]

    /// Optional signer used after JSON sidecars are written.
    private var signingProvider: (any ProvenanceSigningProvider)?

    public init(signingProvider: (any ProvenanceSigningProvider)? = ProvenanceSigningConfiguration.defaultProvider()) {
        self.signingProvider = signingProvider
    }

    /// Overrides the signing provider for tests or app-managed settings.
    public func setSigningProvider(_ provider: (any ProvenanceSigningProvider)?) {
        signingProvider = provider
    }

    // MARK: - Run Lifecycle

    /// Begins a new workflow run and returns its ID.
    ///
    /// - Parameters:
    ///   - name: Human-readable name for the run
    ///   - parameters: Top-level workflow parameters
    /// - Returns: The run ID for use in subsequent `recordStep` calls
    public func beginRun(
        name: String,
        parameters: [String: ParameterValue] = [:]
    ) -> UUID {
        let runClock = ProvenanceRunClock()
        let run = WorkflowRun(name: name, startTime: runClock.startedAt, parameters: parameters)
        runs[run.id] = run
        runClocks[run.id] = runClock
        logger.info("Provenance: began run '\(name)' [\(run.id)]")
        return run.id
    }

    /// Records a completed step execution in the given run.
    ///
    /// - Parameters:
    ///   - runID: The run this step belongs to (from `beginRun`)
    ///   - toolName: Name of the tool (e.g., "samtools")
    ///   - toolVersion: Version string
    ///   - githubReleaseVersion: Human-friendly GitHub release tag, when known
    ///   - containerImage: OCI image reference, if containerized
    ///   - containerDigest: SHA256 digest of the image
    ///   - command: Full argv as executed
    ///   - durableReplayArgv: Durable argv suitable for replay after transient inputs are removed
    ///   - resolvedOptions: Resolved invocation options used by the step
    ///   - runtimeIdentity: Managed/native runtime identity for the step
    ///   - inputs: Input file records
    ///   - outputs: Output file records
    ///   - exitCode: Process exit code
    ///   - wallTime: Execution time in seconds
    ///   - peakMemoryBytes: Peak resident memory in bytes, when available
    ///   - stderr: Standard error output (truncated to 10 KB)
    ///   - dependsOn: IDs of upstream steps
    /// - Returns: The step ID
    @discardableResult
    public func recordStep(
        runID: UUID,
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
        outputs: [FileRecord],
        exitCode: Int32,
        wallTime: TimeInterval,
        peakMemoryBytes: UInt64? = nil,
        stderr: String? = nil,
        dependsOn: [UUID] = []
    ) -> UUID? {
        guard runs[runID] != nil else {
            logger.warning("Provenance: no active run \(runID) — step not recorded")
            return nil
        }

        let truncatedStderr = ProvenanceStderr.truncated(stderr)
        let recordedAt = runClocks[runID]?.now ?? Date()

        let step = StepExecution(
            toolName: toolName,
            toolVersion: toolVersion,
            githubReleaseVersion: githubReleaseVersion,
            containerImage: containerImage,
            containerDigest: containerDigest,
            command: command,
            durableReplayArgv: durableReplayArgv,
            resolvedOptions: resolvedOptions,
            runtimeIdentity: runtimeIdentity,
            inputs: inputs,
            outputs: outputs,
            exitCode: exitCode,
            wallTime: wallTime,
            peakMemoryBytes: peakMemoryBytes,
            stderr: truncatedStderr,
            dependsOn: dependsOn,
            startTime: recordedAt,
            endTime: recordedAt
        )

        runs[runID]?.steps.append(step)

        logger.info("Provenance: recorded \(toolName) step in run \(runID) (exit \(exitCode))")
        return step.id
    }

    /// Marks a run as completed, failed, or cancelled.
    public func completeRun(_ runID: UUID, status: RunStatus) {
        guard runs[runID] != nil else { return }
        runs[runID]?.status = status
        runs[runID]?.endTime = runClocks[runID]?.now ?? Date()
        logger.info("Provenance: run \(runID) → \(status.rawValue)")
    }

    // MARK: - Queries

    /// Returns the workflow run with the given ID.
    public func getRun(_ runID: UUID) -> WorkflowRun? {
        runs[runID]
    }

    /// Returns all runs, most recent first.
    public func allRuns() -> [WorkflowRun] {
        runs.values.sorted { $0.startTime > $1.startTime }
    }

    // MARK: - Persistence

    /// Provenance filename written alongside outputs.
    public static let provenanceFilename = ".lungfish-provenance.json"

    /// Saves a run's provenance record as a JSON sidecar file.
    ///
    /// - Parameters:
    ///   - runID: The run to save
    ///   - directory: The output directory to write the sidecar into
    ///   - dropMissingRunLevelFiles: When true, the run-level `files` and
    ///     `outputs` roll-ups drop paths that no longer exist on disk. Steps keep
    ///     their historically true records. Pipelines that delete an intermediate
    ///     they declared (for example the Kraken2 raw output, which is gzipped
    ///     and then removed) opt in so the envelope never advertises a file the
    ///     reader cannot open.
    public func save(
        runID: UUID,
        to directory: URL,
        bundleLayoutRoot: URL? = nil,
        options: ProvenanceOptions? = nil,
        dropMissingRunLevelFiles: Bool = false
    ) throws {
        guard let run = runs[runID] else {
            throw ProvenanceError.runNotFound(runID)
        }
        let canonical = run.canonicalEnvelope()
        var envelope = options.map { canonical.replacingOptions($0) } ?? canonical
        if dropMissingRunLevelFiles {
            envelope = envelope.droppingMissingRunLevelFiles()
        }
        let writer = ProvenanceWriter(signingProvider: signingProvider)
        let url: URL
        if let bundleLayoutRoot {
            url = try writer.write(envelope, to: directory, bundleLayoutRoot: bundleLayoutRoot)
        } else {
            url = try writer.write(envelope, to: directory)
        }
        logger.info("Provenance: saved canonical run \(runID) to \(url.path)")
    }
}

private extension ProvenanceEnvelope {
    func replacingOptions(_ options: ProvenanceOptions) -> ProvenanceEnvelope {
        ProvenanceEnvelope(
            schemaVersion: schemaVersion,
            id: id,
            createdAt: createdAt,
            workflowName: workflowName,
            workflowVersion: workflowVersion,
            toolName: toolName,
            toolVersion: toolVersion,
            githubReleaseVersion: githubReleaseVersion,
            tool: tool,
            argv: argv,
            durableReplayArgv: durableReplayArgv,
            reproducibleCommand: reproducibleCommand,
            options: options,
            runtimeIdentity: runtimeIdentity,
            files: files,
            output: output,
            outputs: outputs,
            steps: steps,
            wallTimeSeconds: wallTimeSeconds,
            exitStatus: exitStatus,
            stderr: stderr,
            signatures: signatures,
            legacyWorkflowRun: legacyRun
        )
    }
}
