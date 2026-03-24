// BlastResult.swift - BLAST result data models
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation

// MARK: - Per-Read Verdict

/// Classification of a single read's BLAST verification outcome.
///
/// Each verdict is determined by comparing the top BLAST hit against
/// identity, coverage, and E-value thresholds. See ``BlastReadResult/verdict``
/// for the logic that assigns verdicts.
public enum BlastVerdict: String, Sendable, Codable, CaseIterable {

    /// The read's top hit has >= 90% identity AND >= 80% query coverage
    /// to the target taxon, with E-value <= the threshold.
    case verified

    /// A hit was found but does not meet the full verification thresholds.
    /// This may indicate partial matches, short alignments, or multiple
    /// organisms with nearly equal scores.
    case ambiguous

    /// No significant hit was found within the target taxon at the
    /// configured E-value threshold. The read may be misclassified,
    /// novel, or from a divergent strain.
    case unverified

    /// BLAST failed for this read (e.g., parse error, no results returned
    /// due to a server issue).
    case error
}

// MARK: - Hit Summary

/// Lightweight summary of a single BLAST hit for display in the UI.
///
/// Each ``BlastHitSummary`` captures the key alignment statistics for one
/// database hit, ranked within a read's hit list. Up to 5 summaries are
/// stored per ``BlastReadResult`` for multi-hit inspection.
public struct BlastHitSummary: Sendable, Codable, Identifiable {

    /// Unique identifier derived from the accession.
    public var id: String { accession }

    /// 1-based rank within the read's hits (1 = best hit).
    public let rank: Int

    /// GenBank accession of the hit sequence.
    public let accession: String

    /// Organism name from the hit description, if available.
    public let organism: String?

    /// NCBI taxonomy ID from the hit description, if available.
    public let taxId: Int?

    /// Percent identity of the best HSP for this hit (0-100).
    public let percentIdentity: Double

    /// Query coverage percentage (0-100).
    public let queryCoverage: Double

    /// E-value of the best HSP for this hit.
    public let eValue: Double

    /// Bit score of the best HSP for this hit.
    public let bitScore: Double

    /// Alignment length of the best HSP in base pairs.
    public let alignmentLength: Int

    /// Creates a BLAST hit summary.
    ///
    /// - Parameters:
    ///   - rank: 1-based rank within the read's hits
    ///   - accession: GenBank accession
    ///   - organism: Organism name
    ///   - taxId: NCBI taxonomy ID
    ///   - percentIdentity: Percent identity (0-100)
    ///   - queryCoverage: Query coverage (0-100)
    ///   - eValue: E-value
    ///   - bitScore: Bit score
    ///   - alignmentLength: Alignment length in bp
    public init(
        rank: Int,
        accession: String,
        organism: String?,
        taxId: Int?,
        percentIdentity: Double,
        queryCoverage: Double,
        eValue: Double,
        bitScore: Double,
        alignmentLength: Int
    ) {
        self.rank = rank
        self.accession = accession
        self.organism = organism
        self.taxId = taxId
        self.percentIdentity = percentIdentity
        self.queryCoverage = queryCoverage
        self.eValue = eValue
        self.bitScore = bitScore
        self.alignmentLength = alignmentLength
    }
}

// MARK: - Per-Read Result

/// Result of a BLAST verification for a single read.
///
/// Each read submitted to BLAST produces one ``BlastReadResult`` containing
/// the verdict, the top hit's metadata, and alignment statistics.
///
/// ## Verdict Assignment
///
/// The verdict is computed from alignment statistics:
///
/// | Verdict | Criteria |
/// |---------|----------|
/// | `.verified` | >= 90% identity AND >= 80% query coverage AND E-value <= threshold |
/// | `.ambiguous` | Hit found but thresholds not fully met |
/// | `.unverified` | No significant hit within the target taxon |
/// | `.error` | BLAST failed for this read |
public struct BlastReadResult: Sendable, Codable, Identifiable {

    /// The read identifier (matches the FASTA header submitted to BLAST).
    public let id: String

    /// The verification verdict for this read.
    public let verdict: BlastVerdict

    /// Organism name of the top BLAST hit, if any.
    public let topHitOrganism: String?

    /// GenBank accession of the top BLAST hit, if any.
    public let topHitAccession: String?

    /// Percent identity of the best alignment (0-100).
    public let percentIdentity: Double?

    /// Fraction of the query sequence covered by the alignment (0-100).
    public let queryCoverage: Double?

    /// E-value of the best alignment.
    public let eValue: Double?

    /// Length of the best alignment in base pairs.
    public let alignmentLength: Int?

    /// Bit score of the best alignment.
    public let bitScore: Double?

    /// Up to 5 top hits sorted by E-value, for multi-hit inspection.
    public let topHits: [BlastHitSummary]

