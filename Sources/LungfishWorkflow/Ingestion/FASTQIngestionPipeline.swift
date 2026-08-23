// FASTQIngestionPipeline.swift - Clumpify and compress FASTQ files
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import os.log
import LungfishCore
import LungfishIO

private let logger = Logger(subsystem: LogSubsystem.workflow, category: "FASTQIngestionPipeline")

// MARK: - QualityBinningScheme

/// Quality score binning schemes for FASTQ compression optimization.
///
/// Binning reduces the alphabet of quality characters, improving gzip compression.
/// All schemes preserve enough resolution for variant calling and QC.
public enum QualityBinningScheme: String, Sendable, CaseIterable, Codable {
    /// Illumina NovaSeq/NovaSeqX native binning (4 levels).
    case illumina4
    /// 8-level binning — good balance of compression and resolution.
    case eightLevel
    /// No binning — preserve original quality scores.
    case none
}

// MARK: - FASTQIngestionConfig

/// Configuration for the FASTQ ingestion pipeline.
public struct FASTQIngestionConfig: Sendable {

    /// Pairing mode for the input files.
    public enum PairingMode: String, Sendable {
        case singleEnd
        case pairedEnd
        case interleaved
    }

    /// Input FASTQ files. For paired-end, provide [R1, R2].
    public let inputFiles: [URL]

    /// Pairing mode.
    public let pairingMode: PairingMode

    /// Output directory where the processed file will be written.
    public let outputDirectory: URL

    /// Number of threads for pigz compression.
    public let threads: Int

    /// Whether to delete original files after successful ingestion.
    public let deleteOriginals: Bool

    /// Quality binning scheme for compression optimization.
    public let qualityBinning: QualityBinningScheme

    /// Gzip compression level for tool output when supported.
    public let compressionLevel: CompressionLevel

    /// Requested storage optimization tool. `.auto` resolves after recipe execution
    /// against the actual files that will be optimized.
    public let clumpingTool: ClumpingTool

    /// Whether to skip storage optimization. Preserved for older call sites.
    public var skipClumpify: Bool { clumpingTool == .none }

    public init(
        inputFiles: [URL],
        pairingMode: PairingMode = .singleEnd,
        outputDirectory: URL,
        threads: Int = 4,
        deleteOriginals: Bool = true,
        qualityBinning: QualityBinningScheme = .illumina4,
        skipClumpify: Bool = false,
        compressionLevel: CompressionLevel = .balanced,
        clumpingTool: ClumpingTool = .default
    ) {
        self.inputFiles = inputFiles
        self.pairingMode = pairingMode
        self.outputDirectory = outputDirectory
        self.threads = threads
        self.deleteOriginals = deleteOriginals
        self.qualityBinning = qualityBinning
        self.compressionLevel = compressionLevel
        self.clumpingTool = skipClumpify ? .none : clumpingTool
    }
}

// MARK: - FASTQIngestionResult

/// Result of the FASTQ ingestion pipeline.
public struct FASTQIngestionResult: Sendable {
    /// URL of the final processed FASTQ file (.fastq.gz).
    public let outputFile: URL
    /// Whether the file was clumpified (k-mer sorted).
    public let wasClumpified: Bool
    /// Quality binning scheme applied.
    public let qualityBinning: QualityBinningScheme
    /// Original filenames before processing.
    public let originalFilenames: [String]
    /// Original total size in bytes (before processing).
    public let originalSizeBytes: Int64
    /// Final size in bytes (after processing).
    public let finalSizeBytes: Int64
    /// Pairing mode of the output.
    public let pairingMode: FASTQIngestionConfig.PairingMode
    /// Requested clumping tool before automatic resolution.
    public let requestedClumpingTool: ClumpingTool
    /// Resolved clumping tool used for this run.
    public let resolvedClumpingTool: ClumpingTool
    /// Automatic clumping decision details.
    public let clumpingResolution: ClumpingToolResolution
    /// Tool used for the final storage-optimization/compression step.
    public let processingTool: String?
    /// Version of ``processingTool`` captured at execution time.
    public let processingToolVersion: String?
    /// Command line used for the final storage-optimization/compression step.
    public let processingCommandLine: String?
    /// Provenance records for external tool steps run by this pipeline.
    public let provenanceSteps: [StepExecution]

