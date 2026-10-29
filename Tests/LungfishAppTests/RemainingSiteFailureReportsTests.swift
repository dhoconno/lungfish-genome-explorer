// RemainingSiteFailureReportsTests.swift - The last raw-error alerts of ALERT-PRESENTER (ALERT-C4)
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import XCTest
import LungfishKit
import LungfishOperations
import LungfishWorkflow
@testable import LungfishApp

/// Each test builds the alert of one moved site with `FailurePresenter.alert(for:)`. The sites sit behind a
/// private method, a sheet or a command run, so no test reaches one with a real fault. Each words function has a
/// test that reads the title, the two paragraphs, the prose rules and the details area (`assertFailureAlert` in
/// `MainWindowFailureReportsTests.swift`), and the primer test builds the callee's real refusal.
@MainActor
final class RemainingSiteFailureReportsTests: XCTestCase {
    private let raw = "posix_spawn ENOENT /tmp/x.lock"

    // MARK: Primer exports, MainSplitViewController+PrimerAnalysis.swift

    func testPrimerOrderExportNamesTheFolderStepAndKeepsTheRawErrorInTheDetails() {
        let report = MainWindowFailureReports.exportPrimerOrder(rawFailureError(raw))
        assertFailureAlert(report, title: "Could not export the primer order", rawErrorText: raw)
        XCTAssertEqual(report.whatHappened, "Lungfish could not prepare a folder in the project for the primer order, so it was not exported.")
        XCTAssertEqual(report.nextStep, "Check that the project folder can be written to and has free space, then export the primer order again.")
    }

    func testPrimerSelectionExportsNameTheirOwnStep() {
        assertFailureAlert(
            MainWindowFailureReports.exportPrimerAnalysisSelection(isPrimerFASTA: true, rawFailureError(raw)),
            title: "Could not save the primer FASTA bundle", rawErrorText: raw)
        assertFailureAlert(
            MainWindowFailureReports.exportPrimerAnalysisSelection(isPrimerFASTA: false, rawFailureError(raw)),
            title: "Could not extract the reference amplicon", rawErrorText: raw)
    }

    func testTheDestinationsRealRefusalKeepsItsSentenceAndNamesTheProjectFolder() {
        let missing = URL(fileURLWithPath: "/lungfish-no-such-project-\(UUID().uuidString)", isDirectory: true)
        XCTAssertThrowsError(try PrimerAnalysisExportDestination(projectURL: missing, name: "scheme", kind: .primerOrder)) { error in
            let report = MainWindowFailureReports.exportPrimerOrder(error)
            XCTAssertEqual(report.whatHappened, "The originating project is unavailable.")
            XCTAssertTrue(report.nextStep.hasPrefix("Check that the project folder is still in place"))
            let alert = FailurePresenter.alert(for: report)
            XCTAssertEqual(alert.messageText, "Could not export the primer order")
            XCTAssertEqual(alert.informativeText.components(separatedBy: "\n\n").count, 2)
            XCTAssertNotNil(alert.accessoryView as? FailureDetailsView)
        }
    }

    // MARK: FASTQ drawer barcode scout, ViewerViewController+FASTQDrawer.swift

    func testBarcodeDetectionWithAMissingFileSaysSoAndNamesTheSidebarStep() {
        let error = DemultiplexError.inputFileNotFound(URL(fileURLWithPath: "/tmp/reads.fastq"))
        let report = ViewerFailureReports.detectBarcodes(error)
        assertFailureAlert(report, title: "Could not detect the barcodes in the FASTQ file", rawErrorText: "Input FASTQ not found")
        XCTAssertEqual(report.whatHappened, "Lungfish could not find the FASTQ file, so no barcodes were detected.")
        XCTAssertTrue(report.nextStep.hasPrefix("Select the FASTQ bundle in the sidebar again"))
    }

    func testBarcodeDetectionThatStopsKeepsTheToolTextInTheDetails() {
        let error = DemultiplexError.cutadaptFailed(exitCode: 1, stderr: "cutadapt: error: bad adapter")
        let report = ViewerFailureReports.detectBarcodes(error)
        assertFailureAlert(report, title: "Could not detect the barcodes in the FASTQ file", rawErrorText: "cutadapt failed")
        XCTAssertEqual(report.whatHappened, "The barcode search stopped before it finished, so no barcodes were detected.")
    }

    // MARK: Annotation track deletion, ViewerViewController+AnnotationDrawer.swift

    func testAnnotationTrackDeletionPointsToTheOperationsRow() {
        let error = LungfishCLIRunner.RunError.nonZeroExit(status: 2, stderr: "unknown option --track-id")
        let report = ViewerFailureReports.deleteAnnotationTrack("Genes", error)
        assertFailureAlert(report, title: "Could not delete the Genes annotation track", rawErrorText: "unknown option")
        XCTAssertTrue(report.nextStep.contains("Operations panel"))
    }

    func testReloadAfterATrackDeletionSaysTheTrackIsAlreadyGone() {
        let report = ViewerFailureReports.reloadAfterAnnotationTrackDeletion("Genes", rawFailureError(raw))
        assertFailureAlert(report, title: "Could not reload the bundle after deleting the Genes annotation track", rawErrorText: raw)
        XCTAssertTrue(report.whatHappened.hasPrefix("The track was deleted from the bundle"))
        XCTAssertTrue(report.nextStep.hasPrefix("Select the bundle in the sidebar again"))
    }

    func testAnnotationRowDeletionPointsToTheOperationsRow() {
        let error = LungfishCLIRunner.RunError.nonZeroExit(status: 2, stderr: "unknown option --row")
        let report = ViewerFailureReports.deleteAnnotations(error)
        assertFailureAlert(report, title: "Could not delete the annotations", rawErrorText: "unknown option")
        XCTAssertTrue(report.nextStep.contains("Operations panel"))
    }

    func testReloadAfterARowDeletionSaysTheAnnotationsAreAlreadyGone() {
        let report = ViewerFailureReports.reloadAfterAnnotationDeletion(rawFailureError(raw))
        assertFailureAlert(report, title: "Could not reload the bundle after deleting the annotations", rawErrorText: raw)
        XCTAssertTrue(report.whatHappened.hasPrefix("The annotations were deleted from the bundle"))
    }

    // MARK: Merge into New Bundle, SidebarViewController+MenuDelegate.swift

    func testFASTQMergeNamesThePairingAndNameChecks() {
        let report = SidebarFailureReports.mergeIntoNewBundle(kind: .fastq, rawFailureError(raw))
        assertFailureAlert(report, title: "Could not merge the selected FASTQ bundles into a new bundle", rawErrorText: raw)
        XCTAssertTrue(report.nextStep.contains("single-end or all are paired-end"))
    }

    func testReferenceMergePointsToTheOperationsRow() {
        let report = SidebarFailureReports.mergeIntoNewBundle(kind: .reference, rawFailureError(raw))
        assertFailureAlert(report, title: "Could not merge the selected reference bundles into a new bundle", rawErrorText: raw)
        XCTAssertTrue(report.nextStep.hasPrefix("Open the Operations panel to read the log of this merge."))
    }
}
