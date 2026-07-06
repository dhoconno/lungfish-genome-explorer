// FASTQDerivatives.swift - Pointer-based FASTQ derivative datasets
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import CryptoKit

/// Field used for read lookup operations.
public enum FASTQSearchField: String, Codable, Sendable, CaseIterable {
    case id
    case description
}

/// Deduplication preset for clumpify.sh.
public enum FASTQDeduplicatePreset: String, Codable, Sendable, CaseIterable {
    /// Remove exact PCR duplicates (subs=0). Default for amplicon sequencing.
    case exactPCR
    /// Allow 1 substitution for sequencing error tolerance.
    case nearDuplicate1
    /// Allow 2 substitutions (BBTools default tolerance).
    case nearDuplicate2
    /// Optical duplicates only (patterned flowcell, dupedist=40).
    case opticalHiSeq
    /// Optical duplicates for NextSeq/NovaSeq (dupedist=12000).
    case opticalNovaSeq
    /// User-configured custom parameters.
    case custom
}

/// Adapter location for trimming.
public enum FASTQAdapterLocation: String, Codable, Sendable, CaseIterable {
    case fivePrime
    case threePrime
    case both
}

/// Contaminant reference mode for bbduk filtering.
public enum FASTQContaminantFilterMode: String, Codable, Sendable, CaseIterable {
    /// PhiX spike-in (bundled with bbtools).
    case phix
    /// User-supplied reference FASTA.
    case custom
}

/// Primer source for bbduk primer removal.
public enum FASTQPrimerSource: String, Codable, Sendable, CaseIterable {
    /// User-provided literal nucleotide sequence.
    case literal
    /// User-provided reference FASTA file.
    case reference
}

/// Which tool backend to use for primer removal.
public enum FASTQPrimerTool: String, Codable, Sendable, CaseIterable {
    /// cutadapt: semi-global alignment-based trimming (default).
    case cutadapt
    /// bbduk: k-mer based trimming (faster, better for known primer FASTA).
    case bbduk
}

/// BBDuk k-mer trim direction (ktrim parameter).
public enum FASTQKtrimDirection: String, Codable, Sendable, CaseIterable {
    /// Trim everything to the left of the matching k-mer (5' trim).
    case left
    /// Trim everything to the right of the matching k-mer (3' trim).
    case right
}

/// Which end to search for an adapter sequence (for adapter presence filtering).
public enum FASTQAdapterSearchEnd: String, Codable, Sendable, CaseIterable {
    /// Search at the 5' end of reads (-g).
    case fivePrime
    /// Search at the 3' end of reads (-a).
    case threePrime
}

public enum FASTQPrimerTrimMode: String, Codable, Sendable, CaseIterable {
    case fivePrime
    case threePrime
    case linked
    case paired
}

public enum FASTQPrimerReadMode: String, Codable, Sendable, CaseIterable {
    case single
    case paired
}

public enum FASTQPrimerPairFilter: String, Codable, Sendable, CaseIterable {
    case any
    case both
    case first
}

public struct FASTQPrimerTrimConfiguration: Codable, Sendable, Equatable {
    public let source: FASTQPrimerSource
    public let readMode: FASTQPrimerReadMode
    public let mode: FASTQPrimerTrimMode
    public let forwardSequence: String?
    public let reverseSequence: String?
    public let referenceFasta: String?
    public let anchored5Prime: Bool
    public let anchored3Prime: Bool
    public let errorRate: Double
    public let minimumOverlap: Int
    public let allowIndels: Bool
    public let keepUntrimmed: Bool
    public let searchReverseComplement: Bool
    public let pairFilter: FASTQPrimerPairFilter

    /// Which tool backend to use (cutadapt or bbduk). Defaults to .cutadapt.
    public let tool: FASTQPrimerTool

    // BBDuk-specific parameters (used when tool == .bbduk)
    /// BBDuk ktrim direction: left = trim 5' end, right = trim 3' end.
    public let ktrimDirection: FASTQKtrimDirection
    /// BBDuk k-mer size for matching (default 15).
    public let kmerSize: Int
    /// BBDuk minimum k-mer length for end-of-read matches (default 11).
    public let minKmer: Int
    /// BBDuk Hamming distance tolerance (default 1).
    public let hammingDistance: Int

