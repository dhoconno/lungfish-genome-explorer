// CoordinateRulerView.swift - Coordinate ruler with dynamic tick intervals
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import LungfishCore

// MARK: - CoordinateRulerView

/// Enhanced coordinate ruler view inspired by IGV and Geneious.
///
/// Features:
/// - Dynamic tick intervals based on zoom level using 1-2-5-10 rule
/// - Major ticks (10px) with labels, minor ticks (4px) without labels
/// - Formatted labels (1K, 10K, 1M, etc.) centered above major ticks
/// - Chromosome/sequence name displayed on left side
/// - Current visible range display
public class CoordinateRulerView: NSView {

    // MARK: - Properties

    /// The reference frame providing coordinate mapping
    var referenceFrame: ReferenceFrame?

    // MARK: - Layout Constants

    /// Height of major tick marks in pixels
    private let majorTickHeight: CGFloat = 10

    /// Height of minor tick marks in pixels
    private let minorTickHeight: CGFloat = 4

    /// Left margin for chromosome name label
    private let leftMargin: CGFloat = 8

    /// Font for coordinate labels
    private var labelFont: NSFont {
        NSFont.monospacedSystemFont(ofSize: 10, weight: .regular)
    }

    /// Font for chromosome name
    private var chromosomeFont: NSFont {
        NSFont.systemFont(ofSize: 10, weight: .medium)
    }

    // MARK: - View Properties

    public override var isFlipped: Bool { true }

    // MARK: - Drawing

    public override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        guard let context = NSGraphicsContext.current?.cgContext else { return }

        // Background
        context.setFillColor(NSColor.windowBackgroundColor.cgColor)
        context.fill(bounds)

        // Bottom border
        context.setStrokeColor(NSColor.separatorColor.cgColor)
        context.setLineWidth(1)
        context.move(to: CGPoint(x: 0, y: bounds.maxY - 0.5))
        context.addLine(to: CGPoint(x: bounds.maxX, y: bounds.maxY - 0.5))
        context.strokePath()

