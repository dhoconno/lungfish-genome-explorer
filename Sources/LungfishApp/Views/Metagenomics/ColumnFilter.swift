// ColumnFilter.swift - Per-column filter model for taxonomy tables
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation

/// Operator for column filters. Numeric operators apply to numeric columns;
/// text operators apply to string columns.
public enum FilterOperator: String, CaseIterable, Sendable {
    case greaterOrEqual = "≥"
    case lessOrEqual = "≤"
    case equal = "="
    case between = "…"
    case contains = "∋"
    case startsWith = "A…"

    /// Whether this operator is intended for numeric values.
    public var isNumeric: Bool {
        switch self {
        case .greaterOrEqual, .lessOrEqual, .equal, .between: return true
        case .contains, .startsWith: return false
        }
    }

    /// Operators appropriate for numeric columns.
    public static var numericOperators: [FilterOperator] {
        [.greaterOrEqual, .lessOrEqual, .equal, .between]
    }

    /// Operators appropriate for text columns.
    public static var textOperators: [FilterOperator] {
        [.contains, .equal, .startsWith]
    }
}

/// A single column filter with an operator, primary value, and optional
/// secondary value (for "between" ranges).
public struct ColumnFilter: Sendable {
    public let columnId: String
    public var op: FilterOperator
    public var value: String
    public var value2: String?

    public init(columnId: String, op: FilterOperator, value: String, value2: String? = nil) {
        self.columnId = columnId
        self.op = op
        self.value = value
        self.value2 = value2
    }

    /// Whether this filter has a non-empty value and should be applied.
    public var isActive: Bool {
        !value.trimmingCharacters(in: .whitespaces).isEmpty
    }

    // MARK: - Numeric Matching

    /// Tests whether a numeric value passes this filter.
    /// Inactive filters always return true.
    public func matchesNumeric(_ numericValue: Double) -> Bool {
        guard isActive else { return true }
        guard let threshold = Self.parseNumericValue(value) else { return true }

        switch op {
        case .greaterOrEqual:
            return numericValue >= threshold
        case .lessOrEqual:
            return numericValue <= threshold
        case .equal:
            return numericValue == threshold
        case .between:
            if let upper = value2.flatMap({ Self.parseNumericValue($0) }) {
                return numericValue >= threshold && numericValue <= upper
            }
            // Degrade to ≥ if no upper bound
            return numericValue >= threshold
        case .contains, .startsWith:
            // Text operators on numeric values: always pass
            return true
        }
    }

    // MARK: - String Matching

    /// Tests whether a string value passes this filter.
    /// Inactive filters always return true.
    /// For numeric operators, attempts to parse the string as a number.
    public func matchesString(_ stringValue: String) -> Bool {
        guard isActive else { return true }

        switch op {
        case .contains:
            return stringValue.localizedCaseInsensitiveContains(value)
        case .equal:
            return stringValue.caseInsensitiveCompare(value) == .orderedSame
        case .startsWith:
            return stringValue.lowercased().hasPrefix(value.lowercased())
        case .greaterOrEqual, .lessOrEqual, .between:
            // Numeric operator on a string: try to parse as number
            guard let numericValue = Double(stringValue) else { return false }
            return matchesNumeric(numericValue)
        }
    }

    // MARK: - Value Parsing

    /// Parses a numeric string, supporting K/M suffixes and comma separators.
    /// Returns nil if the string cannot be parsed.
    public static func parseNumericValue(_ raw: String) -> Double? {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }

        // Strip commas
        let cleaned = trimmed.replacingOccurrences(of: ",", with: "")

        // Check for K/M suffix
        let lastChar = cleaned.last
        if let lastChar, "kKmM".contains(lastChar) {
            let numberPart = String(cleaned.dropLast())
            guard let base = Double(numberPart) else { return nil }
            switch lastChar {
            case "k", "K": return base * 1_000
            case "m", "M": return base * 1_000_000
            default: return nil
            }
        }

        return Double(cleaned)
    }

}

#if canImport(AppKit)
import AppKit

extension ColumnFilter {
    // MARK: - Column Title Indicator

    /// Updates column header cells to show a Lungfish Orange diamond indicator
    /// when a filter is active on that column.
    ///
    /// - Parameters:
    ///   - columns: The table columns to update.
    ///   - filters: Current filter state keyed by column identifier.
    ///   - originalTitles: Dictionary to store/retrieve original titles.
    public static func updateColumnTitleIndicators(
        columns: [NSTableColumn],
        filters: [String: ColumnFilter],
        originalTitles: inout [String: String]
    ) {
        for column in columns {
            let colId = column.identifier.rawValue

            // Store original title on first encounter
            if originalTitles[colId] == nil {
                originalTitles[colId] = column.title
            }

            guard let originalTitle = originalTitles[colId] else { continue }

            if let filter = filters[colId], filter.isActive {
                let attributed = NSMutableAttributedString(string: originalTitle + " ")
                let diamond = NSAttributedString(
                    string: "◆",
                    attributes: [
                        .foregroundColor: NSColor.lungfishOrange,
                        .font: NSFont.systemFont(ofSize: 9),
                    ]
                )
                attributed.append(diamond)
                column.headerCell.attributedStringValue = attributed
                column.title = originalTitle
            } else {
                column.headerCell.attributedStringValue = NSAttributedString(string: originalTitle)
                column.title = originalTitle
            }
        }
    }

    /// Convenience overload accepting NSTableView directly.
    public static func updateColumnTitleIndicators(
        on tableView: NSTableView,
        filters: [String: ColumnFilter],
        originalTitles: inout [String: String]
    ) {
        updateColumnTitleIndicators(
            columns: tableView.tableColumns,
            filters: filters,
            originalTitles: &originalTitles
        )
        tableView.headerView?.needsDisplay = true
    }
}
#endif
