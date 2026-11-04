// MultipleSequenceAlignmentSurfaceRouteTests.swift - The alignment viewer on the surface host leaves nothing behind (Phase 3.2 lane MSA)
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// An alignment opens in a real window through the sidebar's `displayContent(for:)`. These tests take the viewer away by
// each way it can leave and read what is left: the viewer, its pane, the callbacks the App wired on it, the alignment's
// blocks in the Inspector, and the roles a person marked. The roles live in the Inspector's model and are saved
// nowhere, so a test reads them from the Inspector each time and holds no model across a switch, which would make a
// lost model look kept. `MultipleSequenceAlignmentSurfaceLoadTests` holds a load in flight.

import AppKit
import LungfishTestSupport
import XCTest
@testable import LungfishApp
@testable import LungfishIO
@testable import LungfishKit

/// What the alignment bundle's own reader says when a file of the bundle is damaged. A real load throws this kind of
/// error, not a `SurfaceError`.
struct DamagedAlignmentFile: LocalizedError {
    var errorDescription: String? { "Alignment bundle is missing required file: alignment/primary.aligned.fasta" }
}

/// A surface whose load fails on the file, so the alignment's show never installs.
@MainActor
private final class RefusingAlignmentSurface: ResultViewport {
    let controller = NSViewController()
    var viewController: NSViewController { controller }
    var surfaceKind: SurfaceKind { .bundle(.multipleSequenceAlignment) }

    func load(input: Any, token: AsyncRequestToken<SurfaceRequest>) async throws {
        throw DamagedAlignmentFile()
    }
}

@MainActor
final class MultipleSequenceAlignmentSurfaceRouteTests: XCTestCase {
    private var root: URL!
    private var hostDefaults: HostDefaultsRestorer!

    private let allShown = AlignmentChrome(ruler: false, viewer: false, header: false, status: false)
    private let allHidden = AlignmentChrome(ruler: true, viewer: true, header: true, status: true)

    override func setUpWithError() throws {
        isolateAlignmentPaneDefaults()
    }

    override func setUp() async throws {
        try await super.setUp()
        root = try TestTempDirectory.make(prefix: "MSASurfaceRoute")
        hostDefaults = HostDefaultsRestorer(keysContaining: root.lastPathComponent)
    }

    override func tearDown() async throws {
        hostDefaults.restore()
        TestTempDirectory.cleanup(root)
        try await super.tearDown()
    }

    // MARK: - The surface

    func testTheAlignmentViewerOpensThroughTheSurfaceHost() async throws {
        let harness = try ViewSwitchWindowHarness()
        defer { harness.close() }
        harness.select(try await buildAlignmentRow(root))
        let viewer = harness.split.viewerController!

        let opened = await waitUntil(budget: .lookup) { alignmentIsShownAndWired(harness) }

        XCTAssertTrue(opened, "the alignment viewer never opened")
        XCTAssertEqual(viewer.installedSurface?.surfaceKind, .bundle(.multipleSequenceAlignment))
        XCTAssertEqual(viewer.children.filter { $0 is MultipleSequenceAlignmentViewController }.count, 1)
    }

    /// Zoom reads the slot in `ViewerViewController.swift`, so it must still reach the viewer, and never the genomics frame.
    func testZoomReachesTheViewerThroughTheSlot() async throws {
        let harness = try ViewSwitchWindowHarness()
        defer { harness.close() }
        harness.select(try await buildAlignmentRow(root))
        let viewer = harness.split.viewerController!
        let opened = await waitUntil(budget: .lookup) { alignmentIsShownAndWired(harness) }
        XCTAssertTrue(opened, "the alignment viewer never opened")
        let alignment = try XCTUnwrap(viewer.multipleSequenceAlignmentViewController)

        let fitted = alignment.testingAlignmentColumnWidth
        viewer.zoomIn()
        let zoomedIn = alignment.testingAlignmentColumnWidth
        XCTAssertGreaterThan(zoomedIn, fitted, "Zoom In never reached the viewer")
        viewer.zoomOut()
        XCTAssertLessThan(alignment.testingAlignmentColumnWidth, zoomedIn, "Zoom Out never reached the viewer")
        viewer.zoomToFit()
        XCTAssertEqual(alignment.testingAlignmentColumnWidth, fitted, "Zoom to Fit never reached the viewer")
    }

