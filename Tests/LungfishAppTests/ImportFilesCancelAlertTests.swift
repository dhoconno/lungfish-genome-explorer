// ImportFilesCancelAlertTests.swift - File > Import Files... counts a cancelled file as neither a success nor a failure
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.11 lane U62 (W4, inventory fact F26). File > Import Files... tracks each file it hands to
// the sidebar import and ends with the `Import Completed with Errors` alert when any file posted
// `success: false`. A file the user cancelled posts the same, so a cancel read as a failure. These
// tests drive `importProjectFilesFromURLs` with a recording presenter bound through
// `AppDelegate.ImportFilesOutcomeSeam` and read the outcome the request ends with, the words of its
// alert included. A request that shows no alert still reaches the presenter, so a test that
// expects no alert waits for the end of the request and then reads that there is none.

import AppKit
import XCTest
@testable import LungfishApp
@testable import LungfishCore
@testable import LungfishIO
import LungfishKit
import LungfishKitTestSupport
import LungfishTestSupport
import LungfishWorkflow

/// Records how File > Import Files... requests ended, in place of showing the alert.
@MainActor
final class RecordingImportFilesOutcomePresenter: ImportFilesOutcomePresenting {
    struct Presentation {
        let outcome: ImportFilesOutcome
        let window: NSWindow?
    }

    private(set) var presentations: [Presentation] = []

    func present(_ outcome: ImportFilesOutcome, on window: NSWindow?) {
        presentations.append(Presentation(outcome: outcome, window: window))
    }
}

@MainActor
final class ImportFilesCancelAlertTests: XCTestCase {
    private var root: URL!
    private var project: URL!
    private var sources: URL!
    private var delegate: AppDelegate!
    private var controller: MainWindowController!
    private var lockedFiles: [URL] = []
    private var priorCLIPath: String??
    private var rowsBefore: Set<UUID> = []

    override func setUp() async throws {
        try await super.setUp()
        _ = NSApplication.shared
        OperationCenter.useTemporaryFailureReportsForTesting()
        rowsBefore = Set(OperationCenter.shared.items.map(\.id))
        root = try TestTempDirectory.make(prefix: "import-files-outcome")
        project = root.appendingPathComponent("Fixture.lungfish", isDirectory: true)
        sources = root.appendingPathComponent("Sources", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: sources, withIntermediateDirectories: true)
        delegate = makeAppDelegateWithTemporaryState()
        controller = MainWindowController()
        delegate.mainWindowController = controller
        controller.mainSplitViewController?.sidebarController.openProject(at: project)
    }

