// MSADistanceMatrixGridView.swift - Custom-drawn square distance matrix grid (rulings U4 to U9)
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import LungfishKit

/// Draws the distance matrix as square cells and owns cell selection,
/// keyboard handling and the responder actions the Edit and View menus
/// reach with a nil target. It sits in an NSScrollView. The row gutter and
/// column header are sibling views the pane keeps in step with the scroll.
@MainActor
public final class MSADistanceMatrixGridView: NSView, NSMenuItemValidation, NSViewToolTipOwner {
    // MARK: Data

    public private(set) var matrix: (any MSADistanceMatrixDisplaying)?
    public private(set) var selection = MSADistanceMatrixSelection(size: 0)
    public var colorScale = MSADistanceColorScale(lower: 0, upper: 1) {
        didSet { needsDisplay = true }
    }

    public var showsValues = true {
        didSet {
            guard showsValues != oldValue else { return }
            relayout()
        }
    }

    /// Fonts come from the shared content typography so the grid follows
    /// the app text size setting.
    public var typography: ContentTypography = ContentTypography.current() {
        didSet { relayout() }
    }

    public var pasteboard: PasteboardWriting

    // MARK: Callbacks

    /// Selection changed by the user. The pane maps display indices to records.
    public var onSelectionChanged: ((MSADistanceMatrixSelection) -> Void)?
    public var onFocusChanged: ((MSADistanceCell?) -> Void)?
    public var onReveal: ((MSADistanceCell) -> Void)?
    public var onCopyMatrix: (() -> Void)?
    public var onExport: (() -> Void)?
    /// Whether Export is available even without an on-screen matrix, as in
    /// the too-many-rows state.
    public var isExportAvailable: () -> Bool = { false }

    /// Set by the pane so the AX table can expose header elements.
    public weak var rowHeaderView: MSADistanceMatrixRowHeaderView?
    public weak var columnHeaderView: MSADistanceMatrixColumnHeaderView?

    // MARK: Geometry

    public private(set) var cellSide: CGFloat = 22
    public private(set) var valueFont = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
    static let compactCellSide: CGFloat = 12

    var axCache = MSADistanceAXCache()
    private(set) var layoutCount = 0

