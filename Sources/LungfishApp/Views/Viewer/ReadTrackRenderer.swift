// ReadTrackRenderer.swift - Renders aligned reads at three zoom tiers
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import LungfishCore

// MARK: - ReadTrackRenderer

/// Renders aligned sequencing reads at three zoom-dependent tiers.
///
/// ## Zoom Tiers
///
/// | Tier | Scale (bp/px) | Rendering |
/// |------|---------------|-----------|
/// | Coverage | > 10 | Forward/reverse stacked area chart |
/// | Packed | 0.5 - 10 | Colored bars with strand indicators |
/// | Base | < 0.5 | Geneious-style dots for matches, letters for mismatches |
///
/// ## Design Notes
///
/// Follows the `VariantTrackRenderer` pattern: a `@MainActor` enum with static
/// methods for testability and reuse. The renderer does not maintain state;
/// all data is passed as parameters.
@MainActor
public enum ReadTrackRenderer {

    // MARK: - Layout Constants

    /// Height of a single read in packed mode.
    static let packedReadHeight: CGFloat = 6

    /// Height of a single read in base mode.
    static let baseReadHeight: CGFloat = 14

    /// Vertical gap between read rows.
    static let rowGap: CGFloat = 1

    /// Height of the coverage track.
    static let coverageTrackHeight: CGFloat = 60

    /// Maximum number of read rows to render.
    static let maxReadRows: Int = 75

    /// Minimum pixels per read to render individually.
    static let minReadPixels: CGFloat = 2

    /// Zoom tier thresholds.
    static let coverageThresholdBpPerPx: Double = 10
    static let baseThresholdBpPerPx: Double = 0.5

    // MARK: - Colors

    /// Forward read fill color.
    static let forwardReadColor = NSColor(red: 0.69, green: 0.77, blue: 0.87, alpha: 1.0).cgColor
    /// Forward read stroke color.
    static let forwardReadStroke = NSColor(red: 0.55, green: 0.65, blue: 0.77, alpha: 1.0).cgColor
    /// Reverse read fill color.
    static let reverseReadColor = NSColor(red: 0.87, green: 0.69, blue: 0.69, alpha: 1.0).cgColor
    /// Reverse read stroke color.
    static let reverseReadStroke = NSColor(red: 0.77, green: 0.55, blue: 0.55, alpha: 1.0).cgColor

    /// Forward coverage area fill.
    static let forwardCoverageColor = NSColor(red: 0.42, green: 0.60, blue: 0.77, alpha: 0.7).cgColor
    /// Reverse coverage area fill.
    static let reverseCoverageColor = NSColor(red: 0.77, green: 0.42, blue: 0.42, alpha: 0.7).cgColor

    /// Base colors for mismatches (matches BaseColors used in sequence track).
    static let baseA = NSColor(red: 0, green: 0.8, blue: 0, alpha: 1.0).cgColor
    static let baseT = NSColor(red: 0.8, green: 0, blue: 0, alpha: 1.0).cgColor
    static let baseC = NSColor(red: 0, green: 0, blue: 0.8, alpha: 1.0).cgColor
    static let baseG = NSColor(red: 1.0, green: 0.7, blue: 0, alpha: 1.0).cgColor
    static let baseN = NSColor.gray.cgColor
    /// Match dot color.
    static let matchDotColor = NSColor(white: 0.67, alpha: 0.6).cgColor
    /// Insertion indicator color (magenta).
    static let insertionColor = NSColor(red: 0.8, green: 0, blue: 0.8, alpha: 1.0).cgColor
    /// Deletion line color.
    static let deletionColor = NSColor.gray.cgColor
    /// Mismatch indicator color for packed mode (bright red).
    static let mismatchTickColor = NSColor(red: 0.9, green: 0.15, blue: 0.1, alpha: 1.0).cgColor
    /// Soft-clip indicator color for packed mode (blue-gray).
    static let softClipColor = NSColor(red: 0.5, green: 0.6, blue: 0.75, alpha: 0.6).cgColor

    // MARK: - Zoom Tier Detection

