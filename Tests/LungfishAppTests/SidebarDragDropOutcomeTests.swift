// SidebarDragDropOutcomeTests.swift - Tests for the drag-drop partial-failure outcome summary
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Task E4 (2026-08-08 repo review fix campaign, finding AS4): moveItems/
// copyItems only os_log'd per-item failures inside their loop and continued;
// no NSAlert was ever shown for a partial failure, so a multi-drag of a
// mixed movable/non-movable selection silently moved/copied only the valid
// subset with zero user-visible indication. SidebarDragDropOutcome is the
// pure, testable summary that replaces "return true/false" with a reason
// per skipped item, so the caller can surface exactly what happened.

import XCTest
@testable import LungfishApp

@MainActor
final class SidebarDragDropOutcomeTests: XCTestCase {

    func testOutcomeReportsFullSuccessWhenNoItemsSkipped() {
        var outcome = SidebarDragDropOutcome(kind: .move)
        outcome.recordSuccess()
        outcome.recordSuccess()

        XCTAssertEqual(outcome.succeededCount, 2)
        XCTAssertTrue(outcome.skipped.isEmpty)
        XCTAssertFalse(outcome.hasPartialFailure)
    }

    func testOutcomeReportsPartialFailureWithReasons() {
        var outcome = SidebarDragDropOutcome(kind: .move)
        outcome.recordSuccess()
        outcome.recordSkip(title: "orphan.fasta", reason: .missingURL)
        outcome.recordSkip(title: "Reference Sequences", reason: .moveIntoSelfOrDescendant)

        XCTAssertEqual(outcome.succeededCount, 1)
        XCTAssertEqual(outcome.skipped.count, 2)
        XCTAssertTrue(outcome.hasPartialFailure)

        let message = outcome.alertInformativeText(totalSelected: 3)
        XCTAssertTrue(message.contains("orphan.fasta"), message)
        XCTAssertTrue(message.contains("Reference Sequences"), message)
        XCTAssertTrue(message.contains("1 of 3"), message)
    }

    func testOutcomeReportsFileManagerFailureReason() {
        var outcome = SidebarDragDropOutcome(kind: .copy)
        outcome.recordSkip(title: "locked.bam", reason: .fileSystemError("Permission denied"))

        let message = outcome.alertInformativeText(totalSelected: 1)
        XCTAssertTrue(message.contains("locked.bam"), message)
        XCTAssertTrue(message.contains("Permission denied"), message)
    }

    func testAlertTitleDistinguishesMoveFromCopy() {
        var moveOutcome = SidebarDragDropOutcome(kind: .move)
        moveOutcome.recordSkip(title: "x", reason: .missingURL)
        XCTAssertTrue(moveOutcome.alertTitle.localizedCaseInsensitiveContains("move"), moveOutcome.alertTitle)

        var copyOutcome = SidebarDragDropOutcome(kind: .copy)
        copyOutcome.recordSkip(title: "x", reason: .missingURL)
        XCTAssertTrue(copyOutcome.alertTitle.localizedCaseInsensitiveContains("copied"), copyOutcome.alertTitle)
    }

    /// A refusal that begins with the item's name reads as its own line, and any other reason keeps the name before its
    /// brackets (COPYFOLDER-UX should-fix 1b).
    func testARefusalThatNamesItsItemIsNotRepeatedInTheAlert() {
        let words = "taxtriage-cornea was not copied. a.bam does not match the checksum in the provenance record of taxtriage-cornea."
        var refused = SidebarDragDropOutcome(kind: .copy)
        refused.recordSkip(title: "taxtriage-cornea", reason: .fileSystemError(words))
        XCTAssertEqual(
            refused.alertInformativeText(totalSelected: 1),
            "0 of 1 selected item(s) were copied. The rest were skipped:\n\(words)"
        )

        var mixed = SidebarDragDropOutcome(kind: .copy)
        mixed.recordSkip(title: "taxtriage-cornea", reason: .fileSystemError(words))
        mixed.recordSkip(title: "b.fa", reason: .missingURL)
        mixed.recordSkip(title: "locked.bam", reason: .fileSystemError("Permission denied"))
        let text = mixed.alertInformativeText(totalSelected: 3)
        XCTAssertTrue(text.contains("\n\(words)\n"), text)
        XCTAssertTrue(text.contains("b.fa (\(SidebarDragDropSkipReason.missingURL.reasonText))"), text)
        XCTAssertTrue(text.contains("locked.bam (Permission denied)"), text)
    }
}