    // MARK: - The words

    /// A bundle with its alignment file gone says what happened and what to try. The base said only
    /// "Unable to load alignment bundle.", with neither the file nor a next step.
    func testAnAlignmentFileThatDoesNotReadSaysWhatToTry() async throws {
        let harness = try ViewSwitchWindowHarness()
        defer { harness.close() }
        let row = try await buildAlignmentRow(root)
        try FileManager.default.removeItem(
            at: try XCTUnwrap(row.url).appendingPathComponent("alignment/primary.aligned.fasta")
        )

        harness.select(row)

        await assertTheRouteSaysItDidNotOpen(harness, fileWords: "primary.aligned.fasta")
    }

    /// A surface that refuses on the file takes the same words, the same punctuation as a tree that does not open,
    /// and brings the chrome back.
    func testAnAlignmentThatTheHostRefusesSaysWhatToTry() async throws {
        let harness = try ViewSwitchWindowHarness()
        defer { harness.close() }
        harness.split.viewerController.surfaceHost.registry.register(.bundle(.multipleSequenceAlignment)) {
            RefusingAlignmentSurface()
        }

        harness.select(try await buildAlignmentRow(root))

        let fileWords = "Alignment bundle is missing required file: alignment/primary.aligned.fasta"
        await assertTheRouteSaysItDidNotOpen(harness, fileWords: fileWords)
        XCTAssertTrue(
            harness.split.viewerController.statusBar.positionLabel.stringValue.contains(
                "\(fileWords). Select the item again. If it still does not open, import or rebuild the alignment."
            ),
            harness.split.viewerController.statusBar.positionLabel.stringValue
        )
    }

    /// A load that fails after a newer selection has begun brings back no chrome, since the newer selection owns it.
    /// The base's `tearDownFailedController` restored it whatever `canCommit` said.
    func testASupersededLoadThatFailsLeavesTheChromeToTheNewerOne() async throws {
        let viewer = ViewerViewController()
        viewer.view.frame = NSRect(x: 0, y: 0, width: 1400, height: 800)
        let missing = root.appendingPathComponent("gone.lungfishmsa", isDirectory: true)

        _ = try? await viewer.displayMultipleSequenceAlignmentBundle(at: missing, canCommit: { false })

        XCTAssertEqual(AlignmentChrome(viewer), allHidden, "a stale failure brought the chrome back over the newer selection")
        XCTAssertNil(viewer.multipleSequenceAlignmentViewController)
    }

    // MARK: - Every way the viewer leaves

    /// Another row in the sidebar, for each kind of the matrix: the viewer and its pane go, and with them the callbacks
    /// the App wired and the alignment's blocks in the Inspector, while the roles a person marked stay for the return.
    /// The test holds the controller the viewer let go, since the question is what a controller that something else
    /// still holds can reach.
    func testEveryKindOfTheMatrixTakesTheAlignmentAwayAndKeepsTheMarkedRoles() async throws {
        let harness = try ViewSwitchWindowHarness()
        defer { harness.close() }
        let viewer = harness.split.viewerController!
        let alignment = try await buildAlignmentRow(root)
        harness.select(alignment)
        let first = await waitUntil(budget: .lookup) { alignmentIsShownAndWired(harness) }
        XCTAssertTrue(first, "the alignment never opened")
        let marked = try markLastRowAsExclusion(harness)

        for kind in ViewSwitchKinds.all where kind.name != "MSA" {
            let next = try await buildRow(of: kind.name, under: root)
            harness.select(alignment)
            let shown = await waitUntil(budget: .lookup) { alignmentIsShownAndWired(harness) }
            XCTAssertTrue(shown, "the alignment never opened before \(kind.name)")
            XCTAssertEqual(markedRole(harness, of: marked), .exclusion, "the roles did not survive the way back from the kind before \(kind.name)")
            let held = viewer.multipleSequenceAlignmentViewController

            harness.select(next)

            let left = await waitUntil(budget: .lookup) { viewer.multipleSequenceAlignmentViewController == nil }
            XCTAssertTrue(left, "\(kind.name) left the alignment viewer on screen")
            XCTAssertFalse(viewer.children.contains { $0 is MultipleSequenceAlignmentViewController }, "\(kind.name) left the alignment a child")
            XCTAssertEqual(uncutCallbacks(held), [], "\(kind.name) left callbacks attached")
            XCTAssertTrue(bottomPanes(in: viewer.view).isEmpty, "\(kind.name) left a pane behind")
            XCTAssertNil(documentBlock(harness), "\(kind.name) left the alignment's document in the Inspector")
            XCTAssertNil(selectionBlock(harness), "\(kind.name) left the alignment's selection in the Inspector")
        }
    }

