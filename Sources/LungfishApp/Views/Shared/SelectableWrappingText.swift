// SelectableWrappingText.swift - AppKit-backed selectable text for SwiftUI layouts
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import SwiftUI

@MainActor
struct SelectableWrappingText: NSViewRepresentable {
    var text: String
    var font: NSFont
    var textColor: NSColor
    var maximumNumberOfLines: Int?
    var lineBreakMode: NSLineBreakMode
    var accessibilityIdentifier: String?

    init(
        _ text: String,
        font: NSFont = .systemFont(ofSize: NSFont.smallSystemFontSize),
        textColor: NSColor = .labelColor,
        maximumNumberOfLines: Int? = nil,
        lineBreakMode: NSLineBreakMode = .byWordWrapping,
        accessibilityIdentifier: String? = nil
    ) {
        self.text = text
        self.font = font
        self.textColor = textColor
        self.maximumNumberOfLines = maximumNumberOfLines
        self.lineBreakMode = lineBreakMode
        self.accessibilityIdentifier = accessibilityIdentifier
    }

    func makeNSView(context: Context) -> IntrinsicTextView {
        let textView = IntrinsicTextView()
        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.isRichText = false
        textView.importsGraphics = false
        textView.textContainerInset = .zero
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.heightTracksTextView = false
        textView.isHorizontallyResizable = false
        textView.isVerticallyResizable = true
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        textView.setContentCompressionResistancePriority(.required, for: .vertical)
        textView.setContentHuggingPriority(.defaultLow, for: .horizontal)
        textView.setContentHuggingPriority(.required, for: .vertical)
        updateNSView(textView, context: context)
        return textView
    }

    func updateNSView(_ nsView: IntrinsicTextView, context: Context) {
        var needsIntrinsicInvalidation = false
        if nsView.string != text {
            nsView.string = text
            needsIntrinsicInvalidation = true
        }
        if nsView.font != font {
            nsView.font = font
            needsIntrinsicInvalidation = true
        }
        if nsView.textColor != textColor {
            nsView.textColor = textColor
        }
        let maximumLines = maximumNumberOfLines ?? 0
        if nsView.textContainer?.maximumNumberOfLines != maximumLines {
            nsView.textContainer?.maximumNumberOfLines = maximumLines
            needsIntrinsicInvalidation = true
        }
        if nsView.textContainer?.lineBreakMode != lineBreakMode {
            nsView.textContainer?.lineBreakMode = lineBreakMode
            needsIntrinsicInvalidation = true
        }
        nsView.setAccessibilityIdentifier(accessibilityIdentifier)
        if needsIntrinsicInvalidation {
            nsView.invalidateIntrinsicContentSize()
        }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: IntrinsicTextView, context: Context) -> CGSize? {
        nsView.fittingSize(forProposedWidth: proposal.width)
    }
}

@MainActor
final class IntrinsicTextView: NSTextView {
    private var lastIntrinsicLayoutWidth: CGFloat = -1

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: fittingHeight(for: bounds.width))
    }

    override func layout() {
        super.layout()
        // Text wraps at the width the view has, whatever widths SwiftUI measured it at.
        wrap(atWidth: bounds.width)
        let roundedWidth = bounds.width.rounded(.toNearestOrAwayFromZero)
        if abs(roundedWidth - lastIntrinsicLayoutWidth) > 0.5 {
            lastIntrinsicLayoutWidth = roundedWidth
            invalidateIntrinsicContentSize()
        }
    }

    /// The size SwiftUI should give the view for a proposed width.
    ///
    /// SwiftUI also asks with no width and with an infinite one, to learn how flexible the view is.
    /// Neither has a width to wrap at, so both mean the width the view has now. A zero or negative
    /// width, or no width yet, has no size to answer.
    func fittingSize(forProposedWidth proposed: CGFloat?) -> CGSize? {
        let width = proposed.flatMap { $0.isFinite ? $0 : nil } ?? bounds.width
        guard width > 0 else { return nil }
        return CGSize(width: width, height: fittingHeight(for: width))
    }

    /// The height the text needs at `width`. Measuring leaves the text wrapped at the width the view has.
    func fittingHeight(for width: CGFloat) -> CGFloat {
        guard let layoutManager, let textContainer else { return 0 }
        guard width > 0 else { return ceil(font?.lineHeight ?? 0) }
        wrap(atWidth: width)
        layoutManager.ensureLayout(for: textContainer)
        let height = ceil(layoutManager.usedRect(for: textContainer).height)
        wrap(atWidth: bounds.width)
        return height
    }

    /// Wraps the text at `width`, which a view that has no width yet leaves as it is.
    private func wrap(atWidth width: CGFloat) {
        guard let textContainer, width > 0 else { return }
        let size = NSSize(width: width, height: CGFloat.greatestFiniteMagnitude)
        if textContainer.containerSize != size {
            textContainer.containerSize = size
        }
    }
}

private extension NSFont {
    var lineHeight: CGFloat {
        ascender - descender + leading
    }
}
