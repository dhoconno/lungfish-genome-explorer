// AffectedResultsBlastFirstWordTests.swift - The row of BLAST-ESVIRITU-FIRST-WORD (S1 sweep 2026-11-17, lane BLAST-FIRSTWORD)
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
@testable import LungfishWorkflow

final class AffectedResultsBlastFirstWordTests: XCTestCase {
    private func ids(_ build: Int, _ kind: AffectedResultKind) -> [String] {
        AffectedResults.rows(forAppVersion: "Lungfish 2026.11.11 (\(build))", kind: kind).map(\.backlogID)
    }

    // BIO-THREE-ROWS item 4. A BLAST check judged by organism names took a best match that shared only the first word
    // of the row's name as supporting. The row holds an EsViritu result from the first build that could BLAST-verify an
    // EsViritu row (4443f0068, 511, the consensus check), which is after the first-word rule (2164e5f21, 501), to
    // Preview 2026.11.11 (13672), and no other kind.
    func testTheEsVirituFirstWordRowHoldsItsBuilds() throws {
        let row = try XCTUnwrap(AffectedResults.rows.first { $0.backlogID == "BLAST-ESVIRITU-FIRST-WORD" })
        XCTAssertEqual(row.kinds, [.esViritu])
        XCTAssertEqual(row.firstBuild, 511, "4443f0068, the first BLAST check of an EsViritu row, after 2164e5f21 (501)")
        XCTAssertEqual(row.lastBuild, 13672, "Preview 2026.11.11, the newest build, lacks the fix")
        XCTAssertFalse(ids(510, .esViritu).contains(row.backlogID))
        XCTAssertTrue(ids(511, .esViritu).contains(row.backlogID))
        XCTAssertTrue(ids(12972, .esViritu).contains(row.backlogID), "Stable 2026.11.7")
        XCTAssertTrue(ids(13672, .esViritu).contains(row.backlogID), "Preview 2026.11.11")
        XCTAssertFalse(ids(13673, .esViritu).contains(row.backlogID))
        for kind in AffectedResultKind.allCases where kind != .esViritu {
            XCTAssertFalse(ids(13672, kind).contains(row.backlogID), "\(kind)")
        }
        XCTAssertEqual(
            row.sentence,
            "A BLAST check of an EsViritu row judged by organism names could count a read as supporting "
                + "when its best match was another virus whose name starts with the same word."
        )
        XCTAssertEqual(row.fixCommit, "3c943cb8a", "the commit of the whole-word verdict fix, the last that changes a verdict")
        XCTAssertEqual(row.whatToDo, "Run Verify with BLAST… again.")
    }
}
