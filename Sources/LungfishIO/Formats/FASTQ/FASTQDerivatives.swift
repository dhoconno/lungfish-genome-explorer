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

/// What a derivative bundle stores on disk — enforces correct filename pairing.
public enum FASTQDerivativePayload: Codable, Sendable, Equatable {
    /// Stores a read ID list file (subset operations).
    case subset(readIDListFilename: String)
    /// Stores a trim positions TSV file (trim operations).
    case trim(trimPositionFilename: String)
    /// Stores a full materialized FASTQ file (content-transforming operations like PE merge/repair).
    case full(fastqFilename: String)
    /// Stores paired R1/R2 FASTQ files (deinterleave produces two files from one).
    case fullPaired(r1Filename: String, r2Filename: String)
    /// Stores multiple FASTQ files with classified roles (after merge/repair producing mixed read types).
    case fullMixed(ReadClassification)
    /// Stores a full materialized FASTA file (conversion from FASTQ, or FASTA-native operations).
    case fullFASTA(fastaFilename: String)
    /// A virtual demuxed barcode bundle: stores a read ID list and a small preview FASTQ,
    /// referencing the root FASTQ for full materialization on demand.
    /// Optionally includes a trim positions file for adapter/barcode removal during materialization.
    /// Optionally includes an orient map file inherited from a parent orient step — when present,
    /// trim positions have been adjusted to root orientation and materialization must apply RC.
    case demuxedVirtual(barcodeID: String, readIDListFilename: String, previewFilename: String, trimPositionsFilename: String? = nil, orientMapFilename: String? = nil)
    /// The demux group directory containing all per-barcode bundles.
    case demuxGroup(barcodeCount: Int)
    /// Stores an orientation map TSV (read_id → +/-) and a preview FASTQ.
    /// Oriented FASTQ is materialized on demand using seqkit to RC the marked reads.
    case orientMap(orientMapFilename: String, previewFilename: String)

    /// The category for display purposes.
    public var category: String {
        switch self {
        case .subset: return "subset"
        case .trim: return "trim"
        case .full: return "full"
        case .fullPaired: return "full-paired"
        case .fullMixed: return "full-mixed"
        case .fullFASTA: return "full-fasta"
        case .demuxedVirtual: return "demuxed-virtual"
        case .demuxGroup: return "demux-group"
        case .orientMap: return "orient-map"
        }
    }
}

/// Transformation used to create a derived FASTQ pointer dataset.
public enum FASTQDerivativeOperationKind: String, Codable, Sendable, CaseIterable {
    // Subset operations (produce read ID list)
    case subsampleProportion
    case subsampleCount
    case lengthFilter
    case searchText
    case searchMotif
    case deduplicate

    // Trim operations (produce trim position records)
    case qualityTrim
    case adapterTrim
    case fixedTrim

    // BBTools operations
    case contaminantFilter
    case pairedEndMerge
    case pairedEndRepair
    case primerRemoval
    case errorCorrection
    case interleaveReformat
    case reverseComplement
    case translate

    // Demultiplexing
    case demultiplex

    // Adapter presence filtering (keep/discard reads by adapter match, no trimming)
    case sequencePresenceFilter

    // Orientation
    case orient

    // Human read removal using NCBI sra-human-scrubber
    case humanReadScrub

    /// Whether this operation produces a subset (read IDs) or trim (positions).
    public var isSubsetOperation: Bool {
        switch self {
        case .subsampleProportion, .subsampleCount, .lengthFilter,
             .searchText, .searchMotif, .contaminantFilter,
             .sequencePresenceFilter:
            return true
        case .deduplicate:
            return false  // clumpify writes a full output file
        case .qualityTrim, .adapterTrim, .fixedTrim, .primerRemoval:
            return false
        case .pairedEndMerge, .pairedEndRepair,
             .errorCorrection, .interleaveReformat, .reverseComplement,
             .translate, .demultiplex, .orient, .humanReadScrub:
            return false
        }
    }

    /// Whether this operation produces a full materialized FASTQ (content-transforming).
    public var isFullOperation: Bool {
        switch self {
        case .pairedEndMerge, .pairedEndRepair,
             .errorCorrection, .interleaveReformat, .demultiplex,
             .deduplicate, .humanReadScrub, .reverseComplement, .translate:
            return true
        default:
            return false
        }
    }

    /// Whether this operation produces an orient map (orientation metadata).
    public var isOrientOperation: Bool {
        self == .orient
    }

    /// Whether this operation can work on FASTA files (no quality scores needed).
    public var supportsFASTA: Bool {
        switch self {
        case .subsampleProportion, .subsampleCount, .lengthFilter,
             .searchText, .searchMotif, .deduplicate, .adapterTrim,
             .fixedTrim, .contaminantFilter, .primerRemoval,
             .reverseComplement, .translate,
             .demultiplex, .orient, .sequencePresenceFilter,
             .humanReadScrub:
            return true
        case .qualityTrim, .pairedEndMerge,
             .pairedEndRepair, .errorCorrection,
             .interleaveReformat:
            return false
        }
    }
}

/// Serializable operation configuration for derived FASTQ datasets.
public struct FASTQDerivativeOperation: Codable, Sendable, Equatable {
    public let kind: FASTQDerivativeOperationKind
    public let createdAt: Date

    // Generic optional parameter payload for lightweight persistence.

    // Subset parameters
    public var proportion: Double?
    public var count: Int?
    public var minLength: Int?
    public var maxLength: Int?
    public var query: String?
    public var searchField: FASTQSearchField?
    public var useRegex: Bool?
    public var deduplicatePreset: FASTQDeduplicatePreset?
    public var deduplicateSubstitutions: Int?
    public var deduplicateOptical: Bool?
    public var deduplicateOpticalDistance: Int?

    // Quality trim parameters
    public var qualityThreshold: Int?
    public var windowSize: Int?
    public var qualityTrimMode: FASTQQualityTrimMode?

    // Adapter trim parameters
    public var adapterMode: FASTQAdapterMode?
    public var adapterSequence: String?
    public var adapterSequenceR2: String?
    public var adapterFastaFilename: String?

    // Fixed trim parameters
    public var trimFrom5Prime: Int?
    public var trimFrom3Prime: Int?

    // Contaminant filter parameters
    public var contaminantFilterMode: FASTQContaminantFilterMode?
    public var contaminantReferenceFasta: String?
    public var contaminantKmerSize: Int?
    public var contaminantHammingDistance: Int?

    // PE merge parameters
    public var mergeStrictness: FASTQMergeStrictness?
    public var mergeMinOverlap: Int?

    // Primer removal parameters
    public var primerSource: FASTQPrimerSource?
    public var primerLiteralSequence: String?
    public var primerReferenceFasta: String?
    public var primerKmerSize: Int?
    public var primerMinKmer: Int?
    public var primerHammingDistance: Int?
    public var primerReadMode: FASTQPrimerReadMode?
    public var primerTrimMode: FASTQPrimerTrimMode?
    public var primerForwardSequence: String?
    public var primerReverseSequence: String?
    public var primerAnchored5Prime: Bool?
    public var primerAnchored3Prime: Bool?
    public var primerErrorRate: Double?
    public var primerMinimumOverlap: Int?
    public var primerAllowIndels: Bool?
    public var primerKeepUntrimmed: Bool?
    public var primerSearchReverseComplement: Bool?
    public var primerPairFilter: FASTQPrimerPairFilter?

