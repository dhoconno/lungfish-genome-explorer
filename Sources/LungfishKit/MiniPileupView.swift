// MiniPileupView.swift - Compact read pileup renderer for MiniBAMViewController
// Copyright (c) 2025 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import LungfishCore

// MARK: - MiniPileupView

/// CoreGraphics-based view that renders a compact BAM pileup with base-level detail.
///
/// Renders:
/// - **Coverage depth track** (top 40px): area chart showing per-position depth
/// - **Read pileup** (below): packed reads with colored bases at mismatches,
///   strand arrows, soft-clip indicators, and duplicate highlighting
@MainActor
final class MiniPileupView: NSView {

    // MARK: - Data

    private var reads: [AlignedRead] = []
    private var contigName: String = ""
    private var contigLength: Int = 0
    private var packedRows: [[Int]] = []  // indices into reads array per row
    private(set) var bpPerPixel: Double = 1.0

    /// Callback when a read is clicked.
    var onReadClicked: ((Int) -> Void)?
    var onZoomInRequested: (() -> Void)?
    var onZoomOutRequested: (() -> Void)?
    var onZoomToFitRequested: (() -> Void)?
    var onMagnification: ((CGFloat) -> Void)?

    /// Index of the last read that was right-clicked (for context menu).
    var lastClickedReadIndex: Int?
    var lastContextClickPoint: NSPoint?

    /// Domain noun used in the empty-state label.
    var subjectNoun: String = "virus"

    // MARK: - Constants

    private let depthTrackHeight: CGFloat = 40
    private let readHeight: CGFloat = 12
    private let readGap: CGFloat = 2
    private let leftMargin: CGFloat = 4
    private let topMargin: CGFloat = 4
    private let referenceTrackHeight: CGFloat = 14
    private let referenceTrackGap: CGFloat = 4

    /// Per-position inferred reference bases from aligned reads and MD tags.
    private var inferredReferenceBases: [Int: Character] = [:]
    private var packInvocationCount: Int = 0

    // MARK: - Configuration

    func configure(
        reads: [AlignedRead],
        contigName: String,
        contigLength: Int,
        viewportWidth: CGFloat,
        viewportHeight: CGFloat,
        zoomLevel: Double = 1.0,
        rebuildReference: Bool = false,
        referenceSequence: String? = nil
    ) {
        self.reads = reads
        self.contigName = contigName
        self.contigLength = contigLength
        if rebuildReference {
            if let referenceSequence, !referenceSequence.isEmpty {
                inferredReferenceBases = Self.referenceBaseMap(from: referenceSequence)
            } else {
                inferredReferenceBases = [:]
            }
        }

        packReads()
        applyViewport(viewportWidth: viewportWidth, viewportHeight: viewportHeight, zoomLevel: zoomLevel)
    }

    func updateViewport(
        viewportWidth: CGFloat,
        viewportHeight: CGFloat,
        zoomLevel: Double = 1.0
    ) {
        applyViewport(viewportWidth: viewportWidth, viewportHeight: viewportHeight, zoomLevel: zoomLevel)
    }

    private func applyViewport(
        viewportWidth: CGFloat,
        viewportHeight: CGFloat,
        zoomLevel: Double
    ) {
        // Compute bp/px: at zoom=1.0, entire contig fits in viewport.
        // Higher zoom = fewer bp/px = more detail.
        let effectiveWidth = max(1, viewportWidth - leftMargin * 2)
        let baseBpPerPx = Double(contigLength) / Double(effectiveWidth)
        bpPerPixel = max(0.1, baseBpPerPx / zoomLevel)  // min 0.1 bp/px (~10 px per base)

        // Set frame size
        let pileupHeight = CGFloat(packedRows.count) * (readHeight + readGap)
            + depthTrackHeight + referenceTrackGap + referenceTrackHeight + topMargin * 2
        let contentWidth = max(viewportWidth, CGFloat(Double(contigLength) / bpPerPixel) + leftMargin * 2)
        let contentHeight = max(200, pileupHeight, viewportHeight)
        frame = NSRect(x: 0, y: 0, width: contentWidth, height: contentHeight)

        needsDisplay = true
    }

