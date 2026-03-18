// FASTQMetadataStore.swift - Sidecar JSON metadata persistence for FASTQ files
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishCore
import os.log

private let logger = Logger(subsystem: "com.lungfish.io", category: "FASTQMetadataStore")

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
        sequencingPlatform: SequencingPlatform? = nil
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
            logger.info("Loaded FASTQ metadata from \(url.lastPathComponent)")
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

    /// Size of the file before clumpification/compression (bytes).
    public var originalSizeBytes: Int64?

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
        recipeApplied: RecipeAppliedInfo? = nil
    ) {
        self.isClumpified = isClumpified
        self.isCompressed = isCompressed
        self.pairingMode = pairingMode
        self.qualityBinning = qualityBinning
        self.originalFilenames = originalFilenames
        self.ingestionDate = ingestionDate
        self.originalSizeBytes = originalSizeBytes
        self.recipeApplied = recipeApplied
    }
}

// MARK: - Recipe Applied Info

/// Per-step statistics for a processing recipe applied during ingestion.
public struct RecipeStepResult: Codable, Sendable {
    /// Human-readable step name (e.g. "Human read scrub", "Deduplicate").
    public let stepName: String
    /// Tool identifier (e.g. "sra-human-scrubber", "clumpify").
    public let tool: String
    /// Tool version string at time of execution.
    public let toolVersion: String?
    /// Number of reads (or read pairs for interleaved) entering this step.
    public let inputReadCount: Int?
    /// Number of reads (or read pairs) after this step.
    public let outputReadCount: Int?
    /// Wall-clock seconds this step took.
    public let durationSeconds: Double

    public init(
        stepName: String,
        tool: String,
        toolVersion: String? = nil,
        inputReadCount: Int? = nil,
        outputReadCount: Int? = nil,
        durationSeconds: Double
    ) {
        self.stepName = stepName
        self.tool = tool
        self.toolVersion = toolVersion
        self.inputReadCount = inputReadCount
        self.outputReadCount = outputReadCount
        self.durationSeconds = durationSeconds
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
}
