// EsVirituPipeline.swift - EsViritu viral metagenomics detection orchestrator
// Copyright (c) 2025 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation

import os.log

private let logger = Logger(subsystem: "com.lungfish.workflow", category: "EsVirituPipeline")

// MARK: - EsVirituPipelineError

/// Errors produced during EsViritu pipeline execution.
public enum EsVirituPipelineError: Error, LocalizedError, Sendable {

    /// EsViritu exited with a non-zero status.
    case esVirituFailed(exitCode: Int32, stderr: String)

    /// The EsViritu tool is not installed in the conda environment.
    case esVirituNotInstalled

    /// The detection output file was not produced.
    case detectionOutputNotProduced(URL)

    /// Could not determine the EsViritu version.
    case versionDetectionFailed

    /// The pipeline was cancelled.
    case cancelled

    public var errorDescription: String? {
        switch self {
        case .esVirituFailed(let code, let stderr):
            return "EsViritu failed with exit code \(code): \(stderr)"
        case .esVirituNotInstalled:
            return "EsViritu is not installed. Run: lungfish conda install --pack metagenomics"
        case .detectionOutputNotProduced(let url):
            return "EsViritu did not produce a detection output at \(url.path)"
        case .versionDetectionFailed:
            return "Could not determine EsViritu version"
        case .cancelled:
            return "EsViritu pipeline was cancelled"
        }
    }
}

// MARK: - EsVirituResult

/// The result of a completed EsViritu pipeline run.
///
/// Contains paths to all output files, detected virus count, runtime
/// metadata, and the provenance record ID for traceability.
///
/// ## Output Files
///
/// Every run produces:
/// - ``detectionURL``: Per-virus detection results TSV
/// - ``assemblyURL``: Assembly summary TSV (if viruses detected)
/// - ``taxProfileURL``: Taxonomic profile TSV
/// - ``coverageURL``: Per-window coverage TSV (if viruses detected)
///
/// ## Persistence
///
/// Use ``save(to:)`` to write a JSON sidecar (`esviritu-result.json`)
/// into the output directory.
public struct EsVirituResult: Sendable {

    /// The configuration that produced this result.
    public let config: EsVirituConfig

    /// Path to the detected virus information TSV.
    public let detectionURL: URL

    /// Path to the assembly summary TSV, if produced.
    public let assemblyURL: URL?

    /// Path to the taxonomic profile TSV, if produced.
    public let taxProfileURL: URL?

    /// Path to the virus coverage windows TSV, if produced.
    public let coverageURL: URL?

    /// Number of viruses detected.
    public let virusCount: Int

    /// Total wall-clock time for the pipeline run, in seconds.
    public let runtime: TimeInterval

    /// Version string of the EsViritu tool that was executed.
    public let toolVersion: String

    /// The provenance run ID, if provenance recording was enabled.
    public let provenanceId: UUID?

    /// Creates an EsViritu result.
    ///
    /// - Parameters:
    ///   - config: The configuration used for this run.
    ///   - detectionURL: Path to the detection output.
    ///   - assemblyURL: Path to the assembly summary, or `nil`.
    ///   - taxProfileURL: Path to the tax profile, or `nil`.
    ///   - coverageURL: Path to the coverage windows, or `nil`.
    ///   - virusCount: Number of detected viruses.
    ///   - runtime: Wall-clock time in seconds.
    ///   - toolVersion: EsViritu version string.
    ///   - provenanceId: Provenance run ID, or `nil`.
    public init(
        config: EsVirituConfig,
        detectionURL: URL,
        assemblyURL: URL?,
        taxProfileURL: URL?,
        coverageURL: URL?,
        virusCount: Int,
        runtime: TimeInterval,
        toolVersion: String,
        provenanceId: UUID?
    ) {
        self.config = config
        self.detectionURL = detectionURL
        self.assemblyURL = assemblyURL
        self.taxProfileURL = taxProfileURL
        self.coverageURL = coverageURL
        self.virusCount = virusCount
        self.runtime = runtime
        self.toolVersion = toolVersion
        self.provenanceId = provenanceId
    }

    // MARK: - Convenience

    /// A human-readable summary of the EsViritu result.
    public var summary: String {
        var lines: [String] = []
        lines.append("EsViritu Detection Summary")
        lines.append("  Sample: \(config.sampleName)")
        lines.append("  Viruses detected: \(virusCount)")
        lines.append("  Quality filter: \(config.qualityFilter ? "yes" : "no")")
        lines.append("  Paired-end: \(config.isPairedEnd ? "yes" : "no")")

        let runtimeStr = String(format: "%.1f", runtime)
        lines.append("  Runtime: \(runtimeStr)s")
        lines.append("  Tool: EsViritu \(toolVersion)")

        return lines.joined(separator: "\n")
    }
}