    public init(pasteboard: PasteboardWriting = DefaultPasteboard()) {
        self.pasteboard = pasteboard
        super.init(frame: .zero)
        clipsToBounds = true
        setAccessibilityElement(true)
        setAccessibilityRole(.table)
        setAccessibilityLabel("Distance matrix")
        relayout()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    public override var isFlipped: Bool { true }
    public override var acceptsFirstResponder: Bool { true }
    public override var canBecomeKeyView: Bool { true }
    public override var focusRingMaskBounds: NSRect { visibleRect }
    public override func drawFocusRingMask() { NSBezierPath.fill(visibleRect) }

    // MARK: Loading

    /// Shows a new matrix. Selection resets because indices change meaning.
    public func setMatrix(_ newMatrix: (any MSADistanceMatrixDisplaying)?) {
        matrix = newMatrix
        selection = MSADistanceMatrixSelection(size: newMatrix?.displayCount ?? 0)
        relayout()
        NSAccessibility.post(element: self, notification: .layoutChanged)
    }

    /// Recomputes cell size from typography and the Show Values setting.
    public func relayout() {
        let increaseContrast = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
        let base = typography.font(for: .monospaced)
        valueFont = increaseContrast
            ? NSFont.monospacedSystemFont(ofSize: base.pointSize, weight: .semibold)
            : base
        if showsValues {
            let sample = ("0.0000" as NSString).size(withAttributes: [.font: valueFont]).width
            cellSide = max(typography.tableRowHeight(), ceil(sample + 8))
        } else {
            cellSide = Self.compactCellSide
        }
        let count = CGFloat(matrix?.displayCount ?? 0)
        setFrameSize(NSSize(width: count * cellSide, height: count * cellSide))
        removeAllToolTips()
        addToolTip(bounds, owner: self, userData: nil)
        // AX frames depend on the cell size, so cached elements go.
        axCache.removeAll()
        layoutCount += 1
        needsDisplay = true
    }

    // MARK: Geometry helpers

    public func rect(for cell: MSADistanceCell) -> NSRect {
        NSRect(x: CGFloat(cell.column) * cellSide, y: CGFloat(cell.row) * cellSide, width: cellSide, height: cellSide)
    }

    public func cell(at point: NSPoint) -> MSADistanceCell? {
        guard cellSide > 0, point.x >= 0, point.y >= 0 else { return nil }
        let cell = MSADistanceCell(row: Int(point.y / cellSide), column: Int(point.x / cellSide))
        return selection.contains(cell) ? cell : nil
    }

    func indexRange(_ lower: CGFloat, _ upper: CGFloat) -> Range<Int> {
        let count = matrix?.displayCount ?? 0
        guard count > 0, cellSide > 0 else { return 0..<0 }
        let first = max(0, Int(floor(lower / cellSide)))
        let last = min(count, Int(ceil(upper / cellSide)))
        return first < last ? first..<last : 0..<0
    }

    var visibleRows: Range<Int> { indexRange(visibleRect.minY, visibleRect.maxY) }
    var visibleColumns: Range<Int> { indexRange(visibleRect.minX, visibleRect.maxX) }

    // MARK: Drawing

    public override func draw(_ dirtyRect: NSRect) {
        NSColor.textBackgroundColor.setFill()
        dirtyRect.fill()
        guard let matrix else { return }
        let appearanceKind = MSADistanceAppearance(effectiveAppearance)
        let values = matrix.displayValues
        let rows = indexRange(dirtyRect.minY, dirtyRect.maxY)
        let columns = indexRange(dirtyRect.minX, dirtyRect.maxX)
        let increaseContrast = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        let lineHeight = valueFont.ascender - valueFont.descender

        for row in rows {
            for column in columns {
                let cell = MSADistanceCell(row: row, column: column)
                let frame = rect(for: cell)
                let value = values[row][column]
                var textColor = NSColor.labelColor
                if cell.isDiagonal {
                    NSColor.quaternarySystemFill.setFill()
                    frame.fill()
                } else if value.isNaN {
                    textColor = .secondaryLabelColor
                } else if value == .infinity {
                    drawHatch(in: frame)
                } else if let fill = colorScale.fill(for: value, appearance: appearanceKind) {
                    fill.nsColor.setFill()
                    frame.fill()
                    textColor = MSADistanceColorScale.textColor(on: fill).nsColor
                }
                if increaseContrast {
                    NSColor.separatorColor.setStroke()
                    let path = NSBezierPath(rect: frame.insetBy(dx: 0.5, dy: 0.5))
                    path.lineWidth = 1
                    path.stroke()
                }
                if showsValues {
                    let text = MSADistanceValueFormat.cell(value) as NSString
                    let textRect = NSRect(
                        x: frame.minX,
                        y: frame.midY - lineHeight / 2,
                        width: frame.width,
                        height: lineHeight
                    )
                    text.draw(in: textRect, withAttributes: [
                        .font: valueFont,
                        .foregroundColor: textColor,
                        .paragraphStyle: paragraph,
                    ])
                }
            }
        }
        drawSequenceBands(rows: rows, columns: columns)
        drawSelection(increaseContrast: increaseContrast)
    }

    private func drawHatch(in frame: NSRect) {
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(rect: frame).addClip()
        let path = NSBezierPath()
        let step: CGFloat = 5
        var offset: CGFloat = -frame.height
        while offset < frame.width {
            path.move(to: NSPoint(x: frame.minX + offset, y: frame.maxY))
            path.line(to: NSPoint(x: frame.minX + offset + frame.height, y: frame.minY))
            offset += step
        }
        path.lineWidth = 1
        NSColor.tertiaryLabelColor.setStroke()
        path.stroke()
        NSGraphicsContext.restoreGraphicsState()
    }

    private func drawSequenceBands(rows: Range<Int>, columns: Range<Int>) {
        guard selection.cells.isEmpty, !selection.selectedSequences.isEmpty else { return }
        let width = frame.width
        let height = frame.height
        NSColor.selectedContentBackgroundColor.setStroke()
        for index in selection.selectedSequences {
            let rowBand = NSRect(x: 0, y: CGFloat(index) * cellSide, width: width, height: cellSide)
            let columnBand = NSRect(x: CGFloat(index) * cellSide, y: 0, width: cellSide, height: height)
            for band in [rowBand, columnBand] {
                let path = NSBezierPath(rect: band.insetBy(dx: 1, dy: 1))
                path.lineWidth = 2
                path.stroke()
            }
        }
    }

    private func drawSelection(increaseContrast: Bool) {
        let outerWidth: CGFloat = increaseContrast ? 3 : 2
        for cell in selection.cells {
            let frame = rect(for: cell)
            guard frame.intersects(visibleRect) || visibleRect.isEmpty else { continue }
            let outer = NSBezierPath(rect: frame.insetBy(dx: outerWidth / 2, dy: outerWidth / 2))
            outer.lineWidth = outerWidth
            NSColor.keyboardFocusIndicatorColor.withAlphaComponent(1).setStroke()
            outer.stroke()
            let inner = NSBezierPath(rect: frame.insetBy(dx: outerWidth + 0.5, dy: outerWidth + 0.5))
            inner.lineWidth = 1
            NSColor.white.setStroke()
            inner.stroke()
            let mirror = cell.mirror
            if !cell.isDiagonal, !selection.cells.contains(mirror) {
                let dashed = NSBezierPath(rect: rect(for: mirror).insetBy(dx: 1, dy: 1))
                dashed.lineWidth = 1.5
                dashed.setLineDash([3, 2], count: 2, phase: 0)
                NSColor.keyboardFocusIndicatorColor.withAlphaComponent(1).setStroke()
                dashed.stroke()
            }
        }
        if let focus = selection.focus, window?.firstResponder === self, !selection.cells.contains(focus) {
            let path = NSBezierPath(rect: rect(for: focus).insetBy(dx: 1, dy: 1))
            path.lineWidth = 2
            path.setLineDash([2, 2], count: 2, phase: 0)
            NSColor.labelColor.setStroke()
            path.stroke()
        }
    }

    // MARK: Selection plumbing

    /// Applies a selection change, redraws, scrolls the focus into view and
    /// tells the pane and VoiceOver.
    func updateSelection(_ change: (inout MSADistanceMatrixSelection) -> Void, notify: Bool = true) {
        let oldFocus = selection.focus
        let oldCells = selection.cells
        change(&selection)
        axSyncSelection(oldCells: oldCells, oldFocus: oldFocus)
        needsDisplay = true
        rowHeaderView?.focusedIndex = selection.focus?.row
        columnHeaderView?.focusedIndex = selection.focus?.column
        rowHeaderView?.selectedSequences = selection.cells.isEmpty ? selection.selectedSequences : IndexSet()
        columnHeaderView?.selectedSequences = selection.cells.isEmpty ? selection.selectedSequences : IndexSet()
        if let focus = selection.focus {
            scrollToVisible(rect(for: focus))
        }
        if notify { onSelectionChanged?(selection) }
        if selection.focus != oldFocus {
            onFocusChanged?(selection.focus)
            if let focus = selection.focus {
                NSAccessibility.post(element: axCellElement(for: focus), notification: .focusedUIElementChanged)
            }
        }
        NSAccessibility.post(element: self, notification: .selectedCellsChanged)
    }

    /// Reverse sync from the alignment: cells clear, headers show the band.
    public func reflectSequences(_ displayIndices: IndexSet) {
        updateSelection({ $0.reflectSequences(displayIndices) }, notify: false)
    }

    /// Header clicks, forwarded from the gutter and column header views.
    func headerClicked(_ index: Int, modifiers: NSEvent.ModifierFlags) {
        updateSelection { selection in
            if modifiers.contains(.shift) {
                selection.headerShiftClick(index)
            } else if modifiers.contains(.command) {
                selection.headerCommandClick(index)
            } else {
                selection.headerClick(index)
            }
        }
    }

    /// Reveal target: the focused cell, else the first selected cell.
    var revealTarget: MSADistanceCell? {
        if let focus = selection.focus, matrix != nil { return focus }
        return selection.cells.min { ($0.row, $0.column) < ($1.row, $1.column) }
    }

    // MARK: Mouse

    public override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        let point = convert(event.locationInWindow, from: nil)
        guard let cell = cell(at: point) else { return }
        let flags = event.modifierFlags
        if event.clickCount == 2 {
            onReveal?(cell)
            return
        }
        updateSelection { selection in
            if flags.contains(.command) && flags.contains(.shift) {
                selection.commandShiftClick(cell)
            } else if flags.contains(.command) {
                selection.commandClick(cell)
            } else if flags.contains(.shift) {
                selection.shiftClick(cell)
            } else {
                selection.click(cell)
            }
        }
    }

