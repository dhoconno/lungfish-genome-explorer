// SequenceViewerView+Rendering.swift - Extracted from SequenceViewerView.swift (pure mechanical split, no behavior change)
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

    // MARK: - Drawing

    public override var isFlipped: Bool { true }

    public override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        // Rect-based tooltips (e.g. the no-reference read-track badge) are re-registered every
        // draw pass; clear stale rects first so they don't accumulate as content scrolls/redraws.
        removeAllToolTips()

        guard let context = NSGraphicsContext.current?.cgContext else {
            sequenceViewerLogger.warning("SequenceViewerView.draw: No graphics context available")
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

        // Check for multi-sequence mode first
        let hasBundle = currentReferenceBundle != nil
        let hasFrame = viewController?.referenceFrame != nil
        let hasVC = viewController != nil
        sequenceViewerLogger.debug("SequenceViewerView.draw: hasVC=\(hasVC), hasFrame=\(hasFrame), hasBundle=\(hasBundle), bounds=\(self.bounds.width)x\(self.bounds.height)")
        
        if let frame = viewController?.referenceFrame {
            // Insets are set in viewDidLayout/scheduleDeferredRedraw/handleViewResize.
            // draw() should not mutate frame state — just ensure consistency.


            if shouldDrawMultiSequence, let state = multiSequenceState {
                // Multi-sequence mode: draw stacked sequences with per-sequence annotations
                sequenceViewerLogger.debug("SequenceViewerView.draw: Drawing \(state.stackedSequences.count) stacked sequences")
                drawStackedSequences(state.stackedSequences, frame: frame, context: context)
            } else if currentReferenceBundle != nil {
                // Reference bundle mode: draw from cached bundle data
                sequenceViewerLogger.debug("SequenceViewerView.draw: Drawing bundle content for \(frame.chromosome)")
                drawBundleContent(frame: frame, context: context)
            } else if detachedAlignmentSource != nil {
                // Detached evidence mode reuses the full read/coverage renderer but has
                // no annotation database and no implicit reference sequence.
                drawDetachedAlignmentContent(frame: frame, context: context)
            } else if let seq = sequence {
                // Single sequence mode
                sequenceViewerLogger.debug("SequenceViewerView.draw: Drawing single sequence '\(seq.name, privacy: .public)' in bounds \(self.bounds.width)x\(self.bounds.height)")
                drawSequence(seq, frame: frame, context: context)
            } else if !suppressPlaceholder {
                // No sequence loaded
                sequenceViewerLogger.debug("SequenceViewerView.draw: No content to draw, showing placeholder")
                drawPlaceholder(context: context)
            }
        } else if !suppressPlaceholder {
            // Placeholder message - no reference frame
            sequenceViewerLogger.debug("SequenceViewerView.draw: No reference frame, showing placeholder")
            drawPlaceholder(context: context)
        }
    }
    
    /// Draws content from a reference bundle.
    ///
    /// Sequence and annotations are fetched and cached independently:
    /// - Annotations are always fetched for the visible region from SQLite
    /// - Sequence is only fetched when zoomed in enough to be visible (<500 bp/pixel)
    ///   because reading 240 MB of bgzip data for a full chromosome is impractical
    func drawBundleContent(frame: ReferenceFrame, context: CGContext) {
        guard let bundle = currentReferenceBundle else {
            sequenceViewerLogger.warning("drawBundleContent: currentReferenceBundle is nil")
            return
        }

        ensureVisibleViewportSelection(frame: frame)

        let visibleRegion = GenomicRegion(
            chromosome: frame.chromosome,
            start: max(0, Int(frame.start)),
            end: max(Int(frame.start) + 1, Int(ceil(frame.end)))
        )
        let scale = frame.scale  // bp/pixel
        let needsSequence = scale < showLineThreshold  // Only fetch sequence when it would be visible

        // Always fetch annotations — at wide zoom levels, density mode handles large counts.
        // The density histogram works at any scale; detailed rendering kicks in when zoomed in.
        let visibleSpan = visibleRegion.end - visibleRegion.start
        let needsAnnotations = true

        // Check if annotation cache covers the visible region
        let annotationsCovered = cachedAnnotationRegion?.chromosome == visibleRegion.chromosome
            && (cachedAnnotationRegion?.start ?? Int.max) <= visibleRegion.start
            && (cachedAnnotationRegion?.end ?? Int.min) >= visibleRegion.end

        // Diagnostic: log cache state at key decision points
        sequenceViewerLogger.debug("""
            drawBundleContent: scale=\(scale, format: .fixed(precision: 2)) bp/px, \
            span=\(visibleSpan) bp, \
            needsSeq=\(needsSequence), needsAnnot=\(needsAnnotations), \
            annotCovered=\(annotationsCovered), fetchingAnnot=\(self.isFetchingAnnotations), \
            cachedAnnotCount=\(self.cachedBundleAnnotations.count), \
            fetchingSeq=\(self.isFetchingBundleData), \
            cachedSeqLen=\(self.cachedBundleSequence?.count ?? 0)
            """)

        // Detect stuck fetch states — if a fetch has been running for more than 10 seconds,
        // assume it failed silently and reset the flag to allow retry.
        let stuckThreshold: TimeInterval = 10.0
        if isFetchingAnnotations, let startTime = annotationFetchStartTime,
           Date().timeIntervalSince(startTime) > stuckThreshold {
            sequenceViewerLogger.warning("drawBundleContent: Annotation fetch stuck for >\(stuckThreshold)s, resetting")
            isFetchingAnnotations = false
            annotationFetchStartTime = nil
        }
        if isFetchingBundleData, let startTime = sequenceFetchStartTime,
           Date().timeIntervalSince(startTime) > stuckThreshold {
            sequenceViewerLogger.warning("drawBundleContent: Sequence fetch stuck for >\(stuckThreshold)s, resetting")
            isFetchingBundleData = false
            sequenceFetchStartTime = nil
        }

        // Fetch annotations if cache is stale (only when zoomed in enough).
        // Always fetch asynchronously to avoid blocking the main thread — the sync path
        // caused hangs when first zooming past the 100Kbp threshold on a chromosome.
        if needsAnnotations && !annotationsCovered && !isFetchingAnnotations {
            sequenceViewerLogger.info("drawBundleContent: Triggering annotation fetch for \(visibleRegion.description)")
            fetchAnnotationsAsync(bundle: bundle, region: visibleRegion)
        } else if needsAnnotations && !annotationsCovered && isFetchingAnnotations {
            sequenceViewerLogger.debug("drawBundleContent: Annotation fetch already in progress, waiting")
        }

        // Clear fetch error when user has navigated to a completely different region
        // (different chromosome or non-overlapping position), allowing retry.
        if bundleFetchError != nil, let failed = failedFetchRegion {
            if failed.chromosome != visibleRegion.chromosome
                || visibleRegion.end < failed.start || visibleRegion.start > failed.end {
                sequenceViewerLogger.info("drawBundleContent: Auto-clearing fetch error (navigated away from failed region \(failed.description))")
                bundleFetchError = nil
                failedFetchRegion = nil
            }
        }

        // Check if sequence cache covers the visible region
        if needsSequence {
            let sequenceCovered = cachedBundleSequence != nil
                && cachedSequenceRegion?.chromosome == visibleRegion.chromosome
                && (cachedSequenceRegion?.start ?? Int.max) <= visibleRegion.start
                && (cachedSequenceRegion?.end ?? Int.min) >= visibleRegion.end

            if !sequenceCovered && !isFetchingBundleData && bundleFetchError == nil {
                fetchSequenceAsync(bundle: bundle, region: visibleRegion)
            }
        }

        // Draw sequence (or line placeholder)
        if needsSequence {
            if let cached = cachedBundleSequence,
               let cachedRegion = cachedSequenceRegion,
               cachedRegion.chromosome == visibleRegion.chromosome,
               cachedRegion.start <= visibleRegion.start,
               cachedRegion.end >= visibleRegion.end {
                sequenceViewerLogger.debug("drawBundleContent: Drawing sequence at scale=\(scale) bp/px, cached=\(cached.count) bp, region=\(cachedRegion.description)")
                drawBundleSequence(cached, region: cachedRegion, frame: frame, context: context)
            } else if let fetchError = bundleFetchError {
                sequenceViewerLogger.debug("drawBundleContent: Sequence fetch failed (showing error): \(fetchError)")
                drawSequenceError(fetchError, frame: frame, context: context)
            } else {
                let hasCached = cachedBundleSequence != nil
                let cachedChrom = cachedSequenceRegion?.chromosome ?? "nil"
                let cachedStart = cachedSequenceRegion?.start ?? -1
                let cachedEnd = cachedSequenceRegion?.end ?? -1
                sequenceViewerLogger.debug("drawBundleContent: No sequence cache for visible region. hasCached=\(hasCached), cachedChrom=\(cachedChrom), cachedRange=\(cachedStart)-\(cachedEnd), visibleRange=\(visibleRegion.start)-\(visibleRegion.end), fetching=\(self.isFetchingBundleData)")
                drawSequenceLine(frame: frame, context: context)
            }
        } else {
            drawSequenceLine(frame: frame, context: context)
        }

        // Draw translation track if active and zoomed in enough for individual bases
        if showTranslationTrack && scale < showLettersThreshold {
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
            } else if !frameTranslationFrames.isEmpty, let seq = cachedBundleSequence,
                      let seqRegion = cachedSequenceRegion {
                TranslationTrackRenderer.drawFrameTranslations(
                    frames: frameTranslationFrames,
                    sequence: seq,
                    sequenceStart: seqRegion.start,
                    frame: frame,
                    context: context,
                    yOffset: transY,
                    table: frameTranslationTable,
                    colorScheme: translationColorScheme,
                    showStopCodons: translationShowStopCodons
                )
            }
        }

        // --- Draw annotations (above variants) ---
        if cachedAnnotationRegion?.chromosome == visibleRegion.chromosome,
           !cachedBundleAnnotations.isEmpty {
            sequenceViewerLogger.debug("drawBundleContent: Drawing \(self.cachedBundleAnnotations.count) annotations")
            drawBundleAnnotations(cachedBundleAnnotations, frame: frame, context: context)
        } else {
            // No annotations yet — update bottom Y for variant positioning
            lastAnnotationBottomY = annotationTrackY
        }

        // Show annotation loading status whenever annotation fetch is in flight.
        if isFetchingAnnotations {
            let message = cachedBundleAnnotations.isEmpty ? "Fetching annotations..." : "Updating annotations..."
            drawTrackLoadingBadge(context: context, message: message, yOffset: annotationTrackY + 2)
        }

        // --- Variants below annotations ---
        // Check if variant cache covers the visible region
        let variantsCovered = cachedVariantRegion?.chromosome == visibleRegion.chromosome
            && (cachedVariantRegion?.start ?? Int.max) <= visibleRegion.start
            && (cachedVariantRegion?.end ?? Int.min) >= visibleRegion.end

        // Fetch variants if cache is stale
        if !variantsCovered && !isFetchingVariants {
            fetchVariantsAsync(bundle: bundle, region: visibleRegion)
        }

        let filteredVariants: [SequenceAnnotation] = filteredVisibleVariantAnnotations

        // Draw variant summary bar + genotype rows (below annotations)
        let variantDisplayCap = 5_000
        if showVariants && !filteredVariants.isEmpty {
            let vY = variantTrackY

            let activeTheme = VariantColorTheme.named(sampleDisplayState.colorThemeName)

            if sampleDisplayState.showSummaryBar {
                VariantTrackRenderer.drawSummaryBar(
                    variants: filteredVariants,
                    frame: frame,
                    context: context,
                    yOffset: vY,
                    barHeight: sampleDisplayState.summaryBarHeight,
                    theme: activeTheme
                )
            }

            if filteredVariants.count > variantDisplayCap {
                // Auto-enable summary bar so density histogram is always visible at zoomed-out views
                if !sampleDisplayState.showSummaryBar {
                    sampleDisplayState.showSummaryBar = true
                }
                // Too many variants for genotype display — show zoom-in message
                let msg = "Zoom in to display genotypes (\(filteredVariants.count) variants visible)" as NSString
                let msgAttrs: [NSAttributedString.Key: Any] = [
                    .font: NSFont.systemFont(ofSize: 10),
                    .foregroundColor: NSColor.secondaryLabelColor,
                ]
                let msgY = vY + effectiveSummaryBarHeight + 4
                msg.draw(at: CGPoint(x: 4, y: msgY), withAttributes: msgAttrs)
            } else {
                // Draw per-sample genotype rows if available and enabled
                if let genotypeData = filteredVisibleGenotypeData(), cachedSampleCount > 0,
                   sampleDisplayState.showGenotypeRows {
                    clampGenotypeScrollOffset(frame: frame)
                    let genotypeY = vY + effectiveSummaryBarHeight + effectiveSummaryToRowGap
                    let availableHeight = max(0, bounds.height - genotypeY)
                    VariantTrackRenderer.drawGenotypeRows(
                        genotypeData: genotypeData,
                        frame: frame,
                        context: context,
                        yOffset: genotypeY,
                        state: sampleDisplayState,
                        useHaploidAFShading: sampleDisplayState.useHaploidAFShading,
                        sampleDisplayNames: cachedGenotypeSampleDisplayNames,
                        scrollOffset: genotypeScrollOffset,
                        availableHeight: availableHeight,
                        theme: activeTheme
                    )
                }

                // Fetch genotype data if needed and we have samples
                if cachedSampleCount > 0 && !isFetchingGenotypes {
                    let genotypeCovered = cachedGenotypeRegion?.chromosome == visibleRegion.chromosome
                        && (cachedGenotypeRegion?.start ?? Int.max) <= visibleRegion.start
                        && (cachedGenotypeRegion?.end ?? Int.min) >= visibleRegion.end
                    if !genotypeCovered {
                        fetchGenotypesAsync(bundle: bundle, region: visibleRegion)
                    }
                }
            }

            // Track the bottom Y of the variant track so reads can stack below
            let totalVariantHeight = VariantTrackRenderer.totalHeight(
                sampleCount: cachedSampleCount,
                state: sampleDisplayState
            )
            lastVariantBottomY = vY + totalVariantHeight

            if isFetchingVariants {
                drawTrackLoadingBadge(context: context, message: "Updating variants...", yOffset: vY + 2)
            }
            if isFetchingGenotypes && filteredVariants.count <= variantDisplayCap {
                let genotypeBadgeY = vY + effectiveSummaryBarHeight + effectiveSummaryToRowGap + 2
                drawTrackLoadingBadge(context: context, message: "Updating genotypes...", yOffset: genotypeBadgeY)
            }
        } else if showVariants && !bundle.variantTrackIds.isEmpty {
            // Variant tracks exist but nothing to display — show status badge
            let vY = variantTrackY
            let message: String
            if isFetchingVariants {
                message = "Fetching variants\u{2026}"
            } else if cachedVariantAnnotations.isEmpty {
                message = "No variants in this region"
            } else {
                message = "All \(cachedVariantAnnotations.count) variants filtered out"
            }
            drawTrackLoadingBadge(context: context, message: message, yOffset: vY + 2)
        }

        // --- Read alignments below variants ---
        let showsConsensusAtCurrentScale = applyConsensusViewportPolicy(scale: scale)

        if !alignmentDataProviders.isEmpty && showReads {
            let tier = applyReadViewportPolicy(scale: scale)
            let coverageY = readTrackY
            let maxRowsLimit: Int? = limitReadRowsSetting ? max(1, maxReadRowsSetting) : nil
            let maxRowsCacheKey = maxRowsLimit ?? 0

            let displaySettings = ReadTrackRenderer.DisplaySettings(
                showMismatches: showMismatchesSetting,
                showSoftClips: showSoftClipsSetting,
                showIndels: showIndelsSetting,
                consensusMaskingEnabled: consensusMaskingEnabledSetting,
                consensusGapThreshold: Double(consensusGapThresholdPercentSetting) / 100.0,
                consensusMaskingMinDepth: consensusMaskingMinDepthSetting,
                showStrandColors: showStrandColorsSetting
            )

            // Coverage strip is always visible.
            let depthCovered = cachedDepthRegion?.chromosome == visibleRegion.chromosome
                && (cachedDepthRegion?.start ?? Int.max) <= visibleRegion.start
                && (cachedDepthRegion?.end ?? Int.min) >= visibleRegion.end
            if !depthCovered && !isFetchingDepth {
                fetchDepthAsync(bundle: bundle, region: visibleRegion)
            }
            lastRenderedCoverageY = coverageY
            let coverageRect = CGRect(
                x: 0,
                y: coverageY,
                width: bounds.width,
                height: coverageStripHeight
            )
            ReadTrackRenderer.drawCoverage(
                depthPoints: cachedDepthPoints,
                regionStart: visibleRegion.start,
                regionEnd: visibleRegion.end,
                frame: frame,
                context: context,
                rect: coverageRect
            )
            if isFetchingDepth && cachedDepthPoints.isEmpty {
                let elapsed = depthFetchStartTime.map { Date().timeIntervalSince($0) } ?? 0
                if elapsed > 0.15 {
                    drawTrackLoadingBadge(
                        context: context,
                        message: "Loading depth...",
                        yOffset: coverageRect.minY + 2
                    )
                }
            }

            var rowsY = coverageRect.maxY + coverageToConsensusGap
            if showsConsensusAtCurrentScale {
                let consensusOptions = currentConsensusOptionsSignature()
                let consensusCovered = cachedConsensusRegion?.chromosome == visibleRegion.chromosome
                    && (cachedConsensusRegion?.start ?? Int.max) <= visibleRegion.start
                    && (cachedConsensusRegion?.end ?? Int.min) >= visibleRegion.end
                    && cachedConsensusOptionsSignature == consensusOptions
                if !consensusCovered && !isFetchingConsensus {
                    fetchConsensusAsync(bundle: bundle, region: visibleRegion)
                }
                let consensusRect = CGRect(x: 0, y: rowsY, width: bounds.width, height: consensusStripHeight)
                drawConsensusTrack(
                    sequenceString: cachedConsensusSequence,
                    region: cachedConsensusRegion,
                    frame: frame,
                    context: context,
                    rect: consensusRect
                )
                rowsY = consensusRect.maxY + consensusToReadGap
            }

            // Cache rendering state for hit-testing.
            lastRenderedReadY = rowsY

            if tier == .coverage {
                if bounds.height - rowsY > 20 {
                    drawReadZoomHint(context: context, yOffset: rowsY + 2, scale: scale)
                }
            } else {
                let readsCovered = cachedReadRegion?.chromosome == visibleRegion.chromosome
                    && (cachedReadRegion?.start ?? Int.max) <= visibleRegion.start
                    && (cachedReadRegion?.end ?? Int.min) >= visibleRegion.end
                if !readsCovered && !isFetchingReads {
                    fetchReadsAsync(bundle: bundle, region: visibleRegion)
                }

                if !cachedAlignedReads.isEmpty {
                    // Reuse cached pack layout if scale, data, viewport, and settings haven't changed.
                    // Viewport position matters because reads are filtered to near-viewport before
                    // packing — if the user pans significantly, the visible reads change.
                    let viewportShift = abs(visibleRegion.start - cachedPackViewportStart)
                    let viewportSpan = max(1, visibleRegion.end - visibleRegion.start)
                    let scaleChanged = (scale != cachedPackScale)
                    let dataChanged = (readFetchGeneration != cachedPackDataGeneration)
                    let needsRepack = scaleChanged
                        || dataChanged
                        || (maxRowsCacheKey != cachedPackMaxRows)
                        || (viewportShift > viewportSpan / 4) // Repack when panned >25% of viewport

                    if needsRepack {
                        // New zoom/data fetch should snap back to top rows for predictable navigation.
                        if scaleChanged || dataChanged {
                            readScrollOffset = 0
                        }
                        // Filter reads to viewport +/- safety padding while ensuring reads that
                        // overlap the visible window are never dropped.
                        // The cached read region can be much wider than the viewport (especially
                        // when zooming in from a wider view). Packing all reads wastes the limited
                        // 75-row budget on far off-screen reads, potentially leaving no rows for
                        // reads in the visible window.
                        let viewportSpan = visibleRegion.end - visibleRegion.start
                        let maxReadSpan = max(
                            1,
                            cachedAlignedReads.lazy.prefix(50_000).map { max(1, $0.alignmentEnd - $0.position) }.max() ?? 500
                        )
                        let packPadding = max(maxReadSpan, min(10_000, max(500, viewportSpan)))
                        let packStart = max(0, visibleRegion.start - packPadding)
                        let packEnd = visibleRegion.end + packPadding

                        let readsForPacking = cachedAlignedReads.filter { read in
                            read.chromosome == visibleRegion.chromosome
                                && read.alignmentEnd > packStart
                                && read.position < packEnd
                        }

                        let (packed, packOverflow) = ReadTrackRenderer.packReads(
                            readsForPacking,
                            frame: frame,
                            maxRows: maxRowsLimit,
                            sortMode: .position,
                            prioritizedRegion: visibleRegion.start..<visibleRegion.end
                        )
                        cachedPackedReads = packed
                        cachedPackOverflow = packOverflow
                        cachedPackScale = scale
                        cachedPackDataGeneration = readFetchGeneration
                        cachedPackMaxRows = maxRowsCacheKey
                        cachedPackViewportStart = visibleRegion.start
                        cachedPackViewportEnd = visibleRegion.end
                    }
                    let rowCount = (cachedPackedReads.map(\.row).max() ?? -1) + 1
                    let contentHeight = ReadTrackRenderer.totalHeight(
                        rowCount: rowCount,
                        tier: tier,
                        verticalCompress: verticallyCompressContigSetting
                    )
                    readContentHeight = contentHeight

                    // Available vertical space: from rY to bottom of view
                    let availableHeight = max(0, bounds.height - rowsY)
                    let visibleHeight = min(contentHeight, max(availableHeight, maxReadTrackHeight))

                    // Clamp scroll offset
                    let maxScroll = max(0, contentHeight - visibleHeight)
                    if readScrollOffset > maxScroll { readScrollOffset = maxScroll }

                    // Clip to visible read area and translate by scroll offset
                    let clipRect = CGRect(x: 0, y: rowsY, width: bounds.width, height: visibleHeight)
                    context.saveGState()
                    context.clip(to: clipRect)
                    context.translateBy(x: 0, y: -readScrollOffset)

                    let drawRect = CGRect(x: 0, y: rowsY, width: bounds.width, height: contentHeight)
                    let maskedPositions: Set<Int>
                    if displaySettings.consensusMaskingEnabled {
                        maskedPositions = ReadTrackRenderer.computeHighGapMaskedPositions(
                            packedReads: cachedPackedReads,
                            visibleRegion: visibleRegion.start..<visibleRegion.end,
                            minDepth: displaySettings.consensusMaskingMinDepth,
                            gapThreshold: displaySettings.consensusGapThreshold
                        )
                    } else {
                        maskedPositions = []
                    }

                    if tier == .packed {
                        ReadTrackRenderer.drawPackedReads(
                            packedReads: cachedPackedReads, overflow: cachedPackOverflow, frame: frame,
                            referenceSequence: cachedBundleSequence,
                            referenceStart: cachedSequenceRegion?.start ?? Int(frame.start),
                            settings: displaySettings,
                            verticalCompress: verticallyCompressContigSetting,
                            maxRowsLimit: maxRowsLimit,
                            maskedPositions: maskedPositions,
                            context: context, rect: drawRect
                        )
                    } else {
                        ReadTrackRenderer.drawBaseReads(
                            packedReads: cachedPackedReads, overflow: cachedPackOverflow, frame: frame,
                            referenceSequence: cachedBundleSequence,
                            referenceStart: cachedSequenceRegion?.start ?? Int(frame.start),
                            settings: displaySettings,
                            verticalCompress: verticallyCompressContigSetting,
                            maxRowsLimit: maxRowsLimit,
                            maskedPositions: maskedPositions,
                            context: context, rect: drawRect
                        )
                    }

                    context.restoreGState()

                    // Draw scroll indicator if content exceeds visible area
                    if contentHeight > visibleHeight && maxScroll > 0 {
                        drawReadScrollIndicator(
                            context: context, clipRect: clipRect,
                            contentHeight: contentHeight, scrollOffset: readScrollOffset
                        )
                    }

                    // Degradation cue: base-tier dots/letters classification needs either a
                    // loaded reference or per-read MD tags. With neither, every base renders as
                    // a mismatch letter — surface that so it doesn't read as "no mismatches found".
                    if tier == .base {
                        let hasReference = cachedBundleSequence != nil
                        let hasMDTags = cachedPackedReads.contains { $0.read.mdTag != nil }
                        if ReadTrackRenderer.shouldShowNoReferenceBadge(hasReference: hasReference, hasMDTags: hasMDTags) {
                            drawTrackLoadingBadge(
                                context: context,
                                message: ReadTrackRenderer.noReferenceBadgeMessage,
                                yOffset: rowsY + 2,
                                tooltip: ReadTrackRenderer.noReferenceBadgeTooltip
                            )
                        }
                    }
                } else {
                    cachedPackedReads = []
                    readContentHeight = 0
                }

                if isFetchingReads {
                    let elapsed = readFetchStartTime.map { Date().timeIntervalSince($0) } ?? 0
                    if elapsed > 0.15 {
                        let message = cachedAlignedReads.isEmpty ? "Loading mapped reads..." : "Updating mapped reads..."
                        drawTrackLoadingBadge(context: context, message: message, yOffset: rowsY + 2)
                    }
                }
            }
        }

        // Draw gutter background overlays for non-variant content areas
        // (sequence track, annotation track). The variant track handles its own gutter.
        let gutterInset = frame.leadingInset
        let contentTop: CGFloat = 0
        let contentBottom = variantTrackY
        let contentHeight = max(0, contentBottom - contentTop)

        if gutterInset > 0 && contentHeight > 0 {
            // Left gutter background
            context.setFillColor(VariantTrackRenderer.gutterBackgroundColor)
            context.fill(CGRect(x: 0, y: contentTop, width: gutterInset, height: contentHeight))
            // Left vertical separator
            context.setStrokeColor(VariantTrackRenderer.gutterSeparatorColor)
            context.setLineWidth(0.5)
            let sepX = gutterInset - VariantTrackRenderer.sampleLabelToDataMargin / 2
            context.move(to: CGPoint(x: sepX, y: contentTop))
            context.addLine(to: CGPoint(x: sepX, y: contentBottom))
            context.strokePath()
        }

        // Right margin overlay — clean visual boundary before inspector
        let trailingInset = frame.trailingInset
        if trailingInset > 0 {
            let rightX = bounds.width - trailingInset
            // Right margin background (full height)
            context.setFillColor(NSColor.windowBackgroundColor.cgColor)
            context.fill(CGRect(x: rightX, y: 0, width: trailingInset, height: bounds.height))
            // Right vertical separator
            context.setStrokeColor(VariantTrackRenderer.gutterSeparatorColor)
            context.setLineWidth(0.5)
            context.move(to: CGPoint(x: rightX + 0.5, y: 0))
            context.addLine(to: CGPoint(x: rightX + 0.5, y: bounds.height))
            context.strokePath()
        }

        // Draw selection overlays on top of all content
        drawColumnSelectionHighlight(frame: frame, context: context)
        drawSelectedReadHighlights(frame: frame, context: context)
    }

    /// Read-only evidence rendering for a loose final BAM. This intentionally has
    /// no annotation/variant fetches and only draws bases when validation supplied a
    /// real FASTA record; it never constructs a read-derived reference.
    func drawDetachedAlignmentContent(frame: ReferenceFrame, context: CGContext) {
        guard let source = detachedAlignmentSource else { return }
        guard detachedEvidenceIsCurrent(source) else {
            drawTrackLoadingBadge(context: context, message: detachedEvidenceStaleReason ?? "Classifier alignment evidence is unavailable.", yOffset: 8)
            return
        }
        if let message = detachedEvidenceFetchMessage {
            drawTrackLoadingBadge(context: context, message: message, yOffset: 8)
        }
        ensureVisibleViewportSelection(frame: frame)
        let region = GenomicRegion(
            chromosome: frame.chromosome,
            start: max(0, Int(frame.start)),
            end: max(Int(frame.start) + 1, Int(ceil(frame.end)))
        )
        let scale = frame.scale
        if let sequence = source.referenceSequence,
           scale < showLineThreshold,
           let cachedRegion = cachedSequenceRegion {
            drawBundleSequence(sequence, region: cachedRegion, frame: frame, context: context)
        } else {
            drawSequenceLine(frame: frame, context: context)
        }

        guard showReads else { return }
        let tier = applyReadViewportPolicy(scale: scale)
        let coverageRect = CGRect(x: 0, y: readTrackY, width: bounds.width, height: coverageStripHeight)
        let depthCovered = cachedDepthRegion?.chromosome == region.chromosome
            && (cachedDepthRegion?.start ?? Int.max) <= region.start
            && (cachedDepthRegion?.end ?? Int.min) >= region.end
        if !selectedReadGroupsSetting.isEmpty {
            // samtools depth does not share the view command's RG predicate, so
            // retaining a prior all-RG cache would misrepresent filtered reads.
            fetchDetachedDepth(source: source, region: region)
        } else if !depthCovered && !isFetchingDepth {
            fetchDetachedDepth(source: source, region: region)
        }
        ReadTrackRenderer.drawCoverage(
            depthPoints: cachedDepthPoints,
            regionStart: region.start,
            regionEnd: region.end,
            frame: frame,
            context: context,
            rect: coverageRect
        )

        let rowsY = coverageRect.maxY + coverageToConsensusGap
        lastRenderedReadY = rowsY
        guard tier != .coverage else {
            drawReadZoomHint(context: context, yOffset: rowsY + 2, scale: scale)
            return
        }
        let readsCovered = cachedReadRegion?.chromosome == region.chromosome
            && (cachedReadRegion?.start ?? Int.max) <= region.start
            && (cachedReadRegion?.end ?? Int.min) >= region.end
        if !readsCovered && !isFetchingReads { fetchDetachedReads(source: source, region: region) }
        guard !cachedAlignedReads.isEmpty else { return }

        let maxRows = limitReadRowsSetting ? max(1, maxReadRowsSetting) : nil
        let (packed, overflow) = ReadTrackRenderer.packReads(
            cachedAlignedReads.filter { $0.chromosome == region.chromosome },
            frame: frame,
            maxRows: maxRows,
            sortMode: .position,
            prioritizedRegion: region.start..<region.end
        )
        cachedPackedReads = packed
        cachedPackOverflow = overflow
        let rowCount = (packed.map(\.row).max() ?? -1) + 1
        let contentHeight = ReadTrackRenderer.totalHeight(rowCount: rowCount, tier: tier, verticalCompress: verticallyCompressContigSetting)
        let rect = CGRect(x: 0, y: rowsY, width: bounds.width, height: contentHeight)
        let settings = ReadTrackRenderer.DisplaySettings(
            showMismatches: showMismatchesSetting,
            showSoftClips: showSoftClipsSetting,
            showIndels: showIndelsSetting,
            consensusMaskingEnabled: consensusMaskingEnabledSetting,
            consensusGapThreshold: Double(consensusGapThresholdPercentSetting) / 100,
            consensusMaskingMinDepth: consensusMaskingMinDepthSetting,
            showStrandColors: showStrandColorsSetting
        )
        if tier == .packed {
            ReadTrackRenderer.drawPackedReads(packedReads: packed, overflow: overflow, frame: frame, referenceSequence: source.referenceSequence, referenceStart: 0, settings: settings, verticalCompress: verticallyCompressContigSetting, maxRowsLimit: maxRows, maskedPositions: [], context: context, rect: rect)
        } else {
            ReadTrackRenderer.drawBaseReads(packedReads: packed, overflow: overflow, frame: frame, referenceSequence: source.referenceSequence, referenceStart: 0, settings: settings, verticalCompress: verticallyCompressContigSetting, maxRowsLimit: maxRows, maskedPositions: [], context: context, rect: rect)
            if source.referenceSequence == nil && ReadTrackRenderer.shouldShowNoReferenceBadge(hasReference: false, hasMDTags: packed.contains(where: { $0.read.mdTag != nil })) {
                drawTrackLoadingBadge(context: context, message: ReadTrackRenderer.noReferenceBadgeMessage, yOffset: rowsY + 2, tooltip: ReadTrackRenderer.noReferenceBadgeTooltip)
            }
        }
        drawSelectedReadHighlights(frame: frame, context: context)
    }

    /// Fetches annotations asynchronously for the visible region from SQLite annotation databases.
    /// Runs database queries on a background thread to avoid blocking the UI.
    /// Dedicated queue for annotation I/O to avoid being starved by the search index build.
    static let annotationFetchQueue = DispatchQueue(label: "com.lungfish.annotationFetch", qos: .userInteractive)

    /// Schedules UI state updates on the main run loop common modes.
    /// This avoids starvation during AppKit tracking/layout-heavy loops.
    ///
    /// Uses `MainActor.assumeIsolated` inside the CFRunLoop block to guarantee
    /// the compiler knows we're on the main actor (GCD main queue is always drained).
    nonisolated static func enqueueMainRunLoop(_ block: @escaping @MainActor () -> Void) {
        if Thread.isMainThread {
            MainActor.assumeIsolated { block() }
            return
        }
        CFRunLoopPerformBlock(CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue) {
            MainActor.assumeIsolated { block() }
        }
        CFRunLoopWakeUp(CFRunLoopGetMain())
    }

    func fetchAnnotationsAsync(bundle: ReferenceBundle, region: GenomicRegion) {
        annotationFetchGeneration += 1
        let thisGeneration = annotationFetchGeneration
        isFetchingAnnotations = true
        annotationFetchStartTime = Date()

        let chromLength = bundle.chromosomeLength(named: region.chromosome) ?? Int64(region.end + 1000)
        // Pre-fetch 200% extra on each side so panning doesn't invalidate cache.
        // User can pan 2 full screen-widths before a refetch is needed.
        let visibleSpan = region.end - region.start
        let expandAmount = max(50_000, visibleSpan * 2)
        let expandedStart = max(0, region.start - expandAmount)
        let expandedEnd = min(Int(chromLength), region.end + expandAmount)
        let expandedRegion = GenomicRegion(chromosome: region.chromosome, start: expandedStart, end: expandedEnd)
        let trackIds = bundle.annotationTrackIds

        // Capture per-annotation color overrides for application after loading
        let colorOverrides = viewController?.currentBundleViewState?.annotationColorOverrides ?? [:]

        sequenceViewerLogger.info("fetchAnnotationsAsync: gen=\(thisGeneration), Fetching \(expandedRegion.description) (\(trackIds.count) tracks) on background thread")

        Self.annotationFetchQueue.async { [weak self] in
            var allAnnotations: [SequenceAnnotation] = []

            for trackId in trackIds {
                guard let trackInfo = bundle.annotationTrack(id: trackId) else { continue }

                guard let dbPath = trackInfo.databasePath else {
                    sequenceViewerLogger.error("fetchAnnotationsAsync: Annotation track \(trackId) has no databasePath")
                    continue
                }

                guard let dbURL = try? bundle.memberURL(
                    for: dbPath,
                    field: "annotations[\(trackId)].databasePath"
                ) else {
                    sequenceViewerLogger.error("fetchAnnotationsAsync: Annotation database path is unsafe for \(trackId) at \(dbPath)")
                    continue
                }
                guard FileManager.default.fileExists(atPath: dbURL.path) else {
                    sequenceViewerLogger.error("fetchAnnotationsAsync: Annotation database missing for \(trackId) at \(dbPath)")
                    continue
                }

                do {
                    var annotations = try bundle.getAnnotationsSync(trackId: trackId, region: expandedRegion)
                    for index in annotations.indices {
                        annotations[index].qualifiers["annotation_db_track_id"] = AnnotationQualifier(trackId)
                    }
                    allAnnotations.append(contentsOf: annotations)
                    sequenceViewerLogger.info("fetchAnnotationsAsync: SQLite query returned \(annotations.count) annotations for track \(trackId)")
                } catch {
                    sequenceViewerLogger.error("fetchAnnotationsAsync: SQLite query failed for \(trackId): \(error.localizedDescription)")
                }
            }

            // Apply per-annotation color overrides from BundleViewState
            if !colorOverrides.isEmpty {
                for i in allAnnotations.indices {
                    let key = allAnnotations[i].colorOverrideKey
                    if let override = colorOverrides[key] {
                        allAnnotations[i].color = override
                    }
                }
            }

            let count = allAnnotations.count
            sequenceViewerLogger.info("fetchAnnotationsAsync[RUNLOOP_V2]: gen=\(thisGeneration), background done, \(count) annotations found, scheduling main-runloop commit")

            Self.enqueueMainRunLoop { [weak self] in
                sequenceViewerLogger.info("fetchAnnotationsAsync[RUNLOOP_V2]: gen=\(thisGeneration), main-runloop callback executing")
                guard let viewer = self else {
                    sequenceViewerLogger.error("fetchAnnotationsAsync: self is nil in main-runloop callback, \(count) annotations lost")
                    return
                }
                // Check generation counter: discard stale results from superseded fetches
                guard thisGeneration == viewer.annotationFetchGeneration else {
                    sequenceViewerLogger.info("fetchAnnotationsAsync: Discarding stale result gen=\(thisGeneration) (current=\(viewer.annotationFetchGeneration))")
                    return
                }
                guard viewer.currentReferenceBundle?.url.standardizedFileURL == bundle.url.standardizedFileURL else {
                    sequenceViewerLogger.info("fetchAnnotationsAsync: Discarding stale result for replaced reference bundle")
                    return
                }
                let elapsed = viewer.annotationFetchStartTime.map { Date().timeIntervalSince($0) } ?? 0
                viewer.cachedBundleAnnotations = allAnnotations
                viewer.cachedAnnotationRegion = expandedRegion
                viewer.cachedCDSCodingContexts = [:]
                viewer.isFetchingAnnotations = false
                viewer.annotationFetchStartTime = nil
                viewer.invalidateAnnotationTile()
                sequenceViewerLogger.info("fetchAnnotationsAsync: Cached \(count) annotations for \(expandedRegion.description) in \(elapsed, format: .fixed(precision: 3))s, triggering redraw")
                viewer.setNeedsDisplay(viewer.bounds)
            }
        }
    }

    /// Builds a map from reference chromosome names to variant DB chromosome names.
    ///
    /// When a VCF uses different chromosome naming (e.g., "7" vs "NC_041760.1"),
    /// this method matches chromosomes by comparing reference lengths to variant
    /// database max positions. A VCF chromosome matches a reference chromosome
    /// if its max variant position is within 1% of the reference length.
    nonisolated static func buildVariantChromosomeAliasMap(
        bundleChromosomes: [ChromosomeInfo],
        variantDB: VariantDatabase,
        sequenceViewerLogger: Logger,
        includeMaxPositionFallback: Bool = true
    ) -> [String: String] {
        let vcfChroms = Set(variantDB.allChromosomes())
        let refChromNames = Set(bundleChromosomes.map(\.name))

        // Check if all VCF chromosomes already match reference names
        let unmatched = vcfChroms.subtracting(refChromNames)
        if unmatched.isEmpty { return [:] }

        var aliasMap: [String: String] = [:]  // ref name → VCF name
        var usedVCFChroms = Set<String>()

        // Strategy 1: Name-based matching (fast, reliable with populated aliases)
        // mapVCFChromosomes checks: exact match, aliases, version stripping, chr prefix,
        // fuzzy prefix, and FASTA description matching
        let nameMap = mapVCFChromosomes(Array(unmatched), toBundleChromosomes: bundleChromosomes)
        // nameMap is [vcfChrom: bundleName] — invert to [bundleName: vcfChrom]
        for (vcfChrom, bundleName) in nameMap {
            if aliasMap[bundleName] == nil {
                aliasMap[bundleName] = vcfChrom
                usedVCFChroms.insert(vcfChrom)
            }
        }

        // Strategy 2: Length-based matching for any remaining unmatched chromosomes.
        // Uses VCF ##contig header lengths and optionally MAX(end_pos) as fallback.
        let afterNameMatching = unmatched.subtracting(usedVCFChroms)
        if !afterNameMatching.isEmpty {
            let vcfContigLengths = variantDB.contigLengths()
            let vcfMaxPositions: [String: Int]
            if includeMaxPositionFallback && vcfContigLengths.isEmpty {
                vcfMaxPositions = variantDB.chromosomeMaxPositions()
            } else {
                vcfMaxPositions = [:]
            }

            for chrom in bundleChromosomes {
                if vcfChroms.contains(chrom.name) { continue }
                if aliasMap[chrom.name] != nil { continue }  // Already matched by name

                var bestMatch: String?
                var bestDelta = Int64.max

                for vcfChrom in afterNameMatching where !usedVCFChroms.contains(vcfChrom) {
                    if let contigLength = vcfContigLengths[vcfChrom] {
                        let delta = abs(chrom.length - contigLength)
                        guard delta <= 10 else { continue }
                        if delta < bestDelta {
                            bestDelta = delta
                            bestMatch = vcfChrom
                        }
                    } else if let maxPos = vcfMaxPositions[vcfChrom] {
                        let maxPos64 = Int64(maxPos)
                        guard maxPos64 <= chrom.length else { continue }
                        let delta = chrom.length - maxPos64
                        let tolerance = chrom.length > 1_000_000
                            ? chrom.length / 20
                            : chrom.length / 5
                        guard delta < tolerance else { continue }
                        if delta < bestDelta {
                            bestDelta = delta
                            bestMatch = vcfChrom
                        }
                    }
                }

                if let match = bestMatch {
                    aliasMap[chrom.name] = match
                    usedVCFChroms.insert(match)
                }
            }
        }

        // Warn if we still have unmatched chromosomes
        let finalUnmatched = unmatched.subtracting(usedVCFChroms)
        if aliasMap.isEmpty && !finalUnmatched.isEmpty {
            let vcfSample = Array(finalUnmatched.prefix(3)).joined(separator: ", ")
            let refSample = Array(bundleChromosomes.prefix(3).map(\.name)).joined(separator: ", ")
            sequenceViewerLogger.warning("buildVariantChromosomeAliasMap: Could not match VCF chromosomes [\(vcfSample)] to reference chromosomes [\(refSample)] — variant queries may return empty results")
        }

        if !aliasMap.isEmpty {
            let nameMatchCount = nameMap.count
            let lengthMatchCount = aliasMap.count - nameMatchCount
            let mode = includeMaxPositionFallback ? "full" : "fast"
            sequenceViewerLogger.info("buildVariantChromosomeAliasMap[\(mode, privacy: .public)]: Built \(aliasMap.count) chromosome aliases (\(nameMatchCount) name-based, \(lengthMatchCount) length-based) (e.g., \(aliasMap.first?.key ?? "") → \(aliasMap.first?.value ?? ""))")
        }

        return aliasMap
    }

    nonisolated static let variantAliasWarmupQueue = DispatchQueue(
        label: "com.lungfish.variantAliasWarmup",
        qos: .utility
    )

    /// Computes expensive variant chromosome aliases off the main thread and merges them with fast aliases.
    nonisolated static func warmVariantChromosomeAliasesAsync(
        bundle: ReferenceBundle,
        initialAliasMap: [String: String],
        onComplete: @escaping @MainActor @Sendable ([String: String]) -> Void
    ) {
        guard !bundle.variantTrackIds.isEmpty else { return }
        let bundleChromosomes = bundle.manifest.genome?.chromosomes ?? []
        let initial = initialAliasMap

        variantAliasWarmupQueue.async {
            var merged = initial
            for trackId in bundle.variantTrackIds {
                guard let trackInfo = bundle.variantTrack(id: trackId),
                      let dbPath = trackInfo.databasePath else { continue }
                guard let dbURL = try? bundle.memberURL(
                    for: dbPath,
                    field: "variants[\(trackId)].databasePath"
                ) else { continue }
                guard let db = try? VariantDatabase(url: dbURL) else { continue }

                let aliasMap = Self.buildVariantChromosomeAliasMap(
                    bundleChromosomes: bundleChromosomes,
                    variantDB: db,
                    sequenceViewerLogger: sequenceViewerLogger,
                    includeMaxPositionFallback: true
                )
                for (refChrom, dbChrom) in aliasMap where merged[refChrom] == nil {
                    merged[refChrom] = dbChrom
                }
            }

            guard merged != initial else { return }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    onComplete(merged)
                }
            }
        }
    }

    /// Translates a reference chromosome name to the variant DB chromosome name.
    /// Returns the original name if no alias is needed.
    func variantDBChromosomeName(for refChrom: String) -> String {
        variantChromosomeAliasMap[refChrom] ?? refChrom
    }

    /// Public wrapper for components that need the active variant DB chromosome alias.
    func variantDatabaseChromosomeName(for refChrom: String) -> String {
        variantDBChromosomeName(for: refChrom)
    }

    /// Translates a variant DB chromosome name back to the reference chromosome name.
    /// Returns the original chromosome when no reverse mapping is available.
    func referenceChromosomeName(forVariantDBChromosome variantChrom: String) -> String {
        if let direct = viewController?.currentBundleDataProvider?.chromosomeInfo(named: variantChrom)?.name {
            return direct
        }
        if let mapped = variantChromosomeAliasMap.first(where: { $0.value == variantChrom })?.key {
            return mapped
        }
        return variantChrom
    }

}
