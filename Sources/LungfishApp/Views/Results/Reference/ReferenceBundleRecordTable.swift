// ReferenceBundleRecordTable.swift - Record-level reference bundle metadata table
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import LungfishCore
import LungfishIO
import LungfishKit

struct ReferenceBundleRecordRow: Sendable, Equatable {
    let summary: BundleBrowserSequenceSummary
    let values: [String: String]
    /// Direct reference bundles have sequence rows rather than per-sample
    /// result rows. When persisted BAM metadata resolves exactly one sample,
    /// the owning viewport supplies it here so the standard metadata-column
    /// controller can render that result-scoped sample on every sequence row.
    let sampleID: String?
    let alignmentTrackID: String?
    let readGroupIDs: Set<String>

    init(
        summary: BundleBrowserSequenceSummary,
        values: [String: String],
        sampleID: String? = nil,
        alignmentTrackID: String? = nil,
        readGroupIDs: Set<String> = []
    ) {
        self.summary = summary
        self.values = values
        self.sampleID = sampleID
        self.alignmentTrackID = alignmentTrackID
        self.readGroupIDs = readGroupIDs
    }
}

/// The reference bundle's record table. Its rows offer the shared FASTA
/// commands from the context menu, from every cell's accessibility actions
/// (``accessibilityActions(forRow:cellView:)``) and, for the selected rows,
/// from Selection > Table Row (``ResultRowMenuActions``).
@MainActor
final class ReferenceBundleRecordTable: BatchTableView<ReferenceBundleRecordRow>, ResultRowMenuActions {
    private(set) var dynamicFields: [GenBankRecordDatabase.FieldDefinition] = []
    private var numericDynamicColumnIdentifiers = Set<String>()
    var onDisplayedRowsChanged: (() -> Void)?
    var displaysAlleles = false
    var onCopySequences: (([ReferenceBundleRecordRow], Bool) -> Void)?
    var onExtractSequences: (([ReferenceBundleRecordRow]) -> Void)?
    private let sequenceMenu = NSMenu()

    static func fullReferenceName(for row: ReferenceBundleRecordRow) -> String {
        guard let description = row.summary.displayDescription, !description.isEmpty,
              !row.summary.name.contains(description) else { return row.summary.name }
        return row.summary.name + " " + description
    }

    static func alleleName(for row: ReferenceBundleRecordRow) -> String {
        let fullName = fullReferenceName(for: row)
        let alleles = MHCReferenceGenotypeDisplay.alleleNames(for: fullName)
        return alleles.isEmpty ? row.summary.name : alleles.joined(separator: " / ")
    }

    var selectedSequenceRows: [ReferenceBundleRecordRow] {
        tableView.selectedRowIndexes.compactMap { displayedRows.indices.contains($0) ? displayedRows[$0] : nil }
    }

    func sequenceActionMenu(clickedRow: Int) -> NSMenu {
        guard displayedRows.indices.contains(clickedRow) else { return NSMenu() }
        targetSelection(toRow: clickedRow)
        let rows = selectedSequenceRows
        return FASTASequenceActionMenuBuilder.buildMenu(selectionCount: rows.count, handlers: makeActionHandlers(rows: rows))
    }

    /// Makes `row` the whole selection unless it is already part of it, the
    /// reconciliation a right-click outside the selection performs.
    private func targetSelection(toRow row: Int) {
        guard !tableView.selectedRowIndexes.contains(row) else { return }
        tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
    }

    /// The shared FASTA commands acting on `rows`. The context menu, the
    /// cell actions and the Selection > Table Row items are all built from
    /// these.
    private func makeActionHandlers(rows: [ReferenceBundleRecordRow]) -> FASTASequenceActionHandlers {
        .init(
            onCopyNames: { [weak self] in
                self?.copyText(rows.map { self?.displaysAlleles == true ? Self.alleleName(for: $0) : $0.summary.name }.joined(separator: "\n"))
            },
            onCopySequences: onCopySequences == nil ? nil : { [weak self] in self?.onCopySequences?(rows, false) },
            onCopyFullNames: displaysAlleles ? { [weak self] in self?.copyText(rows.map(Self.fullReferenceName).joined(separator: "\n")) } : nil,
            onCopy: onCopySequences == nil ? nil : { [weak self] in self?.onCopySequences?(rows, true) },
            onCreateBundle: onExtractSequences == nil ? nil : { [weak self] in self?.onExtractSequences?(rows) }
        )
    }

