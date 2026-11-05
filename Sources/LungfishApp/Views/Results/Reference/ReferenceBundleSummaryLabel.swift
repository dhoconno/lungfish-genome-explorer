// ReferenceBundleSummaryLabel.swift - The summary line of the reference viewport's bar, cut to the window and never widening it
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit

/// The summary line above the reference viewport (WALKFIX, W-26).
///
/// A plain label asks for its whole text as a minimum width, and the bar chains it toward the trailing edge. A long
/// line, such as the words of an alignment summary that could not be measured, then grew the window to 4387 points on
/// a 2560 point screen and pushed the toolbar and the Inspector off it. This label cuts the line in the middle, since a
/// warning sits at the tail of the line, and its horizontal compression resistance is under
/// `NSLayoutConstraint.Priority.windowSizeStayPut` (500), so the window keeps its size and the label gives way.
///
/// The tooltip is the whole line on every write, as `StatusBarLabel` does in the status bar. A tip that a writer sets
/// with `toolTip`, such as the reason and the next step of `alignmentSummaryTip`, stays under the whole line.
final class ReferenceBundleSummaryLabel: NSTextField {
    /// Words a writer set as the tooltip, kept under the whole line.
    private var tipBeneathLine: String?

    /// The label with the text, font, colour and identifier the bar has always given it.
    static func make() -> ReferenceBundleSummaryLabel {
        let label = ReferenceBundleSummaryLabel(labelWithString: "Reference Bundle")
        label.font = .systemFont(ofSize: NSFont.smallSystemFontSize, weight: .semibold)
        label.textColor = .secondaryLabelColor
        label.translatesAutoresizingMaskIntoConstraints = false
        label.lineBreakMode = .byTruncatingMiddle
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        label.setAccessibilityIdentifier("reference-bundle-summary-label")
        return label
    }

    override var stringValue: String {
        didSet { refreshToolTip() }
    }

    override var toolTip: String? {
        get { super.toolTip }
        set {
            tipBeneathLine = newValue
            refreshToolTip()
        }
    }

    private func refreshToolTip() {
        let line: String? = stringValue.isEmpty ? nil : stringValue
        let tip = tipBeneathLine.flatMap { $0.isEmpty ? nil : $0 }
        let whole: String?
        if let line, let tip, !line.contains(tip) {
            whole = line + "\n\n" + tip
        } else {
            whole = line ?? tip
        }
        if super.toolTip != whole { super.toolTip = whole }
    }
}
