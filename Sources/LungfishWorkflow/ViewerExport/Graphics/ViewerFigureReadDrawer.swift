// ViewerFigureReadDrawer.swift - One packed read of a viewer figure over canvas items
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishCore

/// Draws one read as `ReadTrackRenderer.drawPackedReads` does, over the four scene item kinds:
/// the soft clips, the body with its pointed strand end, the outline, the mismatch ticks, the
/// deletion and intron lines and the insertion ticks, in that order. A scene has no filled
/// polygon, so the pointed end is filled by one-point horizontal strips whose ends follow the
/// tip's two edges, and a deletion's two-point dash is drawn as its segments.
struct ViewerFigureReadDrawer {
    typealias Point = ViewerFigurePoint
    typealias Segment = ViewerFigureSegment

    let options: ViewerFigureReadTrack.Options
    let frame: ViewerFigureFrame
    let readHeight: Double
    let refBytes: [UInt8]?

    init(options: ViewerFigureReadTrack.Options, frame: ViewerFigureFrame, readHeight: Double) {
        self.options = options
        self.frame = frame
        self.readHeight = readHeight
        self.refBytes = options.referenceSequence.map(ReadTrackRenderer.uppercaseASCIIBytes)
    }

    /// Draws `read` with its top at `y`, and returns false for a read narrower than the live
    /// view's two-point minimum, which it leaves out.
    func draw(_ read: AlignedRead, y: Double, into canvas: inout ViewerFigureCanvas) -> Bool {
        let startPx = x(read.position)
        let width = x(read.alignmentEnd) - startPx
        guard width >= Double(ReadTrackRenderer.minReadPixels) else { return false }
        let alpha = Double(ReadTrackRenderer.mapqAlpha(read.mapq))
        let colours = paints(read, alpha: alpha)
        if options.showSoftClips { softClips(read, y: y, alpha: alpha, into: &canvas) }
        let rect = ViewerFigureRect(x: startPx, y: y, width: width, height: readHeight)
        if width > 6 {
            pointed(rect, reverse: read.isReverse, fill: colours.fill, stroke: colours.stroke, into: &canvas)
        } else {
            canvas.fill(rect, colours.fill)
        }
        mismatches(read, y: y, into: &canvas)
        if options.showIndels { indels(read, y: y, into: &canvas) }
        return true
    }

    private func x(_ position: Int) -> Double {
        Double(frame.screenPosition(for: Double(position)))
    }

    private func paints(_ read: AlignedRead, alpha: Double) -> (fill: ViewerFigurePaint, stroke: ViewerFigurePaint) {
        guard options.showStrandColors else {
            return (ViewerFigurePaint(.systemGray, alpha: alpha), ViewerFigurePaint(.tertiaryLabel, alpha: alpha))
        }
        return (
            ViewerFigurePaint(read.isReverse ? .reverseRead : .forwardRead, alpha: alpha),
            ViewerFigurePaint(read.isReverse ? .reverseReadStroke : .forwardReadStroke, alpha: alpha)
        )
    }

    private func softClips(_ read: AlignedRead, y: Double, alpha: Double, into canvas: inout ViewerFigureCanvas) {
        let paint = ViewerFigurePaint(.softClip, alpha: alpha * 0.5)
        if let first = read.cigar.first, first.op == .softClip {
            let alignStart = x(read.position)
            let clipStart = x(read.position - first.length)
            if alignStart - clipStart >= 1 {
                canvas.fill(ViewerFigureRect(x: clipStart, y: y, width: alignStart - clipStart, height: readHeight), paint)
            }
        }
        if let last = read.cigar.last, last.op == .softClip {
            let alignEnd = x(read.alignmentEnd)
            let clipEnd = x(read.alignmentEnd + last.length)
            if clipEnd - alignEnd >= 1 {
                canvas.fill(ViewerFigureRect(x: alignEnd, y: y, width: clipEnd - alignEnd, height: readHeight), paint)
            }
        }
    }

