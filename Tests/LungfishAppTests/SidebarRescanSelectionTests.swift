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

    /// In every order, for both reload variants, three times running and after a second rescan, the viewer, its rows'
    /// samples, the Summary's samples, the Inspector's name and the sidebar's selected row all name the result selected
    /// last. `notify` false is the watcher's reload. `notify` true is the one about forty callers ask for, whose
    /// unchanged selection is replayed through `sidebarDidRefreshSelectedItems`, which cancels a pending debounce.
    func testSelectingAnotherResultDuringARescanShowsTheSelectedResult() throws {
        for notify in [false, true] {
            for round in 0..<3 {
                for order in Order.allCases {
                    try runRound(round, order: order, notify: notify)
                }
            }
        }
    }

    private func runRound(_ round: Int, order: Order, notify: Bool) throws {
        let (from, to) = round.isMultiple(of: 2) ? (resultA!, resultB!) : (resultB!, resultA!)
        let context = "\(order.rawValue), round \(round + 1), notify \(notify)"
        click(from)
        assertShows(from, "\(context), before the rescan")

        hold.close()
        let landed = hold.shownWhenTheRescanLanded.count
        let applied = try startRescan(notify: notify)
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
            assertShows(to, "\(context), before the release")
            hold.release()
            waitForApply(applied)
            XCTAssertEqual(hold.shownWhenTheRescanLanded.last ?? nil, to.url)
        }
        assertShows(to, context)

        waitForApply(try startRescan(notify: notify))
        assertShows(to, "\(context), after a second rescan")
    }

    // MARK: - A selection made while the shown result's table has the focus (BIO-FOCUS-DROP, lane FOCUSDROP)

    /// An AX client's set of the outline's `AXSelectedRows` leaves the focus in the shown result's table. A person
    /// asked for it, so the result it selects is shown. A set of `AXSelected` on one row element takes another route,
    /// which the FOCUSAX tests below drive.
    func testAnAccessibilitySelectionWithoutSidebarFocusShowsTheSelectedResult() throws {
        try assertAnAccessibilitySelectShowsResultB("AX selected rows of the outline") { outline, element in
            outline.accessibilitySetValue([element], forAttribute: .selectedRows)
        }
    }

    /// The outline's accessibility rows are AppKit's own elements (`NSOutlineRow`), not its row views, and not every
    /// one conforms to `NSAccessibilityRow`. They are read and set by attribute, the way an AX client's request
    /// reaches them.
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

    // MARK: - Owner row 9: B's row element itself, set through the AX server (lane FOCUSAX)

    /// Owner row 9 (b), and (a), which sets the same attribute from computer use: an AX client in another process
    /// sets `AXSelected` on B's row element while A's table has the focus. The request goes through the real AX
    /// server, as the Accessibility Inspector's does. The control makes the same set with the sidebar focused, which
    /// the focus rule takes, so a red line after it is the refusal and not a window the server cannot select in.
    /// AppKit's row element (`NSOutlineRow`) selects through NSTableView's own user path, which asks the delegate's
    /// `outlineView(_:shouldSelectItem:)` and then calls `selectRowIndexes(_:byExtendingSelection:)`, and never
    /// through the outline's marked `AXSelectedRows` entries.
    func testAnAXServerSelectOfTheRowElementWithTheTableFocusedShowsTheSelectedResult() throws {
        try prepareTheAXServer()
        let rowB = try row(of: resultB)
        click(resultA)
        assertShows(resultA, "AXSelected with the sidebar focused, before")
        XCTAssertEqual(AXProcessProbe.setRowSelected(sidebarOutline, row: rowB), .success,
                       "the AX server set no AXSelected on row element \(rowB): \(AXProcessProbe.treeDescription())")
        assertShows(resultB, "the control (the AX server's AXSelected selects nothing in this window)")
        try assertAnAccessibilitySelectShowsResultB("AXSelected on B's row element through the AX server") { _, _ in
            XCTAssertEqual(AXProcessProbe.setRowSelected(sidebarOutline, row: rowB), .success)
            // SWIFT's ruling, item 9: the notice inside the request spent the token, before anything spins the run loop.
            XCTAssertFalse(controller.sidebarController.outlineView.isHoldingProposedSelect,
                           "the row's AX select left its token after the request")
        }
        assertAnUnexplainedSelectAfterwardIsRefused()
    }

    /// Owner row 9 (c): an AX client's `AXPress` on B's row element or on its cell while A's table has the focus.
    /// AppKit's row element (`NSOutlineRow`) lists AXShowDefaultUI and AXShowAlternateUI, and the cell lists only the
    /// row's custom actions, so neither offers AXPress and the server does not run one. Nothing is selected and every
    /// surface stays on A, so the app refuses nothing (UX's E ruling). If AppKit ever offers AXPress there, this test
    /// fails, and the press then needs the mark that (b) needs.
    func testAnAXServerPressOnASidebarRowIsNotOfferedAndLeavesTheShownResult() throws {
        try prepareTheAXServer()
        let rowB = try row(of: resultB)
        click(resultA)
        assertShows(resultA, "AXPress, before")
        try focusTheShownResultsTable()
        let lines = try XCTUnwrap(AXProcessProbe.rowActionLines(sidebarOutline, row: rowB),
                                  "the AX server lists no row element \(rowB) in the sidebar")
        XCTAssertFalse(lines.contains { $0.contains("\"AXPress\"") }, "B's row or its cell offers AXPress: \(lines)")
        for child in [nil, 0] as [Int?] {
            let answer = AXProcessProbe.pressRow(sidebarOutline, row: rowB, child: child)
            XCTAssertNotEqual(answer, .success, "the server ran AXPress on B's \(child == nil ? "row" : "cell")")
        }
        assertShows(resultA, "after an AXPress on B's row and on its cell")
    }

    // MARK: - The one-request token's limits (rulings FOCUSAX-MARK-BIO P1 to P6 and FOCUSAX-MARK-SWIFT items 9 to 14)

    /// BIO P6 and SWIFT item 14: an Inspector's read of every attribute of B's row and their settability, a read of its
    /// actions and a press of the row and of its cell arm no token, so a later unexplained select of B is refused.
    func testAnInspectorReadAndPressOfARowLeaveNoMarkForALaterSelect() throws {
        try prepareTheAXServer()
        let outline = try startOnAWithItsTableFocused("Inspector read")
        let rowB = try row(of: resultB)
        XCTAssertFalse(AXProcessProbe.inspectRow(sidebarOutline, row: rowB).isEmpty)
        _ = AXProcessProbe.rowActionLines(sidebarOutline, row: rowB)
        AXProcessProbe.pressRow(sidebarOutline, row: rowB)
        AXProcessProbe.pressRow(sidebarOutline, row: rowB, child: 0)
        XCTAssertFalse(outline.isHoldingProposedSelect, "an Inspector read or press armed a token")
        outline.selectRowIndexes(IndexSet(integer: rowB), byExtendingSelection: false)
        assertShows(resultA, "an unexplained select of B after an Inspector read of B's row")
    }

    /// BIO P1 and SWIFT N1: AppKit's question for the row that is already the only selection arms nothing, since no
    /// select and no notice follow it. The control: the question for another row arms one.
    func testTheProposalOfTheOnlySelectedRowArmsNoMark() throws {
        let outline = try startOnAWithItsTableFocused("P1")
        XCTAssertTrue(propose(try sidebarItem(resultA), in: outline))
        XCTAssertFalse(outline.isHoldingProposedSelect, "a proposal that changes nothing armed a mark")
        XCTAssertTrue(propose(try sidebarItem(resultB), in: outline))
        XCTAssertTrue(outline.isHoldingProposedSelect, "the control: a proposal of another row armed no mark")
    }

    /// SWIFT item 10 (N1) through the AX server: an AX select of the row already selected leaves no token.
    func testAnAXSelectOfTheSelectedRowArmsNoToken() throws {
        try prepareTheAXServer()
        let outline = try startOnAWithItsTableFocused("AX select of the selected row")
        XCTAssertEqual(AXProcessProbe.setRowSelected(sidebarOutline, row: try row(of: resultA)), .success)
        XCTAssertFalse(outline.isHoldingProposedSelect, "the AX select of the selected row left a token")
        propose(try sidebarItem(resultA), in: outline)
        XCTAssertFalse(outline.isHoldingProposedSelect, "the question for the selected row armed a token")
        assertShows(resultA, "after an AX select of the selected row")
    }

    /// SWIFT item 11 (N3): a question that no select follows is spent by the next select of any row, so a later
    /// select of the proposed row is unexplained and refused.
    func testAProposalNoSelectFollowsIsSpentByTheNextSelect() throws {
        let outline = try startOnAWithItsTableFocused("N3")
        let (rowA, rowB) = (try row(of: resultA), try row(of: resultB))
        propose(try sidebarItem(resultB), in: outline)
        XCTAssertTrue(outline.isHoldingProposedSelect, "the control: a proposal of B armed no token")
        outline.selectRowIndexes(IndexSet(integer: rowA), byExtendingSelection: false)
        XCTAssertFalse(outline.isHoldingProposedSelect, "a select of another row left the token")
        outline.selectRowIndexes(IndexSet(integer: rowB), byExtendingSelection: false)
        assertShows(resultA, "a select of the proposed row after another select")
    }

    /// BIO P2 (T3): a suppressed change of the selection, as a reload's or a restore's, ends an armed token, so an
    /// unexplained select of the armed row after it is refused.
    func testASuppressedSelectionChangeEndsAnArmedMark() throws {
        click(resultA)
        assertShows(resultA, "P2, before")
        let third = try startRescan()
        waitForApply(third)
        let outline = try startOnAWithItsTableFocused("P2")
        let rowX = outline.row(forItem: try XCTUnwrap(item(at: third.copy, in: controller.sidebarController.rootItems)))
        let rowB = try row(of: resultB)
        propose(try sidebarItem(resultB), in: outline)
        controller.sidebarController.withSelectionSuppressed {
            outline.selectRowIndexes(IndexSet(integer: rowX), byExtendingSelection: false)
        }
        outline.selectRowIndexes(IndexSet(integer: rowB), byExtendingSelection: false)
        assertShows(resultA, "an unexplained select of the armed row after a suppressed change")
    }

    /// SWIFT item 12 (N4): the notice of a suppressed select of the proposed row spends the token.
    func testASuppressedNoticeSpendsTheToken() throws {
        let outline = try startOnAWithItsTableFocused("N4")
        let (rowA, rowB) = (try row(of: resultA), try row(of: resultB))
        let sidebar = controller.sidebarController!
        propose(try sidebarItem(resultB), in: outline)
        sidebar.withSelectionSuppressed { outline.selectRowIndexes(IndexSet(integer: rowB), byExtendingSelection: false) }
        XCTAssertFalse(outline.isHoldingProposedSelect, "a suppressed select of the proposed row left the token")
        sidebar.withSelectionSuppressed { outline.selectRowIndexes(IndexSet(integer: rowA), byExtendingSelection: false) }
        assertShows(resultA, "after the suppressed selects")
        outline.selectRowIndexes(IndexSet(integer: rowB), byExtendingSelection: false)
        assertShows(resultA, "an unexplained select of B after a suppressed notice")
    }

    /// BIO P3 (T2) and SWIFT item 13 (N5): a token that no select and no notice spend ends with the run-loop turn that
    /// armed it, so an unexplained select of the armed row one turn later is refused.
    func testAMarkArmedWithNoSelectEndsWithItsRunLoopTurn() throws {
        let outline = try startOnAWithItsTableFocused("P3")
        let rowB = try row(of: resultB)
        propose(try sidebarItem(resultB), in: outline)
        XCTAssertTrue(outline.isHoldingProposedSelect, "the control: a proposal of B armed no token")
        XCTAssertTrue(waitUntilOnRunLoop(budget: .lookup) { !outline.isHoldingProposedSelect },
                      "the mark outlived its run-loop turn")
        outline.selectRowIndexes(IndexSet(integer: rowB), byExtendingSelection: false)
        assertShows(resultA, "an unexplained select of the armed row one turn later")
    }

    /// BIO P4 (T1, T4) and SWIFT N2: a token names the item, not only its row. A row shift that posts no notice puts
    /// another item at B's row, and an unexplained select of that row is refused.
    func testAMarkArmedForOneResultMarksNoOtherResultAtItsRow() throws {
        let outline = try startOnAWithItsTableFocused("P4")
        let itemB = try sidebarItem(resultB)
        let oldRowB = outline.row(forItem: itemB)
        XCTAssertLessThan(try row(of: resultA), oldRowB, "A's selected row would move with the shift")
        let parent = try XCTUnwrap(outline.parent(forItem: itemB) as? SidebarItem, "B's row has no parent row")
        let index = try XCTUnwrap(parent.children.firstIndex { $0 === itemB })
        propose(itemB, in: outline)
        parent.children.insert(SidebarItem(title: "FOCUSAX row shift", type: .folder), at: index)
        outline.insertItems(at: IndexSet(integer: index), inParent: parent, withAnimation: [])
        XCTAssertFalse((outline.item(atRow: oldRowB) as AnyObject?) === itemB, "no row moved")
        outline.selectRowIndexes(IndexSet(integer: oldRowB), byExtendingSelection: false)
        assertShows(resultA, "an unexplained select of B's old row, which another item now holds")
    }

    /// BIO P5, the lane's named hole end to end: an AX select of the row already shown, then a rescan that moves the
    /// rows, then an unexplained select of the old row index. It is refused.
    func testAnAXSelectOfTheShownRowThenARescanLetsNoUnexplainedSelectThrough() throws {
        try prepareTheAXServer()
        let outline = try startOnAWithItsTableFocused("P5")
        let rowAAtTheSelect = try row(of: resultA)
        XCTAssertEqual(AXProcessProbe.setRowSelected(sidebarOutline, row: rowAAtTheSelect), .success)
        waitForApply(try startRescan())
        XCTAssertNotEqual(try row(of: resultA), rowAAtTheSelect, "the rescan moved no row")
        outline.selectRowIndexes(IndexSet(integer: rowAAtTheSelect), byExtendingSelection: false)
        assertShows(resultA, "an unexplained select of the old row after an AX select of the shown row and a rescan")
    }

    /// A shown and A's table focused, the start of each pin above.
    private func startOnAWithItsTableFocused(_ context: String) throws -> SidebarOutlineView {
        click(resultA)
        assertShows(resultA, "\(context), before")
        try focusTheShownResultsTable()
        return controller.sidebarController.outlineView
    }

    private func sidebarItem(_ result: Result) throws -> SidebarItem {
        try XCTUnwrap(item(at: result.url, in: controller.sidebarController.rootItems),
                      "the sidebar lists no row for \(result.url.lastPathComponent)")
    }

    /// AppKit's question on its user path (`outlineView(_:shouldSelectItem:)`), asked as AppKit asks it.
    @discardableResult
    private func propose(_ item: SidebarItem, in outline: SidebarOutlineView) -> Bool {
        controller.sidebarController.outlineView(outline, shouldSelectItem: item)
    }

    /// After an accessibility select shows B, with the focus still out of the sidebar, a selection nobody asked for
    /// is still refused: the explicit mark ended with the request.
    private func assertAnUnexplainedSelectAfterwardIsRefused(file: StaticString = #filePath, line: UInt = #line) {
        let outline = controller.sidebarController.outlineView!
        XCTAssertFalse(controller.sidebarController.outlineViewIsFirstResponder(window.firstResponder),
                       "the focus moved into the sidebar", file: file, line: line)
        XCTAssertFalse(outline.isMakingExplicitSelection, "the explicit mark outlived the request", file: file, line: line)
        guard let rowA = try? row(of: resultA) else { return XCTFail("no row for A", file: file, line: line) }
        outline.selectRowIndexes(IndexSet(integer: rowA), byExtendingSelection: false)
        assertShows(resultB, "an unexplained selection right after the accessibility select", file: file, line: line)
    }

    /// The sidebar's outline as the AX server finds it.
    private var sidebarOutline: AXProcessProbe.Query {
        AXProcessProbe.Query(role: "AXOutline", text: SidebarAccessibilityIdentifier.outline)
    }

    /// Orders the window front, so the AX server lists it, or skips when the process cannot reach the server.
    private func prepareTheAXServer() throws {
        try XCTSkipUnless(AXProcessProbe.isAvailable, AXProcessProbe.unavailableReason)
        window.orderFront(nil)
        let shown = window!
        addTeardownBlock { @MainActor in shown.orderOut(nil) }
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
        // The notice also points the Inspector's provenance and project-copy record at the row, so none may go out.
        let posted = Done()
        let observer = NotificationCenter.default.addObserver(
            forName: .sidebarSelectionChanged, object: controller.sidebarController, queue: nil
        ) { _ in MainActor.assumeIsolated { posted.value = true } }
        defer { NotificationCenter.default.removeObserver(observer) }
        outline.selectRowIndexes(IndexSet(integer: try row(of: resultB)), byExtendingSelection: false)
        XCTAssertFalse(posted.value, "a refused selection posted the sidebar's selection notice: \(describeScreen())")
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

    /// Pin for Select Siblings (Cmd-Shift-A) while the shown result's table has the focus: a person asked for it, so
    /// both results stay selected. A selection of more than one row never met the focus rule, so it is green at the
    /// base too, and the explicit mark keeps it so if the rule ever covers more rows.
    func testSelectSiblingsWithAChildViewerShownSelectsEveryResult() throws {
        click(resultA)
        assertShows(resultA, "Select Siblings, before")
        try focusTheShownResultsTable()
        controller.sidebarController.selectAllSiblings()
        let selected = Set(controller.sidebarController.selectedItems().compactMap { $0.url?.standardizedFileURL })
        XCTAssertEqual(selected, [resultA.url, resultB.url], "Select Siblings went back: \(describeScreen())")
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

    /// Copies result A's folder into Analyses under a new name and starts a rescan, the watcher's (`notify` false) or
    /// the one that replays an unchanged selection (`notify` true).
    private func startRescan(notify: Bool = false) throws -> (done: Done, copy: URL) {
        copies += 1
        let name = String(format: "taxtriage-batch-2026-11-04T09-%02d-00", copies)
        let copy = analyses.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.copyItem(at: resultA.url, to: copy)
        let scan = controller.sidebarController.reloadFromFilesystemAsync(notifyUnchangedSelectionRefresh: notify)
        XCTAssertNotNil(scan, "the sidebar started no rescan")
        let done = Done()
        Task { @MainActor in
            await scan?.value
            done.value = true
        }
        return (done, copy.standardizedFileURL)
    }

    /// Waits for the rescan's task to end, then checks that it applied: a scan found stale ends its task without
    /// touching the tree (`reloadFromFilesystemAsync`), so the copied folder's row proves the apply ran.
    private func waitForApply(_ rescan: (done: Done, copy: URL), file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(waitUntilOnRunLoop(budget: .lookup) { rescan.done.value }, "the rescan never applied",
                      file: file, line: line)
        XCTAssertNotNil(item(at: rescan.copy, in: controller.sidebarController.rootItems),
                        "the rescan was dropped as stale: the sidebar does not list \(rescan.copy.lastPathComponent)",
                        file: file, line: line)
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
