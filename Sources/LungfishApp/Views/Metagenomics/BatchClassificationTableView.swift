// BatchClassificationTableView.swift - Flat NSTableView wrapper for Kraken2 batch results
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import LungfishCore
import os.log

private let logger = Logger(subsystem: LogSubsystem.app, category: "BatchClassificationTableView")

// MARK: - Column Identifiers

private extension NSUserInterfaceItemIdentifier {
    static let sample      = NSUserInterfaceItemIdentifier("sample")
    static let name        = NSUserInterfaceItemIdentifier("name")
    static let rank        = NSUserInterfaceItemIdentifier("rank")
    static let readsDirect = NSUserInterfaceItemIdentifier("readsDirect")
    static let readsClade  = NSUserInterfaceItemIdentifier("readsClade")
    static let percent     = NSUserInterfaceItemIdentifier("percent")
}

// MARK: - BatchClassificationTableView

/// A scrollable flat table showing ``BatchClassificationRow`` records for Kraken2 batch mode.
///
/// ## Layout
///
/// One row per taxon × sample combination. Fixed columns: Sample, Name, Rank,
/// Reads (direct), Reads (clade), and Percentage. Dynamic metadata columns
/// are managed by a ``MetadataColumnController``.
///
/// ## Sorting
///
/// Click any column header to sort. Multi-column sort is not supported.
///
/// ## Selection
///
/// Multi-row selection is enabled. Selection callbacks fire on every selection change.
///
/// ## Thread Safety
///
/// `@MainActor` isolated. All data must be set via ``configure(rows:)``.
@MainActor
final class BatchClassificationTableView: NSView {

    // MARK: - State

    /// The rows currently displayed (after any sort).
    private(set) var displayedRows: [BatchClassificationRow] = []

    /// Unsorted copy preserved so re-sort can restart from a stable baseline.
    private var unsortedRows: [BatchClassificationRow] = []

    // MARK: - Callbacks

    /// Called when the user selects a single row.
    var onRowSelected: ((BatchClassificationRow) -> Void)?

    /// Called when the user selects multiple rows.
    var onMultipleRowsSelected: (([BatchClassificationRow]) -> Void)?

    /// Called when the selection is cleared.
    var onSelectionCleared: (() -> Void)?

    // MARK: - Metadata Columns

    /// Controller for dynamic sample-metadata columns (from imported CSV/TSV).
    let metadataColumns = MetadataColumnController()

    // MARK: - Child Views

    private let scrollView = NSScrollView()
    private let tableView  = NSTableView()

    // MARK: - Init

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupTableView()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupTableView()
    }

    // MARK: - Setup

    private func setupTableView() {
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.hasVerticalScroller   = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers    = true
        addSubview(scrollView)

        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])

        tableView.usesAlternatingRowBackgroundColors = true
        tableView.allowsColumnReordering  = true
        tableView.allowsColumnResizing    = true
        tableView.allowsColumnSelection   = false
        tableView.allowsMultipleSelection = true
        tableView.rowHeight               = 22
        tableView.style                   = .plain
        tableView.delegate                = self
        tableView.dataSource              = self
        tableView.columnAutoresizingStyle = .noColumnAutoresizing

        addFixedColumns()
        scrollView.documentView = tableView

        metadataColumns.isMultiSampleMode = true
        metadataColumns.standardColumnNames = ["Sample", "Name", "Rank",
                                               "Reads (direct)", "Reads (clade)", "%"]
        metadataColumns.install(on: tableView)
    }

    private func addFixedColumns() {
        let specs: [(NSUserInterfaceItemIdentifier, String, CGFloat, CGFloat, Bool)] = [
            (.sample,      "Sample",        130, 70,  true),
            (.name,        "Name",          220, 100, true),
            (.rank,        "Rank",          80,  50,  true),
            (.readsDirect, "Reads (direct)", 90, 60,  false),
            (.readsClade,  "Reads (clade)",  90, 60,  false),
            (.percent,     "%",             65,  45,  false),
        ]
        for (id, title, width, minWidth, ascending) in specs {
            let col = NSTableColumn(identifier: id)
            col.title   = title
            col.width   = width
            col.minWidth = minWidth
            col.sortDescriptorPrototype = NSSortDescriptor(key: id.rawValue, ascending: ascending)
            tableView.addTableColumn(col)
        }
    }

    // MARK: - Public API

    /// Replaces the displayed rows and reloads the table.
    ///
    /// - Parameter rows: The new rows to display.
    func configure(rows: [BatchClassificationRow]) {
        self.unsortedRows  = rows
        self.displayedRows = rows
        tableView.reloadData()
        logger.info("BatchClassificationTableView configured with \(rows.count) rows")
    }

    // MARK: - Cell Factory

    private func makeCellView(identifier: NSUserInterfaceItemIdentifier) -> NSTableCellView {
        let cell = NSTableCellView()
        cell.identifier = identifier
        let tf = NSTextField(labelWithString: "")
        tf.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        tf.lineBreakMode = .byTruncatingTail
        tf.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(tf)
        cell.textField = tf
        NSLayoutConstraint.activate([
            tf.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4),
            tf.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4),
            tf.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        return cell
    }
}

