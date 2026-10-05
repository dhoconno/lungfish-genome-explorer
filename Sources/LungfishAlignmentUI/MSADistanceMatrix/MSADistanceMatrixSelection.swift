// MSADistanceMatrixSelection.swift - Pure selection algebra for the distance matrix grid
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation

/// One cell of the distance matrix, in display order.
public struct MSADistanceCell: Hashable, Sendable {
    public let row: Int
    public let column: Int

    public init(row: Int, column: Int) {
        self.row = row
        self.column = column
    }

    public var isDiagonal: Bool { row == column }

    /// The cell on the other side of the diagonal.
    public var mirror: MSADistanceCell { MSADistanceCell(row: column, column: row) }
}

/// Selection state of the distance matrix grid (rulings U7 and U9).
///
/// The grid holds either a set of cells or a band of whole sequences picked
/// from the row and column headers, never both. Indices are display positions.
/// Callers map them to input record indices through the matrix permutation.
public struct MSADistanceMatrixSelection: Equatable, Sendable {
    public enum Direction: Sendable {
        case up, down, left, right
    }

    public private(set) var size: Int
    public private(set) var cells: Set<MSADistanceCell> = []
    public private(set) var anchor: MSADistanceCell?
    public private(set) var focus: MSADistanceCell?
    /// Sequences picked from the headers or mirrored from the alignment.
    public private(set) var selectedSequences = IndexSet()
    private var headerAnchor: Int?

    public init(size: Int) {
        self.size = max(0, size)
    }

    // MARK: Mouse

    public mutating func click(_ cell: MSADistanceCell) {
        guard contains(cell) else { return }
        leaveHeaderMode()
        cells = [cell]
        anchor = cell
        focus = cell
    }

    public mutating func commandClick(_ cell: MSADistanceCell) {
        guard contains(cell) else { return }
        leaveHeaderMode()
        if cells.contains(cell) {
            cells.remove(cell)
        } else {
            cells.insert(cell)
        }
        anchor = cell
        focus = cell
    }

    public mutating func shiftClick(_ cell: MSADistanceCell) {
        guard contains(cell) else { return }
        leaveHeaderMode()
        let start = anchor ?? cell
        cells = Self.rectangle(start, cell)
        anchor = start
        focus = cell
    }

    public mutating func commandShiftClick(_ cell: MSADistanceCell) {
        guard contains(cell) else { return }
        leaveHeaderMode()
        let start = anchor ?? cell
        cells.formUnion(Self.rectangle(start, cell))
        anchor = start
        focus = cell
    }

    // MARK: Keyboard

    /// Arrow keys. `extend` is Shift, `focusOnly` is Option, `toEdge` is Command.
    public mutating func move(
        _ direction: Direction,
        extend: Bool = false,
        focusOnly: Bool = false,
        toEdge: Bool = false
    ) {
        guard size > 0 else { return }
        guard let current = focus else {
            land(on: MSADistanceCell(row: 0, column: 0), extend: false, focusOnly: focusOnly)
            return
        }
        let last = size - 1
        var row = current.row
        var column = current.column
        switch direction {
        case .up: row = toEdge ? 0 : row - 1
        case .down: row = toEdge ? last : row + 1
        case .left: column = toEdge ? 0 : column - 1
        case .right: column = toEdge ? last : column + 1
        }
        let target = MSADistanceCell(row: clamp(row), column: clamp(column))
        land(on: target, extend: extend, focusOnly: focusOnly)
    }

    /// Page Up and Page Down move the focus by a visible page of rows.
    public mutating func page(_ direction: Direction, rows: Int, extend: Bool = false) {
        guard size > 0 else { return }
        let current = focus ?? MSADistanceCell(row: 0, column: 0)
        let step = max(1, rows)
        let row: Int
        switch direction {
        case .up: row = current.row - step
        case .down: row = current.row + step
        case .left, .right: row = current.row
        }
        land(on: MSADistanceCell(row: clamp(row), column: current.column), extend: extend, focusOnly: false)
    }

    /// Home jumps to the first cell.
    public mutating func home(extend: Bool = false) {
        guard size > 0 else { return }
        land(on: MSADistanceCell(row: 0, column: 0), extend: extend, focusOnly: false)
    }