    /// Which tool backend was used for primer removal (cutadapt or bbduk).
    public var primerTool: FASTQPrimerTool?

    /// BBDuk ktrim direction when primerTool == .bbduk.
    public var primerKtrimDirection: FASTQKtrimDirection?

    // Adapter presence filter parameters
    /// Adapter/barcode sequence to search for (literal nucleotide string).
    public var adapterFilterSequence: String?
    /// FASTA file containing adapter sequences to search for.
    public var adapterFilterFastaPath: String?
    /// Which end to search for the adapter.
    public var adapterFilterSearchEnd: FASTQAdapterSearchEnd?
    /// Minimum overlap for adapter matching (cutadapt --overlap).
    public var adapterFilterMinOverlap: Int?
    /// Maximum error rate for adapter matching (cutadapt -e).
    public var adapterFilterErrorRate: Double?
    /// Whether to keep reads that match (true) or discard them (false).
    /// Default true: keep reads containing the adapter (like ONT barcode filtering).
    public var adapterFilterKeepMatched: Bool?
    /// Whether to also search for the reverse complement of the adapter sequence.
    public var adapterFilterSearchReverseComplement: Bool?

    // Error correction parameters
    public var errorCorrectionKmerSize: Int?

    // Interleave parameters
    public var interleaveDirection: FASTQInterleaveDirection?

    // Sequence transform parameters
    public var translationFrameOffset: Int?

    // Demultiplex parameters
    public var barcodeID: String?
    public var sampleName: String?
    public var demuxRunID: UUID?

    // Human read scrub parameters
    /// Whether to remove (true) or mask with N (false, default) human reads.
    public var humanScrubRemoveReads: Bool?
    /// Database ID to use (default "human-scrubber"). Resolves via DatabaseRegistry.
    public var humanScrubDatabaseID: String?

    // Orient parameters
    /// Relative path to the reference FASTA used for orientation (within Reference Sequences/).
    public var orientReferencePath: String?
    /// Word length for vsearch orient k-mer matching (3-15, default 12).
    public var orientWordLength: Int?
    /// Whether low-complexity masking was applied to the database (dust/none).
    public var orientDbMask: String?
    /// Whether unoriented reads were saved as a separate derivative.
    public var orientSaveUnoriented: Bool?
    /// Number of reads that were reverse-complemented during orientation.
    public var orientRCCount: Int?
    /// Number of reads that could not be oriented.
    public var orientUnmatchedCount: Int?

    /// Which external tool performed the operation (for provenance).
    public var toolUsed: String?

    /// Version of the external tool at time of execution (e.g., "4.9" for cutadapt).
    public var toolVersion: String?

    /// Raw command-line invocation for full reproducibility.
    public var toolCommand: String?

    /// Random seed used for stochastic operations (subsample, shuffle).
    /// Stored for reproducibility — re-running with the same seed produces identical output.
    public var randomSeed: UInt64?

    public init(
        kind: FASTQDerivativeOperationKind,
        createdAt: Date = Date(),
        proportion: Double? = nil,
        count: Int? = nil,
        minLength: Int? = nil,
        maxLength: Int? = nil,
        query: String? = nil,
        searchField: FASTQSearchField? = nil,
        useRegex: Bool? = nil,
        deduplicatePreset: FASTQDeduplicatePreset? = nil,
        deduplicateSubstitutions: Int? = nil,
        deduplicateOptical: Bool? = nil,
        deduplicateOpticalDistance: Int? = nil,
        qualityThreshold: Int? = nil,
        windowSize: Int? = nil,
        qualityTrimMode: FASTQQualityTrimMode? = nil,
        adapterMode: FASTQAdapterMode? = nil,
        adapterSequence: String? = nil,
        adapterSequenceR2: String? = nil,
        adapterFastaFilename: String? = nil,
        trimFrom5Prime: Int? = nil,
        trimFrom3Prime: Int? = nil,
        contaminantFilterMode: FASTQContaminantFilterMode? = nil,
        contaminantReferenceFasta: String? = nil,
        contaminantKmerSize: Int? = nil,
        contaminantHammingDistance: Int? = nil,
        mergeStrictness: FASTQMergeStrictness? = nil,
        mergeMinOverlap: Int? = nil,
        primerSource: FASTQPrimerSource? = nil,
        primerLiteralSequence: String? = nil,
        primerReferenceFasta: String? = nil,
        primerKmerSize: Int? = nil,
        primerMinKmer: Int? = nil,
        primerHammingDistance: Int? = nil,
        primerReadMode: FASTQPrimerReadMode? = nil,
        primerTrimMode: FASTQPrimerTrimMode? = nil,
        primerForwardSequence: String? = nil,
        primerReverseSequence: String? = nil,
        primerAnchored5Prime: Bool? = nil,
        primerAnchored3Prime: Bool? = nil,
        primerErrorRate: Double? = nil,
        primerMinimumOverlap: Int? = nil,
        primerAllowIndels: Bool? = nil,
        primerKeepUntrimmed: Bool? = nil,
        primerSearchReverseComplement: Bool? = nil,
        primerPairFilter: FASTQPrimerPairFilter? = nil,
        primerTool: FASTQPrimerTool? = nil,
        primerKtrimDirection: FASTQKtrimDirection? = nil,
        adapterFilterSequence: String? = nil,
        adapterFilterFastaPath: String? = nil,
        adapterFilterSearchEnd: FASTQAdapterSearchEnd? = nil,
        adapterFilterMinOverlap: Int? = nil,
        adapterFilterErrorRate: Double? = nil,
        adapterFilterKeepMatched: Bool? = nil,
        adapterFilterSearchReverseComplement: Bool? = nil,
        errorCorrectionKmerSize: Int? = nil,
        interleaveDirection: FASTQInterleaveDirection? = nil,
        barcodeID: String? = nil,
        sampleName: String? = nil,
        demuxRunID: UUID? = nil,
        humanScrubRemoveReads: Bool? = nil,
        humanScrubDatabaseID: String? = nil,
        orientReferencePath: String? = nil,
        orientWordLength: Int? = nil,
        orientDbMask: String? = nil,
        orientSaveUnoriented: Bool? = nil,
        orientRCCount: Int? = nil,
        orientUnmatchedCount: Int? = nil,
        toolUsed: String? = nil,
        toolVersion: String? = nil,
        toolCommand: String? = nil,
        randomSeed: UInt64? = nil
    ) {
        self.kind = kind
        self.createdAt = createdAt
        self.proportion = proportion
        self.count = count
        self.minLength = minLength
        self.maxLength = maxLength
        self.query = query
        self.searchField = searchField
        self.useRegex = useRegex
        self.deduplicatePreset = deduplicatePreset
        self.deduplicateSubstitutions = deduplicateSubstitutions
        self.deduplicateOptical = deduplicateOptical
        self.deduplicateOpticalDistance = deduplicateOpticalDistance
        self.qualityThreshold = qualityThreshold
        self.windowSize = windowSize
        self.qualityTrimMode = qualityTrimMode
        self.adapterMode = adapterMode
        self.adapterSequence = adapterSequence
        self.adapterSequenceR2 = adapterSequenceR2
        self.adapterFastaFilename = adapterFastaFilename
        self.trimFrom5Prime = trimFrom5Prime
        self.trimFrom3Prime = trimFrom3Prime
        self.contaminantFilterMode = contaminantFilterMode
        self.contaminantReferenceFasta = contaminantReferenceFasta
        self.contaminantKmerSize = contaminantKmerSize
        self.contaminantHammingDistance = contaminantHammingDistance
        self.mergeStrictness = mergeStrictness
        self.mergeMinOverlap = mergeMinOverlap
        self.primerSource = primerSource
        self.primerLiteralSequence = primerLiteralSequence
        self.primerReferenceFasta = primerReferenceFasta
        self.primerKmerSize = primerKmerSize
        self.primerMinKmer = primerMinKmer
        self.primerHammingDistance = primerHammingDistance
        self.primerReadMode = primerReadMode
        self.primerTrimMode = primerTrimMode
        self.primerForwardSequence = primerForwardSequence
        self.primerReverseSequence = primerReverseSequence
        self.primerAnchored5Prime = primerAnchored5Prime
        self.primerAnchored3Prime = primerAnchored3Prime
        self.primerErrorRate = primerErrorRate
        self.primerMinimumOverlap = primerMinimumOverlap
        self.primerAllowIndels = primerAllowIndels
        self.primerKeepUntrimmed = primerKeepUntrimmed
        self.primerSearchReverseComplement = primerSearchReverseComplement
        self.primerPairFilter = primerPairFilter
        self.primerTool = primerTool
        self.primerKtrimDirection = primerKtrimDirection
        self.adapterFilterSequence = adapterFilterSequence
        self.adapterFilterFastaPath = adapterFilterFastaPath
        self.adapterFilterSearchEnd = adapterFilterSearchEnd
        self.adapterFilterMinOverlap = adapterFilterMinOverlap
        self.adapterFilterErrorRate = adapterFilterErrorRate
        self.adapterFilterKeepMatched = adapterFilterKeepMatched
        self.adapterFilterSearchReverseComplement = adapterFilterSearchReverseComplement
        self.errorCorrectionKmerSize = errorCorrectionKmerSize
        self.interleaveDirection = interleaveDirection
        self.translationFrameOffset = nil
        self.barcodeID = barcodeID
        self.sampleName = sampleName
        self.demuxRunID = demuxRunID
        self.humanScrubRemoveReads = humanScrubRemoveReads
        self.humanScrubDatabaseID = humanScrubDatabaseID
        self.orientReferencePath = orientReferencePath
        self.orientWordLength = orientWordLength
        self.orientDbMask = orientDbMask
        self.orientSaveUnoriented = orientSaveUnoriented
        self.orientRCCount = orientRCCount
        self.orientUnmatchedCount = orientUnmatchedCount
        self.toolUsed = toolUsed
        self.toolVersion = toolVersion
        self.toolCommand = toolCommand
        self.randomSeed = randomSeed
    }

