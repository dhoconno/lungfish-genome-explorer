// FASTQMetadataStore.swift - Sidecar JSON metadata persistence for FASTQ files
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishCore
import os.log

private let logger = Logger(subsystem: "com.lungfish.io", category: "FASTQMetadataStore")

// MARK: - Persisted Assembly Read Type

/// Explicit dataset-level read type used to constrain assembly tool selection.
///
/// Stored in the FASTQ sidecar so the app can remember a user-confirmed assembly
/// class independently of sample metadata CSV fields.
public enum FASTQAssemblyReadType: String, Codable, Sendable, CaseIterable {
    case illuminaShortReads
    case ontReads
    case pacBioHiFi

    public var displayName: String {
        switch self {
        case .illuminaShortReads:
            return "Illumina short reads"
        case .ontReads:
            return "ONT reads"
        case .pacBioHiFi:
            return "PacBio HiFi/CCS"
        }
    }

    public init?(sequencingPlatform: SequencingPlatform) {
        switch sequencingPlatform {
        case .illumina:
            self = .illuminaShortReads
        case .oxfordNanopore:
            self = .ontReads
        default:
            return nil
        }
    }
}

// MARK: - Persisted FASTQ Metadata

/// Metadata persisted alongside a FASTQ file as a sidecar JSON.
///
/// File convention: `SRR12345.fastq.gz.lungfish-meta.json`
///
/// Contains cached statistics (to avoid re-computing on reload),
/// download provenance, and SRA/ENA metadata when available.
public struct PersistedFASTQMetadata: Codable, Sendable {

    /// Cached dataset statistics (avoids re-streaming the FASTQ).
    public var computedStatistics: FASTQDatasetStatistics?

    /// SRA run info (from NCBI SRA search).
    public var sraRunInfo: SRARunInfo?

    /// ENA read record (from ENA Portal API).
    public var enaReadRecord: ENAReadRecord?

    /// Date the FASTQ was downloaded.
    public var downloadDate: Date?

    /// Source URL or identifier for the download.
    public var downloadSource: String?

    /// Ingestion pipeline metadata (clumpify/compress/index status).
    public var ingestion: IngestionMetadata?

    /// Cached summary parsed from `seqkit stats -a -T`.
    public var seqkitStats: SeqkitStatsMetadata?

    /// Read type classification for bundles with heterogeneous read types
    /// (e.g. after paired-end merging produces paired + merged + orphan reads).
    /// Nil for homogeneous single-end or paired-end bundles.
    public var readClassification: ReadClassification?

    /// Optional FASTQ demultiplex metadata edited in the FASTQ bottom drawer.
    public var demultiplexMetadata: FASTQDemultiplexMetadata?

    /// Sequencing platform that generated this data (ONT, Illumina, PacBio, etc.).
    /// Used to select appropriate adapter contexts and error rates.
    public var sequencingPlatform: SequencingPlatform?

    /// Optional user-confirmed assembly read type for this dataset.
    ///
    /// This is narrower than `sequencingPlatform`: PacBio datasets are only
    /// represented here when the user explicitly confirms HiFi/CCS suitability.
    public var assemblyReadType: FASTQAssemblyReadType?

    public init(
        computedStatistics: FASTQDatasetStatistics? = nil,
        sraRunInfo: SRARunInfo? = nil,
        enaReadRecord: ENAReadRecord? = nil,
        downloadDate: Date? = nil,
        downloadSource: String? = nil,
        ingestion: IngestionMetadata? = nil,
        seqkitStats: SeqkitStatsMetadata? = nil,
        readClassification: ReadClassification? = nil,
        demultiplexMetadata: FASTQDemultiplexMetadata? = nil,
        sequencingPlatform: SequencingPlatform? = nil,
        assemblyReadType: FASTQAssemblyReadType? = nil
    ) {
        self.computedStatistics = computedStatistics
        self.sraRunInfo = sraRunInfo
        self.enaReadRecord = enaReadRecord
        self.downloadDate = downloadDate
        self.downloadSource = downloadSource
        self.ingestion = ingestion
        self.seqkitStats = seqkitStats
        self.readClassification = readClassification
        self.demultiplexMetadata = demultiplexMetadata
        self.sequencingPlatform = sequencingPlatform
        self.assemblyReadType = assemblyReadType
    }
}