    public init(
        source: FASTQPrimerSource,
        readMode: FASTQPrimerReadMode = .single,
        mode: FASTQPrimerTrimMode = .fivePrime,
        forwardSequence: String? = nil,
        reverseSequence: String? = nil,
        referenceFasta: String? = nil,
        anchored5Prime: Bool = true,
        anchored3Prime: Bool = true,
        errorRate: Double = 0.12,
        minimumOverlap: Int = 12,
        allowIndels: Bool = true,
        keepUntrimmed: Bool = false,
        searchReverseComplement: Bool = true,
        pairFilter: FASTQPrimerPairFilter = .any,
        tool: FASTQPrimerTool = .cutadapt,
        ktrimDirection: FASTQKtrimDirection = .left,
        kmerSize: Int = 15,
        minKmer: Int = 11,
        hammingDistance: Int = 1
    ) {
        self.source = source
        self.readMode = readMode
        self.mode = mode
        self.forwardSequence = forwardSequence?.trimmingCharacters(in: .whitespacesAndNewlines).uppercased().trimmedNilIfEmpty
        self.reverseSequence = reverseSequence?.trimmingCharacters(in: .whitespacesAndNewlines).uppercased().trimmedNilIfEmpty
        self.referenceFasta = referenceFasta?.trimmingCharacters(in: .whitespacesAndNewlines).trimmedNilIfEmpty
        self.anchored5Prime = anchored5Prime
        self.anchored3Prime = anchored3Prime
        self.errorRate = errorRate
        self.minimumOverlap = minimumOverlap
        self.allowIndels = allowIndels
        self.keepUntrimmed = keepUntrimmed
        self.searchReverseComplement = searchReverseComplement
        self.pairFilter = pairFilter
        self.tool = tool
        self.ktrimDirection = ktrimDirection
        self.kmerSize = kmerSize
        self.minKmer = minKmer
        self.hammingDistance = hammingDistance
    }
}

private extension String {
    var trimmedNilIfEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

/// Interleave/deinterleave direction for reformat.sh.
public enum FASTQInterleaveDirection: String, Codable, Sendable, CaseIterable {
    /// Two files -> one interleaved file.
    case interleave
    /// One interleaved file -> two files.
    case deinterleave
}

/// PE merge strictness mode.
public enum FASTQMergeStrictness: String, Codable, Sendable, CaseIterable {
    /// Standard merge (default bbmerge behaviour).
    case normal
    /// Strict merge — fewer false positive merges.
    case strict
}

/// Quality trimming directionality.
public enum FASTQQualityTrimMode: String, Codable, Sendable, CaseIterable {
    /// Scan from 3' end inward (fastp --cut_right, Trimmomatic SLIDINGWINDOW).
    case cutRight
    /// Scan from 5' end inward (fastp --cut_front).
    case cutFront
    /// Trim low-quality tails only (fastp --cut_tail).
    case cutTail
    /// Trim from both ends.
    case cutBoth
}

/// Adapter removal detection mode.
public enum FASTQAdapterMode: String, Codable, Sendable, CaseIterable {
    /// Auto-detect adapters from read overlap patterns.
    case autoDetect
    /// User-specified adapter sequence(s).
    case specified
    /// Adapter sequences from a FASTA file.
    case fastaFile
}

/// Transformation used to create a derived FASTQ pointer dataset.
public enum FASTQRiboDetectorRetention: String, Codable, Sendable, CaseIterable {
    case nonRRNA = "norrna"
    case rRNA = "rrna"
    case both

    public var displayName: String {
        switch self {
        case .nonRRNA: return "non-rRNA"
        case .rRNA: return "rRNA"
        case .both: return "Both"
        }
    }
}

public enum FASTQRiboDetectorEnsure: String, Codable, Sendable, CaseIterable {
    case rrna
    case norrna
    case both
    case none
}
