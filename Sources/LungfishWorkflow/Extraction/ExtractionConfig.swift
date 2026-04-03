// ExtractionConfig.swift - Configuration, result, and error types for universal read extraction
// Copyright (c) 2025 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation

// MARK: - ReadIDExtractionConfig

/// Configuration for extracting a set of reads by read ID using `seqkit grep`.
///
/// Supports both single-end and paired-end FASTQ input. When ``keepReadPairs``
/// is `true`, pair-mate suffixes (`/1`, `/2`) are stripped before matching so
/// both mates are always included together.
///
/// ## Thread Safety
///
/// `ReadIDExtractionConfig` is a value type conforming to `Sendable`, safe to
/// pass across isolation boundaries.
public struct ReadIDExtractionConfig: Sendable {

    /// The FASTQ file(s) to extract from.
    ///
    /// Provide one file for single-end data or exactly two files (R1, R2) for
    /// paired-end data. Files may be gzip-compressed (`.fastq.gz`).
    public let sourceFASTQs: [URL]

    /// The set of read IDs to extract.
    ///
    /// These are the bare read identifiers as they appear in the FASTQ `@` header
    /// line, without the leading `@` character and without pair-mate suffixes.
    public let readIDs: Set<String>

    /// Whether to include both mates when either mate matches a read ID.
    ///
    /// When `true` (the default), pair-mate suffixes (`/1`, `/2`) are stripped
    /// from both the query IDs and the FASTQ headers before matching. This
    /// ensures both mates are always extracted together.
    public let keepReadPairs: Bool

    /// The directory where output FASTQ file(s) are written.
    public let outputDirectory: URL

    /// Base name for the output file(s), without extension.
    ///
    /// For single-end output the pipeline writes `<outputBaseName>.fastq.gz`.
    /// For paired-end output it writes `<outputBaseName>_R1.fastq.gz` and
    /// `<outputBaseName>_R2.fastq.gz`.
    public let outputBaseName: String

    /// Creates a read-ID extraction configuration.
    ///
    /// - Parameters:
    ///   - sourceFASTQs: Input FASTQ file(s).
    ///   - readIDs: Read IDs to extract.
    ///   - keepReadPairs: Include both mates when either matches (default: `true`).
    ///   - outputDirectory: Directory for output files.
    ///   - outputBaseName: Base name for output files, without extension.
    public init(
        sourceFASTQs: [URL],
        readIDs: Set<String>,
        keepReadPairs: Bool = true,
        outputDirectory: URL,
        outputBaseName: String
    ) {
        self.sourceFASTQs = sourceFASTQs
        self.readIDs = readIDs
        self.keepReadPairs = keepReadPairs
        self.outputDirectory = outputDirectory
        self.outputBaseName = outputBaseName
    }

    /// Whether this configuration targets paired-end data.
    public var isPairedEnd: Bool { sourceFASTQs.count > 1 }
}

// MARK: - BAMRegionExtractionConfig

/// Configuration for extracting reads from a BAM file by genomic region using `samtools view`.
///
/// Regions are specified as strings in samtools region notation (e.g. `"chr1"`,
/// `"chr1:1000-2000"`). When no regions are provided and ``fallbackToAll`` is
/// `true`, all reads are extracted.
///
/// ## Thread Safety
///
/// `BAMRegionExtractionConfig` is a value type conforming to `Sendable`, safe to
/// pass across isolation boundaries.
public struct BAMRegionExtractionConfig: Sendable {

    /// The sorted, indexed BAM file to extract reads from.
    public let bamURL: URL

    /// Genomic regions to extract, in samtools region notation.
    ///
    /// Empty means no region filter; behaviour is controlled by ``fallbackToAll``.
    public let regions: [String]

    /// When `true` and ``regions`` is empty, extract all reads from the BAM.
    ///
    /// When `false` and ``regions`` is empty, the extraction fails with
    /// ``ExtractionError/noMatchingRegions``.
    public let fallbackToAll: Bool

    /// The directory where the output FASTQ file(s) are written.
    public let outputDirectory: URL

