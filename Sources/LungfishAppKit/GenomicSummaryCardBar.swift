// GenomicSummaryCardBar.swift - Reusable horizontal summary card bar
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit

/// A horizontal strip of statistic cards for dataset overview.
///
/// Subclass and override `cards` to provide domain-specific metrics.
/// The base class handles all rendering: card backgrounds, borders,
/// label/value layout, abbreviation when cards are narrow.
///
/// Used by:
/// - `FASTQSummaryBar` — read count, quality, GC, N50
/// - `FASTACollectionSummaryBar` — sequence count, annotations, GC
@MainActor
open class GenomicSummaryCardBar: NSView {

    /// A single summary card with a label and formatted value.
    public struct Card {
        public let label: String
        public let value: String

        public init(label: String, value: String) {
            self.label = label
            self.value = value
        }
    }

    /// Override in subclasses to provide the cards to display.
    open var cards: [Card] { [] }

    open override var isFlipped: Bool { true }

    open override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }

        let cardData = cards
        guard !cardData.isEmpty else { return }

        let padding: CGFloat = 8
        let cardSpacing: CGFloat = 6
        let availableWidth = bounds.width - padding * 2
        let cardWidth = (availableWidth - cardSpacing * CGFloat(cardData.count - 1)) / CGFloat(cardData.count)

        for (i, card) in cardData.enumerated() {
            let x = padding + CGFloat(i) * (cardWidth + cardSpacing)
            let cardRect = CGRect(x: x, y: 4, width: cardWidth, height: bounds.height - 8)

            // Card background
            let bgColor = NSColor.controlBackgroundColor.withAlphaComponent(0.6).cgColor
            ctx.setFillColor(bgColor)
            let path = CGPath(roundedRect: cardRect, cornerWidth: 4, cornerHeight: 4, transform: nil)
            ctx.addPath(path)
            ctx.fillPath()

            // Border
            ctx.setStrokeColor(NSColor.separatorColor.cgColor)
            ctx.setLineWidth(0.5)
            ctx.addPath(path)
            ctx.strokePath()

            // Clip text to card bounds
            ctx.saveGState()
            ctx.clip(to: cardRect.insetBy(dx: 4, dy: 0))

            // Label (top) — use abbreviated label when card is narrow
            let labelAttrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 9, weight: .medium),
                .foregroundColor: NSColor.secondaryLabelColor,
            ]
            let cardContentWidth = cardRect.width - 8
            let fullLabelSize = (card.label as NSString).size(withAttributes: labelAttrs)
            let displayLabel = fullLabelSize.width > cardContentWidth
                ? abbreviatedLabel(for: card.label)
                : card.label
            let labelStr = NSAttributedString(string: displayLabel, attributes: labelAttrs)
            let labelSize = labelStr.size()
            let labelX = cardRect.midX - labelSize.width / 2
            labelStr.draw(at: CGPoint(x: labelX, y: cardRect.minY + 4))

            // Value (bottom)
            let valueAttrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .semibold),
                .foregroundColor: NSColor.labelColor,
            ]
            let valueStr = NSAttributedString(string: card.value, attributes: valueAttrs)
            let valueSize = valueStr.size()
            let valueX = cardRect.midX - valueSize.width / 2
            valueStr.draw(at: CGPoint(x: valueX, y: cardRect.minY + 18))

            ctx.restoreGState()
        }
    }

    /// Shortens a label when the card is too narrow. Override in subclasses
    /// to provide domain-specific abbreviations.
    open func abbreviatedLabel(for label: String) -> String {
        switch label {
        case "Median Length": return "Med. Len"
        case "Mean Length": return "Mean Len"
        case "Total Reads": return "Reads"
        case "Total Bases": return "Bases"
        case "Mean Quality": return "Mean Q"
        case "Median Quality": return "Med. Q"
        case "Min Length": return "Min Len"
        case "Max Length": return "Max Len"
        case "GC Content": return "GC%"
        case "Mean Q": return "Q"
        case "Sequences": return "Seqs"
        case "Annotations": return "Annot"
        case "Feature Types": return "Types"
        case "Shortest": return "Min"
        case "Longest": return "Max"
        default: return String(label.prefix(8))
        }
    }

    // MARK: - Shared Formatters

    /// Formats a count with K/M/G suffixes.
    public static func formatCount(_ count: Int) -> String {
        if count >= 1_000_000 { return String(format: "%.1fM", Double(count) / 1_000_000) }
        if count >= 1_000 { return String(format: "%.1fK", Double(count) / 1_000) }
        return "\(count)"
    }

    /// Formats a base count with bp/Kb/Mb/Gb suffixes.
    public static func formatBases(_ count: Int64) -> String {
        if count >= 1_000_000_000 { return String(format: "%.2f Gb", Double(count) / 1_000_000_000) }
        if count >= 1_000_000 { return String(format: "%.2f Mb", Double(count) / 1_000_000) }
        if count >= 1_000 { return String(format: "%.1f Kb", Double(count) / 1_000) }
        return "\(count) bp"
    }

    /// Formats a base count from Int with bp/Kb/Mb/Gb suffixes.
    public static func formatBases(_ count: Int) -> String {
        formatBases(Int64(count))
    }
}