    /// A second alignment replaces the first: one viewer, the first one's callbacks cut, and the second one's blocks in
    /// the Inspector, since the first one's removal takes out its own blocks before the second gives its own.
    func testASecondAlignmentReplacesTheFirstAndKeepsItsOwnBlocks() async throws {
        let harness = try ViewSwitchWindowHarness()
        defer { harness.close() }
        let viewer = harness.split.viewerController!
        let first = try await buildAlignmentRow(root)
        let second = try await buildAlignmentRow(root)
        harness.select(first)
        let shown = await waitUntil(budget: .lookup) { alignmentIsShownAndWired(harness) }
        XCTAssertTrue(shown, "the first alignment never opened")
        let held = viewer.multipleSequenceAlignmentViewController

        harness.select(second)

        let replaced = await waitUntil(budget: .lookup) {
            viewer.multipleSequenceAlignmentViewController?.bundleURL == second.url && alignmentIsShownAndWired(harness)
        }
        XCTAssertTrue(replaced, "the second alignment never replaced the first")
        XCTAssertEqual(viewer.children.filter { $0 is MultipleSequenceAlignmentViewController }.count, 1)
        XCTAssertEqual(uncutCallbacks(held), [], "the first alignment kept callbacks")
        XCTAssertEqual(bottomPanes(in: viewer.view).count, 1, "the first alignment left its pane behind")
        XCTAssertEqual(
            harness.split.inspectorController.viewModel.documentSectionViewModel.msaDiscriminatingSites?.bundleURL,
            second.url,
            "the Inspector's sites section still describes the first alignment"
        )
    }

    /// The project switch reset takes the viewer away, its callbacks and its blocks, and brings the chrome back. The
    /// roles stay in the Inspector for the same bundle, as they do through any other row.
    func testAProjectSwitchTakesTheAlignmentAway() async throws {
        let harness = try ViewSwitchWindowHarness()
        defer { harness.close() }
        let viewer = harness.split.viewerController!
        let alignment = try await buildAlignmentRow(root)
        harness.select(alignment)
        let shown = await waitUntil(budget: .lookup) { alignmentIsShownAndWired(harness) }
        XCTAssertTrue(shown, "the alignment never opened")
        let marked = try markLastRowAsExclusion(harness)
        let held = viewer.multipleSequenceAlignmentViewController

        harness.split.resetWindowForProjectChange()

        XCTAssertNil(viewer.multipleSequenceAlignmentViewController, "a project switch left the alignment on screen")
        XCTAssertEqual(uncutCallbacks(held), [], "a project switch left callbacks attached")
        XCTAssertTrue(bottomPanes(in: viewer.view).isEmpty, "a project switch left a pane behind")
        XCTAssertNil(documentBlock(harness), "a project switch left the alignment's document in the Inspector")
        XCTAssertNil(selectionBlock(harness), "a project switch left the alignment's selection in the Inspector")
        XCTAssertEqual(AlignmentChrome(viewer), allShown, "a project switch left chrome hidden")

        harness.select(alignment)
        let back = await waitUntil(budget: .lookup) { alignmentIsShownAndWired(harness) }
        XCTAssertTrue(back, "the alignment never opened again")
        XCTAssertEqual(markedRole(harness, of: marked), .exclusion, "the roles did not survive a project switch")
    }

