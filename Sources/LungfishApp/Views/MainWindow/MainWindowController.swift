// MainWindowController.swift - Main application window controller
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import LungfishCore

/// Controller for the main application window.
///
/// Manages the window lifecycle, toolbar, and coordinates between the
/// sidebar, viewer, and inspector panels.
@MainActor
public class MainWindowController: NSWindowController {

    /// The main split view controller
    private var splitViewController: MainSplitViewController!

    /// Toolbar item identifiers
    private enum ToolbarIdentifier {
        static let toolbar = NSToolbar.Identifier("MainToolbar")
        static let navigation = NSToolbarItem.Identifier("Navigation")
        static let coordinates = NSToolbarItem.Identifier("Coordinates")
        static let zoom = NSToolbarItem.Identifier("Zoom")
        static let toggleSidebar = NSToolbarItem.Identifier("ToggleSidebar")
        static let toggleInspector = NSToolbarItem.Identifier("ToggleInspector")
        static let search = NSToolbarItem.Identifier("Search")
        static let flexibleSpace = NSToolbarItem.Identifier.flexibleSpace
        static let space = NSToolbarItem.Identifier.space
    }

    // MARK: - Initialization

    public convenience init() {
        // Create window with appropriate style
        let window = Self.createMainWindow()
        self.init(window: window)
        configureWindow()
    }

    private static func createMainWindow() -> NSWindow {
        let contentRect = NSRect(x: 0, y: 0, width: 1200, height: 800)

        let styleMask: NSWindow.StyleMask = [
            .titled,
            .closable,
            .miniaturizable,
            .resizable,
            .fullSizeContentView  // Modern macOS style
        ]

        let window = NSWindow(
            contentRect: contentRect,
            styleMask: styleMask,
            backing: .buffered,
            defer: false
        )

        window.title = "Lungfish"
        window.minSize = NSSize(width: 800, height: 500)
        window.setFrameAutosaveName("MainWindow")
        window.titlebarAppearsTransparent = false
        window.titleVisibility = .visible
        window.toolbarStyle = .unified

        // Enable window tabs
        window.tabbingMode = .automatic
        window.tabbingIdentifier = "LungfishMainWindow"

        // Center on screen
        window.center()

        return window
    }

    private func configureWindow() {
        guard let window = window else { return }

        // Create the split view controller hierarchy
        splitViewController = MainSplitViewController()
        window.contentViewController = splitViewController

        // Configure toolbar
        configureToolbar()

        // Set window delegate
        window.delegate = self
    }

    // MARK: - Toolbar Configuration

    private func configureToolbar() {
        guard let window = window else { return }

        let toolbar = NSToolbar(identifier: ToolbarIdentifier.toolbar)
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = true
        toolbar.autosavesConfiguration = true

        window.toolbar = toolbar
    }

    // MARK: - Panel Toggle Actions

    @objc public func toggleSidebar(_ sender: Any?) {
        splitViewController.toggleSidebar()
    }

    @objc public func toggleInspector(_ sender: Any?) {
        splitViewController.toggleInspector()
    }

    // MARK: - Navigation Actions

    @objc public func goBack(_ sender: Any?) {
        // Navigate to previous position in history
    }

    @objc public func goForward(_ sender: Any?) {
        // Navigate to next position in history
    }

    @objc public func zoomIn(_ sender: Any?) {
        splitViewController.viewerController?.zoomIn()
    }

    @objc public func zoomOut(_ sender: Any?) {
        splitViewController.viewerController?.zoomOut()
    }

    @objc public func zoomToFit(_ sender: Any?) {
        splitViewController.viewerController?.zoomToFit()
    }
}

// MARK: - NSWindowDelegate

extension MainWindowController: NSWindowDelegate {

    public func windowWillClose(_ notification: Notification) {
        // Save window state before closing
    }

    public func windowDidBecomeMain(_ notification: Notification) {
        // Update menu state when window becomes main
    }

    public func windowDidResignMain(_ notification: Notification) {
        // Handle losing main window status
    }
}

// MARK: - NSToolbarDelegate

extension MainWindowController: NSToolbarDelegate {

