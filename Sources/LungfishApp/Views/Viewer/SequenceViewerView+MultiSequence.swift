// SequenceViewerView+MultiSequence.swift - Multi-sequence rendering extension
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Extends SequenceViewerView to render multiple stacked sequences with per-sequence
// annotation tracks. Each sequence displays its annotations immediately below it,
// with visibility controllable globally or per-sequence.

import AppKit
import LungfishCore
import os.log

/// Logger for multi-sequence rendering
private let renderLogger = Logger(subsystem: "com.lungfish.browser", category: "MultiSequenceRender")

// MARK: - Zoom Threshold Constants for Multi-Sequence

/// Zoom thresholds for multi-sequence rendering (bp/pixel)
///
/// These thresholds define the rendering mode based on zoom level:
/// - BASE_MODE: < 10 bp/pixel - Individual colored bases with letters
/// - LINE_MODE: >= 10 bp/pixel - Simple gray horizontal line
///
/// Per user feedback: sequences should show as a simple line until zoomed in
/// enough to resolve individual bases. No intermediate "rainbow" block mode.
private enum SequenceZoomThresholds {
    /// Below this threshold: show individual base letters with colors
    /// At this zoom level, bases are large enough to read
    static let baseMode: Double = 10.0
}

// MARK: - Rendering Mode

/// Describes the current rendering mode based on zoom level
private enum SequenceRenderingMode {
    /// Individual bases with colored backgrounds and letter labels
    /// Used when zoom < 10 bp/pixel
    case bases

    /// Simple gray horizontal line showing sequence extent
    /// Used when zoom >= 10 bp/pixel
    case line

    /// Determines the rendering mode for a given bases-per-pixel scale
    static func forScale(_ basesPerPixel: Double) -> SequenceRenderingMode {
        if basesPerPixel < SequenceZoomThresholds.baseMode {
            return .bases
        } else {
            return .line
        }
    }
}

// MARK: - Annotation Track Constants

/// Layout constants for annotation tracks within sequence stacks
private enum AnnotationTrackLayout {
    /// Gap between sequence and annotation track
    static let sequenceAnnotationGap: CGFloat = 4

    /// Height of each annotation row
    static let annotationRowHeight: CGFloat = 16

    /// Spacing between annotation rows
    static let rowSpacing: CGFloat = 2

    /// Left margin for annotation track label
    static let labelLeftMargin: CGFloat = 6

    /// Font size for annotation track label
    static let labelFontSize: CGFloat = 8

    /// Minimum feature width in pixels
    static let minimumFeatureWidth: CGFloat = 2

    /// Gap between features for row assignment (in base pairs)
    static let featureGapBp: Int = 2
}

// MARK: - SequenceViewerView Multi-Sequence Extension

extension SequenceViewerView {

    // MARK: - Multi-Sequence Drawing

    /// Draws multiple stacked sequences with per-sequence annotation tracks.
    ///
    /// This method renders each sequence in its own track row, with the reference
    /// sequence (longest or first) at the top and additional sequences below.
    /// Each sequence's annotations are drawn directly beneath it, forming a
    /// visual unit of sequence + annotations.
    ///
    /// Annotation visibility can be controlled:
    /// - Globally via `MultiSequenceState.globalShowAnnotations`
    /// - Per-sequence via `StackedSequenceInfo.showAnnotations`
    ///
    /// - Parameters:
    ///   - sequences: Array of stacked sequence info objects
    ///   - frame: Reference frame for coordinate mapping
    ///   - context: Graphics context for drawing
    internal func drawStackedSequences(
        _ sequences: [StackedSequenceInfo],
        frame: ReferenceFrame,
        context: CGContext
    ) {
        renderLogger.debug("drawStackedSequences: Drawing \(sequences.count) sequences")

        // Get global annotation visibility setting
        let globalShowAnnotations = multiSequenceState?.globalShowAnnotations ?? true

        for stackedInfo in sequences {
            // Calculate track rect for this sequence (full height including annotations)
            let trackRect = CGRect(
                x: 0,
                y: stackedInfo.yOffset,
                width: bounds.width,
                height: stackedInfo.height
            )

            // Skip if completely outside visible area
            if trackRect.maxY < 0 || trackRect.minY > bounds.height {
                continue
            }

            // Draw this sequence track with its annotations
            drawSequenceTrack(
                stackedInfo: stackedInfo,
                frame: frame,
                context: context,
                rect: trackRect,
                globalShowAnnotations: globalShowAnnotations
            )
        }
    }

