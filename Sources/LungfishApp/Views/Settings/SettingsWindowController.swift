// SettingsWindowController.swift - macOS HIG-compliant settings window
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import SwiftUI
import os.log
import LungfishCore

private let logger = Logger(subsystem: LogSubsystem.app, category: "SettingsWindow")

enum SettingsNavigationTab: Hashable {
    case general
    case appearance
    case rendering
    case storage
    case aiServices
}

@MainActor
@Observable
final class SettingsNavigationState {
    static let shared = SettingsNavigationState()

    var selectedTab: SettingsNavigationTab = .general

    func open(_ tab: SettingsNavigationTab) {
        selectedTab = tab
        NSApp?.sendAction(Selector(("showPreferences:")), to: nil, from: nil)
    }
}

/// NSWindowController that hosts the SwiftUI Settings view.
///
/// Follows the macOS HIG pattern: titled tabbed settings window,
/// accessible via Cmd+,. Singleton-like lifecycle managed by AppDelegate.
@MainActor
public final class SettingsWindowController: NSWindowController {

    public init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 550, height: 460),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Settings"
        window.identifier = NSUserInterfaceItemIdentifier(SettingsAccessibilityID.window)
        window.minSize = NSSize(width: 550, height: 460)
        window.setFrameAutosaveName("SettingsWindow")
        window.isRestorable = false

        super.init(window: window)

        let hostingView = NSHostingView(rootView: SettingsView())
        window.contentView = hostingView
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// Shows the settings window, centering it on first display.
    public func show() {
        guard let window else { return }
        if !window.isVisible {
            window.center()
        }
        window.makeKeyAndOrderFront(nil)
        logger.info("Settings window shown")
    }
}
