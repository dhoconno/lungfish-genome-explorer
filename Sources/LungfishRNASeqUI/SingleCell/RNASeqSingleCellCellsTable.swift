// RNASeqSingleCellCellsTable.swift - The cells table of a single-cell result, paged from cells.sqlite
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// The table asks `RNASeqSingleCellPages` for the rows it draws, a page at a time, so half a million cells never sit in
// memory. Each cell of the table is a value of the file. The share at nM 0 or 1 shows as the two counts it comes from,
// and the flag is `not_host_calls.flag` as written, so a row whose p and q are null shows the table's own words.

import AppKit
import LungfishIO

/// The columns, the words of each cell and the table's data source.
@MainActor
public final class RNASeqSingleCellTableSource: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    public struct Column: Equatable, Sendable {
        public var id: String
        public var title: String
    }

    public let pages: RNASeqSingleCellPages
    public let columns: [Column]
    private let sampleNames: [Int: String]

    public init(pages: RNASeqSingleCellPages, summary: RNASeqSingleCellSummary) {
        self.pages = pages
        self.sampleNames = Dictionary(summary.samples.map { ($0.sample, $0.name) }, uniquingKeysWith: { first, _ in first })
        var columns = [
            Column(id: "cell", title: "Cell"), Column(id: "sample", title: "Sample"), Column(id: "barcode", title: "Barcode"),
            Column(id: "umis", title: "UMIs"), Column(id: "genes", title: "Genes"),
        ]
        for extra in summary.extras {
            columns += [
                Column(id: "not-host-\(extra.extra)-umis", title: "\(extra.name) UMIs"),
                Column(id: "not-host-\(extra.extra)-masked", title: "\(extra.name) masked UMIs"),
                Column(id: "not-host-\(extra.extra)-nm01", title: "\(extra.name) UMIs at nM 0 or 1"),
                Column(id: "not-host-\(extra.extra)-flag", title: "\(extra.name) flag"),
            ]
        }
        self.columns = columns
    }

    /// The words the table shows in `column` of row `row`.
    public func text(row: Int, column id: String) -> String {
        guard let found = pages.row(row) else { return "" }
        let cell = found.cell
        switch id {
        case "cell": return String(cell.cell)
        case "sample": return sampleNames[cell.sample] ?? String(cell.sample)
        case "barcode": return cell.barcode
        case "umis": return String(cell.umis)
        case "genes": return String(cell.genes)
        default: break
        }
        let parts = id.split(separator: "-")
        guard parts.count == 4, let extra = Int(parts[2]) else { return "" }
        let columns = found.notHost.first { $0.extra == extra }
        switch parts[3] {
        case "umis": return String(columns?.umis ?? 0)
        case "masked": return String(columns?.maskedUMIs ?? 0)
        case "nm01": return "\(columns?.umisNM01 ?? 0) of \(columns?.umis ?? 0)"
        case "flag": return columns?.call?.flag ?? ""
        default: return ""
        }
    }

    /// Adds the columns to `table` and makes this object its source.
    public func install(in table: NSTableView) {
        for column in table.tableColumns { table.removeTableColumn(column) }
        for column in columns {
            let item = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(column.id))
            item.title = column.title
            item.isEditable = false
            item.width = column.id.hasSuffix("flag") ? 220 : column.id == "barcode" ? 160 : 90
            table.addTableColumn(item)
        }
        table.dataSource = self
        table.delegate = self
        table.reloadData()
    }

    public func numberOfRows(in tableView: NSTableView) -> Int { pages.count }

    public func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let id = tableColumn?.identifier else { return nil }
        let field = (tableView.makeView(withIdentifier: id, owner: self) as? NSTextField) ?? {
            let made = NSTextField(labelWithString: "")
            made.identifier = id
            made.isEditable = false
            made.isSelectable = true
            made.lineBreakMode = .byTruncatingTail
            return made
        }()
        field.stringValue = text(row: row, column: id.rawValue)
        return field
    }

    public func tableView(_ tableView: NSTableView, shouldEdit tableColumn: NSTableColumn?, row: Int) -> Bool { false }
}