    /// Draws a single sequence track at the specified position.
    ///
    /// The track includes the sequence visualization at the top and any
    /// associated annotations directly below it. Annotations are only shown
    /// if both global and per-sequence visibility flags are enabled.
    ///
    /// Rendering mode is determined by zoom level:
    /// - BASE_MODE (< 10 bp/pixel): Individual colored bases with letters
    /// - BLOCK_MODE (10-500 bp/pixel): Colored blocks for dominant base
    /// - LINE_MODE (> 500 bp/pixel): Simple gray horizontal line
    ///
    /// - Parameters:
    ///   - stackedInfo: Information about this stacked sequence
    ///   - frame: Reference frame for coordinate mapping
    ///   - context: Graphics context for drawing
    ///   - rect: Rectangle to draw within (full track height)
    ///   - globalShowAnnotations: Global annotation visibility setting
    private func drawSequenceTrack(
        stackedInfo: StackedSequenceInfo,
        frame: ReferenceFrame,
        context: CGContext,
        rect: CGRect,
        globalShowAnnotations: Bool
    ) {
        let seq = stackedInfo.sequence
        let scale = frame.scale  // bp/pixel

        // Create a rect for just the sequence portion (top part of the track)
        let sequenceRect = CGRect(
            x: rect.minX,
            y: rect.minY,
            width: rect.width,
            height: stackedInfo.sequenceHeight
        )

        // Draw track separator for visual grouping
        drawTrackSeparator(context: context, rect: rect, isActive: stackedInfo.isActive)

        // Draw active indicator if this track is selected
        if stackedInfo.isActive {
            drawActiveIndicator(context: context, rect: sequenceRect)
        }

        // Draw reference indicator badge for reference sequence
        if stackedInfo.isReference && !stackedInfo.isActive {
            drawReferenceIndicator(context: context, rect: sequenceRect)
        }

        // Calculate sequence bounds relative to reference
        let seqStart = stackedInfo.alignmentOffset
        let seqEnd = seqStart + seq.length

        // Check if this sequence is visible in current view
        let visibleStart = Int(frame.start)
        let visibleEnd = Int(frame.end)

        if seqEnd < visibleStart || seqStart > visibleEnd {
            // Sequence not visible - draw placeholder
            drawSequenceOutOfRange(context: context, rect: sequenceRect, sequence: seq)
            return
        }

        // Determine rendering mode based on zoom level
        let renderMode = SequenceRenderingMode.forScale(scale)

        switch renderMode {
        case .bases:
            // High zoom (< 10 bp/pixel): show individual bases with letters
            drawBaseLevelSequenceInTrack(
                seq: seq,
                frame: frame,
                context: context,
                rect: sequenceRect,
                alignmentOffset: stackedInfo.alignmentOffset
            )

        case .line:
            // Low zoom (>= 10 bp/pixel): show simple gray line
            drawLineSequenceInTrack(
                seq: seq,
                frame: frame,
                context: context,
                rect: sequenceRect,
                alignmentOffset: stackedInfo.alignmentOffset
            )
        }

        // Note: Sequence labels are now displayed in TrackHeaderView on the left side,
        // so we no longer draw them inside the track to avoid redundancy.

        // Draw length indicator for shorter sequences
        if !stackedInfo.isReference {
            drawLengthIndicator(
                sequence: seq,
                frame: frame,
                context: context,
                rect: sequenceRect,
                alignmentOffset: stackedInfo.alignmentOffset
            )
        }

        // Determine if annotations should be shown for this track
        let shouldShowAnnotations = globalShowAnnotations && stackedInfo.showAnnotations

        // Draw annotations for this sequence directly below the sequence track
        if shouldShowAnnotations && !stackedInfo.annotations.isEmpty {
            let annotationStartY = stackedInfo.sequenceHeight + AnnotationTrackLayout.sequenceAnnotationGap

            // Draw annotation track label
            drawAnnotationTrackLabel(
                context: context,
                trackRect: rect,
                annotationStartY: annotationStartY,
                sequenceName: seq.name,
                annotationCount: stackedInfo.annotations.count
            )

            // Draw the annotations
            drawTrackAnnotations(
                stackedInfo.annotations,
                frame: frame,
                context: context,
                trackRect: rect,
                annotationStartY: annotationStartY,
                sequenceName: seq.name
            )
        } else if !stackedInfo.annotations.isEmpty && !shouldShowAnnotations {
            // Draw collapsed annotation indicator
            drawCollapsedAnnotationIndicator(
                context: context,
                rect: rect,
                sequenceHeight: stackedInfo.sequenceHeight,
                annotationCount: stackedInfo.annotations.count
            )
        }
    }

