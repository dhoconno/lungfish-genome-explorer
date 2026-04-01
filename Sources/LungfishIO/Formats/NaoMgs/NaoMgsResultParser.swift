// NaoMgsResultParser.swift - Parser for NAO-MGS workflow results
// Copyright (c) 2025 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Owner: File Format Expert (Role 06)

import Foundation
import os.log

private let logger = Logger(subsystem: "com.lungfish.io", category: "NaoMgsResultParser")

// MARK: - NaoMgsError

/// Errors that can occur during NAO-MGS result parsing.
public enum NaoMgsError: Error, LocalizedError, Sendable {
    /// The input file was not found.
    case fileNotFound(URL)

    /// The TSV header is missing or does not contain expected columns.
    case invalidHeader(String)

    /// A data row could not be parsed.
    case malformedRow(lineNumber: Int, reason: String)

    /// The results directory does not contain the expected output files.
    case missingResultFiles(URL)

    /// SAM conversion failed.
    case samConversionFailed(String)

    public var errorDescription: String? {
        switch self {
        case .fileNotFound(let url):
            return "NAO-MGS result file not found: \(url.path)"
        case .invalidHeader(let details):
            return "Invalid NAO-MGS TSV header: \(details)"
        case .malformedRow(let line, let reason):
            return "Malformed row at line \(line): \(reason)"
        case .missingResultFiles(let url):
            return "No NAO-MGS result files found in: \(url.path)"
        case .samConversionFailed(let reason):
            return "SAM conversion failed: \(reason)"
        }
    }
}

// MARK: - NaoMgsVirusHit

/// A single virus hit from the NAO-MGS `virus_hits_final.tsv` output.
///
/// Each row represents one read that aligned to a viral reference genome.
/// The alignment details (CIGAR, coordinates) come from BLAST/bowtie2,
/// while the taxonomic assignment comes from Kraken2.
public struct NaoMgsVirusHit: Sendable, Codable, Equatable {

    /// Sample identifier from the workflow run.
    public let sample: String

    /// Read identifier (FASTQ header).
    public let seqId: String

    /// NCBI taxonomy ID of the assigned taxon.
    public let taxId: Int

    /// Best alignment score from the aligner.
    public let bestAlignmentScore: Double

    /// CIGAR string describing the alignment.
    public let cigar: String

    /// Start position on the query (read), 0-based.
    public let queryStart: Int

    /// End position on the query (read), 0-based.
    public let queryEnd: Int

    /// Start position on the reference, 0-based.
    public let refStart: Int

    /// End position on the reference, 0-based.
    public let refEnd: Int

    /// The full read sequence.
    public let readSequence: String

    /// The full read quality string (Phred+33).
    public let readQuality: String

    /// GenBank accession of the reference genome hit (e.g., "NC_045512.2").
    public let subjectSeqId: String

    /// Title/description of the reference genome.
    public let subjectTitle: String

    /// BLAST bit score.
    public let bitScore: Double

    /// BLAST e-value.
    public let eValue: Double

    /// Percent identity of the alignment.
    public let percentIdentity: Double

    /// Edit distance (number of mismatches) from the aligner (v2 format).
    ///
    /// Populated from `prim_align_edit_distance` in v2 TSV. Zero when not available.
    public let editDistance: Int

    /// Insert size / fragment length from paired-end alignment (v2 format).
    ///
    /// Populated from `prim_align_fragment_length` in v2 TSV. Zero when not available.
    public let fragmentLength: Int

    /// Whether the read was reverse-complemented for alignment (v2 format).
    ///
    /// Populated from `prim_align_query_rc` in v2 TSV (True/False string).
    public let isReverseComplement: Bool

    /// Pair status from the aligner: CP (concordant), DP (discordant), UU (unmapped), UP (unpaired).
    ///
    /// Populated from `prim_align_pair_status` in v2 TSV. Empty when not available.
    public let pairStatus: String

