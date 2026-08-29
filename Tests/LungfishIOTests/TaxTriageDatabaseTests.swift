// TaxTriageDatabaseTests.swift - Unit tests for TaxTriageDatabase
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
import SQLite3
@testable import LungfishIO

final class TaxTriageDatabaseTests: XCTestCase {
    private func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("TaxTriageDatabaseTests-\(UUID().uuidString)")
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

        let rows = [makeTestRow(sample: "s1", organism: "Virus A", tassScore: 0.95, readsAligned: 100)]
        let db = try TaxTriageDatabase.create(at: dbURL, rows: rows, metadata: ["tool": "test"])
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

        XCTAssertThrowsError(try TaxTriageDatabase(at: dbURL)) { error in
            XCTAssertTrue(String(describing: error).contains("build_state"))
            XCTAssertTrue(String(describing: error).contains("building"))
        }
    }

    func testOpenAcceptsLegacyCompleteDatabaseWithoutBuildState() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let dbURL = dir.appendingPathComponent("legacy.sqlite")

        _ = try TaxTriageDatabase.create(
            at: dbURL,
            rows: [makeTestRow(
                sample: "legacy",
                organism: "Legacy",
                tassScore: 0.95,
                readsAligned: 10
            )],
            metadata: ["source": "legacy"]
        )
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open_v2(dbURL.path, &db, SQLITE_OPEN_READWRITE, nil), SQLITE_OK)
        defer { sqlite3_close(db) }
        XCTAssertEqual(sqlite3_exec(db, "DROP TABLE lungfish_database_state", nil, nil, nil), SQLITE_OK)
        sqlite3_close(db)
        db = nil

        let reopened = try TaxTriageDatabase(at: dbURL)
        let rows = try reopened.fetchRows(samples: ["legacy"])
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows.first?.organism, "Legacy")
        XCTAssertNil(try buildStateValue(at: dbURL))
    }

    func testFailedCreatePreservesExistingDatabase() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let dbURL = dir.appendingPathComponent("test.sqlite")

        _ = try TaxTriageDatabase.create(
            at: dbURL,
            rows: [makeTestRow(
                sample: "original",
                organism: "Original",
                tassScore: 0.95,
                readsAligned: 10
            )],
            metadata: [:]
        )

        let duplicates = [
            makeTestRow(sample: "replacement", organism: "Virus", tassScore: 0.9, readsAligned: 10),
            makeTestRow(sample: "replacement", organism: "Virus", tassScore: 0.8, readsAligned: 20),
        ]
        XCTAssertThrowsError(try TaxTriageDatabase.create(at: dbURL, rows: duplicates, metadata: [:]))

        let reopened = try TaxTriageDatabase(at: dbURL)
        let rows = try reopened.fetchRows(samples: ["original"])
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows.first?.organism, "Original")
    }

    func testFetchRowsFiltersBySample() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let dbURL = dir.appendingPathComponent("test.sqlite")

        let rows = [
            makeTestRow(sample: "s1", organism: "Virus A", tassScore: 0.9, readsAligned: 100),
            makeTestRow(sample: "s2", organism: "Virus B", tassScore: 0.8, readsAligned: 200),
            makeTestRow(sample: "s3", organism: "Virus C", tassScore: 0.7, readsAligned: 300),
        ]
        let db = try TaxTriageDatabase.create(at: dbURL, rows: rows, metadata: [:])

        let s1Only = try db.fetchRows(samples: ["s1"])
        XCTAssertEqual(s1Only.count, 1)
        XCTAssertEqual(s1Only[0].organism, "Virus A")

        let s1s2 = try db.fetchRows(samples: ["s1", "s2"])
        XCTAssertEqual(s1s2.count, 2)

        let all = try db.fetchRows(samples: ["s1", "s2", "s3"])
        XCTAssertEqual(all.count, 3)
    }

    func testFetchRowsPageUsesLimitOffsetAndSearchWithoutLoadingEverything() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let dbURL = dir.appendingPathComponent("test.sqlite")

        let rows: [TaxTriageTaxonomyRow] = (0..<8).map { index in
            makeTestRow(
                sample: index < 5 ? "s1" : "s2",
                organism: index == 6 ? "Target virus" : "Virus \(index)",
                tassScore: Double(index) / 10.0,
                readsAligned: 100 + index
            )
        }
        let db = try TaxTriageDatabase.create(at: dbURL, rows: rows, metadata: [:])

        let page = try db.fetchRowsPage(samples: ["s1", "s2"], limit: 3, offset: 2)

        XCTAssertEqual(page.totalMatchingRows, 8)
        XCTAssertEqual(page.rows.count, 3)
        XCTAssertEqual(page.rows.map { $0.organism }, ["Virus 2", "Virus 3", "Virus 4"])

        let filtered = try db.fetchRowsPage(
            samples: ["s1", "s2"],
            limit: 10,
            offset: 0,
            organismSearchText: "target"
        )

        XCTAssertEqual(filtered.totalMatchingRows, 1)
        XCTAssertEqual(filtered.rows.map { $0.organism }, ["Target virus"])
    }

    func testFetchSamples() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let dbURL = dir.appendingPathComponent("test.sqlite")

        let rows = [
            makeTestRow(sample: "s1", organism: "A", tassScore: 0.9, readsAligned: 100),
            makeTestRow(sample: "s1", organism: "B", tassScore: 0.8, readsAligned: 200),
            makeTestRow(sample: "s2", organism: "A", tassScore: 0.7, readsAligned: 300),
        ]
        let db = try TaxTriageDatabase.create(at: dbURL, rows: rows, metadata: [:])

        let samples = try db.fetchSamples()
        XCTAssertEqual(samples.count, 2)
        let s1 = samples.first { $0.sample == "s1" }
        XCTAssertEqual(s1?.organismCount, 2)
    }

    func testMetadataRoundTrip() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let dbURL = dir.appendingPathComponent("test.sqlite")

        let db = try TaxTriageDatabase.create(at: dbURL, rows: [], metadata: [
            "tool_version": "1.2.3",
            "created_at": "2026-04-07",
        ])
        let meta = try db.fetchMetadata()
        XCTAssertEqual(meta["tool_version"], "1.2.3")
        XCTAssertEqual(meta["created_at"], "2026-04-07")
    }

    func testUniqueReadsStored() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let dbURL = dir.appendingPathComponent("test.sqlite")

        let row = makeTestRow(sample: "s1", organism: "V", tassScore: 1.0, readsAligned: 500, uniqueReads: 350)
        let db = try TaxTriageDatabase.create(at: dbURL, rows: [row], metadata: [:])
        let fetched = try db.fetchRows(samples: ["s1"])
        XCTAssertEqual(fetched[0].uniqueReads, 350)
    }

    func testBAMPathStored() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let dbURL = dir.appendingPathComponent("test.sqlite")

        let row = makeTestRow(sample: "s1", organism: "V", tassScore: 1.0, readsAligned: 500,
                              bamPath: "/path/to/sample.bam", bamIndexPath: "/path/to/sample.bam.csi",
                              primaryAccession: "NC_045512.2", accessionLength: 29903)
        let db = try TaxTriageDatabase.create(at: dbURL, rows: [row], metadata: [:])
        let fetched = try db.fetchRows(samples: ["s1"])
        XCTAssertEqual(fetched[0].bamPath, "/path/to/sample.bam")
        XCTAssertEqual(fetched[0].bamIndexPath, "/path/to/sample.bam.csi")
        XCTAssertEqual(fetched[0].primaryAccession, "NC_045512.2")
        XCTAssertEqual(fetched[0].accessionLength, 29903)
    }

    func testEmptyDatabase() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let dbURL = dir.appendingPathComponent("test.sqlite")

        let db = try TaxTriageDatabase.create(at: dbURL, rows: [], metadata: [:])
        XCTAssertEqual(try db.fetchRows(samples: []).count, 0)
        XCTAssertEqual(try db.fetchSamples().count, 0)
    }

    func testAccessionMapRoundTrip() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let dbURL = dir.appendingPathComponent("test.sqlite")

        let rows = [makeTestRow(sample: "s1", organism: "Influenza A", tassScore: 0.9, readsAligned: 100,
                                primaryAccession: "NC_004905.2")]
        let accessionMap = [
            TaxTriageAccessionEntry(sample: "s1", organism: "Influenza A",
                                    accession: "NC_004905.2", description: "segment 5"),
            TaxTriageAccessionEntry(sample: "s1", organism: "Influenza A",
                                    accession: "NC_004906.1", description: "segment 8"),
            TaxTriageAccessionEntry(sample: "s1", organism: "Influenza A",
                                    accession: "NC_004907.1", description: "segment 7"),
        ]
        let db = try TaxTriageDatabase.create(at: dbURL, rows: rows, accessionMap: accessionMap, metadata: [:])

        let accessions = try db.fetchAccessions(sample: "s1", organism: "Influenza A")
        XCTAssertEqual(accessions.count, 3)
        XCTAssertTrue(accessions.contains { $0.accession == "NC_004905.2" })
        XCTAssertTrue(accessions.contains { $0.accession == "NC_004906.1" })
        XCTAssertEqual(accessions.first { $0.accession == "NC_004905.2" }?.description, "segment 5")
    }

    func testAccessionMapEmptyForUnknownOrganism() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let dbURL = dir.appendingPathComponent("test.sqlite")

        let db = try TaxTriageDatabase.create(at: dbURL, rows: [], accessionMap: [], metadata: [:])
        let accessions = try db.fetchAccessions(sample: "s1", organism: "Unknown")
        XCTAssertEqual(accessions.count, 0)
    }

    // MARK: - Helpers

    private func makeTestRow(
        sample: String, organism: String, tassScore: Double, readsAligned: Int,
        uniqueReads: Int? = nil, bamPath: String? = nil, bamIndexPath: String? = nil,
        primaryAccession: String? = nil, accessionLength: Int? = nil
    ) -> TaxTriageTaxonomyRow {
        TaxTriageTaxonomyRow(
            sample: sample, organism: organism, taxId: nil, status: nil,
            tassScore: tassScore, readsAligned: readsAligned, uniqueReads: uniqueReads,
            pctReads: nil, pctAlignedReads: nil, coverageBreadth: nil,
            meanCoverage: nil, meanDepth: nil, confidence: nil,
            k2Reads: nil, parentK2Reads: nil, giniCoefficient: nil,
            meanBaseQ: nil, meanMapQ: nil, mapqScore: nil,
            disparityScore: nil, minhashScore: nil, diamondIdentity: nil,
            k2DisparityScore: nil, siblingsScore: nil, breadthWeightScore: nil,
            hhsPercentile: nil, isAnnotated: nil, annClass: nil,
            microbialCategory: nil, highConsequence: nil, isSpecies: nil,
            pathogenicSubstrains: nil, sampleType: nil,
            bamPath: bamPath, bamIndexPath: bamIndexPath,
            primaryAccession: primaryAccession, accessionLength: accessionLength
        )
    }
}
