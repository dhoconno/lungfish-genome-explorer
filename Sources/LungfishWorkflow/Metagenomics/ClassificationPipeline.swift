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

    /// Creates a classification pipeline.
    ///
    /// - Parameter condaManager: The conda manager to use (default: shared).
    public init(condaManager: CondaManager = .shared) {
        self.condaManager = condaManager
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

        // Phase 1: Validation (0.0 -- 0.10)
        progress?(0.0, "Validating configuration...")
        try config.validate()

        // Create output directory if needed.
        let fm = FileManager.default
        if !fm.fileExists(atPath: config.outputDirectory.path) {
            do {
                try fm.createDirectory(
                    at: config.outputDirectory,
                    withIntermediateDirectories: true
                )
            } catch {
                throw ClassificationConfigError.outputDirectoryCreationFailed(
                    config.outputDirectory, error
                )
            }
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

        // Begin provenance recording.
        let provenanceRecorder = ProvenanceRecorder.shared
        let profileResolution = profileRequest.map {
            BrackenDatabaseCapabilities.resolve(
                catalogID: effectiveConfig.databaseCatalogID,
                installationRecipe: effectiveConfig.databaseInstallationRecipe,
                request: $0
            )
        }
        let runParameters = classificationRunParameters(
            config: effectiveConfig,
            resolution: profileResolution
        )
        let runID = await provenanceRecorder.beginRun(
            name: profileRequest != nil ? "Metagenomics Profiling" : "Metagenomics Classification",
            parameters: runParameters
        )

        // Phase 3: Run kraken2 (0.30 -- 0.80)
        let kraken2Args = effectiveConfig.kraken2Arguments()
        let kraken2Command = ["kraken2"] + kraken2Args
        let inputRecords = effectiveConfig.inputFiles.map { url in
            ProvenanceRecorder.fileRecord(
                url: url,
                format: effectiveConfig.provenanceInputFileFormat,
                role: .input
            )
        }
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
                config: effectiveConfig,
                toolVersion: toolVersion,
                command: kraken2Command,
                inputs: inputRecords,
                exitCode: 130,
                stderr: "Kraken2 classification cancelled.",
                startedAt: kraken2Start
            )
            try await persistInterruptedClassificationRun(
                provenanceRecorder: provenanceRecorder,
                runID: runID,
                config: effectiveConfig,
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
                config: effectiveConfig,
                toolVersion: toolVersion,
                command: kraken2Command,
                inputs: inputRecords,
                exitCode: unavailable ? 127 : 1,
                stderr: error.localizedDescription,
                startedAt: kraken2Start
            )
            try await persistInterruptedClassificationRun(
                provenanceRecorder: provenanceRecorder,
                runID: runID,
                config: effectiveConfig,
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
                config: effectiveConfig,
                toolVersion: toolVersion,
                command: kraken2Command,
                inputs: inputRecords,
                exitCode: 1,
                stderr: error.localizedDescription,
                startedAt: kraken2Start
            )
            try await persistInterruptedClassificationRun(
                provenanceRecorder: provenanceRecorder,
                runID: runID,
                config: effectiveConfig,
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
            githubReleaseVersion: Self.kraken2GithubReleaseVersion,
            command: kraken2Command,
            resolvedOptions: kraken2ResolvedOptions(config: effectiveConfig),
            runtimeIdentity: kraken2RuntimeIdentity,
            inputs: inputRecords,
            outputs: kraken2Outputs,
            exitCode: kraken2Result.exitCode,
            wallTime: kraken2WallTime,
            stderr: kraken2Result.stderr
        )

        if kraken2Result.exitCode != 0 {
            try await persistInterruptedClassificationRun(
                provenanceRecorder: provenanceRecorder,
                runID: runID,
                config: effectiveConfig,
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
                config: effectiveConfig,
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
                config: effectiveConfig,
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
                    config: effectiveConfig,
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
            config: effectiveConfig,
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

    private func recordKraken2Failure(
        provenanceRecorder: ProvenanceRecorder,
        runID: UUID,
        config: ClassificationConfig,
        toolVersion: String,
        command: [String],
        inputs: [FileRecord],
        exitCode: Int32,
        stderr: String,
        startedAt: Date
    ) async {
        let fileManager = FileManager.default
        let outputs: [FileRecord] = [
            (config.reportURL, FileFormat.text, FileRole.report),
            (config.outputURL, FileFormat.text, FileRole.output),
        ].compactMap { url, format, role in
            guard fileManager.fileExists(atPath: url.path) else { return nil }
            return ProvenanceRecorder.fileRecord(url: url, format: format, role: role)
        }
        _ = await provenanceRecorder.recordStep(
            runID: runID,
            toolName: "kraken2",
            toolVersion: toolVersion,
            githubReleaseVersion: Self.kraken2GithubReleaseVersion,
            command: command,
            resolvedOptions: kraken2ResolvedOptions(config: config),
            runtimeIdentity: managedRuntimeIdentity(
                toolName: "kraken2",
                environment: Self.kraken2Environment
            ),
            inputs: inputs,
            outputs: outputs,
            exitCode: exitCode,
            wallTime: Date().timeIntervalSince(startedAt),
            stderr: stderr
        )
    }

    private func persistInterruptedClassificationRun(
        provenanceRecorder: ProvenanceRecorder,
        runID: UUID,
        config: ClassificationConfig,
        resolution: BrackenProfileResolution?,
        status: RunStatus,
        profileState: String
    ) async throws {
        await provenanceRecorder.completeRun(runID, status: status)
        try await provenanceRecorder.save(
            runID: runID,
            to: config.outputDirectory,
            options: classificationProvenanceOptions(
                config: config,
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
        let distributionURL = config.databasePath.appendingPathComponent(
            "database\(resolution.readLength)mers.kmer_distrib"
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
        let brackenVersion = await detectToolVersion(
            toolName: "bracken",
            environment: Self.brackenEnvironment,
            condaManager: condaManager,
            flags: ["-v"]
        )
        logger.info("Detected bracken version: \(brackenVersion, privacy: .public)")
        try Task.checkCancellation()

        let brackenArgs = [
            "-d", config.databasePath.path,
            "-i", config.reportURL.path,
            "-o", config.brackenURL.path,
            "-r", String(resolution.readLength),
            "-l", levelCode,
            "-t", String(resolution.threshold),
        ]
        let brackenCommand = ["bracken"] + brackenArgs
        let brackenInputs = [
            ProvenanceRecorder.fileRecord(url: config.reportURL, format: .text, role: .input),
            ProvenanceRecorder.fileRecord(url: distributionURL, format: .unknown, role: .reference),
        ]
        let resolvedOptions = brackenResolvedOptions(
            resolution: resolution,
            distributionURL: distributionURL
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
        if processResult.exitCode != 0 {
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
            "github_release_version": .string(Self.kraken2GithubReleaseVersion),
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
        config: ClassificationConfig,
        resolution: BrackenProfileResolution?,
        outcome: BrackenProfileOutcome,
        profileState: String? = nil
    ) -> ProvenanceOptions {
        var explicit: [String: ParameterValue] = [
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
            "extraArgs": .string(AdvancedCommandLineOptions.join(config.extraArguments)),
        ]
        var defaults: [String: ParameterValue] = [:]
        var resolvedDefaults: [String: ParameterValue] = [
            "effectiveMemoryMapping": .boolean(config.memoryMapping),
            "profileState": .string(profileState ?? outcome.state.rawValue),
        ]
        if let resolution {
            let request = config.brackenProfileRequest ?? .automaticDefault
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
            "confidence": .number(config.confidence),
            "minimumHitGroups": .integer(config.minimumHitGroups),
            "threads": .integer(config.threads),
            "memoryMapping": .boolean(config.memoryMapping),
            "pairedEnd": .boolean(config.isPairedEnd),
        ]
    }

    private func brackenResolvedOptions(
        resolution: BrackenProfileResolution,
        distributionURL: URL
    ) -> [String: ParameterValue] {
        [
            "requestedRank": .string(resolution.request.provenanceValue),
            "resolvedRank": .string(resolution.rank.code),
            "resolutionSource": .string(resolution.source.rawValue),
            "readLength": .integer(resolution.readLength),
            "threshold": .integer(resolution.threshold),
            "distributionPath": .string(distributionURL.path),
        ]
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
                toolVersion: Self.kraken2GithubReleaseVersion,
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
        let fm = FileManager.default
        let keyFiles = ["hash.k2d", "taxo.k2d", "opts.k2d"]
        var totalSize: UInt64 = 0

        for filename in keyFiles {
            let filePath = path.appendingPathComponent(filename).path
            if let attrs = try? fm.attributesOfItem(atPath: filePath),
               let size = attrs[.size] as? UInt64 {
                totalSize += size
            }
        }

        return totalSize
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
