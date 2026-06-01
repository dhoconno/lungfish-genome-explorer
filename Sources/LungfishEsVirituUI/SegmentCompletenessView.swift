// SegmentCompletenessView.swift - Compact segment coverage grid for segmented viruses
// Copyright (c) 2025 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import LungfishIO

// MARK: - SegmentCompletenessView

/// A compact grid showing coverage status for each segment of a segmented virus.
///
/// Displays one cell per segment, color-coded by coverage depth:
/// - **Green**: coverage ≥ 5x (well covered)
/// - **Yellow**: coverage 1-5x (partially covered)
/// - **Gray**: no reads detected (0x)
///
/// Designed for segmented viruses like Influenza (8 segments), Bunyavirales
/// (3 segments), and Rotaviruses (10-12 segments).
///
/// ```
/// Segment Coverage (6 of 8 segments detected)
/// +----+----+----+----+----+----+----+----+
/// | PB2| PB1| PA | HA | NP | NA |  M | NS |
/// | 4x | 3x | 5x |12x | 2x |  - |  - | 8x |
/// +----+----+----+----+----+----+----+----+
/// ```
@MainActor
public final class SegmentCompletenessView: NSView {

    // MARK: - Data

    private var segments: [(label: String, coverage: Double, reads: Int)] = []
    private var titleText: String = ""

    // MARK: - Constants

    private let cellWidth: CGFloat = 48
    private let cellHeight: CGFloat = 36
    private let cellGap: CGFloat = 3
    private let headerHeight: CGFloat = 18
    private let cornerRadius: CGFloat = 4

    // MARK: - Configuration

    /// Configures the view with segment data from an assembly's contigs.
    ///
    /// - Parameter assembly: The viral assembly containing segment information.
    public func configure(assembly: ViralAssembly) {
        segments = assembly.contigs.map { contig in
            let label = contig.segment ?? contig.accession.suffix(6).description
            return (label: label, coverage: contig.meanCoverage, reads: contig.readCount)
        }

        let detected = segments.filter { $0.reads > 0 }.count
        titleText = "Segment Coverage (\(detected) of \(segments.count) segments detected)"

        invalidateIntrinsicContentSize()
        needsDisplay = true
    }

    // MARK: - Drawing

    public override func draw(_ dirtyRect: NSRect) {
        guard !segments.isEmpty else { return }

        // Title
        let titleAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 10, weight: .medium),
            .foregroundColor: NSColor.secondaryLabelColor,
        ]
        (titleText as NSString).draw(at: NSPoint(x: 0, y: bounds.height - headerHeight + 2), withAttributes: titleAttrs)

        // Cells
        let y = bounds.height - headerHeight - cellHeight - 4
        for (i, seg) in segments.enumerated() {
            let x = CGFloat(i) * (cellWidth + cellGap)
            guard x + cellWidth <= bounds.width else { break }

            let rect = NSRect(x: x, y: y, width: cellWidth, height: cellHeight)
            drawSegmentCell(seg, in: rect)
        }
    }

    private func drawSegmentCell(_ segment: (label: String, coverage: Double, reads: Int), in rect: NSRect) {
        // Background color based on coverage
        let bgColor: NSColor
        if segment.reads == 0 {
            bgColor = NSColor.systemGray.withAlphaComponent(0.15)
        } else if segment.coverage < 5 {
            bgColor = NSColor.systemYellow.withAlphaComponent(0.25)
        } else {
            bgColor = NSColor.systemGreen.withAlphaComponent(0.25)
        }

        // Draw rounded rect background
        let path = NSBezierPath(roundedRect: rect, xRadius: cornerRadius, yRadius: cornerRadius)
        bgColor.setFill()
        path.fill()

        // Border
        let borderColor: NSColor
        if segment.reads == 0 {
            borderColor = NSColor.systemGray.withAlphaComponent(0.3)
        } else if segment.coverage < 5 {
            borderColor = NSColor.systemYellow.withAlphaComponent(0.5)
        } else {
            borderColor = NSColor.systemGreen.withAlphaComponent(0.5)
        }
        borderColor.setStroke()
        path.lineWidth = 0.5
        path.stroke()

        // Segment label (top)
        let labelAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 9, weight: .semibold),
            .foregroundColor: NSColor.labelColor,
        ]
        let label = segment.label as NSString
        let labelSize = label.size(withAttributes: labelAttrs)
        label.draw(
            at: NSPoint(x: rect.midX - labelSize.width / 2, y: rect.maxY - labelSize.height - 3),
            withAttributes: labelAttrs
        )

        // Coverage value (bottom)
        let valueText: String
        if segment.reads == 0 {
            valueText = "—"
        } else {
            valueText = String(format: "%.0fx", segment.coverage)
        }
        let valueAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 9, weight: .regular),
            .foregroundColor: segment.reads == 0 ? NSColor.tertiaryLabelColor : NSColor.secondaryLabelColor,
        ]
        let valueStr = valueText as NSString
        let valueSize = valueStr.size(withAttributes: valueAttrs)
        valueStr.draw(
            at: NSPoint(x: rect.midX - valueSize.width / 2, y: rect.minY + 3),
            withAttributes: valueAttrs
        )
    }

    // MARK: - Intrinsic Size

    public override var intrinsicContentSize: NSSize {
        guard !segments.isEmpty else { return .zero }
        let width = CGFloat(segments.count) * (cellWidth + cellGap) - cellGap
        let height = headerHeight + cellHeight + 4
        return NSSize(width: width, height: height)
    }
}
