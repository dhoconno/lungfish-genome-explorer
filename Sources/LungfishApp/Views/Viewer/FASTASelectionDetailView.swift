// FASTASelectionDetailView.swift - Read-only selected FASTA record viewer
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import LungfishCore
import LungfishKit

@MainActor
final class FASTASelectionDetailView: NSView {
    private let scrollView = NSScrollView(frame: .zero)
    private let textView = NSTextView(frame: .zero)
    private let sequenceFontBaseline = NSFont.monospacedSystemFont(
        ofSize: NSFont.smallSystemFontSize,
        weight: .regular
    )
    private var contentTypographyObservation: ContentTypographyViewObservation?

    var text: String {
        textView.string
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        configureView()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        configureView()
    }

    func setSequences(_ sequences: [Sequence]) {
        let newText = FASTASelectionDetailFormatter.text(for: sequences)
        guard textView.string != newText else { return }
        textView.string = newText
        textView.setSelectedRange(NSRange(location: 0, length: 0))
        scrollView.contentView.scroll(to: .zero)
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }

    private func configureView() {
        setAccessibilityElement(true)
        setAccessibilityIdentifier("fasta-selection-detail")
        setAccessibilityLabel("Selected FASTA sequences")

        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = false
        textView.allowsUndo = false
        textView.usesFindPanel = true
        textView.textColor = .textColor
        textView.backgroundColor = .textBackgroundColor
        textView.textContainerInset = NSSize(width: 10, height: 8)
        textView.minSize = .zero
        textView.maxSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = true
        textView.autoresizingMask = []
        textView.textContainer?.containerSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.textContainer?.widthTracksTextView = false
        textView.textContainer?.heightTracksTextView = false
        textView.setAccessibilityIdentifier("fasta-selection-text")
        textView.setAccessibilityLabel("Selected FASTA records")
        textView.font = resolvedSequenceFont()

        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.documentView = textView
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scrollView)

        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])

        contentTypographyObservation = ContentTypographyViewObservation(
            applicator: ContentTypographyViewApplicator(excludedSubtree: { _ in true }),
            rootProvider: { [weak self] in self },
            afterApply: { [weak self] in self?.applyContentTypography() }
        )
    }

    private func applyContentTypography() {
        let resolvedFont = resolvedSequenceFont()
        guard !hasSameFontSignature(textView.font, resolvedFont) else { return }
        let selectedRange = textView.selectedRange()
        let scrollOrigin = scrollView.contentView.bounds.origin
        textView.font = resolvedFont
        textView.setSelectedRange(selectedRange)
        scrollView.contentView.setBoundsOrigin(scrollOrigin)
        scrollView.reflectScrolledClipView(scrollView.contentView)
        needsLayout = true
    }

    private func resolvedSequenceFont() -> NSFont {
        let bodyFont = ContentTypography.current().font(for: .body)
        let scale = bodyFont.pointSize / max(NSFont.systemFontSize, 1)
        let pointSize = max(
            ContentTypography.minimumPointSize,
            sequenceFontBaseline.pointSize * scale
        )
        return NSFont(
            descriptor: sequenceFontBaseline.fontDescriptor,
            size: pointSize
        ) ?? sequenceFontBaseline
    }

    private func hasSameFontSignature(_ lhs: NSFont?, _ rhs: NSFont) -> Bool {
        guard let lhs else { return false }
        return lhs.fontName == rhs.fontName
            && abs(lhs.pointSize - rhs.pointSize) < 0.001
            && lhs.fontDescriptor.symbolicTraits == rhs.fontDescriptor.symbolicTraits
    }
}
