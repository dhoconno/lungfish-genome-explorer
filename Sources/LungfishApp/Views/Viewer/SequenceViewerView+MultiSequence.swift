// SequenceViewerView+MultiSequence.swift - Multi-sequence rendering extension
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Extends SequenceViewerView to render multiple stacked sequences.

import AppKit
import LungfishCore
import os.log

/// Logger for multi-sequence rendering
private let renderLogger = Logger(subsystem: "com.lungfish.browser", category: "MultiSequenceRender")

// MARK: - Zoom Threshold Constants for Multi-Sequence

/// Zoom thresholds for multi-sequence rendering (bp/pixel)
private enum MultiSequenceZoomThresholds {
    /// Below this: show individual base letters
    static let showLetters: Double = 10.0
    /// Below this: show colored bars
    static let showBars: Double = 100.0
    /// Above this: show simple line representation
    static let showLine: Double = 500.0
}

// MARK: - SequenceViewerView Multi-Sequence Extension

extension SequenceViewerView {

    // MARK: - Multi-Sequence Drawing

    /// Draws multiple stacked sequences.
    ///
    /// This method renders each sequence in its own track row, with the reference
    /// sequence (longest or first) at the top and additional sequences below.
    /// Each sequence's annotations are drawn directly beneath it.
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
                rect: trackRect
            )
        }
    }

    /// Draws a single sequence track at the specified position.
    ///
    /// The track includes the sequence visualization at the top and any
    /// associated annotations directly below it.
    ///
    /// - Parameters:
    ///   - stackedInfo: Information about this stacked sequence
    ///   - frame: Reference frame for coordinate mapping
    ///   - context: Graphics context for drawing
    ///   - rect: Rectangle to draw within (full track height)
    private func drawSequenceTrack(
        stackedInfo: StackedSequenceInfo,
        frame: ReferenceFrame,
        context: CGContext,
        rect: CGRect
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
        if scale < MultiSequenceZoomThresholds.showLetters {
            // High zoom: show individual bases with letters
            drawBaseLevelSequenceInTrack(
                seq: seq,
                frame: frame,
                context: context,
                rect: sequenceRect,
                alignmentOffset: stackedInfo.alignmentOffset
            )
        } else if scale < MultiSequenceZoomThresholds.showBars {
            // Medium zoom: show colored bars without letters
            drawBlockLevelSequenceInTrack(
                seq: seq,
                frame: frame,
                context: context,
                rect: sequenceRect,
                alignmentOffset: stackedInfo.alignmentOffset
            )
        } else if scale < MultiSequenceZoomThresholds.showLine {
            // Low zoom: show GC content / density
            drawOverviewSequenceInTrack(
                seq: seq,
                frame: frame,
                context: context,
                rect: sequenceRect,
                alignmentOffset: stackedInfo.alignmentOffset
            )
        } else {
            // Very low zoom: show simple line representation
            drawLineSequenceInTrack(
                seq: seq,
                frame: frame,
                context: context,
                rect: sequenceRect,
                alignmentOffset: stackedInfo.alignmentOffset
            )
        }

        // Draw sequence label in track
        drawSequenceLabel(
            name: seq.name,
            context: context,
            rect: sequenceRect,
            isReference: stackedInfo.isReference
        )

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

        // Draw annotations for this sequence directly below the sequence track
        if !stackedInfo.annotations.isEmpty {
            let annotationStartY = stackedInfo.sequenceHeight + 4  // Small gap after sequence
            drawTrackAnnotations(
                stackedInfo.annotations,
                frame: frame,
                context: context,
                trackRect: rect,
                annotationStartY: annotationStartY
            )
        }
    }

    // MARK: - Annotation Drawing for Multi-Sequence

    /// Draws annotations for a specific sequence track.
    ///
    /// Annotations are rendered directly below their parent sequence,
    /// grouped by the sequence they belong to rather than in a single combined track.
    ///
    /// - Parameters:
    ///   - annotations: The annotations to draw
    ///   - frame: Reference frame for coordinate mapping
    ///   - context: Graphics context for drawing
    ///   - trackRect: The full track rectangle (for clipping)
    ///   - annotationStartY: Y offset within the track where annotations start
    private func drawTrackAnnotations(
        _ annotations: [SequenceAnnotation],
        frame: ReferenceFrame,
        context: CGContext,
        trackRect: CGRect,
        annotationStartY: CGFloat
    ) {
        let visibleBases = frame.end - frame.start
        let pixelsPerBase = bounds.width / CGFloat(max(1, visibleBases))

        // Annotation layout constants
        let annotationRowHeight: CGFloat = 16
        let rowSpacing: CGFloat = 2

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

        for annotation in annotations {
            // Get the first interval (simplified - could handle discontinuous features)
            guard let interval = annotation.intervals.first else { continue }

            // Check if annotation is visible
            if interval.end < visibleStart || interval.start > visibleEnd {
                continue
            }

            // Calculate screen coordinates
            let startX = CGFloat(interval.start - visibleStart) * pixelsPerBase
            let endX = CGFloat(interval.end - visibleStart) * pixelsPerBase
            let width = max(2, endX - startX)

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
            let y = trackRect.minY + annotationStartY + CGFloat(row) * (annotationRowHeight + rowSpacing)

            // Get color for this annotation type
            let color = typeColors[annotation.type] ?? NSColor.gray

            // Draw annotation box
            let annotRect = CGRect(x: startX, y: y, width: width, height: annotationRowHeight)
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
                    let labelY = y + (annotationRowHeight - labelSize.height) / 2
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
                    let arrowY = y + annotationRowHeight / 2
                    context.move(to: CGPoint(x: arrowX, y: arrowY - arrowSize/2))
                    context.addLine(to: CGPoint(x: arrowX + arrowSize, y: arrowY))
                    context.addLine(to: CGPoint(x: arrowX, y: arrowY + arrowSize/2))
                    context.closePath()
                    context.fillPath()
                } else {
                    // Arrow pointing left
                    let arrowX = max(startX + 2, 0)
                    let arrowY = y + annotationRowHeight / 2
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

    /// Draws base-level sequence in a track (high zoom).
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
                let str = String(baseChar).uppercased()
                let strSize = (str as NSString).size(withAttributes: attributes)
                let strX = x + (pixelsPerBase - strSize.width) / 2
                let strY = drawRect.minY + (drawRect.height - strSize.height) / 2
                (str as NSString).draw(at: CGPoint(x: strX, y: strY), withAttributes: attributes)
            }
        }
    }

    /// Draws block-level sequence in a track (medium zoom).
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

            // Find dominant base
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

    /// Draws overview sequence in a track (low zoom - GC content).
    private func drawOverviewSequenceInTrack(
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
        let binSize = max(1, Int(frame.scale * 2))

        let drawRect = rect.insetBy(dx: 0, dy: 2)

        // GC content colors
        let lowGCColor = NSColor(calibratedRed: 0.2, green: 0.4, blue: 0.8, alpha: 1.0)
        let highGCColor = NSColor(calibratedRed: 0.8, green: 0.2, blue: 0.2, alpha: 1.0)

        for binStart in stride(from: visibleStart, to: visibleEnd, by: binSize) {
            let binEnd = min(binStart + binSize, visibleEnd)
            let genomicStart = binStart + alignmentOffset
            let x = CGFloat(genomicStart - Int(frame.start)) * pixelsPerBase
            let width = CGFloat(binEnd - binStart) * pixelsPerBase

            // Calculate GC content
            var gcCount = 0
            var totalCount = 0
            for i in binStart..<binEnd {
                let base = seq[i].uppercased().first ?? "N"
                if base == "G" || base == "C" {
                    gcCount += 1
                }
                totalCount += 1
            }
            let gcContent = totalCount > 0 ? CGFloat(gcCount) / CGFloat(totalCount) : 0.5

            // Interpolate color
            let color = interpolateColorForTrack(from: lowGCColor, to: highGCColor, factor: gcContent)
            context.setFillColor(color.cgColor)
            context.fill(CGRect(x: x, y: drawRect.minY, width: max(1, width), height: drawRect.height))
        }
    }

    /// Draws a simple line representation for very zoomed out view.
    ///
    /// When zoomed out beyond the line threshold, individual bases and GC content
    /// become meaningless visual noise. This method draws a clean, simple line to
    /// represent the sequence extent without visual clutter.
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

    /// Interpolates between two colors.
    private func interpolateColorForTrack(from: NSColor, to: NSColor, factor: CGFloat) -> NSColor {
        let f = max(0, min(1, factor))
        let fromComponents = from.cgColor.components ?? [0, 0, 0, 1]
        let toComponents = to.cgColor.components ?? [0, 0, 0, 1]

        let r = fromComponents[0] + (toComponents[0] - fromComponents[0]) * f
        let g = fromComponents[1] + (toComponents[1] - fromComponents[1]) * f
        let b = fromComponents[2] + (toComponents[2] - fromComponents[2]) * f

        return NSColor(calibratedRed: r, green: g, blue: b, alpha: 1.0)
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
}
