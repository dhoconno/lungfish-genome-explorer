// AlignedRead.swift - Data model for aligned sequencing reads
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation

// MARK: - CIGAROperation

/// A single CIGAR operation from a SAM/BAM alignment record.
///
/// CIGAR operations describe how a read aligns to the reference sequence.
/// Each operation has a type and a length (number of bases/positions affected).
///
/// ## Reference
///
/// See the [SAM specification](https://samtools.github.io/hts-specs/SAMv1.pdf)
/// for full details on CIGAR operations.
public struct CIGAROperation: Sendable, Equatable {

    /// CIGAR operation type.
    public enum Op: Character, Sendable, CaseIterable {
        /// Alignment match (can be sequence match or mismatch).
        case match = "M"
        /// Insertion to the reference.
        case insertion = "I"
        /// Deletion from the reference.
        case deletion = "D"
        /// Skipped region from the reference (e.g., intron in RNA-seq).
        case skip = "N"
        /// Soft clip (bases present in read but not aligned).
        case softClip = "S"
        /// Hard clip (bases not present in read).
        case hardClip = "H"
        /// Padding (silent deletion from padded reference).
        case padding = "P"
        /// Sequence match (= in extended CIGAR).
        case seqMatch = "="
        /// Sequence mismatch (X in extended CIGAR).
        case seqMismatch = "X"
    }

    /// The operation type.
    public let op: Op

    /// Number of bases/positions affected.
    public let length: Int

    /// Whether this operation consumes reference bases.
    public var consumesReference: Bool {
        switch op {
        case .match, .deletion, .skip, .seqMatch, .seqMismatch: return true
        case .insertion, .softClip, .hardClip, .padding: return false
        }
    }

    /// Whether this operation consumes query (read) bases.
    public var consumesQuery: Bool {
        switch op {
        case .match, .insertion, .softClip, .seqMatch, .seqMismatch: return true
        case .deletion, .skip, .hardClip, .padding: return false
        }
    }

    /// Maximum operation length to prevent DoS from malformed CIGAR strings.
    public static let maxOperationLength = 1_000_000_000

    public init(op: Op, length: Int) {
        self.op = op
        self.length = min(length, CIGAROperation.maxOperationLength)
    }
}

// MARK: - CIGAR Parsing

extension CIGAROperation {

    /// Parses a CIGAR string into an array of operations.
    ///
    /// - Parameter cigarString: A CIGAR string (e.g., "75M2I73M")
    /// - Returns: Array of CIGAR operations, or nil if the string is invalid
    public static func parse(_ cigarString: String) -> [CIGAROperation]? {
        if cigarString == "*" { return [] }

        var operations: [CIGAROperation] = []
        var numberBuffer = ""

        for char in cigarString {
            if char.isNumber {
                numberBuffer.append(char)
            } else if let op = Op(rawValue: char), let length = Int(numberBuffer), length > 0 {
                operations.append(CIGAROperation(op: op, length: length))
                numberBuffer = ""
            } else {
                return nil // Invalid character or missing number
            }
        }

        // If there are leftover digits without an operator, the string is malformed
        if !numberBuffer.isEmpty { return nil }

        return operations
    }
}

// MARK: - AlignedRead

/// A single aligned read from a SAM/BAM file.
///
/// Represents one alignment record with all fields needed for visualization:
/// position, CIGAR, sequence, qualities, and mate-pair information.
///
/// ## Coordinate System
///
/// Positions are 0-based, consistent with the internal coordinate system
/// used throughout Lungfish. SAM files use 1-based positions; conversion
/// happens during parsing.
///
/// ## Usage
///
/// ```swift
/// let reads = try SAMParser.parse(samOutput)
/// for read in reads {
///     let end = read.alignmentEnd
///     if read.isReverse {
///         // Draw on reverse strand
///     }
/// }
/// ```
public struct AlignedRead: Sendable, Identifiable {

    /// Unique identifier for this read instance.
    public let id: UUID

    /// Read name (QNAME field).
    public let name: String

    /// SAM bitwise flag.
    public let flag: UInt16

    /// Reference chromosome name.
    public let chromosome: String

    /// 0-based leftmost mapping position.
    public let position: Int

    /// Mapping quality (0-255).
    public let mapq: UInt8

    /// CIGAR alignment operations.
    public let cigar: [CIGAROperation]

