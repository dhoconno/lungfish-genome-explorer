// ProvenanceRecorder.swift - Captures and persists workflow provenance
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import os.log
import LungfishCore
import LungfishIO

private let logger = Logger(subsystem: LogSubsystem.workflow, category: "ProvenanceRecorder")

// MARK: - ProvenanceRecorder

/// Actor that records the steps of a multi-step pipeline as one run.
///
/// A pipeline calls `beginRun`, then `recordStep` for each step it takes, then
/// `completeRun`. `save` writes the run to the directory it is given as a
/// canonical `ProvenanceEnvelope` sidecar. `NativeToolRunner` and the other tool
/// runners never call this actor, so a tool run through one leaves no step unless
/// its caller records it.
///
/// Seven callers record through `ProvenanceRecorder.shared` today. In
/// LungfishWorkflow they are `ClassificationPipeline`, `EsVirituPipeline`,
/// `TaxonomyExtractionPipeline`, `TaxTriagePipeline`,
/// `TaxTriageSerialBatchRunner` and `NativeBundleBuilder`. In LungfishCLI it
/// is `FastqDeaconRiboSubcommand`.
///
/// Since sub-phase 2.7 a run's state is the `ProvenanceRunBuilder` value of its
/// record and the `ProvenanceStep` values recorded so far. `save` completes the
/// record through `ProvenanceRunBuilder.completeRecordedRun`, which keeps the
/// rules the recorder's records have always followed.
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
///     outputs: [FileRecord(path: "output.vcf.gz", role: .output)],
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

    /// The runs this recorder began, keyed by run ID.
    private var runs: [UUID: RecordedRun] = [:]

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
        let run = RecordedRun(name: name, parameters: parameters, clock: ProvenanceRunClock())
        runs[run.id] = run
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
    ///   - stderr: Standard error output (the whole lines within the first 2,048 and last 8,192 characters when longer than 10,240)
    ///   - dependsOn: IDs of upstream steps
    ///   - parentStepID: The step this one ran under, such as the CLI step whose import ran it
    ///   - managedToolID: The managed tool the step ran, by its lock id, when the caller knows it
    ///   - toolVersionEvidence: What `toolVersion` is known from, when the caller knows it
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
        dependsOn: [UUID] = [],
        parentStepID: UUID? = nil,
        managedToolID: ManagedToolID? = nil,
        toolVersionEvidence: ToolVersionEvidence? = nil
    ) -> UUID? {
        let stepID = modifyRun(runID) { run -> UUID in
            // Both of the step's times are when it was recorded, read from the run's clock.
            let recordedAt = run.clock.now
            let step = ProvenanceStep(
                toolName: toolName,
                toolVersion: toolVersion,
                githubReleaseVersion: githubReleaseVersion,
                argv: command,
                durableReplayArgv: durableReplayArgv,
                // A step's shell line is what a replay runs, its durable argv when it has one.
                reproducibleCommand: (durableReplayArgv ?? command).map(shellEscape).joined(separator: " "),
                resolvedOptions: resolvedOptions ?? [:],
                runtimeIdentity: runtimeIdentity,
                inputs: inputs.map { ProvenanceFileDescriptor(fileRecord: $0) },
                outputs: outputs.map { ProvenanceFileDescriptor(fileRecord: $0) },
                exitStatus: Int(exitCode),
                wallTimeSeconds: wallTime,
                peakMemoryBytes: peakMemoryBytes,
                stderr: ProvenanceStderr.truncated(stderr),
                dependsOn: dependsOn,
                startedAt: recordedAt,
                completedAt: recordedAt,
                parentStepID: parentStepID,
                managedToolID: managedToolID,
                toolVersionEvidence: toolVersionEvidence
            )
            if run.steps.isEmpty {
                // The first step names the run's tool, and its container is the run's.
                run.builder = run.builder.leadingRecordedStep(
                    step,
                    reportedVersion: toolVersion,
                    fallbackVersion: run.appVersion
                )
                run.containerImage = containerImage
                run.containerDigest = containerDigest
            }
            run.steps.append(step)
            return step.id
        }
        guard let stepID else {
            logger.warning("Provenance: no active run \(runID) — step not recorded")
            return nil
        }
        logger.info("Provenance: recorded \(toolName) step in run \(runID) (exit \(exitCode))")
        return stepID
    }

    /// Marks a run as completed, failed, or cancelled.
    public func completeRun(_ runID: UUID, status: RunStatus) {
        let found = modifyRun(runID) { run in
            run.status = status
            run.endedAt = run.clock.now
        }
        guard found != nil else { return }
        logger.info("Provenance: run \(runID) → \(status.rawValue)")
    }

    // MARK: - Queries

    /// Returns the workflow run with the given ID.
    public func getRun(_ runID: UUID) -> WorkflowRun? {
        runs[runID]?.workflowRun
    }

    /// Returns all runs, most recent first.
    public func allRuns() -> [WorkflowRun] {
        runs.values.map(\.workflowRun).sorted { $0.startTime > $1.startTime }
    }

    // MARK: - Persistence

    /// Provenance filename written alongside outputs.
    public static let provenanceFilename = ".lungfish-provenance.json"

    /// Saves a run's provenance record as a JSON sidecar file.
    ///
    /// - Parameters:
    ///   - runID: The run to save
    ///   - directory: The output directory to write the sidecar into
    ///   - options: The record's explicit, default and resolved options, in place of the
    ///     run's own. The run's parameters are merged into the explicit options, so a
    ///     parameter that only the run carries stays in the record. Kraken2's
    ///     `readSetPlan` is one. The caller's explicit value wins a clash. A parameter the
    ///     caller already records as a default or a resolved default with the same value is
    ///     not copied, because explicit options are what was asked for.
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
        var envelope = canonical
        if let options {
            let onlyInRun = run.parameters.filter { key, value in
                options.defaults[key] != value && options.resolvedDefaults[key] != value
            }
            envelope = canonical.replacingOptions(ProvenanceOptions(
                explicit: options.explicit.merging(onlyInRun) { given, _ in given },
                defaults: options.defaults,
                resolvedDefaults: options.resolvedDefaults
            ))
        }
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

    // MARK: - Run State

    /// Applies `change` to the run `runID` in place and returns what it returns, or returns nil when
    /// the recorder holds no such run.
    func modifyRun<Result>(_ runID: UUID, _ change: (inout RecordedRun) -> Result) -> Result? {
        guard runs[runID] != nil else { return nil }
        return change(&runs[runID]!)
    }
}