    // MARK: - Track Separator Drawing

    /// Draws a subtle separator line between sequence tracks for visual grouping.
    private func drawTrackSeparator(context: CGContext, rect: CGRect, isActive: Bool) {
        context.saveGState()

        // Draw subtle bottom border
        let separatorY = rect.maxY - 1
        context.setStrokeColor(NSColor.separatorColor.withAlphaComponent(0.3).cgColor)
        context.setLineWidth(1)
        context.move(to: CGPoint(x: 0, y: separatorY))
        context.addLine(to: CGPoint(x: rect.width, y: separatorY))
        context.strokePath()

        context.restoreGState()
    }

    // MARK: - Annotation Track Label Drawing

    /// Draws the label for an annotation track.
    ///
    /// The label appears at the left side of the annotation area and shows
    /// "Annotations" or the count of annotations for the sequence.
    ///
    /// - Parameters:
    ///   - context: Graphics context for drawing
    ///   - trackRect: The full track rectangle
    ///   - annotationStartY: Y offset where annotations start within track
    ///   - sequenceName: Name of the parent sequence
    ///   - annotationCount: Number of annotations in this track
    private func drawAnnotationTrackLabel(
        context: CGContext,
        trackRect: CGRect,
        annotationStartY: CGFloat,
        sequenceName: String,
        annotationCount: Int
    ) {
        let labelFont = NSFont.systemFont(ofSize: AnnotationTrackLayout.labelFontSize, weight: .medium)
        let labelText = "Annotations (\(annotationCount))"

        let attributes: [NSAttributedString.Key: Any] = [
            .font: labelFont,
            .foregroundColor: NSColor.tertiaryLabelColor
        ]

        let size = (labelText as NSString).size(withAttributes: attributes)

        // Position label at top-left of annotation area
        let labelX = AnnotationTrackLayout.labelLeftMargin
        let labelY = trackRect.minY + annotationStartY

        // Draw background pill for readability
        let pillRect = CGRect(
            x: labelX - 2,
            y: labelY - 1,
            width: size.width + 4,
            height: size.height + 2
        )

        context.saveGState()
        context.setFillColor(NSColor.textBackgroundColor.withAlphaComponent(0.7).cgColor)
        let pillPath = NSBezierPath(roundedRect: pillRect, xRadius: 2, yRadius: 2)
        pillPath.fill()
        context.restoreGState()

        (labelText as NSString).draw(at: CGPoint(x: labelX, y: labelY), withAttributes: attributes)
    }

    // MARK: - Collapsed Annotation Indicator

    /// Draws an indicator showing that annotations are collapsed/hidden.
    ///
    /// This provides visual feedback that annotations exist but are not shown,
    /// allowing users to expand them if needed.
    ///
    /// - Parameters:
    ///   - context: Graphics context for drawing
    ///   - rect: The full track rectangle
    ///   - sequenceHeight: Height of the sequence portion
    ///   - annotationCount: Number of hidden annotations
    private func drawCollapsedAnnotationIndicator(
        context: CGContext,
        rect: CGRect,
        sequenceHeight: CGFloat,
        annotationCount: Int
    ) {
        let indicatorY = rect.minY + sequenceHeight + 2
        let labelFont = NSFont.systemFont(ofSize: 7, weight: .regular)
        let labelText = "\(annotationCount) annotations (hidden)"

        let attributes: [NSAttributedString.Key: Any] = [
            .font: labelFont,
            .foregroundColor: NSColor.quaternaryLabelColor
        ]

        let size = (labelText as NSString).size(withAttributes: attributes)
        let labelX = AnnotationTrackLayout.labelLeftMargin

        // Draw indicator as small italicized text
        (labelText as NSString).draw(
            at: CGPoint(x: labelX, y: indicatorY),
            withAttributes: attributes
        )

        // Draw small expand chevron
        context.saveGState()
        context.setStrokeColor(NSColor.quaternaryLabelColor.cgColor)
        context.setLineWidth(1)

        let chevronX = labelX + size.width + 4
        let chevronY = indicatorY + size.height / 2
        let chevronSize: CGFloat = 4

        context.move(to: CGPoint(x: chevronX, y: chevronY - chevronSize / 2))
        context.addLine(to: CGPoint(x: chevronX + chevronSize / 2, y: chevronY))
        context.addLine(to: CGPoint(x: chevronX, y: chevronY + chevronSize / 2))
        context.strokePath()

        context.restoreGState()
    }

