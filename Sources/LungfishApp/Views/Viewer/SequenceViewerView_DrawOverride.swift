// SequenceViewerView_DrawOverride.swift - Modified draw method with multi-sequence support
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// IMPORTANT: This file contains the REPLACEMENT code for the draw() method in
// SequenceViewerView (located in ViewerViewController.swift around line 893).
//
// To integrate multi-sequence support:
// 1. Replace the existing draw(_ dirtyRect:) method with the one below
// 2. Add the helper method drawAnnotationsAtOffset()
//
// The changes preserve all existing functionality while adding multi-sequence stacking.

import AppKit
import LungfishCore
import os.log

// ============================================================================
// REPLACEMENT CODE - Copy this into SequenceViewerView in ViewerViewController.swift
// Replace lines 893-929 (the draw method) with the following:
// ============================================================================

/*

    // MARK: - Drawing

    public override var isFlipped: Bool { true }

    public override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        guard let context = NSGraphicsContext.current?.cgContext else {
            logger.warning("SequenceViewerView.draw: No graphics context available")
            return
        }

        // Background
        if isDragActive {
            // Highlight when dragging
            context.setFillColor(NSColor.selectedContentBackgroundColor.withAlphaComponent(0.1).cgColor)
        } else {
            context.setFillColor(NSColor.textBackgroundColor.cgColor)
        }
        context.fill(bounds)

        // Draw drag border if active
        if isDragActive {
            context.setStrokeColor(NSColor.selectedContentBackgroundColor.cgColor)
            context.setLineWidth(3)
            context.stroke(bounds.insetBy(dx: 1.5, dy: 1.5))
        }

        // Get reference frame for coordinate mapping
        guard let frame = viewController?.referenceFrame else {
            drawPlaceholder(context: context)
            return
        }

        // Check for multi-sequence mode first
        if shouldDrawMultiSequence {
            // Multi-sequence stacked drawing
            logger.debug("SequenceViewerView.draw: Drawing \(self.sequenceCount) stacked sequences")
            drawMultiSequenceContent(frame: frame, context: context)

            // Draw selection highlight on active track
            // (handled inside drawMultiSequenceContent)

            // Draw annotations below all sequence tracks
            if showAnnotations && !annotations.isEmpty {
                drawAnnotationsAtOffset(
                    yOffset: multiSequenceAnnotationTrackY,
                    frame: frame,
                    context: context
                )
            }

            // Draw multi-sequence info summary
            drawMultiSequenceInfo(frame: frame, context: context)

        } else if let seq = sequence {
            // Single sequence mode (original behavior)
            logger.debug("SequenceViewerView.draw: Drawing sequence '\(seq.name, privacy: .public)' in bounds \(self.bounds.width)x\(self.bounds.height)")
            drawSequence(seq, frame: frame, context: context)

        } else {
            // No sequence loaded
            drawPlaceholder(context: context)
        }
    }

    /// Draws annotations at a custom Y offset (for multi-sequence mode).
    ///
    /// This is a variant of drawAnnotations that allows specifying the Y position
    /// where annotations should start, rather than using the fixed annotationTrackY.
    private func drawAnnotationsAtOffset(
        yOffset: CGFloat,
        frame: ReferenceFrame,
        context: CGContext
    ) {
        let visibleBases = frame.end - frame.start
        let pixelsPerBase = bounds.width / CGFloat(max(1, visibleBases))

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

        // Filter annotations based on visible types and filter text
        let filteredAnnotations = annotations.filter { annotation in
            guard visibleAnnotationTypes.contains(annotation.type) else { return false }
            if !annotationFilterText.isEmpty {
                let lowercaseFilter = annotationFilterText.lowercased()
                let nameMatches = annotation.name.lowercased().contains(lowercaseFilter)
                let noteMatches = annotation.note?.lowercased().contains(lowercaseFilter) ?? false
                if !nameMatches && !noteMatches { return false }
            }
            return true
        }

        for annotation in filteredAnnotations {
            guard let interval = annotation.intervals.first else { continue }
            if interval.end < visibleStart || interval.start > visibleEnd { continue }

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

            while rowEndPositions.count <= row {
                rowEndPositions.append(0)
            }
            rowEndPositions[row] = startX + width

            let y = yOffset + CGFloat(row) * (annotationHeight + annotationRowSpacing)

            // Get color
            let color: NSColor
            if let annotationColor = annotation.color {
                color = NSColor(
                    calibratedRed: annotationColor.red,
                    green: annotationColor.green,
                    blue: annotationColor.blue,
                    alpha: annotationColor.alpha
                )
            } else {
                color = typeColors[annotation.type] ?? NSColor.gray
            }

            // Draw annotation box
            let annotRect = CGRect(x: startX, y: y, width: width, height: annotationHeight)
            context.setFillColor(color.cgColor)
            context.fill(annotRect)

            // Draw border
            context.setStrokeColor(color.withAlphaComponent(0.8).cgColor)
            context.setLineWidth(1)
            context.stroke(annotRect)

            // Draw selection highlight if selected
            if let selected = selectedAnnotation, selected.id == annotation.id {
                drawAnnotationSelectionHighlight(rect: annotRect, context: context)
            }

            // Draw label if space permits
            if width > 30 {
                let label = annotation.name
                let labelAttributes: [NSAttributedString.Key: Any] = [
                    .font: NSFont.systemFont(ofSize: 9, weight: .medium),
                    .foregroundColor: NSColor.white,
                ]
                let labelSize = (label as NSString).size(withAttributes: labelAttributes)

                if labelSize.width < width - 4 {
                    let labelX = startX + (width - labelSize.width) / 2
                    let labelY = y + (annotationHeight - labelSize.height) / 2
                    (label as NSString).draw(at: CGPoint(x: labelX, y: labelY), withAttributes: labelAttributes)
                }
            }

            // Draw strand direction indicator
            if annotation.strand == .forward || annotation.strand == .reverse {
                let arrowSize: CGFloat = 6
                context.setFillColor(NSColor.white.cgColor)

                if annotation.strand == .forward {
                    let arrowX = min(startX + width - arrowSize - 2, bounds.width - arrowSize)
                    let arrowY = y + annotationHeight / 2
                    context.move(to: CGPoint(x: arrowX, y: arrowY - arrowSize/2))
                    context.addLine(to: CGPoint(x: arrowX + arrowSize, y: arrowY))
                    context.addLine(to: CGPoint(x: arrowX, y: arrowY + arrowSize/2))
                    context.closePath()
                    context.fillPath()
                } else {
                    let arrowX = max(startX + 2, 0)
                    let arrowY = y + annotationHeight / 2
                    context.move(to: CGPoint(x: arrowX + arrowSize, y: arrowY - arrowSize/2))
                    context.addLine(to: CGPoint(x: arrowX, y: arrowY))
                    context.addLine(to: CGPoint(x: arrowX + arrowSize, y: arrowY + arrowSize/2))
                    context.closePath()
                    context.fillPath()
                }
            }
        }
    }

    /// Draws multi-sequence summary information.
    private func drawMultiSequenceInfo(frame: ReferenceFrame, context: CGContext) {
        guard let state = multiSequenceState else { return }

        // Draw info below the last sequence track
        let infoY = state.layout.totalHeight(forSequenceCount: state.sequenceCount) + 4

        // Sequence count and active track info
        let countInfo = "\(state.sequenceCount) sequences loaded | Viewing: \(state.activeSequence?.name ?? "none")"
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 10),
            .foregroundColor: NSColor.secondaryLabelColor,
        ]
        (countInfo as NSString).draw(at: CGPoint(x: 4, y: infoY), withAttributes: attributes)

        // Reference info
        if let refSeq = state.referenceSequence {
            let refInfo = "Reference: \(refSeq.name) (\(refSeq.length.formatted()) bp)"
            let refAttributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 10),
                .foregroundColor: NSColor.tertiaryLabelColor,
            ]
            (refInfo as NSString).draw(at: CGPoint(x: 4, y: infoY + 14), withAttributes: refAttributes)
        }
    }

*/

