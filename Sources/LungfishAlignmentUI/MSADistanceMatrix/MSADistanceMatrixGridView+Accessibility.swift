// MSADistanceMatrixGridView+Accessibility.swift - AXTable with lazy virtual rows and cells (ruling U4)
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit

/// Lazily created AX row and cell elements, dropped when the matrix or the
/// cell size changes. The elements are plain `NSAccessibilityElement`s set up
/// through their setters, like the MSA viewport overlays, so no override has
/// to cross into main-actor state.
@MainActor
struct MSADistanceAXCache {
    var rows: [Int: NSAccessibilityElement] = [:]
    var cells: [MSADistanceCell: NSAccessibilityElement] = [:]
    var actionTargets: [MSADistanceCell: MSADistanceAXCellActions] = [:]

    mutating func removeAll() {
        rows.removeAll()
        cells.removeAll()
        actionTargets.removeAll()
    }
}

/// Target of a cell's AX custom actions, the twins of its context menu.
/// Each action first selects and focuses the cell.
@MainActor
final class MSADistanceAXCellActions: NSObject {
    weak var grid: MSADistanceMatrixGridView?
    let cell: MSADistanceCell

    init(grid: MSADistanceMatrixGridView, cell: MSADistanceCell) {
        self.grid = grid
        self.cell = cell
    }

    private func prepare() -> MSADistanceMatrixGridView? {
        guard let grid else { return nil }
        if !grid.selection.cells.contains(cell) || grid.selection.focus != cell {
            let cell = self.cell
            grid.updateSelection { $0.click(cell) }
        }
        return grid
    }

    @objc func reveal() -> Bool { prepare()?.revealPairInAlignment(nil) != nil }
    @objc func copyCells() -> Bool { prepare()?.copy(nil) != nil }
    @objc func copyMatrix() -> Bool { prepare()?.copyMatrix(nil) != nil }
    @objc func export() -> Bool { prepare()?.exportDistanceMatrix(nil) != nil }
    @objc func selectRowSequences() -> Bool { prepare()?.selectRowSequences(nil) != nil }

