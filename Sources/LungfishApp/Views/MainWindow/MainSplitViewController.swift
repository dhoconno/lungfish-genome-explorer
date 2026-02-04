// MainSplitViewController.swift - Three-panel split view controller
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import LungfishCore
import os.log

/// Logger for main split view operations
private let logger = Logger(subsystem: "com.lungfish.browser", category: "MainSplitViewController")

/// Options for handling duplicate files during import
enum DuplicateResolution {
    case replace    // Replace the existing file
    case keepBoth   // Keep both files (rename the new one)
    case skip       // Skip importing, use existing file
}

/// The main split view controller managing sidebar, viewer, and inspector panels.
///
/// Layout:
/// ```
/// +------------+----------------------------+----------+
/// |  Sidebar   |         Viewer             | Inspector|
/// |  (toggle)  |    (always visible)        | (toggle) |
/// +------------+----------------------------+----------+
/// |            Activity Indicator Bar                   |
/// +-----------------------------------------------------+
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

    /// The shared activity indicator for showing progress across the app
    public private(set) var activityIndicator: ActivityIndicatorView!

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
        configureActivityIndicator()
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

    private func configureActivityIndicator() {
        // Create and add the activity indicator at the bottom of the view
        activityIndicator = ActivityIndicatorView()
        view.addSubview(activityIndicator)

        NSLayoutConstraint.activate([
            activityIndicator.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            activityIndicator.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            activityIndicator.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])

        logger.info("configureActivityIndicator: Activity indicator configured")
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

        // Inspector: collapsible, using inspectorWithViewController for macOS 26 Liquid Glass support
        // This provides proper system-standard inspector behavior including translucent materials
        inspectorItem = NSSplitViewItem(inspectorWithViewController: inspectorController)
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

        // Listen for project opened notifications
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleProjectOpened(_:)),
            name: DocumentManager.projectOpenedNotification,
            object: nil
        )

        // Listen for show inspector requests (e.g., from edit annotation action)
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleShowInspector(_:)),
            name: NSNotification.Name("showInspector"),
            object: nil
        )

        // Listen for file drops on the sidebar
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleSidebarFileDropped(_:)),
            name: .sidebarFileDropped,
            object: nil
        )

        logger.info("configureNotifications: Registered for sidebar, document, file drop, and inspector notifications")
        logger.info("configureNotifications: sidebarFileDropped observer registered for name '\(Notification.Name.sidebarFileDropped.rawValue)'")
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
        
        // Check if this is a QuickLook-previewed file type (document, image, unknown)
        if item.type.usesQuickLook, let url = item.url {
            logger.info("handleSidebarSelectionChanged: Using QuickLook preview for '\(item.title, privacy: .public)'")
            viewerController.displayQuickLookPreview(url: url)
            return
        }

        // If the item has a URL, check if already loaded first
        if let url = item.url {
            // First check if document is already registered
            if let existingDocument = DocumentManager.shared.documents.first(where: { $0.url == url }) {
                // Check if the document has been fully loaded (has sequences or annotations)
                let isFullyLoaded = !existingDocument.sequences.isEmpty || !existingDocument.annotations.isEmpty

                if isFullyLoaded {
                    logger.info("handleSidebarSelectionChanged: Document already loaded, displaying directly")
                    viewerController.displayDocument(existingDocument)
                    DocumentManager.shared.setActiveDocument(existingDocument)
                    return
                }

                // Document is registered but not fully loaded (placeholder) - trigger lazy load
                logger.info("handleSidebarSelectionChanged: Document is placeholder, triggering lazy load")
                guard let docType = DocumentType.detect(from: url) else {
                    logger.error("handleSidebarSelectionChanged: Could not detect document type")
                    return
                }

                Task.detached(priority: .userInitiated) {
                    await MainActor.run {
                        self.viewerController.showProgress("Loading \(url.lastPathComponent)...")
                    }

                    do {
                        let result = try await DocumentLoader.loadFile(at: url, type: docType)
                        await MainActor.run {
                            existingDocument.sequences = result.sequences
                            existingDocument.annotations = result.annotations
                            self.viewerController.hideProgress()
                            self.viewerController.displayDocument(existingDocument)
                            DocumentManager.shared.setActiveDocument(existingDocument)
                            self.sidebarController.refreshItem(for: url)
                            logger.info("handleSidebarSelectionChanged: Lazy load complete, displayed")
                        }
                    } catch {
                        await MainActor.run {
                            self.viewerController.hideProgress()
                            logger.error("handleSidebarSelectionChanged: Lazy load failed: \(error.localizedDescription, privacy: .public)")
                            let alert = NSAlert()
                            alert.messageText = "Failed to Open File"
                            alert.informativeText = error.localizedDescription
                            alert.alertStyle = .warning
                            alert.addButton(withTitle: "OK")
                            alert.runModal()
                        }
                    }
                }
                return
            }

            // Document not registered yet, load via DocumentManager
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

        // Categorize documents: fully loaded, placeholders (need lazy load), or unregistered
        var fullyLoadedDocuments: [LoadedDocument] = []
        var placeholderDocuments: [(LoadedDocument, URL, DocumentType)] = []
        var unregisteredURLs: [(URL, DocumentType)] = []

        for item in displayableItems {
            if let url = item.url {
                if let existingDoc = DocumentManager.shared.documents.first(where: { $0.url == url }) {
                    // Check if fully loaded
                    let isFullyLoaded = !existingDoc.sequences.isEmpty || !existingDoc.annotations.isEmpty
                    if isFullyLoaded {
                        fullyLoadedDocuments.append(existingDoc)
                    } else if let docType = DocumentType.detect(from: url) {
                        placeholderDocuments.append((existingDoc, url, docType))
                    }
                } else if let docType = DocumentType.detect(from: url) {
                    unregisteredURLs.append((url, docType))
                }
            } else if let doc = DocumentManager.shared.documents.first(where: { $0.name == item.title }) {
                fullyLoadedDocuments.append(doc)
            }
        }

        let needsLoading = !placeholderDocuments.isEmpty || !unregisteredURLs.isEmpty

        // If we have documents to load, do it asynchronously
        if needsLoading {
            // Use a regular Task (not detached) to maintain MainActor isolation
            Task { @MainActor [weak self] in
                guard let self = self else { return }

                let totalToLoad = placeholderDocuments.count + unregisteredURLs.count
                self.viewerController.showProgress("Loading \(totalToLoad) documents...")

                // Start with already-loaded documents
                var loadedDocs = fullyLoadedDocuments

                // Load placeholder documents via DocumentLoader
                for (existingDoc, url, docType) in placeholderDocuments {
                    do {
                        let result = try await DocumentLoader.loadFile(at: url, type: docType)
                        existingDoc.sequences = result.sequences
                        existingDoc.annotations = result.annotations
                        loadedDocs.append(existingDoc)
                        self.sidebarController.refreshItem(for: url)
                        logger.debug("handleMultipleItemsSelected: Lazy loaded '\(existingDoc.name, privacy: .public)'")
                    } catch {
                        logger.error("handleMultipleItemsSelected: Failed to lazy load \(url.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)")
                    }
                }

                // Load unregistered documents via DocumentManager
                for (url, _) in unregisteredURLs {
                    do {
                        let document = try await DocumentManager.shared.loadDocument(at: url)
                        loadedDocs.append(document)
                        logger.debug("handleMultipleItemsSelected: Loaded '\(document.name, privacy: .public)'")
                    } catch {
                        logger.error("handleMultipleItemsSelected: Failed to load \(url.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)")
                    }
                }

                self.viewerController.hideProgress()

                // Display all documents with multi-sequence stacking
                if !loadedDocs.isEmpty {
                    self.viewerController.displayDocuments(loadedDocs)
                    logger.info("handleMultipleItemsSelected: Displayed \(loadedDocs.count) documents with multi-sequence stacking")
                }
            }
        } else if !fullyLoadedDocuments.isEmpty {
            // All documents already loaded, display immediately
            viewerController.displayDocuments(fullyLoadedDocuments)
            logger.info("handleMultipleItemsSelected: Displayed \(fullyLoadedDocuments.count) already-loaded documents")
        }
    }

    @objc private func handleDocumentLoaded(_ notification: Notification) {
        guard let document = notification.userInfo?["document"] as? LoadedDocument else {
            logger.warning("handleDocumentLoaded: No document in notification")
            return
        }

        logger.info("handleDocumentLoaded: Document '\(document.name, privacy: .public)' was loaded")

        // With the filesystem-backed sidebar model:
        // - Files inside the project are shown via FileSystemWatcher (no manual add needed)
        // - Files outside the project can optionally be shown in "Open Documents"
        // For now, only add to sidebar if NOT inside the current project
        if let projectURL = sidebarController.currentProjectURL {
            let docPath = document.url.standardizedFileURL.path
            let projectPath = projectURL.standardizedFileURL.path
            if docPath.hasPrefix(projectPath) {
                // File is inside project - FileSystemWatcher will handle sidebar refresh
                logger.debug("handleDocumentLoaded: File is inside project, sidebar updated via FileSystemWatcher")
                return
            }
        }
        
        // File is outside project - add to "Open Documents" section (legacy behavior)
        sidebarController.addLoadedDocument(document)
    }

    @objc private func handleProjectOpened(_ notification: Notification) {
        guard let project = notification.userInfo?["project"] as? ProjectFile else {
            logger.warning("handleProjectOpened: No project in notification")
            return
        }

        logger.info("handleProjectOpened: Project '\(project.name, privacy: .public)' was opened")

        // Use the new filesystem-backed sidebar model
        // This will scan the project directory and set up file watching
        sidebarController.openProject(at: project.url)

        // Display the first document if available, otherwise show empty state
        let documents = DocumentManager.shared.documents
        if let firstDoc = documents.first {
            viewerController?.hideProgress()
            viewerController?.displayDocument(firstDoc)
            logger.info("handleProjectOpened: Displaying first document '\(firstDoc.name, privacy: .public)'")
        } else {
            // Empty project - show clear "No sequence selected" state
            viewerController?.showNoSequenceSelected()
            logger.info("handleProjectOpened: Empty project, showing 'No sequence selected' state")
        }
    }

    @objc private func handleSidebarFileDropped(_ notification: Notification) {
        logger.info("handleSidebarFileDropped: Notification received!")
        logger.info("handleSidebarFileDropped: userInfo = \(String(describing: notification.userInfo))")
        
        guard let url = notification.userInfo?["url"] as? URL else {
            logger.warning("handleSidebarFileDropped: No URL in notification userInfo")
            return
        }

        logger.info("handleSidebarFileDropped: Processing dropped file '\(url.lastPathComponent, privacy: .public)' at path '\(url.path, privacy: .public)'")

        // Determine destination - use the new filesystem-backed project URL
        let destinationItem = notification.userInfo?["destination"] as? SidebarItem
        var urlToLoad = url

        // Get project URL from either the sidebar (new model) or DocumentManager (legacy)
        let projectURL = sidebarController.currentProjectURL ?? DocumentManager.shared.activeProject?.url
        
        // If we have an active project, copy the file there
        if let projectURL = projectURL {
            // Determine the target directory based on the destination item
            let targetDir: URL
            if let destItem = destinationItem, destItem.type == .folder, let folderURL = destItem.url {
                // Drop onto a folder - use that folder
                targetDir = folderURL
            } else {
                // Drop onto project root or no specific destination - use project root
                targetDir = projectURL
            }

            // Create target directory if needed
            let fileManager = FileManager.default
            if !fileManager.fileExists(atPath: targetDir.path) {
                do {
                    try fileManager.createDirectory(at: targetDir, withIntermediateDirectories: true)
                    logger.debug("handleSidebarFileDropped: Created target directory: \(targetDir.path, privacy: .public)")
                } catch {
                    logger.error("handleSidebarFileDropped: Failed to create target directory: \(error.localizedDescription, privacy: .public)")
                }
            }

            // Copy file to project
            let destinationURL = targetDir.appendingPathComponent(url.lastPathComponent)
            if !fileManager.fileExists(atPath: destinationURL.path) {
                do {
                    try fileManager.copyItem(at: url, to: destinationURL)
                    urlToLoad = destinationURL
                    logger.info("handleSidebarFileDropped: Copied file to project at \(destinationURL.path, privacy: .public)")
                    // Explicitly refresh sidebar since DispatchSource may not detect all changes
                    sidebarController.reloadFromFilesystem()
                } catch {
                    logger.error("handleSidebarFileDropped: Failed to copy file: \(error.localizedDescription, privacy: .public)")
                    // Continue with original URL
                }
            } else {
                // File already exists - prompt user for action
                logger.info("handleSidebarFileDropped: File '\(url.lastPathComponent, privacy: .public)' already exists, prompting user")
                
                let resolution = showDuplicateFileDialog(filename: url.lastPathComponent)
                switch resolution {
                case .replace:
                    // Replace existing file
                    do {
                        try fileManager.removeItem(at: destinationURL)
                        try fileManager.copyItem(at: url, to: destinationURL)
                        urlToLoad = destinationURL
                        logger.info("handleSidebarFileDropped: Replaced existing file")
                        sidebarController.reloadFromFilesystem()
                    } catch {
                        logger.error("handleSidebarFileDropped: Failed to replace file: \(error.localizedDescription, privacy: .public)")
                    }
                case .keepBoth:
                    // Generate unique name and copy
                    let uniqueURL = generateUniqueFilename(for: url, in: targetDir)
                    do {
                        try fileManager.copyItem(at: url, to: uniqueURL)
                        urlToLoad = uniqueURL
                        logger.info("handleSidebarFileDropped: Created copy with unique name: \(uniqueURL.lastPathComponent, privacy: .public)")
                        sidebarController.reloadFromFilesystem()
                    } catch {
                        logger.error("handleSidebarFileDropped: Failed to copy with unique name: \(error.localizedDescription, privacy: .public)")
                    }
                case .skip:
                    // Use existing file
                    urlToLoad = destinationURL
                    logger.info("handleSidebarFileDropped: Using existing file")
                }
            }
        }
        
        // Load the document and display it
        Task { @MainActor in
            viewerController.showProgress("Loading \(urlToLoad.lastPathComponent)...")
            do {
                let document = try await DocumentManager.shared.loadDocument(at: urlToLoad)
                viewerController.hideProgress()
                viewerController.displayDocument(document)
                // Note: Sidebar is now filesystem-backed, so FileSystemWatcher will refresh it
                // when the file is copied. No manual sidebar update needed.
                logger.info("handleSidebarFileDropped: Successfully loaded and displayed '\(document.name, privacy: .public)'")
            } catch {
                viewerController.hideProgress()
                logger.error("handleSidebarFileDropped: Failed to load file: \(error.localizedDescription, privacy: .public)")
                let alert = NSAlert()
                alert.messageText = "Failed to Open File"
                alert.informativeText = error.localizedDescription
                alert.alertStyle = .warning
                alert.addButton(withTitle: "OK")
                alert.runModal()
            }
        }
    }

    // MARK: - Duplicate File Handling

    /// Shows a dialog asking the user how to handle a duplicate file
    private func showDuplicateFileDialog(filename: String) -> DuplicateResolution {
        let alert = NSAlert()
        alert.messageText = "File Already Exists"
        alert.informativeText = "A file named \"\(filename)\" already exists in this location. What would you like to do?"
        alert.alertStyle = .warning
        
        alert.addButton(withTitle: "Replace")    // First button = index 1000
        alert.addButton(withTitle: "Keep Both")  // Second button = index 1001
        alert.addButton(withTitle: "Skip")       // Third button = index 1002
        
        let response = alert.runModal()
        
        switch response {
        case .alertFirstButtonReturn:  // Replace
            return .replace
        case .alertSecondButtonReturn: // Keep Both
            return .keepBoth
        default:                       // Skip or Cancel
            return .skip
        }
    }

    /// Generates a unique filename by appending a number suffix
    private func generateUniqueFilename(for sourceURL: URL, in targetDir: URL) -> URL {
        let baseName = sourceURL.deletingPathExtension().lastPathComponent
        let ext = sourceURL.pathExtension
        var counter = 1
        var newURL = targetDir.appendingPathComponent("\(baseName) 2.\(ext)")
        
        while FileManager.default.fileExists(atPath: newURL.path) {
            counter += 1
            newURL = targetDir.appendingPathComponent("\(baseName) \(counter + 1).\(ext)")
        }
        
        return newURL
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
                Task { @MainActor in
                    self?.savePanelState()
                    logger.info("toggleInspector: expand complete")
                }
            }
        } else {
            // Collapsing: animate to edge then set collapsed
            let totalWidth = splitView.frame.width

            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.2
                context.allowsImplicitAnimation = true
                self.splitView.animator().setPosition(totalWidth, ofDividerAt: 1)
            } completionHandler: { [weak self] in
                Task { @MainActor in
                    self?.inspectorItem.isCollapsed = true
                    self?.savePanelState()
                    logger.info("toggleInspector: collapse complete")
                }
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
