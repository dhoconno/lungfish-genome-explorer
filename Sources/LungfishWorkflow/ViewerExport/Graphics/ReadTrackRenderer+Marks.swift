// ReadTrackRenderer+Marks.swift - Mismatch, indel, mask and overflow marks of the read track renderer
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import CoreGraphics
import CoreText
import Foundation
import LungfishCore

extension ReadTrackRenderer {

    /// Draws colored tick marks at mismatch positions on a packed read bar.
    ///
    /// Uses ASCII byte comparison (zero allocations) instead of Character/String conversion.
    /// At wider zoom levels, mismatches within the same pixel column are coalesced.
    static func drawMismatchTicks(
        read: AlignedRead,
        frame: ViewerFigureFrame,
        refBytes: [UInt8]?,
        referenceStart: Int,
        mdMismatchPositions: Set<Int>?,
        maskedPositions: Set<Int>,
        context: CGContext,
        figureTheme: ViewerFigureTheme,
        y: CGFloat,
        readHeight: CGFloat
    ) {
        let pixelsPerBase = 1.0 / frame.scale
        // Geneious-style cue in packed mode: mismatch ticks use nucleotide colors.
        let tickAlpha: CGFloat = 0.92
        let colorA = figureTheme.color(.readBaseA).withAlpha(tickAlpha).cgColor
        let colorT = figureTheme.color(.readBaseT).withAlpha(tickAlpha).cgColor
        let colorC = figureTheme.color(.readBaseC).withAlpha(tickAlpha).cgColor
        let colorG = figureTheme.color(.readBaseG).withAlpha(tickAlpha).cgColor
        let colorN = figureTheme.color(.readBaseN).withAlpha(tickAlpha).cgColor

        var lastMismatchPixel: Int = Int.min
        forEachPackedMismatch(
            read: read,
            refBytes: refBytes,
            referenceStart: referenceStart,
            mdMismatchPositions: mdMismatchPositions,
            maskedPositions: maskedPositions
        ) { refPos, upperRead in
            let x = frame.screenPosition(for: Double(refPos))
            let px = Int(x)
            if px != lastMismatchPixel {
                lastMismatchPixel = px
                let tickWidth = max(1.0, min(CGFloat(pixelsPerBase), 3.2))
                let tickColor = colorForByte(upperRead, a: colorA, t: colorT, c: colorC, g: colorG, n: colorN)
                context.setFillColor(tickColor)
                context.fill(CGRect(x: x, y: y, width: tickWidth, height: readHeight))
            }
        }
    }

    /// Walks a read's aligned bases and reports each mismatch as
    /// `(referencePosition, uppercasedReadBase)`.
    ///
    /// Mismatch evidence, in priority order: an explicit CIGAR `X` operation;
    /// a byte comparison against `refBytes` when a reference is loaded; or the
    /// aligner's MD tag positions when no reference is available. `N` bases are
    /// never reported and masked reference positions are skipped.
    static func forEachPackedMismatch(
        read: AlignedRead,
        refBytes: [UInt8]?,
        referenceStart: Int,
        mdMismatchPositions: Set<Int>?,
        maskedPositions: Set<Int>,
        _ body: (_ refPos: Int, _ upperRead: UInt8) -> Void
    ) {
        var seqIterator = read.sequence.utf8.makeIterator()
        var refPos = read.position

        for op in read.cigar {
            switch op.op {
            case .match, .seqMatch, .seqMismatch:
                let explicitMatch = (op.op == .seqMatch)
                let explicitMismatch = (op.op == .seqMismatch)
                for _ in 0..<op.length {
                    guard let readByte = seqIterator.next() else { refPos += 1; continue }
                    if maskedPositions.contains(refPos) || explicitMatch {
                        refPos += 1
                        continue
                    }

                    let upperRead = readByte & 0xDF

                    let isMismatch: Bool
                    if explicitMismatch {
                        isMismatch = true
                    } else if let refBytes {
                        let refIdx = refPos - referenceStart
                        if refIdx >= 0, refIdx < refBytes.count {
                            let upperRef = refBytes[refIdx]
                            if upperRead == 0x4E || upperRef == 0x4E { refPos += 1; continue }
                            isMismatch = !isEquivalentBase(upperRead, upperRef)
                        } else {
                            refPos += 1
                            continue
                        }
                    } else if let mdMismatchPositions {
                        isMismatch = mdMismatchPositions.contains(refPos)
                    } else {
                        refPos += 1
                        continue
                    }

                    if isMismatch, upperRead != 0x4E {
                        body(refPos, upperRead)
                    }

                    refPos += 1
                }

            case .insertion:
                for _ in 0..<op.length {
                    _ = seqIterator.next()
                }

            case .softClip:
                for _ in 0..<op.length {
                    _ = seqIterator.next()
                }

            case .deletion, .skip:
                refPos += op.length

            case .hardClip, .padding:
                break
            }
        }
    }

