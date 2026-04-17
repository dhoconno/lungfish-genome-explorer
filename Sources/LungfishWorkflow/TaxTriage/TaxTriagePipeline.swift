// TaxTriagePipeline.swift - TaxTriage Nextflow pipeline orchestrator
// Copyright (c) 2025 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishCore
import LungfishIO
import os.log

private let logger = Logger(subsystem: "com.lungfish.workflow", category: "TaxTriagePipeline")

// MARK: - TaxTriagePipelineError

/// Errors produced during TaxTriage pipeline execution.
public enum TaxTriagePipelineError: Error, LocalizedError, Sendable {

    /// Nextflow is not installed or not found in PATH.
    case nextflowNotInstalled

    /// No container runtime is available (Docker or Apple Containerization required).
    case containerRuntimeNotAvailable

    /// The samplesheet could not be generated.
    case samplesheetGenerationFailed(Error)

    /// Nextflow exited with a non-zero status.
    case pipelineFailed(exitCode: Int32, stderr: String, logFile: URL?)

    /// The pipeline was cancelled.
    case cancelled

    /// A prerequisite check failed.
    case prerequisiteFailed(tool: String, reason: String)

    public var errorDescription: String? {
        switch self {
        case .nextflowNotInstalled:
            return "Nextflow is not installed. Install it from https://nextflow.io"
        case .containerRuntimeNotAvailable:
            return "No container runtime available. Install Docker Desktop or use Apple Containerization (macOS 26+)."
        case .samplesheetGenerationFailed(let error):
            return "Failed to generate samplesheet: \(error.localizedDescription)"
        case .pipelineFailed(let code, let stderr, _):
            let stderrSnippet = String(stderr.suffix(500))
            return "TaxTriage pipeline failed with exit code \(code): \(stderrSnippet)"
        case .cancelled:
            return "TaxTriage pipeline was cancelled"
        case .prerequisiteFailed(let tool, let reason):
            return "\(tool) prerequisite check failed: \(reason)"
        }
    }
}

// MARK: - TaxTriagePipeline

