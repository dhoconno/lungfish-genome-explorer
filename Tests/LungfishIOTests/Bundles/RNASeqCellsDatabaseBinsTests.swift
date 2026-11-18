// RNASeqCellsDatabaseBinsTests.swift - Every count the single-cell view draws is SQLite's count (Phase 5.4 lane RS-SC-VIEW)
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// A small cells.sqlite written by the one writer holds figures at every bin edge, two samples, a virus and a bacterium
// with a cell whose p and q are null, and a barcode outside the cells. Each bin is checked against a query run through
// a second read-only handle, and against the figure worked out by hand. The fixture imports of Cell Ranger and STARsolo
// are in `Tests/LungfishRNASeqUITests/SingleCell/RNASeqCellsDatabaseBinsFixtureTests.swift`, since this target does not
// link LungfishWorkflow, whose reader imports them.

import Foundation
import SQLite3
import XCTest
import LungfishTestSupport
@testable import LungfishIO

final class RNASeqCellsDatabaseBinsTests: XCTestCase {
    private var root: URL!
    private var url: URL { root.appendingPathComponent(RNASeqCellsDatabase.filename) }

    override func setUpWithError() throws { root = try TestTempDirectory.make(prefix: "cells-bins") }
    override func tearDownWithError() throws { TestTempDirectory.cleanup(root) }

    static let umis: [UInt64] = [0, 1, 2, 3, 4, 7, 8, 1000, 1023, 1024]
    static let genes: [UInt32] = [0, 1, 2, 2, 3, 5, 6, 400, 401, 402]
    static let barcodes = (1...10).map { "BC\($0)" }

    /// Cells 1 to 6 are sample 1 and cells 7 to 10 sample 2. Extra 1 is a virus and extra 2 a bacterium.
    private func writeFile() throws {
        let writer = try RNASeqCellsDatabaseWriter(url: url)
        try writer.addSample(1, name: "S1", matrix: "source/S1/matrix.mtx", size: MatrixMarketSize(rows: 5, columns: 6, entries: 20))
        try writer.addSample(2, name: "S2", matrix: "source/S2/matrix.mtx", size: MatrixMarketSize(rows: 5, columns: 4, entries: 15))
        try writer.addCells(sample: 1, firstCell: 1, barcodes: Array(Self.barcodes[0..<6]), umis: Array(Self.umis[0..<6]), genes: Array(Self.genes[0..<6]))
        try writer.addCells(sample: 2, firstCell: 7, barcodes: Array(Self.barcodes[6...]), umis: Array(Self.umis[6...]), genes: Array(Self.genes[6...]))
        try writer.addNotHostExtras([
            .init(extra: 1, name: "sars-cov-2", kind: "virus", mask: nil, maskWords: ""),
            .init(extra: 2, name: "mtb-erdman", kind: "bacterium", mask: nil, maskWords: "rRNA not masked: no annotation given for mtb-erdman"),
        ], records: [.init(record: 1, extra: 1, name: "NC_045512.2", length: 29903), .init(record: 2, extra: 2, name: "KK339487.1", length: 10000)])
        let counts: [RNASeqCellsDatabase.NotHostCount] = [
            .init(sample: 1, barcode: "BC2", extra: 1, record: 0, umis: 1, maskedUMIs: 0, umisNM01: 1, maskedUMIsNM01: 0),
            .init(sample: 1, barcode: "BC2", extra: 1, record: 1, umis: 1, maskedUMIs: 0, umisNM01: 1, maskedUMIsNM01: 0),
            .init(sample: 1, barcode: "BC3", extra: 1, record: 0, umis: 10, maskedUMIs: 2, umisNM01: 8, maskedUMIsNM01: 1),
            .init(sample: 2, barcode: "BC8", extra: 2, record: 0, umis: 5, maskedUMIs: 4, umisNM01: 3, maskedUMIsNM01: 2),
            // A barcode outside the cells, which no cell histogram counts.
            .init(sample: 1, barcode: "OUTSIDE", extra: 1, record: 0, umis: 500, maskedUMIs: 0, umisNM01: 500, maskedUMIsNM01: 0),
        ]
        let calls: [RNASeqCellsDatabase.NotHostCall] = (1...10).flatMap { cell -> [RNASeqCellsDatabase.NotHostCall] in
            let sample = cell <= 6 ? 1 : 2
            return [
                .init(sample: sample, extra: 1, cell: cell, p: 0.5, q: 0.9, flag: cell == 3 ? "viral RNA above ambient" : ""),
                .init(sample: sample, extra: 2, cell: cell, p: nil, q: nil, flag: "not computed: no rRNA mask for mtb-erdman"),
            ]
        }
        try writer.addNotHostBarcodes([], counts: counts, calls: calls)
        try writer.finish()
    }

