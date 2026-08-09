// SequenceViewerView+AnnotationRendering.swift - Extracted from SequenceViewerView.swift (pure mechanical split, no behavior change)
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import SwiftUI
import LungfishCore
import LungfishIO
import UniformTypeIdentifiers
import Quartz
import PDFKit
import os.log

extension SequenceViewerView {

    /// Formats annotation labels for rendering (single-line, whitespace-normalized).
    func displayLabel(for annotation: SequenceAnnotation) -> String {
        let collapsed = annotation.name
            .replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\t", with: " ")
            .replacingOccurrences(of: "  ", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return collapsed.isEmpty ? annotation.type.rawValue : collapsed
    }

    /// Returns true when this annotation type should render an inline label in expanded mode.
    func shouldRenderExpandedLabel(for annotation: SequenceAnnotation, width: CGFloat, rowCount: Int) -> Bool {
        guard rowCount <= maxLabeledRows, width >= minExpandedLabelWidth else { return false }
        switch annotation.type {
        case .gene, .mRNA, .transcript, .cds:
            return true
        default:
            return false
        }
    }

    /// Draws annotations from a bundle using zoom-dependent rendering tiers.
    ///
    /// Uses an offscreen tile cache for fast pan blitting. When the user pans within
    /// tile bounds, this method just blits the pre-rendered tile image with an X offset
    /// (O(1) per frame). The tile covers 3x the view width so the user can pan a full
    /// screen-width in each direction before the tile needs re-rendering.
    func drawBundleAnnotations(_ annotations: [SequenceAnnotation], frame: ReferenceFrame, context: CGContext) {
        guard showAnnotations, !annotations.isEmpty else {
            lastAnnotationBottomY = annotationTrackY
            return
        }

        // Clip strictly to the annotation lane so labels/features never overlap sequence track.
        context.saveGState()
        let annotationClipRect = CGRect(
            x: frame.leadingInset,
            y: annotationTrackY,
            width: max(0, CGFloat(frame.pixelWidth) - frame.leadingInset - frame.trailingInset),
            height: max(0, bounds.height - annotationTrackY)
        )
        context.clip(to: annotationClipRect)

        // Render directly in view coordinates to keep annotation rows anchored
        // directly beneath the sequence track.
        let displayAnnotations = filterAnnotationsForDisplay(annotations, frame: frame, context: context)

        guard let displayAnnotations else {
            lastAnnotationBottomY = annotationTrackY
            context.restoreGState()
            return
        }

        renderAnnotationsDirect(displayAnnotations, frame: frame, context: context)

        // Compute annotation track bottom for variant positioning.
        // For expanded mode, drawAnnotationsExpanded sets lastAnnotationBottomY directly
        // (including CDS translation sub-track heights), so only compute here for other modes.
        let scale = frame.scale
        let maxSquishedFeatures = 5_000
        let useDensityMode = scale > annotationDensityThreshold
            || (displayAnnotations.count > maxSquishedFeatures && scale > annotationSquishedThreshold)

        if useDensityMode {
            lastAnnotationBottomY = annotationTrackY + annotationDensityHeight(for: displayAnnotations) + annotationLabelClearance
        } else if scale > annotationSquishedThreshold {
            let (rows, _) = packAnnotationsLayered(displayAnnotations, frame: frame)
            lastAnnotationBottomY = annotationTrackY + CGFloat(rows.count) * 7 + annotationLabelClearance
        }
        // else: expanded mode — lastAnnotationBottomY was set inside drawAnnotationsExpanded

        context.restoreGState()
    }

    /// Filters cached annotations for display based on visible region and active
    /// type/text/track filters.
    ///
    /// Returns nil if no features pass the filter (draws a hint label if appropriate).
    func filterAnnotationsForDisplay(
        _ annotations: [SequenceAnnotation],
        frame: ReferenceFrame,
        context: CGContext
    ) -> [SequenceAnnotation]? {
        let scale = frame.scale
        let visibleStart = Int(frame.start)
        let visibleEnd = Int(frame.end)

        // Render rows based on the visible interval only so row packing starts
        // directly beneath the sequence track (no offscreen row inflation).
        let visibleSpan = max(1, visibleEnd - visibleStart)
        let visibleAnnotations = annotations.filter { annot in
            annot.end > visibleStart && annot.start < visibleEnd
        }

        // Apply type filter if set
        var filteredAnnotations: [SequenceAnnotation]
        if let typeFilter = visibleAnnotationTypes {
            filteredAnnotations = visibleAnnotations.filter { typeFilter.contains($0.type) }
        } else {
            filteredAnnotations = visibleAnnotations
        }

        if let localKeys = localAnnotationRenderFilterKeys {
            filteredAnnotations = filteredAnnotations.filter { annotation in
                guard let trackId = annotation.qualifiers["annotation_db_track_id"]?.values.first,
                      let rowId = annotation.qualifiers["annotation_db_row_id"]?.values.first else { return false }
                return localKeys.contains("\(trackId):\(rowId)")
            }
        }

        if !annotationTrackDisplayState.hiddenTrackIDs.isEmpty {
            filteredAnnotations = filteredAnnotations.filter { annotation in
                !annotationTrackDisplayState.hiddenTrackIDs.contains(annotationTrackID(for: annotation))
            }
        }

        // Apply text filter if set
        let finalAnnotations: [SequenceAnnotation]
        if !annotationFilterText.isEmpty {
            let filterLower = annotationFilterText.lowercased()
            finalAnnotations = filteredAnnotations.filter { annot in
                annot.name.lowercased().contains(filterLower)
            }
        } else {
            finalAnnotations = filteredAnnotations
        }

        guard !finalAnnotations.isEmpty else { return nil }

        // Display-time filtering:
        // - keep partially visible features, including sub-pixel annotations that
        //   the squished renderer draws as one-pixel marks
        // - suppress only giant region-container rows that would obscure detail
        // Use the larger of visibleSpan and sequenceLength for the region threshold
        // to avoid false passes when the view has padding beyond chromosome boundaries.
        let regionThresholdSpan = max(visibleSpan, frame.sequenceLength)
        let displayAnnotations: [SequenceAnnotation]
        if scale > annotationDensityThreshold {
            displayAnnotations = finalAnnotations.filter { annot in
                let span = annot.end - annot.start
                return annot.type != .region || span < Int(Double(regionThresholdSpan) * 0.98)
            }
        } else {
            displayAnnotations = finalAnnotations.filter { annot in
                let span = annot.end - annot.start
                return annot.type != .region || span < Int(Double(regionThresholdSpan) * 0.98)
            }
        }

        guard !displayAnnotations.isEmpty else {
            if !finalAnnotations.isEmpty {
                let font = NSFont.systemFont(ofSize: 10)
                let attrs: [NSAttributedString.Key: Any] = [
                    .font: font,
                    .foregroundColor: NSColor.secondaryLabelColor,
                ]
                let text = "\(finalAnnotations.count) features (zoom in to see details)"
                let labelRect = CGRect(x: 4, y: annotationTrackY + 2, width: CGFloat(frame.pixelWidth) - 8, height: 14)
                (text as NSString).draw(in: labelRect, withAttributes: attrs)
            }
            return nil
        }

        return displayAnnotations
    }

    /// Renders annotations to an offscreen CGImage tile covering 3x the visible view width.
    ///
    /// The tile can then be blitted with an X offset during subsequent pans, avoiding
    /// the expensive filtering/packing/drawing pipeline until the user pans past the tile edge.
    func renderAnnotationTile(annotations: [SequenceAnnotation], frame: ReferenceFrame) {
        let viewWidth = frame.pixelWidth
        let viewHeight = Int(bounds.height)
        guard viewWidth > 0, viewHeight > 0 else { return }

        let tilePixelWidth = viewWidth * 3
        let visibleSpan = frame.end - frame.start
        let tileStartBP = max(0, frame.start - visibleSpan)
        let tileEndBP = frame.end + visibleSpan

        // Create a temporary ReferenceFrame for the wider tile region
        let tileFrame = ReferenceFrame(
            chromosome: frame.chromosome,
            start: tileStartBP,
            end: tileEndBP,
            pixelWidth: tilePixelWidth,
            sequenceLength: frame.sequenceLength
        )

        // Create bitmap context for the tile
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let tileContext = CGContext(
            data: nil,
            width: tilePixelWidth,
            height: viewHeight,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ) else { return }

        // The view is flipped (isFlipped = true), so we need to flip the tile context too
        tileContext.translateBy(x: 0, y: CGFloat(viewHeight))
        tileContext.scaleBy(x: 1, y: -1)

        // Render annotations into the tile
        renderAnnotationsDirect(annotations, frame: tileFrame, context: tileContext)

        // Store tile metadata
        self.tileGenomicStart = tileStartBP
        self.tileGenomicEnd = tileEndBP
        self.tileScale = frame.scale
        self.tileWidth = tilePixelWidth
        self.tileHeight = viewHeight
        self.tileChromosome = frame.chromosome
        self.annotationTile = tileContext.makeImage()
    }

    /// Renders annotations directly into a context (used for both tile and fallback rendering).
    func renderAnnotationsDirect(_ annotations: [SequenceAnnotation], frame: ReferenceFrame, context: CGContext) {
        let scale = frame.scale
        let maxSquishedFeatures = 5_000
        let useDensityMode = scale > annotationDensityThreshold
            || (annotations.count > maxSquishedFeatures && scale > annotationSquishedThreshold)

        if useDensityMode {
            drawAnnotationDensity(annotations, frame: frame, context: context)
        } else if scale > annotationSquishedThreshold {
            drawAnnotationsSquished(annotations, frame: frame, context: context)
        } else {
            drawAnnotationsExpanded(annotations, frame: frame, context: context)
        }
    }

    // MARK: - Density Histogram (whole-chromosome zoom level)

    /// Draws a density histogram of annotation counts per pixel column.
    func drawAnnotationDensity(_ annotations: [SequenceAnnotation], frame: ReferenceFrame, context: CGContext) {
        let trackIDs = orderedAnnotationTrackIDs(for: annotations)
        if trackIDs.count > 1 {
            for (index, trackID) in trackIDs.enumerated() {
                let trackAnnotations = annotations.filter { annotationTrackID(for: $0) == trackID }
                drawAnnotationDensity(
                    trackAnnotations,
                    frame: frame,
                    context: context,
                    y: annotationTrackY + CGFloat(index) * 34,
                    labelPrefix: annotationTrackDisplayName(for: trackID)
                )
            }
            return
        }
        drawAnnotationDensity(annotations, frame: frame, context: context, y: annotationTrackY, labelPrefix: nil)
    }

    func annotationDensityHeight(for annotations: [SequenceAnnotation]) -> CGFloat {
        CGFloat(max(1, orderedAnnotationTrackIDs(for: annotations).count)) * 34
    }

    func drawAnnotationDensity(
        _ annotations: [SequenceAnnotation],
        frame: ReferenceFrame,
        context: CGContext,
        y: CGFloat,
        labelPrefix: String?
    ) {
        let dataWidth = frame.dataPixelWidth
        let inset = frame.leadingInset
        let binCount = max(1, Int(dataWidth))
        let bpPerBin = (frame.end - frame.start) / Double(binCount)

        // Build density histogram with per-type tracking
        var bins = [Int](repeating: 0, count: binCount)
        var binTypeCounts = [[AnnotationType: Int]](repeating: [:], count: binCount)
        for annot in annotations {
            let startBin = max(0, Int((Double(annot.start) - frame.start) / bpPerBin))
            let endBin = min(binCount - 1, Int((Double(annot.end) - frame.start) / bpPerBin))
            guard startBin <= endBin else { continue }
            for bin in startBin...endBin {
                bins[bin] += 1
                binTypeCounts[bin][annot.type, default: 0] += 1
            }
        }

        let maxCount = bins.max() ?? 1
        guard maxCount > 0 else { return }

        let trackHeight: CGFloat = 30

        // Draw background
        context.setFillColor(NSColor.controlBackgroundColor.withAlphaComponent(0.3).cgColor)
        context.fill(CGRect(x: inset, y: y, width: dataWidth, height: trackHeight))

        // Draw density bars colored by dominant annotation type per bin
        for (i, count) in bins.enumerated() {
            guard count > 0 else { continue }
            let barHeight = trackHeight * CGFloat(count) / CGFloat(maxCount)
            let rect = CGRect(x: inset + CGFloat(i), y: y + trackHeight - barHeight, width: 1, height: barHeight)
            // Color by the most frequent type in this bin (cached CGColor)
            let dominantType = binTypeCounts[i].max(by: { $0.value < $1.value })?.key ?? .gene
            context.setFillColor(cachedDensityColor(for: dominantType))
            context.fill(rect)
        }

        // Draw label
        let labelText: String
        if let labelPrefix {
            labelText = "\(labelPrefix): \(annotations.count) features"
        } else {
            labelText = "\(annotations.count) features (zoom in to see details)"
        }
        let font = NSFont.systemFont(ofSize: 10)
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor.secondaryLabelColor,
        ]
        let labelRect = CGRect(x: inset + 4, y: y + 2, width: dataWidth - 8, height: 14)
        (labelText as NSString).draw(in: labelRect, withAttributes: attrs)
    }