    public var shortLabel: String {
        switch kind {
        case .subsampleProportion:
            if let proportion {
                return String(format: "subsample-p%.4f", proportion)
            }
            return "subsample-proportion"
        case .subsampleCount:
            if let count {
                return "subsample-n\(count)"
            }
            return "subsample-count"
        case .lengthFilter:
            let minString = minLength.map(String.init) ?? "any"
            let maxString = maxLength.map(String.init) ?? "any"
            return "len-\(minString)-\(maxString)"
        case .searchText:
            return "search-text"
        case .searchMotif:
            return "search-motif"
        case .deduplicate:
            return "dedup"
        case .qualityTrim:
            let q = qualityThreshold ?? 20
            return "qtrim-Q\(q)"
        case .adapterTrim:
            return "adapter-trim"
        case .fixedTrim:
            let f = trimFrom5Prime ?? 0
            let t = trimFrom3Prime ?? 0
            return "trim-\(f)-\(t)"
        case .contaminantFilter:
            let mode = contaminantFilterMode ?? .phix
            return "contaminant-\(mode.rawValue)"
        case .pairedEndMerge:
            let s = mergeStrictness ?? .normal
            return "merge-\(s.rawValue)"
        case .pairedEndRepair:
            return "repair"
        case .primerRemoval:
            let mode = primerTrimMode ?? .fivePrime
            let readMode = primerReadMode ?? .single
            let overlap = primerMinimumOverlap ?? 12
            return "primer-\(mode.rawValue)-\(readMode.rawValue)-ov\(overlap)"
        case .errorCorrection:
            let k = errorCorrectionKmerSize ?? 50
            return "ecc-k\(k)"
        case .interleaveReformat:
            let dir = interleaveDirection ?? .interleave
            return "\(dir.rawValue)"
        case .reverseComplement:
            return "reverse-complement"
        case .translate:
            let offset = translationFrameOffset ?? 0
            return "translate-frame-\(offset + 1)"
        case .sequencePresenceFilter:
            let end = adapterFilterSearchEnd ?? .fivePrime
            let keep = adapterFilterKeepMatched ?? true
            return "adapter-filter-\(end.rawValue)-\(keep ? "keep" : "discard")"
        case .demultiplex:
            if let barcodeID {
                return "demux-\(barcodeID)"
            }
            return "demultiplex"
        case .orient:
            return "orient"
        case .humanReadScrub:
            let dbID = humanScrubDatabaseID ?? "human-scrubber"
            let mode = humanScrubRemoveReads == true ? "remove" : "mask"
            return "human-scrub-\(dbID)-\(mode)"
        }
    }

