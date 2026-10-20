// VariantTrackRenderer.swift - Variant summary bar and genotype row rendering
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import CoreGraphics
import Foundation
import LungfishCore
import LungfishIO

// MARK: - VariantTrackRenderer

/// Static renderer for variant tracks in the genome viewer.
///
/// Provides two visualization modes:
/// 1. **Summary bar** — a histogram showing variant density and type at each position
/// 2. **Per-sample genotype rows** — IGV-inspired colored cells for each sample
///
/// Genotype rows support vertical scrolling for large sample counts (e.g. 451 samples).
/// Only visible rows within the clip region are rendered for performance.
///
/// Rendering is split into static methods for testability and reuse. They draw a
/// `ViewerFigureFrame` with the colours of a `ViewerFigureTheme` and keep no state.
public enum VariantTrackRenderer {

    // MARK: - Layout Constants

    /// Default height of the variant summary bar (used when no state is available).
    static let defaultSummaryBarHeight: CGFloat = 20

    /// Spacing between the summary bar and the first sample row.
    public static let summaryToRowGap: CGFloat = 2

    /// Minimum pixels per variant to draw individual markers (otherwise use density).
    static let minPixelsPerVariant: CGFloat = 1

    /// Width of the scroll indicator track.
    private static let scrollIndicatorWidth: CGFloat = 6
    /// Fallback area reserved for sample labels when no sample strings are available yet.
    private static let sampleLabelFallbackWidth: CGFloat = 150
    /// Visual spacing between sample label area and genotype data area.
    public static let sampleLabelToDataMargin: CGFloat = 12

    // The gutter, data area, border, separator, margin and scroll colours are the theme roles
    // `variantGutterBackground` to `variantScrollThumb`, and the gutter width cache is a
    // `VariantSampleGutterCache` the caller owns.

    // MARK: - Color Palette

    /// Converts a ThemeColor to CGColor.
    private static func cgColor(from tc: ThemeColor) -> CGColor {
        CGColor(red: tc.r, green: tc.g, blue: tc.b, alpha: 1.0)
    }

    /// Returns the resolved theme from state, defaulting to modern.
    private static func resolveTheme(_ state: SampleDisplayState?) -> VariantColorTheme {
        guard let name = state?.colorThemeName else { return .modern }
        return VariantColorTheme.named(name)
    }

    // MARK: - Public API

    /// Returns the total height of all genotype rows (for scroll bounds calculation).
    ///
    /// - Parameters:
    ///   - sampleCount: Number of samples to display
    ///   - scale: Current zoom level in bp/pixel
    ///   - state: Display state controlling row visibility and height mode
    /// - Returns: Total height in pixels for all sample rows
    public static func totalGenotypeHeight(
        sampleCount: Int,
        state: SampleDisplayState
    ) -> CGFloat {
        guard state.showGenotypeRows && sampleCount > 0 else { return 0 }
        return CGFloat(sampleCount) * state.rowHeight
    }

    /// Returns the total height needed for variant rendering including summary bar.
    /// This reports the full content height (all rows), not the visible/clipped height.
    public static func totalHeight(
        sampleCount: Int,
        state: SampleDisplayState
    ) -> CGFloat {
        var height: CGFloat = 0
        if state.showSummaryBar {
            height += state.summaryBarHeight
        }
        if state.showGenotypeRows && sampleCount > 0 {
            if height > 0 { height += summaryToRowGap }
            height += CGFloat(sampleCount) * state.rowHeight
        }
        return height
    }

    /// Returns the summary bar height from display state, or the default.
    public static func summaryBarHeight(state: SampleDisplayState?) -> CGFloat {
        state?.summaryBarHeight ?? defaultSummaryBarHeight
    }

    /// Computes the width of the sample label gutter.
    /// If an override is set, returns it directly (clamped to valid range). A `cache` measured
    /// for the same samples and row height gives its width without measuring the labels again.
    public static func sampleLabelGutterWidth(
        samples: [String],
        sampleDisplayNames: [String: String],
        rowHeight: CGFloat,
        override: CGFloat? = nil,
        cache: VariantSampleGutterCache? = nil
    ) -> CGFloat {
        if let override {
            return max(40, min(400, override))
        }
        guard !samples.isEmpty else { return sampleLabelFallbackWidth }

        // Return the cached value when samples and row height haven't changed
        if let cached = cache?.width(samples: samples, rowHeight: rowHeight) {
            return cached
        }

        let font = ViewerFigureTrackText.font(.system, size: Double(max(7, min(rowHeight - 2, 12))))
        var maxWidth: CGFloat = 0
        for sample in samples {
            let label = sampleDisplayNames[sample] ?? sample
            let width = CGFloat(ViewerFigureTrackText.width(label, font: font))
            if width > maxWidth { maxWidth = width }
        }
        return max(24, ceil(maxWidth) + 8)
    }

