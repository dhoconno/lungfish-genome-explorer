// RNASeqEmbeddingWords.swift - The words of the embedding view (Phase 5.5 lane CM-VIEW)
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// UX's drafts W1 to W6 (`docs/plans/2026-11-19-single-cell-embedding-view.md`, 5.5 W1), the words of cells left out
// and of other counts (5.5 I3), the legend's bound words of `docs/formats/rnaseq-cell-map.md` (Bounds) and the fact
// lines of 5.5 V5. BIO and SC check the science, and UX reads them once at the notes step. No word here says a
// cluster reproduces, matches or equals another tool's, and the flag words are the file's, never "infected".

import Foundation
import LungfishIO
import LungfishKit

public enum RNASeqEmbeddingWords {
    /// How the view reads an embedding's recorded method.
    public enum Method: Equatable, Sendable {
        /// UMAP or t-SNE, which keep near neighbours and nothing else. They share W1.
        case neighbours(String)
        case phate
        /// PCA or another method that is recorded, which gets the neutral caption.
        case other(String)
        case notRecorded
    }

    public static func method(_ recorded: String?) -> Method {
        guard let recorded, !recorded.isEmpty else { return .notRecorded }
        let key = recorded.lowercased().filter { $0.isLetter || $0.isNumber }
        switch key {
        case "umap", "tsne": return .neighbours(recorded)
        case "phate": return .phate
        default: return .other(recorded)
        }
    }

    /// The caption under the plot: W1 for UMAP and t-SNE, W6 for PHATE, and a neutral line that makes no claim about
    /// near neighbours for PCA or a method that is not recorded.
    public static func caption(method recorded: String?, embedding: String) -> String {
        switch method(recorded) {
        case .neighbours(let name):
            return "\(name) puts cells with similar counts near each other on a flat plot. Only local neighbours matter. Distances between far-apart groups, group sizes and gaps between groups carry no meaning."
        case .phate:
            return "PHATE draws cells along smooth paths. A path suggests a transition and gives no time order."
        case .other(let name):
            return "\(embedding) stores the coordinates \(name) gave each cell. LGE plots the first two dimensions as given and computes nothing from them."
        case .notRecorded:
            return "The method used for \(embedding) is not recorded. LGE plots the first two dimensions as given and computes nothing from them."
        }
    }

    /// The axis titles, the method's recorded name or the embedding's name, with no tick numbers.
    public static func axes(method recorded: String?, embedding: String) -> (x: String, y: String) {
        let name = (recorded?.isEmpty == false ? recorded : nil) ?? embedding
        return ("\(name) 1", "\(name) 2")
    }

    /// W2, in "About clusters" for labels that LGE computed (C8).
    public static let computedLabels = "Clusters come from a graph of each cell's nearest neighbours. The plot plays no part in forming them, so one cluster can look split or two can look joined."
    /// W3, in "About clusters" for a label set whose labels are all numbers (C9). BIO sent the first decided words back
    /// (BIOWORDS-TV-CELLMAP item 2) and cleared Sol's revised words on recheck (5.5 W1), so these are the decided words.
    public static let clusterNumbers = "Cluster numbers name groups and give no rank. Another run can give the same groups different numbers. The analyst decides whether to name a cluster as a cell type."
    /// In "About clusters" when a sample has cells with no label (C7b).
    public static let unlabelledGrey = "Cells with no label appear in grey beneath the other cells."

    /// W4, the line under Embedding or Colour by for imported coordinates or labels, whose sha256 the Inspector shows (C4a, C10a).
    public static func imported(file: String) -> String {
        "Imported from \(file), not computed by LGE"
    }

    /// 5.5 I3, the line under Embedding when the record says the embedding came from other counts (C5a).
    public static func otherCounts(embedding: String, parent: String) -> String {
        "\(embedding) was computed on other counts, not those of \(parent)."
    }

    /// 5.5 I3, in "About <method>" after the method's words when the other-counts line shows (C5b).
    public static let otherCountsPlace = "A cell's position need not reflect this result's counts."

    /// 5.5 I3, the cells of one sample that an embedding leaves out on a map of two or more samples, as `embedding_cells`
    /// counts them (C6b).
    public static func leftOut(_ count: Int, of cells: Int, sample: String, embedding: String) -> String {
        "\(count) of \(cells) cells in \(sample) have no coordinates in \(embedding) and aren't drawn."
    }

    /// 5.5 I3, the Cells drawn value on a map of one sample whose embedding leaves cells out (C6a). The numbers are the
    /// manifest's and `embedding_cells`'s.
    public static func cellsDrawn(_ drawn: Int, of cells: Int, sample: String, leftOut: Int, embedding: String) -> String {
        "\(drawn) of \(cells) in \(sample). \(leftOut) have no coordinates in \(embedding)."
    }

    /// The cells of one sample with no label in a set, as `label_set_samples` counts them (C7a).
    public static func unlabelled(_ count: Int, sample: String, set: String) -> String {
        "\(sample) has \(count) cells with no label in \(set)."
    }

    public static let coloursRepeat = "Colours repeat after 19 labels."
    public static let notFlagged = "Not flagged"

    /// The sentence that ends a count's scale words. A gene's words name the grey cells in W5 and pass none.
    public static let greyHaveZero = "Grey cells have 0."

