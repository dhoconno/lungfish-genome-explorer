// MSADistanceMatrixGridView+Accessibility.swift - AXTable with lazy virtual rows and cells (ruling U4)
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit

/// Lazily created AX row and cell elements, dropped when the matrix changes.
@MainActor
struct MSADistanceAXCache {
    var rows: [Int: MSADistanceAXRowElement] = [:]
    var cells: [MSADistanceCell: MSADistanceAXCellElement] = [:]

    mutating func removeAll() {
        rows.removeAll()
        cells.removeAll()
    }
}

/// Runs AX work on the main actor. AppKit declares the NSAccessibilityElement
/// getters outside the main actor although it always calls them on the main
/// thread, so results cross back through an unchecked local.
func axOnMain<T>(_ body: @MainActor () -> T) -> T {
    nonisolated(unsafe) var result: T?
    MainActor.assumeIsolated { result = body() }
    return result!
}

/// A virtual AX row of the grid.
final class MSADistanceAXRowElement: NSAccessibilityElement {
    nonisolated(unsafe) weak var grid: MSADistanceMatrixGridView?
    let index: Int

    @MainActor
    init(grid: MSADistanceMatrixGridView, index: Int) {
        self.grid = grid
        self.index = index
        super.init()
        setAccessibilityRole(.row)
        setAccessibilityParent(grid)
        setAccessibilityIndex(index)
    }

    override func accessibilityLabel() -> String? {
        let grid = self.grid, index = self.index
        return axOnMain { grid?.axRowLabel(index) }
    }

    override func accessibilityChildren() -> [Any]? {
        let grid = self.grid, index = self.index
        return axOnMain { grid?.axCells(inRow: index) ?? [] }
    }

    override func accessibilityFrame() -> NSRect {
        let grid = self.grid, index = self.index
        return axOnMain { grid?.axRowFrame(index) ?? .zero }
    }

    override func isAccessibilitySelected() -> Bool {
        let grid = self.grid, index = self.index
        return axOnMain { grid?.selection.cells.contains { $0.row == index } ?? false }
    }
}

/// A virtual AX cell of the grid.
final class MSADistanceAXCellElement: NSAccessibilityElement {
    nonisolated(unsafe) weak var grid: MSADistanceMatrixGridView?
    let cell: MSADistanceCell

    @MainActor
    init(grid: MSADistanceMatrixGridView, cell: MSADistanceCell) {
        self.grid = grid
        self.cell = cell
        super.init()
        setAccessibilityRole(.cell)
        setAccessibilityRowIndexRange(NSRange(location: cell.row, length: 1))
        setAccessibilityColumnIndexRange(NSRange(location: cell.column, length: 1))
        setAccessibilityHelp(MSADistanceMatrixText.cellHelp)
    }

    override func accessibilityParent() -> Any? {
        let grid = self.grid, row = cell.row
        return axOnMain { grid?.axRowElement(for: row) }
    }

    override func accessibilityLabel() -> String? {
        let grid = self.grid, cell = self.cell
        return axOnMain { grid?.axCellLabel(cell) }
    }

    override func accessibilityFrame() -> NSRect {
        let grid = self.grid, cell = self.cell
        return axOnMain { grid.map { NSAccessibility.screenRect(fromView: $0, rect: $0.rect(for: cell)) } ?? .zero }
    }

    override func isAccessibilitySelected() -> Bool {
        let grid = self.grid, cell = self.cell
        return axOnMain { grid?.selection.cells.contains(cell) ?? false }
    }

    override func setAccessibilitySelected(_ selected: Bool) {
        let grid = self.grid, cell = self.cell
        axOnMain {
            guard let grid, grid.selection.cells.contains(cell) != selected else { return }
            grid.axToggle(cell)
        }
    }

    override func isAccessibilityFocused() -> Bool {
        let grid = self.grid, cell = self.cell
        return axOnMain { grid?.selection.focus == cell }
    }

    override func accessibilityPerformPress() -> Bool {
        let grid = self.grid, cell = self.cell
        return axOnMain {
            guard let grid else { return false }
            grid.axSelectOnly(cell)
            return true
        }
    }

    override func accessibilityCustomActions() -> [NSAccessibilityCustomAction]? {
        let grid = self.grid, cell = self.cell
        return axOnMain { grid?.axCustomActions(for: cell) }
    }
}

extension MSADistanceMatrixGridView {
    func axCells(inRow row: Int) -> [Any] {
        var cells: [Any] = []
        for column in 0..<(matrix?.displayCount ?? 0) {
            cells.append(axCellElement(for: MSADistanceCell(row: row, column: column)))
        }
        return cells
    }

    func axRowLabel(_ index: Int) -> String? {
        guard let names = matrix?.displayNames, names.indices.contains(index) else { return nil }
        return names[index]
    }

    func axRowFrame(_ index: Int) -> NSRect {
        let rect = NSRect(x: 0, y: CGFloat(index) * cellSide, width: bounds.width, height: cellSide)
        return NSAccessibility.screenRect(fromView: self, rect: rect)
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

    /// The cell context menu as AX custom actions, in the same order.
    func axCustomActions(for cell: MSADistanceCell) -> [NSAccessibilityCustomAction] {
        guard matrix != nil else { return [] }
        let entries: [(String, @MainActor (MSADistanceMatrixGridView) -> Void)] = [
            ("Reveal Pair in Alignment", { $0.revealPairInAlignment(nil) }),
            ("Copy", { $0.copy(nil) }),
            ("Copy Matrix", { $0.copyMatrix(nil) }),
            ("Export Matrix as TSV…", { $0.exportDistanceMatrix(nil) }),
            ("Select Row's Sequences", { $0.selectRowSequences(nil) }),
        ]
        var actions: [NSAccessibilityCustomAction] = []
        for (name, body) in entries {
            actions.append(NSAccessibilityCustomAction(name: name) { [weak self] in
                guard let self else { return false }
                return MainActor.assumeIsolated {
                    if !self.selection.cells.contains(cell) { self.axSelectOnly(cell) }
                    body(self)
                    return true
                }
            })
        }
        return actions
    }

    func axToggle(_ cell: MSADistanceCell) {
        updateSelection { $0.commandClick(cell) }
    }

    func axSelectOnly(_ cell: MSADistanceCell) {
        updateSelection { $0.click(cell) }
    }

    func axRowElement(for row: Int) -> MSADistanceAXRowElement {
        if let cached = axCache.rows[row] { return cached }
        let element = MSADistanceAXRowElement(grid: self, index: row)
        axCache.rows[row] = element
        return element
    }

    func axCellElement(for cell: MSADistanceCell) -> MSADistanceAXCellElement {
        if let cached = axCache.cells[cell] { return cached }
        let element = MSADistanceAXCellElement(grid: self, cell: cell)
        axCache.cells[cell] = element
        return element
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