    /// Read nucleotide sequence.
    public let sequence: String

    /// Per-base Phred quality scores.
    public let qualities: [UInt8]

    /// Mate's reference chromosome (nil if unpaired or mate unmapped).
    public let mateChromosome: String?

    /// Mate's 0-based position (nil if unpaired or mate unmapped).
    public let matePosition: Int?

    /// Observed template/insert size.
    public let insertSize: Int

    /// Read group from RG tag (nil if not present).
    public let readGroup: String?

    /// MD tag string for mismatch detection without reference (nil if not present).
    public let mdTag: String?

    /// Number of mismatches (NM tag, nil if not present).
    public let editDistance: Int?

    /// Supplementary alignment records (SA tag, nil if not present).
    public let supplementaryAlignments: String?

    /// Number of reported hits (NH tag, nil if not present).
    public let numHits: Int?

    /// Strand of gene for RNA-seq (XS tag, nil if not present).
    public let strandTag: String?

    /// Cached length of reference consumed by this alignment (avoids repeated CIGAR reduce).
    public let referenceLength: Int

    /// Cached 0-based exclusive end position on the reference.
    public let alignmentEnd: Int

    // MARK: - Computed Properties

    /// Length of the read query sequence.
    public var queryLength: Int {
        cigar.reduce(0) { $0 + ($1.consumesQuery ? $1.length : 0) }
    }

    /// Insert size classification for paired-end coloring.
    public enum InsertSizeClass: Sendable {
        /// Normal insert size (within expected range)
        case normal
        /// Insert size smaller than expected (possible deletion in sample)
        case tooSmall
        /// Insert size larger than expected (possible insertion in sample)
        case tooLarge
        /// Reads mapped to different chromosomes
        case interchromosomal
        /// Mate on same strand (unexpected orientation, possible inversion)
        case abnormalOrientation
        /// Not applicable (unpaired or unmapped mate)
        case notApplicable
    }

    /// Classifies this read's insert size relative to the expected range.
    ///
    /// - Parameters:
    ///   - expectedInsertSize: Expected median insert size
    ///   - stdDevs: Number of standard deviations for normal range (default: 3)
    ///   - stdDev: Estimated standard deviation of insert size
    /// - Returns: Classification of the insert size
    public func insertSizeClass(expectedInsertSize: Int = 400, stdDev: Int = 100, stdDevs: Double = 3) -> InsertSizeClass {
        guard isPaired, !isMateUnmapped else { return .notApplicable }

        // TLEN=0 means insert size not computable (SAM spec §1.4)
        guard insertSize != 0 else { return .notApplicable }

        // Inter-chromosomal
        if let mateChr = mateChromosome, mateChr != chromosome {
            return .interchromosomal
        }

        // Abnormal orientation: both reads on same strand
        if isReverse == isMateReverse {
            return .abnormalOrientation
        }

        let absInsert = abs(insertSize)
        let lowerBound = max(0, expectedInsertSize - Int(stdDevs * Double(stdDev)))
        let upperBound = expectedInsertSize + Int(stdDevs * Double(stdDev))

        if absInsert < lowerBound {
            return .tooSmall
        } else if absInsert > upperBound {
            return .tooLarge
        }
        return .normal
    }

    // MARK: - Flag Properties

    /// Read is paired in sequencing.
    public var isPaired: Bool { flag & 0x1 != 0 }

    /// Read is mapped in a proper pair.
    public var isProperPair: Bool { flag & 0x2 != 0 }

    /// Read is unmapped.
    public var isUnmapped: Bool { flag & 0x4 != 0 }

    /// Mate is unmapped.
    public var isMateUnmapped: Bool { flag & 0x8 != 0 }

    /// Read is on the reverse strand.
    public var isReverse: Bool { flag & 0x10 != 0 }

    /// Mate is on the reverse strand.
    public var isMateReverse: Bool { flag & 0x20 != 0 }

    /// This is the first read in a pair.
    public var isFirstInPair: Bool { flag & 0x40 != 0 }

    /// This is the second read in a pair.
    public var isSecondInPair: Bool { flag & 0x80 != 0 }

    /// Alignment is secondary (not primary).
    public var isSecondary: Bool { flag & 0x100 != 0 }

    /// Read failed platform/vendor quality checks.
    public var failedQC: Bool { flag & 0x200 != 0 }

