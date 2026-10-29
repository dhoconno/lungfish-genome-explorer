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

    func testExportSequencesKeepsTheChosenFileNameInTheBody() {
        let sentence = "No sequences found in empty.seq."
        let report = AppFailureReports.exportSequences(SequenceExportRoute.RouteError(detail: sentence))
        XCTAssertEqual(report.title, "Could not export the sequences")
        XCTAssertEqual(report.whatHappened, sentence)
        XCTAssertEqual(report.nextStep, "Choose files that hold sequences, then export again.")
        XCTAssertEqual(report.details?.contains(sentence), true)
    }

    func testExportSequencesNamesAMissingInputFile() {
        let report = AppFailureReports.exportSequences(SequenceExportRoute.RouteError(detail: "Input file not found: /Users/me/a.fa"))
        XCTAssertEqual(report.whatHappened, "Lungfish could not find the file /Users/me/a.fa.")
        XCTAssertEqual(report.nextStep, "Check that the file is still where it was, then export again.")
    }

    func testExportSequencesKeepsOtherCommandTextOutOfTheBody() {
        let report = AppFailureReports.exportSequences(SequenceExportRoute.RouteError(detail: "lungfish-cli convert exited with status 3"))
        assertFailureAlert(report, title: "Could not export the sequences", rawErrorText: "exited with status 3")
        XCTAssertTrue(report.nextStep.contains("Operations panel"))
    }

    func testStageSequenceExportKeepsTheEmptySelectionSentence() {
        let sentence = "No sequences found in selected files."
        let error = NSError(domain: "com.lungfish.browser", code: 1, userInfo: [NSLocalizedDescriptionKey: sentence])
        let report = AppFailureReports.stageSequenceExport(error)
        XCTAssertEqual(report.whatHappened, sentence)
        XCTAssertEqual(report.nextStep, "Choose files that hold sequences, then export again.")
    }

    func testStageSequenceExportPointsToNoOperationsRow() {
        let report = AppFailureReports.stageSequenceExport(rawFailureError())
        assertFailureAlert(report, title: "Could not export the sequences", rawErrorText: raw)
        XCTAssertFalse(report.nextStep.contains("Operations panel"))
    }
}