    /// Uppercases an ASCII nucleotide string in-place as bytes (faster than String.uppercased()).
    static func uppercaseASCIIBytes(_ s: String) -> [UInt8] {
        var bytes = Array(s.utf8)
        for i in bytes.indices {
            if bytes[i] >= 0x61, bytes[i] <= 0x7A { // a-z
                bytes[i] &= 0xDF
            }
        }
        return bytes
    }

    /// Base-equivalence comparison that treats DNA/RNA thymine-uracil as a match.
    static func isEquivalentBase(_ a: UInt8, _ b: UInt8) -> Bool {
        if a == b { return true }
        // Treat T and U as equivalent for RNA-vs-DNA views.
        return (a == 0x54 && b == 0x55) || (a == 0x55 && b == 0x54)
    }

    /// Extracts absolute mismatch positions from an MD tag.
    ///
    /// MD syntax:
    /// - digits: run of matches
    /// - letters: mismatched reference bases
    /// - `^` + letters: deletion in read relative to reference
    ///
    /// Returned positions are 0-based genomic coordinates.
    static func mismatchPositionsFromMDTag(_ mdTag: String, readStart: Int) -> Set<Int> {
        mismatchPositionsFromMDTagNonisolated(mdTag, readStart: readStart)
    }

    /// Actor-free body of `mismatchPositionsFromMDTag`, so `ReadMismatchCache`
    /// can precompute mismatch positions on the read-fetch background thread.
    nonisolated static func mismatchPositionsFromMDTagNonisolated(_ mdTag: String, readStart: Int) -> Set<Int> {
        guard !mdTag.isEmpty else { return [] }

        var positions = Set<Int>()
        positions.reserveCapacity(8)

        let bytes = Array(mdTag.utf8)
        var i = 0
        var refPos = readStart

        while i < bytes.count {
            let byte = bytes[i]

            // Match run count
            if byte >= 48 && byte <= 57 {
                var value = 0
                while i < bytes.count {
                    let digit = bytes[i]
                    guard digit >= 48 && digit <= 57 else { break }
                    value = value * 10 + Int(digit - 48)
                    i += 1
                }
                refPos += value
                continue
            }

            // Deletion from read (`^ACG`) consumes reference positions.
            if byte == 94 { // ^
                i += 1
                while i < bytes.count {
                    let upper = bytes[i] & 0xDF
                    guard upper >= 65 && upper <= 90 else { break }
                    refPos += 1
                    i += 1
                }
                continue
            }

            // Mismatched reference base letter.
            let upper = byte & 0xDF
            if upper >= 65 && upper <= 90 {
                positions.insert(refPos)
                refPos += 1
                i += 1
                continue
            }

            i += 1
        }

        return positions
    }

