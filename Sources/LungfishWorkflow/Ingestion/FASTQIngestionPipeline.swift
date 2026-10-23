// FASTQIngestionPipeline.swift - Clumpify and compress FASTQ files
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import os.log
import LungfishCore
import LungfishIO

private let logger = Logger(subsystem: LogSubsystem.workflow, category: "FASTQIngestionPipeline")

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
    /// The Java heap clumpify ran with, in GB, nil when clumpify did not run.
    public let clumpifyHeapGB: Int?
    /// The reads Trim Galore removed while it stored the file, from its trimming reports. Nil for every other
    /// tool, which keeps every read.
    public let readsRemovedByStorage: FASTQStorageReadRemoval?

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
        readsRemovedByStorage: FASTQStorageReadRemoval? = nil,
        provenanceSteps: [StepExecution] = [],
        clumpifyHeapGB: Int? = nil
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
        self.clumpifyHeapGB = clumpifyHeapGB
        self.readsRemovedByStorage = readsRemovedByStorage
    }
}

struct FASTQProcessingRecord: Sendable {
    let url: URL
    let tool: String
    let toolVersion: String?
    let commandLine: String
    let steps: [StepExecution]
    /// The reads a Trim Galore storage run removed, nil for a tool that keeps every read.
    var readsRemovedByStorage: FASTQStorageReadRemoval? = nil
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
    /// A BBTools JVM ran out of heap. The sentence is already plain, so it is shown as it is.
    case outOfMemory(String)

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
        case .outOfMemory(let sentence):
            return sentence
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
/// paired path except Trim Galore is verified to hold R1 + R2 records, and
/// Trim Galore's output is checked against each call's trimming report.
///
/// Original files are deleted only after successful, verified processing.
public final class FASTQIngestionPipeline: @unchecked Sendable {

    let runner = NativeToolRunner.shared

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
        var clumpifyHeapGB: Int?
        let estimatedInputBytes = Self.estimatedUncompressedInputBytes(for: config.inputFiles)
        let clumpingResolution = suppliedClumpingResolution
            ?? config.clumpingTool.resolve(estimatedInputBytes: estimatedInputBytes, pinnedHeapGB: config.clumpifyHeapGB)
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
        // R1 and R2 record. Every paired path except Trim Galore is verified
        // against the input counts before any original is deleted. Trim Galore
        // filters reads, so its route checks each call against its report.
        var verifyPairedRecordCount = false
        var processingRecord: FASTQProcessingRecord?
        var provenanceSteps: [StepExecution] = []
        var readsRemovedByStorage: FASTQStorageReadRemoval?

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
            // Heap sizing lives in ManagedJavaHeapPolicy so an import never plans to use memory a
            // concurrently running classifier already holds, unless --clumpify-heap-gb pins it.
            let heapGB = config.clumpifyHeapGB ?? ManagedJavaHeapPolicy.heapGB(minimumGB: 4)
            clumpifyHeapGB = heapGB
            do {
                let record = try await clumpify(
                    config: config,
                    heapGB: heapGB,
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
                // Clumpify is mandatory for imported FASTQ workflows. The out-of-memory sentence is already plain.
                if case .outOfMemory? = error as? FASTQIngestionError { throw error }
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
                readsRemovedByStorage = record.readsRemovedByStorage
                wasClumpified = true
            } catch {
                throw (error as? FASTQIngestionError) ?? FASTQIngestionError.clumpifyFailed(error.localizedDescription)
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
            readsRemovedByStorage: readsRemovedByStorage,
            provenanceSteps: provenanceSteps,
            clumpifyHeapGB: clumpifyHeapGB
        )
    }

    // MARK: - Pipeline Steps

    /// How the storage clumpify run treats one input file's records, as
    /// ``PortableStoragePlan/SingleFileClumpPlan`` describes.
    typealias SingleFileClumpPlan = PortableStoragePlan.SingleFileClumpPlan

    /// ``PortableStoragePlan/singleFileClumpPlan(for:)``.
    static func singleFileClumpPlan(for counts: FASTQPairInterleaver.MixedCounts) -> SingleFileClumpPlan {
        PortableStoragePlan.singleFileClumpPlan(for: counts)
    }

    /// The storage argv of ``PortableStoragePlan/clumpifyArguments(input:input2:output:interleaved:heapGB:threads:qualityBinning:)``.
    static func clumpifyArguments(
        input: URL,
        input2: URL? = nil,
        output: URL,
        interleaved: Bool,
        heapGB: Int,
        threads: Int,
        qualityBinning: QualityBinningScheme
    ) -> [String] {
        PortableStoragePlan.clumpifyArguments(
            input: input, input2: input2, output: output, interleaved: interleaved, heapGB: heapGB, threads: threads,
            qualityBinning: qualityBinning
        )
    }

