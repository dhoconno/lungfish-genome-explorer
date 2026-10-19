// TaxTriageResultsTable.swift - The rows the TaxTriage flat table shows for a search, column filters and a sort
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishCore
import LungfishIO

extension TaxTriageResultsExport {
    /// The prefix of a metadata column's id in the flat table, the id its sort key and its filters carry.
    public static let metadataColumnPrefix = "metadata_"

    /// The ids of the columns the flat table sorts by, in column order (`BatchTaxTriageTableView.columnSpecs`).
    public static let columnIds = [
        "tt_sample", "tt_organism", "tt_tassScore", "tt_reads", "tt_uniqueReads", "tt_confidence",
        "tt_coverageBreadth", "tt_coverageDepth", "tt_abundance",
    ]

    /// The type hints the flat table declares for its column filters (`BatchTaxTriageTableView.columnTypeHints`).
    /// They are keyed by names the table's column ids do not use, as the table keys them, so a filter prefers a
    /// number only through its operator.
    static let columnTypeHints: [String: Bool] = [
        "sample": false, "organism": false, "confidence": false,
        "tassScore": true, "reads": true, "uniqueReads": true,
        "coverageBreadth": true, "coverageDepth": true, "abundance": true,
    ]

    /// The rows the flat table shows once its column filters and its sort apply to the rows its search and Sample
    /// Filter loaded (`BatchTableView.applyFilter` and `sortedForDisplay`). A filter keeps a row by the text of the
    /// cell the table would show, or by the metadata value for a metadata column. Only the first sort key orders
    /// the rows, as the table orders them by its first sort descriptor, and a sort by a metadata column compares
    /// the sample values as natural text. The table's search field is hidden and the organism search reaches the
    /// database, so the loaded rows already follow it.
    ///
    /// - Parameters:
    ///   - metrics: The loaded rows, in the database's order.
    ///   - filters: The column filters and their composition.
    ///   - sortKeys: The sort keys, the first being the primary key.
    ///   - totalReadsByKey: The read counts the table holds by `"<sample>\t<organism>"`.
    ///   - uniqueReadsByKey: The stored unique read counts the table holds by the same key.
    ///   - contaminationRiskOrganismKeys: The normalized names of the organisms the negative controls hold.
    ///   - metadata: The sample metadata store the table holds, if any.
    public static func shownRows(
        metrics: [TaxTriageMetric],
        filters: ColumnFilterSet,
        sortKeys: [ViewerExportSortKey],
        totalReadsByKey: [String: Int],
        uniqueReadsByKey: [String: Int],
        contaminationRiskOrganismKeys: Set<String>,
        metadata: SampleMetadataStore?
    ) -> [TaxTriageMetric] {
        let table = Table(
            totalReadsByKey: totalReadsByKey,
            uniqueReadsByKey: uniqueReadsByKey,
            contaminationRiskOrganismKeys: contaminationRiskOrganismKeys,
            metadata: metadata
        )
        var rows = metrics
        let snapshot = ColumnFilterSnapshot(filters, typeHints: columnTypeHints)
        if snapshot.isActive {
            rows = rows.filter { row in
                snapshot.matches { filter in table.filterValue(for: filter, row: row) }
            }
        }
        guard let key = sortKeys.first else { return rows }
        return rows.sorted { table.precedes($0, $1, by: key.column, ascending: key.ascending) }
    }

    /// The compact text of a read count, as the table shows it (`formatReadCount`).
    static func readCountText(_ count: Int) -> String {
        if count >= 1_000_000 {
            return String(format: "%.1fM", Double(count) / 1_000_000)
        } else if count >= 1_000 {
            return String(format: "%.1fK", Double(count) / 1_000)
        }
        return "\(count)"
    }

    /// The table's per-row lookups: the cell text a filter reads, and the order a sort gives.
    private struct Table {
        let totalReadsByKey: [String: Int]
        let uniqueReadsByKey: [String: Int]
        let contaminationRiskOrganismKeys: Set<String>
        let metadata: SampleMetadataStore?

        private func key(_ row: TaxTriageMetric) -> String {
            "\(row.sample ?? "")\t\(row.organism)"
        }

        private func isContaminationRisk(_ row: TaxTriageMetric) -> Bool {
            !contaminationRiskOrganismKeys.isEmpty
                && contaminationRiskOrganismKeys.contains(OrganismNameNormalizer.normalizedKey(row.organism))
        }

        private func reads(_ row: TaxTriageMetric) -> Int {
            totalReadsByKey[key(row)] ?? row.reads
        }

        private func uniqueReads(_ row: TaxTriageMetric) -> Int? {
            ClassifierUniqueReads.normalized(stored: uniqueReadsByKey[key(row)], readCount: reads(row))
        }