    /// Computes visible positions where gaps dominate among spanning reads.
    ///
    /// A position is masked when:
    /// - at least `minDepth` reads span the position, and
    /// - `(spanningReads - alignedBases) / spanningReads >= gapThreshold`.
    public static func computeHighGapMaskedPositions(
        packedReads: [(row: Int, read: AlignedRead)],
        visibleRegion: Range<Int>,
        minDepth: Int,
        gapThreshold: Double
    ) -> Set<Int> {
        guard !packedReads.isEmpty,
              visibleRegion.lowerBound < visibleRegion.upperBound else { return [] }

        let threshold = max(0.0, min(1.0, gapThreshold))
        let depthFloor = max(1, minDepth)
        let regionStart = visibleRegion.lowerBound
        let regionEnd = visibleRegion.upperBound
        let length = regionEnd - regionStart
        if length > 200_000 { return [] } // Safety bound for pathological draw windows.

        var spanningDiff = [Int](repeating: 0, count: length + 1)
        var alignedCounts = [Int](repeating: 0, count: length)

        for (_, read) in packedReads {
            let spanStart = max(regionStart, read.position)
            let spanEnd = min(regionEnd, read.alignmentEnd)
            if spanStart < spanEnd {
                spanningDiff[spanStart - regionStart] += 1
                spanningDiff[spanEnd - regionStart] -= 1
            }

            var refPos = read.position
            for op in read.cigar {
                switch op.op {
                case .match, .seqMatch, .seqMismatch:
                    for _ in 0..<op.length {
                        if refPos >= regionStart && refPos < regionEnd {
                            alignedCounts[refPos - regionStart] += 1
                        }
                        refPos += 1
                    }
                case .deletion, .skip:
                    refPos += op.length
                case .insertion, .softClip, .hardClip, .padding:
                    break
                }
            }
        }

        var masked = Set<Int>()
        masked.reserveCapacity(length / 4)
        var spanning = 0
        for idx in 0..<length {
            spanning += spanningDiff[idx]
            guard spanning >= depthFloor else { continue }
            let aligned = alignedCounts[idx]
            let gaps = max(0, spanning - aligned)
            let gapFraction = Double(gaps) / Double(spanning)
            if gapFraction >= threshold {
                masked.insert(regionStart + idx)
            }
        }
        return masked
    }

    /// Draws semi-opaque column overlays for masked (high-gap) positions.
    static func drawMaskedColumns(
        _ maskedPositions: Set<Int>,
        frame: ViewerFigureFrame,
        context: CGContext,
        figureTheme: ViewerFigureTheme,
        rect: CGRect
    ) {
        guard !maskedPositions.isEmpty else { return }

        let sorted = maskedPositions.sorted()
        var runStart = sorted[0]
        var runEnd = sorted[0]

        context.saveGState()
        context.setFillColor(figureTheme.color(.controlBackground).withAlpha(0.9).cgColor)

        func fillRun(_ start: Int, _ end: Int) {
            let x0 = frame.screenPosition(for: Double(start))
            let x1 = frame.screenPosition(for: Double(end + 1))
            guard x1 > x0 else { return }
            context.fill(CGRect(x: x0, y: rect.minY, width: x1 - x0, height: rect.height))
        }

        for pos in sorted.dropFirst() {
            if pos == runEnd + 1 {
                runEnd = pos
            } else {
                fillRun(runStart, runEnd)
                runStart = pos
                runEnd = pos
            }
        }
        fillRun(runStart, runEnd)
        context.restoreGState()
    }

    /// Draws semi-transparent extensions at soft-clipped ends of a read in packed mode.
    ///
    /// Soft clips are bases present in the read but not part of the alignment.
    /// They appear as translucent extensions beyond the aligned portion,
    /// indicating where the read sequence continues past the alignment boundary.
    static func drawSoftClipExtensions(
        read: AlignedRead,
        frame: ViewerFigureFrame,
        context: CGContext,
        figureTheme: ViewerFigureTheme,
        y: CGFloat,
        readHeight: CGFloat,
        alpha: CGFloat
    ) {
        guard !read.cigar.isEmpty else { return }

        // Check for leading soft clip
        if let first = read.cigar.first, first.op == .softClip {
            let clipBases = first.length
            let alignStartPx = frame.screenPosition(for: Double(read.position))
            let clipStartPx = frame.screenPosition(for: Double(read.position - clipBases))
            let width = alignStartPx - clipStartPx
            if width >= 1 {
                context.setFillColor(figureTheme.color(.softClip).withAlpha(alpha * 0.5).cgColor)
                context.fill(CGRect(x: clipStartPx, y: y, width: width, height: readHeight))
            }
        }

        // Check for trailing soft clip
        if let last = read.cigar.last, last.op == .softClip {
            let clipBases = last.length
            let alignEndPx = frame.screenPosition(for: Double(read.alignmentEnd))
            let clipEndPx = frame.screenPosition(for: Double(read.alignmentEnd + clipBases))
            let width = clipEndPx - alignEndPx
            if width >= 1 {
                context.setFillColor(figureTheme.color(.softClip).withAlpha(alpha * 0.5).cgColor)
                context.fill(CGRect(x: alignEndPx, y: y, width: width, height: readHeight))
            }
        }
    }

