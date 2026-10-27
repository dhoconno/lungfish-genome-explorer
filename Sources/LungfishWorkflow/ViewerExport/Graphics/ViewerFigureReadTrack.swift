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
/// `ReadTrackRenderer.packReads`. It marks each mismatch as the live view does at the figure's zoom,
/// against the bundle's reference over the reads (OBS-W7). It records in the scene what it leaves
/// out: reads past the row cap or the track's height, which its footnote counts too, the reads the
/// sample or the fetch limit dropped, reads too narrow to draw, the reads and mismatch marks of the
/// coverage tier, which a line in the track names, and the base letters of the base tier (BIO 4).
public struct ViewerFigureReadTrack: ViewerFigureTrackBuilding {
    /// A reference FASTA with its `.fai` and, when bgzipped, its `.gzi`.
    public struct ReferenceFASTA: Sendable, Hashable {
        public let fastaURL: URL
        public let indexURL: URL
        public let gzipIndexURL: URL?

        public init(fastaURL: URL, indexURL: URL, gzipIndexURL: URL? = nil) {
            self.fastaURL = fastaURL
            self.indexURL = indexURL
            self.gzipIndexURL = gzipIndexURL
        }
    }

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
        /// The reference the track compares the reads with to place the mismatch marks, as the live
        /// view compares them with the bundle's sequence. Nil leaves the MD tag and CIGAR `X` to place
        /// them (OBS-W7).
        public let mismatchReference: ReferenceFASTA?

        public init(
            alignmentPath: String, indexPath: String, format: AlignmentFormat = .bam, referenceFastaPath: String? = nil,
            chromosomeAliases: [String: String] = [:], mismatchReference: ReferenceFASTA? = nil
        ) {
            self.alignmentPath = alignmentPath
            self.indexPath = indexPath
            self.format = format
            self.referenceFastaPath = referenceFastaPath
            self.chromosomeAliases = chromosomeAliases
            self.mismatchReference = mismatchReference
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
        var drawing = options
        if drawing.referenceSequence == nil, ReadTrackRenderer.zoomTier(scale: frame.scale) != .coverage,
           let window = try await referenceWindow(covering: reads, chromosome: frame.chromosome) {
            drawing.referenceSequence = window.bases
            drawing.referenceStart = window.start
        }
        try ViewerFigureReadTrack(trackID: trackID, source: source, height: height, options: drawing)
            .draw(reads, into: &canvas, frame: frame, area: area)
    }

