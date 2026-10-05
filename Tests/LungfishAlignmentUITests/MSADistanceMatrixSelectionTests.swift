// MSADistanceMatrixSelectionTests.swift - selection algebra for the distance matrix grid (ruling U7, U9)
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
@testable import LungfishAlignmentUI

final class MSADistanceMatrixSelectionTests: XCTestCase {
    private func cell(_ row: Int, _ column: Int) -> MSADistanceCell {
        MSADistanceCell(row: row, column: column)
    }

    private func rectangle(rows: ClosedRange<Int>, columns: ClosedRange<Int>) -> Set<MSADistanceCell> {
        var cells: Set<MSADistanceCell> = []
        for row in rows { for column in columns { cells.insert(cell(row, column)) } }
        return cells
    }

    func testClickSelectsOneCellAndSetsAnchorAndFocus() {
        var selection = MSADistanceMatrixSelection(size: 5)
        selection.click(cell(1, 2))
        selection.click(cell(3, 4))
        XCTAssertEqual(selection.cells, [cell(3, 4)])
        XCTAssertEqual(selection.anchor, cell(3, 4))
        XCTAssertEqual(selection.focus, cell(3, 4))
    }

    func testCommandClickTogglesCells() {
        var selection = MSADistanceMatrixSelection(size: 5)
        selection.click(cell(0, 0))
        selection.commandClick(cell(2, 3))
        XCTAssertEqual(selection.cells, [cell(0, 0), cell(2, 3)])
        selection.commandClick(cell(0, 0))
        XCTAssertEqual(selection.cells, [cell(2, 3)])
        XCTAssertEqual(selection.focus, cell(0, 0))
    }

    func testShiftClickReplacesWithRectangleFromAnchor() {
        var selection = MSADistanceMatrixSelection(size: 6)
        selection.click(cell(4, 1))
        selection.commandClick(cell(0, 5))
        selection.click(cell(1, 1))
        selection.shiftClick(cell(3, 2))
        XCTAssertEqual(selection.cells, rectangle(rows: 1...3, columns: 1...2))
        XCTAssertEqual(selection.anchor, cell(1, 1))
        XCTAssertEqual(selection.focus, cell(3, 2))
        selection.shiftClick(cell(0, 0))
        XCTAssertEqual(selection.cells, rectangle(rows: 0...1, columns: 0...1))
    }

    func testCommandShiftClickAddsRectangle() {
        var selection = MSADistanceMatrixSelection(size: 6)
        selection.click(cell(5, 5))
        selection.commandClick(cell(0, 0))
        selection.commandShiftClick(cell(1, 1))
        XCTAssertEqual(selection.cells, rectangle(rows: 0...1, columns: 0...1).union([cell(5, 5)]))
    }

    func testArrowsMoveFocusAndSelect() {
        var selection = MSADistanceMatrixSelection(size: 3)
        selection.move(.down)
        XCTAssertEqual(selection.cells, [cell(0, 0)], "first arrow with no focus lands on the first cell")
        selection.move(.right)
        selection.move(.down)
        XCTAssertEqual(selection.cells, [cell(1, 1)])
        selection.move(.down)
        selection.move(.down)
        XCTAssertEqual(selection.focus, cell(2, 1), "arrows clamp at the edge")
        selection.move(.left, toEdge: true)
        XCTAssertEqual(selection.cells, [cell(2, 0)])
        selection.move(.up, toEdge: true)
        XCTAssertEqual(selection.cells, [cell(0, 0)])
    }

    func testShiftArrowsExtendRectangleFromAnchor() {
        var selection = MSADistanceMatrixSelection(size: 5)
        selection.click(cell(2, 2))
        selection.move(.down, extend: true)
        selection.move(.right, extend: true)
        XCTAssertEqual(selection.cells, rectangle(rows: 2...3, columns: 2...3))
        XCTAssertEqual(selection.anchor, cell(2, 2))
        selection.move(.up, extend: true)
        selection.move(.up, extend: true)
        XCTAssertEqual(selection.cells, rectangle(rows: 1...2, columns: 2...3))
    }

