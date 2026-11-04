// ViewerRefusalWordsTests.swift - A refused viewer command answers in words and not with a beep (Phase 3.2, BEEPS)
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import XCTest
@testable import LungfishApp
import LungfishKit
@testable import LungfishOperations

/// Each refusal runs through its real call site with a recording presenter bound to `ViewerRefusalSeam`, so the test
/// reads the words and no alert opens in the tier. At the base the sites beep and record nothing, so the driven tests fail
/// there with a count of 0 where 1 report is expected.
@MainActor
final class ViewerRefusalWordsTests: XCTestCase {
    @MainActor
    final class Recorder: ViewerRefusalPresenting {
        private(set) var reports: [FailureReport] = []

        func present(_ report: FailureReport, in window: NSWindow?) {
            reports.append(report)
        }
    }

    private var retainedControllers: [ViewerViewController] = []

    override func tearDown() async throws {
        retainedControllers.removeAll()
        try await super.tearDown()
    }

    private func recordRefusals(_ body: () -> Void) -> [FailureReport] {
        let recorder = Recorder()
        ViewerRefusalSeam.$presenter.withValue(recorder) { body() }
        return recorder.reports
    }

    private func makeController() -> ViewerViewController {
        let controller = ViewerViewController()
        controller.loadView()
        controller.viewerView.frame = NSRect(x: 0, y: 0, width: 800, height: 300)
        retainedControllers.append(controller)
        return controller
    }

    private func makeResult(name: String = "geneA", rowID: Int64? = nil) -> AnnotationSearchIndex.SearchResult {
        AnnotationSearchIndex.SearchResult(
            name: name, chromosome: "chr1", start: 10, end: 50, trackId: "track1", type: "gene", strand: "+",
            annotationRowId: rowID
        )
    }

    private func onlyReport(_ reports: [FailureReport], file: StaticString = #filePath, line: UInt = #line) throws -> FailureReport {
        XCTAssertEqual(reports.count, 1, "the refusal shows words and not a beep", file: file, line: line)
        return try XCTUnwrap(reports.first, "no words were shown", file: file, line: line)
    }

    // MARK: - The words, by meaning

    func testEveryReportSaysWhatWasMissingAndWhatToTry() {
        let reports: [(String, FailureReport)] = [
            ("empty name", ViewerRefusalReports.annotationForm(
                step: "Save the annotation", command: "Edit Annotation", name: "", type: "gene", chromosome: "chr1", start: "1", end: "5"
            )),
            ("write failed", ViewerRefusalReports.annotationNotWritten(step: "Save the annotation", name: "geneA")),
            ("not editable", ViewerRefusalReports.annotationNotEditable(step: "Edit the annotation")),
            ("nothing to delete", ViewerRefusalReports.nothingToDelete(count: 3)),
            ("one to delete", ViewerRefusalReports.nothingToDelete(count: 1)),
            ("no bundle", ViewerRefusalReports.noBundleToDeleteFrom(step: "Delete the annotation track")),
            ("locus", ViewerRefusalReports.locusNotRead(input: "chr1:abc")),
            ("sequence", ViewerRefusalReports.sequenceNotFound(name: "zzz", knownChromosomes: ["chr1", "chr2"])),
            ("no sequence open", ViewerRefusalReports.sequenceNotFound(name: "zzz", knownChromosomes: [])),
            ("no sequence", ViewerRefusalReports.noSequenceToCopy(step: "Copy the selection")),
            ("no selection", ViewerRefusalReports.noSelectionToCopy(step: "Copy the selection")),
        ]
        for (name, report) in reports {
            XCTAssertTrue(report.title.hasPrefix("Could not "), "\(name): the title names the step: \(report.title)")
            XCTAssertTrue(report.whatHappened.hasSuffix("."), "\(name): what happened reads as a sentence: \(report.whatHappened)")
            XCTAssertTrue(
                report.whatHappened.contains("not") || report.whatHappened.contains("no ") || report.whatHappened.contains("No ")
                    || report.whatHappened.contains("could not") || report.whatHappened.contains("cannot"),
                "\(name): what happened says what was missing: \(report.whatHappened)"
            )
            let firstWord = report.nextStep.split(separator: " ").first.map(String.init) ?? ""
            XCTAssertTrue(
                ["Open", "Select", "Check", "Choose", "Type"].contains(firstWord),
                "\(name): the next step starts with something to do: \(report.nextStep)"
            )
            XCTAssertTrue(report.nextStep.hasSuffix("."), "\(name): the next step reads as a sentence: \(report.nextStep)")
            XCTAssertNil(report.details, "\(name): a refusal has no raw error text")
        }
    }

