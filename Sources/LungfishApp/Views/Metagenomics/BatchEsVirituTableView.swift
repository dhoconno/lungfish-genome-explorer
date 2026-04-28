// BatchEsVirituTableView.swift - NSTableView wrapper for EsViritu batch results
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import LungfishCore
import os.log

private let logger = Logger(subsystem: LogSubsystem.app, category: "BatchEsVirituTableView")

// MARK: - Column Identifiers

private extension NSUserInterfaceItemIdentifier {
    static let esv_sample       = NSUserInterfaceItemIdentifier("sample")
    static let esv_name         = NSUserInterfaceItemIdentifier("name")
    static let esv_family       = NSUserInterfaceItemIdentifier("family")
    static let esv_assembly     = NSUserInterfaceItemIdentifier("assembly")
    static let esv_reads        = NSUserInterfaceItemIdentifier("reads")
    static let esv_uniqueReads  = NSUserInterfaceItemIdentifier("uniqueReads")
    static let esv_rpkmf        = NSUserInterfaceItemIdentifier("rpkmf")
    static let esv_coverage     = NSUserInterfaceItemIdentifier("coverage")
}

// MARK: - BatchEsVirituTableView

/// A scrollable flat table showing ``BatchEsVirituRow`` records for EsViritu batch mode.
///
/// One row per viral assembly × sample combination. Inherits all layout, sort, filter,
/// selection, and metadata column boilerplate from ``BatchTableView``.
@MainActor
final class BatchEsVirituTableView: BatchTableView<BatchEsVirituRow> {

    // MARK: - Subclass Hooks

    override var columnSpecs: [BatchColumnSpec] {
        [
            BatchColumnSpec(identifier: .esv_sample,      title: "Sample",       width: 130, minWidth: 70,  defaultAscending: true),
            BatchColumnSpec(identifier: .esv_name,        title: "Name",         width: 220, minWidth: 100, defaultAscending: true),
            BatchColumnSpec(identifier: .esv_family,      title: "Family",       width: 130, minWidth: 70,  defaultAscending: true),
            BatchColumnSpec(identifier: .esv_assembly,    title: "Assembly",     width: 130, minWidth: 70,  defaultAscending: true),
            BatchColumnSpec(identifier: .esv_reads,       title: "Reads",        width: 80,  minWidth: 50,  defaultAscending: false),
            BatchColumnSpec(identifier: .esv_uniqueReads, title: "Unique Reads", width: 90,  minWidth: 55,  defaultAscending: false),
            BatchColumnSpec(identifier: .esv_rpkmf,       title: "RPKMF",        width: 80,  minWidth: 50,  defaultAscending: false),
            BatchColumnSpec(identifier: .esv_coverage,    title: "Coverage",     width: 80,  minWidth: 50,  defaultAscending: false),
        ]
    }

    override var searchPlaceholder: String { "Filter viruses\u{2026}" }

    override var columnTypeHints: [String: Bool] {
        [
            "sample": false, "name": false, "family": false, "assembly": false,
            "reads": true, "uniqueReads": true, "rpkmf": true, "coverage": true,
        ]
    }

    override func cellContent(
        for column: NSUserInterfaceItemIdentifier,
        row: BatchEsVirituRow
    ) -> (text: String, alignment: NSTextAlignment, font: NSFont?) {
        switch column {
        case .esv_sample:
            return (row.sample, .left, .systemFont(ofSize: 11, weight: .medium))
        case .esv_name:
            return (row.virusName, .left, .systemFont(ofSize: 11, weight: .regular))
        case .esv_family:
            return (row.family ?? "\u{2014}", .left, .systemFont(ofSize: 11))
        case .esv_assembly:
            return (row.assembly, .left, .monospacedDigitSystemFont(ofSize: 11, weight: .regular))
        case .esv_reads:
            return (formatReadCount(row.readCount), .right, nil)
        case .esv_uniqueReads:
            return (formatReadCount(row.uniqueReads), .right, nil)
        case .esv_rpkmf:
            return (String(format: "%.1f", row.rpkmf), .right, nil)
        case .esv_coverage:
            return (String(format: "%.1f%%", row.coverageBreadth * 100), .right, nil)
        default:
            return ("", .left, nil)
        }
    }

    override func rowMatchesFilter(_ row: BatchEsVirituRow, filterText: String) -> Bool {
        row.virusName.localizedCaseInsensitiveContains(filterText)
            || (row.family?.localizedCaseInsensitiveContains(filterText) ?? false)
    }

    override func compareRows(
        _ lhs: BatchEsVirituRow,
        _ rhs: BatchEsVirituRow,
        by key: String,
        ascending: Bool
    ) -> Bool {
        let result: Bool
        switch key {
        case "sample":
            result = lhs.sample.localizedCaseInsensitiveCompare(rhs.sample) == .orderedAscending
        case "name":
            result = lhs.virusName.localizedCaseInsensitiveCompare(rhs.virusName) == .orderedAscending
        case "family":
            let lf = lhs.family ?? ""; let rf = rhs.family ?? ""
            result = lf.localizedCaseInsensitiveCompare(rf) == .orderedAscending
        case "assembly":
            result = lhs.assembly.localizedCaseInsensitiveCompare(rhs.assembly) == .orderedAscending
        case "reads":
            result = lhs.readCount < rhs.readCount
        case "uniqueReads":
            result = lhs.uniqueReads < rhs.uniqueReads
        case "rpkmf":
            result = lhs.rpkmf < rhs.rpkmf
        case "coverage":
            result = lhs.coverageBreadth < rhs.coverageBreadth
        default:
            return false
        }
        return ascending ? result : !result
    }

    override func sampleId(for row: BatchEsVirituRow) -> String? { row.sample }

    override func rowIdentity(for row: BatchEsVirituRow) -> String? {
        [
            "esviritu",
            resultIdentity ?? "unknown-result",
            row.sample,
            row.assembly,
            row.virusName,
        ].joined(separator: "\u{1F}")
    }

    // MARK: - Public API

    override func configure(rows: [BatchEsVirituRow]) {
        super.configure(rows: rows)
        logger.info("BatchEsVirituTableView configured with \(rows.count) rows")
    }
}
