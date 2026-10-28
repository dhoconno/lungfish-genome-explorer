// SidebarFailureReportsTests.swift - The sidebar's failure alerts (ALERT-PRESENTER)
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import XCTest
import LungfishKit
@testable import LungfishApp

@MainActor
final class SidebarFailureReportsTests: XCTestCase {
    func testSaveImportedSampleMetadata() {
        assertFailureAlert(
            SidebarFailureReports.saveImportedSampleMetadata(rawFailureError()),
            title: "Could not save the imported sample metadata",
            rawErrorText: "posix_spawn ENOENT /tmp/x.lock"
        )
    }

    func testCreateFolder() {
        assertFailureAlert(
            SidebarFailureReports.createFolder(rawFailureError()),
            title: "Could not create the folder",
            rawErrorText: "posix_spawn ENOENT /tmp/x.lock"
        )
    }

    func testRenameNamesBothNames() {
        let report = SidebarFailureReports.rename("reads.fastq", to: "sample 1.fastq", rawFailureError())
        assertFailureAlert(report, title: "Could not rename reads.fastq", rawErrorText: "posix_spawn ENOENT /tmp/x.lock")
        XCTAssertTrue(report.nextStep.contains("sample 1.fastq"))
    }

    func testMoveItemsNamesEachItemAndKeepsEachError() {
        let report = SidebarFailureReports.moveItems([
            (name: "reads.fastq", error: rawFailureError("first raw error")),
            (name: "notes.txt", error: rawFailureError("second raw error")),
        ])
        XCTAssertEqual(report.title, "Could not move the selected items")
        XCTAssertTrue(report.whatHappened.contains("reads.fastq"))
        XCTAssertTrue(report.whatHappened.contains("notes.txt"))
        XCTAssertFalse(report.body.contains("raw error"), "raw error text stays out of the body")
        let details = FailurePresenter.alert(for: report).accessoryView as? FailureDetailsView
        XCTAssertTrue(details?.textView.string.contains("first raw error") ?? false)
        XCTAssertTrue(details?.textView.string.contains("second raw error") ?? false)
    }

    func testDeleteItemsNamesTheItem() {
        let report = SidebarFailureReports.deleteItems([(name: "old run", error: rawFailureError())])
        assertFailureAlert(report, title: "Could not delete the selected items", rawErrorText: "posix_spawn ENOENT /tmp/x.lock")
        XCTAssertEqual(report.whatHappened, "Lungfish could not delete old run.")
    }
}