// ============================================================================
// Also modify mouseDown (around line 1649) - add this at the beginning:
// ============================================================================

/*

    public override func mouseDown(with event: NSEvent) {
        guard let frame = viewController?.referenceFrame else { return }

        let location = convert(event.locationInWindow, from: nil)

        // Multi-sequence handling: check if clicking on a sequence track
        if shouldDrawMultiSequence {
            if handleMultiSequenceMouseDown(at: location, frame: frame) {
                // Get base position for the active sequence
                if let basePos = basePositionForActiveSequence(at: location, frame: frame) {
                    selectionStartBase = basePos
                    selectionRange = basePos..<(basePos + 1)
                    isSelecting = true
                    setNeedsDisplay(bounds)
                    updateSelectionStatus()
                }
                return
            }
        }

        // Original implementation continues below...
        // (First, check if the click is on an annotation)
        if let annotation = annotationAtPoint(location) {
            // ... rest of existing code

*/

// ============================================================================
// Modify displayDocument in ViewerViewController (around line 234):
// ============================================================================

/*

    /// Displays a loaded document in the viewer.
    public func displayDocument(_ document: LoadedDocument) {
        logger.info("displayDocument: Starting to display '\(document.name, privacy: .public)'")
        logger.info("displayDocument: Document has \(document.sequences.count) sequences, \(document.annotations.count) annotations")

        currentDocument = document

        // Check for multiple sequences - use stacked display
        if document.sequences.count > 1 {
            logger.info("displayDocument: Multiple sequences detected, using stacked display")
            displayDocumentWithMultipleSequences(document)
            return
        }

        // Single sequence handling (original code follows)
        if let firstSequence = document.sequences.first {
            // ... rest of existing implementation
        }
    }

*/