/// Summary values from `seqkit stats -a -T` cached in metadata.
public struct SeqkitStatsMetadata: Codable, Sendable, Equatable {
    public let numSeqs: Int
    public let sumLen: Int64
    public let minLen: Int
    public let avgLen: Double
    public let maxLen: Int
    public let q20Percentage: Double
    public let q30Percentage: Double
    public let averageQuality: Double
    public let gcPercentage: Double

    public init(
        numSeqs: Int,
        sumLen: Int64,
        minLen: Int,
        avgLen: Double,
        maxLen: Int,
        q20Percentage: Double,
        q30Percentage: Double,
        averageQuality: Double,
        gcPercentage: Double
    ) {
        self.numSeqs = numSeqs
        self.sumLen = sumLen
        self.minLen = minLen
        self.avgLen = avgLen
        self.maxLen = maxLen
        self.q20Percentage = q20Percentage
        self.q30Percentage = q30Percentage
        self.averageQuality = averageQuality
        self.gcPercentage = gcPercentage
    }
}

// MARK: - FASTQMetadataStore

/// Reads and writes sidecar metadata JSON files alongside FASTQ files.
///
/// ```swift
/// // Save after computing statistics
/// let metadata = PersistedFASTQMetadata(
///     computedStatistics: stats,
///     enaReadRecord: enaRecord
/// )
/// FASTQMetadataStore.save(metadata, for: fastqURL)
///
/// // Load on next open
/// if let cached = FASTQMetadataStore.load(for: fastqURL) {
///     // Use cached.computedStatistics instead of re-computing
/// }
/// ```
public enum FASTQMetadataStore {

    /// Returns the sidecar metadata URL for a given FASTQ file.
    ///
    /// Example: `/path/to/SRR123.fastq.gz` → `/path/to/SRR123.fastq.gz.lungfish-meta.json`
    public static func metadataURL(for fastqURL: URL) -> URL {
        fastqURL.appendingPathExtension("lungfish-meta.json")
    }

    /// Loads persisted metadata from the sidecar JSON, if it exists.
    ///
    /// - Parameter fastqURL: The URL of the FASTQ file.
    /// - Returns: The persisted metadata, or nil if no sidecar exists.
    public static func load(for fastqURL: URL) -> PersistedFASTQMetadata? {
        let url = metadataURL(for: fastqURL)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }

        do {
            let data = try Data(contentsOf: url)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let metadata = try decoder.decode(PersistedFASTQMetadata.self, from: data)
            return metadata
        } catch {
            logger.warning("Failed to load FASTQ metadata: \(error)")
            return nil
        }
    }

    /// Saves metadata to the sidecar JSON file.
    ///
    /// - Parameters:
    ///   - metadata: The metadata to persist.
    ///   - fastqURL: The URL of the FASTQ file.
    public static func save(_ metadata: PersistedFASTQMetadata, for fastqURL: URL) {
        let url = metadataURL(for: fastqURL)

        do {
            // Do not create orphan metadata files when the FASTQ was deleted.
            guard FileManager.default.fileExists(atPath: fastqURL.path) else {
                logger.debug("Skipping FASTQ metadata save because source file is missing: \(fastqURL.lastPathComponent, privacy: .public)")
                return
            }

            // Ensure parent directory exists for late writes after moves.
            let parentDirectory = url.deletingLastPathComponent()
            if !FileManager.default.fileExists(atPath: parentDirectory.path) {
                try FileManager.default.createDirectory(at: parentDirectory, withIntermediateDirectories: true)
            }

            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(metadata)
            try data.write(to: url, options: .atomic)
            logger.info("Saved FASTQ metadata to \(url.lastPathComponent)")
        } catch {
            logger.warning("Failed to save FASTQ metadata: \(error)")
        }
    }

    /// Deletes the sidecar metadata file if it exists.
    ///
    /// - Parameter fastqURL: The URL of the FASTQ file.
    public static func delete(for fastqURL: URL) {
        let url = metadataURL(for: fastqURL)
        try? FileManager.default.removeItem(at: url)
    }
}

// MARK: - Read Classification

/// Tracks the composition of a FASTQ bundle containing heterogeneous read types.
///
/// After operations like paired-end merging, a single dataset may contain
/// paired reads, merged reads, and orphan/unpaired reads. This struct records
/// the breakdown so downstream tools receive the correct input format.
///
/// When a bundle is homogeneous (all paired or all single-end), this struct
/// is nil in the metadata — the existing `IngestionMetadata.PairingMode` suffices.
public struct ReadClassification: Codable, Sendable, Equatable {

