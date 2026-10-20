// ReadTrackRenderer+Packed.swift - Read packing and packed rows of the read track renderer
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import LungfishCore
import LungfishKit

extension ReadTrackRenderer {

    // MARK: - Packed Read Rendering (Tier 2)

    /// Packs reads into non-overlapping rows using greedy first-fit algorithm.
    ///
    /// - Parameters:
    ///   - reads: Reads to pack
    ///   - frame: Reference frame for coordinate mapping
    ///   - maxRows: Maximum number of rows
    ///   - sortMode: How to sort reads before packing
    ///   - sortPosition: Reference position for baseAtPosition sort mode
    /// - Returns: Array of (row, read) pairs and the overflow count
    public static func packReads(
        _ reads: [AlignedRead],
        frame: ReferenceFrame,
        maxRows: Int? = 75,
        sortMode: ReadSortMode = .position,
        sortPosition: Int? = nil,
        prioritizedRegion: Range<Int>? = nil
    ) -> (packed: [(row: Int, read: AlignedRead)], overflow: Int) {
        packReads(
            reads,
            frame: ReadPackFrame(frame),
            maxRows: maxRows,
            sortMode: sortMode,
            sortPosition: sortPosition,
            prioritizedRegion: prioritizedRegion,
            shouldCancel: nil
        )
    }

    /// Cancellable variant of `packReads`.
    ///
    /// `shouldCancel` is consulted periodically inside the assignment loop so a
    /// pack running on a background task for an extreme-depth window can be
    /// abandoned when the user zooms, sorts, or changes the row limit. It
    /// returns `nil` when the pack was cancelled; the non-throwing overload
    /// above never cancels and never returns nil.
    public nonisolated static func packReads(
        _ reads: [AlignedRead],
        frame: ReadPackFrame,
        maxRows: Int?,
        sortMode: ReadSortMode,
        sortPosition: Int?,
        prioritizedRegion: Range<Int>?,
        shouldCancel: (() -> Bool)?
    ) -> (packed: [(row: Int, read: AlignedRead)], overflow: Int) {
        let ordered = orderReadsForPacking(
            reads,
            sortMode: sortMode,
            sortPosition: sortPosition,
            prioritizedRegion: prioritizedRegion
        )
        return assignRows(
            ordered: ordered,
            frame: frame,
            maxRows: maxRows,
            shouldCancel: shouldCancel
        )
    }

    /// The sort + prioritization half of packing, split out so tests can feed
    /// the exact same ordering to the linear-scan oracle.
    nonisolated static func orderReadsForPacking(
        _ reads: [AlignedRead],
        sortMode: ReadSortMode,
        sortPosition: Int?,
        prioritizedRegion: Range<Int>?
    ) -> [AlignedRead] {
        let sorted: [AlignedRead]
        switch sortMode {
        case .position:
            sorted = reads.sorted { $0.position < $1.position }
        case .readName:
            sorted = reads.sorted { $0.name < $1.name }
        case .strand:
            sorted = reads.sorted { !$0.isReverse && $1.isReverse }
        case .mappingQuality:
            sorted = reads.sorted { $0.mapq > $1.mapq }
        case .insertSize:
            sorted = reads.sorted { abs($0.insertSize) < abs($1.insertSize) }
        case .baseAtPosition:
            if let pos = sortPosition {
                // Sort by allele rarity at the focal position so minority/variant
                // reads are surfaced in the first visible rows when deeply stacked.
                var baseCounts: [UInt8: Int] = [:]
                baseCounts.reserveCapacity(8)
                for read in reads {
                    let base = baseAtRefPos(read, pos: pos)
                    guard base != 255 else { continue }
                    baseCounts[base, default: 0] += 1
                }

                sorted = reads.sorted {
                    let lhsBase = baseAtRefPos($0, pos: pos)
                    let rhsBase = baseAtRefPos($1, pos: pos)

                    if lhsBase == rhsBase {
                        if $0.position != $1.position {
                            return $0.position < $1.position
                        }
                        return $0.name < $1.name
                    }

                    let lhsMissing = (lhsBase == 255)
                    let rhsMissing = (rhsBase == 255)
                    if lhsMissing != rhsMissing {
                        return !lhsMissing // reads covering the focal base first
                    }

                    let lhsCount = baseCounts[lhsBase] ?? Int.max
                    let rhsCount = baseCounts[rhsBase] ?? Int.max
                    if lhsCount != rhsCount {
                        return lhsCount < rhsCount // rarer alleles first
                    }

                    return lhsBase < rhsBase
                }
            } else {
                sorted = reads.sorted { $0.position < $1.position }
            }
        }
        guard let prioritizedRegion else { return sorted }
        var visible: [AlignedRead] = []
        var nearby: [AlignedRead] = []
        visible.reserveCapacity(sorted.count / 2)
        nearby.reserveCapacity(sorted.count / 2)
        for read in sorted {
            if read.alignmentEnd > prioritizedRegion.lowerBound && read.position < prioritizedRegion.upperBound {
                visible.append(read)
            } else {
                nearby.append(read)
            }
        }
        return visible + nearby
    }

