// Minimap2Pipeline.swift - Read mapping with minimap2
// Copyright (c) 2025 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishCore
import os.log

private let logger = Logger(subsystem: LogSubsystem.workflow, category: "Minimap2Pipeline")

// MARK: - Minimap2Preset

/// Minimap2 alignment presets for different sequencing platforms.
///
/// Each preset tunes minimap2's internal scoring, seeding, and chaining
/// parameters for a specific read type. Choosing the correct preset is
/// critical for alignment quality -- e.g., using `shortRead` for Nanopore
/// data will produce poor results.
///
/// ## Preset Selection Guide
///
/// | Platform / Use Case           | Preset       |
/// |-------------------------------|--------------|
/// | Illumina PE/SE (100-300 bp)   | `shortRead`  |
/// | Oxford Nanopore               | `mapONT`     |
/// | PacBio HiFi / CCS             | `mapHiFi`    |
/// | PacBio CLR                    | `mapPB`      |
/// | Assembly vs close reference   | `asm5`       |
/// | Assembly vs divergent ref     | `asm20`      |
/// | Long-read RNA-seq             | `splice`     |
/// | Short-read RNA-seq            | `spliceSR`   |
public enum Minimap2Preset: String, CaseIterable, Sendable, Codable {
    /// Illumina short reads (100-300 bp paired-end or single-end).
    case shortRead = "sr"

    /// Oxford Nanopore reads (any chemistry).
    case mapONT = "map-ont"

    /// PacBio HiFi / CCS high-accuracy reads.
    case mapHiFi = "map-hifi"

    /// PacBio CLR (continuous long reads, higher error rate).
    case mapPB = "map-pb"

    /// Assembly-to-reference alignment with less than 5% sequence divergence.
    case asm5 = "asm5"

    /// Assembly-to-reference alignment with less than 20% sequence divergence.
    case asm20 = "asm20"

    /// Splice-aware alignment for long-read RNA-seq (Nanopore cDNA / PacBio Iso-Seq).
    case splice = "splice"

    /// Splice-aware alignment for short-read RNA-seq with high-quality junction detection.
    case spliceSR = "splice:hq"

    /// Human-readable display name for UI labels.
    public var displayName: String {
        switch self {
        case .shortRead: return "Illumina Short Reads"
        case .mapONT: return "Oxford Nanopore"
        case .mapHiFi: return "PacBio HiFi/CCS"
        case .mapPB: return "PacBio CLR"
        case .asm5: return "Assembly (<5% divergence)"
        case .asm20: return "Assembly (<20% divergence)"
        case .splice: return "Long-read RNA-seq"
        case .spliceSR: return "Short-read RNA-seq"
        }
    }

    /// Detailed description for tooltips and help text.
    public var description: String {
        switch self {
        case .shortRead: return "Best for paired-end Illumina reads (100-300 bp)"
        case .mapONT: return "Optimized for Oxford Nanopore long reads"
        case .mapHiFi: return "Optimized for PacBio HiFi/CCS high-accuracy reads"
        case .mapPB: return "Optimized for PacBio CLR noisy long reads"
        case .asm5: return "Align assembled contigs to a close reference"
        case .asm20: return "Align assembled contigs to a divergent reference"
        case .splice: return "Splice-aware alignment for long-read RNA-seq"
        case .spliceSR: return "Splice-aware alignment for short-read RNA-seq"
        }
    }
}

// MARK: - Minimap2Config

/// Configuration for a minimap2 read mapping run.
///
/// Encapsulates all parameters needed to run minimap2 alignment. The
/// ``Minimap2Pipeline`` consumes this struct to build the minimap2
/// command line and orchestrate the sort/index steps.
///
/// ## Minimal Usage
///
/// ```swift
/// let config = Minimap2Config(
///     inputFiles: [fastqR1, fastqR2],
///     referenceURL: referenceFASTA,
///     preset: .shortRead,
///     outputDirectory: outputDir,
///     sampleName: "MySample"
/// )
/// ```
public struct Minimap2Config: Sendable {
    /// Input FASTQ files (1 for single-end, 2 for paired-end).
    public var inputFiles: [URL]

    /// Durable scientific input paths to record in provenance when execution uses temporary materialized files.
    public var provenanceInputFiles: [URL]?

    /// Durable checksum-bearing input records to use in provenance when they differ from user-visible input paths.
    public var provenanceInputFileRecords: [FileRecord]?

    /// Reference FASTA file to align against.
    public let referenceURL: URL

    /// Alignment preset controlling scoring and seeding parameters.
    public let preset: Minimap2Preset

    /// Number of alignment threads. Defaults to all available cores.
    public let threads: Int

    /// Whether to include secondary alignments in the output.
    public let includeSecondary: Bool

    /// Whether to include supplementary alignments (chimeric reads, useful for SV detection).
    public let includeSupplementary: Bool

    /// Minimum mapping quality to retain (0 = keep all).
    public let minMappingQuality: Int

    /// Whether input FASTQ files are paired-end.
    public let isPairedEnd: Bool

    /// Output directory for the sorted BAM and index files.
    public var outputDirectory: URL

    /// Sample name used in the @RG read group header and output file naming.
    public let sampleName: String

    /// Additional minimap2 command line arguments supplied by advanced users.
    public let advancedArguments: [String]

