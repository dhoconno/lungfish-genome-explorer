// ViewerFigureAnnotationTrack.swift - The annotation track of a viewer figure
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import CoreGraphics
import CoreText
import Foundation
import LungfishCore
import LungfishIO

/// The annotation track as the live viewer draws it in its three modes, density, squished and
/// expanded, from the bundle's annotation databases, packed by `ViewerFigureAnnotationPacking`
/// and coloured by `ViewerFigureAnnotationColors`. It records in the scene what it leaves out:
/// features past the row cap or the track's height, labels with no room, the query limit, and
/// the embedded CDS translations it does not draw (BIO 4).
public struct ViewerFigureAnnotationTrack: ViewerFigureTrackBuilding {
    /// One annotation database, drawn as one track of the stack.
    public struct Source: Sendable, Hashable {
        public let id: String
        public let name: String
        public let databaseURL: URL

        public init(id: String, name: String, databaseURL: URL) {
            self.id = id
            self.name = name
            self.databaseURL = databaseURL
        }
    }

    /// The live view's settings, with `AppSettings` defaults.
    public struct Options: Sendable, Hashable {
        public var maxRows = 50
        public var featureHeight = 16.0
        public var rowSpacing = 2.0
        public var densityThreshold = 50_000.0
        public var squishedThreshold = 500.0
        public var showLettersThreshold = 10.0
        public var queryLimit = 50_000
        public var visibleTypes: Set<AnnotationType>?
        public var filterText = ""

        public init() {}
    }

    /// The face of the labels. The live labels use the system font, which has only a dot name
    /// that `CTFontCreateWithName` refuses, so the figure names Helvetica Neue.
    public static let fontNames = ["HelveticaNeue"]
    public static let mediumFontNames = ["HelveticaNeue-Medium"]
    static let maxSquishedFeatures = 5_000

    public let trackID: String
    public let sources: [Source]
    public let options: Options
    public let height: Double

    public init(trackID: String = "annotations", sources: [Source], height: Double, options: Options = Options()) {
        self.trackID = trackID
        self.sources = sources
        self.height = height
        self.options = options
    }

    public func build(into canvas: inout ViewerFigureCanvas, frame: ViewerFigureFrame, area: ViewerFigureRect) async throws {
        let annotations = try await load(frame: frame, canvas: &canvas)
        let names = Dictionary(sources.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
        try draw(annotations, displayNames: names, into: &canvas, frame: frame, area: area)
    }

    /// Reads each database once, off the main actor, and tags each feature with its source.
    nonisolated func load(frame: ViewerFigureFrame, canvas: inout ViewerFigureCanvas) async throws -> [SequenceAnnotation] {
        var annotations: [SequenceAnnotation] = []
        for source in sources {
            try Task.checkCancellation()
            let records = try AnnotationDatabase(url: source.databaseURL).queryByRegion(
                chromosome: frame.chromosome, start: Int(frame.start), end: Int(frame.end.rounded(.up)),
                limit: options.queryLimit
            )
            if records.count >= options.queryLimit {
                canvas.omit(ViewerFigureOmission(
                    trackID: trackID, kind: .annotationLimit, reason: "\(source.id) query limit \(options.queryLimit) records",
                    count: nil
                ))
            }
            for record in records {
                var annotation = record.toAnnotation()
                annotation.qualifiers[ViewerFigureAnnotationPacking.trackQualifier] = AnnotationQualifier(source.id)
                annotations.append(annotation)
            }
        }
        return annotations
    }

    /// Draws `annotations` in the area. `displayNames` names each track id in its label.
    public func draw(
        _ annotations: [SequenceAnnotation], displayNames: [String: String] = [:],
        into canvas: inout ViewerFigureCanvas, frame: ViewerFigureFrame, area: ViewerFigureRect
    ) throws(ViewerFigureFontError) {
        var drawer = AnnotationDrawer(track: self, frame: frame, area: area, displayNames: displayNames)
        try drawer.draw(annotations, into: &canvas)
    }
}

/// The drawing of one annotation track, the live view's three modes over canvas items.
private struct AnnotationDrawer {
    typealias Packing = ViewerFigureAnnotationPacking
    let track: ViewerFigureAnnotationTrack
    let frame: ViewerFigureFrame
    let area: ViewerFigureRect
    let displayNames: [String: String]
    var options: ViewerFigureAnnotationTrack.Options { track.options }

    init(track: ViewerFigureAnnotationTrack, frame: ViewerFigureFrame, area: ViewerFigureRect, displayNames: [String: String]) {
        self.track = track
        self.frame = frame
        self.area = area
        self.displayNames = displayNames
    }

