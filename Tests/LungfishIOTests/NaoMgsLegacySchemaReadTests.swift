// NaoMgsLegacySchemaReadTests.swift - A NAO-MGS database from before 2026-09-23 reads by taxon
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// A result imported before 2026-09-23 (commit 6538d8d39) has no `reference_length_source`
// column in `accession_summaries`, because only `NaoMgsDatabase.openReadWrite` adds it. The
// read-only open leaves that shape alone, so `fetchAccessionSummaries` used to throw on it and
// an extraction by taxon found nothing without saying why (R4, BIO 4).

import XCTest
import SQLite3
import LungfishTestSupport
@testable import LungfishIO

final class NaoMgsLegacySchemaReadTests: XCTestCase {

    private var tempDir: URL!

    override func setUp() async throws {
        try await super.setUp()
        tempDir = try TestTempDirectory.make(prefix: "naomgs-legacy-schema")
    }

    override func tearDown() async throws {
        if let dir = tempDir {
            TestTempDirectory.cleanup(dir)
        }
        try await super.tearDown()
    }

    // MARK: - Legacy shape

    /// The pin. Rows of a database that never ran the read-write migration read as the default
    /// that migration writes, in the same order as a migrated database.
    func testAnAccessionSummaryWithoutTheSourceColumnReadsAsAlignmentExtent() throws {
        let url = try makeDatabase(withSourceColumn: false)
        XCTAssertFalse(try hasSourceColumn(url), "The fixture must have the shape of an import before 2026-09-23")

        let database = try NaoMgsDatabase(at: url)
        let summaries = try database.fetchAccessionSummaries(sample: "test_sample", taxId: 11137)

        XCTAssertEqual(summaries.map(\.accession), ["AF304460.1", "KT253324.1"])
        XCTAssertEqual(summaries.map(\.referenceLengthSource), [.alignmentExtent, .alignmentExtent])
        XCTAssertEqual(summaries.map(\.readCount), [3, 2])
        XCTAssertEqual(summaries.map(\.uniqueReadCount), [3, 2])
        XCTAssertEqual(summaries.map(\.referenceLength), [1000, 1000])
        XCTAssertEqual(summaries.map(\.coveredBasePairs), [294, 196])
    }

    /// A taxon that has no rows reads as an empty list on the legacy shape, as on the current one.
    func testALegacyDatabaseReadsNoAccessionsForAnUnknownTaxon() throws {
        let database = try NaoMgsDatabase(at: try makeDatabase(withSourceColumn: false))
        XCTAssertEqual(try database.fetchAccessionSummaries(sample: "test_sample", taxId: 999_999).count, 0)
    }

    /// The read-write open adds the column, and a handle opened after it reads the same rows.
    func testALegacyDatabaseReadsTheSameRowsAfterTheReadWriteMigration() throws {
        let url = try makeDatabase(withSourceColumn: false)
        _ = try NaoMgsDatabase.openReadWrite(at: url)
        XCTAssertTrue(try hasSourceColumn(url), "openReadWrite adds the column")

        let summaries = try NaoMgsDatabase(at: url).fetchAccessionSummaries(sample: "test_sample", taxId: 11137)

        XCTAssertEqual(summaries.map(\.accession), ["AF304460.1", "KT253324.1"])
        XCTAssertEqual(summaries.map(\.referenceLengthSource), [.alignmentExtent, .alignmentExtent])
    }

    // MARK: - Current shape

    /// With the column present the stored value is read, so a length from a reference stays `fasta`.
    func testAnAccessionSummaryWithTheSourceColumnReadsItsStoredValue() throws {
        let url = try makeDatabase(
            withSourceColumn: true,
            extraSQL: "UPDATE accession_summaries SET reference_length_source = 'fasta' WHERE accession = 'KT253324.1';"
        )
        XCTAssertTrue(try hasSourceColumn(url))

        let database = try NaoMgsDatabase(at: url)
        let summaries = try database.fetchAccessionSummaries(sample: "test_sample", taxId: 11137)

        XCTAssertEqual(summaries.map(\.accession), ["AF304460.1", "KT253324.1"])
        XCTAssertEqual(summaries.map(\.referenceLengthSource), [.alignmentExtent, .fasta])
    }

    // MARK: - Helpers

    /// Builds the schema `createSchema` writes today with three accession rows (two for tax ID 11137,
    /// one for 694009) under sample "test_sample". Without the source column it has the shape of a
    /// database imported before 2026-09-23.
    private func makeDatabase(withSourceColumn: Bool, extraSQL: String = "") throws -> URL {
        let url = tempDir.appendingPathComponent(withSourceColumn ? "current.sqlite" : "legacy.sqlite")
        var handle: OpaquePointer?
        guard sqlite3_open(url.path, &handle) == SQLITE_OK, let db = handle else {
            throw fixtureError("Failed to create the fixture database", db: handle)
        }
        defer { sqlite3_close(db) }

        try NaoMgsDatabase.createSchema(db: db)
        try NaoMgsDatabase.createIndices(db: db)
        if !withSourceColumn {
            try execute(db, "ALTER TABLE accession_summaries DROP COLUMN reference_length_source")
        }
        try execute(db, """
        INSERT INTO accession_summaries
            (sample, tax_id, accession, read_count, unique_read_count, reference_length, covered_base_pairs, coverage_fraction)
        VALUES ('test_sample', 11137, 'AF304460.1', 3, 3, 1000, 294, 0.294),
               ('test_sample', 11137, 'KT253324.1', 2, 2, 1000, 196, 0.196),
               ('test_sample', 694009, 'NC_009539.1', 3, 3, 1000, 294, 0.294);
        \(extraSQL)
        """)
        try ClassifierSQLiteDatabaseSupport.markBuildState(ClassifierSQLiteDatabaseSupport.buildStateComplete, db: db)
        return url
    }

    private func hasSourceColumn(_ url: URL) throws -> Bool {
        var handle: OpaquePointer?
        guard sqlite3_open_v2(url.path, &handle, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let db = handle else {
            throw fixtureError("Failed to open the fixture database", db: handle)
        }
        defer { sqlite3_close(db) }

        let sql = "SELECT COUNT(*) FROM pragma_table_info('accession_summaries') WHERE name = 'reference_length_source'"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw fixtureError("Failed to inspect the fixture database", db: db)
        }
        defer { sqlite3_finalize(stmt) }
        return sqlite3_step(stmt) == SQLITE_ROW && sqlite3_column_int(stmt, 0) == 1
    }

    private func execute(_ db: OpaquePointer, _ sql: String) throws {
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else {
            throw fixtureError("Fixture statement failed", db: db)
        }
    }

    private func fixtureError(_ message: String, db: OpaquePointer?) -> NSError {
        let detail = db.map { String(cString: sqlite3_errmsg($0)) } ?? "no handle"
        return NSError(domain: "NaoMgsLegacySchemaReadTests", code: 1, userInfo: [
            NSLocalizedDescriptionKey: "\(message) (\(detail))",
        ])
    }
}
