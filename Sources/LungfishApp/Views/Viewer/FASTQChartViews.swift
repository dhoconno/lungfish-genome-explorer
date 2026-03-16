// FASTQChartViews.swift - CoreGraphics chart components for FASTQ statistics
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import LungfishIO

// MARK: - FASTQSummaryBar

/// Compact horizontal row of statistics cards for FASTQ dataset overview.
///
/// Displays key metrics: Read Count, Base Count, Mean Length, Mean Quality,
/// GC Content, Q20%, Q30%, N50.
@MainActor
final class FASTQSummaryBar: NSView {

    private var statistics: FASTQDatasetStatistics?

    override var isFlipped: Bool { true }

    func update(with stats: FASTQDatasetStatistics) {
        self.statistics = stats
        needsDisplay = true
        updateAccessibility(stats)
    }

    private func updateAccessibility(_ stats: FASTQDatasetStatistics) {
        setAccessibilityRole(.group)
        setAccessibilityLabel("FASTQ Summary Statistics")
        let desc = "\(stats.readCount) reads, mean length \(Int(stats.meanReadLength)) bp, mean quality \(String(format: "%.1f", stats.meanQuality)), GC \(String(format: "%.1f%%", stats.gcContent * 100))"
        setAccessibilityValue(desc)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        guard let stats = statistics else { return }

        let cards: [(String, String)] = [
            ("Reads", formatCount(stats.readCount)),
            ("Bases", formatBases(stats.baseCount)),
            ("Mean Length", String(format: "%.0f bp", stats.meanReadLength)),
            ("Median Length", "\(stats.medianReadLength) bp"),
            ("N50", "\(stats.n50ReadLength) bp"),
            ("Mean Q", String(format: "%.1f", stats.meanQuality)),
            ("Q20", String(format: "%.1f%%", stats.q20Percentage)),
            ("Q30", String(format: "%.1f%%", stats.q30Percentage)),
            ("GC", String(format: "%.1f%%", stats.gcContent * 100)),
        ]

        let padding: CGFloat = 8
        let cardSpacing: CGFloat = 6
        let availableWidth = bounds.width - padding * 2
        let cardWidth = (availableWidth - cardSpacing * CGFloat(cards.count - 1)) / CGFloat(cards.count)

        for (i, card) in cards.enumerated() {
            let x = padding + CGFloat(i) * (cardWidth + cardSpacing)
            let cardRect = CGRect(x: x, y: 4, width: cardWidth, height: bounds.height - 8)

            // Card background
            let bgColor = NSColor.controlBackgroundColor.withAlphaComponent(0.6).cgColor
            ctx.setFillColor(bgColor)
            let path = CGPath(roundedRect: cardRect, cornerWidth: 4, cornerHeight: 4, transform: nil)
            ctx.addPath(path)
            ctx.fillPath()

            // Border
            ctx.setStrokeColor(NSColor.separatorColor.cgColor)
            ctx.setLineWidth(0.5)
            ctx.addPath(path)
            ctx.strokePath()

            // Clip text to card bounds
            ctx.saveGState()
            ctx.clip(to: cardRect.insetBy(dx: 4, dy: 0))

            // Label (top) — use abbreviated label when card is narrow
            let labelAttrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 9, weight: .medium),
                .foregroundColor: NSColor.secondaryLabelColor,
            ]
            let cardContentWidth = cardRect.width - 8
            let fullLabelSize = (card.0 as NSString).size(withAttributes: labelAttrs)
            let displayLabel = fullLabelSize.width > cardContentWidth
                ? abbreviatedLabel(for: card.0)
                : card.0
            let labelStr = NSAttributedString(string: displayLabel, attributes: labelAttrs)
            let labelSize = labelStr.size()
            let labelX = cardRect.midX - labelSize.width / 2
            labelStr.draw(at: CGPoint(x: labelX, y: cardRect.minY + 4))

