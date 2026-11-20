// RNASeqEmbeddingLegend.swift - The legend of the embedding view, its rows from the file (Phase 5.5 lane CM-VIEW)
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Every count and bound in the legend is a value of `cellmap.sqlite` as stored (5.5 L3). The legend counts nothing:
// a label's count is `labels.cells`, a sample's is `samples.cells`, a flag's is `flag_counts.cells` for each sample,
// and a scale's bounds are those of `value_bounds`. VoiceOver reads the plot as a group with one child for each row
// (5.5 V2), never one for each cell.

import AppKit
import LungfishIO

/// What the legend shows for one colouring.
public struct RNASeqEmbeddingLegend: Equatable, Sendable {
    /// One value of a category colouring, with its swatch's palette index and its count as the file holds it.
    public struct Row: Equatable, Sendable {
        public var name: String
        public var count: String
        public var colour: UInt16
    }

    /// The bounds of a continuous colouring as stored, and the top of the scale, the p99 or, when the p99 is 0, the
    /// maximum (5.5 L3).
    public struct Scale: Equatable, Sendable {
        public var minimum: Double
        public var maximum: Double
        public var p99: Double
        public var top: Double { p99 > 0 ? p99 : maximum }
    }

    public var title: String
    public var rows: [Row]
    public var scale: Scale?
    /// The lines under the rows or the scale, such as "Colours repeat after 19 labels".
    public var words: [String]
    /// The formula of a normalised scale as the file records it, nil when the colour is a count (5.5 G1).
    public var formula: String?

    public init(title: String, rows: [Row], scale: Scale? = nil, words: [String] = [], formula: String? = nil) {
        self.title = title
        self.rows = rows
        self.scale = scale
        self.words = words
        self.formula = formula
    }
}

/// The legend on screen: a title, one row a value with its swatch, name and count, or the scale bar with its bounds,
/// then the legend's words. Each text can be selected and copied.
@MainActor
public final class RNASeqEmbeddingLegendView: NSStackView {
    public static let accessibilityID = "rnaseq-cell-map-legend"
    public private(set) var legend: RNASeqEmbeddingLegend?
    /// The view of each row, in order, whose frames VoiceOver's children take.
    public private(set) var rowViews: [NSView] = []
    /// A click on a row with whether Command was held, which selects the row's cells or adds them (CM-SELECT-APP).
    public var onRowClick: ((Int, Bool) -> Void)?
    /// Space on the focused row, which toggles its cells.
    public var onRowToggle: ((Int) -> Void)?
    /// The row the keyboard is on. The legend takes focus, and the arrows move it.
    public private(set) var focusedRow: Int?
    /// The rows whose cells are selected, which show their names in bold.
    public private(set) var markedRows: Set<Int> = []

