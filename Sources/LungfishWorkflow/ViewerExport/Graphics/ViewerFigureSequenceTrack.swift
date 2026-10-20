// ViewerFigureSequenceTrack.swift - The reference sequence track of a viewer figure
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import CoreText
import Foundation
import LungfishCore
import LungfishIO

/// A contig the FASTA index does not name.
public enum ViewerFigureSequenceTrackError: Error, Hashable, LocalizedError {
    case contigNotFound(contig: String, fasta: String)

    public var errorDescription: String? {
        switch self {
        case .contigNotFound(let contig, let fasta):
            "The sequence \(contig) is not in the index of \(fasta), so its track cannot be drawn."
        }
    }
}

/// The reference sequence of a figure, read from an indexed FASTA through LungfishIO and drawn as
/// the live `SequenceViewerView.drawSequence` draws one sequence. Below `lettersThreshold` bases
/// per point each base is a coloured cell, with its letter when a base has 8 points
/// (`drawBaseLevelSequence`, `drawBasesWithLetters`). Up to `lineThreshold` each bin of bases is
/// one block in the colour of its most common base (`drawBlockLevelSequence`). From there on the
/// sequence is a grey bar (`drawLineSequence`, `drawSequenceLine`). Like the live view, the
/// track draws only inside the data area between the frame's insets.
///
/// Letters use `Menlo-Bold`, the face the read track names (13.29), since the live monospaced
/// system face has only a private dot name. Base colours come from `ViewerFigureTheme.baseRole(for:)`
/// and letters from `textOnColor`. What the scale hides is recorded as omissions (BIO ruling
/// Q-G3, items 7 and 10). Bases drawn as blocks or a bar give one `scaleMode` entry, and letters
/// with no room give one `labelsOmitted` entry, each with the count of bases.
public struct ViewerFigureSequenceTrack: ViewerFigureTrackBuilding {
    /// The id the track's omissions name.
    public static let trackID = "sequence"
    /// The live sequence track's height.
    public static let defaultHeight = 40.0
    /// The letter faces in order of preference, before the fonts' own fallback.
    public static let letterFontNames = ["Menlo-Bold"]
    /// The default of the app setting `showLettersThresholdBpPerPixel`.
    public static let defaultLettersThreshold = 10.0
    /// The live block mode threshold, from which the sequence is a bar.
    public static let lineThreshold = 300.0

    public let fastaURL: URL
    public let indexURL: URL
    public let height: Double
    public let lettersThreshold: Double
    /// Shows T as U, as the live view's RNA mode does. Otherwise U shows as T.
    public let showsRNA: Bool

    public init(
        fastaURL: URL, indexURL: URL? = nil, height: Double = ViewerFigureSequenceTrack.defaultHeight,
        lettersThreshold: Double = ViewerFigureSequenceTrack.defaultLettersThreshold, showsRNA: Bool = false
    ) {
        self.fastaURL = fastaURL
        self.indexURL = indexURL ?? fastaURL.appendingPathExtension("fai")
        self.height = height
        self.lettersThreshold = lettersThreshold
        self.showsRNA = showsRNA
    }

    /// The files the track reads, for the figure's record (BIO ruling Q-G3, item 5).
    public var inputFiles: [URL] {
        [fastaURL, indexURL]
    }

