// RNASeqCellsDatabase+Bins.swift - The counts the single-cell view draws, each read by SQLite (Phase 5.4 lane RS-SC-VIEW)
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// The view of a single-cell result computes no number of its own (`docs/plans/2026-10-02-architecture-program.md:262`).
// Each count it draws is read here by one SQL query over a handle opened read only, so reading never writes into the
// project. The handle of `RNASeqCellsDatabase` is private to its own file, so each read here opens its own read-only
// handle on the same file, checks the `meta` schema as `RNASeqCellsDatabase.init(url:)` does, and closes it before it
// returns. The file keeps SQLite's rollback journal, so a read-only handle leaves no `-wal` or `-shm` file behind.

import Foundation
import SQLite3

extension RNASeqCellsDatabase {
    /// The figure of a cell that a histogram bins.
    public enum CellMeasure: Equatable, Hashable, Sendable {
        /// `cells.umis`, the cell's UMIs over the `Gene Expression` features.
        case umis
        /// `cells.genes`, the `Gene Expression` features with a count.
        case genes
        /// The default column of `not_host_counts` for one extra at record 0, the extra's figure over its records. A
        /// cell with no row there holds 0, since the table keeps only counts above 0.
        case notHostUMIs(extra: Int)
    }

    /// The cells whose figure lies in `lower ..< upper`.
    public struct Bin: Equatable, Sendable {
        public var lower: Int
        public var upper: Int
        public var cells: Int

        public init(lower: Int, upper: Int, cells: Int) {
            (self.lower, self.upper, self.cells) = (lower, upper, cells)
        }
    }

    /// The cells that hold one UMI count, and the ranks they take when every cell is ranked by UMIs, most first. Tied
    /// cells share the ranks of their step, so the steps draw the whole rank plot and leave no cell out.
    public struct RankStep: Equatable, Sendable {
        public var umis: Int
        public var firstRank: Int
        public var lastRank: Int

        public init(umis: Int, firstRank: Int, lastRank: Int) {
            (self.umis, self.firstRank, self.lastRank) = (umis, firstRank, lastRank)
        }
    }

    /// The not-host columns of one cell for one extra, as the tables hold them.
    public struct NotHostCellColumns: Equatable, Sendable {
        public var cell: Int
        public var extra: Int
        /// The default and masked columns and their parts at nM 0 or 1, each 0 where `not_host_counts` has no row.
        public var umis: Int
        public var maskedUMIs: Int
        public var umisNM01: Int
        public var maskedUMIsNM01: Int
        /// The cell's row of `not_host_calls`, or nil for an extra that gets no call, such as a spike-in.
        public var call: NotHostCall?

        public init(cell: Int, extra: Int, umis: Int, maskedUMIs: Int, umisNM01: Int, maskedUMIsNM01: Int, call: NotHostCall?) {
            (self.cell, self.extra, self.umis, self.maskedUMIs) = (cell, extra, umis, maskedUMIs)
            (self.umisNM01, self.maskedUMIsNM01, self.call) = (umisNM01, maskedUMIsNM01, call)
        }
    }

    /// The edges of the bins: 0, 1, 2, 4 and on, each twice the one before, until an edge passes `maximum`.
    public static func doublingEdges(through maximum: Int) -> [Int] {
        guard maximum >= 0 else { return [] }
        var edges = [0, 1]
        while let last = edges.last, last <= maximum, last <= Int.max / 2 { edges.append(last * 2) }
        return edges
    }

    /// The cells in each bin of `measure`, counted by SQLite in one query over the cells. The bins run from 0 in
    /// doubling widths, so the last one holds the largest figure. A file with no cells has no bins, and a file of
    /// schema 1 has no not-host table, so its not-host bins are none.
    public static func bins(of measure: CellMeasure, inFileAt url: URL) throws -> [Bin] {
        try withReadOnlyHandle(url) { db, schema in
            guard let source = valuesSQL(measure, schema: schema) else { return [] }
            let maximum = try rows(db, "SELECT max(value) FROM (\(source))") { optionalInt($0, 0) }.first ?? nil
            guard let maximum else { return [] }
            let edges = doublingEdges(through: maximum)
            let cases = (1..<edges.count).map { "WHEN value < \(edges[$0]) THEN \($0 - 1)" }.joined(separator: " ")
            let counted = try rows(db, "SELECT CASE \(cases) END AS bin, count(*) FROM (\(source)) GROUP BY bin") { (int($0, 0), int($0, 1)) }
            let cells = Dictionary(counted, uniquingKeysWith: +)
            return (1..<edges.count).map { Bin(lower: edges[$0 - 1], upper: edges[$0], cells: cells[$0 - 1] ?? 0) }
        }
    }

