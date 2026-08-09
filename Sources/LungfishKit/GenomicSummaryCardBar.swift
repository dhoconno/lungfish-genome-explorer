// GenomicSummaryCardBar.swift - Reusable horizontal summary card bar
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import LungfishCore

/// A horizontal strip of statistic cards for dataset overview.
///
/// Subclass and override `cards` to provide domain-specific metrics.
/// The base class handles all rendering: card backgrounds, borders,
/// and full label/value wrapping when cards are narrow.
///
/// Used by:
/// - `FASTQSummaryBar` — read count, quality, GC, N50
/// - `FASTACollectionSummaryBar` — sequence count, annotations, GC
@MainActor
open class GenomicSummaryCardBar: NSView {
    private var preferredFontProvider: any ContentPreferredFontProviding =
        AppKitContentPreferredFontProvider()
    private var contentTypographyToken: NSObjectProtocol?
    private var lastReportedPreferredHeight: CGFloat?
    private var cachedAccessibilitySignature: [String] = []
    private var cachedAccessibilityChildren: [NSAccessibilityElement] = []
    #if DEBUG
    private var testingAccessibilityNotificationPoster:
        ((NSAccessibility.Notification) -> Void)?
    #endif

    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        configureAccessibility()
        startObservingContentTypography()
    }

    public required init?(coder: NSCoder) {
        super.init(coder: coder)
        configureAccessibility()
        startObservingContentTypography()
    }

    isolated deinit {
        if let contentTypographyToken {
            NotificationCenter.default.removeObserver(contentTypographyToken)
        }
    }

    /// A single summary card with a label and formatted value.
    public struct Card {
        public let label: String
        public let value: String

        public init(label: String, value: String) {
            self.label = label
            self.value = value
        }
    }

    /// Override in subclasses to provide the cards to display.
    open var cards: [Card] { [] }

    open override var isFlipped: Bool { true }

    public var preferredContentHeight: CGFloat {
        layoutMetrics(for: bounds.width).height
    }

    public var onPreferredContentHeightChanged: ((CGFloat) -> Void)?

    open override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: preferredContentHeight)
    }

    /// Call after a subclass changes the values or count returned by `cards`.
    ///
    /// This invalidates drawing, accessibility children, and adaptive layout,
    /// including a host's summary-height constraint.
    public func cardsDidChange() {
        needsDisplay = true
        invalidateAccessibilityChildren()
        invalidateIntrinsicContentSize()
        notifyPreferredContentHeightIfNeeded(force: true)
        postAccessibilityChange(.valueChanged)
        postAccessibilityChange(.layoutChanged)
    }

    public func setContentPreferredFontProvider(
        _ provider: any ContentPreferredFontProviding
    ) {
        preferredFontProvider = provider
        applyContentTypography()
    }

    open override func layout() {
        super.layout()
        notifyPreferredContentHeightIfNeeded()
    }

    open override func accessibilityChildren() -> [Any]? {
        let cardData = cards
        let frames = layoutMetrics(for: bounds.width).frames
        let signature = zip(cardData, frames).flatMap { card, frame in
            [
                card.label,
                card.value,
                NSStringFromRect(frame),
            ]
        }
        if signature == cachedAccessibilitySignature {
            return cachedAccessibilityChildren
        }
        cachedAccessibilitySignature = signature
        cachedAccessibilityChildren = zip(cardData, frames).map { card, frame in
            let element = NSAccessibilityElement()
            element.setAccessibilityParent(self)
            element.setAccessibilityRole(.staticText)
            element.setAccessibilityLabel(card.label)
            element.setAccessibilityValue(card.value)
            element.setAccessibilityFrameInParentSpace(frame)
            return element
        }
        return cachedAccessibilityChildren
    }

    open override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }

        let cardData = cards
        guard !cardData.isEmpty else { return }

        let metrics = layoutMetrics(for: bounds.width)
        let fonts = resolvedFonts()

        for (i, card) in cardData.enumerated() {
            let cardRect = metrics.frames[i]

            // Card background
            let bgColor = NSColor.controlBackgroundColor.withAlphaComponent(0.6).cgColor
            ctx.setFillColor(bgColor)
            let path = CGPath(roundedRect: cardRect, cornerWidth: 4, cornerHeight: 4, transform: nil)
            ctx.addPath(path)
            ctx.fillPath()

            // Border
            ctx.setStrokeColor(NSColor.separatorColor.cgColor)
            ctx.setLineWidth(0.5)
            ctx.addPath(path)
            ctx.strokePath()

            // Clip text to card bounds
            ctx.saveGState()
            ctx.clip(to: cardRect.insetBy(dx: 4, dy: 0))

            // Label (top)
            let labelAttrs: [NSAttributedString.Key: Any] = [
                .font: fonts.label,
                .foregroundColor: NSColor.secondaryLabelColor,
            ]
            let cardContentWidth = max(1, cardRect.width - 8)
            let labelStr = NSAttributedString(string: card.label, attributes: labelAttrs)
            let labelRect = labelStr.boundingRect(
                with: NSSize(width: cardContentWidth, height: .greatestFiniteMagnitude),
                options: [.usesLineFragmentOrigin, .usesFontLeading]
            )
            labelStr.draw(
                with: NSRect(
                    x: cardRect.minX + 4,
                    y: cardRect.minY + 4,
                    width: cardContentWidth,
                    height: ceil(labelRect.height)
                ),
                options: [.usesLineFragmentOrigin, .usesFontLeading]
            )

            // Value (below the label), wrapped so long scientific identifiers
            // remain visible instead of clipping at larger content sizes.
            let valueParagraph = valueParagraphStyle()
            let valueAttrs: [NSAttributedString.Key: Any] = [
                .font: fonts.value,
                .foregroundColor: NSColor.labelColor,
                .paragraphStyle: valueParagraph,
            ]
            let valueStr = NSAttributedString(string: card.value, attributes: valueAttrs)
            let valueRect = valueStr.boundingRect(
                with: NSSize(width: cardContentWidth, height: .greatestFiniteMagnitude),
                options: [.usesLineFragmentOrigin, .usesFontLeading]
            )
            valueStr.draw(
                with: NSRect(
                    x: cardRect.minX + 4,
                    y: cardRect.minY + 6 + ceil(labelRect.height),
                    width: cardContentWidth,
                    height: ceil(valueRect.height)
                ),
                options: [.usesLineFragmentOrigin, .usesFontLeading]
            )

            ctx.restoreGState()
        }
    }

    private func startObservingContentTypography() {
        contentTypographyToken = NotificationCenter.default.addObserver(
            forName: .contentTextSizeDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.applyContentTypography()
            }
        }
        applyContentTypography()
    }

    private func applyContentTypography() {
        needsDisplay = true
        invalidateAccessibilityChildren()
        invalidateIntrinsicContentSize()
        notifyPreferredContentHeightIfNeeded(force: true)
        postAccessibilityChange(.layoutChanged)
    }

    private func resolvedFonts() -> (label: NSFont, value: NSFont) {
        let typography = ContentTypography.current(
            preferredFontProvider: preferredFontProvider
        )
        let caption = typography.font(for: .caption)
        let emphasized = typography.font(for: .emphasizedBody)
        return (
            font(caption, applyingWeight: .medium),
            fixedPitchFont(emphasized, applyingWeight: .semibold)
        )
    }

    private func font(_ base: NSFont, applyingWeight weight: NSFont.Weight) -> NSFont {
        var traits = base.fontDescriptor.object(forKey: .traits)
            as? [NSFontDescriptor.TraitKey: Any] ?? [:]
        traits[.weight] = weight
        let descriptor = base.fontDescriptor.addingAttributes([.traits: traits])
        return NSFont(descriptor: descriptor, size: base.pointSize) ?? base
    }

    private func fixedPitchFont(
        _ base: NSFont,
        applyingWeight weight: NSFont.Weight
    ) -> NSFont {
        let designed = base.fontDescriptor.withDesign(.monospaced)
            ?? NSFont.monospacedSystemFont(
                ofSize: base.pointSize,
                weight: weight
            ).fontDescriptor
        var traits = designed.object(forKey: .traits)
            as? [NSFontDescriptor.TraitKey: Any] ?? [:]
        traits[.weight] = weight
        let descriptor = designed.addingAttributes([.traits: traits])
        return NSFont(descriptor: descriptor, size: base.pointSize) ?? base
    }

    private func valueParagraphStyle() -> NSParagraphStyle {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        paragraph.lineBreakMode = .byCharWrapping
        return paragraph
    }

    private func configureAccessibility() {
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Summary Statistics")
    }

    private func invalidateAccessibilityChildren() {
        cachedAccessibilitySignature = []
        cachedAccessibilityChildren = []
    }

    private func postAccessibilityChange(_ notification: NSAccessibility.Notification) {
        NSAccessibility.post(element: self, notification: notification)
        #if DEBUG
        testingAccessibilityNotificationPoster?(notification)
        #endif
    }

    private func layoutMetrics(for width: CGFloat) -> (frames: [NSRect], height: CGFloat, rows: Int) {
        let cardData = cards
        guard !cardData.isEmpty else { return ([], 48, 0) }
        let padding: CGFloat = 8
        let spacing: CGFloat = 6
        let minimumCardWidth: CGFloat = 104
        let availableWidth = max(1, width - padding * 2)
        let columns = max(
            1,
            min(cardData.count, Int(floor((availableWidth + spacing) / (minimumCardWidth + spacing))))
        )
        let rows = Int(ceil(Double(cardData.count) / Double(columns)))
        let cardWidth = max(
            1,
            (availableWidth - spacing * CGFloat(columns - 1)) / CGFloat(columns)
        )
        let fonts = resolvedFonts()
        let labelWidth = max(1, cardWidth - 8)
        let maximumContentHeight = cardData.map { card in
            let labelHeight = ceil((card.label as NSString).boundingRect(
                with: NSSize(width: labelWidth, height: .greatestFiniteMagnitude),
                options: [.usesLineFragmentOrigin, .usesFontLeading],
                attributes: [.font: fonts.label]
            ).height)
            let valueHeight = ceil((card.value as NSString).boundingRect(
                with: NSSize(width: labelWidth, height: .greatestFiniteMagnitude),
                options: [.usesLineFragmentOrigin, .usesFontLeading],
                attributes: [
                    .font: fonts.value,
                    .paragraphStyle: valueParagraphStyle(),
                ]
            ).height)
            return labelHeight + valueHeight
        }.max() ?? (fonts.label.boundingRectForFont.height + fonts.value.boundingRectForFont.height)
        let cardHeight = ceil(maximumContentHeight + 14)
        let height = max(48, padding + CGFloat(rows) * cardHeight + CGFloat(rows - 1) * spacing)
        let frames = cardData.indices.map { index -> NSRect in
            let row = index / columns
            let column = index % columns
            return NSRect(
                x: padding + CGFloat(column) * (cardWidth + spacing),
                y: 4 + CGFloat(row) * (cardHeight + spacing),
                width: cardWidth,
                height: cardHeight
            )
        }
        return (frames, height, rows)
    }

    private func notifyPreferredContentHeightIfNeeded(force: Bool = false) {
        let height = preferredContentHeight
        guard force || lastReportedPreferredHeight != height else { return }
        lastReportedPreferredHeight = height
        onPreferredContentHeightChanged?(height)
    }

    #if DEBUG
    public struct TestingTypographyMetrics: Equatable {
        public let labelPointSize: CGFloat
        public let valuePointSize: CGFloat
        public let preferredHeight: CGFloat
        public let cardRowCount: Int
        public let labelTraits: NSFontDescriptor.SymbolicTraits
        public let valueTraits: NSFontDescriptor.SymbolicTraits
        public let valueIsFixedPitch: Bool
    }

    public var testingTypographyMetrics: TestingTypographyMetrics {
        let fonts = resolvedFonts()
        return TestingTypographyMetrics(
            labelPointSize: fonts.label.pointSize,
            valuePointSize: fonts.value.pointSize,
            preferredHeight: preferredContentHeight,
            cardRowCount: layoutMetrics(for: bounds.width).rows,
            labelTraits: fonts.label.fontDescriptor.symbolicTraits,
            valueTraits: fonts.value.fontDescriptor.symbolicTraits,
            valueIsFixedPitch: fonts.value.isFixedPitch
        )
    }

    public var testingCardFrames: [NSRect] {
        layoutMetrics(for: bounds.width).frames
    }

    public func setTestingAccessibilityNotificationPoster(
        _ poster: @escaping (NSAccessibility.Notification) -> Void
    ) {
        testingAccessibilityNotificationPoster = poster
    }
    #endif

    /// Retained for source compatibility with older summary bars. Rendering
    /// now always wraps and shows the full label.
    open func abbreviatedLabel(for label: String) -> String {
        switch label {
        case "Median Length": return "Med. Len"
        case "Mean Length": return "Mean Len"
        case "Total Reads": return "Reads"
        case "Total Bases": return "Bases"
        case "Mean Quality": return "Mean Q"
        case "Median Quality": return "Med. Q"
        case "Min Length": return "Min Len"
        case "Max Length": return "Max Len"
        case "GC Content": return "GC%"
        case "Mean Q": return "Q"
        case "Sequences": return "Seqs"
        case "Annotations": return "Annot"
        case "Feature Types": return "Types"
        case "Shortest": return "Min"
        case "Longest": return "Max"
        default: return String(label.prefix(8))
        }
    }

    // MARK: - Shared Formatters

    /// Formats a count with K/M/G suffixes.
    public static func formatCount(_ count: Int) -> String {
        LungfishFormatters.formatAbbreviatedCount(count)
    }

    /// Formats a base count with bp/Kb/Mb/Gb suffixes.
    public static func formatBases(_ count: Int64) -> String {
        if count >= 1_000_000_000 { return String(format: "%.2f Gb", Double(count) / 1_000_000_000) }
        if count >= 1_000_000 { return String(format: "%.2f Mb", Double(count) / 1_000_000) }
        if count >= 1_000 { return String(format: "%.1f Kb", Double(count) / 1_000) }
        return "\(count) bp"
    }

    /// Formats a base count from Int with bp/Kb/Mb/Gb suffixes.
    public static func formatBases(_ count: Int) -> String {
        formatBases(Int64(count))
    }
}