    /// Creates a new minimap2 configuration.
    ///
    /// - Parameters:
    ///   - inputFiles: FASTQ input files (1 for SE, 2 for PE).
    ///   - referenceURL: Reference FASTA file path.
    ///   - preset: Alignment preset for the sequencing platform.
    ///   - threads: Number of threads (default: all cores).
    ///   - includeSecondary: Emit secondary alignments (default: false).
    ///   - includeSupplementary: Emit supplementary alignments (default: true).
    ///   - minMappingQuality: Minimum MAPQ filter (default: 0, no filter).
    ///   - isPairedEnd: Whether input is paired-end (default: true).
    ///   - outputDirectory: Directory for output files.
    ///   - sampleName: Sample name for read group and filenames.
    ///   - advancedArguments: Additional minimap2 options passed through as argv tokens.
    public init(
        inputFiles: [URL],
        referenceURL: URL,
        preset: Minimap2Preset = .shortRead,
        threads: Int = ProcessInfo.processInfo.processorCount,
        includeSecondary: Bool = false,
        includeSupplementary: Bool = true,
        minMappingQuality: Int = 0,
        isPairedEnd: Bool = true,
        outputDirectory: URL,
        sampleName: String,
        advancedArguments: [String] = [],
        provenanceInputFiles: [URL]? = nil,
        provenanceInputFileRecords: [FileRecord]? = nil
    ) {
        self.inputFiles = inputFiles
        self.provenanceInputFiles = provenanceInputFiles
        self.provenanceInputFileRecords = provenanceInputFileRecords
        self.referenceURL = referenceURL
        self.preset = preset
        self.threads = threads
        self.includeSecondary = includeSecondary
        self.includeSupplementary = includeSupplementary
        self.minMappingQuality = minMappingQuality
        self.isPairedEnd = isPairedEnd
        self.outputDirectory = outputDirectory
        self.sampleName = sampleName
        self.advancedArguments = advancedArguments
    }
}

// MARK: - Minimap2Result

/// Result of a completed minimap2 mapping run.
///
/// Contains paths to the output files and summary statistics parsed
/// from ``samtools flagstat``.
public struct Minimap2Result: Sendable {
    /// Path to the coordinate-sorted BAM file.
    public let bamURL: URL

    /// Path to the BAM index (.bai) file.
    public let baiURL: URL

    /// Total reads processed (including secondary/supplementary).
    public let totalReads: Int

    /// Number of reads that mapped to the reference.
    public let mappedReads: Int

    /// Number of reads that did not map.
    public let unmappedReads: Int

    /// Wall clock time for the entire pipeline in seconds.
    public let wallClockSeconds: Double
}

// MARK: - Persistence

/// The filename used for the serialized Minimap2 alignment result sidecar.
private let alignmentResultFilename = "alignment-result.json"

extension Minimap2Result {

    /// Saves the alignment result metadata to a JSON file in the given directory.
    ///
    /// - Parameters:
    ///   - directory: The directory to write `alignment-result.json` into.
    ///   - toolVersion: The minimap2 version string to record.
    /// - Throws: Encoding or file write errors.
    public func save(to directory: URL, toolVersion: String) throws {
        let sidecar = PersistedAlignmentResult(
            schemaVersion: 1,
            bamPath: bamURL.lastPathComponent,
            baiPath: baiURL.lastPathComponent,
            totalReads: totalReads,
            mappedReads: mappedReads,
            unmappedReads: unmappedReads,
            toolVersion: toolVersion,
            wallClockSeconds: wallClockSeconds,
            savedAt: Date()
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(sidecar)

        let fileURL = directory.appendingPathComponent(alignmentResultFilename)
        try data.write(to: fileURL, options: .atomic)

        logger.info("Saved Minimap2 alignment result to \(fileURL.path)")
    }

    /// Loads a Minimap2 alignment result from a directory containing a saved sidecar.
    ///
    /// - Parameter directory: The directory containing `alignment-result.json`.
    /// - Returns: A reconstituted ``Minimap2Result``.
    /// - Throws: ``Minimap2ResultLoadError`` or decoding errors.
    public static func load(from directory: URL) throws -> Minimap2Result {
        let fileURL = directory.appendingPathComponent(alignmentResultFilename)

        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            throw Minimap2ResultLoadError.sidecarNotFound(directory)
        }

        let data = try Data(contentsOf: fileURL)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let sidecar = try decoder.decode(PersistedAlignmentResult.self, from: data)

        return Minimap2Result(
            bamURL: directory.appendingPathComponent(sidecar.bamPath),
            baiURL: directory.appendingPathComponent(sidecar.baiPath),
            totalReads: sidecar.totalReads,
            mappedReads: sidecar.mappedReads,
            unmappedReads: sidecar.unmappedReads,
            wallClockSeconds: sidecar.wallClockSeconds
        )
    }

    /// Whether a saved Minimap2 alignment result exists in the given directory.
    ///
    /// - Parameter directory: The directory to check.
    /// - Returns: `true` if `alignment-result.json` exists.
    public static func exists(in directory: URL) -> Bool {
        FileManager.default.fileExists(
            atPath: directory.appendingPathComponent(alignmentResultFilename).path
        )
    }
}

// MARK: - PersistedAlignmentResult

/// Codable representation of a Minimap2 alignment result for JSON serialization.
///
/// File paths are stored as relative filenames (not absolute paths) so the
/// sidecar remains valid if the output directory is moved.
private struct PersistedAlignmentResult: Codable, Sendable {
    let schemaVersion: Int
    let bamPath: String
    let baiPath: String
    let totalReads: Int
    let mappedReads: Int
    let unmappedReads: Int
    let toolVersion: String
    let wallClockSeconds: Double
    let savedAt: Date
}

// MARK: - Minimap2ResultLoadError

/// Errors that can occur when loading a persisted Minimap2 alignment result.
public enum Minimap2ResultLoadError: Error, LocalizedError, Sendable {

    /// The `alignment-result.json` sidecar was not found.
    case sidecarNotFound(URL)

    public var errorDescription: String? {
        switch self {
        case .sidecarNotFound(let url):
            return "No saved Minimap2 alignment result in \(url.path)"
        }
    }
}

