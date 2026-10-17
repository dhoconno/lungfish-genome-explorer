// AlignmentEvidenceErrorWordsTests.swift - the words of a refusal to act on alignment evidence
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.11 lane A69 (carry-in row SW11). `AlignmentActionContext.EvidenceError` had no
// `LocalizedError` words, so the Operations row of an alignment action whose evidence had changed
// read "The operation couldn't be completed". The words below are the lane's proposal and the UX review
// rules on them. These tests print them, so a ruling changes one string here and one in the source.

import Foundation
import XCTest
@testable import LungfishWorkflow

final class AlignmentEvidenceErrorWordsTests: XCTestCase {
    private let bam = URL(fileURLWithPath: "/work/Project.lungfish/sample.sorted.bam")

    func testStaleEvidenceNamesTheFileThatChanged() {
        let error = AlignmentActionContext.EvidenceError.staleEvidence(bam)

        XCTAssertEqual(
            error.errorDescription,
            "sample.sorted.bam changed after the alignment was opened, so nothing was run. Reopen the alignment and try again."
        )
        XCTAssertEqual(error.localizedDescription, error.errorDescription, "the row and the alert read this text")
    }

    func testMissingEvidenceNamesTheFileThatIsGone() {
        let error = AlignmentActionContext.EvidenceError.missingEvidence(bam)

        XCTAssertEqual(
            error.errorDescription,
            "sample.sorted.bam is missing, so nothing was run. Restore the file or reopen the alignment."
        )
        XCTAssertEqual(error.localizedDescription, error.errorDescription)
    }

    /// UX 7: sentence case, and no colon, semicolon or dash inside a sentence.
    func testTheWordsFollowTheRulesOfProse() throws {
        for error in [
            AlignmentActionContext.EvidenceError.staleEvidence(bam),
            AlignmentActionContext.EvidenceError.missingEvidence(bam),
        ] {
            let words = try XCTUnwrap(error.errorDescription)
            XCTAssertFalse(words.contains(":") || words.contains(";") || words.contains("\u{2014}"), words)
            XCTAssertTrue(words.hasSuffix("."), words)
            XCTAssertFalse(words.contains("/work/"), "a file is named, not its path. \(words)")
        }
    }
}
