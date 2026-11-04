// GenotypeEditQuitConfirmationTests.swift - The buttons of the Quit sheet for a waiting genotype edit (Phase 3.2 lane QUITEDIT)
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// The Quit tests answer the sheet through a seam, so none of them builds it. This test builds the alert and shows
// nothing, and reads which button answers Return, which button is destructive and in what order they stand.

import AppKit
import XCTest
@testable import LungfishApp

@MainActor
final class GenotypeEditQuitConfirmationTests: XCTestCase {
    func testTheQuitSheetGivesReturnToDontQuitOnlyAndKeepsQuitAnywayDestructiveAndFirst() {
        let alert = GenotypeEditQuitConfirmation.makeAlert()
        XCTAssertEqual(
            alert.buttons.map(\.title),
            [GenotypeEditQuitConfirmation.quitButtonTitle, GenotypeEditQuitConfirmation.dontQuitButtonTitle]
        )
        XCTAssertEqual(alert.buttons.map(\.keyEquivalent), ["", "\r"], "only Don't Quit may answer Return")
        XCTAssertTrue(alert.buttons[0].hasDestructiveAction, "Quit Anyway discards the edit")
        XCTAssertFalse(alert.buttons[1].hasDestructiveAction, "Don't Quit keeps it")
    }
}
