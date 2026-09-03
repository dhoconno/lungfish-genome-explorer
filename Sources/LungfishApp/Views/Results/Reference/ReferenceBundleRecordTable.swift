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

@MainActor
final class ReferenceBundleRecordTable: BatchTableView<ReferenceBundleRecordRow> {
    private(set) var dynamicFields: [GenBankRecordDatabase.FieldDefinition] = []
    private var numericDynamicColumnIdentifiers = Set<String>()
    var onDisplayedRowsChanged: (() -> Void)?

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
            .init(identifier: .init("sequence"), title: "Sequence", width: 220, minWidth: 140, defaultAscending: true),
            .init(identifier: .init("length"), title: "Length", width: 100, minWidth: 80, defaultAscending: false),
            .init(identifier: .init("role"), title: "Role", width: 100, minWidth: 80, defaultAscending: true),
        ]
        return fixed + dynamicFields.map { field in
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
        tableView.allowsMultipleSelection = false
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
        rebuildStandardColumns()
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
        guard column.rawValue == "sequence", let bundleDisplayName else { return nil }
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
            return row.summary.name
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
