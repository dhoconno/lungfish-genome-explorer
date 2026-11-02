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
}
