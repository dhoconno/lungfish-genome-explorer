// NaoMgsRowAccessibilityTests.swift - NAO-MGS taxon rows reach the keyboard and AX clients
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import LungfishIO
import LungfishKit
import LungfishTestSupport
import LungfishWorkflow
import XCTest
@testable import LungfishNaoMgsUI

/// The NAO-MGS taxon table builds its context menu, Selection > Table Row
/// validation and each row's accessibility actions from one availability rule
/// (`availableRowCommands(for:)`), and its accession buttons list their menu
/// as accessibility actions.
@MainActor
final class NaoMgsRowAccessibilityTests: XCTestCase {
    private var root: URL!
    private var window: NSWindow!
    private var vc: NaoMgsResultViewController!
    /// A pasteboard of this test's own. The general pasteboard is one per
    /// machine, so a copy made by a test running in another process at the
    /// same time would show up here.
    private let pasteboard = NSPasteboard.withUniqueName()
    private var table: NSTableView { vc.testTaxonomyTableView }
    private let taxonCount = 40

    override func setUp() async throws {
        try await super.setUp()
        _ = NSApplication.shared
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("naomgs-row-ax-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let hits = (0..<taxonCount).flatMap { index in
            (1...2).map { Self.hit(taxIndex: index, read: $0) }
        }
        let database = try NaoMgsDatabase.create(at: root.appendingPathComponent("hits.sqlite"), hits: hits)
        let manifest = NaoMgsManifest(
            sampleName: "sample-A", sourceFilePath: "/tmp/naomgs.tsv", hitCount: hits.count,
            taxonCount: taxonCount, topTaxon: "Taxon 0", topTaxonId: 1_000
        )
        vc = NaoMgsResultViewController()
        vc.pasteboard = pasteboard
        vc.testDisableMiniBAMLoading = true
        vc.onBlastVerification = { _, _, _ in }
        vc.view.frame = NSRect(x: 0, y: 0, width: 1000, height: 480)
        window = NSWindow(contentRect: vc.view.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = vc.view
        window.makeKeyAndOrderFront(nil)
        vc.configure(database: database, manifest: manifest, bundleURL: root)
        let loaded = await waitUntil { self.vc.testDisplayedTaxonOrder.count == self.taxonCount }
        XCTAssertTrue(loaded, "the taxon table loads")
        vc.view.layoutSubtreeIfNeeded()
        table.layoutSubtreeIfNeeded()
    }

    override func tearDown() async throws {
        window.orderOut(nil)
        window.contentView = nil
        window = nil
        vc = nil
        pasteboard.releaseGlobally()
        try? FileManager.default.removeItem(at: root)
        try await super.tearDown()
    }

    private static func hit(taxIndex: Int, read: Int) -> NaoMgsVirusHit {
        NaoMgsVirusHit(
            sample: "sample-A", seqId: "read-\(taxIndex)-\(read)", taxId: 1_000 + taxIndex,
            bestAlignmentScore: 120, cigar: "100M", queryStart: 0, queryEnd: 100,
            refStart: read * 100, refEnd: read * 100 + 100,
            readSequence: String(repeating: "A", count: 100), readQuality: String(repeating: "I", count: 100),
            subjectSeqId: String(format: "NC_%06d.1", taxIndex), subjectTitle: "Taxon \(taxIndex)",
            bitScore: 210, eValue: 1e-40, percentIdentity: 99, editDistance: 1, fragmentLength: 100,
            isReverseComplement: false, pairStatus: "CP", queryLength: 100
        )
    }

    private func taxId(atRow row: Int) throws -> Int {
        let entry = try XCTUnwrap(vc.testDisplayedTaxonOrder[row].split(separator: ":").last)
        return try XCTUnwrap(Int(entry))
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

    func testRowActionsAreListedOnceUnderTheSharedTitles() throws {
        let served = try firstCellActions(3)
        XCTAssertEqual(
            served,
            [
                "Verify with BLAST\u{2026}", "Copy Taxon ID", "Copy Accession", "Open on NCBI",
                "Open Taxonomy on NCBI", "Search PubMed", "Extract Reads\u{2026}",
            ]
        )
        XCTAssertEqual(Set(served).count, served.count, "each action is served once")
    }

    func testCopyActionsWriteThePasteboard() throws {
        pasteboard.clearContents()
        XCTAssertTrue(AccessibilityRowProbe.performCellAction(named: "Copy Taxon ID", in: try rowProxy(4)))
        XCTAssertEqual(pasteboard.string(forType: .string), "\(try taxId(atRow: 4))")

        XCTAssertTrue(AccessibilityRowProbe.performCellAction(named: "Copy Accession", in: try rowProxy(5)))
        let accession = try XCTUnwrap(pasteboard.string(forType: .string))
        XCTAssertTrue(accession.hasPrefix("NC_0000"), accession)
    }

    func testExtractReadsActionOpensTheDialogForItsRow() throws {
        var captured: (ClassifierTool, [ClassifierRowSelector])?
        vc.onExtractReadsRequested = { tool, _, selectors, _ in captured = (tool, selectors) }
        let id = try taxId(atRow: 6)
        XCTAssertTrue(AccessibilityRowProbe.performCellAction(named: "Extract Reads\u{2026}", in: try rowProxy(6)))
        XCTAssertEqual(captured?.0, .naomgs)
        XCTAssertEqual(captured?.1.first?.taxIds, [id])
        XCTAssertEqual(table.selectedRow, 6)
    }

    // MARK: - Row reuse

    func testActionsOfARowFarDownActOnThatRow() throws {
        let far = 36
        pasteboard.clearContents()
        XCTAssertTrue(AccessibilityRowProbe.performCellAction(named: "Copy Taxon ID", in: try rowProxy(far)))
        XCTAssertEqual(pasteboard.string(forType: .string), "\(try taxId(atRow: far))")
        XCTAssertEqual(table.selectedRow, far)
    }

    func testReusedCellViewRebindsItsActionsToTheNewRow() throws {
        let first = try XCTUnwrap(table.view(atColumn: 0, row: 0, makeIfNecessary: true))
        table.scrollRowToVisible(38)
        table.layoutSubtreeIfNeeded()
        guard let shownRow = AccessibilityCellActions.currentRow(of: first) else { return }
        let action = try XCTUnwrap(first.accessibilityCustomActions()?.first { $0.name == "Copy Taxon ID" })
        pasteboard.clearContents()
        XCTAssertEqual(action.handler?(), true)
        XCTAssertEqual(pasteboard.string(forType: .string), "\(try taxId(atRow: shownRow))")
    }

    // MARK: - Menu-bar validation

    func testSelectionTableRowItemsFollowSelectionAndFocus() throws {
        focusTable()
        table.deselectAll(nil)
        XCTAssertFalse(vc.validateMenuItem(menuBarItem(.copyTaxonID)), "nothing selected")
        XCTAssertFalse(vc.validateMenuItem(menuBarItem(.extractReads)), "nothing selected")

        table.selectRowIndexes(IndexSet(integer: 3), byExtendingSelection: false)
        XCTAssertTrue(vc.validateMenuItem(menuBarItem(.copyTaxonID)))
        XCTAssertTrue(vc.validateMenuItem(menuBarItem(.extractReads)))
        XCTAssertTrue(vc.validateMenuItem(menuBarItem(.blastVerify)))
        XCTAssertFalse(vc.validateMenuItem(menuBarItem(.copySequence)), "NAO-MGS does not adopt Copy Sequence")

        table.selectRowIndexes(IndexSet([3, 4]), byExtendingSelection: false)
        XCTAssertFalse(vc.validateMenuItem(menuBarItem(.copyTaxonID)), "single-row command, two rows selected")
        XCTAssertTrue(vc.validateMenuItem(menuBarItem(.extractReads)), "Extract Reads takes any selection")
    }

    func testSelectionTableRowItemsAreDisabledWhenTheTableIsNotFirstResponder() throws {
        table.selectRowIndexes(IndexSet(integer: 3), byExtendingSelection: false)
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 80, height: 20))
        vc.view.addSubview(field)
        XCTAssertTrue(window.makeFirstResponder(field))
        XCTAssertFalse(vc.validateMenuItem(menuBarItem(.copyTaxonID)))
        focusTable()
        XCTAssertTrue(vc.validateMenuItem(menuBarItem(.copyTaxonID)))
    }