    mutating func draw(_ annotations: [SequenceAnnotation], into canvas: inout ViewerFigureCanvas) throws(ViewerFigureFontError) {
        let visibleStart = Int(frame.start)
        let visibleEnd = Int(frame.end)
        var shown = annotations.filter { $0.end > visibleStart && $0.start < visibleEnd }
        if let types = options.visibleTypes { shown = shown.filter { types.contains($0.type) } }
        if !options.filterText.isEmpty {
            let needle = options.filterText.lowercased()
            shown = shown.filter { $0.name.lowercased().contains(needle) }
        }
        guard !shown.isEmpty else { return }
        let regionSpan = max(max(1, visibleEnd - visibleStart), frame.sequenceLength)
        let display = shown.filter { $0.type != .region || ($0.end - $0.start) < Int(Double(regionSpan) * 0.98) }
        omit(.scaleMode, "region features span the view", shown.count - display.count, into: &canvas)
        guard !display.isEmpty else {
            try label("\(shown.count) features (zoom in to see details)", x: 4, top: area.y + 2, size: 10, into: &canvas)
            return
        }
        let scale = frame.scale
        if scale > options.densityThreshold || (display.count > ViewerFigureAnnotationTrack.maxSquishedFeatures
            && scale > options.squishedThreshold) {
            try drawDensity(display, into: &canvas)
        } else if scale > options.squishedThreshold {
            try drawRows(display, squished: true, into: &canvas)
        } else {
            try drawRows(display, squished: false, into: &canvas)
        }
    }

    private func omit(_ kind: ViewerFigureOmissionKind, _ reason: String, _ count: Int?, into canvas: inout ViewerFigureCanvas) {
        guard count.map({ $0 > 0 }) ?? true else { return }
        canvas.omit(ViewerFigureOmission(trackID: track.trackID, kind: kind, reason: reason, count: count))
    }

    /// One line with the top of its line box at `top`, as `NSString.draw(in:)` placed it.
    private func label(
        _ string: String, x: Double, top: Double, size: Double, medium: Bool = false,
        paint: ViewerFigurePaint = ViewerFigurePaint(.secondaryLabel), into canvas: inout ViewerFigureCanvas
    ) throws(ViewerFigureFontError) {
        let names = medium ? ViewerFigureAnnotationTrack.mediumFontNames : ViewerFigureAnnotationTrack.fontNames
        let ascent = Double(CTFontGetAscent(try canvas.font(names, size: size)))
        try canvas.text(string, fontNames: names, size: size, at: ViewerFigurePoint(x: x, y: top + ascent),
                        anchor: .baselineStart, paint)
    }

    // MARK: - Density

    private func drawDensity(_ annotations: [SequenceAnnotation], into canvas: inout ViewerFigureCanvas) throws(ViewerFigureFontError) {
        let reason = frame.scale > options.densityThreshold
            ? "density above \(Int(options.densityThreshold)) bases per point"
            : "density for more than \(ViewerFigureAnnotationTrack.maxSquishedFeatures) features"
        omit(.scaleMode, reason, annotations.count, into: &canvas)
        let ids = Packing.orderedTrackIDs(for: annotations)
        guard ids.count > 1 else {
            return try drawDensity(annotations, top: area.y, prefix: nil, into: &canvas)
        }
        for (index, id) in ids.enumerated() {
            try drawDensity(annotations.filter { Packing.trackID(for: $0) == id }, top: area.y + Double(index) * 34,
                            prefix: displayNames[id] ?? id, into: &canvas)
        }
    }