    /// A window close takes the viewer, the Inspector and the marked roles with it. Roles are saved nowhere, at the base
    /// as well. Nothing in this test holds the split, the viewer or the model afterwards, and the split is shown to be
    /// gone before they are read, so a viewer kept alive by a callback, the surface or the host cannot pass.
    func testClosingTheWindowLeavesNoAlignmentBehind() async throws {
        let row = try await buildAlignmentRow(root)
        weak var weakSplit: MainSplitViewController?
        weak var weakAlignment: MultipleSequenceAlignmentViewController?
        weak var weakSites: MSADiscriminatingSitesInspectorModel?
        try await { () async throws -> Void in
            let harness = try ViewSwitchWindowHarness()
            harness.select(row)
            let shown = await waitUntil(budget: .lookup) { alignmentIsShownAndWired(harness) }
            XCTAssertTrue(shown, "the alignment never opened")
            weakSplit = harness.split
            weakAlignment = harness.split.viewerController.multipleSequenceAlignmentViewController
            weakSites = harness.split.inspectorController.viewModel.documentSectionViewModel.msaDiscriminatingSites
            // Not `harness.close()`: it clears the viewport through the host, which would remove the viewer even if a
            // window close did not.
            harness.controller.close()
            harness.split.invalidateDisplayRequest()
            harness.split.inspectorController.clearSelection()
        }()

        let gone = await waitUntil(budget: .lookup) { weakSplit == nil }
        XCTAssertTrue(gone, "the split is still alive, so this test cannot tell a viewer the window kept from one something else kept")
        let released = await waitUntil(budget: .lookup) { weakAlignment == nil }
        XCTAssertTrue(released, "the alignment viewer outlived its window")
        XCTAssertNil(weakSites, "the marked roles outlived their window")
    }

    // MARK: - The pane

    /// The flag holds what the person left: the default open writes nothing, a close and an open each write once, and
    /// neither a removal nor a new viewer changes it.
    func testThePaneStaysAsThePersonLeftItThroughAnotherRow() async throws {
        let harness = try ViewSwitchWindowHarness()
        defer { harness.close() }
        let viewer = harness.split.viewerController!
        let alignment = try await buildAlignmentRow(root)
        let other = try await buildRow(of: "Status only", under: root)
        let flag = { ViewerViewController.multipleSequenceAlignmentDefaults.object(forKey: MSABottomPaneView.DefaultsKey.isOpen) as? Bool }

        harness.select(alignment)
        let opened = await waitUntil(budget: .lookup) { alignmentIsShownAndWired(harness) && viewer.isActiveDrawerOpen }
        XCTAssertTrue(opened, "the pane never opened by default")
        XCTAssertNil(flag(), "the default open wrote the flag")

        viewer.toggleAnnotationDrawer()
        XCTAssertFalse(viewer.isActiveDrawerOpen, "View > Show Drawer never reached the pane")
        XCTAssertEqual(flag(), false)

        harness.select(other)
        let left = await waitUntil(budget: .lookup) { viewer.multipleSequenceAlignmentViewController == nil }
        XCTAssertTrue(left, "the other row left the alignment on screen")
        XCTAssertEqual(flag(), false, "a removal changed the flag")

        harness.select(alignment)
        let closedAgain = await waitUntil(budget: .lookup) { alignmentIsShownAndWired(harness) }
        XCTAssertTrue(closedAgain, "the alignment never opened again")
        XCTAssertFalse(viewer.isActiveDrawerOpen, "a closed pane came back open")
        XCTAssertEqual(flag(), false)

        viewer.toggleAnnotationDrawer()
        XCTAssertTrue(viewer.isActiveDrawerOpen, "View > Show Drawer never reached the pane")
        XCTAssertEqual(flag(), true)

        harness.select(other)
        let leftOpen = await waitUntil(budget: .lookup) { viewer.multipleSequenceAlignmentViewController == nil }
        XCTAssertTrue(leftOpen, "the other row left the alignment on screen")
        XCTAssertEqual(flag(), true, "a removal with the pane open changed the flag")

        harness.select(alignment)
        let openAgain = await waitUntil(budget: .lookup) { alignmentIsShownAndWired(harness) && viewer.isActiveDrawerOpen }
        XCTAssertTrue(openAgain, "an open pane came back closed")
    }

