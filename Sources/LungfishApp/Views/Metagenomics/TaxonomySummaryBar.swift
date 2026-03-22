// TaxonomySummaryBar.swift - Summary card bar for taxonomy classification results
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import LungfishIO

// MARK: - TaxonomySummaryBar

/// Summary card bar displaying key statistics from a taxonomic classification.
///
/// Shows six cards: Total Reads, Classified %, Unclassified %, Species Count,
/// Shannon Diversity (H'), and Dominant Species. Subclasses ``GenomicSummaryCardBar``
/// for consistent rendering with other dataset summary bars.
///
/// ## Usage
///
/// ```swift
/// let summaryBar = TaxonomySummaryBar()
/// summaryBar.update(tree: classificationResult.tree)
/// ```
@MainActor
final class TaxonomySummaryBar: GenomicSummaryCardBar {

    // MARK: - State

    private var totalReads: Int = 0
    private var classifiedPercent: Double = 0
    private var unclassifiedPercent: Double = 0
    private var speciesCount: Int = 0
    private var shannonDiversity: Double = 0
    private var dominantSpeciesName: String = ""

    // MARK: - Update

    /// Recomputes summary statistics from the given taxonomy tree.
    ///
    /// - Parameter tree: The parsed taxonomy tree from a classification result.
    func update(tree: TaxonTree) {
        totalReads = tree.totalReads
        classifiedPercent = tree.classifiedFraction * 100
        unclassifiedPercent = tree.unclassifiedFraction * 100
        speciesCount = tree.speciesCount
        shannonDiversity = tree.shannonDiversity

        if let dominant = tree.dominantSpecies {
            dominantSpeciesName = dominant.name
        } else {
            dominantSpeciesName = "\u{2014}"
        }

        needsDisplay = true
    }

    // MARK: - Cards

    override var cards: [Card] {
        [
            Card(label: "Total Reads", value: GenomicSummaryCardBar.formatCount(totalReads)),
            Card(
                label: "Classified",
                value: String(format: "%.1f%%", classifiedPercent)
            ),
            Card(
                label: "Unclassified",
                value: String(format: "%.1f%%", unclassifiedPercent)
            ),
            Card(label: "Species", value: GenomicSummaryCardBar.formatCount(speciesCount)),
            Card(
                label: "Shannon H\u{2032}",
                value: String(format: "%.3f", shannonDiversity)
            ),
            Card(label: "Dominant", value: dominantSpeciesName),
        ]
    }

    // MARK: - Abbreviations

    override func abbreviatedLabel(for label: String) -> String {
        switch label {
        case "Total Reads": return "Reads"
        case "Classified": return "Classif."
        case "Unclassified": return "Unclass."
        case "Shannon H\u{2032}": return "H\u{2032}"
        case "Dominant": return "Top"
        default: return super.abbreviatedLabel(for: label)
        }
    }
}
