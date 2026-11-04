// BlastTieVerdictTests.swift - A read is judged on every record tied at NCBI's best bit score
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Ruling BIO-BLAST-TIES of Phase 3.2. The replies under Tests/Fixtures/blast-ties were saved from NCBI and trimmed by
// trim_replies.py in that folder. No test here reaches NCBI, and none says what a new search would name, since a list
// is a draw from the tie at any size.

import XCTest
@testable import LungfishCore

/// The trimmed recorded replies, read from disk.
enum BlastTieFixture {
    struct Claim: Decodable {
        let taxonName: String
        let taxId: Int
        let cladeNames: [String]
        let cladeTaxIds: [Int]
    }

    private static var folder: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Fixtures/blast-ties")
    }

    static func claim(_ key: String) throws -> Claim {
        let data = try Data(contentsOf: folder.appendingPathComponent("claims.json"))
        return try XCTUnwrap(JSONDecoder().decode([String: Claim].self, from: data)[key])
    }

    static func reply(_ name: String) throws -> [BlastSearchResult] {
        try BlastService().parseJSON2Results(Data(contentsOf: folder.appendingPathComponent(name + ".json")))
    }

    static func judged(_ name: String, claim key: String, list: Int) throws -> BlastVerificationResult {
        let (parsed, claim) = (try reply(name), try claim(key))
        return try BlastService().buildVerificationResult(
            request: BlastVerificationRequest(
                taxonName: claim.taxonName, taxId: claim.taxId, sequences: parsed.map { (id: $0.queryId, sequence: "ACGT") },
                database: "core_nt", maxTargetSeqs: list,
                acceptedTaxIds: Set(claim.cladeTaxIds), acceptedTaxonNames: claim.cladeNames
            ),
            searchResults: parsed, rid: name, submittedAt: Date(), completedAt: Date()
        )
    }
}

final class BlastTieVerdictTests: XCTestCase {
    private let service = BlastService()
    private let taxonName = "Human immunodeficiency virus 1"
    private let clade: Set<Int> = [3418650, 11676]
    private let cladeNames = ["Human immunodeficiency virus 1", "Lentivirus humimdef1"]

    private func hit(
        _ accession: String, _ taxId: Int?, organism: String = "Expression vector", otherTaxIds: [Int] = [],
        bit: Double = 139.619, evalue: Double = 4.2664e-29
    ) -> BlastHit {
        BlastHit(accession: accession, title: organism, organism: organism, taxId: taxId, otherTaxIds: otherTaxIds, hsps: [
            BlastHSP(bitScore: bit, evalue: evalue, identity: 75, alignLength: 75, queryFrom: 1, queryTo: 75),
        ])
    }

    /// The five records of RID EHYDS4KV016, the reply that read a false Unsupported on a 100% match to HIV-1.
    private var fiveWithNoHIV: [BlastHit] {
        [hit("PX372844", 3464302), hit("ON783971", 2974064), hit("MZ146780", 2912739), hit("OK471369", 2908268), hit("PZ267688", 32630)]
    }

    private func hiv(_ accession: String, bit: Double = 139.619, evalue: Double = 4.2664e-29) -> BlastHit {
        hit(accession, 11676, organism: taxonName, bit: bit, evalue: evalue)
    }

    private func judge(_ hits: [BlastHit], hitListSize: Int? = nil, related: Set<Int> = []) -> BlastVerificationResult {
        let rows = service.assignVerdicts(
            searchResults: [BlastSearchResult(queryId: "read", queryLength: 75, hits: hits)],
            eValueThreshold: 1e-10, queriedTaxonName: taxonName,
            acceptedTaxIds: clade, acceptedTaxonNames: cladeNames, relatedTaxIds: related, hitListSize: hitListSize
        )
        return BlastVerificationResult(
            taxonName: taxonName, taxId: 11676, readResults: rows, submittedAt: Date(), completedAt: Date(),
            rid: "R", blastProgram: "blastn", database: "core_nt"
        )
    }

