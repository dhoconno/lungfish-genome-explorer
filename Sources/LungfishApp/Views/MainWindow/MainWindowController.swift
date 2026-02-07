// MainWindowController.swift - Main application window controller
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import LungfishCore
import LungfishIO

/// Controller for the main application window.
///
/// Manages the window lifecycle, toolbar, and coordinates between the
/// sidebar, viewer, and inspector panels.
@MainActor
public class MainWindowController: NSWindowController {

    /// The main split view controller
    public private(set) var mainSplitViewController: MainSplitViewController!

    /// Toolbar item identifiers
    private enum ToolbarIdentifier {
        static let toolbar = NSToolbar.Identifier("MainToolbar")
        static let navigation = NSToolbarItem.Identifier("Navigation")
        static let coordinates = NSToolbarItem.Identifier("Coordinates")
        static let zoom = NSToolbarItem.Identifier("Zoom")
        static let toggleSidebar = NSToolbarItem.Identifier("ToggleSidebar")
        static let toggleInspector = NSToolbarItem.Identifier("ToggleInspector")
        static let toggleChromosomeDrawer = NSToolbarItem.Identifier("ToggleChromosomeDrawer")
        static let toggleAnnotationDrawer = NSToolbarItem.Identifier("ToggleAnnotationDrawer")
        static let flexibleSpace = NSToolbarItem.Identifier.flexibleSpace
        static let space = NSToolbarItem.Identifier.space
        static let sidebarTrackingSeparator = NSToolbarItem.Identifier.sidebarTrackingSeparator
    }

    // MARK: - Toolbar State

    /// Stored reference to the coordinates combobox for two-way binding.
    private var coordinateComboBox: NSComboBox?

    /// Annotation search index for the current bundle.
    private var annotationSearchIndex: AnnotationSearchIndex?

    /// Flag to suppress combobox delegate callbacks during programmatic updates.
    private var isUpdatingCoordinatesProgrammatically = false

    // MARK: - Initialization

    public convenience init() {
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
            .fullSizeContentView
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

        window.tabbingMode = .automatic
        window.tabbingIdentifier = "LungfishMainWindow"
        window.center()

        return window
    }

    private func configureWindow() {
        guard let window = window else { return }

        mainSplitViewController = MainSplitViewController()
        window.contentViewController = mainSplitViewController

        configureToolbar()
        setupNotificationObservers()

        window.delegate = self
    }

    // MARK: - Notification Observers