    /// The original query sequence submitted to BLAST (for FASTA copy).
    public let querySequence: String?

    /// Whether the top hits disagree at genus level, indicating possible
    /// taxonomic ambiguity (LCA disagreement).
    public let hasLCADisagreement: Bool

    /// Whether the top BLAST hit organism matches the queried (Kraken2-classified)
    /// taxon at the genus level.
    ///
    /// `true` when the first word (genus) of the top hit organism matches the
    /// first word of the queried taxon name, or when the top hit organism name
    /// contains the queried taxon name (for virus names that are not binomial).
    /// `false` when there is a high-quality hit to a different organism, or
    /// when there is no hit at all.
    public let matchesQueriedTaxon: Bool

    /// Creates a new per-read BLAST result.
    ///
    /// - Parameters:
    ///   - id: Read identifier
    ///   - verdict: Verification verdict
    ///   - topHitOrganism: Organism name of best hit
    ///   - topHitAccession: Accession of best hit
    ///   - percentIdentity: Percent identity (0-100)
    ///   - queryCoverage: Query coverage percentage (0-100)
    ///   - eValue: E-value of best hit
    ///   - alignmentLength: Alignment length in bp
    ///   - bitScore: Bit score of best hit
    ///   - topHits: Up to 5 top hits sorted by E-value
    ///   - querySequence: The original query sequence
    ///   - hasLCADisagreement: Whether top hits disagree at genus level
    ///   - matchesQueriedTaxon: Whether top hit matches the queried taxon
    public init(
        id: String,
        verdict: BlastVerdict,
        topHitOrganism: String? = nil,
        topHitAccession: String? = nil,
        percentIdentity: Double? = nil,
        queryCoverage: Double? = nil,
        eValue: Double? = nil,
        alignmentLength: Int? = nil,
        bitScore: Double? = nil,
        topHits: [BlastHitSummary] = [],
        querySequence: String? = nil,
        hasLCADisagreement: Bool = false,
        matchesQueriedTaxon: Bool = false
    ) {
        self.id = id
        self.verdict = verdict
        self.topHitOrganism = topHitOrganism
        self.topHitAccession = topHitAccession
        self.percentIdentity = percentIdentity
        self.queryCoverage = queryCoverage
        self.eValue = eValue
        self.alignmentLength = alignmentLength
        self.bitScore = bitScore
        self.topHits = topHits
        self.querySequence = querySequence
        self.hasLCADisagreement = hasLCADisagreement
        self.matchesQueriedTaxon = matchesQueriedTaxon
    }
}

// MARK: - Verification Summary

/// Summary of BLAST verification across all submitted reads.
///
/// This aggregates individual ``BlastReadResult`` entries into an overall
/// confidence assessment. The confidence level is based on whether the
/// BLAST hits match the Kraken2-classified taxon, not just whether reads
/// have high-identity alignments.
///
/// ## Confidence Levels
///
/// | Level | Criteria |
/// |-------|----------|
/// | `.supported` | >= 80% of significant hits match the queried taxon |
/// | `.mixed` | 40-79% of significant hits match |
/// | `.unsupported` | < 40% match, or most hits are to different organisms |
/// | `.inconclusive` | No significant hits found at all |
public struct BlastVerificationResult: Sendable, Codable {

    /// The taxon name that was verified (e.g., "Oxbow virus").
    public let taxonName: String

    /// The NCBI taxonomy ID of the target taxon.
    public let taxId: Int

    /// Total number of reads submitted for verification.
    public let totalReads: Int

    /// Number of reads with `.verified` verdict.
    public let verifiedCount: Int

    /// Number of reads with `.ambiguous` verdict.
    public let ambiguousCount: Int

    /// Number of reads with `.unverified` verdict.
    public let unverifiedCount: Int

    /// Number of reads with `.error` verdict.
    public let errorCount: Int

    /// Individual results for each submitted read.
    public let readResults: [BlastReadResult]

    /// When the BLAST job was submitted to NCBI.
    public let submittedAt: Date

    /// When the BLAST job completed, or `nil` if still running.
    public let completedAt: Date?

    /// The NCBI Request ID for this BLAST job.
    ///
    /// Users can check results manually at:
    /// `https://blast.ncbi.nlm.nih.gov/Blast.cgi?CMD=Get&RID=<rid>`
    public let rid: String

    /// The BLAST program used (e.g., "blastn").
    public let blastProgram: String

    /// The BLAST database searched (e.g., "nt").
    public let database: String

    /// The fraction of reads that were verified (0.0-1.0).
    ///
    /// Returns 0 if no reads were submitted. Note: This measures alignment
    /// quality only, not whether hits match the queried taxon. Use
    /// ``confidence`` for the taxon-aware assessment.
    public var verificationRate: Double {
        totalReads > 0 ? Double(verifiedCount) / Double(totalReads) : 0
    }

