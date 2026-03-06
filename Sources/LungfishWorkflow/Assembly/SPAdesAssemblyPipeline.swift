// SPAdesAssemblyPipeline.swift - Core SPAdes assembly pipeline
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import os.log
import LungfishIO

private let logger = Logger(subsystem: "com.lungfish.workflow", category: "SPAdesAssemblyPipeline")

// MARK: - SPAdesMode

/// SPAdes assembly modes corresponding to pipeline presets.
public enum SPAdesMode: String, Sendable, CaseIterable, Codable {
    case isolate = "isolate"
    case meta = "meta"
    case plasmid = "plasmid"
    case rna = "rna"
    case biosyntheticSPAdes = "bio"

    /// The SPAdes command-line flag for this mode.
    public var flag: String {
        switch self {
        case .isolate: return "--isolate"
        case .meta: return "--meta"
        case .plasmid: return "--plasmid"
        case .rna: return "--rna"
        case .biosyntheticSPAdes: return "--bio"
        }
    }

    /// Human-readable display name.
    public var displayName: String {
        switch self {
        case .isolate: return "Bacterial Isolate"
        case .meta: return "Metagenome"
        case .plasmid: return "Plasmid"
        case .rna: return "RNA (Transcriptome)"
        case .biosyntheticSPAdes: return "Biosynthetic Gene Clusters"
        }
    }
}

// MARK: - SPAdesAssemblyConfig

/// Configuration for a SPAdes assembly run.
public struct SPAdesAssemblyConfig: Sendable {
    /// Assembly mode.
    public let mode: SPAdesMode
    /// Paired-end forward reads (R1).
    public let forwardReads: [URL]
    /// Paired-end reverse reads (R2), matched by index with forwardReads.
    public let reverseReads: [URL]
    /// Unpaired/single-end reads.
    public let unpairedReads: [URL]
    /// Custom k-mer sizes, or nil for auto.
    public let kmerSizes: [Int]?
    /// Memory limit in GB (passed to SPAdes --memory).
    public let memoryGB: Int
    /// Number of threads.
    public let threads: Int
    /// Minimum contig length to report.
    public let minContigLength: Int
    /// Whether to skip error correction.
    public let skipErrorCorrection: Bool
    /// Output directory on the host.
    public let outputDirectory: URL
    /// Project name for output naming.
    public let projectName: String

    public init(
        mode: SPAdesMode = .isolate,
        forwardReads: [URL] = [],
        reverseReads: [URL] = [],
        unpairedReads: [URL] = [],
        kmerSizes: [Int]? = nil,
        memoryGB: Int = 16,
        threads: Int = 4,
        minContigLength: Int = 200,
        skipErrorCorrection: Bool = false,
        outputDirectory: URL,
        projectName: String = "assembly_output"
    ) {
        self.mode = mode
        self.forwardReads = forwardReads
        self.reverseReads = reverseReads
        self.unpairedReads = unpairedReads
        self.kmerSizes = kmerSizes
        self.memoryGB = memoryGB
        self.threads = threads
        self.minContigLength = minContigLength
        self.skipErrorCorrection = skipErrorCorrection
        self.outputDirectory = outputDirectory
        self.projectName = projectName
    }

    /// All input file URLs.
    public var allInputFiles: [URL] {
        forwardReads + reverseReads + unpairedReads
    }
}

// MARK: - SPAdesAssemblyResult

/// Result of a completed SPAdes assembly.
public struct SPAdesAssemblyResult: Sendable {
    /// Path to the contigs FASTA file.
    public let contigsPath: URL
    /// Path to the scaffolds FASTA file (if produced).
    public let scaffoldsPath: URL?
    /// Path to the assembly graph (GFA format).
    public let graphPath: URL?
    /// Path to the SPAdes log file.
    public let logPath: URL
    /// Path to the params.txt file.
    public let paramsPath: URL?
    /// Assembly statistics computed from contigs.
    public let statistics: AssemblyStatistics
    /// SPAdes version string.
    public let spadesVersion: String?
    /// Total wall-clock time in seconds.
    public let wallTimeSeconds: TimeInterval
    /// The full command line used.
    public let commandLine: String
    /// Exit code from SPAdes.
    public let exitCode: Int32
}

// MARK: - SPAdesAssemblyPipeline

