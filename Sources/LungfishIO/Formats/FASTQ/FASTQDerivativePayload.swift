// FASTQDerivativePayload.swift - Pointer-based FASTQ derivative datasets
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import CryptoKit

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

public enum FASTQDerivativeOperationKind: String, Codable, Sendable, CaseIterable {
    // Subset operations (produce read ID list)
    case subsampleProportion
    case subsampleCount
    case lengthFilter
    case searchText
    case searchMotif
    case deduplicate

    // Trim operations (produce trim position records)
    case fastpTrim
    case qualityTrim
    case adapterTrim
    case fixedTrim

    // BBTools operations
    case contaminantFilter
    /// bbduk entropy filter: discards low-complexity reads (homopolymers, tandem repeats).
    case lowComplexityFilter
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

    // Ribosomal RNA classification/removal using Deacon
    case ribosomalRNAFilter

    /// Whether this operation produces a subset (read IDs) or trim (positions).
    public var isSubsetOperation: Bool {
        switch self {
        case .subsampleProportion, .subsampleCount, .lengthFilter,
             .searchText, .searchMotif, .contaminantFilter,
             .lowComplexityFilter,
             .sequencePresenceFilter:
            return true
        case .deduplicate:
            return false  // clumpify writes a full output file
        case .fastpTrim, .qualityTrim, .adapterTrim, .fixedTrim, .primerRemoval:
            return false
        case .ribosomalRNAFilter:
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
             .deduplicate, .humanReadScrub, .reverseComplement, .translate,
             .ribosomalRNAFilter:
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
             .fixedTrim, .contaminantFilter, .lowComplexityFilter, .primerRemoval,
             .reverseComplement, .translate,
             .demultiplex, .orient, .sequencePresenceFilter,
             .ribosomalRNAFilter,
             .humanReadScrub:
            return true
        case .fastpTrim, .qualityTrim, .pairedEndMerge,
             .pairedEndRepair, .errorCorrection,
             .interleaveReformat:
            return false
        }
    }
}