    private static func referenceBaseMap(from sequence: String) -> [Int: Character] {
        var bases: [Int: Character] = [:]
        bases.reserveCapacity(sequence.count)
        for (index, base) in sequence.uppercased().enumerated() {
            bases[index] = base
        }
        return bases
    }

    func clear() {
        reads = []
        packedRows = []
        inferredReferenceBases = [:]
        frame = NSRect(x: 0, y: 0, width: 100, height: 100)
        needsDisplay = true
    }

    func applyInferredReferenceBases(_ bases: [Int: Character]) {
        inferredReferenceBases = bases
        needsDisplay = true
    }

    // MARK: - Read Packing

    private func packReads() {
        packInvocationCount += 1
        packedRows = []
        let sorted = reads.indices.sorted { reads[$0].position < reads[$1].position }
        var rowAvailabilityHeap: [(end: Int, row: Int)] = []

        func hasPriority(_ lhs: (end: Int, row: Int), _ rhs: (end: Int, row: Int)) -> Bool {
            if lhs.end == rhs.end {
                return lhs.row < rhs.row
            }
            return lhs.end < rhs.end
        }

        func pushAvailableRow(_ value: (end: Int, row: Int)) {
            rowAvailabilityHeap.append(value)
            var child = rowAvailabilityHeap.count - 1
            while child > 0 {
                let parent = (child - 1) / 2
                guard hasPriority(rowAvailabilityHeap[child], rowAvailabilityHeap[parent]) else { break }
                rowAvailabilityHeap.swapAt(child, parent)
                child = parent
            }
        }

        func popAvailableRow() -> (end: Int, row: Int)? {
            guard !rowAvailabilityHeap.isEmpty else { return nil }
            if rowAvailabilityHeap.count == 1 {
                return rowAvailabilityHeap.removeLast()
            }

            let result = rowAvailabilityHeap[0]
            rowAvailabilityHeap[0] = rowAvailabilityHeap.removeLast()

            var parent = 0
            while true {
                let left = parent * 2 + 1
                let right = left + 1
                var candidate = parent

                if left < rowAvailabilityHeap.count,
                   hasPriority(rowAvailabilityHeap[left], rowAvailabilityHeap[candidate]) {
                    candidate = left
                }
                if right < rowAvailabilityHeap.count,
                   hasPriority(rowAvailabilityHeap[right], rowAvailabilityHeap[candidate]) {
                    candidate = right
                }
                guard candidate != parent else { break }
                rowAvailabilityHeap.swapAt(parent, candidate)
                parent = candidate
            }

            return result
        }

        for idx in sorted {
            let read = reads[idx]

            if let earliest = rowAvailabilityHeap.first,
               read.position > earliest.end + 2,
               let row = popAvailableRow() {
                packedRows[row.row].append(idx)
                pushAvailableRow((end: read.alignmentEnd, row: row.row))
            } else {
                let row = packedRows.count
                packedRows.append([idx])
                pushAvailableRow((end: read.alignmentEnd, row: row))
            }
        }
    }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard !reads.isEmpty else {
            drawEmptyState()
            return
        }