    /// First-fit row assignment over an already-ordered read list.
    ///
    /// Row choice is delegated to `ReadRowAllocator`, whose segment tree answers
    /// "lowest-index row whose end pixel is at most `startPx - gap`" in
    /// `O(log rows)`. The placement rule is byte-for-byte the one the previous
    /// linear scan implemented; only the search cost changed, from
    /// `O(reads x rows)` to `O(reads log rows)`.
    nonisolated static func assignRows(
        ordered: [AlignedRead],
        frame: ReadPackFrame,
        maxRows: Int?,
        shouldCancel: (() -> Bool)? = nil
    ) -> (packed: [(row: Int, read: AlignedRead)], overflow: Int) {
        let rowCap = maxRows.flatMap { $0 > 0 ? $0 : nil }
        var allocator = ReadRowAllocator(
            rowCap: rowCap,
            expectedRows: max(16, min(4_096, ordered.count / 8 + 1))
        )
        var packed: [(Int, AlignedRead)] = []
        packed.reserveCapacity(ordered.count)
        var overflow = 0

        for (index, read) in ordered.enumerated() {
            // Cancellation is checked in coarse batches so the closure call does
            // not itself become the hot path at 600k reads.
            if let shouldCancel, index & 0x3FFF == 0, shouldCancel() {
                return ([], 0)
            }
            let startPx = frame.genomicToPixel(Double(read.position))
            let endPx = frame.genomicToPixel(Double(read.alignmentEnd))
            guard endPx - startPx >= minReadPixels else { continue }

            switch allocator.place(startPx: startPx, endPx: endPx, gap: 2) {
            case .placed(let row):
                packed.append((row, read))
            case .overflow:
                overflow += 1
            }
        }

        return (packed, overflow)
    }

    // MARK: - Visible-read iteration

    /// Iterates only the reads that can actually paint into `clipRect`,
    /// invoking `body(read, y)` with the read's row-derived Y origin.
    ///
    /// Two paths, identical in output:
    ///
    /// * **Fast path** (`layout` supplied): the row range intersecting the clip
    ///   is computed arithmetically, then within each row a binary search finds
    ///   the first read that can reach `frame.start` and iteration stops at the
    ///   first read starting past `frame.end`. Rows scrolled above the viewport
    ///   and reads off either horizontal edge are never touched.
    /// * **Fallback** (`layout == nil`): the original linear walk over
    ///   `packedReads`, preserved so existing callers and tests that pass only
    ///   the flat array keep working unchanged.
    ///
    /// The legacy `y + readHeight <= rect.maxY` guard is preserved in both
    /// paths, so the set of drawn reads is identical to the pre-culling code.
    static func forEachVisiblePackedRead(
        packedReads: [(row: Int, read: AlignedRead)],
        layout: PackedReadLayout?,
        frame: ReferenceFrame,
        rect: CGRect,
        clipRect: CGRect?,
        readHeight: CGFloat,
        rowGap: CGFloat,
        _ body: (_ read: AlignedRead, _ y: CGFloat) -> Void
    ) {
        let pitch = readHeight + rowGap

        guard let layout, layout.rowCount > 0 else {
            // Fallback: preserve the original iteration order and guards.
            for (row, read) in packedReads {
                let y = rect.minY + CGFloat(row) * pitch
                guard y + readHeight <= rect.maxY else { continue }
                if let clipRect, y > clipRect.maxY || y + readHeight < clipRect.minY { continue }
                body(read, y)
            }
            return
        }

        // Without an explicit clip, the content rect itself bounds the work.
        let clip = clipRect ?? rect
        let rowRange = ReadTrackCulling.visibleRowRange(
            rect: rect,
            clip: clip,
            rowCount: layout.rowCount,
            rowHeight: readHeight,
            rowGap: rowGap
        )
        guard !rowRange.isEmpty else { return }

        // Horizontal window in genomic coordinates, widened by one base so a
        // read touching the very edge of the viewport is never dropped.
        let genomicStart = Int(frame.start.rounded(.down)) - 1
        let genomicEnd = Int(frame.end.rounded(.up)) + 1

        for row in rowRange {
            let reads = layout.rows[row]
            guard !reads.isEmpty else { continue }
            let y = rect.minY + CGFloat(row) * pitch
            guard y + readHeight <= rect.maxY else { continue }

            let indexRange = ReadTrackCulling.visibleReadRange(
                in: reads,
                genomicStart: genomicStart,
                genomicEnd: genomicEnd,
                maxReadSpan: layout.maxReadSpan
            )
            for index in indexRange {
                let read = reads[index]
                // The binary search back-off admits reads that start before the
                // window; drop the ones that end before it too.
                guard read.alignmentEnd > genomicStart else { continue }
                body(read, y)
            }
        }
    }

