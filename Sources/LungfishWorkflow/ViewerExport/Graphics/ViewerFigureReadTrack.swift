// ViewerFigureReadTrack.swift - The read track of a viewer figure
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import CoreGraphics
import CoreText
import Foundation
import LungfishCore
import LungfishIO

/// The read track as the live viewer draws it in its packed tier, from one alignment file read
/// through `AlignmentDataProvider`, sampled by `ViewerFigureReadSample` and packed by the moved
/// `ReadTrackRenderer.packReads`. It records in the scene what it leaves out: reads past the row
/// cap or the track's height, the reads the sample or the fetch limit dropped, reads too narrow to
/// draw, the reads of the coverage tier, and the base letters of the base tier (BIO 4).
public struct ViewerFigureReadTrack: ViewerFigureTrackBuilding {
    /// One indexed alignment file.
    public struct Source: Sendable, Hashable {
        public let alignmentPath: String
        public let indexPath: String
        public let format: AlignmentFormat
        public let referenceFastaPath: String?
        /// The live view's alignment contig names, a reference chromosome name to the name the file
        /// uses (`SequenceViewerView.alignmentChromosomeName(for:)`), for a file that names its
        /// contigs differently from the reference. A name outside the map is used as it is.
        public let chromosomeAliases: [String: String]

        public init(
            alignmentPath: String, indexPath: String, format: AlignmentFormat = .bam, referenceFastaPath: String? = nil,
            chromosomeAliases: [String: String] = [:]
        ) {
            self.alignmentPath = alignmentPath
            self.indexPath = indexPath
            self.format = format
            self.referenceFastaPath = referenceFastaPath
            self.chromosomeAliases = chromosomeAliases
        }

        /// The name the alignment file holds `reference` under.
        public func alignmentChromosome(for reference: String) -> String {
            chromosomeAliases[reference] ?? reference
        }
    }

    /// The live view's settings, with its defaults.
    public struct Options: Sendable, Hashable {
        public var maxRows = 75
        public var maxReads = 5_000
        public var fetchLimit = 100_000
        public var excludeFlags: UInt16 = 0x904
        public var minMapQ = 0
        public var sortMode: ReadSortMode = .position
        public var verticalCompress = false
        public var showStrandColors = true
        public var showSoftClips = true
        public var showIndels = true
        /// The reference over the window, for mismatch ticks. Without it the MD tag and CIGAR `X`
        /// operations place them, as in the live view.
        public var referenceSequence: String?
        public var referenceStart = 0

        public init() {}
    }

    /// The face of the overflow line. The live line uses the system font, which has only a dot
    /// name that `CTFontCreateWithName` refuses, so the figure names Helvetica Neue.
    public static let fontNames = ViewerFigureAnnotationTrack.fontNames
    static let overflowBarHeight = 16.0

    public let trackID: String
    public let source: Source?
    public let options: Options
    public let height: Double

    public init(trackID: String = "reads", source: Source?, height: Double, options: Options = Options()) {
        self.trackID = trackID
        self.source = source
        self.height = height
        self.options = options
    }

    public func build(into canvas: inout ViewerFigureCanvas, frame: ViewerFigureFrame, area: ViewerFigureRect) async throws {
        let reads = try await load(frame: frame, canvas: &canvas)
        try draw(reads, into: &canvas, frame: frame, area: area)
    }

    /// Reads the window once, off the main actor.
    nonisolated func load(frame: ViewerFigureFrame, canvas: inout ViewerFigureCanvas) async throws -> [AlignedRead] {
        guard let source else { return [] }
        try Task.checkCancellation()
        let provider = AlignmentDataProvider(
            alignmentPath: source.alignmentPath, indexPath: source.indexPath, format: source.format,
            referenceFastaPath: source.referenceFastaPath
        )
        let reads = try await provider.fetchReads(
            chromosome: source.alignmentChromosome(for: frame.chromosome), start: max(0, Int(frame.start)),
            end: Int(frame.end.rounded(.up)),
            excludeFlags: options.excludeFlags, minMapQ: options.minMapQ, maxReads: options.fetchLimit
        )
        if reads.count >= options.fetchLimit {
            canvas.omit(ViewerFigureOmission(
                trackID: trackID, kind: .readSample, reason: "fetch limit \(options.fetchLimit) reads", count: nil
            ))
        }
        return reads
    }

