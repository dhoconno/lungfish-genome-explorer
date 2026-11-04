// PhylogeneticTreeSurfaceRouteTests.swift - The tree viewer on the surface host leaves nothing behind (Phase 3.2 lane PHYLO)
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// A tree bundle opens in a real window through the sidebar's `displayContent(for:)`. These tests take the viewer away
// by each way it can leave and read what is left of it: the viewer, the callbacks the App wired on it and the tree's
// blocks in the Inspector. They also read the words a person sees when a tree does not open.
//
// The tree viewer holds no edit. A selection, a collapsed clade and the zoom live in the controller and are not
// saved anywhere, and a re-root runs as a command that writes a new bundle. So nothing here asks for a save.

import AppKit
import LungfishTestSupport
import XCTest
@testable import LungfishApp
@testable import LungfishIO
@testable import LungfishKit
import LungfishPhylogeneticsUI

/// What the tree bundle's own loader says when a file of the bundle is damaged. A real load throws this kind of
/// error, not a `SurfaceError`.
private struct DamagedTreeFile: LocalizedError {
    var errorDescription: String? { "Tree bundle is missing required file: manifest.json" }
}

/// A surface whose load fails on the file, so the tree show never installs.
@MainActor
private final class RefusingTreeSurface: ResultViewport {
    let controller = NSViewController()
    var viewController: NSViewController { controller }
    var surfaceKind: SurfaceKind { .bundle(.phylogeneticTree) }

    func load(input: Any, token: AsyncRequestToken<SurfaceRequest>) async throws {
        throw DamagedTreeFile()
    }
}

@MainActor
final class PhylogeneticTreeSurfaceRouteTests: XCTestCase {
    private var root: URL!
    private var hostDefaults: HostDefaultsRestorer!

    override func setUp() async throws {
        try await super.setUp()
        root = try TestTempDirectory.make(prefix: "PhyloSurfaceRoute")
        hostDefaults = HostDefaultsRestorer(keysContaining: root.lastPathComponent)
    }

    override func tearDown() async throws {
        hostDefaults.restore()
        TestTempDirectory.cleanup(root)
        try await super.tearDown()
    }

    // MARK: - The surface

    func testTheTreeViewerOpensThroughTheSurfaceHost() async throws {
        let harness = try ViewSwitchWindowHarness()
        defer { harness.close() }
        harness.select(try await buildRow(of: "Tree"))
        let viewer = harness.split.viewerController!

        let opened = await waitUntil(budget: .lookup) { viewer.phylogeneticTreeViewController != nil }

        XCTAssertTrue(opened, "the tree viewer never opened")
        XCTAssertEqual(viewer.installedSurface?.surfaceKind, .bundle(.phylogeneticTree))
        XCTAssertEqual(viewer.children.filter { $0 is PhylogeneticTreeViewController }.count, 1)
    }

    // MARK: - The words

    /// A tree bundle with a file missing says what happened and what to try. The base said only
    /// "Unable to load tree bundle.", with neither the file nor a next step.
    func testATreeFileThatDoesNotReadSaysWhatToTry() async throws {
        let harness = try ViewSwitchWindowHarness()
        defer { harness.close() }
        let row = try await buildRow(of: "Tree")
        try FileManager.default.removeItem(at: try XCTUnwrap(row.url).appendingPathComponent("manifest.json"))

        harness.select(row)

        await assertTheRouteSaysItDidNotOpen(harness, fileWords: "Tree bundle is missing required file: manifest.json")
    }

    /// A surface that refuses on the file takes the same words, leaves neither a viewer nor an Inspector document
    /// behind and keeps the status bar in view.
    func testATreeThatTheHostRefusesSaysWhatToTry() async throws {
        let harness = try ViewSwitchWindowHarness()
        defer { harness.close() }
        harness.split.viewerController.surfaceHost.registry.register(.bundle(.phylogeneticTree)) { RefusingTreeSurface() }

        harness.select(try await buildRow(of: "Tree"))

        await assertTheRouteSaysItDidNotOpen(harness, fileWords: "Tree bundle is missing required file: manifest.json")
    }

    // MARK: - Every way the viewer leaves

    /// Another row in the sidebar, for each kind of the matrix: the tree viewer goes, and with it the callbacks the App
    /// wired on it and the tree's blocks in the Inspector. The test holds the controller the viewer let go, since the
    /// question is what a controller that something else still holds can reach.
    func testEveryKindOfTheMatrixTakesTheTreeAwayWithItsCallbacksAndInspectorState() async throws {
        let harness = try ViewSwitchWindowHarness()
        defer { harness.close() }
        let viewer = harness.split.viewerController!
        let tree = try await buildRow(of: "Tree")
        for kind in ViewSwitchKinds.all where kind.name != "Tree" {
            let next = try await buildRow(of: kind.name)
            harness.select(tree)
            let shown = await waitUntil(budget: .lookup) { self.treeIsShownAndWired(harness) }
            XCTAssertTrue(shown, "the tree never opened before \(kind.name)")
            let held = viewer.phylogeneticTreeViewController

            harness.select(next)

            let left = await waitUntil(budget: .lookup) { viewer.phylogeneticTreeViewController == nil }
            XCTAssertTrue(left, "\(kind.name) left the tree viewer on screen")
            XCTAssertFalse(viewer.children.contains { $0 is PhylogeneticTreeViewController }, "\(kind.name) left the tree a child")
            XCTAssertNil(held?.onSelectionStateChanged, "\(kind.name) left the tree's selection callback attached")
            XCTAssertNil(held?.onTreeBundleOperationRequested, "\(kind.name) left the tree's operation callback attached")
            XCTAssertNil(documentBlock(harness), "\(kind.name) left the tree's document in the Inspector")
            XCTAssertNil(selectionBlock(harness), "\(kind.name) left the tree's selection in the Inspector")
        }
    }