    /// End jumps to the last cell.
    public mutating func end(extend: Bool = false) {
        guard size > 0 else { return }
        land(on: MSADistanceCell(row: size - 1, column: size - 1), extend: extend, focusOnly: false)
    }

    /// Space toggles the focused cell, the keyboard twin of Command-click.
    public mutating func toggleFocused() {
        guard let focus else { return }
        commandClick(focus)
    }

    public mutating func selectAll() {
        guard size > 0 else { return }
        leaveHeaderMode()
        cells = Self.rectangle(
            MSADistanceCell(row: 0, column: 0),
            MSADistanceCell(row: size - 1, column: size - 1)
        )
        if focus == nil { focus = MSADistanceCell(row: 0, column: 0) }
        if anchor == nil { anchor = focus }
    }

    /// Escape clears cells and header sequences. The focus stays put.
    public mutating func clear() {
        cells = []
        leaveHeaderMode()
    }

    // MARK: Headers and reverse sync

    public mutating func headerClick(_ index: Int) {
        guard (0..<size).contains(index) else { return }
        cells = []
        selectedSequences = IndexSet(integer: index)
        headerAnchor = index
    }

    public mutating func headerCommandClick(_ index: Int) {
        guard (0..<size).contains(index) else { return }
        cells = []
        if selectedSequences.contains(index) {
            selectedSequences.remove(index)
        } else {
            selectedSequences.insert(index)
        }
        headerAnchor = index
    }

    public mutating func headerShiftClick(_ index: Int) {
        guard (0..<size).contains(index) else { return }
        cells = []
        let start = headerAnchor ?? index
        selectedSequences = IndexSet(integersIn: min(start, index)...max(start, index))
        headerAnchor = start
    }

    /// Mirrors a row selection made in the alignment: cells clear and the
    /// sequences show as a band.
    public mutating func reflectSequences(_ displayIndices: IndexSet) {
        cells = []
        selectedSequences = displayIndices.filteredIndexSet { (0..<size).contains($0) }
        headerAnchor = selectedSequences.first
    }

    // MARK: Derived values

    /// Sequences the alignment should select: the union of the rows and
    /// columns of every selected cell, or the header band.
    public var sequenceIndices: IndexSet {
        if cells.isEmpty { return selectedSequences }
        var indices = IndexSet()
        for cell in cells {
            indices.insert(cell.row)
            indices.insert(cell.column)
        }
        return indices
    }

    /// The smallest rectangle that covers every selected cell.
    public var boundingBox: (rows: ClosedRange<Int>, columns: ClosedRange<Int>)? {
        guard let first = cells.first else { return nil }
        var minRow = first.row, maxRow = first.row
        var minColumn = first.column, maxColumn = first.column
        for cell in cells {
            minRow = min(minRow, cell.row)
            maxRow = max(maxRow, cell.row)
            minColumn = min(minColumn, cell.column)
            maxColumn = max(maxColumn, cell.column)
        }
        return (minRow...maxRow, minColumn...maxColumn)
    }

    public func contains(_ cell: MSADistanceCell) -> Bool {
        (0..<size).contains(cell.row) && (0..<size).contains(cell.column)
    }

    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.size == rhs.size && lhs.cells == rhs.cells && lhs.anchor == rhs.anchor
            && lhs.focus == rhs.focus && lhs.selectedSequences == rhs.selectedSequences
    }

    // MARK: Private

    private mutating func land(on target: MSADistanceCell, extend: Bool, focusOnly: Bool) {
        if focusOnly {
            focus = target
            return
        }
        if extend {
            leaveHeaderMode()
            let start = anchor ?? target
            cells = Self.rectangle(start, target)
            anchor = start
            focus = target
        } else {
            click(target)
        }
    }

    private mutating func leaveHeaderMode() {
        selectedSequences = IndexSet()
        headerAnchor = nil
    }

    private func clamp(_ value: Int) -> Int {
        min(max(0, value), size - 1)
    }

    private static func rectangle(_ a: MSADistanceCell, _ b: MSADistanceCell) -> Set<MSADistanceCell> {
        var result: Set<MSADistanceCell> = []
        for row in min(a.row, b.row)...max(a.row, b.row) {
            for column in min(a.column, b.column)...max(a.column, b.column) {
                result.insert(MSADistanceCell(row: row, column: column))
            }
        }
        return result
    }
}