    /// Base name for the output file(s), without extension.
    public let outputBaseName: String

    /// When `true`, passes `-F 1024` to `samtools view` to exclude PCR/optical
    /// duplicate-flagged reads, yielding only unique alignments.
    ///
    /// Defaults to `true` because classifier BAMs (EsViritu, TaxTriage) often
    /// contain duplicates that inflate read counts relative to the unique-read
    /// counts shown in the taxonomy table.
    public let deduplicateReads: Bool

    /// Creates a BAM region extraction configuration.
    ///
    /// - Parameters:
    ///   - bamURL: Sorted, indexed BAM file to read from.
    ///   - regions: Genomic regions in samtools notation.
    ///   - fallbackToAll: Extract all reads when `regions` is empty (default: `false`).
    ///   - outputDirectory: Directory for output files.
    ///   - outputBaseName: Base name for output files, without extension.
    ///   - deduplicateReads: Exclude PCR duplicate-flagged reads (default: `true`).
    public init(
        bamURL: URL,
        regions: [String],
        fallbackToAll: Bool = false,
        outputDirectory: URL,
        outputBaseName: String,
        deduplicateReads: Bool = true
    ) {
        self.bamURL = bamURL
        self.regions = regions
        self.fallbackToAll = fallbackToAll
        self.outputDirectory = outputDirectory
        self.outputBaseName = outputBaseName
        self.deduplicateReads = deduplicateReads
    }
}

// MARK: - DatabaseExtractionConfig

/// Configuration for extracting reads from a Lungfish SQLite database by tax ID or accession.
///
/// Used by the EsViritu and TaxTriage classifiers, which store per-read assignments
/// in a structured SQLite database rather than flat classification files.
///
/// ## Thread Safety
///
/// `DatabaseExtractionConfig` is a value type conforming to `Sendable`, safe to
/// pass across isolation boundaries.
public struct DatabaseExtractionConfig: Sendable {

    /// URL of the classifier SQLite database.
    public let databaseURL: URL

    /// The sample ID within the database to query, if applicable.
    ///
    /// When `nil`, the query spans all samples.
    public let sampleId: String?

    /// Tax IDs to extract reads for.
    ///
    /// When empty, no tax-ID filter is applied.
    public let taxIds: Set<Int>

    /// Sequence accessions to extract reads for.
    ///
    /// When empty, no accession filter is applied.
    public let accessions: Set<String>

    /// Maximum number of reads to extract, or `nil` for no limit.
    public let maxReads: Int?

    /// The directory where output FASTQ file(s) are written.
    public let outputDirectory: URL

    /// Base name for the output file(s), without extension.
    public let outputBaseName: String

    /// Creates a database extraction configuration.
    ///
    /// - Parameters:
    ///   - databaseURL: SQLite database file produced by the classifier.
    ///   - sampleId: Optional sample ID to scope the query.
    ///   - taxIds: NCBI taxonomy IDs to include.
    ///   - accessions: Sequence accessions to include.
    ///   - maxReads: Maximum reads to return, or `nil` for no limit.
    ///   - outputDirectory: Directory for output files.
    ///   - outputBaseName: Base name for output files, without extension.
    public init(
        databaseURL: URL,
        sampleId: String? = nil,
        taxIds: Set<Int> = [],
        accessions: Set<String> = [],
        maxReads: Int? = nil,
        outputDirectory: URL,
        outputBaseName: String
    ) {
        self.databaseURL = databaseURL
        self.sampleId = sampleId
        self.taxIds = taxIds
        self.accessions = accessions
        self.maxReads = maxReads
        self.outputDirectory = outputDirectory
        self.outputBaseName = outputBaseName
    }
}

// MARK: - ExtractionResult

/// The result of a successful read extraction operation.
///
/// Callers use ``fastqURLs`` to locate the extracted FASTQ file(s) and
/// ``pairedEnd`` to determine whether to display them as paired.
///
/// ## Thread Safety
///
/// `ExtractionResult` is a value type conforming to `Sendable`.
public struct ExtractionResult: Sendable {