    func testOptionArrowsMoveFocusOnlyAndSpaceToggles() {
        var selection = MSADistanceMatrixSelection(size: 4)
        selection.click(cell(0, 0))
        selection.move(.right, focusOnly: true)
        selection.move(.down, focusOnly: true)
        XCTAssertEqual(selection.cells, [cell(0, 0)])
        XCTAssertEqual(selection.focus, cell(1, 1))
        selection.toggleFocused()
        XCTAssertEqual(selection.cells, [cell(0, 0), cell(1, 1)])
        selection.toggleFocused()
        XCTAssertEqual(selection.cells, [cell(0, 0)])
    }

    func testPageMovesByRowCountAndHomeEndJumpToCorners() {
        var selection = MSADistanceMatrixSelection(size: 30)
        selection.click(cell(3, 4))
        selection.page(.down, rows: 10)
        XCTAssertEqual(selection.cells, [cell(13, 4)])
        selection.page(.up, rows: 20)
        XCTAssertEqual(selection.cells, [cell(0, 4)])
        selection.end()
        XCTAssertEqual(selection.cells, [cell(29, 29)])
        selection.home()
        XCTAssertEqual(selection.cells, [cell(0, 0)])
    }

    func testSelectAllAndEscape() {
        var selection = MSADistanceMatrixSelection(size: 3)
        selection.selectAll()
        XCTAssertEqual(selection.cells.count, 9)
        selection.clear()
        XCTAssertTrue(selection.cells.isEmpty)
        XCTAssertTrue(selection.selectedSequences.isEmpty)
    }

    func testSequencesAreUnionOfRowsAndColumns() {
        var selection = MSADistanceMatrixSelection(size: 8)
        selection.click(cell(0, 2))
        selection.shiftClick(cell(1, 3))
        XCTAssertEqual(selection.sequenceIndices, IndexSet([0, 1, 2, 3]))
        selection.click(cell(4, 4))
        XCTAssertEqual(selection.sequenceIndices, IndexSet([4]), "a diagonal cell selects one row")
    }

    func testBoundingBox() {
        var selection = MSADistanceMatrixSelection(size: 8)
        XCTAssertNil(selection.boundingBox)
        selection.click(cell(5, 1))
        selection.commandClick(cell(2, 6))
        let box = try? XCTUnwrap(selection.boundingBox)
        XCTAssertEqual(box?.rows, 2...5)
        XCTAssertEqual(box?.columns, 1...6)
    }

    func testHeaderClicksSelectSequencesWithoutCells() {
        var selection = MSADistanceMatrixSelection(size: 6)
        selection.click(cell(1, 1))
        selection.headerClick(2)
        XCTAssertTrue(selection.cells.isEmpty)
        XCTAssertEqual(selection.selectedSequences, IndexSet([2]))
        selection.headerShiftClick(4)
        XCTAssertEqual(selection.selectedSequences, IndexSet(2...4))
        selection.headerCommandClick(0)
        XCTAssertEqual(selection.selectedSequences, IndexSet([0, 2, 3, 4]))
        selection.headerCommandClick(3)
        XCTAssertEqual(selection.selectedSequences, IndexSet([0, 2, 4]))
        XCTAssertEqual(selection.sequenceIndices, IndexSet([0, 2, 4]))
        selection.click(cell(5, 5))
        XCTAssertTrue(selection.selectedSequences.isEmpty, "a cell click leaves header band mode")
    }

    func testReflectSequencesClearsCells() {
        var selection = MSADistanceMatrixSelection(size: 6)
        selection.click(cell(1, 3))
        selection.reflectSequences(IndexSet([0, 5, 9]))
        XCTAssertTrue(selection.cells.isEmpty)
        XCTAssertEqual(selection.selectedSequences, IndexSet([0, 5]), "out-of-range indices are dropped")
    }

    func testCellsOutsideTheMatrixAreIgnored() {
        var selection = MSADistanceMatrixSelection(size: 2)
        selection.click(cell(4, 0))
        XCTAssertTrue(selection.cells.isEmpty)
        var empty = MSADistanceMatrixSelection(size: 0)
        empty.move(.down)
        empty.selectAll()
        XCTAssertNil(empty.focus)
        XCTAssertTrue(empty.cells.isEmpty)
    }
}