    override func tearDown() async throws {
        if let window = controller?.window, let sheet = window.attachedSheet { window.endSheet(sheet) }
        controller?.mainSplitViewController?.sidebarController.closeProject()
        for url in lockedFiles {
            try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path)
        }
        if let priorCLIPath {
            if let priorCLIPath { setenv("LUNGFISH_CLI_PATH", priorCLIPath, 1) } else { unsetenv("LUNGFISH_CLI_PATH") }
        }
        for row in OperationCenter.shared.items where !rowsBefore.contains(row.id) {
            OperationCenter.shared.clearItem(id: row.id)
        }
        TestTempDirectory.cleanup(root)
        try await super.tearDown()
    }

    // MARK: - Pins of the alert as it stands

    /// A batch in which every file fails ends with the alert, in today's words.
    func testABatchOfFailuresOnlyEndsWithImportCompletedWithErrors() async throws {
        let urls = [try makeLockedFile("first.txt"), try makeLockedFile("second.txt")]
        let recorder = await importFiles(urls)

        XCTAssertEqual(recorder.presentations.count, 1, "one request ends once")
        let outcome = try XCTUnwrap(recorder.presentations.first).outcome
        XCTAssertEqual(outcome.alert, ImportFilesOutcome.Alert(
            title: "Import Completed with Errors",
            message: "0 succeeded, 2 failed."
        ))
        XCTAssertTrue(recorder.presentations.first?.window === controller.window, "the alert sits on the import's window")
    }

    /// A batch of one success and one failure names both counts.
    func testABatchOfOneSuccessAndOneFailureNamesBoth() async throws {
        let urls = [try makeTextFile("notes.txt"), try makeLockedFile("locked.txt")]
        let recorder = await importFiles(urls)

        let outcome = try XCTUnwrap(recorder.presentations.first).outcome
        XCTAssertEqual(outcome.alert?.title, "Import Completed with Errors")
        XCTAssertEqual(outcome.alert?.message, "1 succeeded, 1 failed.")
    }

    /// A batch in which every file imports ends without an alert.
    func testABatchOfSuccessesOnlyEndsWithNoAlert() async throws {
        let urls = [try makeTextFile("one.txt"), try makeTextFile("two.txt")]
        let recorder = await importFiles(urls)

        XCTAssertEqual(recorder.presentations.count, 1)
        XCTAssertNil(recorder.presentations.first?.outcome.alert)
        XCTAssertEqual(recorder.presentations.first?.outcome, ImportFilesOutcome(succeeded: 2, failed: 0))
    }

    // MARK: - A cancelled file is not a failure

    /// A GFF whose settings sheet is cancelled ends the import with nothing to report.
    func testCancellingAGFFInItsSettingsSheetEndsWithNoAlert() async throws {
        try addReferenceBundle()
        let gff = try makeAnnotationFile("genes.gff3")
        let recorder = await importFiles([gff]) { await self.answerSheet(.alertSecondButtonReturn) }

        XCTAssertEqual(recorder.presentations.count, 1)
        XCTAssertNil(recorder.presentations.first?.outcome.alert, "a cancel is not a failure")
        XCTAssertEqual(recorder.presentations.first?.outcome.succeeded, 0)
    }

    /// An annotation row whose run ends in `CancellationError` (the row's Cancel) is a cancel too.
    func testAnAnnotationRowThatEndsInCancellationErrorEndsWithNoAlert() async throws {
        try addReferenceBundle()
        let marker = root.appendingPathComponent("launched")
        try useFakeCLI("""
        #!/bin/sh
        touch "\(marker.path)"
        while true; do sleep 0.1; done
        """)
        let gff = try makeAnnotationFile("genes.gff3")
        let recorder = await importFiles([gff]) {
            await self.answerSheet(.alertFirstButtonReturn)
            let launched = await waitUntil(timeout: .seconds(30)) { FileManager.default.fileExists(atPath: marker.path) }
            XCTAssertTrue(launched, "the annotation row never launched the command")
            let started = OperationCenter.shared.items.first { !self.rowsBefore.contains($0.id) }
            guard let started else { return XCTFail("the import started no row") }
            OperationCenter.shared.cancel(id: started.id)
        }

        XCTAssertEqual(recorder.presentations.count, 1)
        XCTAssertNil(recorder.presentations.first?.outcome.alert, "the row's cancel is not a failure")
    }

    /// A FASTQ file whose import sheet is cancelled ends the import with nothing to report.
    func testCancellingOneFASTQImportEndsWithNoAlert() async throws {
        let fastq = try makeFASTQFile("sample.fastq")
        let recorder = await importFiles([fastq]) { await self.clickSheetButton(titled: "Cancel") }

        XCTAssertEqual(recorder.presentations.count, 1)
        XCTAssertNil(recorder.presentations.first?.outcome.alert, "a cancelled FASTQ import is not a failure")
    }

    /// A batch of one success, one failure and one cancel names only the success and the failure.
    func testABatchOfOneFailureAndOneCancelNamesOnlyTheFailure() async throws {
        try addReferenceBundle()
        let urls = [try makeTextFile("notes.txt"), try makeLockedFile("locked.txt"), try makeAnnotationFile("genes.gff3")]
        let recorder = await importFiles(urls) { await self.answerSheet(.alertSecondButtonReturn) }

        XCTAssertEqual(recorder.presentations.count, 1)
        XCTAssertEqual(recorder.presentations.first?.outcome.alert, ImportFilesOutcome.Alert(
            title: "Import Completed with Errors",
            message: "1 succeeded, 1 failed."
        ), "the cancel is named nowhere")
    }

    // MARK: - The outcome and the notice

    /// The tracker files a cancelled file as a failed one, and the outcome takes it back out.
    func testTheOutcomeTakesCancelledFilesOutOfItsFailures() {
        let update = SidebarImportRequestTrackerUpdate(pendingCount: 0, succeeded: 1, failed: 2, isFinished: true)
        let outcome = ImportFilesOutcome(update: update, cancelled: 1)
        XCTAssertEqual(outcome, ImportFilesOutcome(succeeded: 1, failed: 1, cancelled: 1))
        XCTAssertEqual(outcome.alert?.message, "1 succeeded, 1 failed.")

        let cancelsOnly = SidebarImportRequestTrackerUpdate(pendingCount: 0, succeeded: 0, failed: 2, isFinished: true)
        XCTAssertNil(ImportFilesOutcome(update: cancelsOnly, cancelled: 2).alert, "two cancels and nothing else")
    }

    /// The drop-completed notice carries `cancelled`, false unless the caller says the user cancelled.
    func testTheDropCompletedNoticeCarriesTheCancelledKey() throws {
        let split = try XCTUnwrap(controller.mainSplitViewController)
        let seen = NoticeBox()
        let token = NotificationCenter.default.addObserver(
            forName: .sidebarFileDropCompleted, object: split, queue: nil
        ) { note in
            seen.add(cancelled: note.userInfo?["cancelled"] as? Bool, success: note.userInfo?["success"] as? Bool)
        }
        defer { NotificationCenter.default.removeObserver(token) }
        let url = sources.appendingPathComponent("a.fastq")

        split.postSidebarFileDropCompleted(requestID: "r", sourceURL: url, success: false, error: "Cancelled by user", cancelled: true)
        split.postSidebarFileDropCompleted(requestID: "r", sourceURL: url, success: false, error: "disk full")
        split.postSidebarFileDropCompleted(requestID: "r", sourceURL: url, success: true, error: nil)

        XCTAssertEqual(seen.cancelled, [true, false, false])
        XCTAssertEqual(seen.success, [false, false, true], "a cancel still posts success false, for any reader that ignores the key")
    }

    private final class NoticeBox: @unchecked Sendable {
        private(set) var cancelled: [Bool?] = []
        private(set) var success: [Bool?] = []

        func add(cancelled: Bool?, success: Bool?) {
            self.cancelled.append(cancelled)
            self.success.append(success)
        }
    }

    // MARK: - The live presenter

    /// The live presenter shows the alert as a sheet on a given window, in the outcome's words.
    func testTheLivePresenterShowsTheAlertAsASheetOnAGivenWindow() async throws {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 300, height: 200),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        defer {
            if let sheet = window.attachedSheet { window.endSheet(sheet) }
            window.close()
        }
        LiveImportFilesOutcomePresenter().present(ImportFilesOutcome(succeeded: 1, failed: 2), on: window)
        _ = await waitUntil(timeout: .seconds(5)) { window.attachedSheet != nil }

        let texts = window.attachedSheet.map { Self.textFields(in: $0.contentView) } ?? []
        XCTAssertTrue(texts.contains("Import Completed with Errors"), "\(texts)")
        XCTAssertTrue(texts.contains("1 succeeded, 2 failed."), "\(texts)")
    }

    /// The live presenter shows nothing for an outcome without an alert, and nothing without a window.
    func testTheLivePresenterShowsNothingWithoutAnAlertOrAWindow() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 300, height: 200),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        defer { window.close() }
        LiveImportFilesOutcomePresenter().present(ImportFilesOutcome(succeeded: 3, failed: 0), on: window)
        XCTAssertNil(window.attachedSheet, "no file failed, so there is nothing to say")
        LiveImportFilesOutcomePresenter().present(ImportFilesOutcome(succeeded: 0, failed: 1), on: nil)
    }

    // MARK: - Helpers

    /// Imports `urls` through File > Import Files... with a recording presenter bound, runs
    /// `answering` (the test's side of a sheet or a row), and returns the recorder once the
    /// request has ended.
    private func importFiles(
        _ urls: [URL],
        answering: (@MainActor () async -> Void)? = nil
    ) async -> RecordingImportFilesOutcomePresenter {
        let recorder = RecordingImportFilesOutcomePresenter()
        AppDelegate.ImportFilesOutcomeSeam.$presenter.withValue(recorder) {
            delegate.importProjectFilesFromURLs(urls, in: controller)
        }
        await answering?()
        _ = await waitUntil(timeout: .seconds(30)) { !recorder.presentations.isEmpty }
        return recorder
    }

    /// Waits for the sheet on the import's window and ends it with `response`.
    private func answerSheet(_ response: NSApplication.ModalResponse) async {
        guard let window = controller.window else { return XCTFail("the import has no window") }
        let appeared = await waitUntil(timeout: .seconds(30)) { window.attachedSheet != nil }
        XCTAssertTrue(appeared, "no sheet appeared")
        if let sheet = window.attachedSheet { window.endSheet(sheet, returnCode: response) }
    }

    /// Waits for the sheet on the import's window and clicks its button titled `title`.
    private func clickSheetButton(titled title: String) async {
        guard let window = controller.window else { return XCTFail("the import has no window") }
        let appeared = await waitUntil(timeout: .seconds(30)) { window.attachedSheet != nil }
        XCTAssertTrue(appeared, "no sheet appeared")
        let button = Self.buttons(in: window.attachedSheet?.contentView).first { $0.title == title }
        XCTAssertNotNil(button, "the sheet has no \(title) button")
        button?.performClick(nil)
    }

    /// A text file that imports into the project.
    private func makeTextFile(_ name: String) throws -> URL {
        let url = sources.appendingPathComponent(name)
        try Data("plain text".utf8).write(to: url)
        return url
    }

    /// A file the import cannot read, so its copy into the project fails.
    private func makeLockedFile(_ name: String) throws -> URL {
        let url = try makeTextFile(name)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: url.path)
        lockedFiles.append(url)
        return url
    }

    /// An annotation file, whose import asks for a reference bundle and a track name first.
    private func makeAnnotationFile(_ name: String) throws -> URL {
        let url = sources.appendingPathComponent(name)
        try Data("##gff-version 3\nchr1\ttest\tgene\t1\t9\t.\t+\t.\tID=geneA\n".utf8).write(to: url)
        return url
    }

    /// A FASTQ file, whose import asks for its settings in a sheet first.
    private func makeFASTQFile(_ name: String) throws -> URL {
        let url = sources.appendingPathComponent(name)
        try Data("@read1\nACGTACGT\n+\nIIIIIIII\n".utf8).write(to: url)
        return url
    }

    /// A reference bundle in the project, so that an annotation file has a settings sheet.
    private func addReferenceBundle() throws {
        let bundle = project.appendingPathComponent("Fixture.lungfishref", isDirectory: true)
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
        let manifest = BundleManifest(
            name: "Fixture",
            identifier: "org.lungfish.test.\(UUID().uuidString.lowercased())",
            source: SourceInfo(organism: "Test", assembly: "Fixture"),
            genome: GenomeInfo(
                path: "genome/sequence.fa",
                indexPath: "genome/sequence.fa.fai",
                totalLength: 33,
                chromosomes: [ChromosomeInfo(name: "chr1", length: 33, offset: 6, lineBases: 33, lineWidth: 34)]
            )
        )
        try manifest.save(to: bundle)
    }

    /// Runs `script` in place of `lungfish-cli`, so that no real command runs.
    private func useFakeCLI(_ script: String) throws {
        let cli = root.appendingPathComponent("lungfish-cli")
        try script.write(to: cli, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: cli.path)
        if priorCLIPath == nil {
            priorCLIPath = .some(ProcessInfo.processInfo.environment["LUNGFISH_CLI_PATH"])
        }
        setenv("LUNGFISH_CLI_PATH", cli.path, 1)
        XCTAssertEqual(CLIBinaryLocator.cliBinaryPath()?.path, cli.path, "the import would launch another command")
    }

    /// The text of every label under `view`.
    private static func textFields(in view: NSView?) -> [String] {
        guard let view else { return [] }
        var found: [String] = []
        if let field = view as? NSTextField, !field.stringValue.isEmpty { found.append(field.stringValue) }
        for subview in view.subviews { found.append(contentsOf: textFields(in: subview)) }
        return found
    }

    /// Every button under `view`.
    private static func buttons(in view: NSView?) -> [NSButton] {
        guard let view else { return [] }
        var found: [NSButton] = []
        if let button = view as? NSButton { found.append(button) }
        for subview in view.subviews { found.append(contentsOf: buttons(in: subview)) }
        return found
    }
}