    /// Query (read) length in bases.
    ///
    /// Populated from `query_len` in v2 TSV, or derived from ``readSequence`` length.
    public let queryLength: Int

    /// Creates a new virus hit record.
    public init(
        sample: String,
        seqId: String,
        taxId: Int,
        bestAlignmentScore: Double,
        cigar: String,
        queryStart: Int,
        queryEnd: Int,
        refStart: Int,
        refEnd: Int,
        readSequence: String,
        readQuality: String,
        subjectSeqId: String,
        subjectTitle: String,
        bitScore: Double,
        eValue: Double,
        percentIdentity: Double,
        editDistance: Int = 0,
        fragmentLength: Int = 0,
        isReverseComplement: Bool = false,
        pairStatus: String = "",
        queryLength: Int = 0
    ) {
        self.sample = sample
        self.seqId = seqId
        self.taxId = taxId
        self.bestAlignmentScore = bestAlignmentScore
        self.cigar = cigar
        self.queryStart = queryStart
        self.queryEnd = queryEnd
        self.refStart = refStart
        self.refEnd = refEnd
        self.readSequence = readSequence
        self.readQuality = readQuality
        self.subjectSeqId = subjectSeqId
        self.subjectTitle = subjectTitle
        self.bitScore = bitScore
        self.eValue = eValue
        self.percentIdentity = percentIdentity
        self.editDistance = editDistance
        self.fragmentLength = fragmentLength
        self.isReverseComplement = isReverseComplement
        self.pairStatus = pairStatus
        self.queryLength = queryLength
    }
}

// MARK: - NaoMgsTaxonSummary

/// Aggregated statistics for a single taxon across all virus hits.
public struct NaoMgsTaxonSummary: Sendable, Codable, Equatable {
    /// NCBI taxonomy ID.
    public let taxId: Int

    /// Organism name (derived from the subject title).
    public let name: String

    /// Number of reads hitting this taxon.
    public let hitCount: Int

    /// Average percent identity across all hits for this taxon.
    public let avgIdentity: Double

    /// Average bit score across all hits for this taxon.
    public let avgBitScore: Double

    /// Average edit distance across all hits for this taxon (v2 format).
    public let avgEditDistance: Double

    /// Distinct GenBank accessions hit for this taxon.
    public let accessions: [String]

    /// Estimated PCR duplicate reads for this taxon.
    ///
    /// Computed by grouping alignments with identical accession/start/end/strand
    /// and counting all but the first hit in each group.
    public let pcrDuplicateCount: Int

    /// Estimated unique reads (`hitCount - pcrDuplicateCount`).
    public var uniqueReadCount: Int {
        max(0, hitCount - pcrDuplicateCount)
    }

    /// Creates a new taxon summary.
    public init(
        taxId: Int,
        name: String,
        hitCount: Int,
        avgIdentity: Double,
        avgBitScore: Double,
        avgEditDistance: Double = 0,
        accessions: [String],
        pcrDuplicateCount: Int = 0
    ) {
        self.taxId = taxId
        self.name = name
        self.hitCount = hitCount
        self.avgIdentity = avgIdentity
        self.avgBitScore = avgBitScore
        self.avgEditDistance = avgEditDistance
        self.accessions = accessions
        self.pcrDuplicateCount = max(0, min(pcrDuplicateCount, hitCount))
    }

