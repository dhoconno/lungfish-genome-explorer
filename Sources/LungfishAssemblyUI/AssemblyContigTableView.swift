// AssemblyContigTableView.swift - Filterable contig table for assembly results
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import LungfishWorkflow
import LungfishKit

@MainActor
final class AssemblyContigTableView: BatchTableView<AssemblyContigRecord> {
    var scalarPasteboard: PasteboardWriting = DefaultPasteboard()
    private var baselineWidths: [String: CGFloat] = [:]
    private var baselineMinimumWidths: [String: CGFloat] = [:]
    private var lastProgrammaticWidths: [String: CGFloat] = [:]
    private var lastResolvedScale: CGFloat = 1
    private var isApplyingAdaptiveColumnWidths = false

    override var columnSpecs: [BatchColumnSpec] {
        [
            .init(identifier: NSUserInterfaceItemIdentifier("rank"), title: "#", width: 44, minWidth: 34, defaultAscending: true),
            .init(identifier: NSUserInterfaceItemIdentifier("name"), title: "Contig", width: 220, minWidth: 140, defaultAscending: true),
            .init(
                identifier: NSUserInterfaceItemIdentifier("length"),
                title: "Length (bp)",
                width: 110,
                minWidth: 90,
                defaultAscending: false,
                toolTip: "Length (bp)"
            ),
            .init(identifier: NSUserInterfaceItemIdentifier("gc"), title: "GC %", width: 90, minWidth: 70, defaultAscending: false),
            .init(
                identifier: NSUserInterfaceItemIdentifier("share"),
                title: "Share of Assembly (%)",
                width: 150,
                minWidth: 120,
                defaultAscending: false,
                toolTip: "Share of Assembly (%)"
            ),
            .init(
                identifier: NSUserInterfaceItemIdentifier("preview"),
                title: "Sequence Preview",
                width: 360,
                minWidth: 220,
                defaultAscending: true,
                toolTip: "Sequence Preview"
            ),
        ]
    }

    override var searchPlaceholder: String { "Filter contigs by name or header…" }
    override var searchAccessibilityIdentifier: String? { "assembly-result-search" }
    override var searchAccessibilityLabel: String? { "Filter assembly contigs" }
    override var tableAccessibilityIdentifier: String? { "assembly-result-contig-table" }
    override var tableAccessibilityLabel: String? { "Assembly contig table" }
    override var cellCopyPasteboard: PasteboardWriting? { scalarPasteboard }

    override func applyContentTypography() {
        captureUserColumnWidths()
        super.applyContentTypography()
        applyAdaptiveColumnWidths()
    }

    private func captureUserColumnWidths() {
        guard tableView != nil, !isApplyingAdaptiveColumnWidths else { return }
        for column in tableView.tableColumns {
            let identifier = column.identifier.rawValue
            if baselineWidths[identifier] == nil {
                baselineWidths[identifier] = column.width
                baselineMinimumWidths[identifier] = column.minWidth
            } else if let lastWidth = lastProgrammaticWidths[identifier],
                      abs(column.width - lastWidth) > 0.5 {
                baselineWidths[identifier] = column.width / max(lastResolvedScale, 0.01)
            }
        }
    }

    private func applyAdaptiveColumnWidths() {
        guard tableView != nil else { return }
        let typography = resolvedContentTypography()
        let scale = typography.font(for: .body).pointSize
            / max(canonicalContentPointSize(for: .body), 1)
        isApplyingAdaptiveColumnWidths = true
        defer {
            isApplyingAdaptiveColumnWidths = false
            lastResolvedScale = scale
        }
        for column in tableView.tableColumns {
            let identifier = column.identifier.rawValue
            let baselineWidth = baselineWidths[identifier] ?? column.width
            let baselineMinimum = baselineMinimumWidths[identifier] ?? column.minWidth
            baselineWidths[identifier] = baselineWidth
            baselineMinimumWidths[identifier] = baselineMinimum

            let headerWidth = ceil(column.headerCell.cellSize.width + 20)
            let adaptiveMinimum = scale > 1.01
                ? max(baselineMinimum, headerWidth)
                : baselineMinimum
            let adaptiveWidth = max(
                adaptiveMinimum,
                max(
                    baselineWidth * scale,
                    scale > 1.01 ? headerWidth : 0
                )
            )
            column.minWidth = adaptiveMinimum
            column.width = adaptiveWidth
            lastProgrammaticWidths[identifier] = column.width
        }
    }