    // MARK: - Annotation Drawing for Multi-Sequence

    /// Draws annotations for a specific sequence track.
    ///
    /// Annotations are rendered directly below their parent sequence,
    /// grouped by the sequence they belong to rather than in a single combined track.
    /// Each annotation is filtered to only show features that match the sequence name.
    ///
    /// - Parameters:
    ///   - annotations: The annotations to draw
    ///   - frame: Reference frame for coordinate mapping
    ///   - context: Graphics context for drawing
    ///   - trackRect: The full track rectangle (for clipping)
    ///   - annotationStartY: Y offset within the track where annotations start
    ///   - sequenceName: Name of the parent sequence for filtering
    private func drawTrackAnnotations(
        _ annotations: [SequenceAnnotation],
        frame: ReferenceFrame,
        context: CGContext,
        trackRect: CGRect,
        annotationStartY: CGFloat,
        sequenceName: String
    ) {
        let visibleBases = frame.end - frame.start
        let pixelsPerBase = bounds.width / CGFloat(max(1, visibleBases))

        // Leave space for the annotation label at the top
        let labelHeight: CGFloat = 12
        let drawStartY = annotationStartY + labelHeight

        // Standard annotation colors by type
        let typeColors: [AnnotationType: NSColor] = [
            .gene: NSColor(calibratedRed: 0.2, green: 0.6, blue: 0.2, alpha: 1.0),
            .cds: NSColor(calibratedRed: 0.2, green: 0.4, blue: 0.8, alpha: 1.0),
            .exon: NSColor(calibratedRed: 0.6, green: 0.3, blue: 0.8, alpha: 1.0),
            .mRNA: NSColor(calibratedRed: 0.8, green: 0.4, blue: 0.2, alpha: 1.0),
            .transcript: NSColor(calibratedRed: 0.7, green: 0.5, blue: 0.3, alpha: 1.0),
            .misc_feature: NSColor(calibratedRed: 0.5, green: 0.5, blue: 0.5, alpha: 1.0),
            .region: NSColor(calibratedRed: 0.4, green: 0.7, blue: 0.7, alpha: 1.0),
            .primer: NSColor(calibratedRed: 0.2, green: 0.8, blue: 0.2, alpha: 1.0),
            .restrictionSite: NSColor(calibratedRed: 0.8, green: 0.2, blue: 0.2, alpha: 1.0),
        ]

        let visibleStart = Int(frame.start)
        let visibleEnd = Int(frame.end)

        // Track row assignments to avoid overlaps
        var rowEndPositions: [CGFloat] = []

        // Filter annotations to only those belonging to this sequence
        let sequenceAnnotations = annotations.filter { annotation in
            annotation.belongsToSequence(named: sequenceName)
        }

        for annotation in sequenceAnnotations {
            // Get the first interval (simplified - could handle discontinuous features)
            guard let interval = annotation.intervals.first else { continue }

            // Check if annotation is visible
            if interval.end < visibleStart || interval.start > visibleEnd {
                continue
            }

            // Calculate screen coordinates
            let rawStartX = CGFloat(interval.start - visibleStart) * pixelsPerBase
            let endX = CGFloat(interval.end - visibleStart) * pixelsPerBase
            // Clamp startX to view bounds to prevent drawing into gutter/outside area
            let startX = max(0, rawStartX)
            let width = max(AnnotationTrackLayout.minimumFeatureWidth, endX - startX)

            // Find a row that doesn't overlap
            var row = 0
            for (i, endPos) in rowEndPositions.enumerated() {
                if startX >= endPos + 2 {
                    row = i
                    break
                }
                row = i + 1
            }

            // Extend rows array if needed
            while rowEndPositions.count <= row {
                rowEndPositions.append(0)
            }
            rowEndPositions[row] = startX + width

            // Calculate Y position relative to track
            let y = trackRect.minY + drawStartY + CGFloat(row) * (
                AnnotationTrackLayout.annotationRowHeight + AnnotationTrackLayout.rowSpacing
            )

            // Get color for this annotation type
            let color = typeColors[annotation.type] ?? NSColor.gray

            // Draw annotation box
            let annotRect = CGRect(
                x: startX,
                y: y,
                width: width,
                height: AnnotationTrackLayout.annotationRowHeight
            )
            context.setFillColor(color.cgColor)
            context.fill(annotRect)

            // Draw border
            context.setStrokeColor(color.withAlphaComponent(0.8).cgColor)
            context.setLineWidth(1)
            context.stroke(annotRect)

            // Draw label if space permits
            if width > 30 {
                let label = annotation.name
                let labelAttributes: [NSAttributedString.Key: Any] = [
                    .font: NSFont.systemFont(ofSize: 8, weight: .medium),
                    .foregroundColor: NSColor.white,
                ]
                let labelSize = (label as NSString).size(withAttributes: labelAttributes)

                if labelSize.width < width - 4 {
                    let labelX = startX + (width - labelSize.width) / 2
                    let labelY = y + (AnnotationTrackLayout.annotationRowHeight - labelSize.height) / 2
                    (label as NSString).draw(at: CGPoint(x: labelX, y: labelY), withAttributes: labelAttributes)
                }
            }

            // Draw strand direction indicator
            if annotation.strand == .forward || annotation.strand == .reverse {
                let arrowSize: CGFloat = 5
                context.setFillColor(NSColor.white.cgColor)

                if annotation.strand == .forward {
                    // Arrow pointing right
                    let arrowX = min(startX + width - arrowSize - 2, bounds.width - arrowSize)
                    let arrowY = y + AnnotationTrackLayout.annotationRowHeight / 2
                    context.move(to: CGPoint(x: arrowX, y: arrowY - arrowSize/2))
                    context.addLine(to: CGPoint(x: arrowX + arrowSize, y: arrowY))
                    context.addLine(to: CGPoint(x: arrowX, y: arrowY + arrowSize/2))
                    context.closePath()
                    context.fillPath()
                } else {
                    // Arrow pointing left
                    let arrowX = max(startX + 2, 0)
                    let arrowY = y + AnnotationTrackLayout.annotationRowHeight / 2
                    context.move(to: CGPoint(x: arrowX + arrowSize, y: arrowY - arrowSize/2))
                    context.addLine(to: CGPoint(x: arrowX, y: arrowY))
                    context.addLine(to: CGPoint(x: arrowX + arrowSize, y: arrowY + arrowSize/2))
                    context.closePath()
                    context.fillPath()
                }
            }
        }
    }

