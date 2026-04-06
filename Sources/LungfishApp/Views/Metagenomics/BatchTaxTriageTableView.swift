// BatchTaxTriageTableView.swift - Flat NSTableView wrapper for TaxTriage batch results
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import LungfishCore
import LungfishIO
import os.log

private let logger = Logger(subsystem: LogSubsystem.app, category: "BatchTaxTriageTableView")

// MARK: - Column Identifiers

private extension NSUserInterfaceItemIdentifier {
    static let tt_sample          = NSUserInterfaceItemIdentifier("tt_sample")
    static let tt_organism        = NSUserInterfaceItemIdentifier("tt_organism")
    static let tt_tassScore       = NSUserInterfaceItemIdentifier("tt_tassScore")
    static let tt_reads           = NSUserInterfaceItemIdentifier("tt_reads")
    static let tt_confidence      = NSUserInterfaceItemIdentifier("tt_confidence")
    static let tt_coverageBreadth = NSUserInterfaceItemIdentifier("tt_coverageBreadth")
    static let tt_coverageDepth   = NSUserInterfaceItemIdentifier("tt_coverageDepth")
    static let tt_abundance       = NSUserInterfaceItemIdentifier("tt_abundance")
}

// MARK: - BatchTaxTriageTableView

/// A scrollable flat table showing ``TaxTriageMetric`` records for TaxTriage batch mode.
///
/// ## Layout
///
/// One row per taxon × sample combination. Fixed columns: Sample, Organism, TASS Score,
/// Reads, Confidence, Coverage Breadth, Coverage Depth, and Abundance. Dynamic metadata
/// columns are managed by a ``MetadataColumnController``.
///
/// ## Sorting
///
/// Click any column header to sort. TASS Score sorts descending by default (highest first).
/// Multi-column sort is not supported.
///
/// ## Selection
///
/// Multi-row selection is enabled. Selection callbacks fire on every selection change.
///
/// ## Thread Safety
///
/// `@MainActor` isolated. All data must be set via ``configure(rows:)``.
@MainActor
final class BatchTaxTriageTableView: NSView {

    // MARK: - State

    /// The rows currently displayed (after any sort).
    private(set) var displayedRows: [TaxTriageMetric] = []

    /// Unsorted copy preserved so re-sort can restart from a stable baseline.
    private var unsortedRows: [TaxTriageMetric] = []

    // MARK: - Callbacks

    /// Called when the user selects a single row.
    var onRowSelected: ((TaxTriageMetric) -> Void)?

    /// Called when the user selects multiple rows.
    var onMultipleRowsSelected: (([TaxTriageMetric]) -> Void)?

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
        metadataColumns.standardColumnNames = ["Sample", "Organism", "TASS Score",
                                               "Reads", "Confidence",
                                               "Coverage Breadth", "Coverage Depth", "Abundance"]
        metadataColumns.install(on: tableView)
    }

    private func addFixedColumns() {
        // TASS Score sorts descending by default (ascending: false) — highest score first.
        let specs: [(NSUserInterfaceItemIdentifier, String, CGFloat, CGFloat, Bool)] = [
            (.tt_sample,          "Sample",          130, 70,  true),
            (.tt_organism,        "Organism",        220, 100, true),
            (.tt_tassScore,       "TASS Score",       90, 55,  false),
            (.tt_reads,           "Reads",            80, 50,  false),
            (.tt_confidence,      "Confidence",       90, 55,  true),
            (.tt_coverageBreadth, "Coverage Breadth", 110, 65, false),
            (.tt_coverageDepth,   "Coverage Depth",   100, 60, false),
            (.tt_abundance,       "Abundance",         85, 50, false),
        ]
        for (id, title, width, minWidth, ascending) in specs {
            let col = NSTableColumn(identifier: id)
            col.title    = title
            col.width    = width
            col.minWidth = minWidth
            col.sortDescriptorPrototype = NSSortDescriptor(key: id.rawValue, ascending: ascending)
            tableView.addTableColumn(col)
        }
    }

    // MARK: - Public API

    /// Replaces the displayed rows and reloads the table.
    ///
    /// - Parameter rows: The new rows to display.
    func configure(rows: [TaxTriageMetric]) {
        self.unsortedRows  = rows
        self.displayedRows = rows
        tableView.reloadData()
        logger.info("BatchTaxTriageTableView configured with \(rows.count) rows")
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

extension BatchTaxTriageTableView: NSTableViewDataSource {

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
            case "tt_sample":
                let as_ = a.sample ?? ""
                let bs_ = b.sample ?? ""
                result = as_.localizedCaseInsensitiveCompare(bs_) == .orderedAscending
            case "tt_organism":
                result = a.organism.localizedCaseInsensitiveCompare(b.organism) == .orderedAscending
            case "tt_tassScore":
                result = a.tassScore < b.tassScore
            case "tt_reads":
                result = a.reads < b.reads
            case "tt_confidence":
                let ac = a.confidence ?? ""
                let bc = b.confidence ?? ""
                result = ac.localizedCaseInsensitiveCompare(bc) == .orderedAscending
            case "tt_coverageBreadth":
                result = (a.coverageBreadth ?? 0) < (b.coverageBreadth ?? 0)
            case "tt_coverageDepth":
                result = (a.coverageDepth ?? 0) < (b.coverageDepth ?? 0)
            case "tt_abundance":
                result = (a.abundance ?? 0) < (b.abundance ?? 0)
            default:
                result = false
            }
            return ascending ? result : !result
        }
        tableView.reloadData()
    }
}

