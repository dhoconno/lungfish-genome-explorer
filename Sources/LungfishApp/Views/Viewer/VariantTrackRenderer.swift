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
/// Rendering is split into static methods for testability and reuse.
@MainActor
public enum VariantTrackRenderer {

    // MARK: - Layout Constants

    /// Height of the variant summary bar.
    static let summaryBarHeight: CGFloat = 20

    /// Height per sample row in squished mode.
    static let squishedRowHeight: CGFloat = 2

    /// Height per sample row in expanded mode.
    static let expandedRowHeight: CGFloat = 10

    /// Spacing between the summary bar and the first sample row.
    static let summaryToRowGap: CGFloat = 2

    /// Maximum number of sample rows to render.
    static let maxSampleRows = 100

    /// Minimum pixels per variant to draw individual markers (otherwise use density).
    static let minPixelsPerVariant: CGFloat = 1

    // MARK: - Color Palette

    /// Colors for variant types (matching IGV conventions).
    private static let snpColor = CGColor(red: 0.0, green: 0.6, blue: 0.2, alpha: 1.0)       // green
    private static let insColor = CGColor(red: 0.5, green: 0.0, blue: 0.8, alpha: 1.0)       // purple
    private static let delColor = CGColor(red: 0.8, green: 0.0, blue: 0.0, alpha: 1.0)       // red
    private static let mnpColor = CGColor(red: 0.8, green: 0.5, blue: 0.0, alpha: 1.0)       // orange
    private static let complexColor = CGColor(red: 0.5, green: 0.5, blue: 0.5, alpha: 1.0)   // gray

    /// Genotype cell colors (IGV-compatible).
    private static let homRefColor = CGColor(red: 200/255, green: 200/255, blue: 200/255, alpha: 1.0)
    private static let hetColor = CGColor(red: 34/255, green: 12/255, blue: 253/255, alpha: 1.0)
    private static let homAltColor = CGColor(red: 17/255, green: 248/255, blue: 254/255, alpha: 1.0)
    private static let noCallColor = CGColor(red: 250/255, green: 250/255, blue: 250/255, alpha: 1.0)

    // MARK: - Public API

    /// Returns the total height needed for variant rendering at the given zoom and sample count.
    ///
    /// - Parameters:
    ///   - sampleCount: Number of samples to display
    ///   - scale: Current zoom level in bp/pixel
    ///   - state: Display state controlling row visibility and height mode
    /// - Returns: Total height in pixels
    public static func totalHeight(
        sampleCount: Int,
        scale: Double,
        state: SampleDisplayState
    ) -> CGFloat {
        var height = summaryBarHeight
        if state.showGenotypeRows && sampleCount > 0 {
            let rowH = rowHeight(sampleCount: sampleCount, scale: scale, state: state)
            let rows = min(sampleCount, maxSampleRows)
            height += summaryToRowGap + CGFloat(rows) * rowH
        }
        return height
    }

    /// Returns the row height for genotype rows based on zoom and display state.
    public static func rowHeight(
        sampleCount: Int,
        scale: Double,
        state: SampleDisplayState
    ) -> CGFloat {
        switch state.rowHeightMode {
        case .squished:
            return squishedRowHeight
        case .expanded:
            return expandedRowHeight
        case .automatic:
            // Density mode: no rows (>50k bp/px)
            if scale > 50_000 { return 0 }
            // Squished mode (>500 bp/px or many samples)
            if scale > 500 || sampleCount > 20 { return squishedRowHeight }
            // Expanded mode
            return expandedRowHeight
        }
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
        yOffset: CGFloat
    ) {
        guard !variants.isEmpty else { return }

        let pixelWidth = frame.pixelWidth
        guard pixelWidth > 0 else { return }

        // Background
        context.setFillColor(CGColor(red: 0.95, green: 0.95, blue: 0.95, alpha: 1.0))
        context.fill(CGRect(x: 0, y: yOffset, width: CGFloat(pixelWidth), height: summaryBarHeight))

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
        let barBottom = yOffset + summaryBarHeight

        // Draw stacked bars per pixel
        for px in 0..<pixelWidth {
            let total = snpCounts[px] + insCounts[px] + delCounts[px] + otherCounts[px]
            guard total > 0 else { continue }

            let normalizedHeight = (CGFloat(total) / CGFloat(maxCount)) * (summaryBarHeight - 2)
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
            at: CGPoint(x: 4, y: yOffset + (summaryBarHeight - labelSize.height) / 2),
            withAttributes: attrs
        )
    }

    // MARK: - Genotype Row Rendering

    /// Draws per-sample genotype rows below the summary bar.
    ///
    /// - Parameters:
    ///   - genotypeData: Pre-fetched genotype data for the visible region
    ///   - frame: The reference frame for coordinate mapping
    ///   - context: The graphics context to draw into
    ///   - yOffset: Y position for the top of the first sample row
    ///   - state: Display state controlling appearance
    public static func drawGenotypeRows(
        genotypeData: GenotypeDisplayData,
        frame: ReferenceFrame,
        context: CGContext,
        yOffset: CGFloat,
        state: SampleDisplayState
    ) {
        let samples = genotypeData.sampleNames
        guard !samples.isEmpty, !genotypeData.sites.isEmpty else { return }

        let rowH = rowHeight(sampleCount: samples.count, scale: frame.scale, state: state)
        guard rowH > 0 else { return }  // Density mode — no rows to draw

        let showLabels = rowH >= expandedRowHeight
        let visibleSamples = Array(samples.prefix(maxSampleRows))

        // Draw genotype cells for each sample at each variant site
        for (sampleIdx, sampleName) in visibleSamples.enumerated() {
            let rowY = yOffset + CGFloat(sampleIdx) * rowH

            // Sample name label (expanded mode only)
            if showLabels {
                let label = sampleName as NSString
                let labelAttrs: [NSAttributedString.Key: Any] = [
                    .font: NSFont.systemFont(ofSize: 7, weight: .regular),
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
                let color = colorForCall(call)

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

            // Row separator in expanded mode
            if showLabels && sampleIdx < visibleSamples.count - 1 {
                context.setStrokeColor(CGColor(red: 0.9, green: 0.9, blue: 0.9, alpha: 1.0))
                context.setLineWidth(0.5)
                let sepY = rowY + rowH
                context.move(to: CGPoint(x: 0, y: sepY))
                context.addLine(to: CGPoint(x: CGFloat(frame.pixelWidth), y: sepY))
                context.strokePath()
            }
        }
    }

    // MARK: - Color Helpers

    /// Returns the CGColor for a genotype call.
    private static func colorForCall(_ call: GenotypeDisplayCall) -> CGColor {
        switch call {
        case .homRef:  return homRefColor
        case .het:     return hetColor
        case .homAlt:  return homAltColor
        case .noCall:  return noCallColor
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