    public init(
        outputFile: URL,
        wasClumpified: Bool,
        qualityBinning: QualityBinningScheme,
        originalFilenames: [String],
        originalSizeBytes: Int64,
        finalSizeBytes: Int64,
        pairingMode: FASTQIngestionConfig.PairingMode,
        requestedClumpingTool: ClumpingTool = .default,
        resolvedClumpingTool: ClumpingTool? = nil,
        clumpingResolution: ClumpingToolResolution? = nil,
        processingTool: String? = nil,
        processingToolVersion: String? = nil,
        processingCommandLine: String? = nil,
        provenanceSteps: [StepExecution] = []
    ) {
        self.outputFile = outputFile
        self.wasClumpified = wasClumpified
        self.qualityBinning = qualityBinning
        self.originalFilenames = originalFilenames
        self.originalSizeBytes = originalSizeBytes
        self.finalSizeBytes = finalSizeBytes
        self.pairingMode = pairingMode
        let resolution = clumpingResolution ?? requestedClumpingTool.resolve(estimatedInputBytes: originalSizeBytes)
        self.requestedClumpingTool = requestedClumpingTool
        self.resolvedClumpingTool = resolvedClumpingTool ?? resolution.resolved
        self.clumpingResolution = resolution
        self.processingTool = processingTool
        self.processingToolVersion = processingToolVersion
        self.processingCommandLine = processingCommandLine
        self.provenanceSteps = provenanceSteps
    }
}

private struct FASTQProcessingRecord: Sendable {
    let url: URL
    let tool: String
    let toolVersion: String?
    let commandLine: String
    let steps: [StepExecution]
}

// MARK: - FASTQIngestionError

public enum FASTQIngestionError: Error, LocalizedError {
    case noInputFiles
    case inputFileNotFound(URL)
    case pairedEndRequiresTwoFiles
    case clumpifyFailed(String)
    case compressionFailed(String)
    case toolNotFound(String)

    public var errorDescription: String? {
        switch self {
        case .noInputFiles:
            return "No input FASTQ files provided"
        case .inputFileNotFound(let url):
            return "Input file not found: \(url.lastPathComponent)"
        case .pairedEndRequiresTwoFiles:
            return "Paired-end mode requires exactly 2 input files (R1 and R2)"
        case .clumpifyFailed(let msg):
            return "Clumpify failed: \(msg)"
        case .compressionFailed(let msg):
            return "Compression failed: \(msg)"
        case .toolNotFound(let tool):
            return "Required tool not found: \(tool)"
        }
    }
}

// MARK: - FASTQIngestionPipeline

/// Pipeline that processes raw FASTQ files into a compressed, optimized format:
/// 1. **Clumpify** (BBTools `clumpify.sh`) — reorders reads by k-mer similarity
/// 2. **Compress** (pigz/bgzip) — gzip/BGZF compression
///
/// The clumpify step sorts reads so that sequences sharing k-mers are adjacent,
/// letting gzip find longer matches and improving downstream storage locality.
///
/// Original files are deleted after successful processing.
public final class FASTQIngestionPipeline: @unchecked Sendable {

    private let runner = NativeToolRunner.shared

    public init() {}

