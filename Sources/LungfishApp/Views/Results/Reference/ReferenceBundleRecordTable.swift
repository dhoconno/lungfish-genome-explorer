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
}

@MainActor
final class ReferenceBundleRecordTable: BatchTableView<ReferenceBundleRecordRow> {
    private(set) var dynamicFields: [GenBankRecordDatabase.FieldDefinition] = []
    private var numericDynamicColumnIdentifiers = Set<String>()
    var onDisplayedRowsChanged: (() -> Void)?

    override var columnSpecs: [BatchColumnSpec] {
        let fixed: [BatchColumnSpec] = [
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

    override var searchPlaceholder: String { "Filter records\u{2026}" }
    override var searchAccessibilityIdentifier: String? { "reference-bundle-sequence-search" }
    override var searchAccessibilityLabel: String? { "Filter reference records" }
    override var tableAccessibilityIdentifier: String? { "reference-bundle-sequence-table" }
    override var tableAccessibilityLabel: String? { "Reference record table" }

    override var columnTypeHints: [String: Bool] {
        var hints = ["sequence": false, "length": true, "role": false]
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
        let value = columnValue(for: column.rawValue, row: row)
        let numeric = column.rawValue == "length" || numericDynamicColumnIdentifiers.contains(column.rawValue)
        return (
            numeric && column.rawValue == "length" ? row.summary.length.formatted() : value,
            numeric ? .right : .left,
            numeric ? .monospacedDigitSystemFont(ofSize: 12, weight: .regular) : .systemFont(ofSize: 12)
        )
    }

    override func columnValue(for columnId: String, row: ReferenceBundleRecordRow) -> String {
        switch columnId {
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
        if row.summary.name.localizedCaseInsensitiveContains(query)
            || (row.summary.displayDescription?.localizedCaseInsensitiveContains(query) == true)
            || row.summary.aliases.contains(where: { $0.localizedCaseInsensitiveContains(query) })
            || String(row.summary.length).localizedCaseInsensitiveContains(query)
            || row.summary.length.formatted().localizedCaseInsensitiveContains(query)
            || roleDescription(for: row.summary).localizedCaseInsensitiveContains(query) {
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
        row.summary.name
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
