// ColumnFilter.swift - Per-column filter model for taxonomy tables
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation

/// Operator for column filters. Numeric operators apply to numeric columns;
/// text operators apply to string columns.
public enum FilterOperator: String, CaseIterable, Sendable, Codable {
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
public struct ColumnFilter: Sendable, Codable, Equatable {
    public let columnId: String
    public var op: FilterOperator
    public var value: String
    public var value2: String?
    public var isInverted: Bool

    public init(
        columnId: String,
        op: FilterOperator,
        value: String,
        value2: String? = nil,
        isInverted: Bool = false
    ) {
        self.columnId = columnId
        self.op = op
        self.value = value
        self.value2 = value2
        self.isInverted = isInverted
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

        let result: Bool
        switch op {
        case .greaterOrEqual:
            result = numericValue >= threshold
        case .lessOrEqual:
            result = numericValue <= threshold
        case .equal:
            result = numericValue == threshold
        case .between:
            if let upper = value2.flatMap({ Self.parseNumericValue($0) }) {
                result = numericValue >= threshold && numericValue <= upper
            } else {
                // Degrade to ≥ if no upper bound
                result = numericValue >= threshold
            }
        case .contains, .startsWith:
            // Text operators on numeric values: always pass
            result = true
        }
        return applyInversion(result)
    }

    // MARK: - String Matching

    /// Tests whether a string value passes this filter.
    /// Inactive filters always return true.
    /// For numeric operators, attempts to parse the string as a number.
    public func matchesString(_ stringValue: String) -> Bool {
        guard isActive else { return true }

        let result: Bool
        switch op {
        case .contains:
            result = stringValue.localizedCaseInsensitiveContains(value)
        case .equal:
            result = stringValue.caseInsensitiveCompare(value) == .orderedSame
        case .startsWith:
            result = stringValue.lowercased().hasPrefix(value.lowercased())
        case .greaterOrEqual, .lessOrEqual, .between:
            // Numeric operator on a string: try to parse as number
            guard let numericValue = Self.parseNumericValue(stringValue) else {
                return applyInversion(false)
            }
            return matchesNumeric(numericValue)
        }
        return applyInversion(result)
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

        let numericText = cleaned.hasSuffix("%") ? String(cleaned.dropLast()) : cleaned
        return Double(numericText)
    }

    private func applyInversion(_ result: Bool) -> Bool {
        isInverted ? !result : result
    }
}

/// Boolean composition mode for multiple active column filters.
public enum ColumnFilterComposition: String, Sendable, Codable, Equatable {
    case all
    case any
}

/// Ordered, codable filter set used by classifier tables and persisted view state.
public struct ColumnFilterSet: Sendable, Codable, Equatable {
    public var filters: [ColumnFilter]
    public var composition: ColumnFilterComposition

    public init(filters: [ColumnFilter] = [], composition: ColumnFilterComposition = .all) {
        self.filters = filters
        self.composition = composition
    }

    public var activeFilters: [ColumnFilter] {
        filters.filter(\.isActive)
    }

    public var isActive: Bool {
        !activeFilters.isEmpty
    }

    public func matches(_ predicate: (ColumnFilter) -> Bool) -> Bool {
        let active = activeFilters
        guard !active.isEmpty else { return true }
        switch composition {
        case .all:
            return active.allSatisfy(predicate)
        case .any:
            return active.contains(where: predicate)
        }
    }

    public mutating func replaceFilters(for columnId: String, with filter: ColumnFilter) {
        filters.removeAll { $0.columnId == columnId }
        if filter.isActive {
            filters.append(filter)
        }
    }

    public mutating func append(_ filter: ColumnFilter) {
        if filter.isActive {
            filters.append(filter)
        }
    }

    public mutating func removeFilters(for columnId: String) {
        filters.removeAll { $0.columnId == columnId }
    }

    public mutating func removeAll() {
        filters.removeAll()
    }

    public func activeFiltersByColumn() -> [String: ColumnFilter] {
        var result: [String: ColumnFilter] = [:]
        for filter in activeFilters where result[filter.columnId] == nil {
            result[filter.columnId] = filter
        }
        return result
    }
}

#if canImport(AppKit)
import AppKit

extension ColumnFilter {
    /// Filter indicator suffix appended to column titles.
    private static let filterIndicator = " ◆"

    // MARK: - Column Title Indicator

    /// Updates column titles to show a diamond indicator when a filter is active.
    ///
    /// Uses the column title directly (not attributed strings) so the indicator
    /// persists across table reloads.
    ///
    /// - Parameters:
    ///   - columns: The table columns to update.
    ///   - filters: Current filter state keyed by column identifier.
    ///   - originalTitles: Dictionary to store/retrieve original titles.
    @MainActor
    public static func updateColumnTitleIndicators(
        columns: [NSTableColumn],
        filters: [String: ColumnFilter],
        originalTitles: inout [String: String]
    ) {
        for column in columns {
            let colId = column.identifier.rawValue

            // Store original title on first encounter (strip any existing indicator)
            if originalTitles[colId] == nil {
                var title = column.title
                if title.hasSuffix(filterIndicator) {
                    title = String(title.dropLast(filterIndicator.count))
                }
                originalTitles[colId] = title
            }

            guard let originalTitle = originalTitles[colId] else { continue }

            if let filter = filters[colId], filter.isActive {
                column.title = originalTitle + filterIndicator
            } else {
                column.title = originalTitle
            }
        }
    }

    /// Convenience overload accepting NSTableView directly.
    @MainActor
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