    private enum CodingKeys: String, CodingKey {
        case taxId
        case name
        case hitCount
        case avgIdentity
        case avgBitScore
        case avgEditDistance
        case accessions
        case pcrDuplicateCount
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        taxId = try container.decode(Int.self, forKey: .taxId)
        name = try container.decode(String.self, forKey: .name)
        hitCount = try container.decode(Int.self, forKey: .hitCount)
        avgIdentity = try container.decode(Double.self, forKey: .avgIdentity)
        avgBitScore = try container.decode(Double.self, forKey: .avgBitScore)
        avgEditDistance = try container.decode(Double.self, forKey: .avgEditDistance)
        accessions = try container.decode([String].self, forKey: .accessions)
        let decodedDupCount = try container.decodeIfPresent(Int.self, forKey: .pcrDuplicateCount) ?? 0
        pcrDuplicateCount = max(0, min(decodedDupCount, hitCount))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(taxId, forKey: .taxId)
        try container.encode(name, forKey: .name)
        try container.encode(hitCount, forKey: .hitCount)
        try container.encode(avgIdentity, forKey: .avgIdentity)
        try container.encode(avgBitScore, forKey: .avgBitScore)
        try container.encode(avgEditDistance, forKey: .avgEditDistance)
        try container.encode(accessions, forKey: .accessions)
        try container.encode(pcrDuplicateCount, forKey: .pcrDuplicateCount)
    }
}

// MARK: - NaoMgsResult

/// Aggregated results from a NAO-MGS workflow run.
///
/// Contains the per-read virus hits, taxon-level summaries, and metadata
/// about the source directory and sample.
public struct NaoMgsResult: Sendable {
    /// Per-read virus hits.
    public let virusHits: [NaoMgsVirusHit]

    /// Summary statistics grouped by taxon, sorted by hit count descending.
    public let taxonSummaries: [NaoMgsTaxonSummary]

    /// Total reads with virus hits.
    public let totalHitReads: Int

    /// Sample name (from the first hit, or user-provided).
    public let sampleName: String

    /// Source directory of the results.
    public let sourceDirectory: URL

    /// Path to the virus_hits_final.tsv(.gz) file that was parsed.
    public let virusHitsFile: URL

    /// Creates a new NAO-MGS result set.
    public init(
        virusHits: [NaoMgsVirusHit],
        taxonSummaries: [NaoMgsTaxonSummary],
        totalHitReads: Int,
        sampleName: String,
        sourceDirectory: URL,
        virusHitsFile: URL
    ) {
        self.virusHits = virusHits
        self.taxonSummaries = taxonSummaries
        self.totalHitReads = totalHitReads
        self.sampleName = sampleName
        self.sourceDirectory = sourceDirectory
        self.virusHitsFile = virusHitsFile
    }
}

// MARK: - NaoMgsResultParser

/// Parser for NAO-MGS metagenomic surveillance pipeline results.
///
/// Parses the primary `virus_hits_final.tsv.gz` output file produced by the
/// [nao-mgs-workflow](https://github.com/securebio/nao-mgs-workflow). The parser
/// handles both plain TSV and gzip-compressed TSV files.
///
/// ## Usage
///
/// ```swift
/// let parser = NaoMgsResultParser()
///
/// // Parse a single file
/// let hits = try await parser.parseVirusHits(at: virusHitsURL)
///
/// // Load a complete result set from a directory
/// let result = try await parser.loadResults(from: resultsDir, sampleName: "sample1")
///
/// // Convert hits to SAM for viewport display
/// try parser.convertToSAM(hits: hits, outputURL: samOutputURL)
/// ```
///
/// ## Column Mapping
///
/// The parser auto-detects column positions from the TSV header, so it is
/// resilient to column reordering. Missing optional columns produce empty
/// strings or zero values rather than parse errors.
public final class NaoMgsResultParser: @unchecked Sendable {

    /// Required columns -- at least `seq_id` and `sample` must be present.
    /// Taxonomy ID can come from `taxid` OR `aligner_taxid_lca`.
    private static let requiredColumns: Set<String> = [
        "sample", "seq_id"
    ]

