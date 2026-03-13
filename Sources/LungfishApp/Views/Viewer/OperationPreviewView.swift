// OperationPreviewView.swift - Schematic FASTQ operation previews
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import LungfishIO

// MARK: - FASTQ Operations Color Palette
//
// Centralized palette used by OperationPreviewView and FASTQSparklineStrip.
// All colors are semantic tokens, no hardcoded RGB outside this block.
//
//   Primary   — LungfishTeal (brand color, reads, highlights)
//   Paired    — Indigo       (R2 reads in PE visualizations)
//   Kept      — Green        (pass badges, kept brackets)
//   Trimmed   — Red          (removed regions, fail badges)
//   Adapter   — Orange       (adapter, primer, contaminant, warnings)
//   Quality   — Green/Yellow/Orange/Red (Q-score thresholds)
//   Corrected — Purple       (error correction markers)

/// Brand teal from the asset catalog (dark mode aware).
private let lungfishTeal = NSColor(named: "LungfishTeal", bundle: .module)
    ?? NSColor(red: 0, green: 0.627, blue: 0.690, alpha: 1)

/// Color palette for all FASTQ operation previews.
enum FASTQPalette {
    // -- Structural read colors --
    static let readFill      = lungfishTeal                        // primary read body
    static let readFillFaded = lungfishTeal.withAlphaComponent(0.15) // dimmed / duplicate
    static let pairedRead    = NSColor.systemIndigo                // R2 in PE views

    // -- Semantic action colors --
    static let kept          = NSColor.systemGreen                 // pass / kept
    static let trimmed       = NSColor.systemRed                   // removed / fail
    static let adapter       = NSColor.systemOrange                // adapter, primer, warn
    static let corrected     = NSColor.systemPurple                // error correction

    // -- Quality score thresholds --
    static let qualityHigh   = NSColor.systemGreen                 // Q >= 30
    static let qualityMedium = NSColor.systemYellow                // Q 20-29
    static let qualityLow    = NSColor.systemOrange                // Q 10-19
    static let qualityVeryLow = NSColor.systemRed                  // Q < 10

    // -- Text / labels --
    static let summaryText   = NSColor.labelColor
    static let secondaryText = NSColor.secondaryLabelColor
    static let dimText       = NSColor.tertiaryLabelColor

    // -- DNA base colors (matching SequenceAppearance defaults) --
    static let baseA = NSColor(red: 0, green: 0.627, blue: 0, alpha: 1)   // green
    static let baseT = NSColor(red: 1, green: 0, blue: 0, alpha: 1)       // red
    static let baseG = NSColor(red: 1, green: 0.843, blue: 0, alpha: 1)   // gold
    static let baseC = NSColor(red: 0, green: 0, blue: 1, alpha: 1)       // blue
    static let baseN = NSColor.tertiaryLabelColor                          // ambiguous

    static func dnaBaseColor(_ char: Character) -> NSColor {
        switch char {
        case "A", "a": return baseA
        case "T", "t": return baseT
        case "G", "g": return baseG
        case "C", "c": return baseC
        default:       return baseN
        }
    }

    static func qualityColor(for q: Int) -> NSColor {
        if q >= 30 { return qualityHigh }
        if q >= 20 { return qualityMedium }
        if q >= 10 { return qualityLow }
        return qualityVeryLow
    }
}

// MARK: - OperationPreviewView

/// CoreGraphics canvas that draws schematic read diagrams showing how a
/// FASTQ operation will transform reads. Supports animated parameter updates.
///
/// Each operation type has a dedicated drawing method that renders reads,
/// threshold lines, badges, and annotations appropriate to that operation.
@MainActor
final class OperationPreviewView: NSView {

    // MARK: - Types

    enum OperationKind {
        case subsampleProportion
        case subsampleCount
        case lengthFilter
        case qualityTrim
        case adapterTrim
        case fixedTrim
        case contaminantFilter
        case deduplicate
        case errorCorrection
        case interleaveReformat
        case pairedEndMerge
        case pairedEndRepair
        case primerRemoval
        case searchText
        case searchMotif
        case orient
        case demultiplex
        case qualityReport
        case none
    }

    struct Parameters {
        var proportion: Double = 0.1
        var count: Int = 1000
        var minLength: Int? = nil
        var maxLength: Int? = nil
        var qualityThreshold: Int = 20
        var windowSize: Int = 4
        var trimMode: String = "Cut Right (3')"
        var trim5Prime: Int = 0
        var trim3Prime: Int = 0
        var interleaveDirection: String = "Deinterleave"
        var dedupMode: String = "Sequence"
        var kmerSize: Int = 50
        var searchPattern: String = ""
        var searchField: String = "ID"       // "ID" or "Description"
        var searchRegex: Bool = false
        var reverseComplement: Bool = false
    }

    // MARK: - Properties

