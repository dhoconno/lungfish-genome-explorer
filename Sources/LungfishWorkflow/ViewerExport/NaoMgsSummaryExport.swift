// NaoMgsSummaryExport.swift - The NAO-MGS summary export that the viewer and its CLI leaf share
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishCore
import LungfishIO

/// The NAO-MGS summary table export (Phase 2.12 lane 12.31 M4, ARCH ruling 1.1).
///
/// The view and `nao-mgs export table` choose the shown rows and write the table with these functions, so the view,
/// the in-app writer and the leaf agree on the rows, their order and the bytes.
public enum NaoMgsSummaryExport {
    /// The leaf's path under `lungfish-cli` (ARCH ruling 1.1). `nao-mgs summary` already exists, so the leaf is
    /// named `table`.
    public static let commandPath = ["nao-mgs", "export", "table"]
    /// The workflow name the leaf's record carries (ARCH ruling 1.4).
    public static let workflowName = "lungfish nao-mgs export table"
}

extension NaoMgsSummaryExport {
    /// The rows the view shows, in its order, after its search, column filters and first sort key. Sort columns
    /// other than `sample`, `name`, `hits`, `unique` and `refs` keep the rows' order.
    public static func shownRows(
        _ sourceRows: [NaoMgsTaxonSummaryRow],
        searchText: String,
        filters: ColumnFilterSet,
        sortKey: ViewerExportSortKey?,
        metadataRecords: [String: [String: String]]
    ) -> [NaoMgsTaxonSummaryRow] {
        var rows = sourceRows
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !query.isEmpty {
            rows = rows.filter {
                $0.name.localizedCaseInsensitiveContains(query) || $0.sample.localizedCaseInsensitiveContains(query)
            }
        }
        if filters.isActive {
            rows = rows.filter { row in
                filters.matches { filter in columnFilter(filter, matches: row, metadataRecords: metadataRecords) }
            }
        }
        guard let sortKey else { return rows }
        let ascending = sortKey.ascending
        func inOrder(_ compare: ComparisonResult) -> Bool {
            ascending ? compare == .orderedAscending : compare == .orderedDescending
        }
        func countsInOrder(_ lhs: Int, _ rhs: Int) -> Bool { ascending ? lhs < rhs : lhs > rhs }
        switch sortKey.column {
        case "sample": rows.sort { inOrder($0.sample.localizedCaseInsensitiveCompare($1.sample)) }
        case "name": rows.sort { inOrder($0.name.localizedCaseInsensitiveCompare($1.name)) }
        case "hits": rows.sort { countsInOrder($0.hitCount, $1.hitCount) }
        case "unique": rows.sort { countsInOrder($0.uniqueReadCount, $1.uniqueReadCount) }
        case "refs": rows.sort { countsInOrder($0.accessionCount, $1.accessionCount) }
        default: break
        }
        return rows
    }

    /// Whether one column filter keeps a row. A `metadata_<column>` filter reads the sample's value from
    /// `metadataRecords`, numerically when it parses, and drops a row with no value. Other columns keep every row.
    public static func columnFilter(
        _ filter: ColumnFilter,
        matches row: NaoMgsTaxonSummaryRow,
        metadataRecords: [String: [String: String]]
    ) -> Bool {
        guard filter.isActive else { return true }
        switch filter.columnId {
        case "sample": return filter.matchesString(row.sample)
        case "name": return filter.matchesString(row.name.isEmpty ? "Taxid \(row.taxId)" : row.name)
        case "hits": return filter.matchesNumeric(Double(row.hitCount))
        case "unique": return filter.matchesNumeric(Double(row.uniqueReadCount))
        case "refs": return filter.matchesNumeric(Double(row.accessionCount))
        default:
            guard filter.columnId.hasPrefix("metadata_") else { return true }
            let column = String(filter.columnId.dropFirst("metadata_".count))
            guard let value = metadataRecords[row.sample]?[column] else { return false }
            if let number = Double(value) {
                return filter.matchesNumeric(number)
            }
            return filter.matchesString(value)
        }
    }

    /// The summary table of `rows`, each row with its own sample's metadata values.
    public static func summaryTSV(
        rows: [NaoMgsTaxonSummaryRow],
        metadataHeaders: [String],
        metadataValuesBySample: [String: [String]]
    ) -> String {
        let header = [
            "sample", "taxon_id", "name", "hit_count", "unique_read_count", "pcr_duplicate_count",
            "avg_identity", "avg_bit_score", "avg_edit_distance", "accession_count",
        ] + metadataHeaders.map(tsvField)
        var lines = [header.joined(separator: "\t")]
        for row in rows {
            let fields = [
                tsvField(row.sample), "\(row.taxId)", tsvField(row.name), "\(row.hitCount)", "\(row.uniqueReadCount)",
                "\(row.pcrDuplicateCount)", exportDecimal(row.avgIdentity, digits: 2),
                exportDecimal(row.avgBitScore, digits: 1), exportDecimal(row.avgEditDistance, digits: 1),
                "\(row.accessionCount)",
            ] + (metadataValuesBySample[row.sample] ?? []).map(tsvField)
            lines.append(fields.joined(separator: "\t"))
        }
        return lines.joined(separator: "\n") + "\n"
    }

    static func exportDecimal(_ value: Double, digits: Int) -> String {
        String(format: "%.\(digits)f", locale: Locale(identifier: "en_US_POSIX"), value)
    }

    static func tsvField(_ value: String) -> String {
        value.replacingOccurrences(of: "\t", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
    }
}