    /// Runs the ingestion pipeline.
    ///
    /// - Parameters:
    ///   - config: Ingestion configuration
    ///   - clumpingResolution: Resolution already chosen for this invocation, when available
    ///   - progress: Progress callback (fraction 0-1, status message)
    /// - Returns: Ingestion result with output file paths
    public func run(
        config: FASTQIngestionConfig,
        clumpingResolution suppliedClumpingResolution: ClumpingToolResolution? = nil,
        progress: @escaping @Sendable (Double, String) -> Void
    ) async throws -> FASTQIngestionResult {

        // Validate inputs
        guard !config.inputFiles.isEmpty else {
            throw FASTQIngestionError.noInputFiles
        }

        if config.pairingMode == .pairedEnd && config.inputFiles.count != 2 {
            throw FASTQIngestionError.pairedEndRequiresTwoFiles
        }

        for file in config.inputFiles {
            guard FileManager.default.fileExists(atPath: file.path) else {
                throw FASTQIngestionError.inputFileNotFound(file)
            }
        }

        let originalFilenames = config.inputFiles.map { $0.lastPathComponent }
        let originalSize = config.inputFiles.reduce(Int64(0)) { total, url in
            let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
            return total + (attrs?[.size] as? Int64 ?? 0)
        }
        let estimatedInputBytes = Self.estimatedUncompressedInputBytes(for: config.inputFiles)
        let clumpingResolution = suppliedClumpingResolution
            ?? config.clumpingTool.resolve(estimatedInputBytes: estimatedInputBytes)
        precondition(
            clumpingResolution.requested == config.clumpingTool,
            "Clumping resolution must preserve the requested tool"
        )

        let baseName = Self.deriveBaseName(from: config.inputFiles[0])
        var outputFile = config.outputDirectory.appendingPathComponent("\(baseName).fastq.gz")
        if config.inputFiles.contains(where: { $0.standardizedFileURL == outputFile.standardizedFileURL }) {
            outputFile = config.outputDirectory.appendingPathComponent("\(baseName).clumped.fastq.gz")
        }

        try FileManager.default.createDirectory(
            at: config.outputDirectory,
            withIntermediateDirectories: true
        )

        // Step 1: Clumpify + quality bin (50% of progress)
        let clumpifiedFile: URL
        let wasClumpified: Bool
        var processingRecord: FASTQProcessingRecord?
        var provenanceSteps: [StepExecution] = []

        switch clumpingResolution.resolved {
        case .none:
            logger.info("Clumpify skipped (disabled in preferences)")
            clumpifiedFile = config.inputFiles[0]
            wasClumpified = false
            progress(0.5, "Clumpify disabled, skipping...")
        case .bbtools:
            progress(0.0, "Sorting reads by k-mer similarity...")
            do {
                let record = try await clumpify(
                    config: config,
                    outputFile: outputFile,
                    progress: { fraction, msg in
                        progress(fraction * 0.5, msg)
                    }
                )
                clumpifiedFile = record.url
                processingRecord = record
                provenanceSteps.append(contentsOf: record.steps)
                wasClumpified = true
            } catch {
                // Clumpify is mandatory for imported FASTQ workflows.
                throw FASTQIngestionError.clumpifyFailed(error.localizedDescription)
            }
        case .trimGalore:
            progress(0.0, "Optimizing reads with Trim Galore...")
            do {
                let record = try await trimGaloreClumpify(
                    config: config,
                    outputFile: outputFile,
                    progress: { fraction, msg in
                        progress(fraction * 0.5, msg)
                    }
                )
                clumpifiedFile = record.url
                processingRecord = record
                provenanceSteps.append(contentsOf: record.steps)
                wasClumpified = true
            } catch {
                throw FASTQIngestionError.clumpifyFailed(error.localizedDescription)
            }
        case .auto:
            preconditionFailure("ClumpingTool.auto must resolve to a concrete tool")
        }

        try Task.checkCancellation()

        // Step 2: Compress with pigz/bgzip (35% of progress)
        progress(0.5, "Compressing...")
        let compressedFile: URL

        if wasClumpified {
            // clumpify.sh already produced compressed output with pigz.
            compressedFile = clumpifiedFile
            progress(0.85, "Compression complete (bbtools)")
        } else if clumpifiedFile.pathExtension == "gz" {
            // Already compressed and clumpification was skipped
            compressedFile = clumpifiedFile
            progress(0.85, "Already compressed")
        } else {
            let record = try await compress(
                inputFile: clumpifiedFile,
                outputFile: outputFile,
                threads: config.threads,
                progress: { fraction, msg in
                    progress(0.5 + fraction * 0.35, msg)
                }
            )
            compressedFile = record.url
            processingRecord = record
            provenanceSteps.append(contentsOf: record.steps)
        }

        // Delete originals if requested
        if config.deleteOriginals {
            for original in config.inputFiles {
                if original != compressedFile {
                    try? FileManager.default.removeItem(at: original)
                    logger.info("Deleted original: \(original.lastPathComponent)")
                }
            }
        }

        let finalAttrs = try? FileManager.default.attributesOfItem(atPath: compressedFile.path)
        let finalSize = (finalAttrs?[.size] as? Int64) ?? 0

        progress(1.0, "Ingestion complete")

        let outputPairingMode: FASTQIngestionConfig.PairingMode = {
            switch config.pairingMode {
            case .pairedEnd:
                // Paired inputs are normalized to a single interleaved output file.
                return .interleaved
            case .singleEnd, .interleaved:
                return config.pairingMode
            }
        }()

        return FASTQIngestionResult(
            outputFile: compressedFile,
            wasClumpified: wasClumpified,
            qualityBinning: config.qualityBinning,
            originalFilenames: originalFilenames,
            originalSizeBytes: originalSize,
            finalSizeBytes: finalSize,
            pairingMode: outputPairingMode,
            requestedClumpingTool: clumpingResolution.requested,
            resolvedClumpingTool: clumpingResolution.resolved,
            clumpingResolution: clumpingResolution,
            processingTool: processingRecord?.tool,
            processingToolVersion: processingRecord?.toolVersion,
            processingCommandLine: processingRecord?.commandLine,
            provenanceSteps: provenanceSteps
        )
    }

