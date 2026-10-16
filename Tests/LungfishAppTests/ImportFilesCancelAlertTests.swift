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
import LungfishCore
import LungfishIO
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

    override func setUp() async throws {
        try await super.setUp()
        _ = NSApplication.shared
        OperationCenter.useTemporaryFailureReportsForTesting()
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

    /// Imports `urls` through File > Import Files... with a recording presenter bound, and returns
    /// the recorder once the request has ended.
    private func importFiles(_ urls: [URL]) async -> RecordingImportFilesOutcomePresenter {
        let recorder = RecordingImportFilesOutcomePresenter()
        AppDelegate.ImportFilesOutcomeSeam.$presenter.withValue(recorder) {
            delegate.importProjectFilesFromURLs(urls, in: controller)
        }
        _ = await waitUntil(timeout: .seconds(30)) { !recorder.presentations.isEmpty }
        return recorder
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

    /// The text of every label under `view`.
    private static func textFields(in view: NSView?) -> [String] {
        guard let view else { return [] }
        var found: [String] = []
        if let field = view as? NSTextField, !field.stringValue.isEmpty { found.append(field.stringValue) }
        for subview in view.subviews { found.append(contentsOf: textFields(in: subview)) }
        return found
    }
}