        drawDepthTrack(in: dirtyRect)
        drawReferenceTrack(in: dirtyRect)
        drawPileup(in: dirtyRect)
    }

    // MARK: - Depth Track

    private func drawDepthTrack(in dirtyRect: NSRect) {
        let trackRect = NSRect(x: leftMargin, y: bounds.height - depthTrackHeight - topMargin,
                               width: bounds.width - leftMargin * 2, height: depthTrackHeight)

        // Compute per-pixel depth
        let pixelCount = Int(trackRect.width)
        guard pixelCount > 0 else { return }

        var depths = [Int](repeating: 0, count: pixelCount)
        for read in reads {
            let startPx = max(0, Int(Double(read.position) / bpPerPixel))
            let endPx = min(pixelCount - 1, Int(Double(read.alignmentEnd) / bpPerPixel))
            guard startPx <= endPx else { continue }
            for px in startPx...endPx {
                depths[px] += 1
            }
        }

        let maxDepth = max(1, depths.max() ?? 1)

        // Draw area chart
        let path = NSBezierPath()
        path.move(to: NSPoint(x: trackRect.minX, y: trackRect.minY))

        for (i, depth) in depths.enumerated() {
            let x = trackRect.minX + CGFloat(i)
            let normalizedDepth = CGFloat(depth) / CGFloat(maxDepth)
            let y = trackRect.minY + trackRect.height * normalizedDepth
            path.line(to: NSPoint(x: x, y: y))
        }

        path.line(to: NSPoint(x: trackRect.maxX, y: trackRect.minY))
        path.close()

        NSColor.controlAccentColor.withAlphaComponent(0.2).setFill()
        path.fill()

        // Stroke top edge
        let strokePath = NSBezierPath()
        for (i, depth) in depths.enumerated() {
            let x = trackRect.minX + CGFloat(i)
            let normalizedDepth = CGFloat(depth) / CGFloat(maxDepth)
            let y = trackRect.minY + trackRect.height * normalizedDepth
            if i == 0 { strokePath.move(to: NSPoint(x: x, y: y)) }
            else { strokePath.line(to: NSPoint(x: x, y: y)) }
        }
        NSColor.controlAccentColor.withAlphaComponent(0.6).setStroke()
        strokePath.lineWidth = 1
        strokePath.stroke()

        // Max depth label
        let maxLabel = "\(maxDepth)x" as NSString
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 9, weight: .medium),
            .foregroundColor: NSColor.secondaryLabelColor,
        ]
        maxLabel.draw(at: NSPoint(x: trackRect.minX + 2, y: trackRect.maxY - 12), withAttributes: attrs)
    }

    private func drawReferenceTrack(in dirtyRect: NSRect) {
        let refRect = NSRect(
            x: leftMargin,
            y: bounds.height - depthTrackHeight - topMargin - referenceTrackGap - referenceTrackHeight,
            width: bounds.width - leftMargin * 2,
            height: referenceTrackHeight
        )
        guard refRect.intersects(dirtyRect) else { return }

        NSColor.controlBackgroundColor.withAlphaComponent(0.85).setFill()
        NSBezierPath(roundedRect: refRect, xRadius: 3, yRadius: 3).fill()

        guard contigLength > 0 else { return }
        let basePxWidth = CGFloat(1.0 / bpPerPixel)
        guard basePxWidth > 0 else { return }
        guard Self.shouldDrawPerBaseReferenceTrack(basePixelWidth: basePxWidth) else { return }

        let startRef = max(0, Int(floor(Double(dirtyRect.minX - leftMargin) * bpPerPixel)))
        let endRef = min(contigLength - 1, Int(ceil(Double(dirtyRect.maxX - leftMargin) * bpPerPixel)))
        guard endRef >= startRef else { return }

        if basePxWidth >= 5 {
            let font = NSFont.monospacedSystemFont(ofSize: min(10, max(7, basePxWidth * 0.7)), weight: .medium)
            for refPos in startRef...endRef {
                let base = inferredReferenceBases[refPos] ?? "N"
                let x = leftMargin + CGFloat(Double(refPos) / bpPerPixel)
                guard x + basePxWidth >= refRect.minX, x <= refRect.maxX else { continue }

                let attrs: [NSAttributedString.Key: Any] = [
                    .font: font,
                    .foregroundColor: baseColor(for: base),
                ]
                let str = String(base) as NSString
                let size = str.size(withAttributes: attrs)
                str.draw(
                    at: NSPoint(
                        x: x + (basePxWidth - size.width) / 2,
                        y: refRect.minY + (referenceTrackHeight - size.height) / 2
                    ),
                    withAttributes: attrs
                )
            }
        } else {
            for refPos in startRef...endRef {
                let base = inferredReferenceBases[refPos] ?? "N"
                let x = leftMargin + CGFloat(Double(refPos) / bpPerPixel)
                let width = max(1, basePxWidth)
                let rect = NSRect(x: x, y: refRect.minY + 2, width: width, height: referenceTrackHeight - 4)
                baseColor(for: base).withAlphaComponent(0.45).setFill()
                NSBezierPath(rect: rect).fill()
            }
        }
    }

    private nonisolated static func shouldDrawPerBaseReferenceTrack(basePixelWidth: CGFloat) -> Bool {
        basePixelWidth >= 1
    }

    // MARK: - Read Pileup

    private func drawPileup(in dirtyRect: NSRect) {
        let pileupTop = bounds.height - depthTrackHeight - referenceTrackHeight - referenceTrackGap - topMargin * 2

        for (rowIdx, row) in packedRows.enumerated() {
            let rowY = pileupTop - CGFloat(rowIdx + 1) * (readHeight + readGap)
            guard rowY + readHeight >= dirtyRect.minY && rowY <= dirtyRect.maxY else { continue }

            for readIdx in row {
                let read = reads[readIdx]
                drawRead(read, at: rowY, in: dirtyRect)
            }
        }
    }

    private func drawRead(_ read: AlignedRead, at y: CGFloat, in dirtyRect: NSRect) {
        let startX = leftMargin + CGFloat(Double(read.position) / bpPerPixel)
        let endX = leftMargin + CGFloat(Double(read.alignmentEnd) / bpPerPixel)
        let width = max(2, endX - startX)

        let readRect = NSRect(x: startX, y: y, width: width, height: readHeight)

        // Skip if outside dirty rect
        guard readRect.intersects(dirtyRect) else { return }

        // Read color: forward=blue, reverse=red
        // PCR/optical duplicates are filtered upstream by samtools markdup.
        let baseColor: NSColor
        let fillOpacity: CGFloat
        if read.isReverse {
            baseColor = NSColor(red: 0.85, green: 0.45, blue: 0.45, alpha: 1.0)
            fillOpacity = 0.7
        } else {
            baseColor = NSColor(red: 0.45, green: 0.55, blue: 0.85, alpha: 1.0)
            fillOpacity = 0.7
        }

        // Draw read body
        let readPath = NSBezierPath(roundedRect: readRect, xRadius: 2, yRadius: 2)
        baseColor.withAlphaComponent(fillOpacity).setFill()
        readPath.fill()

        // Draw strand arrow at the end
        let arrowSize: CGFloat = 4
        if read.isReverse {
            // Left-pointing arrow
            let arrowPath = NSBezierPath()
            arrowPath.move(to: NSPoint(x: startX, y: y + readHeight / 2))
            arrowPath.line(to: NSPoint(x: startX + arrowSize, y: y + readHeight))
            arrowPath.line(to: NSPoint(x: startX + arrowSize, y: y))
            arrowPath.close()
            baseColor.setFill()
            arrowPath.fill()
        } else {
            // Right-pointing arrow
            let arrowPath = NSBezierPath()
            arrowPath.move(to: NSPoint(x: endX, y: y + readHeight / 2))
            arrowPath.line(to: NSPoint(x: endX - arrowSize, y: y + readHeight))
            arrowPath.line(to: NSPoint(x: endX - arrowSize, y: y))
            arrowPath.close()
            baseColor.setFill()
            arrowPath.fill()
        }

        // At high zoom: draw individual base letters on the read
        let effectiveBpPerPx = bpPerPixel / max(1, Double(window?.backingScaleFactor ?? 1))
        let hasReferenceBases = !inferredReferenceBases.isEmpty
        if effectiveBpPerPx < 0.5 {
            // Ultra-zoom: draw full sequence bases
            drawBaseLetters(read: read, startX: startX, y: y)
            if hasReferenceBases {
                drawReferenceDifferences(read: read, readRect: readRect, y: y, style: .baseLevel)
            } else if let mdTag = read.mdTag {
                drawMismatchesFromMD(read: read, mdTag: mdTag, readRect: readRect, y: y, style: .outline)
            }
        } else if bpPerPixel < 8 {
            // Medium zoom: draw mismatches as colored ticks.
            if hasReferenceBases {
                drawReferenceDifferences(read: read, readRect: readRect, y: y, style: .compact)
            } else if let mdTag = read.mdTag {
                drawMismatchesFromMD(read: read, mdTag: mdTag, readRect: readRect, y: y, style: .fillTick)
            }
        }

        // Draw soft-clip indicators from CIGAR.
        // Leading clips extend left of alignment start; trailing clips extend
        // right of alignment end.
        let cigar = read.cigar
        if let first = cigar.first, first.op == .softClip {
            let clipWidth = max(2, CGFloat(Double(first.length) / bpPerPixel))
            let clipRect = NSRect(x: startX - clipWidth, y: y, width: clipWidth, height: readHeight)
            NSColor.systemYellow.withAlphaComponent(0.5).setFill()
            NSBezierPath(rect: clipRect).fill()
        }
        if let last = cigar.last, last.op == .softClip, cigar.count > 1 {
            let clipWidth = max(2, CGFloat(Double(last.length) / bpPerPixel))
            let clipRect = NSRect(x: endX, y: y, width: clipWidth, height: readHeight)
            NSColor.systemYellow.withAlphaComponent(0.5).setFill()
            NSBezierPath(rect: clipRect).fill()
        }
    }

    /// Draws individual base letters on the read at high zoom levels.
    ///
    /// Walks the CIGAR string to correctly map query bases to reference
    /// positions.  Soft-clipped bases are skipped (they don't align to
    /// the reference).
    private func drawBaseLetters(read: AlignedRead, startX: CGFloat, y: CGFloat) {
        let basePxWidth = CGFloat(1.0 / bpPerPixel)
        guard basePxWidth >= 4 else { return }  // Too small to render letters

        let fontSize = min(10, max(6, basePxWidth * 0.8))
        let font = NSFont.monospacedSystemFont(ofSize: fontSize, weight: .medium)
        let readBases = Array(read.sequence)

        var refPos = read.position
        var queryPos = 0

        for op in read.cigar {
            switch op.op {
            case .match, .seqMatch, .seqMismatch:
                for offset in 0..<op.length {
                    let q = queryPos + offset
                    guard q < readBases.count else { break }
                    let char = readBases[q]
                    let x = leftMargin + CGFloat(Double(refPos + offset) / bpPerPixel)
                    let color = baseColor(for: char)
                    let attrs: [NSAttributedString.Key: Any] = [
                        .font: font,
                        .foregroundColor: color,
                    ]
                    let str = String(char) as NSString
                    let size = str.size(withAttributes: attrs)
                    str.draw(
                        at: NSPoint(x: x + (basePxWidth - size.width) / 2, y: y + (readHeight - size.height) / 2),
                        withAttributes: attrs
                    )
                }
                refPos += op.length
                queryPos += op.length
            case .insertion, .softClip:
                queryPos += op.length
            case .deletion, .skip:
                refPos += op.length
            case .hardClip, .padding:
                break
            }
        }
    }

    /// Draws mismatches parsed from the MD tag as colored ticks on the read.
    ///
    /// The MD tag format: `[0-9]+(([A-Z]|\^[A-Z]+)[0-9]+)*`
    /// Numbers indicate matching bases; letters indicate mismatches;
    /// ^letters indicate deletions from reference.
    private enum MismatchMarkerStyle {
        case fillTick
        case outline
    }

    private enum ReferenceDifferenceStyle {
        case compact
        case baseLevel
    }

    private func drawMismatchesFromMD(
        read: AlignedRead,
        mdTag: String,
        readRect: NSRect,
        y: CGFloat,
        style: MismatchMarkerStyle
    ) {
        var refPos = read.position
        var i = mdTag.startIndex
        let queryByReference = buildReferenceToQueryIndexMap(for: read)

        while i < mdTag.endIndex {
            let ch = mdTag[i]

            if ch.isNumber {
                // Matching bases: skip forward
                var numStr = ""
                while i < mdTag.endIndex && mdTag[i].isNumber {
                    numStr.append(mdTag[i])
                    i = mdTag.index(after: i)
                }
                refPos += Int(numStr) ?? 0
            } else if ch == "^" {
                // Deletion from reference: skip bases
                i = mdTag.index(after: i)
                while i < mdTag.endIndex && mdTag[i].isLetter {
                    refPos += 1
                    i = mdTag.index(after: i)
                }
            } else if ch.isLetter {
                // Mismatch: draw colored tick
                let mismatchX = leftMargin + CGFloat(Double(refPos) / bpPerPixel)
                if mismatchX >= readRect.minX && mismatchX <= readRect.maxX {
                    // Get the read base at this position from the sequence
                    let queryOffset = queryByReference[refPos] ?? (refPos - read.position)
                    let readBase: Character
                    if queryOffset >= 0 && queryOffset < read.sequence.count {
                        let idx = read.sequence.index(read.sequence.startIndex, offsetBy: queryOffset)
                        readBase = read.sequence[idx]
                    } else {
                        readBase = "N"
                    }

                    let color = baseColor(for: readBase)

                    let tickWidth: CGFloat
                    switch style {
                    case .fillTick:
                        tickWidth = max(2, CGFloat(1 / bpPerPixel))
                    case .outline:
                        tickWidth = max(1, CGFloat(1 / bpPerPixel))
                    }
                    let tickRect = NSRect(x: mismatchX, y: y, width: max(1, tickWidth), height: readHeight)
                    switch style {
                    case .fillTick:
                        color.setFill()
                        NSBezierPath(rect: tickRect).fill()
                    case .outline:
                        let outline = NSBezierPath(roundedRect: tickRect.insetBy(dx: -0.5, dy: -0.5), xRadius: 1, yRadius: 1)
                        color.setStroke()
                        outline.lineWidth = 1.2
                        outline.stroke()
                    }
                }

                refPos += 1
                i = mdTag.index(after: i)
            } else {
                i = mdTag.index(after: i)
            }
        }
    }

    private func drawReferenceDifferences(
        read: AlignedRead,
        readRect: NSRect,
        y: CGFloat,
        style: ReferenceDifferenceStyle
    ) {
        let readBases = Array(read.sequence.uppercased())
        guard !readBases.isEmpty else { return }
        let queryByReference = buildReferenceToQueryIndexMap(for: read)
        guard !queryByReference.isEmpty else { return }

        for (refPos, queryOffset) in queryByReference {
            guard queryOffset >= 0, queryOffset < readBases.count else { continue }
            guard let referenceBase = inferredReferenceBases[refPos], referenceBase != "N" else { continue }

            let readBase = readBases[queryOffset]
            guard readBase != "N", readBase != referenceBase else { continue }

            let mismatchX = leftMargin + CGFloat(Double(refPos) / bpPerPixel)
            guard mismatchX >= readRect.minX - 1, mismatchX <= readRect.maxX + 1 else { continue }

            let markerWidth = max(2, CGFloat(1 / bpPerPixel))
            let markerRect = NSRect(x: mismatchX, y: y, width: max(1, markerWidth), height: readHeight)
            let markerColor = baseColor(for: readBase)

            switch style {
            case .compact:
                markerColor.withAlphaComponent(0.95).setFill()
                NSBezierPath(rect: markerRect).fill()
            case .baseLevel:
                NSColor.systemYellow.withAlphaComponent(0.32).setFill()
                NSBezierPath(rect: markerRect).fill()
                let outline = NSBezierPath(
                    roundedRect: markerRect.insetBy(dx: -0.4, dy: -0.4),
                    xRadius: 1,
                    yRadius: 1
                )
                markerColor.setStroke()
                outline.lineWidth = 1
                outline.stroke()
            }
        }
    }

    private func baseColor(for base: Character) -> NSColor {
        switch base.uppercased() {
        case "A": return NSColor(red: 0, green: 0.6, blue: 0, alpha: 1)
        case "T": return NSColor(red: 0.8, green: 0, blue: 0, alpha: 1)
        case "G": return NSColor(red: 0.8, green: 0.7, blue: 0, alpha: 1)
        case "C": return NSColor(red: 0, green: 0, blue: 0.8, alpha: 1)
        default: return .systemGray
        }
    }

    private func buildReferenceToQueryIndexMap(for read: AlignedRead) -> [Int: Int] {
        var mapping: [Int: Int] = [:]
        var refPos = read.position
        var queryPos = 0

        for op in read.cigar {
            switch op.op {
            case .match, .seqMatch, .seqMismatch:
                for offset in 0..<op.length {
                    mapping[refPos + offset] = queryPos + offset
                }
                refPos += op.length
                queryPos += op.length
            case .insertion, .softClip:
                queryPos += op.length
            case .deletion, .skip:
                refPos += op.length
            case .hardClip, .padding:
                break
            }
        }

        return mapping
    }

    nonisolated static func inferReferenceBases(reads: [AlignedRead], contigLength: Int) -> [Int: Character] {
        guard !reads.isEmpty else { return [:] }

        var baseVotes: [Int: [Character: Int]] = [:]
        for read in reads {
            let inferredForRead = inferReferenceBases(for: read)
            for (refPos, base) in inferredForRead {
                guard refPos >= 0 && refPos < contigLength else { continue }
                baseVotes[refPos, default: [:]][base, default: 0] += 1
            }
        }

        var inferred: [Int: Character] = [:]
        for (refPos, votes) in baseVotes {
            let winner = votes.max { lhs, rhs in
                if lhs.value == rhs.value {
                    return lhs.key < rhs.key
                }
                return lhs.value < rhs.value
            }?.key ?? "N"
            inferred[refPos] = winner
        }
        return inferred
    }

    private nonisolated static func inferReferenceBases(for read: AlignedRead) -> [Int: Character] {
        let readBases = Array(read.sequence.uppercased())
        guard !readBases.isEmpty else { return [:] }

        var inferred: [Int: Character] = [:]
        var refPos = read.position
        var queryPos = 0

        for op in read.cigar {
            switch op.op {
            case .match, .seqMatch, .seqMismatch:
                for offset in 0..<op.length {
                    let q = queryPos + offset
                    if q >= 0, q < readBases.count {
                        inferred[refPos + offset] = readBases[q]
                    }
                }
                refPos += op.length
                queryPos += op.length
            case .insertion, .softClip:
                queryPos += op.length
            case .deletion, .skip:
                refPos += op.length
            case .hardClip, .padding:
                break
            }
        }

        guard let mdTag = read.mdTag, !mdTag.isEmpty else { return inferred }

        refPos = read.position
        var idx = mdTag.startIndex
        while idx < mdTag.endIndex {
            let ch = mdTag[idx]
            if ch.isNumber {
                var numStr = ""
                while idx < mdTag.endIndex, mdTag[idx].isNumber {
                    numStr.append(mdTag[idx])
                    idx = mdTag.index(after: idx)
                }
                refPos += Int(numStr) ?? 0
            } else if ch == "^" {
                idx = mdTag.index(after: idx)
                while idx < mdTag.endIndex, mdTag[idx].isLetter {
                    inferred[refPos] = Character(String(mdTag[idx]).uppercased())
                    refPos += 1
                    idx = mdTag.index(after: idx)
                }
            } else if ch.isLetter {
                inferred[refPos] = Character(String(ch).uppercased())
                refPos += 1
                idx = mdTag.index(after: idx)
            } else {
                idx = mdTag.index(after: idx)
            }
        }

        return inferred
    }

    private func drawEmptyState() {
        let text = "Select a \(subjectNoun) to view read alignments" as NSString
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12),
            .foregroundColor: NSColor.tertiaryLabelColor,
        ]
        let size = text.size(withAttributes: attrs)
        text.draw(
            at: NSPoint(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2),
            withAttributes: attrs
        )
    }

    // MARK: - Hit Testing

    override var acceptsFirstResponder: Bool { true }

    private func handleZoomShortcut(_ event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard modifiers.contains(.command) else { return false }
        let disallowed: NSEvent.ModifierFlags = [.control, .option, .function]
        guard modifiers.intersection(disallowed).isEmpty else { return false }

        switch event.keyCode {
        case 24, 69:
            onZoomInRequested?()
            return true
        case 27, 78:
            onZoomOutRequested?()
            return true
        case 29, 82:
            onZoomToFitRequested?()
            return true
        default:
            break
        }

        switch event.charactersIgnoringModifiers {
        case "+", "=":
            onZoomInRequested?()
            return true
        case "-", "_":
            onZoomOutRequested?()
            return true
        case "0":
            onZoomToFitRequested?()
            return true
        default:
            return false
        }
    }

    override func keyDown(with event: NSEvent) {
        if handleZoomShortcut(event) {
            return
        }
        super.keyDown(with: event)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if handleZoomShortcut(event) {
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    override func magnify(with event: NSEvent) {
        onMagnification?(event.magnification)
    }

    /// Finds the read index at a given point in view coordinates.
    private func readIndex(at point: NSPoint) -> Int? {
        let pileupTop = bounds.height - depthTrackHeight - referenceTrackHeight - referenceTrackGap - topMargin * 2

        for (rowIdx, row) in packedRows.enumerated() {
            let rowY = pileupTop - CGFloat(rowIdx + 1) * (readHeight + readGap)

            for readIdx in row {
                let read = reads[readIdx]
                let startX = leftMargin + CGFloat(Double(read.position) / bpPerPixel)
                let endX = leftMargin + CGFloat(Double(read.alignmentEnd) / bpPerPixel)
                let readRect = NSRect(x: startX, y: rowY, width: max(2, endX - startX), height: readHeight)

                if readRect.contains(point) {
                    return readIdx
                }
            }
        }
        return nil
    }

    private func pointInDocumentCoordinates(from event: NSEvent) -> NSPoint {
        convert(event.locationInWindow, from: nil)
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        let point = pointInDocumentCoordinates(from: event)
        if let idx = readIndex(at: point) {
            lastClickedReadIndex = idx
            onReadClicked?(idx)
        } else {
            lastClickedReadIndex = nil
        }
        super.mouseDown(with: event)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        window?.makeFirstResponder(self)
        let point = pointInDocumentCoordinates(from: event)
        lastContextClickPoint = point
        lastClickedReadIndex = readIndex(at: point)
        return super.menu(for: event)
    }

    var testPackInvocationCount: Int { packInvocationCount }
    var testInferredReferenceBaseCount: Int { inferredReferenceBases.count }
    nonisolated static func testingShouldDrawPerBaseReferenceTrack(basePixelWidth: CGFloat) -> Bool {
        shouldDrawPerBaseReferenceTrack(basePixelWidth: basePixelWidth)
    }
}