/// Actor that orchestrates TaxTriage metagenomic classification via Nextflow.
///
/// TaxTriage is a remote Nextflow DSL2 pipeline from JHU APL. Unlike local `.nf`
/// workflow files, it is invoked as `nextflow run jhuapl-bio/taxtriage`. This
/// pipeline actor uses ``ProcessManager`` directly to spawn the Nextflow process,
/// since ``NextflowRunner`` expects a local workflow file.
///
/// The pipeline performs these steps:
///
/// 1. **Check prerequisites**: Verify Nextflow and container runtime availability.
/// 2. **Generate samplesheet**: Write the TaxTriage input CSV to the output directory.
/// 3. **Build command**: Construct the `nextflow run jhuapl-bio/taxtriage` invocation.
/// 4. **Execute**: Run the Nextflow process, streaming progress from stdout/stderr.
/// 5. **Collect outputs**: Discover and categorize output files (reports, metrics, Krona).
/// 6. **Return result**: Package everything into a ``TaxTriageResult``.
///
/// ## Progress
///
/// Progress is reported via a `@Sendable (Double, String) -> Void` callback:
///
/// | Range        | Phase |
/// |-------------|-------|
/// | 0.00 -- 0.05 | Prerequisite checks |
/// | 0.05 -- 0.10 | Samplesheet generation |
/// | 0.10 -- 0.90 | Nextflow execution |
/// | 0.90 -- 1.00 | Output collection |
///
/// ## Example
///
/// ```swift
/// let pipeline = TaxTriagePipeline()
/// let config = TaxTriageConfig(
///     samples: [sample],
///     platform: .illumina,
///     outputDirectory: outputDir
/// )
/// let result = try await pipeline.run(config: config) { progress, message in
///     print("\(Int(progress * 100))% \(message)")
/// }
/// ```
public actor TaxTriagePipeline {

    struct PreparedExecutionConfig {
        let effectiveConfig: TaxTriageConfig
        let redirectDirectory: URL?

        var needsRedirect: Bool {
            redirectDirectory != nil
        }
    }

    /// Shared instance for convenience.
    public static let shared = TaxTriagePipeline()

    /// The process manager used to spawn the Nextflow process.
    private let processManager: ProcessManager

    private let homeDirectoryProvider: @Sendable () -> URL

    /// Creates a TaxTriage pipeline.
    ///
    /// - Parameter processManager: Process manager for spawning processes (default: shared).
    public init(
        processManager: ProcessManager = .shared,
        homeDirectoryProvider: @escaping @Sendable () -> URL = {
            FileManager.default.homeDirectoryForCurrentUser
        }
    ) {
        self.processManager = processManager
        self.homeDirectoryProvider = homeDirectoryProvider
    }

    // MARK: - Prerequisite Checks

    /// Checks whether all prerequisites for running TaxTriage are met.
    ///
    /// Verifies:
    /// - Nextflow is installed and in PATH
    /// - A container runtime (Docker or Apple Containerization) is available
    ///
    /// - Returns: A ``PrerequisiteStatus`` describing the state of each requirement.
    public func checkPrerequisites() async -> PrerequisiteStatus {
        let nextflowPath = managedNextflowExecutableURL()
        let nextflowAvailable = nextflowPath != nil

        // Detect version if available
        var nextflowVersion: String?
        if let nextflowPath {
            await CondaManager.shared.repairManagedLaunchers(environment: "nextflow")
            let tempDir = FileManager.default.temporaryDirectory
            if let result = try? await processManager.runAndWait(
                executable: nextflowPath,
                arguments: ["-version"],
                workingDirectory: tempDir,
                environment: managedNextflowExecutionEnvironment(for: nextflowPath)
            ), result.exitCode == 0 {
                nextflowVersion = parseNextflowVersion(from: result.stdout + "\n" + result.stderr)
            }
        }

        let containerRuntime = await ContainerRuntimeFactory.createRuntime()
        let containerAvailable = containerRuntime != nil
        var containerName: String?
        if let runtime = containerRuntime {
            containerName = await runtime.displayName
        }

        return PrerequisiteStatus(
            nextflowInstalled: nextflowAvailable,
            nextflowVersion: nextflowVersion,
            containerRuntimeAvailable: containerAvailable,
            containerRuntimeName: containerName
        )
    }

    // MARK: - Pipeline Execution

    /// Runs the TaxTriage pipeline with the given configuration.
    ///
    /// - Parameters:
    ///   - config: The pipeline configuration.
    ///   - progress: Progress callback reporting (fraction, message).
    /// - Returns: A ``TaxTriageResult`` with all output files.
    /// - Throws: ``TaxTriageConfigError`` for invalid configuration,
    ///   ``TaxTriagePipelineError`` for execution failures.
    public func run(
        config: TaxTriageConfig,
        progress: (@Sendable (Double, String) -> Void)? = nil
    ) async throws -> TaxTriageResult {
        let startTime = Date()
        var profileAdjustedConfig = config
        profileAdjustedConfig.profile = profileAdjustedConfig.profile
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        if profileAdjustedConfig.profile.isEmpty {
            profileAdjustedConfig.profile = "docker"
        }

        // Phase 1: Prerequisites (0.00 -- 0.05)
        progress?(0.0, "Checking prerequisites...")
        try profileAdjustedConfig.validate()

        let useNextflowConda = Self.usesNextflowConda(profile: profileAdjustedConfig.profile)
        let launchEnvironment = await buildLaunchEnvironment(useNextflowConda: useNextflowConda)
        if profileAdjustedConfig.profile == "docker" {
            try await ensureDockerDaemonReady(
                progress: progress,
                environment: launchEnvironment
            )
        }

        let prereqs = await checkPrerequisites()
        guard prereqs.nextflowInstalled else {
            throw TaxTriagePipelineError.nextflowNotInstalled
        }

        guard let nextflowPath = managedNextflowExecutableURL() else {
            throw TaxTriagePipelineError.nextflowNotInstalled
        }

        let nfVersion = prereqs.nextflowVersion ?? "unknown"
        let executionBackend = profileAdjustedConfig.profile
        logger.info("Prerequisites met: Nextflow \(nfVersion, privacy: .public), backend: \(executionBackend, privacy: .public)")

        // Create output directory
        let fm = FileManager.default
        if !fm.fileExists(atPath: profileAdjustedConfig.outputDirectory.path) {
            do {
                try fm.createDirectory(
                    at: profileAdjustedConfig.outputDirectory,
                    withIntermediateDirectories: true
                )
            } catch {
                throw TaxTriageConfigError.outputDirectoryCreationFailed(
                    profileAdjustedConfig.outputDirectory, error
                )
            }
        }

        OperationMarker.markInProgress(profileAdjustedConfig.outputDirectory, detail: "Running TaxTriage\u{2026}")
        defer { OperationMarker.clearInProgress(profileAdjustedConfig.outputDirectory) }

        progress?(0.05, "Generating samplesheet...")

        // Phase 2: Handle spaces in paths (0.05 -- 0.07)
        //
        // Nextflow and its Docker bind mounts break on paths with spaces.
        // If the output directory or input files contain spaces, redirect
        // everything through a space-free temp directory with symlinks.
        let preparedExecution = try prepareExecutionConfig(for: profileAdjustedConfig)
        let effectiveConfig = preparedExecution.effectiveConfig
        let tempRedirectDir = preparedExecution.redirectDirectory
        let needsRedirect = preparedExecution.needsRedirect

        // Generate samplesheet
        let sampleEntries = effectiveConfig.samples.map { sample in
            TaxTriageSampleEntry(
                sampleId: sample.sampleId,
                fastq1Path: sample.fastq1.path,
                fastq2Path: sample.fastq2?.path,
                platform: sample.platform.rawValue
            )
        }

        do {
            try TaxTriageSamplesheet.write(
                samples: sampleEntries,
                to: effectiveConfig.samplesheetURL
            )
        } catch {
            throw TaxTriagePipelineError.samplesheetGenerationFailed(error)
        }

        let sampleCount = effectiveConfig.samples.count
        let sheetName = effectiveConfig.samplesheetURL.lastPathComponent
        logger.info("Wrote samplesheet with \(sampleCount, privacy: .public) sample(s) to \(sheetName, privacy: .public)")

        progress?(0.10, "Starting TaxTriage pipeline...")

        // Phase 3: Build and execute Nextflow command (0.10 -- 0.90)
        let runtimeConfigURL = try await writeNextflowRuntimeConfig(
            in: effectiveConfig.outputDirectory,
            useNextflowConda: useNextflowConda
        )
        let arguments = buildNextflowLaunchArguments(
            config: effectiveConfig,
            runtimeConfigURL: runtimeConfigURL
        )
        let logFile = config.outputDirectory.appendingPathComponent("nextflow.log")

        // Prepare environment
        let environment = launchEnvironment

        // Fix spaces-in-path issue: the conda-installed Nextflow wrapper script
        // has the conda prefix hardcoded into NXF_DIST without proper quoting.
        // Patch the script to quote the NXF_DIST assignment.
        patchNextflowScript(at: nextflowPath)
        patchTaxTriageDownloadScript()

        // Run Nextflow via micromamba to ensure the conda environment is activated
        let condaManager = CondaManager.shared
        await condaManager.repairManagedLaunchers(environment: "nextflow")
        let micromambaPath = await condaManager.micromambaPath

        let nextflowEnvName: String
        if let envName = await condaManager.environmentContaining(tool: "nextflow") {
            nextflowEnvName = envName
        } else {
            nextflowEnvName = "nextflow"
        }

        let micromambaArgs = ["run", "-n", nextflowEnvName, "nextflow"] + arguments
        let launchCommand = shellCommand(executablePath: micromambaPath.path, arguments: micromambaArgs)
        logger.info("TaxTriage launch command: \(launchCommand, privacy: .public)")
        let launchMetadata = buildLaunchMetadata(
            requestedConfig: profileAdjustedConfig,
            effectiveConfig: effectiveConfig,
            nextflowArguments: arguments,
            launcherPath: micromambaPath.path,
            launcherArguments: micromambaArgs,
            workingDirectory: effectiveConfig.outputDirectory,
            environment: environment
        )
        persistLaunchMetadata(
            launchMetadata,
            requestedOutputDirectory: profileAdjustedConfig.outputDirectory,
            effectiveOutputDirectory: effectiveConfig.outputDirectory
        )

        let handle: ProcessHandle
        do {
            handle = try await processManager.spawn(
                executable: micromambaPath,
                arguments: micromambaArgs,
                workingDirectory: effectiveConfig.outputDirectory,
                environment: environment
            )
        } catch {
            let spawnMessage = "Failed to spawn Nextflow: \(error.localizedDescription)"
            let spawnLog = launchMetadata + "\n--- launcher error ---\n" + spawnMessage + "\n"
            try? spawnLog.write(to: logFile, atomically: true, encoding: .utf8)
            throw TaxTriagePipelineError.pipelineFailed(
                exitCode: -1,
                stderr: spawnMessage,
                logFile: logFile
            )
        }

        logger.info("Nextflow process started with PID \(handle.pid)")

        // Track completed processes for progress estimation
        let tracker = CompletedProcessTracker()

        // Process stdout and stderr concurrently
        var stdoutLines: [String] = []
        var stderrLines: [String] = []

        async let stdoutCollection: [String] = {
            var lines: [String] = []
            for await line in handle.standardOutput {
                lines.append(line)
                // Parse Nextflow progress from stdout
                if let progressFraction = parseNextflowProcessLine(
                    line, tracker: tracker
                ) {
                    let mapped = 0.10 + progressFraction * 0.80
                    progress?(mapped, line.trimmingCharacters(in: .whitespaces))
                }
            }
            return lines
        }()

        async let stderrCollection: [String] = {
            var lines: [String] = []
            for await line in handle.standardError {
                lines.append(line)
            }
            return lines
        }()

        stdoutLines = await stdoutCollection
        stderrLines = await stderrCollection

        // Wait for exit
        let exitCode = await handle.waitForExit()

        // Write combined log
        let combinedLog = launchMetadata
            + "\n--- stdout ---\n"
            + stdoutLines.joined(separator: "\n")
            + "\n--- stderr ---\n"
            + stderrLines.joined(separator: "\n")
        try? combinedLog.write(to: logFile, atomically: true, encoding: .utf8)

        if exitCode != 0 {
            let stderrText = stderrLines.joined(separator: "\n")
            throw TaxTriagePipelineError.pipelineFailed(
                exitCode: exitCode,
                stderr: stderrText,
                logFile: logFile
            )
        }

        progress?(0.90, "Collecting output files...")

        // Phase 4: Copy results back if we used a redirect (0.90 -- 0.95)
        if needsRedirect, let tempDir = tempRedirectDir {
            progress?(0.90, "Copying results to project directory...")
            let tempOutput = effectiveConfig.outputDirectory
            if fm.fileExists(atPath: tempOutput.path) {
                let contents = (try? fm.contentsOfDirectory(at: tempOutput, includingPropertiesForKeys: nil)) ?? []
                for item in contents {
                    let dest = config.outputDirectory.appendingPathComponent(item.lastPathComponent)
                    try? fm.removeItem(at: dest)
                    try? fm.moveItem(at: item, to: dest)
                }
            }
            // Clean up temp redirect directory
            try? fm.removeItem(at: tempDir)
            logger.info("Moved TaxTriage results from temp dir to \(config.outputDirectory.path)")
        }

        // Prune non-essential heavy intermediates before result indexing.
        pruneOutputArtifacts(in: config.outputDirectory)

        // Phase 5: Collect outputs from the ORIGINAL config path (0.95 -- 1.00)
        let result = collectOutputFiles(
            config: profileAdjustedConfig,
            exitCode: exitCode,
            logFile: logFile,
            startTime: startTime
        )

        // Save the result for later reference
        do {
            try result.save()
        } catch {
            logger.warning("Failed to save TaxTriage result: \(error.localizedDescription)")
        }

        progress?(1.0, "TaxTriage pipeline complete")

        let runtimeStr = String(format: "%.1f", result.runtime)
        logger.info("TaxTriage pipeline complete: \(sampleCount, privacy: .public) sample(s), \(runtimeStr, privacy: .public)s")

        return result
    }

    func prepareExecutionConfig(for config: TaxTriageConfig) throws -> PreparedExecutionConfig {
        let needsRedirect = config.outputDirectory.path.contains(" ")
            || config.samples.contains(where: {
                $0.fastq1.path.contains(" ") || ($0.fastq2?.path.contains(" ") ?? false)
            })
        guard needsRedirect else {
            return PreparedExecutionConfig(
                effectiveConfig: config,
                redirectDirectory: nil
            )
        }

        let fm = FileManager.default
        let safeDir = try ProjectTempDirectory.create(
            prefix: "taxtriage-",
            contextURL: config.outputDirectory,
            policy: .systemOnly
        )
        guard !safeDir.path.contains(" ") else {
            try? fm.removeItem(at: safeDir)
            throw TaxTriagePipelineError.prerequisiteFailed(
                tool: "TaxTriage staging",
                reason: "Unable to create a space-free temporary working directory."
            )
        }

        // Keep the samplesheet and symlinked FASTQs under the same space-free root
        // because the pipeline schema rejects input CSV paths that contain spaces.
        let safeSamples = try config.samples.map { sample -> TaxTriageSample in
            let safeFastq1: URL
            if sample.fastq1.path.contains(" ") {
                let linkName = sample.fastq1.lastPathComponent.replacingOccurrences(of: " ", with: "_")
                let linkURL = safeDir.appendingPathComponent(linkName)
                try? fm.removeItem(at: linkURL)
                try fm.createSymbolicLink(at: linkURL, withDestinationURL: sample.fastq1)
                safeFastq1 = linkURL
            } else {
                safeFastq1 = sample.fastq1
            }

            let safeFastq2: URL?
            if let fq2 = sample.fastq2, fq2.path.contains(" ") {
                let linkName = fq2.lastPathComponent.replacingOccurrences(of: " ", with: "_")
                let linkURL = safeDir.appendingPathComponent(linkName)
                try? fm.removeItem(at: linkURL)
                try fm.createSymbolicLink(at: linkURL, withDestinationURL: fq2)
                safeFastq2 = linkURL
            } else {
                safeFastq2 = sample.fastq2
            }

            return TaxTriageSample(
                sampleId: sample.sampleId,
                fastq1: safeFastq1,
                fastq2: safeFastq2,
                platform: sample.platform
            )
        }

        let effectiveConfig = TaxTriageConfig(
            samples: safeSamples,
            platform: config.platform,
            outputDirectory: safeDir.appendingPathComponent("output"),
            kraken2DatabasePath: config.kraken2DatabasePath,
            topHitsCount: config.topHitsCount,
            k2Confidence: config.k2Confidence,
            rank: config.rank,
            skipAssembly: config.skipAssembly,
            skipKrona: config.skipKrona,
            maxMemory: config.maxMemory,
            maxCpus: config.maxCpus,
            profile: config.profile,
            revision: config.revision
        )

        try fm.createDirectory(at: effectiveConfig.outputDirectory, withIntermediateDirectories: true)
        logger.info("Redirected TaxTriage to space-free path: \(safeDir.path)")
        return PreparedExecutionConfig(
            effectiveConfig: effectiveConfig,
            redirectDirectory: safeDir
        )
    }

    // MARK: - Command Building

    /// Builds the full argument array for the `nextflow` command.
    ///
    /// Produces: `["run", "jhuapl-bio/taxtriage", "-r", "main", "-profile", "docker",
    ///   "--input", "samplesheet.csv", "--outdir", "/path/to/output", ...]`
    ///
    /// - Parameter config: The pipeline configuration.
    /// - Returns: The argument array (excluding the `nextflow` executable itself).
    /// Patches the conda-installed Nextflow wrapper script to quote paths
    /// that contain spaces.
    ///
    /// The conda package hardcodes `NXF_DIST=/path/with spaces/...` on line 24
    /// without quotes. This causes bash to split on the space. We patch ONLY:
    /// - Line starting with `NXF_DIST=/` → `NXF_DIST="/..."`
    /// - Line containing `NXF_BIN=${NXF_BIN:-$NXF_DIST/` → adds quotes
    ///
    /// This is idempotent — already-patched scripts are left unchanged.
    private func patchNextflowScript(at path: URL) {
        do {
            let content = try String(contentsOf: path, encoding: .utf8)

            // Only patch if NXF_DIST contains a space and isn't already quoted
            guard content.contains("NXF_DIST=/") else { return }

            let lines = content.components(separatedBy: "\n")
            var newLines: [String] = []
            var patched = false

            for line in lines {
                // ONLY patch the NXF_DIST assignment line (starts with NXF_DIST=/)
                if line.hasPrefix("NXF_DIST=/") && !line.hasPrefix("NXF_DIST=\"") {
                    let value = String(line.dropFirst("NXF_DIST=".count))
                    if value.contains(" ") {
                        newLines.append("NXF_DIST=\"\(value)\"")
                        patched = true
                        continue
                    }
                }

                // ONLY patch the specific NXF_BIN default assignment line
                if line == "NXF_BIN=${NXF_BIN:-$NXF_DIST/$NXF_VER/$NXF_JAR}" {
                    newLines.append("NXF_BIN=${NXF_BIN:-\"$NXF_DIST/$NXF_VER/$NXF_JAR\"}")
                    patched = true
                    continue
                }

                newLines.append(line)
            }

            if patched {
                let patchedContent = newLines.joined(separator: "\n")
                try patchedContent.write(to: path, atomically: true, encoding: .utf8)
                try FileManager.default.setAttributes(
                    [.posixPermissions: 0o755],
                    ofItemAtPath: path.path
                )
                logger.info("Patched Nextflow script to quote NXF_DIST path with spaces")
            }
        } catch {
            logger.warning("Failed to patch Nextflow script: \(error.localizedDescription)")
        }
    }

    /// Patches the TaxTriage download_fastas.py script to fix a bug where
    /// `os.path.basename()` returns empty string for paths with trailing slashes.
    ///
    /// The NCBI assembly_summary_refseq.txt has FTP paths with trailing slashes
    /// (e.g., `https://...GCF_000845245.1_ViralProj14559/`). Python's `os.path.basename()`
    /// returns `""` for such paths, causing the constructed download URL to be
    /// `https://.../_genomic.fna.gz` (missing the assembly name) → HTTP 404.
    ///
    /// Fix: strip trailing slashes before calling basename.
    /// Upstream issue: https://github.com/jhuapl-bio/taxtriage
    private func patchTaxTriageDownloadScript() {
        let home = homeDirectoryProvider()
        let scriptPath = home.appendingPathComponent(".nextflow/assets/jhuapl-bio/taxtriage/bin/download_fastas.py")

        guard FileManager.default.fileExists(atPath: scriptPath.path) else { return }

        do {
            var content = try String(contentsOf: scriptPath, encoding: .utf8)

            // Check if already patched
            if content.contains("rstrip") { return }

            // Patch the get_url function
            let oldLine = "bb = os.path.basename(utl)"
            let newLine = "bb = os.path.basename(utl.rstrip('/'))"

            guard content.contains(oldLine) else { return }

            content = content.replacingOccurrences(of: oldLine, with: newLine)

            // Also fix the URL construction to strip trailing slash
            content = content.replacingOccurrences(
                of: "return utl+\"/\"+bb+\"_genomic.fna.gz\"",
                with: "return utl.rstrip('/')+\"/\"+bb+\"_genomic.fna.gz\""
            )

            try content.write(to: scriptPath, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptPath.path)
            logger.info("Patched TaxTriage download_fastas.py to fix trailing-slash URL bug")
        } catch {
            logger.warning("Failed to patch TaxTriage download script: \(error.localizedDescription)")
        }
    }

    func buildNextflowArguments(config: TaxTriageConfig) -> [String] {
        var args: [String] = ["run"]

        // Pipeline source and revision
        args += [TaxTriageConfig.pipelineRepository, "-r", config.revision]

        // Profile
        args += ["-profile", config.profile]

        // Input samplesheet
        args += ["--input", config.samplesheetURL.path]

        // Output directory
        args += ["--outdir", config.outputDirectory.path]

        // Trace file for progress tracking
        let traceFile = config.outputDirectory.appendingPathComponent("trace.txt")
        args += ["-with-trace", traceFile.path]

        // Database
        if let dbPath = config.kraken2DatabasePath {
            args += ["--db", dbPath.path]
        }

        // Classification parameters
        args += ["--top_hits_count", String(config.topHitsCount)]
        args += ["--k2_confidence", String(config.k2Confidence)]
        args += ["--rank", config.rank]

        // Assembly control
        if config.skipAssembly {
            args.append("--skip_assembly")
        }

        // Krona control
        if config.skipKrona {
            args.append("--skip_krona")
        }

        // Resource limits
        args += ["--max_memory", config.maxMemory]
        args += ["--max_cpus", String(config.maxCpus)]

        return args
    }

    func buildNextflowLaunchArguments(
        config: TaxTriageConfig,
        runtimeConfigURL: URL
    ) -> [String] {
        ["-c", runtimeConfigURL.path] + buildNextflowArguments(config: config)
    }

    // MARK: - Output Collection

    /// Discovers and categorizes output files after pipeline completion.
    private func collectOutputFiles(
        config: TaxTriageConfig,
        exitCode: Int32,
        logFile: URL,
        startTime: Date
    ) -> TaxTriageResult {
        let fm = FileManager.default
        let outputDir = config.outputDirectory

        // Discover all files recursively
        let baseRunner = BaseWorkflowRunner(category: "TaxTriageCollector")
        let allFiles = baseRunner.discoverOutputFiles(in: outputDir, extensions: nil)

        // Categorize by extension and path patterns
        var reportFiles: [URL] = []
        var metricsFiles: [URL] = []
        var kronaFiles: [URL] = []

        for file in allFiles {
            let name = file.lastPathComponent.lowercased()
            let ext = file.pathExtension.lowercased()
            let pathString = file.path.lowercased()

            if name.contains("report") && (ext == "txt" || ext == "tsv") {
                reportFiles.append(file)
            } else if name.contains("tass") || name.contains("metrics")
                        || name.contains("confidence") {
                metricsFiles.append(file)
            } else if ext == "html"
                        && (name.contains("krona") || pathString.contains("krona")) {
                kronaFiles.append(file)
            } else if ext == "tsv" && !name.contains("trace")
                        && !name.contains("samplesheet") {
                metricsFiles.append(file)
            }
        }

        // Find trace file
        let traceURL = outputDir.appendingPathComponent("trace.txt")
        let traceFile = fm.fileExists(atPath: traceURL.path) ? traceURL : nil
        let ignoredFailures: [TaxTriageIgnoredFailure]
        if let logText = try? String(contentsOf: logFile, encoding: .utf8) {
            ignoredFailures = TaxTriageResult.parseIgnoredFailures(fromNextflowLogText: logText)
        } else {
            ignoredFailures = []
        }

        let runtime = Date().timeIntervalSince(startTime)

        return TaxTriageResult(
            config: config,
            runtime: runtime,
            exitCode: exitCode,
            outputDirectory: outputDir,
            reportFiles: reportFiles.sorted { $0.path < $1.path },
            metricsFiles: metricsFiles.sorted { $0.path < $1.path },
            kronaFiles: kronaFiles.sorted { $0.path < $1.path },
            logFile: logFile,
            traceFile: traceFile,
            allOutputFiles: allFiles,
            sourceBundleURLs: config.sourceBundleURLs,
            ignoredFailures: ignoredFailures
        )
    }

    /// Removes large intermediate directories that are not required for
    /// reproducibility or in-app exploration.
    ///
    /// The viewer uses persisted reports/metrics/BAM outputs and sidecars,
    /// not Nextflow's `work/` cache tree.
    private func pruneOutputArtifacts(in outputDirectory: URL) {
        let fm = FileManager.default
        let removableDirs = ["work"]

        for dirName in removableDirs {
            let dirURL = outputDirectory.appendingPathComponent(dirName, isDirectory: true)
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: dirURL.path, isDirectory: &isDir), isDir.boolValue else { continue }
            do {
                try fm.removeItem(at: dirURL)
                logger.info("Pruned TaxTriage intermediate directory: \(dirName, privacy: .public)")
            } catch {
                logger.warning("Failed to prune \(dirName, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    // MARK: - Progress Parsing

    /// Parses a Nextflow stdout line for process completion.
    ///
    /// Nextflow outputs lines like:
    /// ```
    /// [ab/cd1234] process > PROCESS_NAME (1) [100%] 1 of 1
    /// ```
    ///
    /// - Parameters:
    ///   - line: A single stdout line.
    ///   - tracker: The process completion tracker.
    /// - Returns: The updated overall progress fraction, or nil if not a process line.
    private nonisolated func parseNextflowProcessLine(
        _ line: String,
        tracker: CompletedProcessTracker
    ) -> Double? {
        guard line.contains("process >") else { return nil }

        var status = WorkflowProgressUpdate.ProcessStatus.running
        if line.contains("[100%]") {
            status = .completed
        } else if line.lowercased().contains("cached") {
            status = .cached
        }

        let update = WorkflowProgressUpdate(
            process: extractProcessName(from: line),
            status: status,
            message: line
        )
        return tracker.recordUpdate(update)
    }

    /// Extracts the process name from a Nextflow progress line.
    private nonisolated func extractProcessName(from line: String) -> String {
        // Look for pattern: "process > PROCESS_NAME"
        guard let rangeOfMarker = line.range(of: "process >") else {
            return "unknown"
        }
        let afterMarker = line[rangeOfMarker.upperBound...]
            .trimmingCharacters(in: .whitespaces)
        // Take up to the first space or parenthesis
        let name = afterMarker.prefix {
            $0 != " " && $0 != "(" && $0 != "["
        }
        return name.isEmpty ? "unknown" : String(name)
    }

    /// Parses the Nextflow version from `nextflow -version` output.
    private nonisolated func parseNextflowVersion(from output: String) -> String? {
        for line in output.components(separatedBy: .newlines) {
            if let match = line.range(
                of: #"\d+\.\d+\.\d+"#,
                options: .regularExpression
            ) {
                return String(line[match])
            }
        }
        return nil
    }

    func buildLaunchEnvironment(useNextflowConda: Bool) async -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        environment["NXF_ANSI_LOG"] = "false"
        let condaRoot = CondaManager.shared.rootPrefix
        environment["MAMBA_ROOT_PREFIX"] = condaRoot.path

        if useNextflowConda {
            let condaConfig = await CondaManager.shared.nextflowCondaConfig()
            for (key, value) in condaConfig {
                environment[key] = value
            }
        } else {
            // Docker/podman/singularity profiles must not inherit managed conda
            // settings, or Nextflow will override the pipeline's own profile logic.
            environment.removeValue(forKey: "NXF_CONDA_ENABLED")
            environment.removeValue(forKey: "NXF_CONDA_CACHEDIR")
        }

        // Ensure Docker CLI paths are available even in restricted launch envs.
        let dockerPaths = [
            condaRoot.appendingPathComponent("bin").path,
            "/usr/local/bin",
            "/opt/homebrew/bin",
        ]
        let existingPaths = (environment["PATH"] ?? "")
            .split(separator: ":")
            .map(String.init)
        var mergedPaths = existingPaths
        for path in dockerPaths.reversed() where !mergedPaths.contains(path) {
            mergedPaths.insert(path, at: 0)
        }
        environment["PATH"] = mergedPaths.joined(separator: ":")

        // Keep Nextflow cache in a stable, user-space location.
        let nxfHome = homeDirectoryProvider()
            .appendingPathComponent(".nextflow")
        environment["NXF_HOME"] = nxfHome.path
        return environment
    }

    private func managedNextflowExecutableURL() -> URL? {
        let url = CoreToolLocator.executableURL(
            environment: "nextflow",
            executableName: "nextflow",
            homeDirectory: homeDirectoryProvider()
        )
        return FileManager.default.isExecutableFile(atPath: url.path) ? url : nil
    }

    private func managedNextflowExecutionEnvironment(for executablePath: URL) -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        let home = homeDirectoryProvider()
        let condaBin = CoreToolLocator.condaRoot(homeDirectory: home)
            .appendingPathComponent("bin", isDirectory: true)
        let existingPath = environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
        environment["PATH"] = [
            executablePath.deletingLastPathComponent().path,
            condaBin.path,
            existingPath,
        ].joined(separator: ":")
        environment["HOME"] = home.path
        return environment
    }

    private func writeNextflowRuntimeConfig(
        in directory: URL,
        useNextflowConda: Bool
    ) async throws -> URL {
        let configURL = directory.appendingPathComponent("lungfish.nextflow.config")
        let configString: String
        if useNextflowConda {
            configString = await CondaManager.shared.nextflowCondaConfigString()
        } else {
            configString = ""
        }
        try configString.write(to: configURL, atomically: true, encoding: .utf8)
        return configURL
    }

    nonisolated static func usesNextflowConda(profile: String) -> Bool {
        profile
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .contains("conda")
    }

    private func ensureDockerDaemonReady(
        progress: (@Sendable (Double, String) -> Void)?,
        environment: [String: String]
    ) async throws {
        if await dockerDaemonAvailable(environment: environment) {
            return
        }

        progress?(0.01, "Docker daemon unavailable. Launching Docker Desktop...")
        logger.warning("Docker daemon unavailable; attempting to launch Docker Desktop")
        _ = await launchDockerDesktop()

        let timeoutSeconds: UInt64 = 90
        let pollIntervalSeconds: UInt64 = 2
        var waitedSeconds: UInt64 = 0
        while waitedSeconds < timeoutSeconds {
            try? await Task.sleep(nanoseconds: pollIntervalSeconds * 1_000_000_000)
            waitedSeconds += pollIntervalSeconds
            if await dockerDaemonAvailable(environment: environment) {
                logger.info("Docker daemon became available after \(waitedSeconds, privacy: .public)s")
                progress?(0.02, "Docker daemon ready")
                return
            }
        }

        throw TaxTriagePipelineError.prerequisiteFailed(
            tool: "Docker",
            reason: "Docker Desktop is not running or daemon is unreachable. Start Docker Desktop and retry."
        )
    }

    private func launchDockerDesktop() async -> Bool {
        let openPath = URL(fileURLWithPath: "/usr/bin/open")
        do {
            let result = try await processManager.runAndWait(
                executable: openPath,
                arguments: ["-g", "-a", "Docker"],
                workingDirectory: homeDirectoryProvider()
            )
            if result.exitCode == 0 {
                logger.info("Requested Docker Desktop launch via open -a Docker")
                return true
            }
            let stderr = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            logger.warning("Failed to launch Docker Desktop (exit \(result.exitCode, privacy: .public)): \(stderr, privacy: .public)")
            return false
        } catch {
            logger.warning("Failed to launch Docker Desktop: \(error.localizedDescription)")
            return false
        }
    }

    private func dockerDaemonAvailable(environment: [String: String]) async -> Bool {
        guard let dockerPath = processManager.findExecutable(named: "docker") else {
            logger.warning("Docker CLI executable not found in PATH")
            return false
        }
        do {
            let result = try await processManager.runAndWait(
                executable: dockerPath,
                arguments: ["info"],
                workingDirectory: FileManager.default.temporaryDirectory,
                environment: environment
            )
            return result.exitCode == 0
        } catch {
            return false
        }
    }

    private func buildLaunchMetadata(
        requestedConfig: TaxTriageConfig,
        effectiveConfig: TaxTriageConfig,
        nextflowArguments: [String],
        launcherPath: String,
        launcherArguments: [String],
        workingDirectory: URL,
        environment: [String: String]
    ) -> String {
        let timestamp = ISO8601DateFormatter().string(from: Date())
        let lines = [
            "# TaxTriage launch metadata",
            "timestamp: \(timestamp)",
            "requested_profile: \(requestedConfig.profile)",
            "effective_profile: \(effectiveConfig.profile)",
            "requested_output_directory: \(requestedConfig.outputDirectory.path)",
            "effective_output_directory: \(effectiveConfig.outputDirectory.path)",
            "working_directory: \(workingDirectory.path)",
            "nextflow_command: \(shellCommand(executablePath: "nextflow", arguments: nextflowArguments))",
            "launcher_command: \(shellCommand(executablePath: launcherPath, arguments: launcherArguments))",
            "PATH: \(environment["PATH"] ?? "")",
            "NXF_HOME: \(environment["NXF_HOME"] ?? "")",
            "NXF_ANSI_LOG: \(environment["NXF_ANSI_LOG"] ?? "")",
        ]
        return lines.joined(separator: "\n") + "\n"
    }

    private func persistLaunchMetadata(
        _ metadata: String,
        requestedOutputDirectory: URL,
        effectiveOutputDirectory: URL
    ) {
        let fm = FileManager.default
        var directories = [requestedOutputDirectory]
        if effectiveOutputDirectory.path != requestedOutputDirectory.path {
            directories.append(effectiveOutputDirectory)
        }

        for directory in directories {
            do {
                if !fm.fileExists(atPath: directory.path) {
                    try fm.createDirectory(at: directory, withIntermediateDirectories: true)
                }
                let txtURL = directory.appendingPathComponent("taxtriage-launch-command.txt")
                try metadata.write(to: txtURL, atomically: true, encoding: .utf8)

                let launcherCommandLine = metadata
                    .components(separatedBy: .newlines)
                    .first(where: { $0.hasPrefix("launcher_command: ") })
                    .map { String($0.dropFirst("launcher_command: ".count)) } ?? ""
                let script = """
                #!/usr/bin/env bash
                set -euo pipefail
                cd \(shellEscape(directory.path))
                \(launcherCommandLine)
                """
                let shURL = directory.appendingPathComponent("taxtriage-launch-command.sh")
                try script.write(to: shURL, atomically: true, encoding: .utf8)
                try? fm.setAttributes(
                    [.posixPermissions: 0o755],
                    ofItemAtPath: shURL.path
                )
            } catch {
                logger.warning("Failed to persist TaxTriage launch metadata in \(directory.path, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    private nonisolated func shellCommand(executablePath: String, arguments: [String]) -> String {
        ([executablePath] + arguments).map(shellEscape).joined(separator: " ")
    }

}

// MARK: - PrerequisiteStatus

/// Status of TaxTriage pipeline prerequisites.
///
/// Reports the availability of Nextflow and a container runtime,
/// along with version information for installed components.
public struct PrerequisiteStatus: Sendable {

    /// Whether Nextflow is installed and in PATH.
    public let nextflowInstalled: Bool

    /// Nextflow version string, or nil if not installed.
    public let nextflowVersion: String?

    /// Whether a container runtime (Docker or Apple Containerization) is available.
    public let containerRuntimeAvailable: Bool

    /// Name of the detected container runtime, or nil if none found.
    public let containerRuntimeName: String?

    /// Whether all prerequisites are met.
    public var allSatisfied: Bool {
        nextflowInstalled && containerRuntimeAvailable
    }

    /// A human-readable summary of prerequisite status.
    public var summary: String {
        var lines: [String] = []

        if nextflowInstalled {
            lines.append("Nextflow: installed (v\(nextflowVersion ?? "unknown"))")
        } else {
            lines.append("Nextflow: NOT INSTALLED")
        }

        if containerRuntimeAvailable {
            lines.append("Container runtime: \(containerRuntimeName ?? "available")")
        } else {
            lines.append("Container runtime: NOT AVAILABLE")
        }

        if allSatisfied {
            lines.append("Status: All prerequisites met")
        } else {
            lines.append("Status: MISSING PREREQUISITES")
        }

        return lines.joined(separator: "\n")
    }
}

// MARK: - CompletedProcessTracker

/// Tracks completed Nextflow processes to estimate overall progress.
///
/// Since we do not know the total number of processes in advance, the tracker
/// uses a linear estimate based on a typical TaxTriage process count,
/// clamped below 1.0 to leave room for finalization.
private final class CompletedProcessTracker: @unchecked Sendable {
    private var completedCount = 0
    private let lock = NSLock()

    /// Typical number of processes in a TaxTriage run (used for progress estimation).
    private let estimatedTotalProcesses = 15

    /// Records a progress update and returns the estimated fraction complete (0.0 -- 1.0).
    func recordUpdate(_ update: WorkflowProgressUpdate) -> Double {
        if update.status == .completed || update.status == .cached {
            lock.lock()
            completedCount += 1
            let count = completedCount
            lock.unlock()

            return min(Double(count) / Double(estimatedTotalProcesses), 0.95)
        }

        lock.lock()
        let count = completedCount
        lock.unlock()
        return min(Double(count) / Double(estimatedTotalProcesses), 0.95)
    }
}

// MARK: - Shell Quoting