    private func setupNotificationObservers() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleCoordinatesChanged(_:)),
            name: .viewerCoordinatesChanged,
            object: nil
        )

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleBundleLoaded(_:)),
            name: .bundleDidLoad,
            object: nil
        )
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    // MARK: - Coordinate Sync

    @objc private func handleCoordinatesChanged(_ notification: Notification) {
        guard let userInfo = notification.userInfo,
              let chromosome = userInfo[NotificationUserInfoKey.chromosome] as? String,
              let start = userInfo[NotificationUserInfoKey.start] as? Int,
              let end = userInfo[NotificationUserInfoKey.end] as? Int else { return }

        isUpdatingCoordinatesProgrammatically = true
        let formatted = formatCoordinateString(chromosome: chromosome, start: start, end: end)
        coordinateComboBox?.stringValue = formatted
        isUpdatingCoordinatesProgrammatically = false
    }

    private func formatCoordinateString(chromosome: String, start: Int, end: Int) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        let startStr = formatter.string(from: NSNumber(value: start + 1)) ?? "\(start + 1)"
        let endStr = formatter.string(from: NSNumber(value: end)) ?? "\(end)"
        return "\(chromosome):\(startStr)-\(endStr)"
    }

    // MARK: - Bundle Loaded → Index Building & Combobox Population

    @objc private func handleBundleLoaded(_ notification: Notification) {
        guard let userInfo = notification.userInfo,
              let chromosomes = userInfo[NotificationUserInfoKey.chromosomes] as? [ChromosomeInfo] else { return }

        // Populate combobox dropdown with chromosome names
        let sorted = naturalChromosomeSort(chromosomes)
        coordinateComboBox?.removeAllItems()
        coordinateComboBox?.addItems(withObjectValues: sorted.map { $0.name })

        // Build annotation search index on background thread
        guard let viewerController = mainSplitViewController?.viewerController,
              let bundle = viewerController.viewerView?.currentReferenceBundle else { return }

        let index = AnnotationSearchIndex()
        annotationSearchIndex = index

        // Set callback to populate annotation drawer when index is ready
        index.onBuildComplete = { [weak self, weak viewerController] in
            guard let self, let viewerController else { return }
            viewerController.annotationSearchIndex = self.annotationSearchIndex
        }

        // Starts background thread I/O — won't block the UI
        index.buildIndex(bundle: bundle, chromosomes: chromosomes)
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

    // MARK: - Toolbar Button Helper

    /// Creates an NSButton suitable for use as a toolbar item view.
    /// Uses SF Symbols with fallback chain for cross-version compatibility.
    private func makeToolbarButton(symbolName: String, fallbacks: [String], accessibilityLabel: String) -> NSButton {
        var image: NSImage?
        for name in [symbolName] + fallbacks {
            if let img = NSImage(systemSymbolName: name, accessibilityDescription: accessibilityLabel) {
                image = img
                break
            }
        }
        let button = NSButton(frame: NSRect(x: 0, y: 0, width: 38, height: 24))
        button.bezelStyle = .toolbar
        button.image = image ?? NSImage(named: NSImage.infoName)
        button.imagePosition = .imageOnly
        button.setAccessibilityLabel(accessibilityLabel)
        return button
    }

    // MARK: - Panel Toggle Actions

    @objc public func toggleSidebar(_ sender: Any?) {
        mainSplitViewController.toggleSidebar()
    }

    @objc public func toggleInspector(_ sender: Any?) {
        mainSplitViewController.toggleInspector()
    }

    @objc public func toggleChromosomeDrawer(_ sender: Any?) {
        mainSplitViewController.viewerController?.toggleChromosomeDrawer()
    }

    @objc public func toggleAnnotationDrawer(_ sender: Any?) {
        mainSplitViewController.viewerController?.toggleAnnotationDrawer()
    }

    // MARK: - Navigation Actions

    @objc public func goBack(_ sender: Any?) {
        // Navigate to previous position in history
    }

    @objc public func goForward(_ sender: Any?) {
        // Navigate to next position in history
    }

    @objc public func zoomIn(_ sender: Any?) {
        mainSplitViewController.viewerController?.zoomIn()
    }

    @objc public func zoomOut(_ sender: Any?) {
        mainSplitViewController.viewerController?.zoomOut()
    }

    @objc public func zoomToFit(_ sender: Any?) {
        mainSplitViewController.viewerController?.zoomToFit()
    }

    // MARK: - Coordinate Input Handling

    private func handleCoordinateInput(_ input: String) {
        guard let viewerController = mainSplitViewController?.viewerController else { return }

        // Strip commas from user input (they may copy "chr1:1,000-10,000")
        let cleaned = input.replacingOccurrences(of: ",", with: "")
            .trimmingCharacters(in: .whitespaces)
        guard !cleaned.isEmpty else { return }

        // Check if input is just a chromosome name (no colon)
        if !cleaned.contains(":") && !cleaned.contains("-") && !cleaned.contains("..") {
            // Might be a chromosome name from the dropdown
            if let provider = viewerController.currentBundleDataProvider,
               let chromInfo = provider.chromosomeInfo(named: cleaned) {
                viewerController.navigateToChromosomeAndPosition(
                    chromosome: chromInfo.name,
                    chromosomeLength: Int(chromInfo.length),
                    start: 0,
                    end: min(Int(chromInfo.length), 10000)
                )
                return
            }
        }

        // Parse coordinate string: chr:start-end, chr:start..end, start-end, position
        var chromosome: String?
        var startPosition: Int?
        var endPosition: Int?

        if cleaned.contains(":") {
            let colonParts = cleaned.split(separator: ":", maxSplits: 1)
            guard colonParts.count == 2 else { NSSound.beep(); return }
            chromosome = String(colonParts[0])
            parseRange(String(colonParts[1]), start: &startPosition, end: &endPosition)
        } else {
            parseRange(cleaned, start: &startPosition, end: &endPosition)
        }

        guard let start = startPosition else { NSSound.beep(); return }

        // Convert 1-based user input to 0-based
        let zeroBasedStart = max(0, start - 1)
        let zeroBasedEnd: Int? = endPosition.map { max(zeroBasedStart + 1, $0) }

        // For bundle mode with chromosome switch
        if let chrom = chromosome,
           let provider = viewerController.currentBundleDataProvider,
           let chromInfo = provider.chromosomeInfo(named: chrom) {
            let end = zeroBasedEnd ?? min(zeroBasedStart + 10000, Int(chromInfo.length))
            viewerController.navigateToChromosomeAndPosition(
                chromosome: chrom,
                chromosomeLength: Int(chromInfo.length),
                start: zeroBasedStart,
                end: end
            )
        } else {
            viewerController.navigateToPosition(
                chromosome: chromosome,
                start: zeroBasedStart,
                end: zeroBasedEnd
            )
        }
    }

    /// Parses "start-end", "start..end", or a single position.
    private func parseRange(_ input: String, start: inout Int?, end: inout Int?) {
        if input.contains("..") {
            let parts = input.split(separator: ".", omittingEmptySubsequences: true)
            if parts.count == 2 {
                start = Int(parts[0].trimmingCharacters(in: .whitespaces))
                end = Int(parts[1].trimmingCharacters(in: .whitespaces))
            }
        } else if input.contains("-"), input.first != "-" {
            if let hyphen = input.lastIndex(of: "-"), hyphen > input.startIndex {
                let before = String(input[input.startIndex..<hyphen])
                let after = String(input[input.index(after: hyphen)...])
                if let s = Int(before.trimmingCharacters(in: .whitespaces)),
                   let e = Int(after.trimmingCharacters(in: .whitespaces)) {
                    start = s
                    end = e
                } else {
                    start = Int(input.trimmingCharacters(in: .whitespaces))
                }
            }
        } else {
            start = Int(input.trimmingCharacters(in: .whitespaces))
        }
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
            item.toolTip = "Show or hide the sidebar (Opt-Cmd-S)"
            let button = makeToolbarButton(
                symbolName: "sidebar.leading",
                fallbacks: ["sidebar.left", "sidebar.squares.leading"],
                accessibilityLabel: "Toggle Sidebar"
            )
            button.target = self
            button.action = #selector(toggleSidebar(_:))
            item.view = button
            return item

        case ToolbarIdentifier.toggleInspector:
            let item = NSToolbarItem(itemIdentifier: itemIdentifier)
            item.label = "Inspector"
            item.paletteLabel = "Toggle Inspector"
            item.toolTip = "Show or hide the inspector (Opt-Cmd-I)"
            let button = makeToolbarButton(
                symbolName: "sidebar.trailing",
                fallbacks: ["sidebar.right", "info.circle"],
                accessibilityLabel: "Toggle Inspector"
            )
            button.target = self
            button.action = #selector(toggleInspector(_:))
            item.view = button
            return item

        case ToolbarIdentifier.toggleChromosomeDrawer:
            let item = NSToolbarItem(itemIdentifier: itemIdentifier)
            item.label = "Chromosomes"
            item.paletteLabel = "Toggle Chromosome Drawer"
            item.toolTip = "Show or hide the chromosome drawer"
            let button = makeToolbarButton(
                symbolName: "list.bullet.rectangle",
                fallbacks: ["rectangle.split.3x1", "list.bullet"],
                accessibilityLabel: "Toggle Chromosome Drawer"
            )
            button.target = self
            button.action = #selector(toggleChromosomeDrawer(_:))
            item.view = button
            return item

        case ToolbarIdentifier.toggleAnnotationDrawer:
            let item = NSToolbarItem(itemIdentifier: itemIdentifier)
            item.label = "Annotations"
            item.paletteLabel = "Toggle Annotation Drawer"
            item.toolTip = "Show or hide the annotation table"
            let button = makeToolbarButton(
                symbolName: "tablecells",
                fallbacks: ["tablecells.badge.ellipsis", "list.dash"],
                accessibilityLabel: "Toggle Annotation Drawer"
            )
            button.target = self
            button.action = #selector(toggleAnnotationDrawer(_:))
            item.view = button
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
            comboBox.delegate = self
            item.view = comboBox
            coordinateComboBox = comboBox
            return item

        case ToolbarIdentifier.sidebarTrackingSeparator:
            return NSTrackingSeparatorToolbarItem(
                identifier: itemIdentifier,
                splitView: mainSplitViewController.splitView,
                dividerIndex: 0
            )

        default:
            return nil
        }
    }

    public func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [
            ToolbarIdentifier.toggleSidebar,
            ToolbarIdentifier.sidebarTrackingSeparator,
            ToolbarIdentifier.toggleChromosomeDrawer,
            ToolbarIdentifier.toggleAnnotationDrawer,
            ToolbarIdentifier.navigation,
            ToolbarIdentifier.space,
            ToolbarIdentifier.coordinates,
            ToolbarIdentifier.flexibleSpace,
            ToolbarIdentifier.zoom,
            ToolbarIdentifier.toggleInspector,
        ]
    }

    public func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [
            ToolbarIdentifier.toggleSidebar,
            ToolbarIdentifier.sidebarTrackingSeparator,
            ToolbarIdentifier.toggleInspector,
            ToolbarIdentifier.toggleChromosomeDrawer,
            ToolbarIdentifier.toggleAnnotationDrawer,
            ToolbarIdentifier.navigation,
            ToolbarIdentifier.coordinates,
            ToolbarIdentifier.zoom,
            ToolbarIdentifier.flexibleSpace,
            ToolbarIdentifier.space,
        ]
    }
}

// MARK: - NSComboBoxDelegate

extension MainWindowController: NSComboBoxDelegate {

    /// Called when user presses Return in the coordinate combobox or selects an item.
    public func comboBoxSelectionDidChange(_ notification: Notification) {
        guard let comboBox = notification.object as? NSComboBox,
              comboBox === coordinateComboBox,
              !isUpdatingCoordinatesProgrammatically else { return }

        let index = comboBox.indexOfSelectedItem
        guard index >= 0, index < comboBox.numberOfItems else { return }

        if let value = comboBox.itemObjectValue(at: index) as? String {
            handleCoordinateInput(value)
        }
    }

    public func controlTextDidEndEditing(_ obj: Notification) {
        // Handle Return key in coordinate combobox
        if let comboBox = obj.object as? NSComboBox,
           comboBox === coordinateComboBox,
           !isUpdatingCoordinatesProgrammatically {
            let input = comboBox.stringValue
            if !input.isEmpty {
                handleCoordinateInput(input)
            }
            return
        }
    }
}
