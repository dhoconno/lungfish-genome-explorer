// ViewerFigureRangeLabelTrack.swift - The contig name and range at the top of a viewer figure
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import CoreText
import Foundation

/// The band at the top of every figure that names what it shows, the contig and then the range and the contig's
/// length as the live info bar writes them (`EnhancedCoordinateRulerView.drawInfoBar`), such as `chr20`,
/// `250,001 - 250,400 bp` and `of 500.0 kb total` (3.0 lane EXPORT-IMG, walk WF-5). The live bar's zoom buttons and
/// position field are controls and stay out of a figure, so the band writes the contig name the field shows.
///
/// The contig name and the range use `Menlo-Regular` at 11 points, standing in for the live monospaced system face at
/// medium weight, and the length uses Helvetica Neue at 10 points for the system face. A run with no room is left
/// out from the end and recorded as one `labelsOmitted` omission with the count.
public struct ViewerFigureRangeLabelTrack: ViewerFigureTrackBuilding {
    /// The id the track's omission names.
    public static let trackID = "label"
    /// The height of the live info bar.
    public static let defaultHeight = 20.0
    public static let primaryFontNames = ViewerFigureRulerTrack.labelFontNames
    public static let primaryFontSize = 11.0
    public static let secondaryFontNames = ViewerFigureAnnotationTrack.fontNames
    public static let secondaryFontSize = 10.0
    /// The live bar's gap at the left edge and between two runs.
    static let horizontalPadding = 8.0

    public let height: Double

    public init(height: Double = ViewerFigureRangeLabelTrack.defaultHeight) {
        self.height = height
    }

    /// The runs the band writes, in order, the contig name, the range and the contig's length.
    public static func runs(frame: ViewerFigureFrame) -> [String] {
        let range = "\(ViewerFigureRulerTrack.grouped(Int(frame.start) + 1)) - \(ViewerFigureRulerTrack.grouped(Int(frame.end))) bp"
        return [frame.chromosome, range] + (totalText(frame.sequenceLength).map { [$0] } ?? [])
    }

    /// The contig's length as the live bar writes it, in Mb or kb with one decimal unless whole, and nil for a frame
    /// that knows no length.
    static func totalText(_ length: Int) -> String? {
        guard length > 0, length < Int.max else { return nil }
        if length >= 1_000_000 {
            let mb = Double(length) / 1_000_000
            return mb == Double(Int(mb)) ? "of \(Int(mb)) Mb total" : "of \(String(format: "%.1f", mb)) Mb total"
        }
        if length >= 1_000 {
            let kb = Double(length) / 1_000
            return kb == Double(Int(kb)) ? "of \(Int(kb)) kb total" : "of \(String(format: "%.1f", kb)) kb total"
        }
        return "of \(ViewerFigureRulerTrack.grouped(length)) bp total"
    }

    public func build(into canvas: inout ViewerFigureCanvas, frame: ViewerFigureFrame, area: ViewerFigureRect) async throws {
        canvas.fill(area, ViewerFigurePaint(.windowBackground))
        let runs = Self.runs(frame: frame)
        let right = area.x + area.width - Self.horizontalPadding
        var x = area.x + Self.horizontalPadding
        var drawn = 0
        for (index, run) in runs.enumerated() {
            let primary = index < 2
            let names = primary ? Self.primaryFontNames : Self.secondaryFontNames
            let size = primary ? Self.primaryFontSize : Self.secondaryFontSize
            let font = try canvas.font(names, size: size)
            let metrics = ViewerFigureFonts.metrics(run, font: font)
            guard x + metrics.width <= right else { break }
            let ascent = Double(CTFontGetAscent(font))
            let boxHeight = ascent + Double(CTFontGetDescent(font))
            try canvas.text(
                run, fontNames: names, size: size,
                at: ViewerFigurePoint(x: x, y: area.y + (area.height - boxHeight) / 2 + ascent), anchor: .baselineStart,
                ViewerFigurePaint(primary ? .label : .secondaryLabel)
            )
            x += metrics.width + Self.horizontalPadding
            drawn += 1
        }
        if drawn < runs.count {
            canvas.omit(ViewerFigureOmission(
                trackID: Self.trackID, kind: .labelsOmitted,
                reason: "\(runs.count - drawn) of \(runs.count) parts of the contig and range label had no room",
                count: runs.count - drawn
            ))
        }
    }
}
