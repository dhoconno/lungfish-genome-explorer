// OperationsRowCellView.swift - Row cell whose failure subtitle stays readable when selected
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import Combine
import LungfishCore
import LungfishKit

/// A row cell whose failure subtitle stays readable when the row is selected.
///
/// The failure subtitle is drawn in `lungfishDanger`, which does not respond to
/// the cell's background style the way `labelColor` and `secondaryLabelColor`
/// do, so on the blue selection it stayed copper and could not be read. On an
/// emphasized selection it switches to the selected-text color; the failure is
/// still shown there by the status symbol and the error text itself.
@MainActor
final class OperationsRowCellView: NSTableCellView {
    static let detailTag = 101

    var showsFailureDetail = false {
        didSet { updateDetailColor() }
    }

    override var backgroundStyle: NSView.BackgroundStyle {
        didSet { updateDetailColor() }
    }

    private func updateDetailColor() {
        guard let detail = viewWithTag(Self.detailTag) as? NSTextField else { return }
        if backgroundStyle == .emphasized {
            detail.textColor = .alternateSelectedControlTextColor
        } else {
            detail.textColor = showsFailureDetail ? .lungfishDanger : .secondaryLabelColor
        }
    }
}
