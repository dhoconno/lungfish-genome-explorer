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
/// | Packed | 0.6 - 10 | Colored bars with strand indicators |
/// | Base | < 0.6 | Geneious-style dots for matches, letters for mismatches |
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
    static let minReadPixels: CGFloat = 2

    /// Zoom tier thresholds.
    static let coverageThresholdBpPerPx: Double = 10
    static let baseThresholdBpPerPx: Double = 0.6

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
    static let matchDotColor = NSColor(white: 0.48, alpha: 0.82).cgColor
    /// Insertion indicator color (magenta).
    static let insertionColor = NSColor(red: 0.8, green: 0, blue: 0.8, alpha: 1.0).cgColor
    /// Deletion line color.
    static let deletionColor = NSColor.gray.cgColor
    /// Mismatch indicator color for packed mode (bright red).
    static let mismatchTickColor = NSColor(red: 0.9, green: 0.15, blue: 0.1, alpha: 1.0).cgColor
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
        rect: CGRect
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
        let yScale = (rect.height - 18) / CGFloat(maxDepth)

        context.saveGState()

        // Filled depth area
        context.setFillColor(forwardCoverageColor)
        let areaPath = CGMutablePath()
        areaPath.move(to: CGPoint(x: rect.minX, y: rect.maxY))
        for px in 0..<pixelWidth {
            let h = CGFloat(bins[px]) * yScale
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
            let h = CGFloat(bins[px]) * yScale
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
        ("Depth" as NSString).draw(at: CGPoint(x: legendRect.maxX + 4, y: rect.minY + 3), withAttributes: legendAttrs)

        // Summary labels
        let rightLabel = "max: \(maxDepth)x  mean: \(String(format: "%.1f", meanDepth))x" as NSString
        let rightSize = rightLabel.size(withAttributes: legendAttrs)
        rightLabel.draw(
            at: CGPoint(x: rect.maxX - rightSize.width - 4, y: rect.minY + 2),
            withAttributes: legendAttrs
        )

        let coveragePct = Double(stats.coveredBases) / Double(max(1, stats.span)) * 100
        let leftDetail = "\(Int(coveragePct.rounded()))% covered" as NSString
        leftDetail.draw(
            at: CGPoint(x: legendRect.maxX + 44, y: rect.minY + 3),
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
            let mid = (low + high) >> 1
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
        public var consensusMinDepth: Int = 8

        public init(
            showMismatches: Bool = true,
            showSoftClips: Bool = true,
            showIndels: Bool = true,
            consensusMaskingEnabled: Bool = false,
            consensusGapThreshold: Double = 0.9,
            consensusMinDepth: Int = 8
        ) {
            self.showMismatches = showMismatches
            self.showSoftClips = showSoftClips
            self.showIndels = showIndels
            self.consensusMaskingEnabled = consensusMaskingEnabled
            self.consensusGapThreshold = consensusGapThreshold
            self.consensusMinDepth = consensusMinDepth
        }
    }

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
        let ordered: [AlignedRead]
        if let prioritizedRegion {
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
            ordered = visible + nearby
        } else {
            ordered = sorted
        }

        let rowCap = maxRows.flatMap { $0 > 0 ? $0 : nil }
        var rowEndPixels = rowCap.map { [CGFloat](repeating: -1, count: $0) } ?? []
        var packed: [(Int, AlignedRead)] = []
        var overflow = 0

        for read in ordered {
            let startPx = frame.genomicToPixel(Double(read.position))
            let endPx = frame.genomicToPixel(Double(read.alignmentEnd))
            guard endPx - startPx >= minReadPixels else { continue }

            // Find first available row
            var placed = false
            if let rowCap {
                for row in 0..<rowCap {
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
            } else {
                for row in rowEndPixels.indices {
                    if startPx >= rowEndPixels[row] + 2 {
                        packed.append((row, read))
                        rowEndPixels[row] = endPx
                        placed = true
                        break
                    }
                }
                if !placed {
                    // Unlimited rows mode: allocate a new row when no existing row fits.
                    let newRow = rowEndPixels.count
                    rowEndPixels.append(endPx)
                    packed.append((newRow, read))
                    placed = true
                }
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
        verticalCompress: Bool = false,
        maxRowsLimit: Int? = nil,
        maskedPositions: Set<Int> = [],
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
            let y = rect.minY + CGFloat(row) * (readHeight + metrics.rowGap)
            let readWidth = endPx - startPx

            guard y + readHeight <= rect.maxY else { continue }
            guard readWidth >= minReadPixels else { continue }

            let alpha = mapqAlpha(read.mapq)
            let colors = cachedColors(isReverse: read.isReverse, mapq: read.mapq)

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

            // Draw mismatch tick marks using ASCII byte comparison (zero allocations)
            // Mismatch ticks are always shown when reference sequence is available
            if let refBytes {
                drawMismatchTicks(
                    read: read, frame: frame, refBytes: refBytes, referenceStart: referenceStart,
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
        verticalCompress: Bool = false,
        maxRowsLimit: Int? = nil,
        maskedPositions: Set<Int> = [],
        context: CGContext,
        rect: CGRect
    ) {
        context.saveGState()
        let metrics = layoutMetrics(verticalCompress: verticalCompress)
        let readHeight = metrics.baseReadHeight

        let pixelsPerBase = 1.0 / frame.scale
        let preferredFontSize = min(13, max(7, CGFloat(pixelsPerBase) * 0.95))
        // Keep glyphs inside compressed rows so mismatch letters remain legible.
        let fontSize = max(6, min(preferredFontSize, readHeight - 1.5))
        let font = CTFontCreateWithName("Menlo-Bold" as CFString, fontSize, nil)
        let refBytes: [UInt8]? = referenceSequence.map(uppercaseASCIIBytes)
        let cache = GlyphCache(font: font)

        // Pre-compute background colors for each strand to avoid per-read alloc
        let fwdBgTemplate = NSColor(red: 0.84, green: 0.89, blue: 0.95, alpha: 1.0).cgColor
        let revBgTemplate = NSColor(red: 0.95, green: 0.86, blue: 0.86, alpha: 1.0).cgColor

        for (row, read) in packedReads {
            let y = rect.minY + CGFloat(row) * (readHeight + metrics.rowGap)
            guard y + readHeight <= rect.maxY else { continue }

            let alpha = mapqAlpha(read.mapq)

            // Draw soft-clip background extensions
            if settings.showSoftClips {
                drawSoftClipExtensions(read: read, frame: frame, context: context, y: y, readHeight: readHeight, alpha: alpha)
            }

            // Draw read background
            let startPx = frame.genomicToPixel(Double(read.position))
            let endPx = frame.genomicToPixel(Double(read.alignmentEnd))
            let readRect = CGRect(x: startPx, y: y, width: endPx - startPx, height: readHeight)
            let bgAlpha = max(0.35, alpha * 0.72)
            let bgColor = (read.isReverse ? revBgTemplate : fwdBgTemplate).copy(alpha: bgAlpha)!
            context.setFillColor(bgColor)
            context.fill(readRect)
            let borderColor = (read.isReverse ? reverseReadStroke : forwardReadStroke).copy(alpha: max(0.45, alpha * 0.7))!
            context.setStrokeColor(borderColor)
            context.setLineWidth(0.6)
            context.stroke(readRect.insetBy(dx: 0.25, dy: 0.25))

            // Draw bases using CTFont glyph rendering
            drawReadBases(
                read: read,
                frame: frame,
                refBytes: refBytes,
                referenceStart: referenceStart,
                showMismatches: settings.showMismatches,
                maskedPositions: maskedPositions,
                context: context,
                y: y,
                readHeight: readHeight,
                font: font,
                glyphCache: cache,
                alpha: alpha
            )

            // Draw insertion markers
            if settings.showIndels {
                drawInsertionMarkers(read: read, frame: frame, context: context, y: y, readHeight: readHeight)
                drawDeletions(read: read, frame: frame, context: context, y: y + readHeight / 2, readHeight: readHeight)
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
            // Pre-compute glyphs for alphabetic bases (A-Z/a-z), covering RNA U and IUPAC codes.
            let chars = Array(UInt8(65)...UInt8(90)) + Array(UInt8(97)...UInt8(122))
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
        refBytes: [UInt8]?,
        referenceStart: Int,
        showMismatches: Bool = true,
        maskedPositions: Set<Int>,
        context: CGContext,
        y: CGFloat,
        readHeight: CGFloat,
        font: CTFont,
        glyphCache: GlyphCache,
        alpha: CGFloat
    ) {
        let pixelsPerBase = 1.0 / frame.scale
        let cellWidth = CGFloat(pixelsPerBase)
        let cache = glyphCache

        // Pre-compute alpha-modulated colors (5 base colors + match dot + soft clip variants)
        let matchDotAlpha = matchDotColor.copy(alpha: alpha)!
        let mismatchAlpha = max(alpha, 0.85)
        let colorA = baseA.copy(alpha: mismatchAlpha)!
        let colorT = baseT.copy(alpha: mismatchAlpha)!
        let colorC = baseC.copy(alpha: mismatchAlpha)!
        let colorG = baseG.copy(alpha: mismatchAlpha)!
        let colorN = baseN.copy(alpha: mismatchAlpha)!
        let mdMismatchPositions = read.mdTag.map { mismatchPositionsFromMDTag($0, readStart: read.position) }

        // Baseline offset: center glyph vertically using ascent/descent
        let ascent = CTFontGetAscent(font)
        let descent = CTFontGetDescent(font)
        let glyphHeight = ascent + descent
        let baselineY = y + (readHeight - glyphHeight) / 2 + ascent

        context.saveGState()

        // Fix glyph orientation in flipped view (isFlipped=true): CTFontDrawGlyphs renders
        // upside-down because the CTM flips glyph outlines. Text matrix is NOT part of the
        // graphics state, so we save/restore it manually.
        let savedTextMatrix = context.textMatrix
        context.textMatrix = CGAffineTransform(scaleX: 1, y: -1)

        // Use UTF-8 view for zero-allocation iteration
        var seqIterator = read.sequence.utf8.makeIterator()

        var refPos = read.position
        for op in read.cigar {
            switch op.op {
            case .match, .seqMatch, .seqMismatch:
                let explicitMatch = (op.op == .seqMatch)
                let explicitMismatch = (op.op == .seqMismatch)
                for _ in 0..<op.length {
                    guard let readByte = seqIterator.next() else { refPos += 1; continue }
                    guard !maskedPositions.contains(refPos) else {
                        refPos += 1
                        continue
                    }

                    let x = frame.genomicToPixel(Double(refPos))

                    // Uppercase: mask bit 5 (0x20) to convert lowercase ASCII to uppercase
                    let upperByte = readByte & 0xDF

                    // Always compare to reference when available — mismatches are
                    // always shown. The showMismatches toggle controls whether MATCHES
                    // appear as dots (true, default) or base letters (false).
                    let isMatch: Bool
                    if explicitMismatch {
                        isMatch = false
                    } else if explicitMatch {
                        isMatch = true
                    } else if let refBytes, refPos >= referenceStart {
                        let refIdx = refPos - referenceStart
                        if refIdx >= 0, refIdx < refBytes.count {
                            isMatch = isEquivalentBase(upperByte, refBytes[refIdx])
                        } else if let mdMismatchPositions {
                            isMatch = !mdMismatchPositions.contains(refPos)
                        } else {
                            // No reliable reference context for this base: show identity as letter.
                            isMatch = false
                        }
                    } else if let mdMismatchPositions {
                        isMatch = !mdMismatchPositions.contains(refPos)
                    } else {
                        // Without reference or MD tag, surface base identities directly.
                        isMatch = false
                    }

                    let glyph: CGGlyph
                    let glyphWidth: CGFloat
                    let color: CGColor

                    if !isMatch {
                        // Mismatches: ALWAYS shown as colored base letters
                        glyph = cache.glyphs[upperByte] ?? cache.dotGlyph
                        glyphWidth = cache.advances[upperByte]?.width ?? cache.dotAdvance.width
                        color = colorForByte(upperByte, a: colorA, t: colorT, c: colorC, g: colorG, n: colorN)
                    } else if showMismatches {
                        // Mismatch highlight mode (default): matches shown as dots
                        glyph = cache.dotGlyph
                        glyphWidth = cache.dotAdvance.width
                        color = matchDotAlpha
                    } else {
                        // Full sequence mode: matches shown as neutral-colored letters
                        glyph = cache.glyphs[upperByte] ?? cache.dotGlyph
                        glyphWidth = cache.advances[upperByte]?.width ?? cache.dotAdvance.width
                        color = matchDotAlpha
                    }

                    let drawX = x + (cellWidth - glyphWidth) / 2
                    context.setFillColor(color)
                    var g = glyph
                    var pos = CGPoint(x: drawX, y: baselineY)
                    CTFontDrawGlyphs(font, &g, &pos, 1, context)

                    refPos += 1
                }

            case .softClip:
                // Soft clips are rendered by drawSoftClipExtensions; here we just advance the query index
                for _ in 0..<op.length {
                    _ = seqIterator.next()
                }

            case .insertion:
                for _ in 0..<op.length {
                    _ = seqIterator.next()
                }

            case .deletion, .skip:
                refPos += op.length

            case .hardClip, .padding:
                break
            }
        }

        context.textMatrix = savedTextMatrix
        context.restoreGState()
    }

    /// Returns color for an ASCII byte (uppercase). Zero-allocation.
    private static func colorForByte(_ byte: UInt8, a: CGColor, t: CGColor, c: CGColor, g: CGColor, n: CGColor) -> CGColor {
        switch byte {
        case 65: return a  // A
        case 84, 85: return t  // T or U
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
        maskedPositions: Set<Int>,
        context: CGContext,
        y: CGFloat,
        readHeight: CGFloat
    ) {
        let pixelsPerBase = 1.0 / frame.scale
        context.setFillColor(mismatchTickColor)

        var lastMismatchPixel: Int = Int.min
        var seqIterator = read.sequence.utf8.makeIterator()
        var refPos = read.position

        for op in read.cigar {
            switch op.op {
            case .match, .seqMatch, .seqMismatch:
                let explicitMatch = (op.op == .seqMatch)
                let explicitMismatch = (op.op == .seqMismatch)
                for _ in 0..<op.length {
                    guard let readByte = seqIterator.next() else { refPos += 1; continue }
                    let upperRead = readByte & 0xDF

                    let refIdx = refPos - referenceStart
                    refPos += 1
                    let refPosition = refPos - 1
                    if maskedPositions.contains(refPosition) { continue }

                    if explicitMatch { continue }

                    let isMismatch: Bool
                    if explicitMismatch {
                        isMismatch = true
                    } else if refIdx >= 0, refIdx < refBytes.count {
                        let upperRef = refBytes[refIdx]
                        isMismatch = !isEquivalentBase(upperRead, upperRef)
                        guard upperRead != 0x4E && upperRef != 0x4E else { continue }
                    } else {
                        continue
                    }
                    guard isMismatch else { continue }
                    guard upperRead != 0x4E else { continue } // Skip ambiguous read base

                    let x = frame.genomicToPixel(Double(refPosition))
                    let px = Int(x)
                    guard px != lastMismatchPixel else { continue }
                    lastMismatchPixel = px

                    let tickWidth = max(1.0, min(CGFloat(pixelsPerBase), 3.0))
                    context.fill(CGRect(x: x, y: y, width: tickWidth, height: readHeight))
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
    private static func uppercaseASCIIBytes(_ s: String) -> [UInt8] {
        var bytes = Array(s.utf8)
        for i in bytes.indices {
            bytes[i] &= 0xDF
        }
        return bytes
    }

    /// Base-equivalence comparison that treats DNA/RNA thymine-uracil as a match.
    private static func isEquivalentBase(_ a: UInt8, _ b: UInt8) -> Bool {
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
    private static func drawMaskedColumns(
        _ maskedPositions: Set<Int>,
        frame: ReferenceFrame,
        context: CGContext,
        rect: CGRect
    ) {
        guard !maskedPositions.isEmpty else { return }

        let sorted = maskedPositions.sorted()
        var runStart = sorted[0]
        var runEnd = sorted[0]

        context.saveGState()
        context.setFillColor(NSColor.controlBackgroundColor.withAlphaComponent(0.9).cgColor)

        func fillRun(_ start: Int, _ end: Int) {
            let x0 = frame.genomicToPixel(Double(start))
            let x1 = frame.genomicToPixel(Double(end + 1))
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

    /// Intron (splice junction) indicator color — thin gray line, distinct from deletion.
    static let intronColor = NSColor(white: 0.5, alpha: 0.7).cgColor

    /// Draws deletion and intron (N/skip) connecting lines for a read.
    ///
    /// Deletions are shown as dashed dark gray lines; introns are shown as
    /// thin solid lighter lines (matching IGV convention for RNA-seq data).
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
            } else if op.op == .skip {
                // N operations (introns) — thin solid line, distinct from deletions
                let startPx = frame.genomicToPixel(Double(refPos))
                let endPx = frame.genomicToPixel(Double(refPos + op.length))
                context.setStrokeColor(intronColor)
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
        let pixelsPerBase = 1.0 / frame.scale
        let labelColor = NSColor(cgColor: insertionColor) ?? NSColor.magenta
        for ins in read.insertions {
            let x = frame.genomicToPixel(Double(ins.position))
            // Vertical line
            context.setFillColor(insertionColor)
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
                let label = labelText as NSString
                let attrs: [NSAttributedString.Key: Any] = [
                    .font: NSFont.monospacedSystemFont(ofSize: 7, weight: .semibold),
                    .foregroundColor: labelColor
                ]
                label.draw(at: CGPoint(x: x + 2, y: y + 0.5), withAttributes: attrs)
            }
        }
    }

    /// Returns a compact insertion label suitable for the current zoom level.
    private static func insertionLabel(for bases: String, pixelsPerBase: Double) -> String? {
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
    private static func drawOverflowIndicator(
        context: CGContext,
        rect: CGRect,
        overflow: Int,
        maxRowsLimit: Int?
    ) {
        let barHeight: CGFloat = 16
        let barRect = CGRect(x: rect.minX, y: rect.maxY - barHeight, width: rect.width, height: barHeight)

        // Gradient background
        context.setFillColor(NSColor(white: 0.88, alpha: 0.9).cgColor)
        context.fill(barRect)

        // Text
        let text: NSString
        if let maxRowsLimit {
            text = "+\(overflow) reads not shown (max \(maxRowsLimit) rows)" as NSString
        } else {
            text = "+\(overflow) reads not shown" as NSString
        }
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
    /// MAPQ 255 means "unavailable" per SAM spec — rendered at slightly reduced opacity.
    private static func mapqAlpha(_ mapq: UInt8) -> CGFloat {
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

    // MARK: - Intelligent Downsampling

    /// Downsamples reads for high-coverage regions to keep rendering fast.
    ///
    /// Uses reservoir sampling to maintain a representative subset.
    /// Preserves strand balance and read distribution across the region.
    ///
    /// - Parameters:
    ///   - reads: Input reads
    ///   - maxReads: Maximum reads to retain
    ///   - regionStart: Start of the visible region
    ///   - regionEnd: End of the visible region
    /// - Returns: Downsampled reads and the total count before sampling
    public static func downsample(
        _ reads: [AlignedRead],
        maxReads: Int = 5_000,
        regionStart: Int = 0,
        regionEnd: Int = Int.max
    ) -> (reads: [AlignedRead], totalCount: Int) {
        guard reads.count > maxReads else { return (reads, reads.count) }

        let totalCount = reads.count

        // Split by strand to maintain balance
        var forward: [AlignedRead] = []
        var reverse: [AlignedRead] = []
        forward.reserveCapacity(reads.count / 2)
        reverse.reserveCapacity(reads.count / 2)
        for read in reads {
            if read.isReverse {
                reverse.append(read)
            } else {
                forward.append(read)
            }
        }

        // Allocate proportionally to each strand
        let fwdShare = Int(Double(maxReads) * Double(forward.count) / Double(totalCount))
        let revShare = maxReads - fwdShare

        let sampledFwd = reservoirSample(forward, count: fwdShare)
        let sampledRev = reservoirSample(reverse, count: revShare)

        var result = sampledFwd + sampledRev
        result.sort { $0.position < $1.position }
        return (result, totalCount)
    }

    /// Reservoir sampling: picks `count` random elements from `source`.
    private static func reservoirSample(_ source: [AlignedRead], count: Int) -> [AlignedRead] {
        guard count > 0 else { return [] }
        guard source.count > count else { return source }

        var reservoir = Array(source.prefix(count))
        for i in count..<source.count {
            let j = Int.random(in: 0...i)
            if j < count {
                reservoir[j] = source[i]
            }
        }
        return reservoir
    }

    // MARK: - Base Quality Heatmap

    /// Draws per-base quality shading on a base-level read.
    ///
    /// Low quality bases are shaded yellow/red, high quality bases are transparent.
    /// Used when `ReadColorMode.baseQuality` is active.
    static func drawBaseQualityOverlay(
        read: AlignedRead,
        frame: ReferenceFrame,
        context: CGContext,
        y: CGFloat,
        readHeight: CGFloat
    ) {
        guard !read.qualities.isEmpty else { return }
        let pixelsPerBase = 1.0 / frame.scale
        let cellWidth = CGFloat(pixelsPerBase)

        var byteIndex = 0
        var refPos = read.position

        for op in read.cigar {
            switch op.op {
            case .match, .seqMatch, .seqMismatch:
                for _ in 0..<op.length {
                    guard byteIndex < read.qualities.count else { refPos += 1; byteIndex += 1; continue }
                    let q = read.qualities[byteIndex]
                    byteIndex += 1

                    let x = frame.genomicToPixel(Double(refPos))
                    refPos += 1

                    // Quality threshold: highlight bases below Q20
                    if q < 20 {
                        let intensity = CGFloat(20 - q) / 20.0 * 0.4
                        context.setFillColor(CGColor(red: 1.0, green: 0.8, blue: 0.0, alpha: intensity))
                        context.fill(CGRect(x: x, y: y, width: cellWidth, height: readHeight))
                    }
                }

            case .insertion, .softClip:
                for _ in 0..<op.length {
                    byteIndex += 1
                }

            case .deletion, .skip:
                refPos += op.length

            case .hardClip, .padding:
                break
            }
        }
    }

    // MARK: - Split-Read Visualization

    /// Draws connecting lines between a primary alignment and its supplementary alignments (SA tag).
    ///
    /// These lines indicate chimeric/split-read alignments, commonly seen at structural
    /// variant breakpoints. Lines connect from the soft-clipped end of the primary read
    /// to the supplementary alignment positions.
    static func drawSplitReadIndicators(
        read: AlignedRead,
        frame: ReferenceFrame,
        context: CGContext,
        y: CGFloat,
        readHeight: CGFloat,
        currentChromosome: String
    ) {
        let supps = read.parsedSupplementaryAlignments
        guard !supps.isEmpty else { return }

        let readMidY = y + readHeight / 2

        context.saveGState()
        context.setStrokeColor(splitReadColor)
        context.setLineWidth(1.5)
        context.setLineDash(phase: 0, lengths: [3, 2])

        for supp in supps {
            guard supp.chromosome == currentChromosome else { continue }

            // Draw arc connecting primary and supplementary
            let primaryEndPx: CGFloat
            if read.isReverse {
                primaryEndPx = frame.genomicToPixel(Double(read.position))
            } else {
                primaryEndPx = frame.genomicToPixel(Double(read.alignmentEnd))
            }

            let suppStartPx = frame.genomicToPixel(Double(supp.position))

            // Arc height based on distance
            let dist = abs(suppStartPx - primaryEndPx)
            let arcHeight = min(dist * 0.15, 20)

            let path = CGMutablePath()
            path.move(to: CGPoint(x: primaryEndPx, y: readMidY))

            let midX = (primaryEndPx + suppStartPx) / 2
            path.addQuadCurve(
                to: CGPoint(x: suppStartPx, y: readMidY),
                control: CGPoint(x: midX, y: readMidY - arcHeight)
            )

            context.addPath(path)
            context.strokePath()

            // Small triangle at supplementary end
            let triSize: CGFloat = 3
            let triPath = CGMutablePath()
            if suppStartPx > primaryEndPx {
                triPath.move(to: CGPoint(x: suppStartPx, y: readMidY))
                triPath.addLine(to: CGPoint(x: suppStartPx - triSize, y: readMidY - triSize))
                triPath.addLine(to: CGPoint(x: suppStartPx - triSize, y: readMidY + triSize))
            } else {
                triPath.move(to: CGPoint(x: suppStartPx, y: readMidY))
                triPath.addLine(to: CGPoint(x: suppStartPx + triSize, y: readMidY - triSize))
                triPath.addLine(to: CGPoint(x: suppStartPx + triSize, y: readMidY + triSize))
            }
            triPath.closeSubpath()
            context.setFillColor(splitReadColor)
            context.addPath(triPath)
            context.fillPath()
        }

        context.setLineDash(phase: 0, lengths: [])
        context.restoreGState()
    }

    // MARK: - Paired-End Linking

    /// Draws connecting lines between mate pairs that are both visible in the viewport.
    ///
    /// Finds reads with the same name and draws a thin line connecting them,
    /// which helps visualize fragment structure and insert sizes.
    static func drawMatePairLinks(
        packedReads: [(row: Int, read: AlignedRead)],
        frame: ReferenceFrame,
        context: CGContext,
        rect: CGRect,
        readHeight: CGFloat
    ) {
        // Build lookup of read name -> (row, read) for paired reads
        var nameLookup: [String: [(row: Int, read: AlignedRead)]] = [:]
        for (row, read) in packedReads where read.isPaired {
            nameLookup[read.name, default: []].append((row, read))
        }

        context.saveGState()
        context.setStrokeColor(NSColor(white: 0.6, alpha: 0.4).cgColor)
        context.setLineWidth(0.5)

        for (_, mates) in nameLookup where mates.count == 2 {
            let (row1, read1) = mates[0]
            let (row2, read2) = mates[1]

            // Only draw if both are on the same row (typical for properly paired reads)
            guard row1 == row2 else { continue }

            let y = rect.minY + CGFloat(row1) * (readHeight + rowGap) + readHeight / 2

            let end1 = frame.genomicToPixel(Double(read1.alignmentEnd))
            let start2 = frame.genomicToPixel(Double(read2.position))

            // Draw connecting line between mates
            let left = min(end1, start2)
            let right = max(end1, start2)
            guard right - left > 2 else { continue } // Skip if overlapping

            context.move(to: CGPoint(x: left, y: y))
            context.addLine(to: CGPoint(x: right, y: y))
            context.strokePath()
        }

        context.restoreGState()
    }

    // MARK: - Base at Position Helper

    /// Returns a sort key for the base at a reference position in a read.
    /// Used for base-at-position sorting to investigate variants.
    private static func baseAtRefPos(_ read: AlignedRead, pos: Int) -> UInt8 {
        guard pos >= read.position, pos < read.alignmentEnd else { return 255 }
        let seqBytes = Array(read.sequence.utf8)
        var byteIndex = 0
        var refPos = read.position
        for op in read.cigar {
            switch op.op {
            case .match, .seqMatch, .seqMismatch:
                for _ in 0..<op.length {
                    if refPos == pos, byteIndex < seqBytes.count {
                        return seqBytes[byteIndex] & 0xDF // uppercase
                    }
                    refPos += 1
                    byteIndex += 1
                }
            case .insertion, .softClip:
                byteIndex += op.length
            case .deletion, .skip:
                refPos += op.length
            case .hardClip, .padding:
                break
            }
        }
        return 255 // Position not covered by this read
    }
}

// MARK: - ReferenceFrame Extension

extension ReferenceFrame {

    /// Converts a genomic position to a pixel X coordinate.
    func genomicToPixel(_ position: Double) -> CGFloat {
        CGFloat((position - start) / scale)
    }
}
