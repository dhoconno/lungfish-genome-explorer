// TaxTriageRowAccessibilityTests.swift - TaxTriage organism rows reach the keyboard and AX clients
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import LungfishIO
import LungfishKit
import LungfishTestSupport
import XCTest
@testable import LungfishTaxTriageUI

/// Both TaxTriage organism tables (the batch table and the per-sample
/// table) build their context menus, Selection > Table Row validation and
/// each row's accessibility actions from the shared `TaxTriageRowCommands`
/// rule, so the surfaces offer the same commands under the same titles.
@MainActor
final class TaxTriageRowAccessibilityTests: XCTestCase {
    private let rowCount = 40
    private var windows: [NSWindow] = []

    override func setUp() async throws {
        try await super.setUp()
        _ = NSApplication.shared
    }

    override func tearDown() async throws {
        for window in windows {
            window.orderOut(nil)
            window.contentView = nil
        }
        windows.removeAll()
        try await super.tearDown()
    }

    // MARK: - Fixtures

    private func host(_ view: NSView, size: NSSize) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = view
        window.makeKeyAndOrderFront(nil)
        view.layoutSubtreeIfNeeded()
        windows.append(window)
        return window
    }

    private func makeBatchTable() -> (BatchTaxTriageTableView, NSWindow) {
        let table = BatchTaxTriageTableView(frame: NSRect(x: 0, y: 0, width: 760, height: 220))
        table.configure(rows: (0..<rowCount).map { index in
            TaxTriageMetric(
                sample: "sample-\(index)", taxId: 5_000 + index, organism: "Organism \(index)", rank: "S",
                reads: 1_000 + index, abundance: 0.1, coverageBreadth: 50, coverageDepth: 10,
                tassScore: 0.9 - Double(index) / 100, confidence: "High"
            )
        })
        let window = host(table, size: table.frame.size)
        table.layoutSubtreeIfNeeded()
        table.tableView.layoutSubtreeIfNeeded()
        return (table, window)
    }

    private func makeOrganismTable() -> (TaxTriageOrganismTableView, NSWindow) {
        let table = TaxTriageOrganismTableView(frame: NSRect(x: 0, y: 0, width: 640, height: 220))
        table.rows = (0..<rowCount).map { index in
            TaxTriageTableRow(
                organism: "Organism \(index)", tassScore: 0.9 - Double(index) / 100, reads: 1_000 + index,
                uniqueReads: 500, coverage: 88.5, confidence: "High", taxId: 5_000 + index
            )
        }
        let window = host(table, size: table.frame.size)
        table.layoutSubtreeIfNeeded()
        table.testingTableView.layoutSubtreeIfNeeded()
        return (table, window)
    }

    private func rowProxy(_ row: Int, in table: NSTableView) throws -> AnyObject {
        table.scrollRowToVisible(row)
        table.layoutSubtreeIfNeeded()
        let proxies = AccessibilityRowProbe.rowProxies(of: table)
        return try XCTUnwrap(proxies.indices.contains(row) ? proxies[row] : nil, "no AX proxy for row \(row)")
    }

    private func firstCellActions(_ row: Int, in table: NSTableView) throws -> [String] {
        try XCTUnwrap(AccessibilityRowProbe.servedCellActionNames(try rowProxy(row, in: table)).first)
    }

    private func menuBarItem(_ command: ResultRowCommand) -> NSMenuItem {
        command.makeMenuBarItem(identifier: "test-\(command.identifierSlug)")
    }

    private func mainMenu() -> NSMenu {
        let menu = NSMenu()
        for command in ResultRowCommand.allCases { menu.addItem(menuBarItem(command)) }
        return menu
    }

    // MARK: - Batch table

    func testBatchRowActionsAreListedOnceUnderTheSharedTitles() throws {
        let (table, _) = makeBatchTable()
        let served = try firstCellActions(2, in: table.tableView)
        XCTAssertEqual(
            served,
            [
                "Verify with BLAST\u{2026}", "Copy Name", "Copy Taxon ID", "Copy Row as TSV",
                "Open Taxonomy on NCBI", "Extract Reads\u{2026}",
            ]
        )
        XCTAssertEqual(Set(served).count, served.count, "each action is served once")
    }

    func testBatchCopyActionsWriteThePasteboard() throws {
        let (table, _) = makeBatchTable()
        NSPasteboard.general.clearContents()
        XCTAssertTrue(AccessibilityRowProbe.performCellAction(named: "Copy Name", in: try rowProxy(3, in: table.tableView)))
        XCTAssertEqual(NSPasteboard.general.string(forType: .string), table.displayedRows[3].organism)

        XCTAssertTrue(AccessibilityRowProbe.performCellAction(named: "Copy Taxon ID", in: try rowProxy(4, in: table.tableView)))
        XCTAssertEqual(NSPasteboard.general.string(forType: .string), table.displayedRows[4].taxId.map(String.init))

        XCTAssertTrue(AccessibilityRowProbe.performCellAction(named: "Copy Row as TSV", in: try rowProxy(5, in: table.tableView)))
        XCTAssertTrue(NSPasteboard.general.string(forType: .string)?.contains(table.displayedRows[5].organism) == true)
    }

    func testBatchExtractReadsActionUsesTheRowsSelection() throws {
        let (table, _) = makeBatchTable()
        var selected: [String] = []
        table.onExtractReadsRequested = { selected = table.selectedMetrics().map(\.organism) }
        XCTAssertTrue(AccessibilityRowProbe.performCellAction(named: "Extract Reads\u{2026}", in: try rowProxy(6, in: table.tableView)))
        XCTAssertEqual(selected, [table.displayedRows[6].organism])
    }

    func testBatchActionsOfARowFarDownActOnThatRow() throws {
        let (table, _) = makeBatchTable()
        let far = 36
        NSPasteboard.general.clearContents()
        XCTAssertTrue(AccessibilityRowProbe.performCellAction(named: "Copy Name", in: try rowProxy(far, in: table.tableView)))
        XCTAssertEqual(NSPasteboard.general.string(forType: .string), table.displayedRows[far].organism)
        XCTAssertEqual(table.tableView.selectedRow, far)
    }

    func testBatchReusedCellViewRebindsItsActionsToTheNewRow() throws {
        let (table, _) = makeBatchTable()
        let first = try XCTUnwrap(table.tableView.view(atColumn: 1, row: 0, makeIfNecessary: true))
        table.tableView.scrollRowToVisible(38)
        table.tableView.layoutSubtreeIfNeeded()
        guard let shownRow = AccessibilityCellActions.currentRow(of: first) else { return }
        let action = try XCTUnwrap(first.accessibilityCustomActions()?.first { $0.name == "Copy Name" })
        NSPasteboard.general.clearContents()
        XCTAssertEqual(action.handler?(), true)
        XCTAssertEqual(NSPasteboard.general.string(forType: .string), table.displayedRows[shownRow].organism)
    }

    func testBatchSelectionTableRowItemsFollowSelectionAndFocus() throws {
        let (table, window) = makeBatchTable()
        XCTAssertTrue(window.makeFirstResponder(table.tableView))
        table.tableView.deselectAll(nil)
        XCTAssertFalse(table.validateMenuItem(menuBarItem(.copyName)), "nothing selected")
        XCTAssertFalse(table.validateMenuItem(menuBarItem(.extractReads)), "nothing selected")

        table.tableView.selectRowIndexes(IndexSet(integer: 3), byExtendingSelection: false)
        XCTAssertTrue(table.validateMenuItem(menuBarItem(.copyName)))
        XCTAssertTrue(table.validateMenuItem(menuBarItem(.extractReads)))
        XCTAssertTrue(table.validateMenuItem(menuBarItem(.blastVerify)))
        XCTAssertFalse(table.validateMenuItem(menuBarItem(.copyAccession)), "the batch table has no accession")
        XCTAssertFalse(table.validateMenuItem(menuBarItem(.copySequence)))

        table.tableView.selectRowIndexes(IndexSet([3, 4]), byExtendingSelection: false)
        XCTAssertFalse(table.validateMenuItem(menuBarItem(.copyName)), "single-row command, two rows selected")
        XCTAssertTrue(table.validateMenuItem(menuBarItem(.extractReads)))

        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 80, height: 20))
        table.addSubview(field)
        XCTAssertTrue(window.makeFirstResponder(field))
        XCTAssertFalse(table.validateMenuItem(menuBarItem(.extractReads)), "table not first responder")
    }

    func testBatchContextMenuParityAndFollowsSelection() throws {
        let (table, _) = makeBatchTable()
        let menu = try XCTUnwrap(table.tableView.menu)
        ContextMenuParityAssert.assertParity(
            contextMenu: menu, cellActionNames: try firstCellActions(1, in: table.tableView), mainMenu: mainMenu()
        )
        XCTAssertEqual(
            menu.items.filter { !$0.isSeparatorItem }.map(\.title),
            try firstCellActions(1, in: table.tableView)
        )
        let copy = try XCTUnwrap(menu.items.first { $0.title == "Copy Name" })
        table.tableView.deselectAll(nil)
        XCTAssertFalse(table.validateMenuItem(copy))
        table.tableView.selectRowIndexes(IndexSet(integer: 1), byExtendingSelection: false)
        XCTAssertTrue(table.validateMenuItem(copy))
    }

    // MARK: - Per-sample organism table

    func testOrganismRowActionsAreListedOnceUnderTheSharedTitles() throws {
        let (table, _) = makeOrganismTable()
        let served = try firstCellActions(2, in: table.testingTableView)
        XCTAssertEqual(
            served,
            [
                "Verify with BLAST\u{2026}", "Copy Name", "Copy Accession", "Copy Taxon ID", "Copy Row as TSV",
                "Open Taxonomy on NCBI", "Extract Reads\u{2026}",
            ]
        )
        XCTAssertEqual(Set(served).count, served.count, "each action is served once")
    }

    func testOrganismCopyActionsWriteThePasteboard() throws {
        let (table, _) = makeOrganismTable()
        let view = table.testingTableView
        NSPasteboard.general.clearContents()
        XCTAssertTrue(AccessibilityRowProbe.performCellAction(named: "Copy Name", in: try rowProxy(3, in: view)))
        XCTAssertEqual(NSPasteboard.general.string(forType: .string), "Organism 3")
        XCTAssertTrue(AccessibilityRowProbe.performCellAction(named: "Copy Taxon ID", in: try rowProxy(4, in: view)))
        XCTAssertEqual(NSPasteboard.general.string(forType: .string), "5004")
        XCTAssertTrue(AccessibilityRowProbe.performCellAction(named: "Copy Accession", in: try rowProxy(5, in: view)))
        XCTAssertEqual(NSPasteboard.general.string(forType: .string), "taxid:5005")
    }

    func testOrganismExtractReadsActionRunsTheCallbackForItsRow() throws {
        let (table, _) = makeOrganismTable()
        var selected: [String] = []
        table.onExtractFASTQ = { selected = table.selectedTableRows().map(\.organism) }
        XCTAssertTrue(AccessibilityRowProbe.performCellAction(
            named: "Extract Reads\u{2026}", in: try rowProxy(6, in: table.testingTableView)
        ))
        XCTAssertEqual(selected, ["Organism 6"])
    }

    func testOrganismActionsOfARowFarDownActOnThatRow() throws {
        let (table, _) = makeOrganismTable()
        let far = 37
        NSPasteboard.general.clearContents()
        XCTAssertTrue(AccessibilityRowProbe.performCellAction(
            named: "Copy Name", in: try rowProxy(far, in: table.testingTableView)
        ))
        XCTAssertEqual(NSPasteboard.general.string(forType: .string), "Organism \(far)")
        XCTAssertEqual(table.testingTableView.selectedRow, far)
    }

    func testOrganismSelectionTableRowItemsFollowSelectionAndFocus() throws {
        let (table, window) = makeOrganismTable()
        let view = table.testingTableView
        XCTAssertTrue(window.makeFirstResponder(view))
        view.deselectAll(nil)
        XCTAssertFalse(table.validateMenuItem(menuBarItem(.copyName)), "nothing selected")
        view.selectRowIndexes(IndexSet(integer: 3), byExtendingSelection: false)
        XCTAssertTrue(table.validateMenuItem(menuBarItem(.copyName)))
        XCTAssertTrue(table.validateMenuItem(menuBarItem(.copyAccession)))
        XCTAssertFalse(table.validateMenuItem(menuBarItem(.copySequence)))
        view.selectRowIndexes(IndexSet([3, 4]), byExtendingSelection: false)
        XCTAssertFalse(table.validateMenuItem(menuBarItem(.copyName)))
        XCTAssertTrue(table.validateMenuItem(menuBarItem(.extractReads)))

        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 80, height: 20))
        table.addSubview(field)
        XCTAssertTrue(window.makeFirstResponder(field))
        XCTAssertFalse(table.validateMenuItem(menuBarItem(.extractReads)), "table not first responder")
    }

    func testOrganismContextMenuParityAndFollowsSelection() throws {
        let (table, _) = makeOrganismTable()
        let view = table.testingTableView
        let menu = try XCTUnwrap(view.menu)
        ContextMenuParityAssert.assertParity(
            contextMenu: menu, cellActionNames: try firstCellActions(1, in: view), mainMenu: mainMenu()
        )
        XCTAssertEqual(menu.items.filter { !$0.isSeparatorItem }.map(\.title), try firstCellActions(1, in: view))
        let copy = try XCTUnwrap(menu.items.first { $0.title == "Copy Name" })
        view.deselectAll(nil)
        XCTAssertFalse(table.validateMenuItem(copy))
        view.selectRowIndexes(IndexSet(integer: 1), byExtendingSelection: false)
        XCTAssertTrue(table.validateMenuItem(copy))
    }
}