// MARK: - Minimap2PipelineError

/// Errors that can occur during the minimap2 read mapping pipeline.
public enum Minimap2PipelineError: Error, LocalizedError, Sendable {
    /// minimap2 is not installed in any conda environment.
    case minimap2NotInstalled

    /// An input FASTQ file was not found.
    case inputNotFound(URL)

    /// The reference FASTA file was not found.
    case referenceNotFound(URL)

    /// The minimap2 alignment step failed.
    case alignmentFailed(String)

    /// The samtools sort step failed.
    case sortFailed(String)

    /// The samtools index step failed.
    case indexFailed(String)

    /// The samtools flagstat step failed.
    case statsFailed(String)

    public var errorDescription: String? {
        switch self {
        case .minimap2NotInstalled:
            return "minimap2 is not installed. Install the Alignment plugin pack from the Plugin Manager."
        case .inputNotFound(let url):
            return "Input FASTQ not found: \(url.lastPathComponent)"
        case .referenceNotFound(let url):
            return "Reference FASTA not found: \(url.lastPathComponent)"
        case .alignmentFailed(let msg):
            return "minimap2 alignment failed: \(msg)"
        case .sortFailed(let msg):
            return "samtools sort failed: \(msg)"
        case .indexFailed(let msg):
            return "samtools index failed: \(msg)"
        case .statsFailed(let msg):
            return "samtools flagstat failed: \(msg)"
        }
    }
}

// MARK: - Minimap2Pipeline

/// Pipeline for mapping reads to a reference genome using minimap2.
///
/// Orchestrates a four-step workflow:
/// 1. **Align** -- runs minimap2 via ``CondaManager`` to produce SAM output
/// 2. **Sort** -- pipes SAM through ``NativeToolRunner``'s bundled samtools for coordinate sorting
/// 3. **Index** -- builds a BAM index (.bai) with samtools
/// 4. **Stats** -- collects mapping statistics via samtools flagstat
///
/// The pipeline uses `@unchecked Sendable` because it is designed to be
/// called from `Task.detached` contexts where `@MainActor` isolation is
/// not available. Progress is reported via a `@Sendable` callback.
///
/// ## Usage
///
/// ```swift
/// let pipeline = Minimap2Pipeline()
/// let result = try await pipeline.run(config: config) { fraction, message in
///     print("\(Int(fraction * 100))% \(message)")
/// }
/// // result.bamURL is now a sorted, indexed BAM
/// ```
///
/// ## Tool Requirements
///
/// - **minimap2**: Installed via the Alignment plugin pack (bioconda, runs via micromamba).
/// - **samtools**: Bundled as a native tool (Tier 1, always available).
public final class Minimap2Pipeline: @unchecked Sendable {

    /// The conda manager used to discover and run minimap2.
    private let condaManager: CondaManager

    /// The native tool runner used to run samtools (bundled).
    private let runner: NativeToolRunner

    /// Creates a new minimap2 pipeline.
    ///
    /// - Parameters:
    ///   - condaManager: Conda manager instance (default: shared singleton).
    ///   - runner: Native tool runner instance (default: shared singleton).
    public init(condaManager: CondaManager? = nil, runner: NativeToolRunner? = nil) {
        self.condaManager = condaManager ?? CondaManager.shared
        self.runner = runner ?? NativeToolRunner()
    }

