// BatchClassificationTableView.swift - NSTableView wrapper for Kraken2 batch results
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import LungfishCore
import os.log

private let logger = Logger(subsystem: LogSubsystem.app, category: "BatchClassificationTableView")

// MARK: - Column Identifiers

private extension NSUserInterfaceItemIdentifier {
    static let kraken_sample      = NSUserInterfaceItemIdentifier("sample")
    static let kraken_name        = NSUserInterfaceItemIdentifier("name")
    static let kraken_rank        = NSUserInterfaceItemIdentifier("rank")
    static let kraken_readsDirect = NSUserInterfaceItemIdentifier("readsDirect")
    static let kraken_readsClade  = NSUserInterfaceItemIdentifier("readsClade")
    static let kraken_percent     = NSUserInterfaceItemIdentifier("percent")
}

// MARK: - BatchClassificationTableView

/// A scrollable flat table showing ``BatchClassificationRow`` records for Kraken2 batch mode.
///
/// One row per taxon × sample combination. Inherits all layout, sort, filter, selection,
/// and metadata column boilerplate from ``BatchTableView``.
@MainActor
final class BatchClassificationTableView: BatchTableView<BatchClassificationRow> {

    // MARK: - Subclass Hooks

    override var columnSpecs: [BatchColumnSpec] {
        [
            BatchColumnSpec(identifier: .kraken_sample,      title: "Sample",         width: 130, minWidth: 70,  defaultAscending: true),
            BatchColumnSpec(identifier: .kraken_name,        title: "Name",           width: 220, minWidth: 100, defaultAscending: true),
            BatchColumnSpec(identifier: .kraken_rank,        title: "Rank",           width: 80,  minWidth: 50,  defaultAscending: true),
            BatchColumnSpec(identifier: .kraken_readsDirect, title: "Reads (direct)", width: 90,  minWidth: 60,  defaultAscending: false),
            BatchColumnSpec(identifier: .kraken_readsClade,  title: "Reads (clade)",  width: 90,  minWidth: 60,  defaultAscending: false),
            BatchColumnSpec(identifier: .kraken_percent,     title: "%",              width: 65,  minWidth: 45,  defaultAscending: false),
        ]
    }

    override var searchPlaceholder: String { "Filter taxa\u{2026}" }

    override var columnTypeHints: [String: Bool] {
        [
            "sample": false, "name": false, "rank": false,
            "readsDirect": true, "readsClade": true, "percent": true,
        ]
    }

    override func cellContent(
        for column: NSUserInterfaceItemIdentifier,
        row: BatchClassificationRow
    ) -> (text: String, alignment: NSTextAlignment, font: NSFont?) {
        switch column {
        case .kraken_sample:
            return (row.sample, .left, .systemFont(ofSize: 11, weight: .medium))
        case .kraken_name:
            return (row.taxonName, .left, .systemFont(ofSize: 11))
        case .kraken_rank:
            return (row.rankDisplayName, .left, .monospacedDigitSystemFont(ofSize: 11, weight: .regular))
        case .kraken_readsDirect:
            return (formatReadCount(row.readsDirect), .right, nil)
        case .kraken_readsClade:
            return (formatReadCount(row.readsClade), .right, nil)
        case .kraken_percent:
            return (String(format: "%.2f%%", row.percentage), .right, nil)
        default:
            return ("", .left, nil)
        }
    }

    override func rowMatchesFilter(_ row: BatchClassificationRow, filterText: String) -> Bool {
        row.taxonName.localizedCaseInsensitiveContains(filterText)
    }

    override func compareRows(
        _ lhs: BatchClassificationRow,
        _ rhs: BatchClassificationRow,
        by key: String,
        ascending: Bool
    ) -> Bool {
        let result: Bool
        switch key {
        case "sample":
            result = lhs.sample.localizedCaseInsensitiveCompare(rhs.sample) == .orderedAscending
        case "name":
            result = lhs.taxonName.localizedCaseInsensitiveCompare(rhs.taxonName) == .orderedAscending
        case "rank":
            result = lhs.rankDisplayName.localizedCaseInsensitiveCompare(rhs.rankDisplayName) == .orderedAscending
        case "readsDirect":
            result = lhs.readsDirect < rhs.readsDirect
        case "readsClade":
            result = lhs.readsClade < rhs.readsClade
        case "percent":
            result = lhs.percentage < rhs.percentage
        default:
            return false
        }
        return ascending ? result : !result
    }

    override func sampleId(for row: BatchClassificationRow) -> String? { row.sample }

    override func rowIdentity(for row: BatchClassificationRow) -> String? {
        [
            "kraken2",
            resultIdentity ?? "unknown-result",
            row.sample,
            String(row.taxId),
            row.rank,
            row.taxonName,
        ].joined(separator: "\u{1F}")
    }

    // MARK: - Public API

    override func configure(rows: [BatchClassificationRow]) {
        super.configure(rows: rows)
        logger.info("BatchClassificationTableView configured with \(rows.count) rows")
    }
}