    // MARK: - Context menu parity

    func testContextMenuEveryItemHasACellActionOrMenuBarSelectorAndFollowsSelection() throws {
        let menu = try XCTUnwrap(vc.testPopulateContextMenu(forRow: 1))
        let mainMenu = NSMenu()
        for command in ResultRowCommand.allCases { mainMenu.addItem(menuBarItem(command)) }
        ContextMenuParityAssert.assertParity(
            contextMenu: menu, cellActionNames: try firstCellActions(1), mainMenu: mainMenu
        )
        XCTAssertEqual(
            menu.items.filter { !$0.isSeparatorItem }.map(\.title),
            try firstCellActions(1),
            "the context menu and the cell actions list the same commands in the same order"
        )
        let copy = try XCTUnwrap(menu.items.first { $0.title == "Copy Taxon ID" })
        table.deselectAll(nil)
        XCTAssertFalse(vc.validateMenuItem(copy), "no selection and no clicked row")
        table.selectRowIndexes(IndexSet(integer: 1), byExtendingSelection: false)
        XCTAssertTrue(vc.validateMenuItem(copy), "the context menu follows the selection alone")
    }

    // MARK: - Accession buttons

    func testAccessionButtonOffersCopyAccession() async throws {
        table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        let found = await waitUntil { Self.accessionButtons(in: self.vc.testDetailContentView).isEmpty == false }
        XCTAssertTrue(found, "the detail pane lists the taxon's accessions")
        let button = try XCTUnwrap(Self.accessionButtons(in: vc.testDetailContentView).first)
        // Read the action names the way the AX server lists them (the button's cell).
        let names = AccessibilityRowProbe.servedActionNames(ofControl: button)
        XCTAssertEqual(names.filter { $0 == "Copy Accession" }.count, 1, "listed once at the AX element: \(names)")
        XCTAssertEqual(Set(names).count, names.count, "\(names)")
        let action = try XCTUnwrap(button.accessibilityCustomActions()?.first { $0.name == "Copy Accession" })
        pasteboard.clearContents()
        XCTAssertEqual(action.handler?(), true)
        XCTAssertEqual(pasteboard.string(forType: .string), button.title)
    }

    private static func accessionButtons(in root: NSView) -> [NSButton] {
        var found: [NSButton] = []
        func walk(_ view: NSView) {
            if let button = view as? NSButton, button.title.hasPrefix("NC_") { found.append(button) }
            view.subviews.forEach(walk)
        }
        walk(root)
        return found
    }
}
