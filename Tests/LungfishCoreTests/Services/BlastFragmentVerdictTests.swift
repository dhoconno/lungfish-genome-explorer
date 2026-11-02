// BlastFragmentVerdictTests.swift - Both mates of a read pair are judged, a fragment counts once, and a tie reads the clade
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Ruling BIO-BLAST-MATES of Phase 3.1. The fixture is NCBI's reply for RID EGTB319K014, the Stable walk's Verify with
// BLAST run on the TaxTriage row Human immunodeficiency virus 1. Its tax IDs and names come from that reply.

import XCTest
@testable import LungfishCore

final class BlastFragmentVerdictTests: XCTestCase {
    private let service = BlastService()
    private let taxonName = "Human immunodeficiency virus 1"
    private let clade: Set<Int> = [3418650, 11676]
    private let cladeNames = ["Human immunodeficiency virus 1", "Lentivirus humimdef1"]

    /// The five records NCBI returned for the walk's second mate, in the reply's order. All five tie at one score.
    private var walkHits: [BlastHit] {
        [
            walkHit("PX372844", "Expression vector pHR_SFFV clone pHR_SFFV_hCXCR4, complete sequence",
                    organism: "Expression vector pHR_SFFV", taxId: 3464302),
            walkHit("OQ751369", "HIV-1 isolate BC021_proviral_350_Scramble from Canada defective provirus genomic sequence",
                    organism: taxonName, taxId: 11676),
            walkHit("ON783971", "Vector pLV[Exp]-EGFP:T2A:Puro-EF1A >hAAK1, complete sequence",
                    organism: "Vector pLV[Exp]-EGFP:T2A:Puro-EF1A >hAAK1", taxId: 2974064),
            walkHit("MN965909", "HIV-1 isolate pj32 from China envelope glycoprotein (env) gene, partial cds",
                    organism: taxonName, taxId: 11676),
            walkHit("MN965880", "HIV-1 isolate jm11 from China envelope glycoprotein (env) gene, partial cds",
                    organism: taxonName, taxId: 11676),
        ]
    }

    private func walkHit(
        _ accession: String, _ title: String, organism: String, taxId: Int?,
        bitScore: Double = 139.619, evalue: Double = 4.2664e-29
    ) -> BlastHit {
        BlastHit(accession: accession, title: title, organism: organism, taxId: taxId, hsps: [
            BlastHSP(bitScore: bitScore, evalue: evalue, identity: 75, alignLength: 75, queryFrom: 1, queryTo: 75),
        ])
    }

    /// What one mate's answer can be: no hit, a passing hit in the clade, a passing hit outside it, a hit under the
    /// thresholds, or an entry NCBI's reply could not give.
    private enum Mate { case noHit, inClade, outside, weak, failed }

    private func reply(_ id: String, _ mate: Mate) -> BlastSearchResult {
        switch mate {
        case .noHit:
            return BlastSearchResult(queryId: id, queryLength: 75, hits: [])
        case .inClade:
            return BlastSearchResult(queryId: id, queryLength: 75, hits: [
                walkHit("OQ751369", "HIV-1 isolate", organism: taxonName, taxId: 11676),
            ])
        case .outside:
            return BlastSearchResult(queryId: id, queryLength: 75, hits: [
                walkHit("PX372844", "Expression vector", organism: "Expression vector pHR_SFFV", taxId: 3464302),
            ])
        case .weak:
            return BlastSearchResult(queryId: id, queryLength: 76, hits: [
                BlastHit(accession: "WEAK1", title: "HIV-1 isolate", organism: taxonName, taxId: 11676, hsps: [
                    BlastHSP(bitScore: 52.8, evalue: 1e-4, identity: 28, alignLength: 28, queryFrom: 1, queryTo: 28),
                ]),
            ])
        case .failed:
            return BlastSearchResult(queryId: id, queryLength: 0, hits: [], failureMessage: "unparsed")
        }
    }

    private func judged(
        _ sequences: [(id: String, sequence: String)],
        replies: [BlastSearchResult],
        judgesAClaim: Bool = true
    ) throws -> BlastVerificationResult {
        try service.buildVerificationResult(
            request: BlastVerificationRequest(
                taxonName: taxonName,
                taxId: 11676,
                sequences: sequences,
                database: "core_nt",
                acceptedTaxIds: judgesAClaim ? clade : [],
                acceptedTaxonNames: judgesAClaim ? cladeNames : []
            ),
            searchResults: replies,
            rid: "EGTB319K014",
            submittedAt: Date(),
            completedAt: Date()
        )
    }

