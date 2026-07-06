// FASTQDerivativeOperation.swift - Pointer-based FASTQ derivative datasets
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import CryptoKit

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
    public var mergeCountDuplicates: Bool?

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

    // Ribosomal RNA filter parameters
    /// Which rRNA filter read class outputs were retained.
    public var riboDetectorRetention: FASTQRiboDetectorRetention?
    /// Legacy assurance setting preserved for bundle compatibility.
    public var riboDetectorEnsure: FASTQRiboDetectorEnsure?

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
        mergeCountDuplicates: Bool? = nil,
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
        riboDetectorRetention: FASTQRiboDetectorRetention? = nil,
        riboDetectorEnsure: FASTQRiboDetectorEnsure? = nil,
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
        self.mergeCountDuplicates = mergeCountDuplicates
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
        self.riboDetectorRetention = riboDetectorRetention
        self.riboDetectorEnsure = riboDetectorEnsure
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
        case .fastpTrim:
            let q = qualityThreshold ?? 20
            let w = windowSize ?? 4
            let mode = qualityTrimMode ?? .cutRight
            let adapter = adapterMode ?? .autoDetect
            return "fastp adapter + quality trim Q\(q) w\(w) (\(mode.rawValue), \(adapter.rawValue))"
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
        case .ribosomalRNAFilter:
            let retention = riboDetectorRetention ?? .nonRRNA
            return "deacon-ribo-\(retention.rawValue)"
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
        case .fastpTrim:
            let q = qualityThreshold ?? 20
            let w = windowSize ?? 4
            let mode = qualityTrimMode ?? .cutRight
            let adapter = adapterMode ?? .autoDetect
            return "fastp adapter + quality trim Q\(q) w\(w) (\(mode.rawValue), \(adapter.rawValue))"
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
                let toolLabel = "cutadapt"
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
        case .ribosomalRNAFilter:
            let retention = riboDetectorRetention ?? .nonRRNA
            return "Deacon rRNA filter (retain: \(retention.displayName))"
        }
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

        case .fastpTrim:
            let q = qualityThreshold ?? 20
            let w = windowSize ?? 4
            let mode = qualityTrimMode ?? .cutRight
            let adapter = adapterMode ?? .autoDetect
            return "Adapter detection/removal and quality trimming were performed together\(tool) in one fastp pass (Q\(q), window size \(w), \(mode.rawValue) mode, adapter \(adapter.rawValue))."

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
            let counted = mergeCountDuplicates == true
                ? "; duplicate merged reads encoded as size=N"
                : ""
            return "Paired-end reads were merged\(tool) (\(s.rawValue) mode, minimum overlap \(o) bp\(counted))."

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

        case .ribosomalRNAFilter:
            let retention = riboDetectorRetention ?? .nonRRNA
            return "Ribosomal RNA sequences were filtered\(tool) with Deacon ribokmers, retaining \(retention.displayName) reads."
        }
    }
}