    override var columnTypeHints: [String : Bool] {
        [
            "rank": true,
            "length": true,
            "gc": true,
            "share": true,
        ]
    }

    override func cellContent(
        for column: NSUserInterfaceItemIdentifier,
        row: AssemblyContigRecord
    ) -> (text: String, alignment: NSTextAlignment, font: NSFont?) {
        switch column.rawValue {
        case "rank":
            return ("\(row.rank)", .right, nil)
        case "name":
            return (row.name, .left, nil)
        case "length":
            return ("\(row.lengthBP)", .right, nil)
        case "gc":
            return (String(format: "%.1f", row.gcPercent), .right, nil)
        case "share":
            return (String(format: "%.2f", row.shareOfAssemblyPercent), .right, nil)
        case "preview":
            return (
                row.previewSequence,
                .left,
                nil
            )
        default:
            return ("", .left, nil)
        }
    }

    override func rowMatchesFilter(_ row: AssemblyContigRecord, filterText: String) -> Bool {
        let query = filterText.lowercased()
        return row.name.lowercased().contains(query) || row.header.lowercased().contains(query)
    }

    override func compareRows(
        _ lhs: AssemblyContigRecord,
        _ rhs: AssemblyContigRecord,
        by key: String,
        ascending: Bool
    ) -> Bool {
        switch key {
        case "rank":
            return ascending ? lhs.rank < rhs.rank : lhs.rank > rhs.rank
        case "name":
            return ascending ? lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
                : lhs.name.localizedStandardCompare(rhs.name) == .orderedDescending
        case "length":
            return ascending ? lhs.lengthBP < rhs.lengthBP : lhs.lengthBP > rhs.lengthBP
        case "gc":
            return ascending ? lhs.gcPercent < rhs.gcPercent : lhs.gcPercent > rhs.gcPercent
        case "share":
            return ascending ? lhs.shareOfAssemblyPercent < rhs.shareOfAssemblyPercent : lhs.shareOfAssemblyPercent > rhs.shareOfAssemblyPercent
        case "preview":
            return ascending
                ? lhs.previewSequence.localizedStandardCompare(rhs.previewSequence) == .orderedAscending
                : lhs.previewSequence.localizedStandardCompare(rhs.previewSequence) == .orderedDescending
        default:
            return ascending ? lhs.rank < rhs.rank : lhs.rank > rhs.rank
        }
    }

    override func columnValue(for columnId: String, row: AssemblyContigRecord) -> String {
        switch columnId {
        case "rank":
            return "\(row.rank)"
        case "name":
            return row.name
        case "length":
            return "\(row.lengthBP)"
        case "gc":
            return String(format: "%.1f", row.gcPercent)
        case "share":
            return String(format: "%.2f", row.shareOfAssemblyPercent)
        case "preview":
            return row.previewSequence
        default:
            return row.header
        }
    }

    func selectContigs(named names: [String]) {
        let wanted = Set(names)
        let indexes = IndexSet(displayedRows.enumerated().compactMap { wanted.contains($0.element.name) ? $0.offset : nil })
        tableView.selectRowIndexes(indexes, byExtendingSelection: false)
    }

    func record(at row: Int) -> AssemblyContigRecord? {
        guard row >= 0, row < displayedRows.count else { return nil }
        return displayedRows[row]
    }

    func copyValue(row: Int, columnID: String, pasteboard: PasteboardWriting) {
        guard let record = record(at: row) else { return }
        pasteboard.setString(columnValue(for: columnID, row: record))
    }
}
