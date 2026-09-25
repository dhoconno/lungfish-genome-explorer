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
            "Submits selected reads to NCBI BLASTN nt for review. Reads leave the app for NCBI."
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
            "Submits selected reads to NCBI BLASTN core_nt for review. Reads leave the app for NCBI."
        )
    }

    func testHelpTextDoesNotHardCodeADatabase() {
        let verify = LungfishHelpContent.classifierBlastVerify.detail ?? ""
        let readCount = LungfishHelpContent.classifierBlastReadCount.detail ?? ""
        XCTAssertFalse(verify.contains("BLASTN nt"))
        XCTAssertTrue(verify.contains("nt or core_nt"))
        XCTAssertFalse(readCount.contains("searches nt"))
    }
}
