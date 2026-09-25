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
    /// Named after Illumina's NovaSeq/NovaSeqX binning scheme, but the actual
    /// `clumpify.sh quantize=0,8,13,22,27,32,37` boundaries used below produce
    /// 7 distinct quality levels, not 4 (SCI-08). The raw value is kept as
    /// "illumina4" for backward compatibility with persisted provenance and
    /// CLI invocations; do not rename the case without a decode migration.
    case illumina4
    /// `clumpify.sh quantize=2` groups quality scores in steps of 2, which on
    /// a typical 0-40 Phred range yields roughly 21 levels, not 8 (SCI-08).
    /// The raw value is kept as "eightLevel" for backward compatibility.
    case eightLevel
    /// No binning — preserve original quality scores exactly. This is the
    /// default everywhere as of D1 (2026-09-23): binning is opt-in only, at
    /// import time, never applied silently to downloads or derived outputs.
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
        // D1 (2026-09-23): quality binning is off by default everywhere.
        // It is opt-in at import only, named correctly and recorded in
        // provenance; it must never be applied silently to downloads or
        // derived operation outputs (WFL-01, SCI-08).
        qualityBinning: QualityBinningScheme = .none,
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
    case qualityBinningFailed(String)
    case pairedOutputVerificationFailed(String)
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
        case .qualityBinningFailed(let msg):
            return "Quality binning failed: \(msg)"
        case .pairedOutputVerificationFailed(let msg):
            return "Paired import integrity check failed: \(msg). Nothing was imported."
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
/// When clumping is off, paired input is still normalized to one interleaved
/// file: `reformat.sh quantize=` when quality binning is requested, otherwise
/// the tool-free ``FASTQPairInterleaver`` piped through bgzip/pigz. Every
/// paired path except Trim Galore is verified to hold R1 + R2 records.
///
/// Original files are deleted only after successful, verified processing.
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
        // True when step 1 already wrote the final gzip at `outputFile`, so
        // step 2 must not compress (or pass through) an input file instead.
        var stepOneWroteFinalOutput = false
        // Paired inputs must come out as one interleaved file holding every
        // R1 and R2 record. Every paired path except Trim Galore (which
        // filters reads) is verified against the input counts before any
        // original is deleted.
        var verifyPairedRecordCount = false
        var processingRecord: FASTQProcessingRecord?
        var provenanceSteps: [StepExecution] = []

        switch clumpingResolution.resolved {
        case .none:
            if config.qualityBinning != .none {
                // Binning without clumping: reformat.sh applies the same
                // quantize rules clumpify.sh would, without the k-mer sort.
                logger.info("Clumpify skipped; binning quality scores with reformat.sh")
                progress(0.0, "Binning quality scores...")
                let record = try await reformatQuantize(
                    config: config,
                    outputFile: outputFile,
                    progress: { fraction, msg in
                        progress(fraction * 0.5, msg)
                    }
                )
                clumpifiedFile = record.url
                processingRecord = record
                provenanceSteps.append(contentsOf: record.steps)
                stepOneWroteFinalOutput = true
                verifyPairedRecordCount = config.pairingMode == .pairedEnd
            } else if config.pairingMode == .pairedEnd {
                // No tool touches the reads: interleave R1/R2 in Swift straight
                // into the compressor. Before this branch existed the pipeline
                // kept only R1 here and the staged R2 was deleted as an
                // "original" (2026-09-24 data-loss fix).
                logger.info("Clumpify skipped; interleaving paired reads")
                progress(0.0, "Interleaving paired reads...")
                let record = try await interleaveAndCompress(
                    config: config,
                    outputFile: outputFile,
                    progress: { fraction, msg in
                        progress(fraction * 0.5, msg)
                    }
                )
                clumpifiedFile = record.url
                processingRecord = record
                provenanceSteps.append(contentsOf: record.steps)
                stepOneWroteFinalOutput = true
            } else {
                logger.info("Clumpify skipped (disabled in preferences)")
                clumpifiedFile = config.inputFiles[0]
                progress(0.5, "Clumpify disabled, skipping...")
            }
            wasClumpified = false
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
                verifyPairedRecordCount = config.pairingMode == .pairedEnd
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

        if verifyPairedRecordCount {
            progress(0.5, "Verifying paired read counts...")
            try await Self.verifyInterleavedRecordCount(
                output: clumpifiedFile,
                r1: config.inputFiles[0],
                r2: config.inputFiles[1]
            )
        }

        // Step 2: Compress with pigz/bgzip (35% of progress)
        progress(0.5, "Compressing...")
        let compressedFile: URL

        if wasClumpified || stepOneWroteFinalOutput {
            // Step 1 already wrote gzip output (clumpify.sh, reformat.sh, or
            // the Swift interleaver piped through bgzip/pigz).
            compressedFile = clumpifiedFile
            progress(0.85, "Compression complete")
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

        let finalAttrs = try? FileManager.default.attributesOfItem(atPath: compressedFile.path)
        let finalSize = (finalAttrs?[.size] as? Int64) ?? 0

        // Delete originals only once the output exists and every applicable
        // integrity check above has passed; a missing or empty output keeps
        // the inputs so nothing is lost.
        if config.deleteOriginals {
            guard finalSize > 0 else {
                throw FASTQIngestionError.compressionFailed(
                    "ingestion produced no output at \(compressedFile.lastPathComponent); originals were kept"
                )
            }
            for original in config.inputFiles {
                if original.standardizedFileURL != compressedFile.standardizedFileURL {
                    try? FileManager.default.removeItem(at: original)
                    logger.info("Deleted original: \(original.lastPathComponent)")
                }
            }
        }

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

    /// How the storage clumpify run treats one input file's records.
    ///
    /// BBTools guesses the layout of a single file from its first read names
    /// when no `interleaved=` flag is given, and both guesses go wrong on real
    /// imports (verified against the managed BBTools 2026-09-25):
    ///
    /// - Mates that share one identical name (SRA dumps such as
    ///   `@SRR12486983.1 SRR12486983.1` twice, or bare `@frag1` twice) are not
    ///   recognised, so clumpify sorts every read on its own and splits
    ///   nearly every pair.
    /// - `/1` `/2` or Casava names are recognised, and clumpify then pairs
    ///   records by position; a file with an odd record count (a mixed file
    ///   of pairs plus merged reads, for example) silently loses its last
    ///   read.
    ///
    /// So the layout is always stated, and it is decided from the records by
    /// name (``FASTQPairInterleaver/countMixed(interleaved:)``) rather than
    /// from the recorded pairing mode, which a recipe or an explicit choice
    /// may set without the records alternating.
    enum SingleFileClumpPlan: Equatable, Sendable {
        /// No record has its mate next to it: `interleaved=f`.
        case unpaired
        /// Every record is followed by its mate: `interleaved=t`.
        case interleaved
        /// Adjacent pairs mixed with unpaired reads: the pairs run with
        /// `interleaved=t` and the unpaired reads with `interleaved=f`.
        case splitMixed
    }

    static func singleFileClumpPlan(for counts: FASTQPairInterleaver.MixedCounts) -> SingleFileClumpPlan {
        if counts.pairs == 0 { return .unpaired }
        if counts.unpaired == 0 { return .interleaved }
        return .splitMixed
    }

    /// The argv for one storage `clumpify.sh` run.
    ///
    /// `interleaved=` is always stated (see ``SingleFileClumpPlan``). A second
    /// input is an R2 file, which always means `interleaved=t` output.
    static func clumpifyArguments(
        input: URL,
        input2: URL? = nil,
        output: URL,
        interleaved: Bool,
        heapGB: Int,
        threads: Int,
        qualityBinning: QualityBinningScheme
    ) -> [String] {
        var args = [
            "in=\(input.path)",
            "out=\(output.path)",
            "-Xmx\(heapGB)g",
            "ow=t",
            "reorder",
            "groups=auto",
            "pigz=t",
            "zl=4",
            "threads=\(max(1, threads))"
        ]
        if let input2 {
            args.append("in2=\(input2.path)")
        }
        args.append(input2 != nil || interleaved ? "interleaved=t" : "interleaved=f")
        if let quantize = quantizeArgument(for: qualityBinning) {
            args.append(quantize)
        }
        return args
    }

    /// Sorts reads by k-mer similarity using managed BBTools `clumpify.sh`.
    ///
    /// This writes directly to a gzip output so we can avoid an extra
    /// compression pass while keeping compatibility with `samtools fqidx`.
    /// A single input file is scanned first so mates stay adjacent and no
    /// record is lost (``SingleFileClumpPlan``); the output record count is
    /// then checked against the input before anything is deleted.
    private func clumpify(
        config: FASTQIngestionConfig,
        outputFile: URL,
        progress: @escaping @Sendable (Double, String) -> Void
    ) async throws -> FASTQProcessingRecord {
        let inputFile = config.inputFiles[0]
        let inputFile2 = config.pairingMode == .pairedEnd ? config.inputFiles[1] : nil
        let timeoutSeconds = max(900, Double((try? FileManager.default.attributesOfItem(atPath: inputFile.path)[.size] as? Int64) ?? 0) / 2_500_000)

        var env = CoreToolLocator.bbToolsEnvironment(
            homeDirectory: FileManager.default.homeDirectoryForCurrentUser,
            existingPath: ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
        )

        // Paths go to the tool unmodified: `NativeToolRunner.run` stages any
        // whitespace-bearing argument for every BBTools script in one place,
        // so this site does not carry its own symlink handling.
        let fm = FileManager.default

        // Heap sizing lives in ManagedJavaHeapPolicy so an import never plans
        // to use memory a concurrently running classifier already holds.
        let heapGB = ManagedJavaHeapPolicy.heapGB(minimumGB: 4)

        // Override any JAVA_TOOL_OPTIONS that might constrain heap below our calculated value.
        // BBTools reads -Xmx from its own args, but _JAVA_OPTIONS takes highest priority.
        env["_JAVA_OPTIONS"] = "-Xmx\(heapGB)g"

        func arguments(_ input: URL, _ output: URL, interleaved: Bool, input2: URL? = nil) -> [String] {
            Self.clumpifyArguments(
                input: input,
                input2: input2,
                output: output,
                interleaved: interleaved,
                heapGB: heapGB,
                threads: config.threads,
                qualityBinning: config.qualityBinning
            )
        }

        if let inputFile2 {
            progress(0.05, "Launching bbtools clumpify.sh...")
            let step = try await runStorageClumpify(
                arguments: arguments(inputFile, outputFile, interleaved: true, input2: inputFile2),
                inputs: [inputFile, inputFile2],
                output: outputFile,
                config: config,
                environment: env,
                timeout: timeoutSeconds
            )
            return try await clumpifyRecord(outputFile: outputFile, steps: [step], config: config, progress: progress)
        }

        progress(0.02, "Checking which reads are mates...")
        let counts = try await Task.detached(priority: .utility) {
            try FASTQPairInterleaver.countMixed(interleaved: inputFile)
        }.value
        let expectedRecords = counts.pairs * 2 + counts.unpaired
        let plan = Self.singleFileClumpPlan(for: counts)
        logger.info("Clumpify plan \(String(describing: plan)): \(counts.pairs) mate pairs, \(counts.unpaired) unpaired reads")

        var steps: [StepExecution] = []
        switch plan {
        case .unpaired, .interleaved:
            progress(0.05, "Launching bbtools clumpify.sh...")
            steps.append(try await runStorageClumpify(
                arguments: arguments(inputFile, outputFile, interleaved: plan == .interleaved),
                inputs: [inputFile],
                output: outputFile,
                config: config,
                environment: env,
                timeout: timeoutSeconds
            ))
        case .splitMixed:
            // Partition by name so each half gets the right flag, clump each,
            // then compress the concatenation as one stream.
            let scratch = config.outputDirectory.appendingPathComponent(
                ".clumpify-split-\(UUID().uuidString)",
                isDirectory: true
            )
            try fm.createDirectory(at: scratch, withIntermediateDirectories: true)
            defer { try? fm.removeItem(at: scratch) }
            let pairsURL = scratch.appendingPathComponent("pairs.fastq")
            let unpairedURL = scratch.appendingPathComponent("unpaired.fastq")
            progress(0.04, "Separating mate pairs from unpaired reads...")
            try await Task.detached(priority: .utility) {
                FileManager.default.createFile(atPath: pairsURL.path, contents: nil)
                FileManager.default.createFile(atPath: unpairedURL.path, contents: nil)
                let pairsHandle = try FileHandle(forWritingTo: pairsURL)
                defer { try? pairsHandle.close() }
                let unpairedHandle = try FileHandle(forWritingTo: unpairedURL)
                defer { try? unpairedHandle.close() }
                let split = try FASTQPairInterleaver.partitionMixed(
                    interleaved: inputFile,
                    pairs: pairsHandle,
                    unpaired: unpairedHandle
                )
                guard split == counts else {
                    throw FASTQIngestionError.clumpifyFailed(
                        "the pair scan found \(counts.pairs) pairs and \(counts.unpaired) unpaired reads, but the split wrote \(split.pairs) and \(split.unpaired)"
                    )
                }
            }.value

            let clumpedPairs = scratch.appendingPathComponent("pairs.clumped.fastq")
            let clumpedUnpaired = scratch.appendingPathComponent("unpaired.clumped.fastq")
            progress(0.1, "Launching bbtools clumpify.sh on mate pairs...")
            steps.append(try await runStorageClumpify(
                arguments: arguments(pairsURL, clumpedPairs, interleaved: true),
                inputs: [pairsURL],
                output: clumpedPairs,
                config: config,
                environment: env,
                timeout: timeoutSeconds
            ))
            progress(0.5, "Launching bbtools clumpify.sh on unpaired reads...")
            steps.append(try await runStorageClumpify(
                arguments: arguments(unpairedURL, clumpedUnpaired, interleaved: false),
                inputs: [unpairedURL],
                output: clumpedUnpaired,
                config: config,
                environment: env,
                timeout: timeoutSeconds
            ))
            let combined = scratch.appendingPathComponent("combined.fastq")
            try Self.concatenate([clumpedPairs, clumpedUnpaired], to: combined)
            let compressed = try await compress(
                inputFile: combined,
                outputFile: outputFile,
                threads: config.threads,
                progress: { fraction, msg in progress(0.8 + fraction * 0.2, msg) }
            )
            steps.append(contentsOf: compressed.steps)
        }

        progress(0.95, "Verifying read count...")
        let outputRecords = try await Task.detached(priority: .utility) {
            try FASTQPairInterleaver.countRecords(in: outputFile)
        }.value
        guard outputRecords == expectedRecords else {
            try? fm.removeItem(at: outputFile)
            throw FASTQIngestionError.clumpifyFailed(
                "expected \(expectedRecords) reads after clumpify.sh but \(outputFile.lastPathComponent) holds \(outputRecords); originals were kept"
            )
        }
        return try await clumpifyRecord(outputFile: outputFile, steps: steps, config: config, progress: progress)
    }

    /// Runs one storage `clumpify.sh` invocation and returns its provenance step.
    private func runStorageClumpify(
        arguments args: [String],
        inputs: [URL],
        output: URL,
        config: FASTQIngestionConfig,
        environment env: [String: String],
        timeout: Double
    ) async throws -> StepExecution {
        let clumpifyScript = try await runner.toolPath(for: .clumpify)
        let stepStartedAt = Date()
        let result = try await runner.run(
            .clumpify,
            arguments: args,
            workingDirectory: config.outputDirectory,
            environment: env,
            timeout: timeout
        )
        let stepCompletedAt = Date()

        guard result.isSuccess else {
            let stderr = result.stderr.isEmpty ? result.stdout : result.stderr
            throw FASTQIngestionError.clumpifyFailed(
                String(stderr.suffix(2_000)).trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }
        guard FileManager.default.fileExists(atPath: output.path) else {
            throw FASTQIngestionError.clumpifyFailed("clumpify.sh completed without producing output")
        }

        let toolVersion = await runner.getToolVersion(.clumpify) ?? Self.pinnedManagedToolVersion(named: "bbtools")
        return StepExecution(
            toolName: "clumpify.sh",
            toolVersion: toolVersion ?? "unknown",
            command: [clumpifyScript.path] + args,
            inputs: inputs.map {
                ProvenanceRecorder.fileRecord(url: $0, format: .fastq, role: .input)
            },
            outputs: [ProvenanceRecorder.fileRecord(url: output, format: .fastq, role: .output)],
            exitCode: result.exitCode,
            wallTime: stepCompletedAt.timeIntervalSince(stepStartedAt),
            stderr: result.stderr.isEmpty ? nil : result.stderr,
            startTime: stepStartedAt,
            endTime: stepCompletedAt
        )
    }

    private func clumpifyRecord(
        outputFile: URL,
        steps: [StepExecution],
        config: FASTQIngestionConfig,
        progress: @escaping @Sendable (Double, String) -> Void
    ) async throws -> FASTQProcessingRecord {
        progress(1.0, "clumpify.sh complete")
        logger.info("Clumpified reads with bbtools (\(config.qualityBinning.rawValue) binning)")
        let toolVersion = await runner.getToolVersion(.clumpify) ?? Self.pinnedManagedToolVersion(named: "bbtools")
        let commandLine = steps
            .filter { $0.toolName == "clumpify.sh" }
            .map { "clumpify.sh " + $0.command.dropFirst().joined(separator: " ") }
            .joined(separator: " && ")
        return FASTQProcessingRecord(
            url: outputFile,
            tool: "clumpify.sh",
            toolVersion: toolVersion,
            commandLine: commandLine,
            steps: steps
        )
    }

    /// Byte-for-byte concatenation of plain FASTQ files.
    private static func concatenate(_ inputs: [URL], to output: URL) throws {
        FileManager.default.createFile(atPath: output.path, contents: nil)
        let sink = try FileHandle(forWritingTo: output)
        defer { try? sink.close() }
        for input in inputs {
            let source = try FileHandle(forReadingFrom: input)
            defer { try? source.close() }
            while let chunk = try source.read(upToCount: 4 << 20), !chunk.isEmpty {
                try sink.write(contentsOf: chunk)
            }
        }
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

        // An interleaved single file runs in Trim Galore's single-end mode
        // otherwise, which clumps and filters each mate on its own and splits
        // the pairs. Split it into R1/R2 first and run --paired; the paired
        // outputs are interleaved again below.
        var trimInputs = config.inputFiles
        var trimPairing = config.pairingMode
        if config.pairingMode == .interleaved, config.inputFiles.count == 1 {
            let interleavedInput = config.inputFiles[0]
            let counts = try await Task.detached(priority: .utility) {
                try FASTQPairInterleaver.countMixed(interleaved: interleavedInput)
            }.value
            switch Self.singleFileClumpPlan(for: counts) {
            case .unpaired:
                trimPairing = .singleEnd
            case .interleaved:
                let splitDirectory = trimOutputDirectory.appendingPathComponent("input", isDirectory: true)
                try fm.createDirectory(at: splitDirectory, withIntermediateDirectories: true)
                let stem = Self.deriveBaseName(from: interleavedInput)
                let r1 = splitDirectory.appendingPathComponent("\(stem)_R1.fastq")
                let r2 = splitDirectory.appendingPathComponent("\(stem)_R2.fastq")
                try await Task.detached(priority: .utility) {
                    FileManager.default.createFile(atPath: r1.path, contents: nil)
                    FileManager.default.createFile(atPath: r2.path, contents: nil)
                    let r1Handle = try FileHandle(forWritingTo: r1)
                    defer { try? r1Handle.close() }
                    let r2Handle = try FileHandle(forWritingTo: r2)
                    defer { try? r2Handle.close() }
                    _ = try FASTQPairInterleaver.deinterleave(interleaved: interleavedInput, r1: r1Handle, r2: r2Handle)
                }.value
                trimInputs = [r1, r2]
                trimPairing = .pairedEnd
            case .splitMixed:
                throw FASTQIngestionError.clumpifyFailed(
                    "Trim Galore cannot keep mates together in a file that mixes \(counts.pairs) read pairs with \(counts.unpaired) unpaired reads. Choose BBTools clumpify or skip storage optimization for this file."
                )
            }
        }

        let args = Self.trimGaloreClumpifyArguments(
            inputFiles: trimInputs,
            outputDirectory: trimOutputDirectory,
            pairingMode: trimPairing,
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

        if trimPairing == .pairedEnd {
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
        // Trim Galore --clumpify writes plain FASTQ for plain input (its
        // --gzip is ignored in that mode), so compress it instead of moving.
        var compressionSteps: [StepExecution] = []
        var compressionCommand = ""
        if Self.isGzipCompressed(trimmedOutput) {
            try fm.moveItem(at: trimmedOutput, to: outputFile)
        } else {
            let compressed = try await compress(
                inputFile: trimmedOutput,
                outputFile: outputFile,
                threads: config.threads,
                progress: { fraction, msg in progress(0.75 + fraction * 0.25, msg) }
            )
            compressionSteps = compressed.steps
            compressionCommand = " && " + compressed.commandLine
        }

        guard fm.fileExists(atPath: outputFile.path) else {
            throw FASTQIngestionError.clumpifyFailed("trim_galore completed without producing output")
        }

        progress(1.0, "Trim Galore complete")
        return FASTQProcessingRecord(
            url: outputFile,
            tool: "trim_galore",
            toolVersion: toolVersion,
            commandLine: "trim_galore \(args.joined(separator: " "))" + compressionCommand,
            steps: [trimStep] + compressionSteps
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
        let result = try await runner.run(
            .reformat,
            arguments: args,
            workingDirectory: config.outputDirectory,
            timeout: timeoutSeconds
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




    /// Interleaves R1/R2 in Swift and pipes the stream through bgzip or pigz.
    ///
    /// This is the tool-free path for a paired import without storage
    /// optimization or quality binning. `FASTQPairInterleaver` refuses
    /// mismatched mate counts and checks its own written count, so the
    /// output either holds every R1 and R2 record or does not exist.
    private func interleaveAndCompress(
        config: FASTQIngestionConfig,
        outputFile: URL,
        progress: @escaping @Sendable (Double, String) -> Void
    ) async throws -> FASTQProcessingRecord {
        let r1 = config.inputFiles[0]
        let r2 = config.inputFiles[1]
        let tool: NativeTool
        let args: [String]
        if (try? await runner.toolPath(for: .bgzip)) != nil {
            tool = .bgzip
            args = ["-@", String(max(1, config.threads)), "-c"]
        } else if (try? await runner.toolPath(for: .pigz)) != nil {
            tool = .pigz
            args = ["-p", String(max(1, config.threads)), "-c"]
        } else {
            throw FASTQIngestionError.toolNotFound("pigz or bgzip")
        }
        let executableURL = try await runner.findTool(tool)
        let fm = FileManager.default
        let temporaryOutput = outputFile.deletingLastPathComponent().appendingPathComponent(
            ".\(outputFile.lastPathComponent).interleave-\(UUID().uuidString).tmp"
        )
        let stderrFile = temporaryOutput.appendingPathExtension("stderr")

        progress(0.05, "Interleaving paired reads into \(tool.executableName)...")
        let stepStartedAt = Date()

        // The interleaver is synchronous and blocks on pipe writes, so it runs
        // on a detached task; cancellation reaches it through the worker task,
        // whose `Task.checkCancellation` the record loop polls.
        let worker = Task.detached(priority: .utility) {
            () throws -> (counts: FASTQPairInterleaver.Counts, exitCode: Int32) in
            let fm = FileManager.default
            fm.createFile(atPath: temporaryOutput.path, contents: nil)
            fm.createFile(atPath: stderrFile.path, contents: nil)
            guard let outputHandle = FileHandle(forWritingAtPath: temporaryOutput.path),
                  let stderrHandle = FileHandle(forWritingAtPath: stderrFile.path) else {
                throw FASTQIngestionError.compressionFailed("cannot open \(temporaryOutput.lastPathComponent) for writing")
            }
            defer {
                try? outputHandle.close()
                try? stderrHandle.close()
            }
            let process = Process()
            process.executableURL = executableURL
            process.arguments = args
            let stdin = Pipe()
            process.standardInput = stdin
            process.standardOutput = outputHandle
            process.standardError = stderrHandle
            try process.run()

            let writer = stdin.fileHandleForWriting
            let counts: FASTQPairInterleaver.Counts
            do {
                counts = try FASTQPairInterleaver.interleave(r1: r1, r2: r2, to: writer)
                try writer.close()
            } catch {
                try? writer.close()
                if process.isRunning { process.terminate() }
                process.waitUntilExit()
                throw error
            }
            process.waitUntilExit()
            return (counts, process.terminationStatus)
        }
        let outcome: (counts: FASTQPairInterleaver.Counts, exitCode: Int32)
        do {
            outcome = try await withTaskCancellationHandler {
                try await worker.value
            } onCancel: {
                worker.cancel()
            }
        } catch {
            try? fm.removeItem(at: temporaryOutput)
            try? fm.removeItem(at: stderrFile)
            throw error
        }

        let stderr = (try? String(contentsOf: stderrFile, encoding: .utf8)) ?? ""
        try? fm.removeItem(at: stderrFile)
        guard outcome.exitCode == 0 else {
            try? fm.removeItem(at: temporaryOutput)
            throw FASTQIngestionError.compressionFailed(
                "\(tool.executableName) exited with status \(outcome.exitCode): "
                    + String(stderr.suffix(500)).trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }
        try? fm.removeItem(at: outputFile)
        try fm.moveItem(at: temporaryOutput, to: outputFile)
        let stepCompletedAt = Date()

        progress(1.0, "Interleaved \(outcome.counts.writtenRecords) reads")
        logger.info(
            "Interleaved \(outcome.counts.r1Records) pairs into \(outputFile.lastPathComponent) with \(tool.executableName)"
        )

        let toolVersion = await runner.getToolVersion(tool) ?? Self.pinnedVersion(for: tool)
        let interleaveCommand = ["LungfishWorkflow", "interleave-pairs", r1.path, r2.path]
        let step = StepExecution(
            toolName: tool.executableName,
            toolVersion: toolVersion ?? "unknown",
            command: interleaveCommand + ["|", executableURL.path] + args + [">", outputFile.path],
            inputs: [
                ProvenanceRecorder.fileRecord(url: r1, format: .fastq, role: .input),
                ProvenanceRecorder.fileRecord(url: r2, format: .fastq, role: .input),
            ],
            outputs: [ProvenanceRecorder.fileRecord(url: outputFile, format: .fastq, role: .output)],
            exitCode: outcome.exitCode,
            wallTime: stepCompletedAt.timeIntervalSince(stepStartedAt),
            stderr: stderr.isEmpty ? nil : stderr,
            startTime: stepStartedAt,
            endTime: stepCompletedAt
        )
        return FASTQProcessingRecord(
            url: outputFile,
            tool: tool.executableName,
            toolVersion: toolVersion,
            commandLine: "lungfish interleave-pairs \(r1.path) \(r2.path) | \(tool.executableName) \(args.joined(separator: " ")) > \(outputFile.path)",
            steps: [step]
        )
    }

    /// Returns the extension reformat.sh needs when a FASTQ's name and its
    /// compression disagree (a `.gz` name on plain text, or gzip data under a
    /// plain name), and `nil` when the extension already tells the truth.
    static func reformatInputExtensionOverride(for url: URL) -> String? {
        let namedGzip = url.pathExtension.lowercased() == "gz"
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        let magic = (try? handle.read(upToCount: 2)) ?? Data()
        let isGzip = magic.count == 2 && magic[magic.startIndex] == 0x1f && magic[magic.startIndex + 1] == 0x8b
        switch (namedGzip, isGzip) {
        case (true, false): return ".fq"
        case (false, true): return ".fq.gz"
        default: return nil
        }
    }

    /// Bins quality scores with BBTools `reformat.sh` when clumping is off.
    ///
    /// Uses the same `quantize=` values `clumpify.sh` takes, so a binned
    /// import looks the same whether or not it was clumped. Paired input is
    /// written as one interleaved file, as every other paired path does.
    private func reformatQuantize(
        config: FASTQIngestionConfig,
        outputFile: URL,
        progress: @escaping @Sendable (Double, String) -> Void
    ) async throws -> FASTQProcessingRecord {
        guard let quantize = Self.quantizeArgument(for: config.qualityBinning) else {
            preconditionFailure("reformatQuantize requires a binning scheme")
        }
        let reformat = try await runner.toolPath(for: .reformat)
        // reformat.sh chooses its decompressor from the file name, and its
        // extin= override does not change that. A plain FASTQ carrying a .gz
        // name (or gzip data under a plain name) fails as "Not a gzip file",
        // so read such a file through a correctly named link instead.
        var stagedLinks: [URL] = []
        defer { for link in stagedLinks { try? FileManager.default.removeItem(at: link) } }
        func readableName(_ url: URL) throws -> URL {
            guard let ext = Self.reformatInputExtensionOverride(for: url) else { return url }
            let link = config.outputDirectory.appendingPathComponent(
                ".reformat-input-\(UUID().uuidString)\(ext)"
            )
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: url)
            stagedLinks.append(link)
            return link
        }
        let inputFile = try readableName(config.inputFiles[0])
        let inputFile2 = config.pairingMode == .pairedEnd ? try readableName(config.inputFiles[1]) : nil

        var args = ["in=\(inputFile.path)"]
        if let inputFile2 {
            args.append("in2=\(inputFile2.path)")
        }
        args += [
            "out=\(outputFile.path)",
            "ow=t",
            "pigz=t",
            "zl=\(config.compressionLevel.zlValue)",
            "threads=\(max(1, config.threads))",
        ]
        // Two files are interleaved into one output. One file is quantized
        // record by record in its own order, so mates stay where they are;
        // interleaved=f stops reformat.sh from pairing /1 /2 names by
        // position, which silently drops the last read of an odd-count file.
        args.append(inputFile2 != nil ? "interleaved=t" : "interleaved=f")
        args.append(quantize)

        let timeoutSeconds = max(900, Double(Self.estimatedUncompressedInputBytes(for: config.inputFiles)) / 2_500_000)
        progress(0.05, "Launching bbtools reformat.sh...")

        let stepStartedAt = Date()
        let result = try await runner.run(
            .reformat,
            arguments: args,
            workingDirectory: config.outputDirectory,
            timeout: timeoutSeconds
        )
        let stepCompletedAt = Date()

        guard result.isSuccess else {
            try? FileManager.default.removeItem(at: outputFile)
            throw FASTQIngestionError.qualityBinningFailed(
                String((result.stderr.isEmpty ? result.stdout : result.stderr).suffix(2_000))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }
        guard FileManager.default.fileExists(atPath: outputFile.path) else {
            throw FASTQIngestionError.qualityBinningFailed("reformat.sh completed without producing output")
        }

        progress(1.0, "reformat.sh complete")
        logger.info("Binned quality scores with reformat.sh (\(config.qualityBinning.rawValue))")

        let toolVersion = await runner.getToolVersion(.reformat) ?? Self.pinnedManagedToolVersion(named: "bbtools")
        let step = StepExecution(
            toolName: "reformat.sh",
            toolVersion: toolVersion ?? "unknown",
            command: [reformat.path] + args,
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
            tool: "reformat.sh",
            toolVersion: toolVersion,
            commandLine: "reformat.sh \(args.joined(separator: " "))",
            steps: [step]
        )
    }

    /// The `quantize=` argument clumpify.sh and reformat.sh share for a scheme.
    static func quantizeArgument(for scheme: QualityBinningScheme) -> String? {
        switch scheme {
        case .illumina4:
            return "quantize=0,8,13,22,27,32,37"
        case .eightLevel:
            return "quantize=2"
        case .none:
            return nil
        }
    }

    /// Confirms an interleaved output holds exactly R1 + R2 records.
    ///
    /// Counting streams each file once through `/usr/bin/gzip -dc`, so the
    /// check costs one extra read of the inputs and output; that is the
    /// price of never deleting a pair whose mate went missing.
    static func verifyInterleavedRecordCount(output: URL, r1: URL, r2: URL) async throws {
        let counts = try await Task.detached(priority: .utility) { () throws -> (r1: Int, r2: Int, output: Int) in
            let r1Count = try FASTQPairInterleaver.countRecords(in: r1)
            try Task.checkCancellation()
            let r2Count = try FASTQPairInterleaver.countRecords(in: r2)
            try Task.checkCancellation()
            let outputCount = try FASTQPairInterleaver.countRecords(in: output)
            return (r1Count, r2Count, outputCount)
        }.value
        guard counts.r1 == counts.r2 else {
            throw FASTQIngestionError.pairedOutputVerificationFailed(
                "\(r1.lastPathComponent) has \(counts.r1) reads but \(r2.lastPathComponent) has \(counts.r2)"
            )
        }
        guard counts.output == counts.r1 + counts.r2 else {
            throw FASTQIngestionError.pairedOutputVerificationFailed(
                "expected \(counts.r1 + counts.r2) interleaved reads (R1 + R2) but \(output.lastPathComponent) holds \(counts.output)"
            )
        }
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
        let outputs = try fastqOutputs(in: directory).filter { url in
            ["_trimmed.fq.gz", "_trimmed.fastq.gz", "_trimmed.fq", "_trimmed.fastq"]
                .contains { url.lastPathComponent.hasSuffix($0) }
        }
        guard let output = outputs.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }).first else {
            throw FASTQIngestionError.clumpifyFailed("trim_galore did not produce a single-end clumped FASTQ")
        }
        return output
    }

    private static func trimGalorePairedOutputs(in directory: URL) throws -> (r1: URL, r2: URL) {
        let outputs = try fastqOutputs(in: directory)
        // Plain input gives plain `_val_N.fq` under --clumpify; reformat.sh
        // reads either when it interleaves them.
        func mate(_ number: Int) -> URL? {
            outputs.first { url in
                ["_val_\(number).fq.gz", "_val_\(number).fq"].contains { url.lastPathComponent.hasSuffix($0) }
            }
        }
        guard let r1 = mate(1), let r2 = mate(2) else {
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
            return [".fq.gz", ".fastq.gz", ".fq", ".fastq"].contains { name.hasSuffix($0) }
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