    // MARK: - The list size

    func testRequestAsksFor500WithTaxIdsAndFiveWithout() {
        let reads = [(id: "read", sequence: "ACGT")]
        XCTAssertEqual(BlastVerificationRequest(taxonName: "t", taxId: 11676, sequences: reads, acceptedTaxIds: [11676]).maxTargetSeqs, 500)
        XCTAssertEqual(BlastVerificationRequest(taxonName: "t", taxId: 0, sequences: reads, acceptedTaxonNames: ["t"]).maxTargetSeqs, 5)
        XCTAssertEqual(BlastVerificationRequest(taxonName: "t", taxId: 0, sequences: reads).maxTargetSeqs, 5)
        XCTAssertEqual(BlastVerificationRequest(taxonName: "t", taxId: 11676, sequences: reads, maxTargetSeqs: 10, acceptedTaxIds: [11676]).maxTargetSeqs, 10)
    }

    // MARK: - The verdict on a tie

    func testASixthTiedRecordInTheCladeMakesTheReadSupporting() {
        let result = judge(fiveWithNoHIV + [hiv("OQ751369")])
        XCTAssertEqual(result.supportingCount, 1)
        XCTAssertEqual(result.contradictingCount, 0)
    }

    func testAllFiveTiedWithNoCladeOnAFullListCountsNeither() throws {
        let full = judge(fiveWithNoHIV, hitListSize: 5)
        let row = try XCTUnwrap(full.readResults.first)
        XCTAssertEqual(row.verdict, .ambiguous)
        XCTAssertFalse(row.matchesQueriedTaxon)
        XCTAssertEqual(full.supportingCount, 0)
        XCTAssertEqual(full.contradictingCount, 0)
        XCTAssertEqual(full.confidence, .inconclusive)
        XCTAssertEqual(row.tieSummary?.runsPastList, true)

        let endsBelowTheTie = judge(fiveWithNoHIV + [hit("BELOW", 9606, bit: 134.079, evalue: 2e-27)], hitListSize: 6)
        XCTAssertEqual(endsBelowTheTie.contradictingCount, 1, "the list ended below the tie, so no clade record ties")
        XCTAssertEqual(endsBelowTheTie.readResults.first?.tieSummary?.runsPastList, false)
    }

    func testAListFullOfCladeRecordsStaysSupporting() throws {
        let result = judge(["A", "B", "C", "D", "E"].map { hiv($0) }, hitListSize: 5)
        let row = try XCTUnwrap(result.readResults.first)
        XCTAssertEqual(result.supportingCount, 1)
        XCTAssertFalse(row.hasLCADisagreement, "no record outside is in sight")
        XCTAssertEqual(row.tieSummary?.runsPastList, true, "the record says that a record outside could sit past the end")
    }

    /// The name rule judges the first record, so a list full of ties changes nothing there (`BlastFragmentVerdictTests`).
    func testAListFullOfTiesLeavesTheNameRuleAlone() {
        let rows = service.assignVerdicts(
            searchResults: [BlastSearchResult(queryId: "read", queryLength: 75, hits: [hit("A", nil), hiv("B")])],
            eValueThreshold: 1e-10, queriedTaxonName: taxonName, acceptedTaxonNames: cladeNames, hitListSize: 2
        )
        XCTAssertEqual(rows.first?.verdict, .verified)
        XCTAssertEqual(rows.first?.matchesQueriedTaxon, false)
        XCTAssertNil(rows.first?.tieSummary)
    }

