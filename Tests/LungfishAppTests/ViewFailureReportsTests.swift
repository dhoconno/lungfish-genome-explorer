// ViewFailureReportsTests.swift - Viewer, welcome and Operations panel failure alerts (ALERT-PRESENTER)
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import XCTest
import LungfishIO
import LungfishKit
@testable import LungfishApp

@MainActor
final class ViewFailureReportsTests: XCTestCase {
    private let raw = "posix_spawn ENOENT /tmp/x.lock"

    func testExportTable() {
        assertFailureAlert(ViewerFailureReports.exportTable(rawFailureError()), title: "Could not export the table", rawErrorText: raw)
    }

    func testDeleteSampleMetadataColumnNamesTheColumn() {
        assertFailureAlert(
            ViewerFailureReports.deleteSampleMetadataColumn("collection_date", rawFailureError()),
            title: "Could not delete the collection_date column",
            rawErrorText: raw
        )
    }

    func testPrepareSelectedSequence() {
        assertFailureAlert(
            ViewerFailureReports.prepareSelectedSequence(rawFailureError()),
            title: "Could not prepare the selected sequence",
            rawErrorText: raw
        )
    }

    func testApplyAlignmentAnnotations() {
        assertFailureAlert(
            ViewerFailureReports.applyAlignmentAnnotations(rawFailureError()),
            title: "Could not apply the annotations to the selected rows",
            rawErrorText: raw
        )
    }

    func testAddAlignmentAnnotation() {
        assertFailureAlert(ViewerFailureReports.addAlignmentAnnotation(rawFailureError()), title: "Could not add the annotation", rawErrorText: raw)
    }

    func testCreateProject() {
        assertFailureAlert(WelcomeFailureReports.createProject(rawFailureError()), title: "Could not create the project", rawErrorText: raw)
    }

    func testRemovePartialOutput() {
        assertFailureAlert(
            OperationsPanelFailureReports.removePartialOutput(rawFailureError()),
            title: "Could not remove the partial output",
            rawErrorText: raw
        )
    }

    func testWriteOperationLogNamesCopyLog() {
        let report = OperationsPanelFailureReports.writeOperationLog(rawFailureError())
        assertFailureAlert(report, title: "Could not write the operation log", rawErrorText: raw)
        XCTAssertTrue(report.nextStep.contains(OperationRowAction.copyLog.title))
    }

    func testExportTableKeepsTheRowNotStoredSentenceInTheBody() {
        let sentence = "This row is not stored in an annotation database, so it cannot be exported."
        let report = ViewerFailureReports.exportTable(AnnotationTableExportRowNotStored())
        XCTAssertEqual(report.whatHappened, sentence)
        XCTAssertTrue(report.body.contains(sentence))
        XCTAssertEqual(report.details?.contains(sentence), true)
    }

    func testExportTableLeafFailurePointsToTheOperationsLog() {
        let report = ViewerFailureReports.exportTable(AnnotationTableExportLeafFailure(message: "output exists"))
        XCTAssertEqual(report.title, "Could not export the table")
        XCTAssertTrue(report.nextStep.contains("Operations panel"))
        XCTAssertEqual(report.details?.contains("output exists"), true)
        XCTAssertFalse(report.body.contains("output exists"))
    }

    func testAddAlignmentAnnotationWithoutASelectionTellsWhatToSelect() {
        let sentence = "Select one row and one or more alignment columns."
        let report = ViewerFailureReports.addAlignmentAnnotation(MultipleSequenceAlignmentBundle.ImportError.malformedInput(sentence))
        XCTAssertEqual(report.whatHappened, "The annotation needs one selected row and at least one selected column.")
        XCTAssertEqual(report.nextStep, "Select one row and the columns the annotation covers, then add it again.")
        XCTAssertEqual(report.details?.contains(sentence), true)
    }

    func testPrepareSelectedSequenceWithAnEmptyRangeTellsWhatToSelect() {
        let report = ViewerFailureReports.prepareSelectedSequence(SequenceViewerView.FASTAOperationInputError.emptyRange)
        XCTAssertEqual(report.title, "Could not prepare the selected sequence")
        XCTAssertEqual(report.nextStep, "Select a range that holds at least one base, then choose the operation again.")
        XCTAssertEqual(report.details?.contains("Select a non-empty sequence range"), true)
    }
}