// MARK: - Persistence

/// The filename used for the serialized EsViritu result sidecar.
private let esVirituResultFilename = "esviritu-result.json"

extension EsVirituResult {

    /// Saves the EsViritu result metadata to a JSON file in the given directory.
    ///
    /// - Parameter directory: The directory to write `esviritu-result.json` into.
    /// - Throws: Encoding or file write errors.
    public func save(to directory: URL) throws {
        let sidecar = PersistedEsVirituResult(
            config: config,
            detectionPath: detectionURL.lastPathComponent,
            assemblyPath: assemblyURL?.lastPathComponent,
            taxProfilePath: taxProfileURL?.lastPathComponent,
            coveragePath: coverageURL?.lastPathComponent,
            virusCount: virusCount,
            runtime: runtime,
            toolVersion: toolVersion,
            provenanceId: provenanceId,
            savedAt: Date()
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(sidecar)

        let fileURL = directory.appendingPathComponent(esVirituResultFilename)
        try data.write(to: fileURL, options: .atomic)

        logger.info("Saved EsViritu result to \(fileURL.path)")
    }

    /// Loads an EsViritu result from a directory containing a saved sidecar.
    ///
    /// - Parameter directory: The directory containing `esviritu-result.json`.
    /// - Returns: A reconstituted ``EsVirituResult``.
    /// - Throws: ``EsVirituResultLoadError`` or decoding errors.
    public static func load(from directory: URL) throws -> EsVirituResult {
        let fileURL = directory.appendingPathComponent(esVirituResultFilename)

        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            throw EsVirituResultLoadError.sidecarNotFound(directory)
        }

        let data = try Data(contentsOf: fileURL)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let sidecar = try decoder.decode(PersistedEsVirituResult.self, from: data)

        let detectionURL = directory.appendingPathComponent(sidecar.detectionPath)
        let assemblyURL = sidecar.assemblyPath.map { directory.appendingPathComponent($0) }
        let taxProfileURL = sidecar.taxProfilePath.map { directory.appendingPathComponent($0) }
        let coverageURL = sidecar.coveragePath.map { directory.appendingPathComponent($0) }

        return EsVirituResult(
            config: sidecar.config,
            detectionURL: detectionURL,
            assemblyURL: assemblyURL,
            taxProfileURL: taxProfileURL,
            coverageURL: coverageURL,
            virusCount: sidecar.virusCount,
            runtime: sidecar.runtime,
            toolVersion: sidecar.toolVersion,
            provenanceId: sidecar.provenanceId
        )
    }

    /// Whether a saved EsViritu result exists in the given directory.
    ///
    /// - Parameter directory: The directory to check.
    /// - Returns: `true` if `esviritu-result.json` exists.
    public static func exists(in directory: URL) -> Bool {
        FileManager.default.fileExists(
            atPath: directory.appendingPathComponent(esVirituResultFilename).path
        )
    }
}

// MARK: - PersistedEsVirituResult

/// Codable representation of an EsViritu result for JSON serialization.
///
/// File paths are stored as relative filenames (not absolute paths) so the
/// sidecar remains valid if the output directory is moved.
struct PersistedEsVirituResult: Codable, Sendable {
    let config: EsVirituConfig
    let detectionPath: String
    let assemblyPath: String?
    let taxProfilePath: String?
    let coveragePath: String?
    let virusCount: Int
    let runtime: TimeInterval
    let toolVersion: String
    let provenanceId: UUID?
    let savedAt: Date
}

// MARK: - EsVirituResultLoadError

/// Errors that can occur when loading a persisted EsViritu result.
public enum EsVirituResultLoadError: Error, LocalizedError, Sendable {

    /// The `esviritu-result.json` sidecar was not found.
    case sidecarNotFound(URL)

    public var errorDescription: String? {
        switch self {
        case .sidecarNotFound(let url):
            return "No saved EsViritu result in \(url.path)"
        }
    }
}

// MARK: - EsVirituPipeline