    /// Number of reads where the top hits disagree at genus level (LCA disagreement).
    ///
    /// A high count indicates taxonomic ambiguity in the BLAST results,
    /// suggesting the reads may match multiple genera equally well.
    public var lcaDisagreementCount: Int {
        readResults.filter(\.hasLCADisagreement).count
    }

    /// Number of reads whose top BLAST hit matches the queried taxon
    /// (same genus or name containment).
    ///
    /// A "supporting" read has a significant hit AND that hit's organism
    /// matches the Kraken2-classified taxon.
    public var supportingCount: Int {
        readResults.filter { $0.verdict == .verified && $0.matchesQueriedTaxon }.count
    }

    /// Number of reads whose top BLAST hit is a significant match to a
    /// DIFFERENT organism than the queried taxon.
    ///
    /// These reads actively contradict the Kraken2 classification --
    /// the sequences are real but belong to something else.
    public var contradictingCount: Int {
        readResults.filter { $0.verdict == .verified && !$0.matchesQueriedTaxon }.count
    }

    /// Number of reads with no significant BLAST hit, or with ambiguous/error results.
    ///
    /// These reads neither support nor contradict the classification.
    public var inconclusiveCount: Int {
        totalReads - supportingCount - contradictingCount
    }

    /// The fraction of reads with significant hits that support the queried taxon (0.0-1.0).
    ///
    /// Only reads with significant hits (verified verdict) are counted in
    /// the denominator. Returns 0 if no reads had significant hits.
    public var supportRate: Double {
        let significantHits = supportingCount + contradictingCount
        guard significantHits > 0 else { return 0 }
        return Double(supportingCount) / Double(significantHits)
    }

    /// Overall confidence that the Kraken2 classification is correct,
    /// based on whether BLAST hits match the queried taxon.
    ///
    /// ## Confidence Levels
    ///
    /// | Level | Criteria |
    /// |-------|----------|
    /// | `.supported` | >= 80% of significant hits match the queried taxon |
    /// | `.mixed` | 40-79% of significant hits match |
    /// | `.unsupported` | < 40% match, or most hits are to different organisms |
    /// | `.inconclusive` | No significant hits found at all |
    public enum Confidence: String, Sendable, Codable {
        /// >= 80% of reads with significant hits match the queried taxon
        case supported
        /// 40-79% of reads with significant hits match
        case mixed
        /// < 40% of reads match, or most hits are to different organisms
        case unsupported
        /// No significant hits found at all
        case inconclusive
    }

    /// The computed confidence level based on taxon-match rate among
    /// reads with significant BLAST hits.
    ///
    /// This measures whether BLAST results SUPPORT the Kraken2 classification,
    /// not just whether reads have high-identity hits. A read with 100% identity
    /// to a different organism contradicts the classification.
    public var confidence: Confidence {
        let significantHits = supportingCount + contradictingCount
        guard significantHits > 0 else {
            return .inconclusive
        }
        let rate = supportRate
        if rate >= 0.8 {
            return .supported
        } else if rate >= 0.4 {
            return .mixed
        } else {
            return .unsupported
        }
    }

    /// Creates a new BLAST verification result summary.
    ///
    /// - Parameters:
    ///   - taxonName: Name of the target taxon
    ///   - taxId: NCBI taxonomy ID
    ///   - totalReads: Number of reads submitted
    ///   - verifiedCount: Reads with verified verdict
    ///   - ambiguousCount: Reads with ambiguous verdict
    ///   - unverifiedCount: Reads with unverified verdict
    ///   - errorCount: Reads with error verdict
    ///   - readResults: Individual read results
    ///   - submittedAt: When the job was submitted
    ///   - completedAt: When the job completed
    ///   - rid: NCBI Request ID
    ///   - blastProgram: Program used (e.g., "blastn")
    ///   - database: Database searched (e.g., "nt")
    public init(
        taxonName: String,
        taxId: Int,
        totalReads: Int,
        verifiedCount: Int,
        ambiguousCount: Int,
        unverifiedCount: Int,
        errorCount: Int,
        readResults: [BlastReadResult],
        submittedAt: Date,
        completedAt: Date?,
        rid: String,
        blastProgram: String,
        database: String
    ) {
        self.taxonName = taxonName
        self.taxId = taxId
        self.totalReads = totalReads
        self.verifiedCount = verifiedCount
        self.ambiguousCount = ambiguousCount
        self.unverifiedCount = unverifiedCount
        self.errorCount = errorCount
        self.readResults = readResults
        self.submittedAt = submittedAt
        self.completedAt = completedAt
        self.rid = rid
        self.blastProgram = blastProgram
        self.database = database
    }