    // MARK: - Summary Bar Rendering

    /// Draws the variant summary bar showing variant density and type distribution.
    ///
    /// Uses `frame.leadingInset` and `frame.dataPixelWidth` to position content
    /// to the right of the sample name gutter, aligned with all other genomic content.
    ///
    /// - Parameters:
    ///   - variants: Variant annotations in the visible region
    ///   - frame: The reference frame for coordinate mapping (includes leadingInset)
    ///   - context: The graphics context to draw into
    ///   - yOffset: Y position for the top of the summary bar
    public static func drawSummaryBar(
        variants: [SequenceAnnotation],
        frame: ViewerFigureFrame,
        context: CGContext,
        figureTheme: ViewerFigureTheme,
        yOffset: CGFloat,
        barHeight: CGFloat = 20,
        theme: VariantColorTheme = .modern
    ) {
        guard !variants.isEmpty else { return }

        let pixelWidth = frame.pixelWidth
        guard pixelWidth > 0 else { return }

        let snpCG = cgColor(from: theme.snp)
        let insCG = cgColor(from: theme.ins)
        let delCG = cgColor(from: theme.del)
        let complexCG = cgColor(from: theme.complex)

        context.saveGState()
        defer { context.restoreGState() }

        let inset = frame.leadingInset
        let dataPixels = max(1, Int(frame.dataPixelWidth))

        // Gutter background (opaque, matches genotype row gutter)
        if inset > 0 {
            context.setFillColor(figureTheme.color(.variantGutterBackground).cgColor)
            context.fill(CGRect(x: 0, y: yOffset, width: inset, height: barHeight))
        }

        // Data area background
        context.setFillColor(figureTheme.color(.variantDataBackground).cgColor)
        context.fill(CGRect(x: inset, y: yOffset, width: frame.dataPixelWidth, height: barHeight))

        // Bin variants into per-pixel buckets in the data area
        var snpCounts = [Int](repeating: 0, count: dataPixels)
        var insCounts = [Int](repeating: 0, count: dataPixels)
        var delCounts = [Int](repeating: 0, count: dataPixels)
        var otherCounts = [Int](repeating: 0, count: dataPixels)

        let dataScale = Double(dataPixels) / (frame.end - frame.start)

        for variant in variants {
            let startBin = Int((Double(variant.start) - frame.start) * dataScale)
            let endBin = Int((Double(variant.end) - frame.start) * dataScale)
            let px = max(0, min(startBin, dataPixels - 1))
            let pxEnd = max(px, min(endBin, dataPixels - 1))

            let vtype = variant.qualifiers["variant_type"]?.values.first ?? ""

            for p in px...pxEnd {
                switch vtype {
                case "SNP": snpCounts[p] += 1
                case "INS": insCounts[p] += 1
                case "DEL": delCounts[p] += 1
                default: otherCounts[p] += 1
                }
            }
        }

        // Find max count for normalization
        var computedMax = 1
        for px in 0..<dataPixels {
            let total = snpCounts[px] + insCounts[px] + delCounts[px] + otherCounts[px]
            if total > computedMax { computedMax = total }
        }
        let maxCount = computedMax
        let barBottom = yOffset + barHeight
        let insetInt = Int(ceil(inset))

        // Draw stacked bars per pixel in data area
        for px in 0..<dataPixels {
            let total = snpCounts[px] + insCounts[px] + delCounts[px] + otherCounts[px]
            guard total > 0 else { continue }

            let normalizedHeight = (CGFloat(total) / CGFloat(maxCount)) * (barHeight - 2)
            var currentY = barBottom - 1  // 1px margin at bottom

            let segments: [(Int, CGColor)] = [
                (snpCounts[px], snpCG),
                (insCounts[px], insCG),
                (delCounts[px], delCG),
                (otherCounts[px], complexCG),
            ]

            for (count, color) in segments {
                guard count > 0 else { continue }
                let segHeight = (CGFloat(count) / CGFloat(total)) * normalizedHeight
                context.setFillColor(color)
                context.fill(CGRect(x: CGFloat(px + insetInt), y: currentY - segHeight, width: 1, height: segHeight))
                currentY -= segHeight
            }
        }

        // Bottom border line
        context.setStrokeColor(figureTheme.color(.variantSummaryBorder).cgColor)
        context.setLineWidth(0.5)
        context.move(to: CGPoint(x: 0, y: barBottom))
        context.addLine(to: CGPoint(x: CGFloat(pixelWidth), y: barBottom))
        context.strokePath()

        // Label — draw in gutter area if available, otherwise at left edge of data
        let label = "\(variants.count) variants"
        let font = ViewerFigureTrackText.font(.systemMedium, size: 8)
        let labelWidth = CGFloat(ViewerFigureTrackText.width(label, font: font))
        let labelHeight = CGFloat(ViewerFigureTrackText.boxHeight(font))
        let labelX: CGFloat = inset > labelWidth + 8 ? 4 : inset + 4
        ViewerFigureTrackText.draw(
            label, font: font, color: figureTheme.color(.secondaryLabel).cgColor,
            topLeft: CGPoint(x: labelX, y: yOffset + (barHeight - labelHeight) / 2), in: context
        )
    }