/// Core pipeline for running SPAdes assembly via Apple Containers.
///
/// This class follows the `@unchecked Sendable` pipeline pattern for use
/// from `Task.detached` contexts. Progress is reported via a callback,
/// not via `@Published` properties.
///
/// ## Usage
///
/// ```swift
/// let pipeline = SPAdesAssemblyPipeline()
/// let result = try await pipeline.run(config: config) { progress, message in
///     print("\(Int(progress * 100))%: \(message)")
/// }
/// ```
@available(macOS 26, *)
public final class SPAdesAssemblyPipeline: @unchecked Sendable {

    /// Container image reference for SPAdes.
    public static let spadesImageReference = "docker.io/lungfish/spades:4.0.0-arm64"

    public init() {}

    // MARK: - Run

    /// Runs the SPAdes assembly pipeline.
    ///
    /// - Parameters:
    ///   - config: Assembly configuration
    ///   - runtime: The Apple Container runtime to use
    ///   - progress: Progress callback: (fraction 0-1, status message)
    /// - Returns: Assembly result with paths to outputs and statistics
    /// - Throws: On container errors, SPAdes failures, or cancellation
    public func run(
        config: SPAdesAssemblyConfig,
        runtime: AppleContainerRuntime,
        progress: @escaping @Sendable (Double, String) -> Void
    ) async throws -> SPAdesAssemblyResult {
        let startTime = Date()
        progress(0.0, "Preparing assembly workspace...")

        // Validate input files before expensive operations
        try validateInputs(config: config)

        // Check for cancellation before expensive operations
        try Task.checkCancellation()

        // 1. Create workspace with symlinked input files
        let workspace = try createWorkspace(config: config)
        defer { try? FileManager.default.removeItem(at: workspace.tempDir) }

        // 2. Pull the SPAdes image
        progress(0.02, "Pulling SPAdes container image...")
        let image = try await runtime.pullImage(reference: Self.spadesImageReference)
        try Task.checkCancellation()

        // 3. Build SPAdes command
        // Note: SPAdes version will be extracted from spades.log after the main run
        let command = buildCommand(config: config, workspace: workspace)
        let commandLine = command.joined(separator: " ")
        logger.info("SPAdes command: \(commandLine)")
        progress(0.08, "Starting SPAdes assembly...")

        // 5. Create and run the container
        // Give the container 15% more memory than SPAdes --memory to leave headroom
        // for the Linux kernel, libc, and other OS overhead inside the VM
        let containerMemoryBytes = UInt64(Double(config.memoryGB.gib()) * 1.15)
        let containerConfig = ContainerConfiguration(
            cpuCount: config.threads,
            memoryBytes: containerMemoryBytes,
            mounts: workspace.mounts,
            command: command
        )

        let containerName = "spades-\(config.projectName)-\(UUID().uuidString.prefix(8))"
        let container = try await runtime.createContainer(
            name: containerName,
            image: image,
            config: containerConfig
        )

        // Run container with cancellation support — stop the container if task is cancelled
        let exitCode: Int32
        do {
            exitCode = try await withTaskCancellationHandler {
                try await runtime.runAndWait(container)
            } onCancel: {
                Task {
                    logger.info("Cancellation requested — stopping SPAdes container")
                    try? await runtime.stopContainer(container)
                }
            }
        } catch is CancellationError {
            try? await runtime.stopContainer(container)
            try? await runtime.removeContainer(container)
            throw SPAdesPipelineError.cancelled
        } catch {
            try? await runtime.stopContainer(container)
            try? await runtime.removeContainer(container)
            throw error
        }

        // Cleanup container (stop defensively in case runAndWait didn't fully terminate)
        try? await runtime.stopContainer(container)
        try? await runtime.removeContainer(container)
        try Task.checkCancellation()

        let wallTime = Date().timeIntervalSince(startTime)
        progress(0.95, "Computing assembly statistics...")

        // 6. Collect outputs
        let outputDir = workspace.outputDir
        let contigsPath = outputDir.appendingPathComponent("contigs.fasta")
        let scaffoldsPath = outputDir.appendingPathComponent("scaffolds.fasta")
        let graphPath = outputDir.appendingPathComponent("assembly_graph_with_scaffolds.gfa")
        let logPath = outputDir.appendingPathComponent("spades.log")
        let paramsPath = outputDir.appendingPathComponent("params.txt")

        guard FileManager.default.fileExists(atPath: contigsPath.path) else {
            // Check log for error details
            let logContent = (try? String(contentsOf: logPath, encoding: .utf8)) ?? "No log available"
            let parser = SPAdesOutputParser()
            let lastLines = logContent.split(separator: "\n").suffix(20).map(String.init)
            for line in lastLines {
                if let error = parser.detectError(line) {
                    throw SPAdesPipelineError.spadesError(
                        exitCode: exitCode,
                        message: error.description,
                        suggestion: error.recoverySuggestion
                    )
                }
            }
            throw SPAdesPipelineError.spadesError(
                exitCode: exitCode,
                message: "SPAdes did not produce contigs.fasta (exit code \(exitCode))",
                suggestion: "Check the SPAdes log for details"
            )
        }

        // 7. Compute assembly statistics
        let statistics: AssemblyStatistics
        do {
            statistics = try AssemblyStatisticsCalculator.compute(from: contigsPath)
        } catch {
            logger.error("Failed to compute assembly statistics: \(error)")
            statistics = AssemblyStatisticsCalculator.computeFromLengths([])
        }

        progress(1.0, "Assembly complete!")

        return SPAdesAssemblyResult(
            contigsPath: contigsPath,
            scaffoldsPath: FileManager.default.fileExists(atPath: scaffoldsPath.path) ? scaffoldsPath : nil,
            graphPath: FileManager.default.fileExists(atPath: graphPath.path) ? graphPath : nil,
            logPath: logPath,
            paramsPath: FileManager.default.fileExists(atPath: paramsPath.path) ? paramsPath : nil,
            statistics: statistics,
            spadesVersion: nil, // Extracted from spades.log if needed
            wallTimeSeconds: wallTime,
            commandLine: commandLine,
            exitCode: exitCode
        )
    }