    /// The live pentagon. Its inset is at most 3 points and 15 percent of the width.
    private func pointed(
        _ rect: ViewerFigureRect, reverse: Bool, fill: ViewerFigurePaint, stroke: ViewerFigurePaint,
        into canvas: inout ViewerFigureCanvas
    ) {
        let inset = min(3, rect.width * 0.15)
        let minX = rect.x, maxX = rect.x + rect.width, minY = rect.y, maxY = rect.y + rect.height
        let half = rect.height / 2
        canvas.fill(ViewerFigureRect(
            x: reverse ? minX + inset : minX, y: minY, width: rect.width - inset, height: rect.height
        ), fill)
        var strips: [Segment] = []
        var offset = 0.5
        while offset < rect.height {
            let reach = inset * (1 - abs(offset - half) / half)
            let y = minY + offset
            strips.append(reverse
                ? Segment(from: Point(x: minX + inset - reach, y: y), to: Point(x: minX + inset, y: y))
                : Segment(from: Point(x: maxX - inset, y: y), to: Point(x: maxX - inset + reach, y: y)))
            offset += 1
        }
        canvas.strokeSegments(strips, lineWidth: 1, fill)
        let corners = reverse
            ? [Point(x: minX + inset, y: minY), Point(x: maxX, y: minY), Point(x: maxX, y: maxY),
               Point(x: minX + inset, y: maxY), Point(x: minX, y: minY + half)]
            : [Point(x: minX, y: minY), Point(x: maxX - inset, y: minY), Point(x: maxX, y: minY + half),
               Point(x: maxX - inset, y: maxY), Point(x: minX, y: maxY)]
        let edges = corners.indices.map { Segment(from: corners[$0], to: corners[($0 + 1) % corners.count]) }
        canvas.strokeSegments(edges, lineWidth: 0.5, stroke)
    }

    private func mismatches(_ read: AlignedRead, y: Double, into canvas: inout ViewerFigureCanvas) {
        let mdPositions: Set<Int>? = refBytes == nil
            ? read.mdTag.map { ReadTrackRenderer.mismatchPositionsFromMDTagNonisolated($0, readStart: read.position) }
            : nil
        guard refBytes != nil || mdPositions != nil || read.cigar.contains(where: { $0.op == .seqMismatch }) else { return }
        let tickWidth = max(1.0, min(1.0 / frame.scale, 3.2))
        var lastPixel = Int.min
        ReadTrackRenderer.forEachPackedMismatch(
            read: read, refBytes: refBytes, referenceStart: options.referenceStart,
            mdMismatchPositions: mdPositions, maskedPositions: []
        ) { refPos, base in
            let tickX = x(refPos)
            guard Int(tickX) != lastPixel else { return }
            lastPixel = Int(tickX)
            canvas.fill(ViewerFigureRect(x: tickX, y: y, width: tickWidth, height: readHeight),
                        ViewerFigurePaint(Self.baseRole(base), alpha: 0.92))
        }
    }

    /// The role of a mismatch tick, as `ReadTrackRenderer.colorForByte` picks it.
    static func baseRole(_ byte: UInt8) -> ViewerFigureColorRole {
        switch byte {
        case 65: .readBaseA
        case 84, 85: .readBaseT
        case 67: .readBaseC
        case 71: .readBaseG
        default: .readBaseN
        }
    }

    private func indels(_ read: AlignedRead, y: Double, into canvas: inout ViewerFigureCanvas) {
        let lineY = y + readHeight / 2
        var refPos = read.position
        for op in read.cigar {
            if op.op == .deletion {
                let end = x(refPos + op.length)
                var dashes: [Segment] = []
                var dash = x(refPos)
                while dash < end {
                    dashes.append(Segment(from: Point(x: dash, y: lineY), to: Point(x: min(dash + 2, end), y: lineY)))
                    dash += 4
                }
                canvas.strokeSegments(dashes, lineWidth: 1, ViewerFigurePaint(.deletion))
            } else if op.op == .skip {
                canvas.strokeSegments([Segment(
                    from: Point(x: x(refPos), y: lineY), to: Point(x: x(refPos + op.length), y: lineY)
                )], lineWidth: 0.5, ViewerFigurePaint(.intron))
            }
            if op.consumesReference { refPos += op.length }
        }
        for insertion in read.insertions {
            canvas.fill(ViewerFigureRect(x: x(insertion.position) - 0.5, y: y - 1, width: 1, height: readHeight + 2),
                        ViewerFigurePaint(.insertion))
        }
    }
}