// MARK: - NSTableViewDelegate

extension BatchTaxTriageTableView: NSTableViewDelegate {

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let column = tableColumn, row < displayedRows.count else { return nil }

        // Metadata columns handled by the controller
        if MetadataColumnController.isMetadataColumn(column.identifier) {
            let rowData = displayedRows[row]
            return metadataColumns.cellForColumn(column, sampleId: rowData.sample ?? "")
        }

        let rowData = displayedRows[row]
        let id = column.identifier

        let cellView = tableView.makeView(withIdentifier: id, owner: self) as? NSTableCellView
            ?? makeCellView(identifier: id)

        switch id {
        case .tt_sample:
            cellView.textField?.stringValue = rowData.sample ?? "—"
            cellView.textField?.font = .systemFont(ofSize: 11, weight: .medium)
            cellView.textField?.alignment = .left

        case .tt_organism:
            cellView.textField?.stringValue = rowData.organism
            cellView.textField?.font = .systemFont(ofSize: 11)
            cellView.textField?.alignment = .left

        case .tt_tassScore:
            cellView.textField?.stringValue = String(format: "%.3f", rowData.tassScore)
            cellView.textField?.alignment = .right

        case .tt_reads:
            cellView.textField?.stringValue = formatTtReadCount(rowData.reads)
            cellView.textField?.alignment = .right

        case .tt_confidence:
            cellView.textField?.stringValue = rowData.confidence ?? "—"
            cellView.textField?.font = .systemFont(ofSize: 11)
            cellView.textField?.alignment = .left

        case .tt_coverageBreadth:
            if let breadth = rowData.coverageBreadth {
                cellView.textField?.stringValue = String(format: "%.1f%%", breadth)
            } else {
                cellView.textField?.stringValue = "—"
            }
            cellView.textField?.alignment = .right

        case .tt_coverageDepth:
            if let depth = rowData.coverageDepth {
                cellView.textField?.stringValue = String(format: "%.1f×", depth)
            } else {
                cellView.textField?.stringValue = "—"
            }
            cellView.textField?.alignment = .right

        case .tt_abundance:
            if let abundance = rowData.abundance {
                cellView.textField?.stringValue = String(format: "%.2f%%", abundance * 100)
            } else {
                cellView.textField?.stringValue = "—"
            }
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

        let selected = selectedIndexes.compactMap { idx -> TaxTriageMetric? in
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

private func formatTtReadCount(_ count: Int) -> String {
    if count >= 1_000_000 {
        return String(format: "%.1fM", Double(count) / 1_000_000)
    } else if count >= 1_000 {
        return String(format: "%.1fK", Double(count) / 1_000)
    }
    return "\(count)"
}