    /// A list-full mate reads below both verified classes, so it never outweighs a judged mate (Section 7).
    func testAListFullMateNeverOutweighsAJudgedMate() throws {
        func row(_ second: [BlastHit], _ first: [BlastHit]? = nil) throws -> BlastVerificationResult {
            try service.buildVerificationResult(
                request: BlastVerificationRequest(
                    taxonName: taxonName, taxId: 11676, sequences: [(id: "pair", sequence: "A"), (id: "pair", sequence: "C")],
                    database: "core_nt", maxTargetSeqs: 5, acceptedTaxIds: clade, acceptedTaxonNames: cladeNames
                ),
                searchResults: [
                    BlastSearchResult(queryId: "pair", queryLength: 75, hits: first ?? fiveWithNoHIV),
                    BlastSearchResult(queryId: "pair", queryLength: 75, hits: second),
                ],
                rid: "R", submittedAt: Date(), completedAt: Date()
            )
        }
        XCTAssertEqual(try row([hiv("OQ751369")]).supportingCount, 1)
        XCTAssertEqual(try row([hit("PX372844", 3464302)]).contradictingCount, 1)
        let neither = try row(fiveWithNoHIV)
        XCTAssertEqual(neither.supportingCount, 0)
        XCTAssertEqual(neither.contradictingCount, 0)
    }

    func testALaterDeflineInTheCladeCounts() throws {
        let result = judge([hit("MN685337", 32630, organism: "synthetic construct", otherTaxIds: [11676])])
        XCTAssertEqual(result.supportingCount, 1)
        XCTAssertEqual(result.contradictingCount, 0)
        XCTAssertEqual(result.readResults.first?.hasLCADisagreement, true, "the record is filed outside the clade as well")
    }

    // MARK: - The flag

    func testARecordBelowTheBestScoreIsNoConflict() {
        let result = judge([hiv("OQ751369"), hit("BELOW", 3464302, bit: 134.079, evalue: 2e-27)])
        XCTAssertEqual(result.supportingCount, 1)
        XCTAssertEqual(result.readResults.first?.hasLCADisagreement, false)
    }

    func testATiedRelativeOrARecordWithNoTaxIdMakesTheReadShared() {
        XCTAssertEqual(judge([hiv("A"), hit("B", 12721)], related: [12721]).readResults.first?.hasLCADisagreement, true, "a relative")
        XCTAssertEqual(judge([hiv("A"), hit("B", nil)]).readResults.first?.hasLCADisagreement, true, "no tax ID")
    }

    func testAReadWithNoCladeRecordInItsTieIsNotFlagged() {
        let result = judge([hit("A", 3464302), hit("B", 2974064, organism: "Vector")])
        XCTAssertEqual(result.contradictingCount, 1)
        XCTAssertEqual(result.readResults.first?.hasLCADisagreement, false, "it contradicts, and nothing is shared")
    }

    // MARK: - What the row shows

    func testASharedTieShowsItsCladeRecordFirst() throws {
        let walk = [hit("PX372844", 3464302), hiv("OQ751369"), hit("ON783971", 2974064), hiv("MN965909"), hiv("MN965880")]
        let row = try XCTUnwrap(judge(walk).readResults.first)
        XCTAssertEqual(row.topHits.map(\.accession), ["OQ751369", "PX372844", "ON783971", "MN965909", "MN965880"])
        XCTAssertEqual(row.topHits.map(\.rank), [1, 2, 3, 4, 5])
        XCTAssertEqual(row.topHitAccession, "OQ751369")
        XCTAssertEqual(row.topHitOrganism, taxonName)
        XCTAssertEqual(row.topHitRelation, .clade)

        let allInClade = try XCTUnwrap(judge(["C", "A", "B"].map { hiv($0) }).readResults.first)
        XCTAssertEqual(allInClade.topHits.map(\.accession), ["C", "A", "B"], "a tie all in the clade keeps NCBI's order")
    }

    // MARK: - The recorded replies