    // MARK: - Input Validation

    /// Validates the assembly configuration before starting the pipeline.
    ///
    /// Checks that:
    /// - At least some input files are provided
    /// - Forward and reverse read counts match (paired-end consistency)
    /// - All referenced input files exist on disk
    ///
    /// - Parameter config: The assembly configuration to validate
    /// - Throws: `SPAdesPipelineError` if validation fails
    private func validateInputs(config: SPAdesAssemblyConfig) throws {
        // Must have at least one input file
        guard !config.allInputFiles.isEmpty else {
            throw SPAdesPipelineError.noInputFiles
        }

        // Paired-end reads must have matching forward/reverse counts
        if !config.forwardReads.isEmpty || !config.reverseReads.isEmpty {
            guard config.forwardReads.count == config.reverseReads.count else {
                throw SPAdesPipelineError.pairedReadsMismatch(
                    forwardCount: config.forwardReads.count,
                    reverseCount: config.reverseReads.count
                )
            }
        }

        // Verify all input files exist
        for file in config.allInputFiles {
            guard FileManager.default.fileExists(atPath: file.path) else {
                throw SPAdesPipelineError.inputFileNotFound(file)
            }
        }
    }

    // MARK: - Command Construction

    /// Builds the SPAdes command line from configuration.
    ///
    /// Visible for testing.
    public func buildCommand(config: SPAdesAssemblyConfig, workspace: SPAdesWorkspace) -> [String] {
        var args = ["spades.py"]

        // Mode flag
        args.append(config.mode.flag)

        // Input files (using container paths via workspace file name map)
        let nameFor: (URL) -> String = { url in
            workspace.fileNameMap[url] ?? url.lastPathComponent
        }

        for (index, _) in config.forwardReads.enumerated() {
            args += ["-1", "/input/\(nameFor(config.forwardReads[index]))"]
            if index < config.reverseReads.count {
                args += ["-2", "/input/\(nameFor(config.reverseReads[index]))"]
            }
        }

        for read in config.unpairedReads {
            args += ["-s", "/input/\(nameFor(read))"]
        }

        // K-mer sizes
        if let kmers = config.kmerSizes, !kmers.isEmpty {
            args += ["-k", kmers.map(String.init).joined(separator: ",")]
        }

        // Resource limits
        args += ["--memory", String(config.memoryGB)]
        args += ["--threads", String(config.threads)]

        // Error correction
        if config.skipErrorCorrection {
            args.append("--only-assembler")
        }

        // Minimum contig length (SPAdes 4.0+ supports this)
        if config.minContigLength > 0 {
            args += ["--min-contig-length", String(config.minContigLength)]
        }

        // Output directory (inside container)
        args += ["-o", "/output"]

        return args
    }

