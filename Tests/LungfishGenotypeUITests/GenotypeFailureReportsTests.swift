// GenotypeFailureReportsTests.swift - The genotype result view's failure alerts (ALERT-PRESENTER)
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import XCTest
import LungfishKit
@testable import LungfishGenotypeUI

@MainActor
final class GenotypeFailureReportsTests: XCTestCase {
    private let raw = "posix_spawn ENOENT /tmp/x.lock"

    private func rawError() -> NSError {
        NSError(domain: "ALERTTestDomain", code: 7, userInfo: [NSLocalizedDescriptionKey: raw])
    }

    /// The title names the step, the body holds no raw text, the details hold it, and the words keep the prose rules.
    private func assertPlainWords(_ report: FailureReport, title: String, file: StaticString = #filePath, line: UInt = #line) {
        let alert = FailurePresenter.alert(for: report)
        XCTAssertEqual(alert.messageText, title, file: file, line: line)
        XCTAssertFalse(alert.informativeText.contains(raw), "raw error text stays out of the body", file: file, line: line)
        let details = alert.accessoryView as? FailureDetailsView
        XCTAssertEqual(details?.textView.string.contains(raw), true, file: file, line: line)
        for text in [report.title, report.whatHappened, report.nextStep] {
            XCTAssertFalse(text.contains("\u{2014}") || text.contains(";") || text.contains(":"), "prose rule in \(text)", file: file, line: line)
        }
    }

    func testExportGenotypeView() {
        let report = GenotypeFailureReports.exportGenotypeView(rawError())
        assertPlainWords(report, title: "Could not export the genotype view")
        XCTAssertFalse(report.nextStep.contains("Operations panel"))
    }

    func testExportGenotypeViewFromTheExportCommandPointsToTheOperationsLog() {
        let report = GenotypeFailureReports.exportGenotypeView(CLIViewerExportRunner.Failure(message: raw))
        assertPlainWords(report, title: "Could not export the genotype view")
        XCTAssertTrue(report.nextStep.contains("Operations panel"))
    }

    func testExportManualHaplotypeDefinitions() {
        let report = GenotypeFailureReports.exportManualHaplotypeDefinitions(rawError())
        assertPlainWords(report, title: "Could not export the manual haplotype definitions")
        XCTAssertFalse(report.nextStep.contains("Operations panel"))
    }

    func testExportManualHaplotypeDefinitionsFromTheExportCommandPointsToTheOperationsLog() {
        let report = GenotypeFailureReports.exportManualHaplotypeDefinitions(CLIViewerExportRunner.Failure(message: raw))
        assertPlainWords(report, title: "Could not export the manual haplotype definitions")
        XCTAssertTrue(report.nextStep.contains("Operations panel"))
    }

    // MARK: Edits of the annotations a bundle keeps

    private func assertAnnotationEdit(
        _ report: FailureReport, title: String, whatHappened: String, again: String,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        assertPlainWords(report, title: title, file: file, line: line)
        XCTAssertEqual(report.whatHappened, whatHappened, file: file, line: line)
        XCTAssertEqual(
            report.nextStep,
            "Check that the bundle folder can be written to and has free space, then \(again) again.",
            file: file, line: line
        )
    }

    func testOpenAnnotationsForSampleStatusSaysTheStatusWasNotChanged() {
        let report = GenotypeFailureReports.openAnnotationsForSampleStatus(rawError())
        assertPlainWords(report, title: "Could not change the sample status")
        XCTAssertEqual(report.whatHappened, "Lungfish could not open the annotations of the bundle, so the sample status was not changed.")
        XCTAssertEqual(report.nextStep, "Check that the bundle folder is still there and can be read, then change the sample status again.")
    }

    func testChangeSampleStatus() {
        assertAnnotationEdit(GenotypeFailureReports.changeSampleStatus(rawError()), title: "Could not change the sample status",
                             whatHappened: "The new sample status was not saved to the bundle.", again: "change the sample status")
    }

