// ClassificationPipeline.swift - Kraken2 classification and Bracken profiling orchestrator
// Copyright (c) 2025 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishCore
import LungfishIO
import os.log

private let logger = Logger(subsystem: LogSubsystem.workflow, category: "ClassificationPipeline")

// MARK: - ClassificationPipelineError

/// Errors produced during classification pipeline execution.
public enum ClassificationPipelineError: Error, LocalizedError, Sendable {

    /// Kraken2 exited with a non-zero status.
    case kraken2Failed(exitCode: Int32, stderr: String)

    /// Bracken exited with a non-zero status.
    case brackenFailed(exitCode: Int32, stderr: String)

    /// The kraken2 tool is not installed in the conda environment.
    case kraken2NotInstalled

    /// The bracken tool is not installed in the conda environment.
    case brackenNotInstalled

    /// The kreport output file was not produced by kraken2.
    case kreportNotProduced(URL)

    /// The result sidecar could not be persisted.
    case resultSidecarSaveFailed(URL, String)

    /// Could not determine the kraken2 version.
    case versionDetectionFailed

    /// The pipeline was cancelled.
    case cancelled

    public var errorDescription: String? {
        switch self {
        case .kraken2Failed(let code, let stderr):
            return "kraken2 failed with exit code \(code): \(stderr)"
        case .brackenFailed(let code, let stderr):
            return "bracken failed with exit code \(code): \(stderr)"
        case .kraken2NotInstalled:
            return "kraken2 is not installed. Run: lungfish conda install --pack metagenomics"
        case .brackenNotInstalled:
            return "bracken is not installed. Run: lungfish conda install --pack metagenomics"
        case .kreportNotProduced(let url):
            return "kraken2 did not produce a report file at \(url.path)"
        case .resultSidecarSaveFailed(let url, let reason):
            return "Failed to save classification result sidecar at \(url.path): \(reason)"
        case .versionDetectionFailed:
            return "Could not determine kraken2 version"
        case .cancelled:
            return "Classification pipeline was cancelled"
        }
    }
}

struct ClassificationOutputSetupFailure: Error, LocalizedError, Sendable {
    let outputDirectoryCreationError: ClassificationConfigError
    let provenanceSaveErrorDescription: String

    var errorDescription: String? {
        let creationErrorDescription: String
        switch outputDirectoryCreationError {
        case .outputDirectoryCreationFailed(_, let error):
            creationErrorDescription = error.localizedDescription
        default:
            creationErrorDescription = outputDirectoryCreationError.localizedDescription
        }
        return "\(creationErrorDescription); additionally failed to save failed-run provenance: \(provenanceSaveErrorDescription)"
    }
}

// MARK: - ClassificationPipeline

