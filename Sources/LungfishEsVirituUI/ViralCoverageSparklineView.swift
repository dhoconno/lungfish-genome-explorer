// ViralCoverageSparklineView.swift - CoreGraphics sparkline for viral genome coverage
// Copyright (c) 2025 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import LungfishIO

// MARK: - ViralCoverageSparklineView

/// A small area-chart sparkline view that renders genome coverage depth across
/// a viral contig.
///
/// Designed to fit inside an `NSTableCellView` at approximately 200x20 points.
/// The X axis maps to genome position (window start to window end) and the
/// Y axis maps to average coverage depth. The area fill uses a phylum-based
/// color from ``PhylumPalette`` for visual consistency with the sunburst chart.
///
/// ## Rendering
///
/// Coverage windows are rendered as a filled polygon. The path starts at the
/// bottom-left corner, traces the coverage values left-to-right, then returns
/// along the bottom edge to close the shape. A 0.5pt stroke outlines the top
/// edge for clarity at small sizes.
///
/// ## Performance
///
/// The view caches nothing -- it redraws on every `draw(_:)` call. Since the
/// view is small (table cell sized) and the window count is typically <100,
/// drawing is sub-millisecond.
///
/// ## Usage
///
/// ```swift
/// let sparkline = ViralCoverageSparklineView()
/// sparkline.windows = coverageWindows.filter { $0.accession == contig.accession }
/// sparkline.fillColor = PhylumPalette.phylumColor(index: 4)
/// ```
@MainActor
public final class ViralCoverageSparklineView: NSView {

    // MARK: - Data

    /// Coverage windows to render, sorted by ``ViralCoverageWindow/windowStart``.
    ///
    /// Setting this property triggers a redraw.
    public var windows: [ViralCoverageWindow] = [] {
        didSet { needsDisplay = true }
    }

    /// Fill color for the area chart. Defaults to the system accent color.
    public var fillColor: NSColor = .controlAccentColor {
        didSet { needsDisplay = true }
    }

    /// Stroke color for the top edge of the sparkline.
    ///
    /// Defaults to a slightly darker variant of ``fillColor``. When `nil`,
    /// the stroke uses ``fillColor`` at 80% opacity.
    public var strokeColor: NSColor? {
        didSet { needsDisplay = true }
    }

    // MARK: - Drawing

    public override var isFlipped: Bool { true }

    public override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext,
              !windows.isEmpty else { return }

        let sorted = windows.sorted { $0.windowStart < $1.windowStart }

        // Compute X and Y scaling
        let minX = sorted.first!.windowStart
        let maxX = sorted.last!.windowEnd
        let xRange = CGFloat(max(maxX - minX, 1))

        let maxCoverage = sorted.map(\.averageCoverage).max() ?? 1.0
        let yScale = maxCoverage > 0 ? (bounds.height - 2) / CGFloat(maxCoverage) : 0

        let insetRect = bounds.insetBy(dx: 1, dy: 1)

        // Build the filled polygon path
        let path = CGMutablePath()
        path.move(to: CGPoint(x: insetRect.minX, y: insetRect.maxY))

        for window in sorted {
            let xFrac = CGFloat(window.windowStart - minX) / xRange
            let x = insetRect.minX + xFrac * insetRect.width
            let y = insetRect.maxY - CGFloat(window.averageCoverage) * yScale
            path.addLine(to: CGPoint(x: x, y: y))
        }

        // Final point at right edge
        if let last = sorted.last {
            let xFrac = CGFloat(last.windowEnd - minX) / xRange
            let x = insetRect.minX + xFrac * insetRect.width
            let y = insetRect.maxY - CGFloat(last.averageCoverage) * yScale
            path.addLine(to: CGPoint(x: x, y: y))
        }

        // Close along the bottom
        path.addLine(to: CGPoint(x: insetRect.maxX, y: insetRect.maxY))
        path.closeSubpath()

        // Fill
        ctx.saveGState()
        ctx.addPath(path)
        ctx.setFillColor(fillColor.withAlphaComponent(0.35).cgColor)
        ctx.fillPath()
        ctx.restoreGState()

        // Stroke the top edge only (not the bottom closure)
        let strokePath = CGMutablePath()
        var firstPoint = true
        for window in sorted {
            let xFrac = CGFloat(window.windowStart - minX) / xRange
            let x = insetRect.minX + xFrac * insetRect.width
            let y = insetRect.maxY - CGFloat(window.averageCoverage) * yScale
            if firstPoint {
                strokePath.move(to: CGPoint(x: x, y: y))
                firstPoint = false
            } else {
                strokePath.addLine(to: CGPoint(x: x, y: y))
            }
        }
        if let last = sorted.last {
            let xFrac = CGFloat(last.windowEnd - minX) / xRange
            let x = insetRect.minX + xFrac * insetRect.width
            let y = insetRect.maxY - CGFloat(last.averageCoverage) * yScale
            strokePath.addLine(to: CGPoint(x: x, y: y))
        }

        ctx.addPath(strokePath)
        let resolvedStroke = strokeColor ?? fillColor.withAlphaComponent(0.8)
        ctx.setStrokeColor(resolvedStroke.cgColor)
        ctx.setLineWidth(0.5)
        ctx.strokePath()
    }

    // MARK: - Accessibility

    public override func accessibilityRole() -> NSAccessibility.Role? {
        .image
    }

    public override func accessibilityLabel() -> String? {
        if windows.isEmpty {
            return "No coverage data"
        }
        let maxCov = windows.map(\.averageCoverage).max() ?? 0
        return "Coverage sparkline, \(windows.count) windows, peak \(String(format: "%.1f", maxCov))x"
    }
}