    /// A row of single reads and read pairs, where both mates of a pair share one ID, as the BAM routes send them.
    private func judgedRow(singles: [Mate] = [], pairs: [(Mate, Mate)] = []) throws -> BlastVerificationResult {
        var sequences: [(id: String, sequence: String)] = []
        var replies: [BlastSearchResult] = []
        for (index, mate) in singles.enumerated() {
            sequences.append((id: "single\(index)", sequence: "ACGT"))
            replies.append(reply("single\(index)", mate))
        }
        for (index, pair) in pairs.enumerated() {
            for mate in [pair.0, pair.1] {
                sequences.append((id: "pair\(index)", sequence: "ACGT"))
                replies.append(reply("pair\(index)", mate))
            }
        }
        return try judged(sequences, replies: replies)
    }

    private func judgedSecondMateAlone(_ hits: [BlastHit]) -> BlastVerificationResult {
        let rows = service.assignVerdicts(
            searchResults: [BlastSearchResult(queryId: "SRR12486983.3484597", queryLength: 75, hits: hits)],
            eValueThreshold: 1e-10,
            queriedTaxonName: taxonName,
            acceptedTaxIds: clade,
            acceptedTaxonNames: cladeNames
        )
        return BlastVerificationResult(
            taxonName: taxonName, taxId: 11676, readResults: rows, submittedAt: Date(), completedAt: Date(),
            rid: "EGTB319K014", blastProgram: "blastn", database: "core_nt"
        )
    }

    // MARK: - Ties

    /// NCBI's order among records tied at the best score is not evidence, so the vector listed first does not make
    /// this read contradict the row while three HIV-1 records sit beside it at the same score.
    func testVectorTiedFirstCountsAsSupportingInAnyOrder() {
        let xmlOrder = judgedSecondMateAlone(walkHits)
        XCTAssertEqual(xmlOrder.supportingCount, 1, "in the reply's order")
        XCTAssertEqual(xmlOrder.confidence, .supported, "in the reply's order")
        XCTAssertEqual(xmlOrder.readResults.first?.topHitRelation, .outside, "the relation stays the first record's")

        var hits = walkHits
        hits.swapAt(0, 1)
        let hivFirst = judgedSecondMateAlone(hits)
        XCTAssertEqual(hivFirst.supportingCount, 1, "with OQ751369 first")
        XCTAssertEqual(hivFirst.confidence, .supported, "with OQ751369 first")
    }

    /// A vector that beats the clade outright still contradicts. The tie rule must not reach past the best score.
    func testARecordOutsideThatBeatsTheCladeStillContradicts() {
        let hits = [walkHits[0]] + [1, 3, 4].map { index in
            let hit = walkHits[index]
            return walkHit(hit.accession, hit.title, organism: taxonName, taxId: 11676, bitScore: 134, evalue: 2e-27)
        }
        let result = judgedSecondMateAlone(hits)
        XCTAssertEqual(result.contradictingCount, 1)
        XCTAssertEqual(result.supportingCount, 0)
        XCTAssertEqual(result.confidence, .unsupported)
    }

    /// With no tax IDs the name rule decides on the first record alone. Scanning a tie with its first-word rule would
    /// widen the false-Supported hole.
    func testTieRuleNeverRunsOnTheNameRule() {
        let rows = service.assignVerdicts(
            searchResults: [BlastSearchResult(queryId: "SRR12486983.3484597", queryLength: 75, hits: [
                walkHit("PX372844", "Expression vector", organism: "Expression vector pHR_SFFV", taxId: nil),
                walkHit("OQ751369", "HIV-1 isolate", organism: taxonName, taxId: nil),
            ])],
            eValueThreshold: 1e-10,
            queriedTaxonName: taxonName,
            acceptedTaxonNames: cladeNames
        )
        let row = rows.first
        XCTAssertEqual(row?.verdict, .verified)
        XCTAssertEqual(row?.matchesQueriedTaxon, false, "a tied claim record second does not move the name rule")
    }

    // MARK: - The fragment rule