            // Value (bottom)
            let valueAttrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .semibold),
                .foregroundColor: NSColor.labelColor,
            ]
            let valueStr = NSAttributedString(string: card.1, attributes: valueAttrs)
            let valueSize = valueStr.size()
            let valueX = cardRect.midX - valueSize.width / 2
            valueStr.draw(at: CGPoint(x: valueX, y: cardRect.minY + 18))

            ctx.restoreGState()
        }
    }

    private func formatCount(_ count: Int) -> String {
        if count >= 1_000_000 { return String(format: "%.1fM", Double(count) / 1_000_000) }
        if count >= 1_000 { return String(format: "%.1fK", Double(count) / 1_000) }
        return "\(count)"
    }

    private func formatBases(_ count: Int64) -> String {
        if count >= 1_000_000_000 { return String(format: "%.2f Gb", Double(count) / 1_000_000_000) }
        if count >= 1_000_000 { return String(format: "%.2f Mb", Double(count) / 1_000_000) }
        if count >= 1_000 { return String(format: "%.1f Kb", Double(count) / 1_000) }
        return "\(count) bp"
    }

    private func abbreviatedLabel(for label: String) -> String {
        switch label {
        case "Median Length": return "Med. Len"
        case "Mean Length": return "Mean Len"
        case "Total Reads": return "Reads"
        case "Total Bases": return "Bases"
        case "Mean Quality": return "Mean Q"
        case "Median Quality": return "Med. Q"
        case "Min Length": return "Min Len"
        case "Max Length": return "Max Len"
        case "GC Content": return "GC%"
        case "Mean Q": return "Q"
        default: return String(label.prefix(8))
        }
    }
}

// MARK: - Chart Copy-to-Clipboard Helper

/// Renders an NSView to a PNG image and copies it to the system clipboard.
@MainActor
private func copyViewToPasteboard(_ view: NSView) {
    let scale: CGFloat = 2.0  // Retina resolution
    let width = Int(view.bounds.width * scale)
    let height = Int(view.bounds.height * scale)
    guard width > 0, height > 0 else { return }

    guard let bitmapRep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: width,
        pixelsHigh: height,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    ) else { return }

    bitmapRep.size = view.bounds.size

    guard let ctx = NSGraphicsContext(bitmapImageRep: bitmapRep) else { return }
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = ctx
    ctx.cgContext.scaleBy(x: scale, y: scale)
    view.draw(view.bounds)
    NSGraphicsContext.restoreGraphicsState()

    guard let pngData = bitmapRep.representation(using: .png, properties: [:]) else { return }

    let pasteboard = NSPasteboard.general
    pasteboard.clearContents()
    pasteboard.setData(pngData, forType: .png)
}

// MARK: - FASTQHistogramChartView

/// Reusable histogram chart using CoreGraphics.
///
/// Renders a vertical bar chart with axis labels, grid lines, and a title.
/// Used for both read length distribution and quality score distribution.
@MainActor
final class FASTQHistogramChartView: NSView {

    struct HistogramData {
        let title: String
        let xLabel: String
        let yLabel: String
        let bins: [(key: Int, value: Int)]
        let barColor: NSColor

        init(title: String, xLabel: String, yLabel: String,
             bins: [(key: Int, value: Int)],
             barColor: NSColor = .systemBlue) {
            self.title = title
            self.xLabel = xLabel
            self.yLabel = yLabel
            self.bins = bins
            self.barColor = barColor
        }
    }

    private var data: HistogramData?

    override var isFlipped: Bool { true }

    func update(with data: HistogramData) {
        self.data = data
        needsDisplay = true
        updateAccessibility(data)
    }

