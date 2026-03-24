// MiniBAMViewController.swift - Compact BAM alignment viewer for EsViritu detail pane
// Copyright (c) 2025 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import LungfishCore
import LungfishIO
import os.log

private let logger = Logger(subsystem: LogSubsystem.app, category: "MiniBAM")

// MARK: - MiniBAMViewController

/// A compact BAM alignment viewer that shows base-level read pileup for a viral contig.
///
/// Designed to be embedded in the EsViritu detail pane. Unlike the full
/// `SequenceViewerView`, this controller is lightweight:
/// - Creates its own `AlignmentDataProvider` from a BAM path
/// - Renders reads using CoreGraphics directly (no tile cache)
/// - Shows the entire viral contig in a scrollable view
/// - Highlights potential PCR duplicates (identical start/end positions)
///
/// ## Layout
///
/// ```
/// +--------------------------------------------------+
/// | Coverage depth track (40px)                      |
/// | [area chart showing depth across contig]         |
/// +--------------------------------------------------+
/// | Read pileup (scrollable, variable height)        |
/// | [packed reads with mismatch coloring, arrows]    |
/// | [duplicate reads highlighted in orange]          |
/// +--------------------------------------------------+
/// | Status: "42 reads (3 potential duplicates)"      |
/// +--------------------------------------------------+
/// ```
@MainActor
public final class MiniBAMViewController: NSViewController {

    // MARK: - Properties

    private var bamURL: URL?
    private var indexURL: URL?
    private var contigName: String = ""
    private var contigLength: Int = 0
    private var reads: [AlignedRead] = []
    private var duplicateIndices: Set<Int> = []
    private var depthPoints: [DepthPoint] = []

    // MARK: - Subviews

    private let scrollView = NSScrollView()
    private let pileupView = MiniPileupView()
    private let statusLabel = NSTextField(labelWithString: "")

    // MARK: - Lifecycle

