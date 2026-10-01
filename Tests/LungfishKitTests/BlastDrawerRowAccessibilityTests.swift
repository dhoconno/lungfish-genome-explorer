// BlastDrawerRowAccessibilityTests.swift - BLAST result rows reach the keyboard and AX clients
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import LungfishTestSupport
import XCTest
@testable import LungfishCore
@testable import LungfishKit
@testable import LungfishWorkflow

/// The BLAST drawer's outline builds its context menu, Selection > Table
/// Row validation and each row's accessibility actions from one availability
/// rule (`availableRowCommands(for:)`).
@MainActor
final class BlastDrawerRowAccessibilityTests: XCTestCase {
    private var window: NSWindow!
    private var tab: BlastResultsDrawerTab!
    private var outline: NSOutlineView { tab.resultsOutlineView }
    private let readCount = 40
    /// A pasteboard of this test's own. The general pasteboard is one per
    /// machine, so a copy made by a test running in another process at the
    /// same time would show up here.
    private var pasteboard: NSPasteboard!

    override func setUp() async throws {
        try await super.setUp()
        _ = NSApplication.shared
        pasteboard = NSPasteboard.withUniqueName()
        tab = BlastResultsDrawerTab(frame: NSRect(x: 0, y: 0, width: 900, height: 260))
        tab.pasteboard = pasteboard
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 260),
            styleMask: [.titled], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = tab
        tab.frame = window.contentView!.bounds
        tab.autoresizingMask = [.width, .height]
        tab.showResults(makeResult())
        window.layoutIfNeeded()
        tab.layoutSubtreeIfNeeded()
        outline.layoutSubtreeIfNeeded()
    }

    override func tearDown() async throws {
        window.orderOut(nil)
        window = nil
        tab = nil
        pasteboard.releaseGlobally()
        pasteboard = nil
        try await super.tearDown()
    }

    private func makeResult() -> BlastVerificationResult {
        let reads = (0..<readCount).map { index -> BlastReadResult in
            let hits: [BlastHitSummary] = index == 0
                ? (1...3).map { rank in
                    BlastHitSummary(
                        rank: rank, accession: "HIT_\(rank)", organism: "Org \(rank)", taxId: 100 + rank,
                        percentIdentity: 99, queryCoverage: 95, eValue: 0, bitScore: 400, alignmentLength: 200
                    )
                }
                : []
            return BlastReadResult(
                id: String(format: "read_%02d", index),
                verdict: .verified,
                topHitOrganism: "Org",
                topHitAccession: String(format: "ACC_%02d", index),
                percentIdentity: 99,
                topHits: hits,
                querySequence: "ACGT" + String(repeating: "A", count: index)
            )
        }
        return BlastVerificationResult(
            taxonName: "Org", taxId: 1, readResults: reads, submittedAt: Date(), completedAt: Date(),
            rid: "RID", blastProgram: "blastn", database: "core_nt"
        )
    }

    private func rowProxy(_ row: Int) throws -> AnyObject {
        outline.scrollRowToVisible(row)
        outline.layoutSubtreeIfNeeded()
        let proxies = AccessibilityRowProbe.outlineRowProxies(of: outline)
        return try XCTUnwrap(proxies.indices.contains(row) ? proxies[row] : nil, "no AX proxy for row \(row)")
    }

    private func firstCellActions(_ row: Int) throws -> [String] {
        try XCTUnwrap(AccessibilityRowProbe.servedCellActionNames(try rowProxy(row)).first)
    }

    private func readID(atRow row: Int) throws -> String {
        try XCTUnwrap((outline.item(atRow: row) as? ReadResultItem)?.result.id)
    }

    private func focusOutline() {
        window.makeKeyAndOrderFront(nil)
        XCTAssertTrue(window.makeFirstResponder(outline))
    }

    private func menuBarItem(_ command: ResultRowCommand) -> NSMenuItem {
        command.makeMenuBarItem(identifier: "test-\(command.identifierSlug)")
    }

    // MARK: - Served actions

    func testRowActionsAreListedOnceUnderTheSharedTitles() throws {
        let served = try firstCellActions(1)
        XCTAssertEqual(served, ["Copy FASTA", "Copy Name", "Copy Accession"])
        XCTAssertEqual(Set(served).count, served.count, "each action is served once")
    }

    func testCopyActionsWriteThePasteboard() throws {
        pasteboard.clearContents()
        XCTAssertTrue(AccessibilityRowProbe.performCellAction(named: "Copy Name", in: try rowProxy(3)))
        XCTAssertEqual(pasteboard.string(forType: .string), "read_03")

        XCTAssertTrue(AccessibilityRowProbe.performCellAction(named: "Copy FASTA", in: try rowProxy(4)))
        XCTAssertEqual(pasteboard.string(forType: .string), ">read_04\nACGTAAAA\n")

        XCTAssertTrue(AccessibilityRowProbe.performCellAction(named: "Copy Accession", in: try rowProxy(5)))
        XCTAssertEqual(pasteboard.string(forType: .string), "ACC_05")
    }

    func testChildHitRowCopiesItsOwnAccession() throws {
        outline.expandItem(outline.item(atRow: 0), expandChildren: true)
        outline.layoutSubtreeIfNeeded()
        XCTAssertTrue(outline.item(atRow: 1) is HitSummaryItem)
        let served = try firstCellActions(1)
        XCTAssertTrue(served.contains("Copy Accession"), "\(served)")
        pasteboard.clearContents()
        XCTAssertTrue(AccessibilityRowProbe.performCellAction(named: "Copy Accession", in: try rowProxy(1)))
        XCTAssertEqual(pasteboard.string(forType: .string), (outline.item(atRow: 1) as? HitSummaryItem)?.hit.accession)
    }

    // MARK: - Row reuse

    func testActionsOfARowFarDownActOnThatRow() throws {
        let far = 35
        pasteboard.clearContents()
        XCTAssertTrue(AccessibilityRowProbe.performCellAction(named: "Copy Name", in: try rowProxy(far)))
        XCTAssertEqual(pasteboard.string(forType: .string), try readID(atRow: far))
        XCTAssertEqual(outline.selectedRow, far)
    }

    // MARK: - Menu-bar validation

    func testSelectionTableRowItemsFollowSelectionAndFocus() throws {
        focusOutline()
        let copyName = menuBarItem(.copyName)
        XCTAssertFalse(tab.validateMenuItem(copyName), "nothing selected")
        outline.selectRowIndexes(IndexSet(integer: 2), byExtendingSelection: false)
        XCTAssertTrue(tab.validateMenuItem(copyName))
        XCTAssertTrue(tab.validateMenuItem(menuBarItem(.copyFASTA)))
        XCTAssertTrue(tab.validateMenuItem(menuBarItem(.copyAccession)))
        XCTAssertFalse(tab.validateMenuItem(menuBarItem(.extractReads)), "the drawer does not adopt Extract Reads")

        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 80, height: 20))
        tab.addSubview(field)
        XCTAssertTrue(window.makeFirstResponder(field))
        XCTAssertFalse(tab.validateMenuItem(copyName), "outline not first responder")
    }

    func testExpandAllAndCollapseAllActOnTheFocusedOutline() throws {
        let expand = NSMenuItem(
            title: "Expand All", action: #selector(OutlineExpandCollapseActions.expandAllOutlineItems(_:)), keyEquivalent: ""
        )
        XCTAssertFalse(tab.validateMenuItem(expand))
        focusOutline()
        XCTAssertTrue(tab.validateMenuItem(expand))
        outline.collapseItem(nil, collapseChildren: true)
        let collapsed = outline.numberOfRows
        tab.expandAllOutlineItems(nil)
        XCTAssertGreaterThan(outline.numberOfRows, collapsed)
        tab.collapseAllOutlineItems(nil)
        XCTAssertEqual(outline.numberOfRows, collapsed)
    }

    // MARK: - Context menu parity

    func testContextMenuEveryItemHasACellActionOrMenuBarSelector() throws {
        let menu = try XCTUnwrap(outline.menu)
        let mainMenu = NSMenu()
        for command in ResultRowCommand.allCases { mainMenu.addItem(menuBarItem(command)) }
        for selector in [
            #selector(OutlineExpandCollapseActions.expandAllOutlineItems(_:)),
            #selector(OutlineExpandCollapseActions.collapseAllOutlineItems(_:)),
        ] {
            mainMenu.addItem(NSMenuItem(title: "x", action: selector, keyEquivalent: ""))
        }
        ContextMenuParityAssert.assertParity(
            contextMenu: menu, cellActionNames: try firstCellActions(1), mainMenu: mainMenu
        )
    }

    func testContextMenuItemsFollowTheSelection() throws {
        let menu = try XCTUnwrap(outline.menu)
        let copy = try XCTUnwrap(menu.items.first { $0.title == "Copy Name" })
        XCTAssertFalse(tab.validateMenuItem(copy))
        outline.selectRowIndexes(IndexSet(integer: 2), byExtendingSelection: false)
        XCTAssertTrue(tab.validateMenuItem(copy), "the context menu follows the selection alone")
    }

    // MARK: - Header column menu

    func testHeaderColumnMenuIsMirroredAndToggles() throws {
        let header = try XCTUnwrap(outline.headerView)
        let names = (header.accessibilityCustomActions() ?? []).map(\.name)
        XCTAssertFalse(names.isEmpty)
        XCTAssertEqual(Set(names).count, names.count)
        let show = try XCTUnwrap(names.first { $0.hasPrefix("Show ") }, "optional columns start hidden: \(names)")
        let column = String(show.dropFirst("Show ".count).dropLast(" Column".count))
        let tableColumn = try XCTUnwrap(outline.tableColumns.first { $0.title == column })
        XCTAssertTrue(tableColumn.isHidden)
        let action = try XCTUnwrap(header.accessibilityCustomActions()?.first { $0.name == show })
        XCTAssertEqual(action.handler?(), true)
        XCTAssertFalse(tableColumn.isHidden)
        XCTAssertTrue((header.accessibilityCustomActions() ?? []).map(\.name).contains("Hide \(column) Column"))
        UserDefaults.standard.removeObject(forKey: "blastResultsHiddenColumns")
    }
}
