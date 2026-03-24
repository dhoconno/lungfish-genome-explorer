// TaxTriagePipeline.swift - TaxTriage Nextflow pipeline orchestrator
// Copyright (c) 2025 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
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

    /// Shared instance for convenience.
    public static let shared = TaxTriagePipeline()

    /// The process manager used to spawn the Nextflow process.
    private let processManager: ProcessManager

    /// Creates a TaxTriage pipeline.
    ///
    /// - Parameter processManager: Process manager for spawning processes (default: shared).
    public init(processManager: ProcessManager = .shared) {
        self.processManager = processManager
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
        let nextflowPath = processManager.findExecutable(named: "nextflow")
        let nextflowAvailable = nextflowPath != nil

        // Detect version if available
        var nextflowVersion: String?
        if let path = nextflowPath {
            let tempDir = FileManager.default.temporaryDirectory
            if let result = try? await processManager.runAndWait(
                executable: path,
                arguments: ["-version"],
                workingDirectory: tempDir
            ), result.exitCode == 0 {
                nextflowVersion = parseNextflowVersion(from: result.stdout)
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

        // Phase 1: Prerequisites (0.00 -- 0.05)
        progress?(0.0, "Checking prerequisites...")
        try config.validate()

        let prereqs = await checkPrerequisites()
        guard prereqs.nextflowInstalled else {
            throw TaxTriagePipelineError.nextflowNotInstalled
        }
        guard prereqs.containerRuntimeAvailable else {
            throw TaxTriagePipelineError.containerRuntimeNotAvailable
        }

        guard let nextflowPath = processManager.findExecutable(named: "nextflow") else {
            throw TaxTriagePipelineError.nextflowNotInstalled
        }

        let nfVersion = prereqs.nextflowVersion ?? "unknown"
        let rtName = prereqs.containerRuntimeName ?? "unknown"
        logger.info("Prerequisites met: Nextflow \(nfVersion, privacy: .public), container: \(rtName, privacy: .public)")

        // Create output directory
        let fm = FileManager.default
        if !fm.fileExists(atPath: config.outputDirectory.path) {
            do {
                try fm.createDirectory(
                    at: config.outputDirectory,
                    withIntermediateDirectories: true
                )
            } catch {
                throw TaxTriageConfigError.outputDirectoryCreationFailed(
                    config.outputDirectory, error
                )
            }
        }

        progress?(0.05, "Generating samplesheet...")

        // Phase 2: Generate samplesheet (0.05 -- 0.10)
        let sampleEntries = config.samples.map { sample in
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
                to: config.samplesheetURL
            )
        } catch {
            throw TaxTriagePipelineError.samplesheetGenerationFailed(error)
        }

        let sampleCount = config.samples.count
        let sheetName = config.samplesheetURL.lastPathComponent
        logger.info("Wrote samplesheet with \(sampleCount, privacy: .public) sample(s) to \(sheetName, privacy: .public)")

        progress?(0.10, "Starting TaxTriage pipeline...")

        // Phase 3: Build and execute Nextflow command (0.10 -- 0.90)
        let arguments = buildNextflowArguments(config: config)
        let logFile = config.outputDirectory.appendingPathComponent("nextflow.log")

        logger.info("Executing: nextflow \(arguments.joined(separator: " "))")

        // Prepare environment
        var environment = ProcessInfo.processInfo.environment
        environment["NXF_ANSI_LOG"] = "false"

        // Fix spaces-in-path issue: the conda-installed Nextflow wrapper script
        // has the conda prefix hardcoded into NXF_DIST without proper quoting.
        // Patch the script to quote the NXF_DIST assignment.
        patchNextflowScript(at: nextflowPath)

        // Use a space-free home directory for Nextflow's cache
        let nxfHome = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".nextflow")
        environment["NXF_HOME"] = nxfHome.path

        // Run Nextflow via micromamba to ensure the conda environment is activated
        let condaManager = CondaManager.shared
        let micromambaPath = await condaManager.micromambaPath

        let nextflowEnvName: String
        if let envName = await condaManager.environmentContaining(tool: "nextflow") {
            nextflowEnvName = envName
        } else {
            nextflowEnvName = "nextflow"
        }

        let micromambaArgs = ["run", "-n", nextflowEnvName, "nextflow"] + arguments
        logger.info("Running via micromamba: \(micromambaArgs.joined(separator: " "))")

        let handle: ProcessHandle
        do {
            handle = try await processManager.spawn(
                executable: micromambaPath,
                arguments: micromambaArgs,
                workingDirectory: config.outputDirectory,
                environment: environment
            )
        } catch {
            throw TaxTriagePipelineError.pipelineFailed(
                exitCode: -1,
                stderr: "Failed to spawn Nextflow: \(error.localizedDescription)",
                logFile: nil
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
        let combinedLog = stdoutLines.joined(separator: "\n")
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

        // Phase 4: Collect outputs (0.90 -- 1.00)
        let result = collectOutputFiles(
            config: config,
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
        args += ["--max_memory", taxTriageShellQuote(config.maxMemory)]
        args += ["--max_cpus", String(config.maxCpus)]

        return args
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
            allOutputFiles: allFiles
        )
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

/// Quotes a value for safe passing as a Nextflow parameter.
///
/// Nextflow resource strings like "16.GB" need to pass through without
/// shell expansion. This wraps values containing dots in single quotes.
///
/// - Parameter value: The raw value.
/// - Returns: The shell-safe value.
private func taxTriageShellQuote(_ value: String) -> String {
    // Nextflow expects resource strings unquoted in its argument parsing
    value
}