    /// The row's commands as cell actions. A selected row offers the
    /// selection's commands, an unselected row its own, and performing one
    /// first makes the cell's row the selection unless it already is.
    override func accessibilityActions(forRow row: Int, cellView: NSView) -> [NSAccessibilityCustomAction] {
        let isSelected = tableView.selectedRowIndexes.contains(row)
        let count = isSelected ? max(1, tableView.numberOfSelectedRows) : 1
        func targeting(_ pick: @escaping (FASTASequenceActionHandlers) -> (() -> Void)?) -> (() -> Void)? {
            guard let template = displayedRow(at: row), pick(makeActionHandlers(rows: [template])) != nil else { return nil }
            return { [weak self, weak cellView] in
                guard let self, let cellView,
                      let current = AccessibilityCellActions.currentRow(of: cellView) else { return }
                self.targetSelection(toRow: current)
                pick(self.makeActionHandlers(rows: self.selectedSequenceRows))?()
            }
        }
        let handlers = FASTASequenceActionHandlers(
            onCopyNames: targeting { $0.onCopyNames },
            onCopySequences: targeting { $0.onCopySequences },
            onCopyFullNames: targeting { $0.onCopyFullNames },
            onCopy: targeting { $0.onCopy },
            onCreateBundle: targeting { $0.onCreateBundle }
        )
        return FASTASequenceActionMenuBuilder.accessibilityActions(selectionCount: count, handlers: handlers)
    }

    // MARK: - Selection > Table Row (ResultRowMenuActions)