    public func build(into canvas: inout ViewerFigureCanvas, frame: ViewerFigureFrame, area: ViewerFigureRect) async throws {
        let reader = try IndexedFASTAReader(url: fastaURL, indexURL: indexURL)
        guard let entry = reader.index.entry(for: frame.chromosome) else {
            throw ViewerFigureSequenceTrackError.contigNotFound(contig: frame.chromosome, fasta: fastaURL.lastPathComponent)
        }
        let startBase = max(0, Int(frame.start))
        let endBase = min(entry.length, Int(frame.end) + 1)
        guard startBase < endBase else { return }
        let layout = Layout(
            left: area.x + Double(frame.leadingInset), right: area.x + area.width - Double(frame.trailingInset),
            top: area.y, height: area.height,
            pixelsPerBase: Double(frame.dataPixelWidth) / max(1, frame.end - frame.start)
        )
        let scale = frame.scale
        if scale >= Self.lineThreshold {
            drawBar(into: &canvas, layout: layout, bases: endBase - startBase, startOffset: startBase - Int(frame.start))
            canvas.omit(ViewerFigureOmission(
                trackID: Self.trackID, kind: .scaleMode,
                reason: "bases drawn as a bar at \(Self.number(scale)) bases per point, \(Self.number(Self.lineThreshold)) or more",
                count: endBase - startBase
            ))
            return
        }
        let region = GenomicRegion(chromosome: frame.chromosome, start: startBase, end: endBase)
        let bases = Array(try await reader.fetch(region: region).utf8)
        if scale < lettersThreshold {
            try drawBases(bases, into: &canvas, layout: layout)
        } else {
            drawBlocks(bases, into: &canvas, layout: layout, basesPerBin: max(1, Int(scale)))
            canvas.omit(ViewerFigureOmission(
                trackID: Self.trackID, kind: .scaleMode,
                reason: "bases drawn as blocks of their most common base at \(Self.number(scale)) bases per point, "
                    + "\(Self.number(lettersThreshold)) or more",
                count: bases.count
            ))
        }
    }

    /// Where the track draws, in figure points.
    struct Layout {
        let left: Double
        let right: Double
        let top: Double
        let height: Double
        let pixelsPerBase: Double

        /// Floating-point noise in a position, in points. `Double(offset) * pixelsPerBase` is off by
        /// about 3e-14 at 800 points, so a cell that fits the data area exactly can end a hair past it
        /// and the base after the window can begin a hair before it.
        static let tolerance = 1e-6

        /// `rect` cut to the data area, or nil when nothing of it is inside.
        func clipped(_ rect: ViewerFigureRect) -> ViewerFigureRect? {
            let x0 = max(rect.x, left), x1 = min(rect.x + rect.width, right)
            return x1 - x0 > Self.tolerance ? ViewerFigureRect(x: x0, y: rect.y, width: x1 - x0, height: rect.height) : nil
        }
    }

    private func drawBases(_ bases: [UInt8], into canvas: inout ViewerFigureCanvas, layout: Layout) throws {
        let letterSize = Self.letterFontSize(pixelsPerBase: layout.pixelsPerBase, trackHeight: layout.height)
        let font = try letterSize.map { try canvas.font(Self.letterFontNames, size: $0) }
        var lettersLeftOut = 0
        for (offset, byte) in bases.enumerated() {
            let base = Character(Unicode.Scalar(byte))
            let x = layout.left + Double(offset) * layout.pixelsPerBase
            let cell = ViewerFigureRect(x: x, y: layout.top, width: max(1, layout.pixelsPerBase - 0.5), height: layout.height)
            guard let visible = layout.clipped(cell) else { continue }
            canvas.fill(visible, ViewerFigurePaint(ViewerFigureTheme.baseRole(for: base)))
            guard let letterSize, let font, x >= layout.left - Layout.tolerance,
                  x + layout.pixelsPerBase <= layout.right + Layout.tolerance else {
                lettersLeftOut += 1
                continue
            }
            // The live view centres the letter's line box in the cell, so the baseline sits one
            // ascent below the box's top.
            let letter = displayLetter(base)
            let metrics = ViewerFigureFonts.metrics(letter, font: font)
            let boxTop = layout.top + (layout.height - (metrics.ascent + metrics.descent + metrics.leading)) / 2
            try canvas.text(
                letter, fontNames: Self.letterFontNames, size: letterSize,
                at: ViewerFigurePoint(x: x + layout.pixelsPerBase / 2, y: boxTop + metrics.ascent),
                anchor: .baselineCenter, ViewerFigurePaint(.textOnColor)
            )
        }
        if lettersLeftOut > 0 {
            let room = letterSize == nil
                ? "base letters need 8 points a base and \(Self.number(layout.pixelsPerBase)) points a base were drawn"
                : "base letters cut by the edge of the data area"
            canvas.omit(ViewerFigureOmission(trackID: Self.trackID, kind: .labelsOmitted, reason: room, count: lettersLeftOut))
        }
    }

