// MainWindowController.swift - Main application window controller
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import Combine
import SwiftUI
import LungfishCore
import LungfishIO
import os.log

private let logger = Logger(subsystem: LogSubsystem.app, category: "MainWindowController")

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
        static let toolbar = NSToolbar.Identifier("MainToolbarMinimal")
        static let toggleSidebar = NSToolbarItem.Identifier("ToggleSidebar")
        static let toggleInspector = NSToolbarItem.Identifier("ToggleInspector")
        static let toggleChromosomeDrawer = NSToolbarItem.Identifier("ToggleChromosomeDrawer")
        static let toggleAnnotationDrawer = NSToolbarItem.Identifier("ToggleAnnotationDrawer")
        static let operations = NSToolbarItem.Identifier("Operations")
        static let translateTool = NSToolbarItem.Identifier("TranslateTool")
        static let flexibleSpace = NSToolbarItem.Identifier.flexibleSpace
    }

    private enum AccessibilityIdentifier {
        static let window = "main-window"
        static let shell = "main-window-shell"
        static let toggleSidebar = "main-window-toggle-sidebar"
        static let toggleInspector = "main-window-toggle-inspector"
        static let toggleChromosomeDrawer = "main-window-toggle-chromosome-drawer"
        static let toggleAnnotationDrawer = "main-window-toggle-annotation-drawer"
        static let translateTool = "main-window-translate-tool"
        static let operations = "main-window-operations"
    }

    // MARK: - Toolbar State

    /// Annotation search index for the current bundle.
    private var annotationSearchIndex: AnnotationSearchIndex?

    /// Last toolbar inspector-toggle action dispatch time (uptime seconds).
    private var lastInspectorToggleActionTime: TimeInterval = 0

    /// Last AppKit event number handled by the inspector toggle action.
    private var lastInspectorToggleEventNumber: Int?

    /// Bottom drawer toolbar button — highlighted when drawer is open.
    private weak var drawerToolbarButton: NSButton?

    /// Current viewport content mode for toolbar adaptation.
    private var currentContentMode: ViewportContentMode = .empty

    /// Combine subscriptions for toolbar state bindings.
    private var cancellables = Set<AnyCancellable>()

    // MARK: - Initialization

    public convenience init() {
        let window = Self.createMainWindow()
        self.init(window: window)
        configureWindow()
    }

    private static func createMainWindow() -> NSWindow {
        let screen = NSScreen.main ?? NSScreen.screens.first
        let screenFrame = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let defaultWidth = min(screenFrame.width * 0.85, 1920)
        let defaultHeight = min(screenFrame.height * 0.85, 1200)
        let contentRect = NSRect(x: 0, y: 0, width: defaultWidth, height: defaultHeight)

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

        window.title = "Lungfish Genome Explorer"
        window.minSize = NSSize(width: 800, height: 500)
        window.setFrameAutosaveName("MainWindow")
        // Disable window restoration — the app does not implement
        // NSWindowRestoration, so leaving this true causes a console
        // error: "Unable to find className=(null)" on every launch.
        // Frame autosave still works independently of restoration.
        window.isRestorable = false
        window.titlebarAppearsTransparent = false
        window.titleVisibility = .visible
        window.toolbarStyle = .unified
        window.setAccessibilityIdentifier(AccessibilityIdentifier.window)
        window.setAccessibilityLabel("Main window")

        window.collectionBehavior = [.fullScreenPrimary]
        window.tabbingMode = .automatic
        window.tabbingIdentifier = "LungfishMainWindow"
        window.center()

        return window
    }

    private func configureWindow() {
        guard let window = window else { return }

        mainSplitViewController = MainSplitViewController()
        window.contentViewController = mainSplitViewController
        mainSplitViewController.view.setAccessibilityElement(true)
        mainSplitViewController.view.setAccessibilityIdentifier(AccessibilityIdentifier.shell)
        mainSplitViewController.view.setAccessibilityLabel("Main window shell")

        configureToolbar()
        setupNotificationObservers()

        window.delegate = self
    }

    // MARK: - Notification Observers

    private func setupNotificationObservers() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleBundleLoaded(_:)),
            name: .bundleDidLoad,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleContentModeChanged(_:)),
            name: .viewportContentModeDidChange,
            object: nil
        )
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    // MARK: - Content Mode → Toolbar Adaptation

    @objc private func handleContentModeChanged(_ notification: Notification) {
        guard let rawMode = notification.userInfo?[NotificationUserInfoKey.contentMode] as? String,
              let mode = ViewportContentMode(rawValue: rawMode) else { return }
        guard mode != currentContentMode else { return }

        currentContentMode = mode
        updateToolbarForContentMode(mode)
    }

    /// Updates toolbar item visibility based on the viewport content mode.
    ///
    /// Genomics-specific tools (translation, chromosome drawer) are hidden when
    /// the viewport shows FASTQ or metagenomics content. The inspector toggle
    /// and operations button are always visible.
    private func updateToolbarForContentMode(_ mode: ViewportContentMode) {
        guard let toolbar = window?.toolbar else { return }

        for item in toolbar.items {
            switch item.itemIdentifier {
            case ToolbarIdentifier.translateTool:
                // Translation is only relevant for genomic sequences
                let visible = (mode == .genomics || mode == .empty)
                item.isHidden = !visible
                item.isEnabled = visible

            case ToolbarIdentifier.toggleChromosomeDrawer:
                // Chromosome drawer is only relevant for genomic bundles
                let visible = (mode == .genomics || mode == .empty)
                item.isHidden = !visible
                item.isEnabled = visible

            case ToolbarIdentifier.toggleAnnotationDrawer:
                // Bottom drawer is relevant for genomics (annotations) and metagenomics (BLAST/samples)
                let visible = (mode != .empty)
                item.isHidden = !visible
                item.isEnabled = visible

                // Update tooltip based on mode
                if mode == .metagenomics {
                    item.toolTip = "Show or hide the BLAST/samples drawer"
                } else if mode == .fastq {
                    item.toolTip = "Show or hide the metadata drawer"
                } else {
                    item.toolTip = "Show or hide the bottom metadata drawer"
                }

            default:
                break
            }
        }
    }

    // MARK: - Bundle Loaded → Index Building

    @objc private func handleBundleLoaded(_ notification: Notification) {
        guard let userInfo = notification.userInfo,
              let chromosomes = userInfo[NotificationUserInfoKey.chromosomes] as? [ChromosomeInfo] else { return }

        // Build annotation search index on background thread
        guard let viewerController = mainSplitViewController?.viewerController,
              let bundle = viewerController.viewerView?.currentReferenceBundle else { return }

        let index = AnnotationSearchIndex()
        annotationSearchIndex = index

        // Set callback to populate annotation drawer and inspector when index is ready
        let inspectorController = mainSplitViewController?.inspectorController
        index.onBuildComplete = { [weak self, weak viewerController, weak inspectorController] in
            guard let self, let viewerController else { return }
            viewerController.annotationSearchIndex = self.annotationSearchIndex
            // Wire annotation database to inspector selection view model for qualifier enrichment
            inspectorController?.selectionSectionViewModel.annotationDatabase = self.annotationSearchIndex?.annotationDatabase
            // Wire reference bundle for on-the-fly CDS translation computation
            inspectorController?.selectionSectionViewModel.referenceBundle = viewerController.viewerView?.currentReferenceBundle
            // Populate variant types in the inspector's annotation section
            if let variantTypes = self.annotationSearchIndex?.variantTypes, !variantTypes.isEmpty {
                inspectorController?.annotationSectionViewModel.setAvailableVariantTypes(variantTypes)
            }
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
        toolbar.allowsUserCustomization = false
        toolbar.autosavesConfiguration = true

        window.toolbar = toolbar
    }

    // MARK: - Toolbar Button Helper

    /// Creates an NSButton suitable for use as a toolbar item view.
    /// Uses SF Symbols with fallback chain for cross-version compatibility.
    private func makeToolbarImage(symbolName: String, fallbacks: [String], accessibilityLabel: String) -> NSImage {
        let candidates = [symbolName] + fallbacks + ["questionmark.circle", "line.3.horizontal", "square.grid.2x2"]
        for name in candidates {
            if let image = NSImage(systemSymbolName: name, accessibilityDescription: accessibilityLabel) {
                image.isTemplate = true
                return image
            }
        }
        let generated = NSImage(size: NSSize(width: 14, height: 14), flipped: false) { _ in
            let path = NSBezierPath(ovalIn: NSRect(x: 1, y: 1, width: 12, height: 12))
            NSColor.labelColor.setStroke()
            path.lineWidth = 1.5
            path.stroke()
            return true
        }
        generated.isTemplate = true
        return generated
    }

    private func makeToolbarButton(
        symbolName: String,
        fallbacks: [String],
        accessibilityLabel: String,
        accessibilityIdentifier: String
    ) -> NSButton {
        let button = NSButton(frame: NSRect(x: 0, y: 0, width: 38, height: 24))
        button.setButtonType(.momentaryPushIn)
        button.bezelStyle = .toolbar
        button.image = makeToolbarImage(symbolName: symbolName, fallbacks: fallbacks, accessibilityLabel: accessibilityLabel)
        button.imagePosition = .imageOnly
        button.isContinuous = false
        button.sendAction(on: [.leftMouseUp])
        button.setAccessibilityLabel(accessibilityLabel)
        button.setAccessibilityIdentifier(accessibilityIdentifier)
        return button
    }

    // MARK: - Panel Toggle Actions

    @objc public func toggleSidebar(_ sender: Any?) {
        mainSplitViewController.toggleSidebar()
    }

    @objc public func toggleInspector(_ sender: Any?) {
        let senderType = sender.map { String(describing: type(of: $0)) } ?? "nil"
        let now = ProcessInfo.processInfo.systemUptime
        let event = NSApp.currentEvent
        let eventType = event.map { String(describing: $0.type) } ?? "nil"
        let eventNumber = event?.eventNumber
        let clickCount = event?.clickCount ?? 0

        if let eventNumber, lastInspectorToggleEventNumber == eventNumber {
            logger.debug("toggleInspector: duplicate action ignored sender=\(senderType, privacy: .public) eventType=\(eventType, privacy: .public) eventNumber=\(eventNumber) clickCount=\(clickCount)")
            return
        }

        if now - lastInspectorToggleActionTime < 0.25 {
            logger.debug("toggleInspector: duplicate action ignored sender=\(senderType, privacy: .public) eventType=\(eventType, privacy: .public) dt=\(now - self.lastInspectorToggleActionTime, privacy: .public)")
            return
        }

        lastInspectorToggleActionTime = now
        lastInspectorToggleEventNumber = eventNumber
        logger.debug("toggleInspector: sender=\(senderType, privacy: .public) eventType=\(eventType, privacy: .public) eventNumber=\(eventNumber.map(String.init) ?? "nil", privacy: .public) clickCount=\(clickCount) keyWindow=\((self.window?.isKeyWindow == true) ? "true" : "false", privacy: .public)")
        mainSplitViewController.toggleInspector(source: "MainWindowController.toggleInspector")
    }

    @objc public func toggleChromosomeDrawer(_ sender: Any?) {
        mainSplitViewController.viewerController?.toggleChromosomeDrawer()
    }

    @objc public func toggleAnnotationDrawer(_ sender: Any?) {
        let vc = mainSplitViewController.viewerController
        vc?.toggleAnnotationDrawer()

        // Update toolbar button highlight based on drawer state
        let isOpen: Bool
        if let taxTriageVC = vc?.taxTriageViewController {
            isOpen = taxTriageVC.isBlastDrawerOpen
        } else if let taxVC = vc?.taxonomyViewController {
            isOpen = taxVC.isTaxaCollectionsDrawerOpen
        } else if vc?.isDisplayingFASTQDataset == true {
            isOpen = vc?.isFASTQMetadataDrawerOpen ?? false
        } else {
            isOpen = vc?.isAnnotationDrawerOpen ?? false
        }
        drawerToolbarButton?.state = isOpen ? .on : .off
    }

    /// Opens the Operations Panel via AppDelegate's action handler.
    @objc public func showOperationsPanel(_ sender: Any?) {
        // Send directly to the AppDelegate to avoid infinite recursion —
        // this method has the same selector name, so sendAction with nil target
        // would find us again in the responder chain.
        (NSApp.delegate as? AppDelegate)?.showOperationsPanel(sender)
    }

    // MARK: - Translation Tool

    @objc public func showTranslationTool(_ sender: Any?) {
        guard let window = window else { return }
        // Don't open a second sheet if one is already attached
        if window.attachedSheet != nil { return }

        let sheetWindow = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 480),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )

        var toolView = TranslationToolView()
        toolView.onApply = { [weak self, weak sheetWindow] config in
            guard let sheetWindow else { return }
            window.endSheet(sheetWindow)
            guard let viewerView = self?.mainSplitViewController.viewerController?.viewerView else { return }
            viewerView.translationColorScheme = config.colorScheme
            viewerView.translationShowStopCodons = config.showStopCodons
            if config.frames.isEmpty {
                viewerView.hideTranslation()
            } else {
                viewerView.applyFrameTranslation(frames: config.frames, table: config.codonTable)
            }
        }
        toolView.onCancel = { [weak sheetWindow] in
            guard let sheetWindow else { return }
            window.endSheet(sheetWindow)
        }

        sheetWindow.contentViewController = NSHostingController(rootView: toolView)
        window.beginSheet(sheetWindow)
    }

    // MARK: - Navigation Actions

    @objc public func zoomIn(_ sender: Any?) {
        mainSplitViewController.viewerController?.zoomIn()
    }

    @objc public func zoomOut(_ sender: Any?) {
        mainSplitViewController.viewerController?.zoomOut()
    }

    @objc public func zoomToFit(_ sender: Any?) {
        mainSplitViewController.viewerController?.zoomToFit()
    }

}

