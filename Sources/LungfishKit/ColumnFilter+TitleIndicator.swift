// ColumnFilter+TitleIndicator.swift - The AppKit column title indicator for active column filters
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishWorkflow

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
