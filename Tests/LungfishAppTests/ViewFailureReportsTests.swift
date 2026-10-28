// ViewFailureReportsTests.swift - Viewer, welcome and Operations panel failure alerts (ALERT-PRESENTER)
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import XCTest
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
}