    /// Draws deletion and intron (N/skip) connecting lines for a read.
    ///
    /// Deletions are shown as dashed dark gray lines; introns are shown as
    /// thin solid lighter lines (matching IGV convention for RNA-seq data).
    static func drawDeletions(
        read: AlignedRead,
        frame: ViewerFigureFrame,
        context: CGContext,
        figureTheme: ViewerFigureTheme,
        y: CGFloat,
        readHeight: CGFloat
    ) {
        var refPos = read.position
        for op in read.cigar {
            if op.op == .deletion {
                let startPx = frame.screenPosition(for: Double(refPos))
                let endPx = frame.screenPosition(for: Double(refPos + op.length))
                context.setStrokeColor(figureTheme.color(.deletion).cgColor)
                context.setLineWidth(1)
                context.setLineDash(phase: 0, lengths: [2, 2])
                context.move(to: CGPoint(x: startPx, y: y))
                context.addLine(to: CGPoint(x: endPx, y: y))
                context.strokePath()
                context.setLineDash(phase: 0, lengths: [])
            } else if op.op == .skip {
                // N operations (introns) — thin solid line, distinct from deletions
                let startPx = frame.screenPosition(for: Double(refPos))
                let endPx = frame.screenPosition(for: Double(refPos + op.length))
                context.setStrokeColor(figureTheme.color(.intron).cgColor)
                context.setLineWidth(0.5)
                context.move(to: CGPoint(x: startPx, y: y))
                context.addLine(to: CGPoint(x: endPx, y: y))
                context.strokePath()
            }
            if op.consumesReference {
                refPos += op.length
            }
        }
    }

    /// Draws small insertion ticks (for packed mode).
    static func drawInsertionTicks(
        read: AlignedRead,
        frame: ViewerFigureFrame,
        context: CGContext,
        figureTheme: ViewerFigureTheme,
        y: CGFloat,
        readHeight: CGFloat
    ) {
        for ins in read.insertions {
            let x = frame.screenPosition(for: Double(ins.position))
            context.setFillColor(figureTheme.color(.insertion).cgColor)
            context.fill(CGRect(x: x - 0.5, y: y - 1, width: 1, height: readHeight + 2))
        }
    }

    /// Draws insertion markers with triangle indicators (for base mode).
    ///
    /// `labelFont` is the label face from `insertionLabelFont()`. The caller builds it once per draw and not
    /// once per label, since the lookup makes a system font, a descriptor font and a name check each time.
    static func drawInsertionMarkers(
        read: AlignedRead,
        frame: ViewerFigureFrame,
        context: CGContext,
        figureTheme: ViewerFigureTheme,
        labelFont: CTFont,
        y: CGFloat,
        readHeight: CGFloat
    ) {
        let pixelsPerBase = 1.0 / frame.scale
        let labelColor = figureTheme.color(.insertion).cgColor
        for ins in read.insertions {
            let x = frame.screenPosition(for: Double(ins.position))
            // Vertical line
            context.setFillColor(figureTheme.color(.insertion).cgColor)
            context.fill(CGRect(x: x - 0.8, y: y, width: 1.6, height: readHeight))

            // Small triangle pointing down
            let trianglePath = CGMutablePath()
            trianglePath.move(to: CGPoint(x: x - 2, y: y))
            trianglePath.addLine(to: CGPoint(x: x + 2, y: y))
            trianglePath.addLine(to: CGPoint(x: x, y: y + 4))
            trianglePath.closeSubpath()
            context.addPath(trianglePath)
            context.fillPath()

            if let labelText = insertionLabel(for: ins.bases, pixelsPerBase: pixelsPerBase) {
                ViewerFigureTrackText.draw(
                    labelText, font: labelFont, color: labelColor,
                    topLeft: CGPoint(x: x + 2, y: y + 0.5), in: context
                )
            }
        }
    }

