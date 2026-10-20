// ReadTrackRenderer.swift - Renders aligned reads at three zoom tiers
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import LungfishCore
import LungfishKit
import LungfishWorkflow

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