    /// A removal with the pane open leaves no pane in the viewer, writes no flag, and the viewer goes once the removal
    /// has dropped it. The test holds both weakly, so what is read is what the viewer kept.
    func testARemovalWithThePaneOpenLeavesNoPaneBehind() async throws {
        let harness = try ViewSwitchWindowHarness()
        defer { harness.close() }
        let viewer = harness.split.viewerController!
        harness.select(try await buildAlignmentRow(root))
        let opened = await waitUntil(budget: .lookup) { alignmentIsShownAndWired(harness) && viewer.isActiveDrawerOpen }
        XCTAssertTrue(opened, "the pane never opened by default")
        weak var weakAlignment = viewer.multipleSequenceAlignmentViewController
        weak var weakPane = bottomPanes(in: viewer.view).first

        harness.select(try await buildRow(of: "Status only", under: root))

        let left = await waitUntil(budget: .lookup) { viewer.multipleSequenceAlignmentViewController == nil }
        XCTAssertTrue(left, "the other row left the alignment on screen")
        XCTAssertTrue(bottomPanes(in: viewer.view).isEmpty, "a pane stayed in the viewer")
        XCTAssertFalse(viewer.isActiveDrawerOpen, "the toolbar's drawer state still reads open")
        XCTAssertNil(ViewerViewController.multipleSequenceAlignmentDefaults.object(forKey: MSABottomPaneView.DefaultsKey.isOpen))
        let released = await waitUntil(budget: .lookup) { weakAlignment == nil && weakPane == nil }
        XCTAssertTrue(released, "something still holds the removed viewer or its pane")
    }

    // MARK: - Support

    /// Marks the last row of the Inspector's sites section as Exclusion and returns the row's id. The test keeps the id
    /// and not the model, so a model that was dropped and rebuilt cannot pass.
    private func markLastRowAsExclusion(_ harness: ViewSwitchWindowHarness) throws -> String {
        let model = try XCTUnwrap(harness.split.inspectorController.viewModel.documentSectionViewModel.msaDiscriminatingSites)
        let row = try XCTUnwrap(model.rows.last)
        model.setRole(.exclusion, for: row)
        return row.id
    }

    private func markedRole(_ harness: ViewSwitchWindowHarness, of rowID: String) -> MSADiscriminatingSitesInspectorModel.RowRole? {
        harness.split.inspectorController.viewModel.documentSectionViewModel.msaDiscriminatingSites?.rolesByRowID[rowID]
    }

    /// Waits until the route has either shown the alignment or written a refusal, which ends the wait at once on the
    /// base as well, then reads the words.
    private func assertTheRouteSaysItDidNotOpen(
        _ harness: ViewSwitchWindowHarness,
        fileWords: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        let viewer = harness.split.viewerController!
        let words = { viewer.statusBar.positionLabel.stringValue }
        _ = await waitUntil(budget: .lookup) { viewer.multipleSequenceAlignmentViewController != nil || words().contains("Unable to") }
        XCTAssertTrue(
            words().contains("Unable to open the alignment."),
            "the status line never said the alignment did not open: \(words())", file: file, line: line
        )
        XCTAssertTrue(words().contains(fileWords), "the status line left out the file's own words: \(words())", file: file, line: line)
        XCTAssertTrue(
            words().hasSuffix(" Select the item again. If it still does not open, import or rebuild the alignment."),
            "the status line gave no next step that can help: \(words())", file: file, line: line
        )
        XCTAssertFalse(words().contains("bundle:"), "the words name an internal kind id: \(words())", file: file, line: line)
        XCTAssertEqual(AlignmentChrome(viewer), allShown, "a failed load left chrome hidden", file: file, line: line)
        XCTAssertNil(viewer.multipleSequenceAlignmentViewController, "an alignment that did not open is on screen", file: file, line: line)
        XCTAssertNil(documentBlock(harness), "the Inspector describes an alignment that is not shown", file: file, line: line)
    }
}

// MARK: - Shared support of the alignment route tests

/// Which of the genomics viewer's chrome views are hidden.
struct AlignmentChrome: Equatable {
    var ruler: Bool
    var viewer: Bool
    var header: Bool
    var status: Bool
}

