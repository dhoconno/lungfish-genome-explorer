// SelectionAwareTextCellView.swift - Table cell whose colored text stays readable when selected
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit

/// A table cell that draws its text in a fixed accent color, such as a
/// variant-type or genotype color, but switches to the selected-text color on
/// an emphasized selection.
///
/// AppKit flips semantic colors like `labelColor` to white on the blue
/// selection by itself. A fixed color does not flip, so green SNP text stayed
/// green on blue and could not be read.
@MainActor
final class SelectionAwareTextCellView: NSTableCellView {
    /// The text color when the row is not selected; nil means `labelColor`.
    var accentTextColor: NSColor? {
        didSet { applyTextColor() }
    }

    override var backgroundStyle: NSView.BackgroundStyle {
        didSet { applyTextColor() }
    }

    private func applyTextColor() {
        guard let textField else { return }
        textField.textColor = backgroundStyle == .emphasized
            ? .alternateSelectedControlTextColor
            : (accentTextColor ?? .labelColor)
    }
}
