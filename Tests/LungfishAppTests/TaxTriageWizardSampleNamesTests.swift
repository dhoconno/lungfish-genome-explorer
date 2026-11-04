// TaxTriageWizardSampleNamesTests.swift - The dialog refuses two sample names that the pipeline turns into one name
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Lane TTCONTROLS, row TAXTRIAGE-NAMES-THAT-MEET-LOSE-ROWS. The dialog says the words of the run's own refusal.

import XCTest
import SwiftUI
@testable import LungfishApp
@testable import LungfishWorkflow

@MainActor
final class TaxTriageWizardSampleNamesTests: XCTestCase {

    func testDialogRefusesAParenthesisedNameBesideItsUnderscoredTwin() throws {
        let words = try XCTUnwrap(TaxTriageWizardSheet.sampleNamesValidationMessage(["A (1)", "A_1"]))
        XCTAssertTrue(words.contains("A (1) and A_1 become the same name, A_1"), words)
        XCTAssertTrue(words.contains("Rename them so that the names stay different, then run again."), words)
        XCTAssertEqual(words, TaxTriageSample.namesThatMeetWords(in: ["A (1)", "A_1"]), "the dialog and the run say one thing")
    }

    func testDialogTrimsTheNamesAsTheRunDoes() {
        XCTAssertNotNil(TaxTriageWizardSheet.sampleNamesValidationMessage(["A_1 ", " A (1)"]))
    }

    func testDialogAcceptsNamesThatStayDifferent() {
        XCTAssertNil(TaxTriageWizardSheet.sampleNamesValidationMessage(["A 1", "A 2", "B (1)"]))
    }

    /// UX review, blocker B1. The Operations dialog embeds the sheet and prints its own footer, so the words of the
    /// refusal reach a person only if the sample list shows them. The three tests above call the pure helper and
    /// cannot see that. The notice takes room when two names meet and none when they stay different.
    func testSampleNamesNoticeTakesRoomOnlyWhenNamesMeet() {
        let meeting = NSHostingView(rootView: TaxTriageWizardSheet.sampleNamesNotice(["A (1)", "A_1"]))
        let apart = NSHostingView(rootView: TaxTriageWizardSheet.sampleNamesNotice(["A", "B"]))
        XCTAssertGreaterThan(meeting.fittingSize.height, 0, "the names meet, but the sample list shows no words")
        XCTAssertEqual(apart.fittingSize.height, 0, "names that stay different need no notice")
    }
}