    // MARK: - Genotype Row Rendering

    /// Draws per-sample genotype rows below the summary bar with scroll support.
    ///
    /// Only renders rows visible within the available height, based on scroll offset.
    /// Draws a scroll indicator when content exceeds the visible area.
    ///
    /// - Parameters:
    ///   - genotypeData: Pre-fetched genotype data for the visible region
    ///   - frame: The reference frame for coordinate mapping
    ///   - context: The graphics context to draw into
    ///   - yOffset: Y position for the top of the first sample row
    ///   - state: Display state controlling appearance
    ///   - sampleDisplayNames: Optional per-sample display labels
    ///   - scrollOffset: Vertical scroll offset in pixels (0 = top)
    ///   - availableHeight: Maximum height available for rendering genotype rows
    ///   - gutterCache: The caller's measured gutter width, used when it holds these samples
    public static func drawGenotypeRows(
        genotypeData: GenotypeDisplayData,
        frame: ViewerFigureFrame,
        context: CGContext,
        figureTheme: ViewerFigureTheme,
        yOffset: CGFloat,
        state: SampleDisplayState,
        useHaploidAFShading: Bool = false,
        sampleDisplayNames: [String: String] = [:],
        scrollOffset: CGFloat = 0,
        availableHeight: CGFloat = .greatestFiniteMagnitude,
        theme: VariantColorTheme = .modern,
        gutterCache: VariantSampleGutterCache? = nil
    ) {
        let samples = genotypeData.sampleNames
        guard !samples.isEmpty, !genotypeData.sites.isEmpty else { return }

        let rowH = state.rowHeight
        guard rowH > 0 else { return }

        let showLabels = rowH >= 8
        let totalRows = samples.count
        let totalContentHeight = CGFloat(totalRows) * rowH
        guard totalContentHeight > 0 else { return }

        // Normalize unbounded/invalid values so row-range math remains safe.
        let effectiveAvailableHeight: CGFloat = {
            guard availableHeight.isFinite, availableHeight > 0 else { return totalContentHeight }
            return min(availableHeight, totalContentHeight)
        }()
        let maxScrollOffset = max(0, totalContentHeight - effectiveAvailableHeight)
        let effectiveScrollOffset: CGFloat = {
            guard scrollOffset.isFinite else { return 0 }
            return min(max(scrollOffset, 0), maxScrollOffset)
        }()

        context.saveGState()
        defer { context.restoreGState() }

        // Clip to available area so rows don't overflow
        let clipRect = CGRect(x: 0, y: yOffset, width: CGFloat(frame.pixelWidth), height: effectiveAvailableHeight)
        context.clip(to: clipRect)

        let inset = frame.leadingInset
        let labelGutterWidth = showLabels
            ? sampleLabelGutterWidth(
                samples: samples, sampleDisplayNames: sampleDisplayNames, rowHeight: rowH,
                override: state.sampleGutterWidthOverride, cache: gutterCache
            )
            : 0

        // Compute visible row range from scroll offset
        let firstVisibleRow: Int
        let lastVisibleRow: Int
        if effectiveAvailableHeight >= totalContentHeight {
            firstVisibleRow = 0
            lastVisibleRow = totalRows - 1
        } else {
            firstVisibleRow = max(0, Int(floor(effectiveScrollOffset / rowH)))
            let visibleRowCount = max(1, Int(ceil(effectiveAvailableHeight / rowH)) + 1)
            lastVisibleRow = min(totalRows - 1, firstVisibleRow + visibleRowCount)
        }

        guard firstVisibleRow <= lastVisibleRow else { return }

        // Font and colours hoisted outside the per-row loop to avoid allocating them for each
        // of the 451+ sample rows.
        let labelFont = ViewerFigureTrackText.font(.system, size: Double(max(7, min(rowH - 2, 12))))
        let labelColor = figureTheme.color(.label).cgColor
        let gutterBackground = figureTheme.color(.variantGutterBackground).cgColor
        let labelMargin = figureTheme.color(.variantLabelMargin).cgColor
        let gutterSeparator = figureTheme.color(.variantGutterSeparator).cgColor
        let rowSeparator = figureTheme.color(.variantRowSeparator).cgColor

        // Draw genotype cells for each visible sample
        for sampleIdx in firstVisibleRow...lastVisibleRow {
            let sampleName = samples[sampleIdx]
            let rowY = yOffset + CGFloat(sampleIdx) * rowH - effectiveScrollOffset

            // Draw genotype cell for each variant site (BEFORE labels so labels overlay)
            // Uses frame.screenPosition() which includes leadingInset, aligning cells
            // with all other genomic content (sequence, annotations, ruler).
            for site in genotypeData.sites {
                // Skip sites where this sample has no data (from a different source VCF)
                guard let call = site.genotypes[sampleName] else { continue }
                let color = colorForCall(
                    call,
                    theme: theme,
                    haploidAF: useHaploidAFShading ? site.sampleAlleleFractions[sampleName] : nil
                )

                let startPx = frame.screenPosition(for: Double(site.position))
                let endPx = frame.screenPosition(for: Double(site.position + max(1, site.ref.count)))
                let cellWidth = max(1, endPx - startPx)
                let clippedStart = max(inset, startPx)
                let clippedEnd = min(CGFloat(frame.pixelWidth), startPx + cellWidth)
                guard clippedEnd > clippedStart else { continue }

                context.setFillColor(color)
                context.fill(CGRect(
                    x: clippedStart,
                    y: rowY,
                    width: clippedEnd - clippedStart,
                    height: rowH
                ))
            }

            // Sample name label drawn ON TOP of genotype cells (when rows are tall enough)
            if showLabels {
                let label = sampleDisplayNames[sampleName] ?? sampleName
                // Fully opaque gutter background to cover any variant cells beneath
                context.setFillColor(gutterBackground)
                context.fill(CGRect(x: 0, y: rowY, width: labelGutterWidth, height: rowH))
                // Opaque margin between labels and data
                context.setFillColor(labelMargin)
                context.fill(CGRect(x: labelGutterWidth, y: rowY, width: sampleLabelToDataMargin, height: rowH))
                // Vertical separator
                context.setStrokeColor(gutterSeparator)
                context.setLineWidth(0.5)
                let sepX = labelGutterWidth + sampleLabelToDataMargin / 2
                context.move(to: CGPoint(x: sepX, y: rowY))
                context.addLine(to: CGPoint(x: sepX, y: rowY + rowH))
                context.strokePath()
                // Draw label truncated to gutter width
                let labelRect = CGRect(x: 2, y: rowY + 1, width: labelGutterWidth - 4, height: rowH - 2)
                ViewerFigureTrackText.drawTruncatingTail(label, font: labelFont, color: labelColor, in: labelRect, context: context)
            }

            // Row separator when rows are tall enough
            if rowH >= 4 && sampleIdx < totalRows - 1 {
                context.setStrokeColor(rowSeparator)
                context.setLineWidth(0.5)
                let sepY = rowY + rowH
                context.move(to: CGPoint(x: 0, y: sepY))
                context.addLine(to: CGPoint(x: CGFloat(frame.pixelWidth), y: sepY))
                context.strokePath()
            }
        }

        // Draw scroll indicator if content exceeds visible area
        if totalContentHeight > effectiveAvailableHeight {
            drawScrollIndicator(
                context: context,
                figureTheme: figureTheme,
                x: CGFloat(frame.pixelWidth) - scrollIndicatorWidth - 2,
                yOffset: yOffset,
                availableHeight: effectiveAvailableHeight,
                totalContentHeight: totalContentHeight,
                scrollOffset: effectiveScrollOffset
            )
        }
    }

