// FASTQDrawerCloseSheetOKClosesWindowTests.swift - OK on the close sheet of an unsaved FASTQ drawer edit closes the window
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// ux-text lane CSA-CLOSE-S2 (walk row CS-a2 of build 14686, S2, ruling UX-CSA-R17). A sample name is being typed in the
// FASTQ drawer, the dataset folder cannot be written, and the person presses the window's close button. The close sheet
// says "The window closes when you press OK." On build 14686 its OK put a second sheet on the window, the select route's,
// and the window stayed open after that sheet's OK too.
//
// Both sheets are AppKit's own, shown by the app's own presenters, which the test only watches. The window is closed by
// a real performClose, OK is pressed on the sheet's button, and the app's own close handler runs on the window.

import AppKit
import XCTest
@testable import LungfishApp
@testable import LungfishIO
import LungfishKit
import LungfishKitTestSupport
import LungfishTestSupport

/// What the two presenters and the window did, in order.
@MainActor
private final class CloseTimeline {
    var events: [String] = []
    var closeSheets: [NSAlert] = []
    var selectSheets: [NSAlert] = []
    var windowClosed = false
    var hookEnded = false

    func note(_ event: String) { events.append(event) }

    var reading: String { events.joined(separator: " | ") }
}

@MainActor
final class FASTQDrawerCloseSheetOKClosesWindowTests: XCTestCase {
    private var root: URL!
    /// The folders and sidecars the test made read-only, made writable again before the test folder goes.
    private var unwritable: [(folder: URL, sidecar: URL)] = []

    private static let title = "The FASTQ drawer\u{2019}s edits for illumina-reads were not saved."

    private enum Typing {
        /// The name is still in the cell's field editor, as when a person types and then presses the close button.
        case inTheCell
        /// The cell's edit has ended, so the table has handed the name to the drawer.
        case ended
    }

    private struct Scene {
        let delegate: AppDelegate
        let controller: MainWindowController
        let window: NSWindow
        let viewer: ViewerViewController
        let sidecar: URL
        let sidecarBefore: Data
    }

    override func setUp() async throws {
        try await super.setUp()
        try requireNoPendingAnnotationEditsForTest()
        OperationCenter.useTemporaryFailureReportsForTesting()
        root = try TestTempDirectory.make(prefix: "fastq-drawer-close-sheet-ok")
    }

