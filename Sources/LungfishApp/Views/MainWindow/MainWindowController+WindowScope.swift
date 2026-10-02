// MainWindowController+WindowScope.swift - The project window owns its window scope
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import LungfishKit

/// A view this window shows finds the window's scope through
/// `ScopedEventFilter.hostingWindowScope(of:)`, so a view that a container
/// embeds without handing it a scope still posts and filters as this window.
extension MainWindowController: WindowStateScopeOwner {
    public var windowStateScope: WindowStateScope {
        projectSession.windowStateScope
    }
}