// MARK: - NSWindowDelegate

extension MainWindowController: NSWindowDelegate {

    public func windowWillEnterFullScreen(_ notification: Notification) {
        // Invalidate the annotation tile before the transition so it doesn't
        // persist at the old (smaller) window size during the animation.
        mainSplitViewController?.viewerController?.invalidateAnnotationTile()
    }

    public func windowDidEnterFullScreen(_ notification: Notification) {
        // After full-screen transition completes, force redraw so the
        // viewer fills the entire screen and the reference frame width is updated.
        //
        // Important: do not reorder/reactivate the window here; forcing
        // makeKeyAndOrderFront/activate during this transition can interfere with
        // AppKit's full-screen space management and leave a letterboxed/black state.
        mainSplitViewController?.viewerController?.forceFullRedraw()
    }

    public func windowDidExitFullScreen(_ notification: Notification) {
        // Same treatment when leaving full screen.
        // Do not force window ordering; AppKit restores key/main status.
        mainSplitViewController?.viewerController?.forceFullRedraw()
    }

    public func windowDidBecomeKey(_ notification: Notification) {
        // When the window becomes key (e.g., switching back to the app),
        // ensure the annotation tile is current — it may have been
        // invalidated while the window was in the background.
        mainSplitViewController?.viewerController?.forceFullRedraw()
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
            item.toolTip = "Show or hide the sidebar"
            let button = makeToolbarButton(
                symbolName: "sidebar.leading",
                fallbacks: ["sidebar.left", "sidebar.squares.leading", "list.bullet"],
                accessibilityLabel: "Toggle Sidebar",
                accessibilityIdentifier: AccessibilityIdentifier.toggleSidebar
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
                accessibilityLabel: "Toggle Inspector",
                accessibilityIdentifier: AccessibilityIdentifier.toggleInspector
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
                accessibilityLabel: "Toggle Chromosome Drawer",
                accessibilityIdentifier: AccessibilityIdentifier.toggleChromosomeDrawer
            )
            button.target = self
            button.action = #selector(toggleChromosomeDrawer(_:))
            item.view = button
            return item

        case ToolbarIdentifier.toggleAnnotationDrawer:
            let item = NSToolbarItem(itemIdentifier: itemIdentifier)
            item.label = "Drawer"
            item.paletteLabel = "Toggle Bottom Drawer"
            item.toolTip = "Show or hide the bottom metadata drawer"
            let button = makeToolbarButton(
                symbolName: "tablecells",
                fallbacks: ["tablecells.badge.ellipsis", "list.dash"],
                accessibilityLabel: "Toggle Bottom Drawer",
                accessibilityIdentifier: AccessibilityIdentifier.toggleAnnotationDrawer
            )
            button.target = self
            button.action = #selector(toggleAnnotationDrawer(_:))
            button.setButtonType(.pushOnPushOff)
            item.view = button
            drawerToolbarButton = button
            return item

        case ToolbarIdentifier.translateTool:
            let item = NSToolbarItem(itemIdentifier: itemIdentifier)
            item.label = "Translate"
            item.paletteLabel = "Translation Tool"
            item.toolTip = "Open the translation tool"
            let button = makeToolbarButton(
                symbolName: "character.textbox",
                fallbacks: ["textformat.abc", "text.alignleft"],
                accessibilityLabel: "Translation Tool",
                accessibilityIdentifier: AccessibilityIdentifier.translateTool
            )
            button.target = self
            button.action = #selector(showTranslationTool(_:))
            item.view = button
            return item

        case ToolbarIdentifier.operations:
            let item = NSToolbarItem(itemIdentifier: itemIdentifier)
            item.label = "Operations"
            item.paletteLabel = "Operations"
            item.toolTip = "Show operations and activity"
            let button = makeToolbarButton(
                symbolName: "list.bullet.rectangle.portrait",
                fallbacks: ["list.bullet.rectangle", "list.bullet"],
                accessibilityLabel: "Operations",
                accessibilityIdentifier: AccessibilityIdentifier.operations
            )
            button.target = self
            button.action = #selector(showOperationsPanel(_:))
            item.view = button
            return item

        default:
            return nil
        }
    }

    public func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [
            ToolbarIdentifier.toggleSidebar,
            ToolbarIdentifier.toggleChromosomeDrawer,
            ToolbarIdentifier.flexibleSpace,
            ToolbarIdentifier.translateTool,
            ToolbarIdentifier.flexibleSpace,
            ToolbarIdentifier.operations,
            ToolbarIdentifier.flexibleSpace,
            ToolbarIdentifier.toggleAnnotationDrawer,
            ToolbarIdentifier.flexibleSpace,
            ToolbarIdentifier.toggleInspector,
        ]
    }

    public func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [
            ToolbarIdentifier.toggleSidebar,
            ToolbarIdentifier.toggleInspector,
            ToolbarIdentifier.toggleChromosomeDrawer,
            ToolbarIdentifier.toggleAnnotationDrawer,
            ToolbarIdentifier.translateTool,
            ToolbarIdentifier.operations,
            ToolbarIdentifier.flexibleSpace,
        ]
    }
}