    // MARK: - Scroll Indicator

    /// Draws a subtle scrollbar indicator showing position within the full sample list.
    private static func drawScrollIndicator(
        context: CGContext,
        figureTheme: ViewerFigureTheme,
        x: CGFloat,
        yOffset: CGFloat,
        availableHeight: CGFloat,
        totalContentHeight: CGFloat,
        scrollOffset: CGFloat
    ) {
        // Track background
        let trackRect = CGRect(x: x, y: yOffset, width: scrollIndicatorWidth, height: availableHeight)
        context.setFillColor(figureTheme.color(.variantScrollTrack).cgColor)
        context.fill(trackRect)

        // Thumb
        let thumbRatio = availableHeight / totalContentHeight
        let thumbHeight = max(20, availableHeight * thumbRatio)
        let scrollRange = totalContentHeight - availableHeight
        let thumbOffset = scrollRange > 0
            ? (scrollOffset / scrollRange) * (availableHeight - thumbHeight)
            : 0

        let thumbRect = CGRect(
            x: x + 1,
            y: yOffset + thumbOffset,
            width: scrollIndicatorWidth - 2,
            height: thumbHeight
        )
        context.setFillColor(figureTheme.color(.variantScrollThumb).cgColor)
        context.fill(thumbRect)
    }