    func testTheWideHIVRepliesHoldTheMeasuredTies() throws {
        let wide = try BlastTieFixture.judged("t1-hiv2-500-a", claim: "hiv", list: 500)
        let row = try XCTUnwrap(wide.readResults.first)
        let summary = try XCTUnwrap(row.tieSummary)
        XCTAssertEqual(summary.tied, 288)
        XCTAssertEqual(summary.inClade, 117)
        XCTAssertEqual(summary.outside, 171)
        XCTAssertEqual(summary.hitsReturned, 500)
        XCTAssertEqual(summary.hitListSize, 500)
        XCTAssertEqual(summary.bestBitScore, 139.619)
        XCTAssertFalse(summary.runsPastList)
        XCTAssertEqual(summary.outsideExamples.count, 3)
        XCTAssertEqual(wide.supportingCount, 1)
        XCTAssertEqual(wide.contradictingCount, 0)
        XCTAssertEqual(wide.databaseSequenceCount, 132357636)
        XCTAssertEqual(row.topHits.count, 5, "the row still shows five")
        XCTAssertEqual(row.topHitRelation, .clade)
        XCTAssertEqual(row.otherMates?.first?.verdict, .unverified, "the 76-mer has no hit")

        let wider = try BlastTieFixture.judged("t3-hiv2-5000", claim: "hiv", list: 5000)
        let widerSummary = try XCTUnwrap(wider.readResults.first?.tieSummary)
        XCTAssertEqual(widerSummary.tied, 366)
        XCTAssertEqual(widerSummary.inClade, 144)
        XCTAssertEqual(widerSummary.outside, 222)
        XCTAssertEqual(wider.supportingCount, 1)
        XCTAssertEqual(wider.contradictingCount, 0)
        XCTAssertEqual(wider.readResults.first?.topHitRelation, .clade)

        func tiedAccessions(_ name: String) throws -> Set<String> {
            let hits = try XCTUnwrap(BlastTieFixture.reply(name).last).hits
            return Set(hits.filter { $0.hsps.first?.bitScore == hits.first?.hsps.first?.bitScore }.map(\.accession))
        }
        XCTAssertEqual(try tiedAccessions("t1-hiv2-500-a").intersection(tiedAccessions("t3-hiv2-5000")).count, 235)

        let twoFilings = try XCTUnwrap(XCTUnwrap(BlastTieFixture.reply("t3-hiv2-5000").last).hits.first { $0.accession == "MN685337" })
        XCTAssertEqual(twoFilings.taxId, 32630)
        XCTAssertEqual(twoFilings.otherTaxIds, [11676], "the parser reads every defline")
    }

    /// One request's replies name other records and can even miss the best one, and the reading holds on each.
    func testTiedDrawsOfOneRequestReadTheSame() throws {
        let draws: [(name: String, list: Int, best: Double, identity: Double, outside: Int)] = [
            ("b01-rota7-lge", 5, 261.498, 100, 0),
            ("c7a-rota7-curl", 5, 255.958, 99.29, 0),
            ("t2-rota7-500-a", 500, 255.958, 99.29, 4),
        ]
        for draw in draws {
            let result = try BlastTieFixture.judged(draw.name, claim: "rota", list: draw.list)
            XCTAssertEqual(result.supportingCount, 7, draw.name)
            XCTAssertEqual(result.contradictingCount, 0, draw.name)
            XCTAssertEqual(result.confidence, .supported, draw.name)
            let read = try XCTUnwrap(result.readResults.first { $0.id.contains("2129:11905:11145") }, draw.name)
            XCTAssertEqual(read.bitScore, draw.best, draw.name)
            XCTAssertEqual(try XCTUnwrap(read.percentIdentity), draw.identity, accuracy: 0.01, draw.name)
            XCTAssertEqual(read.tieSummary?.outside, draw.outside, draw.name)
            XCTAssertEqual(read.hasLCADisagreement, draw.outside > 0, draw.name)
        }
    }

    // MARK: - The words

