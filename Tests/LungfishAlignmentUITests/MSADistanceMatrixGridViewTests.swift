// MSADistanceMatrixGridViewTests.swift - grid AX table, drawing, keyboard and responder actions (rulings U4 to U9)
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
import AppKit
@testable import LungfishAlignmentUI
import LungfishKit

@MainActor
final class RecordingPasteboard: PasteboardWriting {
    var strings: [String] = []
    func setString(_ string: String) { strings.append(string) }
}

@MainActor
final class MSADistanceMatrixGridViewTests: XCTestCase {
    private func makeGrid(_ count: Int = 4, pasteboard: RecordingPasteboard = RecordingPasteboard())
        -> (MSADistanceMatrixGridView, MSADistanceMatrixRowHeaderView, MSADistanceMatrixColumnHeaderView) {
        let grid = MSADistanceMatrixGridView(pasteboard: pasteboard)
        let rows = MSADistanceMatrixRowHeaderView(frame: NSRect(x: 0, y: 0, width: 80, height: 200))
        let columns = MSADistanceMatrixColumnHeaderView(frame: NSRect(x: 0, y: 0, width: 200, height: 80))
        let matrix = StubDistanceMatrix.make(count)
        rows.names = matrix.displayNames
        columns.names = matrix.displayNames
        grid.rowHeaderView = rows
        grid.columnHeaderView = columns
        grid.setMatrix(matrix)
        return (grid, rows, columns)
    }