    // MARK: - Workspace

    /// Creates a temporary workspace with symlinked input files.
    ///
    /// Deduplicates filenames to prevent silent overwrites when files from
    /// different directories share the same name. The mapping from original
    /// URL to workspace filename is stored in the returned workspace.
    private func createWorkspace(config: SPAdesAssemblyConfig) throws -> SPAdesWorkspace {
        let tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("lungfish-spades-\(UUID().uuidString.prefix(8))")
        let inputDir = tempDir.appendingPathComponent("input")
        let outputDir = config.outputDirectory.appendingPathComponent(config.projectName)

        try FileManager.default.createDirectory(at: inputDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)

        // Symlink input files, deduplicating names to prevent collisions
        var usedNames = Set<String>()
        var fileNameMap: [URL: String] = [:]

        for file in config.allInputFiles {
            var name = file.lastPathComponent
            if usedNames.contains(name) {
                // Deduplicate: insert index before extension
                let stem = file.deletingPathExtension().lastPathComponent
                let ext = file.pathExtension
                var index = 2
                repeat {
                    name = ext.isEmpty ? "\(stem)_\(index)" : "\(stem)_\(index).\(ext)"
                    index += 1
                } while usedNames.contains(name)
                logger.info("Renamed duplicate input: \(file.lastPathComponent) → \(name)")
            }
            usedNames.insert(name)
            fileNameMap[file] = name

            let dest = inputDir.appendingPathComponent(name)
            try FileManager.default.createSymbolicLink(at: dest, withDestinationURL: file)
        }

        let mounts = [
            MountBinding(source: inputDir, destination: "/input", readOnly: true),
            MountBinding(source: outputDir, destination: "/output", readOnly: false),
        ]

        return SPAdesWorkspace(
            tempDir: tempDir,
            inputDir: inputDir,
            outputDir: outputDir,
            mounts: mounts,
            fileNameMap: fileNameMap
        )
    }

}

// MARK: - SPAdesWorkspace

/// Temporary workspace for a SPAdes assembly run.
public struct SPAdesWorkspace: Sendable {
    /// Root of the temporary workspace.
    public let tempDir: URL
    /// Directory containing symlinked input files.
    public let inputDir: URL
    /// Output directory on the host.
    public let outputDir: URL
    /// Mount bindings for the container.
    public let mounts: [MountBinding]
    /// Maps original file URLs to their (possibly deduplicated) workspace filenames.
    public let fileNameMap: [URL: String]
}

// MARK: - SPAdesPipelineError

/// Errors from the SPAdes assembly pipeline.
public enum SPAdesPipelineError: Error, LocalizedError {
    case noInputFiles
    case inputFileNotFound(URL)
    case pairedReadsMismatch(forwardCount: Int, reverseCount: Int)
    case runtimeUnavailable(String)
    case spadesError(exitCode: Int32, message: String, suggestion: String)
    case outputNotFound(String)
    case cancelled

    public var errorDescription: String? {
        switch self {
        case .noInputFiles:
            return "No input FASTQ files provided"
        case .inputFileNotFound(let url):
            return "Input file not found: \(url.lastPathComponent)"
        case .pairedReadsMismatch(let fwd, let rev):
            return "Paired-end read count mismatch: \(fwd) forward reads vs \(rev) reverse reads"
        case .runtimeUnavailable(let reason):
            return "Container runtime unavailable: \(reason)"
        case .spadesError(let code, let message, _):
            return "SPAdes failed (exit \(code)): \(message)"
        case .outputNotFound(let path):
            return "Expected output not found: \(path)"
        case .cancelled:
            return "Assembly was cancelled"
        }
    }

    public var recoverySuggestion: String? {
        switch self {
        case .noInputFiles:
            return "Add at least one FASTQ file"
        case .inputFileNotFound:
            return "Check the file path and permissions"
        case .pairedReadsMismatch:
            return "Ensure each forward read (R1) has a corresponding reverse read (R2)"
        case .runtimeUnavailable:
            return "Requires macOS 26+ on Apple Silicon"
        case .spadesError(_, _, let suggestion):
            return suggestion
        case .outputNotFound:
            return "Check the SPAdes log for errors"
        case .cancelled:
            return nil
        }
    }
}
