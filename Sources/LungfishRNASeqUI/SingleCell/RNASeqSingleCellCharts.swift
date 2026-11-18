// RNASeqSingleCellCharts.swift - The barcode rank plot and the histograms of a single-cell result
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// The charts draw what `RNASeqCellsDatabase+Bins.swift` read and count nothing. A position on screen is a value placed
// on an axis, and every label is a value of the file or an axis tick.

import AppKit
import LungfishIO

/// The cells ranked by UMIs, most first, on log axes. Each step is the run of ranks that one UMI count holds.
@MainActor
public final class RNASeqRankPlotView: NSView {
    public static let accessibilityID = "rnaseq-sc-rank-plot"

    public private(set) var steps: [RNASeqCellsDatabase.RankStep]
    private let inset = NSEdgeInsets(top: 12, left: 56, bottom: 28, right: 16)

    public init(steps: [RNASeqCellsDatabase.RankStep]) {
        self.steps = steps
        super.init(frame: NSRect(x: 0, y: 0, width: 520, height: 220))
        setAccessibilityElement(true)
        setAccessibilityRole(.image)
        setAccessibilityIdentifier(Self.accessibilityID)
        setAccessibilityLabel("Barcode rank plot of the cells")
        if let first = steps.first, let last = steps.last {
            setAccessibilityValue("Rank \(first.firstRank) holds \(first.umis) UMIs, rank \(last.lastRank) holds \(last.umis) UMIs")
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    public override var intrinsicContentSize: NSSize { NSSize(width: 520, height: 220) }
    public override var isFlipped: Bool { false }

    public override func draw(_ dirtyRect: NSRect) {
        let plot = NSRect(x: inset.left, y: inset.bottom, width: bounds.width - inset.left - inset.right,
                          height: bounds.height - inset.top - inset.bottom)
        RNASeqChartAxes.frame(plot)
        guard let maxRank = steps.last?.lastRank, let maxUMIs = steps.first?.umis, maxRank > 0, maxUMIs > 0 else { return }
        let xDecades = RNASeqChartAxes.decades(through: maxRank)
        let yDecades = RNASeqChartAxes.decades(through: maxUMIs)
        func x(_ rank: Int) -> CGFloat { plot.minX + plot.width * CGFloat(log10(Double(max(rank, 1)))) / CGFloat(xDecades) }
        func y(_ umis: Int) -> CGFloat { plot.minY + plot.height * CGFloat(log10(Double(max(umis, 1)))) / CGFloat(yDecades) }
        RNASeqChartAxes.logTicks(decades: xDecades, along: .horizontal, in: plot)
        RNASeqChartAxes.logTicks(decades: yDecades, along: .vertical, in: plot)
        let path = NSBezierPath()
        for (index, step) in steps.enumerated() {
            let left = NSPoint(x: x(step.firstRank), y: y(step.umis))
            if index == 0 { path.move(to: left) } else { path.line(to: left) }
            path.line(to: NSPoint(x: x(step.lastRank), y: y(step.umis)))
        }
        NSColor.controlAccentColor.setStroke()
        path.lineWidth = 1.5
        path.stroke()
        RNASeqChartAxes.label("Rank", at: NSPoint(x: plot.midX, y: 2), centered: true)
        RNASeqChartAxes.label("UMIs", at: NSPoint(x: 4, y: plot.maxY - 12), centered: false)
    }
}

/// The cells in each bin, one bar a bin, the bins in the order and widths the file reader gave.
@MainActor
public final class RNASeqHistogramView: NSView {
    public let histogram: RNASeqSingleCellSummary.Histogram
    private let inset = NSEdgeInsets(top: 12, left: 56, bottom: 28, right: 16)

    public init(histogram: RNASeqSingleCellSummary.Histogram) {
        self.histogram = histogram
        super.init(frame: NSRect(x: 0, y: 0, width: 520, height: 180))
        setAccessibilityElement(true)
        setAccessibilityRole(.image)
        setAccessibilityIdentifier("rnaseq-sc-histogram-\(histogram.id)")
        setAccessibilityLabel(histogram.title)
        setAccessibilityValue(histogram.bins.map { "\($0.lower) to under \($0.upper), \($0.cells) cells" }.joined(separator: "\n"))
        toolTip = histogram.title
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    public override var intrinsicContentSize: NSSize { NSSize(width: 520, height: 180) }

    public override func draw(_ dirtyRect: NSRect) {
        let plot = NSRect(x: inset.left, y: inset.bottom, width: bounds.width - inset.left - inset.right,
                          height: bounds.height - inset.top - inset.bottom)
        RNASeqChartAxes.frame(plot)
        let bins = histogram.bins
        guard let tallest = bins.map(\.cells).max(), tallest > 0 else { return }
        let width = plot.width / CGFloat(bins.count)
        NSColor.controlAccentColor.withAlphaComponent(0.8).setFill()
        for (index, bin) in bins.enumerated() where bin.cells > 0 {
            let height = plot.height * CGFloat(bin.cells) / CGFloat(tallest)
            NSBezierPath(rect: NSRect(x: plot.minX + CGFloat(index) * width + 1, y: plot.minY, width: max(width - 2, 1), height: height)).fill()
        }
        let every = max(1, bins.count / 6)
        for (index, bin) in bins.enumerated() where index % every == 0 {
            RNASeqChartAxes.label(String(bin.lower), at: NSPoint(x: plot.minX + CGFloat(index) * width, y: 2), centered: false)
        }
        RNASeqChartAxes.label(String(tallest), at: NSPoint(x: 4, y: plot.maxY - 12), centered: false)
        RNASeqChartAxes.label("cells", at: NSPoint(x: 4, y: plot.maxY - 26), centered: false)
    }
}

/// The frame, ticks and labels the two charts share.
@MainActor
enum RNASeqChartAxes {
    enum Direction { case horizontal, vertical }

    /// The powers of ten an axis needs to reach `value`, at least one.
    static func decades(through value: Int) -> Int {
        var decades = 1
        var reach = 10
        while reach < value, reach <= Int.max / 10 {
            reach *= 10
            decades += 1
        }
        return decades
    }

    static func frame(_ plot: NSRect) {
        NSColor.separatorColor.setStroke()
        let path = NSBezierPath()
        path.move(to: NSPoint(x: plot.minX, y: plot.maxY))
        path.line(to: NSPoint(x: plot.minX, y: plot.minY))
        path.line(to: NSPoint(x: plot.maxX, y: plot.minY))
        path.stroke()
    }

    /// A tick and its label at each power of ten, from 1.
    static func logTicks(decades: Int, along direction: Direction, in plot: NSRect) {
        NSColor.separatorColor.setStroke()
        var power = 1
        for decade in 0...decades {
            let share = CGFloat(decade) / CGFloat(decades)
            let path = NSBezierPath()
            switch direction {
            case .horizontal:
                let x = plot.minX + plot.width * share
                path.move(to: NSPoint(x: x, y: plot.minY))
                path.line(to: NSPoint(x: x, y: plot.minY - 4))
                label(String(power), at: NSPoint(x: x, y: plot.minY - 18), centered: true)
            case .vertical:
                let y = plot.minY + plot.height * share
                path.move(to: NSPoint(x: plot.minX, y: y))
                path.line(to: NSPoint(x: plot.minX - 4, y: y))
                label(String(power), at: NSPoint(x: plot.minX - 50, y: y - 6), centered: false)
            }
            path.stroke()
            if power <= Int.max / 10 { power *= 10 }
        }
    }

    static func label(_ text: String, at point: NSPoint, centered: Bool) {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize),
            .foregroundColor: NSColor.secondaryLabelColor,
        ]
        let string = NSAttributedString(string: text, attributes: attributes)
        let origin = centered ? NSPoint(x: point.x - string.size().width / 2, y: point.y) : point
        string.draw(at: origin)
    }
}
