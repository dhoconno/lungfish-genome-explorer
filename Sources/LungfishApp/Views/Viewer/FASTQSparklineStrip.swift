// FASTQSparklineStrip.swift - Compact sparkline charts for FASTQ statistics
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import LungfishIO

// Uses FASTQPalette from OperationPreviewView.swift for consistent colors.

// MARK: - FASTQSparklineStrip

/// A horizontal strip of three inline sparkline charts: length distribution,
/// quality per position, and quality score distribution.
///
/// Each sparkline is a filled area chart at 44pt height with no axis labels.
/// Clicking a sparkline presents a popover with the full-size chart.
@MainActor
final class FASTQSparklineStrip: NSView {

    private enum SparklineKind: Int, CaseIterable {
        case length = 0
        case qualityPerPosition = 1
        case qualityScore = 2

        var title: String {
            switch self {
            case .length: return "Length Dist."
            case .qualityPerPosition: return "Q / Position"
            case .qualityScore: return "Q Score Dist."
            }
        }

        var color: NSColor {
            switch self {
            case .length: return FASTQPalette.readFill
            case .qualityPerPosition: return FASTQPalette.qualityMedium
            case .qualityScore: return FASTQPalette.qualityHigh
            }
        }
    }

    private var statistics: FASTQDatasetStatistics?
    private var sparklineTrackingAreas: [NSTrackingArea] = []
    private var hoveredIndex: Int = -1
    private weak var activePopover: NSPopover?

    // Full-size chart views for popovers
    private let lengthHistogramView = FASTQHistogramChartView()
    private let qualityBoxplotView = FASTQQualityBoxplotView()
    private let qualityScoreHistogramView = FASTQHistogramChartView()

    /// Callback when user clicks "Compute Quality Report" in disabled sparkline area
    var onComputeQualityReport: (() -> Void)?

    override var isFlipped: Bool { true }

    func update(with stats: FASTQDatasetStatistics) {
        self.statistics = stats
        updateFullCharts()
        needsDisplay = true
        updateAccessibility(stats)
    }

    private func updateAccessibility(_ stats: FASTQDatasetStatistics) {
        setAccessibilityRole(.group)
        setAccessibilityLabel("FASTQ Quality Sparklines")
        let desc = "Length distribution, per-position quality, and quality score distribution charts. Click to expand."
        setAccessibilityValue(desc)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in sparklineTrackingAreas {
            removeTrackingArea(area)
        }
        sparklineTrackingAreas.removeAll()

        for i in SparklineKind.allCases.indices {
            let rect = sparklineRect(at: i)
            let area = NSTrackingArea(
                rect: rect,
                options: [.mouseEnteredAndExited, .activeInActiveApp],
                owner: self,
                userInfo: ["index": i]
            )
            addTrackingArea(area)
            sparklineTrackingAreas.append(area)
        }
    }

    override func mouseEntered(with event: NSEvent) {
        if let index = (event.trackingArea?.userInfo?["index"] as? Int) {
            hoveredIndex = index
            needsDisplay = true
        }
    }

