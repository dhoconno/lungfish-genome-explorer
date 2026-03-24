// BlastVerificationRequest.swift - BLAST verification request model
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation

// MARK: - Verification Request

/// Configuration for a BLAST verification request.
///
/// This bundles all parameters needed to submit a taxon verification
/// job to the NCBI BLAST URL API, including the subsampled sequences,
/// search parameters, and optional organism filter.
///
/// ## Usage
/// ```swift
/// let request = BlastVerificationRequest(
///     taxonName: "Oxbow virus",
///     taxId: 2560178,
///     sequences: [("read_1", "ATGCGATCGA...")],
///     program: "blastn",
///     database: "nt",
///     maxTargetSeqs: 5,
///     eValueThreshold: 1e-10
/// )
/// ```
public struct BlastVerificationRequest: Sendable {

    /// The taxon name being verified (e.g., "Oxbow virus").
    public let taxonName: String

    /// The NCBI taxonomy ID of the target taxon.
    public let taxId: Int

    /// Subsampled reads as (identifier, nucleotide sequence) pairs.
    ///
    /// These are extracted from the source FASTQ and converted to
    /// plain sequences (no quality scores) for BLAST submission.
    public let sequences: [(id: String, sequence: String)]

    /// The BLAST program to use (typically "blastn" for nucleotide queries).
    public let program: String

    /// The BLAST database to search (typically "nt" for non-redundant nucleotide).
    public let database: String

    /// Optional Entrez query to restrict the BLAST search.
    ///
    /// When `nil`, no Entrez filter is applied and BLAST searches all of
    /// `core_nt` (or the configured database) without taxonomic restriction.
    /// When set, the value is passed as the `ENTREZ_QUERY` parameter to NCBI.
    ///
    /// Example: `"txid2560178[Organism:exp]"` restricts to a specific taxon.
    public let entrezQuery: String?

    /// Maximum number of target sequences to return per query.
    public let maxTargetSeqs: Int

    /// E-value threshold for significance (e.g., 1e-10).
    public let eValueThreshold: Double

    /// Creates a new BLAST verification request.
    ///
    /// - Parameters:
    ///   - taxonName: Name of the taxon to verify
    ///   - taxId: NCBI taxonomy ID
    ///   - sequences: Subsampled reads as (id, sequence) pairs
    ///   - program: BLAST program (default: "blastn")
    ///   - database: BLAST database (default: "nt")
    ///   - entrezQuery: Optional Entrez query filter (default: nil, no filter applied)
    ///   - maxTargetSeqs: Max target sequences per query (default: 5)
    ///   - eValueThreshold: E-value threshold (default: 1e-10)
    public init(
        taxonName: String,
        taxId: Int,
        sequences: [(id: String, sequence: String)],
        program: String = "blastn",
        database: String = "nt",
        entrezQuery: String? = nil,
        maxTargetSeqs: Int = 5,
        eValueThreshold: Double = 1e-10
    ) {
        self.taxonName = taxonName
        self.taxId = taxId
        self.sequences = sequences
        self.program = program
        self.database = database
        self.entrezQuery = entrezQuery
        self.maxTargetSeqs = maxTargetSeqs
        self.eValueThreshold = eValueThreshold
    }

    /// Formats the sequences as a multi-FASTA string for BLAST submission.
    ///
    /// Each sequence is formatted as:
    /// ```
    /// >read_id
    /// ATGCGATCGA...
    /// ```
    ///
    /// - Returns: A multi-FASTA string suitable for the BLAST QUERY parameter.
    public func toMultiFASTA() -> String {
        sequences.map { ">\($0.id)\n\($0.sequence)" }.joined(separator: "\n")
    }
}

// MARK: - Subsample Strategy

/// Strategy for subsampling reads from a classified read set.
///
/// NCBI BLAST has practical limits on query size. Subsampling selects
/// a representative subset of reads for verification.
///
/// ## Default Strategy
///
/// The default `.mixed(longest: 5, random: 15)` strategy selects:
/// 1. The 5 longest reads (longer reads produce more informative alignments)
/// 2. 15 randomly selected reads (for diversity)
///
/// This yields 20 reads total, well within BLAST API limits.
public enum SubsampleStrategy: Sendable, Equatable {