    /// Maps header names to their column indices.
    ///
    /// Supports both the original NAO-MGS column names (v1.x with `taxid`,
    /// `sseqid`, `cigar`, etc.) and the current format (v2.x with
    /// `aligner_taxid_lca`, `prim_align_genome_id_all`, etc.).
    private struct ColumnMap {
        let sample: Int
        let seqId: Int
        let taxId: Int
        let bestAlignmentScore: Int?
        let cigar: Int?
        let queryStart: Int?
        let queryEnd: Int?
        let refStart: Int?
        let refEnd: Int?
        let readSequence: Int?
        let readQuality: Int?
        let subjectSeqId: Int?
        let subjectTitle: Int?
        let bitScore: Int?
        let eValue: Int?
        let percentIdentity: Int?
        // v2 columns
        let queryLen: Int?
        let queryRC: Int?
        let editDistance: Int?
        let fragmentLength: Int?
        let pairStatus: Int?

        init(headers: [String]) throws {
            var map: [String: Int] = [:]
            for (index, header) in headers.enumerated() {
                map[header.lowercased().trimmingCharacters(in: .whitespaces)] = index
            }

            // Validate required columns
            for required in NaoMgsResultParser.requiredColumns {
                guard map[required] != nil else {
                    throw NaoMgsError.invalidHeader(
                        "Missing required column '\(required)'. Found: \(headers.joined(separator: ", "))"
                    )
                }
            }

            // Taxonomy ID: try `taxid` first, then `aligner_taxid_lca`, then `aligner_taxid_top`
            guard let taxIdIdx = map["taxid"] ?? map["aligner_taxid_lca"] ?? map["aligner_taxid_top"] else {
                throw NaoMgsError.invalidHeader(
                    "Missing taxonomy column. Need 'taxid', 'aligner_taxid_lca', or 'aligner_taxid_top'. Found: \(headers.joined(separator: ", "))"
                )
            }

            self.sample = map["sample"]!
            self.seqId = map["seq_id"]!
            self.taxId = taxIdIdx

            // Alignment score: v1 `best_alignment_score` or v2 `prim_align_best_alignment_score`
            self.bestAlignmentScore = map["best_alignment_score"]
                ?? map["prim_align_best_alignment_score"]
                ?? map["aligner_length_normalized_score_mean"]

            // CIGAR: v1 `cigar` or newer v2 `prim_align_cigar`
            self.cigar = map["cigar"] ?? map["prim_align_cigar"]

            // Query coordinates: v1 only
            self.queryStart = map["query_start"]
            self.queryEnd = map["query_end"]

            // Reference start: v1 `ref_start` or v2 `prim_align_ref_start`
            self.refStart = map["ref_start"] ?? map["prim_align_ref_start"]
            self.refEnd = map["ref_end"]

            // Sequence and quality: v1 `read_sequence`/`read_quality` or v2 `query_seq`/`query_qual`
            self.readSequence = map["read_sequence"] ?? map["query_seq"]
            self.readQuality = map["read_quality"] ?? map["query_qual"]

            // Subject/reference ID: v1 `sseqid` or v2 `prim_align_genome_id_all`
            self.subjectSeqId = map["sseqid"] ?? map["prim_align_genome_id_all"]

            // Subject title: v1 only
            self.subjectTitle = map["stitle"]

            // BLAST scores: v1 only (v2 uses alignment scores instead)
            self.bitScore = map["bitscore"]
            self.eValue = map["evalue"]
            self.percentIdentity = map["pident"]

            // v2-specific columns
            self.queryLen = map["query_len"]
            self.queryRC = map["prim_align_query_rc"]
            self.editDistance = map["prim_align_edit_distance"]
            self.fragmentLength = map["prim_align_fragment_length"]
            self.pairStatus = map["prim_align_pair_status"]
        }
    }

    public init() {}

    // MARK: - Parsing

    /// Parses a `virus_hits_final.tsv(.gz)` file into an array of virus hits.
    ///
    /// The parser streams the file line-by-line for memory efficiency.
    /// Gzip-compressed files are auto-detected by the `.gz` extension.
    ///
    /// - Parameter url: Path to the virus_hits_final.tsv or .tsv.gz file.
    /// - Returns: Array of parsed virus hits.
    /// - Throws: ``NaoMgsError`` if the file is missing or malformed.
    public func parseVirusHits(
        at url: URL,
        lineProgress: (@Sendable (Int) -> Void)? = nil
    ) async throws -> [NaoMgsVirusHit] {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw NaoMgsError.fileNotFound(url)
        }

