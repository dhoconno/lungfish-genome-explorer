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
    /// Explicit evidence index. Region workflows must never discover one.
    public let indexURL: URL?
    /// CRAM decoding reference; it is not an index substitute.
    public let decodingReferenceURL: URL?

    /// Genomic regions to extract, in samtools region notation.
    ///
    /// Empty means no region filter; behaviour is controlled by ``fallbackToAll``.
    public let regions: [String]
    public let minMapQ: Int?
    public let excludedFlags: Int?
    public let readGroups: [String]

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
        indexURL: URL? = nil,
        decodingReferenceURL: URL? = nil,
        regions: [String],
        fallbackToAll: Bool = false,
        minMapQ: Int? = nil,
        excludedFlags: Int? = nil,
        readGroups: [String] = [],
        outputDirectory: URL,
        outputBaseName: String,
        deduplicateReads: Bool = true
    ) {
        self.bamURL = bamURL
        self.indexURL = indexURL
        self.decodingReferenceURL = decodingReferenceURL
        self.regions = regions
        self.fallbackToAll = fallbackToAll
        self.minMapQ = minMapQ
        self.excludedFlags = excludedFlags
        self.readGroups = readGroups
        self.outputDirectory = outputDirectory
        self.outputBaseName = outputBaseName
        self.deduplicateReads = deduplicateReads
    }

    /// Exact explicit-index samtools invocation. Options precede `-X`'s
    /// positional BAM/index pair so samtools does not interpret them as regions.
    public func explicitViewArguments(outputBAM: URL) -> [String] {
        var arguments = ["view", "-b"]
        if let decodingReferenceURL, bamURL.pathExtension.lowercased() == "cram" {
            arguments += ["-T", decodingReferenceURL.path]
        }
        if let minMapQ { arguments += ["-q", String(minMapQ)] }
        let flags = excludedFlags ?? (deduplicateReads ? 0x400 : 0)
        if flags != 0 { arguments += ["-F", String(flags)] }
        for group in readGroups { arguments += ["-r", group] }
        arguments += ["-o", outputBAM.path]
        guard let indexURL else { return arguments + [bamURL.path] + regions }
        return arguments + ["-X", bamURL.path, indexURL.path] + regions
    }
}

// MARK: - ReadIDBAMExtractionConfig

/// Configuration for extracting a set of reads by QNAME directly from a BAM
/// file, via `samtools view -N <names.txt>` (falling back to FASTQ-derived
/// extraction is the caller's responsibility — this config always targets a
/// BAM source).
///
/// Used when the reads' original source FASTQ(s) cannot be resolved (e.g. a
/// mapping-result viewport with no retained FASTQ bundle reference), so the
/// BAM itself — from which the reads were selected — is the only available
/// read source.
///
/// ## Bio-gate semantics
///
/// - Secondary (0x100) and supplementary (0x800) alignments are excluded by
///   default (`samtools view -F 0x900`); set ``includeSecondary`` to include
///   them, in which case duplicate-QNAME output records are disambiguated
///   with a `/sup` or `/sec` suffix.
/// - Mates return automatically because `samtools view -N` matches by QNAME
///   — both mates of a pair come back together when either mate's QNAME is
///   in the name file, with NO extra flag needed.
/// - PCR/optical duplicates (0x400) are INCLUDED by default (unlike
///   ``BAMRegionExtractionConfig``, whose `deduplicateReads` defaults to
///   `true`) — read-selection extraction is about a user-identified set of
///   specific reads, so silently dropping a duplicate-flagged one the user
///   explicitly selected would be surprising. Set ``excludeDuplicates`` to
///   opt into `-F 0x400` filtering.
/// - Reads whose mate did not come back mapped/selected are routed to a
///   `singletons.fastq` sidecar via `samtools fastq -s`, rather than being
///   silently dropped.
///
/// ## Known limitation
///
/// A read pair that is FULLY unmapped (both mates unmapped) may not carry a
/// `RNAME`/position and can be absent from a coordinate-sorted BAM's index
/// range scan depending on how the BAM was produced; `samtools view -N`
/// still matches by QNAME across the whole file, so this is a samtools/BAM
/// production characteristic to document for users, not a Lungfish bug.
///
/// ## Thread Safety
///
/// `ReadIDBAMExtractionConfig` is a value type conforming to `Sendable`.
public struct ReadIDBAMExtractionConfig: Sendable {

    /// The BAM file to extract reads from.
    public let bamURL: URL

    /// The set of read QNAMEs to extract.
    public let readIDs: Set<String>

    /// When `true`, secondary/supplementary alignments matching a requested
    /// QNAME are included (name-disambiguated with `/sup`/`/sec` suffixes).
    /// Defaults to `false` (samtools' traditional `-F 0x900` behavior).
    public let includeSecondary: Bool

    /// When `true`, PCR/optical duplicate-flagged reads (0x400) are excluded.
    /// Defaults to `false` — unlike region-based extraction, a user who
    /// explicitly selected a duplicate-flagged read expects it back.
    public let excludeDuplicates: Bool

    /// Output read format: FASTQ (default) or FASTA.
    public let format: ReadIDBAMExtractionFormat

    /// The directory where output file(s) are written.
    public let outputDirectory: URL

    /// Base name for the output file(s), without extension.
    public let outputBaseName: String

    public init(
        bamURL: URL,
        readIDs: Set<String>,
        includeSecondary: Bool = false,
        excludeDuplicates: Bool = false,
        format: ReadIDBAMExtractionFormat = .fastq,
        outputDirectory: URL,
        outputBaseName: String
    ) {
        self.bamURL = bamURL
        self.readIDs = readIDs
        self.includeSecondary = includeSecondary
        self.excludeDuplicates = excludeDuplicates
        self.format = format
        self.outputDirectory = outputDirectory
        self.outputBaseName = outputBaseName
    }

