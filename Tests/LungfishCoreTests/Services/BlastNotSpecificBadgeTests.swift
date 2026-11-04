// BlastNotSpecificBadgeTests.swift - A row whose every supporting read also ties with other records reads Not specific
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Ruling BIO-BLAST-TIES of Phase 3.2, item 7 and R9. The badge is in a file and a commit range of its own, so that the
// row can be reverted alone if the owner reverses it.

import XCTest
@testable import LungfishCore

final class BlastNotSpecificBadgeTests: XCTestCase {
    private func tie(outside: Int, examples: [String] = []) -> BlastTieSummary {
        BlastTieSummary(
            hitListSize: 500, hitsReturned: 500, bestBitScore: 139.619, tied: outside + 1, inClade: 1, outside: outside,
            runsPastList: false, outsideExamples: examples
        )
    }

    private func supporting(outside: Int, examples: [String] = [], otherMates: [BlastReadResult]? = nil) -> BlastReadResult {
        BlastReadResult(
            id: UUID().uuidString, verdict: .verified, matchesQueriedTaxon: true, otherMates: otherMates,
            tieSummary: tie(outside: outside, examples: examples)
        )
    }

    private var contradicting: BlastReadResult {
        BlastReadResult(id: UUID().uuidString, verdict: .verified, matchesQueriedTaxon: false)
    }

    private func row(_ reads: [BlastReadResult]) -> BlastVerificationResult {
        BlastVerificationResult(
            taxonName: "Human immunodeficiency virus 1", taxId: 11676, readResults: reads,
            submittedAt: Date(), completedAt: Date(), rid: "R", blastProgram: "blastn", database: "core_nt"
        )
    }

    func testNotSpecificNeedsEverySupportingReadShared() {
        let specific = (0..<6).map { _ in supporting(outside: 0) }
        XCTAssertEqual(row(specific + [supporting(outside: 3)]).confidence, .supported, "6 specific and 1 shared")
        XCTAssertEqual(row([supporting(outside: 3)]).confidence, .notSpecific, "1 shared")
        let fiveShared = (0..<5).map { _ in supporting(outside: 3) }
        XCTAssertEqual(row(fiveShared + [contradicting]).confidence, .notSpecific, "5 shared and 1 contradicting, a rate of 0.83")
        let threeShared = (0..<3).map { _ in supporting(outside: 3) }
        XCTAssertEqual(row(threeShared + [contradicting, contradicting]).confidence, .mixed, "3 shared and 2 contradicting, a rate of 0.6")
    }

    func testAFragmentWithOneSpecificMateIsSpecific() {
        XCTAssertEqual(row([supporting(outside: 3, otherMates: [supporting(outside: 0)])]).confidence, .supported)
        XCTAssertEqual(row([supporting(outside: 3, otherMates: [supporting(outside: 2)])]).confidence, .notSpecific)
        let noHitMate = BlastReadResult(id: "mate", verdict: .unverified)
        XCTAssertEqual(row([supporting(outside: 3, otherMates: [noHitMate])]).confidence, .notSpecific, "a mate with no hit supports nothing")
    }

    func testTheWideHIVRepliesReadNotSpecificInBothDraws() throws {
        for (name, list) in [("t1-hiv2-500-a", 500), ("t3-hiv2-5000", 5000)] {
            let result = try BlastTieFixture.judged(name, claim: "hiv", list: list)
            XCTAssertEqual(result.supportingCount, 1, name)
            XCTAssertEqual(result.contradictingCount, 0, name)
            XCTAssertEqual(result.confidence, .notSpecific, name)
        }
    }

    /// A saved record has no tie summary, so it keeps the badge it was given until the row is sent again.
    func testARowWithNoSummaryKeepsItsBadge() {
        let saved = BlastReadResult(id: "saved", verdict: .verified, hasLCADisagreement: true, matchesQueriedTaxon: true)
        XCTAssertEqual(row([saved]).confidence, .supported)
    }

    func testTheBadgeWordsNameWhatTheReadsCannotTellApart() {
        let shared = row([supporting(outside: 3, examples: ["Expression vector pHR_SFFV", "synthetic construct", "Homo sapiens"])])
        XCTAssertEqual(
            BlastTieWords.notSpecificSummary(for: shared),
            "Every supporting read also matches other records equally, such as Expression vector pHR_SFFV and synthetic construct. "
                + "These reads cannot tell Human immunodeficiency virus 1 apart from them."
        )
        XCTAssertNil(BlastTieWords.notSpecificSummary(for: row([supporting(outside: 0)])))
    }
}
