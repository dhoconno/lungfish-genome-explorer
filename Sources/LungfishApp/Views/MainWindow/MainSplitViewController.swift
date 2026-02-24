// MainSplitViewController.swift - Three-panel split view controller
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import LungfishCore
import LungfishIO
import os.log

/// Logger for main split view operations
private let logger = Logger(subsystem: "com.lungfish.browser", category: "MainSplitViewController")

/// Dispatches a @MainActor block on the GCD main queue using assumeIsolated.
/// Needed in Task.detached contexts where cooperative executor scheduling is unreliable.
private func performOnMainRunLoop(_ block: @escaping @MainActor @Sendable () -> Void) {
    DispatchQueue.main.async {
        MainActor.assumeIsolated {
            block()
        }
    }
}

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

    // MARK: - Inspector Toggle State

    /// True while an inspector collapse/expand animation is in progress.
    private var inspectorTransitionInFlight = false

    /// Queued collapsed state requested while an animation is running.
    private var queuedInspectorCollapsedState: Bool?

    /// Monotonic serial for guarding completion/fallback callbacks.
    private var inspectorTransitionSerial: Int = 0

    /// Uptime timestamp when the current inspector transition began.
    private var inspectorTransitionStartTime: TimeInterval = 0

    /// Collapsed target for the active inspector transition.
    private var inspectorTransitionTargetCollapsedState: Bool?

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
        // Floating activity indicator positioned above the bottom of the viewer area.
        // Uses z-order above split view content to avoid NSSplitView clipping on macOS 26.
        activityIndicator = ActivityIndicatorView()
        view.addSubview(activityIndicator, positioned: .above, relativeTo: nil)

        NSLayoutConstraint.activate([
            activityIndicator.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            activityIndicator.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -40),
            activityIndicator.widthAnchor.constraint(lessThanOrEqualToConstant: 500),
            activityIndicator.widthAnchor.constraint(greaterThanOrEqualToConstant: 280),
        ])

        logger.info("configureActivityIndicator: Activity indicator configured")
    }

    private func configureChildControllers() {
        // Create child view controllers
        sidebarController = SidebarViewController()
        viewerController = ViewerViewController()
        inspectorController = InspectorViewController()
        _ = inspectorController.view
        logger.info("configureChildControllers: Created all three view controllers")

        // Set up delegate for direct selection handling (avoids async Task issues)
        sidebarController.selectionDelegate = self

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

        // Inspector starts visible by default
        inspectorItem.isCollapsed = false
        logger.info("configureChildControllers: Inspector initial state isCollapsed=\(self.inspectorItem.isCollapsed)")
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
            name: .showInspectorRequested,
            object: nil
        )

        // Listen for file drops on the sidebar
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleSidebarFileDropped(_:)),
            name: .sidebarFileDropped,
            object: nil
        )

        // Show inspector when a reference bundle is loaded
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleBundleDidLoad(_:)),
            name: .bundleDidLoad,
            object: nil
        )

        // Show inspector with chromosome details when requested from chromosome navigator
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleChromosomeInspectorRequested(_:)),
            name: .chromosomeInspectorRequested,
            object: nil
        )

        logger.info("configureNotifications: Registered for sidebar, document, file drop, bundle, inspector, and chromosome inspector notifications")
        logger.info("configureNotifications: sidebarFileDropped observer registered for name '\(Notification.Name.sidebarFileDropped.rawValue)'")
    }

    @objc private func handleShowInspector(_ notification: Notification) {
        let tab = notification.userInfo?[NotificationUserInfoKey.inspectorTab] as? String
        logger.info("handleShowInspector: Showing inspector panel, tab=\(tab ?? "default", privacy: .public)")
        setInspectorVisible(true, animated: false, source: "notification.showInspectorRequested")
        // Tab switching is handled by InspectorViewController observing the same notification
    }

    @objc private func handleBundleDidLoad(_ notification: Notification) {
        logger.info("handleBundleDidLoad: Bundle loaded, ensuring inspector is visible")
        setInspectorVisible(true, animated: false, source: "notification.bundleDidLoad")
    }

    @objc private func handleChromosomeInspectorRequested(_ notification: Notification) {
        logger.info("handleChromosomeInspectorRequested: Showing inspector for chromosome")
        setInspectorVisible(true, animated: false, source: "notification.chromosomeInspectorRequested")
        // Chromosome details are handled by InspectorViewController observing the same notification
    }

    @objc private func handleSidebarSelectionChanged(_ notification: Notification) {
        // NOTE: Document loading is now handled by SidebarSelectionDelegate (sidebarDidSelectItem).
        // This notification handler is kept only for other observers (e.g., InspectorViewController)
        // that may need to know about selection changes but don't load documents.
        //
        // DO NOT add document loading code here - it will cause Swift Task execution issues.
        // See SWIFT-CONCURRENCY-APPKIT-MODAL.md for details.

        logger.debug("handleSidebarSelectionChanged: Notification received (delegate handles loading)")
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

        // Restore inspector state (default: visible)
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
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated {
                    self?.savePanelState()
                }
            }
        }
    }

    /// Toggles the inspector visibility with animation.
    public func toggleInspector(source: String = "api.toggleInspector") {
        let beforeCollapsed = inspectorItem.isCollapsed
        let targetVisible = beforeCollapsed
        logger.info("toggleInspector[\(source, privacy: .public)]: pressed (isCollapsed=\(beforeCollapsed), targetVisible=\(targetVisible))")
        setInspectorVisible(targetVisible, animated: false, source: source)
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
    public func setInspectorVisible(_ visible: Bool, animated: Bool = true, source: String = "api.setInspectorVisible") {
        let targetCollapsedState = !visible
        let now = ProcessInfo.processInfo.systemUptime
        logger.info(
            "setInspectorVisible[\(source, privacy: .public)]: requested visible=\(visible), animated=\(animated), currentIsCollapsed=\(self.inspectorItem.isCollapsed), targetIsCollapsed=\(targetCollapsedState), inFlight=\(self.inspectorTransitionInFlight)"
        )

        if inspectorTransitionInFlight {
            let transitionAge = now - inspectorTransitionStartTime
            if transitionAge > 0.8 {
                logger.error(
                    "setInspectorVisible[\(source, privacy: .public)]: stale in-flight transition detected age=\(transitionAge, privacy: .public)s target=\(String(describing: self.inspectorTransitionTargetCollapsedState), privacy: .public); forcing recovery"
                )
                inspectorTransitionInFlight = false
                inspectorTransitionTargetCollapsedState = nil
                queuedInspectorCollapsedState = nil
            } else {
            if queuedInspectorCollapsedState == targetCollapsedState {
                logger.info(
                    "animateInspectorCollapse[\(source, privacy: .public)]: in-flight, duplicate queued target ignored isCollapsed=\(targetCollapsedState)"
                )
            } else {
                queuedInspectorCollapsedState = targetCollapsedState
                logger.info(
                    "animateInspectorCollapse[\(source, privacy: .public)]: in-flight, queued target isCollapsed=\(targetCollapsedState)"
                )
            }
            return
            }
        }

        guard inspectorItem.isCollapsed != targetCollapsedState else {
            logger.info("setInspectorVisible[\(source, privacy: .public)]: no-op (already at target)")
            if visible {
                // Keep inspector controls and viewer state synchronized even if no
                // split-view transition was needed.
                inspectorController.inspectorVisibilityDidChange(isVisible: true)
            }
            return
        }

        if animated {
            animateInspectorCollapse(to: targetCollapsedState, source: source)
        } else {
            inspectorItem.isCollapsed = targetCollapsedState
            queuedInspectorCollapsedState = nil
            finalizeInspectorVisibilityChange(source: source)
        }
    }

    /// Runs an inspector collapse/expand animation, serializing concurrent requests.
    private func animateInspectorCollapse(to targetCollapsedState: Bool, source: String) {
        inspectorTransitionInFlight = true
        inspectorTransitionSerial += 1
        inspectorTransitionStartTime = ProcessInfo.processInfo.systemUptime
        inspectorTransitionTargetCollapsedState = targetCollapsedState
        let serial = inspectorTransitionSerial

        logger.info(
            "animateInspectorCollapse[\(source, privacy: .public)]: start from isCollapsed=\(self.inspectorItem.isCollapsed) to isCollapsed=\(targetCollapsedState)"
        )

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.25
            context.allowsImplicitAnimation = true
            self.inspectorItem.animator().isCollapsed = targetCollapsedState
        } completionHandler: { [weak self] in
            logger.info("animateInspectorCollapse[\(source, privacy: .public)]: completion callback fired for serial=\(serial)")
            DispatchQueue.main.async { [weak self] in
                self?.completeInspectorCollapseAnimation(serial: serial, source: "\(source).completion")
            }
        }

        // Fallback finalization path for cases where AppKit doesn't invoke
        // split-view animation completion callbacks reliably.
        // Uses GCD timer (not Task.sleep) to guarantee main-thread scheduling
        // even during AppKit animation/layout cycles.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
            MainActor.assumeIsolated {
                logger.info("animateInspectorCollapse[\(source, privacy: .public)]: fallback callback fired for serial=\(serial)")
                self?.completeInspectorCollapseAnimation(serial: serial, source: "\(source).fallback")
            }
        }
    }

    /// Completes an inspector animation exactly once for a transition serial.
    private func completeInspectorCollapseAnimation(serial: Int, source: String) {
        guard serial == inspectorTransitionSerial else {
            logger.debug(
                "completeInspectorCollapseAnimation[\(source, privacy: .public)]: stale serial \(serial) (current=\(self.inspectorTransitionSerial)), ignoring"
            )
            return
        }

        guard inspectorTransitionInFlight else {
            logger.debug(
                "completeInspectorCollapseAnimation[\(source, privacy: .public)]: already finalized"
            )
            return
        }

        inspectorTransitionInFlight = false
        inspectorTransitionTargetCollapsedState = nil
        finalizeInspectorVisibilityChange(source: source)

        guard let queuedTarget = queuedInspectorCollapsedState else { return }
        queuedInspectorCollapsedState = nil

        guard queuedTarget != inspectorItem.isCollapsed else {
            logger.info(
                "animateInspectorCollapse[\(source, privacy: .public)]: queued target already satisfied isCollapsed=\(queuedTarget)"
            )
            return
        }

        logger.info(
            "animateInspectorCollapse[\(source, privacy: .public)]: applying queued target isCollapsed=\(queuedTarget)"
        )
        animateInspectorCollapse(to: queuedTarget, source: "queued")
    }

    /// Persists state and notifies inspector after visibility transitions.
    private func finalizeInspectorVisibilityChange(source: String) {
        savePanelState()
        inspectorController.inspectorVisibilityDidChange(isVisible: !inspectorItem.isCollapsed)
        logger.info(
            "finalizeInspectorVisibilityChange[\(source, privacy: .public)]: isCollapsed=\(self.inspectorItem.isCollapsed), queued=\(String(describing: self.queuedInspectorCollapsedState), privacy: .public)"
        )
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
        guard inspectorTransitionInFlight else { return }
        guard let targetCollapsed = inspectorTransitionTargetCollapsedState else { return }
        guard inspectorItem.isCollapsed == targetCollapsed else { return }

        logger.info(
            "splitViewDidResizeSubviews: transition reached target isCollapsed=\(targetCollapsed), forcing completion"
        )
        completeInspectorCollapseAnimation(
            serial: inspectorTransitionSerial,
            source: "splitViewDidResizeSubviews"
        )
    }
}