    /// URLs of the written FASTQ file(s).
    ///
    /// Contains one URL for single-end extractions and two URLs (R1, R2) for
    /// paired-end extractions.
    public let fastqURLs: [URL]

    /// The number of reads extracted (or read pairs for paired-end data).
    public let readCount: Int

    /// Whether the extracted data is paired-end.
    public let pairedEnd: Bool

    /// Creates an extraction result.
    ///
    /// - Parameters:
    ///   - fastqURLs: Output FASTQ file URL(s).
    ///   - readCount: Number of reads (or pairs) extracted.
    ///   - pairedEnd: Whether the output is paired-end.
    public init(fastqURLs: [URL], readCount: Int, pairedEnd: Bool) {
        self.fastqURLs = fastqURLs
        self.readCount = readCount
        self.pairedEnd = pairedEnd
    }
}

// MARK: - ExtractionMetadata

/// Metadata written into a FASTQ bundle produced by an extraction.
///
/// Serialised as JSON into the bundle's `.lungfish-provenance.json` sidecar.
/// All properties are optional so partial metadata degrades gracefully.
///
/// ## Thread Safety
///
/// `ExtractionMetadata` is a value type conforming to `Sendable` and `Codable`.
public struct ExtractionMetadata: Sendable, Codable {

    /// Human-readable description of the data source (e.g. bundle display name).
    public let sourceDescription: String

    /// The name of the tool or classifier that produced the source data.
    public let toolName: String

    /// The date and time at which the extraction was performed.
    public let extractionDate: Date

    /// Arbitrary key–value parameters describing the extraction (e.g. tax IDs, regions).
    public let parameters: [String: String]

    /// Creates extraction metadata.
    ///
    /// - Parameters:
    ///   - sourceDescription: Human-readable source description.
    ///   - toolName: Name of the tool that produced the source data.
    ///   - extractionDate: When the extraction was performed (default: now).
    ///   - parameters: Key–value extraction parameters for provenance.
    public init(
        sourceDescription: String,
        toolName: String,
        extractionDate: Date = Date(),
        parameters: [String: String] = [:]
    ) {
        self.sourceDescription = sourceDescription
        self.toolName = toolName
        self.extractionDate = extractionDate
        self.parameters = parameters
    }
}

// MARK: - RegionMatchResult

/// Result of attempting to match caller-supplied region strings against the reference
/// names present in a BAM file's header.
///
/// Produced by `BAMRegionMatcher` so the caller can inspect which regions were
/// resolved before handing off to `samtools view`.
public struct RegionMatchResult: Sendable {

    /// The strategy that was applied to resolve region names.
    public enum MatchStrategy: String, Sendable, CaseIterable {
        /// Regions matched the BAM reference names exactly.
        case exact

        /// Regions were matched by prefix (e.g. `"NC_045512"` → `"NC_045512.2"`).
        case prefix

        /// Regions were matched by substring containment.
        case contains

        /// No regions matched; the extraction will include all reads as a fallback.
        case fallbackAll

        /// No BAM file is associated with this dataset; BAM extraction is unavailable.
        case noBAM
    }

    /// Region strings that were successfully resolved to BAM reference names.
    public let matchedRegions: [String]

    /// Region strings that could not be resolved to any BAM reference name.
    public let unmatchedRegions: [String]

    /// The strategy that produced this result.
    public let strategy: MatchStrategy

    /// All reference sequence names present in the BAM header.
    public let bamReferenceNames: [String]

    /// Creates a region match result.
    ///
    /// - Parameters:
    ///   - matchedRegions: Successfully resolved region strings.
    ///   - unmatchedRegions: Unresolved region strings.
    ///   - strategy: The match strategy used.
    ///   - bamReferenceNames: All reference names in the BAM header.
    public init(
        matchedRegions: [String],
        unmatchedRegions: [String],
        strategy: MatchStrategy,
        bamReferenceNames: [String]
    ) {
        self.matchedRegions = matchedRegions
        self.unmatchedRegions = unmatchedRegions
        self.strategy = strategy
        self.bamReferenceNames = bamReferenceNames
    }

