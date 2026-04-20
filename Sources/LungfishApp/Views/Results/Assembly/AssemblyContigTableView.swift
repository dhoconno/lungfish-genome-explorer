// AssemblyContigTableView.swift - Filterable contig table for assembly results
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import LungfishWorkflow

@MainActor
final class AssemblyContigTableView: BatchTableView<AssemblyContigRecord> {
    var scalarPasteboard: PasteboardWriting = DefaultPasteboard()

    override var columnSpecs: [BatchColumnSpec] {
        [
            .init(identifier: NSUserInterfaceItemIdentifier("rank"), title: "#", width: 44, minWidth: 34, defaultAscending: true),
            .init(identifier: NSUserInterfaceItemIdentifier("name"), title: "Contig", width: 220, minWidth: 140, defaultAscending: true),
            .init(identifier: NSUserInterfaceItemIdentifier("length"), title: "Length (bp)", width: 110, minWidth: 90, defaultAscending: false),
            .init(identifier: NSUserInterfaceItemIdentifier("gc"), title: "GC %", width: 90, minWidth: 70, defaultAscending: false),
            .init(identifier: NSUserInterfaceItemIdentifier("share"), title: "Share of Assembly (%)", width: 150, minWidth: 120, defaultAscending: false),
        ]
    }

    override var searchPlaceholder: String { "Filter contigs by name or header…" }
    override var searchAccessibilityIdentifier: String? { "assembly-result-search" }
    override var searchAccessibilityLabel: String? { "Filter assembly contigs" }
    override var tableAccessibilityIdentifier: String? { "assembly-result-contig-table" }
    override var tableAccessibilityLabel: String? { "Assembly contig table" }
    override var cellCopyPasteboard: PasteboardWriting? { scalarPasteboard }

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
