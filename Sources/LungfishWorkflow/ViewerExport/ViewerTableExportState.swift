// ViewerTableExportState.swift - The view state a viewer table export applies, as a value
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation

/// The state of a viewer table that an export applies (Phase 2.12, ARCH ruling 1.2).
///
/// A builder in this folder takes it as a value, never a view object. ``cliArguments()`` writes the options in the
/// row order of the 1.2 table, and a field at its default writes nothing, so `ViewerTableExportState().cliArguments()`
/// is empty. The CLI groups' `apply(to:)` inverts it (ARCH ruling G2-4).
public struct ViewerTableExportState: Codable, Sendable, Equatable {
    /// Sample ids as the result records them. Empty means every sample of the result.
    public var samples: [String]
    /// The search text, matched as the view matches it. `nil` means no search.
    public var searchText: String?
    /// Sort keys, the first being the primary key.
    public var sortKeys: [ViewerExportSortKey]
    /// Column filters with their match. `--filter-match` is written only with a filter.
    public var filters: ColumnFilterSet
    /// Visible metadata column names in display order.
    public var metadataColumns: [String]
    /// Table column ids, only where the export drops hidden columns.
    public var columns: [String]
    /// The table mode, only where the bytes depend on it.
    public var mode: String?

    public init(
        samples: [String] = [],
        searchText: String? = nil,
        sortKeys: [ViewerExportSortKey] = [],
        filters: ColumnFilterSet = ColumnFilterSet(),
        metadataColumns: [String] = [],
        columns: [String] = [],
        mode: String? = nil
    ) {
        self.samples = samples
        self.searchText = searchText
        self.sortKeys = sortKeys
        self.filters = filters
        self.metadataColumns = metadataColumns
        self.columns = columns
        self.mode = mode
    }

    /// The options that carry this state, long names only, in the row order of the 1.2 table.
    public func cliArguments() -> [String] {
        var arguments: [String] = []
        for sample in samples {
            arguments += [ViewerExportOption.sample.flag, sample]
        }
        if let searchText {
            arguments += [ViewerExportOption.search.flag, searchText]
        }
        for key in sortKeys {
            arguments += [ViewerExportOption.sort.flag, key.argument]
        }
        if !filters.filters.isEmpty {
            for filter in filters.filters {
                arguments += [ViewerExportOption.filter.flag, Self.encodedFilter(filter)]
            }
            arguments += [ViewerExportOption.filterMatch.flag, filters.composition.rawValue]
        }
        for column in metadataColumns {
            arguments += [ViewerExportOption.metadataColumn.flag, column]
        }
        for column in columns {
            arguments += [ViewerExportOption.column.flag, column]
        }
        if let mode {
            arguments += [ViewerExportOption.mode.flag, mode]
        }
        return arguments
    }

    /// One filter as the `--filter` value, JSON with sorted keys.
    public static func encodedFilter(_ filter: ColumnFilter) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(filter) else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }

    /// Decodes one `--filter` value written by ``encodedFilter(_:)``.
    public static func decodedFilter(_ text: String) throws -> ColumnFilter {
        try JSONDecoder().decode(ColumnFilter.self, from: Data(text.utf8))
    }
}