    /// Runs the complete read mapping pipeline.
    ///
    /// Validates inputs, runs minimap2 via conda, then sorts and indexes the
    /// output BAM with the bundled samtools. Reports progress through the
    /// callback at key milestones.
    ///
    /// - Parameters:
    ///   - config: Mapping configuration including input files, reference, and preset.
    ///   - progress: Progress callback reporting fraction (0.0-1.0) and a status message.
    /// - Returns: A ``Minimap2Result`` with output file paths and mapping statistics.
    /// - Throws: ``Minimap2PipelineError`` on validation failure or tool errors.
    public func run(
        config: Minimap2Config,
        progress: @Sendable (Double, String) -> Void = { _, _ in }
    ) async throws -> Minimap2Result {
        let startTime = Date()
        let fm = FileManager.default

        // -- Validate inputs --------------------------------------------------

        for inputFile in config.inputFiles {
            guard fm.fileExists(atPath: inputFile.path) else {
                throw Minimap2PipelineError.inputNotFound(inputFile)
            }
        }
        guard fm.fileExists(atPath: config.referenceURL.path) else {
            throw Minimap2PipelineError.referenceNotFound(config.referenceURL)
        }

        // -- Check minimap2 installation --------------------------------------

        progress(0.05, "Checking minimap2 installation...")

        let minimap2Installed = await condaManager.isToolInstalled("minimap2")
        guard minimap2Installed else {
            throw Minimap2PipelineError.minimap2NotInstalled
        }

        // Discover which environment contains minimap2
        guard let minimap2Env = await condaManager.environmentContaining(tool: "minimap2") else {
            throw Minimap2PipelineError.minimap2NotInstalled
        }
        let mapperVersion = await detectToolVersion(
            toolName: "minimap2",
            environment: minimap2Env,
            condaManager: condaManager
        )
        let samtoolsVersion = await runner.getToolVersion(.samtools) ?? "unknown"
        let micromambaExecutablePath = await condaManager.micromambaPath.path

        // -- Prepare output directory -----------------------------------------

        try fm.createDirectory(at: config.outputDirectory, withIntermediateDirectories: true)

        OperationMarker.markInProgress(config.outputDirectory, detail: "Running minimap2 alignment\u{2026}")
        defer { OperationMarker.clearInProgress(config.outputDirectory) }

        let unsortedSAM = config.outputDirectory.appendingPathComponent("aligned.sam")
        let sortedBAM = config.outputDirectory.appendingPathComponent(
            "\(config.sampleName).sorted.bam"
        )
        let baiFile = config.outputDirectory.appendingPathComponent(
            "\(config.sampleName).sorted.bam.bai"
        )
        let replayInputs = try durableReplayInputMaterialization(for: config)

        // -- Build minimap2 arguments -----------------------------------------

        let minimap2Args = buildMinimap2Arguments(
            config: config,
            inputFiles: config.inputFiles,
            unsortedSAM: unsortedSAM
        )
        let provenanceMinimap2Arguments = buildMinimap2Arguments(
            config: config,
            inputFiles: replayInputs.inputFiles,
            unsortedSAM: unsortedSAM
        )
        let minimap2Command = condaCommand(
            name: "minimap2",
            arguments: minimap2Args,
            environment: minimap2Env,
            micromambaExecutablePath: micromambaExecutablePath
        )
        let durableMinimap2Command = condaCommand(
            name: "minimap2",
            arguments: provenanceMinimap2Arguments,
            environment: minimap2Env,
            micromambaExecutablePath: micromambaExecutablePath
        )

        // -- Step 1: Align with minimap2 --------------------------------------

        progress(0.10, "Aligning reads with minimap2 (\(config.preset.displayName))...")
        logger.info("Running minimap2 with preset \(config.preset.rawValue, privacy: .public) on \(config.inputFiles.count, privacy: .public) input file(s)")

        // Dynamic timeout: 2 hours base, scaled by total input size
        let totalInputBytes = config.inputFiles.compactMap { url -> Int64? in
            (try? fm.attributesOfItem(atPath: url.path))?[.size] as? Int64
        }.reduce(0, +)
        let alignTimeout = max(7200, TimeInterval(totalInputBytes / 10_000_000))

        let mappingInputs = mappingInputRecords(for: config, replayInputRecords: replayInputs.fileRecords)
        let minimap2Start = Date()
        let minimap2Result: (stdout: String, stderr: String, exitCode: Int32)
        do {
            minimap2Result = try await condaManager.runTool(
                name: "minimap2",
                arguments: minimap2Args,
                environment: minimap2Env,
                workingDirectory: config.outputDirectory,
                timeout: alignTimeout
            )
        } catch {
            let minimap2End = Date()
            let failureMessage = toolFailureMessage(error)
            let minimap2Step = StepExecution(
                toolName: "minimap2",
                toolVersion: condaToolVersionString(
                    mapperVersion,
                    environment: minimap2Env,
                    executableName: "minimap2"
                ),
                command: minimap2Command,
                durableReplayArgv: durableMinimap2Command,
                inputs: mappingInputs,
                outputs: [],
                exitCode: -1,
                wallTime: minimap2End.timeIntervalSince(minimap2Start),
                stderr: failureMessage,
                startTime: minimap2Start,
                endTime: minimap2End
            )
            try writeMappingProvenance(
                config: config,
                result: failureResult(
                    bamURL: sortedBAM,
                    baiURL: baiFile,
                    startedAt: startTime
                ),
                minimap2Environment: minimap2Env,
                minimap2Arguments: minimap2Args,
                provenanceMinimap2Arguments: provenanceMinimap2Arguments,
                micromambaExecutablePath: micromambaExecutablePath,
                mapperVersion: mapperVersion,
                samtoolsVersion: samtoolsVersion,
                inputFiles: mappingInputs,
                steps: [minimap2Step],
                exitStatus: -1
            )
            try? fm.removeItem(at: unsortedSAM)
            throw Minimap2PipelineError.alignmentFailed(failureMessage)
        }
        let minimap2End = Date()
        let rawSAMRecord = outputRecordIfPresent(url: unsortedSAM, format: .sam, role: .output)
            ?? ProvenanceRecorder.fileRecord(url: unsortedSAM, format: .sam, role: .output)
        var minimap2Step = StepExecution(
            toolName: "minimap2",
            toolVersion: condaToolVersionString(
                mapperVersion,
                environment: minimap2Env,
                executableName: "minimap2"
            ),
            command: minimap2Command,
            durableReplayArgv: durableMinimap2Command,
            inputs: mappingInputs,
            outputs: outputRecordsIfPresent(url: unsortedSAM, format: .sam, role: .output),
            exitCode: minimap2Result.exitCode,
            wallTime: minimap2End.timeIntervalSince(minimap2Start),
            stderr: nonEmpty(minimap2Result.stderr),
            startTime: minimap2Start,
            endTime: minimap2End
        )

        guard minimap2Result.exitCode == 0 else {
            minimap2Step.outputs = []
            try writeMappingProvenance(
                config: config,
                result: failureResult(
                    bamURL: sortedBAM,
                    baiURL: baiFile,
                    startedAt: startTime
                ),
                minimap2Environment: minimap2Env,
                minimap2Arguments: minimap2Args,
                provenanceMinimap2Arguments: provenanceMinimap2Arguments,
                micromambaExecutablePath: micromambaExecutablePath,
                mapperVersion: mapperVersion,
                samtoolsVersion: samtoolsVersion,
                inputFiles: mappingInputs,
                steps: [minimap2Step],
                exitStatus: minimap2Result.exitCode
            )
            // Clean up partial SAM
            try? fm.removeItem(at: unsortedSAM)
            throw Minimap2PipelineError.alignmentFailed(minimap2Result.stderr)
        }

        // -- Step 2: Sort with samtools ---------------------------------------

        progress(0.50, "Sorting alignments...")
        logger.info("Sorting SAM to BAM with samtools")

        // Use half the threads for sorting (I/O bound)
        let sortThreads = max(1, config.threads / 2)

        let sortArguments = [
            "sort",
            "-@", String(sortThreads),
            "-o", sortedBAM.path,
            unsortedSAM.path,
        ]
        let sortStart = Date()
        let sortResult: NativeToolResult
        do {
            sortResult = try await runner.run(
                .samtools,
                arguments: sortArguments,
                workingDirectory: config.outputDirectory,
                timeout: max(3600, TimeInterval(totalInputBytes / 5_000_000))
            )
        } catch {
            let sortEnd = Date()
            let failureMessage = toolFailureMessage(error)
            let sortStep = StepExecution(
                toolName: NativeTool.samtools.executableName,
                toolVersion: nativeToolVersionString(samtoolsVersion, tool: .samtools),
                command: [NativeTool.samtools.executableName] + sortArguments,
                inputs: [rawSAMRecord],
                outputs: outputRecordsIfPresent(url: sortedBAM, format: .bam, role: .output),
                exitCode: -1,
                wallTime: sortEnd.timeIntervalSince(sortStart),
                stderr: failureMessage,
                startTime: sortStart,
                endTime: sortEnd
            )
            try writeMappingProvenance(
                config: config,
                result: failureResult(
                    bamURL: sortedBAM,
                    baiURL: baiFile,
                    startedAt: startTime
                ),
                minimap2Environment: minimap2Env,
                minimap2Arguments: minimap2Args,
                provenanceMinimap2Arguments: provenanceMinimap2Arguments,
                micromambaExecutablePath: micromambaExecutablePath,
                mapperVersion: mapperVersion,
                samtoolsVersion: samtoolsVersion,
                inputFiles: mappingInputs,
                steps: [minimap2Step, sortStep],
                exitStatus: -1
            )
            throw Minimap2PipelineError.sortFailed(failureMessage)
        }
        let sortEnd = Date()
        let sortStep = StepExecution(
            toolName: NativeTool.samtools.executableName,
            toolVersion: nativeToolVersionString(samtoolsVersion, tool: .samtools),
            command: sortResult.arguments.isEmpty ? [NativeTool.samtools.executableName] + sortArguments : sortResult.arguments,
            inputs: [rawSAMRecord],
            outputs: outputRecordsIfPresent(url: sortedBAM, format: .bam, role: .output),
            exitCode: sortResult.exitCode,
            wallTime: sortEnd.timeIntervalSince(sortStart),
            stderr: nonEmpty(sortResult.stderr),
            startTime: sortStart,
            endTime: sortEnd
        )

        guard sortResult.isSuccess else {
            try writeMappingProvenance(
                config: config,
                result: failureResult(
                    bamURL: sortedBAM,
                    baiURL: baiFile,
                    startedAt: startTime
                ),
                minimap2Environment: minimap2Env,
                minimap2Arguments: minimap2Args,
                provenanceMinimap2Arguments: provenanceMinimap2Arguments,
                micromambaExecutablePath: micromambaExecutablePath,
                mapperVersion: mapperVersion,
                samtoolsVersion: samtoolsVersion,
                inputFiles: mappingInputs,
                steps: [minimap2Step, sortStep],
                exitStatus: sortResult.exitCode
            )
            throw Minimap2PipelineError.sortFailed(sortResult.stderr)
        }

        // Clean up unsorted SAM -- it can be very large
        try? fm.removeItem(at: unsortedSAM)

        // -- Step 3: Index with samtools --------------------------------------

        progress(0.80, "Indexing BAM...")
        logger.info("Building BAM index")

        let indexArguments = ["index", sortedBAM.path]
        let indexStart = Date()
        let indexResult: NativeToolResult
        do {
            indexResult = try await runner.run(
                .samtools,
                arguments: indexArguments,
                workingDirectory: config.outputDirectory,
                timeout: 600
            )
        } catch {
            let indexEnd = Date()
            let failureMessage = toolFailureMessage(error)
            let indexStep = StepExecution(
                toolName: NativeTool.samtools.executableName,
                toolVersion: nativeToolVersionString(samtoolsVersion, tool: .samtools),
                command: [NativeTool.samtools.executableName] + indexArguments,
                inputs: [ProvenanceRecorder.fileRecord(url: sortedBAM, format: .bam, role: .input)],
                outputs: outputRecordsIfPresent(url: baiFile, role: .index),
                exitCode: -1,
                wallTime: indexEnd.timeIntervalSince(indexStart),
                stderr: failureMessage,
                startTime: indexStart,
                endTime: indexEnd
            )
            try writeMappingProvenance(
                config: config,
                result: failureResult(
                    bamURL: sortedBAM,
                    baiURL: baiFile,
                    startedAt: startTime
                ),
                minimap2Environment: minimap2Env,
                minimap2Arguments: minimap2Args,
                provenanceMinimap2Arguments: provenanceMinimap2Arguments,
                micromambaExecutablePath: micromambaExecutablePath,
                mapperVersion: mapperVersion,
                samtoolsVersion: samtoolsVersion,
                inputFiles: mappingInputs,
                steps: [minimap2Step, sortStep, indexStep],
                exitStatus: -1
            )
            throw Minimap2PipelineError.indexFailed(failureMessage)
        }
        let indexEnd = Date()
        let indexStep = StepExecution(
            toolName: NativeTool.samtools.executableName,
            toolVersion: nativeToolVersionString(samtoolsVersion, tool: .samtools),
            command: indexResult.arguments.isEmpty ? [NativeTool.samtools.executableName] + indexArguments : indexResult.arguments,
            inputs: [ProvenanceRecorder.fileRecord(url: sortedBAM, format: .bam, role: .input)],
            outputs: outputRecordsIfPresent(url: baiFile, role: .index),
            exitCode: indexResult.exitCode,
            wallTime: indexEnd.timeIntervalSince(indexStart),
            stderr: nonEmpty(indexResult.stderr),
            startTime: indexStart,
            endTime: indexEnd
        )

        guard indexResult.isSuccess else {
            try writeMappingProvenance(
                config: config,
                result: failureResult(
                    bamURL: sortedBAM,
                    baiURL: baiFile,
                    startedAt: startTime
                ),
                minimap2Environment: minimap2Env,
                minimap2Arguments: minimap2Args,
                provenanceMinimap2Arguments: provenanceMinimap2Arguments,
                micromambaExecutablePath: micromambaExecutablePath,
                mapperVersion: mapperVersion,
                samtoolsVersion: samtoolsVersion,
                inputFiles: mappingInputs,
                steps: [minimap2Step, sortStep, indexStep],
                exitStatus: indexResult.exitCode
            )
            throw Minimap2PipelineError.indexFailed(indexResult.stderr)
        }

        // -- Step 4: Collect statistics ---------------------------------------

        progress(0.90, "Collecting alignment statistics...")

        let statsArguments = ["flagstat", sortedBAM.path]
        let statsStart = Date()
        let statsResult: NativeToolResult
        do {
            statsResult = try await runner.run(
                .samtools,
                arguments: statsArguments,
                workingDirectory: config.outputDirectory,
                timeout: 300
            )
        } catch {
            let statsEnd = Date()
            let failureMessage = toolFailureMessage(error)
            let statsStep = StepExecution(
                toolName: NativeTool.samtools.executableName,
                toolVersion: nativeToolVersionString(samtoolsVersion, tool: .samtools),
                command: [NativeTool.samtools.executableName] + statsArguments,
                inputs: [ProvenanceRecorder.fileRecord(url: sortedBAM, format: .bam, role: .input)],
                outputs: [],
                exitCode: -1,
                wallTime: statsEnd.timeIntervalSince(statsStart),
                stderr: failureMessage,
                startTime: statsStart,
                endTime: statsEnd
            )
            try writeMappingProvenance(
                config: config,
                result: failureResult(
                    bamURL: sortedBAM,
                    baiURL: baiFile,
                    startedAt: startTime
                ),
                minimap2Environment: minimap2Env,
                minimap2Arguments: minimap2Args,
                provenanceMinimap2Arguments: provenanceMinimap2Arguments,
                micromambaExecutablePath: micromambaExecutablePath,
                mapperVersion: mapperVersion,
                samtoolsVersion: samtoolsVersion,
                inputFiles: mappingInputs,
                steps: [minimap2Step, sortStep, indexStep, statsStep],
                exitStatus: -1
            )
            throw Minimap2PipelineError.statsFailed(failureMessage)
        }
        let statsEnd = Date()
        let statsStep = StepExecution(
            toolName: NativeTool.samtools.executableName,
            toolVersion: nativeToolVersionString(samtoolsVersion, tool: .samtools),
            command: statsResult.arguments.isEmpty ? [NativeTool.samtools.executableName] + statsArguments : statsResult.arguments,
            inputs: [ProvenanceRecorder.fileRecord(url: sortedBAM, format: .bam, role: .input)],
            outputs: [],
            exitCode: statsResult.exitCode,
            wallTime: statsEnd.timeIntervalSince(statsStart),
            stderr: nonEmpty(statsResult.stderr),
            startTime: statsStart,
            endTime: statsEnd
        )

        guard statsResult.isSuccess else {
            try writeMappingProvenance(
                config: config,
                result: failureResult(
                    bamURL: sortedBAM,
                    baiURL: baiFile,
                    startedAt: startTime
                ),
                minimap2Environment: minimap2Env,
                minimap2Arguments: minimap2Args,
                provenanceMinimap2Arguments: provenanceMinimap2Arguments,
                micromambaExecutablePath: micromambaExecutablePath,
                mapperVersion: mapperVersion,
                samtoolsVersion: samtoolsVersion,
                inputFiles: mappingInputs,
                steps: [minimap2Step, sortStep, indexStep, statsStep],
                exitStatus: statsResult.exitCode
            )
            throw Minimap2PipelineError.statsFailed(statsResult.stderr)
        }

        let (totalReads, mappedReads) = parseFlagstat(statsResult.stdout)

        // -- Done -------------------------------------------------------------

        let elapsed = Date().timeIntervalSince(startTime)
        let mappingPct = totalReads > 0
            ? String(format: "%.1f%%", Double(mappedReads) / Double(totalReads) * 100)
            : "N/A"
        progress(1.0, "Mapping complete: \(mappedReads)/\(totalReads) reads mapped (\(mappingPct))")

        logger.info("Minimap2 pipeline complete in \(String(format: "%.1f", elapsed))s: \(mappedReads)/\(totalReads) mapped")

        let pipelineResult = Minimap2Result(
            bamURL: sortedBAM,
            baiURL: baiFile,
            totalReads: totalReads,
            mappedReads: mappedReads,
            unmappedReads: totalReads - mappedReads,
            wallClockSeconds: elapsed
        )
        try writeMappingProvenance(
            config: config,
            result: pipelineResult,
            minimap2Environment: minimap2Env,
            minimap2Arguments: minimap2Args,
            provenanceMinimap2Arguments: provenanceMinimap2Arguments,
            micromambaExecutablePath: micromambaExecutablePath,
            mapperVersion: mapperVersion,
            samtoolsVersion: samtoolsVersion,
            inputFiles: mappingInputs,
            steps: [minimap2Step, sortStep, indexStep, statsStep],
            exitStatus: 0
        )
        return pipelineResult
    }

