// NvdRowAccessibilityTests.swift - NVD contig rows reach the keyboard and AX clients
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import LungfishIO
import LungfishKit
import LungfishTestSupport
import LungfishWorkflow
import XCTest
@testable import LungfishNvdUI

/// The NVD outline builds its context menu, Selection > Table Row validation
/// and each row's accessibility actions from one availability rule
/// (`availableRowActions(for:)`), so the surfaces offer the same commands
/// under the same titles.
@MainActor
final class NvdRowAccessibilityTests: XCTestCase {
    private var root: URL!
    private var window: NSWindow!
    private var vc: NvdResultViewController!
    /// A pasteboard of this test's own. The general pasteboard is one per
    /// machine, so a copy made by a test running in another process at the
    /// same time would show up here.
    private let pasteboard = NSPasteboard.withUniqueName()
    private var outline: NSOutlineView { vc.testOutlineView }
    private let contigCount = 40

    override func setUp() async throws {
        try await super.setUp()
        _ = NSApplication.shared
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("nvd-row-ax-\(UUID().uuidString)", isDirectory: true)
        let bundle = root.appendingPathComponent("fixture.nvd", isDirectory: true)
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
        var fasta = ""
        for index in 0..<contigCount { fasta += ">\(Self.contig(index))\nAACCGGTT\(String(repeating: "A", count: index))\n" }
        try fasta.write(to: bundle.appendingPathComponent("sample1.fasta"), atomically: true, encoding: .utf8)
        try Data().write(to: bundle.appendingPathComponent("sample1.bam"))
        try Data().write(to: bundle.appendingPathComponent("sample1.bam.bai"))

        var hits = (0..<contigCount).map { Self.hit(index: $0, rank: 1) }
        hits.append(Self.hit(index: 0, rank: 2))
        let database = try NvdDatabase.create(
            at: bundle.appendingPathComponent("nvd.sqlite"),
            hits: hits,
            samples: [NvdSampleMetadata(
                sampleId: "sample1", bamPath: "sample1.bam", fastaPath: "sample1.fasta",
                totalReads: 1000, contigCount: contigCount, hitCount: hits.count
            )]
        )
        let manifest = NvdManifest(
            experiment: "exp-1", sampleCount: 1, contigCount: contigCount, hitCount: hits.count,
            blastDbVersion: "db", snakemakeRunId: "run-1", sourceDirectoryPath: root.path,
            samples: [NvdSampleSummary(
                sampleId: "sample1", contigCount: contigCount, hitCount: hits.count, totalReads: 1000,
                bamRelativePath: "sample1.bam", bamIndexRelativePath: "sample1.bam.bai",
                fastaRelativePath: "sample1.fasta"
            )],
            cachedTopContigs: nil
        )

        vc = NvdResultViewController()
        vc.pasteboard = pasteboard
        vc.onBlastVerification = { _, _ in }
        vc.onExportFASTARequested = { _ in }
        vc.onCreateBundleRequested = { _ in }
        vc.onRunOperationRequested = { _ in }
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1100, height: 520),
            styleMask: [.titled], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentViewController = vc
        window.setContentSize(NSSize(width: 1100, height: 520))
        _ = vc.view
        vc.configure(database: database, manifest: manifest, bundleURL: bundle)
        window.layoutIfNeeded()
        vc.view.layoutSubtreeIfNeeded()
        outline.layoutSubtreeIfNeeded()
    }

    override func tearDown() async throws {
        window.orderOut(nil)
        window.contentViewController = nil
        window = nil
        vc = nil
        pasteboard.releaseGlobally()
        try? FileManager.default.removeItem(at: root)
        try await super.tearDown()
    }

    private static func contig(_ index: Int) -> String { String(format: "contig_%02d", index) }

    private static func hit(index: Int, rank: Int) -> NvdBlastHit {
        NvdBlastHit(
            experiment: "exp-1", blastTask: "blastn", sampleId: "sample1", qseqid: contig(index),
            qlen: 8 + index, sseqid: String(format: "NC_%06d.1", index + rank), stitle: "Reference \(index)",
            taxRank: "species", length: 8, pident: 100, evalue: 0, bitscore: 50,
            sscinames: "Example virus", staxids: "1234", blastDbVersion: "db", snakemakeRunId: "run-1",
            mappedReads: 1_000 - index, totalReads: 1000, statDbVersion: "stats-1", adjustedTaxid: "1234",
            adjustmentMethod: "dominant", adjustedTaxidName: "Example virus", adjustedTaxidRank: "species",
            hitRank: rank, readsPerBillion: Double(1_000 - index) * 10_000
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

    private func contigName(atRow row: Int) throws -> String {
        let item = try XCTUnwrap(outline.item(atRow: row) as? NvdOutlineItem)
        return try XCTUnwrap(item.sampleContig?.qseqid)
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
        XCTAssertGreaterThan(outline.numberOfRows, contigCount - 1)
        let served = try firstCellActions(2)
        XCTAssertEqual(
            served,
            [
                "Extract Reads\u{2026}", "Extract Sequence\u{2026}", "Verify with BLAST\u{2026}", "Copy FASTA",
                "Export FASTA\u{2026}", "Extract to New Bundle\u{2026}", "Run Operation\u{2026}",
                "Copy Name", "Copy Accession", "Open on NCBI", "Search PubMed",
            ]
        )
        XCTAssertEqual(Set(served).count, served.count, "each action is served once")
    }

    func testCopyActionsWriteThePasteboard() throws {
        let name = try contigName(atRow: 3)
        pasteboard.clearContents()
        XCTAssertTrue(AccessibilityRowProbe.performCellAction(named: "Copy Name", in: try rowProxy(3)))
        XCTAssertEqual(pasteboard.string(forType: .string), name)

        XCTAssertTrue(AccessibilityRowProbe.performCellAction(named: "Copy Accession", in: try rowProxy(4)))
        let index = try XCTUnwrap(Int(try contigName(atRow: 4).dropFirst("contig_".count)))
        XCTAssertEqual(pasteboard.string(forType: .string), String(format: "NC_%06d.1", index + 1))

        XCTAssertTrue(AccessibilityRowProbe.performCellAction(named: "Copy FASTA", in: try rowProxy(5)))
        let fasta = try XCTUnwrap(pasteboard.string(forType: .string))
        XCTAssertTrue(fasta.hasPrefix(">\(try contigName(atRow: 5))\nAACCGGTT"), fasta)
    }

    func testExtractReadsActionOpensTheDialogForItsRow() throws {
        var captured: [ClassifierRowSelector] = []
        vc.onExtractReadsRequested = { _, _, selectors, _ in captured = selectors }
        let name = try contigName(atRow: 6)
        XCTAssertTrue(AccessibilityRowProbe.performCellAction(named: "Extract Reads\u{2026}", in: try rowProxy(6)))
        XCTAssertEqual(captured.count, 1)
        XCTAssertEqual(captured.first?.sampleId, "sample1")
        XCTAssertEqual(captured.first?.accessions, [name])
    }

    // MARK: - Row reuse

    func testActionsOfARowFarDownActOnThatRow() throws {
        let far = 36
        let name = try contigName(atRow: far)
        pasteboard.clearContents()
        XCTAssertTrue(AccessibilityRowProbe.performCellAction(named: "Copy Name", in: try rowProxy(far)))
        XCTAssertEqual(pasteboard.string(forType: .string), name)
        XCTAssertEqual(outline.selectedRow, far)
    }

    func testReusedCellViewRebindsItsActionsToTheNewRow() throws {
        let first = try XCTUnwrap(outline.view(atColumn: 0, row: 0, makeIfNecessary: true))
        XCTAssertTrue((first.accessibilityCustomActions() ?? []).contains { $0.name == "Copy Name" })
        outline.scrollRowToVisible(38)
        outline.layoutSubtreeIfNeeded()
        // Whatever row the (possibly recycled) cell now shows, its action
        // copies that row's contig.
        guard let shownRow = AccessibilityCellActions.currentRow(of: first) else { return }
        let action = try XCTUnwrap(first.accessibilityCustomActions()?.first { $0.name == "Copy Name" })
        pasteboard.clearContents()
        XCTAssertEqual(action.handler?(), true)
        XCTAssertEqual(pasteboard.string(forType: .string), try contigName(atRow: shownRow))
    }

    // MARK: - Menu-bar validation

    func testSelectionTableRowItemsFollowSelectionAndFocus() throws {
        focusOutline()
        outline.deselectAll(nil)
        XCTAssertFalse(vc.validateMenuItem(menuBarItem(.copyName)), "nothing selected")
        XCTAssertFalse(vc.validateMenuItem(menuBarItem(.extractReads)), "nothing selected")

        outline.selectRowIndexes(IndexSet(integer: 3), byExtendingSelection: false)
        XCTAssertTrue(vc.validateMenuItem(menuBarItem(.copyName)))
        XCTAssertTrue(vc.validateMenuItem(menuBarItem(.extractReads)))
        XCTAssertTrue(vc.validateMenuItem(menuBarItem(.blastVerify)))
        XCTAssertFalse(vc.validateMenuItem(menuBarItem(.copySequence)), "NVD does not adopt Copy Sequence")

        outline.selectRowIndexes(IndexSet([3, 4]), byExtendingSelection: false)
        XCTAssertFalse(vc.validateMenuItem(menuBarItem(.copyName)), "single-row command, two rows selected")
        XCTAssertTrue(vc.validateMenuItem(menuBarItem(.extractReads)), "Extract Reads takes any selection")
    }

    func testSelectionTableRowItemsAreDisabledWhenTheOutlineIsNotFirstResponder() throws {
        window.makeKeyAndOrderFront(nil)
        outline.selectRowIndexes(IndexSet(integer: 3), byExtendingSelection: false)
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 80, height: 20))
        vc.view.addSubview(field)
        XCTAssertTrue(window.makeFirstResponder(field))
        XCTAssertFalse(vc.validateMenuItem(menuBarItem(.copyName)))
        focusOutline()
        XCTAssertTrue(vc.validateMenuItem(menuBarItem(.copyName)))
    }

    func testExpandAllAndCollapseAllActOnTheFocusedOutline() throws {
        let expand = NSMenuItem(
            title: "Expand All", action: #selector(OutlineExpandCollapseActions.expandAllOutlineItems(_:)), keyEquivalent: ""
        )
        XCTAssertFalse(vc.validateMenuItem(expand), "outline not focused")
        focusOutline()
        XCTAssertTrue(vc.validateMenuItem(expand))
        vc.collapseAllOutlineItems(nil)
        let collapsed = outline.numberOfRows
        XCTAssertEqual(collapsed, contigCount)
        vc.expandAllOutlineItems(nil)
        XCTAssertGreaterThan(outline.numberOfRows, collapsed)
        vc.collapseAllOutlineItems(nil)
        XCTAssertEqual(outline.numberOfRows, collapsed)
    }

    // MARK: - Context menu parity

    func testContextMenuEveryItemHasACellActionOrMenuBarSelector() throws {
        let menu = NSMenu()
        vc.menuNeedsUpdateForTesting(menu, rowItem: .contig(sampleId: "sample1", qseqid: Self.contig(1)))
        XCTAssertFalse(menu.items.isEmpty)
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
        XCTAssertEqual(
            menu.items.filter { !$0.isSeparatorItem }.map(\.title),
            try firstCellActions(1),
            "the context menu and the cell actions list the same commands in the same order"
        )
    }
}
