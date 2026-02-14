// VariantTrackRenderer.swift - Variant summary bar and genotype row rendering
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import LungfishCore
import LungfishIO
import os.log

/// Logger for variant rendering operations
private let variantRendererLogger = Logger(subsystem: "com.lungfish.browser", category: "VariantRenderer")

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
/// Rendering is split into static methods for testability and reuse.
@MainActor
public enum VariantTrackRenderer {

    // MARK: - Layout Constants

    /// Default height of the variant summary bar (used when no state is available).
    static let defaultSummaryBarHeight: CGFloat = 20

    /// Spacing between the summary bar and the first sample row.
    static let summaryToRowGap: CGFloat = 2

    /// Minimum pixels per variant to draw individual markers (otherwise use density).
    static let minPixelsPerVariant: CGFloat = 1

    /// Width of the scroll indicator track.
    private static let scrollIndicatorWidth: CGFloat = 6
    /// Horizontal area reserved for sample labels.
    private static let sampleLabelWidth: CGFloat = 150
    /// Visual spacing between sample label area and genotype data area.
    private static let sampleLabelToDataMargin: CGFloat = 12

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

    // MARK: - Summary Bar Rendering

    /// Draws the variant summary bar showing variant density and type distribution.
    ///
    /// - Parameters:
    ///   - variants: Variant annotations in the visible region
    ///   - frame: The reference frame for coordinate mapping
    ///   - context: The graphics context to draw into
    ///   - yOffset: Y position for the top of the summary bar
    public static func drawSummaryBar(
        variants: [SequenceAnnotation],
        frame: ReferenceFrame,
        context: CGContext,
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

        // Background
        context.setFillColor(CGColor(red: 0.95, green: 0.95, blue: 0.95, alpha: 1.0))
        context.fill(CGRect(x: 0, y: yOffset, width: CGFloat(pixelWidth), height: barHeight))

        // Bin variants into per-pixel buckets by type
        var snpCounts = [Int](repeating: 0, count: pixelWidth)
        var insCounts = [Int](repeating: 0, count: pixelWidth)
        var delCounts = [Int](repeating: 0, count: pixelWidth)
        var otherCounts = [Int](repeating: 0, count: pixelWidth)

        for variant in variants {
            let startPx = Int(frame.screenPosition(for: Double(variant.start)))
            let endPx = Int(frame.screenPosition(for: Double(variant.end)))
            let px = max(0, min(startPx, pixelWidth - 1))
            let pxEnd = max(px, min(endPx, pixelWidth - 1))
            guard pxEnd < pixelWidth else { continue }

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
        for px in 0..<pixelWidth {
            let total = snpCounts[px] + insCounts[px] + delCounts[px] + otherCounts[px]
            if total > computedMax { computedMax = total }
        }
        let maxCount = computedMax
        let barBottom = yOffset + barHeight

        // Draw stacked bars per pixel
        for px in 0..<pixelWidth {
            let total = snpCounts[px] + insCounts[px] + delCounts[px] + otherCounts[px]
            guard total > 0 else { continue }

            let normalizedHeight = (CGFloat(total) / CGFloat(maxCount)) * (barHeight - 2)
            var currentY = barBottom - 1  // 1px margin at bottom

            // Draw stacked from bottom: SNP, INS, DEL, other
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
                context.fill(CGRect(x: CGFloat(px), y: currentY - segHeight, width: 1, height: segHeight))
                currentY -= segHeight
            }
        }

        // Bottom border line
        context.setStrokeColor(CGColor(red: 0.8, green: 0.8, blue: 0.8, alpha: 1.0))
        context.setLineWidth(0.5)
        context.move(to: CGPoint(x: 0, y: barBottom))
        context.addLine(to: CGPoint(x: CGFloat(pixelWidth), y: barBottom))
        context.strokePath()

        // Label
        let label = "\(variants.count) variants" as NSString
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 8, weight: .medium),
            .foregroundColor: NSColor.secondaryLabelColor,
        ]
        let labelSize = label.size(withAttributes: attrs)
        label.draw(
            at: CGPoint(x: 4, y: yOffset + (barHeight - labelSize.height) / 2),
            withAttributes: attrs
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
    public static func drawGenotypeRows(
        genotypeData: GenotypeDisplayData,
        frame: ReferenceFrame,
        context: CGContext,
        yOffset: CGFloat,
        state: SampleDisplayState,
        sampleDisplayNames: [String: String] = [:],
        scrollOffset: CGFloat = 0,
        availableHeight: CGFloat = .greatestFiniteMagnitude,
        theme: VariantColorTheme = .modern
    ) {
        let samples = genotypeData.sampleNames
        guard !samples.isEmpty, !genotypeData.sites.isEmpty else { return }

        let rowH = state.rowHeight
        guard rowH > 0 else { return }

        context.saveGState()
        defer { context.restoreGState() }

        // Clip to available area so rows don't overflow
        let clipRect = CGRect(x: 0, y: yOffset, width: CGFloat(frame.pixelWidth), height: availableHeight)
        context.clip(to: clipRect)

        let showLabels = rowH >= 8
        let totalRows = samples.count
        let dataStartX = showLabels ? (sampleLabelWidth + sampleLabelToDataMargin) : 0
        let dataWidth = max(0, CGFloat(frame.pixelWidth) - dataStartX)

        // Compute visible row range from scroll offset
        let firstVisibleRow = max(0, Int(scrollOffset / rowH))
        let visibleRowCount = Int(ceil(availableHeight / rowH)) + 1
        let lastVisibleRow = min(totalRows - 1, firstVisibleRow + visibleRowCount)

        guard firstVisibleRow <= lastVisibleRow else { return }

        // Draw genotype cells for each visible sample
        for sampleIdx in firstVisibleRow...lastVisibleRow {
            let sampleName = samples[sampleIdx]
            let rowY = yOffset + CGFloat(sampleIdx) * rowH - scrollOffset

            // Sample name label (when rows are tall enough)
            if showLabels {
                let label = (sampleDisplayNames[sampleName] ?? sampleName) as NSString
                let fontSize = max(7, min(rowH - 2, 12))
                let labelAttrs: [NSAttributedString.Key: Any] = [
                    .font: NSFont.systemFont(ofSize: fontSize, weight: .regular),
                    .foregroundColor: NSColor.labelColor,
                ]
                context.setFillColor(CGColor(red: 0.96, green: 0.96, blue: 0.96, alpha: 0.92))
                context.fill(CGRect(x: 0, y: rowY, width: sampleLabelWidth, height: rowH))
                // Keep an explicit blank gutter before genotype cells.
                context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.98))
                context.fill(CGRect(x: sampleLabelWidth, y: rowY, width: sampleLabelToDataMargin, height: rowH))
                context.setStrokeColor(CGColor(red: 0.82, green: 0.82, blue: 0.82, alpha: 1.0))
                context.setLineWidth(0.5)
                let sepX = sampleLabelWidth + sampleLabelToDataMargin / 2
                context.move(to: CGPoint(x: sepX, y: rowY))
                context.addLine(to: CGPoint(x: sepX, y: rowY + rowH))
                context.strokePath()
                label.draw(
                    at: CGPoint(x: 2, y: rowY + 1),
                    withAttributes: labelAttrs
                )
            }

            // Draw genotype cell for each variant site
            for site in genotypeData.sites {
                let call = site.genotypes[sampleName] ?? .noCall
                let color = colorForCallWithImpact(call, impact: site.impact, theme: theme)

                let startPx = frame.screenPosition(for: Double(site.position))
                let endPx = frame.screenPosition(for: Double(site.position + max(1, site.ref.count)))
                let cellWidth = max(1, endPx - startPx)
                let clippedStart = max(dataStartX, startPx)
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

            // Row separator when rows are tall enough
            if rowH >= 4 && sampleIdx < totalRows - 1 {
                context.setStrokeColor(CGColor(red: 0.9, green: 0.9, blue: 0.9, alpha: 1.0))
                context.setLineWidth(0.5)
                let sepY = rowY + rowH
                context.move(to: CGPoint(x: 0, y: sepY))
                context.addLine(to: CGPoint(x: dataStartX + dataWidth, y: sepY))
                context.strokePath()
            }
        }

        // Draw scroll indicator if content exceeds visible area
        let totalContentHeight = CGFloat(totalRows) * rowH
        if totalContentHeight > availableHeight && availableHeight > 0 {
            drawScrollIndicator(
                context: context,
                x: CGFloat(frame.pixelWidth) - scrollIndicatorWidth - 2,
                yOffset: yOffset,
                availableHeight: availableHeight,
                totalContentHeight: totalContentHeight,
                scrollOffset: scrollOffset
            )
        }
    }

    // MARK: - Scroll Indicator

    /// Draws a subtle scrollbar indicator showing position within the full sample list.
    private static func drawScrollIndicator(
        context: CGContext,
        x: CGFloat,
        yOffset: CGFloat,
        availableHeight: CGFloat,
        totalContentHeight: CGFloat,
        scrollOffset: CGFloat
    ) {
        // Track background
        let trackRect = CGRect(x: x, y: yOffset, width: scrollIndicatorWidth, height: availableHeight)
        context.setFillColor(CGColor(red: 0.0, green: 0.0, blue: 0.0, alpha: 0.05))
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
        context.setFillColor(CGColor(red: 0.0, green: 0.0, blue: 0.0, alpha: 0.25))
        context.fill(thumbRect)
    }

    // MARK: - Color Helpers

    /// Returns the CGColor for a genotype call using the given theme.
    private static func colorForCall(_ call: GenotypeDisplayCall, theme: VariantColorTheme) -> CGColor {
        cgColor(from: call.themeColor(from: theme))
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