        /// The text of the cell the table shows for `columnId` (`BatchTaxTriageTableView.cellContent`).
        private func cellText(_ columnId: String, _ row: TaxTriageMetric) -> String {
            switch columnId {
            case "tt_sample":
                return row.sample ?? "\u{2014}"
            case "tt_organism":
                return isContaminationRisk(row) ? "\u{26A0} \(row.organism)" : row.organism
            case "tt_tassScore":
                return String(format: "%.3f", row.tassScore)
            case "tt_reads":
                return TaxTriageResultsExport.readCountText(reads(row))
            case "tt_uniqueReads":
                return uniqueReads(row).map { TaxTriageResultsExport.readCountText($0) } ?? "\u{2014}"
            case "tt_confidence":
                return row.confidence ?? "\u{2014}"
            case "tt_coverageBreadth":
                return row.coverageBreadth.map { String(format: "%.1f%%", $0) } ?? "\u{2014}"
            case "tt_coverageDepth":
                return row.coverageDepth.map { String(format: "%.1f\u{00D7}", $0) } ?? "\u{2014}"
            case "tt_abundance":
                return row.abundance.map { String(format: "%.2f%%", $0 * 100) } ?? "\u{2014}"
            default:
                return ""
            }
        }

        /// The value a column filter tests for `row` (`BatchTableView.columnFilterValue`).
        func filterValue(for filter: PreparedColumnFilter, row: TaxTriageMetric) -> ColumnFilterValue? {
            if let metadataColumnName = filter.metadataColumnName,
               let sample = row.sample,
               let store = metadata,
               let metadataValue = store.records[sample]?[metadataColumnName] {
                if filter.prefersNumeric, let number = ColumnFilter.parseNumericValue(metadataValue) {
                    return .numeric(number)
                }
                return .string(metadataValue)
            }
            let text = cellText(filter.columnId, row)
            if filter.prefersNumeric, let number = ColumnFilter.parseNumericValue(text) {
                return .numeric(number)
            }
            return .string(text)
        }

        /// Whether `lhs` sorts before `rhs` by `key` (`compareDisplayedRows` and `compareRows`). A descending sort
        /// is the negation of the ascending one, as the table's is.
        func precedes(_ lhs: TaxTriageMetric, _ rhs: TaxTriageMetric, by key: String, ascending: Bool) -> Bool {
            if let result = metadataComparison(key, lhs, rhs) {
                return ascending ? result == .orderedAscending : result == .orderedDescending
            }
            let result: Bool
            switch key {
            case "tt_sample":
                result = (lhs.sample ?? "").localizedCaseInsensitiveCompare(rhs.sample ?? "") == .orderedAscending
            case "tt_organism":
                result = lhs.organism.localizedCaseInsensitiveCompare(rhs.organism) == .orderedAscending
            case "tt_tassScore":
                result = lhs.tassScore < rhs.tassScore
            case "tt_reads":
                result = reads(lhs) < reads(rhs)
            case "tt_uniqueReads":
                result = (uniqueReads(lhs) ?? -1) < (uniqueReads(rhs) ?? -1)
            case "tt_confidence":
                result = (lhs.confidence ?? "").localizedCaseInsensitiveCompare(rhs.confidence ?? "") == .orderedAscending
            case "tt_coverageBreadth":
                result = (lhs.coverageBreadth ?? 0) < (rhs.coverageBreadth ?? 0)
            case "tt_coverageDepth":
                result = (lhs.coverageDepth ?? 0) < (rhs.coverageDepth ?? 0)
            case "tt_abundance":
                result = (lhs.abundance ?? 0) < (rhs.abundance ?? 0)
            default:
                return false
            }
            return ascending ? result : !result
        }

        /// The order of two samples' values in a metadata column, or nil when `key` names none the store holds
        /// (`MetadataColumnController.comparison`).
        private func metadataComparison(
            _ key: String,
            _ lhs: TaxTriageMetric,
            _ rhs: TaxTriageMetric
        ) -> ComparisonResult? {
            let prefix = TaxTriageResultsExport.metadataColumnPrefix
            guard key.hasPrefix(prefix), let store = metadata else { return nil }
            let columnName = String(key.dropFirst(prefix.count))
            guard store.columnNames.contains(columnName) else { return nil }
            let lhsValue = lhs.sample.flatMap { store.records[$0]?[columnName] } ?? ""
            let rhsValue = rhs.sample.flatMap { store.records[$0]?[columnName] } ?? ""
            return lhsValue.compare(rhsValue, options: [.caseInsensitive, .numeric])
        }
    }
}
