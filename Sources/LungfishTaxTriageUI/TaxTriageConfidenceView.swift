// TaxTriageConfidenceView.swift - CoreGraphics horizontal bar chart for TASS confidence scores
// Copyright (c) 2025 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import LungfishIO
import LungfishKit

// MARK: - TaxTriageConfidenceView

/// A CoreGraphics horizontal bar chart showing TASS confidence scores per organism.
///
/// Each organism is displayed as a labeled horizontal bar whose length is proportional
/// to the TASS score (0 to 1). Bars are color-coded by confidence tier:
///
/// | Score Range | Color  | Meaning                |
/// |-------------|--------|------------------------|
/// | >= 0.8      | Green  | High confidence        |
/// | 0.4 -- 0.8  | Yellow | Moderate confidence    |
/// | < 0.4       | Red    | Low confidence         |
///
/// ## Layout
///
/// ```
/// Organism Name  [==========  0.95 ]
/// Organism Name  [======      0.62 ]
/// Organism Name  [===         0.31 ]
/// ```
///
/// ## Usage
///
/// Used both as a standalone detail view and as the confidence column cell
/// in ``TaxTriageOrganismTableView``.
///
/// ## Thread Safety
///
/// `@MainActor` isolated. All drawing occurs in `draw(_:)`.
@MainActor
final class TaxTriageConfidenceView: NSView {

    // MARK: - Data

    /// The metrics to render, sorted by TASS score descending.
    var metrics: [TaxTriageMetric] = [] {
        didSet { needsDisplay = true }
    }

    /// Maximum number of organisms to display (0 = unlimited).
    var maxVisible: Int = 0

    // MARK: - Layout Constants

    /// Height of each bar row.
    private let rowHeight: CGFloat = 22

    /// Horizontal padding on each side.
    private let horizontalPadding: CGFloat = 8

    /// Width allocated for the organism name label.
    private let labelWidth: CGFloat = 160

    /// Width allocated for the score value label.
    private let scoreWidth: CGFloat = 40

    /// Vertical padding between rows.
    private let rowSpacing: CGFloat = 2

    /// Corner radius for bar rectangles.
    private let barCornerRadius: CGFloat = 3

    // MARK: - Rendering

    override var isFlipped: Bool { true }

    /// The intrinsic content height based on the number of visible metrics.
    override var intrinsicContentSize: NSSize {
        let count = visibleMetrics.count
        let height = CGFloat(count) * (rowHeight + rowSpacing) + 8
        return NSSize(width: NSView.noIntrinsicMetric, height: max(height, 30))
    }

    /// The subset of metrics actually rendered.
    private var visibleMetrics: [TaxTriageMetric] {
        let sorted = metrics.sorted { $0.tassScore > $1.tassScore }
        if maxVisible > 0 {
            return Array(sorted.prefix(maxVisible))
        }
        return sorted
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }

        let items = visibleMetrics
        guard !items.isEmpty else {
            drawPlaceholder(ctx)
            return
        }

        let barAreaWidth = bounds.width - horizontalPadding * 2 - labelWidth - scoreWidth - 8

