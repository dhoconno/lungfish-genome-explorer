// ReadStyleSection+ReadTotals.swift - What the Inspector's Total Mapped and Total Unmapped rows count
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation

/// The totals of the counted alignment tracks, by the kind of count each track gives. Reads come from flagstat's
/// `primary` lines. A track whose database has no such lines (flagstat before samtools 1.9, text that did not parse,
/// or a hand-made database) has only idxstats alignment records, which count a supplementary alignment again beside
/// its read. The two kinds are never added into one number.
struct ReadTotalsByKind: Equatable {
    private(set) var readsMapped: Int64 = 0
    private(set) var readsUnmapped: Int64 = 0
    private(set) var readTracks = 0
    private(set) var alignmentsMapped: Int64 = 0
    private(set) var alignmentsUnmapped: Int64 = 0
    private(set) var alignmentTracks = 0

    /// Adds one counted track, as reads when it has them and else as its per-sequence alignment records.
    mutating func add(reads: (mapped: Int64, unmapped: Int64)?, alignments: [(mapped: Int64, unmapped: Int64)]) {
        if let reads {
            readsMapped += reads.mapped
            readsUnmapped += reads.unmapped
            readTracks += 1
        } else if !alignments.isEmpty {
            alignmentsMapped += alignments.reduce(0) { $0 + $1.mapped }
            alignmentsUnmapped += alignments.reduce(0) { $0 + $1.unmapped }
            alignmentTracks += 1
        }
    }

    /// What the two Total rows show: the reads when any track has them, else the alignment records.
    var shownMapped: Int64 { readTracks > 0 ? readsMapped : alignmentsMapped }
    var shownUnmapped: Int64 { readTracks > 0 ? readsUnmapped : alignmentsUnmapped }
}

/// A row for the alignment records of the tracks that have no read counts, shown apart from the reads.
struct AlignmentOnlyRow: Identifiable, Equatable {
    let label: String
    let value: Int64
    var id: String { label }
}

extension ReadStyleSectionViewModel {
    /// True when no counted track has read counts, so the two totals are alignment records.
    private var totalsAreAlignments: Bool { totalsByKind.readTracks == 0 && totalsByKind.alignmentTracks > 0 }

    var totalMappedLabel: String { totalsAreAlignments ? "Total Mapped (alignments)" : "Total Mapped" }
    var totalUnmappedLabel: String { totalsAreAlignments ? "Total Unmapped (alignments)" : "Total Unmapped" }
    var mappedPercentLabel: String { totalsAreAlignments ? "Mapped % (alignments)" : "Mapped %" }

    /// The share of the two totals that mapped, `nil` when both are zero.
    var mappedPercent: Double? {
        let total = totalMappedReads + totalUnmappedReads
        return total > 0 ? Double(totalMappedReads) / Double(total) * 100 : nil
    }

    /// The alignment records of the tracks that have no read counts, apart from the reads of the others.
    var alignmentOnlyRows: [AlignmentOnlyRow] {
        guard totalsByKind.readTracks > 0, totalsByKind.alignmentTracks > 0 else { return [] }
        return [
            AlignmentOnlyRow(label: "Mapped (alignments only)", value: totalsByKind.alignmentsMapped),
            AlignmentOnlyRow(label: "Unmapped (alignments only)", value: totalsByKind.alignmentsUnmapped),
        ]
    }

    /// Words under the totals when a counted track has alignment records and no read counts. They say what the
    /// numbers count and what to try. `nil` when every total is a read count.
    var alignmentCountsNote: String? {
        guard totalsByKind.alignmentTracks > 0 else { return nil }
        if totalsByKind.readTracks > 0 {
            return "Some tracks have no read counts. Their alignments are listed apart and not added to the reads. Run the mapping or import those alignments again to count their reads."
        }
        return "These totals count alignments, so a read with a supplementary alignment counts more than once. Run the mapping or import the alignment again to count its reads."
    }
}