    /// Role of a FASTQ file within a multi-file bundle.
    public enum FileRole: String, Codable, Sendable, CaseIterable {
        case pairedR1 = "paired_r1"
        case pairedR2 = "paired_r2"
        case merged = "merged"
        case unpaired = "unpaired"
    }

    /// A single FASTQ file entry in the read manifest.
    public struct FileEntry: Codable, Sendable, Equatable {
        public let filename: String
        public let role: FileRole
        public let readCount: Int

        public init(filename: String, role: FileRole, readCount: Int) {
            self.filename = filename
            self.role = role
            self.readCount = readCount
        }
    }

    /// Files in this bundle and their roles.
    public let files: [FileEntry]

    /// Number of paired reads (individual reads, always even: R1 count + R2 count).
    public var pairedReadCount: Int {
        files.filter { $0.role == .pairedR1 || $0.role == .pairedR2 }
            .reduce(0) { $0 + $1.readCount }
    }

    /// Number of merged reads (overlap-merged from paired input).
    public var mergedReadCount: Int {
        files.filter { $0.role == .merged }.reduce(0) { $0 + $1.readCount }
    }

    /// Number of orphan/unpaired reads.
    public var unpairedReadCount: Int {
        files.filter { $0.role == .unpaired }.reduce(0) { $0 + $1.readCount }
    }

    /// Total surviving reads across all files.
    public var totalReadCount: Int {
        files.reduce(0) { $0 + $1.readCount }
    }

    /// Number of fragments (the conserved quantity across merge operations).
    public var fragmentCount: Int {
        (pairedReadCount / 2) + mergedReadCount + unpairedReadCount
    }

    /// True when all reads are the same type (no mixed composition).
    public var isHomogeneous: Bool {
        let nonEmpty = files.map(\.role).reduce(into: Set<FileRole>()) { $0.insert($1) }
        if nonEmpty.count <= 1 { return true }
        // R1 + R2 together counts as one type (paired)
        if nonEmpty == [.pairedR1, .pairedR2] { return true }
        return false
    }

    /// Human-readable composition label for the sidebar (e.g. "5,000 pairs + 2,617 merged").
    public var compositionLabel: String {
        var parts: [String] = []
        let pairs = pairedReadCount / 2
        if pairs > 0 {
            parts.append("\(pairs.formatted()) pairs")
        }
        if mergedReadCount > 0 {
            parts.append("\(mergedReadCount.formatted()) merged")
        }
        if unpairedReadCount > 0 {
            parts.append("\(unpairedReadCount.formatted()) singles")
        }
        return parts.isEmpty ? "empty" : parts.joined(separator: " + ")
    }

    public init(files: [FileEntry]) {
        self.files = files
    }

    /// Convenience initializer for bundles where counts are known but files are separate.
    public init(pairedR1File: String, pairedR1Count: Int,
                pairedR2File: String, pairedR2Count: Int,
                mergedFile: String? = nil, mergedCount: Int = 0,
                unpairedFile: String? = nil, unpairedCount: Int = 0) {
        var entries: [FileEntry] = [
            FileEntry(filename: pairedR1File, role: .pairedR1, readCount: pairedR1Count),
            FileEntry(filename: pairedR2File, role: .pairedR2, readCount: pairedR2Count),
        ]
        if let mergedFile, mergedCount > 0 {
            entries.append(FileEntry(filename: mergedFile, role: .merged, readCount: mergedCount))
        }
        if let unpairedFile, unpairedCount > 0 {
            entries.append(FileEntry(filename: unpairedFile, role: .unpaired, readCount: unpairedCount))
        }
        self.files = entries
    }
}

// MARK: - Read Manifest

/// Standalone manifest file (`read-manifest.json`) for multi-file bundles.
///
/// This is saved as a separate file in the bundle root when the bundle contains
/// multiple FASTQ files with different roles.
public struct ReadManifest: Codable, Sendable, Equatable {
    public static let filename = "read-manifest.json"

    public let version: Int
    public let classification: ReadClassification
    public let sourceOperation: String?

    public init(classification: ReadClassification, sourceOperation: String? = nil) {
        self.version = 1
        self.classification = classification
        self.sourceOperation = sourceOperation
    }

