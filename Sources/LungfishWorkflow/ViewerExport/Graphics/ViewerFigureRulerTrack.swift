// ViewerFigureRulerTrack.swift - The coordinate ruler of a viewer figure
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import CoreText
import Foundation

/// The coordinate ruler of a figure, its minor and major ticks, position labels, bottom line and
/// border, as the live `EnhancedCoordinateRulerView` draws its ruler band
/// (`drawCoordinateRuler`, `calculateTickInterval`, `formatPosition`). The live view's info bar
/// and mini map are controls and stay out of a figure. The ruler opens no file.
///
/// Labels use `Menlo-Regular` at 10 points. The live labels use the monospaced system face at
/// medium weight, which CoreText names only by a private dot name, so a figure names an
/// installed monospaced face instead. A label left out for lack of room is recorded as one
/// `labelsOmitted` omission with the count (BIO ruling Q-G3, item 7).
public struct ViewerFigureRulerTrack: ViewerFigureTrackBuilding {
    /// The id the track's omissions name.
    public static let trackID = "ruler"
    /// The height of the live ruler band.
    public static let defaultHeight = 20.0
    /// The label faces in order of preference, before the fonts' own fallback.
    public static let labelFontNames = ["Menlo-Regular"]
    public static let labelFontSize = 10.0
    /// The live view's least gap between a label and either edge.
    static let horizontalPadding = 8.0
    /// The live view's least gap between two labels.
    static let minimumLabelSpacing = 10.0

    public let height: Double

    public init(height: Double = ViewerFigureRulerTrack.defaultHeight) {
        self.height = height
    }

    public func build(into canvas: inout ViewerFigureCanvas, frame: ViewerFigureFrame, area: ViewerFigureRect) async throws {
        canvas.fill(area, ViewerFigurePaint(.windowBackground))
        if frame.end - frame.start > 0 {
            try drawRuler(into: &canvas, frame: frame, area: area)
        }
        // The live view's bottom border, drawn last.
        let bottom = area.y + area.height - 0.5
        canvas.strokeSegments([Self.segment(area.x, bottom, area.x + area.width, bottom)], lineWidth: 1, ViewerFigurePaint(.separator))
    }