/// Actor that orchestrates EsViritu viral detection on FASTQ samples.
///
/// The pipeline performs these steps:
///
/// 1. **Validate** the configuration (database exists, input files present).
/// 2. **Detect** the EsViritu version for provenance recording.
/// 3. **Run EsViritu** with the configured arguments.
/// 4. **Parse** the detection output to count detected viruses.
/// 5. **Record provenance** via ``ProvenanceRecorder``.
///
/// ## Progress
///
/// Progress is reported via a `@Sendable (Double, String) -> Void` callback:
///
/// | Range        | Phase |
/// |-------------|-------|
/// | 0.00 -- 0.05 | Validation and setup |
/// | 0.05 -- 0.15 | Version detection |
/// | 0.15 -- 0.85 | EsViritu execution |
/// | 0.85 -- 0.95 | Output parsing |
/// | 0.95 -- 1.00 | Provenance recording and cleanup |
///
/// ## Conda Environment
///
/// The pipeline expects EsViritu to be installed in a conda environment
/// named `esviritu` (matching the metagenomics plugin pack layout).
///
/// ## Usage
///
/// ```swift
/// let pipeline = EsVirituPipeline()
/// let config = EsVirituConfig(
///     inputFiles: [fastqURL],
///     isPairedEnd: false,
///     sampleName: "MySample",
///     outputDirectory: outputDir,
///     databasePath: dbPath
/// )
/// let result = try await pipeline.detect(config: config) { progress, message in
///     print("\(Int(progress * 100))% \(message)")
/// }
/// ```
public actor EsVirituPipeline {

    /// The conda environment name where EsViritu is installed.
    public static let esVirituEnvironment = "esviritu"

    /// Shared instance for convenience.
    public static let shared = EsVirituPipeline()

    /// The conda manager used for tool execution.
    private let condaManager: CondaManager

    /// Creates an EsViritu pipeline.
    ///
    /// - Parameter condaManager: The conda manager to use (default: shared).
    public init(condaManager: CondaManager = .shared) {
        self.condaManager = condaManager
    }

    // MARK: - Detection

    /// Runs EsViritu viral detection on the configured input files.
    ///
    /// - Parameters:
    ///   - config: The EsViritu configuration.
    ///   - progress: Optional progress callback.
    /// - Returns: An ``EsVirituResult`` with detection outputs.
    /// - Throws: ``EsVirituConfigError`` for invalid config,
    ///   ``EsVirituPipelineError`` for execution failures.
    public func detect(
        config: EsVirituConfig,
        progress: (@Sendable (Double, String) -> Void)? = nil
    ) async throws -> EsVirituResult {
        let startTime = Date()

        // Phase 1: Validation (0.00 -- 0.05)
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
                throw EsVirituConfigError.outputDirectoryCreationFailed(
                    config.outputDirectory, error
                )
            }
        }

        progress?(0.05, "Detecting EsViritu version...")

        // Phase 2: Version detection (0.05 -- 0.15)
        let toolVersion = await detectEsVirituVersion()
        logger.info("Detected EsViritu version: \(toolVersion)")

        progress?(0.15, "Running EsViritu...")

        // Symlink input files to a temp directory without spaces in the path.
        // EsViritu shells out to fastp/minimap2 via Python subprocess which
        // breaks on paths with spaces (known bioinformatics tool limitation).
        var effectiveConfig = config
        let symlinkDir = config.outputDirectory.appendingPathComponent("_input_links")
        var symlinkPaths: [URL] = []
        let needsSymlinks = config.inputFiles.contains { $0.path.contains(" ") }
            || config.outputDirectory.path.contains(" ")

        if needsSymlinks {
            try fm.createDirectory(at: symlinkDir, withIntermediateDirectories: true)
            for inputFile in config.inputFiles {
                let linkName = inputFile.lastPathComponent.replacingOccurrences(of: " ", with: "_")
                let linkURL = symlinkDir.appendingPathComponent(linkName)
                try? fm.removeItem(at: linkURL)
                try fm.createSymbolicLink(at: linkURL, withDestinationURL: inputFile)
                symlinkPaths.append(linkURL)
            }

            // If the output directory has spaces, use a temp directory and
            // copy results back later.
            let safeOutputDir: URL
            if config.outputDirectory.path.contains(" ") {
                safeOutputDir = fm.temporaryDirectory
                    .appendingPathComponent("esviritu-\(UUID().uuidString.prefix(8))")
                try fm.createDirectory(at: safeOutputDir, withIntermediateDirectories: true)
            } else {
                safeOutputDir = config.outputDirectory
            }

            effectiveConfig = EsVirituConfig(
                inputFiles: symlinkPaths,
                isPairedEnd: config.isPairedEnd,
                sampleName: config.sampleName,
                outputDirectory: safeOutputDir,
                databasePath: config.databasePath,
                qualityFilter: config.qualityFilter,
                threads: config.threads
            )
            logger.info("Created symlinks to avoid spaces in paths: \(symlinkPaths.map(\.lastPathComponent))")
        }

        // Begin provenance recording.
        let provenanceRecorder = ProvenanceRecorder.shared
        let runID = await provenanceRecorder.beginRun(
            name: "Viral Metagenomics Detection",
            parameters: [
                "sample": .string(config.sampleName),
                "qualityFilter": .boolean(config.qualityFilter),
                "threads": .integer(config.threads),
                "pairedEnd": .boolean(config.isPairedEnd),
            ]
        )

        // Phase 3: Run EsViritu (0.15 -- 0.85)
        let esVirituArgs = effectiveConfig.esVirituArguments()
        let esVirituCommand = ["EsViritu"] + esVirituArgs

        logger.info("Running: EsViritu \(esVirituArgs.joined(separator: " "))")

        let esVirituStart = Date()

        // Build stderr handler for progress parsing.
        let esVirituStderrHandler: (@Sendable (String) -> Void)?
        if let progressCallback = progress {
            esVirituStderrHandler = { (line: String) in
                parseEsVirituProgressLine(line, progress: progressCallback)
            }
        } else {
            esVirituStderrHandler = nil
        }

        // Estimate timeout based on file sizes: minimum 1 hour, scale with input.
        let inputSizeBytes = config.inputFiles.reduce(Int64(0)) { total, url in
            let attrs = try? fm.attributesOfItem(atPath: url.path)
            return total + (attrs?[.size] as? Int64 ?? 0)
        }
        let estimatedTimeout = max(3600.0, Double(inputSizeBytes) / 10_000_000.0)

        let esVirituResult: (stdout: String, stderr: String, exitCode: Int32)
        do {
            esVirituResult = try await condaManager.runTool(
                name: "EsViritu",
                arguments: esVirituArgs,
                environment: Self.esVirituEnvironment,
                environmentVariables: ["ESVIRITU_DB": effectiveConfig.databasePath.path],
                timeout: estimatedTimeout,
                stderrHandler: esVirituStderrHandler
            )
        } catch let error as CondaError {
            await provenanceRecorder.completeRun(runID, status: .failed)
            if case .toolNotFound = error {
                throw EsVirituPipelineError.esVirituNotInstalled
            }
            throw error
        }

        let esVirituWallTime = Date().timeIntervalSince(esVirituStart)

        // Record provenance step.
        let inputRecords = config.inputFiles.map { url in
            FileRecord(path: url.path, format: .fastq, role: .input)
        }
        let outputRecords = [
            FileRecord(path: config.detectionOutputURL.path, format: .text, role: .output),
        ]
        await provenanceRecorder.recordStep(
            runID: runID,
            toolName: "EsViritu",
            toolVersion: toolVersion,
            command: esVirituCommand,
            inputs: inputRecords,
            outputs: outputRecords,
            exitCode: esVirituResult.exitCode,
            wallTime: esVirituWallTime,
            stderr: esVirituResult.stderr
        )

        if esVirituResult.exitCode != 0 {
            await provenanceRecorder.completeRun(runID, status: .failed)
            throw EsVirituPipelineError.esVirituFailed(
                exitCode: esVirituResult.exitCode,
                stderr: esVirituResult.stderr
            )
        }

        progress?(0.85, "Parsing detection results...")

        // Phase 4: Copy results back if we used a temp output directory (0.85 -- 0.90)
        if needsSymlinks && effectiveConfig.outputDirectory != config.outputDirectory {
            progress?(0.85, "Copying results to project directory...")
            let tempOutput = effectiveConfig.outputDirectory
            let contents = (try? fm.contentsOfDirectory(at: tempOutput, includingPropertiesForKeys: nil)) ?? []
            for item in contents {
                let dest = config.outputDirectory.appendingPathComponent(item.lastPathComponent)
                try? fm.removeItem(at: dest)
                try? fm.moveItem(at: item, to: dest)
            }
            try? fm.removeItem(at: tempOutput)
            logger.info("Moved results from temp dir to \(config.outputDirectory.path)")
        }

        // Clean up input symlinks
        if needsSymlinks {
            try? fm.removeItem(at: symlinkDir)
        }

        // Phase 4b: Parse output (0.90 -- 0.95)
        progress?(0.90, "Parsing detection results...")

        guard fm.fileExists(atPath: config.detectionOutputURL.path) else {
            await provenanceRecorder.completeRun(runID, status: .failed)
            throw EsVirituPipelineError.detectionOutputNotProduced(config.detectionOutputURL)
        }

        // Count detected viruses from the TSV (skip header line).
        let virusCount = countDetectedViruses(at: config.detectionOutputURL)
        logger.info("Detected \(virusCount) viruses")

        // Check which optional output files were produced.
        let assemblyURL: URL? = fm.fileExists(atPath: config.assemblyOutputURL.path)
            ? config.assemblyOutputURL : nil
        let taxProfileURL: URL? = fm.fileExists(atPath: config.taxProfileURL.path)
            ? config.taxProfileURL : nil
        let coverageURL: URL? = fm.fileExists(atPath: config.coverageURL.path)
            ? config.coverageURL : nil

        progress?(0.95, "Saving provenance...")

        // Phase 5: Complete provenance (0.95 -- 1.0)
        await provenanceRecorder.completeRun(runID, status: .completed)

        do {
            try await provenanceRecorder.save(runID: runID, to: config.outputDirectory)
        } catch {
            logger.warning("Failed to save provenance: \(error.localizedDescription)")
        }

        let totalRuntime = Date().timeIntervalSince(startTime)

        let result = EsVirituResult(
            config: config,
            detectionURL: config.detectionOutputURL,
            assemblyURL: assemblyURL,
            taxProfileURL: taxProfileURL,
            coverageURL: coverageURL,
            virusCount: virusCount,
            runtime: totalRuntime,
            toolVersion: toolVersion,
            provenanceId: runID
        )

        // Save the result sidecar.
        do {
            try result.save(to: config.outputDirectory)
        } catch {
            logger.warning("Failed to save result sidecar: \(error.localizedDescription)")
        }

        progress?(1.0, "Detection complete")

        let runtimeStr = String(format: "%.1f", totalRuntime)
        logger.info("Pipeline complete: \(virusCount) viruses detected, \(runtimeStr)s")

        return result
    }

    // MARK: - Version Detection

    /// Detects the EsViritu version by running `EsViritu --version`.
    ///
    /// - Returns: The version string, or "unknown" if detection fails.
    private func detectEsVirituVersion() async -> String {
        // Try --version first, then -v as fallback.
        for flag in ["--version", "-v"] {
            do {
                let result = try await condaManager.runTool(
                    name: "EsViritu",
                    arguments: [flag],
                    environment: Self.esVirituEnvironment,
                    timeout: 30
                )
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
                continue
            }
        }

        logger.debug("EsViritu version detection failed")
        return "unknown"
    }

    // MARK: - Helpers

    /// Counts the number of detected viruses from the detection TSV.
    ///
    /// The first line is a header; each subsequent non-empty line represents
    /// one detected virus.
    ///
    /// - Parameter url: Path to the detection TSV file.
    /// - Returns: The number of detected viruses.
    private func countDetectedViruses(at url: URL) -> Int {
        guard let data = try? Data(contentsOf: url),
              let content = String(data: data, encoding: .utf8) else {
            return 0
        }

        let lines = content.components(separatedBy: .newlines)
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }

        // Subtract 1 for the header line.
        return max(0, lines.count - 1)
    }
}