    public func toolbar(
        _ toolbar: NSToolbar,
        itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
        willBeInsertedIntoToolbar flag: Bool
    ) -> NSToolbarItem? {

        switch itemIdentifier {
        case ToolbarIdentifier.toggleSidebar:
            let item = NSToolbarItem(itemIdentifier: itemIdentifier)
            item.label = "Sidebar"
            item.paletteLabel = "Toggle Sidebar"
            item.toolTip = "Show or hide the sidebar (⌥⌘S)"
            item.image = NSImage(systemSymbolName: "sidebar.left", accessibilityDescription: "Sidebar")
            item.action = #selector(toggleSidebar(_:))
            item.target = self
            return item

        case ToolbarIdentifier.toggleInspector:
            let item = NSToolbarItem(itemIdentifier: itemIdentifier)
            item.label = "Inspector"
            item.paletteLabel = "Toggle Inspector"
            item.toolTip = "Show or hide the inspector (⌥⌘I)"
            item.image = NSImage(systemSymbolName: "sidebar.right", accessibilityDescription: "Inspector")
            item.action = #selector(toggleInspector(_:))
            item.target = self
            return item

        case ToolbarIdentifier.navigation:
            let group = NSToolbarItemGroup(itemIdentifier: itemIdentifier)
            group.label = "Navigation"
            group.paletteLabel = "Navigation"

            let backItem = NSToolbarItem(itemIdentifier: .init("Back"))
            backItem.image = NSImage(systemSymbolName: "chevron.left", accessibilityDescription: "Back")
            backItem.action = #selector(goBack(_:))
            backItem.target = self

            let forwardItem = NSToolbarItem(itemIdentifier: .init("Forward"))
            forwardItem.image = NSImage(systemSymbolName: "chevron.right", accessibilityDescription: "Forward")
            forwardItem.action = #selector(goForward(_:))
            forwardItem.target = self

            group.subitems = [backItem, forwardItem]
            group.controlRepresentation = .expanded
            return group

        case ToolbarIdentifier.zoom:
            let group = NSToolbarItemGroup(itemIdentifier: itemIdentifier)
            group.label = "Zoom"
            group.paletteLabel = "Zoom Controls"

            let zoomOutItem = NSToolbarItem(itemIdentifier: .init("ZoomOut"))
            zoomOutItem.image = NSImage(systemSymbolName: "minus.magnifyingglass", accessibilityDescription: "Zoom Out")
            zoomOutItem.action = #selector(zoomOut(_:))
            zoomOutItem.target = self

            let zoomInItem = NSToolbarItem(itemIdentifier: .init("ZoomIn"))
            zoomInItem.image = NSImage(systemSymbolName: "plus.magnifyingglass", accessibilityDescription: "Zoom In")
            zoomInItem.action = #selector(zoomIn(_:))
            zoomInItem.target = self

            group.subitems = [zoomOutItem, zoomInItem]
            group.controlRepresentation = .expanded
            return group

        case ToolbarIdentifier.coordinates:
            let item = NSToolbarItem(itemIdentifier: itemIdentifier)
            item.label = "Coordinates"
            item.paletteLabel = "Genomic Coordinates"

            let comboBox = NSComboBox(frame: NSRect(x: 0, y: 0, width: 250, height: 24))
            comboBox.placeholderString = "chr1:1,000-10,000"
            comboBox.isEditable = true
            comboBox.completes = true
            comboBox.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
            item.view = comboBox
            return item

        case ToolbarIdentifier.search:
            let item = NSSearchToolbarItem(itemIdentifier: itemIdentifier)
            item.searchField.placeholderString = "Search sequences..."
            return item

        default:
            return nil
        }
    }

    public func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [
            ToolbarIdentifier.toggleSidebar,
            ToolbarIdentifier.navigation,
            ToolbarIdentifier.space,
            ToolbarIdentifier.coordinates,
            ToolbarIdentifier.flexibleSpace,
            ToolbarIdentifier.zoom,
            ToolbarIdentifier.search,
            ToolbarIdentifier.toggleInspector,
        ]
    }

    public func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [
            ToolbarIdentifier.toggleSidebar,
            ToolbarIdentifier.toggleInspector,
            ToolbarIdentifier.navigation,
            ToolbarIdentifier.coordinates,
            ToolbarIdentifier.zoom,
            ToolbarIdentifier.search,
            ToolbarIdentifier.flexibleSpace,
            ToolbarIdentifier.space,
        ]
    }
}