    private func drawRuler(into canvas: inout ViewerFigureCanvas, frame: ViewerFigureFrame, area: ViewerFigureRect) throws {
        let visibleRange = frame.end - frame.start
        let pixelsPerBase = Double(frame.dataPixelWidth) / visibleRange
        let tickInterval = Self.tickInterval(visibleRange: visibleRange, pixelWidth: Double(frame.dataPixelWidth))
        let minorTickInterval = tickInterval / 5

        // The live view draws a label with the top of its line box one point below the band's top,
        // so the baseline sits one ascent lower. The ticks start under the label's line box.
        let font = try canvas.font(Self.labelFontNames, size: Self.labelFontSize)
        let sample = ViewerFigureFonts.metrics(Self.formatPosition(Int(tickInterval), tickInterval: tickInterval), font: font)
        let labelBaseline = area.y + 1 + sample.ascent
        let majorTickTop = area.y + sample.ascent + sample.descent + sample.leading + 2
        let majorTickBottom = area.y + area.height
        let minorTickTop = majorTickBottom - 4
        let leading = area.x + Double(frame.leadingInset)
        let rightEdge = area.x + area.width - Double(frame.trailingInset)

        var minorTicks: [ViewerFigureSegment] = []
        var minorPosition = (frame.start / minorTickInterval).rounded(.up) * minorTickInterval
        while minorPosition <= frame.end {
            if minorPosition.truncatingRemainder(dividingBy: tickInterval) != 0 {
                let x = leading + (minorPosition - frame.start) * pixelsPerBase
                if x >= leading && x <= rightEdge {
                    minorTicks.append(Self.segment(x, minorTickTop, x, majorTickBottom))
                }
            }
            minorPosition += minorTickInterval
        }
        canvas.strokeSegments(minorTicks, lineWidth: 0.5, ViewerFigurePaint(.tertiaryLabel))

        var majorTicks: [ViewerFigureSegment] = []
        var labels: [(text: String, x: Double)] = []
        var labelsLeftOut = 0
        var lastLabelRightEdge = -Double.greatestFiniteMagnitude
        let leftBound = area.x + max(Self.horizontalPadding, Double(frame.leadingInset))
        let rightBound = area.x + area.width - max(Self.horizontalPadding, Double(frame.trailingInset))
        var majorPosition = (frame.start / tickInterval).rounded(.up) * tickInterval
        while majorPosition <= frame.end {
            let x = leading + (majorPosition - frame.start) * pixelsPerBase
            if x >= leading && x <= rightEdge {
                majorTicks.append(Self.segment(x, majorTickTop, x, majorTickBottom))
                let label = Self.formatPosition(Int(majorPosition), tickInterval: tickInterval)
                let width = ViewerFigureFonts.metrics(label, font: font).width
                let left = x - width / 2
                if left >= leftBound && left + width <= rightBound && left >= lastLabelRightEdge + Self.minimumLabelSpacing {
                    labels.append((label, x))
                    lastLabelRightEdge = left + width
                } else {
                    labelsLeftOut += 1
                }
            }
            majorPosition += tickInterval
        }
        canvas.strokeSegments(majorTicks, lineWidth: 1, ViewerFigurePaint(.secondaryLabel))
        for label in labels {
            try canvas.text(
                label.text, fontNames: Self.labelFontNames, size: Self.labelFontSize,
                at: ViewerFigurePoint(x: label.x, y: labelBaseline), anchor: .baselineCenter, ViewerFigurePaint(.label)
            )
        }
        if labelsLeftOut > 0 {
            canvas.omit(ViewerFigureOmission(
                trackID: Self.trackID, kind: .labelsOmitted,
                reason: "\(labelsLeftOut) of \(labelsLeftOut + labels.count) position labels had no room", count: labelsLeftOut
            ))
        }

        // The line along the bottom of the ruler band.
        let baseline = majorTickBottom - 0.5
        canvas.strokeSegments([Self.segment(area.x, baseline, area.x + area.width, baseline)], lineWidth: 0.5, ViewerFigurePaint(.separator))
    }

    /// The major tick interval, a 1, 2 or 5 times a power of ten near one label each 80 points,
    /// as the live `calculateTickInterval` picks it.
    static func tickInterval(visibleRange: Double, pixelWidth: Double) -> Double {
        let targetLabelCount = max(1, pixelWidth / 80)
        let rawInterval = visibleRange / targetLabelCount
        let magnitude = pow(10, floor(log10(rawInterval)))
        let normalized = rawInterval / magnitude
        let niceNormalized: Double = if normalized <= 1.5 {
            1
        } else if normalized <= 3 {
            2
        } else if normalized <= 7 {
            5
        } else {
            10
        }
        return niceNormalized * magnitude
    }

    /// A position label, in Mb or kb with one decimal when the interval is that large, and
    /// otherwise in bases with thousands separators, as the live `formatPosition` writes it.
    static func formatPosition(_ position: Int, tickInterval: Double) -> String {
        if tickInterval >= 1_000_000 {
            let millions = Double(position) / 1_000_000
            return millions == Double(Int(millions)) ? "\(Int(millions)) Mb" : String(format: "%.1f Mb", millions)
        } else if tickInterval >= 1_000 {
            let thousands = Double(position) / 1_000
            return thousands == Double(Int(thousands)) ? "\(Int(thousands)) kb" : String(format: "%.1f kb", thousands)
        }
        return grouped(position)
    }

    /// `value` with a comma between groups of three digits. The live view's `NumberFormatter`
    /// writes this in an English locale, and a figure writes it in every locale.
    static func grouped(_ value: Int) -> String {
        let digits = String(value.magnitude)
        var result = value < 0 ? "-" : ""
        for (index, digit) in digits.enumerated() {
            if index > 0 && (digits.count - index) % 3 == 0 {
                result.append(",")
            }
            result.append(digit)
        }
        return result
    }

    static func segment(_ x1: Double, _ y1: Double, _ x2: Double, _ y2: Double) -> ViewerFigureSegment {
        ViewerFigureSegment(from: ViewerFigurePoint(x: x1, y: y1), to: ViewerFigurePoint(x: x2, y: y2))
    }
}
