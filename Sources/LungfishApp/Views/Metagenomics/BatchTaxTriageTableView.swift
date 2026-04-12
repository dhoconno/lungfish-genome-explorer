// BatchTaxTriageTableView.swift - NSTableView wrapper for TaxTriage batch results
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import LungfishCore
import LungfishIO
import SwiftUI
import os.log

private let logger = Logger(subsystem: LogSubsystem.app, category: "BatchTaxTriageTableView")

// MARK: - Column Identifiers

private extension NSUserInterfaceItemIdentifier {
    static let tt_sample          = NSUserInterfaceItemIdentifier("tt_sample")
    static let tt_organism        = NSUserInterfaceItemIdentifier("tt_organism")
    static let tt_tassScore       = NSUserInterfaceItemIdentifier("tt_tassScore")
    static let tt_reads           = NSUserInterfaceItemIdentifier("tt_reads")
    static let tt_uniqueReads     = NSUserInterfaceItemIdentifier("tt_uniqueReads")
    static let tt_confidence      = NSUserInterfaceItemIdentifier("tt_confidence")
    static let tt_coverageBreadth = NSUserInterfaceItemIdentifier("tt_coverageBreadth")
    static let tt_coverageDepth   = NSUserInterfaceItemIdentifier("tt_coverageDepth")
    static let tt_abundance       = NSUserInterfaceItemIdentifier("tt_abundance")
}

// MARK: - BatchTaxTriageTableView

/// A scrollable flat table showing ``TaxTriageMetric`` records for TaxTriage batch mode.
///
/// One row per taxon × sample combination. Inherits all layout, sort, filter,
/// selection, and metadata column boilerplate from ``BatchTableView``.
///
/// ## Extra State
///
/// ``uniqueReadsByKey`` holds deduplication counts populated asynchronously by the
/// owning view controller. Call ``reloadUniqueReadsColumn()`` after updating it.
@MainActor
final class BatchTaxTriageTableView: BatchTableView<TaxTriageMetric> {

    // MARK: - Callbacks

    /// Fired when the user invokes "Extract Reads..." from the context menu.
    /// The VC reads the current selection from the table view itself.
    var onExtractReadsRequested: (() -> Void)?

    /// Fired when the user invokes "Verify with BLAST..." from the context menu.
    /// Parameters: the clicked metric row, and the read count chosen via the popover.
    var onBlastVerifyRequested: ((TaxTriageMetric, Int) -> Void)?