        logger.info("Parsing NAO-MGS virus hits from \(url.lastPathComponent)")

        var hits: [NaoMgsVirusHit] = []
        var columnMap: ColumnMap?
        var lineNumber = 0

        for try await line in url.linesAutoDecompressing() {
            lineNumber += 1

            if lineProgress != nil, lineNumber % 1000 == 0 {
                lineProgress?(lineNumber)
            }

            // Skip empty lines
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { continue }

            // First non-empty line is the header
            if columnMap == nil {
                let headers = trimmed.split(separator: "\t", omittingEmptySubsequences: false)
                    .map { String($0) }
                columnMap = try ColumnMap(headers: headers)
                continue
            }

            // Parse data row
            let fields = trimmed.split(separator: "\t", omittingEmptySubsequences: false)
                .map { String($0) }

            guard let map = columnMap else { continue }

            // Require at least enough fields for the required columns
            let minFields = max(map.sample, map.seqId, map.taxId) + 1
            guard fields.count >= minFields else {
                logger.warning("Skipping line \(lineNumber): only \(fields.count) fields, need \(minFields)")
                continue
            }

            let taxIdStr = fields[map.taxId]
            guard let taxId = Int(taxIdStr) else {
                // Some rows may have "NA" for taxonomy -- skip them
                if taxIdStr != "NA" {
                    logger.warning("Skipping line \(lineNumber): invalid taxid '\(taxIdStr)'")
                }
                continue
            }

            // For v2 format, synthesize a CIGAR from query_len if no explicit cigar column
            var cigar = stringField(fields, map.cigar)
            if cigar.isEmpty {
                let queryLen = intField(fields, map.queryLen)
                if queryLen > 0 {
                    cigar = "\(queryLen)M"  // Simple full-length match
                }
            }

            // For v2 format, derive alignment score from available fields
            let alignScore = doubleField(fields, map.bestAlignmentScore)
            // Use alignment score as proxy for bit score if no explicit bitscore column
            let bitScore = doubleField(fields, map.bitScore)
            let effectiveBitScore = bitScore > 0 ? bitScore : alignScore

            // Parse v2 fields
            let editDist = intField(fields, map.editDistance)
            let fragLen = intField(fields, map.fragmentLength)
            let rcStr = stringField(fields, map.queryRC).lowercased()
            let isRC = rcStr == "true" || rcStr == "1"
            let pairStat = stringField(fields, map.pairStatus)
            let qLen = intField(fields, map.queryLen)

            let readSeq = stringField(fields, map.readSequence)

            let hit = NaoMgsVirusHit(
                sample: fields[map.sample],
                seqId: fields[map.seqId],
                taxId: taxId,
                bestAlignmentScore: alignScore,
                cigar: cigar,
                queryStart: intField(fields, map.queryStart),
                queryEnd: intField(fields, map.queryEnd),
                refStart: intField(fields, map.refStart),
                refEnd: intField(fields, map.refEnd),
                readSequence: readSeq,
                readQuality: stringField(fields, map.readQuality),
                subjectSeqId: stringField(fields, map.subjectSeqId),
                subjectTitle: stringField(fields, map.subjectTitle),
                bitScore: effectiveBitScore,
                eValue: doubleField(fields, map.eValue),
                percentIdentity: {
                    // v1 format has explicit pident column; v2 derives from edit distance
                    let pident = doubleField(fields, map.percentIdentity)
                    if pident > 0 { return pident }
                    // Derive identity from edit distance: identity = (1 - editDist/queryLen) * 100
                    let effectiveLen = qLen > 0 ? qLen : readSeq.count
                    guard effectiveLen > 0 else { return 0 }
                    return max(0, (1.0 - Double(editDist) / Double(effectiveLen)) * 100.0)
                }(),
                editDistance: editDist,
                fragmentLength: fragLen,
                isReverseComplement: isRC,
                pairStatus: pairStat,
                queryLength: qLen > 0 ? qLen : readSeq.count
            )
            hits.append(hit)
        }

