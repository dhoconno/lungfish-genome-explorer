// AffectedResultsTests.swift - The table of results an earlier build made wrong and its matcher
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
@testable import LungfishWorkflow

final class AffectedResultsTests: XCTestCase {
    /// The builds of the published releases from Stable 2026.10.27 on, each the commit count of its packaged commit.
    private let publishedBuilds: Set<Int> = [11609, 11807, 12045, 12518, 12591, 12803, 12818, 12859, 12962, 12972]

    private func version(_ build: Int) -> String { "Lungfish 2026.10.29 (\(build))" }

    private func ids(_ build: Int, _ kind: AffectedResultKind) -> [String] {
        AffectedResults.rows(forAppVersion: version(build), kind: kind).map(\.backlogID)
    }

    func testTheBuildIsTheNumberInBracketsAndNothingElse() {
        XCTAssertEqual(AffectedResults.build(fromAppVersion: "Lungfish 2026.10.29 (12045)"), 12045)
        for text in ["Lungfish 2026.11.7 (dev)", "Lungfish 2026.11.7", "Lungfish fixture", "Lungfish 1.0 ()",
                     "Lungfish 1.0 (12a)", "Lungfish 1.0 (-5)", "", "(12045"] {
            XCTAssertNil(AffectedResults.build(fromAppVersion: text), text)
        }
        XCTAssertNil(AffectedResults.build(fromAppVersion: nil))
    }

    func testARecordOfAnAffectedBuildMatchesTheRowsOfItsKind() {
        // Stable 2026.10.29 counted TaxTriage Reads on the first reference only and could fit a sibling's BAM.
        let taxTriage = ids(12045, .taxTriage)
        XCTAssertTrue(taxTriage.contains("TTREADS"))
        XCTAssertTrue(taxTriage.contains("BUILDDB-BAM-FIT"))
        XCTAssertFalse(taxTriage.contains("NAOMGS-UNALIGNED-MATE-HIT"), "that row speaks about another kind")
        XCTAssertTrue(ids(12045, .naoMgs).contains("NAOMGS-UNALIGNED-MATE-HIT"))
        XCTAssertFalse(ids(12045, .assembly).contains("ASSEMBLY-RECORDED-PATH"), "that row ends at 11807")
        XCTAssertTrue(ids(11807, .assembly).contains("ASSEMBLY-RECORDED-PATH"))
    }

    func testTheBuildBeforeTheFirstAndAfterTheLastDoNotMatch() {
        func holdsBAMFit(_ build: Int) -> Bool { ids(build, .taxTriage).contains("BUILDDB-BAM-FIT") }
        XCTAssertFalse(holdsBAMFit(2978), "one build before the commit that brought the defect in")
        XCTAssertTrue(holdsBAMFit(2979))
        XCTAssertTrue(holdsBAMFit(12859), "Preview 2026.11.5, the last build without the fix")
        XCTAssertFalse(holdsBAMFit(12860))
        XCTAssertEqual(ids(12962, .taxTriage), [], "Preview 2026.11.6 holds every TaxTriage fix")
        XCTAssertEqual(ids(12972, .taxTriage), [], "Stable 2026.11.7 holds every TaxTriage fix")
        XCTAssertFalse(ids(11610, .nvd).contains("NVD-UNIQUE-READS-DOUBLE-COUNT"), "that row ends at Stable 2026.10.27")
        XCTAssertTrue(ids(11609, .nvd).contains("NVD-UNIQUE-READS-DOUBLE-COUNT"))
    }

    func testEveryRowHoldsItsOwnBoundsAndNothingBeyond() {
        for row in AffectedResults.rows {
            XCTAssertTrue(row.holds(build: row.lastBuild), row.backlogID)
            XCTAssertFalse(row.holds(build: row.lastBuild + 1), row.backlogID)
            if let first = row.firstBuild {
                XCTAssertTrue(row.holds(build: first), row.backlogID)
                XCTAssertFalse(row.holds(build: first - 1), row.backlogID)
            }
            for kind in row.kinds {
                XCTAssertTrue(ids(row.lastBuild, kind).contains(row.backlogID), "\(row.backlogID) \(kind)")
                XCTAssertFalse(ids(row.lastBuild + 1, kind).contains(row.backlogID), "\(row.backlogID) \(kind)")
            }
        }
    }

    func testADevBuildOrNoBuildMatchesNothing() {
        for kind in AffectedResultKind.allCases {
            XCTAssertEqual(AffectedResults.rows(forAppVersion: "Lungfish 2026.11.7 (dev)", kind: kind), [], "\(kind)")
            XCTAssertEqual(AffectedResults.rows(forAppVersion: "Lungfish 2026.11.7", kind: kind), [], "\(kind)")
            XCTAssertEqual(AffectedResults.rows(forAppVersion: "", kind: kind), [], "\(kind)")
            XCTAssertEqual(AffectedResults.rows(forAppVersion: nil, kind: kind), [], "\(kind)")
        }
    }

    func testARecordIsReadThroughItsRuntimeIdentity() {
        var affected = ProvenanceEnvelope.fixture()
        affected.runtimeIdentity = ProvenanceRuntimeIdentity(appVersion: "Lungfish 2026.10.29 (12045)")
        XCTAssertTrue(AffectedResults.rows(for: affected, kind: .taxTriage).contains { $0.backlogID == "TTREADS" })

        var current = ProvenanceEnvelope.fixture()
        current.runtimeIdentity = ProvenanceRuntimeIdentity(appVersion: "Lungfish 2026.11.7 (12972)")
        XCTAssertEqual(AffectedResults.rows(for: current, kind: .taxTriage), [])

        var dev = ProvenanceEnvelope.fixture()
        dev.runtimeIdentity = ProvenanceRuntimeIdentity(appVersion: "Lungfish 2026.11.7 (dev)")
        XCTAssertEqual(AffectedResults.rows(for: dev, kind: .taxTriage), [])
    }

    func testTheTableIsWellFormed() {
        let rows = AffectedResults.rows
        XCTAssertEqual(Set(rows.map(\.backlogID)).count, rows.count, "one row for each backlog id")
        for row in rows {
            XCTAssertFalse(row.kinds.isEmpty, row.backlogID)
            XCTAssertTrue(publishedBuilds.contains(row.lastBuild),
                          "\(row.backlogID) ends at the newest published build that lacks the fix")
            XCTAssertLessThan(row.lastBuild, 12972, "\(row.backlogID) is fixed in the newest Stable")
            if let first = row.firstBuild { XCTAssertLessThanOrEqual(first, row.lastBuild, row.backlogID) }
            XCTAssertNotNil(row.fixCommit.range(of: "^[0-9a-f]{9}$", options: .regularExpression), row.backlogID)
            for words in [row.sentence, row.whatToDo] {
                XCTAssertTrue(words.hasSuffix("."), row.backlogID)
                XCTAssertFalse(words.contains("\u{2014}") || words.contains(";") || words.contains(":"),
                               "\(row.backlogID) follows the prose rules")
                XCTAssertEqual(words.components(separatedBy: ". ").count, 1, "\(row.backlogID) is one sentence")
            }
            XCTAssertEqual(row.words, row.sentence + " " + row.whatToDo)
        }
    }
}
