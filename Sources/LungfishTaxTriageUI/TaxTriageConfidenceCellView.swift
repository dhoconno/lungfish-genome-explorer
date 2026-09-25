// TaxTriageConfidenceCellView.swift - Compact TASS confidence indicator cell
// Copyright (c) 2025 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import LungfishKit

/// The High / Medium / Low band a TaxTriage row falls in, matching the
/// Confidence column.
///
/// The row's stored confidence label wins. For organism reports (`.odr.txt`)
/// that label is TaxTriage's own call: a row that passes the run's TASS
/// threshold ("Passes Threshold", 75 on TaxTriage's 0-100 scale, so 0.75 in
/// LGE's 0-1 scale) is High, and below it Medium starts at 0.40
/// (`TaxTriageOrganismReport.odrConfidenceLabel`). Only rows without a label
/// fall back to fixed score bands (High from 0.80, Medium from 0.40).
enum TaxTriageConfidenceBand: Equatable, Sendable {
    case high
    case medium
    case low

    init(label: String?, tassScore: Double) {
        switch label?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "high", "high confidence":
            self = .high
        case "medium", "moderate", "medium confidence", "moderate confidence":
            self = .medium
        case "low", "low confidence":
            self = .low
        default:
            self = Self.scoreBand(tassScore)
        }
    }

    /// Fixed score bands, used only when a row has no confidence label.
    static func scoreBand(_ tassScore: Double) -> TaxTriageConfidenceBand {
        if tassScore >= 0.8 { return .high }
        if tassScore >= 0.4 { return .medium }
        return .low
    }

    /// Whether `label` is one of the recognised confidence labels.
    static func hasRecognisedLabel(_ label: String?) -> Bool {
        switch label?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "high", "high confidence", "medium", "moderate", "medium confidence",
             "moderate confidence", "low", "low confidence":
            return true
        default:
            return false
        }
    }

    /// Tooltip for TASS Score and Confidence cells.
    static func toolTip(label: String?, tassScore: Double) -> String {
        let band = TaxTriageConfidenceBand(label: label, tassScore: tassScore)
        let labelled = hasRecognisedLabel(label)
        switch band {
        case .high:
            return labelled
                ? "High confidence: passes TaxTriage's TASS threshold. Strong taxonomic signal."
                : "High confidence (TASS 0.80 or higher): strong taxonomic signal."
        case .medium:
            return labelled
                ? "Medium confidence: below TaxTriage's TASS threshold, TASS 0.40 or higher. Likely true positive, verify with BLAST."
                : "Medium confidence (TASS 0.40 to 0.80): likely true positive, verify with BLAST."
        case .low:
            return "Low confidence (TASS below 0.40): weak signal, may be noise or contamination."
        }
    }

    @MainActor
    var color: NSColor {
        switch self {
        case .high: return .systemGreen
        case .medium: return .systemYellow
        case .low: return .lungfishDanger
        }
    }
}

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

    /// The row's confidence band. When set (from the row's confidence label)
    /// it decides the bar colour and the accessibility category, so the bar
    /// agrees with the Confidence text. `nil` falls back to score bands.
    var band: TaxTriageConfidenceBand? {
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
        if let band { return band.color }
        return TaxTriageConfidencePalette.color(for: min(max(score, 0), 1))
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
        switch band ?? TaxTriageConfidenceBand.scoreBand(clampedScore) {
        case .high: category = "High"
        case .medium: category = "Medium"
        case .low: category = "Low"
        }
        setAccessibilityValue(NSNumber(value: clampedScore))
        setAccessibilityHelp(
            "\(category) confidence, TASS score \(String(format: "%.3f", clampedScore))"
        )
    }
}
