// TaxTriageConfidenceCellView.swift - Compact TASS confidence indicator cell
// Copyright (c) 2025 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import LungfishKit

@MainActor
enum TaxTriageConfidencePalette {
    static func color(for score: Double) -> NSColor {
        if score >= 0.8 {
            return .systemGreen
        } else if score >= 0.4 {
            return .systemYellow
        } else {
            return .lungfishDanger
        }
    }
}

#if DEBUG
extension TaxTriageConfidenceCellView {
    var testingTrackRect: NSRect { trackRect }
    var testingFillColor: NSColor { fillColor }
}
#endif

// MARK: - TaxTriageConfidenceCellView

/// A compact single-bar confidence indicator for use in an NSTableView cell.
///
/// Renders a single horizontal bar with color coding in the TaxTriage confidence column.
@MainActor
final class TaxTriageConfidenceCellView: NSView {
    private static let trackHeight: CGFloat = 16
    private static let horizontalInset: CGFloat = 2

    /// The TASS confidence score to display (0.0 to 1.0).
    var score: Double = 0 {
        didSet {
            needsDisplay = true
            updateAccessibility()
        }
    }

    override var isFlipped: Bool { true }

    private var trackRect: NSRect {
        let height = min(Self.trackHeight, max(0, bounds.height))
        return NSRect(
            x: bounds.minX + Self.horizontalInset,
            y: bounds.midY - height / 2,
            width: max(0, bounds.width - Self.horizontalInset * 2),
            height: height
        )
    }

    private var fillColor: NSColor {
        TaxTriageConfidencePalette.color(for: min(max(score, 0), 1))
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        configureAccessibility()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        configureAccessibility()
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }

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
        ctx.setFillColor(fillColor.cgColor)
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

    private func configureAccessibility() {
        setAccessibilityElement(true)
        setAccessibilityRole(.valueIndicator)
        setAccessibilityLabel("Confidence")
        updateAccessibility()
    }

    private func updateAccessibility() {
        let clampedScore = min(max(score, 0), 1)
        let category: String
        if clampedScore >= 0.8 {
            category = "High"
        } else if clampedScore >= 0.4 {
            category = "Medium"
        } else {
            category = "Low"
        }
        setAccessibilityValue(NSNumber(value: clampedScore))
        setAccessibilityHelp(
            "\(category) confidence, TASS score \(String(format: "%.3f", clampedScore))"
        )
    }
}
