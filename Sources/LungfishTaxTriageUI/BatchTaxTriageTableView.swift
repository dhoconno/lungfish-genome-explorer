// BatchTaxTriageTableView.swift - NSTableView wrapper for TaxTriage batch results
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import LungfishCore
import LungfishIO
import SwiftUI
import os.log
import LungfishKit

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
public final class BatchTaxTriageTableView: BatchTableView<TaxTriageMetric>, ResultRowMenuActions {

    // MARK: - Callbacks

    /// Fired when the user invokes "Extract Reads..." from the context menu.
    /// The VC reads the current selection from the table view itself.
    var onExtractReadsRequested: (() -> Void)?

    /// Fired when the user invokes "Verify with BLAST..." from the context menu.
    /// Parameters: the clicked metric row, and the read count chosen via the popover.
    var onBlastVerifyRequested: ((TaxTriageMetric, Int) -> Void)?

    // MARK: - Context Menu

    public override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        installContextMenu()
    }

    private func installContextMenu() {
        guard tableView.menu == nil else { return }
        tableView.menu = TaxTriageRowCommands.makeContextMenu(target: self)
    }

    // MARK: - Row Commands

    private func subject(for metric: TaxTriageMetric) -> TaxTriageRowSubject {
        TaxTriageRowSubject(
            organism: metric.organism,
            taxId: metric.taxId,
            tsvFields: [
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
        )
    }

    /// The displayed row indexes a menu command acts on. A context-menu
    /// command acts on the clicked row, or on the whole selection when the
    /// clicked row is part of it. A menu-bar command or accessibility action
    /// acts on the selection, because `clickedRow` outlives the click that
    /// set it.
    private func commandTargetRows(sender: Any?) -> [Int] {
        let selected = selectedRowIndexes()
        if let menuItem = sender as? NSMenuItem,
           ResultRowMenuValidation.isContextMenuItem(menuItem, in: [tableView.menu]),
           tableView.clickedRow >= 0, !selected.contains(tableView.clickedRow) {
            return [tableView.clickedRow].filter { displayedRows.indices.contains($0) }
        }
        return selected
    }

    /// The displayed indexes of the selected rows, resolved through the
    /// stable row identity so a re-sort cannot change which rows they are.
    private func selectedRowIndexes() -> [Int] {
        let ids = Set(selectedRowsByIdentity().compactMap { rowIdentity(for: $0) })
        guard !ids.isEmpty else { return [] }
        return displayedRows.indices.filter { index in
            rowIdentity(for: displayedRows[index]).map(ids.contains) ?? false
        }
    }

    private func availableRowCommands(forRows rows: [Int]) -> [ResultRowCommand] {
        TaxTriageRowCommands.available(for: rows.map { subject(for: displayedRows[$0]) })
    }

    private func adoptContextTargets(sender: Any?) {
        guard let menuItem = sender as? NSMenuItem,
              ResultRowMenuValidation.isContextMenuItem(menuItem, in: [tableView.menu]) else { return }
        let clicked = tableView.clickedRow
        guard clicked >= 0, clicked < displayedRows.count, !selectedRowIndexes().contains(clicked) else { return }
        selectDisplayedRowForContextMenuIfNeeded(clicked)
    }

    private func perform(_ command: ResultRowCommand, sender: Any?) {
        let rows = commandTargetRows(sender: sender)
        guard rows.count == 1, let index = rows.first else { return }
        TaxTriageRowCommands.perform(command, on: subject(for: displayedRows[index]))
    }

    @objc public func extractReadsForSelectedRows(_ sender: Any?) {
        adoptContextTargets(sender: sender)
        onExtractReadsRequested?()
    }

    @objc public func blastVerifySelectedRow(_ sender: Any?) {
        let rows = commandTargetRows(sender: sender)
        guard rows.count == 1, let index = rows.first else { return }
        selectDisplayedRowForContextMenuIfNeeded(index)
        let metric = displayedRows[index]
        // A menu-bar or accessibility invocation can target an off-screen row.
        tableView.scrollRowToVisible(index)
        TaxTriageRowCommands.presentBlastPopover(
            taxonName: metric.organism,
            readsClade: metric.reads,
            anchorRect: tableView.rect(ofRow: index),
            in: tableView
        ) { [weak self] readCount in
            self?.onBlastVerifyRequested?(metric, readCount)
        }
    }

    @objc public func copySelectedRowName(_ sender: Any?) { perform(.copyName, sender: sender) }
    @objc public func copySelectedRowTaxonID(_ sender: Any?) { perform(.copyTaxonID, sender: sender) }
    @objc public func copySelectedRowAsTSV(_ sender: Any?) { perform(.copyAsTSV, sender: sender) }
    @objc public func openSelectedRowTaxonomyOnNCBI(_ sender: Any?) { perform(.openTaxonomyOnNCBI, sender: sender) }

    // MARK: - Menu Validation

    /// The context menu follows the selection (or the clicked row). The
    /// menu-bar items under Selection > Table Row are enabled only while the
    /// table has keyboard focus.
    public override func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        guard let command = ResultRowCommand.command(for: menuItem.action) else {
            return super.validateMenuItem(menuItem)
        }
        guard TaxTriageRowCommands.supported.contains(command) else { return false }
        guard ResultRowMenuValidation.isReachable(menuItem, table: tableView) else { return false }
        return availableRowCommands(forRows: commandTargetRows(sender: menuItem)).contains(command)
    }

    // MARK: - Row Accessibility Actions

    /// The accessibility custom actions of the row at `row`: every
    /// single-row command its context menu offers, named the same. The
    /// handlers resolve the row from `cellView` when they run and select it
    /// first, so the shared handlers act on it through the selection.
    public override func accessibilityActions(forRow row: Int, cellView: NSView) -> [NSAccessibilityCustomAction] {
        guard displayedRows.indices.contains(row) else { return [] }
        return ResultRowMenuValidation.cellActions(
            availableRowCommands(forRows: [row]), on: cellView
        ) { [weak self] command, currentRow in
            guard let self else { return }
            self.selectDisplayedRowForContextMenuIfNeeded(currentRow)
            _ = NSApp.sendAction(command.menuSelector, to: self, from: nil)
        }
    }

    /// Returns the metrics for all currently selected rows.
    public func selectedMetrics() -> [TaxTriageMetric] {
        selectedRowsByIdentity()
    }

    // MARK: - Extra State

    /// Lookup dictionary for BAM-derived total read counts in batch modes.
    ///
    /// Key format: `"<sampleId>\t<organism>"`. Values are populated from
    /// miniBAM selections and/or background computation. When absent, cells fall
    /// back to the parser-provided `row.reads` value.
    public var totalReadsByKey: [String: Int] = [:]

    /// Lookup dictionary for unique (deduplicated) read counts in batch group mode.
    ///
    /// Key format: `"<sampleId>\t<organism>"`. Values are populated from
    /// `perSampleDeduplicatedReadCounts` by the owning view controller as background
    /// BAM deduplication completes. Cells show "—" when the key is absent.
    public var uniqueReadsByKey: [String: Int] = [:]

    /// Normalized organism names (`OrganismNameNormalizer.normalizedKey`)
    /// that TaxTriage detected in a negative-control sample. Rows for these
    /// organisms show a warning sign, orange text and a tooltip, as the
    /// per-sample organism table always did.
    public var contaminationRiskOrganismKeys: Set<String> = [] {
        didSet {
            guard contaminationRiskOrganismKeys != oldValue else { return }
            tableView?.reloadData()
        }
    }

    /// Whether `row`'s organism was detected in a negative-control sample.
    public func isContaminationRisk(_ row: TaxTriageMetric) -> Bool {
        !contaminationRiskOrganismKeys.isEmpty
            && contaminationRiskOrganismKeys.contains(OrganismNameNormalizer.normalizedKey(row.organism))
    }

    static let contaminationRiskToolTipPrefix = "Contamination risk: detected in negative control sample"

    // MARK: - Subclass Hooks

    public override var columnSpecs: [BatchColumnSpec] {
        [
            // TASS Score sorts descending by default (defaultAscending: false) — highest score first.
            BatchColumnSpec(identifier: .tt_sample,          title: "Sample",          width: 130, minWidth: 70,  defaultAscending: true),
            BatchColumnSpec(identifier: .tt_organism,        title: "Organism",        width: 220, minWidth: 100, defaultAscending: true),
            BatchColumnSpec(identifier: .tt_tassScore,       title: "TASS Score",      width: 90,  minWidth: 55,  defaultAscending: false,
                            toolTip: TaxTriageConfidenceBand.headerToolTip),
            BatchColumnSpec(identifier: .tt_reads,           title: "Reads",           width: 80,  minWidth: 50,  defaultAscending: false),
            BatchColumnSpec(identifier: .tt_uniqueReads,     title: "Unique Reads",    width: 90,  minWidth: 55,  defaultAscending: false),
            BatchColumnSpec(identifier: .tt_confidence,      title: "Confidence",      width: 90,  minWidth: 55,  defaultAscending: true),
            BatchColumnSpec(identifier: .tt_coverageBreadth, title: "Coverage Breadth", width: 110, minWidth: 65, defaultAscending: false),
            BatchColumnSpec(identifier: .tt_coverageDepth,   title: "Coverage Depth",  width: 100, minWidth: 60,  defaultAscending: false),
            BatchColumnSpec(identifier: .tt_abundance,       title: "Abundance",       width: 85,  minWidth: 50,  defaultAscending: false),
        ]
    }

    public override var searchPlaceholder: String { "Filter organisms\u{2026}" }

    /// The result view's filter row already has a Filter organisms field,
    /// which filters at the database and drives the Organisms card and the
    /// overview grid. A second field here filtered only the loaded rows.
    public override var showsSearchField: Bool { false }

    public override var columnTypeHints: [String: Bool] {
        [
            "sample": false, "organism": false, "confidence": false,
            "tassScore": true, "reads": true, "uniqueReads": true,
            "coverageBreadth": true, "coverageDepth": true, "abundance": true,
        ]
    }

    public override var standardColumnNames: [String] {
        ["Sample", "Organism", "TASS Score",
         "Reads", "Unique Reads", "Confidence",
         "Coverage Breadth", "Coverage Depth", "Abundance"]
    }

    public override func cellContent(
        for column: NSUserInterfaceItemIdentifier,
        row: TaxTriageMetric
    ) -> (text: String, alignment: NSTextAlignment, font: NSFont?) {
        switch column {
        case .tt_sample:
            return (row.sample ?? "\u{2014}", .left, .systemFont(ofSize: 11, weight: .medium))
        case .tt_organism:
            let text = isContaminationRisk(row) ? "\u{26A0} \(row.organism)" : row.organism
            return (text, .left, .systemFont(ofSize: 11))
        case .tt_tassScore:
            return (String(format: "%.3f", row.tassScore), .right, nil)
        case .tt_reads:
            let key = rowKey(for: row)
            let reads = totalReadsByKey[key] ?? row.reads
            return (formatReadCount(reads), .right, nil)
        case .tt_uniqueReads:
            let key = rowKey(for: row)
            let readCount = totalReadsByKey[key] ?? row.reads
            let text = ClassifierUniqueReads
                .normalized(stored: uniqueReadsByKey[key], readCount: readCount)
                .map { formatReadCount($0) } ?? "\u{2014}"
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

    public override func cellToolTip(
        for column: NSUserInterfaceItemIdentifier,
        row: TaxTriageMetric
    ) -> String? {
        switch column {
        case .tt_organism:
            return isContaminationRisk(row)
                ? "\(Self.contaminationRiskToolTipPrefix)\n\(row.organism)"
                : row.organism
        case .tt_tassScore, .tt_confidence:
            return TaxTriageConfidenceBand.toolTip(label: row.confidence, tassScore: row.tassScore)
        default:
            return nil
        }
    }

    public override func cellTextColor(
        for column: NSUserInterfaceItemIdentifier,
        row: TaxTriageMetric
    ) -> NSColor? {
        column == .tt_organism && isContaminationRisk(row) ? .systemOrange : nil
    }

    public override func rowMatchesFilter(_ row: TaxTriageMetric, filterText: String) -> Bool {
        row.organism.localizedCaseInsensitiveContains(filterText)
    }

    public override func compareRows(
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
            let lhsReads = totalReadsByKey[lk] ?? lhs.reads
            let rhsReads = totalReadsByKey[rk] ?? rhs.reads
            let lhsUnique = ClassifierUniqueReads.normalized(stored: uniqueReadsByKey[lk], readCount: lhsReads) ?? -1
            let rhsUnique = ClassifierUniqueReads.normalized(stored: uniqueReadsByKey[rk], readCount: rhsReads) ?? -1
            result = lhsUnique < rhsUnique
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

    public override func sampleId(for row: TaxTriageMetric) -> String? { row.sample }

    public override func rowIdentity(for row: TaxTriageMetric) -> String? {
        [
            "taxtriage",
            resultIdentity ?? "unknown-result",
            row.sample ?? "unknown-sample",
            row.taxId.map(String.init) ?? "unknown-taxid",
            row.rank ?? "unknown-rank",
            row.organism,
        ].joined(separator: "\u{1F}")
    }

    // MARK: - Empty Column Hiding

    public override func columnHasData(_ columnId: NSUserInterfaceItemIdentifier) -> Bool {
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

    public override func configure(rows: [TaxTriageMetric]) {
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