    public override init(frame: NSRect) {
        super.init(frame: frame)
        orientation = .vertical
        alignment = .leading
        spacing = 4
        setAccessibilityIdentifier(Self.accessibilityID)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    public func show(_ legend: RNASeqEmbeddingLegend, palette: [UInt32]) {
        self.legend = legend
        for view in arrangedSubviews {
            removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        rowViews = []
        let title = NSTextField(labelWithString: legend.title)
        title.font = .boldSystemFont(ofSize: NSFont.systemFontSize)
        title.setAccessibilityIdentifier("rnaseq-cell-map-legend-title")
        addArrangedSubview(title)
        for (index, row) in legend.rows.enumerated() {
            let swatch = NSView(frame: NSRect(x: 0, y: 0, width: 12, height: 12))
            swatch.wantsLayer = true
            swatch.layer?.backgroundColor = Self.colour(palette[Int(row.colour)])
            swatch.layer?.cornerRadius = 6
            swatch.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([swatch.widthAnchor.constraint(equalToConstant: 12), swatch.heightAnchor.constraint(equalToConstant: 12)])
            let name = Self.text(row.name, id: "rnaseq-cell-map-legend-\(index)-name")
            let count = Self.text(row.count, id: "rnaseq-cell-map-legend-\(index)-count")
            count.textColor = .secondaryLabelColor
            let line = NSStackView(views: [swatch, name, count])
            line.orientation = .horizontal
            line.alignment = .centerY
            line.spacing = 6
            line.setAccessibilityIdentifier("rnaseq-cell-map-legend-\(index)")
            line.wantsLayer = true
            line.addGestureRecognizer(NSClickGestureRecognizer(target: self, action: #selector(rowClicked(_:))))
            addArrangedSubview(line)
            rowViews.append(line)
        }
        markedRows = []
        focusedRow = legend.rows.isEmpty ? nil : min(focusedRow ?? 0, legend.rows.count - 1)
        showFocus()
        if let scale = legend.scale {
            let bar = RNASeqEmbeddingScaleBar(palette: palette)
            bar.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([bar.widthAnchor.constraint(equalToConstant: 200), bar.heightAnchor.constraint(equalToConstant: 12)])
            addArrangedSubview(bar)
            let ends = NSStackView(views: [
                Self.text("0", id: "rnaseq-cell-map-scale-low"),
                Self.text(RNASeqEmbeddingWords.number(scale.top), id: "rnaseq-cell-map-scale-top"),
            ])
            ends.orientation = .horizontal
            ends.distribution = .equalSpacing
            ends.translatesAutoresizingMaskIntoConstraints = false
            ends.widthAnchor.constraint(equalToConstant: 200).isActive = true
            addArrangedSubview(ends)
            if let formula = legend.formula {
                let line = NSTextField(wrappingLabelWithString: RNASeqEmbeddingWords.normalisedFormula(formula))
                line.isSelectable = true
                line.preferredMaxLayoutWidth = 260
                line.setAccessibilityIdentifier("rnaseq-cell-map-legend-formula")
                addArrangedSubview(line)
            }
        }
        for (index, words) in legend.words.enumerated() {
            let field = NSTextField(wrappingLabelWithString: words)
            field.isSelectable = true
            field.preferredMaxLayoutWidth = 260
            field.setAccessibilityIdentifier("rnaseq-cell-map-legend-words-\(index)")
            addArrangedSubview(field)
        }
    }

    /// Shows which rows are selected, their names in bold.
    public func mark(_ rows: Set<Int>) {
        markedRows = rows
        for (index, line) in rowViews.enumerated() {
            guard let name = (line as? NSStackView)?.arrangedSubviews.dropFirst().first as? NSTextField else { continue }
            name.font = rows.contains(index) ? .boldSystemFont(ofSize: NSFont.systemFontSize) : .systemFont(ofSize: NSFont.systemFontSize)
            line.setAccessibilitySelected(rows.contains(index))
        }
    }

    public override var acceptsFirstResponder: Bool { !rowViews.isEmpty }

    public override func becomeFirstResponder() -> Bool {
        defer { showFocus() }
        return super.becomeFirstResponder()
    }

    public override func resignFirstResponder() -> Bool {
        defer { showFocus() }
        return super.resignFirstResponder()
    }

    /// Called when Escape is pressed with the legend focused. The controller empties the selection (CM-SELECT-APP).
    public var onEscape: (() -> Void)?

    /// Space toggles the focused row, Escape (key code 53) empties the selection, and the up and down arrows move the focus.
    public override func keyDown(with event: NSEvent) {
        guard !rowViews.isEmpty else { return super.keyDown(with: event) }
        switch event.keyCode {
        case 49: onRowToggle?(focusedRow ?? 0)
        case 53: onEscape?()
        case 125: moveFocus(by: 1)
        case 126: moveFocus(by: -1)
        default: super.keyDown(with: event)
        }
    }

    public func moveFocus(by step: Int) {
        guard !rowViews.isEmpty else { return }
        focusedRow = min(max((focusedRow ?? 0) + step, 0), rowViews.count - 1)
        showFocus()
    }

    @objc private func rowClicked(_ recognizer: NSClickGestureRecognizer) {
        guard let line = recognizer.view, let row = rowViews.firstIndex(where: { $0 === line }) else { return }
        focusedRow = row
        window?.makeFirstResponder(self)
        showFocus()
        onRowClick?(row, NSApp.currentEvent?.modifierFlags.contains(.command) ?? false)
    }

    /// A ring around the focused row while the legend has the keyboard.
    private func showFocus() {
        let focused = window?.firstResponder === self
        for (index, line) in rowViews.enumerated() {
            line.layer?.borderWidth = focused && index == focusedRow ? 2 : 0
            line.layer?.borderColor = NSColor.keyboardFocusIndicatorColor.cgColor
            line.layer?.cornerRadius = 4
        }
    }

    static func colour(_ word: UInt32) -> CGColor {
        CGColor(srgbRed: CGFloat(word & 0xFF) / 255, green: CGFloat(word >> 8 & 0xFF) / 255,
                blue: CGFloat(word >> 16 & 0xFF) / 255, alpha: CGFloat(word >> 24 & 0xFF) / 255)
    }

    private static func text(_ string: String, id: String) -> NSTextField {
        let field = NSTextField(labelWithString: string)
        field.isSelectable = true
        field.setAccessibilityIdentifier(id)
        return field
    }
}

/// The continuous scale drawn from the palette's 256 steps, low on the left.
@MainActor
final class RNASeqEmbeddingScaleBar: NSView {
    private let palette: [UInt32]

    init(palette: [UInt32]) {
        self.palette = palette
        super.init(frame: .zero)
        setAccessibilityElement(false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        let steps = RNASeqEmbeddingPalette.gradientSteps
        let width = bounds.width / CGFloat(steps)
        for step in 0..<steps {
            context.setFillColor(RNASeqEmbeddingLegendView.colour(palette[Int(RNASeqEmbeddingPalette.gradientBase) + step]))
            context.fill(CGRect(x: CGFloat(step) * width, y: 0, width: width + 0.5, height: bounds.height))
        }
    }
}
