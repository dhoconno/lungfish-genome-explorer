// TrackHeaderView.swift - Track header labels and disclosure controls
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import LungfishCore

// MARK: - TrackHeaderViewDelegate

/// Delegate protocol for TrackHeaderView interactions.
@MainActor
public protocol TrackHeaderViewDelegate: AnyObject {
    /// Called when the user clicks the disclosure triangle to toggle annotation visibility.
    func trackHeaderView(_ headerView: TrackHeaderView, didToggleAnnotationsForTrackAt index: Int)
}

// MARK: - TrackHeaderView

/// View for displaying track labels and annotation expand/collapse controls.
///
/// Layout must match the SequenceStackLayout values used by multi-sequence rendering:
/// - startY: Starting Y offset (default: 20)
/// - trackHeight: Height of each sequence track (default: 28)
/// - trackSpacing: Gap between tracks (default: 4)
///
/// Features:
/// - Disclosure triangles for sequences with annotations
/// - Click-to-expand/collapse annotation tracks
/// - Visual feedback for expanded/collapsed state
public class TrackHeaderView: NSView {

    private var trackNames: [String] = []

    /// Stacked sequence info for precise alignment with viewer
    private var stackedSequences: [StackedSequenceInfo] = []

    /// Track positioning (should match SequenceStackLayout values)
    var trackY: CGFloat = SequenceStackLayout.defaultTrackHeight  // startY for first track
    var trackHeight: CGFloat = SequenceStackLayout.defaultTrackHeight
    var trackSpacing: CGFloat = SequenceStackLayout.trackSpacing

    /// Delegate for handling user interactions
    weak var delegate: TrackHeaderViewDelegate?

    /// Tracking area for mouse events
    private var trackingArea: NSTrackingArea?

    /// Currently hovered track index
    private var hoveredTrackIndex: Int?

    /// Size of disclosure triangle
    private let disclosureSize: CGFloat = 10

