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

    /// The room a sheet has under a parent whose content area is
    /// `parentContent`, in screen coordinates. The sheet hangs from the top of
    /// that area and stops at the parent's bottom edge or at the bottom of the
    /// screen's visible frame, whichever comes first (review U3-2).
    static func availableSheetSize(parentContent: NSRect, visibleFrame: NSRect?) -> CGSize {
        guard let visible = visibleFrame else { return parentContent.size }
        let top = min(parentContent.maxY, visible.maxY)
        let bottom = max(parentContent.minY, visible.minY)
        return CGSize(
            width: min(parentContent.width, visible.width),
            height: max(0, top - bottom)
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

    /// The parent window changes that can leave the open sheet too big.
    private static let parentChangeNotifications: [Notification.Name] = [
        NSWindow.didResizeNotification,
        NSWindow.didChangeScreenNotification,
        NSWindow.didEnterFullScreenNotification,
        NSWindow.didExitFullScreenNotification,
    ]

    /// Shrinks the sheet to fit its parent window and screen. A window that
    /// is not yet attached as a sheet is left alone until it is.
    override public func viewWillAppear() {
        super.viewWillAppear()
        clampSheetToParent()
    }

    /// Clamps again once the sheet is attached, and follows the parent while
    /// the sheet is open.
    override public func viewDidAppear() {
        super.viewDidAppear()
        startFollowingSheetParent()
    }

    override public func viewWillDisappear() {
        super.viewWillDisappear()
        stopFollowingSheetParent()
    }

    private func startFollowingSheetParent() {
        guard let window = view.window else { return }
        stopFollowingSheetParent()
        guard let parent = window.sheetParent else {
            // Attached later: clamp when the sheet becomes key.
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(sheetDidBecomeKey(_:)),
                name: NSWindow.didBecomeKeyNotification,
                object: window
            )
            return
        }
        clampSheetToParent()
        for name in Self.parentChangeNotifications {
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(sheetParentDidChange(_:)),
                name: name,
                object: parent
            )
        }
    }

    private func stopFollowingSheetParent() {
        let center = NotificationCenter.default
        center.removeObserver(self, name: NSWindow.didBecomeKeyNotification, object: nil)
        for name in Self.parentChangeNotifications {
            center.removeObserver(self, name: name, object: nil)
        }
    }

    @objc private func sheetDidBecomeKey(_ notification: Notification) {
        guard view.window?.sheetParent != nil else { return }
        startFollowingSheetParent()
    }

    @objc private func sheetParentDidChange(_ notification: Notification) {
        clampSheetToParent()
    }

    /// Fits the sheet into the room under its parent. Never grows it past
    /// its default size.
    func clampSheetToParent() {
        guard let window = view.window, let parent = window.sheetParent else { return }
        let available = Self.availableSheetSize(
            parentContent: parent.convertToScreen(parent.contentLayoutRect),
            visibleFrame: parent.screen?.visibleFrame
        )
        let size = Self.sheetContentSize(fitting: available)
        let current = window.contentLayoutRect.size
        if current.width > size.width || current.height > size.height {
            window.setContentSize(CGSize(width: min(current.width, size.width), height: min(current.height, size.height)))
        }
    }
}