    /// Returns a compact insertion label suitable for the current zoom level.
    static func insertionLabel(for bases: String, pixelsPerBase: Double) -> String? {
        let count = bases.count
        guard count > 0 else { return nil }

        // In base view (>= ~1.7 px/base), show the inserted sequence identity.
        // For long insertions, truncate while preserving total length.
        if pixelsPerBase >= 1.5 {
            let upper = bases.uppercased()
            if count <= 6 {
                return "+\(upper)"
            }
            return "+\(String(upper.prefix(6)))...(\(count))"
        }

        // Packed-like zoom fallback: length-only marker.
        if count > 1 {
            return "I\(count)"
        }
        return nil
    }

    /// Draws the overflow indicator bar at the bottom of the track.
    static func drawOverflowIndicator(
        context: CGContext,
        figureTheme: ViewerFigureTheme,
        rect: CGRect,
        overflow: Int,
        maxRowsLimit: Int?
    ) {
        let barHeight: CGFloat = 16
        let barRect = CGRect(x: rect.minX, y: rect.maxY - barHeight, width: rect.width, height: barHeight)

        // A fixed near-white fill (NSColor(white: 0.88, ...)) put light secondaryLabelColor
        // text on a light bar in Dark Aqua. The quaternarySystemFill and label roles track dark mode.
        context.setFillColor(figureTheme.color(.quaternarySystemFill).cgColor)
        context.fill(barRect)

        // Text
        let text: String
        if let maxRowsLimit {
            text = "+\(overflow) reads not shown (max \(maxRowsLimit) rows)"
        } else {
            text = "+\(overflow) reads not shown"
        }
        let font = ViewerFigureTrackText.font(.system, size: 9)
        let width = CGFloat(ViewerFigureTrackText.width(text, font: font))
        let height = CGFloat(ViewerFigureTrackText.boxHeight(font))
        ViewerFigureTrackText.draw(
            text, font: font, color: figureTheme.color(.label).cgColor,
            topLeft: CGPoint(x: barRect.midX - width / 2, y: barRect.minY + (barHeight - height) / 2), in: context
        )
    }

    // MARK: - Utility

    /// Returns alpha value for a given mapping quality.
    /// MAPQ 255 means "unavailable" per SAM spec — rendered at slightly reduced opacity.
    static func mapqAlpha(_ mapq: UInt8) -> CGFloat {
        switch mapq {
        case 255:      return 0.85  // Unavailable quality — distinct from high-quality
        case 40..<255: return 1.0
        case 20..<40:  return 0.7
        case 10..<20:  return 0.45
        case 1..<10:   return 0.25
        default:       return 0.15
        }
    }

    /// Calculates the total height needed for packed reads.
    ///
    /// - Parameters:
    ///   - rowCount: Number of rows used
    ///   - tier: Current zoom tier
    /// - Returns: Total height in pixels
    public static func totalHeight(rowCount: Int, tier: ZoomTier, verticalCompress: Bool = false) -> CGFloat {
        let metrics = layoutMetrics(verticalCompress: verticalCompress)
        switch tier {
        case .coverage:
            return coverageTrackHeight
        case .packed:
            return CGFloat(rowCount) * (metrics.packedReadHeight + metrics.rowGap)
        case .base:
            return CGFloat(rowCount) * (metrics.baseReadHeight + metrics.rowGap)
        }
    }
}