    override func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        let selected = selectedSequenceRows
        switch menuItem.action {
        case #selector(copySelectedRowName(_:)):
            return !selected.isEmpty
        case #selector(copySelectedRowSequence(_:)), #selector(copySelectedRowFASTA(_:)):
            return onCopySequences != nil && !selected.isEmpty
        case #selector(extractSelectedRowsToNewBundle(_:)):
            return onExtractSequences != nil && !selected.isEmpty
        default:
            return super.validateMenuItem(menuItem)
        }
    }

    @objc func copySelectedRowName(_ sender: Any?) {
        makeActionHandlers(rows: selectedSequenceRows).onCopyNames?()
    }

    @objc func copySelectedRowSequence(_ sender: Any?) {
        makeActionHandlers(rows: selectedSequenceRows).onCopySequences?()
    }

    @objc func copySelectedRowFASTA(_ sender: Any?) {
        makeActionHandlers(rows: selectedSequenceRows).onCopy?()
    }

    @objc func extractSelectedRowsToNewBundle(_ sender: Any?) {
        makeActionHandlers(rows: selectedSequenceRows).onCreateBundle?()
    }

    private func copyText(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    /// The reference bundle's user-facing `manifest.name`, used as the
    /// primary "sequence" cell line. `nil` (the default) falls back to
    /// showing the sequence name alone, unchanged from pre-Item-2 behavior.
    ///
    /// `didSet` re-runs `applyContentTypography()`, which reloads the table so
    /// every visible cell picks up the new primary/secondary text split.
    var bundleDisplayName: String? {
        didSet {
            guard bundleDisplayName != oldValue else { return }
            applyContentTypography()
        }
    }

    override var columnSpecs: [BatchColumnSpec] {
        let fixed: [BatchColumnSpec] = (displaysSamples ? [
            .init(identifier: .init("sample"), title: "Sample", width: 130, minWidth: 90, defaultAscending: true),
        ] : []) + [
            .init(identifier: .init("sequence"), title: displaysAlleles ? "Allele" : "Sequence", width: displaysAlleles ? 350 : 220, minWidth: 140, defaultAscending: true),
            .init(identifier: .init("length"), title: "Length", width: 100, minWidth: 80, defaultAscending: false),
            .init(identifier: .init("role"), title: "Role", width: 100, minWidth: 80, defaultAscending: true),
        ]
        let names: [BatchColumnSpec] = displaysAlleles ? [
            .init(identifier: .init("fullReferenceName"), title: "Full reference name", width: 300, minWidth: 140, defaultAscending: true)
        ] : []
        return fixed + names + dynamicFields.map { field in
            .init(
                identifier: .init(Self.columnIdentifier(for: field.key)),
                title: field.displayTitle,
                width: field.valueType == "number" ? 110 : 180,
                minWidth: field.valueType == "number" ? 80 : 100,
                defaultAscending: true,
                toolTip: "GenBank \(field.sourceCategory) field: \(field.key)"
            )
        }
    }

    private var displaysSamples = false

    override var searchPlaceholder: String { "Filter records\u{2026}" }
    override var searchAccessibilityIdentifier: String? { "reference-bundle-sequence-search" }
    override var searchAccessibilityLabel: String? { "Filter reference records" }
    override var tableAccessibilityIdentifier: String? { "reference-bundle-sequence-table" }
    override var tableAccessibilityLabel: String? { "Reference record table" }

    override var columnTypeHints: [String: Bool] {
        var hints = ["sequence": false, "length": true, "role": false]
        if displaysSamples { hints["sample"] = false }
        for field in dynamicFields {
            hints[Self.columnIdentifier(for: field.key)] = isNumeric(field)
        }
        return hints
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        finishSetup()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        finishSetup()
    }

    private func finishSetup() {
        tableView.allowsMultipleSelection = true
        sequenceMenu.delegate = self
        tableView.menu = sequenceMenu
        tableView.sortDescriptors = [NSSortDescriptor(key: "sequence", ascending: true)]
    }

    func configure(
        dynamicFields: [GenBankRecordDatabase.FieldDefinition],
        rows: [ReferenceBundleRecordRow]
    ) {
        displaysSamples = rows.contains { $0.sampleID != nil }
        self.dynamicFields = dynamicFields.sorted { lhs, rhs in
            if lhs.preferredOrder != rhs.preferredOrder {
                return lhs.preferredOrder < rhs.preferredOrder
            }
            let comparison = lhs.key.localizedStandardCompare(rhs.key)
            return comparison == .orderedSame ? lhs.key < rhs.key : comparison == .orderedAscending
        }
        numericDynamicColumnIdentifiers = Set(
            self.dynamicFields.lazy
                .filter(isNumeric)
                .map { Self.columnIdentifier(for: $0.key) }
        )
        let availableColumnIdentifiers = Set(columnSpecs.map { $0.identifier.rawValue })
        for filteredColumn in columnFilters.keys where !availableColumnIdentifiers.contains(filteredColumn) {
            columnFilterSet.removeFilters(for: filteredColumn)
        }
        let hadFullNameColumn = tableView.tableColumns.contains { $0.identifier.rawValue == "fullReferenceName" }
        rebuildStandardColumns()
        if displaysAlleles && !hadFullNameColumn {
            tableView.tableColumn(withIdentifier: .init("fullReferenceName"))?.isHidden = true
        }
        tableView.sortDescriptors = [NSSortDescriptor(key: "sequence", ascending: true)]
        super.configure(rows: rows)
    }

    override func cellContent(
        for column: NSUserInterfaceItemIdentifier,
        row: ReferenceBundleRecordRow
    ) -> (text: String, alignment: NSTextAlignment, font: NSFont?) {
        let numeric = column.rawValue == "length" || numericDynamicColumnIdentifiers.contains(column.rawValue)
        let displayText: String
        if column.rawValue == "sample" {
            displayText = row.sampleID ?? "—"
        } else if column.rawValue == "sequence", displaysAlleles {
            displayText = Self.alleleName(for: row)
        } else if column.rawValue == "sequence", let bundleDisplayName {
            // Primary line shows the bundle's user-facing name; the
            // underlying sequence/contig name moves to the dimmed secondary
            // line (see `secondaryCellText`). `columnValue(for:"sequence")`
            // is intentionally NOT reused here — it stays keyed on the
            // sequence name for copy/sort/filter-key callers.
            displayText = bundleDisplayName
        } else if numeric && column.rawValue == "length" {
            displayText = row.summary.length.formatted()
        } else {
            displayText = columnValue(for: column.rawValue, row: row)
        }
        return (
            displayText,
            numeric ? .right : .left,
            numeric ? .monospacedDigitSystemFont(ofSize: 12, weight: .regular) : .systemFont(ofSize: 12)
        )
    }

    override func secondaryCellText(
        for column: NSUserInterfaceItemIdentifier,
        row: ReferenceBundleRecordRow
    ) -> String? {
        guard !displaysAlleles, column.rawValue == "sequence", let bundleDisplayName else { return nil }
        return BundleDisplayLabel.secondaryLine(
            bundleName: bundleDisplayName,
            contigName: row.summary.name,
            fastaDescription: row.summary.displayDescription
        )
    }

    override func columnValue(for columnId: String, row: ReferenceBundleRecordRow) -> String {
        switch columnId {
        case "sample":
            return row.sampleID ?? ""
        case "sequence":
            return displaysAlleles ? Self.alleleName(for: row) : row.summary.name
        case "fullReferenceName":
            return Self.fullReferenceName(for: row)
        case "length":
            return String(row.summary.length)
        case "role":
            return roleDescription(for: row.summary)
        default:
            guard let fieldKey = Self.fieldKey(for: columnId) else { return "" }
            return row.values[fieldKey] ?? ""
        }
    }

    override func columnNumericValue(for columnId: String, row: ReferenceBundleRecordRow) -> Double? {
        if columnId == "length" {
            return Double(row.summary.length)
        }
        guard numericDynamicColumnIdentifiers.contains(columnId) else { return nil }
        let firstValue = columnValue(for: columnId, row: row)
            .split(separator: ";", maxSplits: 1, omittingEmptySubsequences: true)
            .first?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return firstValue.flatMap(Double.init)
    }

    override func rowMatchesFilter(_ row: ReferenceBundleRecordRow, filterText: String) -> Bool {
        let query = filterText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return true }
        if (row.sampleID?.localizedCaseInsensitiveContains(query) == true)
            || row.summary.name.localizedCaseInsensitiveContains(query)
            || (row.summary.displayDescription?.localizedCaseInsensitiveContains(query) == true)
            || row.summary.aliases.contains(where: { $0.localizedCaseInsensitiveContains(query) })
            || String(row.summary.length).localizedCaseInsensitiveContains(query)
            || row.summary.length.formatted().localizedCaseInsensitiveContains(query)
            || roleDescription(for: row.summary).localizedCaseInsensitiveContains(query)
            // Bundle display label is a filter convenience only — copy/sort/
            // rowIdentity stay keyed on `row.summary.name` (untouched below).
            || (bundleDisplayName?.localizedCaseInsensitiveContains(query) == true) {
            return true
        }
        return row.values.values.contains { $0.localizedCaseInsensitiveContains(query) }
    }

    override func compareRows(
        _ lhs: ReferenceBundleRecordRow,
        _ rhs: ReferenceBundleRecordRow,
        by key: String,
        ascending: Bool
    ) -> Bool {
        let comparison: ComparisonResult
        if key == "length" || numericDynamicColumnIdentifiers.contains(key) {
            comparison = compareOptionalNumbers(
                columnNumericValue(for: key, row: lhs),
                columnNumericValue(for: key, row: rhs)
            )
        } else if key == "sample" {
            comparison = (lhs.sampleID ?? "").localizedCaseInsensitiveCompare(rhs.sampleID ?? "")
        } else {
            comparison = columnValue(for: key, row: lhs)
                .localizedStandardCompare(columnValue(for: key, row: rhs))
        }

        if comparison == .orderedSame {
            let fallback = lhs.summary.name.localizedStandardCompare(rhs.summary.name)
            return ascending ? fallback == .orderedAscending : fallback == .orderedDescending
        }
        return ascending ? comparison == .orderedAscending : comparison == .orderedDescending
    }

    override func rowIdentity(for row: ReferenceBundleRecordRow) -> String? {
        [row.sampleID ?? "unmatched", row.alignmentTrackID ?? "reference", row.summary.name]
            .joined(separator: "\u{1F}")
    }

    override func sampleId(for row: ReferenceBundleRecordRow) -> String? {
        row.sampleID
    }

    override func didApplyDisplayedRows() {
        onDisplayedRowsChanged?()
    }

    override func hideEmptyColumns() {
        // Every recovered GenBank field remains user-reachable, and chooser state
        // survives record-table refreshes even when the current rows have no value.
    }

    static func columnIdentifier(for fieldKey: String) -> String {
        "genbank.\(fieldKey)"
    }

    private static func fieldKey(for columnIdentifier: String) -> String? {
        let prefix = "genbank."
        guard columnIdentifier.hasPrefix(prefix) else { return nil }
        return String(columnIdentifier.dropFirst(prefix.count))
    }

    private func isNumeric(_ field: GenBankRecordDatabase.FieldDefinition) -> Bool {
        field.valueType.caseInsensitiveCompare("number") == .orderedSame
    }

    private func roleDescription(for row: BundleBrowserSequenceSummary) -> String {
        if row.isMitochondrial { return "Mitochondrial" }
        return row.isPrimary ? "Primary" : "Alternate"
    }

    private func compareOptionalNumbers(_ lhs: Double?, _ rhs: Double?) -> ComparisonResult {
        switch (lhs, rhs) {
        case let (left?, right?):
            if left < right { return .orderedAscending }
            if left > right { return .orderedDescending }
            return .orderedSame
        case (nil, nil): return .orderedSame
        case (nil, _): return .orderedDescending
        case (_, nil): return .orderedAscending
        }
    }
}


extension ReferenceBundleRecordTable: NSMenuDelegate {
    func menuNeedsUpdate(_ menu: NSMenu) {
        let rebuilt = sequenceActionMenu(clickedRow: tableView.clickedRow)
        menu.removeAllItems()
        for item in rebuilt.items {
            rebuilt.removeItem(item)
            menu.addItem(item)
        }
    }
}
