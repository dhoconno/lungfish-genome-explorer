// ViralDetectionRowAccessibilityTests.swift - EsViritu rows reach the keyboard and AX clients
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import LungfishIO
import LungfishKit
import LungfishTestSupport
import XCTest
@testable import LungfishEsVirituUI

/// The EsViritu outline builds its context menu, Selection > Table Row
/// validation and each row's accessibility actions from one availability
/// rule (`availableRowActions(for:)`), so the surfaces offer the same
/// commands under the same titles.
@MainActor
final class ViralDetectionRowAccessibilityTests: XCTestCase {
    private var window: NSWindow!
    private var table: ViralDetectionTableView!
    private var outline: NSOutlineView { table.testOutlineView }
    private var names: [String] = []

    override func setUp() async throws {
        try await super.setUp()
        _ = NSApplication.shared
        names = (0..<40).map { String(format: "Virus %02d", $0) }
        table = ViralDetectionTableView(frame: NSRect(x: 0, y: 0, width: 760, height: 220))
        var assemblies = names.enumerated().map { index, name in
            Self.assembly(sample: "S1", name: name, reads: 1_000 - index, accession: String(format: "NC_%06d", index))
        }
        // A two-segment virus is the only kind with child rows to expand.
        // It sorts last, so the rows above it keep their indexes.
        let last = assemblies.count - 1
        let segment = Self.assembly(sample: "S1", name: names[last], reads: 1, accession: "NC_SEG2")
        assemblies[last] = ViralAssembly(
            assembly: assemblies[last].assembly, assemblyLength: 200, name: names[last], family: "Testviridae",
            genus: nil, species: names[last], totalReads: 961, rpkmf: 961, meanCoverage: 1,
            avgReadIdentity: 0.99, contigs: assemblies[last].contigs + segment.contigs
        )
        table.result = EsVirituResult(
            sampleId: "S1",
            detections: assemblies.flatMap(\.contigs),
            assemblies: assemblies,
            taxProfile: [],
            coverageWindows: [],
            totalFilteredReads: 100_000,
            detectedFamilyCount: 1,
            detectedSpeciesCount: assemblies.count,
            runtime: nil,
            toolVersion: nil
        )
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 760, height: 220),
            styleMask: [.titled], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = table
        table.frame = window.contentView!.bounds
        table.autoresizingMask = [.width, .height]
        window.layoutIfNeeded()
        table.layoutSubtreeIfNeeded()
        outline.layoutSubtreeIfNeeded()
    }

    override func tearDown() async throws {
        window.orderOut(nil)
        window = nil
        table = nil
        try await super.tearDown()
    }

    private static func assembly(sample: String, name: String, reads: Int, accession: String) -> ViralAssembly {
        let detection = ViralDetection(
            sampleId: sample, name: name, description: name, length: 100, segment: nil,
            accession: accession, assembly: "GCF_" + accession, assemblyLength: 100,
            kingdom: "Viruses", phylum: nil, tclass: nil, order: nil, family: "Testviridae",
            genus: nil, species: name, subspecies: nil, rpkmf: Double(reads), readCount: reads,
            coveredBases: 100, meanCoverage: 1, avgReadIdentity: 0.99, pi: 0,
            filteredReadsInSample: 100_000
        )
        return ViralAssembly(
            assembly: "GCF_" + accession, assemblyLength: 100, name: name, family: "Testviridae",
            genus: nil, species: name, totalReads: reads, rpkmf: Double(reads), meanCoverage: 1,
            avgReadIdentity: 0.99, contigs: [detection]
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

    private func focusOutline() {
        window.makeKeyAndOrderFront(nil)
        XCTAssertTrue(window.makeFirstResponder(outline))
    }

    private func menuBarItem(_ command: ResultRowCommand) -> NSMenuItem {
        command.makeMenuBarItem(identifier: "test-\(command.identifierSlug)")
    }

    // MARK: - Served actions

    func testRowActionsAreListedOnceUnderTheSharedTitles() throws {
        let served = try firstCellActions(0)
        XCTAssertEqual(
            served,
            [
                "Extract Reads\u{2026}", "Verify with BLAST\u{2026}", "Open GenBank Record",
                "Open Assembly Record", "Search PubMed", "Open Taxonomy on NCBI",
                "Copy Name", "Copy Accession", "Copy Row as TSV",
            ],
            "each action is served once, named like its context-menu item"
        )
        XCTAssertEqual(Set(served).count, served.count)
    }

    func testEveryCellOfTheRowServesTheSameActions() throws {
        let perCell = AccessibilityRowProbe.servedCellActionNames(try rowProxy(1))
        XCTAssertGreaterThan(perCell.count, 1)
        for (index, names) in perCell.enumerated() {
            XCTAssertEqual(names, perCell[0], "cell \(index)")
        }
    }

    func testCopyNameActionWritesThePasteboard() throws {
        NSPasteboard.general.clearContents()
        XCTAssertTrue(AccessibilityRowProbe.performCellAction(named: "Copy Name", in: try rowProxy(2)))
        XCTAssertEqual(NSPasteboard.general.string(forType: .string), names[2])

        XCTAssertTrue(AccessibilityRowProbe.performCellAction(named: "Copy Accession", in: try rowProxy(3)))
        XCTAssertEqual(NSPasteboard.general.string(forType: .string), "GCF_NC_000003")
    }

    func testRowActionSelectsItsRowBeforeActing() throws {
        XCTAssertTrue(outline.selectedRowIndexes.isEmpty)
        XCTAssertTrue(AccessibilityRowProbe.performCellAction(named: "Copy Row as TSV", in: try rowProxy(4)))
        XCTAssertEqual(outline.selectedRow, 4)
        XCTAssertTrue(NSPasteboard.general.string(forType: .string)?.hasPrefix(names[4] + "\t") == true)
    }

    // MARK: - Row reuse

    func testActionsOfARowFarDownActOnThatRow() throws {
        let far = 33
        outline.scrollRowToVisible(far)
        outline.layoutSubtreeIfNeeded()
        NSPasteboard.general.clearContents()
        XCTAssertTrue(AccessibilityRowProbe.performCellAction(named: "Copy Name", in: try rowProxy(far)))
        XCTAssertEqual(NSPasteboard.general.string(forType: .string), names[far])
    }

    // MARK: - Menu-bar validation follows the selection and the focus

    func testSelectionTableRowItemsFollowSelectionAndFocus() throws {
        focusOutline()
        let copyName = menuBarItem(.copyName)
        let extract = menuBarItem(.extractReads)
        XCTAssertFalse(table.validateMenuItem(copyName), "nothing selected")
        XCTAssertFalse(table.validateMenuItem(extract), "nothing selected")

        outline.selectRowIndexes(IndexSet(integer: 3), byExtendingSelection: false)
        XCTAssertTrue(table.validateMenuItem(copyName))
        XCTAssertTrue(table.validateMenuItem(extract))
        XCTAssertFalse(table.validateMenuItem(menuBarItem(.copySequence)), "EsViritu does not adopt Copy Sequence")

        outline.selectRowIndexes(IndexSet([3, 4]), byExtendingSelection: false)
        XCTAssertFalse(table.validateMenuItem(copyName), "single-row command, two rows selected")
        XCTAssertTrue(table.validateMenuItem(extract), "Extract Reads takes any selection")
    }

    func testSelectionTableRowItemsAreDisabledWhenTheOutlineIsNotFirstResponder() throws {
        window.makeKeyAndOrderFront(nil)
        outline.selectRowIndexes(IndexSet(integer: 3), byExtendingSelection: false)
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 80, height: 20))
        table.addSubview(field)
        XCTAssertTrue(window.makeFirstResponder(field))
        XCTAssertFalse(table.validateMenuItem(menuBarItem(.copyName)))
        XCTAssertFalse(table.validateMenuItem(menuBarItem(.extractReads)))

        focusOutline()
        XCTAssertTrue(table.validateMenuItem(menuBarItem(.copyName)))
    }

    func testExpandAllAndCollapseAllActOnTheFocusedOutline() throws {
        let expand = NSMenuItem(
            title: "Expand All", action: #selector(OutlineExpandCollapseActions.expandAllOutlineItems(_:)), keyEquivalent: ""
        )
        XCTAssertFalse(table.validateMenuItem(expand), "outline not focused")
        focusOutline()
        XCTAssertTrue(table.validateMenuItem(expand))
        table.collapseAllOutlineItems(nil)
        let collapsed = outline.numberOfRows
        XCTAssertEqual(collapsed, names.count)
        table.expandAllOutlineItems(nil)
        XCTAssertGreaterThan(outline.numberOfRows, collapsed)
        table.collapseAllOutlineItems(nil)
        XCTAssertEqual(outline.numberOfRows, collapsed)
    }

    // MARK: - Context menu parity

    func testContextMenuEveryItemHasACellActionOrMenuBarSelector() throws {
        let menu = try XCTUnwrap(table.testingContextMenu)
        let mainMenu = NSMenu()
        for command in ResultRowCommand.allCases { mainMenu.addItem(menuBarItem(command)) }
        for selector in [
            #selector(OutlineExpandCollapseActions.expandAllOutlineItems(_:)),
            #selector(OutlineExpandCollapseActions.collapseAllOutlineItems(_:)),
        ] {
            mainMenu.addItem(NSMenuItem(title: "x", action: selector, keyEquivalent: ""))
        }
        let cellNames = try firstCellActions(0)
        ContextMenuParityAssert.assertParity(contextMenu: menu, cellActionNames: cellNames, mainMenu: mainMenu)

        // The NCBI submenu's children are the other half of the menu.
        let ncbi = try XCTUnwrap(menu.items.first { $0.title == "Look Up on NCBI" }?.submenu)
        for item in ncbi.items {
            XCTAssertTrue(cellNames.contains(item.title), "\(item.title) has no cell action")
        }
    }

    func testContextMenuItemsFollowTheSelection() throws {
        let menu = try XCTUnwrap(table.testingContextMenu)
        let copy = try XCTUnwrap(menu.items.first { $0.title == "Copy Name" })
        XCTAssertFalse(table.validateMenuItem(copy), "no selection and no clicked row")
        outline.selectRowIndexes(IndexSet(integer: 2), byExtendingSelection: false)
        XCTAssertTrue(table.validateMenuItem(copy), "the context menu follows the selection alone")
    }
}