    // MARK: - Squished Mode (medium zoom — thin features, no labels)

    /// Draws annotations as thin packed rectangles without labels.
    func drawAnnotationsSquished(_ annotations: [SequenceAnnotation], frame: ReferenceFrame, context: CGContext) {
        let squishedHeight: CGFloat = 6
        let squishedSpacing: CGFloat = 1
        let (rows, overflow) = packAnnotationsLayered(annotations, frame: frame)

        for (rowIndex, row) in rows.enumerated() {
            let y = annotationTrackY + CGFloat(rowIndex) * (squishedHeight + squishedSpacing)

            for annot in row {
                let colors = cachedColors(for: annot)
                let startX = frame.screenPosition(for: Double(annot.start))
                let endX = frame.screenPosition(for: Double(annot.end))
                let width = max(1, endX - startX)
                let boundingRect = CGRect(x: startX, y: y, width: width, height: squishedHeight)

                if annot.isDiscontinuous {
                    // Discontiguous: connector line + block rectangles
                    let midY = y + squishedHeight / 2

                    // Draw connector line through intron regions
                    context.setStrokeColor(colors.fill)
                    context.setLineWidth(1)
                    context.move(to: CGPoint(x: startX, y: midY))
                    context.addLine(to: CGPoint(x: endX, y: midY))
                    context.strokePath()

                    // Draw each interval (exon) as a filled block
                    context.setFillColor(colors.fill)
                    for interval in annot.intervals {
                        let ix = frame.screenPosition(for: Double(interval.start))
                        let ix2 = frame.screenPosition(for: Double(interval.end))
                        let iw = max(1, ix2 - ix)
                        context.fill(CGRect(x: ix, y: y, width: iw, height: squishedHeight))
                    }
                } else {
                    // Continuous: single filled rectangle
                    context.setFillColor(colors.fill)
                    context.fill(boundingRect)
                }

                // Draw selection highlight
                if let selected = selectedAnnotation, selected.id == annot.id {
                    drawAnnotationSelectionHighlight(rect: boundingRect, context: context)
                }
            }
        }

        drawAnnotationTrackLabels(rows: rows, rowYOffsets: rows.indices.map {
            annotationTrackY + CGFloat($0) * (squishedHeight + squishedSpacing)
        }, frame: frame, context: context)

        if overflow > 0 {
            drawOverflowIndicator(rowCount: rows.count, height: squishedHeight + squishedSpacing,
                                  overflow: overflow, frame: frame, context: context)
        }
    }

    // MARK: - Expanded Mode (close zoom — full detail with labels)