    func testSaveSmartCohort() {
        assertAnnotationEdit(GenotypeFailureReports.saveSmartCohort(rawError()), title: "Could not save the smart cohort",
                             whatHappened: "The smart cohort was not saved to the bundle.", again: "save the smart cohort")
    }

    func testDeleteSmartCohort() {
        assertAnnotationEdit(GenotypeFailureReports.deleteSmartCohort(rawError()), title: "Could not delete the smart cohort",
                             whatHappened: "The smart cohort was not deleted from the bundle.", again: "delete the smart cohort")
    }

    func testRestoreBuiltInCohorts() {
        assertAnnotationEdit(GenotypeFailureReports.restoreBuiltInCohorts(rawError()), title: "Could not restore the built-in cohorts",
                             whatHappened: "The built-in cohorts were not restored in the bundle.", again: "restore the built-in cohorts")
    }

    func testSaveAnnotationStyle() {
        assertAnnotationEdit(GenotypeFailureReports.saveAnnotationStyle(rawError()), title: "Could not save the annotation style",
                             whatHappened: "The annotation style was not saved to the bundle.", again: "save the annotation style")
    }

    func testSaveMatrixAnnotation() {
        assertAnnotationEdit(GenotypeFailureReports.saveMatrixAnnotation(rawError()), title: "Could not save the matrix annotation",
                             whatHappened: "The matrix annotation was not saved to the bundle.", again: "save the annotation")
    }

    func testSaveManualHaplotypeAssignments() {
        assertAnnotationEdit(GenotypeFailureReports.saveManualHaplotypeAssignments(rawError()),
                             title: "Could not save the manual haplotype assignments",
                             whatHappened: "The manual haplotype assignments were not saved to the bundle.", again: "save the assignments")
    }

    func testRemoveManualHaplotype() {
        assertAnnotationEdit(GenotypeFailureReports.removeManualHaplotype(rawError()), title: "Could not remove the manual haplotype",
                             whatHappened: "The manual haplotype was not removed from the bundle.", again: "remove the haplotype")
    }

    func testConfirmCall() {
        assertAnnotationEdit(GenotypeFailureReports.confirmCall(rawError()), title: "Could not confirm the call",
                             whatHappened: "The confirmation of the call was not saved to the bundle.", again: "confirm the call")
    }

    func testSaveHaplotypeChange() {
        assertAnnotationEdit(GenotypeFailureReports.saveHaplotypeChange(rawError()), title: "Could not save the haplotype change",
                             whatHappened: "The haplotype change was not saved to the bundle.", again: "save the haplotype change")
    }

    func testAnEditRefusedAsStaleKeepsTheStoresFactAndNamesTheReload() {
        let report = GenotypeFailureReports.deleteSmartCohort(GenotypeAnnotationStorePersistenceError.staleRevision)
        XCTAssertEqual(report.title, "Could not delete the smart cohort")
        XCTAssertEqual(report.whatHappened, "The genotype annotations changed in another process, so this edit was not applied.")
        XCTAssertEqual(report.nextStep, "Reload the bundle, then delete the smart cohort again.")
        XCTAssertEqual(report.details?.hasPrefix("The genotype annotations changed in another process. Reload the bundle before saving this edit."), true)
        for text in [report.title, report.whatHappened, report.nextStep] {
            XCTAssertFalse(text.contains("\u{2014}") || text.contains(";") || text.contains(":"), "prose rule in \(text)")
        }
    }

    func testAnEditWithNoStoreKeepsTheEditorsSentenceAndNamesTheReopen() {
        let report = GenotypeFailureReports.saveHaplotypeChange(GenotypeResultViewController.ManualHaplotypeEditorError.unavailable)
        XCTAssertEqual(report.title, "Could not save the haplotype change")
        XCTAssertEqual(report.whatHappened, "The manual haplotype assignment store is no longer available.")
        XCTAssertEqual(report.nextStep, "Reopen the bundle, then save the haplotype change again.")
        XCTAssertEqual(FailurePresenter.alert(for: report).informativeText, "\(report.whatHappened)\n\n\(report.nextStep)")
    }
}