    public override var isFlipped: Bool { true }

    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupView()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupView()
    }

    private func setupView() {
    }

    func setTrackNames(_ names: [String]) {
        self.trackNames = names
        self.stackedSequences = []
        setNeedsDisplay(bounds)
    }

    /// Sets the stacked sequences for precise Y alignment.
    /// When set, uses the actual yOffset from each sequence info.
    func setStackedSequences(_ sequences: [StackedSequenceInfo]) {
        self.stackedSequences = sequences
        self.trackNames = sequences.map { $0.sequence.name }
        setNeedsDisplay(bounds)
    }

    public override func updateTrackingAreas() {
        super.updateTrackingAreas()

        if let existingArea = trackingArea {
            removeTrackingArea(existingArea)
        }

        trackingArea = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .mouseMoved, .activeInActiveApp],
            owner: self,
            userInfo: [NotificationUserInfoKey.inspectorTab: "selection"]
        )

        if let area = trackingArea {
            addTrackingArea(area)
        }
    }

    public override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        guard let context = NSGraphicsContext.current?.cgContext else { return }

        // Background - use same color as viewer when empty
        if trackNames.isEmpty {
            context.setFillColor(NSColor.textBackgroundColor.cgColor)
        } else {
            context.setFillColor(NSColor.windowBackgroundColor.cgColor)
        }
        context.fill(bounds)

        // Only draw right border when we have tracks
        if !trackNames.isEmpty {
            context.setStrokeColor(NSColor.separatorColor.cgColor)
            context.setLineWidth(1)
            context.move(to: CGPoint(x: bounds.maxX - 0.5, y: 0))
            context.addLine(to: CGPoint(x: bounds.maxX - 0.5, y: bounds.maxY))
            context.strokePath()

            // Track labels - aligned with viewer tracks
            let labelFont = NSFont.systemFont(ofSize: 11, weight: .medium)
            let attributes: [NSAttributedString.Key: Any] = [
                .font: labelFont,
                .foregroundColor: NSColor.labelColor,
            ]

            for (index, label) in trackNames.enumerated() {
                drawTrackRow(index: index, label: label, attributes: attributes, context: context)
            }
        }
    }

    /// Draws a single track row with label and disclosure triangle.
    private func drawTrackRow(index: Int, label: String, attributes: [NSAttributedString.Key: Any], context: CGContext) {
        // Calculate Y position - use stacked sequence info if available
        let rowY: CGFloat
        let hasAnnotations: Bool
        let annotationsExpanded: Bool

        if index < stackedSequences.count {
            // Use actual offset from multi-sequence layout
            rowY = stackedSequences[index].yOffset
            hasAnnotations = !stackedSequences[index].annotations.isEmpty
            annotationsExpanded = stackedSequences[index].showAnnotations
        } else {
            // Fallback to simple calculation matching SequenceStackLayout
            rowY = trackY + CGFloat(index) * (trackHeight + trackSpacing)
            hasAnnotations = false
            annotationsExpanded = false
        }

        let labelSize = (label as NSString).size(withAttributes: attributes)
        let labelY = rowY + (trackHeight - labelSize.height) / 2

        // Left margin for label (leave space for disclosure triangle if needed)
        var labelX: CGFloat = 8

        // Draw disclosure triangle if this track has annotations
        if hasAnnotations {
            let triangleX: CGFloat = 4
            let triangleY = rowY + (trackHeight - disclosureSize) / 2

            drawDisclosureTriangle(
                at: CGPoint(x: triangleX, y: triangleY),
                expanded: annotationsExpanded,
                hovered: hoveredTrackIndex == index,
                context: context
            )

            labelX = 4 + disclosureSize + 4  // triangle + spacing
        }

        // Truncate long names
        let maxWidth = bounds.width - labelX - 8
        let truncatedLabel = truncateLabel(label, maxWidth: maxWidth, attributes: attributes)

        (truncatedLabel as NSString).draw(at: CGPoint(x: labelX, y: labelY), withAttributes: attributes)

        // Draw annotation count badge if collapsed but has annotations
        if hasAnnotations && !annotationsExpanded && index < stackedSequences.count {
            let count = stackedSequences[index].annotations.count
            drawAnnotationBadge(count: count, y: rowY + trackHeight - 4, context: context)
        }
    }

    /// Draws a disclosure triangle (pointing right when collapsed, down when expanded).
    private func drawDisclosureTriangle(at point: CGPoint, expanded: Bool, hovered: Bool, context: CGContext) {
        context.saveGState()

        let color = hovered ? NSColor.controlAccentColor : NSColor.secondaryLabelColor
        context.setFillColor(color.cgColor)

        context.translateBy(x: point.x + disclosureSize / 2, y: point.y + disclosureSize / 2)

        if expanded {
            // Pointing down (expanded)
            context.move(to: CGPoint(x: -4, y: -2))
            context.addLine(to: CGPoint(x: 4, y: -2))
            context.addLine(to: CGPoint(x: 0, y: 3))
        } else {
            // Pointing right (collapsed)
            context.move(to: CGPoint(x: -2, y: -4))
            context.addLine(to: CGPoint(x: 3, y: 0))
            context.addLine(to: CGPoint(x: -2, y: 4))
        }

        context.closePath()
        context.fillPath()

        context.restoreGState()
    }

    /// Draws a small badge showing annotation count.
    private func drawAnnotationBadge(count: Int, y: CGFloat, context: CGContext) {
        let badgeFont = NSFont.systemFont(ofSize: 8, weight: .medium)
        let badgeText = "\(count)"
        let attributes: [NSAttributedString.Key: Any] = [
            .font: badgeFont,
            .foregroundColor: NSColor.white
        ]

        let size = (badgeText as NSString).size(withAttributes: attributes)
        let badgeWidth = max(size.width + 6, 14)
        let badgeHeight: CGFloat = 12

        let badgeRect = CGRect(
            x: bounds.width - badgeWidth - 4,
            y: y - badgeHeight + 2,
            width: badgeWidth,
            height: badgeHeight
        )

        // Badge background
        context.setFillColor(NSColor.tertiaryLabelColor.cgColor)
        let path = CGPath(roundedRect: badgeRect, cornerWidth: 6, cornerHeight: 6, transform: nil)
        context.addPath(path)
        context.fillPath()

        // Badge text
        let textX = badgeRect.midX - size.width / 2
        let textY = badgeRect.minY + (badgeHeight - size.height) / 2
        (badgeText as NSString).draw(at: CGPoint(x: textX, y: textY), withAttributes: attributes)
    }

    private func truncateLabel(_ label: String, maxWidth: CGFloat, attributes: [NSAttributedString.Key: Any]) -> String {
        let size = (label as NSString).size(withAttributes: attributes)
        if size.width <= maxWidth {
            return label
        }

        var truncated = label
        while truncated.count > 3 {
            truncated = String(truncated.dropLast())
            let testLabel = truncated + "..."
            let testSize = (testLabel as NSString).size(withAttributes: attributes)
            if testSize.width <= maxWidth {
                return testLabel
            }
        }
        return "..."
    }

    // MARK: - Mouse Event Handling

    public override func mouseDown(with event: NSEvent) {
        let location = convert(event.locationInWindow, from: nil)

        // Find which track was clicked
        if let index = trackIndex(at: location) {
            // Check if click was on disclosure triangle area
            if index < stackedSequences.count && !stackedSequences[index].annotations.isEmpty {
                let rowY = stackedSequences[index].yOffset
                let triangleRect = CGRect(x: 0, y: rowY, width: 20, height: trackHeight)

                if triangleRect.contains(location) {
                    delegate?.trackHeaderView(self, didToggleAnnotationsForTrackAt: index)
                    return
                }
            }
        }

        super.mouseDown(with: event)
    }

    public override func mouseMoved(with event: NSEvent) {
        let location = convert(event.locationInWindow, from: nil)
        let newHoveredIndex = trackIndex(at: location)

        if newHoveredIndex != hoveredTrackIndex {
            hoveredTrackIndex = newHoveredIndex
            needsDisplay = true
        }

        // Update cursor based on hover state
        if let index = newHoveredIndex,
           index < stackedSequences.count,
           !stackedSequences[index].annotations.isEmpty {
            let rowY = stackedSequences[index].yOffset
            let triangleRect = CGRect(x: 0, y: rowY, width: 20, height: trackHeight)
            if triangleRect.contains(location) {
                NSCursor.pointingHand.set()
            } else {
                NSCursor.arrow.set()
            }
        } else {
            NSCursor.arrow.set()
        }
    }

    public override func mouseExited(with event: NSEvent) {
        hoveredTrackIndex = nil
        NSCursor.arrow.set()
        needsDisplay = true
    }

    /// Returns the track index at the given Y coordinate, or nil if outside tracks.
    private func trackIndex(at point: CGPoint) -> Int? {
        if !stackedSequences.isEmpty {
            for (index, info) in stackedSequences.enumerated() {
                if point.y >= info.yOffset && point.y < info.yOffset + info.height {
                    return index
                }
            }
        } else {
            // Fallback for simple track names
            for index in 0..<trackNames.count {
                let rowY = trackY + CGFloat(index) * (trackHeight + trackSpacing)
                if point.y >= rowY && point.y < rowY + trackHeight {
                    return index
                }
            }
        }
        return nil
    }
}