    /// Returns the appropriate zoom tier for the current scale.
    public static func zoomTier(scale: Double) -> ZoomTier {
        if scale > coverageThresholdBpPerPx {
            return .coverage
        } else if scale > baseThresholdBpPerPx {
            return .packed
        } else {
            return .base
        }
    }

    /// Zoom tier for read rendering.
    public enum ZoomTier {
        case coverage
        case packed
        case base
    }

    // MARK: - Coverage Rendering (Tier 1)

    /// Draws a forward/reverse stacked coverage area chart.
    ///
    /// - Parameters:
    ///   - reads: All reads in the visible region
    ///   - frame: Current reference frame for coordinate mapping
    ///   - context: CoreGraphics context to draw into
    ///   - rect: Drawing rectangle for the coverage track
    public static func drawCoverage(
        reads: [AlignedRead],
        frame: ReferenceFrame,
        context: CGContext,
        rect: CGRect
    ) {
        let pixelWidth = Int(rect.width)
        guard pixelWidth > 0 else { return }

        // Bin reads by pixel column
        var forwardBins = [Int](repeating: 0, count: pixelWidth)
        var reverseBins = [Int](repeating: 0, count: pixelWidth)

        for read in reads {
            let startPx = max(0, Int(frame.genomicToPixel(Double(read.position)) - rect.minX))
            let endPx = min(pixelWidth - 1, Int(frame.genomicToPixel(Double(read.alignmentEnd)) - rect.minX))
            guard startPx <= endPx else { continue }

            if read.isReverse {
                for i in startPx...endPx { reverseBins[i] += 1 }
            } else {
                for i in startPx...endPx { forwardBins[i] += 1 }
            }
        }

        // Find max coverage with single-pass loop (avoids allocating a temporary array)
        var maxCoverage = 1
        for i in 0..<pixelWidth {
            let total = forwardBins[i] + reverseBins[i]
            if total > maxCoverage { maxCoverage = total }
        }
        let yScale = (rect.height - 16) / CGFloat(maxCoverage) // Leave room for label

        // Draw forward coverage (bottom up)
        context.saveGState()
        context.setFillColor(forwardCoverageColor)
        let forwardPath = CGMutablePath()
        forwardPath.move(to: CGPoint(x: rect.minX, y: rect.maxY))
        for px in 0..<pixelWidth {
            let h = CGFloat(forwardBins[px]) * yScale
            forwardPath.addLine(to: CGPoint(x: rect.minX + CGFloat(px), y: rect.maxY - h))
        }
        forwardPath.addLine(to: CGPoint(x: rect.minX + CGFloat(pixelWidth - 1), y: rect.maxY))
        forwardPath.closeSubpath()
        context.addPath(forwardPath)
        context.fillPath()

        // Draw reverse coverage (stacked on top of forward)
        context.setFillColor(reverseCoverageColor)
        let reversePath = CGMutablePath()
        reversePath.move(to: CGPoint(x: rect.minX, y: rect.maxY))
        for px in 0..<pixelWidth {
            let fwdH = CGFloat(forwardBins[px]) * yScale
            let revH = CGFloat(reverseBins[px]) * yScale
            reversePath.addLine(to: CGPoint(x: rect.minX + CGFloat(px), y: rect.maxY - fwdH - revH))
        }
        // Go back along forward line
        for px in stride(from: pixelWidth - 1, through: 0, by: -1) {
            let fwdH = CGFloat(forwardBins[px]) * yScale
            reversePath.addLine(to: CGPoint(x: rect.minX + CGFloat(px), y: rect.maxY - fwdH))
        }
        reversePath.closeSubpath()
        context.addPath(reversePath)
        context.fillPath()

        // Draw coverage outline
        context.setStrokeColor(NSColor(white: 0.33, alpha: 1).cgColor)
        context.setLineWidth(0.5)
        let outlinePath = CGMutablePath()
        outlinePath.move(to: CGPoint(x: rect.minX, y: rect.maxY))
        for px in 0..<pixelWidth {
            let totalH = CGFloat(forwardBins[px] + reverseBins[px]) * yScale
            outlinePath.addLine(to: CGPoint(x: rect.minX + CGFloat(px), y: rect.maxY - totalH))
        }
        context.addPath(outlinePath)
        context.strokePath()

        // Max coverage label
        if maxCoverage > 0 {
            let label = "max: \(maxCoverage)x" as NSString
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 9, weight: .regular),
                .foregroundColor: NSColor.secondaryLabelColor
            ]
            let size = label.size(withAttributes: attrs)
            label.draw(at: CGPoint(x: rect.maxX - size.width - 4, y: rect.minY + 2), withAttributes: attrs)
        }

        context.restoreGState()
    }

    // MARK: - Display Settings

    /// Rendering options controllable from the Inspector panel.
    public struct DisplaySettings {
        public var showMismatches: Bool = true
        public var showSoftClips: Bool = true
        public var showIndels: Bool = true

        public init(showMismatches: Bool = true, showSoftClips: Bool = true, showIndels: Bool = true) {
            self.showMismatches = showMismatches
            self.showSoftClips = showSoftClips
            self.showIndels = showIndels
        }
    }

    // MARK: - Packed Read Rendering (Tier 2)

    /// Packs reads into non-overlapping rows using greedy first-fit algorithm.
    ///
    /// - Parameters:
    ///   - reads: Reads to pack
    ///   - frame: Reference frame for coordinate mapping
    ///   - maxRows: Maximum number of rows
    /// - Returns: Array of (row, read) pairs and the overflow count
    public static func packReads(
        _ reads: [AlignedRead],
        frame: ReferenceFrame,
        maxRows: Int = 75
    ) -> (packed: [(row: Int, read: AlignedRead)], overflow: Int) {
        // Sort by start position
        let sorted = reads.sorted { $0.position < $1.position }

        var rowEndPixels = [CGFloat](repeating: -1, count: maxRows)
        var packed: [(Int, AlignedRead)] = []
        var overflow = 0

        for read in sorted {
            let startPx = frame.genomicToPixel(Double(read.position))
            let endPx = frame.genomicToPixel(Double(read.alignmentEnd))
            guard endPx - startPx >= minReadPixels else { continue }

            // Find first available row
            var placed = false
            for row in 0..<maxRows {
                if startPx >= rowEndPixels[row] + 2 { // 2px gap
                    packed.append((row, read))
                    rowEndPixels[row] = endPx
                    placed = true
                    break
                }
            }
            if !placed {
                overflow += 1
            }
        }

        return (packed, overflow)
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
        context: CGContext,
        rect: CGRect
    ) {
        context.saveGState()

        // Pre-compute reference as uppercased ASCII bytes (500KB vs 8MB for [Character])
        let refBytes: [UInt8]? = (settings.showMismatches && referenceSequence != nil)
            ? Array(referenceSequence!.uppercased().utf8) : nil

        // Pre-compute CGColor cache for (strand, mapqBin) combinations to avoid per-read allocs.
        // mapqAlpha returns 5 distinct values × 2 strands × 2 (fill/stroke) = 20 cached colors.
        var colorCache: [UInt16: (fill: CGColor, stroke: CGColor)] = [:]
        func cachedColors(isReverse: Bool, mapq: UInt8) -> (fill: CGColor, stroke: CGColor) {
            let key = UInt16(isReverse ? 1 : 0) << 8 | UInt16(mapq)
            if let cached = colorCache[key] { return cached }
            let alpha = mapqAlpha(mapq)
            let fill = (isReverse ? reverseReadColor : forwardReadColor).copy(alpha: alpha)!
            let stroke = (isReverse ? reverseReadStroke : forwardReadStroke).copy(alpha: alpha)!
            colorCache[key] = (fill, stroke)
            return (fill, stroke)
        }

        for (row, read) in packedReads {
            let startPx = frame.genomicToPixel(Double(read.position))
            let endPx = frame.genomicToPixel(Double(read.alignmentEnd))
            let y = rect.minY + CGFloat(row) * (packedReadHeight + rowGap)
            let readWidth = endPx - startPx

            guard y + packedReadHeight <= rect.maxY else { continue }
            guard readWidth >= minReadPixels else { continue }

            let alpha = mapqAlpha(read.mapq)
            let colors = cachedColors(isReverse: read.isReverse, mapq: read.mapq)

            // Draw soft-clip extensions (semi-transparent bars extending from read ends)
            if settings.showSoftClips {
                drawSoftClipExtensions(read: read, frame: frame, context: context, y: y, readHeight: packedReadHeight, alpha: alpha)
            }

            // Draw read rectangle with pointed end for strand
            let readRect = CGRect(x: startPx, y: y, width: readWidth, height: packedReadHeight)

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

            // Draw mismatch tick marks using ASCII byte comparison (zero allocations)
            if settings.showMismatches, let refBytes {
                drawMismatchTicks(
                    read: read, frame: frame, refBytes: refBytes, referenceStart: referenceStart,
                    context: context, y: y, readHeight: packedReadHeight
                )
            }

            // Draw deletion lines
            if settings.showIndels {
                drawDeletions(read: read, frame: frame, context: context, y: y + packedReadHeight / 2, readHeight: packedReadHeight)
                drawInsertionTicks(read: read, frame: frame, context: context, y: y, readHeight: packedReadHeight)
            }
        }

        // Draw overflow indicator
        if overflow > 0 {
            drawOverflowIndicator(context: context, rect: rect, overflow: overflow)
        }

        context.restoreGState()
    }

    // MARK: - Base-Level Rendering (Tier 3)

    /// Draws reads with base-level detail: dots for matches, colored letters for mismatches.
    ///
    /// - Parameters:
    ///   - packedReads: Pre-packed reads with row assignments
    ///   - overflow: Number of reads that didn't fit
    ///   - frame: Reference frame for coordinate mapping
    ///   - referenceSequence: The reference sequence for match/mismatch detection
    ///   - referenceStart: 0-based start position of the reference sequence
    ///   - settings: Display settings controlling mismatch/softclip/indel visibility
    ///   - context: CoreGraphics context
    ///   - rect: Drawing rectangle
    public static func drawBaseReads(
        packedReads: [(row: Int, read: AlignedRead)],
        overflow: Int,
        frame: ReferenceFrame,
        referenceSequence: String?,
        referenceStart: Int,
        settings: DisplaySettings = DisplaySettings(),
        context: CGContext,
        rect: CGRect
    ) {
        context.saveGState()

        let pixelsPerBase = 1.0 / frame.scale
        let fontSize = min(12, CGFloat(pixelsPerBase) * 0.85)
        let font = CTFontCreateWithName("Menlo" as CFString, fontSize, nil)

        // Pre-compute background colors for each strand to avoid per-read alloc
        let fwdBgTemplate = NSColor(red: 0.94, green: 0.96, blue: 0.97, alpha: 1.0).cgColor
        let revBgTemplate = NSColor(red: 0.97, green: 0.94, blue: 0.94, alpha: 1.0).cgColor

        for (row, read) in packedReads {
            let y = rect.minY + CGFloat(row) * (baseReadHeight + rowGap)
            guard y + baseReadHeight <= rect.maxY else { continue }

            let alpha = mapqAlpha(read.mapq)

            // Draw soft-clip background extensions
            if settings.showSoftClips {
                drawSoftClipExtensions(read: read, frame: frame, context: context, y: y, readHeight: baseReadHeight, alpha: alpha)
            }

            // Draw read background
            let startPx = frame.genomicToPixel(Double(read.position))
            let endPx = frame.genomicToPixel(Double(read.alignmentEnd))
            let bgColor = (read.isReverse ? revBgTemplate : fwdBgTemplate).copy(alpha: alpha * 0.5)!
            context.setFillColor(bgColor)
            context.fill(CGRect(x: startPx, y: y, width: endPx - startPx, height: baseReadHeight))

            // Draw bases using CTFont glyph rendering
            drawReadBases(
                read: read,
                frame: frame,
                referenceSequence: referenceSequence,
                referenceStart: referenceStart,
                showMismatches: settings.showMismatches,
                context: context,
                y: y,
                readHeight: baseReadHeight,
                font: font,
                fontSize: fontSize,
                alpha: alpha
            )

            // Draw insertion markers
            if settings.showIndels {
                drawInsertionMarkers(read: read, frame: frame, context: context, y: y, readHeight: baseReadHeight)
                drawDeletions(read: read, frame: frame, context: context, y: y + baseReadHeight / 2, readHeight: baseReadHeight)
            }
        }

        // Draw overflow indicator
        if overflow > 0 {
            drawOverflowIndicator(context: context, rect: rect, overflow: overflow)
        }

        context.restoreGState()
    }

    // MARK: - Private Drawing Helpers

    /// Pre-computed glyph metrics for nucleotide characters, avoiding per-character CoreText layout.
    private struct GlyphCache {
        let font: CTFont
        var glyphs: [UInt8: CGGlyph] = [:]      // ASCII byte -> glyph
        var advances: [UInt8: CGSize] = [:]      // ASCII byte -> glyph size
        let dotGlyph: CGGlyph
        let dotAdvance: CGSize

        init(font: CTFont) {
            self.font = font
            // Pre-compute glyphs for A, C, G, T, N, a, c, g, t, n, .
            let chars: [UInt8] = [65, 67, 71, 84, 78, 97, 99, 103, 116, 110] // A,C,G,T,N,a,c,g,t,n
            for byte in chars {
                var unichars = [UniChar(byte)]
                var glyph = CGGlyph(0)
                CTFontGetGlyphsForCharacters(font, &unichars, &glyph, 1)
                glyphs[byte] = glyph
                var advance = CGSize.zero
                CTFontGetAdvancesForGlyphs(font, .default, &glyph, &advance, 1)
                advances[byte] = advance
            }
            // Dot glyph for matches
            var dotUnichars = [UniChar(46)] // "."
            var dGlyph = CGGlyph(0)
            CTFontGetGlyphsForCharacters(font, &dotUnichars, &dGlyph, 1)
            dotGlyph = dGlyph
            var dAdv = CGSize.zero
            CTFontGetAdvancesForGlyphs(font, .default, &dGlyph, &dAdv, 1)
            dotAdvance = dAdv
        }
    }

    /// Draws individual bases using CTFont glyph rendering (50-100x faster than NSString.draw).
    private static func drawReadBases(
        read: AlignedRead,
        frame: ReferenceFrame,
        referenceSequence: String?,
        referenceStart: Int,
        showMismatches: Bool = true,
        context: CGContext,
        y: CGFloat,
        readHeight: CGFloat,
        font: CTFont,
        fontSize: CGFloat,
        alpha: CGFloat
    ) {
        let pixelsPerBase = 1.0 / frame.scale
        let cellWidth = CGFloat(pixelsPerBase)

        // Pre-compute reference as uppercased ASCII bytes
        let refBytes: [UInt8]? = referenceSequence.map { Array($0.uppercased().utf8) }

        let cache = GlyphCache(font: font)

        // Pre-compute alpha-modulated colors (5 base colors + match dot + soft clip variants)
        let matchDotAlpha = matchDotColor.copy(alpha: alpha)!
        let colorA = baseA.copy(alpha: alpha)!
        let colorT = baseT.copy(alpha: alpha)!
        let colorC = baseC.copy(alpha: alpha)!
        let colorG = baseG.copy(alpha: alpha)!
        let colorN = baseN.copy(alpha: alpha)!
        let softAlphaFactor = alpha * 0.4

        // Baseline offset: center glyph vertically using ascent/descent
        let ascent = CTFontGetAscent(font)
        let descent = CTFontGetDescent(font)
        let glyphHeight = ascent + descent
        let baselineY = y + (readHeight - glyphHeight) / 2 + descent

        context.saveGState()

        // Use UTF-8 view for zero-allocation iteration
        var byteIndex = 0
        let seqBytes = Array(read.sequence.utf8)

        var refPos = read.position
        for op in read.cigar {
            switch op.op {
            case .match, .seqMatch, .seqMismatch:
                for _ in 0..<op.length {
                    guard byteIndex < seqBytes.count else { refPos += 1; continue }
                    let readByte = seqBytes[byteIndex]
                    byteIndex += 1

                    let x = frame.genomicToPixel(Double(refPos))

                    // Uppercase: mask bit 5 (0x20) to convert lowercase ASCII to uppercase
                    let upperByte = readByte & 0xDF

                    let isMatch: Bool
                    if showMismatches, let refBytes, refPos >= referenceStart {
                        let refIdx = refPos - referenceStart
                        if refIdx >= 0, refIdx < refBytes.count {
                            isMatch = (upperByte == refBytes[refIdx])
                        } else {
                            isMatch = true
                        }
                    } else {
                        isMatch = true
                    }

                    let glyph: CGGlyph
                    let glyphWidth: CGFloat
                    let color: CGColor

                    if isMatch {
                        glyph = cache.dotGlyph
                        glyphWidth = cache.dotAdvance.width
                        color = matchDotAlpha
                    } else {
                        glyph = cache.glyphs[upperByte] ?? cache.dotGlyph
                        glyphWidth = cache.advances[upperByte]?.width ?? cache.dotAdvance.width
                        color = colorForByte(upperByte, a: colorA, t: colorT, c: colorC, g: colorG, n: colorN)
                    }

                    let drawX = x + (cellWidth - glyphWidth) / 2
                    context.setFillColor(color)
                    var g = glyph
                    var pos = CGPoint(x: drawX, y: baselineY)
                    CTFontDrawGlyphs(font, &g, &pos, 1, context)

                    refPos += 1
                }

            case .softClip:
                for _ in 0..<op.length {
                    guard byteIndex < seqBytes.count else { continue }
                    let readByte = seqBytes[byteIndex]
                    byteIndex += 1

                    // Soft clips shown as lowercase at reduced opacity
                    let lowerByte = readByte | 0x20
                    let upperByte = readByte & 0xDF
                    if let glyph = cache.glyphs[lowerByte] ?? cache.glyphs[upperByte] {
                        let advance = cache.advances[lowerByte] ?? cache.advances[upperByte] ?? cache.dotAdvance
                        let softColor = colorForByte(upperByte, a: colorA, t: colorT, c: colorC, g: colorG, n: colorN).copy(alpha: softAlphaFactor)!
                        context.setFillColor(softColor)
                        var g = glyph
                        var pos = CGPoint(x: 0, y: baselineY) // soft clips don't have ref positions; skip rendering
                        CTFontDrawGlyphs(font, &g, &pos, 1, context)
                        _ = advance
                    }
                }

            case .insertion:
                for _ in 0..<op.length {
                    if byteIndex < seqBytes.count { byteIndex += 1 }
                }

            case .deletion, .skip:
                refPos += op.length

            case .hardClip, .padding:
                break
            }
        }

        context.restoreGState()
    }

    /// Returns color for an ASCII byte (uppercase). Zero-allocation.
    private static func colorForByte(_ byte: UInt8, a: CGColor, t: CGColor, c: CGColor, g: CGColor, n: CGColor) -> CGColor {
        switch byte {
        case 65: return a  // A
        case 84: return t  // T
        case 67: return c  // C
        case 71: return g  // G
        default: return n  // N or other
        }
    }

    /// Draws colored tick marks at mismatch positions on a packed read bar.
    ///
    /// Uses ASCII byte comparison (zero allocations) instead of Character/String conversion.
    /// At wider zoom levels, mismatches within the same pixel column are coalesced.
    private static func drawMismatchTicks(
        read: AlignedRead,
        frame: ReferenceFrame,
        refBytes: [UInt8],
        referenceStart: Int,
        context: CGContext,
        y: CGFloat,
        readHeight: CGFloat
    ) {
        let pixelsPerBase = 1.0 / frame.scale
        context.setFillColor(mismatchTickColor)

        var lastMismatchPixel: Int = Int.min
        let seqBytes = Array(read.sequence.utf8)
        var byteIndex = 0
        var refPos = read.position

        for op in read.cigar {
            switch op.op {
            case .match, .seqMatch, .seqMismatch:
                for _ in 0..<op.length {
                    guard byteIndex < seqBytes.count else { refPos += 1; continue }
                    let readByte = seqBytes[byteIndex]
                    byteIndex += 1

                    let refIdx = refPos - referenceStart
                    refPos += 1

                    guard refIdx >= 0, refIdx < refBytes.count else { continue }
                    // Case-insensitive comparison by masking bit 5
                    let upperRead = readByte & 0xDF
                    let upperRef = refBytes[refIdx]
                    guard upperRead != upperRef else { continue }
                    // Skip ambiguous bases (N = 0x4E)
                    guard upperRead != 0x4E && upperRef != 0x4E else { continue }

                    let x = frame.genomicToPixel(Double(refPos - 1))
                    let px = Int(x)
                    guard px != lastMismatchPixel else { continue }
                    lastMismatchPixel = px

                    let tickWidth = max(1.0, min(CGFloat(pixelsPerBase), 3.0))
                    context.fill(CGRect(x: x, y: y, width: tickWidth, height: readHeight))
                }

            case .insertion:
                for _ in 0..<op.length {
                    if byteIndex < seqBytes.count { byteIndex += 1 }
                }

            case .softClip:
                for _ in 0..<op.length {
                    if byteIndex < seqBytes.count { byteIndex += 1 }
                }

            case .deletion, .skip:
                refPos += op.length

            case .hardClip, .padding:
                break
            }
        }
    }

    /// Draws semi-transparent extensions at soft-clipped ends of a read in packed mode.
    ///
    /// Soft clips are bases present in the read but not part of the alignment.
    /// They appear as translucent extensions beyond the aligned portion,
    /// indicating where the read sequence continues past the alignment boundary.
    private static func drawSoftClipExtensions(
        read: AlignedRead,
        frame: ReferenceFrame,
        context: CGContext,
        y: CGFloat,
        readHeight: CGFloat,
        alpha: CGFloat
    ) {
        guard !read.cigar.isEmpty else { return }

        // Check for leading soft clip
        if let first = read.cigar.first, first.op == .softClip {
            let clipBases = first.length
            let alignStartPx = frame.genomicToPixel(Double(read.position))
            let clipStartPx = frame.genomicToPixel(Double(read.position - clipBases))
            let width = alignStartPx - clipStartPx
            if width >= 1 {
                context.setFillColor(softClipColor.copy(alpha: alpha * 0.5)!)
                context.fill(CGRect(x: clipStartPx, y: y, width: width, height: readHeight))
            }
        }

        // Check for trailing soft clip
        if let last = read.cigar.last, last.op == .softClip {
            let clipBases = last.length
            let alignEndPx = frame.genomicToPixel(Double(read.alignmentEnd))
            let clipEndPx = frame.genomicToPixel(Double(read.alignmentEnd + clipBases))
            let width = clipEndPx - alignEndPx
            if width >= 1 {
                context.setFillColor(softClipColor.copy(alpha: alpha * 0.5)!)
                context.fill(CGRect(x: alignEndPx, y: y, width: width, height: readHeight))
            }
        }
    }

    /// Draws deletion connecting lines for a read.
    private static func drawDeletions(
        read: AlignedRead,
        frame: ReferenceFrame,
        context: CGContext,
        y: CGFloat,
        readHeight: CGFloat
    ) {
        var refPos = read.position
        for op in read.cigar {
            if op.op == .deletion {
                let startPx = frame.genomicToPixel(Double(refPos))
                let endPx = frame.genomicToPixel(Double(refPos + op.length))
                context.setStrokeColor(deletionColor)
                context.setLineWidth(1)
                context.setLineDash(phase: 0, lengths: [2, 2])
                context.move(to: CGPoint(x: startPx, y: y))
                context.addLine(to: CGPoint(x: endPx, y: y))
                context.strokePath()
                context.setLineDash(phase: 0, lengths: [])
            }
            if op.consumesReference {
                refPos += op.length
            }
        }
    }

    /// Draws small insertion ticks (for packed mode).
    private static func drawInsertionTicks(
        read: AlignedRead,
        frame: ReferenceFrame,
        context: CGContext,
        y: CGFloat,
        readHeight: CGFloat
    ) {
        for ins in read.insertions {
            let x = frame.genomicToPixel(Double(ins.position))
            context.setFillColor(insertionColor)
            context.fill(CGRect(x: x - 0.5, y: y - 1, width: 1, height: readHeight + 2))
        }
    }

    /// Draws insertion markers with triangle indicators (for base mode).
    private static func drawInsertionMarkers(
        read: AlignedRead,
        frame: ReferenceFrame,
        context: CGContext,
        y: CGFloat,
        readHeight: CGFloat
    ) {
        for ins in read.insertions {
            let x = frame.genomicToPixel(Double(ins.position))
            // Vertical line
            context.setFillColor(insertionColor)
            context.fill(CGRect(x: x - 0.5, y: y, width: 1, height: readHeight))

            // Small triangle pointing down
            let trianglePath = CGMutablePath()
            trianglePath.move(to: CGPoint(x: x - 2, y: y))
            trianglePath.addLine(to: CGPoint(x: x + 2, y: y))
            trianglePath.addLine(to: CGPoint(x: x, y: y + 4))
            trianglePath.closeSubpath()
            context.addPath(trianglePath)
            context.fillPath()

            // Insertion length label if > 1 base
            if ins.bases.count > 1 {
                let label = "I\(ins.bases.count)" as NSString
                let attrs: [NSAttributedString.Key: Any] = [
                    .font: NSFont.monospacedDigitSystemFont(ofSize: 7, weight: .medium),
                    .foregroundColor: NSColor(cgColor: insertionColor) ?? NSColor.magenta
                ]
                label.draw(at: CGPoint(x: x + 2, y: y), withAttributes: attrs)
            }
        }
    }

    /// Draws the overflow indicator bar at the bottom of the track.
    private static func drawOverflowIndicator(
        context: CGContext,
        rect: CGRect,
        overflow: Int
    ) {
        let barHeight: CGFloat = 16
        let barRect = CGRect(x: rect.minX, y: rect.maxY - barHeight, width: rect.width, height: barHeight)

        // Gradient background
        context.setFillColor(NSColor(white: 0.88, alpha: 0.9).cgColor)
        context.fill(barRect)

        // Text
        let text = "+\(overflow) reads not shown (max \(maxReadRows) rows)" as NSString
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 9),
            .foregroundColor: NSColor.secondaryLabelColor
        ]
        let size = text.size(withAttributes: attrs)
        text.draw(
            at: CGPoint(x: barRect.midX - size.width / 2, y: barRect.minY + (barHeight - size.height) / 2),
            withAttributes: attrs
        )
    }

    // MARK: - Utility

    /// Returns alpha value for a given mapping quality.
    private static func mapqAlpha(_ mapq: UInt8) -> CGFloat {
        switch mapq {
        case 40...255: return 1.0
        case 20..<40:  return 0.7
        case 10..<20:  return 0.45
        case 1..<10:   return 0.25
        default:       return 0.15
        }
    }

    /// Returns the color for a nucleotide base.
    private static func colorForBase(_ base: Character) -> CGColor {
        switch base {
        case "A", "a": return baseA
        case "T", "t": return baseT
        case "C", "c": return baseC
        case "G", "g": return baseG
        default:        return baseN
        }
    }

    /// Calculates the total height needed for packed reads.
    ///
    /// - Parameters:
    ///   - rowCount: Number of rows used
    ///   - tier: Current zoom tier
    /// - Returns: Total height in pixels
    public static func totalHeight(rowCount: Int, tier: ZoomTier) -> CGFloat {
        switch tier {
        case .coverage:
            return coverageTrackHeight
        case .packed:
            return CGFloat(rowCount) * (packedReadHeight + rowGap)
        case .base:
            return CGFloat(rowCount) * (baseReadHeight + rowGap)
        }
    }
}

// MARK: - ReferenceFrame Extension

extension ReferenceFrame {

    /// Converts a genomic position to a pixel X coordinate.
    func genomicToPixel(_ position: Double) -> CGFloat {
        CGFloat((position - start) / scale)
    }
}
