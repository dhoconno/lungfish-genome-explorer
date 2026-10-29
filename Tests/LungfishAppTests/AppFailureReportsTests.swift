// AppFailureReportsTests.swift - The app delegate's failure alerts (ALERT-PRESENTER)
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import XCTest
import LungfishCore
import LungfishKit
import LungfishWorkflow
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

    func testShowImportedVariantsSaysTheImportItselfWorked() {
        let report = AppFailureReports.showImportedVariants(rawFailureError())
        assertFailureAlert(report, title: "Could not show the imported variants", rawErrorText: raw)
        XCTAssertTrue(report.whatHappened.contains("were imported"))
    }

    func testImportVCFFilePointsToTheOperationsLog() {
        let report = AppFailureReports.importVCFFile(rawFailureError())
        assertFailureAlert(report, title: "Could not import the VCF file", rawErrorText: raw)
        XCTAssertTrue(report.nextStep.contains("Operations panel"))
    }

    func testImportGeneiousExportPointsToTheOperationsLog() {
        let report = AppFailureReports.importGeneiousExport(rawFailureError())
        assertFailureAlert(report, title: "Could not import the Geneious export", rawErrorText: raw)
        XCTAssertTrue(report.nextStep.contains("Operations panel"))
    }

    func testRunSequenceOperationNamesTheOperation() {
        let report = AppFailureReports.runSequenceOperation(named: "Find ORFs", rawFailureError())
        assertFailureAlert(report, title: "Could not run Find ORFs", rawErrorText: raw)
        XCTAssertTrue(report.nextStep.contains("Operations panel"))
    }

    func testReadCzIdResultPointsToNoOperationsRow() {
        let report = AppFailureReports.readCzIdResult(rawFailureError())
        assertFailureAlert(report, title: "Could not read the CZ-ID result", rawErrorText: raw)
        XCTAssertFalse(report.nextStep.contains("Operations panel"))
    }

    func testImportCzIdResultPointsToTheOperationsLog() {
        let report = AppFailureReports.importCzIdResult(rawFailureError())
        assertFailureAlert(report, title: "Could not import the CZ-ID result", rawErrorText: raw)
        XCTAssertTrue(report.nextStep.contains("Operations panel"))
    }

    func testReadFASTQSampleSheetKeepsTheSheetReadersRefusalInTheBody() {
        let report = AppFailureReports.readFASTQSampleSheet(FASTQSampleSheetError.missingRequiredColumns)
        assertFailureAlert(report, title: "Could not read the FASTQ sample sheet", rawErrorText: "FASTQSampleSheetError")
        XCTAssertEqual(report.whatHappened, "Sample sheet must contain sample, r1, and r2 columns.")
        XCTAssertTrue(report.nextStep.contains("Fix the sample sheet"))
    }

    func testReadFASTQSampleSheetWordsAFileReadErrorInGeneralTerms() {
        let report = AppFailureReports.readFASTQSampleSheet(rawFailureError())
        assertFailureAlert(report, title: "Could not read the FASTQ sample sheet", rawErrorText: raw)
        XCTAssertTrue(report.whatHappened.contains("could not read the file"))
        XCTAssertFalse(report.nextStep.contains("Operations panel"))
    }

    func testImportApplicationExportNamesTheKindAndPointsToTheOperationsLog() {
        let report = AppFailureReports.importApplicationExport(named: "CLC Workbench", rawFailureError())
        assertFailureAlert(report, title: "Could not import the CLC Workbench export", rawErrorText: raw)
        XCTAssertTrue(report.nextStep.contains("Operations panel"))
    }

    func testImportNativeBundleNamesTheAlignmentAndTheTree() {
        let alignment = AppFailureReports.importNativeBundle(.msa, rawFailureError())
        assertFailureAlert(alignment, title: "Could not import the multiple sequence alignment", rawErrorText: raw)
        let tree = AppFailureReports.importNativeBundle(.tree, rawFailureError())
        assertFailureAlert(tree, title: "Could not import the phylogenetic tree", rawErrorText: raw)
        XCTAssertTrue(tree.nextStep.contains("Operations panel"))
    }

    func testStartSequenceExportKeepsTheResolversRefusalsInTheBody() {
        let stale = AppFailureReports.startSequenceExport(SequenceExportSourceResolver.CaptureError.staleDocument("Genome A"))
        assertFailureAlert(stale, title: "Could not start the sequence export", rawErrorText: "CaptureError")
        XCTAssertEqual(stale.whatHappened, "The selected document Genome A is no longer open.")
        XCTAssertEqual(stale.nextStep, "Select it again, then export again.")
        let native = AppFailureReports.startSequenceExport(SequenceExportSourceResolver.CaptureError.unavailableNativeDocument("Genome B"))
        assertFailureAlert(native, title: "Could not start the sequence export", rawErrorText: "CaptureError")
        XCTAssertEqual(native.whatHappened, "The selected project sequence Genome B is unavailable.")
        XCTAssertTrue(native.nextStep.contains("Reopen the project"))
        let missing = AppFailureReports.startSequenceExport(SequenceExportSourceResolver.CaptureError.missingFileURL("Genome C"))
        assertFailureAlert(missing, title: "Could not start the sequence export", rawErrorText: "CaptureError")
        XCTAssertEqual(missing.whatHappened, "The selected source Genome C has no file location.")
    }

    func testStartSequenceExportWordsAnyOtherErrorInGeneralTerms() {
        let report = AppFailureReports.startSequenceExport(rawFailureError())
        assertFailureAlert(report, title: "Could not start the sequence export", rawErrorText: raw)
        XCTAssertFalse(report.nextStep.contains("Operations panel"))
    }

    func testReadAnnotationsForExportPointsToNoOperationsRow() {
        let report = AppFailureReports.readAnnotationsForExport(rawFailureError())
        assertFailureAlert(report, title: "Could not read the annotations for export", rawErrorText: raw)
        XCTAssertFalse(report.nextStep.contains("Operations panel"))
    }

    func testAddReferenceBundleAnnotationSaysItDidNotFinishAndPointsToTheOperationsLog() {
        let report = AppFailureReports.addReferenceBundleAnnotation(rawFailureError())
        assertFailureAlert(report, title: "Could not add the annotation", rawErrorText: raw)
        XCTAssertTrue(report.whatHappened.contains("did not finish"))
        XCTAssertTrue(report.nextStep.contains("Operations panel"))
    }

    func testReloadBundleAfterSequenceAnnotationSaysTheWorkFinishedAndPointsToNoRow() {
        let report = AppFailureReports.reloadBundleAfterSequenceAnnotation(rawFailureError())
        assertFailureAlert(report, title: "Could not reload the bundle", rawErrorText: raw)
        XCTAssertTrue(report.whatHappened.contains("finished"))
        XCTAssertFalse(report.nextStep.contains("Operations panel"))
    }

    func testPrepareProvenanceForExportPointsToNoOperationsRow() {
        let report = AppFailureReports.prepareProvenanceForExport(rawFailureError())
        assertFailureAlert(report, title: "Could not prepare the provenance for export", rawErrorText: raw)
        XCTAssertFalse(report.nextStep.contains("Operations panel"))
    }

    func testResolveProjectLockKeepsTheTwoRefusalsTheLockResolverWords() {
        let acquiredText = "Another session acquired the project lock. Try opening the project again."
        let acquired = AppFailureReports.resolveProjectLock(
            CocoaError(.fileLocking, userInfo: [NSLocalizedDescriptionKey: acquiredText])
        )
        assertFailureAlert(acquired, title: "Could not resolve the project lock", rawErrorText: acquiredText)
        XCTAssertEqual(acquired.whatHappened, "Another session acquired the project lock.")
        XCTAssertEqual(acquired.nextStep, "Open the project again.")
        let movedText = "The project folder changed while resolving its lock. Locate the original folder and try again."
        let moved = AppFailureReports.resolveProjectLock(
            CocoaError(.fileReadUnknown, userInfo: [NSLocalizedDescriptionKey: movedText])
        )
        assertFailureAlert(moved, title: "Could not resolve the project lock", rawErrorText: movedText)
        XCTAssertEqual(moved.whatHappened, "The project folder changed while Lungfish was resolving its lock.")
        XCTAssertTrue(moved.nextStep.contains("Locate the original folder"))
    }

    func testResolveProjectLockWordsAnyOtherErrorInGeneralTerms() {
        let report = AppFailureReports.resolveProjectLock(rawFailureError())
        assertFailureAlert(report, title: "Could not resolve the project lock", rawErrorText: raw)
        XCTAssertTrue(report.whatHappened.contains("project did not open"))
        XCTAssertFalse(report.nextStep.contains("Operations panel"))
    }

    func testMigrateProjectKeepsTheVersionRefusalAndTheChangedMetadataRefusal() {
        let version = AppFailureReports.migrateProject(ProjectFileError.incompatibleVersion(found: "1.0", required: "2.0"))
        assertFailureAlert(version, title: "Could not migrate the project", rawErrorText: "Incompatible project version")
        XCTAssertTrue(version.whatHappened.contains("1.0"))
        XCTAssertTrue(version.whatHappened.contains("2.0"))
        XCTAssertTrue(version.nextStep.contains("version of Lungfish that made it"))
        let changed = AppFailureReports.migrateProject(
            ProjectFileError.loadError(message: "Project metadata changed before migration. Reopen the project.")
        )
        assertFailureAlert(changed, title: "Could not migrate the project", rawErrorText: "Project metadata changed before migration")
        XCTAssertEqual(changed.nextStep, "Reopen the project, then migrate it again.")
    }

    func testMigrateProjectWordsAnyOtherErrorInGeneralTerms() {
        let report = AppFailureReports.migrateProject(rawFailureError())
        assertFailureAlert(report, title: "Could not migrate the project", rawErrorText: raw)
        XCTAssertEqual(report.whatHappened, "The project was not migrated.")
        let saveFailure = AppFailureReports.migrateProject(ProjectFileError.saveError(message: raw))
        assertFailureAlert(saveFailure, title: "Could not migrate the project", rawErrorText: raw)
        XCTAssertEqual(saveFailure.whatHappened, "The project was not migrated.")
    }

    func testUpdateAndDeleteReferenceBundleAnnotationPointToTheOperationsLog() {
        let update = AppFailureReports.updateReferenceBundleAnnotation(rawFailureError())
        assertFailureAlert(update, title: "Could not update the annotation", rawErrorText: raw)
        let delete = AppFailureReports.deleteReferenceBundleAnnotation(rawFailureError())
        assertFailureAlert(delete, title: "Could not delete the annotation", rawErrorText: raw)
        for report in [update, delete] {
            XCTAssertTrue(report.whatHappened.contains("did not finish"))
            XCTAssertTrue(report.nextStep.contains("Operations panel"))
        }
    }
}