// MARK: - NSTableViewDataSource

extension BatchClassificationTableView: NSTableViewDataSource {

    func numberOfRows(in tableView: NSTableView) -> Int {
        displayedRows.count
    }

    func tableView(_ tableView: NSTableView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
        guard let descriptor = tableView.sortDescriptors.first,
              let key = descriptor.key else {
            displayedRows = unsortedRows
            tableView.reloadData()
            return
        }

        let ascending = descriptor.ascending
        displayedRows = unsortedRows.sorted { a, b in
            let result: Bool
            switch key {
            case "sample":
                result = a.sample.localizedCaseInsensitiveCompare(b.sample) == .orderedAscending
            case "name":
                result = a.taxonName.localizedCaseInsensitiveCompare(b.taxonName) == .orderedAscending
            case "rank":
                result = a.rankDisplayName.localizedCaseInsensitiveCompare(b.rankDisplayName) == .orderedAscending
            case "readsDirect":
                result = a.readsDirect < b.readsDirect
            case "readsClade":
                result = a.readsClade < b.readsClade
            case "percent":
                result = a.percentage < b.percentage
            default:
                result = false
            }
            return ascending ? result : !result
        }
        tableView.reloadData()
    }
}

// MARK: - NSTableViewDelegate

extension BatchClassificationTableView: NSTableViewDelegate {

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let column = tableColumn, row < displayedRows.count else { return nil }

        // Metadata columns handled by the controller
        if MetadataColumnController.isMetadataColumn(column.identifier) {
            let rowData = displayedRows[row]
            return metadataColumns.cellForColumn(column, sampleId: rowData.sample)
        }

        let rowData = displayedRows[row]
        let id = column.identifier

        let cellView = tableView.makeView(withIdentifier: id, owner: self) as? NSTableCellView
            ?? makeCellView(identifier: id)

        switch id {
        case .sample:
            cellView.textField?.stringValue = rowData.sample
            cellView.textField?.font = .systemFont(ofSize: 11, weight: .medium)
            cellView.textField?.alignment = .left

        case .name:
            cellView.textField?.stringValue = rowData.taxonName
            cellView.textField?.font = .systemFont(ofSize: 11)
            cellView.textField?.alignment = .left

        case .rank:
            cellView.textField?.stringValue = rowData.rankDisplayName
            cellView.textField?.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
            cellView.textField?.alignment = .left

        case .readsDirect:
            cellView.textField?.stringValue = formatReadCount(rowData.readsDirect)
            cellView.textField?.alignment = .right

        case .readsClade:
            cellView.textField?.stringValue = formatReadCount(rowData.readsClade)
            cellView.textField?.alignment = .right

        case .percent:
            cellView.textField?.stringValue = String(format: "%.2f%%", rowData.percentage)
            cellView.textField?.alignment = .right

        default:
            cellView.textField?.stringValue = ""
        }

        return cellView
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        let selectedIndexes = tableView.selectedRowIndexes
        if selectedIndexes.isEmpty {
            onSelectionCleared?()
            return
        }

        let selected = selectedIndexes.compactMap { idx -> BatchClassificationRow? in
            guard idx < displayedRows.count else { return nil }
            return displayedRows[idx]
        }

        if selected.count == 1, let row = selected.first {
            onRowSelected?(row)
        } else if selected.count > 1 {
            onMultipleRowsSelected?(selected)
        }
    }
}

// MARK: - Helpers

private func formatReadCount(_ count: Int) -> String {
    if count >= 1_000_000 {
        return String(format: "%.1fM", Double(count) / 1_000_000)
    } else if count >= 1_000 {
        return String(format: "%.1fK", Double(count) / 1_000)
    }
    return "\(count)"
}