        for (index, metric) in items.enumerated() {
            let y = CGFloat(index) * (rowHeight + rowSpacing) + 4

            // Organism name (left)
            let nameAttrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 11, weight: .regular),
                .foregroundColor: NSColor.labelColor,
            ]
            let nameStr = NSAttributedString(string: metric.organism, attributes: nameAttrs)
            let nameRect = CGRect(
                x: horizontalPadding,
                y: y + 3,
                width: labelWidth,
                height: rowHeight - 6
            )
            ctx.saveGState()
            ctx.clip(to: nameRect)
            nameStr.draw(at: CGPoint(x: nameRect.minX, y: nameRect.minY))
            ctx.restoreGState()

            // Bar
            let barX = horizontalPadding + labelWidth + 4
            let clampedScore = min(max(metric.tassScore, 0), 1)
            let barWidth = max(barAreaWidth * clampedScore, 2)
            let barRect = CGRect(
                x: barX,
                y: y + 3,
                width: barWidth,
                height: rowHeight - 6
            )

            let barColor = confidenceColor(for: clampedScore)
            ctx.setFillColor(barColor.cgColor)
            let barPath = CGPath(
                roundedRect: barRect,
                cornerWidth: barCornerRadius,
                cornerHeight: barCornerRadius,
                transform: nil
            )
            ctx.addPath(barPath)
            ctx.fillPath()

            // Bar background (track)
            let trackRect = CGRect(
                x: barX,
                y: y + 3,
                width: barAreaWidth,
                height: rowHeight - 6
            )
            ctx.setStrokeColor(NSColor.separatorColor.cgColor)
            ctx.setLineWidth(0.5)
            let trackPath = CGPath(
                roundedRect: trackRect,
                cornerWidth: barCornerRadius,
                cornerHeight: barCornerRadius,
                transform: nil
            )
            ctx.addPath(trackPath)
            ctx.strokePath()

            // Score value (right)
            let scoreAttrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium),
                .foregroundColor: NSColor.secondaryLabelColor,
            ]
            let scoreText = String(format: "%.2f", clampedScore)
            let scoreStr = NSAttributedString(string: scoreText, attributes: scoreAttrs)
            let scoreX = bounds.width - horizontalPadding - scoreWidth
            scoreStr.draw(at: CGPoint(x: scoreX, y: y + 3))
        }
    }

    // MARK: - Colors

    /// Returns the bar color for a given TASS score.
    ///
    /// - Parameter score: The TASS confidence score (0.0 to 1.0).
    /// - Returns: Green for >= 0.8, yellow for 0.4--0.8, red for < 0.4.
    static func confidenceColor(for score: Double) -> NSColor {
        if score >= 0.8 {
            return .systemGreen
        } else if score >= 0.4 {
            return .systemYellow
        } else {
            return .lungfishDanger
        }
    }

    /// Instance method forwarding to the static version.
    private func confidenceColor(for score: Double) -> NSColor {
        Self.confidenceColor(for: score)
    }

    // MARK: - Placeholder

    private func drawPlaceholder(_ ctx: CGContext) {
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12, weight: .regular),
            .foregroundColor: NSColor.tertiaryLabelColor,
        ]
        let str = NSAttributedString(string: "No confidence data", attributes: attrs)
        let size = str.size()
        let x = (bounds.width - size.width) / 2
        let y = (bounds.height - size.height) / 2
        str.draw(at: CGPoint(x: x, y: y))
    }
}

// MARK: - TaxTriageConfidenceCellView

/// A compact single-bar confidence indicator for use in an NSTableView cell.
///
/// Renders a single horizontal bar with color coding, suitable for embedding
/// in a table column. Set ``score`` to update.
@MainActor
final class TaxTriageConfidenceCellView: NSView {

    /// The TASS confidence score to display (0.0 to 1.0).
    var score: Double = 0 {
        didSet { needsDisplay = true }
    }

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }

        let inset: CGFloat = 2
        let trackRect = bounds.insetBy(dx: inset, dy: 4)

        // Track background
        ctx.setFillColor(NSColor.controlBackgroundColor.withAlphaComponent(0.4).cgColor)
        let trackPath = CGPath(
            roundedRect: trackRect,
            cornerWidth: 2,
            cornerHeight: 2,
            transform: nil
        )
        ctx.addPath(trackPath)
        ctx.fillPath()

        // Filled bar
        let clampedScore = min(max(score, 0), 1)
        let barWidth = max(trackRect.width * clampedScore, 1)
        let barRect = CGRect(
            x: trackRect.minX,
            y: trackRect.minY,
            width: barWidth,
            height: trackRect.height
        )
        let barColor = TaxTriageConfidenceView.confidenceColor(for: clampedScore)
        ctx.setFillColor(barColor.cgColor)
        let barPath = CGPath(
            roundedRect: barRect,
            cornerWidth: 2,
            cornerHeight: 2,
            transform: nil
        )
        ctx.addPath(barPath)
        ctx.fillPath()

        // Track border
        ctx.setStrokeColor(NSColor.separatorColor.cgColor)
        ctx.setLineWidth(0.5)
        ctx.addPath(trackPath)
        ctx.strokePath()
    }
}