    // MARK: - Private Helpers

    /// Parses samtools flagstat output to extract total and mapped read counts.
    ///
    /// Example flagstat output:
    /// ```
    /// 1234567 + 0 in total (QC-passed reads + QC-failed reads)
    /// 0 + 0 secondary
    /// 0 + 0 supplementary
    /// 0 + 0 duplicates
    /// 1200000 + 0 mapped (97.20% : N/A)
    /// ```
    ///
    /// - Parameter output: The raw flagstat text from samtools.
    /// - Returns: A tuple of (totalReads, mappedReads). Returns (0, 0) on parse failure.
    func parseFlagstat(_ output: String) -> (total: Int, mapped: Int) {
        var total = 0
        var mapped = 0

        for line in output.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.contains("in total") {
                total = Int(trimmed.split(separator: " ").first ?? "0") ?? 0
            } else if trimmed.contains("mapped (") && !trimmed.contains("primary mapped") {
                mapped = Int(trimmed.split(separator: " ").first ?? "0") ?? 0
            }
        }

        return (total, mapped)
    }

    private func writeMappingProvenance(
        config: Minimap2Config,
        result: Minimap2Result,
        minimap2Environment: String,
        minimap2Arguments: [String],
        provenanceMinimap2Arguments: [String],
        micromambaExecutablePath: String,
        mapperVersion: String,
        samtoolsVersion: String,
        inputFiles: [FileRecord],
        steps: [StepExecution],
        exitStatus: Int32
    ) throws {
        let request = MappingRunRequest(
            tool: .minimap2,
            modeID: config.preset.rawValue,
            inputFASTQURLs: config.provenanceInputFiles ?? config.inputFiles,
            referenceFASTAURL: config.referenceURL,
            outputDirectory: config.outputDirectory,
            sampleName: config.sampleName,
            pairedEnd: config.isPairedEnd,
            threads: config.threads,
            includeSecondary: config.includeSecondary,
            includeSupplementary: config.includeSupplementary,
            minimumMappingQuality: config.minMappingQuality,
            advancedArguments: config.advancedArguments
        )
        let mapperInvocation = MappingCommandInvocation(
            label: MappingTool.minimap2.displayName,
            argv: condaCommand(
                name: "minimap2",
                arguments: minimap2Arguments,
                environment: minimap2Environment,
                micromambaExecutablePath: micromambaExecutablePath
            ),
            durableReplayArgv: condaCommand(
                name: "minimap2",
                arguments: provenanceMinimap2Arguments,
                environment: minimap2Environment,
                micromambaExecutablePath: micromambaExecutablePath
            )
        )
        let normalizationInvocations = steps.dropFirst().map { step in
            MappingCommandInvocation(
                label: step.command.dropFirst().first.map { "samtools \($0)" } ?? "samtools",
                argv: step.command
            )
        }
        let outputFiles = [
            outputRecordIfPresent(url: result.bamURL, format: .bam, role: .output),
            outputRecordIfPresent(url: result.baiURL, role: .index),
        ].compactMap { $0 }

        let provenance = MappingProvenance.build(
            request: request,
            result: MappingResult(
                mapper: .minimap2,
                modeID: request.modeID,
                bamURL: result.bamURL,
                baiURL: result.baiURL,
                totalReads: result.totalReads,
                mappedReads: result.mappedReads,
                unmappedReads: result.unmappedReads,
                wallClockSeconds: result.wallClockSeconds,
                contigs: []
            ),
            mapperInvocation: mapperInvocation,
            normalizationInvocations: normalizationInvocations,
            mapperVersion: mapperVersion,
            samtoolsVersion: samtoolsVersion,
            inputFiles: inputFiles,
            outputFiles: outputFiles,
            runtimeIdentity: [
                "mapper": condaRuntimeIdentity(environment: minimap2Environment, executableName: "minimap2"),
                "samtools": runtimeIdentity(for: .samtools),
            ],
            steps: steps,
            exitStatus: exitStatus,
            stderr: combinedStderr(steps.map(\.stderr))
        )
        try provenance.save(to: config.outputDirectory)
    }

    private func failureResult(
        bamURL: URL,
        baiURL: URL,
        startedAt: Date
    ) -> Minimap2Result {
        Minimap2Result(
            bamURL: bamURL,
            baiURL: baiURL,
            totalReads: 0,
            mappedReads: 0,
            unmappedReads: 0,
            wallClockSeconds: Date().timeIntervalSince(startedAt)
        )
    }

    private func outputRecordIfPresent(
        url: URL,
        format: FileFormat? = nil,
        role: FileRole
    ) -> FileRecord? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return ProvenanceRecorder.fileRecord(url: url, format: format, role: role)
    }

    private func outputRecordsIfPresent(
        url: URL,
        format: FileFormat? = nil,
        role: FileRole
    ) -> [FileRecord] {
        outputRecordIfPresent(url: url, format: format, role: role).map { [$0] } ?? []
    }

    private struct DurableReplayInputMaterialization {
        let inputFiles: [URL]
        let fileRecords: [FileRecord]
    }

    private func durableReplayInputMaterialization(
        for config: Minimap2Config
    ) throws -> DurableReplayInputMaterialization {
        let requestedReplayInputs = config.provenanceInputFiles ?? config.inputFiles
        if requestedReplayInputs.allSatisfy(isRunnableSequenceInput) {
            return DurableReplayInputMaterialization(inputFiles: requestedReplayInputs, fileRecords: [])
        }

        let replayDirectory = config.outputDirectory
            .appendingPathComponent(ProvenanceWriter.bundleProvenanceDirectoryName, isDirectory: true)
            .appendingPathComponent("intermediates", isDirectory: true)
            .appendingPathComponent("minimap2-inputs", isDirectory: true)
        try FileManager.default.createDirectory(at: replayDirectory, withIntermediateDirectories: true)

        var replayInputs: [URL] = []
        var replayRecords: [FileRecord] = []
        for (index, inputFile) in config.inputFiles.enumerated() {
            let replayInput = replayDirectory.appendingPathComponent(
                "input-\(index + 1)-\(inputFile.lastPathComponent)"
            )
            try copyReplacingItem(at: inputFile, to: replayInput)
            replayInputs.append(replayInput)
            replayRecords.append(
                ProvenanceRecorder.fileRecord(url: replayInput, format: fileFormat(for: replayInput), role: .input)
            )
        }
        return DurableReplayInputMaterialization(inputFiles: replayInputs, fileRecords: replayRecords)
    }

    private func isRunnableSequenceInput(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
              !isDirectory.boolValue else {
            return false
        }
        switch fileFormat(for: url) {
        case .fastq, .fasta:
            return true
        default:
            return false
        }
    }

    private func copyReplacingItem(at sourceURL: URL, to destinationURL: URL) throws {
        try FileManager.default.createDirectory(
            at: destinationURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        if FileManager.default.fileExists(atPath: destinationURL.path) {
            try FileManager.default.removeItem(at: destinationURL)
        }
        try FileManager.default.copyItem(at: sourceURL, to: destinationURL)
    }

    private func mappingInputRecords(
        for config: Minimap2Config,
        replayInputRecords: [FileRecord]
    ) -> [FileRecord] {
        let records: [FileRecord]
        if let provenanceInputFileRecords = config.provenanceInputFileRecords {
            records = provenanceInputFileRecords + [
                ProvenanceRecorder.fileRecord(url: config.referenceURL, format: fileFormat(for: config.referenceURL), role: .reference),
            ]
        } else {
            let provenanceInputFiles = config.provenanceInputFiles ?? config.inputFiles
            records = provenanceInputFiles.map {
                ProvenanceRecorder.fileRecord(url: $0, format: fileFormat(for: $0), role: .input)
            } + [
                ProvenanceRecorder.fileRecord(url: config.referenceURL, format: fileFormat(for: config.referenceURL), role: .reference),
            ]
        }
        return deduplicatedFileRecords(records + replayInputRecords)
    }

    private func deduplicatedFileRecords(_ records: [FileRecord]) -> [FileRecord] {
        var seen = Set<String>()
        return records.filter { record in
            seen.insert("\(record.role.rawValue)|\(URL(fileURLWithPath: record.path).standardizedFileURL.path)").inserted
        }
    }

    private func buildMinimap2Arguments(
        config: Minimap2Config,
        inputFiles: [URL],
        unsortedSAM: URL
    ) -> [String] {
        var arguments: [String] = [
            "-a",  // Output SAM format
            "-x", config.preset.rawValue,
            "-t", String(config.threads),
        ]

        // Read group header -- samtools and downstream tools use this
        let platform: String
        switch config.preset {
        case .mapONT:
            platform = "ONT"
        case .mapHiFi, .mapPB:
            platform = "PACBIO"
        default:
            platform = "ILLUMINA"
        }
        arguments.append(contentsOf: [
            "-R", "@RG\\tID:\(config.sampleName)\\tSM:\(config.sampleName)\\tPL:\(platform)",
        ])

        // Secondary alignment filter
        if !config.includeSecondary {
            arguments.append("--secondary=no")
        }

        arguments += config.advancedArguments
        arguments += ["-o", unsortedSAM.path]

        // Reference and input files (positional args at the end)
        arguments.append(config.referenceURL.path)
        for inputFile in inputFiles {
            arguments.append(inputFile.path)
        }
        return arguments
    }

    private func fileFormat(for url: URL) -> FileFormat {
        switch url.pathExtension.lowercased() {
        case "sam":
            return .sam
        case "bam":
            return .bam
        case "fastq", "fq":
            return .fastq
        case "fa", "fasta", "fna":
            return .fasta
        default:
            let lowercasedName = url.lastPathComponent.lowercased()
            if lowercasedName.hasSuffix(".fastq.gz") || lowercasedName.hasSuffix(".fq.gz") {
                return .fastq
            }
            if lowercasedName.hasSuffix(".fa.gz")
                || lowercasedName.hasSuffix(".fasta.gz")
                || lowercasedName.hasSuffix(".fna.gz") {
                return .fasta
            }
            return .unknown
        }
    }

    private func toolFailureMessage(_ error: Error) -> String {
        let localized = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        let trimmed = localized.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? String(describing: error) : trimmed
    }

    private func condaCommand(
        name: String,
        arguments: [String],
        environment: String,
        micromambaExecutablePath: String
    ) -> [String] {
        [micromambaExecutablePath, "run", "-n", environment, name] + arguments
    }

    private func condaToolVersionString(
        _ version: String,
        environment: String,
        executableName: String
    ) -> String {
        "\(version) (\(condaRuntimeIdentity(environment: environment, executableName: executableName)))"
    }

    private func nativeToolVersionString(_ version: String, tool: NativeTool) -> String {
        "\(version) (\(runtimeIdentity(for: tool)))"
    }

    private func condaRuntimeIdentity(environment: String, executableName: String) -> String {
        "managed conda environment \(environment); executable \(executableName); root \(condaManager.rootPrefix.path)"
    }

    private func runtimeIdentity(for tool: NativeTool) -> String {
        switch tool.location {
        case .managed(let environment, let executableName):
            let packageSpec = (try? ManagedToolLock.loadFromBundle().tool(named: environment)?.packageSpec)
                ?? tool.sourcePackage
            return "managed conda environment \(environment); executable \(executableName); package \(packageSpec)"
        case .bundled(let relativePath):
            return "bundled executable \(relativePath)"
        }
    }

    private func nonEmpty(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : value
    }

    private func combinedStderr(_ values: [String?]) -> String? {
        let combined = values
            .compactMap { $0 }
            .compactMap(nonEmpty)
            .joined(separator: "\n")
        return combined.isEmpty ? nil : combined
    }
}