    /// Loads a read manifest from a bundle directory, if present.
    public static func load(from bundleURL: URL) -> ReadManifest? {
        let url = bundleURL.appendingPathComponent(filename)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        do {
            let data = try Data(contentsOf: url)
            return try JSONDecoder().decode(ReadManifest.self, from: data)
        } catch {
            return nil
        }
    }

    /// Saves the manifest to a bundle directory.
    public func save(to bundleURL: URL) throws {
        let url = bundleURL.appendingPathComponent(Self.filename)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(self)
        try data.write(to: url, options: .atomic)
    }
}

// MARK: - Ingestion Metadata

/// Records the state of the FASTQ ingestion pipeline.
public struct IngestionMetadata: Codable, Sendable {

    /// Pairing mode of the FASTQ data.
    public enum PairingMode: String, Codable, Sendable {
        case singleEnd = "single_end"
        case pairedEnd = "paired_end"
        case interleaved = "interleaved"
    }

    /// Whether the file has been clumpified (k-mer sorted for compression).
    public var isClumpified: Bool

    /// Whether the file is gzip-compressed.
    public var isCompressed: Bool

    /// Pairing mode (single-end, paired-end, or interleaved).
    public var pairingMode: PairingMode

    /// Quality binning scheme applied (e.g. "illumina4", "eightLevel", "none").
    /// Nil for files ingested before quality binning was added.
    public var qualityBinning: String?

    /// Original filenames before ingestion (e.g. ["SRR123_1.fastq", "SRR123_2.fastq"]).
    public var originalFilenames: [String]

    /// Date the ingestion pipeline completed.
    public var ingestionDate: Date?

    /// Size of the original source files before import or recipe processing (bytes).
    public var originalSizeBytes: Int64?

    /// Size of the FASTQ payload handed to the final storage optimization step (bytes).
    public var storageInputSizeBytes: Int64?

    /// Size of the final stored FASTQ payload after storage optimization/compression (bytes).
    public var storageOutputSizeBytes: Int64?

    /// Post-import recipe applied during ingestion, with per-step stats.
    public var recipeApplied: RecipeAppliedInfo?

    public init(
        isClumpified: Bool = false,
        isCompressed: Bool = false,
        pairingMode: PairingMode = .singleEnd,
        qualityBinning: String? = nil,
        originalFilenames: [String] = [],
        ingestionDate: Date? = nil,
        originalSizeBytes: Int64? = nil,
        storageInputSizeBytes: Int64? = nil,
        storageOutputSizeBytes: Int64? = nil,
        recipeApplied: RecipeAppliedInfo? = nil
    ) {
        self.isClumpified = isClumpified
        self.isCompressed = isCompressed
        self.pairingMode = pairingMode
        self.qualityBinning = qualityBinning
        self.originalFilenames = originalFilenames
        self.ingestionDate = ingestionDate
        self.originalSizeBytes = originalSizeBytes
        self.storageInputSizeBytes = storageInputSizeBytes
        self.storageOutputSizeBytes = storageOutputSizeBytes
        self.recipeApplied = recipeApplied
    }
}

// MARK: - Recipe Applied Info

/// A logical recipe component represented by a physical execution step.
///
/// A physical tool invocation may fuse multiple logical recipe components.
/// These values identify the requested components without implying that each
/// component ran as a separate process.
public struct RecipeLogicalComponent: Codable, Sendable, Equatable {
    public let typeID: String
    public let displayName: String

    public init(typeID: String, displayName: String) {
        self.typeID = typeID
        self.displayName = displayName
    }
}

/// Execution-time evidence for a recipe step output that may be deleted after downstream use.
public struct RecipeStepOutputFile: Codable, Sendable, Equatable {
    public let path: String
    public let checksumSHA256: String
    public let sizeBytes: UInt64

    public init(path: String, checksumSHA256: String, sizeBytes: UInt64) {
        self.path = path
        self.checksumSHA256 = checksumSHA256
        self.sizeBytes = sizeBytes
    }
}