    private func updateAccessibility(_ data: HistogramData) {
        setAccessibilityRole(.image)
        setAccessibilityLabel(data.title)
        let total = data.bins.reduce(0) { $0 + $1.value }
        let desc = "Histogram with \(data.bins.count) bins, \(total) total observations"
        setAccessibilityValue(desc)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        guard let data, !data.bins.isEmpty else {
            drawEmptyState(ctx)
            return
        }

        let margins = NSEdgeInsets(top: 30, left: 60, bottom: 40, right: 20)
        let chartRect = CGRect(
            x: margins.left,
            y: margins.top,
            width: bounds.width - margins.left - margins.right,
            height: bounds.height - margins.top - margins.bottom
        )

        guard chartRect.width > 10, chartRect.height > 10 else { return }

        let maxValue = data.bins.map(\.value).max() ?? 1

        // Background
        ctx.setFillColor(NSColor.controlBackgroundColor.cgColor)
        ctx.fill(bounds)

        // Grid lines (5 horizontal)
        ctx.setStrokeColor(NSColor.separatorColor.withAlphaComponent(0.3).cgColor)
        ctx.setLineWidth(0.5)
        for i in 0...4 {
            let y = chartRect.minY + chartRect.height * CGFloat(i) / 4.0
            ctx.move(to: CGPoint(x: chartRect.minX, y: y))
            ctx.addLine(to: CGPoint(x: chartRect.maxX, y: y))
        }
        ctx.strokePath()

        // Y-axis labels
        let yLabelAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 9, weight: .regular),
            .foregroundColor: NSColor.secondaryLabelColor,
        ]
        for i in 0...4 {
            let value = maxValue - (maxValue * i / 4)
            let y = chartRect.minY + chartRect.height * CGFloat(i) / 4.0
            let label = NSAttributedString(string: formatCount(value), attributes: yLabelAttrs)
            let labelSize = label.size()
            label.draw(at: CGPoint(x: chartRect.minX - labelSize.width - 4, y: y - labelSize.height / 2))
        }

        // Bars — slot width divides chart evenly so bars never overflow
        let barCount = data.bins.count
        let slotWidth = chartRect.width / CGFloat(barCount)
        let barGap: CGFloat = slotWidth > 4 ? 1 : 0
        let barDrawWidth = max(1, slotWidth - barGap)

        ctx.saveGState()
        ctx.clip(to: chartRect)
        ctx.setFillColor(data.barColor.cgColor)
        for (i, bin) in data.bins.enumerated() {
            let barHeight = maxValue > 0
                ? CGFloat(bin.value) / CGFloat(maxValue) * chartRect.height
                : 0
            let x = chartRect.minX + CGFloat(i) * slotWidth + barGap / 2
            let barRect = CGRect(
                x: x,
                y: chartRect.maxY - barHeight,
                width: barDrawWidth,
                height: barHeight
            )
            ctx.fill(barRect)
        }
        ctx.restoreGState()

        // X-axis labels (show a subset to avoid crowding)
        let xLabelAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 9, weight: .regular),
            .foregroundColor: NSColor.secondaryLabelColor,
        ]
        let maxXLabels = max(1, Int(chartRect.width / 50))
        let xLabelStride = max(1, barCount / maxXLabels)
        for i in stride(from: 0, to: barCount, by: xLabelStride) {
            let x = chartRect.minX + CGFloat(i) * slotWidth + slotWidth / 2
            let label = NSAttributedString(string: "\(data.bins[i].key)", attributes: xLabelAttrs)
            let labelSize = label.size()
            label.draw(at: CGPoint(x: x - labelSize.width / 2, y: chartRect.maxY + 4))
        }

        // Title
        let titleAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 13, weight: .semibold),
            .foregroundColor: NSColor.labelColor,
        ]
        let titleStr = NSAttributedString(string: data.title, attributes: titleAttrs)
        let titleSize = titleStr.size()
        titleStr.draw(at: CGPoint(x: bounds.midX - titleSize.width / 2, y: 6))

        // Axis labels
        let axisAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 10),
            .foregroundColor: NSColor.secondaryLabelColor,
        ]
        let xAxisStr = NSAttributedString(string: data.xLabel, attributes: axisAttrs)
        let xAxisSize = xAxisStr.size()
        xAxisStr.draw(at: CGPoint(x: chartRect.midX - xAxisSize.width / 2, y: chartRect.maxY + 22))

        // Y-axis label (drawn rotated)
        let yAxisStr = NSAttributedString(string: data.yLabel, attributes: axisAttrs)
        let yAxisSize = yAxisStr.size()
        ctx.saveGState()
        ctx.translateBy(x: 12, y: chartRect.midY + yAxisSize.width / 2)
        ctx.rotate(by: -.pi / 2)
        yAxisStr.draw(at: .zero)
        ctx.restoreGState()
    }

    override func rightMouseDown(with event: NSEvent) {
        guard data != nil else { return }
        let menu = NSMenu()
        let copyItem = NSMenuItem(title: "Copy Chart as PNG", action: #selector(copyChartToPasteboard(_:)), keyEquivalent: "")
        copyItem.target = self
        menu.addItem(copyItem)
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }

    @objc private func copyChartToPasteboard(_ sender: Any) {
        copyViewToPasteboard(self)
    }

    private func drawEmptyState(_ ctx: CGContext) {
        ctx.setFillColor(NSColor.controlBackgroundColor.cgColor)
        ctx.fill(bounds)

        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 13),
            .foregroundColor: NSColor.tertiaryLabelColor,
        ]
        let str = NSAttributedString(string: "No data available", attributes: attrs)
        let size = str.size()
        str.draw(at: CGPoint(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2))
    }

    private func formatCount(_ value: Int) -> String {
        if value >= 1_000_000 { return String(format: "%.1fM", Double(value) / 1_000_000) }
        if value >= 1_000 { return String(format: "%.1fK", Double(value) / 1_000) }
        return "\(value)"
    }
}