    private func drawDensity(
        _ annotations: [SequenceAnnotation], top: Double, prefix: String?, into canvas: inout ViewerFigureCanvas
    ) throws(ViewerFigureFontError) {
        let dataWidth = Double(frame.dataPixelWidth)
        let inset = Double(frame.leadingInset)
        let binCount = max(1, Int(dataWidth))
        let bpPerBin = (frame.end - frame.start) / Double(binCount)
        var bins = [Int](repeating: 0, count: binCount)
        var typeCounts = [[AnnotationType: Int]](repeating: [:], count: binCount)
        for annotation in annotations {
            let first = max(0, Int((Double(annotation.start) - frame.start) / bpPerBin))
            let last = min(binCount - 1, Int((Double(annotation.end) - frame.start) / bpPerBin))
            guard first <= last else { continue }
            for bin in first...last {
                bins[bin] += 1
                typeCounts[bin][annotation.type, default: 0] += 1
            }
        }
        let maxCount = bins.max() ?? 1
        guard maxCount > 0 else { return }
        let trackHeight = 30.0
        canvas.fill(ViewerFigureRect(x: inset, y: top, width: dataWidth, height: trackHeight),
                    ViewerFigurePaint(.controlBackground, alpha: 0.3))
        for (index, count) in bins.enumerated() where count > 0 {
            let barHeight = trackHeight * Double(count) / Double(maxCount)
            // The live view takes any type of the largest count. A figure breaks the tie by type
            // name so two builds give one scene.
            let dominant = typeCounts[index].max {
                $0.value != $1.value ? $0.value < $1.value : $0.key.rawValue > $1.key.rawValue
            }?.key ?? .gene
            canvas.fill(ViewerFigureRect(x: inset + Double(index), y: top + trackHeight - barHeight, width: 1, height: barHeight),
                        ViewerFigurePaint(ViewerFigureAnnotationColors.role(for: dominant),
                                          alpha: ViewerFigureAnnotationColors.densityAlpha))
        }
        let text = prefix.map { "\($0): \(annotations.count) features" }
            ?? "\(annotations.count) features (zoom in to see details)"
        try label(text, x: inset + 4, top: top + 2, size: 10, into: &canvas)
    }

    // MARK: - Squished and expanded rows

    private func drawRows(_ annotations: [SequenceAnnotation], squished: Bool, into canvas: inout ViewerFigureCanvas) throws(ViewerFigureFontError) {
        let featureHeight = squished ? 6 : options.featureHeight
        let pitch = squished ? 7 : options.featureHeight + options.rowSpacing
        var (rows, overflow) = Packing.packLayered(annotations, frame: frame, maxRows: options.maxRows)
        omit(.annotationLimit, "max \(options.maxRows) rows", overflow, into: &canvas)
        // The figure's track has a fixed height, so rows past it are cut and counted.
        let fit = max(0, Int((area.height + pitch - featureHeight) / pitch))
        if rows.count > fit {
            let cut = rows[fit...].reduce(0) { $0 + $1.count }
            omit(.annotationLimit, "rows past the track height of \(Int(area.height)) points", cut, into: &canvas)
            rows = Array(rows.prefix(fit))
            overflow += cut
        }
        let tops = rows.indices.map { area.y + Double($0) * pitch }
        var labelsLeftOut = 0
        for (index, row) in rows.enumerated() {
            for annotation in row {
                labelsLeftOut += try drawFeature(annotation, top: tops[index], height: featureHeight, squished: squished,
                                                 rowCount: rows.count, into: &canvas)
            }
        }
        if squished {
            let labelled = rows.joined().filter { Packing.takesLabel($0.type) }.count
            omit(.labelsOmitted, "squished rows above \(Int(options.squishedThreshold)) bases per point", labelled, into: &canvas)
        } else {
            omit(.labelsOmitted, "narrower than 72 points or more than 12 rows", labelsLeftOut, into: &canvas)
            if frame.scale < options.showLettersThreshold {
                omit(.trackNotDrawn, "embedded CDS translations", rows.joined().filter { $0.type == .cds }.count, into: &canvas)
            }
        }
        try drawTrackLabels(rows: rows, tops: tops, into: &canvas)
        if overflow > 0 {
            try label("+\(overflow) more features", x: 4, top: area.y + Double(rows.count) * pitch, size: 9, into: &canvas)
        }
    }

