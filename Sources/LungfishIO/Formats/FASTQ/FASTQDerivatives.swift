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

/// Deduplication key strategy.
public enum FASTQDeduplicateMode: String, Codable, Sendable, CaseIterable {
    case identifier
    case description
    case sequence
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

    // Demultiplexing
    case demultiplex

    // Orientation
    case orient

    /// Whether this operation produces a subset (read IDs) or trim (positions).
    public var isSubsetOperation: Bool {
        switch self {
        case .subsampleProportion, .subsampleCount, .lengthFilter,
             .searchText, .searchMotif, .deduplicate, .contaminantFilter:
            return true
        case .qualityTrim, .adapterTrim, .fixedTrim:
            return false
        case .pairedEndMerge, .pairedEndRepair, .primerRemoval,
             .errorCorrection, .interleaveReformat, .demultiplex,
             .orient:
            return false
        }
    }

    /// Whether this operation produces a full materialized FASTQ (content-transforming).
    public var isFullOperation: Bool {
        switch self {
        case .pairedEndMerge, .pairedEndRepair, .primerRemoval,
             .errorCorrection, .interleaveReformat, .demultiplex:
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
             .searchText, .searchMotif, .deduplicate, .fixedTrim,
             .orient, .contaminantFilter:
            return true
        case .qualityTrim, .adapterTrim, .pairedEndMerge,
             .pairedEndRepair, .primerRemoval, .errorCorrection,
             .interleaveReformat, .demultiplex:
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
    public var deduplicateMode: FASTQDeduplicateMode?
    public var pairedAware: Bool?

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

    // Error correction parameters
    public var errorCorrectionKmerSize: Int?

    // Interleave parameters
    public var interleaveDirection: FASTQInterleaveDirection?

    // Demultiplex parameters
    public var barcodeID: String?
    public var sampleName: String?
    public var demuxRunID: UUID?

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
        deduplicateMode: FASTQDeduplicateMode? = nil,
        pairedAware: Bool? = nil,
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
        errorCorrectionKmerSize: Int? = nil,
        interleaveDirection: FASTQInterleaveDirection? = nil,
        barcodeID: String? = nil,
        sampleName: String? = nil,
        demuxRunID: UUID? = nil,
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
        self.deduplicateMode = deduplicateMode
        self.pairedAware = pairedAware
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
        self.errorCorrectionKmerSize = errorCorrectionKmerSize
        self.interleaveDirection = interleaveDirection
        self.barcodeID = barcodeID
        self.sampleName = sampleName
        self.demuxRunID = demuxRunID
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
            let src = primerSource ?? .literal
            let k = primerKmerSize ?? 23
            return "primer-\(src.rawValue)-k\(k)"
        case .errorCorrection:
            let k = errorCorrectionKmerSize ?? 50
            return "ecc-k\(k)"
        case .interleaveReformat:
            let dir = interleaveDirection ?? .interleave
            return "\(dir.rawValue)"
        case .demultiplex:
            if let barcodeID {
                return "demux-\(barcodeID)"
            }
            return "demultiplex"
        case .orient:
            return "orient"
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
            let modeString = deduplicateMode?.rawValue ?? FASTQDeduplicateMode.identifier.rawValue
            if pairedAware == true {
                return "Deduplicate by \(modeString) (paired-aware)"
            }
            return "Deduplicate by \(modeString)"
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
            let src = primerSource ?? .literal
            let k = primerKmerSize ?? 23
            switch src {
            case .literal:
                let seq = primerLiteralSequence ?? ""
                let preview = seq.prefix(20)
                return "Primer removal (literal: \(preview)\(seq.count > 20 ? "…" : ""), k=\(k))"
            case .reference:
                let ref = primerReferenceFasta ?? "reference"
                return "Primer removal (ref: \(ref), k=\(k))"
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

    /// FASTQ filename inside the root bundle.
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
        payloadChecksums: PayloadChecksum? = nil
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
}