    /// The reference bases under `reads`, from their first base to their last, read from the
    /// source's `mismatchReference` as the sequence track reads the bundle's FASTA. Nil with no
    /// reference, no read or a contig the FASTA does not hold.
    nonisolated func referenceWindow(
        covering reads: [AlignedRead], chromosome: String
    ) async throws -> (bases: String, start: Int)? {
        guard let fasta = source?.mismatchReference, let first = reads.map(\.position).min(),
              let last = reads.map(\.alignmentEnd).max() else { return nil }
        try Task.checkCancellation()
        let start = max(0, first)
        if let gzipIndexURL = fasta.gzipIndexURL {
            let reader = try await BgzipIndexedFASTAReader(url: fasta.fastaURL, faiURL: fasta.indexURL, gziURL: gzipIndexURL)
            guard let entry = await reader.fastaIndex.entry(for: chromosome), start < min(last, entry.length) else { return nil }
            return (try await reader.fetch(region: GenomicRegion(chromosome: chromosome, start: start, end: min(last, entry.length))), start)
        }
        let reader = try IndexedFASTAReader(url: fasta.fastaURL, indexURL: fasta.indexURL)
        guard let entry = reader.index.entry(for: chromosome), start < min(last, entry.length) else { return nil }
        return (try await reader.fetch(region: GenomicRegion(chromosome: chromosome, start: start, end: min(last, entry.length))), start)
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
            // The live view draws no read and no mismatch mark here, only its coverage strip and a line
            // that asks for a closer zoom, so the figure draws its own line where the reads would be (OBS-W7).
            let threshold = Self.points(ReadTrackRenderer.coverageThresholdBpPerPx)
            omit(.scaleMode, "reads and mismatch marks above \(threshold) bases per point", shown.count, into: &canvas)
            if area.height >= Self.overflowBarHeight {
                let lines = Self.zoomLines(frame: frame)
                let fits = try canvas.textWidth(lines.full, fontNames: Self.fontNames, size: 9) <= area.width - 8
                try Self.drawLine(fits ? lines.full : lines.short, top: area.y, area: area, into: &canvas)
            }
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
        // The bar under the reads holds the footnote. It is kept when the row cap left reads out, as
        // in the live view, and when rows run past the track's height and the bar and one row fit, so
        // the image counts every read its rows leave out (OBS-W7).
        let rows = (packed.map(\.row).max() ?? -1) + 1
        let pastBottom = rows > 0 && Double(rows - 1) * pitch + drawer.readHeight > area.height
        let bar = overflow > 0 || (pastBottom && area.height >= Self.overflowBarHeight + drawer.readHeight)
        let bottom = area.y + area.height - (bar ? Self.overflowBarHeight : 0)
        var pastHeight = 0
        // `packReads` skips a read narrower than the live two-point minimum without counting it.
        var narrow = sample.reads.count - packed.count - overflow
        var drawn = 0
        for (row, read) in packed {
            let y = area.y + Double(row) * pitch
            guard y + drawer.readHeight <= bottom else {
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
        if bar {
            try Self.drawLine(
                Self.overflowLine(capped: overflow, pastHeight: pastHeight, maxRows: options.maxRows, height: area.height),
                top: area.y + area.height - Self.overflowBarHeight, area: area, into: &canvas
            )
        }
    }

    /// The footnote under the reads. It is the live overflow line, `+N reads not shown (max R rows)`,
    /// and it counts the reads past the track's height too (OBS-W7).
    static func overflowLine(capped: Int, pastHeight: Int, maxRows: Int, height: Double) -> String {
        var limits: [String] = []
        if capped > 0 { limits.append("max \(maxRows) rows") }
        if pastHeight > 0 { limits.append("track height \(points(height)) points") }
        return "+\(capped + pastHeight) reads not shown (\(limits.joined(separator: ", ")))"
    }

    /// The line the track draws above 2 bases a point in place of the live view's line that asks
    /// for a closer zoom, in full and in short for a narrow figure (OBS-W7).
    static func zoomLines(frame: ViewerFigureFrame) -> (full: String, short: String) {
        let widest = Int((ReadTrackRenderer.coverageThresholdBpPerPx * Double(frame.dataPixelWidth)).rounded(.down))
        let short = "Reads and mismatch marks not drawn at \(String(format: "%.1f", frame.scale)) bases per point."
        return (short + " Export \(widest) bases or fewer at this width to draw them.", short)
    }

    private func omit(_ kind: ViewerFigureOmissionKind, _ reason: String, _ count: Int?, into canvas: inout ViewerFigureCanvas) {
        canvas.omit(ViewerFigureOmission(trackID: trackID, kind: kind, reason: reason, count: count))
    }

    /// The live overflow bar across the track with its top at `barTop`, and `line` centred in it. The Depth track draws
    /// its line in the same bar.
    static func drawLine(
        _ line: String, top barTop: Double, area: ViewerFigureRect, into canvas: inout ViewerFigureCanvas
    ) throws(ViewerFigureFontError) {
        canvas.fill(ViewerFigureRect(x: area.x, y: barTop, width: area.width, height: Self.overflowBarHeight),
                    ViewerFigurePaint(.quaternarySystemFill))
        let font = try canvas.font(Self.fontNames, size: 9)
        let ascent = Double(CTFontGetAscent(font))
        let boxHeight = ascent + Double(CTFontGetDescent(font))
        try canvas.text(
            line, fontNames: Self.fontNames, size: 9,
            at: ViewerFigurePoint(x: area.x + area.width / 2, y: barTop + (Self.overflowBarHeight - boxHeight) / 2 + ascent),
            anchor: .baselineCenter, ViewerFigurePaint(.label)
        )
    }

    static func points(_ value: Double) -> String {
        value == value.rounded() ? String(Int(value)) : String(value)
    }
}
