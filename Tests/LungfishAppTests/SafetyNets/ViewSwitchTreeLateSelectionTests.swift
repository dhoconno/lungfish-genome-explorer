// ViewSwitchTreeLateSelectionTests.swift - A tree's selection that lands after the next item's route began changes nothing
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// VS-TREE-LATE. The viewport host tells an installed adopter its view on the main actor's next turn
// (`ViewportHost.announceAfterTheRoute`), and the tree's announce runs the selection callback its route wired. When the
// next item's route begins before that turn and its own viewer installs later, the tree's selection reached the Inspector
// during the next item's visit and showed Selected Item over that item's own tab. The matrix saw it on Tree to FASTA
// collection and Tree to FASTA document in some runs only (VS-INSP, land-9 section 11).
//
// The first two cases keep the callback the tree had while it showed, switch, and call it: the late turn with no timing
// in it. The control picks a node while the tree shows. The probe runs the real routes with no kept callback and prints
// the stack of each tree selection that arrives after the switch began, which names what sends it.

import XCTest
@testable import LungfishApp
@testable import LungfishKit
@testable import LungfishPhylogeneticsUI
import LungfishTestSupport

@MainActor
final class ViewSwitchTreeLateSelectionTests: XCTestCase {
    func testALateTreeSelectionLeavesTheFASTACollectionOnItsOwnTabAndBlocks() async throws {
        try await assertALateTreeSelectionChangesNothing(on: "FASTA collection")
    }

    func testALateTreeSelectionLeavesTheFASTADocumentOnItsOwnTabAndBlocks() async throws {
        try await assertALateTreeSelectionChangesNothing(on: "FASTA document")
    }

    /// The control: a node pick while the tree shows opens Selected Item with that node, over the Document tab a person
    /// picked.
    func testANodePickWhileTheTreeShowsOpensSelectedItemWithThatNode() async throws {
        let scene = try await LateSelectionScene.make(target: nil)
        defer { scene.close() }
        let tree = try await scene.showTree()
        let inspector = try scene.inspector()
        inspector.selectedTab = .bundle
        let tip = try XCTUnwrap(
            tree.nodes.last { $0.isTip && $0.id != tree.selectedNodeID }, "the tree fixture has a second tip to pick")
        tree.selectNode(id: tip.id, center: false)
        XCTAssertEqual(inspector.shownTab, .selectedItem, "a node pick while the tree shows opens Selected Item")
        XCTAssertEqual(
            inspector.selectionSectionViewModel.phylogeneticTreeSelection?.title, tip.displayLabel,
            "Selected Item shows the node the person picked")
    }

    /// The same tree row shown again (a sidebar refresh does it) begins a new request, and the new viewer's callback holds it.
    func testANodePickAfterTheSameTreeIsShownAgainStillOpensSelectedItem() async throws {
        let scene = try await LateSelectionScene.make(target: nil)
        defer { scene.close() }
        let first = try await scene.showTree()
        scene.harness.select(scene.tree.item)
        var again: PhylogeneticTreeViewController?
        let reshown = await waitUntil(budget: .lookup, pollInterval: .milliseconds(25)) {
            again = scene.harness.split.viewerController.phylogeneticTreeViewController
            return again != nil && again !== first && again?.onSelectionStateChanged != nil
        }
        XCTAssertTrue(reshown, "the same tree row shown again installs a new viewer with its callback wired")
        let tree = try XCTUnwrap(again)
        let inspector = try scene.inspector()
        inspector.selectedTab = .bundle
        let tip = try XCTUnwrap(
            tree.nodes.last { $0.isTip && $0.id != tree.selectedNodeID }, "the tree fixture has a second tip to pick")
        tree.selectNode(id: tip.id, center: false)
        XCTAssertEqual(inspector.shownTab, .selectedItem, "a node pick on the tree shown again opens Selected Item")
        XCTAssertEqual(inspector.selectionSectionViewModel.phylogeneticTreeSelection?.title, tip.displayLabel)
    }

    /// The probe of what sends the late selection (VS-TREE-LATE item 1). The tree's route runs on the main queue's next
    /// turn: it shows the tree, where the host enqueues its announce, then wires the callback. The job enqueued here runs
    /// after that route and before that announce, as the matrix's next switch can, so the announce finds the tree still
    /// installed. Each tree selection after the switch prints its stack to the log.
    func testProbeWhatSendsTheTreeSelectionAfterTheSwitchToAFASTACollection() async throws {
        let scene = try await LateSelectionScene.make(target: "FASTA collection")
        defer { scene.close() }
        let target = try XCTUnwrap(scene.target)
        let probe = LateSelectionProbe(harness: scene.harness, next: target.item)
        scene.harness.select(scene.tree.item)
        Task { @MainActor in probe.switchAfterTheTreesRoute() }
        let faults = await scene.settle(on: target)
        print("VS-TREE-LATE probe: wrapped=\(probe.wrapped), \(probe.stacks.count) tree selection(s) after the switch began")
        for (index, stack) in probe.stacks.enumerated() {
            print("VS-TREE-LATE probe stack \(index + 1):\n" + stack.joined(separator: "\n"))
        }
        XCTAssertEqual(faults, [], "the FASTA collection after the tree's route and its late announce differs from it alone")
    }

