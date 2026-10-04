// TaxonomySummaryBar.swift - Summary card bar for taxonomy classification results
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import LungfishKit
import LungfishIO
import LungfishWorkflow

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

    /// The line under the count, set when the run held read pairs.
    private(set) var fragmentLine: String?
    /// Whether the count card counts fragments rather than reads.
    private(set) var countsFragments = false
    /// Whether an older result counted each mate as its own read.
    private(set) var countedPerRead = false
    /// Bumped by every update, so a late "counted per read" check for an
    /// earlier result is dropped.
    private var resultGeneration = 0

    // MARK: - Batch State

    private var isBatchMode: Bool = false
    private var batchSampleCount: Int = 0
    private var batchTotalRows: Int = 0
    private var batchDatabaseName: String = ""

    // MARK: - Update

    /// Recomputes summary statistics from the given taxonomy tree.
    ///
    /// - Parameter tree: The parsed taxonomy tree from a classification result.
    func update(tree: TaxonTree) {
        resultGeneration += 1
        fragmentLine = nil
        countsFragments = false
        countedPerRead = false
        isBatchMode = false
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

        cardsDidChange()
    }

    /// Recomputes the cards from a classification result. A run that held
    /// read pairs counts fragments, and a line says how many came from pairs
    /// and how many from merged or single reads. An older result made from
    /// paired inputs without the read-pairing contract is labelled as
    /// counted per read (manager ruling 3), once its inputs are checked off
    /// the main actor.
    func update(result: ClassificationResult) {
        update(tree: result.tree)
        let presentation = TaxonomyFragmentPresentation(result: result)
        countsFragments = presentation.countsFragments
        fragmentLine = presentation.fragmentLine
        cardsDidChange()
        guard presentation.mayHaveCountedPerRead else { return }
        let generation = resultGeneration
        let inputs = presentation.originalInputs
        Task { [weak self] in
            let holdsPairs = await Task.detached(priority: .utility) {
                await KrakenReadSetPlanner.originalInputsHoldPairs(inputs)
            }.value
            guard let self, self.resultGeneration == generation,
                  presentation.showsCountedPerRead(inputsHoldPairs: holdsPairs) else { return }
            self.countedPerRead = true
            self.cardsDidChange()
        }
    }

    /// Updates the summary bar to show batch aggregation statistics.
    ///
    /// Displays: "Batch: N samples · M taxa · DatabaseName"
    ///
    /// - Parameters:
    ///   - sampleCount: Number of samples in the batch.
    ///   - totalRows: Total number of taxon rows across all samples.
    ///   - databaseName: Name of the classification database used.
    func updateBatch(sampleCount: Int, totalRows: Int, databaseName: String) {
        isBatchMode = true
        batchSampleCount = sampleCount
        batchTotalRows = totalRows
        batchDatabaseName = databaseName
        cardsDidChange()
    }

    // MARK: - Cards

    override var cards: [Card] {
        if isBatchMode {
            return [
                Card(label: "Batch", value: "Kraken2"),
                Card(label: "Samples", value: "\(batchSampleCount)"),
                Card(label: "Taxa", value: GenomicSummaryCardBar.formatCount(batchTotalRows)),
                Card(label: "Database", value: batchDatabaseName.isEmpty ? "\u{2014}" : batchDatabaseName),
            ]
        }
        var cards = [
            Card(
                label: countsFragments ? "Fragments" : "Total Reads",
                value: GenomicSummaryCardBar.formatCount(totalReads)
            ),
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
        if let fragmentLine {
            cards.append(Card(label: "Read Pairing", value: fragmentLine))
        }
        if countedPerRead {
            cards.append(Card(label: "Counting", value: TaxonomyFragmentPresentation.countedPerReadLabel))
        }
        return cards
    }

    // MARK: - Abbreviations

    override func abbreviatedLabel(for label: String) -> String {
        switch label {
        case "Total Reads": return "Reads"
        case "Read Pairing": return "Pairing"
        case "Classified": return "Classif."
        case "Unclassified": return "Unclass."
        case "Shannon H\u{2032}": return "H\u{2032}"
        case "Dominant": return "Top"
        default: return super.abbreviatedLabel(for: label)
        }
    }
}
