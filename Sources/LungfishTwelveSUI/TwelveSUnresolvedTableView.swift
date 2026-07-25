// TwelveSUnresolvedTableView.swift — BatchTableView subclass for 12S unresolved rows
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import LungfishIO
import LungfishKit

/// Sortable/filterable table of 12S unresolved (unmatched) sequence clusters.
@MainActor
final class TwelveSUnresolvedTableView: BatchTableView<TwelveSUnresolvedSequence> {
    private let adaptiveColumnWidths = TwelveSAdaptiveColumnWidthState()
    #if DEBUG
    private(set) var typographyApplicationCount = 0
    #endif

    override var columnSpecs: [BatchColumnSpec] {
        [
            .init(identifier: .init("sequenceID"), title: "Sequence", width: 130, minWidth: 80, defaultAscending: true),
            .init(identifier: .init("readCount"), title: "Reads", width: 70, minWidth: 60, defaultAscending: false),
            .init(identifier: .init("sampleCount"), title: "Samples", width: 75, minWidth: 60, defaultAscending: false),
            .init(identifier: .init("chimeraStatus"), title: "Chimera", width: 110, minWidth: 70, defaultAscending: true),
            .init(identifier: .init("sequence"), title: "Bases", width: 360, minWidth: 120, defaultAscending: true),
        ]
    }

    override var searchPlaceholder: String { "Filter species or matches" }
    override var searchAccessibilityIdentifier: String? { "twelve-s-unresolved-search" }
    override var searchAccessibilityLabel: String? { "Filter 12S unresolved sequences" }
    override var tableAccessibilityIdentifier: String? { "twelve-s-unresolved-result-table" }
    override var tableAccessibilityLabel: String? { "12S unresolved sequence results" }

    override func applyContentTypography() {
        guard tableView != nil else { return }
        let scrollOriginY = currentScrollOriginY
        adaptiveColumnWidths.captureUserWidths(in: tableView)
        super.applyContentTypography()
        adaptiveColumnWidths.apply(
            to: tableView,
            typography: resolvedContentTypography(),
            canonicalBodyPointSize: canonicalContentPointSize(for: .body)
        )
        restoreScrollOriginY(scrollOriginY)
        #if DEBUG
        typographyApplicationCount += 1
        #endif
    }

    override var columnTypeHints: [String: Bool] {
        ["readCount": true, "sampleCount": true]
    }

    private func populatedSampleCount(_ row: TwelveSUnresolvedSequence) -> Int {
        row.sampleCounts.filter { $0.value > 0 }.count
    }

    override func cellContent(
        for column: NSUserInterfaceItemIdentifier,
        row: TwelveSUnresolvedSequence
    ) -> (text: String, alignment: NSTextAlignment, font: NSFont?) {
        switch column.rawValue {
        case "sequenceID":    return (row.sequenceID, .left, nil)
        case "readCount":     return (String(row.readCount), .right, nil)
        case "sampleCount":   return (String(populatedSampleCount(row)), .right, nil)
        case "chimeraStatus": return (row.chimeraStatus.displayName, .left, nil)
        case "sequence":      return (row.sequence, .left, .monospacedSystemFont(ofSize: 11, weight: .regular))
        default:              return ("", .left, nil)
        }
    }

    override func columnValue(for columnId: String, row: TwelveSUnresolvedSequence) -> String {
        switch columnId {
        case "readCount":   return String(row.readCount)
        case "sampleCount": return String(populatedSampleCount(row))
        default:            return cellContent(for: .init(columnId), row: row).text
        }
    }

    override func compareRows(
        _ lhs: TwelveSUnresolvedSequence,
        _ rhs: TwelveSUnresolvedSequence,
        by key: String,
        ascending: Bool
    ) -> Bool {
        switch key {
        case "readCount":
            return ascending ? lhs.readCount < rhs.readCount : lhs.readCount > rhs.readCount
        case "sampleCount":
            let l = populatedSampleCount(lhs), r = populatedSampleCount(rhs)
            return ascending ? l < r : l > r
        default:
            let l = cellContent(for: .init(key), row: lhs).text
            let r = cellContent(for: .init(key), row: rhs).text
            let cmp = l.localizedStandardCompare(r)
            return ascending ? cmp == .orderedAscending : cmp == .orderedDescending
        }
    }

    override func rowMatchesFilter(_ row: TwelveSUnresolvedSequence, filterText: String) -> Bool {
        let needle = filterText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return true }
        let haystack = [row.sequenceID, row.sequence, row.chimeraStatus.displayName, row.note ?? ""]
            .joined(separator: " ")
        return haystack.localizedCaseInsensitiveContains(needle)
    }

    override func rowIdentity(for row: TwelveSUnresolvedSequence) -> String? {
        "\(resultIdentity ?? "")|\(row.sequenceID)"
    }
}