    private(set) var operationKind: OperationKind = .none
    var parameters = Parameters() { didSet { needsDisplay = true } }
    private var statistics: FASTQDatasetStatistics?
    private let fastaScrollView = NSScrollView()
    private let fastaTextView = NSTextView()
    private var showsFASTAPreview = true

    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        configureFASTAPreview()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        configureFASTAPreview()
    }

    // MARK: - Public API

    func update(operation: OperationKind, statistics: FASTQDatasetStatistics?) {
        self.operationKind = operation
        self.statistics = statistics
        needsDisplay = true
        updateAccessibility(operation)
    }

    private func updateAccessibility(_ operation: OperationKind) {
        setAccessibilityRole(.image)
        setAccessibilityLabel("Operation Preview")
        let desc: String
        switch operation {
        case .none: desc = "No operation selected"
        case .qualityReport: desc = "Quality report schematic"
        default: desc = "Schematic showing how reads will be transformed"
        }
        setAccessibilityValue(desc)
    }

    func setFASTAContent(_ text: String) {
        showsFASTAPreview = true
        fastaScrollView.isHidden = false
        fastaTextView.string = text
        refreshFASTATextViewSize()
        needsDisplay = true
    }

    private func configureFASTAPreview() {

        fastaScrollView.translatesAutoresizingMaskIntoConstraints = false
        fastaScrollView.borderType = .noBorder
        fastaScrollView.drawsBackground = true
        fastaScrollView.backgroundColor = .textBackgroundColor
        fastaScrollView.hasVerticalScroller = true
        fastaScrollView.hasHorizontalScroller = true
        fastaScrollView.autohidesScrollers = true

        fastaTextView.isEditable = false
        fastaTextView.isSelectable = true
        fastaTextView.isRichText = false
        fastaTextView.importsGraphics = false
        fastaTextView.allowsUndo = false
        fastaTextView.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        fastaTextView.textColor = .labelColor
        fastaTextView.backgroundColor = .textBackgroundColor
        fastaTextView.usesFindPanel = true
        fastaTextView.isVerticallyResizable = true
        fastaTextView.isHorizontallyResizable = true
        fastaTextView.autoresizingMask = []
        fastaTextView.minSize = NSSize(width: 0, height: 0)
        fastaTextView.maxSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )
        if let textContainer = fastaTextView.textContainer {
            textContainer.widthTracksTextView = false
            textContainer.containerSize = NSSize(
                width: CGFloat.greatestFiniteMagnitude,
                height: CGFloat.greatestFiniteMagnitude
            )
            textContainer.lineBreakMode = .byClipping
            textContainer.lineFragmentPadding = 0
        }
        fastaTextView.textContainerInset = NSSize(width: 8, height: 8)
        fastaScrollView.documentView = fastaTextView

        addSubview(fastaScrollView)
        NSLayoutConstraint.activate([
            fastaScrollView.topAnchor.constraint(equalTo: topAnchor),
            fastaScrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            fastaScrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            fastaScrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    override func layout() {
        super.layout()
        if showsFASTAPreview {
            refreshFASTATextViewSize()
        }
    }

    private func refreshFASTATextViewSize() {
        guard let textContainer = fastaTextView.textContainer,
              let layoutManager = fastaTextView.layoutManager else { return }

        layoutManager.ensureLayout(for: textContainer)
        let used = layoutManager.usedRect(for: textContainer)
        let inset = fastaTextView.textContainerInset

        let targetWidth = max(
            fastaScrollView.contentSize.width,
            ceil(used.width + inset.width * 2 + 8)
        )
        let targetHeight = max(
            fastaScrollView.contentSize.height,
            ceil(used.height + inset.height * 2 + 8)
        )
        let currentSize = fastaTextView.frame.size
        if abs(currentSize.width - targetWidth) > 0.5 || abs(currentSize.height - targetHeight) > 0.5 {
            fastaTextView.setFrameSize(NSSize(width: targetWidth, height: targetHeight))
        }
    }

    // MARK: - Common Drawing Constants

    private let readHeight: CGFloat = 20
    private let readCornerRadius: CGFloat = 3
    private let readSpacing: CGFloat = 8
    private let qualityBarHeight: CGFloat = 4
    private let drawPadding: CGFloat = 16

    private var drawableRect: CGRect {
        bounds.insetBy(dx: drawPadding, dy: drawPadding)
    }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        if showsFASTAPreview {
            return
        }

        guard let ctx = NSGraphicsContext.current?.cgContext else { return }

        // Background
        ctx.setFillColor(NSColor.textBackgroundColor.cgColor)
        ctx.fill(bounds)

        let rect = drawableRect
        guard rect.width > 20, rect.height > 20 else { return }

        switch operationKind {
        case .subsampleProportion, .subsampleCount:
            drawSubsamplePreview(ctx: ctx, rect: rect)
        case .qualityTrim:
            drawQualityTrimPreview(ctx: ctx, rect: rect)
        case .lengthFilter:
            drawLengthFilterPreview(ctx: ctx, rect: rect)
        case .fixedTrim:
            drawFixedTrimPreview(ctx: ctx, rect: rect)
        case .adapterTrim:
            drawAdapterTrimPreview(ctx: ctx, rect: rect)
        case .deduplicate:
            drawDeduplicatePreview(ctx: ctx, rect: rect)
        case .errorCorrection:
            drawErrorCorrectionPreview(ctx: ctx, rect: rect)
        case .interleaveReformat:
            drawInterleavePreview(ctx: ctx, rect: rect)
        case .contaminantFilter:
            drawContaminantFilterPreview(ctx: ctx, rect: rect)
        case .pairedEndMerge:
            drawPairedEndMergePreview(ctx: ctx, rect: rect)
        case .pairedEndRepair:
            drawPairedEndRepairPreview(ctx: ctx, rect: rect)
        case .primerRemoval:
            drawPrimerRemovalPreview(ctx: ctx, rect: rect)
        case .searchText, .searchMotif:
            drawSearchPreview(ctx: ctx, rect: rect)
        case .orient:
            drawDemultiplexPreview(ctx: ctx, rect: rect)
        case .demultiplex:
            drawDemultiplexPreview(ctx: ctx, rect: rect)
        case .qualityReport:
            drawQualityReportPreview(ctx: ctx, rect: rect)
        case .none:
            drawIdleState(ctx: ctx, rect: rect)
        }
    }

    // MARK: - Idle State

    private func drawIdleState(ctx: CGContext, rect: CGRect) {
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 14),
            .foregroundColor: FASTQPalette.dimText,
        ]
        let str = NSAttributedString(string: "Select an operation to preview", attributes: attrs)
        let size = str.size()
        str.draw(at: CGPoint(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2))
    }

    // MARK: - Subsample Preview

    private func drawSubsamplePreview(ctx: CGContext, rect: CGRect) {
        let displayCount = 8
        let proportion: Double
        if operationKind == .subsampleProportion {
            proportion = parameters.proportion
        } else {
            let total = statistics?.readCount ?? 10000
            proportion = min(1.0, Double(parameters.count) / Double(max(1, total)))
        }

        let keptCount = Int(floor(Double(displayCount) * proportion))

        // Summary text
        let summaryAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12, weight: .medium),
            .foregroundColor: FASTQPalette.summaryText,
        ]
        let summaryStr = NSAttributedString(
            string: "Keeping \(keptCount) of \(displayCount) reads (\(String(format: "%.0f", proportion * 100))%)",
            attributes: summaryAttrs
        )
        summaryStr.draw(at: CGPoint(x: rect.midX - summaryStr.size().width / 2, y: rect.minY))

        let readAreaTop = rect.minY + 24
        let readWidth = rect.width - 60 // leave room for badges

        for i in 0..<displayCount {
            let y = readAreaTop + CGFloat(i) * (readHeight + readSpacing)
            guard y + readHeight <= rect.maxY else { break }

            let isKept = i < keptCount
            let readRect = CGRect(x: rect.minX, y: y, width: readWidth, height: readHeight)

            // Read body
            let readPath = CGPath(roundedRect: readRect, cornerWidth: readCornerRadius, cornerHeight: readCornerRadius, transform: nil)
            ctx.addPath(readPath)
            ctx.setFillColor(FASTQPalette.readFill.withAlphaComponent(0.6).cgColor)
            ctx.fillPath()

            if !isKept {
                // Fade overlay
                ctx.addPath(readPath)
                ctx.setFillColor(NSColor.windowBackgroundColor.withAlphaComponent(0.7).cgColor)
                ctx.fillPath()
            }

            // Read label
            let labelAttrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.monospacedSystemFont(ofSize: 9, weight: .regular),
                .foregroundColor: isKept ? FASTQPalette.secondaryText : FASTQPalette.dimText,
            ]
            let label = NSAttributedString(string: "Read \(i + 1)", attributes: labelAttrs)
            label.draw(at: CGPoint(x: readRect.minX + 4, y: readRect.minY + 3))

            // Badge
            let badgeX = readRect.maxX + 8
            let badgeY = y + 3
            drawBadge(ctx: ctx, x: badgeX, y: badgeY,
                      text: isKept ? "KEPT" : "SKIP",
                      color: isKept ? FASTQPalette.kept : FASTQPalette.dimText)
        }
    }

    // MARK: - Quality Trim Preview

    private func drawQualityTrimPreview(ctx: CGContext, rect: CGRect) {
        let readLength = 50
        let threshold = parameters.qualityThreshold
        let windowSize = parameters.windowSize

        // Deterministic quality profile (Q35 tapering to Q3)
        let qualities: [Int] = (0..<readLength).map { pos in
            let fraction = Double(pos) / Double(readLength - 1)
            return max(2, min(40, Int(35.0 - fraction * 32.0)))
        }

        // Find trim point (sliding window from right)
        var trimPoint = readLength
        if parameters.trimMode.contains("Right") || parameters.trimMode.contains("Both") {
            for pos in stride(from: readLength - windowSize, through: 0, by: -1) {
                let windowEnd = min(pos + windowSize, readLength)
                let windowQualities = qualities[pos..<windowEnd]
                let meanQ = windowQualities.reduce(0, +) / windowQualities.count
                if meanQ >= threshold {
                    trimPoint = windowEnd
                    break
                }
            }
        }

        let cellWidth = min(rect.width / CGFloat(readLength), 14)
        let totalReadWidth = cellWidth * CGFloat(readLength)
        let startX = rect.minX + (rect.width - totalReadWidth) / 2
        let readY = rect.midY - 20

        // Summary
        let summaryAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12, weight: .medium),
            .foregroundColor: FASTQPalette.summaryText,
        ]
        let summary = NSAttributedString(
            string: "Quality Trim Q\(threshold): keeping \(trimPoint) of \(readLength) bp",
            attributes: summaryAttrs
        )
        summary.draw(at: CGPoint(x: rect.midX - summary.size().width / 2, y: rect.minY))

        // Draw base cells
        for i in 0..<readLength {
            let x = startX + CGFloat(i) * cellWidth
            let q = qualities[i]
            let isTrimmed = i >= trimPoint

            let cellColor = FASTQPalette.qualityColor(for: q)

            let cellRect = CGRect(x: x, y: readY, width: cellWidth - 0.5, height: 24)

            // Base cell background
            ctx.setFillColor(cellColor.withAlphaComponent(isTrimmed ? 0.15 : 0.5).cgColor)
            ctx.fill(cellRect)

            // Base letter (only if cells are wide enough)
            if cellWidth >= 10 {
                let bases = ["A", "T", "G", "C"]
                let base = bases[i % 4]
                let baseAttrs: [NSAttributedString.Key: Any] = [
                    .font: NSFont.monospacedSystemFont(ofSize: min(11, cellWidth - 2), weight: .regular),
                    .foregroundColor: isTrimmed ? FASTQPalette.dimText : FASTQPalette.summaryText,
                ]
                let baseStr = NSAttributedString(string: base, attributes: baseAttrs)
                let baseSize = baseStr.size()
                baseStr.draw(at: CGPoint(
                    x: cellRect.midX - baseSize.width / 2,
                    y: cellRect.midY - baseSize.height / 2
                ))
            }

            // Quality value below
            if cellWidth >= 8 {
                let qAttrs: [NSAttributedString.Key: Any] = [
                    .font: NSFont.monospacedDigitSystemFont(ofSize: 7, weight: .regular),
                    .foregroundColor: FASTQPalette.secondaryText,
                ]
                let qStr = NSAttributedString(string: "\(q)", attributes: qAttrs)
                let qSize = qStr.size()
                qStr.draw(at: CGPoint(x: cellRect.midX - qSize.width / 2, y: cellRect.maxY + 1))
            }
        }

        // Trim line
        if trimPoint < readLength {
            let lineX = startX + CGFloat(trimPoint) * cellWidth
            ctx.setStrokeColor(FASTQPalette.readFill.cgColor)
            ctx.setLineWidth(1.5)
            ctx.setLineDash(phase: 0, lengths: [4, 3])
            ctx.move(to: CGPoint(x: lineX, y: readY - 8))
            ctx.addLine(to: CGPoint(x: lineX, y: readY + 42))
            ctx.strokePath()
            ctx.setLineDash(phase: 0, lengths: [])

            // Trimmed region overlay
            let trimRect = CGRect(
                x: lineX, y: readY,
                width: totalReadWidth + startX - lineX,
                height: 24
            )
            ctx.setFillColor(FASTQPalette.trimmed.withAlphaComponent(0.1).cgColor)
            ctx.fill(trimRect)

            // Brackets
            drawBracket(ctx: ctx, x: startX, width: CGFloat(trimPoint) * cellWidth,
                        y: readY + 40, label: "Kept: \(trimPoint) bp", color: FASTQPalette.kept)
            drawBracket(ctx: ctx, x: lineX, width: CGFloat(readLength - trimPoint) * cellWidth,
                        y: readY + 40, label: "Trimmed: \(readLength - trimPoint) bp", color: FASTQPalette.trimmed)
        }

        // 5' / 3' labels
        let endLabelAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 10, weight: .semibold),
            .foregroundColor: FASTQPalette.secondaryText,
        ]
        NSAttributedString(string: "5'", attributes: endLabelAttrs)
            .draw(at: CGPoint(x: startX - 16, y: readY + 4))
        NSAttributedString(string: "3'", attributes: endLabelAttrs)
            .draw(at: CGPoint(x: startX + totalReadWidth + 4, y: readY + 4))
    }

    // MARK: - Length Filter Preview

    private func drawLengthFilterPreview(ctx: CGContext, rect: CGRect) {
        let minLen = parameters.minLength ?? 0
        let maxLen = parameters.maxLength ?? 200

        // Representative reads with varying lengths
        let readLengths: [Int]
        if let stats = statistics {
            // Sample from actual distribution
            let sorted = stats.readLengthHistogram.sorted { $0.key < $1.key }
            let totalReads = sorted.reduce(0) { $0 + $1.value }
            var sampled: [Int] = []
            for (length, count) in sorted {
                let sampleCount = max(0, Int(round(Double(count) / Double(max(1, totalReads)) * 8)))
                for _ in 0..<min(sampleCount, 2) {
                    sampled.append(length)
                }
            }
            readLengths = Array(sampled.prefix(8))
        } else {
            readLengths = [35, 80, 120, 15, 151, 200, 50, 180]
        }

        let displayReads = readLengths.isEmpty ? [35, 80, 120, 15, 151, 200, 50, 180] : readLengths
        let maxDisplayLength = displayReads.max() ?? 200
        let readAreaTop = rect.minY + 24
        let readAreaWidth = rect.width - 80

        // Summary
        let passing = displayReads.filter {
            ($0 >= (parameters.minLength ?? 0)) &&
            ($0 <= (parameters.maxLength ?? Int.max))
        }.count
        let summaryAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12, weight: .medium),
            .foregroundColor: FASTQPalette.summaryText,
        ]
        let summary = NSAttributedString(
            string: "Keeping \(passing) of \(displayReads.count) reads (min: \(minLen) bp, max: \(maxLen) bp)",
            attributes: summaryAttrs
        )
        summary.draw(at: CGPoint(x: rect.midX - summary.size().width / 2, y: rect.minY))

        // Draw reads
        for (i, length) in displayReads.enumerated() {
            let y = readAreaTop + CGFloat(i) * (readHeight + readSpacing)
            guard y + readHeight <= rect.maxY else { break }

            let isKept = (length >= (parameters.minLength ?? 0)) &&
                         (length <= (parameters.maxLength ?? Int.max))
            let readWidth = readAreaWidth * CGFloat(length) / CGFloat(max(1, maxDisplayLength))
            let readRect = CGRect(x: rect.minX, y: y, width: readWidth, height: readHeight)

            let readPath = CGPath(roundedRect: readRect, cornerWidth: readCornerRadius, cornerHeight: readCornerRadius, transform: nil)
            let color: NSColor = isKept
                ? FASTQPalette.readFill.withAlphaComponent(0.5)
                : FASTQPalette.dimText.withAlphaComponent(0.3)
            ctx.addPath(readPath)
            ctx.setFillColor(color.cgColor)
            ctx.fillPath()

            // Length label
            let labelAttrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 9, weight: .regular),
                .foregroundColor: isKept ? FASTQPalette.secondaryText : FASTQPalette.dimText,
            ]
            NSAttributedString(string: "\(length) bp", attributes: labelAttrs)
                .draw(at: CGPoint(x: readRect.maxX + 4, y: y + 4))

            if !isKept {
                // Strikethrough
                ctx.setStrokeColor(FASTQPalette.adapter.cgColor)
                ctx.setLineWidth(1)
                ctx.move(to: CGPoint(x: readRect.minX, y: readRect.midY))
                ctx.addLine(to: CGPoint(x: readRect.maxX, y: readRect.midY))
                ctx.strokePath()
            }
        }

        // Threshold lines
        if let minLength = parameters.minLength, minLength > 0 {
            let lineX = rect.minX + readAreaWidth * CGFloat(minLength) / CGFloat(max(1, maxDisplayLength))
            drawThresholdLine(ctx: ctx, x: lineX, rect: rect, label: "Min: \(minLength) bp", color: FASTQPalette.adapter)
        }
        if let maxLength = parameters.maxLength, maxLength < maxDisplayLength * 2 {
            let lineX = rect.minX + readAreaWidth * CGFloat(maxLength) / CGFloat(max(1, maxDisplayLength))
            drawThresholdLine(ctx: ctx, x: lineX, rect: rect, label: "Max: \(maxLength) bp", color: FASTQPalette.trimmed)
        }
    }

    // MARK: - Fixed Trim Preview

    private func drawFixedTrimPreview(ctx: CGContext, rect: CGRect) {
        let readLength = 100
        let trim5 = parameters.trim5Prime
        let trim3 = parameters.trim3Prime
        let kept = max(0, readLength - trim5 - trim3)

        let readWidth = rect.width - 40
        let readY = rect.midY - 20

        // Summary
        let summaryAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12, weight: .medium),
            .foregroundColor: FASTQPalette.summaryText,
        ]
        let summary = NSAttributedString(
            string: "Fixed Trim: keeping \(kept) of \(readLength) bp",
            attributes: summaryAttrs
        )
        summary.draw(at: CGPoint(x: rect.midX - summary.size().width / 2, y: rect.minY))

        let readRect = CGRect(x: rect.minX + 20, y: readY, width: readWidth, height: readHeight)

        // Full read background
        ctx.setFillColor(FASTQPalette.readFill.withAlphaComponent(0.5).cgColor)
        ctx.fill(readRect)

        // 5' trim region
        if trim5 > 0 {
            let trimWidth = readWidth * CGFloat(trim5) / CGFloat(readLength)
            let trimRect = CGRect(x: readRect.minX, y: readY, width: trimWidth, height: readHeight)
            ctx.setFillColor(FASTQPalette.trimmed.withAlphaComponent(0.2).cgColor)
            ctx.fill(trimRect)

            // Hatch lines
            drawHatch(ctx: ctx, rect: trimRect)

            drawBracket(ctx: ctx, x: trimRect.minX, width: trimWidth,
                        y: readY + readHeight + 8, label: "5' Trim: \(trim5) bp", color: FASTQPalette.trimmed)
        }

        // 3' trim region
        if trim3 > 0 {
            let trimWidth = readWidth * CGFloat(trim3) / CGFloat(readLength)
            let trimRect = CGRect(x: readRect.maxX - trimWidth, y: readY, width: trimWidth, height: readHeight)
            ctx.setFillColor(FASTQPalette.trimmed.withAlphaComponent(0.2).cgColor)
            ctx.fill(trimRect)

            drawHatch(ctx: ctx, rect: trimRect)

            drawBracket(ctx: ctx, x: trimRect.minX, width: trimWidth,
                        y: readY + readHeight + 8, label: "3' Trim: \(trim3) bp", color: FASTQPalette.trimmed)
        }

        // Kept bracket
        let keptStart = readRect.minX + readWidth * CGFloat(trim5) / CGFloat(readLength)
        let keptWidth = readWidth * CGFloat(kept) / CGFloat(readLength)
        if kept > 0 {
            drawBracket(ctx: ctx, x: keptStart, width: keptWidth,
                        y: readY - 16, label: "Kept: \(kept) bp", color: FASTQPalette.kept)
        }

        // 5' / 3' labels
        let endLabelAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 10, weight: .semibold),
            .foregroundColor: FASTQPalette.secondaryText,
        ]
        NSAttributedString(string: "5'", attributes: endLabelAttrs)
            .draw(at: CGPoint(x: readRect.minX - 16, y: readY + 3))
        NSAttributedString(string: "3'", attributes: endLabelAttrs)
            .draw(at: CGPoint(x: readRect.maxX + 4, y: readY + 3))

        // Warning if trimming everything
        if kept <= 0 {
            let warnAttrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 11, weight: .medium),
                .foregroundColor: FASTQPalette.trimmed,
            ]
            let warn = NSAttributedString(string: "Warning: trim removes entire read", attributes: warnAttrs)
            warn.draw(at: CGPoint(x: rect.midX - warn.size().width / 2, y: rect.maxY - 20))
        }
    }

    // MARK: - Adapter Trim Preview

    private func drawAdapterTrimPreview(ctx: CGContext, rect: CGRect) {
        let readLength = 150
        let adapterLength = 20
        let genomicLength = readLength - adapterLength

        let readWidth = rect.width - 40
        let readY = rect.midY - 20
        let genomicWidth = readWidth * CGFloat(genomicLength) / CGFloat(readLength)
        let adapterWidth = readWidth - genomicWidth
        let startX = rect.minX + 20

        // Summary
        let summaryAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12, weight: .medium),
            .foregroundColor: FASTQPalette.summaryText,
        ]
        let summary = NSAttributedString(
            string: "Adapter Removal: keeping \(genomicLength) bp genomic",
            attributes: summaryAttrs
        )
        summary.draw(at: CGPoint(x: rect.midX - summary.size().width / 2, y: rect.minY))

        // Genomic region
        let genomicRect = CGRect(x: startX, y: readY, width: genomicWidth, height: readHeight)
        ctx.setFillColor(FASTQPalette.readFill.withAlphaComponent(0.3).cgColor)
        ctx.fill(genomicRect)

        // Adapter region
        let adapterRect = CGRect(x: startX + genomicWidth, y: readY, width: adapterWidth, height: readHeight)
        ctx.setFillColor(FASTQPalette.adapter.withAlphaComponent(0.5).cgColor)
        ctx.fill(adapterRect)

        // Adapter top border
        ctx.setStrokeColor(FASTQPalette.adapter.cgColor)
        ctx.setLineWidth(2)
        ctx.move(to: CGPoint(x: adapterRect.minX, y: adapterRect.minY))
        ctx.addLine(to: CGPoint(x: adapterRect.maxX, y: adapterRect.minY))
        ctx.strokePath()

        // "Adapter" label
        let adapterLabel: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 10, weight: .semibold),
            .foregroundColor: FASTQPalette.adapter,
        ]
        NSAttributedString(string: "Adapter", attributes: adapterLabel)
            .draw(at: CGPoint(x: adapterRect.midX - 20, y: adapterRect.minY - 14))

        // Clip line
        let clipX = startX + genomicWidth
        ctx.setStrokeColor(FASTQPalette.readFill.cgColor)
        ctx.setLineWidth(1.5)
        ctx.setLineDash(phase: 0, lengths: [4, 3])
        ctx.move(to: CGPoint(x: clipX, y: readY - 8))
        ctx.addLine(to: CGPoint(x: clipX, y: readY + readHeight + 16))
        ctx.strokePath()
        ctx.setLineDash(phase: 0, lengths: [])

        // Brackets
        drawBracket(ctx: ctx, x: startX, width: genomicWidth,
                    y: readY + readHeight + 8, label: "Kept: \(genomicLength) bp", color: FASTQPalette.kept)
        drawBracket(ctx: ctx, x: clipX, width: adapterWidth,
                    y: readY + readHeight + 8, label: "Removed: \(adapterLength) bp", color: FASTQPalette.trimmed)
    }

    // MARK: - Deduplicate Preview

    private func drawDeduplicatePreview(ctx: CGContext, rect: CGRect) {
        let groups: [(sequence: String, count: Int)] = [
            ("ATGCCATG...", 3),
            ("GCTTAAGC...", 2),
            ("TACCGGTA...", 1),
        ]

        var y = rect.minY + 24
        let readWidth = rect.width - 80

        // Summary
        let totalReads = groups.reduce(0) { $0 + $1.count }
        let unique = groups.count
        let summaryAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12, weight: .medium),
            .foregroundColor: FASTQPalette.summaryText,
        ]
        let summary = NSAttributedString(
            string: "Deduplicate: \(unique) unique of \(totalReads) reads",
            attributes: summaryAttrs
        )
        summary.draw(at: CGPoint(x: rect.midX - summary.size().width / 2, y: rect.minY))

        for group in groups {
            for j in 0..<group.count {
                guard y + readHeight <= rect.maxY else { return }

                let isDuplicate = j > 0
                let readRect = CGRect(x: rect.minX, y: y, width: readWidth, height: readHeight)
                let readPath = CGPath(roundedRect: readRect, cornerWidth: readCornerRadius, cornerHeight: readCornerRadius, transform: nil)

                ctx.addPath(readPath)
                ctx.setFillColor((isDuplicate ? FASTQPalette.readFillFaded : FASTQPalette.readFill.withAlphaComponent(0.5)).cgColor)
                ctx.fillPath()

                // Sequence label
                let seqAttrs: [NSAttributedString.Key: Any] = [
                    .font: NSFont.monospacedSystemFont(ofSize: 9, weight: .regular),
                    .foregroundColor: isDuplicate ? FASTQPalette.dimText : FASTQPalette.secondaryText,
                ]
                NSAttributedString(string: group.sequence, attributes: seqAttrs)
                    .draw(at: CGPoint(x: readRect.minX + 4, y: readRect.minY + 4))

                // Badge
                let badgeX = readRect.maxX + 8
                drawBadge(ctx: ctx, x: badgeX, y: y + 3,
                          text: isDuplicate ? "DUP" : "UNIQUE",
                          color: isDuplicate ? FASTQPalette.adapter : FASTQPalette.kept)

                y += readHeight + readSpacing
            }
        }
    }

    // MARK: - Error Correction Preview

    private func drawErrorCorrectionPreview(ctx: CGContext, rect: CGRect) {
        let readLength = 30
        let errorPositions = [5, 12, 22]

        let cellWidth = min(rect.width / CGFloat(readLength), 14)
        let totalWidth = cellWidth * CGFloat(readLength)
        let startX = rect.minX + (rect.width - totalWidth) / 2
        let readY = rect.midY - 20

        let summaryAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12, weight: .medium),
            .foregroundColor: FASTQPalette.summaryText,
        ]
        let summary = NSAttributedString(
            string: "Error Correction: \(errorPositions.count) errors detected (k=\(parameters.kmerSize))",
            attributes: summaryAttrs
        )
        summary.draw(at: CGPoint(x: rect.midX - summary.size().width / 2, y: rect.minY))

        let bases = ["A", "T", "G", "C"]
        let errors = ["a", "g", "c"]  // lowercase = error

        for i in 0..<readLength {
            let x = startX + CGFloat(i) * cellWidth
            let isError = errorPositions.contains(i)

            let cellRect = CGRect(x: x, y: readY, width: cellWidth - 0.5, height: 24)
            let cellColor: NSColor = isError
                ? FASTQPalette.trimmed.withAlphaComponent(0.4)
                : FASTQPalette.readFill.withAlphaComponent(0.2)
            ctx.setFillColor(cellColor.cgColor)
            ctx.fill(cellRect)

            if cellWidth >= 10 {
                let base = isError ? errors[errorPositions.firstIndex(of: i)! % errors.count] : bases[i % 4]
                let baseAttrs: [NSAttributedString.Key: Any] = [
                    .font: NSFont.monospacedSystemFont(ofSize: min(11, cellWidth - 2), weight: isError ? .bold : .regular),
                    .foregroundColor: isError ? FASTQPalette.trimmed : FASTQPalette.summaryText,
                ]
                let baseStr = NSAttributedString(string: base.uppercased(), attributes: baseAttrs)
                let baseSize = baseStr.size()
                baseStr.draw(at: CGPoint(x: cellRect.midX - baseSize.width / 2, y: cellRect.midY - baseSize.height / 2))
            }

            // Error arrow
            if isError {
                ctx.setFillColor(FASTQPalette.trimmed.cgColor)
                let midX = cellRect.midX
                let arrowY = cellRect.minY - 2
                ctx.move(to: CGPoint(x: midX, y: arrowY))
                ctx.addLine(to: CGPoint(x: midX - 3, y: arrowY - 6))
                ctx.addLine(to: CGPoint(x: midX + 3, y: arrowY - 6))
                ctx.closePath()
                ctx.fillPath()
            }
        }
    }

    // MARK: - Interleave Preview

    private func drawInterleavePreview(ctx: CGContext, rect: CGRect) {
        let isDeinterleave = parameters.interleaveDirection.contains("Deinterleave")
        let pairCount = 3

        let headerAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12, weight: .medium),
            .foregroundColor: FASTQPalette.summaryText,
        ]
        let labelAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 9, weight: .bold),
            .foregroundColor: FASTQPalette.secondaryText,
        ]

        // Arrow symbol
        let arrowX = rect.midX
        let arrowWidth: CGFloat = 40

        if isDeinterleave {
            // Interleaved single file → two separate R1/R2 files
            let summaryStr = NSAttributedString(string: "Deinterleave: one file → R1 + R2 files", attributes: headerAttrs)
            summaryStr.draw(at: CGPoint(x: rect.midX - summaryStr.size().width / 2, y: rect.minY))

            let colLeft = rect.minX
            let colR1 = arrowX + arrowWidth / 2 + 8
            let colR2 = colR1 + (rect.maxX - colR1) / 2
            let readAreaTop = rect.minY + 24
            let readW = min((arrowX - arrowWidth / 2 - colLeft - 8), 160)
            let outW = min((rect.maxX - colR1) / 2 - 4, 100)

            // Column headers
            let colHeaderAttrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 10, weight: .semibold),
                .foregroundColor: FASTQPalette.secondaryText,
            ]
            NSAttributedString(string: "Interleaved", attributes: colHeaderAttrs)
                .draw(at: CGPoint(x: colLeft, y: readAreaTop))
            NSAttributedString(string: "R1 output", attributes: colHeaderAttrs)
                .draw(at: CGPoint(x: colR1, y: readAreaTop))
            NSAttributedString(string: "R2 output", attributes: colHeaderAttrs)
                .draw(at: CGPoint(x: colR2, y: readAreaTop))

            let rowStart = readAreaTop + 18
            for i in 0..<pairCount {
                let yR1 = rowStart + CGFloat(i * 2) * (readHeight + 4)
                let yR2 = yR1 + readHeight + 4
                guard yR2 + readHeight <= rect.maxY else { break }

                // Input: interleaved R1, R2 in one file
                let r1In = CGRect(x: colLeft, y: yR1, width: readW, height: readHeight)
                let r2In = CGRect(x: colLeft, y: yR2, width: readW, height: readHeight)
                ctx.setFillColor(FASTQPalette.readFill.withAlphaComponent(0.5).cgColor)
                ctx.fill(r1In)
                ctx.setFillColor(FASTQPalette.pairedRead.withAlphaComponent(0.5).cgColor)
                ctx.fill(r2In)
                NSAttributedString(string: "R1.\(i+1)", attributes: labelAttrs).draw(at: CGPoint(x: r1In.minX + 3, y: yR1 + 3))
                NSAttributedString(string: "R2.\(i+1)", attributes: labelAttrs).draw(at: CGPoint(x: r2In.minX + 3, y: yR2 + 3))

                // Arrows
                ctx.setStrokeColor(FASTQPalette.secondaryText.cgColor)
                ctx.setLineWidth(1)
                ctx.move(to: CGPoint(x: r1In.maxX + 4, y: r1In.midY))
                ctx.addLine(to: CGPoint(x: colR1 - 4, y: yR1 + readHeight / 2))
                ctx.move(to: CGPoint(x: r2In.maxX + 4, y: r2In.midY))
                ctx.addLine(to: CGPoint(x: colR2 - 4, y: yR2 + readHeight / 2))
                ctx.strokePath()

                // Output: R1 file
                let r1Out = CGRect(x: colR1, y: yR1, width: outW, height: readHeight)
                ctx.setFillColor(FASTQPalette.readFill.withAlphaComponent(0.5).cgColor)
                ctx.fill(r1Out)
                NSAttributedString(string: "R1.\(i+1)", attributes: labelAttrs).draw(at: CGPoint(x: r1Out.minX + 3, y: yR1 + 3))

                // Output: R2 file
                let r2Out = CGRect(x: colR2, y: yR2, width: outW, height: readHeight)
                ctx.setFillColor(FASTQPalette.pairedRead.withAlphaComponent(0.5).cgColor)
                ctx.fill(r2Out)
                NSAttributedString(string: "R2.\(i+1)", attributes: labelAttrs).draw(at: CGPoint(x: r2Out.minX + 3, y: yR2 + 3))
            }
        } else {
            // Two separate R1/R2 files → one interleaved file
            let summaryStr = NSAttributedString(string: "Interleave: R1 + R2 files → one interleaved file", attributes: headerAttrs)
            summaryStr.draw(at: CGPoint(x: rect.midX - summaryStr.size().width / 2, y: rect.minY))

            let colR1 = rect.minX
            let colR2 = rect.minX
            let colOut = arrowX + arrowWidth / 2 + 8
            let readAreaTop = rect.minY + 24
            let inW = min((arrowX - arrowWidth / 2 - colR1 - 8), 140)
            let outW = min((rect.maxX - colOut - 4), 160)

            // Column headers
            let colHeaderAttrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 10, weight: .semibold),
                .foregroundColor: FASTQPalette.secondaryText,
            ]
            NSAttributedString(string: "R1 + R2 input", attributes: colHeaderAttrs)
                .draw(at: CGPoint(x: colR1, y: readAreaTop))
            NSAttributedString(string: "Interleaved output", attributes: colHeaderAttrs)
                .draw(at: CGPoint(x: colOut, y: readAreaTop))

            let rowStart = readAreaTop + 18
            for i in 0..<pairCount {
                let yR1 = rowStart + CGFloat(i * 2) * (readHeight + 4)
                let yR2 = yR1 + readHeight + 4
                guard yR2 + readHeight <= rect.maxY else { break }

                // Input: separate R1 and R2
                let r1In = CGRect(x: colR1, y: yR1, width: inW, height: readHeight)
                let r2In = CGRect(x: colR2, y: yR2, width: inW, height: readHeight)
                ctx.setFillColor(FASTQPalette.readFill.withAlphaComponent(0.5).cgColor)
                ctx.fill(r1In)
                ctx.setFillColor(FASTQPalette.pairedRead.withAlphaComponent(0.5).cgColor)
                ctx.fill(r2In)
                NSAttributedString(string: "R1.\(i+1)", attributes: labelAttrs).draw(at: CGPoint(x: r1In.minX + 3, y: yR1 + 3))
                NSAttributedString(string: "R2.\(i+1)", attributes: labelAttrs).draw(at: CGPoint(x: r2In.minX + 3, y: yR2 + 3))

                // Arrows to interleaved output
                ctx.setStrokeColor(FASTQPalette.secondaryText.cgColor)
                ctx.setLineWidth(1)
                ctx.move(to: CGPoint(x: r1In.maxX + 4, y: r1In.midY))
                ctx.addLine(to: CGPoint(x: colOut - 4, y: yR1 + readHeight / 2))
                ctx.move(to: CGPoint(x: r2In.maxX + 4, y: r2In.midY))
                ctx.addLine(to: CGPoint(x: colOut - 4, y: yR2 + readHeight / 2))
                ctx.strokePath()

                // Output: interleaved (R1 then R2)
                let outR1 = CGRect(x: colOut, y: yR1, width: outW, height: readHeight)
                let outR2 = CGRect(x: colOut, y: yR2, width: outW, height: readHeight)
                ctx.setFillColor(FASTQPalette.readFill.withAlphaComponent(0.5).cgColor)
                ctx.fill(outR1)
                ctx.setFillColor(FASTQPalette.pairedRead.withAlphaComponent(0.5).cgColor)
                ctx.fill(outR2)
                NSAttributedString(string: "R1.\(i+1)", attributes: labelAttrs).draw(at: CGPoint(x: outR1.minX + 3, y: yR1 + 3))
                NSAttributedString(string: "R2.\(i+1)", attributes: labelAttrs).draw(at: CGPoint(x: outR2.minX + 3, y: yR2 + 3))
            }
        }
    }

    // MARK: - Contaminant Filter Preview

    private func drawContaminantFilterPreview(ctx: CGContext, rect: CGRect) {
        let reads: [(label: String, isContaminant: Bool)] = [
            ("Genomic read 1", false),
            ("Genomic read 2", false),
            ("PhiX match", true),
            ("Genomic read 3", false),
            ("PhiX match", true),
            ("Genomic read 4", false),
        ]

        var y = rect.minY + 24
        let readWidth = rect.width - 80

        let summaryAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12, weight: .medium),
            .foregroundColor: FASTQPalette.summaryText,
        ]
        let passing = reads.filter { !$0.isContaminant }.count
        let summary = NSAttributedString(
            string: "Contaminant Filter: \(passing) of \(reads.count) reads pass",
            attributes: summaryAttrs
        )
        summary.draw(at: CGPoint(x: rect.midX - summary.size().width / 2, y: rect.minY))

        for read in reads {
            guard y + readHeight <= rect.maxY else { return }

            let readRect = CGRect(x: rect.minX, y: y, width: readWidth, height: readHeight)
            let readPath = CGPath(roundedRect: readRect, cornerWidth: readCornerRadius, cornerHeight: readCornerRadius, transform: nil)

            let color: NSColor = read.isContaminant
                ? FASTQPalette.trimmed.withAlphaComponent(0.3)
                : FASTQPalette.readFill.withAlphaComponent(0.5)
            ctx.addPath(readPath)
            ctx.setFillColor(color.cgColor)
            ctx.fillPath()

            if read.isContaminant {
                // Contaminant label
                let contAttrs: [NSAttributedString.Key: Any] = [
                    .font: NSFont.systemFont(ofSize: 9),
                    .foregroundColor: FASTQPalette.trimmed,
                ]
                NSAttributedString(string: read.label, attributes: contAttrs)
                    .draw(at: CGPoint(x: readRect.minX + 4, y: readRect.minY + 4))
            }

            drawBadge(ctx: ctx, x: readRect.maxX + 8, y: y + 3,
                      text: read.isContaminant ? "FAIL" : "PASS",
                      color: read.isContaminant ? FASTQPalette.trimmed : FASTQPalette.kept)

            y += readHeight + readSpacing
        }
    }

    // MARK: - Paired-End Merge Preview

    private func drawPairedEndMergePreview(ctx: CGContext, rect: CGRect) {
        let summaryAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12, weight: .medium),
            .foregroundColor: FASTQPalette.summaryText,
        ]
        let summary = NSAttributedString(
            string: "Paired-End Merge: overlapping R1 + R2 → merged read",
            attributes: summaryAttrs
        )
        summary.draw(at: CGPoint(x: rect.midX - summary.size().width / 2, y: rect.minY))

        let readWidth = rect.width * 0.6
        let overlapWidth = readWidth * 0.2
        let startX = rect.minX + 20
        let r1Y = rect.minY + 40
        let r2Y = r1Y + readHeight + 8
        let mergedY = r2Y + readHeight + 24

        // R1
        let r1Rect = CGRect(x: startX, y: r1Y, width: readWidth, height: readHeight)
        ctx.setFillColor(FASTQPalette.readFill.withAlphaComponent(0.5).cgColor)
        ctx.fill(r1Rect)

        // R2 (shifted right, overlapping)
        let r2Rect = CGRect(x: startX + readWidth - overlapWidth, y: r2Y, width: readWidth, height: readHeight)
        ctx.setFillColor(FASTQPalette.pairedRead.withAlphaComponent(0.5).cgColor)
        ctx.fill(r2Rect)

        // Overlap highlight
        let overlapRect = CGRect(x: r2Rect.minX, y: r1Y, width: overlapWidth, height: r2Y + readHeight - r1Y)
        ctx.setFillColor(FASTQPalette.kept.withAlphaComponent(0.15).cgColor)
        ctx.fill(overlapRect)

        // Labels
        let labelAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 9, weight: .bold),
            .foregroundColor: FASTQPalette.secondaryText,
        ]
        NSAttributedString(string: "R1", attributes: labelAttrs).draw(at: CGPoint(x: r1Rect.minX + 3, y: r1Y + 3))
        NSAttributedString(string: "R2", attributes: labelAttrs).draw(at: CGPoint(x: r2Rect.minX + 3, y: r2Y + 3))

        // Arrow
        let arrowY = r2Y + readHeight + 8
        ctx.setStrokeColor(FASTQPalette.secondaryText.cgColor)
        ctx.setLineWidth(1)
        ctx.move(to: CGPoint(x: rect.midX, y: arrowY))
        ctx.addLine(to: CGPoint(x: rect.midX, y: mergedY - 4))
        ctx.strokePath()

        // Merged read
        let mergedWidth = r2Rect.maxX - startX
        let mergedRect = CGRect(x: startX, y: mergedY, width: mergedWidth, height: readHeight)
        ctx.setFillColor(FASTQPalette.kept.withAlphaComponent(0.5).cgColor)
        ctx.fill(mergedRect)

        NSAttributedString(string: "Merged", attributes: labelAttrs).draw(at: CGPoint(x: mergedRect.minX + 3, y: mergedY + 3))
    }

    // MARK: - Paired-End Repair Preview

    private func drawPairedEndRepairPreview(ctx: CGContext, rect: CGRect) {
        let summaryAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12, weight: .medium),
            .foregroundColor: FASTQPalette.summaryText,
        ]
        let summary = NSAttributedString(
            string: "Paired-End Repair: re-synchronize orphaned reads",
            attributes: summaryAttrs
        )
        summary.draw(at: CGPoint(x: rect.midX - summary.size().width / 2, y: rect.minY))

        let readWidth = rect.width * 0.35
        let readAreaTop = rect.minY + 32
        let pairs = [("Read A/1", "Read A/2", true), ("Read B/1", "(orphan)", false), ("Read C/1", "Read C/2", true)]

        for (i, pair) in pairs.enumerated() {
            let y = readAreaTop + CGFloat(i) * (readHeight + readSpacing)
            guard y + readHeight <= rect.maxY else { break }

            let r1Rect = CGRect(x: rect.minX, y: y, width: readWidth, height: readHeight)
            ctx.setFillColor(FASTQPalette.readFill.withAlphaComponent(0.5).cgColor)
            ctx.fill(r1Rect)

            let r2Rect = CGRect(x: rect.minX + readWidth + 20, y: y, width: readWidth, height: readHeight)
            ctx.setFillColor(pair.2 ? FASTQPalette.pairedRead.withAlphaComponent(0.5).cgColor : FASTQPalette.adapter.withAlphaComponent(0.3).cgColor)
            ctx.fill(r2Rect)

            let labelAttrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.monospacedSystemFont(ofSize: 9, weight: .regular),
                .foregroundColor: FASTQPalette.secondaryText,
            ]
            NSAttributedString(string: pair.0, attributes: labelAttrs).draw(at: CGPoint(x: r1Rect.minX + 3, y: y + 3))
            NSAttributedString(string: pair.1, attributes: labelAttrs).draw(at: CGPoint(x: r2Rect.minX + 3, y: y + 3))

            drawBadge(ctx: ctx, x: r2Rect.maxX + 8, y: y + 3,
                      text: pair.2 ? "PAIRED" : "ORPHAN",
                      color: pair.2 ? FASTQPalette.kept : FASTQPalette.adapter)
        }
    }

    // MARK: - Primer Removal Preview

    private func drawPrimerRemovalPreview(ctx: CGContext, rect: CGRect) {
        let readLength = 100
        let primerLength = 20
        let readWidth = rect.width - 40
        let readY = rect.midY - 20
        let startX = rect.minX + 20

        let summaryAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12, weight: .medium),
            .foregroundColor: FASTQPalette.summaryText,
        ]
        let summary = NSAttributedString(
            string: "Primer Removal: \(primerLength) bp primer at 5' end",
            attributes: summaryAttrs
        )
        summary.draw(at: CGPoint(x: rect.midX - summary.size().width / 2, y: rect.minY))

        let primerWidth = readWidth * CGFloat(primerLength) / CGFloat(readLength)
        let genomicWidth = readWidth - primerWidth

        // Primer region
        let primerRect = CGRect(x: startX, y: readY, width: primerWidth, height: readHeight)
        ctx.setFillColor(FASTQPalette.adapter.withAlphaComponent(0.5).cgColor)
        ctx.fill(primerRect)

        // Genomic region
        let genomicRect = CGRect(x: startX + primerWidth, y: readY, width: genomicWidth, height: readHeight)
        ctx.setFillColor(FASTQPalette.readFill.withAlphaComponent(0.3).cgColor)
        ctx.fill(genomicRect)

        let primerLabel: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 10, weight: .semibold),
            .foregroundColor: FASTQPalette.adapter,
        ]
        NSAttributedString(string: "Primer", attributes: primerLabel)
            .draw(at: CGPoint(x: primerRect.midX - 16, y: primerRect.minY - 14))

        drawBracket(ctx: ctx, x: startX + primerWidth, width: genomicWidth,
                    y: readY + readHeight + 8, label: "Kept: \(readLength - primerLength) bp", color: FASTQPalette.kept)
        drawBracket(ctx: ctx, x: startX, width: primerWidth,
                    y: readY + readHeight + 8, label: "Removed: \(primerLength) bp", color: FASTQPalette.trimmed)
    }

    // MARK: - Search Preview

    private func drawSearchPreview(ctx: CGContext, rect: CGRect) {
        let isMotif = operationKind == .searchMotif
        let pattern = parameters.searchPattern

        // Title
        let titleAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12, weight: .medium),
            .foregroundColor: FASTQPalette.summaryText,
        ]
        let title = isMotif ? "Find reads containing a sequence motif" : "Find reads by ID or description"
        let titleStr = NSAttributedString(string: title, attributes: titleAttrs)
        titleStr.draw(at: CGPoint(x: rect.midX - titleStr.size().width / 2, y: rect.minY))

        // Show pattern being searched
        if !pattern.isEmpty {
            let patternAttrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.monospacedSystemFont(ofSize: 10, weight: .semibold),
                .foregroundColor: FASTQPalette.readFill,
            ]
            let label = isMotif ? "Motif: \(pattern.uppercased())" : "Pattern: \"\(pattern)\""
            let patternStr = NSAttributedString(string: label, attributes: patternAttrs)
            patternStr.draw(at: CGPoint(x: rect.maxX - patternStr.size().width - 4, y: rect.minY + 2))
        }

        if isMotif {
            drawMotifSearchPreview(ctx: ctx, rect: rect)
        } else {
            drawTextSearchPreview(ctx: ctx, rect: rect)
        }
    }

    private func drawMotifSearchPreview(ctx: CGContext, rect: CGRect) {
        let motif = parameters.searchPattern.uppercased()
        let monoFont = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        let charWidth: CGFloat = 8.5
        let seqY = rect.minY + 28
        let rowH: CGFloat = 26

        // Example sequences with realistic content
        let sequences: [(seq: String, id: String)] = [
            ("ATCGATCGATGCATGNTACGATCG", "@SRR.1"),
            ("GCTAAGCTTAGCAATCGATCGAT", "@SRR.2"),
            ("TACCGANCTGCATGGATCGATCC", "@SRR.3"),
            ("AATTCCGGAATTCCGGAATTCCG", "@SRR.4"),
        ]

        // If no motif entered, show placeholder
        if motif.isEmpty {
            let hintAttrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 12),
                .foregroundColor: FASTQPalette.dimText,
            ]
            let hint = NSAttributedString(string: "Enter a DNA motif (e.g. ATGCNNNT) to preview matches", attributes: hintAttrs)
            hint.draw(at: CGPoint(x: rect.midX - hint.size().width / 2, y: rect.midY - 8))
            return
        }

        for (i, entry) in sequences.enumerated() {
            let y = seqY + CGFloat(i) * rowH
            guard y + readHeight <= rect.maxY else { return }

            // Find motif in sequence using IUPAC matching (forward + reverse complement)
            var matchRange = findIUPACMatch(in: entry.seq.uppercased(), motif: motif)
            var isRevComp = false
            if matchRange == nil && parameters.reverseComplement {
                matchRange = findIUPACMatch(in: entry.seq.uppercased(), motif: reverseComplement(of: motif))
                if matchRange != nil { isRevComp = true }
            }

            // ID label
            let idAttrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.monospacedSystemFont(ofSize: 9, weight: .regular),
                .foregroundColor: matchRange != nil ? FASTQPalette.secondaryText : FASTQPalette.dimText,
            ]
            NSAttributedString(string: entry.id, attributes: idAttrs)
                .draw(at: CGPoint(x: rect.minX, y: y + 1))

            let seqX = rect.minX + 52

            // Background for sequence
            let seqRect = CGRect(x: seqX, y: y, width: CGFloat(entry.seq.count) * charWidth + 4, height: readHeight)
            let bgColor: NSColor = matchRange != nil
                ? FASTQPalette.readFill.withAlphaComponent(0.08)
                : FASTQPalette.dimText.withAlphaComponent(0.06)
            let bgPath = CGPath(roundedRect: seqRect, cornerWidth: readCornerRadius, cornerHeight: readCornerRadius, transform: nil)
            ctx.setFillColor(bgColor.cgColor)
            ctx.addPath(bgPath)
            ctx.fillPath()

            // Highlight motif region
            if let range = matchRange {
                let hlRect = CGRect(
                    x: seqX + 2 + CGFloat(range.lowerBound) * charWidth,
                    y: y + 2,
                    width: CGFloat(range.count) * charWidth,
                    height: readHeight - 4
                )
                let hlPath = CGPath(roundedRect: hlRect, cornerWidth: 2, cornerHeight: 2, transform: nil)
                ctx.setFillColor(FASTQPalette.readFill.withAlphaComponent(0.25).cgColor)
                ctx.addPath(hlPath)
                ctx.fillPath()
                ctx.setStrokeColor(FASTQPalette.readFill.withAlphaComponent(0.6).cgColor)
                ctx.setLineWidth(1)
                ctx.addPath(hlPath)
                ctx.strokePath()
            }

            // Draw bases
            for (j, char) in entry.seq.enumerated() {
                let baseColor = FASTQPalette.dnaBaseColor(char)
                let isHighlighted = matchRange?.contains(j) ?? false
                let attrs: [NSAttributedString.Key: Any] = [
                    .font: monoFont,
                    .foregroundColor: isHighlighted ? baseColor : baseColor.withAlphaComponent(0.4),
                ]
                NSAttributedString(string: String(char), attributes: attrs)
                    .draw(at: CGPoint(x: seqX + 2 + CGFloat(j) * charWidth, y: y + 3))
            }

            // Match badge
            if matchRange != nil {
                let badgeText = isRevComp ? "RC" : "MATCH"
                drawBadge(ctx: ctx, x: seqRect.maxX + 6, y: y + 3,
                          text: badgeText, color: FASTQPalette.readFill)
            }
        }
    }

    /// Returns the reverse complement of a DNA sequence (supports IUPAC).
    private func reverseComplement(of seq: String) -> String {
        let complements: [Character: Character] = [
            "A": "T", "T": "A", "G": "C", "C": "G", "U": "A",
            "R": "Y", "Y": "R", "S": "S", "W": "W",
            "K": "M", "M": "K", "B": "V", "V": "B",
            "D": "H", "H": "D", "N": "N",
        ]
        return String(seq.reversed().map { complements[$0] ?? $0 })
    }

    /// Simple IUPAC-aware motif matcher for preview display.
    private func findIUPACMatch(in sequence: String, motif: String) -> Range<Int>? {
        let seqChars = Array(sequence)
        let motifChars = Array(motif)
        guard motifChars.count <= seqChars.count, !motifChars.isEmpty else { return nil }

        outer: for start in 0...(seqChars.count - motifChars.count) {
            for (offset, mc) in motifChars.enumerated() {
                if !iupacMatches(mc, seqChars[start + offset]) {
                    continue outer
                }
            }
            return start..<(start + motifChars.count)
        }
        return nil
    }

    /// Returns true if an IUPAC code matches a concrete base.
    private func iupacMatches(_ code: Character, _ base: Character) -> Bool {
        let b = base.uppercased().first ?? "?"
        switch code.uppercased().first ?? "?" {
        case "A": return b == "A"
        case "T", "U": return b == "T" || b == "U"
        case "G": return b == "G"
        case "C": return b == "C"
        case "R": return b == "A" || b == "G"
        case "Y": return b == "C" || b == "T"
        case "S": return b == "G" || b == "C"
        case "W": return b == "A" || b == "T"
        case "K": return b == "G" || b == "T"
        case "M": return b == "A" || b == "C"
        case "B": return b == "C" || b == "G" || b == "T"
        case "D": return b == "A" || b == "G" || b == "T"
        case "H": return b == "A" || b == "C" || b == "T"
        case "V": return b == "A" || b == "C" || b == "G"
        case "N": return true
        case ".": return true
        default: return false
        }
    }

    private func drawTextSearchPreview(ctx: CGContext, rect: CGRect) {
        let pattern = parameters.searchPattern
        let searchField = parameters.searchField

        // Example reads for preview
        let reads: [(id: String, desc: String)] = [
            ("@SRR1770413.1", "length=151 paired"),
            ("@SRR1770413.2", "length=151 paired"),
            ("@SRR1770413.3", "length=102 single"),
            ("@SRR1770413.4", "length=151 paired"),
            ("@SRR1770413.5", "length=98 single"),
        ]

        // If no pattern entered, show placeholder
        if pattern.isEmpty {
            let hintAttrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 12),
                .foregroundColor: FASTQPalette.dimText,
            ]
            let hint = NSAttributedString(
                string: "Enter a search pattern to filter reads by \(searchField.lowercased())",
                attributes: hintAttrs
            )
            hint.draw(at: CGPoint(x: rect.midX - hint.size().width / 2, y: rect.midY - 8))
            return
        }

        var y = rect.minY + 28
        let readWidth = rect.width - 64

        for read in reads {
            guard y + readHeight <= rect.maxY else { return }

            // Match against the selected field
            let matchTarget = searchField == "Description" ? read.desc : read.id
            let matched: Bool
            if parameters.searchRegex {
                matched = (try? NSRegularExpression(pattern: pattern, options: .caseInsensitive)
                    .firstMatch(in: matchTarget, range: NSRange(matchTarget.startIndex..., in: matchTarget))) != nil
            } else {
                matched = matchTarget.localizedCaseInsensitiveContains(pattern)
            }

            let readRect = CGRect(x: rect.minX, y: y, width: readWidth, height: readHeight)
            let bgColor: NSColor = matched
                ? FASTQPalette.readFill.withAlphaComponent(0.12)
                : FASTQPalette.dimText.withAlphaComponent(0.06)
            let path = CGPath(roundedRect: readRect, cornerWidth: readCornerRadius, cornerHeight: readCornerRadius, transform: nil)
            ctx.setFillColor(bgColor.cgColor)
            ctx.addPath(path)
            ctx.fillPath()

            // ID
            let idAttrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.monospacedSystemFont(ofSize: 10, weight: .medium),
                .foregroundColor: matched ? FASTQPalette.summaryText : FASTQPalette.dimText,
            ]
            NSAttributedString(string: read.id, attributes: idAttrs)
                .draw(at: CGPoint(x: readRect.minX + 6, y: readRect.minY + 3))

            // Description
            let descX = readRect.minX + 130
            let descAttrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.monospacedSystemFont(ofSize: 10, weight: .regular),
                .foregroundColor: matched ? FASTQPalette.secondaryText : FASTQPalette.dimText,
            ]
            NSAttributedString(string: read.desc, attributes: descAttrs)
                .draw(at: CGPoint(x: descX, y: readRect.minY + 3))

            if matched {
                drawBadge(ctx: ctx, x: readRect.maxX + 6, y: y + 3,
                          text: "MATCH", color: FASTQPalette.readFill)
            }

            y += readHeight + readSpacing
        }
    }


    // MARK: - Quality Report Preview

    private func drawQualityReportPreview(ctx: CGContext, rect: CGRect) {
        // Draw a schematic showing quality analysis output: bar chart icon + description
        let centerX = rect.midX
        let centerY = rect.midY

        // Draw a stylized bar chart icon
        let barWidth: CGFloat = 8
        let barSpacing: CGFloat = 4
        let barHeights: [CGFloat] = [0.3, 0.6, 0.9, 0.7, 0.5, 0.8, 0.4, 0.65, 0.85, 0.55]
        let maxBarHeight: CGFloat = 60
        let totalWidth = CGFloat(barHeights.count) * (barWidth + barSpacing) - barSpacing
        let startX = centerX - totalWidth / 2
        let baseY = centerY + 20

        for (i, h) in barHeights.enumerated() {
            let x = startX + CGFloat(i) * (barWidth + barSpacing)
            let height = h * maxBarHeight
            let barRect = CGRect(x: x, y: baseY - height, width: barWidth, height: height)

            // Color by quality tier
            let color: NSColor
            if h >= 0.8 { color = FASTQPalette.qualityHigh }
            else if h >= 0.6 { color = FASTQPalette.qualityMedium }
            else if h >= 0.4 { color = FASTQPalette.qualityLow }
            else { color = FASTQPalette.qualityVeryLow }

            ctx.setFillColor(color.withAlphaComponent(0.7).cgColor)
            ctx.fill(barRect)
            ctx.setStrokeColor(color.cgColor)
            ctx.setLineWidth(0.5)
            ctx.stroke(barRect)
        }

        // Title above
        let titleAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 13, weight: .medium),
            .foregroundColor: FASTQPalette.summaryText,
        ]
        let title = NSAttributedString(string: "Quality Report", attributes: titleAttrs)
        let titleSize = title.size()
        title.draw(at: CGPoint(x: centerX - titleSize.width / 2, y: baseY - maxBarHeight - 30))

        // Subtitle below
        let subtitleAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11),
            .foregroundColor: FASTQPalette.secondaryText,
        ]
        let subtitle = NSAttributedString(
            string: "Per-position quality, length distribution, Q score histogram",
            attributes: subtitleAttrs
        )
        let subSize = subtitle.size()
        subtitle.draw(at: CGPoint(x: centerX - subSize.width / 2, y: baseY + 10))
    }

    // MARK: - Drawing Helpers

    private func drawBadge(ctx: CGContext, x: CGFloat, y: CGFloat,
                           text: String, color: NSColor) {
        guard !text.isEmpty else { return }
        let badgeAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 9, weight: .semibold),
            .foregroundColor: color,
        ]
        let badgeStr = NSAttributedString(string: text, attributes: badgeAttrs)
        let badgeSize = badgeStr.size()
        let badgeRect = CGRect(x: x, y: y, width: badgeSize.width + 8, height: 14)

        // Badge background
        let badgePath = CGPath(roundedRect: badgeRect, cornerWidth: 3, cornerHeight: 3, transform: nil)
        ctx.addPath(badgePath)
        ctx.setFillColor(color.withAlphaComponent(0.15).cgColor)
        ctx.fillPath()

        badgeStr.draw(at: CGPoint(x: x + 4, y: y))
    }

    private func drawBracket(ctx: CGContext, x: CGFloat, width: CGFloat,
                             y: CGFloat, label: String, color: NSColor) {
        ctx.setStrokeColor(color.cgColor)
        ctx.setLineWidth(1)

        // Bracket shape
        ctx.move(to: CGPoint(x: x, y: y))
        ctx.addLine(to: CGPoint(x: x, y: y + 4))
        ctx.move(to: CGPoint(x: x, y: y + 2))
        ctx.addLine(to: CGPoint(x: x + width, y: y + 2))
        ctx.move(to: CGPoint(x: x + width, y: y))
        ctx.addLine(to: CGPoint(x: x + width, y: y + 4))
        ctx.strokePath()

        // Label
        let labelAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 10),
            .foregroundColor: color,
        ]
        let labelStr = NSAttributedString(string: label, attributes: labelAttrs)
        let labelSize = labelStr.size()
        labelStr.draw(at: CGPoint(x: x + width / 2 - labelSize.width / 2, y: y + 6))
    }

    private func drawThresholdLine(ctx: CGContext, x: CGFloat, rect: CGRect,
                                   label: String, color: NSColor) {
        ctx.setStrokeColor(color.cgColor)
        ctx.setLineWidth(1)
        ctx.setLineDash(phase: 0, lengths: [4, 3])
        ctx.move(to: CGPoint(x: x, y: rect.minY + 20))
        ctx.addLine(to: CGPoint(x: x, y: rect.maxY))
        ctx.strokePath()
        ctx.setLineDash(phase: 0, lengths: [])

        let labelAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 10),
            .foregroundColor: color,
        ]
        NSAttributedString(string: label, attributes: labelAttrs)
            .draw(at: CGPoint(x: x + 4, y: rect.minY + 20))
    }

    // MARK: - Demultiplex Preview

    private func drawDemultiplexPreview(ctx: CGContext, rect: CGRect) {
        // Title
        let titleAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12, weight: .medium),
            .foregroundColor: FASTQPalette.summaryText,
        ]
        let titleStr = NSAttributedString(string: "Split reads by internal barcode signatures", attributes: titleAttrs)
        titleStr.draw(at: CGPoint(x: rect.midX - titleStr.size().width / 2, y: rect.minY))

        // Input reads (left side)
        let inputX = rect.minX + 8
        let outputX = rect.midX + 40
        let readY = rect.minY + 28
        let rowH: CGFloat = 16
        let readW = rect.midX - 30

        let barcodeColors: [NSColor] = [
            .systemBlue, .systemGreen, .systemOrange, .systemPurple, .systemRed
        ]
        let barcodeLabels = ["D701", "D702", "D703", "D701", "D702", "unassigned", "D703", "D701"]

        // Draw input reads with embedded barcode regions
        let inputLabel = NSAttributedString(string: "Input FASTQ", attributes: [
            .font: NSFont.systemFont(ofSize: 9, weight: .semibold),
            .foregroundColor: FASTQPalette.secondaryText,
        ])
        inputLabel.draw(at: CGPoint(x: inputX, y: readY - 14))

        for (i, bc) in barcodeLabels.prefix(6).enumerated() {
            let y = readY + CGFloat(i) * rowH
            guard y + readHeight <= rect.maxY - 10 else { break }

            let isUnassigned = bc == "unassigned"
            let bcIndex = ["D701", "D702", "D703"].firstIndex(of: bc) ?? -1
            let color = isUnassigned ? FASTQPalette.dimText : barcodeColors[bcIndex]

            // Read body
            ctx.setFillColor(FASTQPalette.readFill.withAlphaComponent(0.15).cgColor)
            let readRect = CGRect(x: inputX, y: y, width: readW, height: readHeight)
            ctx.fill(readRect)

            // Barcode region (small colored segment)
            let bcWidth: CGFloat = 28
            let bcX = inputX + readW * 0.15
            ctx.setFillColor(color.withAlphaComponent(isUnassigned ? 0.2 : 0.5).cgColor)
            ctx.fill(CGRect(x: bcX, y: y, width: bcWidth, height: readHeight))

            // Barcode label
            let bcAttrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.monospacedSystemFont(ofSize: 7, weight: .medium),
                .foregroundColor: isUnassigned ? FASTQPalette.dimText : color,
            ]
            NSAttributedString(string: bc, attributes: bcAttrs)
                .draw(at: CGPoint(x: bcX + bcWidth + 2, y: y + 1))
        }

        // Arrow
        let arrowY = readY + 2 * rowH
        ctx.setStrokeColor(FASTQPalette.secondaryText.cgColor)
        ctx.setLineWidth(1.5)
        let arrowStartX = inputX + readW + 4
        let arrowEndX = outputX - 4
        ctx.move(to: CGPoint(x: arrowStartX, y: arrowY + readHeight / 2))
        ctx.addLine(to: CGPoint(x: arrowEndX, y: arrowY + readHeight / 2))
        ctx.addLine(to: CGPoint(x: arrowEndX - 6, y: arrowY + readHeight / 2 - 4))
        ctx.move(to: CGPoint(x: arrowEndX, y: arrowY + readHeight / 2))
        ctx.addLine(to: CGPoint(x: arrowEndX - 6, y: arrowY + readHeight / 2 + 4))
        ctx.strokePath()

        // Output bundles (right side)
        let outputLabel = NSAttributedString(string: "Per-Barcode Bundles", attributes: [
            .font: NSFont.systemFont(ofSize: 9, weight: .semibold),
            .foregroundColor: FASTQPalette.secondaryText,
        ])
        outputLabel.draw(at: CGPoint(x: outputX, y: readY - 14))

        let outputBarcodes = ["D701", "D702", "D703"]
        let bundleW = rect.maxX - outputX - 8
        for (i, bc) in outputBarcodes.enumerated() {
            let y = readY + CGFloat(i) * (rowH * 1.6)
            guard y + readHeight + 4 <= rect.maxY else { break }

            let color = barcodeColors[i]

            // Bundle box
            ctx.setFillColor(color.withAlphaComponent(0.1).cgColor)
            let bundleRect = CGRect(x: outputX, y: y, width: bundleW, height: readHeight + 4)
            let bundlePath = CGPath(roundedRect: bundleRect, cornerWidth: 3, cornerHeight: 3, transform: nil)
            ctx.addPath(bundlePath)
            ctx.fillPath()
            ctx.setStrokeColor(color.withAlphaComponent(0.4).cgColor)
            ctx.setLineWidth(1)
            ctx.addPath(bundlePath)
            ctx.strokePath()

            // Bundle label
            let bundleAttrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.monospacedSystemFont(ofSize: 10, weight: .semibold),
                .foregroundColor: color,
            ]
            NSAttributedString(string: "\(bc).lungfishfastq", attributes: bundleAttrs)
                .draw(at: CGPoint(x: outputX + 6, y: y + 2))
        }
    }

    private func drawHatch(ctx: CGContext, rect: CGRect) {
        ctx.saveGState()
        ctx.clip(to: rect)
        ctx.setStrokeColor(FASTQPalette.trimmed.withAlphaComponent(0.3).cgColor)
        ctx.setLineWidth(0.5)
        let spacing: CGFloat = 4
        for offset in stride(from: -rect.height, through: rect.width + rect.height, by: spacing) {
            ctx.move(to: CGPoint(x: rect.minX + offset, y: rect.maxY))
            ctx.addLine(to: CGPoint(x: rect.minX + offset + rect.height, y: rect.minY))
        }
        ctx.strokePath()
        ctx.restoreGState()
    }
}