    /// Sorts reads by k-mer similarity using managed BBTools `clumpify.sh`, through ``PortableStorageStep``.
    ///
    /// This writes directly to a gzip output so we can avoid an extra
    /// compression pass while keeping compatibility with `samtools fqidx`.
    /// A single input file is scanned first so mates stay adjacent and no
    /// record is lost (``SingleFileClumpPlan``); the output record count is
    /// then checked against the input before anything is deleted. The Mac
    /// names the BBTools environment and the compressor, bgzip and then pigz.
    private func clumpify(
        config: FASTQIngestionConfig,
        heapGB: Int,
        outputFile: URL,
        progress: @escaping @Sendable (Double, String) -> Void
    ) async throws -> FASTQProcessingRecord {
        let environment = CoreToolLocator.bbToolsEnvironment(
            homeDirectory: FileManager.default.homeDirectoryForCurrentUser,
            existingPath: ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
        )
        let inputs = config.pairingMode == .pairedEnd
            ? [config.inputFiles[0], config.inputFiles[1]]
            : [config.inputFiles[0]]
        let run = PortableStorageStep<NativeToolStorageLauncher>.ClumpifyRun(
            inputs: inputs,
            output: outputFile,
            workingDirectory: config.outputDirectory,
            heapGB: heapGB,
            threads: config.threads,
            qualityBinning: config.qualityBinning,
            environment: environment,
            compressor: await resolveCompressor()
        )
        let step = storageStep
        let records = try await Self.mappingStorageErrors {
            try await step.clumpify(run, progress: progress)
        }
        return try await clumpifyRecord(
            outputFile: outputFile, steps: records.map(\.step), config: config, progress: progress
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
        let evidence = await versionEvidence(for: .clumpify)
        let commandLine = steps
            .filter { $0.toolName == "clumpify.sh" }
            .map { "clumpify.sh " + $0.command.dropFirst().joined(separator: " ") }
            .joined(separator: " && ")
        return FASTQProcessingRecord(
            url: outputFile,
            tool: "clumpify.sh",
            toolVersion: evidence.version,
            commandLine: commandLine,
            steps: steps
        )
    }

    func interleavePairedFASTQ(
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

        let stepClock = ProvenanceRunClock()
        let result = try await runner.run(
            .reformat,
            arguments: args,
            workingDirectory: config.outputDirectory,
            timeout: timeoutSeconds
        )
        let stepCompletedAt = stepClock.now

        guard result.isSuccess else {
            throw FASTQIngestionError.clumpifyFailed(
                String((result.stderr.isEmpty ? result.stdout : result.stderr).suffix(2_000))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }
        guard FileManager.default.fileExists(atPath: outputFile.path) else {
            throw FASTQIngestionError.clumpifyFailed("reformat.sh completed without producing interleaved output")
        }

        let evidence = await versionEvidence(for: .reformat)
        let step = StepExecution(
            toolName: "reformat.sh",
            toolVersion: evidence.recordedString,
            command: [reformat.path] + args,
            inputs: [
                ProvenanceRecorder.fileRecord(url: r1, format: .fastq, role: .input),
                ProvenanceRecorder.fileRecord(url: r2, format: .fastq, role: .input),
            ],
            outputs: [ProvenanceRecorder.fileRecord(url: outputFile, format: .fastq, role: .output)],
            exitCode: result.exitCode,
            wallTime: stepCompletedAt.timeIntervalSince(stepClock.startedAt),
            stderr: result.stderr.isEmpty ? nil : result.stderr,
            managedToolID: NativeTool.reformat.managedToolID, toolVersionEvidence: evidence,
            startTime: stepClock.startedAt,
            endTime: stepCompletedAt
        )

        progress(1.0, "Interleaving complete")
        return FASTQProcessingRecord(
            url: outputFile,
            tool: "reformat.sh",
            toolVersion: evidence.version,
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
        guard let compressor = await resolveCompressor() else {
            throw FASTQIngestionError.toolNotFound("pigz or bgzip")
        }
        let tool = NativeToolStorageLauncher.nativeTool(compressor.tool)
        let args = compressor.streamArguments(threads: max(1, config.threads))
        let executableURL = try await runner.findTool(tool)
        let fm = FileManager.default
        let temporaryOutput = outputFile.deletingLastPathComponent().appendingPathComponent(
            ".\(outputFile.lastPathComponent).interleave-\(UUID().uuidString).tmp"
        )
        let stderrFile = temporaryOutput.appendingPathExtension("stderr")

        progress(0.05, "Interleaving paired reads into \(tool.executableName)...")
        let stepClock = ProvenanceRunClock()

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
            let run = try ToolProcess.start(ToolProcessSpec(
                executableURL: executableURL, arguments: args, environment: ToolProcessSpec.inheritedEnvironment(),
                stdin: .stream, stdout: .descriptor(outputHandle.fileDescriptor),
                stderr: .descriptor(stderrHandle.fileDescriptor), label: tool.executableName
            ))
            guard run.pid != nil else {
                _ = try run.waitBlocking()  // throws the launch failure
                throw FASTQIngestionError.compressionFailed("cannot launch \(tool.executableName)")
            }
            let feed = ToolProcessStdinFeed(stdin: run.stdin)
            let counts: FASTQPairInterleaver.Counts
            do {
                counts = try FASTQPairInterleaver.interleave(r1: r1, r2: r2, to: feed.writer)
            } catch {
                run.cancel()  // stops the compressor and releases a write that waits on it
                feed.finish()
                _ = try? run.waitBlocking()
                throw error
            }
            feed.finish()
            let result = try run.waitBlocking()
            if result.status == 0, let incomplete = result.incompleteOutputReason {
                throw FASTQIngestionError.compressionFailed(incomplete)
            }
            return (counts, result.status)
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
        let stepCompletedAt = stepClock.now

        progress(1.0, "Interleaved \(outcome.counts.writtenRecords) reads")
        logger.info(
            "Interleaved \(outcome.counts.r1Records) pairs into \(outputFile.lastPathComponent) with \(tool.executableName)"
        )

        let evidence = await versionEvidence(for: tool)
        let interleaveCommand = ["LungfishWorkflow", "interleave-pairs", r1.path, r2.path]
        let step = StepExecution(
            toolName: tool.executableName,
            toolVersion: evidence.recordedString,
            command: interleaveCommand + ["|", executableURL.path] + args + [">", outputFile.path],
            inputs: [
                ProvenanceRecorder.fileRecord(url: r1, format: .fastq, role: .input),
                ProvenanceRecorder.fileRecord(url: r2, format: .fastq, role: .input),
            ],
            outputs: [ProvenanceRecorder.fileRecord(url: outputFile, format: .fastq, role: .output)],
            exitCode: outcome.exitCode,
            wallTime: stepCompletedAt.timeIntervalSince(stepClock.startedAt),
            stderr: stderr.isEmpty ? nil : stderr,
            managedToolID: tool.managedToolID, toolVersionEvidence: evidence,
            startTime: stepClock.startedAt,
            endTime: stepCompletedAt
        )
        return FASTQProcessingRecord(
            url: outputFile,
            tool: tool.executableName,
            toolVersion: evidence.version,
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

    /// The error a binning run throws when its tool lookup fails.
    ///
    /// A route that runs no clumpify bins with `reformat.sh`, so a default
    /// import fails at the lookup on a machine without the BBTools plugin. The
    /// runner's message names only the missing tool. This one names the plugin
    /// and the way to import without binning. Any other error passes through
    /// unchanged.
    static func qualityBinningToolError(_ error: Error) -> Error {
        guard let toolError = error as? NativeToolError, case .toolNotFound = toolError else { return error }
        return FASTQIngestionError.qualityBinningFailed(
            "Quality binning needs the BBTools plugin, which is not installed. "
                + "Install it from the Plugin Manager or import again with --quality-binning none."
        )
    }

    /// Bins quality scores with BBTools `reformat.sh` when clumping is off.
    ///
    /// Uses the same `quantize=` values `clumpify.sh` takes, so a binned
    /// import looks the same whether or not it was clumped. Paired input is
    /// written as one interleaved file, as every other paired path does.
    func reformatQuantize(
        config: FASTQIngestionConfig,
        outputFile: URL,
        progress: @escaping @Sendable (Double, String) -> Void
    ) async throws -> FASTQProcessingRecord {
        guard let quantize = Self.quantizeArgument(for: config.qualityBinning) else {
            preconditionFailure("reformatQuantize requires a binning scheme")
        }
        let reformat: URL
        do {
            reformat = try await runner.toolPath(for: .reformat)
        } catch {
            throw Self.qualityBinningToolError(error)
        }
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

        let stepClock = ProvenanceRunClock()
        let result = try await runner.run(
            .reformat,
            arguments: args,
            workingDirectory: config.outputDirectory,
            timeout: timeoutSeconds
        )
        let stepCompletedAt = stepClock.now

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

        let evidence = await versionEvidence(for: .reformat)
        let step = StepExecution(
            toolName: "reformat.sh",
            toolVersion: evidence.recordedString,
            command: [reformat.path] + args,
            inputs: config.inputFiles.map {
                ProvenanceRecorder.fileRecord(url: $0, format: .fastq, role: .input)
            },
            outputs: [ProvenanceRecorder.fileRecord(url: outputFile, format: .fastq, role: .output)],
            exitCode: result.exitCode,
            wallTime: stepCompletedAt.timeIntervalSince(stepClock.startedAt),
            stderr: result.stderr.isEmpty ? nil : result.stderr,
            managedToolID: NativeTool.reformat.managedToolID, toolVersionEvidence: evidence,
            startTime: stepClock.startedAt,
            endTime: stepCompletedAt
        )
        return FASTQProcessingRecord(
            url: outputFile,
            tool: "reformat.sh",
            toolVersion: evidence.version,
            commandLine: "reformat.sh \(args.joined(separator: " "))",
            steps: [step]
        )
    }

    /// ``PortableStoragePlan/quantizeArgument(for:)``.
    static func quantizeArgument(for scheme: QualityBinningScheme) -> String? {
        PortableStoragePlan.quantizeArgument(for: scheme)
    }

    /// Confirms an interleaved output holds exactly R1 + R2 records, through
    /// ``PortableStorageChecks/verifyInterleavedRecordCount(output:r1:r2:launcher:)``.
    ///
    /// Counting streams each file once through `/usr/bin/gzip -dc`, so the
    /// check costs one extra read of the inputs and output; that is the
    /// price of never deleting a pair whose mate went missing.
    static func verifyInterleavedRecordCount(output: URL, r1: URL, r2: URL) async throws {
        try await mappingStorageErrors {
            try await PortableStorageChecks.verifyInterleavedRecordCount(
                output: output, r1: r1, r2: r2, launcher: ToolProcessChildLauncher()
            )
        }
    }

    /// Compresses a FASTQ file with bgzip or pigz, by today's order, through ``PortableStorageStep``.
    func compress(
        inputFile: URL,
        outputFile: URL,
        threads: Int,
        progress: @escaping @Sendable (Double, String) -> Void
    ) async throws -> FASTQProcessingRecord {
        let compressor = await resolveCompressor()
        let step = storageStep
        let record = try await Self.mappingStorageErrors {
            try await step.compress(
                input: inputFile, output: outputFile, compressor: compressor, threads: threads, progress: progress
            )
        }
        let arguments = record.run.launch.arguments.joined(separator: " ")
        return FASTQProcessingRecord(
            url: outputFile,
            tool: record.step.toolName,
            toolVersion: record.evidence.version,
            commandLine: "\(record.step.toolName) \(arguments) > \(outputFile.path)",
            steps: [record.step]
        )
    }

    /// A probe that answers is observed. One that does not leaves the lock's pin for the tool's id,
    /// recorded as a pin and never as a measurement, or unknown when the lock holds none.
    func versionEvidence(for tool: NativeTool) async -> ToolVersionEvidence {
        Self.versionEvidence(observed: await runner.getToolVersion(tool), for: tool)
    }

    static func versionEvidence(observed: String?, for tool: NativeTool, lock: ManagedToolLock = .bundled) -> ToolVersionEvidence {
        observed.map { .observed(version: $0, reportedLine: nil) } ?? .lockPin(for: tool.managedToolID, in: lock)
    }

    // MARK: - Helpers

    /// ``PortableStoragePlan/estimatedUncompressedInputBytes(for:)``.
    public static func estimatedUncompressedInputBytes(for urls: [URL]) -> Int64 {
        PortableStoragePlan.estimatedUncompressedInputBytes(for: urls)
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

    static func trimGaloreSingleOutput(in directory: URL) throws -> URL {
        let outputs = try fastqOutputs(in: directory).filter { url in
            ["_trimmed.fq.gz", "_trimmed.fastq.gz", "_trimmed.fq", "_trimmed.fastq"]
                .contains { url.lastPathComponent.hasSuffix($0) }
        }
        guard let output = outputs.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }).first else {
            throw FASTQIngestionError.clumpifyFailed("trim_galore did not produce a single-end clumped FASTQ")
        }
        return output
    }

    static func trimGalorePairedOutputs(in directory: URL) throws -> (r1: URL, r2: URL) {
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

    /// ``PortableStoragePlan/isGzipCompressed(_:)``.
    static func isGzipCompressed(_ url: URL) -> Bool {
        PortableStoragePlan.isGzipCompressed(url)
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
