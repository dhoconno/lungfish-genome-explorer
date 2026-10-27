// ViewerFigureDepthTrack.swift - The Depth track of a viewer figure
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishCore
import LungfishIO

/// The Depth track the live viewer draws above the reads of an alignment track, its coverage strip, which the window
/// always shows (`SequenceViewerView+Rendering.swift`, `ReadTrackRenderer.drawCoverage(depthPoints:...)`). It reads
/// `samtools depth` over the figure's region through `AlignmentDataProvider.fetchDepth`, under the read track's flag
/// and mapping-quality filters and no base-quality filter as the live view's defaults set them, and draws it through a
/// coverage layer in the scale the command names, with the legend, the covered share and the max and mean depth
/// (3.0 lane EXPORT-IMG, walk WF-5).
///
/// Above ``thresholdBasesPerPoint`` the track reads no depth. It draws one line where the strip would be, in the form
/// of the read track's line, and records a `trackNotDrawn` omission, so the image and the record say so.
public struct ViewerFigureDepthTrack: ViewerFigureTrackBuilding {
    /// The widest scale the figure reads depth at. `samtools depth` writes a line for each covered base, and 1,000
    /// bases a point keeps a figure of 1,648 points, the walk's width, near 1.6 million lines, which the provider
    /// reads well inside its 30-second limit.
    public static let thresholdBasesPerPoint = 1_000.0
    public static let fontNames = ViewerFigureReadTrack.fontNames

    /// The id of the alignment track the depth is of, which the track's omission names.
    public let trackID: String
    public let source: ViewerFigureReadTrack.Source?
    public let scaleMode: CoverageScaleMode
    public let excludeFlags: UInt16
    public let minMapQ: Int
    /// The live strip's 60 points when the track draws, and the height of one line when the scale leaves it out.
    public let height: Double

    public init(
        trackID: String, source: ViewerFigureReadTrack.Source?, frame: ViewerFigureFrame,
        scaleMode: CoverageScaleMode = .default, excludeFlags: UInt16 = 0x904, minMapQ: Int = 0
    ) {
        self.trackID = trackID
        self.source = source
        self.scaleMode = scaleMode
        self.excludeFlags = excludeFlags
        self.minMapQ = minMapQ
        self.height = Self.draws(at: frame) ? Double(ReadTrackRenderer.coverageTrackHeight) : ViewerFigureReadTrack.overflowBarHeight
    }

    /// Whether a figure of `frame` draws the depth.
    public static func draws(at frame: ViewerFigureFrame) -> Bool {
        frame.scale <= thresholdBasesPerPoint
    }

    public func build(into canvas: inout ViewerFigureCanvas, frame: ViewerFigureFrame, area: ViewerFigureRect) async throws {
        guard Self.draws(at: frame) else {
            try drawNote(into: &canvas, frame: frame, area: area)
            return
        }
        draw(try await load(frame: frame), into: &canvas, frame: frame, area: area)
    }

    /// Reads the depth of the window once, off the main actor. The live view asks again under the reference's contig
    /// name when the alignment's name for it gives nothing.
    nonisolated func load(frame: ViewerFigureFrame) async throws -> [ViewerFigureCoverageLayer.Depth] {
        guard let source else { return [] }
        try Task.checkCancellation()
        let start = max(0, Int(frame.start.rounded(.down)))
        let end = Int(frame.end.rounded(.up))
        guard end > start else { return [] }
        let provider = AlignmentDataProvider(
            alignmentPath: source.alignmentPath, indexPath: source.indexPath, format: source.format,
            referenceFastaPath: source.referenceFastaPath
        )
        let name = source.alignmentChromosome(for: frame.chromosome)
        var points = try await provider.fetchDepth(
            chromosome: name, start: start, end: end, minMapQ: minMapQ, minBaseQ: 0, excludeFlags: excludeFlags
        )
        if points.isEmpty, name != frame.chromosome {
            points = (try? await provider.fetchDepth(
                chromosome: frame.chromosome, start: start, end: end, minMapQ: minMapQ, minBaseQ: 0, excludeFlags: excludeFlags
            )) ?? []
        }
        return points.filter { $0.depth > 0 && $0.position >= start && $0.position < end }
            .map { ViewerFigureCoverageLayer.Depth(position: $0.position, depth: $0.depth) }
    }

    /// Draws `depths` across the area as one coverage layer.
    public func draw(
        _ depths: [ViewerFigureCoverageLayer.Depth], into canvas: inout ViewerFigureCanvas, frame: ViewerFigureFrame,
        area: ViewerFigureRect
    ) {
        canvas.layer(.coverage(ViewerFigureCoverageLayer(
            rect: area, regionStart: Int(frame.start.rounded(.down)), regionEnd: Int(frame.end.rounded(.up)),
            depths: depths, scaleMode: scaleMode
        )))
    }

    /// The line drawn in place of the depth, in full and in short for a narrow figure, in the form of the read track's
    /// line (UX ruling on WF-5).
    static func noteLines(frame: ViewerFigureFrame) -> (full: String, short: String) {
        let widest = Int((thresholdBasesPerPoint * Double(frame.dataPixelWidth)).rounded(.down))
        let short = "Depth not drawn at \(String(format: "%.1f", frame.scale)) bases per point."
        return (short + " Export \(widest) bases or fewer at this width to draw it.", short)
    }

    private func drawNote(into canvas: inout ViewerFigureCanvas, frame: ViewerFigureFrame, area: ViewerFigureRect) throws {
        canvas.omit(ViewerFigureOmission(
            trackID: trackID, kind: .trackNotDrawn,
            reason: "depth not drawn above \(ViewerFigureReadTrack.points(Self.thresholdBasesPerPoint)) bases per point",
            count: nil
        ))
        guard area.height >= ViewerFigureReadTrack.overflowBarHeight else { return }
        let lines = Self.noteLines(frame: frame)
        let fits = try canvas.textWidth(lines.full, fontNames: Self.fontNames, size: 9) <= area.width - 8
        try ViewerFigureReadTrack.drawLine(fits ? lines.full : lines.short, top: area.y, area: area, into: &canvas)
    }
}
