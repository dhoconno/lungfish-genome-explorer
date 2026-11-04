// BlastSearchFileFactsTests.swift - A resume judges and records a reply as the first process would have
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Lane BLASTCOLLECT, BIO review 2 blocker B1. `blast resume` rebuilds its request from the search file's facts, so the
// facts have to keep what the verdicts were judged at (BLAST-ESVIRITU-FIRST-WORD), or the record of every viewer run, which
// a resume writes, carries no basis. A file from before the field has no key and decodes as no basis.

import XCTest
@testable import LungfishCore

final class BlastSearchFileFactsTests: XCTestCase {
    private let sequences = [(id: "r1", sequence: "ACGT")]

    func testFactsKeepWhatTheRowWasJudgedAt() throws {
        let request = BlastVerificationRequest(taxonName: "Oxbow virus", taxId: 0, sequences: sequences, judgedAt: .names)
        let facts = BlastSearchFile.Facts(request)

        XCTAssertEqual(facts.request(sequences: sequences).judgedAt, .names, "a resume stamps its result as the first process did")
        let again = try JSONDecoder().decode(BlastSearchFile.Facts.self, from: JSONEncoder().encode(facts))
        XCTAssertEqual(again.request(sequences: sequences).judgedAt, .names, "and so does one that read the file back")
    }

    func testFactsFromBeforeTheFieldDecode() throws {
        let request = BlastVerificationRequest(taxonName: "Oxbow virus", taxId: 0, sequences: sequences)
        let data = try JSONEncoder().encode(BlastSearchFile.Facts(request))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])

        XCTAssertNil(object["judgedAt"], "a request with no basis writes no key")
        let decoded = try JSONDecoder().decode(BlastSearchFile.Facts.self, from: data)
        XCTAssertNil(decoded.request(sequences: sequences).judgedAt)
    }
}