    /// The `samtools view -F` flag filter value for this configuration.
    ///
    /// Defaults to excluding secondary + supplementary (`0x900`); adds
    /// duplicate exclusion (`0x400`) when ``excludeDuplicates`` is set.
    /// When ``includeSecondary`` is `true`, secondary/supplementary are NOT
    /// filtered (the caller disambiguates their output names instead).
    public var flagFilter: Int {
        var filter = 0
        if !includeSecondary {
            filter |= 0x900
        }
        if excludeDuplicates {
            filter |= 0x400
        }
        return filter
    }
}

/// Output format for ``ReadIDBAMExtractionConfig``-driven extraction.
public enum ReadIDBAMExtractionFormat: String, Sendable {
    case fastq
    case fasta
}

/// Result of a BAM-source read-ID extraction, including the persisted name
/// file (kept, not deleted, so a CLI replay of the operation is faithful)
/// and any singleton reads routed to a separate sidecar file.
public struct ReadIDBAMExtractionResult: Sendable {
    /// Primary output file URL(s) — one for single-end/interleaved output.
    public let outputURLs: [URL]

    /// Number of reads extracted (paired mates count individually).
    public let readCount: Int

    /// URL of the persisted read-name file passed to `samtools view -N`.
    public let readNameFileURL: URL

    /// URL of the singleton sidecar file, if any singleton reads were
    /// produced (a mate that did not itself match/return).
    public let singletonsURL: URL?

    public init(
        outputURLs: [URL],
        readCount: Int,
        readNameFileURL: URL,
        singletonsURL: URL? = nil
    ) {
        self.outputURLs = outputURLs
        self.readCount = readCount
        self.readNameFileURL = readNameFileURL
        self.singletonsURL = singletonsURL
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
/// Serialized as JSON into the bundle's `extraction-metadata.json` file.
/// Core descriptive fields are required; parameters and provenance source URLs
/// can be empty when a caller has no additional context.
///
/// ## Thread Safety
///
/// `ExtractionMetadata` is a value type conforming to `Sendable` and `Codable`.
public struct ExtractionMetadata: Sendable, Codable {
    private enum CodingKeys: String, CodingKey {
        case sourceDescription
        case toolName
        case extractionDate
        case parameters
        case sourceURLs
    }

    /// Human-readable description of the data source (e.g. bundle display name).
    public let sourceDescription: String

    /// The name of the tool or classifier that produced the source data.
    public let toolName: String

    /// The date and time at which the extraction was performed.
    public let extractionDate: Date

    /// Arbitrary key–value parameters describing the extraction (e.g. tax IDs, regions).
    public let parameters: [String: String]

    /// Source files/directories that should be recorded as provenance inputs.
    public let sourceURLs: [URL]

    /// Creates extraction metadata.
    ///
    /// - Parameters:
    ///   - sourceDescription: Human-readable source description.
    ///   - toolName: Name of the tool that produced the source data.
    ///   - extractionDate: When the extraction was performed (default: now).
    ///   - parameters: Key–value extraction parameters for provenance.
    ///   - sourceURLs: Source files/directories to record as provenance inputs.
    public init(
        sourceDescription: String,
        toolName: String,
        extractionDate: Date = Date(),
        parameters: [String: String] = [:],
        sourceURLs: [URL] = []
    ) {
        self.sourceDescription = sourceDescription
        self.toolName = toolName
        self.extractionDate = extractionDate
        self.parameters = parameters
        self.sourceURLs = sourceURLs.map(\.standardizedFileURL)
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        sourceDescription = try container.decode(String.self, forKey: .sourceDescription)
        toolName = try container.decode(String.self, forKey: .toolName)
        extractionDate = try container.decode(Date.self, forKey: .extractionDate)
        parameters = try container.decodeIfPresent([String: String].self, forKey: .parameters) ?? [:]
        sourceURLs = try container.decodeIfPresent([URL].self, forKey: .sourceURLs) ?? []
    }

    /// Returns metadata with additional parameters, preserving existing values
    /// unless the added parameter intentionally replaces the same key.
    public func mergingParameters(_ additionalParameters: [String: String]) -> ExtractionMetadata {
        var merged = parameters
        for (key, value) in additionalParameters {
            merged[key] = value
        }
        return ExtractionMetadata(
            sourceDescription: sourceDescription,
            toolName: toolName,
            extractionDate: extractionDate,
            parameters: merged,
            sourceURLs: sourceURLs
        )
    }

    /// Returns metadata with provenance source URLs replaced by the supplied durable paths.
    public func recordingSourceURLs(_ urls: [URL]) -> ExtractionMetadata {
        ExtractionMetadata(
            sourceDescription: sourceDescription,
            toolName: toolName,
            extractionDate: extractionDate,
            parameters: parameters,
            sourceURLs: urls.map(\.standardizedFileURL)
        )
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

    // MARK: - Filename Sanitization

    /// Sanitises a raw string for use as a filename component.
    ///
    /// Replaces whitespace runs with underscores, strips characters that are not
    /// alphanumeric, dash, underscore, or dot, and truncates to 200 characters.
    public static func sanitizeFilename(_ raw: String) -> String {
        sanitize(raw)
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
    case explicitIndexRequired(URL)

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
        case .explicitIndexRequired(let url):
            return "An explicit index is required for \(url.lastPathComponent)"
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