    /// Creates a verification result from an array of read results.
    ///
    /// Automatically computes verified/ambiguous/unverified/error counts
    /// from the read results array.
    ///
    /// - Parameters:
    ///   - taxonName: Name of the target taxon
    ///   - taxId: NCBI taxonomy ID
    ///   - readResults: Individual read results
    ///   - submittedAt: When the job was submitted
    ///   - completedAt: When the job completed
    ///   - rid: NCBI Request ID
    ///   - blastProgram: Program used
    ///   - database: Database searched
    public init(
        taxonName: String,
        taxId: Int,
        readResults: [BlastReadResult],
        submittedAt: Date,
        completedAt: Date?,
        rid: String,
        blastProgram: String,
        database: String
    ) {
        self.taxonName = taxonName
        self.taxId = taxId
        self.totalReads = readResults.count
        self.verifiedCount = readResults.filter { $0.verdict == .verified }.count
        self.ambiguousCount = readResults.filter { $0.verdict == .ambiguous }.count
        self.unverifiedCount = readResults.filter { $0.verdict == .unverified }.count
        self.errorCount = readResults.filter { $0.verdict == .error }.count
        self.readResults = readResults
        self.submittedAt = submittedAt
        self.completedAt = completedAt
        self.rid = rid
        self.blastProgram = blastProgram
        self.database = database
    }
}

// MARK: - Raw BLAST Hit Models

/// A single BLAST search result for one query sequence.
///
/// This model mirrors the JSON2 `BlastOutput2[].report.results.search`
/// structure from the NCBI BLAST API.
public struct BlastSearchResult: Sendable, Codable {

    /// The query sequence identifier (read ID).
    public let queryId: String

    /// The query sequence length.
    public let queryLength: Int

    /// All hits returned for this query, ordered by bit score.
    public let hits: [BlastHit]

    /// Creates a BLAST search result.
    public init(queryId: String, queryLength: Int, hits: [BlastHit]) {
        self.queryId = queryId
        self.queryLength = queryLength
        self.hits = hits
    }
}

/// A single BLAST database hit.
///
/// Each hit represents a database sequence that matched the query,
/// and may contain multiple high-scoring segment pairs (HSPs).
public struct BlastHit: Sendable, Codable {

    /// The GenBank accession of the hit sequence.
    public let accession: String

    /// The full title/description of the hit sequence.
    public let title: String

    /// The organism name extracted from the hit description, if available.
    public let organism: String?

    /// The NCBI taxonomy ID from the hit description, if available.
    public let taxId: Int?

    /// High-scoring segment pairs for this hit.
    public let hsps: [BlastHSP]

    /// Creates a BLAST hit.
    ///
    /// - Parameters:
    ///   - accession: GenBank accession
    ///   - title: Full title/description
    ///   - organism: Organism name
    ///   - taxId: NCBI taxonomy ID (default: nil)
    ///   - hsps: High-scoring segment pairs
    public init(accession: String, title: String, organism: String?, taxId: Int? = nil, hsps: [BlastHSP]) {
        self.accession = accession
        self.title = title
        self.organism = organism
        self.taxId = taxId
        self.hsps = hsps
    }
}

/// A high-scoring segment pair from a BLAST alignment.
///
/// An HSP represents a single aligned region between the query
/// and a database sequence.
public struct BlastHSP: Sendable, Codable {

    /// The bit score of this alignment.
    public let bitScore: Double

    /// The E-value (expected number of chance alignments).
    public let evalue: Double

    /// Number of identical positions in the alignment.
    public let identity: Int

    /// Length of the alignment in base pairs.
    public let alignLength: Int

    /// Start position on the query (1-based).
    public let queryFrom: Int

    /// End position on the query (1-based).
    public let queryTo: Int

    /// Percent identity computed as `identity / alignLength * 100`.
    public var percentIdentity: Double {
        alignLength > 0 ? Double(identity) / Double(alignLength) * 100.0 : 0
    }

    /// Query coverage as a fraction of the query length.
    ///
    /// Must be computed with the query length from the parent ``BlastSearchResult``.
    ///
    /// - Parameter queryLength: Total length of the query sequence.
    /// - Returns: Coverage percentage (0-100).
    public func queryCoverage(queryLength: Int) -> Double {
        guard queryLength > 0 else { return 0 }
        let aligned = abs(queryTo - queryFrom) + 1
        return Double(aligned) / Double(queryLength) * 100.0
    }

    /// Creates a BLAST HSP.
    public init(
        bitScore: Double,
        evalue: Double,
        identity: Int,
        alignLength: Int,
        queryFrom: Int,
        queryTo: Int
    ) {
        self.bitScore = bitScore
        self.evalue = evalue
        self.identity = identity
        self.alignLength = alignLength
        self.queryFrom = queryFrom
        self.queryTo = queryTo
    }
}