    /// Every cell ranked by `umis`, most first, as one step for each UMI count, ranked by SQLite.
    public static func rankSteps(inFileAt url: URL) throws -> [RankStep] {
        try withReadOnlyHandle(url) { db, _ in
            try rows(db, """
                SELECT umis, through - here + 1, through FROM (
                  SELECT umis, count(*) AS here,
                         sum(count(*)) OVER (ORDER BY umis DESC ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW) AS through
                  FROM cells GROUP BY umis)
                ORDER BY umis DESC
                """) { RankStep(umis: int($0, 0), firstRank: int($0, 1), lastRank: int($0, 2)) }
        }
    }

    /// The not-host columns of a page of cells, the page being that of `cells(offset:limit:)`. One row for each cell
    /// and each extra, in the order of their numbers. A file of schema 1 gives none.
    public static func notHostColumns(offset: Int, limit: Int, inFileAt url: URL) throws -> [NotHostCellColumns] {
        try withReadOnlyHandle(url) { db, schema in
            guard schema >= 2 else { return [] }
            return try rows(db, """
                SELECT c.cell, e.extra, coalesce(n.umis, 0), coalesce(n.masked_umis, 0), coalesce(n.umis_nm01, 0),
                       coalesce(n.masked_umis_nm01, 0), k.sample, k.p, k.q, k.flag
                FROM (SELECT cell, sample, barcode FROM cells ORDER BY cell LIMIT \(max(0, limit)) OFFSET \(max(0, offset))) AS c
                CROSS JOIN not_host_extras AS e
                LEFT JOIN not_host_counts AS n
                  ON n.sample = c.sample AND n.barcode = c.barcode AND n.extra = e.extra AND n.record = 0
                LEFT JOIN not_host_calls AS k ON k.sample = c.sample AND k.extra = e.extra AND k.cell = c.cell
                ORDER BY c.cell, e.extra
                """) { row in
                let cell = int(row, 0), extra = int(row, 1)
                let call = optionalInt(row, 6).map { sample in
                    NotHostCall(sample: sample, extra: extra, cell: cell, p: optionalDouble(row, 7), q: optionalDouble(row, 8), flag: text(row, 9))
                }
                return NotHostCellColumns(cell: cell, extra: extra, umis: int(row, 2), maskedUMIs: int(row, 3),
                                          umisNM01: int(row, 4), maskedUMIsNM01: int(row, 5), call: call)
            }
        }
    }

    /// The rows the histogram of `measure` bins, each as `value`, or nil when the file has no table for it.
    static func valuesSQL(_ measure: CellMeasure, schema: Int) -> String? {
        switch measure {
        case .umis:
            return "SELECT umis AS value FROM cells"
        case .genes:
            return "SELECT genes AS value FROM cells"
        case .notHostUMIs(let extra):
            guard schema >= 2 else { return nil }
            return """
                SELECT coalesce(n.umis, 0) AS value FROM cells AS c LEFT JOIN not_host_counts AS n
                  ON n.sample = c.sample AND n.barcode = c.barcode AND n.extra = \(extra) AND n.record = 0
                """
        }
    }

    static func optionalDouble(_ statement: OpaquePointer, _ column: Int32) -> Double? {
        sqlite3_column_type(statement, column) == SQLITE_NULL ? nil : sqlite3_column_double(statement, column)
    }

    /// Opens `url` read only, refuses a file with no schema or a newer one in the words of `init(url:)`, runs `body`
    /// with the handle and the schema, and closes the handle.
    static func withReadOnlyHandle<T>(_ url: URL, _ body: (OpaquePointer, Int) throws -> T) throws -> T {
        var handle: OpaquePointer?
        guard sqlite3_open_v2(url.path, &handle, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let handle else {
            sqlite3_close(handle)
            throw RNASeqResultError.unreadableFile(path: filename, reason: "SQLite could not open it")
        }
        defer { sqlite3_close(handle) }
        let found = try rows(handle, "SELECT value FROM meta WHERE key = 'schema_version'") { text($0, 0) }
        guard let first = found.first, let version = Int(first) else {
            throw RNASeqResultError.unreadableFile(path: filename, reason: "its meta table holds no schema_version")
        }
        guard version <= currentSchemaVersion else { throw RNASeqResultError.newerSchema(version) }
        return try body(handle, version)
    }
}