    public override func menu(for event: NSEvent) -> NSMenu? {
        let point = convert(event.locationInWindow, from: nil)
        if let cell = cell(at: point), !selection.cells.contains(cell) {
            updateSelection { $0.click(cell) }
        }
        return contextMenu()
    }

    /// The cell context menu. Every item has a menu-bar twin with a nil
    /// target and an AX custom action on the cell.
    public func contextMenu() -> NSMenu {
        let menu = NSMenu(title: "Distance Matrix")
        let reveal = NSMenuItem(title: "Reveal Pair in Alignment", action: #selector(revealPairInAlignment(_:)), keyEquivalent: "\r")
        reveal.keyEquivalentModifierMask = []
        menu.addItem(reveal)
        menu.addItem(NSMenuItem(title: "Copy", action: #selector(copy(_:)), keyEquivalent: "c"))
        menu.addItem(NSMenuItem(title: "Copy Matrix", action: #selector(copyMatrix(_:)), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Export Matrix as TSV…", action: #selector(exportDistanceMatrix(_:)), keyEquivalent: ""))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Select Row's Sequences", action: #selector(selectRowSequences(_:)), keyEquivalent: ""))
        for item in menu.items { item.target = self }
        return menu
    }

    // MARK: Keyboard

    public override func keyDown(with event: NSEvent) {
        guard matrix != nil else {
            super.keyDown(with: event)
            return
        }
        let flags = event.modifierFlags
        let extend = flags.contains(.shift)
        let focusOnly = flags.contains(.option)
        let toEdge = flags.contains(.command)
        let pageRows = max(1, Int(visibleRect.height / max(cellSide, 1)) - 1)
        if let special = event.specialKey {
            switch special {
            case .upArrow: return updateSelection { $0.move(.up, extend: extend, focusOnly: focusOnly, toEdge: toEdge) }
            case .downArrow: return updateSelection { $0.move(.down, extend: extend, focusOnly: focusOnly, toEdge: toEdge) }
            case .leftArrow: return updateSelection { $0.move(.left, extend: extend, focusOnly: focusOnly, toEdge: toEdge) }
            case .rightArrow: return updateSelection { $0.move(.right, extend: extend, focusOnly: focusOnly, toEdge: toEdge) }
            case .pageUp: return updateSelection { $0.page(.up, rows: pageRows, extend: extend) }
            case .pageDown: return updateSelection { $0.page(.down, rows: pageRows, extend: extend) }
            case .home: return updateSelection { $0.home(extend: extend) }
            case .end: return updateSelection { $0.end(extend: extend) }
            case .carriageReturn, .enter:
                revealPairInAlignment(nil)
                return
            default: break
            }
        }
        if event.charactersIgnoringModifiers == " " && flags.intersection([.command, .control, .option]).isEmpty {
            updateSelection { $0.toggleFocused() }
            return
        }
        if event.keyCode == 53 {
            cancelOperation(nil)
            return
        }
        super.keyDown(with: event)
    }

    public override func cancelOperation(_ sender: Any?) {
        updateSelection { $0.clear() }
    }

    public override func becomeFirstResponder() -> Bool {
        needsDisplay = true
        return super.becomeFirstResponder()
    }

    public override func resignFirstResponder() -> Bool {
        needsDisplay = true
        return super.resignFirstResponder()
    }

    // MARK: Responder actions

    @objc public func copy(_ sender: Any?) {
        guard let matrix, let text = MSADistanceMatrixClipboard.tsv(for: selection, in: matrix) else { return }
        pasteboard.setString(text)
    }

    @objc public override func selectAll(_ sender: Any?) {
        updateSelection { $0.selectAll() }
    }

    @objc public func revealPairInAlignment(_ sender: Any?) {
        guard let target = revealTarget else { return }
        onReveal?(target)
    }

    @objc public func copyMatrix(_ sender: Any?) {
        guard matrix != nil else { return }
        onCopyMatrix?()
    }

    @objc public func exportDistanceMatrix(_ sender: Any?) {
        guard matrix != nil || isExportAvailable() else { return }
        onExport?()
    }

    @objc public func selectRowSequences(_ sender: Any?) {
        guard let target = revealTarget else { return }
        headerClicked(target.row, modifiers: [])
    }

    public func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(copy(_:)):
            guard let matrix else { return false }
            return MSADistanceMatrixClipboard.tsv(for: selection, in: matrix) != nil
        case #selector(selectAll(_:)):
            return (matrix?.displayCount ?? 0) > 0
        case #selector(revealPairInAlignment(_:)), #selector(selectRowSequences(_:)):
            return revealTarget != nil
        case #selector(copyMatrix(_:)):
            return matrix != nil
        case #selector(exportDistanceMatrix(_:)):
            return matrix != nil || isExportAvailable()
        default:
            return true
        }
    }

    // MARK: Appearance changes

    public override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil else { return }
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(accessibilityDisplayOptionsChanged(_:)),
            name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
            object: nil
        )
    }

    @objc private func accessibilityDisplayOptionsChanged(_ notification: Notification) {
        relayout()
    }

    /// Help tag with the full cell description, so the 4-decimal drawing
    /// and truncated names never hide data.
    public func view(
        _ view: NSView,
        stringForToolTip tag: NSView.ToolTipTag,
        point: NSPoint,
        userData data: UnsafeMutableRawPointer?
    ) -> String {
        guard let cell = cell(at: point) else { return "" }
        return axCellLabel(cell) ?? ""
    }

    isolated deinit {
        NSWorkspace.shared.notificationCenter.removeObserver(self)
    }
}