// MARK: - FASTQQualityBoxplotView

/// Per-position quality boxplot chart (FastQC-style).
///
/// Renders a boxplot at each read position showing the distribution of
/// quality scores. Color-coded background bands indicate quality zones:
/// green (>=30), yellow (20-30), red (<20).
@MainActor
final class FASTQQualityBoxplotView: NSView {

    private var summaries: [PositionQualitySummary] = []

    override var isFlipped: Bool { true }

    func update(with summaries: [PositionQualitySummary]) {
        self.summaries = summaries
        needsDisplay = true
        updateAccessibility(summaries)
    }

    private func updateAccessibility(_ summaries: [PositionQualitySummary]) {
        setAccessibilityRole(.image)
        setAccessibilityLabel("Per-Position Quality Boxplot")
        guard !summaries.isEmpty else {
            setAccessibilityValue("No data")
            return
        }
        let meanQ = summaries.reduce(0.0) { $0 + $1.mean } / Double(summaries.count)
        let desc = "\(summaries.count) positions, overall mean quality \(String(format: "%.1f", meanQ))"
        setAccessibilityValue(desc)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        guard !summaries.isEmpty else {
            drawEmptyState(ctx)
            return
        }

        let margins = NSEdgeInsets(top: 30, left: 50, bottom: 40, right: 20)
        let chartRect = CGRect(
            x: margins.left,
            y: margins.top,
            width: bounds.width - margins.left - margins.right,
            height: bounds.height - margins.top - margins.bottom
        )

        guard chartRect.width > 10, chartRect.height > 10 else { return }

        // Quality range: 0 to 42 (typical Illumina max)
        let maxQ: Double = 42
        let minQ: Double = 0

        // Background
        ctx.setFillColor(NSColor.controlBackgroundColor.cgColor)
        ctx.fill(bounds)

        // Quality zone backgrounds (FastQC style)
        drawQualityZones(ctx: ctx, chartRect: chartRect, maxQ: maxQ)

        // Grid lines
        ctx.setStrokeColor(NSColor.separatorColor.withAlphaComponent(0.3).cgColor)
        ctx.setLineWidth(0.5)
        for q in stride(from: 0, through: Int(maxQ), by: 5) {
            let y = chartRect.maxY - CGFloat(Double(q) / maxQ) * chartRect.height
            ctx.move(to: CGPoint(x: chartRect.minX, y: y))
            ctx.addLine(to: CGPoint(x: chartRect.maxX, y: y))
        }
        ctx.strokePath()

        // Y-axis labels
        let yLabelAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 9, weight: .regular),
            .foregroundColor: NSColor.secondaryLabelColor,
        ]
        for q in stride(from: 0, through: Int(maxQ), by: 5) {
            let y = chartRect.maxY - CGFloat(Double(q) / maxQ) * chartRect.height
            let label = NSAttributedString(string: "\(q)", attributes: yLabelAttrs)
            let labelSize = label.size()
            label.draw(at: CGPoint(x: chartRect.minX - labelSize.width - 4, y: y - labelSize.height / 2))
        }

        // Limit displayed positions to avoid overcrowding
        let maxPositions = min(summaries.count, Int(chartRect.width / 3))
        let stride = max(1, summaries.count / maxPositions)
        let displayedPositions = summaries.enumerated()
            .filter { $0.offset % stride == 0 }
            .map(\.element)

        let posCount = displayedPositions.count
        let boxSpacing: CGFloat = 1
        let boxWidth = max(2, (chartRect.width - boxSpacing * CGFloat(posCount + 1)) / CGFloat(posCount))

        for (i, summary) in displayedPositions.enumerated() {
            let x = chartRect.minX + boxSpacing + CGFloat(i) * (boxWidth + boxSpacing)

            func yForQ(_ q: Double) -> CGFloat {
                chartRect.maxY - CGFloat((q - minQ) / (maxQ - minQ)) * chartRect.height
            }

            let yMedian = yForQ(summary.median)
            let yQ1 = yForQ(summary.lowerQuartile)
            let yQ3 = yForQ(summary.upperQuartile)
            let yP10 = yForQ(summary.percentile10)
            let yP90 = yForQ(summary.percentile90)

            // Whiskers (10th to 90th percentile)
            ctx.setStrokeColor(NSColor.secondaryLabelColor.cgColor)
            ctx.setLineWidth(0.5)
            let midX = x + boxWidth / 2
            ctx.move(to: CGPoint(x: midX, y: yP10))
            ctx.addLine(to: CGPoint(x: midX, y: yQ1))
            ctx.move(to: CGPoint(x: midX, y: yQ3))
            ctx.addLine(to: CGPoint(x: midX, y: yP90))
            // Whisker caps
            ctx.move(to: CGPoint(x: x + 1, y: yP10))
            ctx.addLine(to: CGPoint(x: x + boxWidth - 1, y: yP10))
            ctx.move(to: CGPoint(x: x + 1, y: yP90))
            ctx.addLine(to: CGPoint(x: x + boxWidth - 1, y: yP90))
            ctx.strokePath()

            // Box (Q1 to Q3)
            let boxRect = CGRect(
                x: x,
                y: min(yQ1, yQ3),
                width: boxWidth,
                height: abs(yQ3 - yQ1)
            )
            ctx.setFillColor(NSColor.systemYellow.withAlphaComponent(0.6).cgColor)
            ctx.fill(boxRect)
            ctx.setStrokeColor(NSColor.systemYellow.withAlphaComponent(0.8).cgColor)
            ctx.setLineWidth(1)
            ctx.stroke(boxRect)

            // Median line (red)
            ctx.setStrokeColor(NSColor.systemRed.cgColor)
            ctx.setLineWidth(1.5)
            ctx.move(to: CGPoint(x: x, y: yMedian))
            ctx.addLine(to: CGPoint(x: x + boxWidth, y: yMedian))
            ctx.strokePath()

            // Mean marker (blue triangle)
            let yMean = yForQ(summary.mean)
            ctx.setFillColor(NSColor.systemBlue.cgColor)
            let triSize: CGFloat = 3
            ctx.move(to: CGPoint(x: midX, y: yMean - triSize))
            ctx.addLine(to: CGPoint(x: midX - triSize, y: yMean + triSize))
            ctx.addLine(to: CGPoint(x: midX + triSize, y: yMean + triSize))
            ctx.closePath()
            ctx.fillPath()
        }

        // X-axis labels (position numbers)
        let xLabelAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 9, weight: .regular),
            .foregroundColor: NSColor.secondaryLabelColor,
        ]
        let maxXLabels = max(1, Int(chartRect.width / 35))
        let xLabelStride = max(1, posCount / maxXLabels)
        for i in Swift.stride(from: 0, to: posCount, by: xLabelStride) {
            let x = chartRect.minX + boxSpacing + CGFloat(i) * (boxWidth + boxSpacing) + boxWidth / 2
            let label = NSAttributedString(string: "\(displayedPositions[i].position + 1)", attributes: xLabelAttrs)
            let labelSize = label.size()
            label.draw(at: CGPoint(x: x - labelSize.width / 2, y: chartRect.maxY + 4))
        }

        // Title
        let titleAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 13, weight: .semibold),
            .foregroundColor: NSColor.labelColor,
        ]
        let titleStr = NSAttributedString(string: "Per-Position Quality Scores", attributes: titleAttrs)
        let titleSize = titleStr.size()
        titleStr.draw(at: CGPoint(x: bounds.midX - titleSize.width / 2, y: 6))

        // Axis labels
        let axisAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 10),
            .foregroundColor: NSColor.secondaryLabelColor,
        ]
        let xAxisStr = NSAttributedString(string: "Position in Read (bp)", attributes: axisAttrs)
        let xAxisSize = xAxisStr.size()
        xAxisStr.draw(at: CGPoint(x: chartRect.midX - xAxisSize.width / 2, y: chartRect.maxY + 22))
    }

    override func rightMouseDown(with event: NSEvent) {
        guard !summaries.isEmpty else { return }
        let menu = NSMenu()
        let copyItem = NSMenuItem(title: "Copy Chart as PNG", action: #selector(copyChartToPasteboard(_:)), keyEquivalent: "")
        copyItem.target = self
        menu.addItem(copyItem)
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }

    @objc private func copyChartToPasteboard(_ sender: Any) {
        copyViewToPasteboard(self)
    }

    private func drawQualityZones(ctx: CGContext, chartRect: CGRect, maxQ: Double) {
        // Green zone: Q >= 30
        let greenTop = chartRect.maxY - CGFloat(30.0 / maxQ) * chartRect.height
        let greenRect = CGRect(x: chartRect.minX, y: chartRect.minY, width: chartRect.width, height: greenTop - chartRect.minY)
        ctx.setFillColor(NSColor.systemGreen.withAlphaComponent(0.08).cgColor)
        ctx.fill(greenRect)

        // Yellow zone: Q 20-30
        let yellowTop = chartRect.maxY - CGFloat(20.0 / maxQ) * chartRect.height
        let yellowRect = CGRect(x: chartRect.minX, y: greenTop, width: chartRect.width, height: yellowTop - greenTop)
        ctx.setFillColor(NSColor.systemYellow.withAlphaComponent(0.08).cgColor)
        ctx.fill(yellowRect)

        // Red zone: Q < 20
        let redRect = CGRect(x: chartRect.minX, y: yellowTop, width: chartRect.width, height: chartRect.maxY - yellowTop)
        ctx.setFillColor(NSColor.systemRed.withAlphaComponent(0.08).cgColor)
        ctx.fill(redRect)
    }

    private func drawEmptyState(_ ctx: CGContext) {
        ctx.setFillColor(NSColor.controlBackgroundColor.cgColor)
        ctx.fill(bounds)

        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 13),
            .foregroundColor: NSColor.tertiaryLabelColor,
        ]
        let str = NSAttributedString(string: "No per-position quality data", attributes: attrs)
        let size = str.size()
        str.draw(at: CGPoint(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2))
    }
}
