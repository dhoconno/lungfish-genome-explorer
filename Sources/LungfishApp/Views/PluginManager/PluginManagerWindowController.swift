// PluginManagerWindowController.swift - Plugin Manager window for bioinformatics tool management
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import SwiftUI
import LungfishCore
import os.log

/// Logger for the Plugin Manager window.
private let logger = Logger(subsystem: LogSubsystem.app, category: "PluginManager")

/// NSWindowController that hosts the Plugin Manager SwiftUI view.
///
/// Provides a singleton window for browsing, installing, and managing
/// bioinformatics tools from bioconda via micromamba. Follows the same
/// lazy singleton pattern used by ``SettingsWindowController``.
///
/// The window features a toolbar with a segmented control (Installed /
/// Packs / Databases). The content area is a
/// SwiftUI ``PluginManagerView`` wrapped in an ``NSHostingView``.
///
/// ## Usage
///
/// ```swift
/// PluginManagerWindowController.show()
/// PluginManagerWindowController.show(tab: .databases)
/// ```
@MainActor
public final class PluginManagerWindowController: NSWindowController, NSToolbarDelegate {

    /// Shared singleton instance. Created on first call to ``show()``.
    private static var shared: PluginManagerWindowController?

    /// The SwiftUI view model, retained for toolbar-to-view binding.
    private let viewModel = PluginManagerViewModel()

    /// Toolbar item identifiers.
    private enum ToolbarID {
        static let segmentedControl = NSToolbarItem.Identifier("pluginManagerSegment")
    }

    // MARK: - Singleton Access

    /// Shows the Plugin Manager window, creating it if needed.
    ///
    /// Reuses the singleton window if it already exists. Centers the
    /// window on first display.
    public static func show() {
        showWindow(tab: nil)
    }

    /// Shows the Plugin Manager window and switches to the specified tab.
    ///
    /// - Parameter tab: The tab to display. Pass `.databases` to navigate
    ///   directly to the Kraken2 database management view.
    static func show(tab: PluginManagerViewModel.Tab) {
        showWindow(tab: tab)
    }

    public static func show(packID: String) {
        showWindow(tab: .packs)
        shared?.viewModel.focusPack(packID)
    }

    /// Internal implementation shared by both `show()` overloads.
    private static func showWindow(tab: PluginManagerViewModel.Tab?) {
        if shared == nil {
            shared = PluginManagerWindowController()
        }
        if let tab {
            shared?.viewModel.selectedTab = tab
            shared?.syncSegmentedControl(to: tab)
        }
        shared?.showWindow(nil)
    }

    // MARK: - Initialization

    private init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Plugin Manager"
        window.minSize = NSSize(width: 640, height: 400)
        window.setFrameAutosaveName("PluginManagerWindow")
        window.isRestorable = false
        window.isReleasedWhenClosed = false
        window.setAccessibilityIdentifier(PluginManagerAccessibilityID.window)

        super.init(window: window)

        setupToolbar()
        setupContent()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - Setup

    private func setupToolbar() {
        guard let window else { return }

        let toolbar = NSToolbar(identifier: "PluginManagerToolbar")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = false
        window.toolbar = toolbar
    }

    private func setupContent() {
        guard let window else { return }
        let hostingView = NSHostingView(rootView: PluginManagerView(viewModel: viewModel))
        window.contentView = hostingView
    }

    // MARK: - Window Lifecycle

    override public func showWindow(_ sender: Any?) {
        guard let window else { return }
        if !window.isVisible {
            window.center()
        }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
        logger.info("Plugin Manager window shown")
    }

    // MARK: - NSToolbarDelegate

    public func toolbar(
        _ toolbar: NSToolbar,
        itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
        willBeInsertedIntoToolbar flag: Bool
    ) -> NSToolbarItem? {
        switch itemIdentifier {
        case ToolbarID.segmentedControl:
            let item = NSToolbarItem(itemIdentifier: itemIdentifier)
            let segmented = NSSegmentedControl(
                labels: ["Installed", "Packs", "Databases"],
                trackingMode: .selectOne,
                target: self,
                action: #selector(segmentChanged(_:))
            )
            segmented.segmentStyle = .texturedRounded
            segmented.selectedSegment = viewModel.selectedTab.segmentIndex
            segmented.setWidth(96, forSegment: 0)
            segmented.setWidth(72, forSegment: 1)
            segmented.setWidth(92, forSegment: 2)
            segmented.setAccessibilityIdentifier(PluginManagerAccessibilityID.toolbarSegmentedControl)
            item.view = segmented
            item.label = "Sections"
            item.toolTip = "Switch between Installed, Packs, and Databases"
            return item

        default:
            return nil
        }
    }

    public func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [
            ToolbarID.segmentedControl,
        ]
    }

    public func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar)
    }

    // MARK: - Toolbar Actions

    @objc private func segmentChanged(_ sender: NSSegmentedControl) {
        let tab = PluginManagerViewModel.Tab.from(segmentIndex: sender.selectedSegment)
        viewModel.selectedTab = tab
    }

    // MARK: - Helpers

    /// Synchronizes the toolbar segmented control to match a given tab.
    ///
    /// Called when ``show(tab:)`` programmatically changes the selected tab
    /// so that the toolbar visual state remains in sync with the view model.
    private func syncSegmentedControl(to tab: PluginManagerViewModel.Tab) {
        guard let toolbar = window?.toolbar else { return }
        for item in toolbar.items where item.itemIdentifier == ToolbarID.segmentedControl {
            if let segmented = item.view as? NSSegmentedControl {
                segmented.selectedSegment = tab.segmentIndex
            }
        }
    }
}
