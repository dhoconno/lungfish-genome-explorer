// LeftoverAnnotationEditsGuardTests.swift - The guard against a genotype annotation count an earlier test left up (Phase 3.2 lane QUITEDIT)
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// The classes that drive Quit call `requireNoPendingAnnotationEditsForTest()` first, so that a count an earlier test
// left up stops them at once, in words, and never reaches the sheet that waits for a click. This test holds a waiting
// retry the way the genotype matrix does and reads the guard before, during and after.

import XCTest
@testable import LungfishApp
@testable import LungfishGenotypeUI

@MainActor
final class LeftoverAnnotationEditsGuardTests: XCTestCase {
    func testTheGuardFiresWhileAWaitingRetryIsCountedAndPassesOnceItIsGivenBack() throws {
        try requireNoPendingAnnotationEditsForTest()

        let hold = GenotypeWaitingRetryHold()
        defer { hold.release() }
        XCTAssertTrue(GenotypeResultViewController.isSavingAnnotationEdits, "a waiting retry counts as saving")
        XCTAssertThrowsError(try requireNoPendingAnnotationEditsForTest(), "a waiting retry was left up") { error in
            XCTAssertTrue(error is LeftoverOperationsError, "the guard throws the helper's error: \(error)")
            XCTAssertTrue(
                String(describing: error).contains("saving or waiting for its workbook"),
                "the words name what was left up: \(error)"
            )
        }

        hold.release()
        XCTAssertFalse(GenotypeResultViewController.isSavingAnnotationEdits, "the retry gave its count back")
        XCTAssertNoThrow(try requireNoPendingAnnotationEditsForTest(), "nothing is left up, so the guard passes")
    }
}
