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
        if nsView.string != text {
            nsView.string = text
        }
        nsView.font = font
        nsView.textColor = textColor
        nsView.textContainer?.maximumNumberOfLines = maximumNumberOfLines ?? 0
        nsView.textContainer?.lineBreakMode = lineBreakMode
        nsView.setAccessibilityIdentifier(accessibilityIdentifier)
        nsView.invalidateIntrinsicContentSize()
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: IntrinsicTextView, context: Context) -> CGSize? {
        guard let width = proposal.width, width > 0 else { return nil }
        return CGSize(width: width, height: nsView.fittingHeight(for: width))
    }
}

@MainActor
final class IntrinsicTextView: NSTextView {
    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: fittingHeight(for: bounds.width))
    }

    override func layout() {
        super.layout()
        invalidateIntrinsicContentSize()
    }

    func fittingHeight(for width: CGFloat) -> CGFloat {
        guard let layoutManager, let textContainer else { return 0 }
        guard width > 0 else { return ceil(font?.lineHeight ?? 0) }
        textContainer.containerSize = NSSize(width: width, height: CGFloat.greatestFiniteMagnitude)
        layoutManager.ensureLayout(for: textContainer)
        return ceil(layoutManager.usedRect(for: textContainer).height)
    }
}

private extension NSFont {
    var lineHeight: CGFloat {
        ascender - descender + leading
    }
}
