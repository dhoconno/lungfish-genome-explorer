// AlignedReadFASTAFormatter.swift - Multi-read aligned-orientation FASTA formatter
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Formats a selection of AlignedRead records (from the main mapping viewport's
// read-track multi-select) as FASTA, in aligned orientation, directly from the
// in-memory SEQ field (no samtools round-trip).
//
// Bio-gate semantics (docs/superpowers/specs/2026-08-09-mapping-viewer-fixes-spec.md,
// Item 3):
//   - Header: >{QNAME} {RNAME}:{1-based start}-{end} strand={+|-} cigar={CIGAR} mapq={MAPQ}
//     with `hardclipped={N}` appended (N = total hard-clipped bases) when the
//     CIGAR contains any H operations.
//   - Body: AlignedRead.sequence verbatim — soft-clipped bases ARE included
//     (SAM's SEQ field always contains them), hard-clipped bases are already
//     absent from SEQ.
//   - Reads whose sequence is empty or "*" (common for secondary alignments,
//     SAM flag 0x100, whose SEQ/QUAL are frequently written as "*") are
//     skipped. The caller-visible skip count lets the UI report how many
//     selected reads were omitted.
//
// Coordinates: AlignedRead.position is 0-based (internal convention);
// alignmentEnd is the 0-based EXCLUSIVE end. The header reports 1-based
// INCLUSIVE coordinates: start = position + 1, end = alignmentEnd (the
// 0-based exclusive end numerically equals the 1-based inclusive end).

import LungfishCore

/// Result of formatting a selection of aligned reads as FASTA.
public struct AlignedReadFASTAFormatResult: Sendable, Equatable {
    /// The formatted FASTA text. Empty when every read was skipped.
    public let fasta: String

    /// Number of reads skipped because their SEQ was empty or "*".
    public let skippedCount: Int

    public init(fasta: String, skippedCount: Int) {
        self.fasta = fasta
        self.skippedCount = skippedCount
    }
}

/// Formats `AlignedRead` records as FASTA in aligned orientation (SEQ verbatim,
/// including soft clips), for the mapping viewport's "Copy as FASTA" read
/// selection action.
public enum AlignedReadFASTAFormatter {

    /// Formats the given reads as FASTA, skipping any with empty/`"*"` SEQ.
    ///
    /// - Parameter reads: The reads to format, in the order given.
    /// - Returns: The joined FASTA text plus the count of skipped reads.
    public static func format(_ reads: [AlignedRead]) -> AlignedReadFASTAFormatResult {
        var records: [String] = []
        var skipped = 0

        for read in reads {
            guard let record = formatRecord(read) else {
                skipped += 1
                continue
            }
            records.append(record)
        }

        return AlignedReadFASTAFormatResult(
            fasta: records.joined(separator: "\n"),
            skippedCount: skipped
        )
    }

    /// Formats a single read as one FASTA record (header + sequence), or
    /// returns `nil` if the read's SEQ is empty or `"*"` (skip).
    private static func formatRecord(_ read: AlignedRead) -> String? {
        guard !read.sequence.isEmpty, read.sequence != "*" else { return nil }

        let start = read.position + 1
        let end = read.alignmentEnd
        let strand = read.isReverse ? "-" : "+"
        let cigar = read.cigarString

        var header = ">\(read.name) \(read.chromosome):\(start)-\(end) strand=\(strand) cigar=\(cigar) mapq=\(read.mapq)"

        let hardClippedBases = read.cigar
            .filter { $0.op == .hardClip }
            .reduce(0) { $0 + $1.length }
        if hardClippedBases > 0 {
            header += " hardclipped=\(hardClippedBases)"
        }

        return "\(header)\n\(read.sequence)"
    }
}