    private func key(_ special: NSEvent.SpecialKey, flags: NSEvent.ModifierFlags = []) -> NSEvent {
        let character = String(Character(UnicodeScalar(special.rawValue)!))
        return NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: 0,
            context: nil, characters: character, charactersIgnoringModifiers: character,
            isARepeat: false, keyCode: 0
        )!
    }

    private func key(characters: String, keyCode: UInt16, flags: NSEvent.ModifierFlags = []) -> NSEvent {
        NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: 0,
            context: nil, characters: characters, charactersIgnoringModifiers: characters,
            isARepeat: false, keyCode: keyCode
        )!
    }

    // MARK: AX table

    func testGridIsAnAXTableWithRowAndColumnCountsAndHeaders() throws {
        let (grid, rows, columns) = makeGrid(4)
        XCTAssertEqual(grid.accessibilityRole(), .table)
        XCTAssertEqual(grid.accessibilityRowCount(), 4)
        XCTAssertEqual(grid.accessibilityColumnCount(), 4)
        XCTAssertEqual(grid.accessibilityRows()?.count, 4)
        let columnHeaders = try XCTUnwrap(grid.accessibilityColumnHeaderUIElements() as? [NSAccessibilityElement])
        let rowHeaders = try XCTUnwrap(grid.accessibilityRowHeaderUIElements() as? [NSAccessibilityElement])
        XCTAssertEqual(columnHeaders.count, 4)
        XCTAssertEqual(rowHeaders.count, 4)
        XCTAssertEqual(columnHeaders.map { $0.accessibilityLabel() }, ["s0", "s1", "s2", "s3"])
        XCTAssertEqual(rowHeaders.first?.accessibilityCustomActions()?.map(\.name), ["Select Sequence in Alignment"])
        XCTAssertTrue(columns.accessibilityChildren()?.count == 4)
        XCTAssertTrue(rows.accessibilityChildren()?.count == 4)
    }

    func testCellElementsCarryIndicesLabelsAndCustomActions() throws {
        let (grid, _, _) = makeGrid(3)
        let element = try XCTUnwrap(grid.accessibilityCell(forColumn: 2, row: 1) as? NSAccessibilityElement)
        XCTAssertEqual(element.accessibilityRole(), .cell)
        XCTAssertEqual(element.accessibilityRowIndexRange(), NSRange(location: 1, length: 1))
        XCTAssertEqual(element.accessibilityColumnIndexRange(), NSRange(location: 2, length: 1))
        XCTAssertEqual(element.accessibilityLabel(), "s1, s2, 0.997000, 100 sites compared")
        XCTAssertEqual(element.accessibilityHelp(), "Press Return to show both sequences in the alignment.")
        XCTAssertEqual(
            element.accessibilityCustomActions()?.map(\.name),
            ["Reveal Pair in Alignment", "Copy", "Copy Matrix", "Export Matrix as TSV…", "Select Row's Sequences"]
        )
        let diagonal = try XCTUnwrap(grid.accessibilityCell(forColumn: 0, row: 0) as? NSAccessibilityElement)
        XCTAssertEqual(diagonal.accessibilityLabel(), "s0, s0, 1.000000, 100 sites compared, same sequence")
        XCTAssertNil(grid.accessibilityCell(forColumn: 3, row: 0))
        let row = try XCTUnwrap(grid.accessibilityRows()?[1] as? NSAccessibilityElement)
        XCTAssertEqual(row.accessibilityRole(), .row)
        XCTAssertEqual(row.accessibilityChildren()?.count, 3)
        XCTAssertTrue((element.accessibilityParent() as AnyObject) === row)
    }

    func testCellElementsAreCachedAndDroppedOnReload() throws {
        let (grid, _, _) = makeGrid(3)
        let first = try XCTUnwrap(grid.accessibilityCell(forColumn: 1, row: 1) as AnyObject?)
        XCTAssertTrue(first === grid.accessibilityCell(forColumn: 1, row: 1) as AnyObject?)
        grid.setMatrix(StubDistanceMatrix.make(3))
        XCTAssertFalse(first === grid.accessibilityCell(forColumn: 1, row: 1) as AnyObject?)
    }

    func testSelectionShowsInAXSelectedCellsAndPressSelects() throws {
        let (grid, _, _) = makeGrid(3)
        let element = try XCTUnwrap(grid.accessibilityCell(forColumn: 0, row: 2) as? NSAccessibilityElement)
        XCTAssertTrue(element.accessibilityPerformPress())
        XCTAssertTrue(element.isAccessibilitySelected())
        XCTAssertEqual(grid.accessibilitySelectedCells()?.count, 1)
        element.setAccessibilitySelected(false)
        XCTAssertTrue(grid.selection.cells.isEmpty)
    }

    // MARK: Keyboard and responder actions

    func testKeyboardRoutesThroughSelectionAlgebra() {
        let (grid, _, _) = makeGrid(4)
        grid.keyDown(with: key(.downArrow))
        XCTAssertEqual(grid.selection.cells, [MSADistanceCell(row: 0, column: 0)])
        grid.keyDown(with: key(.rightArrow, flags: .shift))
        XCTAssertEqual(grid.selection.cells.count, 2)
        grid.keyDown(with: key(.downArrow, flags: .option))
        XCTAssertEqual(grid.selection.cells.count, 2, "Option-arrow moves focus only")
        grid.keyDown(with: key(characters: " ", keyCode: 49))
        XCTAssertEqual(grid.selection.cells.count, 3, "Space toggles the focused cell")
        grid.keyDown(with: key(characters: "\u{1b}", keyCode: 53))
        XCTAssertTrue(grid.selection.cells.isEmpty)
    }

    func testReturnRevealsFocusedPair() {
        let (grid, _, _) = makeGrid(4)
        var revealed: MSADistanceCell?
        grid.onReveal = { revealed = $0 }
        grid.keyDown(with: key(.downArrow))
        grid.keyDown(with: key(.rightArrow))
        grid.keyDown(with: key(.carriageReturn))
        XCTAssertEqual(revealed, MSADistanceCell(row: 0, column: 1))
    }

    func testCopyAndSelectAllAreValidatedResponderActions() {
        let pasteboard = RecordingPasteboard()
        let (grid, _, _) = makeGrid(3, pasteboard: pasteboard)
        let copyItem = NSMenuItem(title: "Copy", action: #selector(MSADistanceMatrixGridView.copy(_:)), keyEquivalent: "c")
        let selectAllItem = NSMenuItem(title: "Select All", action: #selector(NSResponder.selectAll(_:)), keyEquivalent: "a")
        let revealItem = NSMenuItem(title: "Reveal", action: #selector(MSADistanceMatrixGridView.revealPairInAlignment(_:)), keyEquivalent: "")
        XCTAssertFalse(grid.validateMenuItem(copyItem))
        XCTAssertTrue(grid.validateMenuItem(selectAllItem))
        XCTAssertFalse(grid.validateMenuItem(revealItem))
        grid.selectAll(nil)
        XCTAssertTrue(grid.validateMenuItem(copyItem))
        grid.copy(nil)
        XCTAssertEqual(pasteboard.strings, [StubDistanceMatrix.make(3).squareTSV])
        XCTAssertTrue(grid.validateMenuItem(revealItem))
    }

    func testCopyMatrixAndExportForwardAndValidate() {
        let grid = MSADistanceMatrixGridView(pasteboard: RecordingPasteboard())
        let copyMatrix = NSMenuItem(title: "Copy Matrix", action: #selector(MSADistanceMatrixGridView.copyMatrix(_:)), keyEquivalent: "")
        let export = NSMenuItem(title: "Export", action: #selector(MSADistanceMatrixGridView.exportDistanceMatrix(_:)), keyEquivalent: "")
        XCTAssertFalse(grid.validateMenuItem(copyMatrix))
        XCTAssertFalse(grid.validateMenuItem(export))
        grid.isExportAvailable = { true }
        XCTAssertTrue(grid.validateMenuItem(export), "export stays available in the too-many-rows state")
        var exports = 0
        var copies = 0
        grid.onExport = { exports += 1 }
        grid.onCopyMatrix = { copies += 1 }
        grid.setMatrix(StubDistanceMatrix.make(2))
        XCTAssertTrue(grid.validateMenuItem(copyMatrix))
        grid.copyMatrix(nil)
        grid.exportDistanceMatrix(nil)
        XCTAssertEqual(copies, 1)
        XCTAssertEqual(exports, 1)
    }

    func testContextMenuMatchesCustomActions() throws {
        let (grid, _, _) = makeGrid(3)
        let menuTitles = grid.contextMenu().items.filter { !$0.isSeparatorItem }.map(\.title)
        let element = try XCTUnwrap(grid.accessibilityCell(forColumn: 1, row: 0) as? NSAccessibilityElement)
        XCTAssertEqual(menuTitles, element.accessibilityCustomActions()?.map(\.name))
    }

    func testHeaderClickSelectsSequenceBandAndBoldsHeaders() {
        let (grid, rows, columns) = makeGrid(4)
        var reported: [IndexSet] = []
        grid.onSelectionChanged = { reported.append($0.sequenceIndices) }
        grid.headerClicked(2, modifiers: [])
        grid.headerClicked(3, modifiers: .command)
        XCTAssertEqual(reported.last, IndexSet([2, 3]))
        XCTAssertEqual(rows.selectedSequences, IndexSet([2, 3]))
        XCTAssertEqual(columns.selectedSequences, IndexSet([2, 3]))
        grid.reflectSequences(IndexSet([0]))
        XCTAssertEqual(rows.selectedSequences, IndexSet([0]))
        XCTAssertEqual(reported.count, 2, "reverse sync never echoes back to the alignment")
    }

    // MARK: Geometry, typography and drawing

    func testShowValuesOffShrinksCells() {
        let (grid, _, _) = makeGrid(10)
        XCTAssertGreaterThanOrEqual(grid.cellSide, 22)
        grid.showsValues = false
        XCTAssertEqual(grid.cellSide, 12)
        XCTAssertEqual(grid.frame.size, NSSize(width: 120, height: 120))
    }

    func testTypographyRelayoutGrowsCells() {
        let (grid, _, _) = makeGrid(3)
        let provider = FixedSizeFontProvider(pointSize: 13)
        grid.typography = ContentTypography(preference: .custom(100), preferredFontProvider: provider)
        let small = grid.cellSide
        provider.pointSize = 26
        grid.typography = ContentTypography(preference: .custom(100), preferredFontProvider: provider)
        XCTAssertGreaterThan(grid.cellSide, small)
        XCTAssertEqual(grid.frame.width, grid.cellSide * 3, accuracy: 0.01)
    }

    func testGridDrawsColouredCellsOffscreen() throws {
        let matrix = StubDistanceMatrix(
            displayNames: ["a", "b"],
            displayRecordIndices: [0, 1],
            displayValues: [[1, 0.5], [0.5, 1]]
        )
        let grid = MSADistanceMatrixGridView(pasteboard: RecordingPasteboard())
        grid.appearance = NSAppearance(named: .aqua)
        grid.showsValues = false
        grid.setMatrix(matrix)
        grid.colorScale = MSADistanceColorScale(lower: 0, upper: 1)
        let rep = try XCTUnwrap(grid.bitmapImageRepForCachingDisplay(in: grid.bounds))
        grid.cacheDisplay(in: grid.bounds, to: rep)
        // Off-diagonal cell (row 0, column 1) sits at x 12...24, y 0...12 in the flipped grid.
        let scaleX = CGFloat(rep.pixelsWide) / grid.bounds.width
        let scaleY = CGFloat(rep.pixelsHigh) / grid.bounds.height
        let colour = try XCTUnwrap(rep.colorAt(x: Int(18 * scaleX), y: Int(6 * scaleY))?.usingColorSpace(.sRGB))
        let expected = MSADistanceColorScale.rampColor(at: 0.5, appearance: .light)
        XCTAssertEqual(colour.redComponent, expected.red, accuracy: 0.03)
        XCTAssertEqual(colour.greenComponent, expected.green, accuracy: 0.03)
        XCTAssertEqual(colour.blueComponent, expected.blue, accuracy: 0.03)
    }
}

@MainActor
final class FixedSizeFontProvider: ContentPreferredFontProviding {
    var pointSize: CGFloat

    init(pointSize: CGFloat) { self.pointSize = pointSize }

    func preferredFont(for role: ContentTypography.Role) -> NSFont {
        role == .monospaced
            ? .monospacedSystemFont(ofSize: pointSize, weight: .regular)
            : .systemFont(ofSize: pointSize)
    }

    func canonicalUnscaledPointSize(for role: ContentTypography.Role) -> CGFloat { 13 }
}
