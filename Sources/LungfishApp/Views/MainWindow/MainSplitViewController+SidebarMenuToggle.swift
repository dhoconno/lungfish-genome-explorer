// MainSplitViewController+SidebarMenuToggle.swift - The View menu's sidebar toggle on the shell's reveal path
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit

extension MainSplitViewController {
    /// View > Show Sidebar and Hide Sidebar send `toggleSidebar(_:)` up the responder chain. Whenever a view inside the
    /// split view is first responder, this controller answers before the window controller does. AppKit's own toggle
    /// reveals the sidebar at the width its constraint held while hidden, zero points (W-12), so the action takes the
    /// shell's toggle, which sets the reveal width first and saves the panel state.
    override public func toggleSidebar(_ sender: Any?) {
        toggleSidebar()
    }
}
