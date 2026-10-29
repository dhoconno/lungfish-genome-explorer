// TaxTriageDatabaseIdentityRecordTests.swift - The TaxTriage record names its Kraken 2 database by the install receipt
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// DB-IDENTITY, Phase 3.1, BIO-DB-IDENTITY sections 3 and 5. A TaxTriage record cites the payload digest of its Kraken 2
// database's install receipt when that receipt adds up to its own digest, and says `unpinned` with a note when it does
// not. TaxTriage fetches its references from NCBI during a run, so its record also names that fetch as a live snapshot.
// The receipts here are the ones `Kraken2DatabaseReceiptTests` writes, which are laid out as an install writes them.

import XCTest
import LungfishTestSupport
@testable import LungfishWorkflow

final class TaxTriageDatabaseIdentityRecordTests: XCTestCase {

    private var root: URL!

    override func setUpWithError() throws {
        root = try TestTempDirectory.make(prefix: "taxtriage-database-identity").resolvingSymlinksInPath()
    }

    override func tearDown() {
        TestTempDirectory.cleanup(root)
    }

    private func makeDatabase() throws -> URL {
        let database = root.appendingPathComponent("kraken2-viral", isDirectory: true)
        try Kraken2DatabaseReceiptTests.writeDatabaseFiles(in: database)
        return database
    }

    /// A receipt that adds up gives the digest, the status `pinned` and the version the receipt names, and the save
    /// files the digest among the record's resolved defaults.
    func testTaxTriageRecordCitesKraken2ReceiptDigest() throws {
        let database = try makeDatabase()
        let receipt = try Kraken2DatabaseReceiptTests.writeReceipt(in: database)

        let identity = TaxTriageRecordFacts.databaseIdentity(at: database)

        XCTAssertEqual(identity["databaseDigest"], .string(receipt.digest))
        XCTAssertEqual(identity["databaseIdentityStatus"], .string("pinned"))
        XCTAssertEqual(identity["databaseCatalogVersion"], .string("2026.1"), "the receipt's workflow version")
        XCTAssertNil(identity["databaseIdentityNote"], "a receipt that adds up needs no note")
        XCTAssertEqual(
            TaxTriageRecordFacts.recordOptions(fromRunParameters: identity).resolvedDefaults["databaseDigest"],
            .string(receipt.digest),
            "the save files the digest among the resolved defaults"
        )
    }

    /// A receipt that does not add up to its own digest records no digest and says why. A database with no receipt at
    /// all says `unpinned` and nothing more, as before.
    func testTaxTriageRecordRefusesReceiptThatDoesNotAddUp() throws {
        let database = try makeDatabase()
        try Kraken2DatabaseReceiptTests.writeReceipt(in: database) { $0.aggregate = String(repeating: "0", count: 64) }

        let refused = TaxTriageRecordFacts.databaseIdentity(at: database)

        XCTAssertEqual(refused["databaseIdentityStatus"], .string("unpinned"))
        XCTAssertNil(refused["databaseDigest"])
        XCTAssertEqual(
            refused["databaseIdentityNote"],
            .string(
                "The install receipt in \(database.standardizedFileURL.path) does not add up to its own digest, "
                    + "so this run records no digest."
            )
        )

        try FileManager.default.removeItem(at: database.appendingPathComponent(ProvenanceWriter.provenanceFilename))
        let bare = TaxTriageRecordFacts.databaseIdentity(at: database)
        XCTAssertEqual(bare["databaseIdentityStatus"], .string("unpinned"))
        XCTAssertNil(bare["databaseDigest"])
        XCTAssertNil(bare["databaseIdentityNote"], "no receipt, no note")
    }

    /// The references TaxTriage fetched from NCBI are a live snapshot. The entry names the run's start as the fetch date
    /// and the kept `combine/<sample>.combined.gcfmap.tsv` of each sample as the files that list them.
    func testTaxTriageRecordNamesFetchedReferencesAsLiveSnapshot() throws {
        let output = root.appendingPathComponent("taxtriage-out", isDirectory: true)
        let reads = root.appendingPathComponent("reads", isDirectory: true)
        let samples = ["S1", "S2"].map { TaxTriageSample(sampleId: $0, fastq1: reads.appendingPathComponent("\($0).fastq")) }

        let facts = TaxTriageRecordFacts(config: TaxTriageConfig(samples: samples, outputDirectory: output))

        guard case .dictionary(let entry)? = facts.resolvedDefaults["fetchedReferences"] else {
            return XCTFail("the record names no fetchedReferences entry")
        }
        XCTAssertEqual(entry["status"], .string("liveSnapshot"))
        XCTAssertEqual(
            entry["listingFiles"],
            .array(["S1", "S2"].map { .file(output.appendingPathComponent("combine/\($0).combined.gcfmap.tsv")) })
        )
        let fetchedAt = try XCTUnwrap(entry["fetchedAt"]?.stringValue, "the entry names the date of the fetch")
        let date = try XCTUnwrap(ISO8601DateFormatter().date(from: fetchedAt))
        XCTAssertLessThan(abs(date.timeIntervalSinceNow), 120, "the run's start")
        XCTAssertTrue(TaxTriageRecordFacts.resolvedDefaultKeys.contains("fetchedReferences"))
        XCTAssertNotNil(
            TaxTriageRecordFacts.recordOptions(fromRunParameters: facts.runParameters).resolvedDefaults["fetchedReferences"],
            "the save files the entry among the resolved defaults"
        )
    }

    /// A step records the database as a reference input, with the receipt's aggregate as its checksum. A receipt that
    /// does not add up, and a run that names no database, add none.
    func testTaxTriageStepInputsCiteTheDatabaseReference() throws {
        let database = try makeDatabase()
        let receipt = try Kraken2DatabaseReceiptTests.writeReceipt(in: database)

        let records = TaxTriageRecordFacts.databaseReferenceRecords(at: database)

        XCTAssertEqual(records.count, 1)
        let reference = try XCTUnwrap(records.first)
        XCTAssertEqual(reference.role, .reference)
        XCTAssertEqual(reference.sha256, receipt.digest)
        XCTAssertEqual(reference.path, database.standardizedFileURL.path)
        try Kraken2DatabaseReceiptTests.writeReceipt(in: database) { $0.aggregate = String(repeating: "0", count: 64) }
        XCTAssertTrue(TaxTriageRecordFacts.databaseReferenceRecords(at: database).isEmpty, "a receipt that does not add up")
        XCTAssertTrue(TaxTriageRecordFacts.databaseReferenceRecords(at: nil).isEmpty)
    }
}
