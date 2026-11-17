// AffectedResultsVR-SE-ADAPTERSTests.swift - The row for a single-end Viral Recon run that let fastp guess the adapter
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
import LungfishCore
@testable import LungfishWorkflow

/// S1 sweep 2026-11-17, lane VR-SE-ADAPTERS (ruling BIO-THREE-ROWS, items 8 to 11). VIRALRECON-SE-ADAPTER-GUESS holds a
/// Viral Recon result from the first Viral Recon commit (be56a5d8e, build 1618) to Preview 2026.11.11 (13672), the newest
/// published build that lacks the fix, and no other kind. It shares the kind and the first build of
/// VIRALRECON-READ-ORDER, and a Viral Recon result of those builds shows both rows.
final class AffectedResultsVRSEAdaptersTests: XCTestCase {
    private let backlogID = "VIRALRECON-SE-ADAPTER-GUESS"

    private func ids(_ build: Int, _ kind: AffectedResultKind) -> [String] {
        AffectedResults.rows(forAppVersion: "Lungfish 2026.11.11 (\(build))", kind: kind).map(\.backlogID)
    }

    func testTheRowHoldsItsBuildsAndOnlyTheViralReconKind() throws {
        let row = try XCTUnwrap(AffectedResults.rows.first { $0.backlogID == backlogID })
        XCTAssertEqual(row.kinds, [.viralRecon])
        XCTAssertEqual(row.firstBuild, 1618, "be56a5d8e, the first Viral Recon commit")
        XCTAssertEqual(row.lastBuild, 13672, "Preview 2026.11.11, the newest build, lacks the fix")

        XCTAssertFalse(ids(1617, .viralRecon).contains(backlogID))
        XCTAssertTrue(ids(1618, .viralRecon).contains(backlogID))
        XCTAssertTrue(ids(12972, .viralRecon).contains(backlogID), "Stable 2026.11.7")
        XCTAssertTrue(ids(13672, .viralRecon).contains(backlogID), "Preview 2026.11.11")
        XCTAssertFalse(ids(13673, .viralRecon).contains(backlogID))
        for kind in AffectedResultKind.allCases where kind != .viralRecon {
            XCTAssertFalse(ids(13672, kind).contains(backlogID), "\(kind)")
        }
    }

    func testTheRowShowsAlongsideTheReadOrderRowOfTheSameBuilds() {
        for build in [1618, 5524, 12972] {
            XCTAssertTrue(ids(build, .viralRecon).contains("VIRALRECON-READ-ORDER"), "\(build)")
            XCTAssertTrue(ids(build, .viralRecon).contains(backlogID), "\(build)")
        }
        XCTAssertFalse(ids(12973, .viralRecon).contains("VIRALRECON-READ-ORDER"), "that row ends at Stable 2026.11.7")
        XCTAssertTrue(ids(12973, .viralRecon).contains(backlogID), "the first build after Stable 2026.11.7 still lacks this fix")
    }

    func testTheRowSaysWhatHappenedAndWhatToDo() throws {
        let row = try XCTUnwrap(AffectedResults.rows.first { $0.backlogID == backlogID })
        XCTAssertEqual(row.sentence, "A single-end Viral Recon run let fastp guess the adapter from the first reads, "
                       + "so the same reads in another stored order could be trimmed differently.")
        XCTAssertEqual(row.whatToDo, "Run it again.")
        XCTAssertEqual(row.fixCommit, "78594ad20")
    }

    // A record names its build in `Lungfish <version> (<build>)`, and the table believes a build only when its version
    // is a published release. Preview 2026.11.11 is the newest build that lacks the fix, so the table must publish it.
    func testARecordOfPreview2026_11_11ShowsTheRow() {
        var preview = ProvenanceEnvelope.fixture()
        preview.runtimeIdentity = ProvenanceRuntimeIdentity(appVersion: "Lungfish 2026.11.11 (13672)")
        XCTAssertEqual(AffectedResults.builds(of: preview), 13672...13672)
        XCTAssertTrue(AffectedResults.rows(for: preview, kind: .viralRecon).contains { $0.backlogID == backlogID })
    }
}
