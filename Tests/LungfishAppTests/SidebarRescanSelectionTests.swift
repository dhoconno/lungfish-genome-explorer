// SidebarRescanSelectionTests.swift - A result selected during a sidebar rescan is the one on screen (3.3 lane RESCAN35)
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Owner row 35 (RESCAN-RESULT-LEFT-ON-SCREEN). Walk 3 of Preview 2026.11.2 saw a TaxTriage result stay on screen once
// after the sidebar picked up a new result folder and another TaxTriage result was selected. The panel's D6 made the
// row EVIDENCE, a test with a forced order. This test opens a project with two TaxTriage results, shows one, copies a
// third result folder into Analyses, and runs the rescan the watcher's event starts (`reloadFromFilesystemAsync`,
// which `SidebarRefreshScheduler` calls). The scan is held on the main actor at `scanBarrierForTesting`, between its
// read of the folder and its apply, and released before the selection, inside the selection's debounce, or after the
// selected result is on screen. The selection takes the route a click takes: the outline becomes the first responder
// and its row is selected, which posts the outline's selection change. The hold resumes on the main actor in the same
// turn as the selection, so the apply runs before the debounce's work item, which the main queue gets only 0.1 s later.

import AppKit
import LungfishTestSupport
import XCTest
@testable import LungfishApp
@testable import LungfishIO
@testable import LungfishKit
@testable import LungfishTaxTriageUI
@testable import LungfishWorkflow

/// Holds a sidebar scan between its read and its apply, and notes which result was on screen when the apply ran.
@MainActor
private final class RescanHold {
    private var isOpen = true
    private var waiting: [CheckedContinuation<Void, Never>] = []
    private(set) var arrivals = 0
    /// The result on screen at each apply, read in the same main-actor job as the apply.
    private(set) var shownWhenTheRescanLanded: [URL?] = []
    var shown: () -> URL? = { nil }

    func arriveAndWait() async {
        arrivals += 1
        if !isOpen {
            await withCheckedContinuation { waiting.append($0) }
        }
        shownWhenTheRescanLanded.append(shown())
    }

    func close() { isOpen = false }

    func release() {
        isOpen = true
        let held = waiting
        waiting.removeAll()
        held.forEach { $0.resume() }
    }
}

@MainActor
private final class Done {
    var value = false
}

@MainActor
final class SidebarRescanSelectionTests: XCTestCase {
    private enum Order: String, CaseIterable {
        case beforeTheSelection = "the rescan lands before the selection"
        case insideTheDebounce = "the rescan lands inside the selection's debounce"
        case afterTheDisplay = "the rescan lands after the selected result is on screen"
    }

    private struct Result {
        let url: URL
        let sample: String
    }

    private var root: URL!
    private var project: URL!
    private var analyses: URL!
    private var resultA: Result!
    private var resultB: Result!
    private var controller: MainSplitViewController!
    private var window: NSWindow!
    private var hold: RescanHold!
    private var copies = 0

    /// The TaxTriage result view may save its column layout to `UserDefaults.standard` under the result's path.
    private var hostDefaults: HostDefaultsRestorer?