    override func mouseExited(with event: NSEvent) {
        hoveredIndex = -1
        needsDisplay = true
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        for kind in SparklineKind.allCases {
            let rect = sparklineRect(at: kind.rawValue)
            if rect.contains(point) {
                if kind == .length || hasQualityData {
                    showPopover(for: kind, from: rect)
                } else {
                    onComputeQualityReport?()
                }
                return
            }
        }
    }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }

        for kind in SparklineKind.allCases {
            let rect = sparklineRect(at: kind.rawValue)
            drawSparkline(ctx: ctx, rect: rect, kind: kind)
        }
    }

    private func sparklineRect(at index: Int) -> CGRect {
        let padding: CGFloat = 8
        let gap: CGFloat = 8
        let count = CGFloat(SparklineKind.allCases.count)
        let width = (bounds.width - padding * 2 - gap * (count - 1)) / count
        let x = padding + CGFloat(index) * (width + gap)
        return CGRect(x: x, y: 4, width: width, height: bounds.height - 8)
    }

    private func drawSparkline(ctx: CGContext, rect: CGRect, kind: SparklineKind) {
        guard rect.width > 0, rect.height > 0 else { return }

        // Clip all drawing to this sparkline's rect so nothing bleeds into neighbors
        ctx.saveGState()
        ctx.clip(to: rect)

        // Background
        let isHovered = hoveredIndex == kind.rawValue
        let bgAlpha: CGFloat = isHovered ? 0.55 : 0.4
        let bgColor = NSColor.controlBackgroundColor.withAlphaComponent(bgAlpha).cgColor
        let bgPath = CGPath(roundedRect: rect, cornerWidth: 6, cornerHeight: 6, transform: nil)
        ctx.addPath(bgPath)
        ctx.setFillColor(bgColor)
        ctx.fillPath()

        // Border
        ctx.setStrokeColor(NSColor.separatorColor.cgColor)
        ctx.setLineWidth(0.5)
        ctx.addPath(bgPath)
        ctx.strokePath()

        // Title
        let titleAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 9, weight: .medium),
            .foregroundColor: NSColor.secondaryLabelColor,
        ]
        let titleStr = NSAttributedString(string: kind.title, attributes: titleAttrs)
        titleStr.draw(at: CGPoint(x: rect.minX + 4, y: rect.minY + 2))

        // Chart area (below title)
        let chartRect = CGRect(
            x: rect.minX + 4,
            y: rect.minY + 14,
            width: rect.width - 8,
            height: rect.height - 18
        )

        guard chartRect.width > 4, chartRect.height > 4 else {
            ctx.restoreGState()
            return
        }

        let hasData: Bool
        switch kind {
        case .length:
            hasData = statistics != nil && !(statistics!.readLengthHistogram.isEmpty)
            if hasData {
                drawBarSparkline(ctx: ctx, rect: chartRect,
                                 bins: statistics!.readLengthHistogram.sorted { $0.key < $1.key },
                                 color: kind.color)
            }
        case .qualityPerPosition:
            hasData = hasQualityData
            if hasData {
                drawQualityPositionSparkline(ctx: ctx, rect: chartRect)
            }
        case .qualityScore:
            hasData = hasQualityData
            if hasData {
                drawBarSparkline(ctx: ctx, rect: chartRect,
                                 bins: statistics!.qualityScoreHistogram.sorted { $0.key < $1.key }
                                     .map { (key: Int($0.key), value: $0.value) },
                                 color: kind.color)
            }
        }

        if !hasData && kind != .length {
            drawDisabledState(ctx: ctx, rect: chartRect)
        }

        ctx.restoreGState()
    }

    private func drawBarSparkline(ctx: CGContext, rect: CGRect,
                                  bins: [(key: Int, value: Int)],
                                  color: NSColor) {
        guard !bins.isEmpty else { return }

        // When there are more bins than pixels, aggregate into pixel-width buckets
        // so the full distribution is visible and Y-max reflects what's drawn.
        let displayBins: [(key: Int, value: Int)]
        let maxPixelBins = Int(rect.width)
        if bins.count > maxPixelBins, maxPixelBins > 0,
           let minKey = bins.first?.key, let maxKey = bins.last?.key, maxKey > minKey {
            let keyRange = maxKey - minKey
            let bucketSize = max(1, (keyRange + maxPixelBins - 1) / maxPixelBins)
            var aggregated: [Int: Int] = [:]
            for bin in bins {
                let bucket = (bin.key - minKey) / bucketSize
                aggregated[bucket, default: 0] += bin.value
            }
            displayBins = aggregated.sorted { $0.key < $1.key }
                .map { (key: $0.key, value: $0.value) }
        } else {
            displayBins = bins
        }

        let maxValue = displayBins.map(\.value).max() ?? 1
        guard maxValue > 0 else { return }

        let barCount = displayBins.count
        let barWidth = max(1, rect.width / CGFloat(barCount))

        // Draw as filled area path
        let path = CGMutablePath()
        path.move(to: CGPoint(x: rect.minX, y: rect.maxY))

        for (i, bin) in displayBins.enumerated() {
            let x = rect.minX + CGFloat(i) * barWidth
            let h = CGFloat(bin.value) / CGFloat(maxValue) * rect.height
            let y = rect.maxY - h
            path.addLine(to: CGPoint(x: x, y: y))
            path.addLine(to: CGPoint(x: x + barWidth, y: y))
        }

        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        path.closeSubpath()

        // Fill
        ctx.saveGState()
        ctx.addPath(path)
        ctx.clip()
        ctx.setFillColor(color.withAlphaComponent(0.2).cgColor)
        ctx.fill(rect)
        ctx.restoreGState()

        // Stroke top edge
        let strokePath = CGMutablePath()
        strokePath.move(to: CGPoint(x: rect.minX, y: rect.maxY))
        for (i, bin) in displayBins.enumerated() {
            let x = rect.minX + CGFloat(i) * barWidth
            let h = CGFloat(bin.value) / CGFloat(maxValue) * rect.height
            let y = rect.maxY - h
            strokePath.addLine(to: CGPoint(x: x, y: y))
            strokePath.addLine(to: CGPoint(x: x + barWidth, y: y))
        }
        ctx.setStrokeColor(color.withAlphaComponent(0.6).cgColor)
        ctx.setLineWidth(0.5)
        ctx.addPath(strokePath)
        ctx.strokePath()
    }

    private func drawQualityPositionSparkline(ctx: CGContext, rect: CGRect) {
        guard let stats = statistics, !stats.perPositionQuality.isEmpty else { return }
        let summaries = stats.perPositionQuality
        let maxQ: CGFloat = 42

        // Draw quality zone background bands
        let greenY = rect.maxY - (30.0 / maxQ) * rect.height
        let yellowY = rect.maxY - (20.0 / maxQ) * rect.height

        ctx.setFillColor(FASTQPalette.qualityHigh.withAlphaComponent(0.06).cgColor)
        ctx.fill(CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: greenY - rect.minY))
        ctx.setFillColor(FASTQPalette.qualityMedium.withAlphaComponent(0.06).cgColor)
        ctx.fill(CGRect(x: rect.minX, y: greenY, width: rect.width, height: yellowY - greenY))
        ctx.setFillColor(FASTQPalette.qualityVeryLow.withAlphaComponent(0.06).cgColor)
        ctx.fill(CGRect(x: rect.minX, y: yellowY, width: rect.width, height: rect.maxY - yellowY))

        // Draw median line
        let path = CGMutablePath()
        let positionWidth = rect.width / CGFloat(summaries.count)
        for (i, summary) in summaries.enumerated() {
            let x = rect.minX + CGFloat(i) * positionWidth + positionWidth / 2
            let y = rect.maxY - CGFloat(summary.median / Double(maxQ)) * rect.height
            if i == 0 {
                path.move(to: CGPoint(x: x, y: y))
            } else {
                path.addLine(to: CGPoint(x: x, y: y))
            }
        }

        ctx.setStrokeColor(FASTQPalette.qualityMedium.withAlphaComponent(0.7).cgColor)
        ctx.setLineWidth(1)
        ctx.addPath(path)
        ctx.strokePath()
    }

    private func drawDisabledState(ctx: CGContext, rect: CGRect) {
        // Subtle dashed border to indicate interactivity
        ctx.saveGState()
        ctx.setStrokeColor(NSColor.tertiaryLabelColor.withAlphaComponent(0.4).cgColor)
        ctx.setLineWidth(1.0)
        ctx.setLineDash(phase: 0, lengths: [3, 3])
        let insetRect = rect.insetBy(dx: 2, dy: 2)
        ctx.addPath(CGPath(roundedRect: insetRect, cornerWidth: 4, cornerHeight: 4, transform: nil))
        ctx.strokePath()
        ctx.restoreGState()

        // "Click to Compute" label
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 9, weight: .medium),
            .foregroundColor: NSColor.secondaryLabelColor,
        ]
        let str = NSAttributedString(string: "Click to Compute", attributes: attrs)
        let size = str.size()
        str.draw(at: CGPoint(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2))
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        // Show pointing hand cursor over quality sparklines when no data
        if !hasQualityData {
            for kind in SparklineKind.allCases where kind != .length {
                let rect = sparklineRect(at: kind.rawValue)
                addCursorRect(rect, cursor: .pointingHand)
            }
        }
    }

    private var hasQualityData: Bool {
        guard let stats = statistics else { return false }
        return !stats.perPositionQuality.isEmpty && !stats.qualityScoreHistogram.isEmpty
    }

    // MARK: - Popovers

    private func showPopover(for kind: SparklineKind, from rect: CGRect) {
        activePopover?.close()

        let popover = NSPopover()
        popover.behavior = .semitransient
        popover.contentSize = NSSize(width: 560, height: 340)

        let chartView: NSView
        switch kind {
        case .length:
            chartView = lengthHistogramView
        case .qualityPerPosition:
            chartView = qualityBoxplotView
        case .qualityScore:
            chartView = qualityScoreHistogramView
        }

        let vc = NSViewController()
        vc.view = chartView
        popover.contentViewController = vc

        popover.show(relativeTo: rect, of: self, preferredEdge: .maxY)
        activePopover = popover
    }

    private func updateFullCharts() {
        guard let stats = statistics else { return }

        let lengthBins = stats.readLengthHistogram
            .sorted { $0.key < $1.key }
            .map { (key: $0.key, value: $0.value) }

        lengthHistogramView.update(with: .init(
            title: "Read Length Distribution",
            xLabel: "Read Length (bp)",
            yLabel: "Count",
            bins: lengthBins,
            barColor: .systemBlue
        ))

        let qBins = stats.qualityScoreHistogram.sorted { $0.key < $1.key }
            .map { (key: Int($0.key), value: $0.value) }

        qualityScoreHistogramView.update(with: .init(
            title: "Quality Score Distribution",
            xLabel: "Quality Score (Phred)",
            yLabel: "Base Count",
            bins: qBins,
            barColor: FASTQPalette.qualityHigh
        ))

        qualityBoxplotView.update(with: stats.perPositionQuality)
    }
}