    /// Draws one feature and returns 1 when it should have had a label and had no room.
    private func drawFeature(
        _ annotation: SequenceAnnotation, top: Double, height: Double, squished: Bool, rowCount: Int,
        into canvas: inout ViewerFigureCanvas
    ) throws(ViewerFigureFontError) -> Int {
        let role = ViewerFigureAnnotationColors.role(for: annotation.type)
        let fill = ViewerFigurePaint(role, alpha: ViewerFigureAnnotationColors.fillAlpha)
        let stroke = ViewerFigurePaint(role)
        let startX = Double(frame.screenPosition(for: Double(annotation.start)))
        let endX = Double(frame.screenPosition(for: Double(annotation.end)))
        let width = squished ? max(1, endX - startX) : max(3, endX - startX)
        let box = ViewerFigureRect(x: startX, y: top, width: width, height: height)
        let midY = top + height / 2
        let blocks = annotation.intervals.map { interval -> ViewerFigureRect in
            let x = Double(frame.screenPosition(for: Double(interval.start)))
            let x2 = Double(frame.screenPosition(for: Double(interval.end)))
            return ViewerFigureRect(x: x, y: top, width: max(1, x2 - x), height: height)
        }
        if squished {
            if annotation.isDiscontinuous {
                canvas.strokeSegments([segment(startX, midY, endX, midY)], lineWidth: 1, fill)
                for block in blocks { canvas.fill(block, fill) }
            } else {
                canvas.fill(box, fill)
            }
            return 0
        }
        var leftOut = 0
        if annotation.isDiscontinuous {
            canvas.fill(ViewerFigureRect(x: startX, y: midY - 1, width: width, height: 2), fill)
            for block in blocks {
                canvas.fill(block, fill)
                canvas.strokeRect(block, lineWidth: 1, stroke)
            }
            if width > 8 { drawStrandArrow(annotation.strand, box: box, into: &canvas) }
            leftOut = try drawFeatureLabel(annotation, box: box, rowCount: rowCount, into: &canvas)
        } else {
            canvas.fill(box, fill)
            canvas.strokeRect(box, lineWidth: 1, stroke)
            leftOut = try drawFeatureLabel(annotation, box: box, rowCount: rowCount, into: &canvas)
            if width > 8 { drawStrandArrow(annotation.strand, box: box, into: &canvas) }
        }
        return leftOut
    }

    /// The label inside the feature, cut at its tail with an ellipsis as the live view cut it.
    private func drawFeatureLabel(
        _ annotation: SequenceAnnotation, box: ViewerFigureRect, rowCount: Int, into canvas: inout ViewerFigureCanvas
    ) throws(ViewerFigureFontError) -> Int {
        guard Packing.takesLabel(annotation.type) else { return 0 }
        guard Packing.shouldRenderExpandedLabel(for: annotation, width: box.width, rowCount: rowCount) else { return 1 }
        let names = ViewerFigureAnnotationTrack.fontNames
        let room = box.width - 4
        var text = Packing.displayLabel(for: annotation)
        if try canvas.textWidth(text, fontNames: names, size: 10) > room {
            var kept = text
            text = ""
            while kept.count > 1 {
                kept.removeLast()
                let cut = kept + "\u{2026}"
                if try canvas.textWidth(cut, fontNames: names, size: 10) <= room {
                    text = cut
                    break
                }
            }
            if text.isEmpty { return 1 }
        }
        try label(text, x: box.x + 2, top: box.y + 1, size: 10, paint: ViewerFigurePaint(.text), into: &canvas)
        return 0
    }

    /// The live view's three-point arrow, as two segments.
    private func drawStrandArrow(_ strand: Strand, box: ViewerFigureRect, into canvas: inout ViewerFigureCanvas) {
        let size = 4.0
        let midY = box.y + box.height / 2
        let segments: [ViewerFigureSegment]
        switch strand {
        case .forward:
            let x = box.x + box.width - size - 2
            segments = [segment(x, midY - size / 2, x + size, midY), segment(x + size, midY, x, midY + size / 2)]
        case .reverse:
            let x = box.x + 2
            segments = [segment(x + size, midY - size / 2, x, midY), segment(x, midY, x + size, midY + size / 2)]
        default:
            return
        }
        canvas.strokeSegments(segments, lineWidth: 1, ViewerFigurePaint(.text, alpha: 0.5))
    }

    /// A rule above each track after the first, and the track's name, when there are several.
    private func drawTrackLabels(rows: [[SequenceAnnotation]], tops: [Double], into canvas: inout ViewerFigureCanvas) throws(ViewerFigureFontError) {
        guard Packing.orderedTrackIDs(for: Array(rows.joined())).count > 1 else { return }
        var previous: String?
        for (index, row) in rows.enumerated() {
            guard let first = row.first else { continue }
            let id = Packing.trackID(for: first)
            guard id != previous else { continue }
            if previous != nil {
                canvas.strokeSegments(
                    [segment(Double(frame.leadingInset), tops[index] - 2,
                             Double(frame.pixelWidth) - Double(frame.trailingInset), tops[index] - 2)],
                    lineWidth: 1, ViewerFigurePaint(.separator, alpha: 0.65)
                )
            }
            try label(displayNames[id] ?? id, x: Double(frame.leadingInset) + 4, top: tops[index] + 1, size: 9,
                      medium: true, into: &canvas)
            previous = id
        }
    }

    private func segment(_ x1: Double, _ y1: Double, _ x2: Double, _ y2: Double) -> ViewerFigureSegment {
        ViewerFigureSegment(from: ViewerFigurePoint(x: x1, y: y1), to: ViewerFigurePoint(x: x2, y: y2))
    }
}