/// Actor that orchestrates Kraken2 classification and optional Bracken profiling.
///
/// The pipeline performs these steps:
///
/// 1. **Validate** the configuration (database exists, input files present).
/// 2. **Auto-enable memory mapping** if the database exceeds 80% of system RAM.
/// 3. **Detect** kraken2 and bracken versions for provenance recording.
/// 4. **Run kraken2** with the configured arguments.
/// 5. **Parse** the kreport output into a ``TaxonTree``.
/// 6. **(Optional) Run Bracken** to re-estimate abundances.
/// 7. **Record provenance** via ``ProvenanceRecorder``.
///
/// ## Progress
///
/// Progress is reported via a `@Sendable (Double, String) -> Void` callback:
///
/// | Range      | Phase |
/// |-----------|-------|
/// | 0.0 -- 0.10 | Validation and setup |
/// | 0.10 -- 0.30 | Version detection |
/// | 0.30 -- 0.80 | Kraken2 execution |
/// | 0.80 -- 0.90 | Report parsing |
/// | 0.90 -- 0.95 | Bracken execution (if profiling) |
/// | 0.95 -- 1.00 | Provenance recording and cleanup |
///
/// ## Conda Environment
///
/// The pipeline expects kraken2 and bracken to be installed in conda
/// environments named `kraken2` and `bracken` respectively (matching the
/// metagenomics plugin pack layout).
///
/// ## Usage
///
/// ```swift
/// let pipeline = ClassificationPipeline()
/// let config = ClassificationConfig.fromPreset(
///     .balanced,
///     inputFiles: [fastqURL],
///     isPairedEnd: false,
///     databaseName: "Viral",
///     databasePath: viralDBPath,
///     outputDirectory: outputDir
/// )
/// let result = try await pipeline.classify(config: config) { progress, message in
///     print("\(Int(progress * 100))% \(message)")
/// }
/// ```
public actor ClassificationPipeline {

    /// The conda environment name where kraken2 is installed.
    public static let kraken2Environment = "kraken2"

    /// The conda environment name where bracken is installed.
    public static let brackenEnvironment = "bracken"

    /// Human-readable GitHub release tag for the pinned Kraken2 package.
    public static let kraken2GithubReleaseVersion = "v2.17.1"

    /// Shared instance for convenience.
    public static let shared = ClassificationPipeline()

    /// The conda manager used for tool execution.
    private let condaManager: CondaManager

    /// Per-environment cache of the detected Bracken CLI dialect.
    ///
    /// Probing costs a process launch, and the resolved executable cannot change
    /// underneath a running process, so the decision is cached for the lifetime
    /// of this actor.
    private var brackenDialectCache: [String: BrackenCLIDialect] = [:]

    /// Creates a classification pipeline.
    ///
    /// - Parameter condaManager: The conda manager to use (default: shared).
    public init(condaManager: CondaManager = .shared) {
        self.condaManager = condaManager
    }

    /// Detects which Bracken CLI dialect the `bracken` executable in `environment`
    /// speaks, caching the result per environment.
    ///
    /// Runs `bracken --help` and classifies its usage text. A probe that cannot
    /// run at all falls back to the wrapper dialect, which is the only arm64
    /// bioconda build and which validates its own inputs before execution.
    func detectBrackenDialect(environment: String) async -> BrackenCLIDialect {
        if let cached = brackenDialectCache[environment] { return cached }

        var helpText = ""
        if let result = try? await condaManager.runTool(
            name: "bracken",
            arguments: ["--help"],
            environment: environment,
            timeout: 120
        ) {
            helpText = result.stdout + result.stderr
        }

        let dialect = BrackenInvocation.dialect(fromHelpText: helpText)
        brackenDialectCache[environment] = dialect
        logger.info(
            "Detected bracken CLI dialect: \(dialect.rawValue, privacy: .public) in environment \(environment, privacy: .public)"
        )
        return dialect
    }

    // MARK: - Classification

    /// Runs Kraken2 classification on the configured input files.
    ///
    /// - Parameters:
    ///   - config: The classification configuration.
    ///   - progress: Optional progress callback.
    /// - Returns: A ``ClassificationResult`` with the parsed taxonomy tree.
    /// - Throws: ``ClassificationConfigError`` for invalid config,
    ///   ``ClassificationPipelineError`` for execution failures.
    public func classify(
        config: ClassificationConfig,
        progress: (@Sendable (Double, String) -> Void)? = nil
    ) async throws -> ClassificationResult {
        try await runPipeline(
            config: config,
            profileRequest: nil,
            progress: progress
        )
    }

    /// Runs Kraken2 classification followed by database-aware Bracken profiling.
    ///
    /// A missing request uses the automatic 150-base default. Stable SILVA and
    /// Greengenes identities resolve that request to genus; other databases use
    /// species. The returned result states whether profiling completed or
    /// degraded after a valid Kraken2 classification.
    public func profile(
        config: ClassificationConfig,
        progress: (@Sendable (Double, String) -> Void)? = nil
    ) async throws -> ClassificationResult {
        let request = config.brackenProfileRequest ?? .automaticDefault
        return try await runPipeline(
            config: config.withProfileRequest(request),
            profileRequest: request,
            progress: progress
        )
    }

    /// Source-compatible explicit Bracken invocation.
    ///
    /// The supplied rank remains explicit and is never replaced by a database
    /// default. Existing callers that pass all three Bracken settings continue
    /// through the same preflighted implementation as config-driven requests.
    public func profile(
        config: ClassificationConfig,
        brackenReadLength: Int = 150,
        brackenLevel: TaxonomicRank = .species,
        brackenThreshold: Int = 10,
        progress: (@Sendable (Double, String) -> Void)? = nil
    ) async throws -> ClassificationResult {
        let request = BrackenProfileRequest(
            rank: .explicit(brackenLevel),
            readLength: brackenReadLength,
            threshold: brackenThreshold
        )
        return try await runPipeline(
            config: config.withProfileRequest(request),
            profileRequest: request,
            progress: progress
        )
    }

    // MARK: - Private Pipeline

    /// Core pipeline implementation shared by `classify` and `profile`.
    private func runPipeline(
        config: ClassificationConfig,
        profileRequest: BrackenProfileRequest?,
        progress: (@Sendable (Double, String) -> Void)?
    ) async throws -> ClassificationResult {
        let startTime = Date()
        let fm = FileManager.default
        let provenanceRecorder = ProvenanceRecorder.shared
        let profileResolution = profileRequest.map {
            BrackenDatabaseCapabilities.resolve(
                catalogID: config.databaseCatalogID,
                installationRecipe: config.databaseInstallationRecipe,
                request: $0
            )
        }
        let runID = await provenanceRecorder.beginRun(
            name: profileRequest != nil ? "Metagenomics Profiling" : "Metagenomics Classification",
            parameters: classificationRunParameters(
                config: config,
                resolution: profileResolution
            )
        )

        // Establish the provenance run before any validation or output setup so
        // every persistable pre-tool failure belongs to the attempted workflow.
        if !fm.fileExists(atPath: config.outputDirectory.path) {
            do {
                try fm.createDirectory(
                    at: config.outputDirectory,
                    withIntermediateDirectories: true
                )
            } catch {
                let outputDirectoryCreationError = ClassificationConfigError.outputDirectoryCreationFailed(
                    config.outputDirectory,
                    error
                )
                _ = await provenanceRecorder.recordStep(
                    runID: runID,
                    toolName: "Lungfish Classification Output Setup",
                    toolVersion: WorkflowRun.currentAppVersion,
                    command: [
                        "LungfishWorkflow", "create-output-directory",
                        config.outputDirectory.path,
                    ],
                    resolvedOptions: [
                        "outputDirectory": .string(config.outputDirectory.path),
                    ],
                    runtimeIdentity: ProvenanceRuntimeIdentity(),
                    inputs: [],
                    outputs: [],
                    exitCode: 1,
                    wallTime: Date().timeIntervalSince(startTime),
                    stderr: error.localizedDescription
                )
                await provenanceRecorder.completeRun(runID, status: .failed)
                do {
                    try await provenanceRecorder.save(
                        runID: runID,
                        to: config.outputDirectory,
                        options: classificationProvenanceOptions(
                            requestedConfig: config,
                            effectiveConfig: config,
                            resolution: profileResolution,
                            outcome: .notRequested,
                            profileState: "failed"
                        )
                    )
                } catch let provenanceSaveError {
                    throw ClassificationConfigError.outputDirectoryCreationFailed(
                        config.outputDirectory,
                        ClassificationOutputSetupFailure(
                            outputDirectoryCreationError: outputDirectoryCreationError,
                            provenanceSaveErrorDescription: provenanceSaveError.localizedDescription
                        )
                    )
                }
                throw outputDirectoryCreationError
            }
        }

        // Phase 1: Validation (0.0 -- 0.10)
        progress?(0.0, "Validating configuration...")
        do {
            try config.validate()
        } catch {
            let validationInputs = existingClassificationInputRecords(config: config)
            _ = await provenanceRecorder.recordStep(
                runID: runID,
                toolName: "Lungfish Classification Validation",
                toolVersion: WorkflowRun.currentAppVersion,
                command: classificationValidationCommand(config: config),
                resolvedOptions: kraken2ResolvedOptions(config: config),
                runtimeIdentity: ProvenanceRuntimeIdentity(),
                inputs: validationInputs,
                outputs: [],
                exitCode: 2,
                wallTime: Date().timeIntervalSince(startTime),
                stderr: error.localizedDescription
            )
            await provenanceRecorder.completeRun(runID, status: .failed)
            try await provenanceRecorder.save(
                runID: runID,
                to: config.outputDirectory,
                options: classificationProvenanceOptions(
                    requestedConfig: config,
                    effectiveConfig: config,
                    resolution: profileResolution,
                    outcome: .notRequested,
                    profileState: "failed"
                )
            )
            throw error
        }

        OperationMarker.markInProgress(config.outputDirectory, detail: "Running Kraken2 classification\u{2026}")
        defer { OperationMarker.clearInProgress(config.outputDirectory) }

        // Auto-enable memory mapping if database exceeds 80% of system RAM (Gap 19).
        var effectiveConfig = config
        if shouldAutoEnableMemoryMapping(config: config) {
            effectiveConfig.memoryMapping = true
            let systemGB = String(
                format: "%.0f",
                Double(ProcessInfo.processInfo.physicalMemory) / 1_073_741_824
            )
            logger.info(
                "Auto-enabled memory mapping: database exceeds 80%% of \(systemGB, privacy: .public) GB system RAM"
            )
        }

        do {
            try removeKnownClassificationOutputs(config: effectiveConfig)
        } catch {
            _ = await provenanceRecorder.recordStep(
                runID: runID,
                toolName: "Lungfish Classification Output Preparation",
                toolVersion: WorkflowRun.currentAppVersion,
                command: classificationOutputPreparationCommand(config: effectiveConfig),
                resolvedOptions: kraken2ResolvedOptions(config: effectiveConfig),
                runtimeIdentity: ProvenanceRuntimeIdentity(),
                inputs: [],
                outputs: [],
                exitCode: 1,
                wallTime: Date().timeIntervalSince(startTime),
                stderr: error.localizedDescription
            )
            try await persistInterruptedClassificationRun(
                provenanceRecorder: provenanceRecorder,
                runID: runID,
                requestedConfig: config,
                effectiveConfig: effectiveConfig,
                resolution: profileResolution,
                status: .failed,
                profileState: "failed"
            )
            throw error
        }

        let replayMaterializationStart = Date()
        let replayInputs: DurableReplayInputMaterialization
        let replayMaterializationStepID: UUID?
        do {
            replayInputs = try durableReplayInputMaterialization(for: effectiveConfig)
            if replayInputs.replayRecords.isEmpty {
                replayMaterializationStepID = nil
            } else {
                let executionRecords = effectiveConfig.inputFiles.map { url in
                    ProvenanceRecorder.fileRecord(
                        url: url,
                        format: effectiveConfig.provenanceInputFileFormat,
                        role: .input
                    )
                }
                replayMaterializationStepID = await provenanceRecorder.recordStep(
                    runID: runID,
                    toolName: "Lungfish Classification Replay Input Materialization",
                    toolVersion: WorkflowRun.currentAppVersion,
                    command: classificationReplayInputMaterializationCommand(config: effectiveConfig),
                    resolvedOptions: replayInputMaterializationOptions(
                        config: effectiveConfig,
                        replayInputs: replayInputs.inputFiles
                    ),
                    runtimeIdentity: ProvenanceRuntimeIdentity(),
                    inputs: deduplicatedFileRecords(executionRecords + replayInputs.lineageRecords),
                    outputs: replayInputs.replayRecords.map {
                        FileRecord(
                            path: $0.path,
                            sha256: $0.sha256,
                            sizeBytes: $0.sizeBytes,
                            format: $0.format,
                            role: .output
                        )
                    },
                    exitCode: 0,
                    wallTime: Date().timeIntervalSince(replayMaterializationStart)
                )
            }
        } catch {
            _ = await provenanceRecorder.recordStep(
                runID: runID,
                toolName: "Lungfish Classification Replay Input Materialization",
                toolVersion: WorkflowRun.currentAppVersion,
                command: classificationReplayInputMaterializationCommand(config: effectiveConfig),
                resolvedOptions: replayInputMaterializationOptions(
                    config: effectiveConfig,
                    replayInputs: durableReplayInputURLs(for: effectiveConfig)
                ),
                runtimeIdentity: ProvenanceRuntimeIdentity(),
                inputs: existingReplayInputMaterializationRecords(config: effectiveConfig),
                outputs: existingReplayInputMaterializationOutputs(config: effectiveConfig),
                exitCode: 1,
                wallTime: Date().timeIntervalSince(replayMaterializationStart),
                stderr: error.localizedDescription
            )
            try await persistInterruptedClassificationRun(
                provenanceRecorder: provenanceRecorder,
                runID: runID,
                requestedConfig: config,
                effectiveConfig: effectiveConfig,
                resolution: profileResolution,
                status: .failed,
                profileState: "failed"
            )
            throw error
        }

        progress?(0.10, "Detecting tool versions...")

        // Phase 2: Kraken2 version detection (0.10 -- 0.30). Bracken is probed
        // only after report/database preflight succeeds.
        let toolVersion = await detectToolVersion(
            toolName: "kraken2",
            environment: Self.kraken2Environment,
            condaManager: condaManager,
            flags: ["--version"]
        )
        logger.info("Detected kraken2 version: \(toolVersion, privacy: .public)")

        progress?(0.30, "Running kraken2...")

        // Phase 3: Run kraken2 (0.30 -- 0.80)
        let kraken2Args = effectiveConfig.kraken2Arguments()
        let kraken2Command = ["kraken2"] + kraken2Args
        var durableReplayConfig = effectiveConfig
        durableReplayConfig.inputFiles = replayInputs.inputFiles
        let durableKraken2Command = ["kraken2"] + durableReplayConfig.kraken2Arguments()
        let sequenceInputRecords = effectiveConfig.inputFiles.map { url in
            ProvenanceRecorder.fileRecord(
                url: url,
                format: effectiveConfig.provenanceInputFileFormat,
                role: .input
            )
        }
        let inputRecords = deduplicatedFileRecords(
            sequenceInputRecords
                + replayInputs.lineageRecords
                + replayInputs.replayRecords
                + [databaseInputRecord(config: effectiveConfig)]
        )
        let kraken2RuntimeIdentity = managedRuntimeIdentity(
            toolName: "kraken2",
            environment: Self.kraken2Environment
        )
        func existingKraken2OutputRecords() -> [FileRecord] {
            [
                (effectiveConfig.reportURL, FileFormat.text, FileRole.report),
                (effectiveConfig.outputURL, FileFormat.text, FileRole.output),
            ].compactMap { url, format, role in
                guard fm.fileExists(atPath: url.path) else { return nil }
                return ProvenanceRecorder.fileRecord(url: url, format: format, role: role)
            }
        }
        logger.info("Running: kraken2 \(kraken2Args.joined(separator: " "), privacy: .public)")

        let kraken2Start = Date()
        // Build an optional stderr handler that forwards kraken2 progress
        // lines to the caller's progress callback. Explicit if/else avoids
        // type ambiguity with Optional.map and nested @Sendable closures.
        let kraken2StderrHandler: (@Sendable (String) -> Void)?
        if let progressCallback = progress {
            kraken2StderrHandler = { (line: String) in
                parseKraken2ProgressLine(line, progress: progressCallback)
            }
        } else {
            kraken2StderrHandler = nil
        }

        let kraken2Result: (stdout: String, stderr: String, exitCode: Int32)
        do {
            kraken2Result = try await condaManager.runTool(
                name: "kraken2",
                arguments: kraken2Args,
                environment: Self.kraken2Environment,
                timeout: 7200, // 2 hour timeout for large datasets
                stderrHandler: kraken2StderrHandler
            )
        } catch is CancellationError {
            await recordKraken2Failure(
                provenanceRecorder: provenanceRecorder,
                runID: runID,
                requestedConfig: config,
                effectiveConfig: effectiveConfig,
                toolVersion: toolVersion,
                command: kraken2Command,
                durableReplayCommand: durableKraken2Command,
                inputs: inputRecords,
                dependsOn: replayMaterializationStepID.map { [$0] } ?? [],
                exitCode: 130,
                stderr: "Kraken2 classification cancelled.",
                startedAt: kraken2Start
            )
            try await persistInterruptedClassificationRun(
                provenanceRecorder: provenanceRecorder,
                runID: runID,
                requestedConfig: config,
                effectiveConfig: effectiveConfig,
                resolution: profileResolution,
                status: .cancelled,
                profileState: "cancelled"
            )
            throw CancellationError()
        } catch let error as CondaError {
            let unavailable: Bool
            if case .toolNotFound = error {
                unavailable = true
            } else {
                unavailable = false
            }
            await recordKraken2Failure(
                provenanceRecorder: provenanceRecorder,
                runID: runID,
                requestedConfig: config,
                effectiveConfig: effectiveConfig,
                toolVersion: toolVersion,
                command: kraken2Command,
                durableReplayCommand: durableKraken2Command,
                inputs: inputRecords,
                dependsOn: replayMaterializationStepID.map { [$0] } ?? [],
                exitCode: unavailable ? 127 : 1,
                stderr: error.localizedDescription,
                startedAt: kraken2Start
            )
            try await persistInterruptedClassificationRun(
                provenanceRecorder: provenanceRecorder,
                runID: runID,
                requestedConfig: config,
                effectiveConfig: effectiveConfig,
                resolution: profileResolution,
                status: .failed,
                profileState: "failed"
            )
            if unavailable { throw ClassificationPipelineError.kraken2NotInstalled }
            throw error
        } catch {
            await recordKraken2Failure(
                provenanceRecorder: provenanceRecorder,
                runID: runID,
                requestedConfig: config,
                effectiveConfig: effectiveConfig,
                toolVersion: toolVersion,
                command: kraken2Command,
                durableReplayCommand: durableKraken2Command,
                inputs: inputRecords,
                dependsOn: replayMaterializationStepID.map { [$0] } ?? [],
                exitCode: 1,
                stderr: error.localizedDescription,
                startedAt: kraken2Start
            )
            try await persistInterruptedClassificationRun(
                provenanceRecorder: provenanceRecorder,
                runID: runID,
                requestedConfig: config,
                effectiveConfig: effectiveConfig,
                resolution: profileResolution,
                status: .failed,
                profileState: "failed"
            )
            throw error
        }

        let kraken2WallTime = Date().timeIntervalSince(kraken2Start)

        // Record kraken2 provenance step.
        let kraken2Outputs = existingKraken2OutputRecords()
        let kraken2StepID = await provenanceRecorder.recordStep(
            runID: runID,
            toolName: "kraken2",
            toolVersion: toolVersion,
            githubReleaseVersion: kraken2GithubReleaseVersion(for: toolVersion),
            command: kraken2Command,
            durableReplayArgv: durableKraken2Command,
            resolvedOptions: kraken2ResolvedOptions(config: effectiveConfig),
            runtimeIdentity: kraken2RuntimeIdentity,
            inputs: inputRecords,
            outputs: kraken2Outputs,
            exitCode: kraken2Result.exitCode,
            wallTime: kraken2WallTime,
            stderr: kraken2Result.stderr,
            dependsOn: replayMaterializationStepID.map { [$0] } ?? []
        )

        if kraken2Result.exitCode != 0 {
            try await persistInterruptedClassificationRun(
                provenanceRecorder: provenanceRecorder,
                runID: runID,
                requestedConfig: config,
                effectiveConfig: effectiveConfig,
                resolution: profileResolution,
                status: .failed,
                profileState: "failed"
            )
            throw ClassificationPipelineError.kraken2Failed(
                exitCode: kraken2Result.exitCode,
                stderr: kraken2Result.stderr
            )
        }

        progress?(0.80, "Parsing classification report...")

        // Phase 4: Parse kreport (0.80 -- 0.90)
        guard fm.fileExists(atPath: effectiveConfig.reportURL.path) else {
            let error = ClassificationPipelineError.kreportNotProduced(effectiveConfig.reportURL)
            _ = await provenanceRecorder.recordStep(
                runID: runID,
                toolName: "Lungfish Kraken Report Validation",
                toolVersion: WorkflowRun.currentAppVersion,
                command: ["LungfishWorkflow", "validate-kreport", effectiveConfig.reportURL.path],
                inputs: [],
                outputs: [],
                exitCode: 1,
                wallTime: 0,
                stderr: error.localizedDescription,
                dependsOn: kraken2StepID.map { [$0] } ?? []
            )
            try await persistInterruptedClassificationRun(
                provenanceRecorder: provenanceRecorder,
                runID: runID,
                requestedConfig: config,
                effectiveConfig: effectiveConfig,
                resolution: profileResolution,
                status: .failed,
                profileState: "failed"
            )
            throw error
        }

        let parseStartedAt = Date()
        var tree: TaxonTree
        do {
            tree = try KreportParser.parse(url: effectiveConfig.reportURL)
        } catch {
            _ = await provenanceRecorder.recordStep(
                runID: runID,
                toolName: "Lungfish Kraken Report Parser",
                toolVersion: WorkflowRun.currentAppVersion,
                command: ["LungfishWorkflow", "parse-kreport", effectiveConfig.reportURL.path],
                inputs: [
                    ProvenanceRecorder.fileRecord(
                        url: effectiveConfig.reportURL,
                        format: .text,
                        role: .input
                    ),
                ],
                outputs: [],
                exitCode: 1,
                wallTime: Date().timeIntervalSince(parseStartedAt),
                stderr: error.localizedDescription,
                dependsOn: kraken2StepID.map { [$0] } ?? []
            )
            try await persistInterruptedClassificationRun(
                provenanceRecorder: provenanceRecorder,
                runID: runID,
                requestedConfig: config,
                effectiveConfig: effectiveConfig,
                resolution: profileResolution,
                status: .failed,
                profileState: "failed"
            )
            throw error
        }

        let totalReads = tree.totalReads
        let speciesCount = tree.speciesCount
        logger.info("Parsed kreport: \(totalReads, privacy: .public) total reads, \(speciesCount, privacy: .public) species")

        progress?(
            0.90,
            profileRequest != nil ? "Preflighting Bracken profiling..." : "Recording provenance..."
        )

        // Phase 5: Optional Bracken (0.90 -- 0.95)
        var brackenOutputURL: URL?
        var profileOutcome: BrackenProfileOutcome = .notRequested
        var resultDependencyIDs = kraken2StepID.map { [$0] } ?? []
        if let profileResolution {
            let preflight = await preflightBracken(
                config: effectiveConfig,
                tree: tree,
                resolution: profileResolution,
                provenanceRecorder: provenanceRecorder,
                runID: runID,
                dependsOn: resultDependencyIDs
            )
            if let preflightStepID = preflight.stepID {
                resultDependencyIDs = [preflightStepID]
            }

            do {
                let preparation = try await prepareBrackenOutputTarget(
                    config: effectiveConfig,
                    resolution: profileResolution,
                    distributionURL: preflight.distributionURL,
                    provenanceRecorder: provenanceRecorder,
                    runID: runID,
                    dependsOn: resultDependencyIDs
                )
                if let preparationStepID = preparation.stepID {
                    resultDependencyIDs = [preparationStepID]
                }

                if let degraded = preparation.degradedOutcome {
                    profileOutcome = degraded
                } else if let degraded = preflight.degradedOutcome {
                    profileOutcome = degraded
                } else if let levelCode = preflight.levelCode {
                    progress?(0.92, "Running Bracken profiling...")
                    let execution = try await executeBracken(
                        config: effectiveConfig,
                        tree: tree,
                        resolution: profileResolution,
                        levelCode: levelCode,
                        distributionURL: preflight.distributionURL,
                        provenanceRecorder: provenanceRecorder,
                        runID: runID,
                        dependsOn: resultDependencyIDs
                    )
                    tree = execution.tree
                    brackenOutputURL = execution.outputURL
                    profileOutcome = execution.outcome
                    if let terminalStepID = execution.terminalStepID {
                        resultDependencyIDs = [terminalStepID]
                    }
                }
            } catch is CancellationError {
                await provenanceRecorder.completeRun(runID, status: .cancelled)
                let cancellationOptions = classificationProvenanceOptions(
                    requestedConfig: config,
                    effectiveConfig: effectiveConfig,
                    resolution: profileResolution,
                    outcome: .notRequested,
                    profileState: "cancelled"
                )
                try await provenanceRecorder.save(
                    runID: runID,
                    to: effectiveConfig.outputDirectory,
                    options: cancellationOptions
                )
                throw CancellationError()
            }
        }

        progress?(0.95, "Compacting Kraken2 output...")

        let retainedOutputURL = await compactKrakenOutputIfPossible(
            rawURL: effectiveConfig.outputURL,
            provenanceRecorder: provenanceRecorder,
            runID: runID,
            dependsOn: kraken2StepID.map { [$0] } ?? []
        ) ?? effectiveConfig.outputURL

        let totalRuntime = Date().timeIntervalSince(startTime)

        let result = ClassificationResult(
            config: effectiveConfig,
            tree: tree,
            reportURL: effectiveConfig.reportURL,
            outputURL: retainedOutputURL,
            brackenURL: brackenOutputURL,
            profileOutcome: profileOutcome,
            runtime: totalRuntime,
            toolVersion: toolVersion,
            provenanceId: runID
        )
        let provenanceOptions = classificationProvenanceOptions(
            requestedConfig: config,
            effectiveConfig: effectiveConfig,
            resolution: profileResolution,
            outcome: profileOutcome
        )

        progress?(0.97, "Saving result metadata...")

        let sidecarURL = effectiveConfig.outputDirectory.appendingPathComponent(ClassificationResult.sidecarFilename)
        try? fm.removeItem(at: sidecarURL)
        let sidecarInputRecords = classificationResultOutputRecords(
            reportURL: effectiveConfig.reportURL,
            outputURL: retainedOutputURL,
            brackenURL: brackenOutputURL
        )
        let sidecarSaveStart = Date()
        do {
            try result.save(to: effectiveConfig.outputDirectory)
        } catch let sidecarError {
            await provenanceRecorder.recordStep(
                runID: runID,
                toolName: "Lungfish Classification Result Sidecar",
                toolVersion: WorkflowRun.currentAppVersion,
                command: ["LungfishWorkflow", "ClassificationResult.save", sidecarURL.path],
                inputs: sidecarInputRecords,
                outputs: [
                    ProvenanceRecorder.fileRecord(url: sidecarURL, format: .json, role: .output),
                ],
                exitCode: 1,
                wallTime: Date().timeIntervalSince(sidecarSaveStart),
                stderr: sidecarError.localizedDescription,
                dependsOn: resultDependencyIDs
            )
            await provenanceRecorder.completeRun(runID, status: .failed)
            do {
                try await provenanceRecorder.save(
                    runID: runID,
                    to: effectiveConfig.outputDirectory,
                    options: provenanceOptions
                )
            } catch let provenanceError {
                throw ClassificationPipelineError.resultSidecarSaveFailed(
                    sidecarURL,
                    "\(sidecarError.localizedDescription); additionally failed to save failed-run provenance: \(provenanceError.localizedDescription)"
                )
            }
            throw ClassificationPipelineError.resultSidecarSaveFailed(
                sidecarURL,
                sidecarError.localizedDescription
            )
        }
        let sidecarWallTime = Date().timeIntervalSince(sidecarSaveStart)

        await provenanceRecorder.recordStep(
            runID: runID,
            toolName: "Lungfish Classification Result Sidecar",
            toolVersion: WorkflowRun.currentAppVersion,
            command: ["LungfishWorkflow", "ClassificationResult.save", sidecarURL.path],
            inputs: sidecarInputRecords,
            outputs: [
                ProvenanceRecorder.fileRecord(url: sidecarURL, format: .json, role: .output),
            ],
            exitCode: 0,
            wallTime: sidecarWallTime,
            dependsOn: resultDependencyIDs
        )

        progress?(0.98, "Saving provenance...")

        // Phase 6: Complete provenance (0.95 -- 1.0)
        let runStatus: RunStatus = profileOutcome.state == .degraded ? .failed : .completed
        await provenanceRecorder.completeRun(runID, status: runStatus)

        do {
            try await provenanceRecorder.save(
                runID: runID,
                to: effectiveConfig.outputDirectory,
                options: provenanceOptions
            )
        } catch {
            try? fm.removeItem(at: sidecarURL)
            await provenanceRecorder.completeRun(runID, status: .failed)
            throw error
        }

        let completionMessage: String
        switch profileOutcome.state {
        case .completed:
            completionMessage = "Profiling complete"
        case .degraded:
            completionMessage = "Kraken classification complete; profiling degraded"
        case .notRequested:
            completionMessage = "Classification complete"
        }
        progress?(1.0, completionMessage)

        let runtimeStr = String(format: "%.1f", totalRuntime)
        logger.info("Pipeline complete: \(totalReads, privacy: .public) reads, \(speciesCount, privacy: .public) species, \(runtimeStr, privacy: .public)s")

        return result
    }

    private func existingClassificationInputRecords(
        config: ClassificationConfig
    ) -> [FileRecord] {
        let fm = FileManager.default
        let sequenceInputs = config.inputFiles.compactMap { url -> FileRecord? in
            guard fm.fileExists(atPath: url.path) else { return nil }
            return ProvenanceRecorder.fileOrDirectoryRecord(
                url: url,
                format: config.provenanceInputFileFormat,
                role: .input
            )
        }
        let originalInputs = (config.originalInputFiles ?? []).compactMap { url -> FileRecord? in
            guard fm.fileExists(atPath: url.path) else { return nil }
            return ProvenanceRecorder.fileOrDirectoryRecord(url: url, role: .input)
        }
        let databaseInputs: [FileRecord]
        if fm.fileExists(atPath: config.databasePath.path) {
            databaseInputs = [databaseInputRecord(config: config)]
        } else {
            databaseInputs = []
        }
        return deduplicatedFileRecords(sequenceInputs + originalInputs + databaseInputs)
    }

    private func classificationValidationCommand(
        config: ClassificationConfig
    ) -> [String] {
        [
            "LungfishWorkflow", "validate-classification-config",
            "--goal", config.goal.rawValue,
            "--database", config.databasePath.path,
            "--input-format", config.inputFormat.rawValue,
            "--output-directory", config.outputDirectory.path,
        ] + config.inputFiles.flatMap { ["--input", $0.path] }
    }

    private func knownClassificationOutputURLs(
        config: ClassificationConfig
    ) -> [URL] {
        let compressedOutput = config.outputURL.appendingPathExtension("gz")
        return [
            config.reportURL,
            config.outputURL,
            compressedOutput,
            KrakenIndexDatabase.indexURL(for: config.outputURL),
            KrakenIndexDatabase.indexURL(for: compressedOutput),
            config.brackenURL,
            config.outputDirectory.appendingPathComponent(ClassificationResult.sidecarFilename),
            config.outputDirectory
                .appendingPathComponent(".lungfish-provenance", isDirectory: true)
                .appendingPathComponent("intermediates", isDirectory: true)
                .appendingPathComponent("classification-inputs", isDirectory: true),
        ]
    }

    private func classificationOutputPreparationCommand(
        config: ClassificationConfig
    ) -> [String] {
        ["LungfishWorkflow", "remove-stale-classification-outputs"]
            + knownClassificationOutputURLs(config: config).map(\.path)
    }

    private func removeKnownClassificationOutputs(
        config: ClassificationConfig
    ) throws {
        let fm = FileManager.default
        for url in knownClassificationOutputURLs(config: config)
            where fm.fileExists(atPath: url.path) {
            try fm.removeItem(at: url)
        }
    }

    private func deduplicatedFileRecords(_ records: [FileRecord]) -> [FileRecord] {
        var seen = Set<String>()
        return records.filter { record in
            seen.insert("\(record.role.rawValue)|\(record.path)").inserted
        }
    }

    private struct DurableReplayInputMaterialization {
        let inputFiles: [URL]
        let lineageRecords: [FileRecord]
        let replayRecords: [FileRecord]
    }

    private func durableReplayInputURLs(for config: ClassificationConfig) -> [URL] {
        let originalInputs = config.originalInputFiles ?? []
        let originalPaths = originalInputs.map { $0.standardizedFileURL.path }
        let executionPaths = config.inputFiles.map { $0.standardizedFileURL.path }
        guard !originalInputs.isEmpty, originalPaths != executionPaths else {
            return []
        }

        let replayDirectory = config.outputDirectory
            .appendingPathComponent(".lungfish-provenance", isDirectory: true)
            .appendingPathComponent("intermediates", isDirectory: true)
            .appendingPathComponent("classification-inputs", isDirectory: true)
        return config.inputFiles.enumerated().map { index, executionInput in
            replayDirectory.appendingPathComponent(
                "input-\(index + 1)-\(executionInput.lastPathComponent)"
            )
        }
    }

    private func durableReplayInputMaterialization(
        for config: ClassificationConfig
    ) throws -> DurableReplayInputMaterialization {
        let originalInputs = config.originalInputFiles ?? []
        let lineageRecords = originalInputs.map {
            ProvenanceRecorder.fileOrDirectoryRecord(url: $0, role: .input)
        }
        let replayInputURLs = durableReplayInputURLs(for: config)
        guard !replayInputURLs.isEmpty else {
            return DurableReplayInputMaterialization(
                inputFiles: config.inputFiles,
                lineageRecords: lineageRecords,
                replayRecords: []
            )
        }

        let replayDirectory = replayInputURLs[0].deletingLastPathComponent()
        let fm = FileManager.default
        try fm.createDirectory(at: replayDirectory, withIntermediateDirectories: true)

        var durableInputs: [URL] = []
        var replayRecords: [FileRecord] = []
        for (executionInput, replayInput) in zip(config.inputFiles, replayInputURLs) {
            if fm.fileExists(atPath: replayInput.path) {
                try fm.removeItem(at: replayInput)
            }
            try fm.copyItem(at: executionInput, to: replayInput)
            durableInputs.append(replayInput)
            replayRecords.append(
                ProvenanceRecorder.fileRecord(
                    url: replayInput,
                    format: config.provenanceInputFileFormat,
                    role: .input
                )
            )
        }
        return DurableReplayInputMaterialization(
            inputFiles: durableInputs,
            lineageRecords: lineageRecords,
            replayRecords: replayRecords
        )
    }

    private func classificationReplayInputMaterializationCommand(
        config: ClassificationConfig
    ) -> [String] {
        let copies = zip(config.inputFiles, durableReplayInputURLs(for: config))
            .map { source, destination in
                "/bin/cp \(shellEscape(source.path)) \(shellEscape(destination.path))"
            }
            .joined(separator: "\n")
        let replayDirectory = durableReplayInputURLs(for: config).first?.deletingLastPathComponent()
        let mkdir = replayDirectory.map { "/bin/mkdir -p \(shellEscape($0.path))" } ?? ":"
        return ["/bin/sh", "-c", "set -e\n\(mkdir)\n\(copies)"]
    }

    private func replayInputMaterializationOptions(
        config: ClassificationConfig,
        replayInputs: [URL]
    ) -> [String: ParameterValue] {
        [
            "copyCount": .integer(replayInputs.count),
            "inputFormat": .string(config.inputFormat.rawValue),
            "pairedEnd": .boolean(config.isPairedEnd),
            "destinationDirectory": replayInputs.first
                .map { .file($0.deletingLastPathComponent()) } ?? .null,
        ]
    }

    private func existingReplayInputMaterializationRecords(
        config: ClassificationConfig
    ) -> [FileRecord] {
        let fm = FileManager.default
        let executionRecords = config.inputFiles.compactMap { url -> FileRecord? in
            guard fm.fileExists(atPath: url.path) else { return nil }
            return ProvenanceRecorder.fileRecord(
                url: url,
                format: config.provenanceInputFileFormat,
                role: .input
            )
        }
        let lineageRecords = (config.originalInputFiles ?? []).compactMap { url -> FileRecord? in
            guard fm.fileExists(atPath: url.path) else { return nil }
            return ProvenanceRecorder.fileOrDirectoryRecord(url: url, role: .input)
        }
        return deduplicatedFileRecords(executionRecords + lineageRecords)
    }

    private func existingReplayInputMaterializationOutputs(
        config: ClassificationConfig
    ) -> [FileRecord] {
        let fm = FileManager.default
        return durableReplayInputURLs(for: config).compactMap { url -> FileRecord? in
            guard fm.fileExists(atPath: url.path) else { return nil }
            return ProvenanceRecorder.fileRecord(
                url: url,
                format: config.provenanceInputFileFormat,
                role: .output
            )
        }
    }

    private func databaseInputRecord(config: ClassificationConfig) -> FileRecord {
        let normalizedDigest = config.databaseDigest.map {
            $0.hasPrefix("sha256:") ? String($0.dropFirst("sha256:".count)) : $0
        }
        return FileRecord(
            path: config.databasePath.standardizedFileURL.path,
            sha256: normalizedDigest,
            sizeBytes: estimateDatabaseSize(at: config.databasePath),
            format: .unknown,
            role: .reference
        )
    }

    private func recordKraken2Failure(
        provenanceRecorder: ProvenanceRecorder,
        runID: UUID,
        requestedConfig _: ClassificationConfig,
        effectiveConfig: ClassificationConfig,
        toolVersion: String,
        command: [String],
        durableReplayCommand: [String],
        inputs: [FileRecord],
        dependsOn: [UUID],
        exitCode: Int32,
        stderr: String,
        startedAt: Date
    ) async {
        let fileManager = FileManager.default
        let outputs: [FileRecord] = [
            (effectiveConfig.reportURL, FileFormat.text, FileRole.report),
            (effectiveConfig.outputURL, FileFormat.text, FileRole.output),
        ].compactMap { url, format, role in
            guard fileManager.fileExists(atPath: url.path) else { return nil }
            return ProvenanceRecorder.fileRecord(url: url, format: format, role: role)
        }
        _ = await provenanceRecorder.recordStep(
            runID: runID,
            toolName: "kraken2",
            toolVersion: toolVersion,
            githubReleaseVersion: kraken2GithubReleaseVersion(for: toolVersion),
            command: command,
            durableReplayArgv: durableReplayCommand,
            resolvedOptions: kraken2ResolvedOptions(config: effectiveConfig),
            runtimeIdentity: managedRuntimeIdentity(
                toolName: "kraken2",
                environment: Self.kraken2Environment
            ),
            inputs: inputs,
            outputs: outputs,
            exitCode: exitCode,
            wallTime: Date().timeIntervalSince(startedAt),
            stderr: stderr,
            dependsOn: dependsOn
        )
    }

    private func persistInterruptedClassificationRun(
        provenanceRecorder: ProvenanceRecorder,
        runID: UUID,
        requestedConfig: ClassificationConfig,
        effectiveConfig: ClassificationConfig,
        resolution: BrackenProfileResolution?,
        status: RunStatus,
        profileState: String
    ) async throws {
        await provenanceRecorder.completeRun(runID, status: status)
        try await provenanceRecorder.save(
            runID: runID,
            to: effectiveConfig.outputDirectory,
            options: classificationProvenanceOptions(
                requestedConfig: requestedConfig,
                effectiveConfig: effectiveConfig,
                resolution: resolution,
                outcome: .notRequested,
                profileState: profileState
            )
        )
    }

    private struct BrackenPreflightResult {
        let levelCode: String?
        let distributionURL: URL
        let degradedOutcome: BrackenProfileOutcome?
        let stepID: UUID?
    }

    private struct BrackenExecutionResult {
        let tree: TaxonTree
        let outputURL: URL?
        let outcome: BrackenProfileOutcome
        let terminalStepID: UUID?
    }

    private struct BrackenOutputPreparationResult {
        let degradedOutcome: BrackenProfileOutcome?
        let stepID: UUID?
    }

    private func preflightBracken(
        config: ClassificationConfig,
        tree: TaxonTree,
        resolution: BrackenProfileResolution,
        provenanceRecorder: ProvenanceRecorder,
        runID: UUID,
        dependsOn: [UUID]
    ) async -> BrackenPreflightResult {
        let startedAt = Date()
        // Resolve the kmer distribution the same way execution will: prefer the
        // exact read length, else the nearest available N. Preflighting the file
        // that will actually be used keeps the preflight honest for databases
        // that ship a different set of read lengths than the request.
        let distributionResolution = try? BrackenInvocation.resolveKmerDistribution(
            databasePath: config.databasePath,
            readLength: resolution.readLength,
            availableFilenames: BrackenInvocation.availableDistributionFilenames(
                inDatabase: config.databasePath
            )
        )
        if let distributionResolution, distributionResolution.isSubstituted {
            logger.info(
                """
                Bracken kmer distribution for read length \
                \(distributionResolution.requestedReadLength, privacy: .public) is absent; \
                substituting nearest available read length \
                \(distributionResolution.readLength, privacy: .public) \
                (\(distributionResolution.url.lastPathComponent, privacy: .public)).
                """
            )
        }
        let distributionURL = distributionResolution?.url
            ?? config.databasePath.appendingPathComponent(
                BrackenInvocation.distributionFilename(readLength: resolution.readLength)
            )
        let levelCode = BrackenDatabaseCapabilities.levelCode(for: resolution.rank)
        let failure: (BrackenProfileDegradationReason, String)?

        if levelCode == nil {
            failure = (
                .unsupportedRank,
                "Bracken does not support requested rank \(resolution.rank.code). Supported ranks are D, P, C, O, F, G, and S."
            )
        } else if tree.nodes(at: resolution.rank).isEmpty {
            failure = (
                .rankAbsentFromReport,
                "The Kraken report has no rows at resolved rank \(resolution.rank.code) (\(resolution.rank.displayName))."
            )
        } else if let diagnostic = brackenDistributionDiagnostic(at: distributionURL) {
            failure = (.distributionUnavailable, diagnostic)
        } else {
            failure = nil
        }

        var inputs = [
            ProvenanceRecorder.fileRecord(url: config.reportURL, format: .text, role: .input),
        ]
        if failure == nil {
            inputs.append(
                ProvenanceRecorder.fileRecord(
                    url: distributionURL,
                    format: .unknown,
                    role: .reference
                )
            )
        }

        let command = [
            "LungfishWorkflow",
            "BrackenPreflight",
            "--kreport", config.reportURL.path,
            "--database", config.databasePath.path,
            "--distribution", distributionURL.path,
            "--requested-rank", resolution.request.provenanceValue,
            "--resolved-rank", resolution.rank.code,
            "--read-length", String(resolution.readLength),
            "--threshold", String(resolution.threshold),
        ]
        let stepID = await provenanceRecorder.recordStep(
            runID: runID,
            toolName: "Lungfish Bracken Preflight",
            toolVersion: WorkflowRun.currentAppVersion,
            command: command,
            resolvedOptions: brackenResolvedOptions(
                resolution: resolution,
                distributionURL: distributionURL
            ),
            runtimeIdentity: ProvenanceRuntimeIdentity(),
            inputs: inputs,
            outputs: [],
            exitCode: failure == nil ? 0 : 2,
            wallTime: Date().timeIntervalSince(startedAt),
            stderr: failure?.1,
            dependsOn: dependsOn
        )

        return BrackenPreflightResult(
            levelCode: levelCode,
            distributionURL: distributionURL,
            degradedOutcome: failure.map {
                .degraded(resolution: resolution, reason: $0.0, message: $0.1)
            },
            stepID: stepID
        )
    }

    private func prepareBrackenOutputTarget(
        config: ClassificationConfig,
        resolution: BrackenProfileResolution,
        distributionURL: URL,
        provenanceRecorder: ProvenanceRecorder,
        runID: UUID,
        dependsOn: [UUID]
    ) async throws -> BrackenOutputPreparationResult {
        try Task.checkCancellation()
        let fm = FileManager.default
        guard fm.fileExists(atPath: config.brackenURL.path) else {
            return BrackenOutputPreparationResult(degradedOutcome: nil, stepID: nil)
        }

        do {
            try fm.removeItem(at: config.brackenURL)
            return BrackenOutputPreparationResult(degradedOutcome: nil, stepID: nil)
        } catch {
            let message = "Could not remove stale Bracken target before profiling: \(error.localizedDescription)"
            let stepID = await provenanceRecorder.recordStep(
                runID: runID,
                toolName: "Lungfish Bracken Output Preparation",
                toolVersion: WorkflowRun.currentAppVersion,
                command: ["LungfishWorkflow", "remove-stale-output", config.brackenURL.path],
                resolvedOptions: brackenResolvedOptions(
                    resolution: resolution,
                    distributionURL: distributionURL
                ),
                runtimeIdentity: ProvenanceRuntimeIdentity(),
                inputs: [],
                outputs: [],
                exitCode: 1,
                wallTime: 0,
                stderr: message,
                dependsOn: dependsOn
            )
            return BrackenOutputPreparationResult(
                degradedOutcome: .degraded(
                    resolution: resolution,
                    reason: .outputInvalid,
                    message: message
                ),
                stepID: stepID
            )
        }
    }

    private func executeBracken(
        config: ClassificationConfig,
        tree: TaxonTree,
        resolution: BrackenProfileResolution,
        levelCode: String,
        distributionURL: URL,
        provenanceRecorder: ProvenanceRecorder,
        runID: UUID,
        dependsOn: [UUID]
    ) async throws -> BrackenExecutionResult {
        let fm = FileManager.default
        try Task.checkCancellation()
        // The only arm64-installable bioconda Bracken build exposes the inner
        // `est_abundance.py` CLI rather than the real driver, so the argument
        // form has to follow whichever dialect this executable actually speaks.
        let dialect = await detectBrackenDialect(environment: Self.brackenEnvironment)
        try Task.checkCancellation()

        // `est_abundance.py` has no version flag, so `bracken -v` prints an
        // argparse usage error whose digits would otherwise be recorded as a
        // bogus version. Read the packaged version from conda-meta instead.
        let brackenVersion: String
        switch dialect {
        case .database:
            brackenVersion = await detectToolVersion(
                toolName: "bracken",
                environment: Self.brackenEnvironment,
                condaManager: condaManager,
                flags: ["-v"]
            )
        case .kmerDistribution:
            let envURL = await condaManager.environmentURL(named: Self.brackenEnvironment)
            brackenVersion = CondaMetaReader.primaryPackage(
                named: "bracken",
                inEnvironment: envURL
            )?.version ?? "unknown"
        }
        logger.info("Detected bracken version: \(brackenVersion, privacy: .public)")
        try Task.checkCancellation()

        let brackenArgs = BrackenInvocation.arguments(
            dialect: dialect,
            databasePath: config.databasePath,
            distributionURL: distributionURL,
            reportURL: config.reportURL,
            outputURL: config.brackenURL,
            readLength: resolution.readLength,
            levelCode: levelCode,
            threshold: resolution.threshold
        )
        let brackenCommand = ["bracken"] + brackenArgs
        let brackenInputs = [
            ProvenanceRecorder.fileRecord(url: config.reportURL, format: .text, role: .input),
            ProvenanceRecorder.fileRecord(url: distributionURL, format: .unknown, role: .reference),
        ]
        let resolvedOptions = brackenResolvedOptions(
            resolution: resolution,
            distributionURL: distributionURL,
            dialect: dialect,
            effectiveArgv: brackenCommand
        )
        let runtimeIdentity = managedRuntimeIdentity(
            toolName: "bracken",
            environment: Self.brackenEnvironment
        )

        if fm.fileExists(atPath: config.brackenURL.path) {
            do {
                try fm.removeItem(at: config.brackenURL)
            } catch {
                let message = "Could not remove stale Bracken target before execution: \(error.localizedDescription)"
                let stepID = await provenanceRecorder.recordStep(
                    runID: runID,
                    toolName: "Lungfish Bracken Output Preparation",
                    toolVersion: WorkflowRun.currentAppVersion,
                    command: ["LungfishWorkflow", "remove-stale-output", config.brackenURL.path],
                    resolvedOptions: resolvedOptions,
                    runtimeIdentity: ProvenanceRuntimeIdentity(),
                    inputs: [],
                    outputs: [],
                    exitCode: 1,
                    wallTime: 0,
                    stderr: message,
                    dependsOn: dependsOn
                )
                return BrackenExecutionResult(
                    tree: tree,
                    outputURL: nil,
                    outcome: .degraded(
                        resolution: resolution,
                        reason: .outputInvalid,
                        message: message,
                        toolVersion: brackenVersion
                    ),
                    terminalStepID: stepID
                )
            }
        }

        logger.info("Running: bracken \(brackenArgs.joined(separator: " "), privacy: .public)")
        try Task.checkCancellation()
        let startedAt = Date()
        let processResult: (stdout: String, stderr: String, exitCode: Int32)
        do {
            processResult = try await condaManager.runTool(
                name: "bracken",
                arguments: brackenArgs,
                environment: Self.brackenEnvironment,
                timeout: 3600
            )
        } catch is CancellationError {
            try? fm.removeItem(at: config.brackenURL)
            _ = await provenanceRecorder.recordStep(
                runID: runID,
                toolName: "bracken",
                toolVersion: brackenVersion,
                command: brackenCommand,
                resolvedOptions: resolvedOptions,
                runtimeIdentity: runtimeIdentity,
                inputs: brackenInputs,
                outputs: [],
                exitCode: 130,
                wallTime: Date().timeIntervalSince(startedAt),
                stderr: "Bracken profiling cancelled.",
                dependsOn: dependsOn
            )
            throw CancellationError()
        } catch let error as CondaError {
            try? fm.removeItem(at: config.brackenURL)
            let unavailable: Bool
            if case .toolNotFound = error {
                unavailable = true
            } else {
                unavailable = false
            }
            let message = error.localizedDescription
            let stepID = await provenanceRecorder.recordStep(
                runID: runID,
                toolName: "bracken",
                toolVersion: brackenVersion,
                command: brackenCommand,
                resolvedOptions: resolvedOptions,
                runtimeIdentity: runtimeIdentity,
                inputs: brackenInputs,
                outputs: [],
                exitCode: unavailable ? 127 : 1,
                wallTime: Date().timeIntervalSince(startedAt),
                stderr: message,
                dependsOn: dependsOn
            )
            return BrackenExecutionResult(
                tree: tree,
                outputURL: nil,
                outcome: .degraded(
                    resolution: resolution,
                    reason: unavailable ? .toolUnavailable : .toolFailed,
                    message: message,
                    toolVersion: brackenVersion
                ),
                terminalStepID: stepID
            )
        } catch {
            try? fm.removeItem(at: config.brackenURL)
            let message = error.localizedDescription
            let stepID = await provenanceRecorder.recordStep(
                runID: runID,
                toolName: "bracken",
                toolVersion: brackenVersion,
                command: brackenCommand,
                resolvedOptions: resolvedOptions,
                runtimeIdentity: runtimeIdentity,
                inputs: brackenInputs,
                outputs: [],
                exitCode: 1,
                wallTime: Date().timeIntervalSince(startedAt),
                stderr: message,
                dependsOn: dependsOn
            )
            return BrackenExecutionResult(
                tree: tree,
                outputURL: nil,
                outcome: .degraded(
                    resolution: resolution,
                    reason: .toolFailed,
                    message: message,
                    toolVersion: brackenVersion
                ),
                terminalStepID: stepID
            )
        }

        let processWallTime = Date().timeIntervalSince(startedAt)
        if Task.isCancelled {
            try? fm.removeItem(at: config.brackenURL)
            let brackenStepID = await provenanceRecorder.recordStep(
                runID: runID,
                toolName: "bracken",
                toolVersion: brackenVersion,
                command: brackenCommand,
                resolvedOptions: resolvedOptions,
                runtimeIdentity: runtimeIdentity,
                inputs: brackenInputs,
                outputs: [],
                exitCode: processResult.exitCode,
                wallTime: processWallTime,
                stderr: processResult.stderr,
                dependsOn: dependsOn
            )
            _ = await provenanceRecorder.recordStep(
                runID: runID,
                toolName: "Lungfish Bracken Cancellation",
                toolVersion: WorkflowRun.currentAppVersion,
                command: ["LungfishWorkflow", "cancel-bracken-output", config.brackenURL.path],
                resolvedOptions: resolvedOptions,
                runtimeIdentity: ProvenanceRuntimeIdentity(),
                inputs: [],
                outputs: [],
                exitCode: 130,
                wallTime: 0,
                stderr: "Bracken profiling cancelled after process termination.",
                dependsOn: brackenStepID.map { [$0] } ?? dependsOn
            )
            throw CancellationError()
        }
        // `bioconda::bracken=1.0.0`'s `est_abundance.py` writes and closes the
        // complete abundance table, then crashes with an UnboundLocalError on
        // `u_reads` when the Kraken report has no unclassified (U) line, because
        // that variable is only ever assigned inside the U branch. The exit is
        // non-zero but the output is already whole. Treat that one signature as
        // success so a fully-classified sample still profiles; every other
        // non-zero exit stays a failure, and the output still has to pass the
        // existing validation and parse checks below.
        let survivedKnownWrapperCrash = dialect == .kmerDistribution
            && processResult.exitCode != 0
            && BrackenInvocation.isUnclassifiedReadsCrash(stderr: processResult.stderr)
            && fm.fileExists(atPath: config.brackenURL.path)
        if survivedKnownWrapperCrash {
            logger.info(
                """
                bracken exited \(processResult.exitCode, privacy: .public) with the known \
                bracken=1.0.0 UnboundLocalError on 'u_reads' (Kraken report has no unclassified \
                line). The abundance table was written before the crash; continuing to validation.
                """
            )
        }

        if processResult.exitCode != 0 && !survivedKnownWrapperCrash {
            try? fm.removeItem(at: config.brackenURL)
            let unavailable = processResult.exitCode == 127
            let message: String
            if !processResult.stderr.isEmpty {
                message = processResult.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            } else if unavailable {
                message = "Bracken executable was not available in the managed environment."
            } else {
                message = "Bracken exited with status \(processResult.exitCode)."
            }
            let stepID = await provenanceRecorder.recordStep(
                runID: runID,
                toolName: "bracken",
                toolVersion: brackenVersion,
                command: brackenCommand,
                resolvedOptions: resolvedOptions,
                runtimeIdentity: runtimeIdentity,
                inputs: brackenInputs,
                outputs: [],
                exitCode: processResult.exitCode,
                wallTime: processWallTime,
                stderr: processResult.stderr,
                dependsOn: dependsOn
            )
            return BrackenExecutionResult(
                tree: tree,
                outputURL: nil,
                outcome: .degraded(
                    resolution: resolution,
                    reason: unavailable ? .toolUnavailable : .toolFailed,
                    message: message,
                    toolVersion: brackenVersion
                ),
                terminalStepID: stepID
            )
        }

        let outputFailure: (BrackenProfileDegradationReason, String)?
        if !fm.fileExists(atPath: config.brackenURL.path) {
            outputFailure = (
                .outputMissing,
                "Bracken exited successfully but did not produce \(config.brackenURL.path)."
            )
        } else if let diagnostic = generatedBrackenOutputDiagnostic(at: config.brackenURL) {
            outputFailure = (.outputInvalid, diagnostic)
        } else {
            outputFailure = nil
        }

        var mergedTree = tree
        var parseFailure: String?
        if outputFailure == nil {
            do {
                let rows = try BrackenParser.parse(url: config.brackenURL)
                let matchingRows = rows.filter { row in
                    row.taxonomyLevel == levelCode && tree.node(taxId: row.taxId) != nil
                }
                if matchingRows.isEmpty {
                    parseFailure = "Bracken output contained no \(levelCode)-rank taxa matching the Kraken report."
                } else {
                    BrackenParser.mergeBracken(rows: matchingRows, into: &mergedTree)
                }
            } catch {
                parseFailure = "Bracken output could not be parsed or merged: \(error.localizedDescription)"
            }
        }

        if let failure = outputFailure
            ?? parseFailure.map({ (BrackenProfileDegradationReason.outputInvalid, $0) }) {
            let validationInputs: [FileRecord]
            if fm.fileExists(atPath: config.brackenURL.path) {
                validationInputs = [
                    ProvenanceRecorder.fileRecord(
                        url: config.brackenURL,
                        format: .text,
                        role: .input
                    ),
                ]
            } else {
                validationInputs = []
            }
            try? fm.removeItem(at: config.brackenURL)
            let brackenStepID = await provenanceRecorder.recordStep(
                runID: runID,
                toolName: "bracken",
                toolVersion: brackenVersion,
                command: brackenCommand,
                resolvedOptions: resolvedOptions,
                runtimeIdentity: runtimeIdentity,
                inputs: brackenInputs,
                outputs: [],
                exitCode: processResult.exitCode,
                wallTime: processWallTime,
                stderr: processResult.stderr,
                dependsOn: dependsOn
            )
            let validationStepID = await provenanceRecorder.recordStep(
                runID: runID,
                toolName: "Lungfish Bracken Output Validation",
                toolVersion: WorkflowRun.currentAppVersion,
                command: ["LungfishWorkflow", "validate-bracken-output", config.brackenURL.path],
                resolvedOptions: resolvedOptions,
                runtimeIdentity: ProvenanceRuntimeIdentity(),
                inputs: validationInputs,
                outputs: [],
                exitCode: 1,
                wallTime: 0,
                stderr: failure.1,
                dependsOn: brackenStepID.map { [$0] } ?? dependsOn
            )
            return BrackenExecutionResult(
                tree: tree,
                outputURL: nil,
                outcome: .degraded(
                    resolution: resolution,
                    reason: failure.0,
                    message: failure.1,
                    toolVersion: brackenVersion
                ),
                terminalStepID: validationStepID ?? brackenStepID
            )
        }

        let outputRecord = ProvenanceRecorder.fileRecord(
            url: config.brackenURL,
            format: .text,
            role: .output
        )
        let stepID = await provenanceRecorder.recordStep(
            runID: runID,
            toolName: "bracken",
            toolVersion: brackenVersion,
            command: brackenCommand,
            resolvedOptions: resolvedOptions,
            runtimeIdentity: runtimeIdentity,
            inputs: brackenInputs,
            outputs: [outputRecord],
            exitCode: processResult.exitCode,
            wallTime: processWallTime,
            stderr: processResult.stderr,
            dependsOn: dependsOn
        )
        logger.info("Bracken profiling merged successfully")
        return BrackenExecutionResult(
            tree: mergedTree,
            outputURL: config.brackenURL,
            outcome: .completed(resolution: resolution, toolVersion: brackenVersion),
            terminalStepID: stepID
        )
    }

    private func brackenDistributionDiagnostic(at url: URL) -> String? {
        do {
            let values = try url.resourceValues(forKeys: [
                .isRegularFileKey,
                .isSymbolicLinkKey,
                .isReadableKey,
                .fileSizeKey,
            ])
            guard values.isSymbolicLink != true else {
                return "Bracken distribution must not be a symbolic link: \(url.path)."
            }
            guard values.isRegularFile == true else {
                return "Bracken distribution is missing or is not a regular file: \(url.path)."
            }
            guard values.isReadable == true,
                  FileManager.default.isReadableFile(atPath: url.path) else {
                return "Bracken distribution is not readable: \(url.path)."
            }
            guard (values.fileSize ?? 0) > 0 else {
                return "Bracken distribution is empty: \(url.path)."
            }
            let handle = try FileHandle(forReadingFrom: url)
            try handle.close()
            return nil
        } catch {
            return "Bracken distribution is unavailable at \(url.path): \(error.localizedDescription)"
        }
    }

    private func generatedBrackenOutputDiagnostic(at url: URL) -> String? {
        do {
            let values = try url.resourceValues(forKeys: [
                .isRegularFileKey,
                .isReadableKey,
                .fileSizeKey,
            ])
            guard values.isRegularFile == true else {
                return "Bracken output is not a regular file: \(url.path)."
            }
            guard values.isReadable == true,
                  FileManager.default.isReadableFile(atPath: url.path) else {
                return "Bracken output is not readable: \(url.path)."
            }
            guard (values.fileSize ?? 0) > 0 else {
                return "Bracken output is empty: \(url.path)."
            }
            return nil
        } catch {
            return "Bracken output is unavailable at \(url.path): \(error.localizedDescription)"
        }
    }

    private func classificationRunParameters(
        config: ClassificationConfig,
        resolution: BrackenProfileResolution?
    ) -> [String: ParameterValue] {
        var parameters: [String: ParameterValue] = [
            "goal": .string(config.goal.rawValue),
            "database": .string(config.databaseName),
            "databaseVersion": .string(config.databaseVersion),
            "databasePath": .file(config.databasePath.standardizedFileURL),
            "databaseDigest": config.databaseDigest.map(ParameterValue.string) ?? .null,
            "databaseCatalogID": config.databaseCatalogID.map(ParameterValue.string) ?? .null,
            "databaseInstallationRecipe": config.databaseInstallationRecipe
                .map { .string($0.provenanceValue) } ?? .null,
            "confidence": .number(config.confidence),
            "minimumHitGroups": .integer(config.minimumHitGroups),
            "threads": .integer(config.threads),
            "pairedEnd": .boolean(config.isPairedEnd),
            "memoryMapping": .boolean(config.memoryMapping),
            "quickMode": .boolean(config.quickMode),
            "inputFormat": .string(config.inputFormat.rawValue),
            "reportMinimizerData": .boolean(true),
            "extraArgs": .string(AdvancedCommandLineOptions.join(config.extraArguments)),
        ]
        if let resolution {
            parameters["brackenRankRequest"] = .string(resolution.request.provenanceValue)
            parameters["brackenRequestedReadLength"] = .integer(
                config.brackenProfileRequest?.readLength ?? BrackenProfileRequest.automaticDefault.readLength
            )
            parameters["brackenRequestedThreshold"] = .integer(
                config.brackenProfileRequest?.threshold ?? BrackenProfileRequest.automaticDefault.threshold
            )
            parameters["brackenResolvedRank"] = .string(resolution.rank.code)
            parameters["brackenResolutionSource"] = .string(resolution.source.rawValue)
            parameters["brackenReadLength"] = .integer(resolution.readLength)
            parameters["brackenThreshold"] = .integer(resolution.threshold)
            if case .explicit(let rank) = resolution.request {
                parameters["brackenExplicitRank"] = .string(rank.code)
            }
        }
        return parameters
    }

    private func classificationProvenanceOptions(
        requestedConfig: ClassificationConfig,
        effectiveConfig: ClassificationConfig,
        resolution: BrackenProfileResolution?,
        outcome: BrackenProfileOutcome,
        profileState: String? = nil
    ) -> ProvenanceOptions {
        var explicit: [String: ParameterValue] = [
            "goal": .string(requestedConfig.goal.rawValue),
            "database": .string(requestedConfig.databaseName),
            "databaseVersion": .string(requestedConfig.databaseVersion),
            "databasePath": .file(requestedConfig.databasePath.standardizedFileURL),
            "databaseDigest": requestedConfig.databaseDigest.map(ParameterValue.string) ?? .null,
            "databaseCatalogID": requestedConfig.databaseCatalogID.map(ParameterValue.string) ?? .null,
            "databaseInstallationRecipe": requestedConfig.databaseInstallationRecipe
                .map { .string($0.provenanceValue) } ?? .null,
            "confidence": .number(requestedConfig.confidence),
            "minimumHitGroups": .integer(requestedConfig.minimumHitGroups),
            "threads": .integer(requestedConfig.threads),
            "pairedEnd": .boolean(requestedConfig.isPairedEnd),
            "memoryMapping": .boolean(requestedConfig.memoryMapping),
            "quickMode": .boolean(requestedConfig.quickMode),
            "inputFormat": .string(requestedConfig.inputFormat.rawValue),
            "extraArgs": .string(AdvancedCommandLineOptions.join(requestedConfig.extraArguments)),
        ]
        var defaults: [String: ParameterValue] = [
            "goal": .string(ClassificationConfig.Goal.classify.rawValue),
            "inputFormat": .string(SequenceFormat.fastq.rawValue),
            "confidence": .number(0),
            "minimumHitGroups": .integer(2),
            "threads": .integer(4),
            "pairedEnd": .boolean(false),
            "memoryMapping": .boolean(false),
            "quickMode": .boolean(false),
            "reportMinimizerData": .boolean(true),
            "extraArgs": .string(""),
        ]
        var resolvedDefaults: [String: ParameterValue] = [
            "goal": .string(effectiveConfig.goal.rawValue),
            "inputFormat": .string(effectiveConfig.inputFormat.rawValue),
            "confidence": .number(effectiveConfig.confidence),
            "minimumHitGroups": .integer(effectiveConfig.minimumHitGroups),
            "threads": .integer(effectiveConfig.threads),
            "pairedEnd": .boolean(effectiveConfig.isPairedEnd),
            "effectiveMemoryMapping": .boolean(effectiveConfig.memoryMapping),
            "quickMode": .boolean(effectiveConfig.quickMode),
            "reportMinimizerData": .boolean(true),
            "extraArgs": .string(AdvancedCommandLineOptions.join(effectiveConfig.extraArguments)),
            "databaseIdentityStatus": .string(databaseIdentityStatus(config: effectiveConfig)),
            "databaseCoreFileSizes": databaseCoreFileSizesOption(at: effectiveConfig.databasePath),
            "profileState": .string(profileState ?? outcome.state.rawValue),
        ]
        if let resolution {
            let request = requestedConfig.brackenProfileRequest ?? .automaticDefault
            explicit["brackenRankRequest"] = .string(request.rank.provenanceValue)
            explicit["brackenRequestedReadLength"] = .integer(request.readLength)
            explicit["brackenRequestedThreshold"] = .integer(request.threshold)
            if case .explicit(let rank) = request.rank {
                explicit["brackenExplicitRank"] = .string(rank.code)
            }
            defaults["brackenRankRequest"] = .string("automatic")
            defaults["brackenReadLength"] = .integer(150)
            defaults["brackenThreshold"] = .integer(10)
            resolvedDefaults["brackenResolvedRank"] = .string(resolution.rank.code)
            resolvedDefaults["brackenResolutionSource"] = .string(resolution.source.rawValue)
            resolvedDefaults["brackenReadLength"] = .integer(resolution.readLength)
            resolvedDefaults["brackenThreshold"] = .integer(resolution.threshold)
        }
        if let reason = outcome.reason {
            resolvedDefaults["profileReason"] = .string(reason.rawValue)
        }
        if let message = outcome.message {
            resolvedDefaults["profileMessage"] = .string(message)
        }
        if let toolVersion = outcome.toolVersion {
            resolvedDefaults["brackenToolVersion"] = .string(toolVersion)
        }
        return ProvenanceOptions(
            explicit: explicit,
            defaults: defaults,
            resolvedDefaults: resolvedDefaults
        )
    }

    private func kraken2ResolvedOptions(
        config: ClassificationConfig
    ) -> [String: ParameterValue] {
        [
            "databasePath": .string(config.databasePath.path),
            "databaseDigest": config.databaseDigest.map(ParameterValue.string) ?? .null,
            "databaseIdentityStatus": .string(databaseIdentityStatus(config: config)),
            "databaseCoreFileSizes": databaseCoreFileSizesOption(at: config.databasePath),
            "confidence": .number(config.confidence),
            "minimumHitGroups": .integer(config.minimumHitGroups),
            "threads": .integer(config.threads),
            "memoryMapping": .boolean(config.memoryMapping),
            "pairedEnd": .boolean(config.isPairedEnd),
            "quickMode": .boolean(config.quickMode),
            "inputFormat": .string(config.inputFormat.rawValue),
            "reportMinimizerData": .boolean(true),
            "extraArgs": .string(AdvancedCommandLineOptions.join(config.extraArguments)),
        ]
    }

    private func databaseIdentityStatus(config: ClassificationConfig) -> String {
        config.databaseDigest == nil
            ? "unresolved-bounded-metadata"
            : "provided-aggregate-digest"
    }

    private func databaseCoreFileSizesOption(at databasePath: URL) -> ParameterValue {
        .dictionary(
            databaseCoreFileSizes(at: databasePath).mapValues { size in
                .integer(Int(min(size, UInt64(Int.max))))
            }
        )
    }

    private func kraken2GithubReleaseVersion(for detectedVersion: String) -> String? {
        func normalized(_ version: String) -> String {
            let trimmed = version.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.lowercased().hasPrefix("v") ? String(trimmed.dropFirst()) : trimmed
        }
        return normalized(detectedVersion) == normalized(Self.kraken2GithubReleaseVersion)
            ? Self.kraken2GithubReleaseVersion
            : nil
    }

    private func brackenResolvedOptions(
        resolution: BrackenProfileResolution,
        distributionURL: URL,
        dialect: BrackenCLIDialect? = nil,
        effectiveArgv: [String]? = nil
    ) -> [String: ParameterValue] {
        var options: [String: ParameterValue] = [
            "requestedRank": .string(resolution.request.provenanceValue),
            "resolvedRank": .string(resolution.rank.code),
            "resolutionSource": .string(resolution.source.rawValue),
            "readLength": .integer(resolution.readLength),
            "threshold": .integer(resolution.threshold),
            "distributionPath": .string(distributionURL.path),
        ]
        // Record which CLI form actually ran, and the argv it ran with, so a
        // reader of the provenance can tell the real Bracken driver apart from
        // the `est_abundance.py` passthrough wrapper.
        if let dialect {
            options["brackenCLIDialect"] = .string(dialect.rawValue)
        }
        if let effectiveArgv {
            options["effectiveArgv"] = .string(effectiveArgv.joined(separator: " "))
        }
        return options
    }

    private func managedRuntimeIdentity(
        toolName: String,
        environment: String
    ) -> ProvenanceRuntimeIdentity {
        let prefix = condaManager.rootPrefix.appendingPathComponent(
            "envs/\(environment)",
            isDirectory: true
        )
        return ProvenanceRuntimeIdentity(
            executablePath: prefix.appendingPathComponent("bin/\(toolName)").path,
            condaEnvironment: environment,
            condaPrefix: prefix.path,
            pluginPack: "Metagenomics"
        )
    }

    private func classificationResultOutputRecords(
        reportURL: URL,
        outputURL: URL,
        brackenURL: URL?
    ) -> [FileRecord] {
        let fm = FileManager.default
        var records = [
            ProvenanceRecorder.fileRecord(url: reportURL, format: .text, role: .report),
            ProvenanceRecorder.fileRecord(url: outputURL, format: .text, role: .output),
        ]
        let indexURL = KrakenIndexDatabase.indexURL(for: outputURL)
        if fm.fileExists(atPath: indexURL.path) {
            records.append(ProvenanceRecorder.fileRecord(url: indexURL, format: .unknown, role: .index))
        }
        if let brackenURL {
            records.append(ProvenanceRecorder.fileRecord(url: brackenURL, format: .text, role: .output))
        }
        return records
    }

    private func compactKrakenOutputIfPossible(
        rawURL: URL,
        provenanceRecorder: ProvenanceRecorder,
        runID: UUID,
        dependsOn: [UUID]
    ) async -> URL? {
        let fm = FileManager.default
        guard fm.fileExists(atPath: rawURL.path) else { return nil }

        let compressedURL = rawURL.appendingPathExtension("gz")
        let indexURL = KrakenIndexDatabase.indexURL(for: compressedURL)
        let indexStartedAt = Date()

        do {
            try? fm.removeItem(at: indexURL)
            try KrakenIndexDatabase.build(
                from: rawURL,
                to: indexURL,
                includeUnclassified: false
            )
            let indexCompletedAt = Date()
            _ = await provenanceRecorder.recordStep(
                runID: runID,
                toolName: "lungfish-kraken2-index",
                toolVersion: WorkflowRun.currentAppVersion,
                command: [
                    CLICommandIdentity.executableName,
                    "internal",
                    "kraken2-index",
                    "--classified-only",
                    rawURL.path,
                    indexURL.path,
                ],
                inputs: [
                    ProvenanceRecorder.fileRecord(url: rawURL, format: .text, role: .input),
                ],
                outputs: [
                    ProvenanceRecorder.fileRecord(url: indexURL, format: .unknown, role: .index),
                ],
                exitCode: 0,
                wallTime: indexCompletedAt.timeIntervalSince(indexStartedAt),
                dependsOn: dependsOn
            )

            let gzipStartedAt = Date()
            try gzipCopy(source: rawURL, destination: compressedURL)
            let gzipCompletedAt = Date()
            _ = await provenanceRecorder.recordStep(
                runID: runID,
                toolName: "gzip",
                toolVersion: "system",
                command: gzipReplayCommand(source: rawURL, destination: compressedURL),
                inputs: [
                    ProvenanceRecorder.fileRecord(url: rawURL, format: .text, role: .input),
                ],
                outputs: [
                    ProvenanceRecorder.fileRecord(url: compressedURL, format: .text, role: .output),
                ],
                exitCode: 0,
                wallTime: gzipCompletedAt.timeIntervalSince(gzipStartedAt),
                dependsOn: dependsOn
            )

            try fm.removeItem(at: rawURL)
            logger.info(
                "Compacted Kraken2 output to \(compressedURL.lastPathComponent, privacy: .public) and \(indexURL.lastPathComponent, privacy: .public)"
            )
            return compressedURL
        } catch {
            logger.warning("Failed to compact Kraken2 output; retaining raw output: \(error.localizedDescription, privacy: .public)")
            try? fm.removeItem(at: compressedURL)
            try? fm.removeItem(at: indexURL)
        }
        return nil
    }

    private func gzipReplayCommand(source: URL, destination: URL) -> [String] {
        let command = "/usr/bin/gzip -c \(shellEscape(source.path)) > \(shellEscape(destination.path))"
        return ["/bin/sh", "-c", command]
    }

    private func gzipCopy(source: URL, destination: URL) throws {
        let fm = FileManager.default
        try? fm.removeItem(at: destination)
        fm.createFile(atPath: destination.path, contents: nil)
        let outputHandle = try FileHandle(forWritingTo: destination)
        defer { outputHandle.closeFile() }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/gzip")
        process.arguments = ["-c", source.path]
        process.standardOutput = outputHandle
        let stderr = Pipe()
        process.standardError = stderr
        try process.run()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            let stderrText = String(
                data: stderr.fileHandleForReading.readDataToEndOfFile(),
                encoding: .utf8
            ) ?? ""
            throw ClassificationPipelineError.kraken2Failed(
                exitCode: process.terminationStatus,
                stderr: stderrText
            )
        }
    }

    // MARK: - Memory Mapping Auto-Enable

    /// Determines whether memory mapping should be auto-enabled for the given config.
    ///
    /// Memory mapping is auto-enabled when the database size exceeds 80% of the
    /// system's physical RAM and the user has not already enabled it.
    ///
    /// - Parameter config: The classification configuration.
    /// - Returns: `true` if memory mapping should be auto-enabled.
    func shouldAutoEnableMemoryMapping(config: ClassificationConfig) -> Bool {
        guard !config.memoryMapping else { return false }

        let systemRAM = ProcessInfo.processInfo.physicalMemory
        let threshold = UInt64(Double(systemRAM) * 0.8)

        let dbSize = estimateDatabaseSize(at: config.databasePath)
        return dbSize > threshold
    }

    /// Estimates the total size of a Kraken2 database directory.
    ///
    /// Sums the sizes of the key database files (hash.k2d, taxo.k2d, opts.k2d).
    ///
    /// - Parameter path: Path to the database directory.
    /// - Returns: Total estimated size in bytes.
    private func estimateDatabaseSize(at path: URL) -> UInt64 {
        databaseCoreFileSizes(at: path).values.reduce(0, +)
    }

    /// Reads bounded metadata for the three core Kraken2 database files.
    ///
    /// This deliberately does not enumerate or hash the database directory:
    /// custom databases can be hundreds of gigabytes, and legacy registrations
    /// may not have an installation digest. Callers must keep that missing digest
    /// explicit rather than presenting this size snapshot as a content checksum.
    private func databaseCoreFileSizes(at path: URL) -> [String: UInt64] {
        let fm = FileManager.default
        let keyFiles = ["hash.k2d", "taxo.k2d", "opts.k2d"]
        var sizes: [String: UInt64] = [:]

        for filename in keyFiles {
            let filePath = path.appendingPathComponent(filename).path
            if let attrs = try? fm.attributesOfItem(atPath: filePath),
               let size = attrs[.size] as? UInt64 {
                sizes[filename] = size
            }
        }

        return sizes
    }

}