// MARK: - RecordedRun

extension ProvenanceRecorder {
    /// One run the recorder gathers: the builder value of its record, the steps recorded so far and
    /// how the run ended.
    struct RecordedRun: Sendable {
        let id: UUID
        /// Times the run, so no step time and no end is earlier than the run's start, even when the
        /// wall clock steps back.
        let clock: ProvenanceRunClock
        /// The app version and operating system the run began under, which its record names.
        let appVersion: String
        let hostOS: String
        /// The run's name and parameters, and from its first recorded step on, that step's tool,
        /// version, argv and durable argv, which the record names as the run's own.
        var builder: ProvenanceRunBuilder
        /// The container the first step ran in, which the record names as the run's.
        var containerImage: String?
        var containerDigest: String?
        var steps: [ProvenanceStep] = []
        var status: RunStatus = .running
        var endedAt: Date?

        init(name: String, parameters: [String: ParameterValue], clock: ProvenanceRunClock) {
            id = UUID()
            self.clock = clock
            appVersion = WorkflowRun.currentAppVersion
            hostOS = WorkflowRun.currentHostOS
            // Until a step is recorded, the run names itself as its tool and the app as its version.
            builder = ProvenanceRunBuilder(
                workflowName: name,
                workflowVersion: ProvenanceVersion.required(appVersion, fallback: WorkflowRun.currentAppVersion),
                toolName: name,
                toolVersion: ProvenanceVersion.required(nil, fallback: appVersion)
            )
            .options(explicit: parameters, defaults: [:], resolved: [:])
        }

        /// The parameters the run began with.
        var parameters: [String: ParameterValue] {
            builder.provenanceOptions.explicit
        }

        /// The record of the run as `save` writes it before the caller's options. The runtime identity
        /// is the writing process's, with the app version, operating system and container of the run.
        func canonicalEnvelope() -> ProvenanceEnvelope {
            builder
                .runtime(ProvenanceRuntimeIdentity(
                    appVersion: appVersion,
                    operatingSystemVersion: hostOS,
                    user: WorkflowRun.currentUser,
                    containerImage: containerImage,
                    containerDigest: containerDigest
                ))
                .completeRecordedRun(
                    id: id,
                    steps: steps,
                    status: status,
                    startedAt: clock.startedAt,
                    endedAt: endedAt
                )
        }

        /// The run as `getRun` and `allRuns` return it. The first step carries the run's container,
        /// and a later step's container is not kept, because no record names it.
        var workflowRun: WorkflowRun {
            WorkflowRun(
                id: id,
                name: builder.workflowName,
                startTime: clock.startedAt,
                endTime: endedAt,
                status: status,
                appVersion: appVersion,
                hostOS: hostOS,
                steps: steps.enumerated().map { index, step in
                    StepExecution(
                        recordedStep: step,
                        containerImage: index == 0 ? containerImage : nil,
                        containerDigest: index == 0 ? containerDigest : nil
                    )
                },
                parameters: parameters
            )
        }
    }
}

private extension StepExecution {
    /// A recorded step as a run's step, for the `WorkflowRun` view of a recorded run.
    init(recordedStep step: ProvenanceStep, containerImage: String?, containerDigest: String?) {
        self.init(
            id: step.id,
            toolName: step.toolName,
            toolVersion: step.toolVersion,
            githubReleaseVersion: step.githubReleaseVersion,
            containerImage: containerImage,
            containerDigest: containerDigest,
            command: step.argv,
            durableReplayArgv: step.durableReplayArgv,
            resolvedOptions: step.resolvedOptions,
            runtimeIdentity: step.runtimeIdentity,
            inputs: step.inputs.map(FileRecord.init(provenanceFile:)),
            outputs: step.outputs.map(FileRecord.init(provenanceFile:)),
            exitCode: step.exitStatus.map { Int32(clamping: $0) },
            wallTime: step.wallTimeSeconds,
            peakMemoryBytes: step.peakMemoryBytes,
            stderr: step.stderr,
            dependsOn: step.dependsOn,
            parentStepID: step.parentStepID,
            managedToolID: step.managedToolID,
            toolVersionEvidence: step.toolVersionEvidence,
            // The recorder stamps every step it records, so both times are always there.
            startTime: step.startedAt ?? Date.distantPast,
            endTime: step.completedAt
        )
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
            status: status,
            legacyWorkflowRun: legacyRun
        )
    }
}
