// BlastConsentHelpTests.swift - The help of the two BLAST leaves says what leaves this Mac and how often
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
@testable import LungfishCLI

/// Phase 3.2 lane BLASTNET N5 (UX-BLAST-WORDS Q4).
final class BlastConsentHelpTests: XCTestCase {
    private let sends = "The sequences go to NCBI and leave this Mac, and LGE cannot call them back. If NCBI is slow, the same sequences are sent again, "
        + "at most three sends in all, and the record lists every send."
    private let resume = "and lungfish-cli blast resume --output <folder> collects it later."

    func testBlastSubmitHelpSaysTheSameSequencesMayGoAgain() {
        XCTAssertTrue(
            BlastCommand.SubmitSubcommand.configuration.discussion
                .contains("\(sends) A search still waiting stays in --output, \(resume)")
        )
    }

    /// `blast verify` has no `--output`. Its search stays under `--result-dir`, so the words name that.
    func testBlastVerifyHelpSaysTheSameSequencesMayGoAgain() {
        XCTAssertTrue(
            BlastCommand.VerifySubcommand.configuration.discussion
                .contains("\(sends) A search still waiting stays under --result-dir, \(resume)")
        )
    }
}
