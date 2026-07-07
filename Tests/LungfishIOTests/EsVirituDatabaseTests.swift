// EsVirituDatabaseTests.swift - Unit tests for EsVirituDatabase
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
import SQLite3
@testable import LungfishIO

final class EsVirituDatabaseTests: XCTestCase {
    private func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("EsVirituDatabaseTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func buildStateValue(at url: URL) throws -> String? {
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READONLY, nil), SQLITE_OK)
        defer { sqlite3_close(db) }

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(
            db,
            "SELECT value FROM lungfish_database_state WHERE key = 'build_state'",
            -1,
            &stmt,
            nil
        ) == SQLITE_OK else {
            return nil
        }
        defer { sqlite3_finalize(stmt) }

        guard sqlite3_step(stmt) == SQLITE_ROW, let value = sqlite3_column_text(stmt, 0) else {
            return nil
        }
        return String(cString: value)
    }

    func testCreateAndOpen() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let dbURL = dir.appendingPathComponent("test.sqlite")

        let rows = [makeTestRow(sample: "s1", virusName: "SARS-CoV-2", accession: "NC_045512.2",
                                assembly: "GCF_009858895.2", readCount: 1000)]
        let db = try EsVirituDatabase.create(at: dbURL, rows: rows, metadata: ["tool": "test"])
        XCTAssertEqual(try db.fetchRows(samples: ["s1"]).count, 1)
        XCTAssertEqual(try db.fetchMetadata()["tool"], "test")
        XCTAssertNil(try db.fetchMetadata()["build_state"])
        XCTAssertEqual(try buildStateValue(at: dbURL), "complete")
    }

    func testOpenRejectsIncompleteBuildState() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let dbURL = dir.appendingPathComponent("building.sqlite")

        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(dbURL.path, &db), SQLITE_OK)
        defer { sqlite3_close(db) }
        XCTAssertEqual(sqlite3_exec(db, """
            CREATE TABLE lungfish_database_state (key TEXT PRIMARY KEY, value TEXT NOT NULL);
            INSERT INTO lungfish_database_state VALUES ('build_state', 'building');
            """, nil, nil, nil), SQLITE_OK)

        XCTAssertThrowsError(try EsVirituDatabase(at: dbURL)) { error in
            XCTAssertTrue(String(describing: error).contains("build_state"))
            XCTAssertTrue(String(describing: error).contains("building"))
        }
    }

    func testOpenAcceptsLegacyCompleteDatabaseWithoutBuildState() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let dbURL = dir.appendingPathComponent("legacy.sqlite")

        _ = try EsVirituDatabase.create(
            at: dbURL,
            rows: [makeTestRow(
                sample: "legacy",
                virusName: "Legacy",
                accession: "ACC_LEGACY",
                assembly: "ASM_LEGACY",
                readCount: 10
            )],
            metadata: ["source": "legacy"]
        )
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open_v2(dbURL.path, &db, SQLITE_OPEN_READWRITE, nil), SQLITE_OK)
        defer { sqlite3_close(db) }
        XCTAssertEqual(sqlite3_exec(db, "DROP TABLE lungfish_database_state", nil, nil, nil), SQLITE_OK)
        sqlite3_close(db)
        db = nil

        let reopened = try EsVirituDatabase(at: dbURL)
        let rows = try reopened.fetchRows(samples: ["legacy"])
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows.first?.virusName, "Legacy")
        XCTAssertNil(try buildStateValue(at: dbURL))
    }

    func testFailedCreatePreservesExistingDatabase() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let dbURL = dir.appendingPathComponent("test.sqlite")

        _ = try EsVirituDatabase.create(
            at: dbURL,
            rows: [makeTestRow(
                sample: "original",
                virusName: "Original",
                accession: "ACC_ORIG",
                assembly: "ASM_ORIG",
                readCount: 10
            )],
            metadata: [:]
        )

        let duplicates = [
            makeTestRow(
                sample: "replacement",
                virusName: "Virus A",
                accession: "ACC_DUP",
                assembly: "ASM_DUP",
                readCount: 10
            ),
            makeTestRow(
                sample: "replacement",
                virusName: "Virus B",
                accession: "ACC_DUP",
                assembly: "ASM_DUP",
                readCount: 20
            ),
        ]
        XCTAssertThrowsError(try EsVirituDatabase.create(at: dbURL, rows: duplicates, metadata: [:]))

        let reopened = try EsVirituDatabase(at: dbURL)
        let rows = try reopened.fetchRows(samples: ["original"])
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows.first?.virusName, "Original")
    }

    func testFetchRowsFiltersBySample() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let dbURL = dir.appendingPathComponent("test.sqlite")

        let rows = [
            makeTestRow(sample: "s1", virusName: "Virus A", accession: "ACC001", assembly: "ASM001", readCount: 100),
            makeTestRow(sample: "s2", virusName: "Virus B", accession: "ACC002", assembly: "ASM002", readCount: 200),
            makeTestRow(sample: "s3", virusName: "Virus C", accession: "ACC003", assembly: "ASM003", readCount: 300),
        ]
        let db = try EsVirituDatabase.create(at: dbURL, rows: rows, metadata: [:])

        let s1Only = try db.fetchRows(samples: ["s1"])
        XCTAssertEqual(s1Only.count, 1)
        XCTAssertEqual(s1Only[0].virusName, "Virus A")

        let s1s2 = try db.fetchRows(samples: ["s1", "s2"])
        XCTAssertEqual(s1s2.count, 2)

        let all = try db.fetchRows(samples: ["s1", "s2", "s3"])
        XCTAssertEqual(all.count, 3)
    }

    func testFetchSamples() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let dbURL = dir.appendingPathComponent("test.sqlite")

        let rows = [
            makeTestRow(sample: "s1", virusName: "Virus A", accession: "ACC001", assembly: "ASM001", readCount: 100),
            makeTestRow(sample: "s1", virusName: "Virus B", accession: "ACC002", assembly: "ASM002", readCount: 200),
            makeTestRow(sample: "s2", virusName: "Virus A", accession: "ACC003", assembly: "ASM003", readCount: 300),
        ]
        let db = try EsVirituDatabase.create(at: dbURL, rows: rows, metadata: [:])

        let samples = try db.fetchSamples()
        XCTAssertEqual(samples.count, 2)
        let s1 = samples.first { $0.sample == "s1" }
        XCTAssertEqual(s1?.detectionCount, 2)
    }

    func testMetadataRoundTrip() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let dbURL = dir.appendingPathComponent("test.sqlite")

        let db = try EsVirituDatabase.create(at: dbURL, rows: [], metadata: [
            "tool_version": "2.1.0",
            "created_at": "2026-04-07",
        ])
        let meta = try db.fetchMetadata()
        XCTAssertEqual(meta["tool_version"], "2.1.0")
        XCTAssertEqual(meta["created_at"], "2026-04-07")
    }

    func testUniqueReadsStored() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let dbURL = dir.appendingPathComponent("test.sqlite")

        let row = makeTestRow(sample: "s1", virusName: "SARS-CoV-2", accession: "NC_045512.2",
                              assembly: "GCF_009858895.2", readCount: 500, uniqueReads: 420)
        let db = try EsVirituDatabase.create(at: dbURL, rows: [row], metadata: [:])
        let fetched = try db.fetchRows(samples: ["s1"])
        XCTAssertEqual(fetched[0].uniqueReads, 420)
    }

    func testBAMPathStored() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let dbURL = dir.appendingPathComponent("test.sqlite")

        let row = makeTestRow(sample: "s1", virusName: "SARS-CoV-2", accession: "NC_045512.2",
                              assembly: "GCF_009858895.2", readCount: 500,
                              bamPath: "/path/to/sample.bam", bamIndexPath: "/path/to/sample.bam.csi")
        let db = try EsVirituDatabase.create(at: dbURL, rows: [row], metadata: [:])
        let fetched = try db.fetchRows(samples: ["s1"])
        XCTAssertEqual(fetched[0].bamPath, "/path/to/sample.bam")
        XCTAssertEqual(fetched[0].bamIndexPath, "/path/to/sample.bam.csi")
    }

    func testEmptyDatabase() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let dbURL = dir.appendingPathComponent("test.sqlite")

        let db = try EsVirituDatabase.create(at: dbURL, rows: [], metadata: [:])
        XCTAssertEqual(try db.fetchRows(samples: []).count, 0)
        XCTAssertEqual(try db.fetchSamples().count, 0)
    }

    // MARK: - Coverage Windows

    func testCoverageWindowsRoundTrip() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let dbURL = dir.appendingPathComponent("test.sqlite")

        let rows = [makeTestRow(sample: "s1", virusName: "Virus A",
                                accession: "NC_001", assembly: "GCA_001", readCount: 100)]
        let windows = [
            EsVirituCoverageWindow(sample: "s1", accession: "NC_001",
                                   windowIndex: 0, windowStart: 0, windowEnd: 100, averageCoverage: 5.0),
            EsVirituCoverageWindow(sample: "s1", accession: "NC_001",
                                   windowIndex: 1, windowStart: 100, windowEnd: 200, averageCoverage: 12.5),
        ]
        let db = try EsVirituDatabase.create(at: dbURL, rows: rows, coverageWindows: windows, metadata: [:])

        let fetched = try db.fetchCoverageWindows(sample: "s1", accession: "NC_001")
        XCTAssertEqual(fetched.count, 2)
        XCTAssertEqual(fetched[0].windowIndex, 0)
        XCTAssertEqual(fetched[0].averageCoverage, 5.0, accuracy: 0.01)
        XCTAssertEqual(fetched[1].windowStart, 100)
    }

    func testCoverageWindowsEmptyForMissingSample() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let dbURL = dir.appendingPathComponent("test.sqlite")

        let db = try EsVirituDatabase.create(at: dbURL, rows: [], coverageWindows: [], metadata: [:])
        let fetched = try db.fetchCoverageWindows(sample: "nonexistent", accession: "NC_001")
        XCTAssertEqual(fetched.count, 0)
    }

    // MARK: - Helpers

    private func makeTestRow(
        sample: String,
        virusName: String,
        accession: String,
        assembly: String,
        readCount: Int,
        uniqueReads: Int? = nil,
        bamPath: String? = nil,
        bamIndexPath: String? = nil
    ) -> EsVirituDetectionRow {
        EsVirituDetectionRow(
            sample: sample,
            virusName: virusName,
            description: nil,
            contigLength: nil,
            segment: nil,
            accession: accession,
            assembly: assembly,
            assemblyLength: nil,
            kingdom: nil,
            phylum: nil,
            tclass: nil,
            torder: nil,
            family: nil,
            genus: nil,
            species: nil,
            subspecies: nil,
            rpkmf: nil,
            readCount: readCount,
            uniqueReads: uniqueReads,
            coveredBases: nil,
            meanCoverage: nil,
            avgReadIdentity: nil,
            pi: nil,
            filteredReadsInSample: nil,
            bamPath: bamPath,
            bamIndexPath: bamIndexPath
        )
    }
}
