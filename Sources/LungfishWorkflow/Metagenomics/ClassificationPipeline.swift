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
            runBracken: false,
            brackenReadLength: 150,
            brackenLevel: .species,
            brackenThreshold: 10,
            progress: progress
        )
    }

    /// Runs Kraken2 classification followed by Bracken abundance profiling.
    ///
    /// Bracken re-estimates abundance at the specified taxonomic level by
    /// redistributing reads from higher levels. The result tree will have
    /// ``TaxonNode/brackenReads`` and ``TaxonNode/brackenFraction`` populated
    /// on matched nodes.
    ///
    /// - Parameters:
    ///   - config: The classification configuration.
    ///   - brackenReadLength: Read length for Bracken's `-r` flag (default: 150).
    ///   - brackenLevel: Taxonomic level for abundance estimation (default: species).
    ///   - brackenThreshold: Minimum read count threshold for Bracken (default: 10).
    ///   - progress: Optional progress callback.
    /// - Returns: A ``ClassificationResult`` with Bracken-augmented tree.
    /// - Throws: ``ClassificationConfigError`` or ``ClassificationPipelineError``.
    public func profile(
        config: ClassificationConfig,
        brackenReadLength: Int = 150,
        brackenLevel: TaxonomicRank = .species,
        brackenThreshold: Int = 10,
        progress: (@Sendable (Double, String) -> Void)? = nil
    ) async throws -> ClassificationResult {
        try await runPipeline(
            config: config,
            runBracken: true,
            brackenReadLength: brackenReadLength,
            brackenLevel: brackenLevel,
            brackenThreshold: brackenThreshold,
            progress: progress
        )
    }

    // MARK: - Private Pipeline

    /// Core pipeline implementation shared by `classify` and `profile`.
    private func runPipeline(
        config: ClassificationConfig,
        runBracken: Bool,
        brackenReadLength: Int,
        brackenLevel: TaxonomicRank,
        brackenThreshold: Int,
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

        // Phase 2: Version detection (0.10 -- 0.30)
        let toolVersion = await detectKraken2Version()
        logger.info("Detected kraken2 version: \(toolVersion, privacy: .public)")

        // Detect bracken version separately when profiling (Gap 22 fix).
        let brackenVersion: String
        if runBracken {
            brackenVersion = await detectBrackenVersion()
            logger.info("Detected bracken version: \(brackenVersion, privacy: .public)")
        } else {
            brackenVersion = "unknown"
        }

        progress?(0.30, "Running kraken2...")

        // Begin provenance recording.
        let provenanceRecorder = ProvenanceRecorder.shared
        let runID = await provenanceRecorder.beginRun(
            name: runBracken ? "Metagenomics Profiling" : "Metagenomics Classification",
            parameters: [
                "database": .string(effectiveConfig.databaseName),
                "confidence": .number(effectiveConfig.confidence),
                "minimumHitGroups": .integer(effectiveConfig.minimumHitGroups),
                "threads": .integer(effectiveConfig.threads),
                "pairedEnd": .boolean(effectiveConfig.isPairedEnd),
                "memoryMapping": .boolean(effectiveConfig.memoryMapping),
            ]
        )

        // Phase 3: Run kraken2 (0.30 -- 0.80)
        let kraken2Args = effectiveConfig.kraken2Arguments()
        let kraken2Command = ["kraken2"] + kraken2Args

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
        } catch let error as CondaError {
            await provenanceRecorder.completeRun(runID, status: .failed)
            if case .toolNotFound = error {
                throw ClassificationPipelineError.kraken2NotInstalled
            }
            throw error
        }

        let kraken2WallTime = Date().timeIntervalSince(kraken2Start)

        // Record kraken2 provenance step.
        let inputRecords = effectiveConfig.inputFiles.map { url in
            FileRecord(path: url.path, format: .fastq, role: .input)
        }
        let kraken2Outputs = [
            FileRecord(path: effectiveConfig.reportURL.path, format: .text, role: .report),
            FileRecord(path: effectiveConfig.outputURL.path, format: .text, role: .output),
        ]
        let kraken2StepID = await provenanceRecorder.recordStep(
            runID: runID,
            toolName: "kraken2",
            toolVersion: toolVersion,
            command: kraken2Command,
            inputs: inputRecords,
            outputs: kraken2Outputs,
            exitCode: kraken2Result.exitCode,
            wallTime: kraken2WallTime,
            stderr: kraken2Result.stderr
        )

        if kraken2Result.exitCode != 0 {
            await provenanceRecorder.completeRun(runID, status: .failed)
            throw ClassificationPipelineError.kraken2Failed(
                exitCode: kraken2Result.exitCode,
                stderr: kraken2Result.stderr
            )
        }

        progress?(0.80, "Parsing classification report...")

        // Phase 4: Parse kreport (0.80 -- 0.90)
        guard fm.fileExists(atPath: effectiveConfig.reportURL.path) else {
            await provenanceRecorder.completeRun(runID, status: .failed)
            throw ClassificationPipelineError.kreportNotProduced(effectiveConfig.reportURL)
        }

        var tree = try KreportParser.parse(url: effectiveConfig.reportURL)

        let totalReads = tree.totalReads
        let speciesCount = tree.speciesCount
        logger.info("Parsed kreport: \(totalReads, privacy: .public) total reads, \(speciesCount, privacy: .public) species")

        progress?(0.90, runBracken ? "Running Bracken profiling..." : "Recording provenance...")

        // Phase 5: Optional Bracken (0.90 -- 0.95)
        var brackenOutputURL: URL?
        if runBracken {
            let levelCode = brackenLevelCode(for: brackenLevel)
            let brackenArgs = [
                "-d", effectiveConfig.databasePath.path,
                "-i", effectiveConfig.reportURL.path,
                "-o", effectiveConfig.brackenURL.path,
                "-r", String(brackenReadLength),
                "-l", levelCode,
                "-t", String(brackenThreshold),
            ]
            let brackenCommand = ["bracken"] + brackenArgs

            logger.info("Running: bracken \(brackenArgs.joined(separator: " "), privacy: .public)")

            let brackenStart = Date()
            let brackenResult: (stdout: String, stderr: String, exitCode: Int32)
            do {
                brackenResult = try await condaManager.runTool(
                    name: "bracken",
                    arguments: brackenArgs,
                    environment: Self.brackenEnvironment,
                    timeout: 3600
                )
            } catch let error as CondaError {
                await provenanceRecorder.completeRun(runID, status: .failed)
                if case .toolNotFound = error {
                    throw ClassificationPipelineError.brackenNotInstalled
                }
                throw error
            }

            let brackenWallTime = Date().timeIntervalSince(brackenStart)

            // Record bracken provenance step with dependency on kraken2.
            // Uses separately detected bracken version (Gap 22 fix).
            let brackenInputs = [
                FileRecord(path: effectiveConfig.reportURL.path, format: .text, role: .input),
            ]
            let brackenOutputRecords = [
                FileRecord(path: effectiveConfig.brackenURL.path, format: .text, role: .output),
            ]
            let dependsOn: [UUID] = kraken2StepID.map { [$0] } ?? []
            await provenanceRecorder.recordStep(
                runID: runID,
                toolName: "bracken",
                toolVersion: brackenVersion,
                command: brackenCommand,
                inputs: brackenInputs,
                outputs: brackenOutputRecords,
                exitCode: brackenResult.exitCode,
                wallTime: brackenWallTime,
                stderr: brackenResult.stderr,
                dependsOn: dependsOn
            )

            if brackenResult.exitCode != 0 {
                // Bracken failure is non-fatal -- log warning but continue with kraken2-only results.
                let exitCode = brackenResult.exitCode
                let stderrText = brackenResult.stderr
                logger.warning("Bracken failed (exit \(exitCode, privacy: .public)): \(stderrText, privacy: .public)")
            } else if fm.fileExists(atPath: effectiveConfig.brackenURL.path) {
                // Merge bracken results into the tree.
                try BrackenParser.mergeBracken(url: effectiveConfig.brackenURL, into: &tree)
                brackenOutputURL = effectiveConfig.brackenURL
                logger.info("Bracken profiling merged successfully")
            }
        }

        progress?(0.95, "Saving provenance...")

        // Phase 6: Complete provenance (0.95 -- 1.0)
        await provenanceRecorder.completeRun(runID, status: .completed)

        do {
            try await provenanceRecorder.save(runID: runID, to: effectiveConfig.outputDirectory)
        } catch {
            // Provenance save failure is non-fatal.
            logger.warning("Failed to save provenance: \(error.localizedDescription, privacy: .public)")
        }

        let totalRuntime = Date().timeIntervalSince(startTime)

        let result = ClassificationResult(
            config: effectiveConfig,
            tree: tree,
            reportURL: effectiveConfig.reportURL,
            outputURL: effectiveConfig.outputURL,
            brackenURL: brackenOutputURL,
            runtime: totalRuntime,
            toolVersion: toolVersion,
            provenanceId: runID
        )

        // Build the Kraken index sidecar for fast taxon-specific lookups
        // (BLAST verification, sequence extraction). Non-fatal if it fails.
        do {
            let krakenURL = effectiveConfig.outputURL
            let indexURL = KrakenIndexDatabase.indexURL(for: krakenURL)
            try KrakenIndexDatabase.build(from: krakenURL, to: indexURL)
            logger.info("Built classification index at \(indexURL.lastPathComponent, privacy: .public)")
        } catch {
            logger.warning("Failed to build classification index: \(error.localizedDescription, privacy: .public)")
        }

        progress?(1.0, "Classification complete")

        let runtimeStr = String(format: "%.1f", totalRuntime)
        logger.info("Pipeline complete: \(totalReads, privacy: .public) reads, \(speciesCount, privacy: .public) species, \(runtimeStr, privacy: .public)s")

        return result
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

    // MARK: - Version Detection

    /// Detects the kraken2 version by running `kraken2 --version`.
    ///
    /// - Returns: The version string, or "unknown" if detection fails.
    private func detectKraken2Version() async -> String {
        do {
            let result = try await condaManager.runTool(
                name: "kraken2",
                arguments: ["--version"],
                environment: Self.kraken2Environment,
                timeout: 30
            )
            // kraken2 --version outputs something like "Kraken version 2.1.3"
            let versionLine = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            if let range = versionLine.range(of: #"\d+\.\d+(\.\d+)?"#, options: .regularExpression) {
                return String(versionLine[range])
            }
            // Fall back to full output if regex fails.
            return versionLine.isEmpty ? "unknown" : versionLine
        } catch {
            logger.debug("kraken2 --version failed: \(error.localizedDescription, privacy: .public)")
            return "unknown"
        }
    }

    /// Detects the bracken version by running `bracken --version` or `bracken -v`.
    ///
    /// Bracken may report its version differently from kraken2, so this method
    /// detects it independently rather than assuming it matches the kraken2 install
    /// (Gap 22 fix). Tries `--version` first, then `-v` as a fallback.
    ///
    /// - Returns: The version string, or "unknown" if detection fails.
    private func detectBrackenVersion() async -> String {
        for flag in ["--version", "-v"] {
            do {
                let result = try await condaManager.runTool(
                    name: "bracken",
                    arguments: [flag],
                    environment: Self.brackenEnvironment,
                    timeout: 30
                )
                // Bracken may output "Bracken v2.9" or "bracken 2.9" or similar.
                // Check both stdout and stderr since different versions may write
                // the version to different streams.
                let combined = result.stdout + result.stderr
                let trimmed = combined.trimmingCharacters(in: .whitespacesAndNewlines)
                if let range = trimmed.range(
                    of: #"\d+\.\d+(\.\d+)?"#,
                    options: .regularExpression
                ) {
                    return String(trimmed[range])
                }
                if !trimmed.isEmpty {
                    return trimmed.components(separatedBy: .newlines).first ?? trimmed
                }
            } catch {
                // Try next flag variant
                continue
            }
        }

        logger.debug("bracken version detection failed with both --version and -v")
        return "unknown"
    }

    // MARK: - Helpers

    /// Maps a ``TaxonomicRank`` to the Bracken `-l` flag letter.
    ///
    /// - Parameter rank: The taxonomic rank.
    /// - Returns: A single-letter code string.
    private func brackenLevelCode(for rank: TaxonomicRank) -> String {
        switch rank {
        case .domain: return "D"
        case .phylum: return "P"
        case .class: return "C"
        case .order: return "O"
        case .family: return "F"
        case .genus: return "G"
        case .species: return "S"
        default: return "S" // Default to species
        }
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
