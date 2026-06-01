// TwelveSTargetTableView.swift — BatchTableView subclass for 12S target rows
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import LungfishIO
import LungfishKit

/// Sortable/filterable table of 12S scientific-name target rows.
///
/// Subclasses ``BatchTableView`` so column sort, per-column filter menus,
/// multi-row selection callbacks, the context-menu hook, and per-sample
/// metadata columns all come from the kernel.
@MainActor
final class TwelveSTargetTableView: BatchTableView<TwelveSScientificNameCountRow> {

    /// Returns the alternate-match display texts for a row (alternate matches,
    /// else potential matches) — used by the Alternates column and detail.
    static func alternateTexts(for row: TwelveSScientificNameCountRow) -> [String] {
        row.alternateMatches.isEmpty ? row.potentialMatches : row.alternateMatches.map(\.displayName)
    }

    override var columnSpecs: [BatchColumnSpec] {
        [
            .init(identifier: .init("scientificName"), title: "Scientific Name", width: 220, minWidth: 120, defaultAscending: true),
            .init(identifier: .init("commonNames"), title: "Common Names", width: 150, minWidth: 80, defaultAscending: true),
            .init(identifier: .init("taxonGroups"), title: "Group", width: 95, minWidth: 60, defaultAscending: true),
            .init(identifier: .init("taxids"), title: "Tax ID", width: 90, minWidth: 60, defaultAscending: true),
            .init(identifier: .init("totalExactReads"), title: "Exact Reads", width: 90, minWidth: 70, defaultAscending: false),
            .init(identifier: .init("referenceTargets"), title: "Refs", width: 60, minWidth: 50, defaultAscending: false),
            .init(identifier: .init("maxSamplePercent"), title: "Max %", width: 80, minWidth: 60, defaultAscending: false),
            .init(identifier: .init("alternateMatchCount"), title: "Alternates", width: 85, minWidth: 60, defaultAscending: false),
        ]
    }

    override var searchPlaceholder: String { "Filter species or matches" }
    override var tableAccessibilityIdentifier: String? { "twelve-s-result-table" }

    override var columnTypeHints: [String: Bool] {
        [
            "totalExactReads": true,
            "referenceTargets": true,
            "maxSamplePercent": true,
            "alternateMatchCount": true,
        ]
    }

    override func cellContent(
        for column: NSUserInterfaceItemIdentifier,
        row: TwelveSScientificNameCountRow
    ) -> (text: String, alignment: NSTextAlignment, font: NSFont?) {
        switch column.rawValue {
        case "scientificName":      return (row.scientificName, .left, nil)
        case "commonNames":         return (row.commonNamesText, .left, nil)
        case "taxonGroups":         return (row.displayTaxonGroups.joined(separator: "; "), .left, nil)
        case "taxids":              return (row.taxids.joined(separator: "; "), .left, nil)
        case "totalExactReads":     return (String(row.totalExactReads), .right, nil)
        case "referenceTargets":    return (String(row.referenceTargetCount), .right, nil)
        case "maxSamplePercent":    return (String(format: "%.1f%%", row.maxSamplePercent), .right, nil)
        case "alternateMatchCount": return (String(Self.alternateTexts(for: row).count), .right, nil)
        default:                    return ("", .left, nil)
        }
    }

    override func columnValue(for columnId: String, row: TwelveSScientificNameCountRow) -> String {
        switch columnId {
        case "totalExactReads":     return String(row.totalExactReads)
        case "referenceTargets":    return String(row.referenceTargetCount)
        case "maxSamplePercent":    return String(row.maxSamplePercent)
        case "alternateMatchCount": return String(Self.alternateTexts(for: row).count)
        default:                    return cellContent(for: .init(columnId), row: row).text
        }
    }

    override func compareRows(
        _ lhs: TwelveSScientificNameCountRow,
        _ rhs: TwelveSScientificNameCountRow,
        by key: String,
        ascending: Bool
    ) -> Bool {
        switch key {
        case "totalExactReads":
            return ascending ? lhs.totalExactReads < rhs.totalExactReads : lhs.totalExactReads > rhs.totalExactReads
        case "referenceTargets":
            return ascending ? lhs.referenceTargetCount < rhs.referenceTargetCount : lhs.referenceTargetCount > rhs.referenceTargetCount
        case "maxSamplePercent":
            return ascending ? lhs.maxSamplePercent < rhs.maxSamplePercent : lhs.maxSamplePercent > rhs.maxSamplePercent
        case "alternateMatchCount":
            let l = Self.alternateTexts(for: lhs).count, r = Self.alternateTexts(for: rhs).count
            return ascending ? l < r : l > r
        default:
            let l = cellContent(for: .init(key), row: lhs).text
            let r = cellContent(for: .init(key), row: rhs).text
            let cmp = l.localizedStandardCompare(r)
            return ascending ? cmp == .orderedAscending : cmp == .orderedDescending
        }
    }

    override func rowMatchesFilter(_ row: TwelveSScientificNameCountRow, filterText: String) -> Bool {
        let needle = filterText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return true }
        let haystack = [
            row.scientificName,
            row.commonNamesText,
            row.potentialMatchesText,
            row.displayTaxonGroups.joined(separator: " "),
            row.taxids.joined(separator: " "),
            row.targetIDs.joined(separator: " "),
        ].joined(separator: " ")
        return haystack.localizedCaseInsensitiveContains(needle)
    }

    override func rowIdentity(for row: TwelveSScientificNameCountRow) -> String? {
        let prefix = resultIdentity ?? ""
        return "\(prefix)|\(row.scientificName)|\(row.taxids.joined(separator: ","))"
    }
}