    func testTheFormNamesTheFirstBoxThatIsWrong() {
        func problem(_ name: String, _ type: String, _ chromosome: String, _ start: String, _ end: String) -> String? {
            ViewerRefusalReports.annotationFormProblem(name: name, type: type, chromosome: chromosome, start: start, end: end)
        }
        XCTAssertEqual(problem("", "gene", "chr1", "1", "5"), "The Name box is empty")
        XCTAssertEqual(problem("a", " ", "chr1", "1", "5"), "The Type box is empty")
        XCTAssertEqual(problem("a", "gene", "", "1", "5"), "The Chromosome box is empty")
        XCTAssertEqual(problem("a", "gene", "chr1", "x", "5"), "Start must be a whole number, and \"x\" is not one")
        XCTAssertEqual(problem("a", "gene", "chr1", "0", "5"), "Start must be 1 or more, and it is 0")
        XCTAssertEqual(problem("a", "gene", "chr1", "9", "5"), "End (5) comes before Start (9)")
        XCTAssertNil(problem("a", "gene", "chr1", "1", "5"), "a complete form has no problem, so a refusal is the failed write")
        XCTAssertEqual(
            ViewerRefusalReports.annotationForm(
                step: "Add the annotation", command: "Add Annotation", name: "a", type: "gene", chromosome: "chr1", start: "1", end: "5"
            ),
            ViewerRefusalReports.annotationNotWritten(step: "Add the annotation", name: "a")
        )
    }

    func testTheMetadataSheetWordsSayWhatToDo() {
        for words in [ViewerRefusalReports.metadataNothingToExport, ViewerRefusalReports.metadataNothingToImport] {
            XCTAssertTrue(words.hasSuffix("."), words)
            XCTAssertTrue(words.contains("Tick") || words.contains("Check"), words)
            XCTAssertLessThanOrEqual(
                words.count, 100,
                "the sheet shows this on one 11 point line about 600 points wide, and a longer sentence loses its end"
            )
        }
    }

    // MARK: - The live presenter