/// Per-step statistics for a processing recipe applied during ingestion.
public struct RecipeStepResult: Codable, Sendable {
    /// Human-readable step name (e.g. "Human read scrub", "Deduplicate").
    public let stepName: String
    /// Tool identifier (e.g. "sra-human-scrubber", "clumpify").
    public let tool: String
    /// Tool version string at time of execution.
    public let toolVersion: String?
    /// Command line used to execute the step (for reproducibility/auditing).
    public let commandLine: String?
    /// Exact argv used to execute the step when available, including the executable as argv[0].
    public let commandArguments: [String]?
    /// Number of reads (or read pairs for interleaved) entering this step.
    public let inputReadCount: Int?
    /// Number of reads (or read pairs) after this step.
    public let outputReadCount: Int?
    /// Wall-clock seconds this step took.
    public let durationSeconds: Double
    /// Additional files emitted by the step and retained with the final bundle.
    public let auxiliaryOutputPaths: [String]
    /// Rewrites from exact execution-time paths to durable replay paths for auxiliary outputs.
    public let auxiliaryCommandPathRewrites: [String: String]
    /// Ordered logical recipe components represented by this physical step.
    public let logicalComponents: [RecipeLogicalComponent]
    /// Primary output files snapshotted at execution time before intermediate cleanup.
    public let executionOutputFiles: [RecipeStepOutputFile]
    /// Actual process exit status, when the process ran and reported one.
    public let exitStatus: Int?
    /// Bounded, normalized stderr captured from the actual process.
    public let stderr: String?
    /// Actual process start timestamp, when captured.
    public let startedAt: Date?
    /// Actual process completion timestamp, when captured.
    public let completedAt: Date?

    private enum CodingKeys: String, CodingKey {
        case stepName
        case tool
        case toolVersion
        case commandLine
        case commandArguments
        case inputReadCount
        case outputReadCount
        case durationSeconds
        case auxiliaryOutputPaths
        case auxiliaryCommandPathRewrites
        case logicalComponents
        case executionOutputFiles
        case exitStatus
        case stderr
        case startedAt
        case completedAt
    }

    private static let maxStderrLength = 10_240
    private static let stderrTruncationMarker = "\n... [truncated]"
    private static let deduplicationComponentID = "fastp-dedup"
    private static let trimmingComponentID = "fastp-trim"
    private static let legacyFusedFastpLabel = "remove pcr duplicates + adapter + quality trim"

    public init(
        stepName: String,
        tool: String,
        toolVersion: String? = nil,
        commandLine: String? = nil,
        commandArguments: [String]? = nil,
        inputReadCount: Int? = nil,
        outputReadCount: Int? = nil,
        durationSeconds: Double,
        auxiliaryOutputPaths: [String] = [],
        auxiliaryCommandPathRewrites: [String: String] = [:],
        logicalComponents: [RecipeLogicalComponent] = [],
        executionOutputFiles: [RecipeStepOutputFile] = [],
        exitStatus: Int? = nil,
        stderr: String? = nil,
        startedAt: Date? = nil,
        completedAt: Date? = nil
    ) {
        self.stepName = stepName
        self.tool = tool
        self.toolVersion = toolVersion
        self.commandLine = commandLine
        self.commandArguments = commandArguments
        self.inputReadCount = inputReadCount
        self.outputReadCount = outputReadCount
        self.durationSeconds = durationSeconds
        self.auxiliaryOutputPaths = auxiliaryOutputPaths
        self.auxiliaryCommandPathRewrites = auxiliaryCommandPathRewrites
        self.logicalComponents = logicalComponents
        self.executionOutputFiles = executionOutputFiles
        self.exitStatus = exitStatus
        self.stderr = Self.normalizedStderr(stderr)
        self.startedAt = startedAt
        self.completedAt = completedAt
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        stepName = try container.decode(String.self, forKey: .stepName)
        tool = try container.decode(String.self, forKey: .tool)
        toolVersion = try container.decodeIfPresent(String.self, forKey: .toolVersion)
        commandLine = try container.decodeIfPresent(String.self, forKey: .commandLine)
        commandArguments = try container.decodeIfPresent([String].self, forKey: .commandArguments)
        inputReadCount = try container.decodeIfPresent(Int.self, forKey: .inputReadCount)
        outputReadCount = try container.decodeIfPresent(Int.self, forKey: .outputReadCount)
        durationSeconds = try container.decode(Double.self, forKey: .durationSeconds)
        auxiliaryOutputPaths = try container.decodeIfPresent([String].self, forKey: .auxiliaryOutputPaths) ?? []
        auxiliaryCommandPathRewrites = try container.decodeIfPresent(
            [String: String].self,
            forKey: .auxiliaryCommandPathRewrites
        ) ?? [:]
        logicalComponents = try container.decodeIfPresent(
            [RecipeLogicalComponent].self,
            forKey: .logicalComponents
        ) ?? []
        executionOutputFiles = try container.decodeIfPresent(
            [RecipeStepOutputFile].self,
            forKey: .executionOutputFiles
        ) ?? []
        exitStatus = try container.decodeIfPresent(Int.self, forKey: .exitStatus)
        stderr = Self.normalizedStderr(try container.decodeIfPresent(String.self, forKey: .stderr))
        startedAt = try container.decodeIfPresent(Date.self, forKey: .startedAt)
        completedAt = try container.decodeIfPresent(Date.self, forKey: .completedAt)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(stepName, forKey: .stepName)
        try container.encode(tool, forKey: .tool)
        try container.encodeIfPresent(toolVersion, forKey: .toolVersion)
        try container.encodeIfPresent(commandLine, forKey: .commandLine)
        try container.encodeIfPresent(commandArguments, forKey: .commandArguments)
        try container.encodeIfPresent(inputReadCount, forKey: .inputReadCount)
        try container.encodeIfPresent(outputReadCount, forKey: .outputReadCount)
        try container.encode(durationSeconds, forKey: .durationSeconds)
        if !auxiliaryOutputPaths.isEmpty {
            try container.encode(auxiliaryOutputPaths, forKey: .auxiliaryOutputPaths)
        }
        if !auxiliaryCommandPathRewrites.isEmpty {
            try container.encode(auxiliaryCommandPathRewrites, forKey: .auxiliaryCommandPathRewrites)
        }
        if !logicalComponents.isEmpty {
            try container.encode(logicalComponents, forKey: .logicalComponents)
        }
        if !executionOutputFiles.isEmpty {
            try container.encode(executionOutputFiles, forKey: .executionOutputFiles)
        }
        try container.encodeIfPresent(exitStatus, forKey: .exitStatus)
        try container.encodeIfPresent(stderr, forKey: .stderr)
        try container.encodeIfPresent(startedAt, forKey: .startedAt)
        try container.encodeIfPresent(completedAt, forKey: .completedAt)
    }