// MARK: - SidebarSelectionDelegate

extension MainSplitViewController: SidebarSelectionDelegate {

    public func sidebarDidSelectItem(_ item: SidebarItem?) {
        guard let item = item else {
            logger.info("sidebarDidSelectItem: Selection cleared, clearing viewer")
            viewerController.clearBundleDisplay()
            viewerController.clearViewer()
            return
        }

        displayContent(for: item)
    }

    public func sidebarDidSelectItems(_ items: [SidebarItem]) {
        // Filter to displayable items
        let displayableItems = items.filter { item in
            item.type != .folder && item.type != .project && item.type != .group
        }

        guard !displayableItems.isEmpty else { return }

        if displayableItems.count == 1 {
            displayContent(for: displayableItems[0])
        } else {
            // Multi-selection - delegate to existing handler
            handleMultipleItemsSelected(displayableItems)
        }
    }

    /// Unified content dispatch - synchronous for reliability.
    ///
    /// This method handles all content display decisions synchronously,
    /// avoiding Swift Task issues that occur when called from notification handlers.
    private func displayContent(for item: SidebarItem) {
        logger.info("displayContent: Selected '\(item.title, privacy: .public)' type=\(String(describing: item.type))")

        // Skip non-displayable container types
        guard item.type != .folder && item.type != .project && item.type != .group else {
            logger.debug("displayContent: Skipping container item type")
            return
        }

        // When switching away from a bundle to a non-bundle item, clean up the navigator
        if item.type != .referenceBundle {
            viewerController.clearBundleDisplay()
        }

        // QuickLook preview for document, image, unknown types
        if item.type.usesQuickLook, let url = item.url {
            logger.info("displayContent: Using QuickLook preview for '\(item.title, privacy: .public)'")
            viewerController.displayQuickLookPreview(url: url)
            return
        }

        // Reference genome bundles (.lungfishref)
        if item.type == .referenceBundle, let url = item.url {
            displayReferenceBundle(at: url)
            return
        }

        // Genomics files - check cache first
        if let url = item.url {
            displayGenomicsFile(url: url)
        } else if item.type == .sequence || item.type == .annotation || item.type == .alignment {
            // Check for already-loaded document by name
            if let document = DocumentManager.shared.documents.first(where: { $0.name == item.title }) {
                logger.info("displayContent: Found matching document by name, displaying")
                viewerController.displayDocument(document)
                DocumentManager.shared.setActiveDocument(document)
            }
        }
    }

