// ReferenceAndKitTableAccessibilityTests.swift - Row commands of two more viewer tables reach AX clients
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import LungfishKit
import LungfishTestSupport
import XCTest
@testable import LungfishApp
@testable import LungfishCore
@testable import LungfishIO

/// The reference bundle record table publishes the shared FASTA commands
/// through the `BatchTableView` hook and the Selection > Table Row items,
/// and the FASTQ metadata drawer's barcode kit table publishes its three
/// copy commands on every cell.
@MainActor
final class ReferenceAndKitTableAccessibilityTests: XCTestCase {
    /// A pasteboard of this test's own. The general pasteboard is one per
    /// machine, so a copy made by a test running in another process at the
    /// same time would show up here.
    private let pasteboard = NSPasteboard.withUniqueName()

    override func tearDown() {
        pasteboard.releaseGlobally()
        super.tearDown()
    }

    private func summary(_ name: String, length: Int) -> BundleBrowserSequenceSummary {
        BundleBrowserSequenceSummary(
            name: name, displayDescription: nil, length: Int64(length), aliases: [],
            isPrimary: true, isMitochondrial: false, metrics: nil
        )
    }

    private func makeRecordTable() -> (ReferenceBundleRecordTable, NSWindow) {
        _ = NSApplication.shared
        let table = ReferenceBundleRecordTable(frame: NSRect(x: 0, y: 0, width: 700, height: 300))
        table.pasteboard = pasteboard
        let window = NSWindow(contentRect: table.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = table
        table.configure(dynamicFields: [], rows: [
            ReferenceBundleRecordRow(summary: summary("chr1", length: 100), values: [:]),
            ReferenceBundleRecordRow(summary: summary("chr2", length: 200), values: [:]),
            ReferenceBundleRecordRow(summary: summary("chrM", length: 16_569), values: [:]),
        ])
        table.layoutSubtreeIfNeeded()
        table.tableView.layoutSubtreeIfNeeded()
        return (table, window)
    }

    /// Goes through `AXUIElementCopyActionNames` and `AXUIElementPerformAction`
    /// like an out-of-process client: the row's actions are listed once and
    /// performing one on an unselected row acts on that row alone.
    func testRecordRowActionsReachAnOutOfProcessAXClient() throws {
        try XCTSkipUnless(AXProcessProbe.isAvailable, "process is not trusted for accessibility")
        let (table, window) = makeRecordTable()
        window.orderFront(nil)
        defer { window.close() }
        var extracted: [[String]] = []
        table.onCopySequences = { _, _ in }
        table.onExtractSequences = { extracted.append($0.map(\.summary.name)) }
        table.tableView.reloadData()
        table.tableView.layoutSubtreeIfNeeded()

        let listed = AXProcessProbe.rowCellActionNames(row: 2)
        let names = try XCTUnwrap(listed, "the server lists the row's cell")
        XCTAssertEqual(names, ["Copy Name", "Copy Sequence", "Copy FASTA", "Extract to New Bundle\u{2026}"])
        XCTAssertTrue(AXProcessProbe.performRowCellAction("Copy Name", row: 2))
        XCTAssertEqual(pasteboard.string(forType: .string), "chrM")
        table.tableView.selectRowIndexes(IndexSet([0, 1]), byExtendingSelection: false)
        XCTAssertTrue(AXProcessProbe.performRowCellAction("Extract to New Bundle\u{2026}", row: 2))
        XCTAssertEqual(extracted.last, ["chrM"], "an unselected row is targeted alone")
    }

    func testRecordRowsPublishTheFASTACommandsOnceAndInParityWithTheContextMenu() throws {
        let (table, window) = makeRecordTable()
        defer { window.close() }
        var copied: [(names: [String], fasta: Bool)] = []
        table.onCopySequences = { rows, fasta in copied.append((rows.map(\.summary.name), fasta)) }
        var extracted: [[String]] = []
        table.onExtractSequences = { extracted.append($0.map(\.summary.name)) }
        table.tableView.reloadData()
        table.tableView.layoutSubtreeIfNeeded()

        let rows = AccessibilityRowProbe.rowProxies(of: table.tableView)
        XCTAssertEqual(rows.count, 3)
        let expected = ["Copy Name", "Copy Sequence", "Copy FASTA", "Extract to New Bundle\u{2026}"]
        XCTAssertEqual(AccessibilityRowProbe.firstCellActionNames(rows[1]), expected)
        for served in AccessibilityRowProbe.servedCellActionNames(rows[1]) {
            XCTAssertEqual(served, expected, "the AX server lists each action once")
        }
        ContextMenuParityAssert.assertParity(
            contextMenu: table.sequenceActionMenu(clickedRow: 1),
            cellActionNames: expected,
            mainMenu: MainMenu.createMainMenu()
        )

        XCTAssertTrue(AccessibilityRowProbe.performCellAction(named: "Copy Name", in: rows[2]))
        XCTAssertEqual(pasteboard.string(forType: .string), "chrM")
        XCTAssertTrue(AccessibilityRowProbe.performCellAction(named: "Copy FASTA", in: rows[0]))
        XCTAssertEqual(copied.last?.names, ["chr1"])
        XCTAssertEqual(copied.last?.fasta, true)

        // On a selected row the command takes the whole selection; on an
        // unselected row it takes that row alone.
        table.tableView.selectRowIndexes(IndexSet([0, 1]), byExtendingSelection: false)
        XCTAssertTrue(AccessibilityRowProbe.performCellAction(named: "Extract to New Bundle\u{2026}", in: rows[0]))
        XCTAssertEqual(extracted.last, ["chr1", "chr2"])
        XCTAssertTrue(AccessibilityRowProbe.performCellAction(named: "Extract to New Bundle\u{2026}", in: rows[2]))
        XCTAssertEqual(extracted.last, ["chrM"])
    }

    func testRecordMenuBarRowCommandsFollowTheSelection() throws {
        let (table, window) = makeRecordTable()
        defer { window.close() }
        var copied: [(names: [String], fasta: Bool)] = []
        table.onCopySequences = { rows, fasta in copied.append((rows.map(\.summary.name), fasta)) }
        func item(_ selector: Selector) -> NSMenuItem { NSMenuItem(title: "", action: selector, keyEquivalent: "") }
        let copyName = item(#selector(ResultRowMenuActions.copySelectedRowName(_:)))
        let copySequence = item(#selector(ResultRowMenuActions.copySelectedRowSequence(_:)))
        let extract = item(#selector(ResultRowMenuActions.extractSelectedRowsToNewBundle(_:)))

        table.tableView.deselectAll(nil)
        XCTAssertFalse(table.validateMenuItem(copyName))
        table.tableView.selectRowIndexes(IndexSet([1, 2]), byExtendingSelection: false)
        XCTAssertTrue(table.validateMenuItem(copyName))
        XCTAssertTrue(table.validateMenuItem(copySequence))
        XCTAssertFalse(table.validateMenuItem(extract), "no extract handler wired")
        table.copySelectedRowName(nil)
        XCTAssertEqual(pasteboard.string(forType: .string), "chr2\nchrM")
        table.copySelectedRowSequence(nil)
        XCTAssertEqual(copied.last?.names, ["chr2", "chrM"])
        XCTAssertEqual(copied.last?.fasta, false)
    }

    func testKitBarcodeRowsPublishTheThreeCopyCommandsAndCopyTheRow() throws {
        _ = NSApplication.shared
        let drawer = FASTQMetadataDrawerView()
        drawer.frame = NSRect(x: 0, y: 0, width: 800, height: 500)
        drawer.pasteboard = pasteboard
        let window = NSWindow(contentRect: drawer.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = drawer
        defer { window.close() }
        drawer.testShowKitBarcodes([
            BarcodeEntry(id: "D701", i7Sequence: "ATTACTCG", i5Sequence: "TATAGCCT"),
            BarcodeEntry(id: "D702", i7Sequence: "TCCGGAGA", i5Sequence: nil),
        ])
        drawer.layoutSubtreeIfNeeded()
        drawer.testKitDetailTable.layoutSubtreeIfNeeded()

        let rows = AccessibilityRowProbe.rowProxies(of: drawer.testKitDetailTable)
        XCTAssertEqual(rows.count, 2)
        let expected = ["Copy Selected Barcodes", "Copy Barcode IDs", "Copy Sequences"]
        for row in rows {
            XCTAssertEqual(AccessibilityRowProbe.firstCellActionNames(row), expected)
            for served in AccessibilityRowProbe.servedCellActionNames(row) {
                XCTAssertEqual(served, expected, "the AX server lists each action once")
            }
        }
        XCTAssertTrue(AccessibilityRowProbe.performCellAction(named: "Copy Barcode IDs", in: rows[1]))
        XCTAssertEqual(pasteboard.string(forType: .string), "D702")
        XCTAssertTrue(AccessibilityRowProbe.performCellAction(named: "Copy Sequences", in: rows[0]))
        XCTAssertEqual(pasteboard.string(forType: .string), "ATTACTCG")
        XCTAssertTrue(AccessibilityRowProbe.performCellAction(named: "Copy Selected Barcodes", in: rows[0]))
        XCTAssertEqual(pasteboard.string(forType: .string), "ID\tSequence\tSecondary\nD701\tATTACTCG\tTATAGCCT")
    }
}
