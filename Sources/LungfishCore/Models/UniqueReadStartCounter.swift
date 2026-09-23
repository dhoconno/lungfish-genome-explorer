// UniqueReadStartCounter.swift - Streaming unique-read counter for SAM text.
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation

/// Counts unique aligned reads from a stream of SAM text lines, using the
/// same dedup key as `AlignedRead.deduplicatedReadCount`
/// (`AlignedReadDedup.swift`): a read's 0-based start position, its
/// reference-consuming alignment end (`position + sum(CIGAR ops that consume
/// reference)`), and its strand. Two reads sharing all three are treated as
/// duplicates of each other and counted once.
///
/// Unlike `AlignedReadDedup.deduplicatedReadCount(from:)`, which operates on
/// an already-fully-parsed, already-capped `[AlignedRead]` array, this type
/// consumes raw SAM lines directly: it does not allocate `AlignedRead`
/// values (no sequence/quality strings), does not cap the number of reads
/// counted, and can be fed incrementally as `samtools view` output arrives
/// rather than requiring the whole SAM text to be buffered in memory first.
/// Memory is bounded by the number of *distinct* (position, end, strand)
/// keys, not by the number of records read.
public struct UniqueReadStartCounter: Sendable {
    /// A packed representation of one (position, alignmentEnd, strand) key.
    /// Reference coordinates fit comfortably in 32 bits (the largest
    /// chromosomes are under 2^31 bp), so position and end are packed
    /// alongside a 1-bit strand flag into one hashable `UInt64` instead of
    /// allocating a `String` key per read, which was the shape used by
    /// `AlignedReadDedup` (fine for its already-small, capped input, too
    /// costly per-read for an uncapped whole-contig stream).
    private struct Key: Hashable {
        let packed: UInt64

        init(position: Int, alignmentEnd: Int, isReverse: Bool) {
            let clampedPosition = UInt64(clamping: max(0, position))
            let clampedEnd = UInt64(clamping: max(0, alignmentEnd))
            let strandBit: UInt64 = isReverse ? 1 : 0
            // position: bits 33-63 (31 bits), end: bits 2-32 (31 bits), strand: bit 0.
            packed = (clampedPosition << 33) | (clampedEnd << 2) | strandBit
        }
    }

    private var seenKeys: Set<Key> = []

    public init() {}

    /// Distinct (position, alignmentEnd, strand) keys seen so far.
    public var uniqueCount: Int { seenKeys.count }

    /// Total lines that parsed as a mapped alignment record, whether or not
    /// they turned out to be a duplicate of an already-seen key.
    public private(set) var recordCount: Int = 0

    /// Feeds one SAM alignment line (no leading `@` header lines). Malformed
    /// or unmapped lines are ignored, matching `SAMParser.parseLine`.
    public mutating func ingest(line: some StringProtocol) {
        guard let key = Self.parseKey(line: line) else { return }
        recordCount += 1
        seenKeys.insert(key)
    }

    /// Feeds every line in a chunk of SAM text, carrying over any trailing
    /// partial line to `leftover` so the caller can prepend it to the next
    /// chunk. Pass `isFinal: true` on the last chunk to also consume
    /// `leftover` itself.
    public mutating func ingest(chunk: String, leftover: inout String, isFinal: Bool = false) {
        let combined = leftover + chunk
        var lines = combined.split(separator: "\n", omittingEmptySubsequences: false)
        if !isFinal, let last = lines.last, !combined.hasSuffix("\n") {
            leftover = String(last)
            lines.removeLast()
        } else {
            leftover = ""
        }
        for line in lines where !line.isEmpty {
            ingest(line: line)
        }
    }

    private static func parseKey(line: some StringProtocol) -> Key? {
        guard !line.hasPrefix("@") else { return nil }
        let fields = line.split(separator: "\t", omittingEmptySubsequences: false)
        guard fields.count >= 6 else { return nil }

        guard let flag = UInt16(fields[1]) else { return nil }
        if flag & 0x4 != 0 { return nil } // unmapped

        guard fields[2] != "*" else { return nil }
        guard let pos1Based = Int(fields[3]), pos1Based > 0 else { return nil }
        let position = pos1Based - 1

        guard let referenceLength = cigarReferenceLength(fields[5]) else { return nil }
        let alignmentEnd = position + referenceLength
        let isReverse = flag & 0x10 != 0

        return Key(position: position, alignmentEnd: alignmentEnd, isReverse: isReverse)
    }

    /// Sums the lengths of CIGAR operations that consume the reference
    /// (M, D, N, =, X — mirroring `CIGAROperation.consumesReference`),
    /// without allocating a `[CIGAROperation]` array.
    private static func cigarReferenceLength(_ cigar: some StringProtocol) -> Int? {
        if cigar == "*" { return 0 }
        var total = 0
        var current = 0
        for character in cigar {
            if let digit = character.wholeNumberValue, character.isASCII, character.isNumber {
                current = current * 10 + digit
                continue
            }
            switch character {
            case "M", "D", "N", "=", "X":
                total += current
            case "I", "S", "H", "P":
                break
            default:
                return nil
            }
            current = 0
        }
        return total
    }
}