    // MARK: - Color Helpers

    /// Pre-computed haploid AF color lookup table (256 quantized entries).
    private static let haploidAFColorLUT: [CGColor] = {
        typealias RGBStop = (position: CGFloat, color: (r: CGFloat, g: CGFloat, b: CGFloat))
        let stops: [RGBStop] = [
            (0.00, (0.97, 0.97, 0.995)),
            (0.15, (0.80, 0.86, 1.00)),
            (0.45, (0.57, 0.50, 0.94)),
            (0.75, (0.35, 0.29, 0.73)),
            (1.00, (0.08, 0.08, 0.10)),
        ]
        return (0..<256).map { i in
            let clamped = CGFloat(i) / 255.0
            var r: CGFloat = stops[0].color.r
            var g: CGFloat = stops[0].color.g
            var b: CGFloat = stops[0].color.b
            for idx in 1..<stops.count {
                let left = stops[idx - 1]
                let right = stops[idx]
                guard clamped <= right.position else { continue }
                let span = max(0.0001, right.position - left.position)
                let t = (clamped - left.position) / span
                r = left.color.r + (right.color.r - left.color.r) * t
                g = left.color.g + (right.color.g - left.color.g) * t
                b = left.color.b + (right.color.b - left.color.b) * t
                break
            }
            return CGColor(red: r, green: g, blue: b, alpha: 1.0)
        }
    }()

    /// Maps haploid alternate allele fraction to a color ramp:
    /// AF≈0 -> near white, intermediate -> blue/purple, AF≈1 -> near black.
    /// Uses a 256-entry LUT to avoid per-call CGColor allocation.
    static func haploidAFColor(_ af: Double) -> CGColor {
        let idx = max(0, min(255, Int((max(0.0, min(1.0, af)) * 255).rounded())))
        return haploidAFColorLUT[idx]
    }

    /// Returns the CGColor for a genotype call using the given theme.
    private static func colorForCall(_ call: GenotypeDisplayCall, theme: VariantColorTheme, haploidAF: Double? = nil) -> CGColor {
        if let af = haploidAF, call == .het || call == .homAlt {
            return haploidAFColor(af)
        }
        return cgColor(from: call.themeColor(from: theme))
    }

    /// Returns the CGColor for a genotype call, applying impact-based coloring
    /// for non-synonymous variants that carry alt alleles.
    private static func colorForCallWithImpact(_ call: GenotypeDisplayCall, impact: VariantImpact?, theme: VariantColorTheme) -> CGColor {
        // Only color alt-carrying genotypes differently; homRef and noCall keep standard colors
        guard call == .het || call == .homAlt else { return colorForCall(call, theme: theme) }
        guard let impact, impact != .synonymous, impact != .unknown else { return colorForCall(call, theme: theme) }

        switch impact {
        case .missense:
            return cgColor(from: call == .het ? theme.missenseHet : theme.missenseHomAlt)
        case .nonsense:
            return cgColor(from: call == .het ? theme.nonsenseHet : theme.nonsenseHomAlt)
        case .frameshift:
            return cgColor(from: call == .het ? theme.frameshiftHet : theme.frameshiftHomAlt)
        case .spliceRegion:
            return cgColor(from: call == .het ? theme.missenseHet : theme.missenseHomAlt)
        case .synonymous, .unknown:
            return colorForCall(call, theme: theme)
        }
    }

    /// Returns the CGColor for a variant type string using the given theme.
    static func colorForVariantType(_ vtype: String, theme: VariantColorTheme = .modern) -> CGColor {
        switch vtype {
        case "SNP":     return cgColor(from: theme.snp)
        case "INS":     return cgColor(from: theme.ins)
        case "DEL":     return cgColor(from: theme.del)
        case "MNP":     return cgColor(from: theme.mnp)
        default:        return cgColor(from: theme.complex)
        }
    }
}
