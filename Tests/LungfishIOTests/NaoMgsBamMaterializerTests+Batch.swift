// NaoMgsBamMaterializerTests+Batch.swift - The NAO-MGS writer sends its SAM text to samtools in 64 KiB batches
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
import SQLite3
import LungfishTestSupport
@testable import LungfishIO

extension NaoMgsBamMaterializerTests {

    /// 2000 single-end rows are about 580 KB of SAM text, so the writer sends nine full batches and a last partial
    /// one. Every row must reach the BAM, which a lost last batch or a lost batch boundary would break
    /// (lane 13.09 SWIFT fix 1).
    func testALargeSampleStreamsThroughSeveralBatches() throws {
        guard let samtools = BamFixtureBuilder.locateSamtools() else {
            try ToolAvailability.skipOrFail("samtools is not installed")
        }
        let tmp = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let dbURL = tmp.appendingPathComponent("naomgs.sqlite")
        try makeTestDatabase(at: dbURL, sample: "S1", duplicateCount: 0)
        try addSingleEndRows(to: dbURL, sample: "S1", count: 2000)

        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open_v2(dbURL.path, &db, SQLITE_OPEN_READONLY, nil), SQLITE_OK)
        defer { sqlite3_close(db) }
        var statement: OpaquePointer?
        XCTAssertEqual(sqlite3_prepare_v2(db, "SELECT count(*) FROM virus_hits WHERE sample = 'S1'", -1, &statement, nil), SQLITE_OK)
        defer { sqlite3_finalize(statement) }
        XCTAssertEqual(sqlite3_step(statement), SQLITE_ROW)
        let stored = Int(sqlite3_column_int64(statement, 0))
        XCTAssertEqual(stored, 2000)

        let result = try materializeForPin(dbURL: dbURL, tmp: tmp, samtools: samtools, markDuplicates: false)
        let bam = try XCTUnwrap(result.bamURLs.first)
        let count = Process()
        count.executableURL = URL(fileURLWithPath: samtools)
        count.arguments = ["view", "-c", bam.path]
        let output = Pipe()
        count.standardOutput = output
        try count.run()
        let text = String(data: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        count.waitUntilExit()
        XCTAssertEqual(count.terminationStatus, 0)
        XCTAssertEqual(Int(text.trimmingCharacters(in: .whitespacesAndNewlines)), stored)
    }
}