    public var displaySummary: String {
        switch kind {
        case .subsampleProportion:
            if let proportion {
                return "Subsample by proportion (\(String(format: "%.4f", proportion)))"
            }
            return "Subsample by proportion"
        case .subsampleCount:
            if let count {
                return "Subsample \(count) reads"
            }
            return "Subsample by count"
        case .lengthFilter:
            let minString = minLength.map(String.init) ?? "-"
            let maxString = maxLength.map(String.init) ?? "-"
            return "Length filter (min: \(minString), max: \(maxString))"
        case .searchText:
            let fieldString = searchField?.rawValue ?? "id"
            let queryString = query ?? ""
            return "Search \(fieldString): \(queryString)"
        case .searchMotif:
            let queryString = query ?? ""
            return "Motif search: \(queryString)"
        case .deduplicate:
            let subs = deduplicateSubstitutions ?? 0
            let preset = deduplicatePreset ?? .exactPCR
            if deduplicateOptical == true {
                let dist = deduplicateOpticalDistance ?? 40
                return "Deduplicate optical (dist: \(dist), subs: \(subs))"
            }
            return "Deduplicate (\(preset.rawValue), subs: \(subs))"
        case .qualityTrim:
            let q = qualityThreshold ?? 20
            let w = windowSize ?? 4
            let mode = qualityTrimMode ?? .cutRight
            return "Quality trim Q\(q) w\(w) (\(mode.rawValue))"
        case .adapterTrim:
            let mode = adapterMode ?? .autoDetect
            switch mode {
            case .autoDetect:
                return "Adapter removal (auto-detect)"
            case .specified:
                let seq = adapterSequence ?? ""
                let preview = seq.prefix(20)
                return "Adapter removal (\(preview)\(seq.count > 20 ? "…" : ""))"
            case .fastaFile:
                return "Adapter removal (FASTA file)"
            }
        case .fixedTrim:
            let f = trimFrom5Prime ?? 0
            let t = trimFrom3Prime ?? 0
            return "Fixed trim (5': \(f) bp, 3': \(t) bp)"
        case .contaminantFilter:
            let mode = contaminantFilterMode ?? .phix
            switch mode {
            case .phix:
                return "Contaminant filter (PhiX)"
            case .custom:
                let ref = contaminantReferenceFasta ?? "custom"
                return "Contaminant filter (\(ref))"
            }
        case .pairedEndMerge:
            let s = mergeStrictness ?? .normal
            let o = mergeMinOverlap ?? 12
            return "PE merge (\(s.rawValue), min overlap: \(o))"
        case .pairedEndRepair:
            return "PE read repair"
        case .primerRemoval:
            let tool = primerTool ?? .cutadapt
            let src = primerSource ?? .literal
            let mode = primerTrimMode ?? .fivePrime
            let toolLabel = tool == .bbduk ? "bbduk" : "cutadapt"
            switch tool {
            case .bbduk:
                let dir = primerKtrimDirection ?? .left
                let k = primerKmerSize ?? 15
                let dirLabel = dir == .left ? "5'" : "3'"
                if let ref = primerReferenceFasta {
                    return "Primer trim \(dirLabel) via bbduk (ref: \(ref), k=\(k))"
                }
                return "Primer trim \(dirLabel) via bbduk (k=\(k))"
            case .cutadapt:
                let overlap = primerMinimumOverlap ?? 12
                switch src {
                case .literal:
                    let seq = primerForwardSequence ?? primerLiteralSequence ?? ""
                    let preview = seq.prefix(20)
                    return "Primer trim (\(mode.rawValue), literal: \(preview)\(seq.count > 20 ? "…" : ""), ov=\(overlap)) via \(toolLabel)"
                case .reference:
                    let ref = primerReferenceFasta ?? "reference"
                    return "Primer trim (\(mode.rawValue), ref: \(ref), ov=\(overlap)) via \(toolLabel)"
                }
            }
        case .errorCorrection:
            let k = errorCorrectionKmerSize ?? 50
            return "Error correction (k=\(k))"
        case .interleaveReformat:
            let dir = interleaveDirection ?? .interleave
            switch dir {
            case .interleave:
                return "Interleave R1/R2"
            case .deinterleave:
                return "Deinterleave to R1/R2"
            }
        case .reverseComplement:
            return "Reverse complement sequences"
        case .translate:
            let offset = translationFrameOffset ?? 0
            return "Translate sequences (frame \(offset + 1))"
        case .sequencePresenceFilter:
            let end = adapterFilterSearchEnd ?? .fivePrime
            let keep = adapterFilterKeepMatched ?? true
            let searchRC = adapterFilterSearchReverseComplement ?? false
            let endLabel = end == .fivePrime ? "5'" : "3'"
            let action = keep ? "Keep" : "Discard"
            let rcSuffix = searchRC ? " +RC" : ""
            if let seq = adapterFilterSequence {
                let preview = seq.prefix(20)
                return "\(action) reads matching \(endLabel) sequence (\(preview)\(seq.count > 20 ? "..." : "")\(rcSuffix))"
            }
            return "\(action) reads matching \(endLabel) sequence\(rcSuffix)"
        case .demultiplex:
            if let barcodeID {
                let label = sampleName ?? barcodeID
                return "Demultiplex → \(label)"
            }
            return "Demultiplex"
        case .orient:
            let ref = orientReferencePath ?? "reference"
            let refName = URL(fileURLWithPath: ref).deletingPathExtension().lastPathComponent
            if let rc = orientRCCount, let unmatched = orientUnmatchedCount {
                return "Orient against \(refName) (\(rc) RC'd, \(unmatched) unmatched)"
            }
            return "Orient against \(refName)"
        case .humanReadScrub:
            let mode = humanScrubRemoveReads == true ? "remove" : "mask with N"
            let dbID = humanScrubDatabaseID ?? "human-scrubber"
            return "Human read scrub (\(mode), db: \(dbID))"
        }
    }
}

// MARK: - Orient Map File I/O

/// Reads and writes `orient-map.tsv` files used by orient derivative bundles.
public enum FASTQOrientMapFile {

    /// Writes orientation records to a TSV file. Format: `readID\torientation\n`
    /// where orientation is "+" (forward) or "-" (reverse complemented).
    ///
    /// - Precondition: Each record's orientation must be "+" or "-".
    public static func write(_ records: [(readID: String, orientation: String)], to url: URL) throws {
        let fm = FileManager.default
        let tmpURL = url.appendingPathExtension("tmp")
        fm.createFile(atPath: tmpURL.path, contents: nil)
        let handle = try FileHandle(forWritingTo: tmpURL)
        do {
            for record in records {
                precondition(record.orientation == "+" || record.orientation == "-",
                             "Orientation must be + or -, got \(record.orientation)")
                guard let data = "\(record.readID)\t\(record.orientation)\n"
                    .data(using: .utf8) else { continue }
                handle.write(data)
            }
            try handle.close()
        } catch {
            try? handle.close()
            try? fm.removeItem(at: tmpURL)
            throw error
        }
        // POSIX rename is atomic on same filesystem
        if rename(tmpURL.path, url.path) != 0 {
            // Fallback for cross-device moves
            try? fm.removeItem(at: url)
            try fm.moveItem(at: tmpURL, to: url)
        }
    }

    /// Loads orientation records from a TSV file into a dictionary keyed by read ID.
    /// Values are "+" (already forward) or "-" (was reverse complemented).
    public static func load(from url: URL) throws -> [String: String] {
        let content = try String(contentsOf: url, encoding: .utf8)
        var orientations: [String: String] = [:]
        for line in content.split(separator: "\n", omittingEmptySubsequences: true) {
            let fields = line.split(separator: "\t")
            guard fields.count >= 2 else { continue }
            let readID = String(fields[0])
            let orientation = String(fields[1])
            guard orientation == "+" || orientation == "-" else { continue }
            orientations[readID] = orientation
        }
        return orientations
    }

    /// Returns the set of read IDs that need reverse complementing.
    public static func loadRCReadIDs(from url: URL) throws -> Set<String> {
        let content = try String(contentsOf: url, encoding: .utf8)
        var rcIDs: Set<String> = []
        for line in content.split(separator: "\n", omittingEmptySubsequences: true) {
            let fields = line.split(separator: "\t")
            guard fields.count >= 2, fields[1] == "-" else { continue }
            rcIDs.insert(String(fields[0]))
        }
        return rcIDs
    }