    /// Whether all requested regions were matched.
    public var isFullMatch: Bool {
        unmatchedRegions.isEmpty && !matchedRegions.isEmpty
    }
}

// MARK: - ExtractionBundleNaming

/// Utilities for deriving safe, human-readable FASTQ bundle names from classifier
/// output identifiers.
///
/// All generated names:
/// - Replace whitespace with underscores
/// - Strip characters that are invalid in file or bundle names
/// - Are truncated to 200 characters
public enum ExtractionBundleNaming: Sendable {

    /// Derives a bundle name from a source descriptor and a selection label.
    ///
    /// The resulting name combines ``source`` and ``selection`` with a dash,
    /// sanitises the combined string, and truncates it to 200 characters.
    ///
    /// - Parameters:
    ///   - source: The source dataset name (e.g. bundle display name).
    ///   - selection: A short description of what was selected (e.g. taxon name).
    /// - Returns: A sanitised, truncated string suitable for use as a bundle or file name.
    public static func bundleName(source: String, selection: String) -> String {
        let combined = "\(source)-\(selection)"
        return sanitize(combined)
    }

    // MARK: - Private Helpers

    private static func sanitize(_ raw: String) -> String {
        // Replace whitespace runs with underscores
        var result = raw.replacingOccurrences(
            of: #"\s+"#,
            with: "_",
            options: .regularExpression
        )

        // Strip characters that are not alphanumeric, dash, underscore, or dot
        result = result.filter { char in
            char.isLetter || char.isNumber
                || char == "-" || char == "_" || char == "."
        }

        // Truncate to 200 characters
        if result.count > 200 {
            result = String(result.prefix(200))
        }

        return result
    }
}

// MARK: - ExtractionError

/// Errors produced during universal read extraction operations.
public enum ExtractionError: Error, LocalizedError, Sendable {

    /// No source FASTQ files were provided or could be resolved.
    case noSourceFASTQ

    /// The read ID set is empty; there is nothing to extract.
    case emptyReadIDSet

    /// The BAM file does not exist at the specified path.
    case bamFileNotFound(URL)

    /// The BAM file is not indexed (missing `.bai` or `.csi` index).
    case bamNotIndexed(URL)

    /// None of the requested regions could be matched to BAM reference names.
    case noMatchingRegions([String])

    /// The extraction produced zero reads.
    case emptyExtraction

    /// `seqkit grep` exited with a non-zero status.
    ///
    /// The associated value is the combined standard error output from the tool.
    case seqkitFailed(String)

    /// `samtools view` exited with a non-zero status.
    ///
    /// The associated value is the combined standard error output from the tool.
    case samtoolsFailed(String)

    /// The SQLite database query failed.
    ///
    /// The associated value describes the failure reason.
    case databaseQueryFailed(String)

    /// The output FASTQ bundle directory could not be created or written to.
    ///
    /// The associated value describes the failure reason.
    case bundleCreationFailed(String)

    // MARK: - LocalizedError

    public var errorDescription: String? {
        switch self {
        case .noSourceFASTQ:
            return "No source FASTQ files are available for extraction"
        case .emptyReadIDSet:
            return "The read ID set is empty; nothing to extract"
        case .bamFileNotFound(let url):
            return "BAM file not found: \(url.lastPathComponent)"
        case .bamNotIndexed(let url):
            return "BAM file is not indexed: \(url.lastPathComponent)"
        case .noMatchingRegions(let regions):
            let preview = regions.prefix(3).joined(separator: ", ")
            let suffix = regions.count > 3 ? " (and \(regions.count - 3) more)" : ""
            return "No BAM reference names matched the requested regions: \(preview)\(suffix)"
        case .emptyExtraction:
            return "The extraction produced zero reads"
        case .seqkitFailed(let stderr):
            return "seqkit grep failed: \(stderr)"
        case .samtoolsFailed(let stderr):
            return "samtools view failed: \(stderr)"
        case .databaseQueryFailed(let reason):
            return "Database query failed: \(reason)"
        case .bundleCreationFailed(let reason):
            return "Could not create output bundle: \(reason)"
        }
    }
}