private extension ClassificationConfig {
    func withProfileRequest(_ request: BrackenProfileRequest) -> ClassificationConfig {
        var profiled = ClassificationConfig(
            goal: .profile,
            inputFiles: inputFiles,
            isPairedEnd: isPairedEnd,
            databaseName: databaseName,
            inputFormat: inputFormat,
            databaseVersion: databaseVersion,
            databasePath: databasePath,
            databaseDigest: databaseDigest,
            databaseCatalogID: databaseCatalogID,
            databaseInstallationRecipe: databaseInstallationRecipe,
            brackenProfileRequest: request,
            confidence: confidence,
            minimumHitGroups: minimumHitGroups,
            threads: threads,
            memoryMapping: memoryMapping,
            quickMode: quickMode,
            outputDirectory: outputDirectory,
            extraArguments: extraArguments
        )
        profiled.sampleDisplayName = sampleDisplayName
        profiled.originalInputFiles = originalInputFiles
        return profiled
    }
}

// MARK: - Kraken2 Progress Parsing

/// Parses a Kraken2 stderr progress line and reports it via the progress callback.
///
/// Kraken2 writes lines like:
/// ```
///   12345 sequences (1.2 Mbp) processed
/// ```
///
/// This function extracts the sequence count and reports it in the 0.30--0.80
/// progress range used by the classification pipeline. Since we don't know the
/// total sequence count upfront, we use the count itself as an informational
/// message without computing a fraction.
///
/// - Parameters:
///   - line: A single line from kraken2's stderr output.
///   - progress: The pipeline's progress callback.
func parseKraken2ProgressLine(
    _ line: String,
    progress: @Sendable (Double, String) -> Void
) {
    // Match lines like "  12345 sequences (1.2 Mbp) processed"
    let trimmed = line.trimmingCharacters(in: .whitespaces)
    guard trimmed.contains("sequences") && trimmed.contains("processed") else { return }

    // Extract the sequence count (first number in the line)
    let parts = trimmed.split(separator: " ", omittingEmptySubsequences: true)
    guard let countStr = parts.first, let count = Int(countStr) else { return }

    // Report in the kraken2 execution progress range (0.30 -- 0.80).
    // We can't compute a true fraction since we don't know total reads,
    // so report a fixed 0.50 progress with a descriptive message.
    let formattedCount: String
    if count >= 1_000_000 {
        formattedCount = String(format: "%.1fM", Double(count) / 1_000_000)
    } else if count >= 1_000 {
        formattedCount = String(format: "%.1fK", Double(count) / 1_000)
    } else {
        formattedCount = String(count)
    }

    progress(0.50, "Classifying: \(formattedCount) sequences processed...")
}
