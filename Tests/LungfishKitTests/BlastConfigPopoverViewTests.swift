// BlastConfigPopoverViewTests.swift - The BLAST popover names the database searched
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
@testable import LungfishKit

@MainActor
final class BlastConfigPopoverViewTests: XCTestCase {

    func testCaptionDefaultsToNt() {
        XCTAssertEqual(
            BlastConfigPopoverView.submissionCaption(database: "nt"),
            "Sends the selected reads to NCBI BLASTN nt, so they leave this Mac and LGE cannot call them back. If NCBI is slow, LGE sends the same reads again, at most three sends in all. The record lists every send."
        )
        XCTAssertEqual(
            BlastConfigPopoverView.submissionCaption(database: "  "),
            BlastConfigPopoverView.submissionCaption(database: "nt"),
            "a blank database name falls back to nt"
        )
    }

    func testCaptionNamesCoreNt() {
        XCTAssertEqual(
            BlastConfigPopoverView.submissionCaption(database: "core_nt"),
            "Sends the selected reads to NCBI BLASTN core_nt, so they leave this Mac and LGE cannot call them back. If NCBI is slow, LGE sends the same reads again, at most three sends in all. The record lists every send."
        )
    }

    /// UX review SF1. A person who cancels later does not take the reads back, and the help says so too.
    func testHelpSaysASendCannotBeCalledBack() {
        let detail = LungfishHelpContent.classifierBlastVerify.detail ?? ""
        XCTAssertTrue(detail.contains("The reads leave this Mac, and LGE cannot call them back."), detail)
    }

    func testHelpTextDoesNotHardCodeADatabase() {
        let verify = LungfishHelpContent.classifierBlastVerify.detail ?? ""
        let readCount = LungfishHelpContent.classifierBlastReadCount.detail ?? ""
        XCTAssertFalse(verify.contains("BLASTN nt"))
        XCTAssertTrue(verify.contains("nt or core_nt"))
        XCTAssertFalse(readCount.contains("searches nt"))
    }
}
