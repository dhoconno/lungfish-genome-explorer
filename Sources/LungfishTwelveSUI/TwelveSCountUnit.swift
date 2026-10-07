// TwelveSCountUnit.swift - The unit a 12S result counts in, as its labels name it
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import LungfishIO
import LungfishKit

/// The unit of a 12S result's counts. A run that read unmerged pairs counts
/// fragments, a merged read or a concordant pair once each, so its labels
/// name fragments. A run of merged or single reads only, and a result
/// written before the read fate recorded its pairs, keeps its labels in
/// reads, as such results always read (Phase 2.1 round F4, review B N1).
public enum TwelveSCountUnit: Sendable, Equatable {
    case reads
    case fragments

    public init(readFate: TwelveSAmpliconReadFate) {
        self = readFate.pairedFragments > 0 ? .fragments : .reads
    }

    /// `Reads` or `Fragments`, for a column or a field.
    public var title: String {
        switch self {
        case .reads: return "Reads"
        case .fragments: return "Fragments"
        }
    }

    /// `Exact Reads` or `Exact Fragments`.
    public var exactTitle: String { "Exact \(title)" }

    /// The noun after a count, `read` or `reads`, `fragment` or `fragments`.
    public func noun(for count: Int) -> String {
        switch self {
        case .reads: return count == 1 ? "read" : "reads"
        case .fragments: return count == 1 ? "fragment" : "fragments"
        }
    }

    /// The help of a count column. In reads it is the help such a column
    /// always showed.
    public var columnHelp: String {
        switch self {
        case .reads: return "Read count in reads."
        case .fragments: return "Fragment count. A merged read counts once, and so does an unmerged pair whose mates agree."
        }
    }
}

extension BatchTableView {
    /// Gives the shown columns the titles and help of the current column
    /// specs, after a count unit changed. Columns are retitled in place,
    /// because a rebuild would drop the sample columns a 12S table adds
    /// itself. The header menu is refreshed so it names the same titles.
    func applyColumnSpecTitles() {
        guard tableView != nil else { return }
        var changed = false
        for spec in columnSpecs {
            guard let column = tableView.tableColumn(withIdentifier: spec.identifier) else { continue }
            let toolTip = spec.toolTip ?? column.headerToolTip
            guard column.title != spec.title || column.headerToolTip != toolTip else { continue }
            column.title = spec.title
            column.headerToolTip = toolTip
            changed = true
        }
        guard changed else { return }
        metadataColumns.standardColumnNames = standardColumnNames
        metadataColumns.refreshAfterStandardColumnsChanged()
    }
}
