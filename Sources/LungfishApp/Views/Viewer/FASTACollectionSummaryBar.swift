// FASTACollectionSummaryBar.swift - The summary cards above the FASTA collection list
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import LungfishCore
import LungfishKit

// MARK: - FASTACollectionSummaryBar

/// Summary card bar for the FASTA collection view.
///
/// Displays: Sequences, Total Length, Annotations, GC%, Shortest, Longest.
/// When showing sequences from multiple source files, also displays a "Sources"
/// card with the file count.
@MainActor
final class FASTACollectionSummaryBar: GenomicSummaryCardBar {

    // MARK: - State

    private var sequenceCount: Int = 0
    private var totalLength: Int64 = 0
    private var annotationCount: Int = 0
    /// False until the list's GC pass delivers, so the card reads blank and never 0.0 while it counts.
    private var gcCounted = false
    /// Every record's G+C over every record's A+C+G+T (W-8), nil when no record has an A, C, G or T.
    private var gcPercent: Double?
    private var shortestLength: Int = 0
    private var longestLength: Int = 0
    private var sourceFileCount: Int = 0

    // MARK: - Update

    /// Recomputes summary statistics from the provided sequences.
    ///
    /// - Parameters:
    ///   - sequences: All sequences in the collection.
    ///   - annotationCount: Total number of annotations across all sequences.
    ///   - sourceFileCount: Number of distinct source files (0 for single-document).
    ///
    /// The GC card reads blank until ``showGC(_:)`` gives it the pass's value.
    func update(
        sequences: [LungfishCore.Sequence],
        annotationCount: Int,
        sourceFileCount: Int = 0
    ) {
        self.sequenceCount = sequences.count
        self.annotationCount = annotationCount
        self.sourceFileCount = sourceFileCount
        gcCounted = false
        gcPercent = nil

        if sequences.isEmpty {
            totalLength = 0
            shortestLength = 0
            longestLength = 0
        } else {
            var total: Int64 = 0
            var shortest = Int.max
            var longest = 0

            for seq in sequences {
                let len = seq.length
                total += Int64(len)
                if len < shortest { shortest = len }
                if len > longest { longest = len }
            }

            totalLength = total
            shortestLength = shortest
            longestLength = longest
        }

        cardsDidChange()
    }

    /// Shows the list's pooled GC once the pass has counted it. Nil, when no record has an A, C, G or T, reads a dash.
    func showGC(_ percent: Double?) {
        gcCounted = true
        gcPercent = percent
        cardsDidChange()
    }

    private var gcText: String {
        guard gcCounted else { return "" }
        return gcPercent.map { String(format: "%.1f%%", $0) } ?? "\u{2014}"
    }

    // MARK: - Cards

    override var cards: [Card] {
        var result = [
            Card(label: "Sequences", value: GenomicSummaryCardBar.formatCount(sequenceCount)),
        ]

        // Show "Sources" card when combining multiple documents
        if sourceFileCount > 0 {
            result.append(
                Card(label: "Sources", value: "\(sourceFileCount) files")
            )
        }

        result.append(contentsOf: [
            Card(label: "Total Length", value: GenomicSummaryCardBar.formatBases(totalLength)),
            Card(label: "Annotations", value: GenomicSummaryCardBar.formatCount(annotationCount)),
            Card(label: "GC Content", value: gcText),
            Card(label: "Shortest", value: GenomicSummaryCardBar.formatBases(shortestLength)),
            Card(label: "Longest", value: GenomicSummaryCardBar.formatBases(longestLength)),
        ])

        return result
    }
}
