// MainSplitViewController.swift - Three-panel split view controller
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import LungfishCore
import os.log

/// Logger for main split view operations
private let logger = Logger(subsystem: "com.lungfish.browser", category: "MainSplitViewController")


/// The main split view controller managing sidebar, viewer, and inspector panels.
///
/// Layout:
/// ```
/// +------------+----------------------------+----------+
/// |  Sidebar   |         Viewer             | Inspector|
/// |  (toggle)  |    (always visible)        | (toggle) |
/// +------------+----------------------------+----------+
/// ```
@MainActor
public class MainSplitViewController: NSSplitViewController {

    // MARK: - Child View Controllers

    /// The sidebar panel (project/file navigation)
    public private(set) var sidebarController: SidebarViewController!

    /// The main viewer panel (sequence/tracks)
    public private(set) var viewerController: ViewerViewController!

    /// The inspector panel (selection details)
    public private(set) var inspectorController: InspectorViewController!

    // MARK: - Split View Items

    private var sidebarItem: NSSplitViewItem!
    private var viewerItem: NSSplitViewItem!
    private var inspectorItem: NSSplitViewItem!

    // MARK: - Configuration

    /// Minimum sidebar width
    private let sidebarMinWidth: CGFloat = 180
    /// Default sidebar width
    private let sidebarDefaultWidth: CGFloat = 220
    /// Maximum sidebar width
    private let sidebarMaxWidth: CGFloat = 350

    /// Minimum inspector width
    private let inspectorMinWidth: CGFloat = 200
    /// Default inspector width
    private let inspectorDefaultWidth: CGFloat = 280
    /// Maximum inspector width
    private let inspectorMaxWidth: CGFloat = 450

    /// Minimum viewer width
    private let viewerMinWidth: CGFloat = 400

    // MARK: - Lifecycle

    public override func viewDidLoad() {
        super.viewDidLoad()
        logger.info("viewDidLoad: MainSplitViewController loading")
        configureSplitView()
        configureChildControllers()
        configureKeyboardShortcuts()
        configureNotifications()
        restorePanelState()
        logger.info("viewDidLoad: MainSplitViewController setup complete")
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    // MARK: - Configuration

    private func configureSplitView() {
        // Use thin dividers for modern look
        splitView.dividerStyle = .thin

        // Vertical splits (side by side)
        splitView.isVertical = true

        // Autosave configuration
        splitView.autosaveName = "MainSplitView"
    }

    private func configureChildControllers() {
        // Create child view controllers
        sidebarController = SidebarViewController()
        viewerController = ViewerViewController()
        inspectorController = InspectorViewController()
        logger.info("configureChildControllers: Created all three view controllers")

        // Create split view items with appropriate behaviors

        // Sidebar: collapsible, sidebar behavior for vibrancy
        sidebarItem = NSSplitViewItem(sidebarWithViewController: sidebarController)
        sidebarItem.canCollapse = true
        sidebarItem.minimumThickness = sidebarMinWidth
        sidebarItem.maximumThickness = sidebarMaxWidth
        sidebarItem.preferredThicknessFraction = 0.15
        sidebarItem.holdingPriority = .defaultLow + 1
        sidebarItem.collapseBehavior = .preferResizingSplitViewWithFixedSiblings

        // Viewer: always visible, takes remaining space
        viewerItem = NSSplitViewItem(viewController: viewerController)
        viewerItem.canCollapse = false
        viewerItem.minimumThickness = viewerMinWidth
        viewerItem.holdingPriority = .defaultLow

        // Inspector: collapsible, using regular viewController instead of inspector
        // (inspectorWithViewController has issues with layout)
        inspectorItem = NSSplitViewItem(viewController: inspectorController)
        inspectorItem.canCollapse = true
        inspectorItem.minimumThickness = inspectorMinWidth
        inspectorItem.maximumThickness = inspectorMaxWidth
        inspectorItem.preferredThicknessFraction = 0.2
        inspectorItem.holdingPriority = .defaultLow + 1
        inspectorItem.collapseBehavior = .default

        // Add items in order: sidebar, viewer, inspector
        addSplitViewItem(sidebarItem)
        addSplitViewItem(viewerItem)
        addSplitViewItem(inspectorItem)
        logger.info("configureChildControllers: Added all three split view items, count=\(self.splitViewItems.count)")

        // Inspector starts collapsed by default
        inspectorItem.isCollapsed = true
        logger.info("configureChildControllers: Inspector initial state isCollapsed=\(self.inspectorItem.isCollapsed)")
    }

    private func configureKeyboardShortcuts() {
        // Keyboard shortcuts are handled by menu items with key equivalents
        // See MainMenu.swift for menu configuration
    }

    private func configureNotifications() {
        // Listen for sidebar selection changes
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleSidebarSelectionChanged(_:)),
            name: .sidebarSelectionChanged,
            object: nil
        )

