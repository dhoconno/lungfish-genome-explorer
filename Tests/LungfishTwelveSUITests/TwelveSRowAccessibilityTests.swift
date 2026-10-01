// TwelveSRowAccessibilityTests.swift - 12S rows and controls reach the keyboard and AX clients
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import LungfishCore
import LungfishIO
import LungfishKit
import LungfishTestSupport
import XCTest
@testable import LungfishTwelveSUI

/// The 12S tables build their copy context menu, Selection > Table Row
/// validation and each row's accessibility actions from one list of entries
/// (`TwelveSCopyMenuProvider`). The Export and Sample Columns buttons list
/// their menus as accessibility actions, and File > Export > 12S Result…
/// presents the format choice as a sheet.
@MainActor
final class TwelveSRowAccessibilityTests: XCTestCase {
    private final class SpyPasteboard: PasteboardWriting {
        var last: String?
        func setString(_ s: String) { last = s }
    }

    private let rowCount = 40
    private var window: NSWindow!
    private var vc: TwelveSAmpliconResultViewController!
    private var spy = SpyPasteboard()

    override func setUp() async throws {
        try await super.setUp()
        _ = NSApplication.shared
        spy = SpyPasteboard()
        vc = TwelveSAmpliconResultViewController()
        vc.view.frame = NSRect(x: 0, y: 0, width: 1000, height: 560)
        vc.testingSetPasteboard(spy)
        window = NSWindow(contentRect: vc.view.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = vc.view
        window.makeKeyAndOrderFront(nil)
        vc.configure(result: makeResult())
        vc.view.layoutSubtreeIfNeeded()
        vc.testingActiveTableView.layoutSubtreeIfNeeded()
    }

    override func tearDown() async throws {
        window.orderOut(nil)
        window.contentView = nil
        window = nil
        vc = nil
        try await super.tearDown()
    }

    private func makeResult() -> TwelveSAmpliconResultBundleData {
        let template = TwelveSFixtures.twoSampleResult()
        let targets = (0..<rowCount).map { index in
            TwelveSAmpliconTarget(
                targetID: "t\(index)", displayName: "species \(index)",
                scientificName: String(format: "Species %02d", index), commonName: "common \(index)",
                taxid: "\(7_000 + index)", taxonGroup: "Mammal"
            )
        }
        var counts: [String: [String: Int]] = [:]
        for index in 0..<rowCount { counts["t\(index)"] = ["SampleA": 100 - index, "SampleB": 5] }
        let unresolved = (0..<rowCount).map { index in
            TwelveSUnresolvedSequence(
                sequenceID: String(format: "cluster_%02d", index),
                sequence: "ACGT" + String(repeating: "A", count: index),
                readCount: 100 - index, sampleCounts: ["SampleA": 100 - index], chimeraStatus: .notDetected
            )
        }
        return TwelveSAmpliconResultBundleData(
            bundleURL: template.bundleURL, manifest: template.manifest, artifacts: template.artifacts,
            samples: template.samples, targets: targets, countRows: counts, readFate: template.readFate,
            unresolvedSequences: unresolved
        )
    }

    private func rowProxy(_ row: Int) throws -> AnyObject {
        let table = vc.testingActiveTableView
        table.scrollRowToVisible(row)
        table.layoutSubtreeIfNeeded()
        let proxies = AccessibilityRowProbe.rowProxies(of: table)
        return try XCTUnwrap(proxies.indices.contains(row) ? proxies[row] : nil, "no AX proxy for row \(row)")
    }

    private func firstCellActions(_ row: Int) throws -> [String] {
        try XCTUnwrap(AccessibilityRowProbe.servedCellActionNames(try rowProxy(row)).first)
    }

    private func menuBarItem(_ command: ResultRowCommand) -> NSMenuItem {
        command.makeMenuBarItem(identifier: "test-\(command.identifierSlug)")
    }

    private func focusActiveTable() {
        window.makeKeyAndOrderFront(nil)
        XCTAssertTrue(window.makeFirstResponder(vc.testingActiveTableView))
    }

    // MARK: - Target rows

    func testTargetRowActionsAreListedOnceUnderTheContextMenuTitles() throws {
        let name = vc.testingTargetText(row: 2, column: "scientificName")
        let served = try firstCellActions(2)
        XCTAssertEqual(served, ["Copy Name", "Learn More About \(name)", "View Photo of \(name)"])
        XCTAssertEqual(Set(served).count, served.count, "each action is served once")
    }

    func testTargetCopyNameActionWritesThePasteboardAndSelectsTheRow() throws {
        let name = vc.testingTargetText(row: 3, column: "scientificName")
        XCTAssertTrue(AccessibilityRowProbe.performCellAction(named: "Copy Name", in: try rowProxy(3)))
        XCTAssertEqual(spy.last, name)
        XCTAssertEqual(vc.testingActiveTableView.selectedRow, 3)
    }

    func testTargetLookupActionOpensTheSpeciesPage() throws {
        var opened: [URL] = []
        vc.onOpenURLRequested = { opened.append($0) }
        let name = vc.testingTargetText(row: 4, column: "scientificName")
        XCTAssertTrue(AccessibilityRowProbe.performCellAction(named: "Learn More About \(name)", in: try rowProxy(4)))
        XCTAssertEqual(opened.count, 1)
        XCTAssertTrue(opened[0].absoluteString.contains("taxonomy"), opened[0].absoluteString)
    }

    func testActionsOfARowFarDownActOnThatRow() throws {
        let far = 36
        let name = vc.testingTargetText(row: far, column: "scientificName")
        XCTAssertTrue(AccessibilityRowProbe.performCellAction(named: "Copy Name", in: try rowProxy(far)))
        XCTAssertEqual(spy.last, name)
        XCTAssertEqual(vc.testingActiveTableView.selectedRow, far)
    }

    func testReusedCellViewRebindsItsActionsToTheNewRow() throws {
        let table = vc.testingActiveTableView
        let first = try XCTUnwrap(table.view(atColumn: 1, row: 0, makeIfNecessary: true))
        table.scrollRowToVisible(38)
        table.layoutSubtreeIfNeeded()
        guard let shownRow = AccessibilityCellActions.currentRow(of: first) else { return }
        let action = try XCTUnwrap(first.accessibilityCustomActions()?.first { $0.name == "Copy Name" })
        XCTAssertEqual(action.handler?(), true)
        XCTAssertEqual(spy.last, vc.testingTargetText(row: shownRow, column: "scientificName"))
    }

    // MARK: - Unresolved rows

    func testUnresolvedRowActionsAndCopySequence() throws {
        vc.showUnresolvedForTesting()
        vc.view.layoutSubtreeIfNeeded()
        let served = try firstCellActions(5)
        XCTAssertEqual(served, ["Copy Name", "Copy Sequence"])
        XCTAssertTrue(AccessibilityRowProbe.performCellAction(named: "Copy Sequence", in: try rowProxy(5)))
        XCTAssertTrue(spy.last?.hasPrefix("ACGT") == true, spy.last ?? "nil")
        XCTAssertTrue(AccessibilityRowProbe.performCellAction(named: "Copy Name", in: try rowProxy(6)))
        XCTAssertEqual(spy.last, vc.testingUnresolvedSequenceID(at: 6))
    }

    // MARK: - Menu-bar validation

    func testSelectionTableRowItemsFollowSelectionModeAndFocus() throws {
        focusActiveTable()
        let table = vc.testingActiveTableView
        table.deselectAll(nil)
        XCTAssertFalse(vc.validateMenuItem(menuBarItem(.copyName)), "nothing selected")

        table.selectRowIndexes(IndexSet(integer: 3), byExtendingSelection: false)
        XCTAssertTrue(vc.validateMenuItem(menuBarItem(.copyName)))
        XCTAssertFalse(vc.validateMenuItem(menuBarItem(.copyAsTSV)), "Copy Rows needs two rows")
        XCTAssertFalse(vc.validateMenuItem(menuBarItem(.copySequence)), "target rows have no sequence")
        XCTAssertFalse(vc.validateMenuItem(menuBarItem(.extractReads)))

        table.selectRowIndexes(IndexSet([3, 4]), byExtendingSelection: false)
        XCTAssertTrue(vc.validateMenuItem(menuBarItem(.copyAsTSV)))

        vc.showUnresolvedForTesting()
        focusActiveTable()
        vc.testingActiveTableView.selectRowIndexes(IndexSet(integer: 2), byExtendingSelection: false)
        XCTAssertTrue(vc.validateMenuItem(menuBarItem(.copySequence)))

        vc.copySelectedRowName(nil)
        XCTAssertEqual(spy.last, vc.testingUnresolvedSequenceID(at: 2))
    }

    func testSelectionTableRowItemsAreDisabledWhenTheTableIsNotFirstResponder() throws {
        vc.testingActiveTableView.selectRowIndexes(IndexSet(integer: 3), byExtendingSelection: false)
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 80, height: 20))
        vc.view.addSubview(field)
        XCTAssertTrue(window.makeFirstResponder(field))
        XCTAssertFalse(vc.validateMenuItem(menuBarItem(.copyName)))
        focusActiveTable()
        XCTAssertTrue(vc.validateMenuItem(menuBarItem(.copyName)))
    }

    // MARK: - Context menu parity

    func testContextMenuEveryItemHasACellActionOrMenuBarSelector() throws {
        vc.testingActiveTableView.selectRowIndexes(IndexSet(integer: 1), byExtendingSelection: false)
        let menu = vc.testingPopulatedCopyContextMenu()
        let mainMenu = NSMenu()
        for command in ResultRowCommand.allCases { mainMenu.addItem(menuBarItem(command)) }
        let cellNames = try firstCellActions(1)
        ContextMenuParityAssert.assertParity(contextMenu: menu, cellActionNames: cellNames, mainMenu: mainMenu)
        XCTAssertEqual(menu.items.filter { !$0.isSeparatorItem }.map(\.title), cellNames)
    }

    // MARK: - Buttons and the Export menu item

    func testExportButtonListsTheFormatsAsActions() throws {
        XCTAssertEqual(
            vc.testingExportButtonActionNames,
            ["Export as CSV\u{2026}", "Export as TSV\u{2026}", "Export as Excel\u{2026}"]
        )
    }

    func testSampleColumnsButtonOffersImportAndShowHideActions() throws {
        let store = try SampleMetadataStore(
            csvData: Data("Sample\tCohort\nSampleA\tcase\nSampleB\tcontrol\n".utf8),
            knownSampleIds: ["SampleA", "SampleB"]
        )
        vc.applyMetadataStore(store)
        XCTAssertEqual(vc.testingSampleColumnsActions.map(\.name), ["Hide Cohort Column", "Import Metadata\u{2026}"])
        var imports = 0
        vc.onMetadataImportRequested = { imports += 1 }
        XCTAssertEqual(vc.testingSampleColumnsActions[0].handler?(), true)
        XCTAssertEqual(vc.testingSampleColumnsActions.map(\.name), ["Show Cohort Column", "Import Metadata\u{2026}"])
        XCTAssertEqual(vc.testingSampleColumnsActions[1].handler?(), true)
        XCTAssertEqual(imports, 1)
    }

    func testExportMenuItemPresentsTheFormatChoiceAsASheet() throws {
        let item = NSMenuItem(
            title: "12S Result\u{2026}", action: #selector(TwelveSResultMenuActions.exportTwelveSResult(_:)), keyEquivalent: ""
        )
        XCTAssertTrue(vc.validateMenuItem(item), "a result is showing")
        XCTAssertEqual(
            vc.makeExportFormatAlert().buttons.map(\.title),
            TwelveSAmpliconResultExportFormat.allCases.map(\.displayName) + ["Cancel"]
        )

        vc.exportTwelveSResult(nil)
        let sheet = try XCTUnwrap(window.attachedSheet, "the format choice is a sheet on the result window")
        let cancel = NSApplication.ModalResponse(
            rawValue: NSApplication.ModalResponse.alertFirstButtonReturn.rawValue
                + TwelveSAmpliconResultExportFormat.allCases.count
        )
        window.endSheet(sheet, returnCode: cancel)
        XCTAssertNil(window.attachedSheet)
    }

    func testExportMenuItemIsDisabledWithoutAResult() {
        let empty = TwelveSAmpliconResultViewController()
        let item = NSMenuItem(
            title: "12S Result\u{2026}", action: #selector(TwelveSResultMenuActions.exportTwelveSResult(_:)), keyEquivalent: ""
        )
        XCTAssertFalse(empty.validateMenuItem(item))
    }
}