    // MARK: - Track Decoration Drawing

    /// Draws the active track indicator (highlight border).
    private func drawActiveIndicator(context: CGContext, rect: CGRect) {
        context.saveGState()

        // Draw subtle highlight background
        context.setFillColor(NSColor.selectedContentBackgroundColor.withAlphaComponent(0.1).cgColor)
        context.fill(rect)

        // Draw left border indicator
        context.setFillColor(NSColor.controlAccentColor.cgColor)
        context.fill(CGRect(x: 0, y: rect.minY, width: 3, height: rect.height))

        context.restoreGState()
    }

    /// Draws the reference sequence indicator badge.
    private func drawReferenceIndicator(context: CGContext, rect: CGRect) {
        let badgeWidth: CGFloat = 4
        context.saveGState()
        context.setFillColor(NSColor.systemGray.withAlphaComponent(0.5).cgColor)
        context.fill(CGRect(x: 0, y: rect.minY, width: badgeWidth, height: rect.height))
        context.restoreGState()
    }

    /// Draws placeholder for sequences outside visible range.
    private func drawSequenceOutOfRange(context: CGContext, rect: CGRect, sequence: Sequence) {
        context.saveGState()

        // Draw faded background
        context.setFillColor(NSColor.tertiarySystemFill.cgColor)
        context.fill(rect.insetBy(dx: 4, dy: 2))

        // Draw message
        let message = "\(sequence.name) (not in view)"
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 10),
            .foregroundColor: NSColor.tertiaryLabelColor
        ]
        let size = (message as NSString).size(withAttributes: attributes)
        let x = rect.midX - size.width / 2
        let y = rect.midY - size.height / 2
        (message as NSString).draw(at: CGPoint(x: x, y: y), withAttributes: attributes)

        context.restoreGState()
    }

    /// Draws the sequence name label in the track.
    private func drawSequenceLabel(name: String, context: CGContext, rect: CGRect, isReference: Bool) {
        let labelFont = NSFont.systemFont(ofSize: 9, weight: isReference ? .semibold : .regular)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: labelFont,
            .foregroundColor: NSColor.secondaryLabelColor
        ]

        let labelText = isReference ? "\(name) (ref)" : name
        let size = (labelText as NSString).size(withAttributes: attributes)

        // Position in top-left of track with padding
        let x: CGFloat = 6
        let y = rect.minY + 2

        // Draw background pill for readability
        let pillRect = CGRect(x: x - 2, y: y - 1, width: size.width + 4, height: size.height + 2)
        context.saveGState()
        context.setFillColor(NSColor.textBackgroundColor.withAlphaComponent(0.8).cgColor)
        let pillPath = NSBezierPath(roundedRect: pillRect, xRadius: 3, yRadius: 3)
        pillPath.fill()
        context.restoreGState()

        (labelText as NSString).draw(at: CGPoint(x: x, y: y), withAttributes: attributes)
    }

    /// Draws length indicator showing where shorter sequences end.
    private func drawLengthIndicator(
        sequence: Sequence,
        frame: ReferenceFrame,
        context: CGContext,
        rect: CGRect,
        alignmentOffset: Int
    ) {
        let seqEnd = alignmentOffset + sequence.length
        let visibleStart = frame.start
        let visibleEnd = frame.end
        let pixelsPerBase = bounds.width / CGFloat(max(1, visibleEnd - visibleStart))

        // Only show if sequence ends within visible range
        guard Double(seqEnd) > visibleStart && Double(seqEnd) < visibleEnd else { return }

        let endX = CGFloat(seqEnd - Int(visibleStart)) * pixelsPerBase

        context.saveGState()

        // Draw vertical line at sequence end
        context.setStrokeColor(NSColor.tertiaryLabelColor.cgColor)
        context.setLineWidth(1)
        context.setLineDash(phase: 0, lengths: [3, 2])
        context.move(to: CGPoint(x: endX, y: rect.minY))
        context.addLine(to: CGPoint(x: endX, y: rect.maxY))
        context.strokePath()

        // Draw "empty" region pattern beyond sequence
        context.setFillColor(NSColor.quaternarySystemFill.cgColor)
        context.fill(CGRect(x: endX, y: rect.minY, width: bounds.width - endX, height: rect.height))

        context.restoreGState()
    }

    // MARK: - Sequence Rendering at Different Zoom Levels

    /// Draws base-level sequence in a track (high zoom, < 10 bp/pixel).
    ///
    /// At this zoom level, individual bases are large enough to be readable.
    /// Each base is drawn as a colored rectangle with its letter label.
    ///
    /// Colors follow IGV convention:
    /// - A = Green
    /// - T = Red
    /// - C = Blue
    /// - G = Orange/Yellow
    /// - N = Gray
    ///
    /// - Parameters:
    ///   - seq: The sequence to draw
    ///   - frame: Reference frame for coordinate mapping
    ///   - context: Graphics context for drawing
    ///   - rect: Rectangle to draw within
    ///   - alignmentOffset: Position offset for sequence alignment
    private func drawBaseLevelSequenceInTrack(
        seq: Sequence,
        frame: ReferenceFrame,
        context: CGContext,
        rect: CGRect,
        alignmentOffset: Int
    ) {
        let visibleStart = max(0, Int(frame.start) - alignmentOffset)
        let visibleEnd = min(seq.length, Int(frame.end) - alignmentOffset + 1)

        guard visibleStart < visibleEnd else { return }

        let visibleBases = frame.end - frame.start
        let pixelsPerBase = bounds.width / CGFloat(max(1, visibleBases))

        let fontSize = min(pixelsPerBase * 0.75, rect.height * 0.8)
        let showLetters = pixelsPerBase >= 8 && fontSize >= 6
        let font = NSFont.monospacedSystemFont(ofSize: max(6, fontSize), weight: .bold)

        // Inset drawing area slightly for visual clarity
        let drawRect = rect.insetBy(dx: 0, dy: 2)

        for i in visibleStart..<visibleEnd {
            let genomicPos = i + alignmentOffset
            let x = CGFloat(genomicPos - Int(frame.start)) * pixelsPerBase
            let baseChar = seq[i]

            // Draw background color
            let color = BaseColors.color(for: baseChar)
            context.setFillColor(color.cgColor)
            context.fill(CGRect(
                x: x,
                y: drawRect.minY,
                width: max(1, pixelsPerBase - 0.5),
                height: drawRect.height
            ))

            // Draw letter if space permits
            if showLetters {
                let attributes: [NSAttributedString.Key: Any] = [
                    .font: font,
                    .foregroundColor: NSColor.white
                ]
                // Convert T to U if in RNA mode
                var displayBase = String(baseChar).uppercased()
                if isRNAMode && displayBase == "T" {
                    displayBase = "U"
                }
                let strSize = (displayBase as NSString).size(withAttributes: attributes)
                let strX = x + (pixelsPerBase - strSize.width) / 2
                let strY = drawRect.minY + (drawRect.height - strSize.height) / 2
                (displayBase as NSString).draw(at: CGPoint(x: strX, y: strY), withAttributes: attributes)
            }
        }
    }

    /// Draws block-level sequence in a track (medium zoom, 10-500 bp/pixel).
    ///
    /// At this zoom level, multiple bases are aggregated into colored blocks.
    /// Each block shows the dominant base color for that region.
    ///
    /// Colors follow IGV convention:
    /// - A = Green
    /// - T = Red
    /// - C = Blue
    /// - G = Orange/Yellow
    /// - N = Gray
    ///
    /// - Parameters:
    ///   - seq: The sequence to draw
    ///   - frame: Reference frame for coordinate mapping
    ///   - context: Graphics context for drawing
    ///   - rect: Rectangle to draw within
    ///   - alignmentOffset: Position offset for sequence alignment
    private func drawBlockLevelSequenceInTrack(
        seq: Sequence,
        frame: ReferenceFrame,
        context: CGContext,
        rect: CGRect,
        alignmentOffset: Int
    ) {
        let visibleStart = max(0, Int(frame.start) - alignmentOffset)
        let visibleEnd = min(seq.length, Int(frame.end) - alignmentOffset + 1)

        guard visibleStart < visibleEnd else { return }

        let visibleBases = frame.end - frame.start
        let pixelsPerBase = bounds.width / CGFloat(max(1, visibleBases))
        let basesPerBin = max(1, Int(frame.scale))

        let drawRect = rect.insetBy(dx: 0, dy: 2)

        for binStart in stride(from: visibleStart, to: visibleEnd, by: basesPerBin) {
            let binEnd = min(binStart + basesPerBin, visibleEnd)
            let genomicStart = binStart + alignmentOffset
            let x = CGFloat(genomicStart - Int(frame.start)) * pixelsPerBase
            let width = CGFloat(binEnd - binStart) * pixelsPerBase

            // Find dominant base in this bin
            var counts: [Character: Int] = ["A": 0, "T": 0, "C": 0, "G": 0, "N": 0]
            for i in binStart..<binEnd {
                let base = Character(seq[i].uppercased())
                counts[base, default: 0] += 1
            }
            let dominantBase = counts.max(by: { $0.value < $1.value })?.key ?? "N"

            let color = BaseColors.color(for: dominantBase)
            context.setFillColor(color.cgColor)
            context.fill(CGRect(x: x, y: drawRect.minY, width: max(1, width), height: drawRect.height))
        }
    }

    /// Draws a simple line representation for very zoomed out view (> 500 bp/pixel).
    ///
    /// When zoomed out beyond 500 bp/pixel, individual bases and colored blocks
    /// become uninformative visual noise. This method draws a clean, simple gray
    /// line to represent the sequence extent without visual clutter.
    ///
    /// This addresses user feedback that "rainbow of colors" at low zoom is not
    /// informative and should be replaced with a simple line representation.
    ///
    /// - Parameters:
    ///   - seq: The sequence to draw
    ///   - frame: Reference frame for coordinate mapping
    ///   - context: Graphics context for drawing
    ///   - rect: Rectangle to draw within
    ///   - alignmentOffset: Position offset for sequence alignment
    private func drawLineSequenceInTrack(
        seq: Sequence,
        frame: ReferenceFrame,
        context: CGContext,
        rect: CGRect,
        alignmentOffset: Int
    ) {
        let seqStart = alignmentOffset
        let seqEnd = alignmentOffset + seq.length

        let visibleBases = frame.end - frame.start
        let pixelsPerBase = bounds.width / CGFloat(max(1, visibleBases))

        // Calculate the visible portion of the sequence
        let visibleSeqStart = max(seqStart, Int(frame.start))
        let visibleSeqEnd = min(seqEnd, Int(frame.end))

        guard visibleSeqStart < visibleSeqEnd else { return }

        let startX = CGFloat(visibleSeqStart - Int(frame.start)) * pixelsPerBase
        let endX = CGFloat(visibleSeqEnd - Int(frame.start)) * pixelsPerBase
        let lineWidth = max(1, endX - startX)

        let drawRect = rect.insetBy(dx: 0, dy: 2)

        // Draw a simple gray line to represent the sequence
        let lineColor = NSColor.systemGray
        let lineY = drawRect.midY
        let lineThickness: CGFloat = 4

        context.saveGState()

        // Draw sequence extent as a solid bar
        context.setFillColor(lineColor.cgColor)
        context.fill(CGRect(
            x: max(0, startX),
            y: lineY - lineThickness / 2,
            width: lineWidth,
            height: lineThickness
        ))

        // Draw subtle border for definition
        context.setStrokeColor(lineColor.withAlphaComponent(0.7).cgColor)
        context.setLineWidth(1)
        context.stroke(CGRect(
            x: max(0, startX),
            y: lineY - lineThickness / 2,
            width: lineWidth,
            height: lineThickness
        ))

        context.restoreGState()
    }
}

