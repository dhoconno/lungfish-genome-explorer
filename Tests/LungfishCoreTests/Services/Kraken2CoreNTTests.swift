// Kraken2CoreNTTests.swift - Kraken 2's Verify with BLAST searches core_nt, as every other route does
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import XCTest
@testable import LungfishCore

/// Phase 3.2 lane KRAKENCORE (BIO-BLAST-DATABASES items 2, 5 and 6, row BLAST-KRAKEN2-NT). Kraken 2 sent `nt` because the
/// request builders at `BlastService+Sources.swift` passed no database and the shared default is `nt`. NCBI answers `nt` with
/// `core_nt`, so the caption and the record named a database that was not searched. These tests build the request with the two
/// builders the app's Kraken 2 route reads (the read-ID lookup and the scan) from a small recorded fixture. No search is sent.
final class Kraken2CoreNTTests: XCTestCase {
    static let taxId = 562

    /// The requests of the read-ID lookup and the scan for a two-read fixture, in that order.
    static func requests() async throws -> [BlastVerificationRequest] {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("kraken2-core-nt-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        func record(_ name: String) -> String {
            let sequence = String(repeating: "ACGT", count: 8)
            return "@\(name)\n\(sequence)\n+\n\(String(repeating: "I", count: sequence.count))\n"
        }
        let reads = directory.appendingPathComponent("sample.fastq")
        try (record("r1") + record("r2")).write(to: reads, atomically: true, encoding: .utf8)
        let kraken = directory.appendingPathComponent("classification.kraken")
        try "C\tr1\t\(taxId)\t32\t\(taxId):28\nC\tr2\t\(taxId)\t32\t\(taxId):28\n".write(to: kraken, atomically: true, encoding: .utf8)

        let service = BlastService(httpClient: BlastRecordingClient())
        let sources = [BlastReadSource(url: reads)]
        let indexed = try await service.buildVerificationRequestFromReadIds(
            taxonName: "Escherichia coli", taxId: taxId, matchingReadIds: ["r1", "r2"], sources: sources, readCount: 10,
            targetTaxIds: [taxId], classificationOutputURL: kraken
        )
        let scanned = try await service.buildVerificationRequest(
            taxonName: "Escherichia coli", taxId: taxId, targetTaxIds: [taxId], classificationOutputURL: kraken,
            sources: sources, readCount: 10
        )
        return [indexed, scanned]
    }

    /// BIO R1. Both builders of the Kraken 2 route ask for `core_nt`, the database NCBI searches for `nt`.
    func testKraken2VerifyRequestSearchesCoreNT() async throws {
        let built = try await Self.requests()
        XCTAssertEqual(built.count, 2)
        for request in built {
            XCTAssertEqual(request.sequences.count, 2, "the fixture's two reads are drawn")
            XCTAssertEqual(request.database, BlastDatabaseID.coreNT.rawValue)
        }
    }

    /// BIO R2. A record a Kraken 2 search saved before the move keeps `nt`, its verdict and its badge when it is read now.
    /// It passes at the base by design, since it guards the move.
    func testAKraken2RecordThatSearchedNtKeepsItsDatabaseAndBadge() throws {
        let supporting = (1...3).map { BlastReadResult(id: "read_\($0)", verdict: .verified, matchesQueriedTaxon: true) }
        let saved = BlastVerificationResult(
            taxonName: "Escherichia coli", taxId: Self.taxId, readResults: supporting, submittedAt: Date(timeIntervalSince1970: 1_700_000_000),
            completedAt: Date(timeIntervalSince1970: 1_700_000_060), rid: "OLD1", blastProgram: "blastn", database: "nt",
            databaseSequenceCount: 132_357_636
        )
        let read = try JSONDecoder().decode(BlastVerificationResult.self, from: JSONEncoder().encode(saved))
        XCTAssertEqual(read.database, "nt")
        XCTAssertEqual(read.confidence, saved.confidence)
        XCTAssertEqual(read.confidence, .supported)
        XCTAssertEqual(read.databaseSequenceCount, 132_357_636)
        let reread = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(read)) as? [String: Any])
        XCTAssertNil(reread["reportedDatabase"], "a record from before the fields names no reported database")
        XCTAssertNil(reread["blastVersion"], "and no program version")
    }
}