    /// Read is a PCR or optical duplicate.
    public var isDuplicate: Bool { flag & 0x400 != 0 }

    /// Alignment is supplementary.
    public var isSupplementary: Bool { flag & 0x800 != 0 }

    /// Strand of this read.
    public var strand: Strand {
        isReverse ? .reverse : .forward
    }

    // MARK: - Initialization

    public init(
        name: String,
        flag: UInt16,
        chromosome: String,
        position: Int,
        mapq: UInt8,
        cigar: [CIGAROperation],
        sequence: String,
        qualities: [UInt8],
        mateChromosome: String? = nil,
        matePosition: Int? = nil,
        insertSize: Int = 0,
        readGroup: String? = nil,
        mdTag: String? = nil,
        editDistance: Int? = nil,
        supplementaryAlignments: String? = nil,
        numHits: Int? = nil,
        strandTag: String? = nil
    ) {
        self.id = UUID()
        self.name = name
        self.flag = flag
        self.chromosome = chromosome
        self.position = position
        self.mapq = mapq
        self.cigar = cigar
        self.sequence = sequence
        self.qualities = qualities
        self.mateChromosome = mateChromosome
        self.matePosition = matePosition
        self.insertSize = insertSize
        self.readGroup = readGroup
        self.mdTag = mdTag
        self.editDistance = editDistance
        self.supplementaryAlignments = supplementaryAlignments
        self.numHits = numHits
        self.strandTag = strandTag
        // Cache reference length to avoid repeated CIGAR walks (called 4+ times per read per frame)
        let refLen = cigar.reduce(0) { $0 + ($1.consumesReference ? $1.length : 0) }
        self.referenceLength = refLen
        self.alignmentEnd = position + refLen
    }
}

// MARK: - AlignedRead Helpers

extension AlignedRead {

    /// Returns the CIGAR string representation.
    public var cigarString: String {
        if cigar.isEmpty { return "*" }
        return cigar.map { "\($0.length)\($0.op.rawValue)" }.joined()
    }

    /// Iterates over aligned base pairs, yielding (readBase, referenceOffset, operation).
    ///
    /// This is the primary method for base-level rendering. For each aligned position,
    /// it yields the read base, its position on the reference, and the CIGAR operation
    /// that produced the alignment.
    ///
    /// - Parameter handler: Closure called for each aligned position
    public func forEachAlignedBase(
        _ handler: (Character, Int, CIGAROperation.Op) -> Void
    ) {
        var refPos = position
        var queryPos = sequence.startIndex

        for op in cigar {
            switch op.op {
            case .match, .seqMatch, .seqMismatch:
                for _ in 0..<op.length {
                    if queryPos < sequence.endIndex {
                        handler(sequence[queryPos], refPos, op.op)
                        queryPos = sequence.index(after: queryPos)
                    }
                    refPos += 1
                }

            case .insertion:
                // Insertions don't consume reference, but we track the query bases
                for _ in 0..<op.length {
                    if queryPos < sequence.endIndex {
                        queryPos = sequence.index(after: queryPos)
                    }
                }

            case .deletion, .skip:
                // Deletions/skips consume reference but not query
                refPos += op.length

            case .softClip:
                for _ in 0..<op.length {
                    if queryPos < sequence.endIndex {
                        queryPos = sequence.index(after: queryPos)
                    }
                }

            case .hardClip, .padding:
                break
            }
        }
    }

    /// Returns insertion positions and their inserted sequences.
    ///
    /// Each tuple contains (referencePosition, insertedBases) where the reference
    /// position is the 0-based position immediately before the insertion.
    public var insertions: [(position: Int, bases: String)] {
        var result: [(Int, String)] = []
        var refPos = position
        var queryPos = sequence.startIndex

        for op in cigar {
            switch op.op {
            case .match, .seqMatch, .seqMismatch:
                for _ in 0..<op.length {
                    if queryPos < sequence.endIndex {
                        queryPos = sequence.index(after: queryPos)
                    }
                    refPos += 1
                }

            case .insertion:
                let endIndex = sequence.index(queryPos, offsetBy: min(op.length, sequence.distance(from: queryPos, to: sequence.endIndex)))
                let bases = String(sequence[queryPos..<endIndex])
                // Padded CIGAR alignments may represent one biological insertion as
                // consecutive I operations at the same reference position (e.g. I-P-I).
                // Merge those so rendering shows a single insertion event and label.
                if let last = result.last, last.0 == refPos {
                    result[result.count - 1].1.append(contentsOf: bases)
                } else {
                    result.append((refPos, bases))
                }
                queryPos = endIndex

            case .deletion, .skip:
                refPos += op.length

            case .softClip:
                for _ in 0..<op.length {
                    if queryPos < sequence.endIndex {
                        queryPos = sequence.index(after: queryPos)
                    }
                }

            case .hardClip, .padding:
                break
            }
        }

        return result
    }