    /// Display reference bundle using the ViewerViewController's bundle display system.
    ///
    /// This method delegates to `ViewerViewController.displayBundle(at:)` which handles:
    /// - Loading and validating the bundle manifest
    /// - Creating a `BundleDataProvider` for on-demand data access
    /// - Showing a `ChromosomeNavigatorView` for chromosome selection
    /// - Setting up the `ReferenceFrame` for the first chromosome
    /// - Configuring the `SequenceViewerView` for on-demand rendering
    private func displayReferenceBundle(at url: URL) {
        if viewerController.currentBundleDataProvider != nil,
           viewerController.currentBundleURL?.standardizedFileURL == url.standardizedFileURL {
            logger.debug("displayReferenceBundle: '\(url.lastPathComponent, privacy: .public)' already displayed, skipping reload")
            viewerController.openAnnotationDrawerIfBundleHasData()
            return
        }

        logger.info("displayReferenceBundle: Opening '\(url.lastPathComponent, privacy: .public)'")

        do {
            try viewerController.displayBundle(at: url)
            logger.info("displayReferenceBundle: Bundle displayed successfully")
        } catch {
            logger.error("displayReferenceBundle: Failed - \(error.localizedDescription, privacy: .public)")
            let alert = NSAlert()
            alert.messageText = "Failed to Open Reference Bundle"
            alert.informativeText = error.localizedDescription
            alert.alertStyle = .warning
            alert.addButton(withTitle: "OK")
            alert.runModal()
        }
    }