    /// Returns the set of forward-oriented read IDs ("+").
    public static func loadForwardReadIDs(from url: URL) throws -> Set<String> {
        let content = try String(contentsOf: url, encoding: .utf8)
        var fwdIDs: Set<String> = []
        for line in content.split(separator: "\n", omittingEmptySubsequences: true) {
            let fields = line.split(separator: "\t")
            guard fields.count >= 2, fields[1] == "+" else { continue }
            fwdIDs.insert(String(fields[0]))
        }
        return fwdIDs
    }
}

// MARK: - Trim Position Record

/// A single read's trim boundaries, referencing positions in the root FASTQ sequence.
public struct FASTQTrimRecord: Sendable, Equatable {
    /// Normalized read identifier.
    public let readID: String
    /// Mate number: 0 = single-end/unknown, 1 = R1, 2 = R2.
    public let mate: Int
    /// 0-based inclusive start position in the original sequence.
    public let trimStart: Int
    /// Exclusive end position in the original sequence.
    public let trimEnd: Int

    public init(readID: String, mate: Int = 0, trimStart: Int, trimEnd: Int) {
        precondition(trimStart >= 0, "trimStart must be non-negative")
        precondition(trimEnd >= 0, "trimEnd must be non-negative")
        precondition(trimEnd >= trimStart, "trimEnd (\(trimEnd)) must be >= trimStart (\(trimStart))")
        self.readID = readID
        self.mate = mate
        self.trimStart = trimStart
        self.trimEnd = trimEnd
    }

    /// The length of the trimmed subsequence.
    public var trimmedLength: Int { max(0, trimEnd - trimStart) }
}

// MARK: - Trim Position File I/O

/// Reads and writes `trim-positions.tsv` files used by trim derivative bundles.
///
/// **Format v2** (current): `#format lungfish-trim-v2\nread_id\tmate\ttrim_start\ttrim_end\n`
/// - Absolute coordinates: trimStart/trimEnd are positions in the ROOT sequence.
/// - Mate-aware: mate column (0=single, 1=R1, 2=R2).
///
/// **Format v1** (legacy): `read_id\ttrim_5p\ttrim_3p\n` or 4-column `read_id\tmate\ttrim_5p\ttrim_3p\n`
/// - Relative offsets: trim_5p/trim_3p are bases removed from each end.
/// - Detected by absence of `#format` header line.
public enum FASTQTrimPositionFile {

    public static let formatHeader = "#format lungfish-trim-v2"

    /// Writes trim records in v2 format with `#format` header and mate column.
    /// Uses atomic write (tmp file + rename) and streaming FileHandle writes.
    public static func write(_ records: [FASTQTrimRecord], to url: URL) throws {
        let fm = FileManager.default
        let tmpURL = url.appendingPathExtension("tmp")
        fm.createFile(atPath: tmpURL.path, contents: nil)
        let handle = try FileHandle(forWritingTo: tmpURL)
        do {
            if let headerData = "\(formatHeader)\nread_id\tmate\ttrim_start\ttrim_end\n".data(using: .utf8) {
                handle.write(headerData)
            }
            for record in records {
                guard let data = "\(record.readID)\t\(record.mate)\t\(record.trimStart)\t\(record.trimEnd)\n"
                    .data(using: .utf8) else { continue }
                handle.write(data)
            }
            try handle.close()
        } catch {
            try? handle.close()
            try? fm.removeItem(at: tmpURL)
            throw error
        }
        // POSIX rename is atomic on same filesystem
        if rename(tmpURL.path, url.path) != 0 {
            try? fm.removeItem(at: url)
            try fm.moveItem(at: tmpURL, to: url)
        }
    }

    /// Loads trim records from a TSV file into a dictionary keyed by bare read ID.
    /// Auto-detects v1 vs v2 format via `#format` header.
    /// For PE data, the last mate's entry wins (use `loadRecords` for full fidelity).
    /// Records with invalid ranges are skipped.
    public static func load(from url: URL) throws -> [String: (start: Int, end: Int)] {
        let content = try String(contentsOf: url, encoding: .utf8)
        var positions: [String: (Int, Int)] = [:]
        let isV2 = content.hasPrefix(formatHeader)

        for line in content.split(separator: "\n", omittingEmptySubsequences: true) {
            if line.hasPrefix("#") || line.hasPrefix("read_id") { continue }
            let fields = line.split(separator: "\t")
            if isV2 {
                // v2: read_id, mate, trim_start, trim_end
                guard fields.count >= 4,
                      let start = Int(fields[2]),
                      let end = Int(fields[3]),
                      start >= 0, end >= 0, end > start else { continue }
                positions[String(fields[0])] = (start, end)
            } else if fields.count >= 3,
                      let start = Int(fields[1]),
                      let end = Int(fields[2]),
                      start >= 0, end >= 0, end > start {
                positions[String(fields[0])] = (start, end)
            }
        }
        return positions
    }

    /// Loads trim records as an array (preserving order).
    /// Auto-detects v1 vs v2 format.
    public static func loadRecords(from url: URL) throws -> [FASTQTrimRecord] {
        let content = try String(contentsOf: url, encoding: .utf8)
        var records: [FASTQTrimRecord] = []
        let isV2 = content.hasPrefix(formatHeader)

        for line in content.split(separator: "\n", omittingEmptySubsequences: true) {
            if line.hasPrefix("#") || line.hasPrefix("read_id") { continue }
            let fields = line.split(separator: "\t")
            if isV2 {
                guard fields.count >= 4,
                      let mate = Int(fields[1]),
                      let start = Int(fields[2]),
                      let end = Int(fields[3]),
                      start >= 0, end >= 0, end > start else { continue }
                records.append(FASTQTrimRecord(readID: String(fields[0]), mate: mate, trimStart: start, trimEnd: end))
            } else if fields.count >= 3,
                      let start = Int(fields[1]),
                      let end = Int(fields[2]),
                      start >= 0, end >= 0, end > start {
                records.append(FASTQTrimRecord(readID: String(fields[0]), trimStart: start, trimEnd: end))
            }
        }
        return records
    }

    /// Composes two sets of trim positions.
    ///
    /// When a trim-of-trim chain exists, child positions are relative to the parent's
    /// trimmed sequence. This computes absolute positions relative to the root FASTQ.
    ///
    /// - Parameters:
    ///   - parent: Trim positions from the parent operation (absolute, relative to root).
    ///   - child: Trim positions from the child operation (relative to parent's trimmed output).
    /// - Returns: Composed absolute positions for reads present in both sets.
    public static func compose(
        parent: [String: (start: Int, end: Int)],
        child: [String: (start: Int, end: Int)]
    ) -> [String: (start: Int, end: Int)] {
        var result: [String: (start: Int, end: Int)] = [:]
        for (readID, childPos) in child {
            guard let parentPos = parent[readID] else { continue }
            let absoluteStart = parentPos.start + childPos.start
            let absoluteEnd = min(parentPos.start + childPos.end, parentPos.end)
            guard absoluteEnd > absoluteStart else { continue }
            result[readID] = (absoluteStart, absoluteEnd)
        }
        return result
    }
}