    public func replacingAuxiliaryOutputs(
        paths: [String],
        commandPathRewrites: [String: String]
    ) -> RecipeStepResult {
        RecipeStepResult(
            stepName: stepName,
            tool: tool,
            toolVersion: toolVersion,
            commandLine: commandLine,
            commandArguments: commandArguments,
            inputReadCount: inputReadCount,
            outputReadCount: outputReadCount,
            durationSeconds: durationSeconds,
            auxiliaryOutputPaths: paths,
            auxiliaryCommandPathRewrites: commandPathRewrites,
            logicalComponents: logicalComponents,
            executionOutputFiles: executionOutputFiles,
            exitStatus: exitStatus,
            stderr: stderr,
            startedAt: startedAt,
            completedAt: completedAt
        )
    }

    /// Timestamp-derived wall time when actual execution evidence is available,
    /// otherwise the duration stored by legacy metadata.
    public var effectiveDurationSeconds: Double {
        guard let startedAt, let completedAt else { return durationSeconds }
        return completedAt.timeIntervalSince(startedAt)
    }

    /// Whether this physical step includes a deduplication operation.
    public var didApplyDeduplication: Bool {
        if !logicalComponents.isEmpty {
            return logicalComponentTypeIDs.contains(Self.deduplicationComponentID)
        }

        let name = stepName.lowercased()
        let arguments = commandArguments ?? []
        return name.contains("dedup")
            || name.contains("duplicate")
            || arguments.contains(where: { $0.lowercased() == "--dedup" })
    }

    /// Whether this physical step combines deduplication with trimming or filtering.
    public var didApplyDeduplicationAndTrimmingInCombinedPass: Bool {
        if !logicalComponents.isEmpty {
            return logicalComponentTypeIDs.contains(Self.deduplicationComponentID)
                && logicalComponentTypeIDs.contains(Self.trimmingComponentID)
        }

        let normalizedTool = tool.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let normalizedName = stepName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let hasKnownFusedFastpName = normalizedTool == "fastp"
            && normalizedName == Self.legacyFusedFastpLabel
        let arguments = commandArguments?.map { $0.lowercased() } ?? []
        let hasDedupArgument = arguments.contains("--dedup")
        let trimArgumentPrefixes = [
            "--adapter_sequence",
            "--average_qual",
            "--cut_",
            "--length_required",
            "--qualified_quality_phred",
            "--trim_"
        ]
        let hasTrimArgument = arguments.contains { argument in
            trimArgumentPrefixes.contains { prefix in argument.hasPrefix(prefix) }
        }

        return hasKnownFusedFastpName || (hasDedupArgument && hasTrimArgument)
    }