    // MARK: - Support

    private func assertALateTreeSelectionChangesNothing(on name: String) async throws {
        let scene = try await LateSelectionScene.make(target: name)
        defer { scene.close() }
        let target = try XCTUnwrap(scene.target)
        let tree = try await scene.showTree()
        let inspector = try scene.inspector()
        // The callback the tree's route wired and the selection it sent, as the tree holds them while it shows.
        let late = try XCTUnwrap(tree.onSelectionStateChanged, "the tree's route wires its selection callback")
        let selection = try XCTUnwrap(
            inspector.selectionSectionViewModel.phylogeneticTreeSelection, "the tree's route sends its selection")
        scene.harness.select(target.item)
        // The next item's display request and Inspector visit have begun, and its viewer installs later.
        late(selection)
        XCTAssertNotEqual(
            inspector.shownTab, .selectedItem,
            "\(name): a tree selection after the switch began showed Selected Item over the item's own tab")
        let faults = await scene.settle(on: target)
        XCTAssertEqual(faults, [], "\(name) after the tree's late selection differs from the \(name) alone")
    }
}

/// The window, the store and the fixtures of one case. The tree lies in a project the store has read, so its show has a
/// view memory key and the host announces it after the route. The next kind lies beside the project.
@MainActor
private final class LateSelectionScene {
    let root: URL
    let harness: ViewSwitchWindowHarness
    let tree: ViewSwitchFixture
    let target: ViewSwitchFixture?
    private let hostDefaults: HostDefaultsRestorer

    static func make(target name: String?) async throws -> LateSelectionScene {
        let root = try TestTempDirectory.make(prefix: "ViewSwitchTreeLate")
        do {
            return try await LateSelectionScene(root: root, target: name)
        } catch {
            TestTempDirectory.cleanup(root)
            throw error
        }
    }

    private init(root: URL, target name: String?) async throws {
        self.root = root
        // Declared before the window, so its restore runs after the window closes (ViewSwitchMatrixTests).
        hostDefaults = HostDefaultsRestorer(keysContaining: root.lastPathComponent)
        let project = try SafetyNetFiles.makeDirectory(root.appendingPathComponent("Views.lungfish", isDirectory: true))
        tree = try await ViewSwitchFixtures.build(try ViewSwitchFixtures.kind(named: "Tree"), in: project)
        if let name {
            target = try await ViewSwitchFixtures.build(try ViewSwitchFixtures.kind(named: name), in: root)
        } else {
            target = nil
        }
        let store = ViewMemoryStore(root: root.appendingPathComponent("view-memory", isDirectory: true))
        store.loadProject(at: project)
        harness = try ViewSwitchWindowHarness()
        harness.keepViews(in: store)
    }

    func close() {
        harness.close()
        hostDefaults.restore()
        TestTempDirectory.cleanup(root)
    }

    func inspector() throws -> InspectorViewModel {
        try XCTUnwrap(harness.split.inspectorController, "the window has an Inspector").viewModel
    }

    /// Selects the tree and waits until its route wired the callback and sent its selection to the Inspector.
    func showTree() async throws -> PhylogeneticTreeViewController {
        harness.select(tree.item)
        let inspector = try inspector()
        var shown: PhylogeneticTreeViewController?
        let wired = await waitUntil(budget: .lookup, pollInterval: .milliseconds(25)) {
            shown = self.harness.split.viewerController.phylogeneticTreeViewController
            return shown?.onSelectionStateChanged != nil
                && inspector.selectionSectionViewModel.phylogeneticTreeSelection != nil
        }
        XCTAssertTrue(wired, "the tree showed and its route sent its selection to the Inspector")
        return try XCTUnwrap(shown, "the tree showed")
    }

    /// Waits until the window reads as `fixture`'s kind alone, and returns the faults of the last reading, empty once it
    /// does.
    func settle(on fixture: ViewSwitchFixture) async -> [String] {
        var faults: [String] = []
        let settled = await waitUntil(budget: .lookup, pollInterval: .milliseconds(25)) {
            faults = self.harness.read(kindRoot: fixture.root, matrixRoot: self.root).faults(against: fixture.alone)
            return faults.isEmpty
        }
        return settled ? [] : faults
    }
}

/// Wraps the callback the tree's route wired, so each call after the switch records its stack, then switches.
@MainActor
private final class LateSelectionProbe {
    let harness: ViewSwitchWindowHarness
    let next: SidebarItem
    var wrapped = false
    var switched = false
    var stacks: [[String]] = []

    init(harness: ViewSwitchWindowHarness, next: SidebarItem) {
        self.harness = harness
        self.next = next
    }

    func switchAfterTheTreesRoute() {
        if let tree = harness.split.viewerController.phylogeneticTreeViewController,
           let wired = tree.onSelectionStateChanged {
            wrapped = true
            tree.onSelectionStateChanged = { [weak self] state in
                if self?.switched == true { self?.stacks.append(Thread.callStackSymbols) }
                wired(state)
            }
        }
        harness.select(next)
        switched = true
    }
}
