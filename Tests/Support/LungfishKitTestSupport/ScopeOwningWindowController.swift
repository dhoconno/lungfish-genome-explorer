// ScopeOwningWindowController.swift - A project-window stand-in for scope tests
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import LungfishKit

/// A window controller that owns a `WindowStateScope`, standing in for a
/// project window in tests of `ScopedEventFilter.hostingWindowScope(of:)` and
/// of views that find their scope through the window that shows them.
///
/// The window is created but never ordered on screen.
@MainActor
public final class ScopeOwningWindowController: NSWindowController, WindowStateScopeOwner {
    public let windowStateScope: WindowStateScope

    public init(windowStateScope: WindowStateScope = WindowStateScope()) {
        self.windowStateScope = windowStateScope
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 480),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: true
        )
        window.isReleasedWhenClosed = false
        super.init(window: window)
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) {
        fatalError("ScopeOwningWindowController is created in code only")
    }

    /// Adds `view` to the window's content view, so the view reports this
    /// window as its `window`.
    public func host(_ view: NSView) {
        window?.contentView?.addSubview(view)
    }
}