        // Draw ruler with coordinates
        if let frame = referenceFrame {
            drawEnhancedRuler(frame: frame, context: context)
        } else {
            drawPlaceholderRuler(context: context)
        }
    }

    // MARK: - Enhanced Ruler Drawing

    /// Draws the enhanced ruler with dynamic tick intervals and formatted labels.
    private func drawEnhancedRuler(frame: ReferenceFrame, context: CGContext) {
        let visibleRange = frame.end - frame.start
        guard visibleRange > 0 else { return }

        let pixelsPerBase = frame.dataPixelWidth / CGFloat(visibleRange)

        // Calculate tick intervals using 1-2-5-10 rule
        let (majorInterval, minorInterval) = calculateTickIntervals(visibleRange: visibleRange)

        // Draw chromosome name and visible range on left
        drawChromosomeLabel(frame: frame, context: context)

        // Draw minor ticks first (so major ticks draw over them if needed)
        drawMinorTicks(
            frame: frame,
            context: context,
            interval: minorInterval,
            majorInterval: majorInterval,
            pixelsPerBase: pixelsPerBase
        )

        // Draw major ticks with labels
        drawMajorTicks(
            frame: frame,
            context: context,
            interval: majorInterval,
            pixelsPerBase: pixelsPerBase
        )
    }

    /// Calculates major and minor tick intervals based on visible range using 1-2-5-10 rule.
    ///
    /// The 1-2-5-10 rule creates visually pleasing intervals by using multiples of
    /// 1, 2, and 5 at each order of magnitude (e.g., 1, 2, 5, 10, 20, 50, 100...).
    ///
    /// - Parameter visibleRange: The number of base pairs currently visible
    /// - Returns: Tuple of (majorInterval, minorInterval) in base pairs
    private func calculateTickIntervals(visibleRange: Double) -> (major: Double, minor: Double) {
        // Target approximately 5-10 major ticks on screen for readability
        let targetMajorTicks = 7.0
        let idealInterval = visibleRange / targetMajorTicks

        // Find the order of magnitude
        let magnitude = pow(10, floor(log10(idealInterval)))

        // Determine the multiplier using 1-2-5-10 rule
        let normalized = idealInterval / magnitude
        let multiplier: Double
        if normalized < 1.5 {
            multiplier = 1
        } else if normalized < 3.5 {
            multiplier = 2
        } else if normalized < 7.5 {
            multiplier = 5
        } else {
            multiplier = 10
        }

        let majorInterval = magnitude * multiplier

        // Minor interval is 1/10th or 1/5th of major, depending on multiplier
        let minorInterval: Double
        switch multiplier {
        case 1, 2:
            minorInterval = majorInterval / 10
        case 5:
            minorInterval = majorInterval / 5
        default:
            minorInterval = majorInterval / 10
        }

        // Apply the specific rules from requirements for edge cases
        let effectiveMajor: Double
        let effectiveMinor: Double

        if visibleRange < 100 {
            // < 100 bp visible: every 10 bp with minor ticks at 1 bp
            effectiveMajor = 10
            effectiveMinor = 1
        } else if visibleRange < 1000 {
            // 100-1000 bp: every 100 bp with minor at 10 bp
            effectiveMajor = 100
            effectiveMinor = 10
        } else if visibleRange < 10000 {
            // 1K-10K bp: every 1K with minor at 100 bp
            effectiveMajor = 1000
            effectiveMinor = 100
        } else if visibleRange < 100000 {
            // 10K-100K bp: every 10K with minor at 1K
            effectiveMajor = 10000
            effectiveMinor = 1000
        } else {
            // > 100K bp: every 100K with minor at 10K
            effectiveMajor = 100000
            effectiveMinor = 10000
        }

        // Use the more appropriate of calculated vs. requirement-based intervals
        // Prefer the calculated interval if it provides better granularity
        if majorInterval > 0 && majorInterval < effectiveMajor && visibleRange >= 100 {
            return (majorInterval, minorInterval)
        }

        return (effectiveMajor, effectiveMinor)
    }

    /// Draws minor tick marks (without labels).
    private func drawMinorTicks(
        frame: ReferenceFrame,
        context: CGContext,
        interval: Double,
        majorInterval: Double,
        pixelsPerBase: CGFloat
    ) {
        guard interval > 0 else { return }

        // Calculate minimum pixel spacing to avoid overlapping ticks
        let minPixelSpacing: CGFloat = 3
        let pixelInterval = CGFloat(interval) * pixelsPerBase
        guard pixelInterval >= minPixelSpacing else { return }

        context.saveGState()
        context.setStrokeColor(NSColor.quaternaryLabelColor.cgColor)
        context.setLineWidth(0.5)

        var pos = (frame.start / interval).rounded(.up) * interval
        while pos < frame.end {
            // Skip positions that are major tick positions
            let isMajorTick = majorInterval > 0 && abs(pos.truncatingRemainder(dividingBy: majorInterval)) < 0.001
            if !isMajorTick {
                let x = frame.leadingInset + CGFloat((pos - frame.start)) * pixelsPerBase

                // Draw minor tick at bottom (clip to data area)
                if x >= frame.leadingInset && x <= bounds.width - frame.trailingInset {
                    context.move(to: CGPoint(x: x, y: bounds.maxY - minorTickHeight))
                    context.addLine(to: CGPoint(x: x, y: bounds.maxY))
                    context.strokePath()
                }
            }

            pos += interval
        }

        context.restoreGState()
    }

    /// Draws major tick marks with centered labels.
    private func drawMajorTicks(
        frame: ReferenceFrame,
        context: CGContext,
        interval: Double,
        pixelsPerBase: CGFloat
    ) {
        guard interval > 0 else { return }

        let attributes: [NSAttributedString.Key: Any] = [
            .font: labelFont,
            .foregroundColor: NSColor.secondaryLabelColor,
        ]

        context.saveGState()
        context.setStrokeColor(NSColor.tertiaryLabelColor.cgColor)
        context.setLineWidth(1)

        // Track label positions to avoid overlap
        var lastLabelEndX: CGFloat = -100

        var pos = (frame.start / interval).rounded(.up) * interval
        while pos < frame.end {
            let x = frame.leadingInset + CGFloat((pos - frame.start)) * pixelsPerBase

            // Draw major tick at bottom (clip to data area)
            if x >= frame.leadingInset && x <= bounds.width - frame.trailingInset {
                context.move(to: CGPoint(x: x, y: bounds.maxY - majorTickHeight))
                context.addLine(to: CGPoint(x: x, y: bounds.maxY))
                context.strokePath()
            }

            // Draw label centered above tick
            let label = formatPosition(Int(pos))
            let labelSize = (label as NSString).size(withAttributes: attributes)
            let labelX = x - labelSize.width / 2

            // Only draw label if it fits and doesn't overlap with previous label
            let labelPadding: CGFloat = 4
            if labelX > lastLabelEndX + labelPadding &&
               labelX >= frame.leadingInset &&
               labelX + labelSize.width <= bounds.width - frame.trailingInset {
                // Position label above the tick, leaving room for tick marks
                let labelY = bounds.maxY - majorTickHeight - labelSize.height - 2
                (label as NSString).draw(at: CGPoint(x: labelX, y: labelY), withAttributes: attributes)
                lastLabelEndX = labelX + labelSize.width
            }

            pos += interval
        }

        context.restoreGState()
    }

    /// Draws chromosome name and visible range on the left side of the ruler.
    private func drawChromosomeLabel(frame: ReferenceFrame, context: CGContext) {
        // Build the range string: "chr1:1,000-10,000"
        let startFormatted = formatPositionWithCommas(Int(frame.start))
        let endFormatted = formatPositionWithCommas(Int(frame.end))
        let rangeString = "\(frame.chromosome):\(startFormatted)-\(endFormatted)"

        let attributes: [NSAttributedString.Key: Any] = [
            .font: chromosomeFont,
            .foregroundColor: NSColor.labelColor,
        ]

        let labelSize = (rangeString as NSString).size(withAttributes: attributes)

        // Position in top-left area of ruler
        let labelY = (bounds.height - majorTickHeight - labelSize.height) / 2
        let labelRect = CGRect(
            x: leftMargin,
            y: max(2, labelY),
            width: min(labelSize.width, bounds.width / 3),
            height: labelSize.height
        )

        // Draw background for visibility
        context.saveGState()
        context.setFillColor(NSColor.windowBackgroundColor.withAlphaComponent(0.9).cgColor)
        context.fill(labelRect.insetBy(dx: -2, dy: -1))
        context.restoreGState()

        // Draw the text (truncated if necessary)
        (rangeString as NSString).draw(in: labelRect, withAttributes: attributes)
    }

    /// Draws placeholder ruler when no reference frame is set.
    private func drawPlaceholderRuler(context: CGContext) {
        context.setStrokeColor(NSColor.tertiaryLabelColor.cgColor)
        context.setLineWidth(0.5)

        // Draw evenly spaced minor ticks
        let tickSpacing: CGFloat = 50
        for x in stride(from: CGFloat(0), to: bounds.width, by: tickSpacing) {
            context.move(to: CGPoint(x: x, y: bounds.maxY - minorTickHeight))
            context.addLine(to: CGPoint(x: x, y: bounds.maxY))
            context.strokePath()
        }

        // Draw a centered message
        let message = "No sequence loaded"
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 10),
            .foregroundColor: NSColor.tertiaryLabelColor,
        ]
        let size = (message as NSString).size(withAttributes: attributes)
        let x = (bounds.width - size.width) / 2
        let y = (bounds.height - majorTickHeight - size.height) / 2
        (message as NSString).draw(at: CGPoint(x: x, y: max(2, y)), withAttributes: attributes)
    }

    // MARK: - Position Formatting

    /// Formats a genomic position with appropriate suffix (K, M, G).
    ///
    /// - Parameter pos: Position in base pairs
    /// - Returns: Formatted string (e.g., "1.5M", "10K", "500")
    private func formatPosition(_ pos: Int) -> String {
        let absPos = abs(pos)

        if absPos >= 1_000_000_000 {
            // Gigabases
            let value = Double(pos) / 1_000_000_000
            if value.truncatingRemainder(dividingBy: 1) == 0 {
                return String(format: "%.0fG", value)
            }
            return String(format: "%.1fG", value)
        } else if absPos >= 1_000_000 {
            // Megabases
            let value = Double(pos) / 1_000_000
            if value.truncatingRemainder(dividingBy: 1) == 0 {
                return String(format: "%.0fM", value)
            }
            return String(format: "%.1fM", value)
        } else if absPos >= 1_000 {
            // Kilobases
            let value = Double(pos) / 1_000
            if value.truncatingRemainder(dividingBy: 1) == 0 {
                return String(format: "%.0fK", value)
            }
            return String(format: "%.1fK", value)
        } else {
            // Base pairs
            return "\(pos)"
        }
    }

    /// Formats a position with comma separators for the range display.
    ///
    /// - Parameter pos: Position in base pairs
    /// - Returns: Formatted string with comma separators (e.g., "1,234,567")
    private func formatPositionWithCommas(_ pos: Int) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.groupingSeparator = ","
        return formatter.string(from: NSNumber(value: pos)) ?? "\(pos)"
    }
}