    public override func loadView() {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        view = container

        setupScrollView()
        setupStatusLabel()

        // Context menu for the pileup view
        let menu = NSMenu()
        menu.addItem(withTitle: "Zoom In", action: #selector(zoomInAction), keyEquivalent: "+")
        menu.items.last?.keyEquivalentModifierMask = .command
        menu.addItem(withTitle: "Zoom Out", action: #selector(zoomOutAction), keyEquivalent: "-")
        menu.items.last?.keyEquivalentModifierMask = .command
        menu.addItem(withTitle: "Zoom to Fit", action: #selector(zoomToFitAction), keyEquivalent: "0")
        menu.items.last?.keyEquivalentModifierMask = .command
        menu.addItem(.separator())
        menu.addItem(withTitle: "Copy Read Sequence (FASTQ)", action: #selector(copyReadFASTQ), keyEquivalent: "")
        menu.addItem(withTitle: "Copy Read Name", action: #selector(copyReadName), keyEquivalent: "")
        pileupView.menu = menu

        // Wire the pileup view's click handler for read selection
        pileupView.onReadClicked = { [weak self] readIndex in
            self?.selectedReadIndex = readIndex
        }
    }

    /// Index of the currently selected read (for context menu operations).
    private var selectedReadIndex: Int?

    /// Current zoom level (1.0 = fit entire contig in viewport width).
    private var zoomLevel: Double = 1.0

    private func setupScrollView() {
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = false
        scrollView.drawsBackground = false
        // Do NOT use allowsMagnification — it just scales pixels.
        // We implement semantic zoom by changing bpPerPixel and re-rendering.
        scrollView.allowsMagnification = false
        scrollView.documentView = pileupView
        view.addSubview(scrollView)

        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        statusLabel.font = .systemFont(ofSize: 10)
        statusLabel.textColor = .tertiaryLabelColor
        statusLabel.alignment = .center
        view.addSubview(statusLabel)

        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: view.topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: statusLabel.topAnchor, constant: -2),

            statusLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 4),
            statusLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -4),
            statusLabel.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -2),
            statusLabel.heightAnchor.constraint(equalToConstant: 14),
        ])
    }

    private func setupStatusLabel() {
        statusLabel.stringValue = "Select a virus to view alignments"
    }

    // MARK: - Public API

    /// Zoom in: doubles the zoom level (halves bp/px), re-renders at higher detail.
    ///
    /// Preserves the scroll position by centering on the current viewport midpoint.
    public func zoomIn() {
        let maxZoom = Double(contigLength) / 2.0  // Min 2bp visible
        let newZoom = min(maxZoom, zoomLevel * 2)
        applyZoom(newZoom)
    }

    /// Zoom out: halves the zoom level (doubles bp/px).
    public func zoomOut() {
        let newZoom = max(1.0, zoomLevel / 2)
        applyZoom(newZoom)
    }

    /// Zoom to fit the entire contig in the viewport.
    public func zoomToFit() {
        applyZoom(1.0)
    }

    /// Applies a new zoom level and re-renders the pileup.
    private func applyZoom(_ newZoom: Double) {
        // Remember viewport center position in bp coordinates
        let viewportWidth = scrollView.contentSize.width
        let scrollX = scrollView.contentView.bounds.origin.x
        let oldBpPerPx = pileupView.bpPerPixel
        let centerBp = (Double(scrollX) + Double(viewportWidth) / 2) * oldBpPerPx

        zoomLevel = newZoom

        // Re-render with new zoom level
        pileupView.configure(
            reads: reads,
            duplicateIndices: duplicateIndices,
            contigName: contigName,
            contigLength: contigLength,
            viewportWidth: viewportWidth,
            zoomLevel: zoomLevel
        )

        // Scroll to keep the same bp position centered
        let newBpPerPx = pileupView.bpPerPixel
        let newScrollX = CGFloat(centerBp / newBpPerPx) - viewportWidth / 2
        let clampedX = max(0, min(newScrollX, pileupView.frame.width - viewportWidth))
        scrollView.contentView.scroll(to: NSPoint(x: clampedX, y: scrollView.contentView.bounds.origin.y))
        scrollView.reflectScrolledClipView(scrollView.contentView)

        updateZoomStatus()
    }

    private func updateZoomStatus() {
        let bpPerPx = pileupView.bpPerPixel
        let zoomText: String
        if bpPerPx < 1 {
            zoomText = String(format: "%.1f px/bp", 1.0 / bpPerPx)
        } else {
            zoomText = String(format: "%.0f bp/px", bpPerPx)
        }

        let dupCount = duplicateIndices.count
        let uniqueCount = reads.count - dupCount
        let dupText = dupCount > 0 ? " (\(uniqueCount) unique, \(dupCount) PCR dups)" : ""
        statusLabel.stringValue = "\(reads.count) reads\(dupText) · \(zoomText) · ⌘+/⌘- to zoom"
    }

    /// Loads and displays reads for a specific viral contig from the BAM file.
    ///
    /// - Parameters:
    ///   - bamURL: Path to the sorted, indexed BAM file.
    ///   - contig: The viral contig accession to display.
    ///   - contigLength: Length of the reference contig in base pairs.
    public func displayContig(bamURL: URL, contig: String, contigLength: Int) {
        self.bamURL = bamURL
        self.contigName = contig
        self.contigLength = contigLength

        let indexPath = bamURL.path + ".bai"
        guard FileManager.default.fileExists(atPath: indexPath) else {
            statusLabel.stringValue = "BAM index not found"
            logger.warning("BAM index not found at \(indexPath)")
            return
        }

        let provider = AlignmentDataProvider(
            alignmentPath: bamURL.path,
            indexPath: indexPath
        )

        // Fetch all reads for this contig (viral genomes are small, so fetch everything)
        Task { @MainActor in
            do {
                let fetchedReads = try await provider.fetchReads(
                    chromosome: contig,
                    start: 0,
                    end: contigLength,
                    maxReads: 5000
                )

                self.reads = fetchedReads
                self.detectDuplicates()
                self.updatePileup()

                // Scroll to TOP of pileup (where most reads are concentrated)
                // so the user sees the highest-coverage region first
                self.scrollView.magnification = 1.0
                if let docView = self.scrollView.documentView {
                    let topPoint = NSPoint(x: 0, y: docView.frame.height - self.scrollView.contentSize.height)
                    self.scrollView.contentView.scroll(to: topPoint)
                }

                let dupCount = self.duplicateIndices.count
                let uniqueCount = fetchedReads.count - dupCount
                let dupText = dupCount > 0 ? " (\(uniqueCount) unique, \(dupCount) PCR duplicates)" : ""
                let zoomHint = fetchedReads.count > 0 ? " · ⌘+/⌘- to zoom" : ""
                self.statusLabel.stringValue = "\(fetchedReads.count) reads\(dupText)\(zoomHint)"

                logger.info("Loaded \(fetchedReads.count) reads for \(contig, privacy: .public), \(dupCount) potential duplicates")
            } catch {
                self.statusLabel.stringValue = "Failed to load reads: \(error.localizedDescription)"
                logger.error("Failed to fetch reads for \(contig, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    // MARK: - Keyboard Shortcuts

    public override func keyDown(with event: NSEvent) {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if modifiers == .command {
            switch event.charactersIgnoringModifiers {
            case "+", "=":
                zoomIn()
                return
            case "-":
                zoomOut()
                return
            case "0":
                zoomToFit()
                return
            default:
                break
            }
        }
        super.keyDown(with: event)
    }

    // Make sure we can become first responder for keyboard events
    public override var acceptsFirstResponder: Bool { true }

    // MARK: - Context Menu Actions

    @objc private func zoomInAction() { zoomIn() }
    @objc private func zoomOutAction() { zoomOut() }
    @objc private func zoomToFitAction() { zoomToFit() }

    @objc private func copyReadFASTQ() {
        guard let idx = selectedReadIndex ?? pileupView.lastClickedReadIndex,
              idx < reads.count else { return }
        let read = reads[idx]
        let qualString = String(read.qualities.map { Character(UnicodeScalar($0 + 33)) })
        let fastq = "@\(read.name)\n\(read.sequence)\n+\n\(qualString)"
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(fastq, forType: .string)
    }

    @objc private func copyReadName() {
        guard let idx = selectedReadIndex ?? pileupView.lastClickedReadIndex,
              idx < reads.count else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(reads[idx].name, forType: .string)
    }

    /// Clears the current display.
    public func clear() {
        reads = []
        duplicateIndices = []
        depthPoints = []
        pileupView.clear()
        statusLabel.stringValue = "Select a virus to view alignments"
    }

    // MARK: - Duplicate Detection

    /// Identifies potential PCR duplicates: reads with identical start and end positions.
    ///
    /// The FIRST read in each position group is kept as the "real" read.
    /// Subsequent reads at the same position are marked as potential duplicates
    /// and rendered at 50% opacity in orange.
    private func detectDuplicates() {
        duplicateIndices = []

        // Group reads by (start, end, strand) — same position AND strand = likely PCR dup
        var positionGroups: [String: [Int]] = [:]
        for (i, read) in reads.enumerated() {
            let strand = read.isReverse ? "R" : "F"
            let key = "\(read.position)-\(read.alignmentEnd)-\(strand)"
            positionGroups[key, default: []].append(i)
        }

        // Mark all reads EXCEPT the first in each group as duplicates
        for (_, indices) in positionGroups where indices.count > 1 {
            for idx in indices.dropFirst() {
                duplicateIndices.insert(idx)
            }
        }
    }

    // MARK: - Pileup Update

    private func updatePileup() {
        pileupView.configure(
            reads: reads,
            duplicateIndices: duplicateIndices,
            contigName: contigName,
            contigLength: contigLength,
            viewportWidth: scrollView.contentSize.width,
            zoomLevel: zoomLevel
        )
    }
}

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
    private var duplicateIndices: Set<Int> = []
    private var contigName: String = ""
    private var contigLength: Int = 0
    private var packedRows: [[Int]] = []  // indices into reads array per row
    private(set) var bpPerPixel: Double = 1.0

    /// Callback when a read is clicked.
    var onReadClicked: ((Int) -> Void)?

    /// Index of the last read that was right-clicked (for context menu).
    var lastClickedReadIndex: Int?

    // MARK: - Constants

    private let depthTrackHeight: CGFloat = 40
    private let readHeight: CGFloat = 12
    private let readGap: CGFloat = 2
    private let leftMargin: CGFloat = 4
    private let topMargin: CGFloat = 4

    // MARK: - Configuration

    func configure(
        reads: [AlignedRead],
        duplicateIndices: Set<Int>,
        contigName: String,
        contigLength: Int,
        viewportWidth: CGFloat,
        zoomLevel: Double = 1.0
    ) {
        self.reads = reads
        self.duplicateIndices = duplicateIndices
        self.contigName = contigName
        self.contigLength = contigLength

        // Compute bp/px: at zoom=1.0, entire contig fits in viewport.
        // Higher zoom = fewer bp/px = more detail.
        let effectiveWidth = max(1, viewportWidth - leftMargin * 2)
        let baseBpPerPx = Double(contigLength) / Double(effectiveWidth)
        bpPerPixel = max(0.1, baseBpPerPx / zoomLevel)  // min 0.1 bp/px (~10 px per base)

        // Pack reads into rows (greedy left-to-right packing)
        packReads()

        // Set frame size
        let pileupHeight = CGFloat(packedRows.count) * (readHeight + readGap) + depthTrackHeight + topMargin * 2
        let contentWidth = max(viewportWidth, CGFloat(Double(contigLength) / bpPerPixel) + leftMargin * 2)
        frame = NSRect(x: 0, y: 0, width: contentWidth, height: max(200, pileupHeight))

        needsDisplay = true
    }

    func clear() {
        reads = []
        duplicateIndices = []
        packedRows = []
        frame = NSRect(x: 0, y: 0, width: 100, height: 100)
        needsDisplay = true
    }

    // MARK: - Read Packing

    private func packReads() {
        packedRows = []
        let sorted = reads.indices.sorted { reads[$0].position < reads[$1].position }

        for idx in sorted {
            let read = reads[idx]
            let readEnd = read.alignmentEnd

            // Find first row where this read fits
            var placed = false
            for row in 0..<packedRows.count {
                if let lastIdx = packedRows[row].last {
                    let lastEnd = reads[lastIdx].alignmentEnd
                    if read.position > lastEnd + 2 {  // 2bp gap
                        packedRows[row].append(idx)
                        placed = true
                        break
                    }
                }
            }
            if !placed {
                packedRows.append([idx])
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

    // MARK: - Read Pileup

    private func drawPileup(in dirtyRect: NSRect) {
        let pileupTop = bounds.height - depthTrackHeight - topMargin * 2

        for (rowIdx, row) in packedRows.enumerated() {
            let rowY = pileupTop - CGFloat(rowIdx + 1) * (readHeight + readGap)
            guard rowY + readHeight >= dirtyRect.minY && rowY <= dirtyRect.maxY else { continue }

            for readIdx in row {
                let read = reads[readIdx]
                let isDuplicate = duplicateIndices.contains(readIdx)
                drawRead(read, at: rowY, isDuplicate: isDuplicate, in: dirtyRect)
            }
        }
    }

    private func drawRead(_ read: AlignedRead, at y: CGFloat, isDuplicate: Bool, in dirtyRect: NSRect) {
        let startX = leftMargin + CGFloat(Double(read.position) / bpPerPixel)
        let endX = leftMargin + CGFloat(Double(read.alignmentEnd) / bpPerPixel)
        let width = max(2, endX - startX)

        let readRect = NSRect(x: startX, y: y, width: width, height: readHeight)

        // Skip if outside dirty rect
        guard readRect.intersects(dirtyRect) else { return }

        // Read color: forward=blue, reverse=red
        // Duplicates: same strand color but at 50% opacity with orange tint
        let baseColor: NSColor
        let fillOpacity: CGFloat
        if isDuplicate {
            // Duplicate reads: orange-tinted at 50% opacity to de-emphasize
            baseColor = .systemOrange
            fillOpacity = 0.35
        } else if read.isReverse {
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
        if effectiveBpPerPx < 0.5 {
            // Ultra-zoom: draw full sequence bases
            drawBaseLetters(read: read, startX: startX, y: y, baseColor: baseColor)
        } else if bpPerPixel < 5, let mdTag = read.mdTag {
            // Medium zoom: draw only mismatches as colored ticks
            drawMismatchesFromMD(read: read, mdTag: mdTag, readRect: readRect, y: y)
        }

        // Draw soft-clip indicators from CIGAR
        let cigar = read.cigar
        if let first = cigar.first, first.op == .softClip {
            let clipWidth = max(2, CGFloat(Double(first.length) / bpPerPixel))
            let clipRect = NSRect(x: startX, y: y, width: clipWidth, height: readHeight)
            NSColor.systemYellow.withAlphaComponent(0.5).setFill()
            NSBezierPath(rect: clipRect).fill()
        }
        if let last = cigar.last, last.op == .softClip {
            let clipWidth = max(2, CGFloat(Double(last.length) / bpPerPixel))
            let clipRect = NSRect(x: endX - clipWidth, y: y, width: clipWidth, height: readHeight)
            NSColor.systemYellow.withAlphaComponent(0.5).setFill()
            NSBezierPath(rect: clipRect).fill()
        }

        // Duplicate indicator: diagonal stripes
        if isDuplicate {
            drawDuplicatePattern(in: readRect)
        }
    }

    /// Draws individual base letters on the read at high zoom levels.
    private func drawBaseLetters(read: AlignedRead, startX: CGFloat, y: CGFloat, baseColor: NSColor) {
        let basePxWidth = CGFloat(1.0 / bpPerPixel)
        guard basePxWidth >= 4 else { return }  // Too small to render letters

        let fontSize = min(10, max(6, basePxWidth * 0.8))
        let font = NSFont.monospacedSystemFont(ofSize: fontSize, weight: .medium)

        for (i, char) in read.sequence.enumerated() {
            let refPos = read.position + i
            let x = leftMargin + CGFloat(Double(refPos) / bpPerPixel)

            let color: NSColor
            switch char.uppercased() {
            case "A": color = NSColor(red: 0, green: 0.6, blue: 0, alpha: 1)
            case "T": color = NSColor(red: 0.8, green: 0, blue: 0, alpha: 1)
            case "G": color = NSColor(red: 0.8, green: 0.7, blue: 0, alpha: 1)
            case "C": color = NSColor(red: 0, green: 0, blue: 0.8, alpha: 1)
            default: color = .systemGray
            }

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
    }

    /// Draws mismatches parsed from the MD tag as colored ticks on the read.
    ///
    /// The MD tag format: `[0-9]+(([A-Z]|\^[A-Z]+)[0-9]+)*`
    /// Numbers indicate matching bases; letters indicate mismatches;
    /// ^letters indicate deletions from reference.
    private func drawMismatchesFromMD(read: AlignedRead, mdTag: String, readRect: NSRect, y: CGFloat) {
        var refPos = read.position
        var i = mdTag.startIndex

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
                    let queryOffset = refPos - read.position
                    let readBase: Character
                    if queryOffset >= 0 && queryOffset < read.sequence.count {
                        let idx = read.sequence.index(read.sequence.startIndex, offsetBy: queryOffset)
                        readBase = read.sequence[idx]
                    } else {
                        readBase = "N"
                    }

                    let color: NSColor
                    switch readBase.uppercased() {
                    case "A": color = .systemGreen
                    case "T": color = .systemRed
                    case "G": color = .systemYellow
                    case "C": color = .systemBlue
                    default: color = .systemGray
                    }

                    let tickWidth = max(1, CGFloat(1 / bpPerPixel))
                    let tickRect = NSRect(x: mismatchX, y: y, width: tickWidth, height: readHeight)
                    color.setFill()
                    NSBezierPath(rect: tickRect).fill()
                }

                refPos += 1
                i = mdTag.index(after: i)
            } else {
                i = mdTag.index(after: i)
            }
        }
    }

    private func drawDuplicatePattern(in rect: NSRect) {
        // Diagonal lines pattern to indicate potential PCR duplicate
        NSGraphicsContext.current?.saveGraphicsState()

        let clip = NSBezierPath(roundedRect: rect, xRadius: 2, yRadius: 2)
        clip.addClip()

        NSColor.systemOrange.withAlphaComponent(0.3).setStroke()
        let stripe = NSBezierPath()
        stripe.lineWidth = 1
        var x = rect.minX - rect.height
        while x < rect.maxX + rect.height {
            stripe.move(to: NSPoint(x: x, y: rect.minY))
            stripe.line(to: NSPoint(x: x + rect.height, y: rect.maxY))
            x += 6
        }
        stripe.stroke()

        NSGraphicsContext.current?.restoreGraphicsState()
    }

    private func drawEmptyState() {
        let text = "Select a virus to view read alignments" as NSString
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

    /// Finds the read index at a given point in view coordinates.
    private func readIndex(at point: NSPoint) -> Int? {
        let pileupTop = bounds.height - depthTrackHeight - topMargin * 2

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

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if let idx = readIndex(at: point) {
            lastClickedReadIndex = idx
            onReadClicked?(idx)
        } else {
            lastClickedReadIndex = nil
        }
        super.mouseDown(with: event)
    }

    override func rightMouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        lastClickedReadIndex = readIndex(at: point)
        super.rightMouseDown(with: event)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let point = convert(event.locationInWindow, from: nil)
        lastClickedReadIndex = readIndex(at: point)
        return super.menu(for: event)
    }
}