// MARK: - Sample Provenance

/// Tracks the origin, preparation, and processing history of a sample.
/// Stored in the manifest for traceability across the derivative lineage.
public struct SampleProvenance: Codable, Sendable, Equatable {
    /// Sample identifier (e.g., lab sample ID, accession number).
    public let sampleID: String?
    /// Organism or species name.
    public let organism: String?
    /// Tissue or sample type.
    public let tissue: String?
    /// Library preparation method (e.g., "SQK-LSK114", "Nextera XT").
    public let libraryPrep: String?
    /// Sequencing instrument (e.g., "MinION", "NovaSeq 6000").
    public let instrument: String?
    /// Sequencing run ID or flow cell ID.
    public let runID: String?
    /// Date the sample was sequenced.
    public let sequencingDate: Date?
    /// Free-form notes.
    public let notes: String?

    public init(
        sampleID: String? = nil,
        organism: String? = nil,
        tissue: String? = nil,
        libraryPrep: String? = nil,
        instrument: String? = nil,
        runID: String? = nil,
        sequencingDate: Date? = nil,
        notes: String? = nil
    ) {
        self.sampleID = sampleID
        self.organism = organism
        self.tissue = tissue
        self.libraryPrep = libraryPrep
        self.instrument = instrument
        self.runID = runID
        self.sequencingDate = sequencingDate
        self.notes = notes
    }
}

// MARK: - Payload Checksum

/// SHA-256 checksums for verifying payload integrity.
public struct PayloadChecksum: Codable, Sendable, Equatable {
    /// Filename → hex-encoded SHA-256 hash.
    public let checksums: [String: String]

    public init(checksums: [String: String] = [:]) {
        self.checksums = checksums
    }

    /// Result of a checksum validation.
    public enum ValidationResult: Sendable, Equatable {
        /// No checksum recorded for this file — validation was not performed.
        case notRecorded
        /// Checksum matches the expected value.
        case valid
        /// Checksum does not match the expected value.
        case invalid
    }

    /// Validates that a file's contents match the recorded checksum.
    public func validate(filename: String, data: Data) -> ValidationResult {
        guard let expected = checksums[filename] else { return .notRecorded }
        let actual = Self.sha256Hex(data)
        return actual == expected ? .valid : .invalid
    }

