// TaxonomyTooltipView.swift - Hover tooltip for taxonomy chart segments
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import LungfishIO

// MARK: - TaxonomyTooltipView

/// A compact tooltip view showing taxon details on hover.
///
/// Displays:
/// - Taxon name (bold)
/// - Rank
/// - Read count (direct and clade)
/// - Percentage of total and classified reads
/// - Number of child taxa
///
/// The tooltip has a rounded rectangle background with a subtle drop shadow,
/// matching the visual style of other tooltips in the application.
@MainActor
public class TaxonomyTooltipView: NSView {

    // MARK: - State

    private var taxonName: String = ""
    private var rankName: String = ""
    private var readsDirect: Int = 0
    private var readsClade: Int = 0
    private(set) var percentOfTotal: Double = 0
    private(set) var percentOfClassified: Double = 0
    private var childCount: Int = 0

    // MARK: - Configuration

    private let cornerRadius: CGFloat = 6
    private let padding: CGFloat = 10
    private let lineSpacing: CGFloat = 3

    // MARK: - View Configuration

    public override var isFlipped: Bool { true }

    // MARK: - Update

    /// Updates the tooltip content for a given taxon node.
    ///
    /// - Parameters:
    ///   - node: The taxon node to display.
    ///   - totalReads: Total reads in the dataset (for percentage calculation).
    ///   - classifiedReads: Classified reads in the dataset.
    public func update(with node: TaxonNode, totalReads: Int, classifiedReads: Int) {
        taxonName = node.name
        rankName = node.rank.displayName
        readsDirect = node.readsDirect
        readsClade = node.readsClade
        childCount = node.children.count

        if totalReads > 0 {
            percentOfTotal = Double(node.readsClade) / Double(totalReads) * 100
        } else {
            percentOfTotal = 0
        }

        percentOfClassified = classifiedReads > 0
            ? Double(node.readsClade) / Double(classifiedReads) * 100
            : 0

        needsDisplay = true
        invalidateIntrinsicContentSize()
    }

    // MARK: - Sizing

    /// Computes the preferred size for the tooltip based on current content.
    ///
    /// This is separate from `NSView.fittingSize` to avoid overriding the
    /// Auto Layout computed property.
    public var preferredSize: NSSize {
        let lines = tooltipLines()
        var maxWidth: CGFloat = 0
        var totalHeight: CGFloat = 0

        for line in lines {
            let size = line.size()
            maxWidth = max(maxWidth, size.width)
            totalHeight += size.height + lineSpacing
        }

        // Add separator height
        totalHeight += 6  // separator spacing

        return NSSize(
            width: max(160, maxWidth + padding * 2),
            height: totalHeight + padding * 2
        )
    }

    public override var intrinsicContentSize: NSSize {
        preferredSize
    }

    // MARK: - Drawing

    public override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }

        let drawBounds = bounds.insetBy(dx: 1, dy: 1)

        // Shadow
        ctx.saveGState()
        ctx.setShadow(
            offset: CGSize(width: 0, height: -2),
            blur: 6,
            color: NSColor.black.withAlphaComponent(0.2).cgColor
        )

        // Background
        let bgPath = NSBezierPath(roundedRect: drawBounds, xRadius: cornerRadius, yRadius: cornerRadius)
        NSColor.windowBackgroundColor.setFill()
        bgPath.fill()

        ctx.restoreGState()

        // Border
        NSColor.separatorColor.setStroke()
        bgPath.lineWidth = 0.5
        bgPath.stroke()

        // Content
        let lines = tooltipLines()
        var y: CGFloat = padding

        for (i, line) in lines.enumerated() {
            // Draw separator after the rank line (index 1)
            if i == 2 {
                let sepY = y - lineSpacing / 2
                ctx.setStrokeColor(NSColor.separatorColor.cgColor)
                ctx.setLineWidth(0.5)
                ctx.move(to: CGPoint(x: padding, y: sepY))
                ctx.addLine(to: CGPoint(x: drawBounds.maxX - padding, y: sepY))
                ctx.strokePath()
                y += 3
            }

            line.draw(at: CGPoint(x: padding, y: y))
            y += line.size().height + lineSpacing
        }
    }

    // MARK: - Content

    /// Builds the attributed string lines for the tooltip.
    private func tooltipLines() -> [NSAttributedString] {
        let nameAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 13, weight: .semibold),
            .foregroundColor: NSColor.labelColor,
        ]
        let rankAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11),
            .foregroundColor: NSColor.secondaryLabelColor,
        ]
        let detailAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular),
            .foregroundColor: NSColor.labelColor,
        ]
        let labelAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11),
            .foregroundColor: NSColor.secondaryLabelColor,
        ]

        var lines: [NSAttributedString] = []

        // Name
        lines.append(NSAttributedString(string: taxonName, attributes: nameAttrs))

        // Rank
        lines.append(NSAttributedString(string: rankName, attributes: rankAttrs))

        // Reads (direct)
        let directLine = NSMutableAttributedString(string: "Reads: ", attributes: labelAttrs)
        directLine.append(NSAttributedString(
            string: formatNumber(readsDirect),
            attributes: detailAttrs
        ))
        lines.append(directLine)

        // Clade reads
        let cladeLine = NSMutableAttributedString(string: "Clade reads: ", attributes: labelAttrs)
        cladeLine.append(NSAttributedString(
            string: formatNumber(readsClade),
            attributes: detailAttrs
        ))
        lines.append(cladeLine)

        // Percentage of total
        let pctTotalLine = NSMutableAttributedString(
            string: "% of total: ",
            attributes: labelAttrs
        )
        pctTotalLine.append(NSAttributedString(
            string: String(format: "%.1f%%", percentOfTotal),
            attributes: detailAttrs
        ))
        lines.append(pctTotalLine)

        // Percentage of classified
        let pctClassLine = NSMutableAttributedString(
            string: "% of classified: ",
            attributes: labelAttrs
        )
        pctClassLine.append(NSAttributedString(
            string: String(format: "%.1f%%", percentOfClassified),
            attributes: detailAttrs
        ))
        lines.append(pctClassLine)

        // Child count
        if childCount > 0 {
            let childLine = NSMutableAttributedString(
                string: "Child taxa: ",
                attributes: labelAttrs
            )
            childLine.append(NSAttributedString(
                string: "\(childCount)",
                attributes: detailAttrs
            ))
            lines.append(childLine)
        }

        return lines
    }

    /// Formats a number with thousands separators.
    private func formatNumber(_ value: Int) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.groupingSeparator = ","
        return formatter.string(from: NSNumber(value: value)) ?? "\(value)"
    }
}
