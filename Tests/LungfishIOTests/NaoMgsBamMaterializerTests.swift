// NaoMgsBamMaterializerTests.swift - Tests for NaoMgsBamMaterializer
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
import SQLite3
@testable import LungfishIO

final class NaoMgsBamMaterializerTests: XCTestCase {

    private var samtoolsPath: String {
        BamFixtureBuilder.locateSamtools() ?? ""
    }

    private func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("NaoMgsMaterializerTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Creates a minimal NAO-MGS SQLite database with one sample and a handful of virus_hits rows.
    private func makeTestDatabase(at dbURL: URL, sample: String = "S1", duplicateCount: Int = 3) throws {
        var db: OpaquePointer?
        guard sqlite3_open_v2(dbURL.path, &db,
                               SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil) == SQLITE_OK else {
            throw NSError(domain: "test", code: 1)
        }
        defer { sqlite3_close(db) }

        let schema = """
        CREATE TABLE virus_hits (
            rowid INTEGER PRIMARY KEY,
            sample TEXT NOT NULL,
            seq_id TEXT NOT NULL,
            tax_id INTEGER NOT NULL,
            subject_seq_id TEXT NOT NULL,
            subject_title TEXT NOT NULL,
            ref_start INTEGER NOT NULL,
            cigar TEXT NOT NULL,
            read_sequence TEXT NOT NULL,
            read_quality TEXT NOT NULL,
            percent_identity REAL NOT NULL,
            bit_score REAL NOT NULL,
            e_value REAL NOT NULL,
            edit_distance INTEGER NOT NULL,
            query_length INTEGER NOT NULL,
            is_reverse_complement INTEGER NOT NULL,
            pair_status TEXT NOT NULL,
            fragment_length INTEGER NOT NULL,
            best_alignment_score REAL NOT NULL
        );
        CREATE TABLE reference_lengths (accession TEXT PRIMARY KEY, length INTEGER NOT NULL);
        """
        sqlite3_exec(db, schema, nil, nil, nil)

        sqlite3_exec(db, "INSERT INTO reference_lengths VALUES ('NC_001', 1000)", nil, nil, nil)

        // Insert `duplicateCount` rows at identical position (will become duplicates after markdup)
        let seq = String(repeating: "A", count: 50)
        let qual = String(repeating: "I", count: 50)
        for i in 0..<duplicateCount {
            let sql = """
            INSERT INTO virus_hits VALUES (
                NULL, '\(sample)', 'read\(i)', 1, 'NC_001', 'Test virus',
                100, '50M', '\(seq)', '\(qual)', 99.0, 100.0, 0.001, 0, 50, 0,
                'unpaired', 50, 90.0
            )
            """
            sqlite3_exec(db, sql, nil, nil, nil)
        }
    }

    func testMaterializeSingleSample() throws {
        guard !samtoolsPath.isEmpty else { XCTFail("samtools not available"); return }

        let tmp = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tmp) }

        let dbURL = tmp.appendingPathComponent("naomgs.sqlite")
        try makeTestDatabase(at: dbURL, sample: "S1", duplicateCount: 3)

        let generated = try NaoMgsBamMaterializer.materializeAll(
            dbPath: dbURL.path,
            resultURL: tmp,
            samtoolsPath: samtoolsPath
        )

        XCTAssertEqual(generated.count, 1)
        let bamURL = generated[0]
        XCTAssertTrue(FileManager.default.fileExists(atPath: bamURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: bamURL.path + ".bai"))
    }

    func testMaterializeDuplicatesAreMarked() throws {
        guard !samtoolsPath.isEmpty else { XCTFail("samtools not available"); return }

        let tmp = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tmp) }

        let dbURL = tmp.appendingPathComponent("naomgs.sqlite")
        try makeTestDatabase(at: dbURL, sample: "S1", duplicateCount: 5)

        let generated = try NaoMgsBamMaterializer.materializeAll(
            dbPath: dbURL.path,
            resultURL: tmp,
            samtoolsPath: samtoolsPath
        )

        let bamURL = generated[0]
        // After markdup, non-duplicate count should be less than total (5)
        let total = try MarkdupService.countReads(
            bamURL: bamURL, accession: nil, flagFilter: 0x004, samtoolsPath: samtoolsPath
        )
        let nonDup = try MarkdupService.countReads(
            bamURL: bamURL, accession: nil, flagFilter: 0x404, samtoolsPath: samtoolsPath
        )
        XCTAssertEqual(total, 5)
        XCTAssertLessThan(nonDup, total, "Some reads should be flagged as duplicates")
    }

    func testMaterializeIdempotent() async throws {
        guard !samtoolsPath.isEmpty else { XCTFail("samtools not available"); return }

        let tmp = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tmp) }

        let dbURL = tmp.appendingPathComponent("naomgs.sqlite")
        try makeTestDatabase(at: dbURL, sample: "S1", duplicateCount: 3)

        let first = try NaoMgsBamMaterializer.materializeAll(
            dbPath: dbURL.path, resultURL: tmp, samtoolsPath: samtoolsPath
        )
        let firstMtime = (try? FileManager.default.attributesOfItem(atPath: first[0].path)[.modificationDate]) as? Date

        try await Task.sleep(nanoseconds: 1_100_000_000)

        let second = try NaoMgsBamMaterializer.materializeAll(
            dbPath: dbURL.path, resultURL: tmp, samtoolsPath: samtoolsPath
        )
        let secondMtime = (try? FileManager.default.attributesOfItem(atPath: second[0].path)[.modificationDate]) as? Date

        XCTAssertEqual(firstMtime, secondMtime, "Second call should be a no-op")
    }
}