    /// Computes the SHA-256 hex string for the given data.
    public static func sha256Hex(_ data: Data) -> String {
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    /// Computes the SHA-256 hex string by streaming from a file handle (memory-efficient for large files).
    public static func sha256Hex(fileAt url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        let chunkSize = 65536
        while true {
            let chunk = handle.readData(ofLength: chunkSize)
            if chunk.isEmpty { break }
            hasher.update(data: chunk)
        }
        let digest = hasher.finalize()
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}

// MARK: - Derived Bundle Manifest

/// Pointer manifest saved in derived `.lungfishfastq` bundles.
///
/// Derived bundles do not duplicate FASTQ payload bytes. They store either
/// a read ID list (subset operations) or trim position records (trim operations),
/// plus lineage metadata pointing back to a parent/root bundle.
public struct FASTQDerivedBundleManifest: Codable, Sendable, Equatable {
    /// Current schema version. Increment when making breaking changes to the manifest format.
    public static let currentSchemaVersion = 2

    /// Schema version of this manifest. Version 1 = original, 2 = added orientMapFilename to demuxedVirtual.
    public let schemaVersion: Int

    public let id: UUID
    public let name: String
    public let createdAt: Date

    /// Relative path from this bundle to the immediate parent bundle.
    public let parentBundleRelativePath: String

    /// Relative path from this bundle to the root (physical FASTQ payload) bundle.
    public let rootBundleRelativePath: String

    /// FASTQ filename inside the root bundle (first file for multi-file bundles).
    public let rootFASTQFilename: String

    /// What this derivative stores on disk (read ID list or trim positions).
    public let payload: FASTQDerivativePayload

    /// Sequence of operations from root to this dataset (inclusive of latest operation).
    public let lineage: [FASTQDerivativeOperation]

    /// Latest operation used to produce this dataset.
    public let operation: FASTQDerivativeOperation

    /// Cached dataset statistics for immediate dashboard/inspector rendering.
    public let cachedStatistics: FASTQDatasetStatistics

    /// Pairing mode inherited at generation time.
    public let pairingMode: IngestionMetadata.PairingMode?

    /// Read classification for mixed-type bundles (after merge/repair).
    /// Nil for homogeneous bundles.
    public let readClassification: ReadClassification?

    /// Batch operation ID linking this bundle to a batch processing run.
    /// Nil for individually-created derivatives.
    public let batchOperationID: UUID?

    /// The sequence format of the root payload file.
    /// Nil for legacy manifests (assumed FASTQ).
    public let sequenceFormat: SequenceFormat?

    /// Sample provenance metadata (organism, library prep, instrument, etc.).
    /// Nil for bundles without sample-level metadata.
    public let provenance: SampleProvenance?

    /// SHA-256 checksums of payload files for integrity verification.
    /// Nil for bundles without checksum tracking.
    public let payloadChecksums: PayloadChecksum?

    /// Materialization lifecycle state. Nil for legacy manifests (treated as virtual
    /// for derived bundles, materialized for bundles with full/fullPaired/fullMixed payloads).
    public var materializationState: MaterializationState?

    /// Resolved materialization state, applying defaults for nil values and
    /// treating stale `.materializing` states (from crashed sessions) as `.virtual`.
    public var resolvedState: MaterializationState {
        if let state = materializationState {
            if case .materializing = state {
                return .virtual
            }
            return state
        }
        switch payload {
        case .full, .fullPaired, .fullMixed, .fullFASTA:
            return .materialized(checksum: payloadChecksums?.checksums.values.first ?? "")
        default:
            return .virtual
        }
    }

    /// Whether this bundle has been materialized to a full FASTQ on disk.
    public var isMaterialized: Bool {
        if case .materialized = resolvedState { return true }
        return false
    }

    /// Checks whether the root FASTQ file has been modified after this derivative was created.
    ///
    /// A stale derivative means the root data has changed since this bundle's creation,
    /// so the derivative's pointer-based or materialized data may no longer be correct.
    /// Returns `nil` if the root bundle cannot be resolved.
    public func isStale(bundleURL: URL) -> Bool? {
        let rootURL = FASTQBundle.resolveBundle(relativePath: rootBundleRelativePath, from: bundleURL)
        let rootFASTQ = rootURL.appendingPathComponent(rootFASTQFilename)

        guard let attrs = try? FileManager.default.attributesOfItem(atPath: rootFASTQ.path),
              let rootModDate = attrs[.modificationDate] as? Date else {
            return nil
        }
        return rootModDate > createdAt
    }

    public init(
        id: UUID = UUID(),
        name: String,
        createdAt: Date = Date(),
        parentBundleRelativePath: String,
        rootBundleRelativePath: String,
        rootFASTQFilename: String,
        payload: FASTQDerivativePayload = .subset(readIDListFilename: "read-ids.txt"),
        lineage: [FASTQDerivativeOperation],
        operation: FASTQDerivativeOperation,
        cachedStatistics: FASTQDatasetStatistics,
        pairingMode: IngestionMetadata.PairingMode?,
        readClassification: ReadClassification? = nil,
        batchOperationID: UUID? = nil,
        sequenceFormat: SequenceFormat? = .fastq,
        provenance: SampleProvenance? = nil,
        payloadChecksums: PayloadChecksum? = nil,
        materializationState: MaterializationState? = nil
    ) {
        self.schemaVersion = Self.currentSchemaVersion
        self.id = id
        self.name = name
        self.createdAt = createdAt
        self.parentBundleRelativePath = parentBundleRelativePath
        self.rootBundleRelativePath = rootBundleRelativePath
        self.rootFASTQFilename = rootFASTQFilename
        self.payload = payload
        self.lineage = lineage
        self.operation = operation
        self.cachedStatistics = cachedStatistics
        self.pairingMode = pairingMode
        self.readClassification = readClassification
        self.batchOperationID = batchOperationID
        self.sequenceFormat = sequenceFormat
        self.provenance = provenance
        self.payloadChecksums = payloadChecksums
        self.materializationState = materializationState
    }

    // Custom decoding for backward compatibility with schema version 1 manifests
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.schemaVersion = try container.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        self.id = try container.decode(UUID.self, forKey: .id)
        self.name = try container.decode(String.self, forKey: .name)
        self.createdAt = try container.decode(Date.self, forKey: .createdAt)
        self.parentBundleRelativePath = try container.decode(String.self, forKey: .parentBundleRelativePath)
        self.rootBundleRelativePath = try container.decode(String.self, forKey: .rootBundleRelativePath)
        self.rootFASTQFilename = try container.decode(String.self, forKey: .rootFASTQFilename)
        self.payload = try container.decode(FASTQDerivativePayload.self, forKey: .payload)
        self.lineage = try container.decode([FASTQDerivativeOperation].self, forKey: .lineage)
        self.operation = try container.decode(FASTQDerivativeOperation.self, forKey: .operation)
        self.cachedStatistics = try container.decode(FASTQDatasetStatistics.self, forKey: .cachedStatistics)
        self.pairingMode = try container.decodeIfPresent(IngestionMetadata.PairingMode.self, forKey: .pairingMode)
        self.readClassification = try container.decodeIfPresent(ReadClassification.self, forKey: .readClassification)
        self.batchOperationID = try container.decodeIfPresent(UUID.self, forKey: .batchOperationID)
        self.sequenceFormat = try container.decodeIfPresent(SequenceFormat.self, forKey: .sequenceFormat)
        self.provenance = try container.decodeIfPresent(SampleProvenance.self, forKey: .provenance)
        self.payloadChecksums = try container.decodeIfPresent(PayloadChecksum.self, forKey: .payloadChecksums)
        self.materializationState = try container.decodeIfPresent(MaterializationState.self, forKey: .materializationState)
    }

    // MARK: - Referential Integrity Validation

    /// Issues found during referential integrity validation.
    public struct IntegrityReport: Sendable, Equatable {
        public let parentBundleExists: Bool
        public let rootBundleExists: Bool
        public let rootPayloadFileExists: Bool
        public let payloadFilesExist: Bool
        public let checksumValid: Bool?  // nil if no checksums recorded

        public var isValid: Bool {
            parentBundleExists && rootBundleExists && rootPayloadFileExists && payloadFilesExist && (checksumValid ?? true)
        }

        public var issues: [String] {
            var result: [String] = []
            if !parentBundleExists { result.append("Parent bundle not found") }
            if !rootBundleExists { result.append("Root bundle not found") }
            if !rootPayloadFileExists { result.append("Root payload file not found") }
            if !payloadFilesExist { result.append("Payload sidecar file(s) missing") }
            if let valid = checksumValid, !valid { result.append("Payload checksum mismatch") }
            return result
        }
    }

    /// Validates referential integrity of this manifest relative to the bundle at `bundleURL`.
    public func validateIntegrity(bundleURL: URL) -> IntegrityReport {
        let fm = FileManager.default

        // Resolve relative paths from the bundle's containing directory.
        // Relative paths like "../root.lungfishfastq" are relative to the bundle location.
        let containerDir = bundleURL.deletingLastPathComponent()
        let parentURL = containerDir.appendingPathComponent(parentBundleRelativePath).standardizedFileURL
        let rootURL = containerDir.appendingPathComponent(rootBundleRelativePath).standardizedFileURL

        let parentExists = fm.fileExists(atPath: parentURL.path)
        let rootExists = fm.fileExists(atPath: rootURL.path)
        let rootPayloadExists = rootExists && fm.fileExists(
            atPath: rootURL.appendingPathComponent(rootFASTQFilename).path
        )

        // Check payload sidecar files exist
        let payloadExists: Bool
        switch payload {
        case .subset(let filename):
            payloadExists = fm.fileExists(atPath: bundleURL.appendingPathComponent(filename).path)
        case .trim(let filename):
            payloadExists = fm.fileExists(atPath: bundleURL.appendingPathComponent(filename).path)
        case .full(let filename):
            payloadExists = fm.fileExists(atPath: bundleURL.appendingPathComponent(filename).path)
        case .fullFASTA(let filename):
            payloadExists = fm.fileExists(atPath: bundleURL.appendingPathComponent(filename).path)
        case .fullPaired(let r1, let r2):
            payloadExists = fm.fileExists(atPath: bundleURL.appendingPathComponent(r1).path)
                && fm.fileExists(atPath: bundleURL.appendingPathComponent(r2).path)
        case .fullMixed(let classification):
            payloadExists = classification.files.map(\.filename).allSatisfy {
                fm.fileExists(atPath: bundleURL.appendingPathComponent($0).path)
            }
        case .demuxedVirtual(_, let readIDFile, let previewFile, let trimFile, let orientFile):
            var exists = fm.fileExists(atPath: bundleURL.appendingPathComponent(readIDFile).path)
                && fm.fileExists(atPath: bundleURL.appendingPathComponent(previewFile).path)
            if let trimFile { exists = exists && fm.fileExists(atPath: bundleURL.appendingPathComponent(trimFile).path) }
            if let orientFile { exists = exists && fm.fileExists(atPath: bundleURL.appendingPathComponent(orientFile).path) }
            payloadExists = exists
        case .demuxGroup:
            payloadExists = true // Directory-level, always valid
        case .orientMap(let mapFile, let previewFile):
            payloadExists = fm.fileExists(atPath: bundleURL.appendingPathComponent(mapFile).path)
                && fm.fileExists(atPath: bundleURL.appendingPathComponent(previewFile).path)
        }

        // Validate checksums if present (streams file in chunks to avoid loading large files into memory)
        var checksumValid: Bool?
        if let checksums = payloadChecksums, !checksums.checksums.isEmpty {
            checksumValid = true
            for (filename, expectedHash) in checksums.checksums {
                let fileURL = bundleURL.appendingPathComponent(filename)
                guard let actualHash = try? PayloadChecksum.sha256Hex(fileAt: fileURL) else {
                    checksumValid = false
                    break
                }
                if actualHash != expectedHash {
                    checksumValid = false
                    break
                }
            }
        }

        return IntegrityReport(
            parentBundleExists: parentExists,
            rootBundleExists: rootExists,
            rootPayloadFileExists: rootPayloadExists,
            payloadFilesExist: payloadExists,
            checksumValid: checksumValid
        )
    }

    // MARK: - Methods Text Export

    /// Generates a publication-ready methods paragraph describing the processing pipeline.
    ///
    /// Includes tool names, versions, and non-default parameters for each step.
    /// Optionally includes per-step read count statistics.
    ///
    /// Example output:
    /// ```
    /// Raw reads were processed using the following pipeline: Quality trimming was
    /// performed using fastp (Q20, window size 4, cut-right mode). Adapter sequences
    /// were removed using fastp with auto-detection. 150,000 reads (95.2%) were
    /// retained after processing.
    /// ```
    public func generateMethodsText(includeStats: Bool = true) -> String {
        let allSteps = lineage + [operation]
        guard !allSteps.isEmpty else { return "No processing steps were applied." }

        var sentences: [String] = []
        sentences.append("Raw reads were processed using the following pipeline:")

        for step in allSteps {
            sentences.append(step.methodsSentence)
        }

        if includeStats {
            let stats = cachedStatistics
            if stats.readCount > 0 {
                let formatter = NumberFormatter()
                formatter.numberStyle = .decimal
                let readStr = formatter.string(from: NSNumber(value: stats.readCount)) ?? "\(stats.readCount)"
                let meanQ = String(format: "%.1f", stats.meanQuality)
                let meanLen = String(format: "%.0f", stats.meanReadLength)
                sentences.append(
                    "\(readStr) reads were retained after processing"
                    + " (mean quality: \(meanQ), mean length: \(meanLen) bp)."
                )
            }
        }

        return sentences.joined(separator: " ")
    }
}

// MARK: - Methods Text for Individual Operations

extension FASTQDerivativeOperation {
    /// Generates a single methods-text sentence for this operation.
    public var methodsSentence: String {
        let tool = toolUsed.map { name in
            if let version = toolVersion {
                return " using \(name) v\(version)"
            }
            return " using \(name)"
        } ?? ""

        switch kind {
        case .qualityTrim:
            let q = qualityThreshold ?? 20
            let w = windowSize ?? 4
            let mode = qualityTrimMode ?? .cutRight
            return "Quality trimming was performed\(tool) (Q\(q), window size \(w), \(mode.rawValue) mode)."

        case .adapterTrim:
            let mode = adapterMode ?? .autoDetect
            switch mode {
            case .autoDetect:
                return "Adapter sequences were removed\(tool) with auto-detection."
            case .specified:
                return "Adapter sequences were removed\(tool) with specified adapter sequence."
            case .fastaFile:
                return "Adapter sequences were removed\(tool) using a custom adapter FASTA file."
            }

        case .fixedTrim:
            let f = trimFrom5Prime ?? 0
            let t = trimFrom3Prime ?? 0
            return "Fixed trimming was applied\(tool) (\(f) bp from 5' end, \(t) bp from 3' end)."

        case .primerRemoval:
            let mode = primerTrimMode ?? .fivePrime
            let err = primerErrorRate.map { String(format: "%.0f%%", $0 * 100) } ?? "12%"
            let overlap = primerMinimumOverlap ?? 12
            return "Primer sequences were removed\(tool) (\(mode.rawValue) mode, error rate \(err), minimum overlap \(overlap) bp)."

        case .contaminantFilter:
            let mode = contaminantFilterMode ?? .phix
            switch mode {
            case .phix:
                return "PhiX contaminant sequences were filtered\(tool)."
            case .custom:
                let ref = contaminantReferenceFasta ?? "custom reference"
                return "Contaminant sequences were filtered\(tool) against \(ref)."
            }

        case .pairedEndMerge:
            let s = mergeStrictness ?? .normal
            let o = mergeMinOverlap ?? 12
            return "Paired-end reads were merged\(tool) (\(s.rawValue) mode, minimum overlap \(o) bp)."

        case .pairedEndRepair:
            return "Paired-end reads were repaired\(tool)."

        case .lengthFilter:
            let minStr = minLength.map { "\($0) bp" } ?? "none"
            let maxStr = maxLength.map { "\($0) bp" } ?? "none"
            return "Reads were filtered by length\(tool) (min: \(minStr), max: \(maxStr))."

        case .subsampleProportion:
            let p = proportion.map { String(format: "%.2f%%", $0 * 100) } ?? "unknown"
            return "Reads were randomly subsampled\(tool) to \(p) of the original dataset."

        case .subsampleCount:
            let n = count.map(String.init) ?? "unknown"
            return "Reads were randomly subsampled\(tool) to \(n) reads."

        case .deduplicate:
            let subs = deduplicateSubstitutions ?? 0
            if deduplicateOptical == true {
                let dist = deduplicateOpticalDistance ?? 40
                return "Optical duplicate reads were removed\(tool) (substitution tolerance: \(subs), pixel distance: \(dist))."
            }
            return "Duplicate reads were removed\(tool) by sequence identity (substitution tolerance: \(subs))."

        case .errorCorrection:
            let k = errorCorrectionKmerSize ?? 50
            return "Error correction was performed\(tool) (k-mer size \(k))."

        case .orient:
            let ref = orientReferencePath ?? "reference"
            let w = orientWordLength ?? 12
            return "Reads were oriented\(tool) against \(ref) (word length \(w))."

        case .demultiplex:
            let sample = sampleName ?? barcodeID ?? "unknown"
            return "Reads were demultiplexed\(tool) (sample: \(sample))."

        case .searchText, .searchMotif:
            let q = query ?? ""
            return "Reads were filtered by sequence search\(tool) (query: \(q))."

        case .interleaveReformat:
            let dir = interleaveDirection ?? .interleave
            return "Reads were reformatted\(tool) (\(dir.rawValue))."

        case .reverseComplement:
            return "Sequences were reverse-complemented\(tool)."

        case .translate:
            let offset = translationFrameOffset ?? 0
            return "Sequences were translated\(tool) in frame \(offset + 1)."

        case .sequencePresenceFilter:
            let end = adapterFilterSearchEnd ?? .fivePrime
            let keep = adapterFilterKeepMatched ?? true
            let searchRC = adapterFilterSearchReverseComplement ?? false
            let endLabel = end == .fivePrime ? "5'" : "3'"
            let action = keep ? "retained" : "removed"
            let overlap = adapterFilterMinOverlap ?? 16
            let rcNote = searchRC ? ", including reverse complement" : ""
            return "Reads were filtered\(tool) by \(endLabel) sequence presence (minimum overlap \(overlap) bp\(rcNote), matching reads \(action))."

        case .humanReadScrub:
            let dbID = humanScrubDatabaseID ?? "human-scrubber"
            let mode = humanScrubRemoveReads == true ? "removed" : "masked with N"
            return "Human reads were identified\(tool) using the '\(dbID)' k-mer database and \(mode)."
        }
    }
}