    /// Display genomics file - cache-first, then load via DocumentManager.
    private func displayGenomicsFile(url: URL) {
        // FASTQ files use the streaming statistics dashboard (not bulk loading)
        if isFASTQFile(url) {
            loadFASTQDatasetInBackground(url: url)
            return
        }

        // Standalone VCF files use the VCF dataset dashboard
        if isVCFFile(url) {
            loadVCFDatasetInBackground(url: url)
            return
        }

        // Check if already loaded
        if let existingDocument = DocumentManager.shared.documents.first(where: { $0.url == url }) {
            let isFullyLoaded = !existingDocument.sequences.isEmpty || !existingDocument.annotations.isEmpty

            if isFullyLoaded {
                logger.info("displayGenomicsFile: Document cached, displaying directly")
                viewerController.displayDocument(existingDocument)
                DocumentManager.shared.setActiveDocument(existingDocument)
                return
            }
        }

        // Not cached - load via DocumentManager using GCD wrapper
        loadGenomicsFileInBackground(url: url)
    }

    /// Returns true if the URL points to a FASTQ file (by extension).
    private func isFASTQFile(_ url: URL) -> Bool {
        var checkURL = url
        if checkURL.pathExtension.lowercased() == "gz" {
            checkURL = checkURL.deletingPathExtension()
        }
        let ext = checkURL.pathExtension.lowercased()
        return ext == "fastq" || ext == "fq"
    }