// MARK: - EsViritu Progress Parsing

/// Parses an EsViritu stderr progress line and reports it via the progress callback.
///
/// EsViritu writes progress information to stderr during execution. This
/// function extracts status messages and reports them in the 0.15--0.85
/// progress range used by the pipeline.
///
/// - Parameters:
///   - line: A single line from EsViritu's stderr output.
///   - progress: The pipeline's progress callback.
func parseEsVirituProgressLine(
    _ line: String,
    progress: @Sendable (Double, String) -> Void
) {
    let trimmed = line.trimmingCharacters(in: .whitespaces)
    guard !trimmed.isEmpty else { return }

    // Map known EsViritu phases to progress fractions.
    if trimmed.contains("quality") || trimmed.contains("fastp") {
        progress(0.25, "Quality filtering reads...")
    } else if trimmed.contains("align") || trimmed.contains("mapping") {
        progress(0.40, "Aligning reads to viral references...")
    } else if trimmed.contains("detect") || trimmed.contains("screen") {
        progress(0.55, "Screening for viral signatures...")
    } else if trimmed.contains("assembl") {
        progress(0.65, "Assembling viral contigs...")
    } else if trimmed.contains("coverage") || trimmed.contains("depth") {
        progress(0.75, "Calculating coverage statistics...")
    } else if trimmed.contains("profil") || trimmed.contains("taxonom") {
        progress(0.80, "Building taxonomic profile...")
    }
}