// MARK: - Hit Testing for Multi-Sequence

extension SequenceViewerView {

    /// Returns the stacked sequence info at the given point.
    ///
    /// - Parameter point: Point in view coordinates
    /// - Returns: The stacked sequence info at that point, or nil
    internal func stackedSequenceAtPoint(_ point: NSPoint) -> StackedSequenceInfo? {
        guard let multiState = multiSequenceState else { return nil }
        return multiState.sequenceInfo(atY: point.y)
    }

    /// Converts a point to base position for a specific sequence track.
    ///
    /// - Parameters:
    ///   - point: Point in view coordinates
    ///   - stackedInfo: The stacked sequence info
    ///   - frame: Reference frame for coordinate mapping
    /// - Returns: The base position in the sequence
    internal func basePosition(
        atPoint point: NSPoint,
        forSequence stackedInfo: StackedSequenceInfo,
        frame: ReferenceFrame
    ) -> Int {
        let visibleBases = frame.end - frame.start
        let basesPerPixel = visibleBases / Double(bounds.width)
        let baseOffset = Double(point.x) * basesPerPixel
        let genomicPosition = Int(frame.start + baseOffset)

        // Adjust for alignment offset and clamp to sequence bounds
        let seqPosition = genomicPosition - stackedInfo.alignmentOffset
        return max(0, min(stackedInfo.sequence.length - 1, seqPosition))
    }