    /// Returns true if the URL points to a VCF file (by extension).
    private func isVCFFile(_ url: URL) -> Bool {
        var checkURL = url
        if checkURL.pathExtension.lowercased() == "gz" {
            checkURL = checkURL.deletingPathExtension()
        }
        return checkURL.pathExtension.lowercased() == "vcf"
    }

    /// Loads a standalone VCF file and displays the VCF dataset dashboard.
    private func loadVCFDatasetInBackground(url: URL) {
        logger.info("loadVCFDatasetInBackground: Loading '\(url.lastPathComponent, privacy: .public)'")

        guard let viewerController = self.viewerController else {
            logger.warning("loadVCFDatasetInBackground: Viewer controller not available")
            return
        }

        viewerController.showProgress("Analyzing VCF file...")

        Task.detached(priority: .userInitiated) {
            do {
                let reader = VCFReader()
                let summary = try await reader.summarize(from: url)
                let variants = try await reader.readAll(from: url)

                DispatchQueue.main.async { [weak viewerController, weak self] in
                    MainActor.assumeIsolated {
                        viewerController?.hideProgress()
                        viewerController?.displayVCFDataset(
                            summary: summary,
                            variants: variants,
                            onDownloadReference: { [weak self] inferredRef in
                                self?.downloadReferenceForVCF(inferredRef, vcfURL: url)
                            }
                        )
                        logger.info("loadVCFDatasetInBackground: Dashboard displayed with \(summary.variantCount) variants")
                    }
                }
            } catch {
                let errorMessage = "\(error)"
                DispatchQueue.main.async { [weak viewerController] in
                    MainActor.assumeIsolated {
                        viewerController?.hideProgress()
                        logger.error("loadVCFDatasetInBackground: Failed - \(errorMessage)")

                        let alert = NSAlert()
                        alert.messageText = "Failed to Analyze VCF File"
                        alert.informativeText = errorMessage
                        alert.alertStyle = .warning
                        alert.addButton(withTitle: "OK")
                        alert.runModal()
                    }
                }
            }
        }
    }

