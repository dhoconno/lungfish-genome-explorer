// ReadTrackRenderer.swift - Renders aligned reads at three zoom tiers
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import LungfishCore
import LungfishKit

// MARK: - ReadTrackRenderer

/// Renders aligned sequencing reads at three zoom-dependent tiers.
///
/// ## Zoom Tiers
///
/// | Tier | Scale (bp/px) | Rendering |
/// |------|---------------|-----------|
/// | Coverage | > 2.0 | Forward/reverse stacked area chart |
/// | Packed | 0.6 < x <= 2.0 | Colored bars with strand indicators |
/// | Base | <= 0.6 | Geneious-style dots for matches, letters for mismatches |
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

    /// Compact mode packed-row height.
    static let packedReadHeightCompact: CGFloat = 4

    /// Compact mode base-row height.
    static let baseReadHeightCompact: CGFloat = 11

    /// Compact mode row gap.
    static let rowGapCompact: CGFloat = 1

    /// Height of the coverage track.
    static let coverageTrackHeight: CGFloat = 60

    /// Maximum number of read rows to render.
    static let maxReadRows: Int = 75

    /// Minimum pixels per read to render individually.
    nonisolated static let minReadPixels: CGFloat = 2

    /// Zoom tier thresholds.
    static let coverageThresholdBpPerPx: Double = ReadViewportPolicy.coverageThresholdBpPerPx
    static let baseThresholdBpPerPx: Double = ReadViewportPolicy.baseThresholdBpPerPx
    /// In base tier, switch from dot-mode matches to letter-mode matches once bases are clearly legible.
    static let matchLetterThresholdPxPerBase: Double = 4.0

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

    /// Base colors for mismatches (delegated to SemanticColors.DNA).
    static let baseA = SemanticColors.DNA.baseA.cgColor
    static let baseT = SemanticColors.DNA.baseT.cgColor
    static let baseC = SemanticColors.DNA.baseC.cgColor
    static let baseG = SemanticColors.DNA.baseG.cgColor
    static let baseN = SemanticColors.DNA.baseN.cgColor
    /// Match dot color.
    static let matchDotColor = NSColor(white: 0.48, alpha: 0.82).cgColor
    /// Insertion indicator color (magenta).
    static let insertionColor = NSColor(red: 0.8, green: 0, blue: 0.8, alpha: 1.0).cgColor
    /// Deletion line color.
    static let deletionColor = NSColor.gray.cgColor
    /// Soft-clip indicator color for packed mode (blue-gray).
    static let softClipColor = NSColor(red: 0.5, green: 0.6, blue: 0.75, alpha: 0.6).cgColor

    // Insert size coloring (IGV convention)
    /// Normal insert size.
    static let insertNormalColor = NSColor(red: 0.75, green: 0.75, blue: 0.75, alpha: 1.0).cgColor
    /// Insert size too small (potential deletion).
    static let insertTooSmallColor = NSColor(red: 0.0, green: 0.0, blue: 0.85, alpha: 1.0).cgColor
    /// Insert size too large (potential insertion).
    static let insertTooLargeColor = NSColor(red: 0.85, green: 0.0, blue: 0.0, alpha: 1.0).cgColor
    /// Inter-chromosomal mates.
    static let insertInterchromosomalColor = NSColor(red: 0.6, green: 0.0, blue: 0.85, alpha: 1.0).cgColor
    /// Abnormal orientation (inversion).
    static let insertAbnormalOrientationColor = NSColor(red: 0.0, green: 0.75, blue: 0.75, alpha: 1.0).cgColor

    // First/Second in pair coloring
    static let firstInPairColor = NSColor(red: 0.45, green: 0.45, blue: 0.85, alpha: 1.0).cgColor
    static let secondInPairColor = NSColor(red: 0.85, green: 0.45, blue: 0.45, alpha: 1.0).cgColor

    /// Split-read indicator color (bright orange line connecting chimeric parts).
    static let splitReadColor = NSColor(red: 1.0, green: 0.5, blue: 0.0, alpha: 0.8).cgColor

    // MARK: - Zoom Tier Detection

    /// Returns the appropriate zoom tier for the current scale.
    public static func zoomTier(scale: Double) -> ZoomTier {
        ReadViewportPolicy.zoomTier(scale: scale)
    }

    /// Zoom tier for read rendering.
    public enum ZoomTier {
        case coverage
        case packed
        case base
    }

    /// Per-tier row layout metrics.
    public struct LayoutMetrics: Sendable, Equatable {
        public let packedReadHeight: CGFloat
        public let baseReadHeight: CGFloat
        public let rowGap: CGFloat
    }

    /// Returns row layout metrics for compressed/non-compressed modes.
    public static func layoutMetrics(verticalCompress: Bool) -> LayoutMetrics {
        if verticalCompress {
            return LayoutMetrics(
                packedReadHeight: packedReadHeightCompact,
                baseReadHeight: baseReadHeightCompact,
                rowGap: rowGapCompact
            )
        }
        return LayoutMetrics(
            packedReadHeight: packedReadHeight,
            baseReadHeight: baseReadHeight,
            rowGap: rowGap
        )
    }

    // MARK: - Coverage Models

    /// Sparse coverage point used for depth-based rendering.
    public struct CoveragePoint: Sendable, Equatable {
        public let position: Int
        public let depth: Int

        public init(position: Int, depth: Int) {
            self.position = position
            self.depth = depth
        }
    }

    /// Summary statistics for a depth profile.
    public struct CoverageStats: Sendable, Equatable {
        public let regionStart: Int
        public let regionEnd: Int
        public let maxDepth: Int
        public let meanDepth: Double
        public let coveredBases: Int

        public var span: Int { max(0, regionEnd - regionStart) }
    }

    // MARK: - Color Mode Support

    /// Returns fill and stroke colors for a read based on the current color mode.
    static func readColors(
        for read: AlignedRead,
        colorMode: ReadColorMode,
        alpha: CGFloat,
        expectedInsertSize: Int = 400,
        insertSizeStdDev: Int = 100,
        readGroupColorMap: [String: CGColor]? = nil
    ) -> (fill: CGColor, stroke: CGColor) {
        switch colorMode {
        case .strand:
            let fill = (read.isReverse ? reverseReadColor : forwardReadColor).copy(alpha: alpha)!
            let stroke = (read.isReverse ? reverseReadStroke : forwardReadStroke).copy(alpha: alpha)!
            return (fill, stroke)

        case .insertSize:
            let sizeClass = read.insertSizeClass(expectedInsertSize: expectedInsertSize, stdDev: insertSizeStdDev)
            let baseColor: CGColor
            switch sizeClass {
            case .normal: baseColor = insertNormalColor
            case .tooSmall: baseColor = insertTooSmallColor
            case .tooLarge: baseColor = insertTooLargeColor
            case .interchromosomal: baseColor = insertInterchromosomalColor
            case .abnormalOrientation: baseColor = insertAbnormalOrientationColor
            case .notApplicable:
                let fill = (read.isReverse ? reverseReadColor : forwardReadColor).copy(alpha: alpha)!
                let stroke = (read.isReverse ? reverseReadStroke : forwardReadStroke).copy(alpha: alpha)!
                return (fill, stroke)
            }
            let fill = baseColor.copy(alpha: alpha)!
            let stroke = baseColor.copy(alpha: max(alpha - 0.15, 0.1))!
            return (fill, stroke)

        case .mappingQuality:
            // MAPQ 255 = unavailable per SAM spec — show as neutral gray
            if read.mapq == 255 {
                let gray = CGColor(gray: 0.65, alpha: alpha)
                return (gray, CGColor(gray: 0.5, alpha: alpha))
            }
            // Heatmap: blue (low quality) → green (medium) → red (high quality)
            let mqNorm = CGFloat(read.mapq) / 60.0
            let clamped = min(max(mqNorm, 0), 1)
            let r: CGFloat, g: CGFloat, b: CGFloat
            if clamped < 0.5 {
                let t = clamped * 2
                r = 0.2
                g = 0.2 + 0.6 * t
                b = 0.8 * (1.0 - t)
            } else {
                let t = (clamped - 0.5) * 2
                r = 0.2 + 0.7 * t
                g = 0.8 - 0.4 * t
                b = 0.0
            }
            let fill = CGColor(red: r, green: g, blue: b, alpha: alpha)
            let stroke = CGColor(red: r * 0.8, green: g * 0.8, blue: b * 0.8, alpha: alpha)
            return (fill, stroke)

        case .readGroup:
            if let rg = read.readGroup, let color = readGroupColorMap?[rg] {
                return (color.copy(alpha: alpha)!, color.copy(alpha: max(alpha - 0.15, 0.1))!)
            }
            let fill = (read.isReverse ? reverseReadColor : forwardReadColor).copy(alpha: alpha)!
            let stroke = (read.isReverse ? reverseReadStroke : forwardReadStroke).copy(alpha: alpha)!
            return (fill, stroke)

        case .firstOfPair:
            guard read.isPaired else {
                let fill = (read.isReverse ? reverseReadColor : forwardReadColor).copy(alpha: alpha)!
                let stroke = (read.isReverse ? reverseReadStroke : forwardReadStroke).copy(alpha: alpha)!
                return (fill, stroke)
            }
            let baseColor = read.isFirstInPair ? firstInPairColor : secondInPairColor
            return (baseColor.copy(alpha: alpha)!, baseColor.copy(alpha: max(alpha - 0.15, 0.1))!)

        case .baseQuality:
            // Base quality is per-base; for the read background, use mean quality
            let meanQ: CGFloat
            if read.qualities.isEmpty {
                meanQ = 0.5
            } else {
                let sum = read.qualities.reduce(0, { $0 + Int($1) })
                meanQ = min(CGFloat(sum) / CGFloat(read.qualities.count) / 40.0, 1.0)
            }
            // Yellow (low) → Green (high)
            let fill = CGColor(red: 1.0 - meanQ * 0.7, green: 0.3 + meanQ * 0.5, blue: 0.1, alpha: alpha)
            let stroke = CGColor(red: (1.0 - meanQ * 0.7) * 0.8, green: (0.3 + meanQ * 0.5) * 0.8, blue: 0.08, alpha: alpha)
            return (fill, stroke)
        }
    }

    /// Pre-assigns colors for read groups found in a set of reads.
    static func buildReadGroupColorMap(from reads: [AlignedRead]) -> [String: CGColor] {
        var map: [String: CGColor] = [:]
        // Collect unique read groups with O(1) membership check
        var seenSet = Set<String>()
        var orderedGroups: [String] = []
        for read in reads {
            if let rg = read.readGroup, seenSet.insert(rg).inserted {
                orderedGroups.append(rg)
            }
        }
        // Assign distinct hues
        let count = max(orderedGroups.count, 1)
        for (i, rg) in orderedGroups.enumerated() {
            let hue = CGFloat(i) / CGFloat(count)
            let color = NSColor(hue: hue, saturation: 0.55, brightness: 0.75, alpha: 1.0).cgColor
            map[rg] = color
        }
        return map
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
            // Walk CIGAR to skip N (intron) and D (deletion) regions for accurate coverage.
            // Only count bins for reference-consuming, query-consuming operations (M, =, X).
            var refPos = read.position
            for op in read.cigar {
                switch op.op {
                case .match, .seqMatch, .seqMismatch:
                    let opStart = max(0, Int(frame.genomicToPixel(Double(refPos)) - rect.minX))
                    let opEnd = min(pixelWidth - 1, Int(frame.genomicToPixel(Double(refPos + op.length)) - rect.minX))
                    if opStart <= opEnd {
                        if read.isReverse {
                            for i in opStart...opEnd { reverseBins[i] += 1 }
                        } else {
                            for i in opStart...opEnd { forwardBins[i] += 1 }
                        }
                    }
                    refPos += op.length
                case .deletion, .skip:
                    refPos += op.length
                case .insertion, .softClip, .hardClip, .padding:
                    break
                }
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

    /// Draws depth-based coverage from sparse `samtools depth` points.
    ///
    /// This path is decoupled from read rendering and is intended for zoomed-out
    /// coverage visualization where loading full read records is unnecessary.
    public static func drawCoverage(
        depthPoints: [CoveragePoint],
        regionStart: Int,
        regionEnd: Int,
        frame: ReferenceFrame,
        context: CGContext,
        rect: CGRect,
        scaleMode: CoverageScaleMode = .default
    ) {
        let pixelWidth = Int(rect.width)
        guard pixelWidth > 0, regionEnd > regionStart else { return }

        let bins = binnedDepthColumns(
            depthPoints: depthPoints,
            regionStart: regionStart,
            regionEnd: regionEnd,
            frame: frame,
            rect: rect
        )

        let stats = summarizeCoverage(
            depthPoints: depthPoints,
            regionStart: regionStart,
            regionEnd: regionEnd
        )

        var maxDepth = max(1, stats.maxDepth)
        for depth in bins where depth > maxDepth {
            maxDepth = depth
        }
        let meanDepth = stats.meanDepth
        let trackHeight = rect.height - 18
        // Height comes from the selected transform rather than a fixed linear
        // ratio, so a single deep peak cannot flatten every shallow region.
        func columnHeight(_ depth: Int) -> CGFloat {
            let fraction = scaleMode.normalizedHeight(
                depth: Double(depth),
                maxDepth: Double(maxDepth)
            )
            return trackHeight * CGFloat(fraction)
        }

        context.saveGState()

        // Filled depth area
        context.setFillColor(forwardCoverageColor)
        let areaPath = CGMutablePath()
        areaPath.move(to: CGPoint(x: rect.minX, y: rect.maxY))
        for px in 0..<pixelWidth {
            let h = columnHeight(bins[px])
            areaPath.addLine(to: CGPoint(x: rect.minX + CGFloat(px), y: rect.maxY - h))
        }
        areaPath.addLine(to: CGPoint(x: rect.minX + CGFloat(pixelWidth - 1), y: rect.maxY))
        areaPath.closeSubpath()
        context.addPath(areaPath)
        context.fillPath()

        // Outline
        context.setStrokeColor(NSColor(white: 0.33, alpha: 1).cgColor)
        context.setLineWidth(0.6)
        let outlinePath = CGMutablePath()
        outlinePath.move(to: CGPoint(x: rect.minX, y: rect.maxY))
        for px in 0..<pixelWidth {
            let h = columnHeight(bins[px])
            outlinePath.addLine(to: CGPoint(x: rect.minX + CGFloat(px), y: rect.maxY - h))
        }
        context.addPath(outlinePath)
        context.strokePath()

        // Legend key
        let legendRect = CGRect(x: rect.minX + 4, y: rect.minY + 4, width: 10, height: 10)
        context.setFillColor(forwardCoverageColor)
        context.fill(legendRect)
        context.setStrokeColor(NSColor(white: 0.25, alpha: 1).cgColor)
        context.stroke(legendRect)

        let legendAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 9, weight: .regular),
            .foregroundColor: NSColor.secondaryLabelColor,
        ]
        let depthLegend = scaleMode.axisLabel.map { "Depth (\($0))" } ?? "Depth"
        (depthLegend as NSString).draw(at: CGPoint(x: legendRect.maxX + 4, y: rect.minY + 3), withAttributes: legendAttrs)

        // Summary labels
        let rightLabel = "max: \(maxDepth)x  mean: \(String(format: "%.1f", meanDepth))x" as NSString
        let rightSize = rightLabel.size(withAttributes: legendAttrs)
        rightLabel.draw(
            at: CGPoint(x: rect.maxX - rightSize.width - 4, y: rect.minY + 2),
            withAttributes: legendAttrs
        )

        let coveragePct = Double(stats.coveredBases) / Double(max(1, stats.span)) * 100
        let leftDetail = "\(Int(coveragePct.rounded()))% covered" as NSString
        let depthLegendWidth = (depthLegend as NSString).size(withAttributes: legendAttrs).width
        leftDetail.draw(
            at: CGPoint(x: legendRect.maxX + 8 + depthLegendWidth + 8, y: rect.minY + 3),
            withAttributes: legendAttrs
        )

        context.restoreGState()
    }

    /// Bins sparse depth points into pixel columns for coverage rendering.
    ///
    /// Each 1bp depth sample is expanded to its full on-screen pixel span so
    /// zoomed-in views (>1 px/base) do not introduce false zero-depth columns.
    static func binnedDepthColumns(
        depthPoints: [CoveragePoint],
        regionStart: Int,
        regionEnd: Int,
        frame: ReferenceFrame,
        rect: CGRect
    ) -> [Int] {
        let pixelWidth = Int(rect.width)
        guard pixelWidth > 0, regionEnd > regionStart else { return [] }

        var bins = [Int](repeating: 0, count: pixelWidth)
        for point in depthPoints {
            if point.depth <= 0 { continue }
            if point.position < regionStart || point.position >= regionEnd { continue }

            let startX = frame.genomicToPixel(Double(point.position)) - rect.minX
            let endX = frame.genomicToPixel(Double(point.position + 1)) - rect.minX
            let startPx = max(0, Int(floor(startX)))
            let endPxExclusive = min(pixelWidth, max(startPx + 1, Int(ceil(endX))))
            if startPx >= pixelWidth || endPxExclusive <= 0 { continue }

            for px in startPx..<endPxExclusive where point.depth > bins[px] {
                bins[px] = point.depth
            }
        }
        return bins
    }

    /// Returns depth value for a specific 0-based genomic position.
    ///
    /// `depthPoints` should be sorted by position for efficient lookup.
    public static func depthAt(position: Int, in depthPoints: [CoveragePoint]) -> Int {
        guard !depthPoints.isEmpty else { return 0 }
        var low = 0
        var high = depthPoints.count - 1
        while low <= high {
            let mid = low + (high - low) / 2
            let point = depthPoints[mid]
            if point.position == position {
                return point.depth
            } else if point.position < position {
                low = mid + 1
            } else {
                high = mid - 1
            }
        }
        return 0
    }

    /// Computes summary statistics for a depth profile.
    public static func summarizeCoverage(
        depthPoints: [CoveragePoint],
        regionStart: Int,
        regionEnd: Int
    ) -> CoverageStats {
        guard regionEnd > regionStart else {
            return CoverageStats(regionStart: regionStart, regionEnd: regionEnd, maxDepth: 0, meanDepth: 0, coveredBases: 0)
        }
        var maxDepth = 0
        var coveredBases = 0
        var totalDepth: Int64 = 0

        // Sparse input contains non-zero positions; missing positions imply depth 0.
        for point in depthPoints where point.position >= regionStart && point.position < regionEnd {
            let d = max(0, point.depth)
            if d > 0 {
                coveredBases += 1
                totalDepth += Int64(d)
                if d > maxDepth { maxDepth = d }
            }
        }

        let span = max(1, regionEnd - regionStart)
        let meanDepth = Double(totalDepth) / Double(span)
        return CoverageStats(
            regionStart: regionStart,
            regionEnd: regionEnd,
            maxDepth: maxDepth,
            meanDepth: meanDepth,
            coveredBases: coveredBases
        )
    }

    // MARK: - Display Settings

    /// Rendering options controllable from the Inspector panel.
    public struct DisplaySettings {
        /// When true (default), matches are shown as dots and mismatches as colored letters.
        /// When false, all bases are shown as letters (matches in neutral gray, mismatches colored).
        /// Mismatches are ALWAYS visible regardless of this setting.
        public var showMismatches: Bool = true
        public var showSoftClips: Bool = true
        public var showIndels: Bool = true
        public var consensusMaskingEnabled: Bool = false
        public var consensusGapThreshold: Double = 0.9
        public var consensusMaskingMinDepth: Int = 8
        /// When true, forward reads have blue-tinted backgrounds and reverse reads
        /// have pink-tinted backgrounds. When false, all reads share a neutral background.
        public var showStrandColors: Bool = true
        /// How packed reads are colored. Only consulted when
        /// `showStrandColors` is true; `.strand` reproduces the exact
        /// pre-existing behavior, so this is additive.
        public var colorMode: ReadColorMode = .strand

        public init(
            showMismatches: Bool = true,
            showSoftClips: Bool = true,
            showIndels: Bool = true,
            consensusMaskingEnabled: Bool = false,
            consensusGapThreshold: Double = 0.9,
            consensusMaskingMinDepth: Int = 8,
            showStrandColors: Bool = true,
            colorMode: ReadColorMode = .strand
        ) {
            self.showMismatches = showMismatches
            self.showSoftClips = showSoftClips
            self.showIndels = showIndels
            self.consensusMaskingEnabled = consensusMaskingEnabled
            self.consensusGapThreshold = consensusGapThreshold
            self.consensusMaskingMinDepth = consensusMaskingMinDepth
            self.showStrandColors = showStrandColors
            self.colorMode = colorMode
        }
    }
}

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
