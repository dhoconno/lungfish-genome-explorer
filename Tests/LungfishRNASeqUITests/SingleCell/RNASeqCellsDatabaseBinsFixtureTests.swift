// RNASeqCellsDatabaseBinsFixtureTests.swift - The bins of the two pbmc_1k_v3 imports are SQLite's counts (lane RS-SC-VIEW)
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// The check of the brief's IO test on real imports. It lives in the leaf's tests because LungfishIOTests does not link
// LungfishWorkflow, whose folder reader imports a Cell Ranger or STARsolo folder (`Package.swift`, LungfishIOTests).

import Foundation
import LungfishIO
import LungfishTestSupport
import SQLite3
import XCTest

final class RNASeqCellsDatabaseBinsFixtureTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws { root = try TestTempDirectory.make(prefix: "cells-bins-fixture") }
    override func tearDownWithError() throws { TestTempDirectory.cleanup(root) }

    /// `sql` with each value bound, run through a second handle opened read only.
    private func count(_ url: URL, _ sql: String, _ values: [Int]) throws -> Int {
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

    func testEveryBinOfBothImportsEqualsTheCountOfASecondReadOnlyHandle() throws {
        for fixture in RNASeqSingleCellFixtures.Fixture.allCases {
            let result = try RNASeqSingleCellFixtures.write(fixture, into: root.appendingPathComponent(fixture == .cellRanger ? "a" : "b"))
            let url = result.appendingPathComponent(RNASeqCellsDatabase.filename)
            let database = try RNASeqCellsDatabase(url: url)
            let cellCount = try database.cellCount()
            XCTAssertGreaterThan(cellCount, 100, "\(fixture) holds the cells of the pbmc_1k_v3 cut")
            XCTAssertEqual(try database.samples().map(\.cells), [cellCount])
            for (column, measure) in [("umis", RNASeqCellsDatabase.CellMeasure.umis), ("genes", .genes)] {
                let bins = try RNASeqCellsDatabase.bins(of: measure, inFileAt: url)
                XCTAssertGreaterThan(bins.count, 5, "\(fixture) \(column)")
                XCTAssertEqual(bins.first?.lower, 0)
                for bin in bins {
                    let sql = "SELECT COUNT(*) FROM cells WHERE \(column) >= ? AND \(column) < ?"
                    XCTAssertEqual(bin.cells, try count(url, sql, [bin.lower, bin.upper]), "\(fixture) \(column) \(bin)")
                }
                XCTAssertEqual(bins.reduce(0) { $0 + $1.cells }, cellCount, "\(fixture) \(column): every cell lies in one bin")
                let largest = try count(url, "SELECT max(\(column)) FROM cells", [])
                XCTAssertTrue(bins.last.map { $0.lower <= largest && largest < $0.upper } ?? false, "\(fixture) \(column): the last bin holds the largest")
            }
            let steps = try RNASeqCellsDatabase.rankSteps(inFileAt: url)
            XCTAssertEqual(steps.first?.firstRank, 1)
            XCTAssertEqual(steps.last?.lastRank, cellCount)
            for step in steps.prefix(50) {
                XCTAssertEqual(step.lastRank, try count(url, "SELECT COUNT(*) FROM cells WHERE umis >= ?", [step.umis]), "\(fixture) \(step)")
            }
            XCTAssertEqual(try RNASeqCellsDatabase.bins(of: .notHostUMIs(extra: 1), inFileAt: url).map(\.cells), [cellCount],
                           "an import with no not-host pass puts every cell at 0")
        }
    }
}