    /// Draws annotations as full-height boxes with labels and strand indicators.
    /// Discontiguous features (e.g., transcripts with exons) are rendered with a
    /// thin connector line and thick blocks for each interval, like IGV/Geneious.
    func drawAnnotationsExpanded(_ annotations: [SequenceAnnotation], frame: ReferenceFrame, context: CGContext) {
        let (rows, overflow) = packAnnotationsLayered(annotations, frame: frame)
        let rowCount = rows.count

        // Determine if embedded annotation translations should be rendered beneath feature rows.
        let canRenderEmbeddedTranslations = frame.scale < showLettersThreshold
            && !showTranslationTrack  // don't double-render with manual translation
        let autoCDS = canRenderEmbeddedTranslations
            && cachedBundleSequence != nil
            && cachedSequenceRegion != nil

        // Build sequence provider from cached data (no I/O in draw loop)
        let sequenceProvider: ((Int, Int) -> String?)?
        if autoCDS, let seq = cachedBundleSequence, let region = cachedSequenceRegion {
            sequenceProvider = { start, end in
                let clampedStart = max(region.start, start)
                let clampedEnd = min(region.end, end)
                guard clampedStart < clampedEnd else { return nil }
                let offsetStart = clampedStart - region.start
                let offsetEnd = clampedEnd - region.start
                guard offsetStart >= 0, offsetEnd <= seq.count else { return nil }
                let startIdx = seq.index(seq.startIndex, offsetBy: offsetStart)
                let endIdx = seq.index(seq.startIndex, offsetBy: offsetEnd)
                return String(seq[startIdx..<endIdx])
            }
        } else {
            sequenceProvider = nil
        }

        let embeddedTranslationTrackH = TranslationTrackRenderer.cdsTrackHeight() + 2

        // First pass: determine which rows contain annotations needing translation sub-tracks.
        // Compute per-row Y offsets with accumulated translation space.
        var rowYOffsets = [CGFloat](repeating: 0, count: rows.count)
        var cumulativeExtra: CGFloat = 0
        for (rowIndex, row) in rows.enumerated() {
            rowYOffsets[rowIndex] = annotationTrackY + CGFloat(rowIndex) * (annotationHeight + annotationRowSpacing) + cumulativeExtra
            if canRenderEmbeddedTranslations,
               row.contains(where: { embeddedAnnotationTranslationAvailable(for: $0, sequenceProvider: sequenceProvider) }) {
                cumulativeExtra += embeddedTranslationTrackH
            }
        }

        // Second pass: draw annotations and embedded translations.
        for (rowIndex, row) in rows.enumerated() {
            let y = rowYOffsets[rowIndex]

            for annot in row {
                let startX = frame.screenPosition(for: Double(annot.start))
                let endX = frame.screenPosition(for: Double(annot.end))
                let width = max(3, endX - startX)

                let colors = cachedColors(for: annot)

                let boundingRect = CGRect(x: startX, y: y, width: width, height: annotationHeight)

                if annot.isDiscontinuous {
                    // Discontiguous: connector line + block rectangles (IGV-style)
                    let midY = y + annotationHeight / 2
                    let connectorHeight: CGFloat = 2

                    // Draw connector line (thin bar through intron regions)
                    context.setFillColor(colors.fill)
                    context.fill(CGRect(x: startX, y: midY - connectorHeight / 2,
                                        width: width, height: connectorHeight))

                    // Draw each interval (exon) as a full-height filled block
                    for interval in annot.intervals {
                        let ix = frame.screenPosition(for: Double(interval.start))
                        let ix2 = frame.screenPosition(for: Double(interval.end))
                        let iw = max(1, ix2 - ix)
                        let blockRect = CGRect(x: ix, y: y, width: iw, height: annotationHeight)
                        context.setFillColor(colors.fill)
                        context.fill(blockRect)
                        context.setStrokeColor(colors.stroke)
                        context.setLineWidth(1)
                        context.stroke(blockRect)
                    }

                    // Draw strand arrows on connector if feature is wide enough
                    if width > 8 {
                        drawStrandArrow(strand: annot.strand, rect: boundingRect, context: context)
                    }

                    // Draw label above or inside the feature
                    if shouldRenderExpandedLabel(for: annot, width: width, rowCount: rowCount) {
                        let label = displayLabel(for: annot)
                        let paragraph = NSMutableParagraphStyle()
                        paragraph.lineBreakMode = .byTruncatingTail
                        let font = NSFont.systemFont(ofSize: 10)
                        let attributes: [NSAttributedString.Key: Any] = [
                            .font: font,
                            .foregroundColor: NSColor.textColor,
                            .paragraphStyle: paragraph,
                        ]
                        let labelRect = CGRect(x: startX + 2, y: y + 1, width: width - 4, height: annotationHeight - 2)
                        (label as NSString).draw(
                            with: labelRect,
                            options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine],
                            attributes: attributes
                        )
                    }
                } else {
                    // Continuous: single filled rectangle with border
                    context.setFillColor(colors.fill)
                    context.fill(boundingRect)

                    // Draw border
                    context.setStrokeColor(colors.stroke)
                    context.setLineWidth(1)
                    context.stroke(boundingRect)

                    // Draw label if space permits
                    if shouldRenderExpandedLabel(for: annot, width: width, rowCount: rowCount) {
                        let label = displayLabel(for: annot)
                        let paragraph = NSMutableParagraphStyle()
                        paragraph.lineBreakMode = .byTruncatingTail
                        let font = NSFont.systemFont(ofSize: 10)
                        let attributes: [NSAttributedString.Key: Any] = [
                            .font: font,
                            .foregroundColor: NSColor.textColor,
                            .paragraphStyle: paragraph,
                        ]
                        let labelRect = CGRect(x: startX + 2, y: y + 1, width: width - 4, height: annotationHeight - 2)
                        (label as NSString).draw(
                            with: labelRect,
                            options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine],
                            attributes: attributes
                        )
                    }

                    // Draw strand arrow if feature is wide enough
                    if width > 8 {
                        drawStrandArrow(strand: annot.strand, rect: boundingRect, context: context)
                    }
                }

                // Draw selection highlight around the selected annotation
                if let selected = selectedAnnotation, selected.id == annot.id {
                    drawAnnotationSelectionHighlight(rect: boundingRect, context: context)
                }

                if canRenderEmbeddedTranslations,
                   let result = embeddedAnnotationTranslationResult(for: annot, sequenceProvider: sequenceProvider) {
                    TranslationTrackRenderer.drawCDSTranslation(
                        result: result,
                        frame: frame,
                        context: context,
                        yOffset: y + annotationHeight + 1,
                        colorScheme: translationColorScheme,
                        showStopCodons: translationShowStopCodons
                    )
                }
            }
        }

        drawAnnotationTrackLabels(rows: rows, rowYOffsets: rowYOffsets, frame: frame, context: context)

        // Update lastAnnotationBottomY to include CDS translation heights
        let totalHeight = CGFloat(rows.count) * (annotationHeight + annotationRowSpacing) + cumulativeExtra
        lastAnnotationBottomY = annotationTrackY + totalHeight + annotationLabelClearance

        if overflow > 0 {
            drawOverflowIndicator(rowCount: rows.count, height: annotationHeight + annotationRowSpacing,
                                  overflow: overflow, frame: frame, context: context)
        }
    }

    func embeddedAnnotationTranslationAvailable(
        for annotation: SequenceAnnotation,
        sequenceProvider: ((Int, Int) -> String?)?
    ) -> Bool {
        if annotation.type == .cds {
            return sequenceProvider != nil
        }
        return Self.storedAnnotationTranslationResult(for: annotation) != nil
    }

    func embeddedAnnotationTranslationResult(
        for annotation: SequenceAnnotation,
        sequenceProvider: ((Int, Int) -> String?)?
    ) -> TranslationResult? {
        if let cached = cachedCDSTranslations[annotation.id] {
            return cached
        }

        let result: TranslationResult?
        if annotation.type == .cds, let sequenceProvider {
            result = TranslationEngine.translateCDS(
                annotation: annotation,
                sequenceProvider: sequenceProvider
            )
        } else {
            result = Self.storedAnnotationTranslationResult(for: annotation)
        }

        if let result {
            cachedCDSTranslations[annotation.id] = result
        }
        return result
    }

    // MARK: - Pixel-Based Row Packing

    /// Packs annotations into layered rows:
    /// - genome landmarks first (genes/transcripts/etc.)
    /// - variant-like features (SNP/indel/etc.) beneath landmarks
    func packAnnotationsLayered(
        _ annotations: [SequenceAnnotation],
        frame: ReferenceFrame
    ) -> (rows: [[SequenceAnnotation]], overflow: Int) {
        let trackIDs = orderedAnnotationTrackIDs(for: annotations)
        if trackIDs.count > 1 {
            var rows: [[SequenceAnnotation]] = []
            var overflow = 0
            for trackID in trackIDs {
                let trackAnnotations = annotations.filter { annotationTrackID(for: $0) == trackID }
                let packed = packAnnotationsLayeredWithinTrack(trackAnnotations, frame: frame, maxRows: maxAnnotationRows)
                rows.append(contentsOf: packed.rows)
                overflow += packed.overflow
            }
            return (rows, overflow)
        }
        return packAnnotationsLayeredWithinTrack(annotations, frame: frame, maxRows: maxAnnotationRows)
    }

    func packAnnotationsLayeredWithinTrack(
        _ annotations: [SequenceAnnotation],
        frame: ReferenceFrame,
        maxRows: Int
    ) -> (rows: [[SequenceAnnotation]], overflow: Int) {
        guard maxRows > 0 else { return ([], annotations.count) }
        let landmarks = annotations.filter { !isVariantAnnotationType($0.type) }
        let variants = annotations.filter { isVariantAnnotationType($0.type) }

        let (landmarkRows, landmarkOverflow) = packAnnotationsPixelBased(landmarks, frame: frame, maxRows: maxRows)
        let remainingRows = max(0, maxRows - landmarkRows.count)
        let (variantRows, variantOverflow) = packAnnotationsPixelBased(variants, frame: frame, maxRows: remainingRows)

        return (landmarkRows + variantRows, landmarkOverflow + variantOverflow)
    }

    #if DEBUG
    func debugPackedAnnotationTrackIDs(_ annotations: [SequenceAnnotation], frame: ReferenceFrame) -> [String] {
        let (rows, _) = packAnnotationsLayered(annotations, frame: frame)
        var ordered: [String] = []
        var seen: Set<String> = []
        for row in rows {
            guard let first = row.first else { continue }
            let trackID = annotationTrackID(for: first)
            guard !seen.contains(trackID) else { continue }
            seen.insert(trackID)
            ordered.append(trackID)
        }
        return ordered
    }

    func debugBundleDisplayAnnotationNames(_ annotations: [SequenceAnnotation], frame: ReferenceFrame) -> [String] {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: nil,
            width: max(1, frame.pixelWidth),
            height: max(1, Int(bounds.height)),
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ) else { return [] }

        return filterAnnotationsForDisplay(annotations, frame: frame, context: context)?.map(\.name) ?? []
    }
    #endif

    func isVariantAnnotationType(_ type: AnnotationType) -> Bool {
        switch type {
        case .snp, .variation, .insertion, .deletion:
            return true
        default:
            return false
        }
    }

    func annotationTrackID(for annotation: SequenceAnnotation) -> String {
        annotation.qualifiers["annotation_db_track_id"]?.values.first ?? "annotations"
    }

    func annotationTrackDisplayName(for trackID: String) -> String {
        annotationTrackDisplayState.displayNames[trackID] ?? trackID
    }

    func orderedAnnotationTrackIDs(for annotations: [SequenceAnnotation]) -> [String] {
        var discovered: [String] = []
        var seen: Set<String> = []
        for annotation in annotations {
            let trackID = annotationTrackID(for: annotation)
            guard !seen.contains(trackID) else { continue }
            seen.insert(trackID)
            discovered.append(trackID)
        }

        let discoveredSet = Set(discovered)
        var ordered = annotationTrackDisplayState.order.filter { discoveredSet.contains($0) }
        let orderedSet = Set(ordered)
        ordered.append(contentsOf: discovered.filter { !orderedSet.contains($0) })
        return ordered
    }

    func drawAnnotationTrackLabels(
        rows: [[SequenceAnnotation]],
        rowYOffsets: [CGFloat],
        frame: ReferenceFrame,
        context: CGContext
    ) {
        guard orderedAnnotationTrackIDs(for: rows.flatMap { $0 }).count > 1 else { return }
        let font = NSFont.systemFont(ofSize: 9, weight: .medium)
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor.secondaryLabelColor,
        ]
        var previousTrackID: String?
        for (rowIndex, row) in rows.enumerated() {
            guard let firstAnnotation = row.first, rowIndex < rowYOffsets.count else { continue }
            let trackID = annotationTrackID(for: firstAnnotation)
            guard trackID != previousTrackID else { continue }
            let y = rowYOffsets[rowIndex]
            if previousTrackID != nil {
                context.setStrokeColor(NSColor.separatorColor.withAlphaComponent(0.65).cgColor)
                context.setLineWidth(1)
                context.move(to: CGPoint(x: frame.leadingInset, y: y - 2))
                context.addLine(to: CGPoint(x: CGFloat(frame.pixelWidth) - frame.trailingInset, y: y - 2))
                context.strokePath()
            }
            let label = annotationTrackDisplayName(for: trackID)
            let labelRect = CGRect(x: frame.leadingInset + 4, y: y + 1, width: 180, height: 12)
            (label as NSString).draw(in: labelRect, withAttributes: attrs)
            previousTrackID = trackID
        }
    }

    /// Packs annotations into rows using pixel-based gap detection.
    /// Returns the packed rows and number of overflow features that couldn't be placed.
    func packAnnotationsPixelBased(
        _ annotations: [SequenceAnnotation],
        frame: ReferenceFrame,
        maxRows: Int
    ) -> (rows: [[SequenceAnnotation]], overflow: Int) {
        let sortedAnnotations = annotations.sorted {
            if $0.start != $1.start { return $0.start < $1.start }
            if $0.end != $1.end { return $0.end < $1.end }
            return $0.name.localizedCompare($1.name) == .orderedAscending
        }

        var rows: [[SequenceAnnotation]] = []
        var rowEndPixels: [CGFloat] = []  // Track rightmost pixel in each row
        var overflow = 0

        for annot in sortedAnnotations {
            let startX = frame.screenPosition(for: Double(annot.start))

            var placed = false
            for rowIndex in 0..<rows.count {
                if startX >= rowEndPixels[rowIndex] + minPixelGap {
                    rows[rowIndex].append(annot)
                    let endX = frame.screenPosition(for: Double(annot.end))
                    rowEndPixels[rowIndex] = max(endX, startX + 3)  // min 3px feature width
                    placed = true
                    break
                }
            }

            if !placed {
                if rows.count < maxRows {
                    rows.append([annot])
                    let endX = frame.screenPosition(for: Double(annot.end))
                    rowEndPixels.append(max(endX, startX + 3))
                } else {
                    overflow += 1
                }
            }
        }

        return (rows, overflow)
    }

    // MARK: - Annotation Drawing Helpers

    /// Draws a small strand arrow inside an annotation rect.
    func drawStrandArrow(strand: Strand, rect: CGRect, context: CGContext) {
        guard strand == .forward || strand == .reverse else { return }

        let arrowSize: CGFloat = 4
        let midY = rect.midY
        context.setStrokeColor(NSColor.textColor.withAlphaComponent(0.5).cgColor)
        context.setLineWidth(1)

        if strand == .forward {
            let x = rect.maxX - arrowSize - 2
            context.move(to: CGPoint(x: x, y: midY - arrowSize / 2))
            context.addLine(to: CGPoint(x: x + arrowSize, y: midY))
            context.addLine(to: CGPoint(x: x, y: midY + arrowSize / 2))
        } else {
            let x = rect.minX + 2
            context.move(to: CGPoint(x: x + arrowSize, y: midY - arrowSize / 2))
            context.addLine(to: CGPoint(x: x, y: midY))
            context.addLine(to: CGPoint(x: x + arrowSize, y: midY + arrowSize / 2))
        }
        context.strokePath()
    }

    /// Draws a "+N more features" indicator below the last row.
    func drawOverflowIndicator(rowCount: Int, height: CGFloat, overflow: Int,
                                       frame: ReferenceFrame, context: CGContext) {
        let y = annotationTrackY + CGFloat(rowCount) * height
        let text = "+\(overflow) more features"
        let font = NSFont.systemFont(ofSize: 9)
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor.secondaryLabelColor,
        ]
        let labelRect = CGRect(x: 4, y: y, width: CGFloat(frame.pixelWidth) - 8, height: 12)
        (text as NSString).draw(in: labelRect, withAttributes: attrs)
    }
    
    /// Draws a loading indicator.
    func drawLoadingIndicator(context: CGContext, message: String) {
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.alignment = .center
        
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 14, weight: .medium),
            .foregroundColor: NSColor.secondaryLabelColor,
            .paragraphStyle: paragraphStyle,
        ]
        
        let size = (message as NSString).size(withAttributes: attributes)
        let rect = NSRect(
            x: (bounds.width - size.width) / 2,
            y: (bounds.height - size.height) / 2,
            width: size.width,
            height: size.height
        )

        (message as NSString).draw(in: rect, withAttributes: attributes)
    }

    /// Draws a compact loading badge anchored within a track region.
    ///
    /// - Parameter tooltip: When non-nil, registers a hover tooltip over the badge's rect with
    ///   this text (additive — existing call sites that omit it are unaffected). Each call
    ///   replaces any tooltip previously registered by this same call site's badge, since the
    ///   badge redraws at the same rect every frame; callers that stop showing the badge should
    ///   ensure `removeAllToolTips()` or a fresh draw pass clears stale rects.
    func drawTrackLoadingBadge(context: CGContext, message: String, yOffset: CGFloat, tooltip: String? = nil) {
        let textAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 10, weight: .medium),
            .foregroundColor: NSColor.secondaryLabelColor,
        ]
        let text = message as NSString
        let textSize = text.size(withAttributes: textAttrs)

        let spinnerSize: CGFloat = 10
        let badgeHeight: CGFloat = 18
        let horizontalPadding: CGFloat = 8
        let badgeWidth = min(
            max(120, spinnerSize + 8 + textSize.width + horizontalPadding * 2),
            max(120, bounds.width - 16)
        )
        let badgeRect = CGRect(
            x: 8,
            y: max(0, yOffset),
            width: badgeWidth,
            height: badgeHeight
        )

        if let tooltip {
            _ = addToolTip(badgeRect, owner: tooltip as NSString, userData: nil)
        }

        context.saveGState()
        context.setFillColor(NSColor.windowBackgroundColor.withAlphaComponent(0.92).cgColor)
        context.setStrokeColor(NSColor.separatorColor.withAlphaComponent(0.7).cgColor)
        context.setLineWidth(0.8)
        let badgePath = CGPath(roundedRect: badgeRect, cornerWidth: 6, cornerHeight: 6, transform: nil)
        context.addPath(badgePath)
        context.drawPath(using: .fillStroke)

        let spinnerRect = CGRect(
            x: badgeRect.minX + horizontalPadding,
            y: badgeRect.midY - spinnerSize / 2,
            width: spinnerSize,
            height: spinnerSize
        )
        context.setStrokeColor(NSColor.tertiaryLabelColor.withAlphaComponent(0.35).cgColor)
        context.setLineWidth(1.2)
        context.strokeEllipse(in: spinnerRect)

        context.setStrokeColor(NSColor.controlAccentColor.cgColor)
        context.setLineWidth(1.8)
        let center = CGPoint(x: spinnerRect.midX, y: spinnerRect.midY)
        let radius = spinnerSize / 2 - 1
        let phase = trackLoadingAnimationPhase
        let sweep: CGFloat = .pi * 1.1
        context.addArc(
            center: center,
            radius: radius,
            startAngle: phase,
            endAngle: phase + sweep,
            clockwise: false
        )
        context.strokePath()

        let textRect = CGRect(
            x: spinnerRect.maxX + 8,
            y: badgeRect.midY - textSize.height / 2,
            width: badgeRect.maxX - spinnerRect.maxX - horizontalPadding - 8,
            height: textSize.height
        )
        text.draw(in: textRect, withAttributes: textAttrs)
        context.restoreGState()
    }

    /// Draws a hint when zoom level is too low for per-read rendering.
    func drawReadZoomHint(context: CGContext, yOffset: CGFloat, scale: Double) {
        let threshold = ReadTrackRenderer.coverageThresholdBpPerPx
        let message = "Zoom in to view individual mapped reads (<= \(String(format: "%.1f", threshold)) bp/px)"
        let detail = "Current zoom: \(String(format: "%.1f", scale)) bp/px"
        let textAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 10, weight: .medium),
            .foregroundColor: NSColor.secondaryLabelColor,
        ]
        let detailAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 9, weight: .regular),
            .foregroundColor: NSColor.tertiaryLabelColor,
        ]

        let title = message as NSString
        let subtitle = detail as NSString
        let titleSize = title.size(withAttributes: textAttrs)
        let subtitleSize = subtitle.size(withAttributes: detailAttrs)
        let badgeWidth = min(
            max(220, max(titleSize.width, subtitleSize.width) + 16),
            max(220, bounds.width - 16)
        )
        let badgeHeight: CGFloat = 34
        let badgeRect = CGRect(x: 8, y: max(0, yOffset), width: badgeWidth, height: badgeHeight)

        context.saveGState()
        context.setFillColor(NSColor.windowBackgroundColor.withAlphaComponent(0.9).cgColor)
        context.setStrokeColor(NSColor.separatorColor.withAlphaComponent(0.8).cgColor)
        context.setLineWidth(0.8)
        let path = CGPath(roundedRect: badgeRect, cornerWidth: 6, cornerHeight: 6, transform: nil)
        context.addPath(path)
        context.drawPath(using: .fillStroke)

        title.draw(
            in: CGRect(
                x: badgeRect.minX + 8,
                y: badgeRect.minY + 6,
                width: badgeRect.width - 16,
                height: titleSize.height
            ),
            withAttributes: textAttrs
        )
        subtitle.draw(
            in: CGRect(
                x: badgeRect.minX + 8,
                y: badgeRect.minY + 18,
                width: badgeRect.width - 16,
                height: subtitleSize.height
            ),
            withAttributes: detailAttrs
        )
        context.restoreGState()
    }

    /// Draws a macOS-style scroll indicator on the right edge of the read track.
    func drawReadScrollIndicator(
        context: CGContext, clipRect: CGRect,
        contentHeight: CGFloat, scrollOffset: CGFloat
    ) {
        let trackHeight = clipRect.height
        guard trackHeight > 0, contentHeight > trackHeight else { return }

        let indicatorWidth: CGFloat = 6
        let indicatorMinHeight: CGFloat = 20
        let margin: CGFloat = 2

        let fraction = trackHeight / contentHeight
        let indicatorHeight = max(indicatorMinHeight, trackHeight * fraction)
        let scrollFraction = scrollOffset / (contentHeight - trackHeight)
        let indicatorY = clipRect.minY + scrollFraction * (trackHeight - indicatorHeight)

        let indicatorRect = CGRect(
            x: clipRect.maxX - indicatorWidth - margin,
            y: indicatorY,
            width: indicatorWidth,
            height: indicatorHeight
        )

        context.saveGState()
        context.setFillColor(NSColor(white: 0.4, alpha: 0.5).cgColor)
        let path = CGPath(roundedRect: indicatorRect, cornerWidth: indicatorWidth / 2, cornerHeight: indicatorWidth / 2, transform: nil)
        context.addPath(path)
        context.fillPath()
        context.restoreGState()
    }

    func drawPlaceholder(context: CGContext) {
        // isFlipped=true: Y=0 is top, Y increases downward
        let centerY = bounds.height / 2

        // Draw SF Symbol icon centered above the text
        let symbolConfig = NSImage.SymbolConfiguration(pointSize: 48, weight: .thin)
        if let symbolImage = NSImage(
            systemSymbolName: "doc.viewfinder",
            accessibilityDescription: "No file selected"
        )?.withSymbolConfiguration(symbolConfig) {
            let imageSize = symbolImage.size
            let imageRect = NSRect(
                x: (bounds.width - imageSize.width) / 2,
                y: centerY - imageSize.height - 8,
                width: imageSize.width,
                height: imageSize.height
            )

            NSGraphicsContext.saveGraphicsState()
            NSColor.tertiaryLabelColor.set()
            symbolImage.draw(in: imageRect, from: .zero, operation: .destinationIn, fraction: 1.0)
            NSGraphicsContext.restoreGraphicsState()

            // Draw tinted version
            let tintedImage = NSImage(size: symbolImage.size, flipped: false) { rect in
                symbolImage.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1.0)
                NSColor.tertiaryLabelColor.withAlphaComponent(0.5).set()
                rect.fill(using: .sourceAtop)
                return true
            }
            tintedImage.draw(in: imageRect, from: .zero, operation: .sourceOver, fraction: 1.0)
        }

        // Draw text below the icon
        let message = "Select a file from the sidebar to view"
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.alignment = .center
        paragraphStyle.lineSpacing = 4

        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 14, weight: .regular),
            .foregroundColor: NSColor.tertiaryLabelColor,
            .paragraphStyle: paragraphStyle,
        ]

        let size = (message as NSString).size(withAttributes: attributes)
        let textRect = NSRect(
            x: (bounds.width - size.width) / 2,
            y: centerY + 8,
            width: size.width,
            height: size.height
        )

        (message as NSString).draw(in: textRect, withAttributes: attributes)
    }

    func drawSequence(_ seq: Sequence, frame: ReferenceFrame, context: CGContext) {
        ensureVisibleViewportSelection(frame: frame)
        let clipInset = frame.leadingInset
        let clipRight = bounds.width - frame.trailingInset
        if clipInset > 0 || frame.trailingInset > 0 {
            context.saveGState()
            defer { context.restoreGState() }
            let clipRect = CGRect(
                x: min(clipInset, bounds.width),
                y: trackY,
                width: max(0, clipRight - clipInset),
                height: trackHeight
            )
            context.clip(to: clipRect)
        }

        let scale = frame.scale  // bp/pixel

        // Decide rendering mode based on zoom level (scale = bp/pixel)
        // Three modes based on user feedback:
        // - BASE_MODE: < 10 bp/pixel - Individual colored bases with letters
        // - BLOCK_MODE: 10-300 bp/pixel - Colored blocks showing dominant base (no letters)
        // - LINE_MODE: > 300 bp/pixel - Simple gray horizontal line
        //
        // User feedback: Show colors when ~300bp visible (~1% of typical sequence)
        // This corresponds to about 0.3 bp/pixel on a 1000px screen,
        // but the block mode threshold is set at 300 bp/pixel for the transition
        // from colored blocks to gray line.
        let blockModeThreshold: Double = 300.0  // Show colored blocks up to 300 bp/pixel

        if scale < showLettersThreshold {
            // High zoom (< 10 bp/pixel): show individual bases with letters
            // Colors: A=Green, T=Red, C=Blue, G=Orange, N=Gray
            drawBaseLevelSequence(seq, frame: frame, context: context)
        } else if scale < blockModeThreshold {
            // Medium zoom (10-300 bp/pixel): show colored blocks without letters
            // Shows dominant base color per bin for pattern visualization
            drawBlockLevelSequence(seq, frame: frame, context: context)
        } else {
            // Low zoom (>= 300 bp/pixel): show simple gray line
            // At this scale, individual bases provide no useful information
            drawLineSequence(seq, frame: frame, context: context)
        }

        // Draw translation track if active and zoomed in enough
        if showTranslationTrack && frame.scale < showLettersThreshold {
            let transY = trackY + trackHeight + 4
            if let result = activeTranslationResult {
                TranslationTrackRenderer.drawCDSTranslation(
                    result: result,
                    frame: frame,
                    context: context,
                    yOffset: transY,
                    colorScheme: translationColorScheme,
                    showStopCodons: translationShowStopCodons
                )
            } else if !frameTranslationFrames.isEmpty {
                // For single-sequence mode, extract the visible portion
                let visStart = max(0, Int(frame.start))
                let visEnd = min(seq.length, Int(frame.end))
                if visStart < visEnd {
                    let bases = seq[visStart..<visEnd]
                    TranslationTrackRenderer.drawFrameTranslations(
                        frames: frameTranslationFrames,
                        sequence: bases,
                        sequenceStart: visStart,
                        frame: frame,
                        context: context,
                        yOffset: transY,
                        table: frameTranslationTable,
                        colorScheme: translationColorScheme,
                        showStopCodons: translationShowStopCodons
                    )
                }
            }
        }

        // Draw annotations if present and enabled
        if showAnnotations && !annotations.isEmpty {
            drawAnnotations(frame: frame, context: context)
        }

        // Draw sequence info header
        drawSequenceInfo(seq, frame: frame, context: context)

        // Draw column selection overlay
        drawColumnSelectionHighlight(frame: frame, context: context)
    }

    /// Draws a Geneious-style column selection highlight spanning the full view height.
    func drawColumnSelectionHighlight(frame: ReferenceFrame, context: CGContext) {
        guard isUserColumnSelection, let range = selectionRange else { return }

        let startX = frame.screenPosition(for: Double(range.lowerBound))
        let endX = frame.screenPosition(for: Double(range.upperBound))
        let clippedStartX = max(0, startX)
        let clippedEndX = min(bounds.width, endX)
        let width = clippedEndX - clippedStartX
        guard width > 0 else { return }

        context.saveGState()

        // Full-height dark navy column fill (Geneious style)
        let columnRect = CGRect(x: clippedStartX, y: 0, width: width, height: bounds.height)
        context.setFillColor(NSColor(red: 0.15, green: 0.22, blue: 0.42, alpha: 0.40).cgColor)
        context.fill(columnRect)

        // Edge lines at selection boundaries
        context.setStrokeColor(NSColor(red: 0.15, green: 0.22, blue: 0.42, alpha: 0.75).cgColor)
        context.setLineWidth(1)
        if clippedStartX > 0 {
            context.move(to: CGPoint(x: clippedStartX, y: 0))
            context.addLine(to: CGPoint(x: clippedStartX, y: bounds.height))
        }
        if clippedEndX < bounds.width {
            context.move(to: CGPoint(x: clippedEndX, y: 0))
            context.addLine(to: CGPoint(x: clippedEndX, y: bounds.height))
        }
        context.strokePath()

        context.restoreGState()
    }

    /// Draws dark blue overlay highlights on selected reads.
    func drawSelectedReadHighlights(frame: ReferenceFrame, context: CGContext) {
        guard !selectedReadIDs.isEmpty else { return }

        let metrics = ReadTrackRenderer.layoutMetrics(verticalCompress: verticallyCompressContigSetting)
        let tier = lastRenderedReadTier
        guard tier != .coverage else { return }

        let rowHeight: CGFloat = tier == .base ? metrics.baseReadHeight : metrics.packedReadHeight
        let rY = lastRenderedReadY

        context.saveGState()

        for (row, read) in cachedPackedReads {
            guard selectedReadIDs.contains(read.id) else { continue }

            let startPx = frame.screenPosition(for: Double(read.position))
            let endPx = frame.screenPosition(for: Double(read.alignmentEnd))
            let y = rY + CGFloat(row) * (rowHeight + metrics.rowGap) - readScrollOffset
            let readRect = CGRect(x: startPx, y: y, width: endPx - startPx, height: rowHeight)

            // Dark blue overlay (Geneious style)
            context.setFillColor(NSColor(red: 0.15, green: 0.22, blue: 0.50, alpha: 0.50).cgColor)
            context.fill(readRect)

            // Border
            context.setStrokeColor(NSColor(red: 0.2, green: 0.3, blue: 0.6, alpha: 0.85).cgColor)
            context.setLineWidth(1)
            context.stroke(readRect)
        }

        context.restoreGState()
    }


    /// Returns the filtered annotations based on current filter settings.
    func filteredAnnotations() -> [SequenceAnnotation] {
        var result = annotations

        // Filter by type if visibleAnnotationTypes is set
        if let visibleTypes = visibleAnnotationTypes {
            result = result.filter { visibleTypes.contains($0.type) }
        }

        // Filter by text if filterText is not empty
        if !annotationFilterText.isEmpty {
            let lowercaseFilter = annotationFilterText.lowercased()
            result = result.filter { annotation in
                annotation.name.lowercased().contains(lowercaseFilter) ||
                annotation.type.rawValue.lowercased().contains(lowercaseFilter) ||
                (annotation.note?.lowercased().contains(lowercaseFilter) ?? false)
            }
        }

        return result
    }

    /// Draws annotation features below the sequence track
    func drawAnnotations(frame: ReferenceFrame, context: CGContext) {
        let visibleBases = frame.end - frame.start
        let pixelsPerBase = frame.dataPixelWidth / CGFloat(max(1, visibleBases))

        // Annotation colors from user settings
        let settings = AppSettings.shared
        var typeColors: [AnnotationType: NSColor] = [:]
        for type in AnnotationType.allCases {
            typeColors[type] = settings.annotationColor(for: type)
        }

        let visibleStart = Int(frame.start)
        let visibleEnd = Int(frame.end)

        // Track row assignments to avoid overlaps
        var rowEndPositions: [CGFloat] = []

        // Use filtered annotations
        let displayAnnotations = filteredAnnotations()

        for annotation in displayAnnotations {
            // Get the first interval (simplified - could handle discontinuous features)
            guard let interval = annotation.intervals.first else { continue }

            // Check if annotation is visible
            if interval.end < visibleStart || interval.start > visibleEnd {
                continue
            }

            // Calculate screen coordinates (offset by leadingInset for gutter)
            let rawStartX = frame.leadingInset + CGFloat(interval.start - visibleStart) * pixelsPerBase
            let endX = frame.leadingInset + CGFloat(interval.end - visibleStart) * pixelsPerBase
            // Clamp startX to data area start
            let startX = max(frame.leadingInset, rawStartX)
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

            let y = annotationTrackY + CGFloat(row) * (annotationHeight + annotationRowSpacing)

            // Get color for this annotation type
            let color = typeColors[annotation.type] ?? NSColor.gray

            // Draw annotation box
            let annotRect = CGRect(x: startX, y: y, width: width, height: annotationHeight)
            context.setFillColor(color.cgColor)
            context.fill(annotRect)

            // Draw border
            context.setStrokeColor(color.withAlphaComponent(0.8).cgColor)
            context.setLineWidth(1)
            context.stroke(annotRect)

            // Draw selection highlight if this annotation is selected
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
                    // Arrow pointing right
                    let arrowX = min(startX + width - arrowSize - 2, bounds.width - arrowSize)
                    let arrowY = y + annotationHeight / 2
                    context.move(to: CGPoint(x: arrowX, y: arrowY - arrowSize/2))
                    context.addLine(to: CGPoint(x: arrowX + arrowSize, y: arrowY))
                    context.addLine(to: CGPoint(x: arrowX, y: arrowY + arrowSize/2))
                    context.closePath()
                    context.fillPath()
                } else {
                    // Arrow pointing left
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

    /// Draws a macOS-style selection highlight around the selected annotation.
    ///
    /// Uses a solid rounded rectangle stroke with the system accent color,
    /// following macOS Human Interface Guidelines for content selection.
    func drawAnnotationSelectionHighlight(rect: CGRect, context: CGContext) {
        context.saveGState()

        let accentColor = NSColor.controlAccentColor
        let highlightRect = rect.insetBy(dx: -1.5, dy: -1.5)
        let cornerRadius: CGFloat = 3
        let path = CGPath(roundedRect: highlightRect, cornerWidth: cornerRadius, cornerHeight: cornerRadius, transform: nil)

        // Solid rounded stroke with accent color
        context.setStrokeColor(accentColor.cgColor)
        context.setLineWidth(2)
        context.addPath(path)
        context.strokePath()

        context.restoreGState()
    }

    /// Draws quality score overlay behind bases when enabled.
    ///
    /// This method renders semi-transparent colored rectangles behind each base
    /// to indicate the quality/confidence of the sequencing at that position.
    /// Quality scores are typically from FASTQ files.
    ///
    /// - Parameters:
    ///   - context: The graphics context to draw into
    ///   - sequence: The sequence containing quality scores
    ///   - frame: The current reference frame for coordinate mapping
    ///   - rect: The rectangle area to draw within
    func drawQualityOverlay(
        context: CGContext,
        sequence: Sequence,
        frame: ReferenceFrame,
        rect: CGRect
    ) {
        // Only draw if quality overlay is enabled and quality scores exist
        guard sequenceAppearance.showQualityOverlay,
              let qualityScores = sequence.qualityScores else {
            return
        }

        let startBase = max(0, Int(frame.start))
        let endBase = min(sequence.length, Int(frame.end) + 1)

        // Ensure we have quality scores for the visible range
        guard startBase < qualityScores.count else { return }

        let visibleBases = frame.end - frame.start
        let pixelsPerBase = frame.dataPixelWidth / CGFloat(max(1, visibleBases))

        context.saveGState()

        // Draw quality overlay for each visible base
        for i in startBase..<min(endBase, qualityScores.count) {
            let x = frame.leadingInset + CGFloat(i - startBase) * pixelsPerBase
            let qualityScore = qualityScores[i]
            let qualityColor = QualityColors.color(forScore: qualityScore)

            context.setFillColor(qualityColor.cgColor)
            context.fill(CGRect(
                x: x,
                y: rect.origin.y,
                width: max(1, pixelsPerBase - 0.5),
                height: rect.height
            ))
        }

        context.restoreGState()
    }

    func drawBaseLevelSequence(_ seq: Sequence, frame: ReferenceFrame, context: CGContext) {
        let startBase = max(0, Int(frame.start))
        let endBase = min(seq.length, Int(frame.end) + 1)

        let visibleBases = frame.end - frame.start
        let pixelsPerBase = frame.dataPixelWidth / CGFloat(max(1, visibleBases))

        // Font sizing based on available space
        let fontSize = min(pixelsPerBase * 0.75, trackHeight * 0.8)
        let showLetters = pixelsPerBase >= 8 && fontSize >= 6
        let font = NSFont.monospacedSystemFont(ofSize: max(6, fontSize), weight: .bold)

        // Draw quality overlay BEFORE the base colors so it appears behind
        let trackRect = CGRect(x: frame.leadingInset, y: trackY, width: frame.dataPixelWidth, height: trackHeight)
        drawQualityOverlay(context: context, sequence: seq, frame: frame, rect: trackRect)

        for i in startBase..<endBase {
            let x = frame.leadingInset + CGFloat(i - startBase) * pixelsPerBase
            let baseChar = seq[i]

            // Draw background color using appearance settings
            let color = sequenceAppearance.color(forBase: baseChar)
            context.setFillColor(color.cgColor)
            context.fill(CGRect(x: x, y: trackY, width: max(1, pixelsPerBase - 0.5), height: trackHeight))

            // Draw letter if space permits
            if showLetters {
                let attributes: [NSAttributedString.Key: Any] = [
                    .font: font,
                    .foregroundColor: NSColor.white,
                ]
                // Handle T/U conversion based on RNA mode:
                // - Default (DNA mode): U → T (show as DNA)
                // - RNA mode: T → U (show as RNA)
                var displayBase = String(baseChar).uppercased()
                if isRNAMode && displayBase == "T" {
                    displayBase = "U"
                } else if !isRNAMode && displayBase == "U" {
                    displayBase = "T"
                }
                let strSize = (displayBase as NSString).size(withAttributes: attributes)
                let strX = x + (pixelsPerBase - strSize.width) / 2
                let strY = trackY + (trackHeight - strSize.height) / 2
                (displayBase as NSString).draw(at: CGPoint(x: strX, y: strY), withAttributes: attributes)
            }
        }
    }

    func drawBlockLevelSequence(_ seq: Sequence, frame: ReferenceFrame, context: CGContext) {
        let startBase = max(0, Int(frame.start))
        let endBase = min(seq.length, Int(frame.end) + 1)

        let visibleBases = frame.end - frame.start
        let pixelsPerBase = frame.dataPixelWidth / CGFloat(max(1, visibleBases))

        // Draw quality overlay BEFORE the base colors so it appears behind
        let trackRect = CGRect(x: frame.leadingInset, y: trackY, width: frame.dataPixelWidth, height: trackHeight)
        drawQualityOverlay(context: context, sequence: seq, frame: frame, rect: trackRect)

        // Aggregate bases into bins for colored bar display
        let basesPerBin = max(1, Int(frame.scale))

        for binStart in stride(from: startBase, to: endBase, by: basesPerBin) {
            let binEnd = min(binStart + basesPerBin, endBase)
            let x = frame.leadingInset + CGFloat(binStart - startBase) * pixelsPerBase
            let width = CGFloat(binEnd - binStart) * pixelsPerBase

            // Find dominant base in this bin
            var counts: [Character: Int] = ["A": 0, "T": 0, "C": 0, "G": 0, "N": 0]
            for i in binStart..<binEnd {
                let base = Character(seq[i].uppercased())
                counts[base, default: 0] += 1
            }
            let dominantBase = counts.max(by: { $0.value < $1.value })?.key ?? "N"

            // Use appearance settings for color
            let color = sequenceAppearance.color(forBase: dominantBase)

            context.setFillColor(color.cgColor)
            context.fill(CGRect(x: x, y: trackY, width: max(1, width), height: trackHeight))
        }
    }

    func drawOverviewSequence(_ seq: Sequence, frame: ReferenceFrame, context: CGContext) {
        let startBase = max(0, Int(frame.start))
        let endBase = min(seq.length, Int(frame.end) + 1)

        let visibleBases = frame.end - frame.start
        let pixelsPerBase = frame.dataPixelWidth / CGFloat(max(1, visibleBases))

        // Calculate bin size for density display (2 pixels per bin minimum)
        let binSize = max(1, Int(frame.scale * 2))

        // GC content color gradient
        let lowGCColor = NSColor(calibratedRed: 0.2, green: 0.4, blue: 0.8, alpha: 1.0)
        let highGCColor = NSColor(calibratedRed: 0.8, green: 0.2, blue: 0.2, alpha: 1.0)

        for binStart in stride(from: startBase, to: endBase, by: binSize) {
            let binEnd = min(binStart + binSize, endBase)
            let x = frame.leadingInset + CGFloat(binStart - startBase) * pixelsPerBase
            let width = CGFloat(binEnd - binStart) * pixelsPerBase

            // Calculate GC content for this bin
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

            // Interpolate color based on GC content
            let color = interpolateColor(from: lowGCColor, to: highGCColor, factor: gcContent)
            context.setFillColor(color.cgColor)
            context.fill(CGRect(x: x, y: trackY, width: max(1, width), height: trackHeight))
        }

        // Draw GC legend
        drawGCLegend(context: context)
    }

    /// Draws a simple line representation for very zoomed out view.
    ///
    /// When zoomed out beyond showLineThreshold, individual bases and GC content
    /// become meaningless noise. This method draws a clean, simple line to
    /// represent the sequence extent without visual clutter.
    ///
    /// - Parameters:
    ///   - seq: The sequence to draw
    ///   - frame: The current reference frame for coordinate mapping
    ///   - context: The graphics context to draw into
    func drawLineSequence(_ seq: Sequence, frame: ReferenceFrame, context: CGContext) {
        let startBase = max(0, Int(frame.start))
        let endBase = min(seq.length, Int(frame.end) + 1)

        let visibleBases = frame.end - frame.start
        let pixelsPerBase = frame.dataPixelWidth / CGFloat(max(1, visibleBases))

        // Calculate the visible portion of the sequence
        let startX = frame.leadingInset + CGFloat(startBase - Int(frame.start)) * pixelsPerBase
        let endX = frame.leadingInset + CGFloat(endBase - Int(frame.start)) * pixelsPerBase
        let lineWidth = max(1, endX - startX)

        // Draw a simple gray bar to represent the sequence
        // Use a thicker bar that's proportional to track height for better visibility at low zoom
        let lineColor = NSColor.systemGray
        let lineY = trackY + trackHeight / 2
        let lineThickness: CGFloat = max(8, trackHeight * 0.4)  // At least 8px, up to 40% of track height

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

        // Draw scale indicator
        drawLineScaleIndicator(context: context, frame: frame)
    }

    /// Draws a scale indicator when in line mode.
    func drawLineScaleIndicator(context: CGContext, frame: ReferenceFrame) {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 9),
            .foregroundColor: NSColor.secondaryLabelColor
        ]

        let visibleBases = Int(frame.end - frame.start)
        let scaleText: String
        if visibleBases >= 1_000_000 {
            scaleText = "\(visibleBases / 1_000_000) Mb visible"
        } else if visibleBases >= 1_000 {
            scaleText = "\(visibleBases / 1_000) kb visible"
        } else {
            scaleText = "\(visibleBases) bp visible"
        }

        let textSize = (scaleText as NSString).size(withAttributes: attributes)
        let textX = bounds.maxX - textSize.width - 8
        let textY = trackY + 2

        (scaleText as NSString).draw(at: CGPoint(x: textX, y: textY), withAttributes: attributes)
    }

    func interpolateColor(from: NSColor, to: NSColor, factor: CGFloat) -> NSColor {
        let f = max(0, min(1, factor))
        let fromComponents = from.cgColor.components ?? [0, 0, 0, 1]
        let toComponents = to.cgColor.components ?? [0, 0, 0, 1]

        let r = fromComponents[0] + (toComponents[0] - fromComponents[0]) * f
        let g = fromComponents[1] + (toComponents[1] - fromComponents[1]) * f
        let b = fromComponents[2] + (toComponents[2] - fromComponents[2]) * f

        return NSColor(calibratedRed: r, green: g, blue: b, alpha: 1.0)
    }

    func drawGCLegend(context: CGContext) {
        let legendWidth: CGFloat = 60
        let legendHeight: CGFloat = 10
        let legendX = bounds.maxX - legendWidth - 8
        let legendY = trackY

        // Draw gradient
        let lowGCColor = NSColor(calibratedRed: 0.2, green: 0.4, blue: 0.8, alpha: 1.0)
        let highGCColor = NSColor(calibratedRed: 0.8, green: 0.2, blue: 0.2, alpha: 1.0)

        for i in 0..<Int(legendWidth) {
            let factor = CGFloat(i) / legendWidth
            let color = interpolateColor(from: lowGCColor, to: highGCColor, factor: factor)
            context.setFillColor(color.cgColor)
            context.fill(CGRect(x: legendX + CGFloat(i), y: legendY, width: 1, height: legendHeight))
        }

        // Draw labels
        let labelFont = NSFont.systemFont(ofSize: 8)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: labelFont,
            .foregroundColor: NSColor.secondaryLabelColor
        ]
        ("AT" as NSString).draw(at: CGPoint(x: legendX - 14, y: legendY), withAttributes: attributes)
        ("GC" as NSString).draw(at: CGPoint(x: legendX + legendWidth + 2, y: legendY), withAttributes: attributes)
    }

    func drawSequenceInfo(_ seq: Sequence, frame: ReferenceFrame, context: CGContext) {
        // Draw info below the sequence track
        var info = "\(seq.name) | \(seq.length.formatted()) bp | \(seq.alphabet)"

        // Add quality overlay indicator if enabled
        if sequenceAppearance.showQualityOverlay && seq.qualityScores != nil {
            info += " | Quality overlay enabled"
        }

        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11, weight: .regular),
            .foregroundColor: NSColor.secondaryLabelColor,
        ]
        let infoY = trackY + trackHeight + 8
        (info as NSString).draw(at: CGPoint(x: 4, y: infoY), withAttributes: attributes)
    }

}
