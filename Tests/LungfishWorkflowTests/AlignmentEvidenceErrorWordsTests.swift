// AlignmentEvidenceErrorWordsTests.swift - the words of a refusal to act on alignment evidence
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.11 lane A69 (carry-in row SW11). `AlignmentActionContext.EvidenceError` had no
// `LocalizedError` words, so the Operations row of an alignment action whose evidence had changed
// read "The operation couldn't be completed". The words below are the UX ruling of the A69 review.
// Each test reads `localizedDescription`, the text the row and the alert show, so each fails at the
// base by its assertion and not by a build error.

import Foundation
import XCTest
@testable import LungfishWorkflow

final class AlignmentEvidenceErrorWordsTests: XCTestCase {
    private let bam = URL(fileURLWithPath: "/work/Project.lungfish/sample.sorted.bam")

    func testStaleEvidenceNamesTheFileThatChanged() {
        XCTAssertEqual(
            AlignmentActionContext.EvidenceError.staleEvidence(bam).localizedDescription,
            "The file sample.sorted.bam changed after the alignment was opened, so nothing was saved. Reopen the alignment and try again."
        )
    }

    func testMissingEvidenceNamesTheFileThatIsGone() {
        XCTAssertEqual(
            AlignmentActionContext.EvidenceError.missingEvidence(bam).localizedDescription,
            "The file sample.sorted.bam is missing, so nothing was saved. Restore the file and try again."
        )
    }

    /// UX 7. Sentence case, exactly one period ending each sentence, no colon, semicolon or dash, the
    /// file named and not its path, and the fix named in the last sentence.
    func testTheWordsFollowTheRulesOfProse() {
        for error in [
            AlignmentActionContext.EvidenceError.staleEvidence(bam),
            AlignmentActionContext.EvidenceError.missingEvidence(bam),
        ] {
            let words = error.localizedDescription
            XCTAssertFalse(words.contains(":") || words.contains(";") || words.contains("\u{2014}"), words)
            XCTAssertFalse(words.contains(".."), words)
            XCTAssertTrue(words.hasSuffix("and try again."), "the last sentence names the fix. \(words)")
            XCTAssertTrue(words.first?.isUppercase == true, "sentence case. \(words)")
            XCTAssertFalse(words.contains("/work/"), "a file is named, not its path. \(words)")
            XCTAssertFalse(words.contains("nothing was run"), "the check can come after the tool ran. \(words)")
        }
    }
}
