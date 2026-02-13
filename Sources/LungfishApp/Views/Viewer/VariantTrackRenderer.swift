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

    // MARK: - Color Palette

    /// Colors for variant types (matching IGV conventions).
    private static let snpColor = CGColor(red: 0.0, green: 0.6, blue: 0.2, alpha: 1.0)       // green
    private static let insColor = CGColor(red: 0.5, green: 0.0, blue: 0.8, alpha: 1.0)       // purple
    private static let delColor = CGColor(red: 0.8, green: 0.0, blue: 0.0, alpha: 1.0)       // red
    private static let mnpColor = CGColor(red: 0.8, green: 0.5, blue: 0.0, alpha: 1.0)       // orange
    private static let complexColor = CGColor(red: 0.5, green: 0.5, blue: 0.5, alpha: 1.0)   // gray

    /// Genotype cell colors derived from GenotypeDisplayCall canonical colors.
    private static let homRefColor = cgColor(for: .homRef)
    private static let hetColor = cgColor(for: .het)
    private static let homAltColor = cgColor(for: .homAlt)
    private static let noCallColor = cgColor(for: .noCall)

    /// Impact-aware genotype colors (used when variant has a known amino acid impact).
    /// Non-synonymous variants get warmer tones to visually distinguish them.
    private static let missenseHetColor = CGColor(red: 0.95, green: 0.4, blue: 0.1, alpha: 1.0)    // orange
    private static let missenseHomAltColor = CGColor(red: 0.85, green: 0.2, blue: 0.0, alpha: 1.0)  // dark orange
    private static let nonsenseHetColor = CGColor(red: 0.95, green: 0.1, blue: 0.1, alpha: 1.0)     // bright red
    private static let nonsenseHomAltColor = CGColor(red: 0.75, green: 0.0, blue: 0.0, alpha: 1.0)   // dark red
    private static let frameshiftHetColor = CGColor(red: 0.6, green: 0.1, blue: 0.7, alpha: 1.0)    // purple
    private static let frameshiftHomAltColor = CGColor(red: 0.45, green: 0.0, blue: 0.55, alpha: 1.0) // dark purple

    private static func cgColor(for call: GenotypeDisplayCall) -> CGColor {
        let c = call.color
        return CGColor(red: c.r, green: c.g, blue: c.b, alpha: 1.0)
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
        var height = state.summaryBarHeight
        if state.showGenotypeRows && sampleCount > 0 {
            height += summaryToRowGap + CGFloat(sampleCount) * state.rowHeight
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
        barHeight: CGFloat = 20
    ) {
        guard !variants.isEmpty else { return }

        let pixelWidth = frame.pixelWidth
        guard pixelWidth > 0 else { return }

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
                (snpCounts[px], snpColor),
                (insCounts[px], insColor),
                (delCounts[px], delColor),
                (otherCounts[px], complexColor),
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
        availableHeight: CGFloat = .greatestFiniteMagnitude
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
                label.draw(
                    at: CGPoint(x: 2, y: rowY + 1),
                    withAttributes: labelAttrs
                )
            }

            // Draw genotype cell for each variant site
            for site in genotypeData.sites {
                let call = site.genotypes[sampleName] ?? .noCall
                let color = colorForCallWithImpact(call, impact: site.impact)

                let startPx = frame.screenPosition(for: Double(site.position))
                let endPx = frame.screenPosition(for: Double(site.position + max(1, site.ref.count)))
                let cellWidth = max(1, endPx - startPx)

                context.setFillColor(color)
                context.fill(CGRect(
                    x: startPx,
                    y: rowY,
                    width: cellWidth,
                    height: rowH
                ))
            }

            // Row separator when rows are tall enough
            if rowH >= 4 && sampleIdx < totalRows - 1 {
                context.setStrokeColor(CGColor(red: 0.9, green: 0.9, blue: 0.9, alpha: 1.0))
                context.setLineWidth(0.5)
                let sepY = rowY + rowH
                context.move(to: CGPoint(x: 0, y: sepY))
                context.addLine(to: CGPoint(x: CGFloat(frame.pixelWidth), y: sepY))
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

    /// Returns the CGColor for a genotype call (default colors, no impact).
    private static func colorForCall(_ call: GenotypeDisplayCall) -> CGColor {
        switch call {
        case .homRef:  return homRefColor
        case .het:     return hetColor
        case .homAlt:  return homAltColor
        case .noCall:  return noCallColor
        }
    }

    /// Returns the CGColor for a genotype call, applying impact-based coloring
    /// for non-synonymous variants that carry alt alleles.
    private static func colorForCallWithImpact(_ call: GenotypeDisplayCall, impact: VariantImpact?) -> CGColor {
        // Only color alt-carrying genotypes differently; homRef and noCall keep standard colors
        guard call == .het || call == .homAlt else { return colorForCall(call) }
        guard let impact, impact != .synonymous, impact != .unknown else { return colorForCall(call) }

        switch impact {
        case .missense:
            return call == .het ? missenseHetColor : missenseHomAltColor
        case .nonsense:
            return call == .het ? nonsenseHetColor : nonsenseHomAltColor
        case .frameshift:
            return call == .het ? frameshiftHetColor : frameshiftHomAltColor
        case .spliceRegion:
            return call == .het ? missenseHetColor : missenseHomAltColor  // same as missense for now
        case .synonymous, .unknown:
            return colorForCall(call)
        }
    }

    /// Returns the CGColor for a variant type string.
    static func colorForVariantType(_ vtype: String) -> CGColor {
        switch vtype {
        case "SNP":     return snpColor
        case "INS":     return insColor
        case "DEL":     return delColor
        case "MNP":     return mnpColor
        default:        return complexColor
        }
    }
}