    func testTheWordsSayWhatTheTieHeld() throws {
        let wide = try XCTUnwrap(BlastTieFixture.judged("t1-hiv2-500-a", claim: "hiv", list: 500).readResults.first)
        XCTAssertEqual(
            BlastTieWords.read(wide),
            "Tied with 287 other records at the best score: 116 more in this taxon, 171 outside. NCBI returned 500."
        )
        let full = try XCTUnwrap(judge(fiveWithNoHIV, hitListSize: 5).readResults.first)
        XCTAssertEqual(
            BlastTieWords.read(full),
            "More than 5 records tie at the best score and none returned is in this taxon. "
                + "NCBI's list ended before the tie did, so this read counts neither way."
        )
        XCTAssertNil(BlastTieWords.read(try XCTUnwrap(judge([hiv("A")]).readResults.first)), "a record alone ties with nothing")
        XCTAssertNil(BlastTieWords.read(BlastReadResult(id: "saved", verdict: .verified)), "a saved record has no summary")

        XCTAssertEqual(BlastTieWords.flaggedCount(in: judge([hiv("A"), hit("B", 3464302)])), "1 also matches other records equally")
        XCTAssertEqual(BlastTieWords.flaggedCount(in: judge([hiv("A")])), "")
        let saved = BlastVerificationResult(
            taxonName: taxonName, taxId: 11676,
            readResults: Array(repeating: BlastReadResult(id: "saved", verdict: .verified, hasLCADisagreement: true), count: 2),
            submittedAt: Date(), completedAt: Date(), rid: "R", blastProgram: "blastn", database: "core_nt"
        )
        XCTAssertEqual(BlastTieWords.flaggedCount(in: saved), "2 with conflicting organisms", "a saved record reads as it did")
    }

    // MARK: - The record

    func testTieSummarySurvivesARecordAndOldRecordsDecode() throws {
        let judged = judge(fiveWithNoHIV + [hiv("OQ751369")], hitListSize: 500)
        let saved = BlastVerificationResult(
            taxonName: taxonName, taxId: 11676, readResults: judged.readResults, submittedAt: Date(), completedAt: Date(),
            rid: "R", blastProgram: "blastn", database: "core_nt", databaseSequenceCount: 132357636
        )
        let decoded = try JSONDecoder().decode(BlastVerificationResult.self, from: JSONEncoder().encode(saved))
        XCTAssertEqual(decoded.databaseSequenceCount, 132357636)
        let summary = try XCTUnwrap(decoded.readResults.first?.tieSummary)
        XCTAssertEqual(summary.tied, 6)
        XCTAssertEqual(summary.inClade, 1)
        XCTAssertEqual(summary.outside, 5)
        XCTAssertEqual(summary.hitsReturned, 6)
        XCTAssertEqual(summary.hitListSize, 500)

        // A row as a saved record holds it: no summary, so it keeps the badge and the flag it was given.
        let old = #"""
        {"taxonName":"HIV-1","taxId":11676,"totalReads":1,"verifiedCount":1,"ambiguousCount":0,"unverifiedCount":0,"errorCount":0,
         "readResults":[{"hasLCADisagreement":true,"id":"r1","matchesQueriedTaxon":true,"topHits":[],"verdict":"verified"}],
         "submittedAt":0,"rid":"EHSMXBRH014","blastProgram":"blastn","database":"core_nt"}
        """#
        let record = try JSONDecoder().decode(BlastVerificationResult.self, from: Data(old.utf8))
        XCTAssertNil(record.databaseSequenceCount)
        XCTAssertNil(record.readResults.first?.tieSummary)
        XCTAssertEqual(record.readResults.first?.hasLCADisagreement, true)
        XCTAssertEqual(record.confidence, .supported)

        let plain = String(decoding: try JSONEncoder().encode(BlastReadResult(id: "r1", verdict: .verified)), as: UTF8.self)
        XCTAssertFalse(plain.contains("tieSummary"), "a row with no summary has no such key: \(plain)")
    }
}