    /// Select the N longest reads.
    case longestFirst(count: Int)

    /// Select N reads at random.
    case random(count: Int)

    /// Select a mix of longest and random reads.
    ///
    /// The longest reads are selected first, then the remaining slots
    /// are filled with random reads from the rest of the pool.
    case mixed(longest: Int, random: Int)

    /// The total number of reads to select.
    public var totalCount: Int {
        switch self {
        case .longestFirst(let count):
            return count
        case .random(let count):
            return count
        case .mixed(let longest, let random):
            return longest + random
        }
    }

    /// The default strategy: 5 longest + 15 random = 20 reads.
    public static let `default` = SubsampleStrategy.mixed(longest: 5, random: 15)
}

// MARK: - BLAST Job Submission

/// Response from submitting a BLAST job to NCBI.
///
/// The NCBI BLAST URL API returns a Request ID (RID) and an estimated
/// time to completion (RTOE) when a job is submitted.
public struct BlastJobSubmission: Sendable {

    /// The NCBI Request ID for tracking and retrieving this job.
    public let rid: String

    /// Estimated time of execution in seconds.
    ///
    /// The client should wait at least this long before the first
    /// status poll. Returns 0 if not provided by NCBI.
    public let rtoe: Int

    /// Creates a BLAST job submission response.
    public init(rid: String, rtoe: Int) {
        self.rid = rid
        self.rtoe = rtoe
    }
}

// MARK: - BLAST Job Status

/// Status of a BLAST job on the NCBI server.
public enum BlastJobStatus: Sendable, Equatable {
    /// The job is still running. Poll again later.
    case waiting

    /// The job has completed and results are ready for retrieval.
    case ready

    /// The job encountered an error on the server.
    case error(message: String)

    /// The job was not found (invalid or expired RID).
    case unknown
}

// MARK: - BLAST Service Error

/// Errors specific to the BLAST verification pipeline.
public enum BlastServiceError: Error, LocalizedError, Sendable {

    /// The BLAST submission was rejected by NCBI.
    case submissionFailed(message: String)

    /// Failed to parse the RID from the NCBI submission response.
    case ridParsingFailed(responseBody: String)

    /// The BLAST job timed out after the maximum wait period.
    case timeout(rid: String, elapsed: TimeInterval)

    /// The BLAST job failed on the NCBI server.
    case jobFailed(rid: String, message: String)

    /// Failed to parse the BLAST results JSON.
    case resultParsingFailed(message: String)

    /// No sequences were provided for verification.
    case noSequences

    /// Rate limit: must wait before submitting another request.
    case rateLimitExceeded(retryAfter: TimeInterval)

    /// The HTTP response was not successful.
    case httpError(statusCode: Int, body: String)

    public var errorDescription: String? {
        switch self {
        case .submissionFailed(let message):
            return "BLAST submission failed: \(message)"
        case .ridParsingFailed:
            return "Failed to parse NCBI Request ID from submission response"
        case .timeout(let rid, let elapsed):
            let minutes = Int(elapsed / 60)
            return "BLAST job timed out after \(minutes) minutes (RID: \(rid)). "
                + "Check results at https://blast.ncbi.nlm.nih.gov/Blast.cgi?CMD=Get&RID=\(rid)"
        case .jobFailed(let rid, let message):
            return "BLAST job \(rid) failed: \(message)"
        case .resultParsingFailed(let message):
            return "Failed to parse BLAST results: \(message)"
        case .noSequences:
            return "No sequences provided for BLAST verification"
        case .rateLimitExceeded(let retryAfter):
            return "NCBI rate limit exceeded. Retry after \(Int(retryAfter)) seconds."
        case .httpError(let statusCode, let body):
            return "HTTP \(statusCode): \(body.prefix(200))"
        }
    }
}