    // MARK: - Context Menu

    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        installContextMenu()
    }

    private func installContextMenu() {
        guard tableView.menu == nil else { return }
        let menu = NSMenu()

        let blastItem = NSMenuItem(
            title: "Verify with BLAST\u{2026}",
            action: #selector(contextBlastVerify(_:)),
            keyEquivalent: ""
        )
        blastItem.target = self
        menu.addItem(blastItem)

        menu.addItem(NSMenuItem.separator())

        let copyOrganismItem = NSMenuItem(
            title: "Copy Organism Name",
            action: #selector(contextCopyOrganism(_:)),
            keyEquivalent: ""
        )
        copyOrganismItem.target = self
        menu.addItem(copyOrganismItem)

        let copyTaxIdItem = NSMenuItem(
            title: "Copy TaxID",
            action: #selector(contextCopyTaxId(_:)),
            keyEquivalent: ""
        )
        copyTaxIdItem.target = self
        menu.addItem(copyTaxIdItem)

        let copyRowTSVItem = NSMenuItem(
            title: "Copy Row as TSV",
            action: #selector(contextCopyRowTSV(_:)),
            keyEquivalent: ""
        )
        copyRowTSVItem.target = self
        menu.addItem(copyRowTSVItem)

        menu.addItem(NSMenuItem.separator())

        let lookupItem = NSMenuItem(
            title: "Look Up in NCBI Taxonomy",
            action: #selector(contextLookUpNCBI(_:)),
            keyEquivalent: ""
        )
        lookupItem.target = self
        menu.addItem(lookupItem)

        menu.addItem(NSMenuItem.separator())

        let extractItem = NSMenuItem(
            title: "Extract Reads\u{2026}",
            action: #selector(contextExtractReads(_:)),
            keyEquivalent: ""
        )
        extractItem.target = self
        menu.addItem(extractItem)

        tableView.menu = menu
    }

    // MARK: - Context Menu Actions

    @objc private func contextBlastVerify(_ sender: Any?) {
        let clickedRow = tableView.clickedRow
        guard clickedRow >= 0, clickedRow < displayedRows.count else { return }
        let metric = displayedRows[clickedRow]

        let popover = NSPopover()
        popover.behavior = .transient
        popover.contentSize = NSSize(width: 280, height: 160)
        popover.contentViewController = NSHostingController(
            rootView: BlastConfigPopoverView(
                taxonName: metric.organism,
                readsClade: metric.reads,
                onRun: { [weak self, weak popover] readCount in
                    popover?.close()
                    self?.onBlastVerifyRequested?(metric, readCount)
                }
            )
        )

        let rowRect = tableView.rect(ofRow: clickedRow)
        popover.show(relativeTo: rowRect, of: tableView, preferredEdge: .maxY)
    }

    @objc private func contextCopyOrganism(_ sender: Any?) {
        let row = tableView.clickedRow
        guard row >= 0, row < displayedRows.count else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(displayedRows[row].organism, forType: .string)
    }

    @objc private func contextCopyTaxId(_ sender: Any?) {
        let row = tableView.clickedRow
        guard row >= 0, row < displayedRows.count else { return }
        let metric = displayedRows[row]
        let taxIdString = metric.taxId.map(String.init) ?? ""
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(taxIdString, forType: .string)
    }

    @objc private func contextCopyRowTSV(_ sender: Any?) {
        let row = tableView.clickedRow
        guard row >= 0, row < displayedRows.count else { return }
        let metric = displayedRows[row]
        let fields: [String] = [
            metric.sample ?? "",
            metric.organism,
            String(format: "%.4f", metric.tassScore),
            "\(metric.reads)",
            metric.confidence ?? "",
            metric.coverageBreadth.map { String(format: "%.1f", $0) } ?? "",
            metric.coverageDepth.map { String(format: "%.1f", $0) } ?? "",
            metric.abundance.map { String(format: "%.4f", $0) } ?? "",
            metric.taxId.map(String.init) ?? "",
            metric.rank ?? "",
        ]
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(fields.joined(separator: "\t"), forType: .string)
    }

    @objc private func contextLookUpNCBI(_ sender: Any?) {
        let row = tableView.clickedRow
        guard row >= 0, row < displayedRows.count else { return }
        let metric = displayedRows[row]
        let urlString: String
        if let taxId = metric.taxId {
            urlString = "https://www.ncbi.nlm.nih.gov/Taxonomy/Browser/wwwtax.cgi?id=\(taxId)"
        } else {
            let encoded = metric.organism.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? metric.organism
            urlString = "https://www.ncbi.nlm.nih.gov/Taxonomy/Browser/wwwtax.cgi?name=\(encoded)"
        }
        if let url = URL(string: urlString) {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func contextExtractReads(_ sender: Any?) {
        onExtractReadsRequested?()
    }

    // MARK: - Menu Validation

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(contextBlastVerify(_:)) {
            // BLAST requires exactly one row (the clicked row).
            return tableView.clickedRow >= 0 && tableView.selectedRowIndexes.count <= 1
        }
        if menuItem.action == #selector(contextCopyOrganism(_:))
            || menuItem.action == #selector(contextCopyTaxId(_:))
            || menuItem.action == #selector(contextCopyRowTSV(_:))
            || menuItem.action == #selector(contextLookUpNCBI(_:)) {
            return tableView.clickedRow >= 0
        }
        if menuItem.action == #selector(contextExtractReads(_:)) {
            return !tableView.selectedRowIndexes.isEmpty || tableView.clickedRow >= 0
        }
        return true
    }

    /// Returns the metrics for all currently selected rows.
    func selectedMetrics() -> [TaxTriageMetric] {
        tableView.selectedRowIndexes.compactMap { index in
            guard index < displayedRows.count else { return nil }
            return displayedRows[index]
        }
    }

    // MARK: - Extra State

    /// Lookup dictionary for BAM-derived total read counts in batch modes.
    ///
    /// Key format: `"<sampleId>\t<organism>"`. Values are populated from
    /// miniBAM selections and/or background computation. When absent, cells fall
    /// back to the parser-provided `row.reads` value.
    var totalReadsByKey: [String: Int] = [:]

    /// Lookup dictionary for unique (deduplicated) read counts in batch group mode.
    ///
    /// Key format: `"<sampleId>\t<organism>"`. Values are populated from
    /// `perSampleDeduplicatedReadCounts` by the owning view controller as background
    /// BAM deduplication completes. Cells show "—" when the key is absent.
    var uniqueReadsByKey: [String: Int] = [:]

    // MARK: - Subclass Hooks

    override var columnSpecs: [BatchColumnSpec] {
        [
            // TASS Score sorts descending by default (defaultAscending: false) — highest score first.
            BatchColumnSpec(identifier: .tt_sample,          title: "Sample",          width: 130, minWidth: 70,  defaultAscending: true),
            BatchColumnSpec(identifier: .tt_organism,        title: "Organism",        width: 220, minWidth: 100, defaultAscending: true),
            BatchColumnSpec(identifier: .tt_tassScore,       title: "TASS Score",      width: 90,  minWidth: 55,  defaultAscending: false),
            BatchColumnSpec(identifier: .tt_reads,           title: "Reads",           width: 80,  minWidth: 50,  defaultAscending: false),
            BatchColumnSpec(identifier: .tt_uniqueReads,     title: "Unique Reads",    width: 90,  minWidth: 55,  defaultAscending: false),
            BatchColumnSpec(identifier: .tt_confidence,      title: "Confidence",      width: 90,  minWidth: 55,  defaultAscending: true),
            BatchColumnSpec(identifier: .tt_coverageBreadth, title: "Coverage Breadth", width: 110, minWidth: 65, defaultAscending: false),
            BatchColumnSpec(identifier: .tt_coverageDepth,   title: "Coverage Depth",  width: 100, minWidth: 60,  defaultAscending: false),
            BatchColumnSpec(identifier: .tt_abundance,       title: "Abundance",       width: 85,  minWidth: 50,  defaultAscending: false),
        ]
    }

    override var searchPlaceholder: String { "Filter organisms\u{2026}" }

    override var columnTypeHints: [String: Bool] {
        [
            "sample": false, "organism": false, "confidence": false,
            "tassScore": true, "reads": true, "uniqueReads": true,
            "coverageBreadth": true, "coverageDepth": true, "abundance": true,
        ]
    }

    override var standardColumnNames: [String] {
        ["Sample", "Organism", "TASS Score",
         "Reads", "Unique Reads", "Confidence",
         "Coverage Breadth", "Coverage Depth", "Abundance"]
    }

    override func cellContent(
        for column: NSUserInterfaceItemIdentifier,
        row: TaxTriageMetric
    ) -> (text: String, alignment: NSTextAlignment, font: NSFont?) {
        switch column {
        case .tt_sample:
            return (row.sample ?? "\u{2014}", .left, .systemFont(ofSize: 11, weight: .medium))
        case .tt_organism:
            return (row.organism, .left, .systemFont(ofSize: 11))
        case .tt_tassScore:
            return (String(format: "%.3f", row.tassScore), .right, nil)
        case .tt_reads:
            let key = rowKey(for: row)
            let reads = totalReadsByKey[key] ?? row.reads
            return (formatReadCount(reads), .right, nil)
        case .tt_uniqueReads:
            let key = rowKey(for: row)
            let text = uniqueReadsByKey[key].map { formatReadCount($0) } ?? "\u{2014}"
            return (text, .right, nil)
        case .tt_confidence:
            return (row.confidence ?? "\u{2014}", .left, .systemFont(ofSize: 11))
        case .tt_coverageBreadth:
            let text = row.coverageBreadth.map { String(format: "%.1f%%", $0) } ?? "\u{2014}"
            return (text, .right, nil)
        case .tt_coverageDepth:
            let text = row.coverageDepth.map { String(format: "%.1f\u{00D7}", $0) } ?? "\u{2014}"
            return (text, .right, nil)
        case .tt_abundance:
            let text = row.abundance.map { String(format: "%.2f%%", $0 * 100) } ?? "\u{2014}"
            return (text, .right, nil)
        default:
            return ("", .left, nil)
        }
    }

    override func rowMatchesFilter(_ row: TaxTriageMetric, filterText: String) -> Bool {
        row.organism.localizedCaseInsensitiveContains(filterText)
    }

    override func compareRows(
        _ lhs: TaxTriageMetric,
        _ rhs: TaxTriageMetric,
        by key: String,
        ascending: Bool
    ) -> Bool {
        let result: Bool
        switch key {
        case "tt_sample":
            let ls = lhs.sample ?? ""; let rs = rhs.sample ?? ""
            result = ls.localizedCaseInsensitiveCompare(rs) == .orderedAscending
        case "tt_organism":
            result = lhs.organism.localizedCaseInsensitiveCompare(rhs.organism) == .orderedAscending
        case "tt_tassScore":
            result = lhs.tassScore < rhs.tassScore
        case "tt_reads":
            let lk = rowKey(for: lhs)
            let rk = rowKey(for: rhs)
            result = (totalReadsByKey[lk] ?? lhs.reads) < (totalReadsByKey[rk] ?? rhs.reads)
        case "tt_uniqueReads":
            let lk = rowKey(for: lhs)
            let rk = rowKey(for: rhs)
            result = (uniqueReadsByKey[lk] ?? -1) < (uniqueReadsByKey[rk] ?? -1)
        case "tt_confidence":
            let lc = lhs.confidence ?? ""; let rc = rhs.confidence ?? ""
            result = lc.localizedCaseInsensitiveCompare(rc) == .orderedAscending
        case "tt_coverageBreadth":
            result = (lhs.coverageBreadth ?? 0) < (rhs.coverageBreadth ?? 0)
        case "tt_coverageDepth":
            result = (lhs.coverageDepth ?? 0) < (rhs.coverageDepth ?? 0)
        case "tt_abundance":
            result = (lhs.abundance ?? 0) < (rhs.abundance ?? 0)
        default:
            return false
        }
        return ascending ? result : !result
    }

    override func sampleId(for row: TaxTriageMetric) -> String? { row.sample }

    // MARK: - Empty Column Hiding

    override func columnHasData(_ columnId: NSUserInterfaceItemIdentifier) -> Bool {
        switch columnId {
        case .tt_coverageBreadth:
            return unfilteredRows.contains { $0.coverageBreadth != nil }
        case .tt_coverageDepth:
            return unfilteredRows.contains { $0.coverageDepth != nil }
        case .tt_abundance:
            return unfilteredRows.contains { $0.abundance != nil }
        default:
            return true
        }
    }

    // MARK: - Public API

    override func configure(rows: [TaxTriageMetric]) {
        super.configure(rows: rows)
        logger.info("BatchTaxTriageTableView configured with \(rows.count) rows")
    }

    /// Reloads only the Reads + Unique Reads column cells without re-sorting or scrolling.
    ///
    /// Call this after updating ``totalReadsByKey`` and/or ``uniqueReadsByKey``.
    func reloadReadStatsColumns() {
        let readsColumn = tableView.column(withIdentifier: .tt_reads)
        let uniqueColumn = tableView.column(withIdentifier: .tt_uniqueReads)

        var colIndexSet = IndexSet()
        if readsColumn >= 0 {
            colIndexSet.insert(readsColumn)
        }
        if uniqueColumn >= 0 {
            colIndexSet.insert(uniqueColumn)
        }
        guard !colIndexSet.isEmpty else { return }

        let rowIndexSet = IndexSet(integersIn: 0..<displayedRows.count)
        if !rowIndexSet.isEmpty {
            tableView.reloadData(forRowIndexes: rowIndexSet, columnIndexes: colIndexSet)
        }
    }

    /// Backward-compatible alias for older call sites that only update unique reads.
    func reloadUniqueReadsColumn() {
        reloadReadStatsColumns()
    }

    private func rowKey(for row: TaxTriageMetric) -> String {
        "\(row.sample ?? "")\t\(row.organism)"
    }
}