    func testFragmentRuleTableReadsTheSameInEitherOrder() throws {
        // Mates that split between the clade and another organism count as neither.
        for (first, second) in [(Mate.inClade, Mate.outside), (Mate.outside, Mate.inClade)] {
            let result = try judgedRow(pairs: [(first, second)])
            let label = "(\(first), \(second))"
            XCTAssertEqual(result.readResults.count, 1, label)
            XCTAssertEqual(result.supportingCount, 0, label)
            XCTAssertEqual(result.contradictingCount, 0, label)
            XCTAssertEqual(result.readResults.first?.verdict, .ambiguous, label)
            XCTAssertEqual(result.readResults.first?.hasLCADisagreement, true, label)
            XCTAssertEqual(result.confidence, .inconclusive, label)
        }

        // Both mates failing leaves no usable result, and the job still fails.
        XCTAssertThrowsError(try judgedRow(pairs: [(.failed, .failed)]))

        let table: [(first: Mate, second: Mate, supporting: Int, contradicting: Int, verdict: BlastVerdict)] = [
            (.noHit, .inClade, 1, 0, .verified),
            (.inClade, .inClade, 1, 0, .verified),
            (.outside, .noHit, 0, 1, .verified),
            (.weak, .inClade, 1, 0, .verified),
            (.weak, .noHit, 0, 0, .ambiguous),
            (.noHit, .failed, 0, 0, .unverified),
        ]
        for row in table {
            for (first, second) in [(row.first, row.second), (row.second, row.first)] {
                let result = try judgedRow(pairs: [(first, second)])
                let label = "(\(first), \(second))"
                XCTAssertEqual(result.readResults.count, 1, label)
                XCTAssertEqual(result.supportingCount, row.supporting, label)
                XCTAssertEqual(result.contradictingCount, row.contradicting, label)
                XCTAssertEqual(result.readResults.first?.verdict, row.verdict, label)
            }
        }
    }

    /// 4 supporting reads and 2 pairs whose second mate matches another organism read 4 of 4 when that answer is dropped.
    func testADroppedContradictionCanNoLongerLeaveARowSupported() throws {
        let result = try judgedRow(
            singles: Array(repeating: .inClade, count: 4),
            pairs: Array(repeating: (.noHit, .outside), count: 2)
        )
        XCTAssertEqual(result.supportingCount, 4)
        XCTAssertEqual(result.contradictingCount, 2)
        XCTAssertEqual(result.confidence, .mixed)
    }

    /// 1 supporting read, 1 contradicting read and 3 pairs whose second mate supports read 1 of 2 when that answer is dropped.
    func testADroppedMatchCanNoLongerLeaveARowMixed() throws {
        let result = try judgedRow(
            singles: [.inClade, .outside],
            pairs: Array(repeating: (.noHit, .inClade), count: 3)
        )
        XCTAssertEqual(result.supportingCount, 4)
        XCTAssertEqual(result.contradictingCount, 1)
        XCTAssertEqual(result.confidence, .supported)
    }

    /// A FASTA selection, an assembly or a 12S request makes no claim, so two sequences of one name stay two rows.
    func testARequestWithNoClaimKeepsEveryAnswerOfASharedName() throws {
        let result = try judged(
            [(id: "a", sequence: "AAAA"), (id: "a", sequence: "GGGG")],
            replies: [reply("a", .inClade), reply("a", .noHit)],
            judgesAClaim: false
        )
        XCTAssertEqual(result.readResults.count, 2)
        XCTAssertEqual(result.readResults.map(\.querySequence), ["AAAA", "GGGG"])
        XCTAssertEqual(result.readResults.map(\.verdict), [.verified, .unverified])
    }

    // MARK: - The walk's fragment

    /// The walk read `0 supporting, 0 contradicting (1 read)` while NCBI's reply held five 100% matches for the second mate.
    func testBothMatesOfTheWalkHIVFragmentAreJudged() throws {
        let fragment = "SRR12486983.3484597"
        let mate1 = "CTCCGTTGTTGTTGTTGAGAGAGATTGCTCGCGTACCTGTGCATCAACCCTACTATCATTATGAATAATTTTATAT"
        let mate2 = "TTGAAGAATCGCAAAACCAGCAAGAAAAGAATGAACAAGAATTATTGGAATTAGATAAATGGGCAAGTTTGTGGA"
        let result = try judged(
            [(id: fragment, sequence: mate1), (id: fragment, sequence: mate2)],
            replies: [
                BlastSearchResult(queryId: fragment, queryLength: 76, hits: []),
                BlastSearchResult(queryId: fragment, queryLength: 75, hits: walkHits),
            ]
        )
        XCTAssertEqual(result.supportingCount, 1)
        XCTAssertEqual(result.contradictingCount, 0)
        XCTAssertEqual(result.confidence, .supported)
        XCTAssertEqual(result.totalReads, 1)
        XCTAssertEqual(result.judgedSequenceCount, 2)
        let row = try XCTUnwrap(result.readResults.first)
        XCTAssertEqual(row.topHitAccession, "PX372844")
        XCTAssertTrue(row.hasLCADisagreement)
        XCTAssertEqual(row.querySequence, mate2)
        XCTAssertEqual(row.otherMates?.first?.verdict, .unverified)
        XCTAssertEqual(row.otherMates?.first?.querySequence, mate1)
    }

