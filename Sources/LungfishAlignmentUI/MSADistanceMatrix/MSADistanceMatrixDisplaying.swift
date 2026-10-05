// MSADistanceMatrixDisplaying.swift - What the distance grid needs from a computed matrix, plus shared text
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation

/// The read-only view of a computed matrix the grid draws, in display order.
///
/// `MSADistanceMatrix` from LungfishIO conforms. Tests use small stubs.
public protocol MSADistanceMatrixDisplaying {
    var displayNames: [String] { get }
    /// Display position to index in the input records.
    var displayRecordIndices: [Int] { get }
    var displayValues: [[Double]] { get }
    func displayComparableSites(row: Int, column: Int) -> Int
    /// The square TSV, byte-identical to `lungfish-cli msa distance`.
    var squareTSV: String { get }
}

extension MSADistanceMatrixDisplaying {
    var displayCount: Int { displayNames.count }
}

/// Tab-separated copies of part of the matrix (ruling U8).
public enum MSADistanceMatrixClipboard {
    /// The selection's bounding rectangle in display order with the CLI
    /// header shape: corner `row`, column names, then one line per row with
    /// its name and six-decimal values. Unselected cells inside the box are
    /// empty fields. With no cells, the header band's S x S submatrix.
    public static func tsv(
        for selection: MSADistanceMatrixSelection,
        in matrix: any MSADistanceMatrixDisplaying
    ) -> String? {
        let names = matrix.displayNames
        let values = matrix.displayValues
        if let box = selection.boundingBox {
            let columns = Array(box.columns)
            var lines = ["row\t" + columns.map { names[$0] }.joined(separator: "\t")]
            for row in box.rows {
                let fields = columns.map { column -> String in
                    selection.cells.contains(MSADistanceCell(row: row, column: column))
                        ? MSADistanceValueFormat.full(values[row][column])
                        : ""
                }
                lines.append(([names[row]] + fields).joined(separator: "\t"))
            }
            return lines.joined(separator: "\n") + "\n"
        }
        let sequences = Array(selection.selectedSequences.filter { $0 < names.count })
        guard !sequences.isEmpty else { return nil }
        var lines = ["row\t" + sequences.map { names[$0] }.joined(separator: "\t")]
        for row in sequences {
            let fields = sequences.map { MSADistanceValueFormat.full(values[row][$0]) }
            lines.append(([names[row]] + fields).joined(separator: "\t"))
        }
        return lines.joined(separator: "\n") + "\n"
    }
}

/// VoiceOver and footer strings (ux memo sections 3, 5 and 8).
public enum MSADistanceMatrixText {
    public static func cellLabel(
        rowName: String,
        columnName: String,
        value: Double,
        comparableSites: Int,
        isDiagonal: Bool
    ) -> String {
        var label: String
        if value.isNaN {
            label = "\(rowName), \(columnName), no comparable sites"
        } else if value == .infinity {
            label = "\(rowName), \(columnName), saturated, distance not estimable, "
                + "\(MSADistanceValueFormat.count(comparableSites)) sites compared"
        } else {
            label = "\(rowName), \(columnName), \(MSADistanceValueFormat.full(value)), "
                + "\(MSADistanceValueFormat.count(comparableSites)) sites compared"
        }
        if isDiagonal { label += ", same sequence" }
        return label
    }

    public static let cellHelp = "Press Return to show both sequences in the alignment."

    public static func legendLabel(modelName: String, lower: Double, upper: Double) -> String {
        "Colour scale, \(modelName), \(MSADistanceValueFormat.cell(lower)) to \(MSADistanceValueFormat.cell(upper)). "
            + "n/a means no comparable sites. Infinity means saturated."
    }

    public static func footer(
        rowName: String,
        columnName: String,
        modelName: String,
        value: Double,
        comparableSites: Int,
        differences: Int,
        gapSkipped: Int,
        ambiguitySkipped: Int
    ) -> String {
        let valueText: String
        if value.isNaN {
            valueText = "no comparable sites"
        } else if value == .infinity {
            valueText = "saturated"
        } else {
            valueText = MSADistanceValueFormat.full(value)
        }
        return "\(rowName) vs \(columnName), \(modelName) \(valueText), "
            + "\(MSADistanceValueFormat.count(comparableSites)) compared, "
            + "\(MSADistanceValueFormat.count(differences)) differ, "
            + "\(MSADistanceValueFormat.count(gapSkipped)) gap-skipped, "
            + "\(MSADistanceValueFormat.count(ambiguitySkipped)) ambiguity-skipped"
    }

    public static func tooManyRows(_ count: Int, limit: Int) -> String {
        "This alignment has \(MSADistanceValueFormat.count(count)) sequences. "
            + "The matrix shows up to \(MSADistanceValueFormat.count(limit)). Export computes the full matrix."
    }
}