    /// A second tree replaces the first: one viewer, the first one's callbacks cut, and the second tree's blocks in the
    /// Inspector, since the first tree's removal takes out its own blocks before the second tree gives its own.
    func testASecondTreeReplacesTheFirstAndKeepsItsOwnBlocks() async throws {
        let harness = try ViewSwitchWindowHarness()
        defer { harness.close() }
        let viewer = harness.split.viewerController!
        let first = try await buildRow(of: "Tree")
        let second = try await buildRow(of: "Tree")
        harness.select(first)
        let shown = await waitUntil(budget: .lookup) { self.treeIsShownAndWired(harness) }
        XCTAssertTrue(shown, "the first tree never opened")
        let held = viewer.phylogeneticTreeViewController

        harness.select(second)

        let replaced = await waitUntil(budget: .lookup) { viewer.phylogeneticTreeViewController?.bundleURL == second.url }
        XCTAssertTrue(replaced, "the second tree never replaced the first")
        XCTAssertEqual(viewer.children.filter { $0 is PhylogeneticTreeViewController }.count, 1)
        XCTAssertNil(held?.onSelectionStateChanged, "the first tree kept its selection callback")
        XCTAssertNil(held?.onTreeBundleOperationRequested, "the first tree kept its operation callback")
        XCTAssertNotNil(documentBlock(harness), "the first tree's removal took the second tree's document out")
        XCTAssertNotNil(selectionBlock(harness), "the first tree's removal took the second tree's selection out")
    }

    /// A window close takes the tree with it. Nothing in this test holds the split, the viewer or the controller
    /// afterwards, and the split is shown to be gone before the tree is read, so a tree kept alive by a callback, the
    /// surface or the host cannot pass.
    func testClosingTheWindowLeavesNoTreeViewCallbackOrInspectorStateBehind() async throws {
        let row = try await buildRow(of: "Tree")
        weak var weakSplit: MainSplitViewController?
        weak var weakTree: PhylogeneticTreeViewController?
        try await { () async throws -> Void in
            let harness = try ViewSwitchWindowHarness()
            harness.select(row)
            let shown = await waitUntil(budget: .lookup) { self.treeIsShownAndWired(harness) }
            XCTAssertTrue(shown, "the tree never opened")
            weakSplit = harness.split
            weakTree = harness.split.viewerController.phylogeneticTreeViewController
            // Not `harness.close()`: it clears the viewport through the host, which would remove the tree even if a
            // window close did not.
            harness.controller.close()
            harness.split.invalidateDisplayRequest()
            harness.split.inspectorController.clearSelection()
        }()

        let gone = await waitUntil(budget: .lookup) { weakSplit == nil }
        XCTAssertTrue(gone, "the split is still alive, so this test cannot tell a tree the window kept from one something else kept")
        XCTAssertNil(weakTree, "the tree viewer outlived its window")
    }

    // MARK: - Support

    private func documentBlock(_ harness: ViewSwitchWindowHarness) -> Any? {
        harness.split.inspectorController.viewModel.documentSectionViewModel.phylogeneticTreeDocument
    }

    private func selectionBlock(_ harness: ViewSwitchWindowHarness) -> Any? {
        harness.split.inspectorController.viewModel.selectionSectionViewModel.phylogeneticTreeSelection
    }

    /// The tree is shown, and the route has given the Inspector its document and its first selection.
    private func treeIsShownAndWired(_ harness: ViewSwitchWindowHarness) -> Bool {
        harness.split.viewerController.phylogeneticTreeViewController != nil
            && documentBlock(harness) != nil
            && selectionBlock(harness) != nil
    }

    /// Waits until the route has either shown the tree or written a refusal, which ends the wait at once on the base
    /// as well, then reads the words.
    private func assertTheRouteSaysItDidNotOpen(
        _ harness: ViewSwitchWindowHarness,
        fileWords: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        let viewer = harness.split.viewerController!
        let words = { viewer.statusBar.positionLabel.stringValue }
        _ = await waitUntil(budget: .lookup) { viewer.phylogeneticTreeViewController != nil || words().contains("Unable to") }
        XCTAssertTrue(
            words().contains("Unable to open the phylogenetic tree."),
            "the status line never said the tree did not open: \(words())", file: file, line: line
        )
        XCTAssertTrue(words().contains(fileWords), "the status line left out the file's own words: \(words())", file: file, line: line)
        XCTAssertTrue(words().contains("Select the item again."), "the status line gave no next step: \(words())", file: file, line: line)
        XCTAssertFalse(words().contains("bundle:"), "the words name an internal kind id: \(words())", file: file, line: line)
        XCTAssertFalse(viewer.statusBar.isHidden, "the words are in a hidden status bar", file: file, line: line)
        XCTAssertNil(viewer.phylogeneticTreeViewController, "a tree that did not open is on screen", file: file, line: line)
        XCTAssertNil(documentBlock(harness), "the Inspector describes a tree that is not shown", file: file, line: line)
    }

    /// Builds the sidebar row of one matrix kind under its own folder.
    private func buildRow(of name: String) async throws -> SidebarItem {
        let kind = try XCTUnwrap(ViewSwitchKinds.all.first { $0.name == name }, "the matrix has no kind \(name)")
        let row = try XCTUnwrap(ViewSwitchKinds.row(of: kind), "\(name) names no routing row")
        let kindRoot = try SafetyNetFiles.makeDirectory(
            root.appendingPathComponent(kind.folder + "-" + UUID().uuidString, isDirectory: true)
        )
        return try await row.build(RoutingRowContext(root: kindRoot, paths: SafetyNetPathRenderer(root: kindRoot))).item
    }
}