        lineProgress?(lineNumber)
        logger.info("Parsed \(hits.count) virus hits from \(url.lastPathComponent)")
        return hits
    }

    /// Loads a complete NAO-MGS result set from a directory.
    ///
    /// Searches for `virus_hits_final.tsv.gz` (or `.tsv`) in the directory,
    /// parses it, and aggregates results by taxon.
    ///
    /// - Parameters:
    ///   - directory: Path to the NAO-MGS output directory.
    ///   - sampleName: Sample name override. If nil, derived from the first hit.
    /// - Returns: Aggregated ``NaoMgsResult``.
    /// - Throws: ``NaoMgsError`` if no result files are found.
    public func loadResults(
        from directory: URL,
        sampleName: String? = nil,
        lineProgress: (@Sendable (Int) -> Void)? = nil
    ) async throws -> NaoMgsResult {
        let fm = FileManager.default

        // If the user passed a file directly (not a directory), use it
        var isDir: ObjCBool = false
        let virusHitsFile: URL
        if fm.fileExists(atPath: directory.path, isDirectory: &isDir), !isDir.boolValue {
            // It's a file, not a directory
            virusHitsFile = directory
        } else {
            // Search for virus_hits files in the directory
            // Try standard name first, then any *virus_hits*.tsv.gz pattern
            let candidates = [
                directory.appendingPathComponent("virus_hits_final.tsv.gz"),
                directory.appendingPathComponent("virus_hits_final.tsv"),
            ]

            if let found = candidates.first(where: { fm.fileExists(atPath: $0.path) }) {
                virusHitsFile = found
            } else if let contents = try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil),
                      let match = contents.first(where: {
                          let name = $0.lastPathComponent.lowercased()
                          return name.contains("virus_hits") && (name.hasSuffix(".tsv") || name.hasSuffix(".tsv.gz"))
                      }) {
                virusHitsFile = match
            } else {
                throw NaoMgsError.missingResultFiles(directory)
            }
        }

        let hits = try await parseVirusHits(at: virusHitsFile, lineProgress: lineProgress)

        let resolvedSampleName = sampleName
            ?? hits.first?.sample
            ?? directory.lastPathComponent

        let summaries = aggregateByTaxon(hits)

        return NaoMgsResult(
            virusHits: hits,
            taxonSummaries: summaries,
            totalHitReads: hits.count,
            sampleName: resolvedSampleName,
            sourceDirectory: directory,
            virusHitsFile: virusHitsFile
        )
    }

    // MARK: - SAM Conversion

    /// Converts NAO-MGS virus hits into a SAM file for display in the alignment viewer.
    ///
    /// Groups hits by reference accession, writes proper @HD and @SQ header lines,
    /// and creates alignment records from the CIGAR, sequence, and quality data.
    ///
    /// - Parameters:
    ///   - hits: Array of virus hits to convert.
    ///   - outputURL: Path to write the SAM file.
    /// - Throws: ``NaoMgsError/samConversionFailed(_:)`` if writing fails.
    public func convertToSAM(hits: [NaoMgsVirusHit], outputURL: URL) throws {
        guard !hits.isEmpty else {
            throw NaoMgsError.samConversionFailed("No hits to convert")
        }

        logger.info("Converting \(hits.count) NAO-MGS hits to SAM at \(outputURL.lastPathComponent)")

        // Group hits by reference accession to build @SQ lines.
        // Track the maximum reference end position per accession for the sequence length.
        var refLengths: [String: Int] = [:]
        var refTitles: [String: String] = [:]

        for hit in hits {
            guard !hit.subjectSeqId.isEmpty else { continue }
            let currentMax = refLengths[hit.subjectSeqId] ?? 0
            // Estimate reference length from refStart + read length (refEnd may be 0 in v2)
            let estimatedEnd = hit.refEnd > 0
                ? hit.refEnd + 1
                : hit.refStart + max(hit.readSequence.count, hit.queryStart) + 1
            refLengths[hit.subjectSeqId] = max(currentMax, estimatedEnd)
            if refTitles[hit.subjectSeqId] == nil {
                refTitles[hit.subjectSeqId] = hit.subjectTitle
            }
        }

        var samLines: [String] = []

        // @HD header
        samLines.append("@HD\tVN:1.6\tSO:unsorted")

        // @SQ header lines, sorted by accession for deterministic output
        for accession in refLengths.keys.sorted() {
            let length = refLengths[accession] ?? 1
            // Use at least 1 for length, and pad slightly to account for alignment overhangs
            let paddedLength = max(length, 1)
            samLines.append("@SQ\tSN:\(accession)\tLN:\(paddedLength)")
        }

        // @RG header for the sample
        if let firstSample = hits.first?.sample {
            samLines.append("@RG\tID:\(firstSample)\tSM:\(firstSample)")
        }

        // @PG header
        samLines.append("@PG\tID:nao-mgs\tPN:nao-mgs-workflow\tVN:1.0")

        // Alignment records
        for hit in hits {
            let refName = hit.subjectSeqId.isEmpty ? "*" : hit.subjectSeqId
            let cigar = hit.cigar.isEmpty ? "*" : hit.cigar
            let sequence = hit.readSequence.isEmpty ? "*" : hit.readSequence
            let quality = hit.readQuality.isEmpty ? "*" : hit.readQuality

            // FLAG: 16 = reverse strand, 0 = forward strand.
            let flag = hit.isReverseComplement ? 16 : 0

            // POS is 1-based in SAM (NAO-MGS refStart is 0-based)
            let pos = hit.refStart + 1

            // MAPQ: derive from bit score (capped at 60)
            let mapq = min(Int(hit.bitScore / 5.0), 60)

            // RNEXT, PNEXT, TLEN are unknown for single-end virus hits
            let record = [
                hit.seqId,              // QNAME
                String(flag),           // FLAG
                refName,                // RNAME
                String(pos),            // POS
                String(mapq),           // MAPQ
                cigar,                  // CIGAR
                "*",                    // RNEXT
                "0",                    // PNEXT
                "0",                    // TLEN
                sequence,               // SEQ
                quality,                // QUAL
                "RG:Z:\(hit.sample)",   // Read group tag
                "XI:f:\(String(format: "%.1f", hit.percentIdentity))",  // Percent identity
                "XS:f:\(String(format: "%.1f", hit.bitScore))",         // Bit score
                "XE:f:\(hit.eValue)",   // E-value
                "XT:i:\(hit.taxId)",    // Taxonomy ID
                "NM:i:\(hit.editDistance)",  // Edit distance
            ].joined(separator: "\t")

            samLines.append(record)
        }

        // Write SAM file
        let content = samLines.joined(separator: "\n") + "\n"
        guard let data = content.data(using: .utf8) else {
            throw NaoMgsError.samConversionFailed("Failed to encode SAM content as UTF-8")
        }

        do {
            try data.write(to: outputURL, options: .atomic)
        } catch {
            throw NaoMgsError.samConversionFailed("Failed to write SAM file: \(error.localizedDescription)")
        }

        logger.info("Wrote SAM file with \(hits.count) alignments across \(refLengths.count) references")
    }

    // MARK: - Aggregation

    /// Aggregates virus hits by taxonomy ID into per-taxon summaries.
    ///
    /// - Parameter hits: Array of virus hits to aggregate.
    /// - Returns: Array of taxon summaries sorted by hit count descending.
    public func aggregateByTaxon(_ hits: [NaoMgsVirusHit]) -> [NaoMgsTaxonSummary] {
        // Group by taxId
        var groups: [Int: [NaoMgsVirusHit]] = [:]
        for hit in hits {
            groups[hit.taxId, default: []].append(hit)
        }

        let summaries: [NaoMgsTaxonSummary] = groups.map { taxId, taxHits in
            // Use explicit percentIdentity when available (v1 format); otherwise
            // derive from edit distance: identity = (1 - editDist/queryLen) * 100.
            let totalIdentity = taxHits.reduce(0.0) { sum, hit in
                if hit.percentIdentity > 0 { return sum + hit.percentIdentity }
                let len = hit.queryLength > 0 ? hit.queryLength : hit.readSequence.count
                guard len > 0 else { return sum }
                return sum + max(0, (1.0 - Double(hit.editDistance) / Double(len)) * 100.0)
            }
            let totalBitScore = taxHits.reduce(0.0) { $0 + $1.bitScore }
            let totalEditDistance = taxHits.reduce(0) { $0 + $1.editDistance }
            let accessions = Array(Set(taxHits.map(\.subjectSeqId).filter { !$0.isEmpty })).sorted()
            let duplicateCount = estimatePCRDuplicateCount(for: taxHits)

            // Derive the organism name from the first subject title.
            // NAO-MGS stitle often has the format "Accession Description Species"
            let name = taxHits.first?.subjectTitle ?? "Unknown (taxid: \(taxId))"

            return NaoMgsTaxonSummary(
                taxId: taxId,
                name: name,
                hitCount: taxHits.count,
                avgIdentity: taxHits.isEmpty ? 0 : totalIdentity / Double(taxHits.count),
                avgBitScore: taxHits.isEmpty ? 0 : totalBitScore / Double(taxHits.count),
                avgEditDistance: taxHits.isEmpty ? 0 : Double(totalEditDistance) / Double(taxHits.count),
                accessions: accessions,
                pcrDuplicateCount: duplicateCount
            )
        }

        return summaries.sorted { $0.hitCount > $1.hitCount }
    }

    /// Estimates PCR duplicates from NAO-MGS hits by grouping identical alignments.
    ///
    /// Uses the same basic heuristic as miniBAM duplicate visualization:
    /// alignments with identical accession/start/end/strand are considered
    /// duplicates, and all but one in each group are counted as PCR dups.
    private func estimatePCRDuplicateCount(for hits: [NaoMgsVirusHit]) -> Int {
        guard !hits.isEmpty else { return 0 }

        var groups: [String: Int] = [:]
        for hit in hits {
            let strand = hit.isReverseComplement ? "R" : "F"
            let readLength = hit.queryLength > 0 ? hit.queryLength : max(0, hit.readSequence.count)
            let inferredRefEnd = max(hit.refEnd, hit.refStart + max(1, readLength))
            let key = "\(hit.subjectSeqId)|\(hit.refStart)|\(inferredRefEnd)|\(strand)"
            groups[key, default: 0] += 1
        }

        return groups.values.reduce(0) { sum, count in
            sum + max(0, count - 1)
        }
    }

    // MARK: - Field Helpers

    /// Safely extracts a string field from the row, returning empty string if missing.
    private func stringField(_ fields: [String], _ index: Int?) -> String {
        guard let idx = index, idx < fields.count else { return "" }
        return fields[idx]
    }

    /// Safely extracts an integer field, returning 0 if missing or unparseable.
    private func intField(_ fields: [String], _ index: Int?) -> Int {
        guard let idx = index, idx < fields.count else { return 0 }
        return Int(fields[idx]) ?? 0
    }

    /// Safely extracts a double field, returning 0.0 if missing or unparseable.
    private func doubleField(_ fields: [String], _ index: Int?) -> Double {
        guard let idx = index, idx < fields.count else { return 0.0 }
        return Double(fields[idx]) ?? 0.0
    }
}
