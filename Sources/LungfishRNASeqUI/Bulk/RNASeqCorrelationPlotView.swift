// RNASeqCorrelationPlotView.swift - The sample correlation plot of a bulk RNA-seq result (Phase 5.4 lane RS-BULK-VIEW M2)
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Samples by samples, one square a cell of the correlation table that `lungfish-cli rnaseq quality --table correlation`
// prints. The shade only orders the cells from the table's lowest value to 1, and every cell reads as the CLI's text,
// by the arrow keys, by the pointer and through VoiceOver.

import AppKit
import LungfishWorkflow

@MainActor
public final class RNASeqCorrelationPlotView: NSView {
    public static let accessibilityID = "rnaseq-bulk-correlation-plot"

    public private(set) var samples: [String] = []
    /// The CLI's text of each cell, samples by samples.
    public private(set) var cells: [[String]] = []
    /// The cell that the keys and the pointer chose, row then column.
    public private(set) var selected: (row: Int, column: Int)?
    /// The words of the chosen cell, given each time the choice moves.
    public var onSelect: (@MainActor (String) -> Void)?

    private var values: [[Double?]] = []
    private var lowest: Double = 1
    private var elements: [NSAccessibilityElement] = []

    public override var isFlipped: Bool { true }
    public override var acceptsFirstResponder: Bool { true }

    public override init(frame: NSRect) {
        super.init(frame: frame)
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityIdentifier(Self.accessibilityID)
        setAccessibilityLabel("Sample correlation plot")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// Shows the table. `cells` is the CLI's text of each value and `caption` names the measure.
    public func show(_ correlation: RNASeqSampleCorrelation, cells: [[String]], caption: String) {
        samples = correlation.samples
        values = correlation.values
        self.cells = cells
        let offDiagonal = values.enumerated().flatMap { i, row in row.enumerated().compactMap { j, r in i == j ? nil : r } }
        lowest = offDiagonal.min() ?? 1
        elements = []
        selected = nil
        setAccessibilityLabel(caption)
        setAccessibilityValue(nil)
        needsDisplay = true
    }

    /// The words of a cell, the two samples and the CLI's text of their value.
    public func cellDescription(row: Int, column: Int) -> String {
        "\(samples[row]) and \(samples[column]): \(cells[row][column])"
    }

    /// The text of the table's lowest value, where the shade starts, as the CLI printed it.
    public var lowestText: String? {
        for (i, row) in values.enumerated() {
            for (j, r) in row.enumerated() where i != j && r == lowest { return cells[i][j] }
        }
        return nil
    }

    public func select(row: Int, column: Int) {
        guard !samples.isEmpty else { return }
        let r = min(max(row, 0), samples.count - 1)
        let c = min(max(column, 0), samples.count - 1)
        selected = (r, c)
        let words = cellDescription(row: r, column: c)
        setAccessibilityValue(words)
        NSAccessibility.post(element: self, notification: .valueChanged)
        onSelect?(words)
        needsDisplay = true
    }

    // MARK: - Keys and pointer

    public override func keyDown(with event: NSEvent) {
        guard !samples.isEmpty else { return super.keyDown(with: event) }
        let (row, column) = selected ?? (0, 0)
        switch event.specialKey {
        case .leftArrow?: select(row: row, column: selected == nil ? 0 : column - 1)
        case .rightArrow?: select(row: row, column: selected == nil ? 0 : column + 1)
        case .upArrow?: select(row: selected == nil ? 0 : row - 1, column: column)
        case .downArrow?: select(row: selected == nil ? 0 : row + 1, column: column)
        default: super.keyDown(with: event)
        }
    }

    public override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        let point = convert(event.locationInWindow, from: nil)
        let side = cellSide
        guard side > 0, point.x >= 0, point.y >= 0 else { return }
        let row = Int(point.y / side)
        let column = Int(point.x / side)
        if row < samples.count, column < samples.count { select(row: row, column: column) }
    }

    // MARK: - Drawing

    private var cellSide: CGFloat {
        samples.isEmpty ? 0 : floor(min(bounds.width, bounds.height) / CGFloat(samples.count) * 100) / 100
    }

    public func cellRect(row: Int, column: Int) -> NSRect {
        let side = cellSide
        return NSRect(x: CGFloat(column) * side, y: CGFloat(row) * side, width: side, height: side)
    }

    public override func draw(_ dirtyRect: NSRect) {
        NSColor.textBackgroundColor.setFill()
        bounds.fill()
        for (i, row) in values.enumerated() {
            for (j, r) in row.enumerated() {
                let rect = cellRect(row: i, column: j)
                guard rect.intersects(dirtyRect) else { continue }
                shade(r).setFill()
                rect.fill()
            }
        }
        if let selected {
            NSColor.keyboardFocusIndicatorColor.setStroke()
            let ring = NSBezierPath(rect: cellRect(row: selected.row, column: selected.column).insetBy(dx: 1, dy: 1))
            ring.lineWidth = 2
            ring.stroke()
        }
    }

    /// A cell with no value is grey, and a value is darker the nearer it is to 1 on the scale from the lowest value.
    private func shade(_ r: Double?) -> NSColor {
        guard let r else { return NSColor.quaternaryLabelColor }
        let fraction = lowest < 1 ? CGFloat((r - lowest) / (1 - lowest)) : 1
        return NSColor.systemBlue.withAlphaComponent(0.15 + 0.85 * min(max(fraction, 0), 1))
    }

    // MARK: - VoiceOver

    public override func accessibilityChildren() -> [Any]? {
        if elements.count != samples.count * samples.count {
            elements = samples.indices.flatMap { i in
                samples.indices.map { j -> NSAccessibilityElement in
                    let element = NSAccessibilityElement()
                    element.setAccessibilityRole(.staticText)
                    element.setAccessibilityLabel("\(samples[i]) and \(samples[j])")
                    element.setAccessibilityValue(cells[i][j])
                    element.setAccessibilityParent(self)
                    element.setAccessibilityFrameInParentSpace(cellRect(row: i, column: j))
                    return element
                }
            }
        }
        return elements
    }
}
