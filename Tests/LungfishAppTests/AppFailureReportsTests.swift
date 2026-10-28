// AppFailureReportsTests.swift - The app delegate's failure alerts (ALERT-PRESENTER)
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import XCTest
import LungfishKit
@testable import LungfishApp

@MainActor
final class AppFailureReportsTests: XCTestCase {
    private let raw = "posix_spawn ENOENT /tmp/x.lock"

    func testPrepareReferenceSequencesFolder() {
        assertFailureAlert(
            AppFailureReports.prepareReferenceSequencesFolder(rawFailureError()),
            title: "Could not prepare the Reference Sequences folder",
            rawErrorText: raw
        )
    }

    func testImportReferenceSequence() {
        assertFailureAlert(
            AppFailureReports.importReferenceSequence(rawFailureError()),
            title: "Could not import the reference sequence",
            rawErrorText: raw
        )
    }

    func testPrepareAnalysesFolder() {
        assertFailureAlert(
            AppFailureReports.prepareAnalysesFolder(rawFailureError()),
            title: "Could not prepare the Analyses folder",
            rawErrorText: raw
        )
    }

    func testShowImportedAlignmentsSaysTheImportItselfWorked() {
        let report = AppFailureReports.showImportedAlignments(rawFailureError())
        assertFailureAlert(report, title: "Could not show the imported alignments", rawErrorText: raw)
        XCTAssertTrue(report.whatHappened.contains("were imported"))
    }

    func testImportBAMFile() {
        assertFailureAlert(AppFailureReports.importBAMFile(rawFailureError()), title: "Could not import the BAM file", rawErrorText: raw)
    }

    func testImportAnnotationTrack() {
        assertFailureAlert(
            AppFailureReports.importAnnotationTrack(rawFailureError()),
            title: "Could not import the annotation track",
            rawErrorText: raw
        )
    }

    func testReadBundleForVCFImport() {
        assertFailureAlert(
            AppFailureReports.readBundleForVCFImport(rawFailureError()),
            title: "Could not read the bundle for the VCF import",
            rawErrorText: raw
        )
    }
}
