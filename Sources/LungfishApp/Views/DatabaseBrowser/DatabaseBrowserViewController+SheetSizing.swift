// DatabaseBrowserViewController+SheetSizing.swift - Keeps the Search Online Databases sheet inside its parent
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Lane U1: disclosing the advanced filters used to grow the sheet past the
// bottom of the screen, which hid Cancel and Download Selected. The sheet now
// keeps a stable size no larger than its parent window, and the pane scrolls
// the extra content instead (see DatabaseBrowserPane).

import AppKit
import SwiftUI

extension DatabaseBrowserViewController {
    /// The sheet's content size when its parent window has room for it.
    static let defaultSheetContentSize = CGSize(width: 900, height: 620)

    /// The sheet's content size inside a parent whose content area is
    /// `available`. The sheet never grows past its parent.
    static func sheetContentSize(fitting available: CGSize) -> CGSize {
        CGSize(
            width: min(defaultSheetContentSize.width, available.width),
            height: min(defaultSheetContentSize.height, available.height)
        )
    }

    /// Hosts the dialog so that only its minimum size reaches the window.
    /// With the default sizing options the ideal size did too, and the sheet
    /// grew whenever the pane disclosed more content.
    static func makeSheetHostingView<Content: View>(rootView: Content) -> NSHostingView<Content> {
        let hostingView = NSHostingView(rootView: rootView)
        hostingView.sizingOptions = [.minSize]
        hostingView.frame = NSRect(origin: .zero, size: defaultSheetContentSize)
        return hostingView
    }

    /// Shrinks the sheet to fit its parent window, or the screen when it has
    /// no parent yet.
    override public func viewWillAppear() {
        super.viewWillAppear()
        guard let window = view.window,
              let available = window.sheetParent?.contentLayoutRect.size ?? window.screen?.visibleFrame.size
        else { return }
        let size = Self.sheetContentSize(fitting: available)
        let current = window.contentLayoutRect.size
        if current.width > size.width || current.height > size.height {
            window.setContentSize(size)
        }
    }
}