    /// Handles "Download Reference" from the VCF dashboard.
    ///
    /// Searches NCBI for the inferred assembly, downloads FASTA + GFF3,
    /// and builds a .lungfishref bundle via DownloadCenter.
    private func downloadReferenceForVCF(_ inferredRef: ReferenceInference.Result, vcfURL: URL) {
        guard let assembly = inferredRef.assembly else {
            logger.warning("downloadReferenceForVCF: No assembly name in inferred reference")
            return
        }

        // Confirmation sheet
        let alert = NSAlert()
        alert.messageText = "Download Reference Genome"
        alert.informativeText = "Download the \(assembly) (\(inferredRef.organism ?? "")) reference genome from NCBI? This will create a bundle that can be used with your VCF file."
        alert.addButton(withTitle: "Download")
        alert.addButton(withTitle: "Cancel")
        alert.alertStyle = .informational

        guard alert.runModal() == .alertFirstButtonReturn else { return }

        // Search term: use accession if available, otherwise assembly name
        let searchTerm: String
        if let accession = inferredRef.accession {
            searchTerm = accession
        } else {
            searchTerm = "\(inferredRef.organism ?? assembly)[Organism] AND \(assembly)[Assembly Name]"
        }

        let downloadID = DownloadCenter.shared.start(
            title: "\(assembly) Reference",
            detail: "Searching NCBI..."
        )

        Task.detached {
            do {
                let ncbi = NCBIService()

                // Search for the assembly
                performOnMainRunLoop {
                    DownloadCenter.shared.update(id: downloadID, progress: 0.05, detail: "Searching NCBI for \(assembly)...")
                }

                let ids = try await ncbi.esearch(database: .assembly, term: searchTerm, retmax: 5)
                guard !ids.isEmpty else {
                    performOnMainRunLoop {
                        DownloadCenter.shared.fail(id: downloadID, detail: "No assembly found for '\(assembly)'")
                    }
                    return
                }

                // Get assembly summary
                performOnMainRunLoop {
                    DownloadCenter.shared.update(id: downloadID, progress: 0.1, detail: "Getting assembly info...")
                }

                let summaries = try await ncbi.assemblyEsummary(ids: ids)
                guard let assemblySummary = summaries.first else {
                    performOnMainRunLoop {
                        DownloadCenter.shared.fail(id: downloadID, detail: "No assembly details found")
                    }
                    return
                }

                // Download and build bundle
                performOnMainRunLoop {
                    DownloadCenter.shared.update(id: downloadID, progress: 0.15, detail: "Downloading genome files...")
                }

                let genomesDir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
                    .appendingPathComponent("Genomes", isDirectory: true)
                try? FileManager.default.createDirectory(at: genomesDir, withIntermediateDirectories: true)

                let viewModel = GenomeDownloadViewModel()
                let bundleURL = try await viewModel.downloadAndBuild(
                    assembly: assemblySummary,
                    outputDirectory: genomesDir
                ) { progress, message in
                    // Map 0.15-0.95 range for download+build phase
                    let scaledProgress = 0.15 + progress * 0.8
                    performOnMainRunLoop {
                        DownloadCenter.shared.update(id: downloadID, progress: scaledProgress, detail: message)
                    }
                }

                performOnMainRunLoop {
                    DownloadCenter.shared.complete(id: downloadID, detail: "Bundle ready", bundleURLs: [bundleURL])
                }

                logger.info("downloadReferenceForVCF: Bundle built at \(bundleURL.path, privacy: .public)")
            } catch {
                let errorMessage = "\(error)"
                performOnMainRunLoop {
                    DownloadCenter.shared.fail(id: downloadID, detail: errorMessage)
                }
                logger.error("downloadReferenceForVCF: Failed - \(errorMessage)")
            }
        }
    }

