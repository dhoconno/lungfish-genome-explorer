// ViewerExportOption.swift - The one spelling of every flag a viewer export leaf and the GUI share
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation

/// A flag that a viewer export leaf takes and the GUI writes (Phase 2.12, ARCH ruling G2-3).
///
/// The CLI's `ViewerExportOptions` groups take their names from these cases, and ``ViewerExportInvocation`` writes the
/// same names into the argv the runner runs, the row records and the leaf records. No lane writes one of these flag
/// strings by hand.
public enum ViewerExportOption: String, CaseIterable, Sendable {
    case sample
    case search
    case sort
    case filter
    case filterMatch = "filter-match"
    case metadataColumn = "metadata-column"
    case column
    case mode
    case tab
    case outputFormat = "output-format"
    case selection
    case output
    case force

    /// The long flag, such as `--metadata-column`.
    public var flag: String { "--" + rawValue }
}

/// One sort key of a viewer table, written `<column>:ascending` or `<column>:descending` (ARCH ruling 1.2).
public struct ViewerExportSortKey: Codable, Sendable, Equatable {
    public var column: String
    public var ascending: Bool

    public init(column: String, ascending: Bool) {
        self.column = column
        self.ascending = ascending
    }

    /// Parses `<column>:ascending` or `<column>:descending` at the last colon, so a column id may hold a colon.
    /// Any other direction word, or an empty column, is refused.
    public init?(argument: String) {
        guard let colon = argument.lastIndex(of: ":") else { return nil }
        let column = String(argument[..<colon])
        let direction = String(argument[argument.index(after: colon)...])
        guard !column.isEmpty else { return nil }
        switch direction {
        case "ascending": self.init(column: column, ascending: true)
        case "descending": self.init(column: column, ascending: false)
        default: return nil
        }
    }

    /// The option value, `<column>:ascending` or `<column>:descending`.
    public var argument: String {
        column + ":" + (ascending ? "ascending" : "descending")
    }
}

/// The two delimited formats a table export writes, the value of `--output-format`.
public enum ViewerExportDelimitedFormat: String, CaseIterable, Codable, Sendable {
    case csv
    case tsv

    /// The field separator the format writes.
    public var separator: String {
        switch self {
        case .csv: return ","
        case .tsv: return "\t"
        }
    }
}