    var customActions: [NSAccessibilityCustomAction] {
        [
            NSAccessibilityCustomAction(name: "Reveal Pair in Alignment", target: self, selector: #selector(reveal)),
            NSAccessibilityCustomAction(name: "Copy", target: self, selector: #selector(copyCells)),
            NSAccessibilityCustomAction(name: "Copy Matrix", target: self, selector: #selector(copyMatrix)),
            NSAccessibilityCustomAction(name: "Export Matrix as TSV…", target: self, selector: #selector(export)),
            NSAccessibilityCustomAction(name: "Select Row's Sequences", target: self, selector: #selector(selectRowSequences)),
        ]
    }
}

extension MSADistanceMatrixGridView {
    /// The row element and, with it, every cell of that row.
    func axRowElement(for row: Int) -> NSAccessibilityElement {
        if let cached = axCache.rows[row] { return cached }
        let count = matrix?.displayCount ?? 0
        let element = NSAccessibilityElement()
        element.setAccessibilityParent(self)
        element.setAccessibilityRole(.row)
        element.setAccessibilityIndex(row)
        element.setAccessibilityLabel(axRowLabel(row))
        element.setAccessibilityFrameInParentSpace(
            NSRect(x: 0, y: CGFloat(row) * cellSide, width: CGFloat(count) * cellSide, height: cellSide)
        )
        axCache.rows[row] = element
        var children: [Any] = []
        for column in 0..<count {
            let cell = MSADistanceCell(row: row, column: column)
            let cellElement = makeCellElement(cell, parent: element)
            axCache.cells[cell] = cellElement
            children.append(cellElement)
        }
        element.setAccessibilityChildren(children)
        return element
    }

    func axCellElement(for cell: MSADistanceCell) -> NSAccessibilityElement {
        if let cached = axCache.cells[cell] { return cached }
        _ = axRowElement(for: cell.row)
        return axCache.cells[cell] ?? NSAccessibilityElement()
    }

    private func makeCellElement(_ cell: MSADistanceCell, parent: NSAccessibilityElement) -> NSAccessibilityElement {
        let element = NSAccessibilityElement()
        element.setAccessibilityParent(parent)
        element.setAccessibilityRole(.cell)
        element.setAccessibilityRowIndexRange(NSRange(location: cell.row, length: 1))
        element.setAccessibilityColumnIndexRange(NSRange(location: cell.column, length: 1))
        element.setAccessibilityLabel(axCellLabel(cell))
        element.setAccessibilityHelp(MSADistanceMatrixText.cellHelp)
        // Relative to the row element, which is one cell tall.
        element.setAccessibilityFrameInParentSpace(
            NSRect(x: CGFloat(cell.column) * cellSide, y: 0, width: cellSide, height: cellSide)
        )
        element.setAccessibilitySelected(selection.cells.contains(cell))
        element.setAccessibilityFocused(selection.focus == cell)
        let actions = MSADistanceAXCellActions(grid: self, cell: cell)
        axCache.actionTargets[cell] = actions
        element.setAccessibilityCustomActions(actions.customActions)
        return element
    }

    /// Mirrors a selection change into the cached elements.
    func axSyncSelection(oldCells: Set<MSADistanceCell>, oldFocus: MSADistanceCell?) {
        for cell in oldCells.symmetricDifference(selection.cells) {
            axCache.cells[cell]?.setAccessibilitySelected(selection.cells.contains(cell))
        }
        if oldFocus != selection.focus {
            if let oldFocus { axCache.cells[oldFocus]?.setAccessibilityFocused(false) }
            if let focus = selection.focus { axCache.cells[focus]?.setAccessibilityFocused(true) }
        }
    }

    func axRowLabel(_ index: Int) -> String? {
        guard let names = matrix?.displayNames, names.indices.contains(index) else { return nil }
        return names[index]
    }

    func axCellLabel(_ cell: MSADistanceCell) -> String? {
        guard let matrix else { return nil }
        let names = matrix.displayNames
        guard names.indices.contains(cell.row), names.indices.contains(cell.column) else { return nil }
        return MSADistanceMatrixText.cellLabel(
            rowName: names[cell.row],
            columnName: names[cell.column],
            value: matrix.displayValues[cell.row][cell.column],
            comparableSites: matrix.displayComparableSites(row: cell.row, column: cell.column),
            isDiagonal: cell.isDiagonal
        )
    }

    public override func accessibilityRowCount() -> Int { matrix?.displayCount ?? 0 }
    public override func accessibilityColumnCount() -> Int { matrix?.displayCount ?? 0 }

    public override func accessibilityRows() -> [Any]? {
        var rows: [Any] = []
        for row in 0..<(matrix?.displayCount ?? 0) { rows.append(axRowElement(for: row)) }
        return rows
    }

    public override func accessibilityChildren() -> [Any]? {
        accessibilityRows()
    }

    public override func accessibilityVisibleRows() -> [Any]? {
        var rows: [Any] = []
        for row in visibleRows { rows.append(axRowElement(for: row)) }
        return rows
    }

    public override func accessibilityVisibleCells() -> [Any]? {
        var cells: [Any] = []
        for row in visibleRows {
            for column in visibleColumns {
                cells.append(axCellElement(for: MSADistanceCell(row: row, column: column)))
            }
        }
        return cells
    }

    public override func accessibilitySelectedCells() -> [Any]? {
        var cells: [Any] = []
        for cell in selection.cells.sorted(by: { ($0.row, $0.column) < ($1.row, $1.column) }) {
            cells.append(axCellElement(for: cell))
        }
        return cells
    }

    public override func accessibilitySelectedRows() -> [Any]? {
        var rows: [Any] = []
        for row in Set(selection.cells.map(\.row)).sorted() { rows.append(axRowElement(for: row)) }
        return rows
    }

    public override func accessibilityCell(forColumn column: Int, row: Int) -> Any? {
        let cell = MSADistanceCell(row: row, column: column)
        guard selection.contains(cell) else { return nil }
        return axCellElement(for: cell)
    }

    public override func accessibilityColumnHeaderUIElements() -> [Any]? {
        columnHeaderView?.headerElements
    }

    public override func accessibilityRowHeaderUIElements() -> [Any]? {
        rowHeaderView?.headerElements
    }

    public override func accessibilityValue() -> Any? {
        guard let count = matrix?.displayCount else { return "Not computed" }
        return "\(count) by \(count)"
    }
}