    private var logicalComponentTypeIDs: Set<String> {
        Set(logicalComponents.map { $0.typeID.lowercased() })
    }

    private static func normalizedStderr(_ stderr: String?) -> String? {
        guard let stderr else { return nil }
        let bounded: String
        if stderr.count > maxStderrLength {
            bounded = String(stderr.prefix(maxStderrLength)) + stderrTruncationMarker
        } else {
            bounded = stderr
        }
        return bounded.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : bounded
    }

    /// Reads removed (positive) or added (negative) by this step.
    public var readsRemoved: Int? {
        guard let i = inputReadCount, let o = outputReadCount else { return nil }
        return i - o
    }
}

/// Summary of a post-import recipe run, stored in IngestionMetadata.
public struct RecipeAppliedInfo: Codable, Sendable {
    /// Stable identifier of the recipe (e.g. "illuminaVSP2TargetEnrichment").
    public let recipeID: String
    /// Human-readable recipe display name.
    public let recipeName: String
    /// Date the recipe was applied.
    public let appliedDate: Date
    /// Ordered results for each recipe step.
    public let stepResults: [RecipeStepResult]

    public init(
        recipeID: String,
        recipeName: String,
        appliedDate: Date = Date(),
        stepResults: [RecipeStepResult]
    ) {
        self.recipeID = recipeID
        self.recipeName = recipeName
        self.appliedDate = appliedDate
        self.stepResults = stepResults
    }

    /// Total reads removed across all steps (input of step 0 minus output of last step).
    public var totalReadsRemoved: Int? {
        guard let first = stepResults.first?.inputReadCount,
              let last = stepResults.last?.outputReadCount else { return nil }
        return first - last
    }

    public struct ReadDeltaSummary: Equatable, Sendable {
        public let inputReads: Int
        public let outputReads: Int

        public init(inputReads: Int, outputReads: Int) {
            self.inputReads = inputReads
            self.outputReads = outputReads
        }

        public var readsRemoved: Int { inputReads - outputReads }

        public var percentRemoved: Double {
            inputReads > 0 ? Double(readsRemoved) / Double(inputReads) * 100 : 0
        }
    }

    public var deduplicationSummary: ReadDeltaSummary? {
        readDeltaSummary { step in
            step.didApplyDeduplication && !step.didApplyDeduplicationAndTrimmingInCombinedPass
        }
    }

    /// Whether any recipe step performed deduplication.
    public var didApplyDeduplication: Bool {
        stepResults.contains(where: \.didApplyDeduplication)
    }

    /// Whether deduplication was performed as part of a fused physical step.
    public var deduplicationPerformedInCombinedPass: Bool {
        stepResults.contains(where: \.didApplyDeduplicationAndTrimmingInCombinedPass)
    }

    public var humanScrubSummary: ReadDeltaSummary? {
        readDeltaSummary { step in
            let name = step.stepName.lowercased()
            let tool = step.tool.lowercased()
            return name.contains("human") || name.contains("scrub") || tool.contains("deacon")
        }
    }

    public static func readDeltaLogLine(_ label: String, _ summary: ReadDeltaSummary) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        let input = formatter.string(from: NSNumber(value: summary.inputReads)) ?? "\(summary.inputReads)"
        let output = formatter.string(from: NSNumber(value: summary.outputReads)) ?? "\(summary.outputReads)"
        let pct = String(format: "%.1f", summary.percentRemoved)
        return "\(label) removed \(pct)% of reads (\(input) -> \(output))"
    }

    private func readDeltaSummary(
        matching predicate: (RecipeStepResult) -> Bool
    ) -> ReadDeltaSummary? {
        guard let step = stepResults.first(where: predicate),
              let input = step.inputReadCount,
              let output = step.outputReadCount else {
            return nil
        }
        return ReadDeltaSummary(inputReads: input, outputReads: output)
    }
}
