// FailurePresenterTests.swift - The one failure presenter (ALERT-PRESENTER)
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import XCTest
@testable import LungfishKit

@MainActor
final class FailurePresenterTests: XCTestCase {
    private func diskFullError() -> NSError {
        NSError(domain: "TestDomain", code: 42, userInfo: [NSLocalizedDescriptionKey: "The disk is full."])
    }

    func testAlertTitleNamesTheFailedStep() {
        let report = FailureReport(
            failedStep: "Import the Kraken2 database",
            whatHappened: "Lungfish could not read the database files.",
            nextStep: "Check that the folder holds a complete Kraken2 database, then import it again.",
            underlying: nil
        )
        let alert = FailurePresenter.alert(for: report)
        XCTAssertEqual(alert.messageText, "Could not import the Kraken2 database")
        XCTAssertEqual(alert.alertStyle, .warning)
    }

    func testBodyIsWhatHappenedThenTheNextStepAsTwoParagraphs() {
        let report = FailureReport(
            failedStep: "Save the metadata",
            whatHappened: "The project folder could not be written.",
            nextStep: "Check that the project folder can be written to, then try again.",
            underlying: diskFullError()
        )
        let alert = FailurePresenter.alert(for: report)
        XCTAssertEqual(
            alert.informativeText,
            "The project folder could not be written.\n\nCheck that the project folder can be written to, then try again."
        )
        XCTAssertFalse(alert.informativeText.contains("The disk is full."), "raw error text stays out of the body")
    }

    func testDetailsHoldTheErrorDescriptionDomainAndCode() {
        let report = FailureReport(failedStep: "Save the file", whatHappened: "A.", nextStep: "B.", underlying: diskFullError())
        XCTAssertEqual(report.details, "The disk is full.\n\nError domain TestDomain, code 42")
    }

    func testDetailsAreaIsCollapsedAndSelectable() throws {
        let report = FailureReport(failedStep: "Save the file", whatHappened: "A.", nextStep: "B.", underlying: diskFullError())
        let alert = FailurePresenter.alert(for: report)
        let details = try XCTUnwrap(alert.accessoryView as? FailureDetailsView)
        XCTAssertFalse(details.isExpanded, "the details area starts collapsed")
        XCTAssertTrue(details.scrollView.isHidden)
        XCTAssertEqual(details.textView.string, "The disk is full.\n\nError domain TestDomain, code 42")
        XCTAssertTrue(details.textView.isSelectable)
        XCTAssertFalse(details.textView.isEditable)
        XCTAssertEqual(details.toggleButton.title, "Show Details")
        let collapsedHeight = details.frame.height

        details.toggleDetails(nil)
        XCTAssertTrue(details.isExpanded)
        XCTAssertEqual(details.toggleButton.title, "Hide Details")
        XCTAssertGreaterThan(details.frame.height, collapsedHeight)

        details.toggleDetails(nil)
        XCTAssertFalse(details.isExpanded)
        XCTAssertEqual(details.frame.height, collapsedHeight)
    }

    func testShowDetailsGrowsTheAlertWindowAndHideDetailsShrinksIt() throws {
        let report = FailureReport(failedStep: "Save the file", whatHappened: "A.", nextStep: "B.", underlying: diskFullError())
        let alert = FailurePresenter.alert(for: report)
        alert.layout()
        let details = try XCTUnwrap(alert.accessoryView as? FailureDetailsView)
        let collapsed = alert.window.frame.height
        details.setExpanded(true)
        XCTAssertGreaterThanOrEqual(alert.window.frame.height, collapsed + FailureDetailsView.textHeight, "the sheet grows by the details area")
        details.setExpanded(false)
        XCTAssertEqual(alert.window.frame.height, collapsed, accuracy: 1, "Hide Details gives the height back")
    }

    func testItemErrorsListEachItemWithItsError() {
        let report = FailureReport(
            failedStep: "Move the selected items",
            whatHappened: "Two items were not moved, sample.fastq and notes.txt.",
            nextStep: "Check that the destination folder can be written to, then move them again.",
            itemErrors: [(name: "sample.fastq", error: diskFullError()), (name: "notes.txt", error: diskFullError())]
        )
        XCTAssertEqual(
            report.details,
            "sample.fastq\nThe disk is full.\n\nError domain TestDomain, code 42\n\nnotes.txt\nThe disk is full.\n\nError domain TestDomain, code 42"
        )
        XCTAssertNil(FailureReport(failedStep: "Move", whatHappened: "A.", nextStep: "B.", itemErrors: []).details)
    }

    func testReportWithoutAnErrorHasNoDetailsArea() {
        let report = FailureReport(failedStep: "Open the project", whatHappened: "A.", nextStep: "B.", underlying: nil)
        XCTAssertNil(report.details)
        XCTAssertNil(FailurePresenter.alert(for: report).accessoryView)
    }

    func testStepThatStartsWithAnAllCapitalsNameKeepsItsCase() {
        let report = FailureReport(failedStep: "BLAST the selected sequence", whatHappened: "A.", nextStep: "B.", underlying: nil)
        XCTAssertEqual(report.title, "Could not BLAST the selected sequence")
    }

    func testReportsWithTheSameWordsAndErrorAreEqual() {
        let first = FailureReport(failedStep: "Save the file", whatHappened: "A.", nextStep: "B.", underlying: diskFullError())
        let second = FailureReport(failedStep: "Save the file", whatHappened: "A.", nextStep: "B.", underlying: diskFullError())
        XCTAssertEqual(first, second)
    }

    func testWarningPresenterShimKeepsItsWords() {
        let alert = WarningPresenter.alert(title: "Export Failed", message: "Choose a folder you can write to.")
        XCTAssertEqual(alert.messageText, "Export Failed")
        XCTAssertEqual(alert.informativeText, "Choose a folder you can write to.")
        XCTAssertEqual(alert.alertStyle, .warning)
        XCTAssertEqual(alert.buttons.map(\.title), ["OK"])
    }
}
