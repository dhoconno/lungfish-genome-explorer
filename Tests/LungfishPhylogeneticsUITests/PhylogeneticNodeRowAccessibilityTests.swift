// PhylogeneticNodeRowAccessibilityTests.swift - Tree node rows reach the keyboard and AX clients
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import LungfishIO
import LungfishKit
import LungfishTestSupport
import XCTest
@testable import LungfishPhylogeneticsUI

/// The node table builds its context menu, Selection > Table Row validation
/// and each row's accessibility actions from one availability rule
/// (`availableNodeActions(forNodeID:selectedTipCount:)`), so the surfaces
/// offer the same commands under the same titles.
@MainActor
final class PhylogeneticNodeRowAccessibilityTests: XCTestCase {
    private let tipCount = 40
    private var directory: URL!
    private var window: NSWindow!
    /// A pasteboard of this test's own. The general pasteboard is one per
    /// machine, so a copy made by a test running in another process at the
    /// same time would show up here.
    private let pasteboard = NSPasteboard.withUniqueName()
    private var controller: PhylogeneticTreeViewController!
    private var table: NSTableView { controller.testingNodeTableView }

    override func setUp() async throws {
        try await super.setUp()
        _ = NSApplication.shared
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PhylogeneticNodeAX-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        // A caterpillar tree: tip0 joins tip1, that clade joins tip2, and so on.
        var newick = "(tip0:0.1,tip1:0.1)"
        for index in 2..<tipCount { newick = "(\(newick):0.1,tip\(index):0.1)" }
        let sourceURL = directory.appendingPathComponent("tree.nwk")
        try (newick + ";\n").write(to: sourceURL, atomically: true, encoding: .utf8)
        let bundleURL = directory.appendingPathComponent("tree.lungfishtree", isDirectory: true)
        _ = try PhylogeneticTreeBundleImporter.importTree(from: sourceURL, to: bundleURL)

        controller = PhylogeneticTreeViewController()
        controller.pasteboard = pasteboard
        controller.view.frame = NSRect(x: 0, y: 0, width: 1000, height: 640)
        window = NSWindow(contentRect: controller.view.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = controller.view
        window.makeKeyAndOrderFront(nil)
        try controller.displayBundle(at: bundleURL)
        controller.view.layoutSubtreeIfNeeded()
        table.layoutSubtreeIfNeeded()
    }

    override func tearDown() async throws {
        window.orderOut(nil)
        window.contentView = nil
        window = nil
        controller = nil
        pasteboard.releaseGlobally()
        try? FileManager.default.removeItem(at: directory)
        try await super.tearDown()
    }

    private func nodeLabel(_ row: Int) -> String { controller.testingNodeCellAccessibilityValue(column: "node", row: row) }

    private func isTip(_ row: Int) -> Bool { controller.testingNodeCellAccessibilityValue(column: "type", row: row) == "Tip" }

    private func firstRow(isTip wantTip: Bool) throws -> Int {
        try XCTUnwrap((0..<table.numberOfRows).first { isTip($0) == wantTip })
    }

    private func rowProxy(_ row: Int) throws -> AnyObject {
        table.scrollRowToVisible(row)
        table.layoutSubtreeIfNeeded()
        let proxies = AccessibilityRowProbe.rowProxies(of: table)
        return try XCTUnwrap(proxies.indices.contains(row) ? proxies[row] : nil, "no AX proxy for row \(row)")
    }

    private func firstCellActions(_ row: Int) throws -> [String] {
        try XCTUnwrap(AccessibilityRowProbe.servedCellActionNames(try rowProxy(row)).first)
    }

    private func focusTable() {
        window.makeKeyAndOrderFront(nil)
        XCTAssertTrue(window.makeFirstResponder(table))
    }

    private func menuBarItem(_ command: ResultRowCommand) -> NSMenuItem {
        command.makeMenuBarItem(identifier: "test-\(command.identifierSlug)")
    }

    // MARK: - Served actions

    func testTipRowActionsAreListedOnceUnderTheContextMenuTitles() throws {
        let served = try firstCellActions(try firstRow(isTip: true))
        XCTAssertEqual(
            served,
            [
                "Show in Inspector", "Copy Name", "Copy Subtree as Newick", "Root on Selected Branch",
                "Extract Subtree as New Bundle\u{2026}", "Export Subtree\u{2026}", "Copy Selected Tip Names",
                "Center Node", "Reveal Provenance",
            ]
        )
        XCTAssertEqual(Set(served).count, served.count, "each action is served once")
    }

    func testInternalRowOffersCollapseAndNoTipNames() throws {
        let served = try firstCellActions(try firstRow(isTip: false))
        XCTAssertTrue(served.contains("Collapse Clade"), "\(served)")
        XCTAssertFalse(served.contains("Copy Selected Tip Names"), "\(served)")
        XCTAssertEqual(Set(served).count, served.count)
    }

    func testCopyActionsWriteThePasteboard() throws {
        let tipRow = try firstRow(isTip: true)
        pasteboard.clearContents()
        XCTAssertTrue(AccessibilityRowProbe.performCellAction(named: "Copy Name", in: try rowProxy(tipRow)))
        XCTAssertEqual(pasteboard.string(forType: .string), nodeLabel(tipRow))

        let internalRow = try firstRow(isTip: false)
        XCTAssertTrue(AccessibilityRowProbe.performCellAction(named: "Copy Subtree as Newick", in: try rowProxy(internalRow)))
        let newick = try XCTUnwrap(pasteboard.string(forType: .string))
        XCTAssertTrue(newick.hasPrefix("("), newick)
    }

    func testShowInInspectorActionReportsTheRowsNode() throws {
        var title: String?
        controller.onSelectionStateChanged = { title = $0?.title }
        let row = try firstRow(isTip: true) + 3
        XCTAssertTrue(AccessibilityRowProbe.performCellAction(named: "Show in Inspector", in: try rowProxy(row)))
        XCTAssertEqual(title, nodeLabel(row))
    }

    func testRootOnSelectedBranchActionRequestsTheRowsReroot() throws {
        var request: PhylogeneticTreeViewController.TreeBundleOperationRequest?
        controller.onTreeBundleOperationRequested = { request = $0 }
        let row = try firstRow(isTip: true) + 2
        XCTAssertTrue(AccessibilityRowProbe.performCellAction(named: "Root on Selected Branch", in: try rowProxy(row)))
        XCTAssertEqual(request?.operation, .reroot)
        XCTAssertEqual(request?.nodeLabel, nodeLabel(row))
    }

    func testCollapseCladeActionTogglesAndRenames() throws {
        let row = try firstRow(isTip: false)
        XCTAssertTrue(AccessibilityRowProbe.performCellAction(named: "Collapse Clade", in: try rowProxy(row)))
        XCTAssertEqual(controller.testingCollapsedNodeLabels, [nodeLabel(row)])
        table.layoutSubtreeIfNeeded()
        XCTAssertTrue(try firstCellActions(row).contains("Expand Clade"))
    }

    // MARK: - Row reuse

    func testActionsOfARowFarDownActOnThatRow() throws {
        let far = table.numberOfRows - 3
        pasteboard.clearContents()
        XCTAssertTrue(AccessibilityRowProbe.performCellAction(named: "Copy Name", in: try rowProxy(far)))
        XCTAssertEqual(pasteboard.string(forType: .string), nodeLabel(far))
        XCTAssertEqual(table.selectedRow, far)
    }

    func testReusedCellViewRebindsItsActionsToTheNewRow() throws {
        let first = try XCTUnwrap(table.view(atColumn: 0, row: 0, makeIfNecessary: true))
        table.scrollRowToVisible(table.numberOfRows - 1)
        table.layoutSubtreeIfNeeded()
        guard let shownRow = AccessibilityCellActions.currentRow(of: first) else { return }
        let action = try XCTUnwrap(first.accessibilityCustomActions()?.first { $0.name == "Copy Name" })
        pasteboard.clearContents()
        XCTAssertEqual(action.handler?(), true)
        XCTAssertEqual(pasteboard.string(forType: .string), nodeLabel(shownRow))
    }

    // MARK: - Menu-bar validation

    func testSelectionTableRowItemsFollowTheSelectedNodeAndFocus() throws {
        focusTable()
        XCTAssertTrue(controller.validateMenuItem(menuBarItem(.showInInspector)))
        XCTAssertTrue(controller.validateMenuItem(menuBarItem(.copyName)))
        XCTAssertFalse(controller.validateMenuItem(menuBarItem(.extractReads)), "the tree does not adopt Extract Reads")
        XCTAssertFalse(controller.validateMenuItem(menuBarItem(.copySequence)))

        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 80, height: 20))
        controller.view.addSubview(field)
        XCTAssertTrue(window.makeFirstResponder(field))
        XCTAssertFalse(controller.validateMenuItem(menuBarItem(.copyName)), "node table not first responder")
        XCTAssertFalse(controller.validateMenuItem(menuBarItem(.showInInspector)))
    }

    func testMenuBarCopyNameCopiesTheSelectedNode() throws {
        focusTable()
        let row = try firstRow(isTip: true) + 1
        controller.testingSelectNode(label: nodeLabel(row))
        pasteboard.clearContents()
        controller.copySelectedRowName(nil)
        XCTAssertEqual(pasteboard.string(forType: .string), nodeLabel(row))
    }

    // MARK: - Context menu parity

    func testContextMenuEveryItemHasACellActionOrMenuBarSelectorAndFollowsTheNode() throws {
        let row = try firstRow(isTip: true) + 1
        controller.testingSelectNode(label: nodeLabel(row))
        let menu = try XCTUnwrap(controller.testingNodeTableContextMenu)
        let mainMenu = NSMenu()
        for command in ResultRowCommand.allCases { mainMenu.addItem(menuBarItem(command)) }
        let cellNames = try firstCellActions(row)
        // A tip cannot be collapsed, so its menu keeps the item disabled and
        // the row serves no action for it.
        ContextMenuParityAssert.assertParity(
            contextMenu: menu, cellActionNames: cellNames, mainMenu: mainMenu, exempt: ["Collapse Clade"]
        )

        let enabledTitles = menu.items.filter { controller.validateMenuItem($0) }.map(\.title)
        XCTAssertEqual(enabledTitles, cellNames, "the context menu enables exactly the commands the row serves")
    }

    // MARK: - Canvas and node table menus

    private func rightClickEvent(in view: NSView, at point: NSPoint) throws -> NSEvent {
        try XCTUnwrap(NSEvent.mouseEvent(
            with: .rightMouseDown, location: view.convert(point, to: nil), modifierFlags: [],
            timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 0,
            clickCount: 1, pressure: 1
        ))
    }

    func testCanvasAndNodeTableHaveSeparateMenus() throws {
        let tableMenu = try XCTUnwrap(controller.testingNodeTableContextMenu)
        let canvasMenu = try XCTUnwrap(controller.testingTreeCanvasView.menu)
        XCTAssertFalse(tableMenu === canvasMenu)
    }

    func testCanvasCommandActsOnTheClickedCanvasNodeNotAStaleTableRow() throws {
        let tips = (0..<table.numberOfRows).filter { isTip($0) }
        let staleRow = tips[1]
        let canvasLabel = nodeLabel(tips[5])
        controller.testingSelectNode(label: nodeLabel(tips[0]))
        // A table right-click leaves clickedRow pointing at an unselected row.
        let rect = table.rect(ofRow: staleRow)
        _ = table.menu(for: try rightClickEvent(in: table, at: NSPoint(x: rect.midX, y: rect.midY)))
        XCTAssertEqual(table.clickedRow, staleRow)

        let canvas = controller.testingTreeCanvasView
        let point = try XCTUnwrap(controller.testingCanvasPoint(label: canvasLabel))
        let menu = try XCTUnwrap(canvas.menu(for: try rightClickEvent(in: canvas, at: point)))
        let copyName = try XCTUnwrap(menu.items.first { $0.title == "Copy Name" })
        XCTAssertTrue(controller.validateMenuItem(copyName), "canvas menu items are context-menu items")
        pasteboard.clearContents()
        controller.copySelectedRowName(copyName)
        XCTAssertEqual(pasteboard.string(forType: .string), canvasLabel)
    }

    func testCollapseCladeFromTheMenuBarRenamesTheRowActionWithoutAFullReload() throws {
        let row = try firstRow(isTip: false)
        controller.testingSelectNode(label: nodeLabel(row))
        controller.toggleSelectedCladeCollapse(nil)
        table.layoutSubtreeIfNeeded()
        let served = try firstCellActions(row)
        XCTAssertTrue(served.contains("Expand Clade"), "\(served)")
    }
}