    /// Loads FASTQ file using the streaming statistics collector, then displays the dashboard.
    ///
    /// Checks for cached statistics in the sidecar metadata file first. If found,
    /// uses them directly (still loads sample records for the table). Otherwise,
    /// computes statistics in a single streaming pass and caches them.
    private func loadFASTQDatasetInBackground(url: URL) {
        logger.info("loadFASTQDatasetInBackground: Loading '\(url.lastPathComponent, privacy: .public)'")

        guard let viewerController = self.viewerController else {
            logger.warning("loadFASTQDatasetInBackground: Viewer controller not available")
            return
        }

        // Check for cached metadata
        let cachedMeta = FASTQMetadataStore.load(for: url)
        if let cachedStats = cachedMeta?.computedStatistics {
            logger.info("loadFASTQDatasetInBackground: Using cached statistics (\(cachedStats.readCount) reads)")
            viewerController.showProgress("Loading FASTQ sample records...")

            // Still need to load sample records for the table
            Task.detached(priority: .userInitiated) {
                do {
                    let reader = FASTQReader()
                    var sampleRecords: [FASTQRecord] = []
                    sampleRecords.reserveCapacity(10_000)
                    var count = 0
                    for try await record in reader.records(from: url) {
                        if count < 10_000 { sampleRecords.append(record) }
                        count += 1
                        if count >= 10_000 { break }
                    }

                    DispatchQueue.main.async {
                        MainActor.assumeIsolated {
                            viewerController.hideProgress()
                            viewerController.displayFASTQDataset(
                                statistics: cachedStats,
                                records: sampleRecords,
                                sraRunInfo: cachedMeta?.sraRunInfo,
                                enaReadRecord: cachedMeta?.enaReadRecord
                            )
                            logger.info("loadFASTQDatasetInBackground: Displayed from cache with \(sampleRecords.count) sample records")
                        }
                    }
                } catch {
                    let errorMessage = "\(error)"
                    DispatchQueue.main.async {
                        MainActor.assumeIsolated {
                            viewerController.hideProgress()
                            logger.error("loadFASTQDatasetInBackground: Failed to load samples - \(errorMessage)")
                        }
                    }
                }
            }
            return
        }

        viewerController.showProgress("Computing FASTQ statistics...")

        Task.detached(priority: .userInitiated) {
            do {
                let reader = FASTQReader()
                let (statistics, sampleRecords) = try await reader.computeStatistics(
                    from: url,
                    sampleLimit: 10_000,
                    progress: { count in
                        DispatchQueue.main.async {
                            MainActor.assumeIsolated {
                                viewerController.showProgress(
                                    "Computing FASTQ statistics... \(count) reads processed"
                                )
                            }
                        }
                    }
                )

                // Cache the computed statistics for next time
                var metadata = cachedMeta ?? PersistedFASTQMetadata()
                metadata.computedStatistics = statistics
                FASTQMetadataStore.save(metadata, for: url)

                let sraRunInfo = metadata.sraRunInfo
                let enaReadRecord = metadata.enaReadRecord
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        viewerController.hideProgress()
                        viewerController.displayFASTQDataset(
                            statistics: statistics,
                            records: sampleRecords,
                            sraRunInfo: sraRunInfo,
                            enaReadRecord: enaReadRecord
                        )
                        logger.info("loadFASTQDatasetInBackground: Dashboard displayed with \(statistics.readCount) total reads, \(sampleRecords.count) in table")
                    }
                }
            } catch {
                let errorMessage = "\(error)"
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        viewerController.hideProgress()
                        logger.error("loadFASTQDatasetInBackground: Failed - \(errorMessage)")

                        let alert = NSAlert()
                        alert.messageText = "Failed to Analyze FASTQ File"
                        alert.informativeText = errorMessage
                        alert.alertStyle = .warning
                        alert.addButton(withTitle: "OK")
                        alert.runModal()
                    }
                }
            }
        }
    }

    /// Loads a genomics file in the background using structured concurrency.
    private func loadGenomicsFileInBackground(url: URL) {
        logger.info("loadGenomicsFileInBackground: Loading '\(url.lastPathComponent, privacy: .public)'")

        // Guard that controllers are available
        guard let viewerController = self.viewerController,
              let sidebarController = self.sidebarController else {
            logger.warning("loadGenomicsFileInBackground: Controllers not available")
            return
        }

        viewerController.showProgress("Loading \(url.lastPathComponent)...")

        // Use detached task for background loading without inheriting actor context.
        // UI callbacks use GCD main queue + MainActor.assumeIsolated (not await MainActor.run)
        // because the cooperative executor doesn't reliably schedule from Task.detached.
        Task.detached(priority: .userInitiated) {
            do {
                let document = try await DocumentManager.shared.loadDocument(at: url)

                // Update UI via GCD main queue (guaranteed to drain)
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        viewerController.hideProgress()
                        viewerController.displayDocument(document)
                        sidebarController.refreshItem(for: url)
                        logger.info("loadGenomicsFileInBackground: Loaded and displayed")
                    }
                }
            } catch {
                let errorMessage = error.localizedDescription
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        viewerController.hideProgress()
                        logger.error("loadGenomicsFileInBackground: Failed - \(errorMessage)")

                        let alert = NSAlert()
                        alert.messageText = "Failed to Open File"
                        alert.informativeText = errorMessage
                        alert.alertStyle = .warning
                        alert.addButton(withTitle: "OK")
                        alert.runModal()
                    }
                }
            }
        }
    }
}