    /// Draws `reads` in the area.
    public func draw(
        _ reads: [AlignedRead], into canvas: inout ViewerFigureCanvas, frame: ViewerFigureFrame, area: ViewerFigureRect
    ) throws(ViewerFigureFontError) {
        let windowStart = Int(frame.start.rounded(.down))
        let windowEnd = Int(frame.end.rounded(.up))
        let shown = reads.filter { $0.alignmentEnd > windowStart && $0.position < windowEnd }
        guard !shown.isEmpty else { return }
        let tier = ReadTrackRenderer.zoomTier(scale: frame.scale)
        if tier == .coverage {
            omit(.scaleMode, "reads drawn as coverage above 2 bases per point", shown.count, into: &canvas)
            return
        }
        let sample = ViewerFigureReadSample.sample(shown, maxReads: options.maxReads)
        if sample.reads.count < sample.totalCount {
            omit(.readSample, ViewerFigureReadSample.rule(maxReads: options.maxReads),
                 sample.totalCount - sample.reads.count, into: &canvas)
        }
        let (packed, overflow) = ReadTrackRenderer.packReads(
            sample.reads, frame: frame, maxRows: options.maxRows, sortMode: options.sortMode
        )
        if overflow > 0 {
            omit(.readRowCap, "max \(options.maxRows) rows", overflow, into: &canvas)
        }
        let metrics = ReadTrackRenderer.layoutMetrics(verticalCompress: options.verticalCompress)
        let drawer = ViewerFigureReadDrawer(
            options: options, frame: frame,
            readHeight: Double(tier == .base ? metrics.baseReadHeight : metrics.packedReadHeight)
        )
        let pitch = drawer.readHeight + Double(metrics.rowGap)
        var pastHeight = 0
        // `packReads` skips a read narrower than the live two-point minimum without counting it.
        var narrow = sample.reads.count - packed.count - overflow
        var drawn = 0
        for (row, read) in packed {
            let y = area.y + Double(row) * pitch
            guard y + drawer.readHeight <= area.y + area.height - (overflow > 0 ? Self.overflowBarHeight : 0) else {
                pastHeight += 1
                continue
            }
            if drawer.draw(read, y: y, into: &canvas) { drawn += 1 } else { narrow += 1 }
        }
        if pastHeight > 0 {
            omit(.readRowCap, "rows past the track height of \(Self.points(area.height)) points", pastHeight, into: &canvas)
        }
        if narrow > 0 {
            omit(.scaleMode, "reads narrower than \(Self.points(Double(ReadTrackRenderer.minReadPixels))) points", narrow, into: &canvas)
        }
        if tier == .base, drawn > 0 {
            omit(.labelsOmitted, "base letters of the base tier", drawn, into: &canvas)
        }
        if overflow > 0 {
            try drawOverflow(overflow, area: area, into: &canvas)
        }
    }

    private func omit(_ kind: ViewerFigureOmissionKind, _ reason: String, _ count: Int?, into canvas: inout ViewerFigureCanvas) {
        canvas.omit(ViewerFigureOmission(trackID: trackID, kind: kind, reason: reason, count: count))
    }

    /// The live overflow bar at the bottom of the track, with its line centred in it.
    private func drawOverflow(_ overflow: Int, area: ViewerFigureRect, into canvas: inout ViewerFigureCanvas) throws(ViewerFigureFontError) {
        let barTop = area.y + area.height - Self.overflowBarHeight
        canvas.fill(ViewerFigureRect(x: area.x, y: barTop, width: area.width, height: Self.overflowBarHeight),
                    ViewerFigurePaint(.quaternarySystemFill))
        let font = try canvas.font(Self.fontNames, size: 9)
        let ascent = Double(CTFontGetAscent(font))
        let boxHeight = ascent + Double(CTFontGetDescent(font))
        try canvas.text(
            "+\(overflow) reads not shown (max \(options.maxRows) rows)", fontNames: Self.fontNames, size: 9,
            at: ViewerFigurePoint(x: area.x + area.width / 2, y: barTop + (Self.overflowBarHeight - boxHeight) / 2 + ascent),
            anchor: .baselineCenter, ViewerFigurePaint(.label)
        )
    }

    static func points(_ value: Double) -> String {
        value == value.rounded() ? String(Int(value)) : String(value)
    }
}