    /// Parsed supplementary alignment from the SA tag.
    public struct SupplementaryAlignment: Sendable {
        public let chromosome: String
        public let position: Int  // 0-based
        public let strand: Strand
        public let cigarString: String
        public let mapq: UInt8
        public let editDistance: Int
    }

    /// Parses the SA tag into supplementary alignment records.
    ///
    /// SA tag format: "chr,pos,strand,CIGAR,mapQ,NM;chr,pos,strand,CIGAR,mapQ,NM;..."
    public var parsedSupplementaryAlignments: [SupplementaryAlignment] {
        guard let sa = supplementaryAlignments else { return [] }
        var results: [SupplementaryAlignment] = []
        for record in sa.split(separator: ";") where !record.isEmpty {
            let fields = record.split(separator: ",")
            guard fields.count >= 6,
                  let pos = Int(fields[1]), pos > 0,
                  let mq = UInt8(fields[4]),
                  let nm = Int(fields[5]) else { continue }
            let strand: Strand = fields[2] == "-" ? .reverse : .forward
            results.append(SupplementaryAlignment(
                chromosome: String(fields[0]),
                position: pos - 1, // Convert 1-based to 0-based
                strand: strand,
                cigarString: String(fields[3]),
                mapq: mq,
                editDistance: nm
            ))
        }
        return results
    }

    /// Whether this read has split-read (chimeric) alignments.
    public var hasSplitAlignments: Bool {
        supplementaryAlignments != nil
    }
}

// MARK: - Read Sorting

/// Sort mode for aligned reads in the viewer.
public enum ReadSortMode: String, Sendable, CaseIterable {
    /// Sort by leftmost mapping position (default, matches samtools output)
    case position
    /// Sort by read name (groups mate pairs together)
    case readName
    /// Sort by strand (forward reads first, then reverse)
    case strand
    /// Sort by mapping quality (highest first)
    case mappingQuality
    /// Sort by insert size (smallest first)
    case insertSize
    /// Sort by base at a specific position (for variant investigation)
    case baseAtPosition

    public var displayName: String {
        switch self {
        case .position: return "Position"
        case .readName: return "Read Name"
        case .strand: return "Strand"
        case .mappingQuality: return "Mapping Quality"
        case .insertSize: return "Insert Size"
        case .baseAtPosition: return "Base at Position"
        }
    }
}

/// Group mode for aligned reads in the viewer.
public enum ReadGroupMode: String, Sendable, CaseIterable {
    /// No grouping
    case none
    /// Group by read pair (mate pairs displayed together)
    case readPair
    /// Group by strand
    case strand
    /// Group by read group
    case readGroup
    /// Group by first-in-pair / second-in-pair
    case firstOfPair
    /// Group by supplementary / primary
    case supplementaryStatus

    public var displayName: String {
        switch self {
        case .none: return "None"
        case .readPair: return "Read Pair"
        case .strand: return "Strand"
        case .readGroup: return "Read Group"
        case .firstOfPair: return "First of Pair"
        case .supplementaryStatus: return "Primary/Supplementary"
        }
    }
}

/// Color-by mode for aligned reads.
public enum ReadColorMode: String, Sendable, CaseIterable {
    /// Color by strand (default: blue forward, red reverse)
    case strand
    /// Color by insert size (red=too large, blue=too small, green=normal)
    case insertSize
    /// Color by mapping quality
    case mappingQuality
    /// Color by read group
    case readGroup
    /// Color by first/second in pair
    case firstOfPair
    /// Color by base quality
    case baseQuality

    public var displayName: String {
        switch self {
        case .strand: return "Strand"
        case .insertSize: return "Insert Size"
        case .mappingQuality: return "Mapping Quality"
        case .readGroup: return "Read Group"
        case .firstOfPair: return "First/Second in Pair"
        case .baseQuality: return "Base Quality"
        }
    }
}