    // MARK: - Pipeline Steps

    /// Sorts reads by k-mer similarity using managed BBTools `clumpify.sh`.
    ///
    /// This writes directly to a gzip output so we can avoid an extra
    /// compression pass while keeping compatibility with `samtools fqidx`.
    private func clumpify(
        config: FASTQIngestionConfig,
        outputFile: URL,
        progress: @escaping @Sendable (Double, String) -> Void
    ) async throws -> FASTQProcessingRecord {
        let inputFile = config.inputFiles[0]
        let inputFile2 = config.pairingMode == .pairedEnd ? config.inputFiles[1] : nil
        let clumpifyScript = try await runner.toolPath(for: .clumpify)
        let timeoutSeconds = max(900, Double((try? FileManager.default.attributesOfItem(atPath: inputFile.path)[.size] as? Int64) ?? 0) / 2_500_000)

        var env = CoreToolLocator.bbToolsEnvironment(
            homeDirectory: FileManager.default.homeDirectoryForCurrentUser,
            existingPath: ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
        )

        // BBTools internally calls pigz/gzip without quoting paths, so spaces
        // break at multiple levels (shell eval AND internal tool invocations).
        // Use symlinks for inputs and a temp name for outputs to ensure all paths
        // are space-free throughout the entire BBTools pipeline.
        let fm = FileManager.default
        var symlinksToCleanup: [URL] = []

        let safeInput = try Self.bbToolsSafePath(for: inputFile, fm: fm, cleanup: &symlinksToCleanup)
        let safeOutput = try Self.bbToolsSafeOutputPath(for: outputFile, cleanup: &symlinksToCleanup)

        // Heap sizing lives in ManagedJavaHeapPolicy so an import never plans
        // to use memory a concurrently running classifier already holds.
        let heapGB = ManagedJavaHeapPolicy.heapGB(minimumGB: 4)

        // Override any JAVA_TOOL_OPTIONS that might constrain heap below our calculated value.
        // BBTools reads -Xmx from its own args, but _JAVA_OPTIONS takes highest priority.
        env["_JAVA_OPTIONS"] = "-Xmx\(heapGB)g"

        var args = [
            "in=\(safeInput.path)",
            "out=\(safeOutput.path)",
            "-Xmx\(heapGB)g",
            "ow=t",
            "reorder",
            "groups=auto",
            "pigz=t",
            "zl=4",
            "threads=\(max(1, config.threads))"
        ]

        if let inputFile2 {
            let safeInput2 = try Self.bbToolsSafePath(for: inputFile2, fm: fm, cleanup: &symlinksToCleanup)
            args.append("in2=\(safeInput2.path)")
            args.append("interleaved=t")
        }

        switch config.qualityBinning {
        case .illumina4:
            args.append("quantize=0,8,13,22,27,32,37")
        case .eightLevel:
            args.append("quantize=2")
        case .none:
            break
        }

        progress(0.05, "Launching bbtools clumpify.sh...")

        defer {
            for link in symlinksToCleanup { try? fm.removeItem(at: link) }
        }

        let stepStartedAt = Date()
        let result = try await runner.runProcess(
            executableURL: clumpifyScript,
            arguments: args,
            workingDirectory: config.outputDirectory,
            environment: env,
            timeout: timeoutSeconds,
            toolName: "clumpify.sh"
        )
        let stepCompletedAt = Date()

        // Move temp output to the real path if we used a space-free name.
        if safeOutput != outputFile, fm.fileExists(atPath: safeOutput.path) {
            try? fm.removeItem(at: outputFile)
            do {
                try fm.moveItem(at: safeOutput, to: outputFile)
            } catch {
                try fm.copyItem(at: safeOutput, to: outputFile)
                try? fm.removeItem(at: safeOutput)
            }
        }

        guard result.isSuccess else {
            let stderr = result.stderr.isEmpty ? result.stdout : result.stderr
            throw FASTQIngestionError.clumpifyFailed(
                String(stderr.suffix(2_000)).trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }

        guard fm.fileExists(atPath: outputFile.path) else {
            throw FASTQIngestionError.clumpifyFailed("clumpify.sh completed without producing output")
        }

        progress(1.0, "clumpify.sh complete")
        logger.info("Clumpified reads with bbtools (\(config.qualityBinning.rawValue) binning)")

        let toolVersion = await runner.getToolVersion(.clumpify) ?? Self.pinnedManagedToolVersion(named: "bbtools")
        let step = StepExecution(
            toolName: "clumpify.sh",
            toolVersion: toolVersion ?? "unknown",
            command: [clumpifyScript.path] + args,
            inputs: config.inputFiles.map {
                ProvenanceRecorder.fileRecord(url: $0, format: .fastq, role: .input)
            },
            outputs: [ProvenanceRecorder.fileRecord(url: outputFile, format: .fastq, role: .output)],
            exitCode: result.exitCode,
            wallTime: stepCompletedAt.timeIntervalSince(stepStartedAt),
            stderr: result.stderr.isEmpty ? nil : result.stderr,
            startTime: stepStartedAt,
            endTime: stepCompletedAt
        )
        return FASTQProcessingRecord(
            url: outputFile,
            tool: "clumpify.sh",
            toolVersion: toolVersion,
            commandLine: "clumpify.sh \(args.joined(separator: " "))",
            steps: [step]
        )
    }

    /// Runs Trim Galore's `--clumpify` mode for final-stage FASTQ storage optimization.
    ///
    /// Trim Galore writes paired-end data as two files, while Lungfish bundles store
    /// paired imports as one interleaved FASTQ. For paired inputs, this method uses
    /// BBTools `reformat.sh` only as a streaming interleaver after Trim Galore.
    private func trimGaloreClumpify(
        config: FASTQIngestionConfig,
        outputFile: URL,
        progress: @escaping @Sendable (Double, String) -> Void
    ) async throws -> FASTQProcessingRecord {
        let fm = FileManager.default
        let trimGalore = try await runner.toolPath(for: .trimGalore)
        let trimOutputDirectory = config.outputDirectory.appendingPathComponent(
            "trim-galore-\(UUID().uuidString)",
            isDirectory: true
        )
        try fm.createDirectory(at: trimOutputDirectory, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: trimOutputDirectory) }

        let timeoutSeconds = max(900, Double(Self.estimatedUncompressedInputBytes(for: config.inputFiles)) / 2_500_000)
        let args = Self.trimGaloreClumpifyArguments(
            inputFiles: config.inputFiles,
            outputDirectory: trimOutputDirectory,
            pairingMode: config.pairingMode,
            threads: config.threads,
            compressionLevel: config.compressionLevel,
            memoryBytes: ClumpingTool.clumpifyHeapBytes(
                physicalMemoryBytes: Int64(clamping: ProcessInfo.processInfo.physicalMemory)
            )
        )

        progress(0.05, "Launching Trim Galore --clumpify...")
        let stepStartedAt = Date()
        let result = try await runner.runProcess(
            executableURL: trimGalore,
            arguments: args,
            workingDirectory: config.outputDirectory,
            timeout: timeoutSeconds,
            toolName: "trim_galore"
        )
        let stepCompletedAt = Date()

        guard result.isSuccess else {
            let stderr = result.stderr.isEmpty ? result.stdout : result.stderr
            throw FASTQIngestionError.clumpifyFailed(
                String(stderr.suffix(2_000)).trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }

        let toolVersion = await runner.getToolVersion(.trimGalore) ?? Self.pinnedManagedToolVersion(named: "trim_galore")
        let trimStep = StepExecution(
            toolName: "trim_galore",
            toolVersion: toolVersion ?? "unknown",
            command: [trimGalore.path] + args,
            inputs: config.inputFiles.map {
                ProvenanceRecorder.fileRecord(url: $0, format: .fastq, role: .input)
            },
            outputs: [ProvenanceRecorder.fileOrDirectoryRecord(url: trimOutputDirectory, format: .unknown, role: .output)],
            exitCode: result.exitCode,
            wallTime: stepCompletedAt.timeIntervalSince(stepStartedAt),
            stderr: result.stderr.isEmpty ? nil : result.stderr,
            startTime: stepStartedAt,
            endTime: stepCompletedAt
        )

        if config.pairingMode == .pairedEnd {
            let pairedOutputs = try Self.trimGalorePairedOutputs(in: trimOutputDirectory)
            let interleaveRecord = try await interleavePairedFASTQ(
                r1: pairedOutputs.r1,
                r2: pairedOutputs.r2,
                outputFile: outputFile,
                config: config,
                progress: { fraction, msg in progress(0.75 + fraction * 0.25, msg) }
            )
            return FASTQProcessingRecord(
                url: interleaveRecord.url,
                tool: "trim_galore",
                toolVersion: toolVersion,
                commandLine: "trim_galore \(args.joined(separator: " ")) && \(interleaveRecord.commandLine)",
                steps: [trimStep] + interleaveRecord.steps
            )
        }

        let trimmedOutput = try Self.trimGaloreSingleOutput(in: trimOutputDirectory)
        try? fm.removeItem(at: outputFile)
        try fm.moveItem(at: trimmedOutput, to: outputFile)

        guard fm.fileExists(atPath: outputFile.path) else {
            throw FASTQIngestionError.clumpifyFailed("trim_galore completed without producing output")
        }

        progress(1.0, "Trim Galore complete")
        return FASTQProcessingRecord(
            url: outputFile,
            tool: "trim_galore",
            toolVersion: toolVersion,
            commandLine: "trim_galore \(args.joined(separator: " "))",
            steps: [trimStep]
        )
    }

    private func interleavePairedFASTQ(
        r1: URL,
        r2: URL,
        outputFile: URL,
        config: FASTQIngestionConfig,
        progress: @escaping @Sendable (Double, String) -> Void
    ) async throws -> FASTQProcessingRecord {
        let reformat = try await runner.toolPath(for: .reformat)
        let args = [
            "in1=\(r1.path)",
            "in2=\(r2.path)",
            "out=\(outputFile.path)",
            "ow=t",
            "pigz=t",
            "zl=\(config.compressionLevel.zlValue)",
            "threads=\(max(1, config.threads))",
            "interleaved=t",
        ]
        let timeoutSeconds = max(600, Double(Self.estimatedUncompressedInputBytes(for: [r1, r2])) / 5_000_000)
        progress(0.1, "Interleaving paired Trim Galore outputs...")

        let stepStartedAt = Date()
        let result = try await runner.runProcess(
            executableURL: reformat,
            arguments: args,
            workingDirectory: config.outputDirectory,
            environment: CoreToolLocator.bbToolsEnvironment(
                homeDirectory: FileManager.default.homeDirectoryForCurrentUser,
                existingPath: ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
            ),
            timeout: timeoutSeconds,
            toolName: "reformat.sh"
        )
        let stepCompletedAt = Date()

        guard result.isSuccess else {
            throw FASTQIngestionError.clumpifyFailed(
                String((result.stderr.isEmpty ? result.stdout : result.stderr).suffix(2_000))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }
        guard FileManager.default.fileExists(atPath: outputFile.path) else {
            throw FASTQIngestionError.clumpifyFailed("reformat.sh completed without producing interleaved output")
        }

        let toolVersion = await runner.getToolVersion(.reformat) ?? Self.pinnedManagedToolVersion(named: "bbtools")
        let step = StepExecution(
            toolName: "reformat.sh",
            toolVersion: toolVersion ?? "unknown",
            command: [reformat.path] + args,
            inputs: [
                ProvenanceRecorder.fileRecord(url: r1, format: .fastq, role: .input),
                ProvenanceRecorder.fileRecord(url: r2, format: .fastq, role: .input),
            ],
            outputs: [ProvenanceRecorder.fileRecord(url: outputFile, format: .fastq, role: .output)],
            exitCode: result.exitCode,
            wallTime: stepCompletedAt.timeIntervalSince(stepStartedAt),
            stderr: result.stderr.isEmpty ? nil : result.stderr,
            startTime: stepStartedAt,
            endTime: stepCompletedAt
        )

        progress(1.0, "Interleaving complete")
        return FASTQProcessingRecord(
            url: outputFile,
            tool: "reformat.sh",
            toolVersion: toolVersion,
            commandLine: "reformat.sh \(args.joined(separator: " "))",
            steps: [step]
        )
    }

    /// Returns a space-free path for BBTools by symlinking if needed.
    ///
    /// BBTools internally invokes pigz/gzip without quoting paths, so spaces
    /// break even after surviving the shell `eval`. Symlinks provide a clean
    /// space-free path that works at every level.
    private static func bbToolsSafePath(
        for url: URL,
        fm: FileManager,
        cleanup: inout [URL]
    ) throws -> URL {
        guard url.path.contains(" ") else { return url }
        let linkDir = try ProjectTempDirectory.create(
            prefix: "lungfish-bbtools-",
            contextURL: url,
            policy: .systemOnly
        )
        let linkURL = linkDir.appendingPathComponent(bbToolsShellSafeLeafName(for: url))
        try fm.createSymbolicLink(at: linkURL, withDestinationURL: url)
        cleanup.append(linkDir)
        return linkURL
    }

    /// Returns a space-free output path for BBTools.
    ///
    /// For output files, symlinks don't reliably work (tools may delete and
    /// recreate). Use a temp name in system temp and then move/copy into place.
    private static func bbToolsSafeOutputPath(
        for url: URL,
        cleanup: inout [URL]
    ) throws -> URL {
        guard url.path.contains(" ") else { return url }
        let outputDir = try ProjectTempDirectory.create(
            prefix: "lungfish-bbtools-",
            contextURL: url,
            policy: .systemOnly
        )
        cleanup.append(outputDir)
        return outputDir.appendingPathComponent(bbToolsShellSafeLeafName(for: url))
    }

    private static func bbToolsShellSafeLeafName(for url: URL) -> String {
        let suffix: String
        if url.pathExtension.isEmpty {
            suffix = ""
        } else {
            suffix = ".\(url.pathExtension)"
        }
        return "bbtools-\(UUID().uuidString.lowercased())\(suffix)"
    }

    /// Compresses a FASTQ file with pigz (parallel gzip) or bgzip.
    private func compress(
        inputFile: URL,
        outputFile: URL,
        threads: Int,
        progress: @escaping @Sendable (Double, String) -> Void
    ) async throws -> FASTQProcessingRecord {
        let tool: NativeTool
        let args: [String]

        if (try? await runner.toolPath(for: .bgzip)) != nil {
            tool = .bgzip
            args = ["-@", String(threads), "-c", inputFile.path]
        } else if (try? await runner.toolPath(for: .pigz)) != nil {
            tool = .pigz
            args = ["-p", String(threads), "-c", inputFile.path]
        } else {
            throw FASTQIngestionError.toolNotFound("pigz or bgzip")
        }

        let inputAttrs = try? FileManager.default.attributesOfItem(atPath: inputFile.path)
        let inputSize = (inputAttrs?[.size] as? Int64) ?? 0
        let timeoutSeconds = max(600, Double(inputSize) / 5_000_000)

        progress(0.1, "Compressing with \(tool.executableName)...")

        let executableURL = try await runner.findTool(tool)
        let stepStartedAt = Date()
        let result = try await runner.runWithFileOutput(
            tool,
            arguments: args,
            outputFile: outputFile,
            timeout: timeoutSeconds
        )
        let stepCompletedAt = Date()

        guard result.isSuccess else {
            throw FASTQIngestionError.compressionFailed(
                String(result.stderr.suffix(500)).trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }

        progress(1.0, "Compression complete")
        let toolVersion = await runner.getToolVersion(tool) ?? Self.pinnedVersion(for: tool)
        let step = StepExecution(
            toolName: tool.executableName,
            toolVersion: toolVersion ?? "unknown",
            command: [executableURL.path] + args + [">", outputFile.path],
            inputs: [ProvenanceRecorder.fileRecord(url: inputFile, format: .fastq, role: .input)],
            outputs: [ProvenanceRecorder.fileRecord(url: outputFile, format: .fastq, role: .output)],
            exitCode: result.exitCode,
            wallTime: stepCompletedAt.timeIntervalSince(stepStartedAt),
            stderr: result.stderr.isEmpty ? nil : result.stderr,
            startTime: stepStartedAt,
            endTime: stepCompletedAt
        )
        return FASTQProcessingRecord(
            url: outputFile,
            tool: tool.executableName,
            toolVersion: toolVersion,
            commandLine: "\(tool.executableName) \(args.joined(separator: " ")) > \(outputFile.path)",
            steps: [step]
        )
    }

    private static func pinnedVersion(for tool: NativeTool) -> String? {
        switch tool {
        case .clumpify, .bbduk, .bbmerge, .repair, .tadpole, .reformat, .bbmap, .mapPacBio:
            return pinnedManagedToolVersion(named: "bbtools")
        case .bgzip:
            return pinnedManagedToolVersion(named: "htslib")
        case .pigz:
            return pinnedManagedToolVersion(named: "pigz")
        case .trimGalore:
            return pinnedManagedToolVersion(named: "trim_galore")
        default:
            return nil
        }
    }

    private static func pinnedManagedToolVersion(named id: String) -> String? {
        (try? ManagedToolLock.loadFromBundle().tool(named: id)?.version) ?? nil
    }

    // MARK: - Helpers

    public static func estimatedUncompressedInputBytes(for urls: [URL]) -> Int64 {
        urls.reduce(Int64(0)) { total, url in
            let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
            let size = attrs?[.size] as? Int64 ?? 0
            let multiplier: Int64 = isGzipCompressed(url) ? 4 : 1
            return total + size * multiplier
        }
    }

    public static func trimGaloreClumpifyArguments(
        inputFiles: [URL],
        outputDirectory: URL,
        pairingMode: FASTQIngestionConfig.PairingMode,
        threads: Int,
        compressionLevel: CompressionLevel,
        memoryBytes: Int64
    ) -> [String] {
        let memoryGB = max(1, memoryBytes / 1_073_741_824)
        var args = [
            "--clumpify",
            "--compression", String(compressionLevel.zlValue),
            "--cores", String(max(2, threads)),
            "--memory", "\(memoryGB)G",
            "--output_dir", outputDirectory.path,
        ]
        if pairingMode == .pairedEnd {
            args.append("--paired")
        }
        args.append(contentsOf: inputFiles.map(\.path))
        return args
    }

    private static func trimGaloreSingleOutput(in directory: URL) throws -> URL {
        let outputs = try fastqOutputs(in: directory).filter {
            $0.lastPathComponent.hasSuffix("_trimmed.fq.gz")
                || $0.lastPathComponent.hasSuffix("_trimmed.fastq.gz")
        }
        guard let output = outputs.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }).first else {
            throw FASTQIngestionError.clumpifyFailed("trim_galore did not produce a single-end clumped FASTQ")
        }
        return output
    }

    private static func trimGalorePairedOutputs(in directory: URL) throws -> (r1: URL, r2: URL) {
        let outputs = try fastqOutputs(in: directory)
        guard let r1 = outputs.first(where: { $0.lastPathComponent.hasSuffix("_val_1.fq.gz") }),
              let r2 = outputs.first(where: { $0.lastPathComponent.hasSuffix("_val_2.fq.gz") }) else {
            throw FASTQIngestionError.clumpifyFailed("trim_galore did not produce paired clumped FASTQs")
        }
        return (r1, r2)
    }

    private static func fastqOutputs(in directory: URL) throws -> [URL] {
        try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ).filter { url in
            let name = url.lastPathComponent.lowercased()
            return name.hasSuffix(".fq.gz") || name.hasSuffix(".fastq.gz")
        }
    }

    private static func isGzipCompressed(_ url: URL) -> Bool {
        let name = url.lastPathComponent.lowercased()
        return name.hasSuffix(".gz") || name.hasSuffix(".gzip") || name.hasSuffix(".bgz")
    }

    /// Derives a clean base name from a FASTQ filename.
    ///
    /// Strips common suffixes: `.fastq`, `.fq`, `.gz`, `_R1`, `_R2`, `_1`, `_2`
    public static func deriveBaseName(from url: URL) -> String {
        var name = url.lastPathComponent

        // Strip extensions
        let extensions = [".gz", ".fastq", ".fq", ".fastq.gz", ".fq.gz"]
        for ext in extensions.sorted(by: { $0.count > $1.count }) {
            if name.hasSuffix(ext) {
                name = String(name.dropLast(ext.count))
                break
            }
        }

        // Strip paired-end suffixes
        let suffixes = ["_R1", "_R2", "_1", "_2", "_r1", "_r2"]
        for suffix in suffixes {
            if name.hasSuffix(suffix) {
                name = String(name.dropLast(suffix.count))
                break
            }
        }

        return name
    }
}