    private func drawBlocks(_ bases: [UInt8], into canvas: inout ViewerFigureCanvas, layout: Layout, basesPerBin: Int) {
        for binStart in stride(from: 0, to: bases.count, by: basesPerBin) {
            let binEnd = min(binStart + basesPerBin, bases.count)
            let block = ViewerFigureRect(
                x: layout.left + Double(binStart) * layout.pixelsPerBase, y: layout.top,
                width: max(1, Double(binEnd - binStart) * layout.pixelsPerBase), height: layout.height
            )
            if let visible = layout.clipped(block) {
                let role = ViewerFigureTheme.baseRole(for: Self.dominantBase(bases[binStart ..< binEnd]))
                canvas.fill(visible, ViewerFigurePaint(role))
            }
        }
    }

    /// The grey bar of `drawLineSequence`, filled and then outlined at 70 % alpha. An outline cut
    /// by the data area's edge keeps only its sides inside it, as the live clip does.
    private func drawBar(into canvas: inout ViewerFigureCanvas, layout: Layout, bases: Int, startOffset: Int) {
        let startX = layout.left + Double(startOffset) * layout.pixelsPerBase
        let endX = layout.left + Double(startOffset + bases) * layout.pixelsPerBase
        let thickness = max(8, layout.height * 0.4)
        let bar = ViewerFigureRect(
            x: max(0, startX), y: layout.top + layout.height / 2 - thickness / 2,
            width: max(1, endX - startX), height: thickness
        )
        guard let visible = layout.clipped(bar) else { return }
        canvas.fill(visible, ViewerFigurePaint(.systemGray))
        let outline = ViewerFigurePaint(.systemGray, alpha: 0.7)
        if visible == bar {
            canvas.strokeRect(bar, lineWidth: 1, outline)
            return
        }
        let minY = bar.y, maxY = bar.y + bar.height, minX = visible.x, maxX = visible.x + visible.width
        var sides = [
            ViewerFigureRulerTrack.segment(minX, minY, maxX, minY), ViewerFigureRulerTrack.segment(minX, maxY, maxX, maxY),
        ]
        if bar.x >= layout.left {
            sides.append(ViewerFigureRulerTrack.segment(bar.x, minY, bar.x, maxY))
        }
        if bar.x + bar.width <= layout.right {
            sides.append(ViewerFigureRulerTrack.segment(bar.x + bar.width, minY, bar.x + bar.width, maxY))
        }
        canvas.strokeSegments(sides, lineWidth: 1, outline)
    }

    private func displayLetter(_ base: Character) -> String {
        let upper = base.uppercased()
        if showsRNA && upper == "T" {
            return "U"
        }
        return !showsRNA && upper == "U" ? "T" : upper
    }

    /// The letter size of the live `baseLetterFontSize`, or nil when a letter has no room.
    static func letterFontSize(pixelsPerBase: Double, trackHeight: Double) -> Double? {
        let size = min(pixelsPerBase * 0.75, trackHeight * 0.8)
        guard pixelsPerBase.isFinite, trackHeight.isFinite, size.isFinite, pixelsPerBase >= 8, size >= 6 else {
            return nil
        }
        return size
    }

    /// The most common base of a bin, upper case. The live view takes the largest count from a
    /// dictionary, whose order changes from run to run, so a tie there has no fixed winner. A
    /// figure breaks a tie in the order A, T, C, G, N and then by letter, so a scene repeats.
    static func dominantBase(_ bin: ArraySlice<UInt8>) -> Character {
        var counts: [UInt8: Int] = [:]
        for byte in bin {
            counts[(byte >= 0x61 && byte <= 0x7A) ? byte - 0x20 : byte, default: 0] += 1
        }
        let order = Array("ATCGN".utf8)
        let ranked = counts.keys.sorted { lhs, rhs in
            let left = order.firstIndex(of: lhs) ?? order.count, right = order.firstIndex(of: rhs) ?? order.count
            return (counts[lhs, default: 0], -left, -Int(lhs)) > (counts[rhs, default: 0], -right, -Int(rhs))
        }
        return Character(Unicode.Scalar(ranked.first ?? UInt8(ascii: "N")))
    }

    /// A number in at most four significant digits, the same in every locale.
    static func number(_ value: Double) -> String {
        String(format: "%.4g", value)
    }
}