    /// Checks if a point is within the annotation area of a sequence track.
    ///
    /// - Parameters:
    ///   - point: Point in view coordinates
    ///   - stackedInfo: The stacked sequence info
    /// - Returns: True if the point is within the annotation area
    internal func isPointInAnnotationArea(
        _ point: NSPoint,
        forSequence stackedInfo: StackedSequenceInfo
    ) -> Bool {
        let annotationStartY = stackedInfo.yOffset + stackedInfo.sequenceHeight
        let annotationEndY = stackedInfo.yOffset + stackedInfo.height

        return point.y >= annotationStartY && point.y < annotationEndY
    }

    /// Returns the annotation at the given point, if any.
    ///
    /// - Parameters:
    ///   - point: Point in view coordinates
    ///   - stackedInfo: The stacked sequence info
    ///   - frame: Reference frame for coordinate mapping
    /// - Returns: The annotation at that point, or nil
    internal func annotationAtPoint(
        _ point: NSPoint,
        forSequence stackedInfo: StackedSequenceInfo,
        frame: ReferenceFrame
    ) -> SequenceAnnotation? {
        guard isPointInAnnotationArea(point, forSequence: stackedInfo) else {
            return nil
        }

        let globalShowAnnotations = multiSequenceState?.globalShowAnnotations ?? true
        guard globalShowAnnotations && stackedInfo.showAnnotations else {
            return nil
        }

        let visibleBases = frame.end - frame.start
        let basesPerPixel = visibleBases / Double(bounds.width)
        let clickedPosition = Int(frame.start + Double(point.x) * basesPerPixel)

        // Find annotation at this position
        for annotation in stackedInfo.annotations {
            guard annotation.belongsToSequence(named: stackedInfo.sequence.name) else {
                continue
            }

            if annotation.overlaps(start: clickedPosition, end: clickedPosition + 1) {
                return annotation
            }
        }

        return nil
    }
}
