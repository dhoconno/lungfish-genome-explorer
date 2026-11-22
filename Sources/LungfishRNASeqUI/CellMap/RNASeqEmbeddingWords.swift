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
            return "\(name) places cells with similar counts near each other on a flat picture. Only near neighbours mean something. The distance between groups far apart, the size of a group and the space between groups carry no meaning."
        case .phate:
            return "PHATE draws cells along smooth paths. A path suggests a transition, not an order in time."
        case .other(let name):
            return "\(embedding) holds the coordinates \(name) gave each cell. LGE draws its first two dimensions as given and computes nothing from them."
        case .notRecorded:
            return "The method that made \(embedding) is not recorded. LGE draws its first two dimensions as given and computes nothing from them."
        }
    }

    /// The axis titles, the method's recorded name or the embedding's name, with no tick numbers.
    public static func axes(method recorded: String?, embedding: String) -> (x: String, y: String) {
        let name = (recorded?.isEmpty == false ? recorded : nil) ?? embedding
        return ("\(name) 1", "\(name) 2")
    }

    /// W2, beside labels that LGE computed.
    public static let computedLabels = "Clusters come from a graph of each cell's nearest neighbours, not from this picture, so one cluster can look split here and two can look joined."
    /// W3, beside a label set whose labels are all numbers.
    public static let clusterNumbers = "A cluster number is a name, not a rank. Another run can number the same groups differently. Naming a cluster as a cell type is the analyst's call."

    /// W4, for imported coordinates.
    public static func importedCoordinates(file: String) -> String {
        "Coordinates imported from \(file). LGE did not compute them."
    }

    /// W4, for imported labels.
    public static func importedLabels(set: String, file: String) -> String {
        "Labels of \(set) imported from \(file). LGE did not compute them."
    }

    /// 5.5 I3, when the record says the embedding came from other counts.
    public static func otherCounts(embedding: String, parent: String) -> String {
        "\(embedding) was computed on other counts, not on the counts of \(parent), so a cell's place need not follow the counts this result holds."
    }

    /// 5.5 I3, the cells of one sample that an embedding leaves out, as `embedding_cells` counts them.
    public static func leftOut(_ count: Int, of cells: Int, sample: String, embedding: String) -> String {
        "\(count) of the \(cells) cells of \(sample) have no coordinates in \(embedding) and are not drawn."
    }

    /// The cells of one sample with no label in a set, as `label_set_samples` counts them.
    public static func unlabelled(_ count: Int, sample: String, set: String) -> String {
        "\(count) cells of \(sample) have no label in \(set) and draw in grey under the others."
    }

    public static let coloursRepeat = "Colours repeat after 19 labels."
    public static let notFlagged = "Not flagged"

    /// The sentence that ends a count's scale words. A gene's words name the grey cells in W5 and pass none.
    public static let greyHaveZero = "Grey cells have 0."

    /// The scale's words with a p99 above 0 (`docs/formats/rnaseq-cell-map.md`, Bounds).
    public static func scale(p99: String, cells: Int, maximum: String, grey: String? = greyHaveZero) -> String {
        sentence("Colour runs from 0 to \(p99), the 99th percentile of all \(cells) cells of this cell map, zeros included. Cells above \(p99) take the top colour, and the largest value is \(maximum).", grey)
    }

    /// The scale's words when at least 99% of the cells have 0.
    public static func scaleToMaximum(maximum: String, cells: Int, grey: String? = greyHaveZero) -> String {
        sentence("Colour runs from 0 to \(maximum), the largest value, since at least 99% of the \(cells) cells of this cell map have 0.", grey)
    }

    private static func sentence(_ words: String, _ grey: String?) -> String { grey.map { "\(words) \($0)" } ?? words }

    /// The scale's words when no cell has a count.
    public static func scaleAllZero(cells: Int) -> String {
        "All \(cells) cells of this cell map have 0, so every cell draws in grey."
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
    public static func embeddingHelp(method recorded: String?, embedding: String) -> LungfishHelpContent.HelpItem {
        LungfishHelpContent.HelpItem(id: embeddingHelpID, summary: "About \(methodSubject(method: recorded, embedding: embedding))",
                                     detail: caption(method: recorded, embedding: embedding), audience: .benchScientist)
    }

    /// The item beside Colour by, with W2 for labels LGE computed and W3 for labels that are all numbers (C8, C9). Nil
    /// when neither holds, and the button then hides.
    public static func clustersHelp(computed: Bool, numbers: Bool) -> LungfishHelpContent.HelpItem? {
        let words = [computed ? computedLabels : nil, numbers ? clusterNumbers : nil].compactMap { $0 }
        guard !words.isEmpty else { return nil }
        return LungfishHelpContent.HelpItem(id: clustersHelpID, summary: "About \(clustersSubject)", detail: words.joined(separator: "\n\n"),
                                            audience: .benchScientist)
    }
}