    /// With no window and no key window, `FailurePresenter` would run an application-modal alert, which a unit test never
    /// answers, so a test that forgot `recordRefusals` would hang the tier. The live presenter shows nothing then. The
    /// choice is a pure function, so this test opens no alert (the pattern of
    /// `ClassifierNoProjectRefusalTests.testTheLivePresenterChoosesASheetOnlyForAGivenWindow`).
    func testTheLivePresenterShowsNothingWhenThereIsNoWindow() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 100), styleMask: [.titled], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        XCTAssertFalse(
            LiveViewerRefusalPresenter.canShow(in: nil, keyWindow: nil),
            "no window and no key window would run an application-modal alert"
        )
        XCTAssertTrue(LiveViewerRefusalPresenter.canShow(in: window, keyWindow: nil), "a given window holds the sheet")
        XCTAssertTrue(LiveViewerRefusalPresenter.canShow(in: nil, keyWindow: window), "the key window holds the sheet when none is given")
    }

    // MARK: - The drawer, through its real call sites

    func testSavingAnEditWithAnEmptyNameNamesTheBox() throws {
        let drawer = AnnotationTableDrawerView()
        let result = makeResult()
        let form = drawer.makeAnnotationEditForm(for: result, currentRecord: nil)
        form.nameField.stringValue = ""
        let reports = recordRefusals { drawer.performAnnotationEdit(result: result, rowID: 7, form: form) }
        let report = try onlyReport(reports)
        XCTAssertEqual(report.title, "Could not save the annotation")
        XCTAssertTrue(report.whatHappened.contains("The Name box is empty"), report.whatHappened)
        XCTAssertTrue(report.nextStep.contains("Edit Annotation"), report.nextStep)
    }

    func testSavingAnEditWithEndBeforeStartSaysSo() throws {
        let drawer = AnnotationTableDrawerView()
        let result = makeResult()
        let form = drawer.makeAnnotationEditForm(for: result, currentRecord: nil)
        form.startField.stringValue = "50"
        form.endField.stringValue = "10"
        let reports = recordRefusals { drawer.performAnnotationEdit(result: result, rowID: 7, form: form) }
        let report = try onlyReport(reports)
        XCTAssertTrue(report.whatHappened.contains("End (10) comes before Start (50)"), report.whatHappened)
    }

    func testSavingAnEditWithNoAnnotationDatabaseOpenSaysSo() throws {
        let drawer = AnnotationTableDrawerView()
        let result = makeResult()
        let form = drawer.makeAnnotationEditForm(for: result, currentRecord: nil)
        let reports = recordRefusals { drawer.performAnnotationEdit(result: result, rowID: 7, form: form) }
        let report = try onlyReport(reports)
        XCTAssertEqual(report.title, "Could not save the annotation")
        XCTAssertTrue(report.whatHappened.contains("annotation database"), report.whatHappened)
    }

    func testEditingAnAnnotationThatHasNoRecordIsAnswered() throws {
        let drawer = AnnotationTableDrawerView()
        let item = NSMenuItem(title: "Edit Annotation", action: nil, keyEquivalent: "")
        let reports = recordRefusals { drawer.editAnnotationAction(item) }
        let report = try onlyReport(reports)
        XCTAssertEqual(report.title, "Could not edit the annotation")
        XCTAssertTrue(report.whatHappened.contains("annotation database"), report.whatHappened)
    }

    // MARK: - Deleting annotations, through the viewer

    func testDeletingAnnotationsWithNoDatabaseRecordIsAnswered() throws {
        let controller = makeController()
        let drawer = AnnotationTableDrawerView()
        let rows = [makeResult(name: "a"), makeResult(name: "b"), makeResult(name: "c")]
        let reports = recordRefusals { controller.annotationDrawer(drawer, didRequestDeleteAnnotations: rows) }
        let report = try onlyReport(reports)
        XCTAssertEqual(report.title, "Could not delete the selected annotations")
        XCTAssertTrue(report.whatHappened.contains("None of the 3 selected annotations"), report.whatHappened)
    }

    func testDeletingAnnotationsWithNoBundleOpenIsAnswered() throws {
        let controller = makeController()
        let drawer = AnnotationTableDrawerView()
        let reports = recordRefusals {
            controller.annotationDrawer(drawer, didRequestDeleteAnnotations: [self.makeResult(rowID: 5)])
        }
        let report = try onlyReport(reports)
        XCTAssertEqual(report.title, "Could not delete the selected annotation")
        XCTAssertTrue(report.whatHappened.contains("no reference bundle"), report.whatHappened)
    }

    func testDeletingATrackWithNoBundleOpenIsAnswered() throws {
        let controller = makeController()
        let drawer = AnnotationTableDrawerView()
        let reports = recordRefusals {
            controller.annotationDrawer(drawer, didRequestDeleteAnnotationTrack: "track1", trackName: "Genes")
        }
        let report = try onlyReport(reports)
        XCTAssertEqual(report.title, "Could not delete the annotation track")
        XCTAssertTrue(report.whatHappened.contains("no reference bundle"), report.whatHappened)
    }

    // MARK: - The ruler's position box, through the viewer

    func testATypedPositionThatCannotBeReadIsAnswered() throws {
        let controller = makeController()
        let ruler = EnhancedCoordinateRulerView(frame: NSRect(x: 0, y: 0, width: 800, height: 30))
        let reports = recordRefusals { controller.ruler(ruler, didRequestPositionInput: "chr1:abc") }
        let report = try onlyReport(reports)
        XCTAssertEqual(report.title, "Could not go to the position")
        XCTAssertTrue(report.whatHappened.contains("chr1:abc"), report.whatHappened)
    }

    func testATypedSequenceNameThatIsNotThereIsAnswered() throws {
        let controller = makeController()
        let ruler = EnhancedCoordinateRulerView(frame: NSRect(x: 0, y: 0, width: 800, height: 30))
        let reports = recordRefusals { controller.ruler(ruler, didRequestPositionInput: "zzz") }
        let report = try onlyReport(reports)
        XCTAssertEqual(report.title, "Could not go to the sequence")
        XCTAssertTrue(report.whatHappened.contains("zzz"), report.whatHappened)
    }

    // MARK: - Copying with nothing to copy, through the sequence viewer

    func testCopyComplementWithNothingOpenSaysSo() throws {
        let viewerView = try XCTUnwrap(makeController().viewerView)
        let reports = recordRefusals { viewerView.copyComplementAction(nil) }
        let report = try onlyReport(reports)
        XCTAssertEqual(report.title, "Could not copy the complement")
        XCTAssertTrue(report.whatHappened.contains("no sequence"), report.whatHappened)
    }

    func testCopyReverseComplementWithNothingOpenSaysSo() throws {
        let viewerView = try XCTUnwrap(makeController().viewerView)
        let reports = recordRefusals { viewerView.copyReverseComplementAction(nil) }
        let report = try onlyReport(reports)
        XCTAssertEqual(report.title, "Could not copy the reverse complement")
    }

    func testCopyingTheSelectionWithNothingOpenSaysSo() throws {
        let viewerView = try XCTUnwrap(makeController().viewerView)
        let reports = recordRefusals { viewerView.copySelectionToClipboard() }
        let report = try onlyReport(reports)
        XCTAssertEqual(report.title, "Could not copy the selection")
        XCTAssertTrue(report.whatHappened.contains("no sequence"), report.whatHappened)
    }
}