        // Listen for document loaded notifications
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleDocumentLoaded(_:)),
            name: DocumentManager.documentLoadedNotification,
            object: nil
        )

        // Listen for show inspector requests (e.g., from edit annotation action)
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleShowInspector(_:)),
            name: NSNotification.Name("showInspector"),
            object: nil
        )

        logger.debug("configureNotifications: Registered for sidebar, document, and inspector notifications")
    }

    @objc private func handleShowInspector(_ notification: Notification) {
        logger.info("handleShowInspector: Showing inspector panel")
        setInspectorVisible(true, animated: true)
    }

    @objc private func handleSidebarSelectionChanged(_ notification: Notification) {
        // Check for empty selection (viewer should be cleared)
        if let items = notification.userInfo?["items"] as? [SidebarItem], items.isEmpty {
            logger.info("handleSidebarSelectionChanged: Selection cleared, clearing viewer")
            viewerController.clearViewer()
            return
        }

        // Check for multi-selection first (new behavior)
        if let items = notification.userInfo?["items"] as? [SidebarItem], items.count > 1 {
            handleMultipleItemsSelected(items)
            return
        }

        // Fall back to single item handling (backward compatibility)
        guard let item = notification.userInfo?["item"] as? SidebarItem else {
            logger.warning("handleSidebarSelectionChanged: No item in notification")
            return
        }

        logger.info("handleSidebarSelectionChanged: Selected '\(item.title, privacy: .public)' type=\(String(describing: item.type))")

        // Skip folder/project items - they don't have displayable content
        if item.type == .folder || item.type == .project || item.type == .group {
            logger.debug("handleSidebarSelectionChanged: Skipping container item type")
            return
        }

        // If the item has a URL, check if already loaded first
        if let url = item.url {
            // First check if document is already loaded to avoid re-loading
            if let existingDocument = DocumentManager.shared.documents.first(where: { $0.url == url }) {
                logger.info("handleSidebarSelectionChanged: Document already loaded, displaying directly")
                viewerController.displayDocument(existingDocument)
                DocumentManager.shared.setActiveDocument(existingDocument)
                return
            }

            // Not loaded yet, load it
            logger.info("handleSidebarSelectionChanged: Loading document from '\(url.path, privacy: .public)'")
            Task { @MainActor in
                viewerController.showProgress("Loading \(url.lastPathComponent)...")
                do {
                    let document = try await DocumentManager.shared.loadDocument(at: url)
                    viewerController.hideProgress()
                    viewerController.displayDocument(document)
                    logger.info("handleSidebarSelectionChanged: Document loaded and displayed")
                } catch {
                    viewerController.hideProgress()
                    logger.error("handleSidebarSelectionChanged: Failed to load document: \(error.localizedDescription, privacy: .public)")
                    let alert = NSAlert()
                    alert.messageText = "Failed to Open File"
                    alert.informativeText = error.localizedDescription
                    alert.alertStyle = .warning
                    alert.addButton(withTitle: "OK")
                    alert.runModal()
                }
            }
        } else if item.type == .sequence || item.type == .annotation || item.type == .alignment {
            // Check if this is a document that's already loaded (by name match)
            logger.debug("handleSidebarSelectionChanged: Checking for already loaded document matching '\(item.title, privacy: .public)'")
            if let document = DocumentManager.shared.documents.first(where: { $0.name == item.title }) {
                logger.info("handleSidebarSelectionChanged: Found matching document by name, displaying")
                viewerController.displayDocument(document)
                DocumentManager.shared.setActiveDocument(document)
            }
        }
    }

    /// Handles multiple sidebar items being selected.
    ///
    /// This method collects sequences from all selected documents and displays them
    /// stacked in the viewer using multi-sequence support.
    ///
    /// - Parameter items: Array of selected sidebar items
    private func handleMultipleItemsSelected(_ items: [SidebarItem]) {
        // Filter to only sequence-type items that can be displayed
        let displayableItems = items.filter { item in
            item.type == .sequence || item.type == .annotation || item.type == .alignment
        }

        guard !displayableItems.isEmpty else {
            logger.debug("handleMultipleItemsSelected: No displayable items in selection")
            return
        }

        let itemNames = displayableItems.map { $0.title }.joined(separator: ", ")
        logger.info("handleMultipleItemsSelected: Processing \(displayableItems.count) items: [\(itemNames, privacy: .public)]")

        // Collect URLs that need to be loaded
        var urlsToLoad: [URL] = []
        var alreadyLoadedDocuments: [LoadedDocument] = []

        for item in displayableItems {
            if let url = item.url {
                // Check if already loaded
                if let existingDoc = DocumentManager.shared.documents.first(where: { $0.url == url }) {
                    alreadyLoadedDocuments.append(existingDoc)
                } else {
                    urlsToLoad.append(url)
                }
            } else if let doc = DocumentManager.shared.documents.first(where: { $0.name == item.title }) {
                // Found by name
                alreadyLoadedDocuments.append(doc)
            }
        }

        // If we have URLs to load, do it asynchronously
        if !urlsToLoad.isEmpty {
            Task { @MainActor in
                viewerController.showProgress("Loading \(urlsToLoad.count) documents...")

                var loadedDocs = alreadyLoadedDocuments

                for url in urlsToLoad {
                    do {
                        let document = try await DocumentManager.shared.loadDocument(at: url)
                        loadedDocs.append(document)
                        logger.debug("handleMultipleItemsSelected: Loaded '\(document.name, privacy: .public)'")
                    } catch {
                        logger.error("handleMultipleItemsSelected: Failed to load \(url.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)")
                    }
                }

                viewerController.hideProgress()

                // Display all documents with multi-sequence stacking
                if !loadedDocs.isEmpty {
                    viewerController.displayDocuments(loadedDocs)
                    logger.info("handleMultipleItemsSelected: Displayed \(loadedDocs.count) documents with multi-sequence stacking")
                }
            }
        } else if !alreadyLoadedDocuments.isEmpty {
            // All documents already loaded, display immediately
            viewerController.displayDocuments(alreadyLoadedDocuments)
            logger.info("handleMultipleItemsSelected: Displayed \(alreadyLoadedDocuments.count) already-loaded documents")
        }
    }

    @objc private func handleDocumentLoaded(_ notification: Notification) {
        guard let document = notification.userInfo?["document"] as? LoadedDocument else {
            logger.warning("handleDocumentLoaded: No document in notification")
            return
        }

        logger.info("handleDocumentLoaded: Document '\(document.name, privacy: .public)' was loaded, updating sidebar")

        // Update the sidebar with the new document
        sidebarController.addLoadedDocument(document)
    }

    // MARK: - Panel State

    private func savePanelState() {
        let defaults = UserDefaults.standard
        defaults.set(sidebarItem.isCollapsed, forKey: "SidebarCollapsed")
        defaults.set(inspectorItem.isCollapsed, forKey: "InspectorCollapsed")
    }

    private func restorePanelState() {
        let defaults = UserDefaults.standard

        // Restore sidebar state (default: visible)
        if defaults.object(forKey: "SidebarCollapsed") != nil {
            sidebarItem.isCollapsed = defaults.bool(forKey: "SidebarCollapsed")
        }

        // Restore inspector state (default: collapsed)
        if defaults.object(forKey: "InspectorCollapsed") != nil {
            inspectorItem.isCollapsed = defaults.bool(forKey: "InspectorCollapsed")
        }
    }

    // MARK: - Public API

    /// Toggles the sidebar visibility with animation.
    public func toggleSidebar() {
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.2
            context.allowsImplicitAnimation = true
            sidebarItem.animator().isCollapsed.toggle()
        } completionHandler: { [weak self] in
            Task { @MainActor in
                self?.savePanelState()
            }
        }
    }

    /// Toggles the inspector visibility with animation.
    public func toggleInspector() {
        logger.info("toggleInspector: isCollapsed=\(self.inspectorItem.isCollapsed)")

        let shouldExpand = self.inspectorItem.isCollapsed

        if shouldExpand {
            // Expanding: set isCollapsed to false and manually position the divider
            // to ensure proper layout
            self.inspectorItem.isCollapsed = false
            let inspectorWidth = inspectorDefaultWidth
            let totalWidth = splitView.frame.width
            let targetPosition = totalWidth - inspectorWidth

            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.25
                context.allowsImplicitAnimation = true
                self.splitView.animator().setPosition(targetPosition, ofDividerAt: 1)
            } completionHandler: { [weak self] in
                self?.savePanelState()
                logger.info("toggleInspector: expand complete")
            }
        } else {
            // Collapsing: animate to edge then set collapsed
            let totalWidth = splitView.frame.width

            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.2
                context.allowsImplicitAnimation = true
                self.splitView.animator().setPosition(totalWidth, ofDividerAt: 1)
            } completionHandler: { [weak self] in
                self?.inspectorItem.isCollapsed = true
                self?.savePanelState()
                logger.info("toggleInspector: collapse complete")
            }
        }
    }

    /// Shows or hides the sidebar.
    public func setSidebarVisible(_ visible: Bool, animated: Bool = true) {
        guard sidebarItem.isCollapsed == visible else { return }

        if animated {
            toggleSidebar()
        } else {
            sidebarItem.isCollapsed = !visible
            savePanelState()
        }
    }

    /// Shows or hides the inspector.
    public func setInspectorVisible(_ visible: Bool, animated: Bool = true) {
        guard inspectorItem.isCollapsed == visible else { return }

        if animated {
            toggleInspector()
        } else {
            inspectorItem.isCollapsed = !visible
            savePanelState()
        }
    }

    /// Whether the sidebar is currently visible.
    public var isSidebarVisible: Bool {
        !sidebarItem.isCollapsed
    }

    /// Whether the inspector is currently visible.
    public var isInspectorVisible: Bool {
        !inspectorItem.isCollapsed
    }

    // MARK: - NSSplitViewDelegate

    public override func splitView(
        _ splitView: NSSplitView,
        canCollapseSubview subview: NSView
    ) -> Bool {
        // Allow collapsing sidebar and inspector
        if subview == sidebarController.view {
            return true
        }
        if subview == inspectorController.view {
            return true
        }
        return false
    }

    public override func splitViewDidResizeSubviews(_ notification: Notification) {
        // Placeholder for future toolbar tracking separator updates if needed
    }
}

// MARK: - Accessibility

extension MainSplitViewController {

    public func getAccessibilityLabel() -> String {
        "Main content area"
    }

    public func getAccessibilityChildren() -> [NSView] {
        [sidebarController.view, viewerController.view, inspectorController.view]
    }
}