    /// The scale's words with a p99 above 0 (`docs/formats/rnaseq-cell-map.md`, Bounds, C12a). The definition is in
    /// "About the colour scale".
    public static func scale(p99: String, maximum: String, grey: String? = greyHaveZero) -> String {
        sentence("0 to \(p99) (99th percentile). The largest value is \(maximum).", grey)
    }

    /// The scale's words when at least 99% of the cells have 0 (C12c).
    public static func scaleToMaximum(maximum: String, cells: Int, grey: String? = greyHaveZero) -> String {
        sentence("0 to \(maximum), the largest value, since at least 99% of the \(cells) cells have 0.", grey)
    }

    private static func sentence(_ words: String, _ grey: String?) -> String { grey.map { "\(words) \($0)" } ?? words }

    /// The scale's words when no cell has a count (C13b).
    public static func scaleAllZero(cells: Int) -> String {
        "All \(cells) cells have 0 and appear grey."
    }

    /// "About the colour scale" beside the legend's title, both scale states (C12b), and for a gene why grey is no
    /// reading of the gene (C14b).
    public static func colourScale(cells: Int, gene: Bool) -> String {
        "Colour runs from 0 to the 99th percentile of all \(cells) cells in this map, zeros included, and higher values use the top colour. "
            + "If at least 99% of the \(cells) cells have 0, the scale ends at the largest value."
            + (gene ? "\n\nA grey cell does not rule out gene expression." : "")
    }

    /// The plot's VoiceOver label (UX U-A3).
    public static func plotLabel(method recorded: String?, embedding: String, colouring: String) -> String {
        let name = (recorded?.isEmpty == false ? recorded : nil) ?? embedding
        return "\(name) of the cells, coloured by \(colouring)"
    }

    /// The plot's VoiceOver value, with numbers from the file.
    public static func plotValue(cells: Int, values: Int) -> String {
        "\(cells) cells drawn, \(values) \(values == 1 ? "value" : "values") in the legend"
    }

    /// One legend value as VoiceOver reads it.
    public static func legendChild(name: String, count: String) -> String {
        "\(name), \(count) cells"
    }

    /// The line hover shows for one cell, its values as written.
    public static func hover(barcode: String, sample: String, value: String?) -> String {
        ["Barcode \(barcode)", "sample \(sample)", value].compactMap { $0 }.joined(separator: ", ")
    }

    /// The words when the view could not read the cell map, with the step after.
    public static func failed(_ reason: String) -> String {
        "The cell map could not be shown. \(reason)"
    }

    public static let noEmbedding = "This cell map holds no embedding, so there is nothing to draw. Import the embedding again with lungfish-cli rnaseq cell-map import."

    /// A number as the file holds it, a whole number without a fraction.
    public static func number(_ value: Double) -> String {
        if value.isFinite, value == value.rounded(), abs(value) < 1e15 { return String(Int64(value)) }
        return String(Float32(value))
    }
}

/// The info buttons of the cell map (5.6 U2). Each item is built here from the words above, never copied into Kit, and
/// its popover holds a general caveat that left the view. The tests run Kit's catalog check on them.
extension RNASeqEmbeddingWords {
    public static let embeddingHelpID = "rnaseq.cellmap.embedding"
    public static let clustersHelpID = "rnaseq.cellmap.clusters"
    public static let clustersSubject = "clusters"

    /// What the button beside Embedding is about: the recorded method, or the embedding's name when none is recorded.
    public static func methodSubject(method recorded: String?, embedding: String) -> String {
        (recorded?.isEmpty == false ? recorded : nil) ?? embedding
    }

    /// The item beside Embedding. Its popover holds the method's caption (C1 to C3).
    public static func embeddingHelp(method recorded: String?, embedding: String, otherCounts: Bool = false) -> LungfishHelpContent.HelpItem {
        LungfishHelpContent.HelpItem(id: embeddingHelpID, summary: "Explains how to read the plot.",
                                     detail: caption(method: recorded, embedding: embedding) + (otherCounts ? "\n\n\(otherCountsPlace)" : ""),
                                     audience: .benchScientist)
    }

    /// The item beside Colour by, with W2 for labels LGE computed, W3 for labels that are all numbers and the grey of
    /// cells with no label (C8, C9, C7b). Nil when none holds, and the button then hides.
    public static func clustersHelp(computed: Bool, numbers: Bool, unlabelled: Bool = false) -> LungfishHelpContent.HelpItem? {
        let words = [computed ? computedLabels : nil, numbers ? clusterNumbers : nil, unlabelled ? unlabelledGrey : nil].compactMap { $0 }
        guard !words.isEmpty else { return nil }
        return LungfishHelpContent.HelpItem(id: clustersHelpID, summary: "Explains what cluster labels mean.", detail: words.joined(separator: "\n\n"),
                                            audience: .benchScientist)
    }

    public static let scaleHelpID = "rnaseq.cellmap.scale"
    public static let scaleSubject = "the colour scale"

    /// The item beside the legend's title while a colour bar shows (C12b, C14b).
    public static func scaleHelp(cells: Int, gene: Bool) -> LungfishHelpContent.HelpItem {
        LungfishHelpContent.HelpItem(id: scaleHelpID, summary: "Explains how colours are assigned to values.",
                                     detail: colourScale(cells: cells, gene: gene), audience: .benchScientist)
    }
}