    override func tearDown() async throws {
        for held in unwritable {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: held.folder.path)
            try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: held.sidecar.path)
        }
        unwritable = []
        if let root { TestTempDirectory.cleanup(root) }
        root = nil
        try await super.tearDown()
    }

    // MARK: - CS-a2

    /// The walk's row CS-a2. While the close sheet shows, the dashboard under the drawer is taken away, as a refresh of
    /// the selected dataset takes it (the drawer was gone behind the walk's second sheet, the dashboard and the sidebar
    /// row were not). Then the person presses OK once. The window closes, and no second sheet shows.
    func testOneOKClosesTheWindowWhenTheDashboardWentWhileTheCloseSheetShowed() async throws {
        try await assertOneOKClosesTheWindow(typing: .inTheCell, removal: .whileTheSheetShows)
    }

    /// The dashboard goes in the turn after OK, before the close sheet's hook has run.
    func testOneOKClosesTheWindowWhenTheDashboardWentBeforeTheOKHookRan() async throws {
        try await assertOneOKClosesTheWindow(typing: .ended, removal: .beforeTheOKHookRuns)
    }

    /// Control: the name is still being typed in the cell when the person presses the close button, then OK once.
    func testOneOKOnTheCloseSheetClosesTheWindowWhileTheNameIsStillInTheCell() async throws {
        try await assertOneOKClosesTheWindow(typing: .inTheCell, removal: .none)
    }

    /// Control: the same close after the cell's edit has ended.
    func testOneOKOnTheCloseSheetClosesTheWindowAfterTheCellEditEnded() async throws {
        try await assertOneOKClosesTheWindow(typing: .ended, removal: .none)
    }

    private enum Removal { case none, whileTheSheetShows, beforeTheOKHookRuns }

    private func assertOneOKClosesTheWindow(
        typing: Typing, removal: Removal, file: StaticString = #filePath, line: UInt = #line
    ) async throws {
        let scene = try await sceneWithAnEditThatCannotBeSaved(typing: typing)
        let timeline = CloseTimeline()
        let stopWatching = watch(scene, into: timeline)
        defer { stopWatching() }

        scene.window.performClose(nil)
        let sheet = try XCTUnwrap(timeline.closeSheets.first, "the close dropped the edit with no sheet", file: file, line: line)
        XCTAssertEqual(timeline.closeSheets.count, 1, file: file, line: line)
        XCTAssertFalse(timeline.windowClosed, "the window closed over words nobody saw", file: file, line: line)
        XCTAssertEqual(sheet.messageText, Self.title, file: file, line: line)
        XCTAssertEqual(sheet.buttons.map(\.title), ["OK"], file: file, line: line)
        XCTAssertTrue(sheet.informativeText.contains("The window closes when you press OK."), sheet.informativeText,
                      file: file, line: line)
        XCTAssertTrue(scene.window.attachedSheet === sheet.window, "the close sheet is not on the window", file: file, line: line)
        XCTAssertEqual(timeline.selectSheets.count, 0, "the close button showed the select route's sheet as well",
                       file: file, line: line)

        if removal == .whileTheSheetShows {
            timeline.note("dashboard removed")
            scene.viewer.clearSurface(ifShowing: .bundle(.fastq))
        }
        timeline.note("OK pressed")
        sheet.buttons[0].performClick(nil)
        if removal == .beforeTheOKHookRuns {
            timeline.note("dashboard removed")
            scene.viewer.clearSurface(ifShowing: .bundle(.fastq))
        }
        _ = await waitUntil(budget: WaitBudget.standard) {
            timeline.hookEnded && ((timeline.windowClosed && !scene.window.isVisible)
                || (scene.window.attachedSheet != nil && scene.window.attachedSheet !== sheet.window))
        }

        XCTAssertEqual(timeline.selectSheets.count, 0,
                       "one OK on the close sheet showed a second sheet: \(timeline.selectSheets.first?.informativeText ?? ""). "
                       + "Timeline: \(timeline.reading)", file: file, line: line)
        XCTAssertEqual(timeline.closeSheets.count, 1, "one OK showed the close sheet again. Timeline: \(timeline.reading)",
                       file: file, line: line)
        // As the walk did, a second sheet is answered too, and the window must be gone after it.
        if let second = scene.window.attachedSheet, second !== sheet.window, let ok = second.contentView.flatMap({ Self.buttons(in: $0) })?.first {
            timeline.note("OK pressed on the second sheet")
            ok.performClick(nil)
            _ = await waitUntil(budget: WaitBudget.standard) { timeline.windowClosed && !scene.window.isVisible }
        }
        XCTAssertTrue(timeline.windowClosed, "the window did not close after OK. Timeline: \(timeline.reading)",
                      file: file, line: line)
        XCTAssertFalse(scene.window.isVisible, "the window is still on screen after OK. Timeline: \(timeline.reading)",
                       file: file, line: line)
        let after = try Data(contentsOf: scene.sidecar)
        XCTAssertEqual(after, scene.sidecarBefore, "the settings saved earlier changed", file: file, line: line)
        XCTAssertFalse(String(decoding: after, as: UTF8.self).contains("CS-typed-name"), "the sidecar holds the typed name",
                       file: file, line: line)
    }

    // MARK: - Fixture

    /// Watches both presenters, which still show AppKit's own sheets, and the window's sheets and close. Runs the app's
    /// own close handler on the window: the test's delegate never ran applicationDidFinishLaunching, which registers it.
    private func watch(_ scene: Scene, into timeline: CloseTimeline) -> @MainActor () -> Void {
        let presentBeforeClose = ViewerViewController.presentUnkeptFASTQDrawerEditBeforeClose
        let presentOnSelect = ViewerViewController.presentUnkeptFASTQDrawerEdit
        let window = scene.window
        let viewer = scene.viewer
        ViewerViewController.presentUnkeptFASTQDrawerEditBeforeClose = { alert, sheetWindow, close in
            timeline.note("close sheet")
            timeline.closeSheets.append(alert)
            presentBeforeClose(alert, sheetWindow) {
                timeline.note("OK hook starts (sheet attached \(window.attachedSheet != nil), "
                    + "drawer edit waits \(viewer.fastqMetadataDrawerView?.hasWaitingEdit == true))")
                close()
                timeline.hookEnded = true
                timeline.note("OK hook ends (window visible \(window.isVisible), drawer \(viewer.fastqMetadataDrawerView != nil))")
            }
        }
        ViewerViewController.presentUnkeptFASTQDrawerEdit = { alert, sheetWindow in
            timeline.note("select sheet (window visible \(window.isVisible), closed \(timeline.windowClosed), "
                + "sheet attached \(window.attachedSheet != nil))")
            timeline.selectSheets.append(alert)
            presentOnSelect(alert, sheetWindow)
        }
        let center = NotificationCenter.default
        let names: [Notification.Name] = [
            NSWindow.willBeginSheetNotification, NSWindow.didEndSheetNotification, NSWindow.willCloseNotification,
        ]
        let tokens = names.map { name in
            center.addObserver(forName: name, object: window, queue: nil) { _ in
                MainActor.assumeIsolated {
                    if name == NSWindow.willCloseNotification { timeline.windowClosed = true }
                    timeline.note(name.rawValue)
                }
            }
        }
        center.addObserver(scene.delegate, selector: NSSelectorFromString("windowWillClose:"),
                           name: NSWindow.willCloseNotification, object: window)
        return {
            ViewerViewController.presentUnkeptFASTQDrawerEditBeforeClose = presentBeforeClose
            ViewerViewController.presentUnkeptFASTQDrawerEdit = presentOnSelect
            tokens.forEach { center.removeObserver($0) }
            center.removeObserver(scene.delegate, name: NSWindow.willCloseNotification, object: window)
        }
    }

    private func sceneWithAnEditThatCannotBeSaved(typing: Typing) async throws -> Scene {
        try XCTSkipIf(geteuid() == 0, "a process run as root writes into a read-only folder")
        let delegate = AppDelegate()
        delegate.projectWindowStateStore = ProjectWindowStateStore(stateURL: root.appendingPathComponent("windows.json"))
        let controller = delegate.createAndShowMainWindow()
        let window = try XCTUnwrap(controller.window, "the project window is gone")
        window.setFrameAutosaveName("")
        window.toolbar?.autosavesConfiguration = false
        window.animationBehavior = .none
        window.isReleasedWhenClosed = false
        addTeardownBlock { @MainActor in
            while let sheet = window.attachedSheet { window.endSheet(sheet) }
            controller.close()
        }
        window.makeKeyAndOrderFront(nil)
        let viewer = try XCTUnwrap(controller.mainSplitViewController?.viewerController, "the project window has no viewer")

        let fastq = try await makeFASTQ(named: "First")
        let opened = viewer.displayFASTQDataset(
            statistics: .countsOnlyFixture(readCount: 4, baseCount: 400), records: [], fastqURL: fastq
        )
        XCTAssertTrue(opened, "the dashboard of \(fastq.lastPathComponent) did not open")
        viewer.toggleFASTQMetadataDrawer()
        let drawer = try XCTUnwrap(viewer.fastqMetadataDrawerView, "the drawer did not open")
        let table = try XCTUnwrap(Self.tables(in: drawer).first { $0.tableColumn(withIdentifier: .init("sampleName")) != nil },
                                  "the drawer has no sample table")
        let column = try XCTUnwrap(table.tableColumn(withIdentifier: .init("sampleName")))
        XCTAssertGreaterThan(table.numberOfRows, 0, "the sample table has no row")
        switch typing {
        case .inTheCell:
            table.editColumn(table.column(withIdentifier: .init("sampleName")), row: 0, with: nil, select: true)
            let editor = try XCTUnwrap(window.firstResponder as? NSTextView, "the sample name cell did not start an edit")
            editor.insertText("CS-typed-name", replacementRange: NSRange(location: 0, length: (editor.string as NSString).length))
            XCTAssertEqual(table.editedRow, 0, "Precondition: the name is still being typed in the cell")
        case .ended:
            drawer.tableView(table, setObjectValue: "CS-typed-name", for: column, row: 0)
        }

        let sidecar = FASTQMetadataStore.metadataURL(for: fastq)
        let before = try Data(contentsOf: sidecar)
        let folder = fastq.deletingLastPathComponent()
        try FileManager.default.setAttributes([.posixPermissions: 0o444], ofItemAtPath: sidecar.path)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: folder.path)
        unwritable.append((folder: folder, sidecar: sidecar))
        XCTAssertThrowsError(try FASTQMetadataStore.write(PersistedFASTQMetadata(), for: fastq),
                             "Precondition: the folder can be written")
        XCTAssertEqual(try Data(contentsOf: sidecar), before, "Precondition: the probe changed the sidecar")
        return Scene(delegate: delegate, controller: controller, window: window, viewer: viewer,
                     sidecar: sidecar, sidecarBefore: before)
    }

    /// A FASTQ bundle with cached statistics and a saved sample row, in a folder named `name`.
    private func makeFASTQ(named name: String) async throws -> URL {
        let (_, fastq) = try await RoutingSafetyNetFixtures.fastqBundle(in: root.appendingPathComponent(name, isDirectory: true))
        var persisted = FASTQMetadataStore.load(for: fastq) ?? PersistedFASTQMetadata()
        persisted.demultiplexMetadata = FASTQDemultiplexMetadata(sampleAssignments: [
            FASTQSampleBarcodeAssignment(sampleID: "bc01", sampleName: "Saved name", forwardBarcodeID: "bc01"),
        ])
        try FASTQMetadataStore.write(persisted, for: fastq)
        return fastq
    }

    private static func buttons(in view: NSView) -> [NSButton] {
        view.subviews.flatMap { subview in (subview as? NSButton).map { [$0] } ?? buttons(in: subview) }
            .filter { $0.title == "OK" }
    }

    private static func tables(in view: NSView) -> [NSTableView] {
        view.subviews.flatMap { subview in (subview as? NSTableView).map { [$0] } ?? tables(in: subview) }
    }
}
