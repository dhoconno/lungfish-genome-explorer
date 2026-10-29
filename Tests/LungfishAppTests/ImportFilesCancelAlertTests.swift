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

    /// A GFF into a project with no reference bundle gets no settings sheet, so the file is refused
    /// and not cancelled, and the request still ends with the alert (Phase 2.11 review of lane U62, Fix 1).
    func testAGFFIntoAProjectWithNoReferenceBundleStillEndsWithImportCompletedWithErrors() async throws {
        let gff = try makeAnnotationFile("genes.gff3")
        let recorder = await importFiles([gff])

        XCTAssertEqual(recorder.presentations.count, 1)
        XCTAssertEqual(recorder.presentations.first?.outcome.alert, ImportFilesOutcome.Alert(
            title: "Import Completed with Errors",
            message: "0 succeeded, 1 failed."
        ), "a refusal is not a cancel")
        XCTAssertNil(controller.window?.attachedSheet, "no settings sheet appears without a reference bundle")
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

    // MARK: - A refused ZIP (Phase 3.0 lane ZIP, OBS-W9)

    /// File > Import Files... on a ZIP that holds a link to a file outside the archive shows the sheet a drop
    /// shows, once. It names the archive and says why. The counts alert that ends the request stays, since it is
    /// right for a batch that mixes imports and refusals, and the project is left as it was. The sheet's
    /// presenter is read in the call that starts the import, because the import continues in a task that does
    /// not inherit this test's binding.
    func testARefusedZipOnTheMenuRouteIsExplainedInOneSheet() async throws {
        let zip = try makeReadBundleZip(name: "SRR12486983-abslink", absoluteLinkTo: "/etc/hosts")
        let before = try projectListing()
        let sheets = RecordingZipFailurePresenter()
        let outcome = RecordingImportFilesOutcomePresenter()
        LGEZipImportFailureSeam.$presenter.withValue(sheets) {
            AppDelegate.ImportFilesOutcomeSeam.$presenter.withValue(outcome) {
                delegate.importProjectFilesFromURLs([zip], in: controller)
            }
        }
        _ = await waitUntil(timeout: .seconds(30)) { !outcome.presentations.isEmpty }

        let message = try XCTUnwrap(sheets.messages.first, "no sheet was shown")
        XCTAssertEqual(sheets.messages.count, 1, "one sheet for the drop: \(sheets.messages)")
        XCTAssertEqual(message.title, "Could not import SRR12486983-abslink.zip")
        XCTAssertTrue(
            message.text.hasPrefix("It holds a link to a file outside the archive, so Lungfish did not import it. "), message.text
        )
        XCTAssertTrue(message.text.contains("points to the absolute path /etc/hosts"), message.text)
        XCTAssertTrue(
            message.text.contains("Pack the ZIP again with each link replaced by the file it points to"), message.text
        )
        XCTAssertEqual(outcome.presentations.map(\.outcome.failed), [1], "the request still ends in its counts alert")
        XCTAssertEqual(try projectListing(), before, "the import leaves the project as it was, with no bundle and no .tmp folder")
    }

    /// The error the resolution throws, here a project folder that takes no new entry, shows the same sheet. It
    /// was the raw "Import Failed" sheet before, and nothing at all when the import had no window.
    func testAMenuImportThatCannotMakeItsWorkingFolderIsExplainedInOneSheet() async throws {
        try XCTSkipIf(getuid() == 0, "root writes into a folder that has no write permission")
        let zip = try makeReadBundleZip(name: "SRR12486983")
        let before = try projectListing()
        let sheets = RecordingZipFailurePresenter()
        let outcome = RecordingImportFilesOutcomePresenter()
        // The sidebar can still read the folder, but the import cannot make its .tmp folder in it.
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: project.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: project.path) }
        LGEZipImportFailureSeam.$presenter.withValue(sheets) {
            AppDelegate.ImportFilesOutcomeSeam.$presenter.withValue(outcome) {
                delegate.importProjectFilesFromURLs([zip], in: controller)
            }
        }
        // A resolution that throws ends the request at its sheet and shows no counts alert. The sheet the import
        // showed before the fix also ends this wait, so a failing run reports its assertions at once.
        let window = try XCTUnwrap(controller.window)
        _ = await waitUntil(timeout: .seconds(30)) { !sheets.messages.isEmpty || window.attachedSheet != nil }

        XCTAssertEqual(sheets.messages.count, 1, "one sheet for the import: \(sheets.messages)")
        XCTAssertEqual(sheets.messages.first?.title, "Could not import SRR12486983.zip")
        XCTAssertTrue(sheets.messages.first?.text.contains("working folder") == true, "\(sheets.messages)")
        XCTAssertTrue(outcome.presentations.isEmpty, "a resolution that throws ends the request with no counts alert")
        XCTAssertEqual(try projectListing(), before)
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

    /// A ZIP of one read bundle in the sources folder. With `absoluteLinkTo` the bundle also holds a link to that
    /// path, which Lungfish refuses (OBS-W9). `zip -y` stores the link as a link and does not follow it.
    private func makeReadBundleZip(name: String, absoluteLinkTo target: String? = nil) throws -> URL {
        let fm = FileManager.default
        let stage = root.appendingPathComponent("zip-stage-\(name)", isDirectory: true)
        let bundle = stage.appendingPathComponent("\(name).lungfishfastq", isDirectory: true)
        try fm.createDirectory(at: bundle, withIntermediateDirectories: true)
        try "@read1\nACGTACGTAC\n+\nIIIIIIIIII\n".write(
            to: bundle.appendingPathComponent("reads.fastq"), atomically: true, encoding: .utf8
        )
        if let target {
            try fm.createSymbolicLink(atPath: bundle.appendingPathComponent("link").path, withDestinationPath: target)
        }
        let archive = sources.appendingPathComponent("\(name).zip")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        process.currentDirectoryURL = stage
        process.arguments = ["-qry", archive.path, bundle.lastPathComponent]
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
        return archive
    }

    /// Every path under the project, relative to it and sorted, so a folder the import made and left shows. The
    /// sidebar writes its search index into a project when it opens one, at a time the import does not choose, so
    /// the index files stay out of the listing.
    private func projectListing() throws -> [String] {
        try FileManager.default.subpathsOfDirectory(atPath: project.path)
            .filter { !$0.hasPrefix(".universal-search.db") }
            .sorted()
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