    override func setUp() async throws {
        try await super.setUp()
        root = try TestTempDirectory.make(prefix: "sidebar-rescan-selection")
        hostDefaults = HostDefaultsRestorer(keysContaining: root.lastPathComponent)
        project = root.appendingPathComponent("Rescan.lungfish", isDirectory: true)
        analyses = project.appendingPathComponent(AnalysesFolder.directoryName, isDirectory: true)
        try FileManager.default.createDirectory(at: analyses, withIntermediateDirectories: true)
        resultA = try makeTaxTriageBatch(named: "taxtriage-batch-2026-11-05T12-00-00", sample: "SAMPLE-A")
        resultB = try makeTaxTriageBatch(named: "taxtriage-batch-2026-11-05T13-00-00", sample: "SAMPLE-B")

        let split = MainSplitViewController()
        let host = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1400, height: 900),
            styleMask: [.titled, .resizable, .closable],
            backing: .buffered,
            defer: false
        )
        host.isReleasedWhenClosed = false
        host.contentViewController = split
        host.layoutIfNeeded()
        split.view.layoutSubtreeIfNeeded()
        controller = split
        window = host

        let hold = RescanHold()
        hold.shown = { [weak split] in
            split?.viewerController.taxTriageViewController?.batchGroupURL?.standardizedFileURL
        }
        self.hold = hold
        SidebarViewController.scanBarrierForTesting = { @MainActor in await hold.arriveAndWait() }

        split.sidebarController.openProject(at: project)
        // Only the test starts a rescan, so no watcher event lands at a time the test did not choose.
        split.sidebarController.detachFilesystemWatcherForTesting()
    }

    override func tearDown() async throws {
        SidebarViewController.scanBarrierForTesting = nil
        hold?.release()
        controller?.sidebarController.closeProject()
        window?.contentViewController = nil
        window = nil
        controller = nil
        hostDefaults?.restore()
        TestTempDirectory.cleanup(root)
        try await super.tearDown()
    }

    // MARK: - Row 35

    /// In every order, five times running and after a second rescan, the viewer, its rows' samples, the Summary's
    /// samples, the Inspector's name and the sidebar's selected row all name the result selected last.
    func testSelectingAnotherResultDuringARescanShowsTheSelectedResult() throws {
        for round in 0..<5 {
            for order in Order.allCases {
                let (from, to) = round.isMultiple(of: 2) ? (resultA!, resultB!) : (resultB!, resultA!)
                click(from)
                assertShows(from, "\(order.rawValue), round \(round + 1), before the rescan")

                hold.close()
                let landed = hold.shownWhenTheRescanLanded.count
                let applied = try startRescan()
                XCTAssertTrue(waitUntilOnRunLoop(budget: .lookup) { self.hold.arrivals > landed },
                              "the rescan never finished reading the project")
                switch order {
                case .beforeTheSelection:
                    hold.release()
                    waitForApply(applied)
                    click(to)
                case .insideTheDebounce:
                    // One main-actor turn: the click schedules the debounce and the release queues the apply first.
                    click(to)
                    hold.release()
                    waitForApply(applied)
                    XCTAssertEqual(hold.shownWhenTheRescanLanded.last ?? nil, from.url,
                                   "the order was not forced: the selection's debounce ran before the rescan landed")
                case .afterTheDisplay:
                    click(to)
                    assertShows(to, "\(order.rawValue), round \(round + 1), before the release")
                    hold.release()
                    waitForApply(applied)
                    XCTAssertEqual(hold.shownWhenTheRescanLanded.last ?? nil, to.url)
                }
                assertShows(to, "\(order.rawValue), round \(round + 1)")

                waitForApply(try startRescan())
                assertShows(to, "\(order.rawValue), round \(round + 1), after a second rescan")
            }
        }
    }

    // MARK: - A selection made while the shown result's table has the focus (BIO-FOCUS-DROP, lane FOCUSDROP)

    /// An accessibility select (VoiceOver, Voice Control, the Accessibility Inspector, walk 3's AX click) leaves the
    /// focus in the shown result's table. A person asked for it, so the result it selects is shown.
    func testAnAccessibilitySelectionWithoutSidebarFocusShowsTheSelectedResult() throws {
        try assertAnAccessibilitySelectShowsResultB("AX selected rows of the outline") { outline, element in
            outline.accessibilitySetValue([element], forAttribute: .selectedRows)
        }
    }

    /// The outline's accessibility rows are AppKit's own elements (`NSOutlineRow`), not its row views, and not every
    /// one conforms to `NSAccessibilityRow`. They are read and set by attribute, the way an AX client's request
    /// reaches them. (Setting `AXSelected` on the row element selects nothing in a unit test's window, so that route
    /// is left to the packaged walk.)
    private func assertAnAccessibilitySelectShowsResultB(
        _ route: String,
        _ select: (NSOutlineView, NSObject) -> Void
    ) throws {
        click(resultA)
        assertShows(resultA, "\(route), before")
        try focusTheShownResultsTable()
        let outline = controller.sidebarController.outlineView!
        let row = try row(of: resultB)
        let elements = outline.accessibilityAttributeValue(.rows) as? [NSObject] ?? []
        let element = try XCTUnwrap(elements.first { ($0.accessibilityAttributeValue(.index) as? Int) == row },
                                    "the outline lists no accessibility row for \(resultB.url.lastPathComponent)")
        select(outline, element)
        XCTAssertEqual(outline.selectedRow, row, "\(route) selected another row")
        XCTAssertFalse(controller.sidebarController.outlineViewIsFirstResponder(window.firstResponder),
                       "\(route) moved the focus into the sidebar")
        assertShows(resultB, route)
        waitForApply(try startRescan())
        assertShows(resultB, "\(route), after a rescan")
    }

    /// A selection nobody asked for (no focus in the sidebar, no click, no accessibility select) while a result is shown
    /// goes back to the shown result's row and posts no notice. The viewer, the Inspector and the sidebar keep naming the
    /// result on screen, and a click on the other row then shows it. RESCAN35's probe, as written.
    func testAnUnexplainedSelectionWithoutSidebarFocusLeavesEverySurfaceOnTheShownResult() throws {
        click(resultA)
        assertShows(resultA, "unexplained selection, before")
        waitForApply(try startRescan())
        XCTAssertTrue(window.makeFirstResponder(nil))
        let outline = controller.sidebarController.outlineView!
        outline.selectRowIndexes(IndexSet(integer: try row(of: resultB)), byExtendingSelection: false)
        let viewerURL = controller.viewerController.taxTriageViewController?.batchGroupURL?.standardizedFileURL
        let inspectorPath = controller.inspectorController.activeContentSelectionIdentity?.standardizedURLPath
        XCTAssertEqual(viewerURL?.path, inspectorPath,
                       "the Inspector names another result than the viewer: \(describeScreen())")
        assertShows(resultA, "unexplained selection")
        waitForApply(try startRescan())
        assertShows(resultA, "unexplained selection, after a second rescan")
        click(resultB)
        assertShows(resultB, "a click on the other row after the unexplained selection")
    }

    /// The Inspector's source link selects the result it names while the shown result's table has the focus. A person
    /// asked for it, so its result is shown. This stands in for the Operations panel's Results button, whose
    /// `OperationResultNavigation.navigate(to:)` finds its window only through `AppDelegate.shared`, which a unit test
    /// has not, and both take the same explicit `selectItem(forURL:explicit:)`.
    func testAnExplicitSelectionWithAChildViewerShownShowsTheResult() throws {
        click(resultA)
        assertShows(resultA, "Inspector link, before")
        try focusTheShownResultsTable()
        let scope = try XCTUnwrap(controller.sidebarController.windowStateScope, "the sidebar has no window scope")
        NotificationCenter.default.post(name: .navigateToSidebarItem, object: nil,
                                        userInfo: ["url": resultB.url, NotificationUserInfoKey.windowStateScope: scope])
        assertShows(resultB, "Inspector link")
        waitForApply(try startRescan())
        assertShows(resultB, "Inspector link, after a rescan")
    }

    /// Pin for the route after a run (FASTQ trim, split and demux, primer design, mapping): the run's result is selected
    /// while the shown result's table has the focus, and it is shown. Green at the base too, where a patch after the
    /// select in `finishRefreshSidebarAndSelectDerivedURL` showed what the focus rule had refused.
    func testADerivedResultSelectedAfterARunWithAChildViewerShownShowsTheResult() throws {
        click(resultA)
        assertShows(resultA, "after a run, before")
        try focusTheShownResultsTable()
        let selected = Done()
        controller.refreshSidebarAndSelectDerivedURL(resultB.url) { selected.value = true }
        XCTAssertTrue(waitUntilOnRunLoop(budget: .lookup) { selected.value }, "the run's result was never selected")
        assertShows(resultB, "after a run")
        waitForApply(try startRescan())
        assertShows(resultB, "after a run, after a rescan")
    }

    // MARK: - Helpers

    /// Puts the focus in the shown TaxTriage result's table, as a click in its rows does.
    private func focusTheShownResultsTable(file: StaticString = #filePath, line: UInt = #line) throws {
        let view = try XCTUnwrap(controller.viewerController.taxTriageViewController?.view, "no TaxTriage result is shown",
                                 file: file, line: line)
        let table = try XCTUnwrap(firstTable(in: view), "the TaxTriage result shows no table", file: file, line: line)
        XCTAssertTrue(window.makeFirstResponder(table), "the TaxTriage table refused the focus", file: file, line: line)
        XCTAssertFalse(controller.sidebarController.outlineViewIsFirstResponder(window.firstResponder),
                       "the sidebar kept the focus", file: file, line: line)
    }

    private func firstTable(in view: NSView) -> NSTableView? {
        if let table = view as? NSTableView, !table.isHiddenOrHasHiddenAncestor { return table }
        return view.subviews.lazy.compactMap { self.firstTable(in: $0) }.first
    }

    private func row(of result: Result) throws -> Int {
        let sidebar = controller.sidebarController!
        let item = try XCTUnwrap(item(at: result.url, in: sidebar.rootItems),
                                 "the sidebar lists no row for \(result.url.lastPathComponent)")
        let row = sidebar.outlineView.row(forItem: item)
        XCTAssertGreaterThanOrEqual(row, 0, "the row for \(item.title) is not visible")
        return row
    }

    /// Selects the result's row as a click does: the outline takes the focus and its row is selected.
    private func click(_ result: Result, file: StaticString = #filePath, line: UInt = #line) {
        let sidebar = controller.sidebarController!
        guard let item = item(at: result.url, in: sidebar.rootItems) else {
            XCTFail("the sidebar lists no row for \(result.url.lastPathComponent)", file: file, line: line)
            return
        }
        let row = sidebar.outlineView.row(forItem: item)
        XCTAssertGreaterThanOrEqual(row, 0, "the row for \(item.title) is not visible", file: file, line: line)
        XCTAssertTrue(window.makeFirstResponder(sidebar.outlineView), file: file, line: line)
        sidebar.outlineView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
    }

    /// Copies result A's folder into Analyses under a new name and starts the rescan the watcher's event starts.
    private func startRescan() throws -> Done {
        copies += 1
        let name = String(format: "taxtriage-batch-2026-11-04T09-%02d-00", copies)
        try FileManager.default.copyItem(at: resultA.url, to: analyses.appendingPathComponent(name, isDirectory: true))
        let scan = controller.sidebarController.reloadFromFilesystemAsync(notifyUnchangedSelectionRefresh: false)
        XCTAssertNotNil(scan, "the sidebar started no rescan")
        let done = Done()
        Task { @MainActor in
            await scan?.value
            done.value = true
        }
        return done
    }

    private func waitForApply(_ done: Done, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(waitUntilOnRunLoop(budget: .lookup) { done.value }, "the rescan never applied", file: file, line: line)
    }

    /// Waits until every place on screen names `result`, and says what each one shows when they do not.
    private func assertShows(_ result: Result, _ context: String, file: StaticString = #filePath, line: UInt = #line) {
        let settled = waitUntilOnRunLoop(budget: .lookup) { self.screen(names: result) }
        XCTAssertTrue(settled, "\(context): \(describeScreen()) but \(result.url.lastPathComponent) was selected",
                      file: file, line: line)
    }

    private func screen(names result: Result) -> Bool {
        let sidebar = controller.sidebarController!
        let viewer = controller.viewerController.taxTriageViewController
        let inspector = controller.inspectorController!
        let title = item(at: result.url, in: sidebar.rootItems)?.title
        return viewer?.batchGroupURL?.standardizedFileURL == result.url
            && viewer?.sampleEntries.map(\.id) == [result.sample]
            && summary.batchSourceSampleURLs.map(\.sampleId) == [result.sample]
            && title != nil && inspector.viewModel.selectedItem == title
            && inspector.activeContentSelectionIdentity?.standardizedURLPath == result.url.path
            && sidebar.selectedItems().compactMap { $0.url?.standardizedFileURL } == [result.url]
    }

    private func describeScreen() -> String {
        let viewer = controller.viewerController.taxTriageViewController
        let shown = viewer?.batchGroupURL?.lastPathComponent ?? "no TaxTriage result"
        let rows = viewer?.sampleEntries.map(\.id) ?? []
        let summarySamples = summary.batchSourceSampleURLs.map(\.sampleId)
        let named = controller.inspectorController.viewModel.selectedItem ?? "nothing"
        let identity = controller.inspectorController.activeContentSelectionIdentity?.standardizedURLPath ?? "none"
        let selected = controller.sidebarController.selectedItems().map { $0.url?.lastPathComponent ?? $0.title }
        return "the viewer shows \(shown) with rows of \(rows), the Summary lists \(summarySamples), the Inspector "
            + "names \(named) (\((identity as NSString).lastPathComponent)), the sidebar selects \(selected),"
    }

    private var summary: DocumentSectionViewModel {
        controller.inspectorController.viewModel.documentSectionViewModel
    }

    private func item(at url: URL, in items: [SidebarItem]) -> SidebarItem? {
        for item in items {
            if item.url?.standardizedFileURL == url { return item }
            if let found = self.item(at: url, in: item.children) { return found }
        }
        return nil
    }

    /// The routing fixture's TaxTriage database of one sample, with its analysis metadata and the sample's folder, in
    /// Analyses. The sidebar lists a TaxTriage batch with no sidecar only when it holds a sample folder.
    private func makeTaxTriageBatch(named name: String, sample: String) throws -> Result {
        let batch = try RoutingSafetyNetFixtures.taxTriageResult(named: name, in: analyses, samples: [sample])
        try FileManager.default.createDirectory(at: batch.appendingPathComponent(sample, isDirectory: true),
                                                withIntermediateDirectories: true)
        try AnalysesFolder.writeAnalysisMetadata(
            AnalysesFolder.AnalysisMetadata(tool: "taxtriage", isBatch: true, created: Date()),
            to: batch
        )
        return Result(url: batch.standardizedFileURL, sample: sample)
    }
}