    /// `sql` with each value bound, run through a handle of its own opened read only.
    private func count(_ sql: String, _ values: [Int]) throws -> Int {
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READONLY, nil), SQLITE_OK)
        defer { sqlite3_close(db) }
        var statement: OpaquePointer?
        XCTAssertEqual(sqlite3_prepare_v2(db, sql, -1, &statement, nil), SQLITE_OK, sql)
        defer { sqlite3_finalize(statement) }
        for (index, value) in values.enumerated() { sqlite3_bind_int64(statement, Int32(index + 1), Int64(value)) }
        XCTAssertEqual(sqlite3_step(statement), SQLITE_ROW)
        return Int(sqlite3_column_int64(statement, 0))
    }

    private func files() throws -> [String: String] {
        var found: [String: String] = [:]
        for name in try FileManager.default.contentsOfDirectory(atPath: root.path) {
            let item = root.appendingPathComponent(name)
            found[name] = "\(try RNASeqResultBundle.sha256Hex(fileAt: item)) \(try item.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? -1)"
        }
        return found
    }

    func testTheEdgesDoubleFromZeroUntilOnePassesTheLargestFigure() {
        XCTAssertEqual(RNASeqCellsDatabase.doublingEdges(through: 0), [0, 1])
        XCTAssertEqual(RNASeqCellsDatabase.doublingEdges(through: 1), [0, 1, 2])
        XCTAssertEqual(RNASeqCellsDatabase.doublingEdges(through: 3), [0, 1, 2, 4])
        XCTAssertEqual(RNASeqCellsDatabase.doublingEdges(through: 1024), [0, 1, 2, 4, 8, 16, 32, 64, 128, 256, 512, 1024, 2048])
        XCTAssertEqual(RNASeqCellsDatabase.doublingEdges(through: -1), [])
        XCTAssertEqual(RNASeqCellsDatabase.doublingEdges(through: Int.max).last, 1 << 62)
    }

    func testEveryUMIAndGeneBinIsTheCountOfASecondReadOnlyHandle() throws {
        try writeFile()
        let umis = try RNASeqCellsDatabase.bins(of: .umis, inFileAt: url)
        XCTAssertEqual(umis.map(\.cells), [1, 1, 2, 2, 1, 0, 0, 0, 0, 0, 2, 1])
        XCTAssertEqual(umis.last?.upper, 2048)
        for bin in umis {
            XCTAssertEqual(bin.cells, try count("SELECT COUNT(*) FROM cells WHERE umis >= ? AND umis < ?", [bin.lower, bin.upper]), "\(bin)")
        }
        let genes = try RNASeqCellsDatabase.bins(of: .genes, inFileAt: url)
        XCTAssertEqual(genes.map(\.cells), [1, 1, 3, 2, 0, 0, 0, 0, 0, 3])
        for bin in genes {
            XCTAssertEqual(bin.cells, try count("SELECT COUNT(*) FROM cells WHERE genes >= ? AND genes < ?", [bin.lower, bin.upper]), "\(bin)")
        }
        XCTAssertEqual(zip(umis.dropFirst(), umis).allSatisfy { $0.lower == $1.upper }, true, "the bins leave no gap")
    }

    func testTheNotHostBinsCountEachCellOnceAndACellWithNoRowAtZero() throws {
        try writeFile()
        let virus = try RNASeqCellsDatabase.bins(of: .notHostUMIs(extra: 1), inFileAt: url)
        // BC2 holds 1 and BC3 10. The barcode outside the cells and the record row of BC2 count for no cell.
        XCTAssertEqual(virus.map { [$0.lower, $0.upper, $0.cells] }, [[0, 1, 8], [1, 2, 1], [2, 4, 0], [4, 8, 0], [8, 16, 1]])
        let bacterium = try RNASeqCellsDatabase.bins(of: .notHostUMIs(extra: 2), inFileAt: url)
        XCTAssertEqual(bacterium.map(\.cells), [9, 0, 0, 1])
        let sql = """
            SELECT COUNT(*) FROM cells c WHERE coalesce((SELECT umis FROM not_host_counts n
              WHERE n.sample = c.sample AND n.barcode = c.barcode AND n.extra = ? AND n.record = 0), 0) >= ?
              AND coalesce((SELECT umis FROM not_host_counts n
              WHERE n.sample = c.sample AND n.barcode = c.barcode AND n.extra = ? AND n.record = 0), 0) < ?
            """
        for (extra, bins) in [(1, virus), (2, bacterium)] {
            for bin in bins { XCTAssertEqual(bin.cells, try count(sql, [extra, bin.lower, extra, bin.upper]), "extra \(extra) \(bin)") }
        }
    }

    func testTheRankStepsAreTheRanksSQLiteGivesTheCellsMostUMIsFirst() throws {
        try writeFile()
        let steps = try RNASeqCellsDatabase.rankSteps(inFileAt: url)
        XCTAssertEqual(steps.map(\.umis), [1024, 1023, 1000, 8, 7, 4, 3, 2, 1, 0])
        XCTAssertEqual(steps.first, .init(umis: 1024, firstRank: 1, lastRank: 1))
        XCTAssertEqual(steps.last, .init(umis: 0, firstRank: 10, lastRank: 10))
        for step in steps {
            XCTAssertEqual(step.firstRank, try count("SELECT COUNT(*) FROM cells WHERE umis > ?", [step.umis]) + 1)
            XCTAssertEqual(step.lastRank, try count("SELECT COUNT(*) FROM cells WHERE umis >= ?", [step.umis]))
        }
    }

    func testTiedCellsShareTheRanksOfOneStep() throws {
        let writer = try RNASeqCellsDatabaseWriter(url: url)
        try writer.addSample(1, name: "S1", matrix: "m", size: MatrixMarketSize(rows: 1, columns: 5, entries: 5))
        try writer.addCells(sample: 1, firstCell: 1, barcodes: ["A", "B", "C", "D", "E"], umis: [5, 9, 5, 5, 2], genes: [1, 1, 1, 1, 1])
        try writer.finish()
        XCTAssertEqual(try RNASeqCellsDatabase.rankSteps(inFileAt: url), [
            .init(umis: 9, firstRank: 1, lastRank: 1), .init(umis: 5, firstRank: 2, lastRank: 4), .init(umis: 2, firstRank: 5, lastRank: 5),
        ])
        XCTAssertEqual(try RNASeqCellsDatabase.notHostColumns(offset: 0, limit: 5, inFileAt: url), [], "a file with no extra has no not-host columns")
    }

    func testAPageOfNotHostColumnsHoldsTheCountsAndTheCallAsWritten() throws {
        try writeFile()
        let page = try RNASeqCellsDatabase.notHostColumns(offset: 1, limit: 2, inFileAt: url)
        XCTAssertEqual(page.map { [$0.cell, $0.extra] }, [[2, 1], [2, 2], [3, 1], [3, 2]])
        XCTAssertEqual(page[2], .init(cell: 3, extra: 1, umis: 10, maskedUMIs: 2, umisNM01: 8, maskedUMIsNM01: 1,
                                      call: .init(sample: 1, extra: 1, cell: 3, p: 0.5, q: 0.9, flag: "viral RNA above ambient")))
        XCTAssertEqual(page[1].umis, 0, "a cell with no row holds 0")
        XCTAssertNil(page[1].call?.p)
        XCTAssertEqual(page[1].call?.flag, "not computed: no rRNA mask for mtb-erdman")
        let cells = try RNASeqCellsDatabase(url: url).cells(offset: 1, limit: 2).map(\.cell)
        XCTAssertEqual(Array(Set(page.map(\.cell))).sorted(), cells, "the page is the page of cells(offset:limit:)")
    }

    func testASchema1FileHasNoNotHostBinsAndANewerOneIsRefusedInWords() throws {
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path, &db), SQLITE_OK)
        for sql in [
            "CREATE TABLE meta (key TEXT PRIMARY KEY, value TEXT NOT NULL)", "INSERT INTO meta VALUES ('schema_version', '1')",
            "CREATE TABLE cells (cell INTEGER PRIMARY KEY, sample INTEGER NOT NULL, \"column\" INTEGER NOT NULL, barcode TEXT NOT NULL, umis INTEGER NOT NULL, genes INTEGER NOT NULL)",
            "INSERT INTO cells VALUES (1, 1, 1, 'AAAC', 5, 2)",
        ] { XCTAssertEqual(sqlite3_exec(db, sql, nil, nil, nil), SQLITE_OK, sql) }
        XCTAssertEqual(try RNASeqCellsDatabase.bins(of: .notHostUMIs(extra: 1), inFileAt: url), [])
        XCTAssertEqual(try RNASeqCellsDatabase.notHostColumns(offset: 0, limit: 10, inFileAt: url), [])
        XCTAssertEqual(try RNASeqCellsDatabase.bins(of: .umis, inFileAt: url).map(\.cells), [0, 0, 0, 1])
        XCTAssertEqual(sqlite3_exec(db, "UPDATE meta SET value = '3' WHERE key = 'schema_version'", nil, nil, nil), SQLITE_OK)
        sqlite3_close(db)
        XCTAssertThrowsError(try RNASeqCellsDatabase.bins(of: .umis, inFileAt: url)) { error in
            XCTAssertEqual(error.localizedDescription, "This RNA-seq result was written by a newer LGE (schema 3). Open it with that version or a later one.")
        }
        let missing = root.appendingPathComponent("none.sqlite")
        XCTAssertThrowsError(try RNASeqCellsDatabase.rankSteps(inFileAt: missing))
        XCTAssertFalse(FileManager.default.fileExists(atPath: missing.path), "a read-only open makes no file")
    }

    func testReadingChangesNoByteAndLeavesNoJournalBehind() throws {
        try writeFile()
        let before = try files()
        XCTAssertEqual(Array(before.keys), [RNASeqCellsDatabase.filename])
        _ = try RNASeqCellsDatabase.bins(of: .umis, inFileAt: url)
        _ = try RNASeqCellsDatabase.bins(of: .notHostUMIs(extra: 1), inFileAt: url)
        _ = try RNASeqCellsDatabase.rankSteps(inFileAt: url)
        _ = try RNASeqCellsDatabase.notHostColumns(offset: 0, limit: 10, inFileAt: url)
        XCTAssertEqual(try files(), before, "no -wal, -shm or -journal file and no changed byte")
    }
}