    /// NCBI's reply for RID EGTB319K014 holds two reports under one `query_title`: the 76-mer with no hits, then the
    /// 75-mer with five. The parser must hand back both, in the reply's order, or the fragment rule never sees the
    /// second mate and the row reads Inconclusive again. The JSON is the saved reply without its alignments and ranges
    /// on the subject, and the five records share one HSP here as they do in the reply (the same score and span).
    func testTheWalkReplyKeepsBothMatesThroughTheParser() throws {
        let fragment = "SRR12486983.3484597"
        let mate1 = "CTCCGTTGTTGTTGTTGAGAGAGATTGCTCGCGTACCTGTGCATCAACCCTACTATCATTATGAATAATTTTATAT"
        let mate2 = "TTGAAGAATCGCAAAACCAGCAAGAAAAGAATGAACAAGAATTATTGGAATTAGATAAATGGGCAAGTTTGTGGA"
        let hsp = #"{"bit_score": 139.619, "evalue": 4.2664e-29, "identity": 75, "align_len": 75, "query_from": 1, "query_to": 75}"#
        let reply = #"""
        {"BlastOutput2": [
          {"report": {"results": {"search": {
            "query_id": "Query_6160774", "query_title": "SRR12486983.3484597", "query_len": 76,
            "hits": [], "message": "No hits found"
          }}}},
          {"report": {"results": {"search": {
            "query_id": "Query_6160775", "query_title": "SRR12486983.3484597", "query_len": 75,
            "hits": [
              {"num": 1, "len": 10062, "hsps": [\#(hsp)], "description": [
                {"accession": "PX372844", "taxid": 3464302, "sciname": "Expression vector pHR_SFFV",
                 "title": "Expression vector pHR_SFFV clone pHR_SFFV_hCXCR4, complete sequence"}]},
              {"num": 2, "len": 8191, "hsps": [\#(hsp)], "description": [
                {"accession": "OQ751369", "taxid": 11676, "sciname": "Human immunodeficiency virus 1",
                 "title": "HIV-1 isolate BC021_proviral_350_Scramble from Canada defective provirus genomic sequence"}]},
              {"num": 3, "len": 12284, "hsps": [\#(hsp)], "description": [
                {"accession": "ON783971", "taxid": 2974064, "sciname": "Vector pLV[Exp]-EGFP:T2A:Puro-EF1A >hAAK1",
                 "title": "Vector pLV[Exp]-EGFP:T2A:Puro-EF1A >hAAK1, complete sequence"}]},
              {"num": 4, "len": 408, "hsps": [\#(hsp)], "description": [
                {"accession": "MN965909", "taxid": 11676, "sciname": "Human immunodeficiency virus 1",
                 "title": "HIV-1 isolate pj32 from China envelope glycoprotein (env) gene, partial cds"},
                {"accession": "MN966033", "taxid": 11676, "sciname": "Human immunodeficiency virus 1",
                 "title": "HIV-1 isolate xh42 from China envelope glycoprotein (env) gene, partial cds"}]},
              {"num": 5, "len": 408, "hsps": [\#(hsp)], "description": [
                {"accession": "MN965880", "taxid": 11676, "sciname": "Human immunodeficiency virus 1",
                 "title": "HIV-1 isolate jm11 from China envelope glycoprotein (env) gene, partial cds"}]}
            ]
          }}}}
        ]}
        """#
        let parsed = try service.parseJSON2Results(Data(reply.utf8))
        XCTAssertEqual(parsed.map(\.queryId), [fragment, fragment], "both reports keep the shared title")
        XCTAssertEqual(parsed.map(\.queryLength), [76, 75], "in the reply's order")
        XCTAssertEqual(parsed.map { $0.hits.map(\.accession) }, [[], ["PX372844", "OQ751369", "ON783971", "MN965909", "MN965880"]])

        let result = try judged([(id: fragment, sequence: mate1), (id: fragment, sequence: mate2)], replies: parsed)
        XCTAssertEqual(result.totalReads, 1)
        XCTAssertEqual(result.supportingCount, 1)
        XCTAssertEqual(result.judgedSequenceCount, 2)
        XCTAssertEqual(result.readResults.first?.topHitAccession, "PX372844")
    }

    // MARK: - Reconciling answers with sequences

    /// A query of R1s then R2s holds a fragment's mates apart. Each answer still pairs with its own sequence.
    func testMatesApartInTheQueryLineUpBySubmissionOrder() throws {
        let result = try judged(
            [(id: "a", sequence: "AAAA"), (id: "b", sequence: "CCCC"), (id: "a", sequence: "GGGG")],
            replies: [reply("a", .noHit), reply("b", .outside), reply("a", .inClade)]
        )
        XCTAssertEqual(result.readResults.map(\.id), ["a", "b"])
        let fragmentA = result.readResults[0]
        XCTAssertEqual(fragmentA.verdict, .verified)
        XCTAssertEqual(fragmentA.querySequence, "GGGG")
        XCTAssertEqual(fragmentA.matchesQueriedTaxon, true)
        XCTAssertEqual(fragmentA.otherMates?.map(\.querySequence), ["AAAA"])
        XCTAssertEqual(fragmentA.otherMates?.map(\.verdict), [.unverified])
        XCTAssertEqual(result.readResults[1].querySequence, "CCCC")
        XCTAssertEqual(result.readResults[1].matchesQueriedTaxon, false)
        XCTAssertEqual(result.judgedSequenceCount, 3)
    }

    func testAMateMissingFromTheReplyStaysAnErrorMate() throws {
        let result = try judged(
            [(id: "a", sequence: "AAAA"), (id: "a", sequence: "GGGG")],
            replies: [reply("a", .inClade)]
        )
        XCTAssertEqual(result.readResults.count, 1)
        XCTAssertEqual(result.readResults.first?.verdict, .verified)
        XCTAssertEqual(result.readResults.first?.querySequence, "AAAA")
        XCTAssertEqual(result.readResults.first?.otherMates?.map(\.verdict), [.error])
        XCTAssertEqual(result.readResults.first?.otherMates?.first?.errorMessage, BlastService.missingReadResultMessage)
        XCTAssertEqual(result.readResults.first?.otherMates?.first?.querySequence, "GGGG")
    }

    // MARK: - The record

    func testOtherMatesSurviveARecordAndOldRecordsDecode() throws {
        let fragmentRow = BlastReadResult(
            id: "a", verdict: .verified, querySequence: "GGGG", matchesQueriedTaxon: true,
            otherMates: [BlastReadResult(id: "a", verdict: .unverified, querySequence: "AAAA")]
        )
        let result = BlastVerificationResult(
            taxonName: taxonName, taxId: 11676, readResults: [fragmentRow], submittedAt: Date(), completedAt: Date(),
            rid: "EGTB319K014", blastProgram: "blastn", database: "core_nt"
        )
        let decoded = try JSONDecoder().decode(BlastVerificationResult.self, from: JSONEncoder().encode(result))
        XCTAssertEqual(decoded.totalReads, 1)
        XCTAssertEqual(decoded.judgedSequenceCount, 2)
        XCTAssertEqual(decoded.readResults.first?.otherMates?.map(\.querySequence), ["AAAA"])
        XCTAssertEqual(decoded.readResults.first?.otherMates?.map(\.verdict), [.unverified])

        let singleRead = String(decoding: try JSONEncoder().encode(BlastReadResult(id: "r1", verdict: .verified)), as: UTF8.self)
        XCTAssertFalse(singleRead.contains("otherMates"), "a single read's JSON is unchanged: \(singleRead)")

        // A read row as the walk's saved record holds it.
        let saved = #"{"hasLCADisagreement":false,"id":"r1","matchesQueriedTaxon":false,"querySequence":"AAAA","topHits":[],"verdict":"unverified"}"#
        let old = try JSONDecoder().decode(BlastReadResult.self, from: Data(saved.utf8))
        XCTAssertNil(old.otherMates)
        XCTAssertEqual(old.verdict, .unverified)
    }
}