    /// Draws packed reads as colored bars with strand indicators, mismatch highlights, and soft clips.
    ///
    /// - Parameters:
    ///   - packedReads: Pre-packed reads with row assignments
    ///   - overflow: Number of reads that didn't fit
    ///   - frame: Reference frame for coordinate mapping
    ///   - referenceSequence: Optional reference sequence for mismatch detection
    ///   - referenceStart: 0-based start position of the reference sequence
    ///   - settings: Display settings controlling mismatch/softclip/indel visibility
    ///   - context: CoreGraphics context
    ///   - rect: Drawing rectangle
    public static func drawPackedReads(
        packedReads: [(row: Int, read: AlignedRead)],
        overflow: Int,
        frame: ReferenceFrame,
        referenceSequence: String? = nil,
        referenceStart: Int = 0,
        settings: DisplaySettings = DisplaySettings(),
        verticalCompress: Bool = false,
        maxRowsLimit: Int? = nil,
        maskedPositions: Set<Int> = [],
        layout: PackedReadLayout? = nil,
        clipRect: CGRect? = nil,
        mismatchCache: ReadMismatchCache? = nil,
        context: CGContext,
        rect: CGRect
    ) {
        context.saveGState()
        let metrics = layoutMetrics(verticalCompress: verticalCompress)
        let readHeight = metrics.packedReadHeight

        // Pre-compute reference as uppercased ASCII bytes (500KB vs 8MB for [Character])
        // Always compute reference bytes — mismatch ticks are always shown when reference is available
        let refBytes: [UInt8]? = referenceSequence.map(uppercaseASCIIBytes)

        // Pre-compute CGColor cache for (strand, mapqBin) combinations to avoid per-read allocs.
        // mapqAlpha returns 5 distinct values × 2 strands × 2 (fill/stroke) = 20 cached colors.
        // Only used for the `.strand` color mode and the neutral (colors off) case, both of
        // which are fully determined by (isReverse, mapq); every other color mode
        // (insert size, MAPQ heatmap, read group, pair, base quality) varies per read beyond
        // that, so it goes through `ReadTrackRenderer.readColors(for:colorMode:)` uncached below.
        let useStrandColors = settings.showStrandColors
        let colorMode = settings.colorMode
        // Fixed light-gray RGB values (0.78/0.62) read as washed-out, low-contrast glyphs
        // in Dark Aqua. systemGray/tertiaryLabelColor are dynamic colors that resolve per
        // appearance. Both feed `.copy(alpha:)` below (mapqAlpha overrides alpha entirely), so
        // only hue/lightness matter here, not the alpha passed to withAlphaComponent.
        let neutralFillPacked = NSColor.systemGray.cgColor
        let neutralStrokePacked = NSColor.tertiaryLabelColor.cgColor
        var colorCache: [UInt16: (fill: CGColor, stroke: CGColor)] = [:]
        func cachedColors(isReverse: Bool, mapq: UInt8) -> (fill: CGColor, stroke: CGColor) {
            let key = UInt16(isReverse ? 1 : 0) << 8 | UInt16(mapq)
            if let cached = colorCache[key] { return cached }
            let alpha = mapqAlpha(mapq)
            let fill: CGColor
            let stroke: CGColor
            if useStrandColors {
                fill = (isReverse ? reverseReadColor : forwardReadColor).copy(alpha: alpha)!
                stroke = (isReverse ? reverseReadStroke : forwardReadStroke).copy(alpha: alpha)!
            } else {
                fill = neutralFillPacked.copy(alpha: alpha)!
                stroke = neutralStrokePacked.copy(alpha: alpha)!
            }
            colorCache[key] = (fill, stroke)
            return (fill, stroke)
        }
        func colorsForRead(_ read: AlignedRead) -> (fill: CGColor, stroke: CGColor) {
            guard useStrandColors, colorMode != .strand else {
                return cachedColors(isReverse: read.isReverse, mapq: read.mapq)
            }
            let alpha = mapqAlpha(read.mapq)
            return readColors(for: read, colorMode: colorMode, alpha: alpha)
        }

        forEachVisiblePackedRead(
            packedReads: packedReads,
            layout: layout,
            frame: frame,
            rect: rect,
            clipRect: clipRect,
            readHeight: readHeight,
            rowGap: metrics.rowGap
        ) { read, y in
            let startPx = frame.genomicToPixel(Double(read.position))
            let endPx = frame.genomicToPixel(Double(read.alignmentEnd))
            let readWidth = endPx - startPx

            guard readWidth >= minReadPixels else { return }

            let alpha = mapqAlpha(read.mapq)
            let colors = colorsForRead(read)

            // Draw soft-clip extensions (semi-transparent bars extending from read ends)
            if settings.showSoftClips {
                drawSoftClipExtensions(read: read, frame: frame, context: context, y: y, readHeight: readHeight, alpha: alpha)
            }

            // Draw read rectangle with pointed end for strand
            let readRect = CGRect(x: startPx, y: y, width: readWidth, height: readHeight)

            if readWidth > 6 {
                let path = CGMutablePath()
                let arrowInset: CGFloat = min(3, readWidth * 0.15)

                if read.isReverse {
                    path.move(to: CGPoint(x: readRect.minX + arrowInset, y: readRect.minY))
                    path.addLine(to: CGPoint(x: readRect.maxX, y: readRect.minY))
                    path.addLine(to: CGPoint(x: readRect.maxX, y: readRect.maxY))
                    path.addLine(to: CGPoint(x: readRect.minX + arrowInset, y: readRect.maxY))
                    path.addLine(to: CGPoint(x: readRect.minX, y: readRect.midY))
                } else {
                    path.move(to: CGPoint(x: readRect.minX, y: readRect.minY))
                    path.addLine(to: CGPoint(x: readRect.maxX - arrowInset, y: readRect.minY))
                    path.addLine(to: CGPoint(x: readRect.maxX, y: readRect.midY))
                    path.addLine(to: CGPoint(x: readRect.maxX - arrowInset, y: readRect.maxY))
                    path.addLine(to: CGPoint(x: readRect.minX, y: readRect.maxY))
                }
                path.closeSubpath()

                // Combined fill+stroke in single pass (halves Quartz state changes)
                context.setFillColor(colors.fill)
                context.setStrokeColor(colors.stroke)
                context.setLineWidth(0.5)
                context.addPath(path)
                context.drawPath(using: .fillStroke)
            } else {
                context.setFillColor(colors.fill)
                context.fill(readRect)
            }

            // Draw mismatch tick marks. With a reference the comparison is a
            // zero-allocation ASCII byte walk; without one (classifier evidence
            // BAMs are loaded with no reference) the aligner's MD tag and CIGAR
            // `X` operations still locate every mismatch, so differences stay
            // visible at every zoom level that draws individual reads.
            // MD parsing is the expensive part; when a reference is loaded the
            // comparison is a cheap byte walk and no cache is consulted.
            let mdMismatchPositions: Set<Int>? = refBytes == nil
                ? (mismatchCache.map { $0.positions(for: read) }
                    ?? read.mdTag.map { mismatchPositionsFromMDTag($0, readStart: read.position) })
                : nil
            if refBytes != nil || mdMismatchPositions != nil || read.cigar.contains(where: { $0.op == .seqMismatch }) {
                drawMismatchTicks(
                    read: read, frame: frame, refBytes: refBytes, referenceStart: referenceStart,
                    mdMismatchPositions: mdMismatchPositions,
                    maskedPositions: maskedPositions,
                    context: context, y: y, readHeight: readHeight
                )
            }

            // Draw deletion lines
            if settings.showIndels {
                drawDeletions(read: read, frame: frame, context: context, y: y + readHeight / 2, readHeight: readHeight)
                drawInsertionTicks(read: read, frame: frame, context: context, y: y, readHeight: readHeight)
            }
        }

        if !maskedPositions.isEmpty {
            drawMaskedColumns(maskedPositions, frame: frame, context: context, rect: rect)
        }

        // Draw overflow indicator
        if overflow > 0 {
            drawOverflowIndicator(context: context, rect: rect, overflow: overflow, maxRowsLimit: maxRowsLimit)
        }

        context.restoreGState()
    }
}
