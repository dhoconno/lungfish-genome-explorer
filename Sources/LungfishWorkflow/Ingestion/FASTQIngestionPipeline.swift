// FASTQIngestionPipeline.swift - Clumpify and compress FASTQ files
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import os.log

private let logger = Logger(subsystem: "com.lungfish.workflow", category: "FASTQIngestionPipeline")

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

    /// Whether to skip the clumpify step (k-mer sorting + quality binning).
    /// When true, only compression is performed.
    public let skipClumpify: Bool

    public init(
        inputFiles: [URL],
        pairingMode: PairingMode = .singleEnd,
        outputDirectory: URL,
        threads: Int = 4,
        deleteOriginals: Bool = true,
        qualityBinning: QualityBinningScheme = .illumina4,
        skipClumpify: Bool = false
    ) {
        self.inputFiles = inputFiles
        self.pairingMode = pairingMode
        self.outputDirectory = outputDirectory
        self.threads = threads
        self.deleteOriginals = deleteOriginals
        self.qualityBinning = qualityBinning
        self.skipClumpify = skipClumpify
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
    ///   - progress: Progress callback (fraction 0-1, status message)
    /// - Returns: Ingestion result with output file paths
    public func run(
        config: FASTQIngestionConfig,
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

        if config.skipClumpify {
            logger.info("Clumpify skipped (disabled in preferences)")
            clumpifiedFile = config.inputFiles[0]
            wasClumpified = false
            progress(0.5, "Clumpify disabled, skipping...")
        } else {
            progress(0.0, "Sorting reads by k-mer similarity...")
            do {
                clumpifiedFile = try await clumpify(
                    config: config,
                    outputFile: outputFile,
                    progress: { fraction, msg in
                        progress(fraction * 0.5, msg)
                    }
                )
                wasClumpified = true
            } catch {
                // Clumpify is mandatory for imported FASTQ workflows.
                throw FASTQIngestionError.clumpifyFailed(error.localizedDescription)
            }
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
            compressedFile = try await compress(
                inputFile: clumpifiedFile,
                outputFile: outputFile,
                threads: config.threads,
                progress: { fraction, msg in
                    progress(0.5 + fraction * 0.35, msg)
                }
            )
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
            pairingMode: outputPairingMode
        )
    }

    // MARK: - Pipeline Steps

    /// Sorts reads by k-mer similarity using bundled BBTools `clumpify.sh`.
    ///
    /// This writes directly to a gzip output so we can avoid an extra
    /// compression pass while keeping compatibility with `samtools fqidx`.
    private func clumpify(
        config: FASTQIngestionConfig,
        outputFile: URL,
        progress: @escaping @Sendable (Double, String) -> Void
    ) async throws -> URL {
        let inputFile = config.inputFiles[0]
        let inputFile2 = config.pairingMode == .pairedEnd ? config.inputFiles[1] : nil
        let toolsDirectory = await runner.getToolsDirectory()
        let clumpifyScript = try await runner.toolPath(for: .clumpify)
        let bundledJava = (try? await runner.toolPath(for: .java))
        let timeoutSeconds = max(900, Double((try? FileManager.default.attributesOfItem(atPath: inputFile.path)[.size] as? Int64) ?? 0) / 2_500_000)

        var env: [String: String] = [:]
        if let toolsDirectory {
            let existingPath = ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
            env["PATH"] = "\(toolsDirectory.path):\(existingPath)"
        }
        if let bundledJava {
            let javaHome = bundledJava.deletingLastPathComponent().deletingLastPathComponent()
            env["JAVA_HOME"] = javaHome.path
            env["BBMAP_JAVA"] = bundledJava.path
        }

        // BBTools internally calls pigz/gzip without quoting paths, so spaces
        // break at multiple levels (shell eval AND internal tool invocations).
        // Use symlinks for inputs and a temp name for outputs to ensure all paths
        // are space-free throughout the entire BBTools pipeline.
        let fm = FileManager.default
        var symlinksToCleanup: [URL] = []

        let safeInput = try Self.bbToolsSafePath(for: inputFile, fm: fm, cleanup: &symlinksToCleanup)
        let safeOutput = Self.bbToolsSafeOutputPath(for: outputFile, in: config.outputDirectory)

        // Allocate ~80% of physical memory to Java heap, capped at 31g (JVM compressed oops limit).
        // Minimum 4g to handle large FASTQ files (BBTools default is only 2g).
        let physicalMemoryGB = Int(ProcessInfo.processInfo.physicalMemory / (1024 * 1024 * 1024))
        let heapGB = max(4, min(31, physicalMemoryGB * 80 / 100))

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

        let result = try await runner.runProcess(
            executableURL: clumpifyScript,
            arguments: args,
            workingDirectory: config.outputDirectory,
            environment: env,
            timeout: timeoutSeconds,
            toolName: "clumpify.sh"
        )

        // Move temp output to the real path if we used a space-free name.
        if safeOutput != outputFile, fm.fileExists(atPath: safeOutput.path) {
            try? fm.removeItem(at: outputFile)
            try fm.moveItem(at: safeOutput, to: outputFile)
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

        return outputFile
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
        let safeName = url.lastPathComponent.replacingOccurrences(of: " ", with: "_")
        let linkDir = fm.temporaryDirectory.appendingPathComponent("lungfish-bbtools-\(UUID().uuidString)")
        try fm.createDirectory(at: linkDir, withIntermediateDirectories: true)
        let linkURL = linkDir.appendingPathComponent(safeName)
        try fm.createSymbolicLink(at: linkURL, withDestinationURL: url)
        cleanup.append(linkDir)
        return linkURL
    }

    /// Returns a space-free output path for BBTools.
    ///
    /// For output files, symlinks don't reliably work (tools may delete and
    /// recreate). Instead use a temp name in the same directory and rename after.
    private static func bbToolsSafeOutputPath(for url: URL, in directory: URL) -> URL {
        guard url.path.contains(" ") else { return url }
        let safeName = url.lastPathComponent.replacingOccurrences(of: " ", with: "_")
        return directory.appendingPathComponent(safeName)
    }

    /// Compresses a FASTQ file with pigz (parallel gzip) or bgzip.
    private func compress(
        inputFile: URL,
        outputFile: URL,
        threads: Int,
        progress: @escaping @Sendable (Double, String) -> Void
    ) async throws -> URL {
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

        let result = try await runner.runWithFileOutput(
            tool,
            arguments: args,
            outputFile: outputFile,
            timeout: timeoutSeconds
        )

        guard result.isSuccess else {
            throw FASTQIngestionError.compressionFailed(
                String(result.stderr.suffix(500)).trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }

        progress(1.0, "Compression complete")
        return outputFile
    }

    // MARK: - Helpers

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
