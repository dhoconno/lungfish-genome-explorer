// NaoMgsVirusHit.swift - A single virus hit from the NAO-MGS virus_hits_final.tsv output
// Copyright (c) 2025 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import os.log

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