extension AlignmentChrome {
    @MainActor
    init(_ viewer: ViewerViewController) {
        self.init(
            ruler: viewer.enhancedRulerView.isHidden,
            viewer: viewer.viewerView.isHidden,
            header: viewer.headerView.isHidden,
            status: viewer.statusBar.isHidden
        )
    }
}

@MainActor
func documentBlock(_ harness: ViewSwitchWindowHarness) -> Any? {
    harness.split.inspectorController.viewModel.documentSectionViewModel.multipleSequenceAlignmentDocument
}

@MainActor
func selectionBlock(_ harness: ViewSwitchWindowHarness) -> Any? {
    harness.split.inspectorController.viewModel.selectionSectionViewModel.multipleSequenceAlignmentSelection
}

/// The alignment is shown, and the route has wired it and given the Inspector its document and its first selection.
@MainActor
func alignmentIsShownAndWired(_ harness: ViewSwitchWindowHarness) -> Bool {
    harness.split.viewerController.multipleSequenceAlignmentViewController?.onSelectionStateChanged != nil
        && documentBlock(harness) != nil
        && selectionBlock(harness) != nil
}

/// The names of the callbacks still set on an alignment viewer, every one the App can wire.
@MainActor
func uncutCallbacks(_ controller: MultipleSequenceAlignmentViewController?) -> [String] {
    guard let controller else { return [] }
    let callbacks: [(String, Any?)] = [
        ("onExtractSequenceRequested", controller.onExtractSequenceRequested),
        ("onExtractAnnotatedSequenceRequested", controller.onExtractAnnotatedSequenceRequested),
        ("onExportFASTARequested", controller.onExportFASTARequested),
        ("onExportMSASelectionRequested", controller.onExportMSASelectionRequested),
        ("onCopyMSASelectionRequested", controller.onCopyMSASelectionRequested),
        ("onReferenceRowChanged", controller.onReferenceRowChanged),
        ("onConsensusComparisonRequested", controller.onConsensusComparisonRequested),
        ("onExportAlignmentRequested", controller.onExportAlignmentRequested),
        ("onCreateBundleRequested", controller.onCreateBundleRequested),
        ("onCreateAnnotatedBundleRequested", controller.onCreateAnnotatedBundleRequested),
        ("onRunOperationRequested", controller.onRunOperationRequested),
        ("onInferTreeRequested", controller.onInferTreeRequested),
        ("onAddAnnotationRequested", controller.onAddAnnotationRequested),
        ("onProjectAnnotationRequested", controller.onProjectAnnotationRequested),
        ("onSelectionStateChanged", controller.onSelectionStateChanged),
        ("onExportDistanceMatrixRequested", controller.onExportDistanceMatrixRequested),
        ("onFocusedDistancePairChanged", controller.onFocusedDistancePairChanged),
        ("onBottomPaneStateChanged", controller.onBottomPaneStateChanged),
    ]
    return callbacks.filter { $0.1 != nil }.map(\.0)
}

/// Every alignment bottom pane under `view`.
@MainActor
func bottomPanes(in view: NSView) -> [MSABottomPaneView] {
    let own = (view as? MSABottomPaneView).map { [$0] } ?? []
    return own + view.subviews.flatMap { bottomPanes(in: $0) }
}

@MainActor
func buildAlignmentRow(_ root: URL) async throws -> SidebarItem {
    try await buildRow(of: "MSA", under: root)
}

/// Builds the sidebar row of one matrix kind under its own folder.
@MainActor
func buildRow(of name: String, under root: URL) async throws -> SidebarItem {
    let kind = try XCTUnwrap(ViewSwitchKinds.all.first { $0.name == name }, "the matrix has no kind \(name)")
    let row = try XCTUnwrap(ViewSwitchKinds.row(of: kind), "\(name) names no routing row")
    let kindRoot = try SafetyNetFiles.makeDirectory(
        root.appendingPathComponent(kind.folder + "-" + UUID().uuidString, isDirectory: true)
    )
    return try await row.build(RoutingRowContext(root: kindRoot, paths: SafetyNetPathRenderer(root: kindRoot))).item
}
