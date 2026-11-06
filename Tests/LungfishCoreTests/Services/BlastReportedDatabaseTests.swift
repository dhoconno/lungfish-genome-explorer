// BlastReportedDatabaseTests.swift - The record keeps the database and version NCBI reports
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import XCTest
@testable import LungfishCore

/// Phase 3.2 lane KRAKENCORE (BIO-BLAST-DATABASES item 7, ARCH-BLAST-SEAM item 11, review row R4). NCBI answers a search for `nt`
/// with `core_nt`, and its reply says so in `report.search_target.db` and `report.version`. The result keeps both beside the
/// database the search asked for, inside the record's `result` and never as a new top-level key of the record. These tests read the
/// reply from a recorded string and send nothing. They read the keys from the encoded record, so a build without the fields fails
/// them at run time.
final class BlastReportedDatabaseTests: XCTestCase {
    private let service = BlastService()

    /// A one-read JSON2 reply. `report` holds the two facts when they are given, and a reply that names neither is what an older
    /// server sent.
    static func reply(database: String?, version: String?) -> Data {
        let facts = (version.map { #""version":"\#($0)","# } ?? "") + (database.map { #""search_target":{"db":"\#($0)"},"# } ?? "")
        let json = """
        {"BlastOutput2":[{"report":{\(facts)"results":{"search":{"query_title":"r1","query_len":32,"hits":[
          {"description":[{"accession":"NZ_1","title":"t","sciname":"Escherichia coli","taxid":562}],
           "hsps":[{"bit_score":58.0,"evalue":1e-10,"identity":32,"align_len":32,"query_from":1,"query_to":32}]}
        ],"stat":{"db_num":132357636}}}}}]}
        """
        return Data(json.utf8)
    }

    static func request(asking database: String) -> BlastVerificationRequest {
        BlastVerificationRequest(
            taxonName: "Escherichia coli", taxId: 562,
            sequences: [(id: "r1", sequence: String(repeating: "ACGT", count: 8))], database: database
        )
    }

    private func result(asking database: String, reply: Data) throws -> BlastVerificationResult {
        try service.buildVerificationResult(
            request: Self.request(asking: database), searchResults: try service.parseJSON2Results(reply), rid: "RID1",
            submittedAt: Date(timeIntervalSince1970: 1_800_000_000), completedAt: Date(timeIntervalSince1970: 1_800_000_060)
        )
    }

    /// The record the search saves for `result`, as the JSON object its file holds.
    private func recordObject(_ result: BlastVerificationResult, asking database: String) throws -> [String: Any] {
        let record = BlastSubmissionRecord(
            savedAt: Date(timeIntervalSince1970: 1_800_000_100),
            query: BlastSubmissionRecord.Query(fileName: BlastSubmissionRecord.queryFileName, sha256: "x", sequenceCount: 1),
            lineage: BlastSubmissionRecord.Lineage(), search: BlastSubmissionRecord.Search(Self.request(asking: database)), result: result
        )
        let data = try BlastSubmissionRecord.encoder.encode(record)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    /// BIO R4. A search sent as `nt` that NCBI ran on `core_nt` keeps both names and the program version inside the result, and
    /// the record keeps its six top-level keys and its schema version.
    func testTheRecordKeepsTheDatabaseAndVersionNCBIReports() throws {
        let sent = try result(asking: "nt", reply: Self.reply(database: "core_nt", version: "BLASTN 2.17.0+"))
        let record = try recordObject(sent, asking: "nt")
        XCTAssertEqual(Set(record.keys), ["schemaVersion", "savedAt", "query", "lineage", "search", "result"], "no new top-level key")
        XCTAssertEqual(record["schemaVersion"] as? Int, BlastSubmissionRecord.currentSchemaVersion)
        let facts = try XCTUnwrap(record["result"] as? [String: Any])
        XCTAssertEqual(facts["database"] as? String, "nt", "the database the search asked for")
        XCTAssertEqual(facts["databaseSequenceCount"] as? Int, 132_357_636)
        XCTAssertEqual(facts["reportedDatabase"] as? String, "core_nt", "the database NCBI says it searched")
        XCTAssertEqual(facts["blastVersion"] as? String, "BLASTN 2.17.0+")
    }

    /// A reply that names neither fact leaves both keys out, as a record made before the fields has none. It passes at the base
    /// by design, since it guards the old shape.
    func testAReplyThatNamesNeitherLeavesBothOut() throws {
        let sent = try result(asking: "core_nt", reply: Self.reply(database: nil, version: nil))
        let facts = try XCTUnwrap(recordObject(sent, asking: "core_nt")["result"] as? [String: Any])
        XCTAssertNil(facts["reportedDatabase"])
        XCTAssertNil(facts["blastVersion"])
        XCTAssertEqual(facts["database"] as? String, "core_nt")
    }

    /// The words name the database NCBI searched only when it is not the one the search asked for. UX reads them at review.
    func testTheWordsNameTheDatabaseNCBISearchedOnlyWhenItDiffers() throws {
        let differs = try result(asking: "nt", reply: Self.reply(database: "core_nt", version: "BLASTN 2.17.0+"))
        XCTAssertEqual(differs.database, "nt")
        XCTAssertEqual(differs.reportedDatabase, "core_nt")
        XCTAssertEqual(differs.blastVersion, "BLASTN 2.17.0+")
        XCTAssertEqual(differs.reportedDatabaseWords, "NCBI searched core_nt, not the nt this search asked for.")

        let same = try result(asking: "core_nt", reply: Self.reply(database: "core_nt", version: "BLASTN 2.17.0+"))
        XCTAssertEqual(same.reportedDatabase, "core_nt")
        XCTAssertNil(same.reportedDatabaseWords, "the common case adds no words")

        let silent = try result(asking: "nt", reply: Self.reply(database: nil, version: nil))
        XCTAssertNil(silent.reportedDatabase)
        XCTAssertNil(silent.blastVersion)
        XCTAssertNil(silent.reportedDatabaseWords, "a reply that names no database adds none")

        let blank = try result(asking: "nt", reply: Self.reply(database: "  ", version: ""))
        XCTAssertNil(blank.reportedDatabase, "a blank name is no name")
        XCTAssertNil(blank.blastVersion)
    }
}
