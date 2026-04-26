// MainSplitViewController.swift - Three-panel split view controller
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import LungfishCore
import LungfishIO
import LungfishWorkflow
import os.log

/// Logger for main split view operations
private let logger = Logger(subsystem: LogSubsystem.app, category: "MainSplitViewController")

/// Dispatches a @MainActor block on the GCD main queue using assumeIsolated.
/// Needed in Task.detached contexts where cooperative executor scheduling is unreliable.
private func performOnMainRunLoop(_ block: @escaping @MainActor @Sendable () -> Void) {
    DispatchQueue.main.async {
        MainActor.assumeIsolated {
            block()
        }
    }
}

private extension FASTQOperationLaunchRequest {
    var primaryInputURL: URL? {
        switch self {
        case .refreshQCSummary(let inputURLs):
            return inputURLs.first
        case .derivative(_, let inputURLs, _):
            return inputURLs.first
        case .map(let inputURLs, _, _):
            return inputURLs.first
        case .assemble(let request, _):
            return request.inputURLs.first
        case .classify(_, let inputURLs, _):
            return inputURLs.first
        }
    }

    var outputMode: FASTQOperationOutputMode {
        switch self {
        case .refreshQCSummary:
            return .fixedBatch
        case .derivative(_, _, let outputMode):
            return outputMode
        case .map(_, _, let outputMode):
            return outputMode
        case .assemble(_, let outputMode):
            return outputMode
        case .classify:
            return .fixedBatch
        }
    }

    var isDemultiplexRequest: Bool {
        if case .derivative(let request, _, _) = self, case .demultiplex = request {
            return true
        }
        return false
    }

    var operationDisplayTitle: String {
        switch self {
        case .refreshQCSummary:
            return "FASTQ QC Summary"
        case .derivative(let request, _, _):
            return request.operationLabel
        case .map:
            return "Map Reads"
        case .assemble(let request, _):
            return request.tool.displayName
        case .classify(let tool, _, _):
            return tool.title
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
    nonisolated static let legacyShellAutosaveName = "MainSplitView"
    nonisolated static let sidebarCollapsedDefaultsKey = "SidebarCollapsed"
    nonisolated static let inspectorCollapsedDefaultsKey = "InspectorCollapsed"
    nonisolated static let sidebarWidthDefaultsKey = "WorkspaceShellSidebarWidth"
    nonisolated static let inspectorWidthDefaultsKey = "WorkspaceShellInspectorWidth"

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
    private var sidebarWidthConstraint: NSLayoutConstraint?
    private var inspectorWidthConstraint: NSLayoutConstraint?
    private var sidebarContainerView: NSView? { sidebarController?.view.superview }
    private var viewerContainerView: NSView? { viewerController?.view.superview }
    private var inspectorContainerView: NSView? { inspectorController?.view.superview }

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

    /// True once the initial persisted shell widths have been re-applied after layout.
    private var hasAppliedInitialShellLayout = false

    // MARK: - Selection State

    /// Monotonic generation counter for sidebar selection changes.
    ///
    /// Incremented every time a new sidebar item is selected. Background tasks
    /// capture this value and check it before updating the UI, discarding stale
    /// results when the user has moved on to a different selection.
    private var selectionGeneration: Int = 0

    /// Debounce work item for rapid sidebar selection changes.
    ///
    /// When the user clicks quickly through sidebar items (< 150ms between clicks),
    /// only the final selection is processed. This prevents unnecessary background
    /// loads and reduces main thread contention during rapid browsing.
    private var selectionDebounceWorkItem: DispatchWorkItem?

    /// Background task for multi-selection document loading.
    ///
    /// Cancelled whenever the selection moves on so stale collection loads
    /// cannot repaint the viewport after a tool result is displayed.
    private var multiDocumentLoadTask: Task<Void, Never>?

    // MARK: - FASTQ Loading State

    /// Background task for FASTQ statistics/sample loading.
    ///
    /// Cancelled whenever selection changes away from FASTQ content so stale
    /// progress updates cannot overwrite the active view.
    private var fastqLoadTask: Task<Void, Never>?

    /// Monotonic generation used to discard stale async FASTQ updates.
    private var fastqLoadGeneration: Int = 0

    /// FASTQ URL currently targeted by the active background load.
    private var activeFASTQLoadURL: URL?
    /// Original selected FASTQ source URL (bundle or raw FASTQ path).
    private var activeFASTQSourceURL: URL?

    // MARK: - Configuration

    /// Minimum sidebar width
    private let sidebarMinWidth: CGFloat = 180
    /// Default sidebar width
    private let sidebarDefaultWidth: CGFloat = 240
    /// Maximum sidebar width
    private let sidebarMaxWidth: CGFloat = 720

    /// Minimum inspector width
    private let inspectorMinWidth: CGFloat = 200
    /// Default inspector width
    private let inspectorDefaultWidth: CGFloat = 280
    /// Maximum inspector width
    private let inspectorMaxWidth: CGFloat = 450

    /// Minimum viewer width
    private let viewerMinWidth: CGFloat = 400

    private var pendingShellResizeEvent: WorkspaceShellLayoutCoordinator.Event = .shellDidResize
    private var isApplyingProgrammaticShellDividerMove = false
    private var programmaticShellResizeSuppressionDepth = 0
    private var pendingSidebarRevealRestore = false
    private var pendingInspectorRevealRestore = false
    private var pendingSidebarRevealWidth: CGFloat?
    private var pendingInspectorRevealWidth: CGFloat?

    private lazy var shellLayoutCoordinator = WorkspaceShellLayoutCoordinator(
        sidebarMinWidth: sidebarMinWidth,
        sidebarMaxWidth: sidebarMaxWidth,
        inspectorMinWidth: inspectorMinWidth,
        inspectorMaxWidth: inspectorMaxWidth,
        viewerMinWidth: viewerMinWidth
    )

    /// Tracks sidebar width recommendations versus explicit user drags.
    private let sidebarWidthCoordinator = SplitShellWidthCoordinator()

    // MARK: - Lifecycle

    public override func viewDidLoad() {
        super.viewDidLoad()
        logger.info("viewDidLoad: MainSplitViewController loading")
        configureSplitView()
        configureChildControllers()
        configureActivityIndicator()
        configureNotifications()
        restorePanelState()
        // One-time migration: clear stale split view autosave from broken TARIC configuration
        let autosaveMigrationKey = "com.lungfish.splitview.autosave.v2.migrated"
        if !UserDefaults.standard.bool(forKey: autosaveMigrationKey) {
            UserDefaults.standard.removeObject(
                forKey: "NSSplitView Subview Frames \(Self.legacyShellAutosaveName)"
            )
            UserDefaults.standard.set(true, forKey: autosaveMigrationKey)
        }

        logger.info("viewDidLoad: MainSplitViewController setup complete")
    }

    public override func viewDidLayout() {
        super.viewDidLayout()

        guard !hasAppliedInitialShellLayout else { return }
        hasAppliedInitialShellLayout = true
        performOnMainRunLoop { [weak self] in
            self?.restorePersistedShellLayout()
        }
    }

    public override func viewWillDisappear() {
        super.viewWillDisappear()
        invalidatePendingSelectionDebounce(reason: "controller teardown")
        cancelMultiDocumentLoadIfNeeded(hideProgress: false, reason: "controller teardown")
        cancelFASTQLoadIfNeeded(hideProgress: false, reason: "controller teardown")
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

        // Shell widths are user-owned and persisted explicitly rather than via NSSplitView autosave.
        splitView.autosaveName = nil
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
        let sidebarView = sidebarController.view
        sidebarView.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        sidebarView.setContentHuggingPriority(.defaultLow, for: .horizontal)
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
        sidebarWidthCoordinator.noteObservedWidth(sidebarDefaultWidth)
        logger.info("configureChildControllers: Added all three split view items, count=\(self.splitViewItems.count)")

        ensureShellWidthConstraints()

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

        // Listen for sidebar width recommendations based on current filename lengths.
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleSidebarPreferredWidthRecommended(_:)),
            name: .sidebarPreferredWidthRecommended,
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

        // Cancel any in-flight FASTQ load since we are switching to multi-select
        cancelFASTQLoadIfNeeded(hideProgress: true, reason: "multi-select")

        // Clear bundle display so collection view is unobstructed
        viewerController.clearBundleDisplay()
        viewerController.hideFASTACollectionView()
        viewerController.hideCollectionBackButton()

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
            multiDocumentLoadTask?.cancel()
            multiDocumentLoadTask = nil
            let generation = selectionGeneration

            // Use a regular Task (not detached) to maintain MainActor isolation
            multiDocumentLoadTask = Task { @MainActor [weak self] in
                guard let self = self else { return }

                let totalToLoad = placeholderDocuments.count + unregisteredURLs.count
                self.viewerController.showProgress("Loading \(totalToLoad) documents...")

                // Start with already-loaded documents
                var loadedDocs = fullyLoadedDocuments

                // Load placeholder documents via DocumentLoader
                for (existingDoc, url, docType) in placeholderDocuments {
                    guard !Task.isCancelled, self.selectionGeneration == generation else {
                        logger.info("handleMultipleItemsSelected: Discarding stale multi-select load before lazy load")
                        self.multiDocumentLoadTask = nil
                        return
                    }

                    do {
                        let result = try await DocumentLoader.loadFile(at: url, type: docType)
                        guard !Task.isCancelled, self.selectionGeneration == generation else {
                            logger.info("handleMultipleItemsSelected: Discarding stale multi-select load after lazy load")
                            self.multiDocumentLoadTask = nil
                            return
                        }
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
                    guard !Task.isCancelled, self.selectionGeneration == generation else {
                        logger.info("handleMultipleItemsSelected: Discarding stale multi-select load before document load")
                        self.multiDocumentLoadTask = nil
                        return
                    }

                    do {
                        let document = try await DocumentManager.shared.loadDocument(at: url)
                        guard !Task.isCancelled, self.selectionGeneration == generation else {
                            logger.info("handleMultipleItemsSelected: Discarding stale multi-select load after document load")
                            self.multiDocumentLoadTask = nil
                            return
                        }
                        loadedDocs.append(document)
                        logger.debug("handleMultipleItemsSelected: Loaded '\(document.name, privacy: .public)'")
                    } catch {
                        logger.error("handleMultipleItemsSelected: Failed to load \(url.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)")
                    }
                }

                guard !Task.isCancelled, self.selectionGeneration == generation else {
                    logger.info("handleMultipleItemsSelected: Discarding stale multi-select load before collection display")
                    self.multiDocumentLoadTask = nil
                    return
                }

                self.viewerController.hideProgress()
                self.multiDocumentLoadTask = nil

                if self.hasActiveSidebarChildViewport {
                    logger.info("handleMultipleItemsSelected: Skipping collection display — active child viewport already present")
                    return
                }

                // Display combined sequences from all documents in the collection view
                self.displayMultiDocumentCollection(loadedDocs)
            }
        } else if !fullyLoadedDocuments.isEmpty {
            // All documents already loaded, display immediately
            displayMultiDocumentCollection(fullyLoadedDocuments)
        }
    }

    /// Combines sequences from multiple documents and displays them in a
    /// ``FASTACollectionViewController`` with source file attribution.
    ///
    /// Each sequence is tagged with the name of the document it came from,
    /// allowing the user to see the origin of every sequence in the collection.
    ///
    /// - Parameter documents: The loaded documents to combine.
    private func displayMultiDocumentCollection(_ documents: [LoadedDocument]) {
        guard !documents.isEmpty else {
            logger.warning("displayMultiDocumentCollection: No documents provided")
            return
        }

        var allSequences: [LungfishCore.Sequence] = []
        var allAnnotations: [SequenceAnnotation] = []
        var sourceNames: [UUID: String] = [:]

        for document in documents {
            let sourceName = document.name
            for seq in document.sequences {
                sourceNames[seq.id] = sourceName
            }
            allSequences.append(contentsOf: document.sequences)
            allAnnotations.append(contentsOf: document.annotations)
            logger.debug("displayMultiDocumentCollection: Added \(document.sequences.count) sequences from '\(document.name, privacy: .public)'")
        }

        logger.info("displayMultiDocumentCollection: Total \(allSequences.count) sequences from \(documents.count) documents, \(allAnnotations.count) annotations")

        guard !allSequences.isEmpty else {
            logger.warning("displayMultiDocumentCollection: No sequences found in any document")
            return
        }

        viewerController.displayFASTACollection(
            sequences: allSequences,
            annotations: allAnnotations,
            sourceNames: sourceNames
        )
        recordUITestEvent("viewport.collection.displayed sequences=\(allSequences.count)")
        logger.info("displayMultiDocumentCollection: Displayed collection with \(allSequences.count) sequences from \(documents.count) files")
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
        // In multi-window mode, only the active main window should react to
        // DocumentManager's global project-opened notification.
        if AppDelegate.shared?.mainWindowController?.mainSplitViewController !== self {
            logger.debug("handleProjectOpened: Ignoring notification for non-active window")
            return
        }

        guard let project = notification.userInfo?["project"] as? ProjectFile else {
            logger.warning("handleProjectOpened: No project in notification")
            return
        }

        logger.info("handleProjectOpened: Project '\(project.name, privacy: .public)' was opened")

        // Update window title to reflect the project name
        let projectName = project.url.deletingPathExtension().lastPathComponent
        view.window?.title = "\(projectName) \u{2014} Lungfish Genome Explorer"

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

        // Support both new "urls" array format and legacy single "url" format
        let allURLs: [URL]
        if let urls = notification.userInfo?["urls"] as? [URL] {
            allURLs = urls
        } else if let url = notification.userInfo?["url"] as? URL {
            allURLs = [url]
        } else {
            logger.warning("handleSidebarFileDropped: No URLs in notification userInfo")
            return
        }
        let requestID = notification.userInfo?["requestID"] as? String

        logger.info("handleSidebarFileDropped: Processing \(allURLs.count) dropped file(s)")

        let importPlan = makeSidebarImportPlan(for: allURLs)
        let sourceURLs = importPlan.sourceURLs

        logger.info(
            "handleSidebarFileDropped: Expanded to \(sourceURLs.count) import source(s); autoDisplay=\(importPlan.shouldAutoDisplayImportedContent)"
        )

        guard !sourceURLs.isEmpty else {
            logger.warning("handleSidebarFileDropped: No importable sources found after expansion")
            return
        }

        // Determine destination - use the new filesystem-backed project URL
        let destinationItem = notification.userInfo?["destination"] as? SidebarItem

        // Get project URL from either the sidebar (new model) or DocumentManager (legacy)
        let projectURL = sidebarController.currentProjectURL ?? DocumentManager.shared.activeProject?.url

        // Determine the target directory based on the destination item
        let targetDir: URL = {
            if let projectURL {
                if let destItem = destinationItem, destItem.type == .folder, let folderURL = destItem.url {
                    return folderURL
                }
                return projectURL
            }
            return sourceURLs[0].deletingLastPathComponent()
        }()

        // Partition URLs into FASTQ files, ONT directories, and other files
        var fastqURLs: [URL] = []
        var otherURLs: [URL] = []

        for url in sourceURLs {
            if isONTDirectory(url) {
                importONTDirectoryInBackground(sourceURL: url, projectURL: targetDir, requestID: requestID)
            } else if FASTQBundle.isFASTQFileURL(url) {
                fastqURLs.append(url)
            } else {
                otherURLs.append(url)
            }
        }

        // FASTQ files: group into R1/R2 pairs and present import config sheet
        if !fastqURLs.isEmpty {
            let pairs = groupFASTQByPairs(fastqURLs)
            presentFASTQImportSheet(pairs: pairs, projectDirectory: targetDir, requestID: requestID)
        }

        // Non-FASTQ files: copy to project as before
        if !otherURLs.isEmpty {
            Task { @MainActor [weak self] in
                guard let self else { return }
                for url in otherURLs {
                    await self.importNonFASTQFile(
                        url: url,
                        projectURL: projectURL,
                        targetDir: targetDir,
                        requestID: requestID,
                        displayAfterImport: importPlan.shouldAutoDisplayImportedContent
                    )
                }
            }
        }
    }

    func makeSidebarImportPlan(for droppedURLs: [URL]) -> SidebarImportPlan {
        SidebarImportPlanner.makePlan(
            for: droppedURLs,
            ontDirectoryDetector: { [weak self] url in
                self?.isONTDirectory(url) ?? false
            }
        )
    }

    /// Imports a single non-FASTQ file, handling duplicate resolution via sheet.
    private func importNonFASTQFile(
        url: URL,
        projectURL: URL?,
        targetDir: URL,
        requestID: String?,
        displayAfterImport: Bool
    ) async {
        if ReferenceBundleImportService.isStandaloneReferenceSource(url) {
            guard let projectURL else {
                let errorMessage = "Open a project before importing standalone reference files."
                postSidebarFileDropCompleted(
                    requestID: requestID,
                    sourceURL: url,
                    success: false,
                    error: errorMessage
                )
                return
            }

            do {
                let refsDir = try ReferenceSequenceFolder.ensureFolder(in: projectURL)
                let cliCmd = OperationCenter.buildCLICommand(
                    subcommand: "import",
                    args: ["fasta", url.path, "--output-dir", refsDir.path]
                )
                let opID = OperationCenter.shared.start(
                    title: "Reference Import",
                    detail: "Importing \(url.lastPathComponent)...",
                    operationType: .bundleBuild,
                    cliCommand: cliCmd
                )

                let result = try await ReferenceBundleImportService.importAsReferenceBundleViaCLI(
                    sourceURL: url,
                    outputDirectory: refsDir
                ) { progress, message in
                    DispatchQueue.main.async {
                        MainActor.assumeIsolated {
                            OperationCenter.shared.update(
                                id: opID,
                                progress: progress,
                                detail: message
                            )
                        }
                    }
                }

                OperationCenter.shared.complete(
                    id: opID,
                    detail: "Imported \(result.bundleURL.lastPathComponent)"
                )
                sidebarController.reloadFromFilesystem()
                if displayAfterImport {
                    loadGenomicsFileInBackground(url: result.bundleURL)
                }
                postSidebarFileDropCompleted(
                    requestID: requestID,
                    sourceURL: url,
                    success: true,
                    error: nil
                )
            } catch {
                let errorMessage = error.localizedDescription
                logger.error(
                    "handleSidebarFileDropped: Reference helper import failed for \(url.lastPathComponent, privacy: .public): \(errorMessage, privacy: .public)"
                )
                postSidebarFileDropCompleted(
                    requestID: requestID,
                    sourceURL: url,
                    success: false,
                    error: errorMessage
                )
            }
            return
        }

        var urlToLoad = url
        var importSucceeded = true
        var importError: String?
        if projectURL != nil {
            let fileManager = FileManager.default
            if !fileManager.fileExists(atPath: targetDir.path) {
                try? fileManager.createDirectory(at: targetDir, withIntermediateDirectories: true)
            }

            let destinationURL = targetDir.appendingPathComponent(url.lastPathComponent)
            if !fileManager.fileExists(atPath: destinationURL.path) {
                do {
                    try fileManager.copyItem(at: url, to: destinationURL)
                    urlToLoad = destinationURL
                    logger.info("handleSidebarFileDropped: Copied file to project at \(destinationURL.path, privacy: .public)")
                    sidebarController.reloadFromFilesystem()
                } catch {
                    logger.error("handleSidebarFileDropped: Failed to copy file: \(error.localizedDescription, privacy: .public)")
                    importSucceeded = false
                    importError = error.localizedDescription
                }
            } else {
                let resolution = await showDuplicateFileDialog(filename: url.lastPathComponent)
                switch resolution {
                case .replace:
                    do {
                        try fileManager.removeItem(at: destinationURL)
                        try fileManager.copyItem(at: url, to: destinationURL)
                        urlToLoad = destinationURL
                        sidebarController.reloadFromFilesystem()
                    } catch {
                        logger.error("handleSidebarFileDropped: Failed to replace file: \(error.localizedDescription, privacy: .public)")
                        importSucceeded = false
                        importError = error.localizedDescription
                    }
                case .keepBoth:
                    let uniqueURL = generateUniqueFilename(for: url, in: targetDir)
                    do {
                        try fileManager.copyItem(at: url, to: uniqueURL)
                        urlToLoad = uniqueURL
                        sidebarController.reloadFromFilesystem()
                    } catch {
                        logger.error("handleSidebarFileDropped: Failed to copy with unique name: \(error.localizedDescription, privacy: .public)")
                        importSucceeded = false
                        importError = error.localizedDescription
                    }
                case .skip:
                    urlToLoad = destinationURL
                }
            }
        }

        // Standalone VCF files use the auto-ingestion pipeline (handled by displayGenomicsFile)
        if displayAfterImport {
            loadGenomicsFileInBackground(url: urlToLoad)
        }
        postSidebarFileDropCompleted(requestID: requestID, sourceURL: url, success: importSucceeded, error: importError)
    }

    // MARK: - FASTQ Import Sheet

    /// Presents the FASTQ import configuration sheet for the given file pairs.
    private func presentFASTQImportSheet(pairs: [FASTQFilePair], projectDirectory: URL, requestID: String?) {
        guard let window = view.window else {
            // Fallback: import first pair with defaults if no window for sheet
            for pair in pairs {
                importFASTQFileInBackground(sourceURL: pair.r1, projectDirectory: projectDirectory, requestID: requestID)
            }
            return
        }

        // Auto-detect platform from the first R1 file
        let detectedPlatform = LungfishIO.SequencingPlatform.detect(fromFASTQ: pairs[0].r1) ?? .unknown

        FASTQImportConfigSheet.present(
            on: window,
            pairs: pairs,
            detectedPlatform: detectedPlatform,
            onImport: { [weak self] config in
                self?.importFASTQBatchWithConfig(
                    pairs: pairs,
                    config: config,
                    projectDirectory: projectDirectory,
                    requestID: requestID
                )
            },
            onCancel: { [weak self] in
                for pair in pairs {
                    self?.postSidebarFileDropCompleted(requestID: requestID, sourceURL: pair.r1, success: false, error: "Cancelled by user")
                }
            }
        )
    }

    /// Entry point for Import Center FASTQ import (no sidebar request ID).
    func presentFASTQImportSheetFromImportCenter(pairs: [FASTQFilePair], projectDirectory: URL) {
        presentFASTQImportSheet(pairs: pairs, projectDirectory: projectDirectory, requestID: nil)
    }

    /// Imports multiple FASTQ file pairs using the same user-configured settings.
    private func importFASTQBatchWithConfig(
        pairs: [FASTQFilePair],
        config: FASTQImportConfiguration,
        projectDirectory: URL,
        requestID: String?
    ) {
        guard let viewerController = self.viewerController else { return }

        Task { @MainActor [weak self] in
            guard let self else { return }
            for (index, pair) in pairs.enumerated() {
                await self.importFASTQPair(
                    pair: pair, index: index, totalPairs: pairs.count,
                    config: config, projectDirectory: projectDirectory,
                    viewerController: viewerController, requestID: requestID
                )
            }
        }
    }

    /// Imports a single FASTQ pair, resolving duplicates via sheet if needed.
    private func importFASTQPair(
        pair: FASTQFilePair, index: Int, totalPairs: Int,
        config: FASTQImportConfiguration, projectDirectory: URL,
        viewerController: ViewerViewController, requestID: String?
    ) async {
        let baseName = pair.sampleName
        var effectiveBundleName = baseName

        let bundleExt = FASTQBundle.directoryExtension
        var bundleURL = projectDirectory.appendingPathComponent("\(effectiveBundleName).\(bundleExt)")

        // Check for existing bundle
        if FileManager.default.fileExists(atPath: bundleURL.path) {
            let resolution = await showDuplicateFileDialog(filename: "\(effectiveBundleName).\(bundleExt)")
            switch resolution {
            case .replace:
                do {
                    try FileManager.default.removeItem(at: bundleURL)
                } catch {
                    logger.error("importFASTQBatch: Failed to remove existing bundle: \(error)")
                    postSidebarFileDropCompleted(requestID: requestID, sourceURL: pair.r1, success: false, error: error.localizedDescription)
                    return
                }
            case .keepBoth:
                var counter = 2
                var uniqueName = "\(baseName) \(counter)"
                while FileManager.default.fileExists(atPath: projectDirectory.appendingPathComponent("\(uniqueName).\(bundleExt)").path) {
                    counter += 1
                    uniqueName = "\(baseName) \(counter)"
                }
                effectiveBundleName = uniqueName
                bundleURL = projectDirectory.appendingPathComponent("\(effectiveBundleName).\(bundleExt)")
            case .skip:
                displayGenomicsFile(url: bundleURL)
                postSidebarFileDropCompleted(requestID: requestID, sourceURL: pair.r1, success: true, error: nil)
                return
            }
        }

        let progressMessage = totalPairs > 1
            ? "Importing \(index + 1) of \(totalPairs): \(pair.r1.lastPathComponent)\u{2026}"
            : "Importing \(pair.r1.lastPathComponent)\u{2026}"
        viewerController.showProgress(progressMessage)

        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            FASTQIngestionService.ingestAndBundle(
                pair: pair,
                projectDirectory: projectDirectory,
                bundleName: effectiveBundleName,
                importConfig: config
            ) { [weak self, weak viewerController] result in
                defer { continuation.resume() }
                switch result {
                case .success(let bundleURL):
                    viewerController?.hideProgress()
                    self?.sidebarController.reloadFromFilesystem()
                    self?.displayGenomicsFile(url: bundleURL)
                    self?.postSidebarFileDropCompleted(requestID: requestID, sourceURL: pair.r1, success: true, error: nil)
                case .failure(let error):
                    viewerController?.hideProgress()
                    logger.error("importFASTQBatch: \(error)")
                    self?.postSidebarFileDropCompleted(requestID: requestID, sourceURL: pair.r1, success: false, error: error.localizedDescription)
                    let alert = NSAlert()
                    alert.messageText = "Failed to Import FASTQ"
                    alert.informativeText = "\(error)"
                    alert.alertStyle = .warning
                    alert.addButton(withTitle: "OK")
                    alert.applyLungfishBranding()
                    if let window = self?.view.window ?? NSApp.keyWindow {
                        alert.beginSheetModal(for: window)
                    }
                }
            }
        }
    }

    // MARK: - Duplicate File Handling

    /// Shows a dialog asking the user how to handle a duplicate file
    /// Shows a dialog asking the user how to handle a duplicate file
    private func showDuplicateFileDialog(filename: String) async -> DuplicateResolution {
        let alert = NSAlert()
        alert.messageText = "File Already Exists"
        alert.informativeText = "A file named \"\(filename)\" already exists in this location. What would you like to do?"
        alert.alertStyle = .warning

        alert.addButton(withTitle: "Replace")    // First button = index 1000
        alert.addButton(withTitle: "Keep Both")  // Second button = index 1001
        alert.addButton(withTitle: "Skip")       // Third button = index 1002

        alert.applyLungfishBranding()

        guard let window = self.view.window ?? NSApp.keyWindow else { return .skip }
        let response = await alert.beginSheetModal(for: window)

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
        var counter = 2
        var newURL = targetDir.appendingPathComponent("\(baseName) \(counter).\(ext)")

        while FileManager.default.fileExists(atPath: newURL.path) {
            counter += 1
            newURL = targetDir.appendingPathComponent("\(baseName) \(counter).\(ext)")
        }

        return newURL
    }

    // MARK: - FASTQ Import Pipeline

    /// Imports a FASTQ file: ingests in temp dir, then creates a `.lungfishfastq`
    /// bundle in the project with the processed file inside.
    ///
    /// Flow: source FASTQ → copy to temp → clumpify + compress → create bundle
    /// in project → move processed file into bundle → display.
    private func importFASTQFileInBackground(sourceURL: URL, projectDirectory: URL, requestID: String?) {
        guard let viewerController = self.viewerController else {
            postSidebarFileDropCompleted(
                requestID: requestID,
                sourceURL: sourceURL,
                success: false,
                error: "Viewer unavailable while importing FASTQ."
            )
            return
        }

        let baseName = FASTQBundle.deriveBaseName(from: sourceURL)
        let bundleExt = FASTQBundle.directoryExtension
        let bundleURL = projectDirectory.appendingPathComponent("\(baseName).\(bundleExt)")

        // Check for existing bundle
        if FileManager.default.fileExists(atPath: bundleURL.path) {
            Task { @MainActor [weak self] in
                guard let self else { return }
                let resolution = await self.showDuplicateFileDialog(filename: "\(baseName).\(bundleExt)")
                self.completeFASTQImport(
                    resolution: resolution, baseName: baseName, bundleExt: bundleExt,
                    bundleURL: bundleURL, sourceURL: sourceURL,
                    projectDirectory: projectDirectory, viewerController: viewerController,
                    requestID: requestID
                )
            }
        } else {
            performFASTQIngest(
                effectiveBundleName: baseName, sourceURL: sourceURL,
                projectDirectory: projectDirectory, viewerController: viewerController,
                requestID: requestID
            )
        }
    }

    /// Handles the duplicate resolution result and proceeds with FASTQ import.
    private func completeFASTQImport(
        resolution: DuplicateResolution, baseName: String, bundleExt: String,
        bundleURL: URL, sourceURL: URL,
        projectDirectory: URL, viewerController: ViewerViewController,
        requestID: String?
    ) {
        var effectiveBundleName = baseName
        switch resolution {
        case .replace:
            do {
                try FileManager.default.removeItem(at: bundleURL)
            } catch {
                logger.error("importFASTQFileInBackground: Failed to remove existing bundle: \(error)")
                self.postSidebarFileDropCompleted(requestID: requestID, sourceURL: sourceURL, success: false, error: error.localizedDescription)
                let alert = NSAlert()
                alert.messageText = "Failed to Replace Bundle"
                alert.informativeText = "\(error)"
                alert.alertStyle = .warning
                alert.addButton(withTitle: "OK")
                alert.applyLungfishBranding()
                if let window = self.view.window ?? NSApp.keyWindow {
                    alert.beginSheetModal(for: window)
                }
                return
            }
        case .keepBoth:
            var counter = 2
            var uniqueName = "\(baseName) \(counter)"
            while FileManager.default.fileExists(atPath: projectDirectory.appendingPathComponent("\(uniqueName).\(bundleExt)").path) {
                counter += 1
                uniqueName = "\(baseName) \(counter)"
            }
            effectiveBundleName = uniqueName
        case .skip:
            displayGenomicsFile(url: bundleURL)
            postSidebarFileDropCompleted(requestID: requestID, sourceURL: sourceURL, success: true, error: nil)
            return
        }
        performFASTQIngest(
            effectiveBundleName: effectiveBundleName, sourceURL: sourceURL,
            projectDirectory: projectDirectory, viewerController: viewerController,
            requestID: requestID
        )
    }

    /// Performs the actual FASTQ ingestion after duplicate resolution.
    private func performFASTQIngest(
        effectiveBundleName: String, sourceURL: URL,
        projectDirectory: URL, viewerController: ViewerViewController,
        requestID: String?
    ) {
        viewerController.showProgress("Importing \(sourceURL.lastPathComponent)\u{2026}")

        FASTQIngestionService.ingestAndBundle(
            sourceURL: sourceURL,
            projectDirectory: projectDirectory,
            bundleName: effectiveBundleName
        ) { [weak self, weak viewerController] result in
            viewerController?.hideProgress()
            switch result {
            case .success(let bundleURL):
                self?.sidebarController.reloadFromFilesystem()
                self?.displayGenomicsFile(url: bundleURL)
                self?.postSidebarFileDropCompleted(requestID: requestID, sourceURL: sourceURL, success: true, error: nil)
            case .failure(let error):
                logger.error("importFASTQFileInBackground: \(error)")
                self?.postSidebarFileDropCompleted(requestID: requestID, sourceURL: sourceURL, success: false, error: error.localizedDescription)
                let alert = NSAlert()
                alert.messageText = "Failed to Import FASTQ"
                alert.informativeText = "\(error)"
                alert.alertStyle = .warning
                alert.addButton(withTitle: "OK")
                alert.applyLungfishBranding()
                if let window = self?.view.window ?? NSApp.keyWindow {
                    alert.beginSheetModal(for: window)
                }
            }
        }
    }

    /// Returns `true` when the URL looks like an ONT instrument output directory
    /// (contains `barcode*` subdirectories with `.fastq.gz` chunks).
    private func isONTDirectory(_ url: URL) -> Bool {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue else {
            return false
        }
        // Quick probe — try detecting layout without throwing
        let importer = ONTDirectoryImporter()
        return (try? importer.detectLayout(at: url)) != nil
    }

    /// Imports an ONT output directory into per-barcode `.lungfishfastq` bundles
    /// via the ONTDirectoryImporter, running in the background.
    func importONTDirectoryInBackground(sourceURL: URL, projectURL: URL, requestID: String? = nil) {
        guard let viewerController = self.viewerController else {
            postSidebarFileDropCompleted(
                requestID: requestID,
                sourceURL: sourceURL,
                success: false,
                error: "Viewer unavailable while importing ONT directory."
            )
            return
        }

        // Ask whether to include unclassified reads, then proceed
        let importer = ONTDirectoryImporter()
        let layout = try? importer.detectLayout(at: sourceURL)
        let hasUnclassified = layout?.hasUnclassified ?? false

        if hasUnclassified, let window = self.view.window ?? NSApp.keyWindow {
            let alert = NSAlert()
            alert.messageText = "ONT Directory Import"
            alert.informativeText = "Found \(layout!.barcodeDirectories.count) barcode directories. Include unclassified reads?"
            alert.addButton(withTitle: "Include Unclassified")
            alert.addButton(withTitle: "Barcoded Only")
            alert.applyLungfishBranding()
            Task { @MainActor [weak self] in
                let response = await alert.beginSheetModal(for: window)
                let includeUnclassified = response == .alertFirstButtonReturn
                self?.performONTImport(
                    sourceURL: sourceURL, projectURL: projectURL,
                    includeUnclassified: includeUnclassified,
                    viewerController: viewerController, requestID: requestID
                )
            }
        } else {
            performONTImport(
                sourceURL: sourceURL, projectURL: projectURL,
                includeUnclassified: false,
                viewerController: viewerController, requestID: requestID
            )
        }
    }

    /// Performs the actual ONT directory import after the user has chosen whether to include unclassified reads.
    private func performONTImport(
        sourceURL: URL, projectURL: URL,
        includeUnclassified: Bool,
        viewerController: ViewerViewController, requestID: String?
    ) {
        let config = ONTImportConfig(
            sourceDirectory: sourceURL,
            outputDirectory: projectURL,
            includeUnclassified: includeUnclassified
        )

        viewerController.showProgress("Importing ONT directory\u{2026}")

        let ontCliCmd = "# lungfish import ont \(sourceURL.path) (CLI command not yet available \u{2014} use GUI)"
        let opID = OperationCenter.shared.start(
            title: "ONT Import: \(sourceURL.lastPathComponent)",
            detail: "Detecting layout\u{2026}",
            operationType: .ingestion,
            cliCommand: ontCliCmd
        )

        Task.detached(priority: .userInitiated) { [weak self] in
            do {
                let importer = ONTDirectoryImporter()
                let result = try await importer.importDirectory(config: config) { fraction, message in
                    DispatchQueue.main.async {
                        MainActor.assumeIsolated {
                            OperationCenter.shared.update(id: opID, progress: fraction, detail: message)
                        }
                    }
                }

                let detail = "\(result.bundleURLs.count) barcode bundles, \(result.totalReadCount) reads"
                logger.info("importONTDirectoryInBackground: \(detail)")

                DispatchQueue.main.async { [weak self, weak viewerController] in
                    MainActor.assumeIsolated {
                        viewerController?.hideProgress()
                        OperationCenter.shared.complete(id: opID, detail: detail, bundleURLs: result.bundleURLs)
                        self?.sidebarController.reloadFromFilesystem()
                        self?.postSidebarFileDropCompleted(requestID: requestID, sourceURL: sourceURL, success: true, error: nil)

                        // Display the first bundle
                        if let firstBundle = result.bundleURLs.first {
                            self?.displayGenomicsFile(url: firstBundle)
                        }
                    }
                }
            } catch {
                logger.error("importONTDirectoryInBackground: \(error)")
                DispatchQueue.main.async { [weak self, weak viewerController] in
                    MainActor.assumeIsolated {
                        viewerController?.hideProgress()
                        OperationCenter.shared.fail(id: opID, detail: "\(error)")
                        self?.postSidebarFileDropCompleted(requestID: requestID, sourceURL: sourceURL, success: false, error: error.localizedDescription)

                        let alert = NSAlert()
                        alert.messageText = "ONT Import Failed"
                        alert.informativeText = "\(error)"
                        alert.alertStyle = .warning
                        alert.addButton(withTitle: "OK")
                        alert.applyLungfishBranding()
                        if let window = self?.view.window ?? NSApp.keyWindow {
                            alert.beginSheetModal(for: window)
                        }
                    }
                }
            }
        }
    }

    private func postSidebarFileDropCompleted(requestID: String?, sourceURL: URL, success: Bool, error: String?) {
        var userInfo: [String: Any] = [
            "url": sourceURL,
            "success": success
        ]
        if let requestID {
            userInfo["requestID"] = requestID
        }
        if let error {
            userInfo["error"] = error
        }
        NotificationCenter.default.post(
            name: .sidebarFileDropCompleted,
            object: self,
            userInfo: userInfo
        )
    }

    @objc private func handleSidebarPreferredWidthRecommended(_ notification: Notification) {
        guard let rawWidth = notification.userInfo?["width"] as? CGFloat else { return }
        applySidebarPreferredWidth(rawWidth, allowShrink: false, isRecommendation: true)
    }

    private func sidebarWidthBounds() -> (minimum: CGFloat, maximum: CGFloat)? {
        guard splitView.subviews.count >= 2 else { return nil }
        let minimum = max(sidebarMinWidth, splitView.minPossiblePositionOfDivider(at: 0))
        let maximum = min(sidebarMaxWidth, splitView.maxPossiblePositionOfDivider(at: 0))
        guard maximum >= minimum else { return nil }
        return (minimum, maximum)
    }

    private func applySidebarPreferredWidth(
        _ width: CGFloat,
        allowShrink: Bool,
        scheduleAsync: Bool = true,
        isRecommendation: Bool = false
    ) {
        shellLayoutCoordinator.recordRecommendation(width)
        ensureShellWidthConstraints()
        guard sidebarContainerView != nil else { return }
        guard !sidebarItem.isCollapsed else { return }

        let applyPosition = { [weak self] in
            guard let self else { return }
            guard let sidebarContainerView = self.sidebarContainerView else { return }
            guard !self.sidebarItem.isCollapsed else { return }
            guard let widthBounds = self.sidebarWidthBounds() else { return }

            let liveCurrentWidth = sidebarContainerView.frame.width
            let resolved = self.shellLayoutCoordinator.resolvedSidebarWidth(currentWidth: liveCurrentWidth)
            guard let target = self.sidebarWidthCoordinator.recommendedWidthToApply(
                proposedWidth: resolved,
                minimumWidth: widthBounds.minimum,
                maximumWidth: widthBounds.maximum,
                currentWidth: liveCurrentWidth,
                allowShrink: allowShrink
            ) else { return }
            guard !(!allowShrink && isRecommendation && target < liveCurrentWidth) else { return }

            self.withProgrammaticShellResizeSuppression {
                self.sidebarWidthCoordinator.noteProgrammaticWidth(target)
                self.sidebarWidthConstraint?.constant = target
                self.splitView.adjustSubviews()
                self.view.layoutSubtreeIfNeeded()
            }
            self.sidebarWidthCoordinator.finishProgrammaticWidth()
        }

        if scheduleAsync {
            performOnMainRunLoop {
                applyPosition()
            }
        } else {
            applyPosition()
        }
    }

    private func restorePersistedShellLayout() {
        withProgrammaticShellResizeSuppression {
            ensureShellWidthConstraints()
            let resolvedWidths = shellLayoutCoordinator.resolvedShellWidths(
                currentSidebarWidth: sidebarContainerView?.frame.width ?? sidebarDefaultWidth,
                currentInspectorWidth: inspectorContainerView?.frame.width ?? inspectorDefaultWidth,
                totalWidth: currentShellContentWidth()
            )

            sidebarWidthConstraint?.constant = resolvedWidths.sidebarWidth
            inspectorWidthConstraint?.constant = resolvedWidths.inspectorWidth

            if !sidebarItem.isCollapsed {
                setShellDividerPosition(
                    resolvedWidths.sidebarWidth,
                    ofDividerAt: 0
                )
            }

            if !inspectorItem.isCollapsed {
                let inspectorDividerPosition = shellContainerWidth()
                    - resolvedWidths.inspectorWidth
                    - splitView.dividerThickness
                setShellDividerPosition(
                    inspectorDividerPosition,
                    ofDividerAt: 1
                )
            }

            splitView.adjustSubviews()
            splitView.layoutSubtreeIfNeeded()
            view.layoutSubtreeIfNeeded()
        }
    }

    private func reapplyPersistedShellLayoutForCurrentVisibility(scheduleAsync: Bool) {
        let restoreLayout = { [weak self] in
            guard let self else { return }
            self.ensureShellWidthConstraints()
            self.restorePersistedShellLayout()
            self.completePendingRevealWidthReset()
        }

        if scheduleAsync {
            performOnMainRunLoop {
                restoreLayout()
            }
        } else {
            restoreLayout()
        }
    }

    private func markPendingRevealRestore(sidebar: Bool = false, inspector: Bool = false) {
        pendingSidebarRevealRestore = pendingSidebarRevealRestore || sidebar
        pendingInspectorRevealRestore = pendingInspectorRevealRestore || inspector
    }

    private func schedulePendingRevealRestoreIfNeeded() {
        let needsSidebarRestore = pendingSidebarRevealRestore && !sidebarItem.isCollapsed
        let needsInspectorRestore = pendingInspectorRevealRestore && !inspectorItem.isCollapsed
        guard needsSidebarRestore || needsInspectorRestore else { return }

        pendingSidebarRevealRestore = false
        pendingInspectorRevealRestore = false
        reapplyPersistedShellLayoutForCurrentVisibility(scheduleAsync: true)
    }

    private func requestPendingRevealRestorePass() {
        performOnMainRunLoop { [weak self] in
            self?.schedulePendingRevealRestoreIfNeeded()
        }
    }

    private func queuePostVisibilityShellRestore() {
        performOnMainRunLoop { [weak self] in
            self?.reapplyPersistedShellLayoutForCurrentVisibility(scheduleAsync: true)
        }
    }

    private func plannedSidebarRevealWidth() -> CGFloat {
        let desiredWidth = shellLayoutCoordinator.resolvedSidebarWidth(currentWidth: sidebarDefaultWidth)
        let currentInspectorWidth = !inspectorItem.isCollapsed ? (inspectorContainerView?.frame.width ?? inspectorDefaultWidth) : 0
        let visibleShellWidth = shellContentWidth(
            sidebarVisible: true,
            inspectorVisible: !inspectorItem.isCollapsed
        )

        return shellLayoutCoordinator.resizeDecision(
            event: .userDraggedSidebar,
            currentSidebarWidth: desiredWidth,
            currentInspectorWidth: currentInspectorWidth,
            totalWidth: visibleShellWidth
        ).sidebarWidthToPersist ?? desiredWidth
    }

    private func plannedInspectorRevealWidth() -> CGFloat {
        let desiredWidth = shellLayoutCoordinator.resolvedInspectorWidth(currentWidth: inspectorDefaultWidth)
        let currentSidebarWidth = !sidebarItem.isCollapsed ? (sidebarContainerView?.frame.width ?? sidebarDefaultWidth) : 0
        let visibleShellWidth = shellContentWidth(
            sidebarVisible: !sidebarItem.isCollapsed,
            inspectorVisible: true
        )

        return shellLayoutCoordinator.resizeDecision(
            event: .userDraggedInspector,
            currentSidebarWidth: currentSidebarWidth,
            currentInspectorWidth: desiredWidth,
            totalWidth: visibleShellWidth
        ).inspectorWidthToPersist ?? desiredWidth
    }

    private func prepareSidebarRevealWidthIfNeeded() {
        guard sidebarItem.isCollapsed else { return }
        let revealWidth = plannedSidebarRevealWidth()
        pendingSidebarRevealWidth = revealWidth
        sidebarItem.minimumThickness = revealWidth
    }

    private func prepareInspectorRevealWidthIfNeeded() {
        guard inspectorItem.isCollapsed else { return }
        let revealWidth = plannedInspectorRevealWidth()
        pendingInspectorRevealWidth = revealWidth
        inspectorItem.minimumThickness = revealWidth
    }

    private func finalizeSidebarRevealWidthIfNeeded() {
        guard let pendingSidebarRevealWidth else { return }
        ensureShellWidthConstraints()
        sidebarWidthConstraint?.constant = pendingSidebarRevealWidth
    }

    private func finalizeInspectorRevealWidthIfNeeded() {
        guard let pendingInspectorRevealWidth else { return }
        ensureShellWidthConstraints()
        inspectorWidthConstraint?.constant = pendingInspectorRevealWidth
    }

    private func completePendingRevealWidthReset() {
        if pendingSidebarRevealWidth != nil {
            pendingSidebarRevealWidth = nil
            sidebarItem.minimumThickness = sidebarItem.isCollapsed ? 0 : sidebarMinWidth
        }

        if pendingInspectorRevealWidth != nil {
            pendingInspectorRevealWidth = nil
            inspectorItem.minimumThickness = inspectorItem.isCollapsed ? 0 : inspectorMinWidth
        }
    }

    private func setShellDividerPosition(
        _ position: CGFloat,
        ofDividerAt dividerIndex: Int
    ) {
        pendingShellResizeEvent = .shellDidResize
        isApplyingProgrammaticShellDividerMove = true
        splitView.setPosition(position, ofDividerAt: dividerIndex)
        splitView.adjustSubviews()
        splitView.layoutSubtreeIfNeeded()
        view.layoutSubtreeIfNeeded()
        isApplyingProgrammaticShellDividerMove = false
    }

    private func restoreSidebarWidthIfNeeded(currentWidth: CGFloat) {
        guard !sidebarItem.isCollapsed else { return }
        guard currentWidth >= sidebarMinWidth - 1 else { return }
        guard let widthBounds = sidebarWidthBounds() else { return }
        guard let target = sidebarWidthCoordinator.restoredUserWidthToApply(
            currentWidth: currentWidth,
            minimumWidth: widthBounds.minimum,
            maximumWidth: widthBounds.maximum
        ) else { return }

        ensureShellWidthConstraints()
        withProgrammaticShellResizeSuppression {
            sidebarWidthCoordinator.noteProgrammaticWidth(target)
            sidebarWidthConstraint?.constant = target
            splitView.adjustSubviews()
            view.layoutSubtreeIfNeeded()
        }
        sidebarWidthCoordinator.finishProgrammaticWidth()
    }

    // MARK: - Panel State

    private func savePanelState() {
        let defaults = UserDefaults.standard
        defaults.set(sidebarItem.isCollapsed, forKey: Self.sidebarCollapsedDefaultsKey)
        defaults.set(inspectorItem.isCollapsed, forKey: Self.inspectorCollapsedDefaultsKey)

        if let sidebarWidth = shellLayoutCoordinator.state.lastUserSidebarWidth {
            defaults.set(sidebarWidth, forKey: Self.sidebarWidthDefaultsKey)
        } else {
            defaults.removeObject(forKey: Self.sidebarWidthDefaultsKey)
        }

        if let inspectorWidth = shellLayoutCoordinator.state.lastUserInspectorWidth {
            defaults.set(inspectorWidth, forKey: Self.inspectorWidthDefaultsKey)
        } else {
            defaults.removeObject(forKey: Self.inspectorWidthDefaultsKey)
        }
    }

    private func restorePanelState() {
        let defaults = UserDefaults.standard

        // Restore sidebar state (default: visible)
        if defaults.object(forKey: Self.sidebarCollapsedDefaultsKey) != nil {
            sidebarItem.isCollapsed = defaults.bool(forKey: Self.sidebarCollapsedDefaultsKey)
        }
        sidebarItem.minimumThickness = sidebarItem.isCollapsed ? 0 : sidebarMinWidth
        shellLayoutCoordinator.setSidebarVisible(!sidebarItem.isCollapsed)

        // Restore inspector state (default: visible)
        if defaults.object(forKey: Self.inspectorCollapsedDefaultsKey) != nil {
            inspectorItem.isCollapsed = defaults.bool(forKey: Self.inspectorCollapsedDefaultsKey)
        }
        inspectorItem.minimumThickness = inspectorItem.isCollapsed ? 0 : inspectorMinWidth
        shellLayoutCoordinator.setInspectorVisible(!inspectorItem.isCollapsed)

        if let sidebarWidth = persistedWidth(forKey: Self.sidebarWidthDefaultsKey) {
            shellLayoutCoordinator.recordUserSidebarWidth(sidebarWidth)
            sidebarWidthCoordinator.noteUserRequestedWidth(sidebarWidth)
        }

        if let inspectorWidth = persistedWidth(forKey: Self.inspectorWidthDefaultsKey) {
            shellLayoutCoordinator.recordUserInspectorWidth(inspectorWidth)
        }
    }

    private func persistedWidth(forKey key: String) -> CGFloat? {
        guard let number = UserDefaults.standard.object(forKey: key) as? NSNumber else { return nil }
        return CGFloat(number.doubleValue)
    }

    private func ensureShellWidthConstraints() {
        if let sidebarContainerView {
            let currentSidebarConstraintView = sidebarWidthConstraint?.firstItem as? NSView
            if currentSidebarConstraintView !== sidebarContainerView {
                let sidebarWidth = shellLayoutCoordinator.resolvedSidebarWidth(
                    currentWidth: max(sidebarContainerView.frame.width, sidebarDefaultWidth)
                )
                sidebarWidthConstraint?.isActive = false
                let constraint = sidebarContainerView.widthAnchor.constraint(equalToConstant: sidebarWidth)
                constraint.priority = .required
                constraint.isActive = true
                sidebarWidthConstraint = constraint
            }
        }

        if let inspectorContainerView {
            let currentInspectorConstraintView = inspectorWidthConstraint?.firstItem as? NSView
            if currentInspectorConstraintView !== inspectorContainerView {
                let inspectorWidth = shellLayoutCoordinator.resolvedInspectorWidth(
                    currentWidth: max(inspectorContainerView.frame.width, inspectorDefaultWidth)
                )
                inspectorWidthConstraint?.isActive = false
                let constraint = inspectorContainerView.widthAnchor.constraint(equalToConstant: inspectorWidth)
                constraint.priority = .required
                constraint.isActive = true
                inspectorWidthConstraint = constraint
            }
        }
    }

    private func currentShellContentWidth() -> CGFloat {
        shellContentWidth(
            sidebarVisible: !sidebarItem.isCollapsed,
            inspectorVisible: !inspectorItem.isCollapsed
        )
    }

    private func shellContentWidth(
        sidebarVisible: Bool,
        inspectorVisible: Bool
    ) -> CGFloat {
        let visiblePaneCount = [sidebarVisible, true, inspectorVisible]
            .filter { $0 }
            .count
        let visibleDividerCount = max(0, visiblePaneCount - 1)
        let dividerWidth = CGFloat(visibleDividerCount) * splitView.dividerThickness
        return max(0, shellContainerWidth() - dividerWidth)
    }

    private func shellContainerWidth() -> CGFloat {
        let enclosingWidth = view.superview?.bounds.width ?? 0
        return max(enclosingWidth, view.bounds.width, splitView.bounds.width)
    }

    private var isSuppressingProgrammaticShellResize: Bool {
        programmaticShellResizeSuppressionDepth > 0
    }

    private func beginProgrammaticShellResizeSuppression() {
        pendingShellResizeEvent = .shellDidResize
        programmaticShellResizeSuppressionDepth += 1
    }

    private func endProgrammaticShellResizeSuppression(scheduleAsync: Bool = false) {
        let release = { [weak self] in
            guard let self else { return }
            self.programmaticShellResizeSuppressionDepth = max(0, self.programmaticShellResizeSuppressionDepth - 1)
        }

        if scheduleAsync {
            performOnMainRunLoop {
                release()
            }
        } else {
            release()
        }
    }

    private func withProgrammaticShellResizeSuppression(
        scheduleAsyncRelease: Bool = false,
        _ mutation: () -> Void
    ) {
        beginProgrammaticShellResizeSuppression()
        mutation()
        endProgrammaticShellResizeSuppression(scheduleAsync: scheduleAsyncRelease)
    }

    private func releaseProgrammaticShellResizeSuppressionIfNeeded() {
        pendingShellResizeEvent = .shellDidResize
        programmaticShellResizeSuppressionDepth = max(0, programmaticShellResizeSuppressionDepth - 1)
    }

    // MARK: - Public API

    /// Toggles the sidebar visibility with animation.
    public func toggleSidebar() {
        prepareSidebarRevealWidthIfNeeded()
        beginProgrammaticShellResizeSuppression()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.2
            context.allowsImplicitAnimation = true
            sidebarItem.animator().isCollapsed.toggle()
        } completionHandler: { [weak self] in
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    let isSidebarVisible = !self.sidebarItem.isCollapsed
                    self.shellLayoutCoordinator.setSidebarVisible(isSidebarVisible)
                    if isSidebarVisible {
                        self.finalizeSidebarRevealWidthIfNeeded()
                        self.markPendingRevealRestore(sidebar: true)
                        self.requestPendingRevealRestorePass()
                    } else {
                        self.sidebarItem.minimumThickness = 0
                        self.queuePostVisibilityShellRestore()
                    }
                    self.savePanelState()
                    self.endProgrammaticShellResizeSuppression(scheduleAsync: true)
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
            if visible {
                prepareSidebarRevealWidthIfNeeded()
            }
            beginProgrammaticShellResizeSuppression()
            sidebarItem.isCollapsed = !visible
            shellLayoutCoordinator.setSidebarVisible(visible)
            if visible {
                finalizeSidebarRevealWidthIfNeeded()
                markPendingRevealRestore(sidebar: true)
                requestPendingRevealRestorePass()
            } else {
                sidebarItem.minimumThickness = 0
                queuePostVisibilityShellRestore()
            }
            savePanelState()
            endProgrammaticShellResizeSuppression()
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
                releaseProgrammaticShellResizeSuppressionIfNeeded()
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
            if visible {
                prepareInspectorRevealWidthIfNeeded()
            }
            beginProgrammaticShellResizeSuppression()
            animateInspectorCollapse(to: targetCollapsedState, source: source)
        } else {
            if visible {
                prepareInspectorRevealWidthIfNeeded()
            }
            beginProgrammaticShellResizeSuppression()
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0
                context.allowsImplicitAnimation = false
                inspectorItem.animator().isCollapsed = targetCollapsedState
            } completionHandler: { [weak self] in
                DispatchQueue.main.async { [weak self] in
                    MainActor.assumeIsolated {
                        guard let self else { return }
                        self.queuedInspectorCollapsedState = nil
                        self.finalizeInspectorVisibilityChange(source: source)
                    }
                }
            }
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
                MainActor.assumeIsolated {
                    self?.completeInspectorCollapseAnimation(serial: serial, source: "\(source).completion")
                }
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
        beginProgrammaticShellResizeSuppression()
        animateInspectorCollapse(to: queuedTarget, source: "queued")
    }

    /// Persists state and notifies inspector after visibility transitions.
    private func finalizeInspectorVisibilityChange(source: String) {
        let isInspectorVisible = !inspectorItem.isCollapsed
        shellLayoutCoordinator.setInspectorVisible(isInspectorVisible)
        if isInspectorVisible {
            finalizeInspectorRevealWidthIfNeeded()
            markPendingRevealRestore(inspector: true)
            requestPendingRevealRestorePass()
        } else {
            inspectorItem.minimumThickness = 0
            queuePostVisibilityShellRestore()
        }
        savePanelState()
        endProgrammaticShellResizeSuppression(scheduleAsync: true)
        inspectorController.inspectorVisibilityDidChange(isVisible: isInspectorVisible)
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
    //
    // NOTE: Do NOT override canCollapseSubview, constrainMinCoordinate, or
    // constrainMaxCoordinate on NSSplitViewController — these legacy delegate
    // methods are incompatible with constraint-based layout and cause an
    // assertion failure on macOS Tahoe. Use NSSplitViewItem properties instead:
    //   - canCollapse, minimumThickness, maximumThickness (set in configureChildControllers)

    public override func splitView(
        _ splitView: NSSplitView,
        constrainSplitPosition proposedPosition: CGFloat,
        ofSubviewAt dividerIndex: Int
    ) -> CGFloat {
        guard splitView === self.splitView else { return proposedPosition }
        guard !isApplyingProgrammaticShellDividerMove else { return proposedPosition }
        guard !isSuppressingProgrammaticShellResize else { return proposedPosition }

        let clampedPosition = min(
            max(proposedPosition, splitView.minPossiblePositionOfDivider(at: dividerIndex)),
            splitView.maxPossiblePositionOfDivider(at: dividerIndex)
        )

        switch dividerIndex {
        case 0:
            pendingShellResizeEvent = .userDraggedSidebar
        case 1:
            pendingShellResizeEvent = .userDraggedInspector
        default:
            pendingShellResizeEvent = .shellDidResize
        }

        if dividerIndex == 0,
           !sidebarItem.isCollapsed,
           !sidebarWidthCoordinator.isApplyingProgrammaticWidth {
            sidebarWidthCoordinator.noteUserRequestedWidth(clampedPosition)
        }

        return clampedPosition
    }

    public override func splitViewDidResizeSubviews(_ notification: Notification) {
        guard notification.object as? NSSplitView === splitView else { return }

        let sidebarWidth = !sidebarItem.isCollapsed ? (sidebarContainerView?.frame.width ?? 0) : 0
        let inspectorWidth = !inspectorItem.isCollapsed ? (inspectorContainerView?.frame.width ?? 0) : 0
        let totalWidth = currentShellContentWidth()
        let resizeEvent = isSuppressingProgrammaticShellResize ? .shellDidResize : pendingShellResizeEvent
        pendingShellResizeEvent = .shellDidResize
        let decision = shellLayoutCoordinator.resizeDecision(
            event: resizeEvent,
            currentSidebarWidth: sidebarWidth,
            currentInspectorWidth: inspectorWidth,
            totalWidth: totalWidth
        )

        if let sidebarWidth = decision.sidebarWidthToPersist, !sidebarItem.isCollapsed {
            shellLayoutCoordinator.recordUserSidebarWidth(sidebarWidth)
            sidebarWidthConstraint?.constant = sidebarWidth
            savePanelState()
        }

        if let inspectorWidth = decision.inspectorWidthToPersist, !inspectorItem.isCollapsed {
            shellLayoutCoordinator.recordUserInspectorWidth(inspectorWidth)
            inspectorWidthConstraint?.constant = inspectorWidth
            savePanelState()
        }

        if !sidebarItem.isCollapsed {
            sidebarWidthCoordinator.noteObservedWidth(sidebarWidth)
            restoreSidebarWidthIfNeeded(currentWidth: sidebarWidth)
        }

        schedulePendingRevealRestoreIfNeeded()
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

    var testingShellLayoutState: WorkspaceShellLayoutState {
        shellLayoutCoordinator.state
    }

    var testingSidebarWidth: CGFloat {
        sidebarContainerView?.frame.width ?? 0
    }

    var testingInspectorWidth: CGFloat {
        inspectorContainerView?.frame.width ?? 0
    }

    var testingSidebarConstraintWidth: CGFloat {
        sidebarWidthConstraint?.constant ?? 0
    }

    func testingSetShellFrames(
        sidebarWidth: CGFloat,
        inspectorWidth: CGFloat,
        totalWidth: CGFloat,
        height: CGFloat = 900
    ) {
        guard let sidebarContainerView, let viewerContainerView, let inspectorContainerView else { return }

        let dividerThickness = splitView.dividerThickness
        let viewerWidth = totalWidth - sidebarWidth - inspectorWidth - (dividerThickness * 2)
        let resolvedViewerWidth = max(viewerWidth, viewerMinWidth)
        let resolvedTotalWidth = sidebarWidth + resolvedViewerWidth + inspectorWidth + (dividerThickness * 2)
        view.frame = NSRect(x: 0, y: 0, width: resolvedTotalWidth, height: height)
        splitView.frame = view.bounds
        splitView.bounds = view.bounds
        sidebarContainerView.frame = NSRect(x: 0, y: 0, width: sidebarWidth, height: height)
        viewerContainerView.frame = NSRect(
            x: sidebarWidth + dividerThickness,
            y: 0,
            width: resolvedViewerWidth,
            height: height
        )
        inspectorContainerView.frame = NSRect(
            x: resolvedTotalWidth - inspectorWidth,
            y: 0,
            width: inspectorWidth,
            height: height
        )
    }

    func testingProcessShellResize() {
        splitViewDidResizeSubviews(Notification(name: Notification.Name("WorkspaceShellLayoutTests.Resize"), object: splitView))
    }

    func testingRestorePersistedShellLayout() {
        restorePanelState()
        restorePersistedShellLayout()
    }

    func testingForceStaleInspectorTransitionSuppression() {
        inspectorTransitionInFlight = true
        inspectorTransitionStartTime = ProcessInfo.processInfo.systemUptime - 1.0
        inspectorTransitionTargetCollapsedState = inspectorItem.isCollapsed
        queuedInspectorCollapsedState = nil
        programmaticShellResizeSuppressionDepth = 1
    }
}

// MARK: - SidebarSelectionDelegate

extension MainSplitViewController: SidebarSelectionDelegate {
    private func recordUITestEvent(_ event: String) {
        AppUITestConfiguration.current.appendEvent(event)
    }

    private func invalidatePendingSelectionDebounce(reason: String) {
        guard selectionDebounceWorkItem != nil else { return }
        logger.info("invalidatePendingSelectionDebounce: cancelling pending selection work (\(reason, privacy: .public))")
        selectionDebounceWorkItem?.cancel()
        selectionDebounceWorkItem = nil
        selectionGeneration &+= 1
    }

    private func cancelMultiDocumentLoadIfNeeded(hideProgress: Bool, reason: String) {
        if multiDocumentLoadTask != nil {
            logger.info("cancelMultiDocumentLoadIfNeeded: cancelling multi-document load (\(reason, privacy: .public))")
            multiDocumentLoadTask?.cancel()
            multiDocumentLoadTask = nil
        }
        if hideProgress {
            viewerController.hideProgress()
        }
    }

    /// Cancels any in-flight FASTQ dashboard load and optionally clears progress UI.
    private func cancelFASTQLoadIfNeeded(hideProgress: Bool, reason: String) {
        if fastqLoadTask != nil {
            logger.info("cancelFASTQLoadIfNeeded: cancelling FASTQ load (\(reason, privacy: .public))")
            fastqLoadTask?.cancel()
            fastqLoadTask = nil
        }
        fastqLoadGeneration &+= 1
        activeFASTQLoadURL = nil
        activeFASTQSourceURL = nil
        if hideProgress {
            viewerController.hideProgress()
        }
    }

    /// Returns true when a non-genomics child controller currently owns the viewport.
    private var hasActiveSidebarChildViewport: Bool {
        viewerController.taxTriageViewController != nil
            || viewerController.esVirituViewController != nil
            || viewerController.taxonomyViewController != nil
            || viewerController.fastqDatasetController != nil
            || viewerController.assemblyResultController != nil
            || viewerController.activeMappingViewportController != nil
    }

    /// Heuristic for whether the current sidebar selection callback was user-initiated.
    ///
    /// Filesystem refreshes and other programmatic updates can also trigger selection
    /// churn. We only want "selection cleared" to blank the viewport when the user
    /// actually interacted with the sidebar.
    private func isLikelyUserDrivenSidebarSelectionChange() -> Bool {
        let firstResponder = view.window?.firstResponder
        guard sidebarController.outlineViewIsFirstResponder(firstResponder) else { return false }
        guard let event = NSApp.currentEvent, event.window === view.window else { return false }
        switch event.type {
        case .leftMouseDown, .leftMouseUp,
             .rightMouseDown, .rightMouseUp,
             .otherMouseDown, .otherMouseUp,
             .keyDown:
            return true
        default:
            return false
        }
    }

    public func sidebarDidSelectItem(_ item: SidebarItem?) {
        // Cancel any pending debounced selection
        selectionDebounceWorkItem?.cancel()
        selectionDebounceWorkItem = nil

        // Increment generation counter to invalidate any in-flight background loads
        selectionGeneration &+= 1

        // If a metagenomics/FASTQ child VC is actively displayed, only process
        // selection changes when the sidebar outline view is the actual first
        // responder (i.e., the user clicked in the sidebar). Ignore spurious
        // selection changes from focus shifts, filesystem refreshes, etc.
        if hasActiveSidebarChildViewport {
            let firstResponder = view.window?.firstResponder
            let sidebarHasFocus = sidebarController.outlineViewIsFirstResponder(firstResponder)
            if !sidebarHasFocus {
                logger.debug("sidebarDidSelectItem: Ignoring selection change — sidebar not focused, active child VC displayed")
                return
            }
        }
        let userInitiatedInSidebar = isLikelyUserDrivenSidebarSelectionChange()

        // Debounce ALL selection changes (including nil/clear) to avoid
        // flickering when NSOutlineView fires deselect + reselect in quick
        // succession.
        let generation = selectionGeneration
        let workItem = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self = self else { return }
                guard self.selectionGeneration == generation else {
                    return
                }

                if let item {
                    self.displayContent(for: item)
                } else {
                    if self.hasActiveSidebarChildViewport && !userInitiatedInSidebar {
                        logger.debug("sidebarDidSelectItem: Ignoring non-user selection clear while active child VC is displayed")
                        return
                    }
                    logger.info("sidebarDidSelectItem: Selection cleared, clearing viewer and inspector")
                    self.cancelFASTQLoadIfNeeded(hideProgress: true, reason: "selection cleared")
                    self.viewerController.clearViewport(statusMessage: "No sequence selected")
                    self.inspectorController.clearSelection()
                }
            }
        }
        selectionDebounceWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1, execute: workItem)
    }

    public func sidebarDidSelectItems(_ items: [SidebarItem]) {
        // Cancel any pending debounced selection
        selectionDebounceWorkItem?.cancel()
        selectionDebounceWorkItem = nil

        // Increment generation counter
        selectionGeneration &+= 1

        // Filter to displayable items
        let displayableItems = items.filter { item in
            item.type != .folder && item.type != .project && item.type != .group
        }

        // Debounce all paths (including empty) to match sidebarDidSelectItem behavior
        let generation = selectionGeneration
        let workItem = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self = self, self.selectionGeneration == generation else { return }

                guard !displayableItems.isEmpty else {
                    self.cancelFASTQLoadIfNeeded(hideProgress: true, reason: "multi-select containers only")
                    self.viewerController.clearViewport(statusMessage: "No sequence selected")
                    self.inspectorController.clearSelection()
                    return
                }

                if displayableItems.count == 1 {
                    self.displayContent(for: displayableItems[0])
                } else {
                    self.handleMultipleItemsSelected(displayableItems)
                }
            }
        }
        selectionDebounceWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1, execute: workItem)
    }

    /// Unified content dispatch - synchronous for reliability.
    ///
    /// This method handles all content display decisions synchronously,
    /// avoiding Swift Task issues that occur when called from notification handlers.
    private func displayContent(for item: SidebarItem) {
        logger.info("displayContent: Selected '\(item.title, privacy: .public)' type=\(String(describing: item.type))")

        let selectedFASTQURL: URL? = {
            guard let url = item.url else { return nil }
            if FASTQBundle.isBundleURL(url) {
                return url.standardizedFileURL
            }
            return FASTQBundle.resolvePrimaryFASTQURL(for: url)?.standardizedFileURL
        }()
        if selectedFASTQURL == nil {
            cancelFASTQLoadIfNeeded(hideProgress: true, reason: "selected non-FASTQ item '\(item.title)'")
        }

        // Skip non-displayable container types
        guard item.type != .folder && item.type != .project && item.type != .group else {
            logger.debug("displayContent: Skipping container item type")
            return
        }

        // Batch group items: route directly to the batch aggregated viewer
        if item.type == .batchGroup, let batchURL = item.url {
            displayBatchGroup(at: batchURL)
            return
        }

        // When switching away from a bundle to a non-bundle item, clean up the navigator
        if item.type != .referenceBundle {
            viewerController.clearBundleDisplay()
        }

        // Always clear FASTA collection view when switching sidebar items
        viewerController.hideFASTACollectionView()
        viewerController.hideCollectionBackButton()

        // QuickLook preview for document, image, unknown types
        if item.type.usesQuickLook, let url = item.url {
            logger.info("displayContent: Using QuickLook preview for '\(item.title, privacy: .public)'")
            viewerController.displayQuickLookPreview(url: url)
            return
        }

        // Reference genome bundles (.lungfishref)
        if item.type == .referenceBundle, let url = item.url {
            displayReferenceBundleViewportFromSidebar(at: url)
            return
        }

        // Classification results (Kraken2 kreport/kraken output)
        if item.type == .classificationResult, let url = item.url {
            routeClassifierDisplay(url: url)
            return
        }

        // EsViritu viral detection results
        if item.type == .esvirituResult, let url = item.url {
            routeClassifierDisplay(url: url)
            return
        }

        // TaxTriage results — all go through the DB router now.
        // Per-sample display will be handled via DB queries (Task 6).
        if item.type == .taxTriageResult, let url = item.url {
            routeClassifierDisplay(url: url)
            return
        }

        // NAO-MGS surveillance result bundles
        if item.type == .naoMgsResult, let url = item.url {
            displayNaoMgsResultFromSidebar(at: url)
            return
        }

        // NVD result bundles
        if item.type == .nvdResult, let url = item.url {
            displayNvdResultFromSidebar(at: url)
            return
        }

        // Generic analysis results in Analyses/ folder — try to detect tool type
        // from directory name and dispatch to the appropriate viewer.
        // Classifier results route through the ClassifierDatabaseRouter; non-classifier
        // results are dispatched by prefix or analysis-metadata.json.
        if item.type == .analysisResult, let url = item.url {
            if ClassifierDatabaseRouter.route(for: url) != nil {
                routeClassifierDisplay(url: url)
                return
            }
            // Determine tool: check metadata first (works for renamed dirs), then prefix.
            let dirName = url.lastPathComponent
            let toolId = item.userInfo["analysisTool"]
                ?? AnalysesFolder.readAnalysisMetadata(from: url)?.tool
                ?? dirName
            if toolId.hasPrefix("naomgs") {
                displayNaoMgsResultFromSidebar(at: url)
            } else if toolId.hasPrefix("nvd") {
                displayNvdResultFromSidebar(at: url)
            } else if toolId.hasPrefix("spades")
                || toolId.hasPrefix("megahit")
                || toolId.hasPrefix("skesa")
                || toolId.hasPrefix("flye")
                || toolId.hasPrefix("hifiasm") {
                displayAssemblyAnalysisFromSidebar(at: url)
            } else if toolId == MappingTool.minimap2.rawValue
                || toolId == MappingTool.bwaMem2.rawValue
                || toolId == MappingTool.bowtie2.rawValue
                || toolId == MappingTool.bbmap.rawValue {
                displayMappingAnalysisFromSidebar(at: url)
            } else {
                logger.warning("displayContent: Unknown analysis type for '\(dirName, privacy: .public)'")
            }
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

    /// Display a direct reference bundle in the shared list/detail reference viewport.
    private func displayReferenceBundleViewportFromSidebar(at url: URL, forceReload: Bool = false) {
        logger.info("displayReferenceBundleViewport: Opening '\(url.lastPathComponent, privacy: .public)'")

        activityIndicator.show(
            message: "Loading \(url.lastPathComponent)...",
            style: .indeterminate
        )

        // Defer execution to the next runloop so the loading indicator paints immediately.
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                defer { self.activityIndicator.hide() }

                do {
                    self.inspectorController.clearSelection()
                    let manifest = try BundleManifest.load(from: url)
                    let input = ReferenceBundleViewportInput.directBundle(
                        bundleURL: url,
                        manifest: manifest
                    )
                    try self.viewerController.displayReferenceBundleViewport(input)
                    self.wireDirectReferenceViewportInspectorUpdates()
                    logger.info("displayReferenceBundleViewport: Bundle displayed successfully")
                } catch {
                    logger.error("displayReferenceBundleViewport: Failed - \(error.localizedDescription, privacy: .public)")
                    self.viewerController.clearViewport(statusMessage: "Unable to load reference bundle.")
                }
            }
        }
    }

    func wireDirectReferenceViewportInspectorUpdates() {
        guard let controller = viewerController.referenceBundleViewportController else { return }
        controller.onEmbeddedReferenceBundleLoaded = { [weak self, weak controller] bundle in
            guard let self, let controller else { return }
            self.inspectorController.updateReferenceBundleTrackSections(
                from: bundle,
                applySettings: { payload in
                    controller.applyEmbeddedReadDisplaySettings(payload)
                }
            )
        }
        controller.notifyEmbeddedReferenceBundleLoadedIfAvailable()
    }

    private func wireMappingReferenceViewportInspectorUpdates() {
        guard let controller = viewerController.referenceBundleViewportController else { return }
        controller.onEmbeddedReferenceBundleLoaded = { [weak self, weak controller] bundle in
            guard let self, let controller else { return }
            self.inspectorController.updateMappingAlignmentSection(
                from: bundle,
                applySettings: { payload in
                    controller.applyEmbeddedReadDisplaySettings(payload)
                }
            )
        }
        controller.notifyEmbeddedReferenceBundleLoadedIfAvailable()
    }

    private func displayAssemblyAnalysisFromSidebar(at url: URL) {
        logger.info("displayAssemblyAnalysis: Opening '\(url.lastPathComponent, privacy: .public)'")
        recordUITestEvent("assembly.display.requested \(url.lastPathComponent)")
        invalidatePendingSelectionDebounce(reason: "display assembly analysis")
        cancelFASTQLoadIfNeeded(hideProgress: true, reason: "display assembly analysis")
        cancelMultiDocumentLoadIfNeeded(hideProgress: true, reason: "display assembly analysis")

        do {
            let result = try AssemblyResult.load(from: url)
            let provenance = try? AssemblyProvenance.load(from: url)
            inspectorController.clearSelection()
            inspectorController.updateAssemblyDocument(
                result: result,
                provenance: provenance,
                projectURL: sidebarController.currentProjectURL ?? DocumentManager.shared.activeProject?.url
            )
            viewerController.displayAssemblyResult(result)
            recordUITestEvent(
                "assembly.display.succeeded tool=\(result.tool.rawValue) contigs=\(result.statistics.contigCount)"
            )
        } catch {
            logger.error(
                "displayAssemblyAnalysis: Failed to load result from \(url.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)"
            )
            recordUITestEvent("assembly.display.failed \(url.lastPathComponent) error=\(error.localizedDescription)")
            viewerController.clearViewport(statusMessage: "Unable to load assembly result.")
        }
    }

    func refreshSidebarAndDisplayMappingResult(at url: URL) {
        refreshSidebarAndSelectDerivedURL(url)
        displayMappingAnalysisFromSidebar(at: url)
    }

    private func displayMappingAnalysisFromSidebar(at url: URL) {
        logger.info("displayMappingAnalysis: Opening '\(url.lastPathComponent, privacy: .public)'")
        recordUITestEvent("mapping.display.requested \(url.lastPathComponent)")
        invalidatePendingSelectionDebounce(reason: "display mapping analysis")
        cancelFASTQLoadIfNeeded(hideProgress: true, reason: "display mapping analysis")
        cancelMultiDocumentLoadIfNeeded(hideProgress: true, reason: "display mapping analysis")

        do {
            let result = try MappingResult.load(from: url)
            let provenance = MappingProvenance.load(from: url)
            let projectURL = sidebarController.currentProjectURL ?? DocumentManager.shared.activeProject?.url
            let input = ReferenceBundleViewportInput.mappingResult(
                result: result,
                resultDirectoryURL: url,
                provenance: provenance
            )
            inspectorController.clearSelection()
            inspectorController.updateMappingDocument(
                MappingDocumentStateBuilder.build(
                    result: result,
                    provenance: provenance,
                    projectURL: projectURL
                )
            )
            try viewerController.displayReferenceBundleViewport(input)
            wireMappingReferenceViewportInspectorUpdates()
            recordUITestEvent(
                "mapping.display.succeeded tool=\(result.mapper.rawValue) contigs=\(result.contigs.count)"
            )
        } catch {
            logger.error(
                "displayMappingAnalysis: Failed to load result from \(url.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)"
            )
            recordUITestEvent("mapping.display.failed \(url.lastPathComponent) error=\(error.localizedDescription)")
            viewerController.clearViewport(statusMessage: "Unable to load mapping result.")
        }
    }


    /// Routes a classifier result directory through the DB router.
    ///
    /// - Top-level classifier dir with DB → loads batch view.
    /// - Per-sample subdir with DB → loads batch view, filters picker to that sample.
    /// - Any classifier dir without DB → shows auto-build placeholder.
    /// - Non-classifier dir → logs and no-ops.
    private func routeClassifierDisplay(url: URL) {
        guard let route = ClassifierDatabaseRouter.route(for: url) else {
            logger.warning("routeClassifierDisplay: Not a classifier directory: \(url.lastPathComponent, privacy: .public)")
            return
        }

        if route.databaseURL != nil {
            displayBatchGroup(at: route.resultURL)
            if let sampleId = route.sampleId {
                filterBatchViewToSingleSample(sampleId: sampleId)
            }
        } else {
            showDatabaseBuildPlaceholder(tool: route.displayName, resultURL: route.resultURL)
        }
    }

    /// After a batch view loads, constrain the sample picker to a single sample.
    /// Fires the metagenomicsSampleSelectionChanged notification which each VC
    /// observes to reload the filtered view.
    private func filterBatchViewToSingleSample(sampleId: String) {
        if let taxTriageVC = viewerController.taxTriageViewController {
            taxTriageVC.samplePickerState?.selectedSamples = [sampleId]
            NotificationCenter.default.post(name: .metagenomicsSampleSelectionChanged, object: nil)
            return
        }
        if let esVirituVC = viewerController.esVirituViewController {
            esVirituVC.samplePickerState?.selectedSamples = [sampleId]
            NotificationCenter.default.post(name: .metagenomicsSampleSelectionChanged, object: nil)
            return
        }
        if let taxonomyVC = viewerController.taxonomyViewController {
            taxonomyVC.samplePickerState?.selectedSamples = [sampleId]
            NotificationCenter.default.post(name: .metagenomicsSampleSelectionChanged, object: nil)
            return
        }
    }

    /// Displays a batch aggregated viewer for a `.batchGroup` sidebar item.
    ///
    /// Detects the tool type from the batch directory name prefix, loads the
    /// appropriate manifest (for Kraken2 and EsViritu) or scans subdirectories
    /// (for TaxTriage), creates the viewer VC, and wires the Inspector.
    ///
    /// - Parameter batchURL: The batch result directory (e.g. `kraken2-batch-2024-06-02T14-20-15/`).
    private func displayBatchGroup(at batchURL: URL) {
        let dirName = batchURL.lastPathComponent
        logger.info("displayBatchGroup: Opening '\(dirName, privacy: .public)'")

        let projectURL = sidebarController.currentProjectURL ?? DocumentManager.shared.activeProject?.url
        let toolId = AnalysesFolder.readAnalysisMetadata(from: batchURL)?.tool ?? dirName

        if toolId.hasPrefix("spades")
            || toolId.hasPrefix("megahit")
            || toolId.hasPrefix("skesa")
            || toolId.hasPrefix("flye")
            || toolId.hasPrefix("hifiasm") {
            displayAssemblyAnalysisFromSidebar(at: batchURL)
            return
        }

        if toolId == MappingTool.minimap2.rawValue
            || toolId == MappingTool.bwaMem2.rawValue
            || toolId == MappingTool.bowtie2.rawValue
            || toolId == MappingTool.bbmap.rawValue {
            displayMappingAnalysisFromSidebar(at: batchURL)
            return
        }

        if dirName.hasPrefix("kraken2") || dirName.hasPrefix("classification") {
            // Check for SQLite database first -- faster than parsing per-sample kreport files.
            let dbURL = batchURL.appendingPathComponent("kraken2.sqlite")
            if FileManager.default.fileExists(atPath: dbURL.path),
               let db = try? Kraken2Database(at: dbURL) {
                viewerController.displayTaxonomyFromDatabase(db: db, resultURL: batchURL)
                if let taxonomyVC = viewerController.taxonomyViewController {
                    // Load sample metadata from the bundle if available
                    let knownIds = Set(taxonomyVC.sampleEntries.map(\.id))
                    let metadataStore = SampleMetadataStore.load(from: batchURL, knownSampleIds: knownIds)
                    metadataStore?.wireAutosave(bundleURL: batchURL)
                    taxonomyVC.sampleMetadataStore = metadataStore

                    self.inspectorController?.updateClassifierSampleState(
                        pickerState: taxonomyVC.samplePickerState,
                        entries: taxonomyVC.sampleEntries,
                        strippedPrefix: taxonomyVC.strippedPrefix,
                        metadata: metadataStore,
                        attachments: BundleAttachmentStore(bundleURL: batchURL)
                    )
                }
            } else {
                // No SQLite DB — show placeholder and auto-build.
                showDatabaseBuildPlaceholder(tool: "Kraken2", resultURL: batchURL)
                return
            }
            // Build params starting from the manifest-level fields (if available).
            if let manifest = MetagenomicsBatchResultStore.loadClassification(from: batchURL) {
                var params: [String: String] = [
                    "Database": "\(manifest.databaseName) \(manifest.databaseVersion)".trimmingCharacters(in: .whitespaces),
                    "Goal": manifest.goal,
                ]
                // Augment with per-sample config from the first sample's result sidecar.
                if let firstSample = manifest.samples.first {
                    let sampleResultDir = batchURL.appendingPathComponent(firstSample.resultDirectory)
                    if let sampleResult = try? ClassificationResult.load(from: sampleResultDir) {
                        let cfg = sampleResult.config
                        if !sampleResult.toolVersion.isEmpty {
                            params["Tool Version"] = "Kraken2 \(sampleResult.toolVersion)"
                        }
                        params["Confidence"] = String(format: "%.2f", cfg.confidence)
                        params["Min Hit Groups"] = "\(cfg.minimumHitGroups)"
                        params["Threads"] = "\(cfg.threads)"
                        if cfg.memoryMapping { params["Memory Mapping"] = "Yes" }
                        if cfg.quickMode { params["Quick Mode"] = "Yes" }
                        let runtimeStr = formatInspectorRuntime(sampleResult.runtime)
                        if !runtimeStr.isEmpty { params["Runtime (first sample)"] = runtimeStr }
                    }
                }
                let sourceSamples = resolveBatchSourceSamples(manifest.samples, projectURL: projectURL)
                self.inspectorController?.updateBatchOperationDetails(
                    tool: "Kraken2",
                    parameters: params,
                    timestamp: manifest.header.createdAt,
                    sourceSamples: sourceSamples
                )
            }
            // Kraken2 batch always reads from its own per-result sidecars; no separate
            // aggregated manifest is built, so this status is not applicable.
            self.inspectorController?.viewModel.documentSectionViewModel.batchManifestStatus = .notCached

        } else if dirName.hasPrefix("esviritu") {
            // Check for SQLite database first — faster than parsing per-sample files.
            let dbURL = batchURL.appendingPathComponent("esviritu.sqlite")
            if FileManager.default.fileExists(atPath: dbURL.path),
               let db = try? EsVirituDatabase(at: dbURL) {
                viewerController.displayEsVirituFromDatabase(db: db, resultURL: batchURL)
                if let evVC = viewerController.esVirituViewController {
                    let knownIds = Set(evVC.sampleEntries.map(\.id))
                    let metadataStore = SampleMetadataStore.load(from: batchURL, knownSampleIds: knownIds)
                    metadataStore?.wireAutosave(bundleURL: batchURL)
                    evVC.sampleMetadataStore = metadataStore

                    self.inspectorController?.updateClassifierSampleState(
                        pickerState: evVC.samplePickerState,
                        entries: evVC.sampleEntries,
                        strippedPrefix: evVC.strippedPrefix,
                        metadata: metadataStore,
                        attachments: BundleAttachmentStore(bundleURL: batchURL)
                    )
                }
            } else {
                // No SQLite DB — show placeholder and auto-build.
                showDatabaseBuildPlaceholder(tool: "EsViritu", resultURL: batchURL)
                return
            }
            // Build params from the first sample's EsViritu result sidecar.
            var esVirituParams: [String: String] = [:]
            if let firstSample = MetagenomicsBatchResultStore.loadEsViritu(from: batchURL)?.samples.first {
                let sampleResultDir = batchURL.appendingPathComponent(firstSample.resultDirectory)
                if let sampleResult = try? LungfishWorkflow.EsVirituResult.load(from: sampleResultDir) {
                    let cfg = sampleResult.config
                    if !sampleResult.toolVersion.isEmpty {
                        esVirituParams["Tool Version"] = "EsViritu \(sampleResult.toolVersion)"
                    }
                    esVirituParams["Threads"] = "\(cfg.threads)"
                    esVirituParams["Quality Filter"] = cfg.qualityFilter ? "Yes" : "No"
                    esVirituParams["Min Read Length"] = "\(cfg.minReadLength)"
                    esVirituParams["Paired-End"] = cfg.isPairedEnd ? "Yes" : "No"
                    let runtimeStr = formatInspectorRuntime(sampleResult.runtime)
                    if !runtimeStr.isEmpty { esVirituParams["Runtime (first sample)"] = runtimeStr }
                }
            }
            if let manifest = MetagenomicsBatchResultStore.loadEsViritu(from: batchURL) {
                let sourceSamples = resolveBatchSourceSamples(manifest.samples, projectURL: projectURL)
                self.inspectorController?.updateBatchOperationDetails(
                    tool: "EsViritu",
                    parameters: esVirituParams,
                    timestamp: manifest.header.createdAt,
                    sourceSamples: sourceSamples
                )
            }
            if let esVirituVC = viewerController.esVirituViewController {
                self.inspectorController?.viewModel.documentSectionViewModel.batchManifestStatus =
                    esVirituVC.didLoadFromManifestCache ? .cached : .building
            }

        } else if dirName.hasPrefix("taxtriage") {
            // Check for SQLite database first — faster than parsing per-sample files.
            let dbURL = batchURL.appendingPathComponent("taxtriage.sqlite")
            if FileManager.default.fileExists(atPath: dbURL.path),
               let db = try? TaxTriageDatabase(at: dbURL) {
                viewerController.displayTaxTriageFromDatabase(db: db, resultURL: batchURL)
                if let ttVC = viewerController.taxTriageViewController {
                    let knownIds = Set(ttVC.sampleEntries.map(\.id))
                    let metadataStore = SampleMetadataStore.load(from: batchURL, knownSampleIds: knownIds)
                    metadataStore?.wireAutosave(bundleURL: batchURL)
                    ttVC.sampleMetadataStore = metadataStore

                    self.inspectorController?.updateClassifierSampleState(
                        pickerState: ttVC.samplePickerState,
                        entries: ttVC.sampleEntries,
                        strippedPrefix: ttVC.strippedPrefix,
                        metadata: metadataStore,
                        attachments: BundleAttachmentStore(bundleURL: batchURL)
                    )
                }
            } else {
                // No SQLite DB — show placeholder and auto-build.
                showDatabaseBuildPlaceholder(tool: "TaxTriage", resultURL: batchURL)
                return
            }

            // Load TaxTriage result sidecar for provenance.
            var taxTriageParams: [String: String] = [:]
            let taxTriageTimestamp: Date? = nil  // TaxTriageResult does not store a createdAt timestamp
            var taxTriageSamples: [(sampleId: String, bundleURL: URL?)] = []

            if let ttResult = try? TaxTriageResult.load(from: batchURL) {
                let cfg = ttResult.config

                // Pipeline parameters
                taxTriageParams["Platform"] = cfg.platform.displayName
                taxTriageParams["Classifiers"] = cfg.classifiers.joined(separator: ", ")
                taxTriageParams["Confidence"] = String(format: "%.2f", cfg.k2Confidence)
                taxTriageParams["Top Hits"] = "\(cfg.topHitsCount)"
                taxTriageParams["Rank"] = cfg.rank
                taxTriageParams["Max CPUs"] = "\(cfg.maxCpus)"
                taxTriageParams["Max Memory"] = cfg.maxMemory
                if let dbPath = cfg.kraken2DatabasePath {
                    taxTriageParams["Database Path"] = dbPath.lastPathComponent
                }
                let runtimeStr = formatInspectorRuntime(ttResult.runtime)
                if !runtimeStr.isEmpty { taxTriageParams["Runtime"] = runtimeStr }
                if ttResult.hasIgnoredFailures {
                    let sampleCount = Set(ttResult.ignoredFailures.compactMap(\.sampleID)).count
                    if sampleCount > 0 {
                        taxTriageParams["Warnings"] = "\(ttResult.ignoredFailures.count) ignored failures across \(sampleCount) samples"
                    } else {
                        taxTriageParams["Warnings"] = "\(ttResult.ignoredFailures.count) ignored failures"
                    }
                }

                // Resolve source sample URLs from config samples and project search.
                taxTriageSamples = cfg.samples.map { sample in
                    let bundleURL = cfg.sourceBundleURLs?.first { url in
                        url.deletingPathExtension().lastPathComponent
                            .localizedCaseInsensitiveContains(sample.sampleId)
                    } ?? projectURL.flatMap { findBundleInProject($0, matchingSampleId: sample.sampleId) }
                    return (sampleId: sample.sampleId, bundleURL: bundleURL)
                }
            } else if let taxTriageVC = viewerController.taxTriageViewController {
                // No sidecar available — use sample entries from the VC to at least resolve source URLs.
                taxTriageSamples = taxTriageVC.sampleEntries.map { entry in
                    let bundleURL = projectURL.flatMap { findBundleInProject($0, matchingSampleId: entry.id) }
                    return (sampleId: entry.id, bundleURL: bundleURL)
                }
            }

            self.inspectorController?.clearBatchOperationDetails()
            self.inspectorController?.updateBatchOperationDetails(
                tool: "TaxTriage",
                parameters: taxTriageParams,
                timestamp: taxTriageTimestamp,
                sourceSamples: taxTriageSamples
            )
            if let taxTriageVC = viewerController.taxTriageViewController {
                self.inspectorController?.viewModel.documentSectionViewModel.batchManifestStatus =
                    taxTriageVC.didLoadFromManifestCache ? .cached : .building
            }

        } else if dirName.hasPrefix("naomgs") || AnalysesFolder.readAnalysisMetadata(from: batchURL)?.tool == "naomgs" {
            displayNaoMgsResultFromSidebar(at: batchURL)
            self.inspectorController?.clearBatchOperationDetails()

        } else if dirName.hasPrefix("nvd") || AnalysesFolder.readAnalysisMetadata(from: batchURL)?.tool == "nvd" {
            displayNvdResultFromSidebar(at: batchURL)
            self.inspectorController?.clearBatchOperationDetails()

        } else {
            logger.warning("displayBatchGroup: Unrecognized batch prefix in '\(dirName, privacy: .public)'")
        }
    }

    /// Shows a ``DatabaseBuildPlaceholderView`` in the viewport area and
    /// automatically triggers a background `lungfish build-db` subprocess.
    ///
    /// On success the placeholder is removed and ``displayBatchGroup(at:)`` is
    /// called again so the newly-built SQLite database is picked up.  On failure
    /// the placeholder switches to an error state with a Retry button.
    ///
    /// - Parameters:
    ///   - tool: Human-readable tool name (e.g. "TaxTriage").
    ///   - resultURL: The batch result directory URL.
    private func showDatabaseBuildPlaceholder(tool: String, resultURL: URL) {
        // Clear any existing viewport content so the placeholder is the only thing shown.
        viewerController.clearViewport(statusMessage: "")

        let placeholder = DatabaseBuildPlaceholderView()

        let contentView = viewerController.view
        contentView.addSubview(placeholder)
        placeholder.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            placeholder.topAnchor.constraint(equalTo: contentView.topAnchor),
            placeholder.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            placeholder.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            placeholder.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
        ])

        let dirName = resultURL.lastPathComponent
        logger.info(
            "showDatabaseBuildPlaceholder: Shown for tool='\(tool, privacy: .public)' result='\(dirName, privacy: .public)'"
        )

        // Auto-trigger the database build.
        triggerDatabaseBuild(tool: tool, resultURL: resultURL, placeholder: placeholder)
    }

    /// Runs `lungfish-cli build-db <tool> <resultDir>` via ``LungfishCLIRunner``.
    ///
    /// Updates the placeholder view with progress/error states and, on success,
    /// removes it and re-triggers ``displayBatchGroup(at:)`` so the newly-built
    /// database is loaded.
    ///
    /// Most batch pipelines now build the database in-process before the user
    /// ever reaches this placeholder (see ``runEsVirituBatch`` and
    /// ``runClassificationBatch``). This path exists as a fallback for
    /// legacy/imported batches that were created without an attached SQLite DB.
    private func triggerDatabaseBuild(
        tool: String,
        resultURL: URL,
        placeholder: DatabaseBuildPlaceholderView
    ) {
        let cliTool = tool.lowercased()

        // Show the "building" spinner state immediately so the user sees feedback.
        placeholder.showBuilding(tool: tool)

        Task.detached { [weak self] in
            do {
                try LungfishCLIRunner.buildClassifierDatabase(tool: cliTool, resultURL: resultURL, force: true)

                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        guard let self else { return }
                        placeholder.removeFromSuperview()
                        // Re-display — the DB should now exist.
                        self.displayBatchGroup(at: resultURL)
                    }
                }
            } catch {
                let errorDescription = error.localizedDescription
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        guard let self else { return }
                        placeholder.showError("Build failed: \(errorDescription)")
                        // Ensure the placeholder is still in the viewport hierarchy so the error is visible.
                        if placeholder.superview == nil {
                            let contentView = self.viewerController.view
                            contentView.addSubview(placeholder)
                            placeholder.translatesAutoresizingMaskIntoConstraints = false
                            NSLayoutConstraint.activate([
                                placeholder.topAnchor.constraint(equalTo: contentView.topAnchor),
                                placeholder.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
                                placeholder.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
                                placeholder.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
                            ])
                        }
                        placeholder.onRetry = { [weak self] in
                            placeholder.removeFromSuperview()
                            self?.showDatabaseBuildPlaceholder(tool: tool, resultURL: resultURL)
                        }
                    }
                }
            }
        }
    }

    /// Formats a pipeline runtime duration as a human-readable string for the Inspector.
    ///
    /// Returns strings like "34s", "2m 14s", or "1h 3m" depending on magnitude.
    /// Returns an empty string for zero or negative durations.
    private func formatInspectorRuntime(_ seconds: TimeInterval) -> String {
        guard seconds > 0 else { return "" }
        let total = Int(seconds.rounded())
        if total < 60 {
            return "\(total)s"
        } else if total < 3600 {
            let m = total / 60
            let s = total % 60
            return s > 0 ? "\(m)m \(s)s" : "\(m)m"
        } else {
            let h = total / 3600
            let m = (total % 3600) / 60
            return m > 0 ? "\(h)h \(m)m" : "\(h)h"
        }
    }

    /// Resolves each sample record's originating `.lungfishfastq` bundle URL.
    ///
    /// First attempts to walk up the input file path to find a `.lungfishfastq` ancestor.
    /// If that fails (e.g. when materialized temp files have been cleaned up), falls back
    /// to searching the project directory for a bundle whose name contains the sample ID.
    ///
    /// - Parameters:
    ///   - samples: Records from a batch manifest.
    ///   - projectURL: The project root to search as a fallback (optional).
    /// - Returns: Tuples of sample ID and bundle URL (nil when the bundle cannot be located).
    private func resolveBatchSourceSamples(
        _ samples: [MetagenomicsBatchSampleRecord],
        projectURL: URL? = nil
    ) -> [(sampleId: String, bundleURL: URL?)] {
        samples.map { record in
            // Primary: walk up each input file path looking for a .lungfishfastq ancestor.
            var bundleURL = record.inputFiles.first.flatMap { path in
                resolveBundleURL(fromInputFilePath: path)
            }

            // Fallback: search the project directory for a .lungfishfastq bundle whose
            // filename (without extension) contains the sample ID.
            // This handles the common case where inputFiles pointed to materialized temp files
            // that have since been cleaned up.
            if bundleURL == nil, let projectURL {
                bundleURL = findBundleInProject(projectURL, matchingSampleId: record.sampleId)
            }

            return (sampleId: record.sampleId, bundleURL: bundleURL)
        }
    }

    /// Searches a project directory tree for a `.lungfishfastq` bundle whose filename
    /// (without extension) contains the given sample ID (case-insensitive).
    ///
    /// Only searches two levels deep to stay fast: `<project>/` and `<project>/Imports/`.
    ///
    /// - Parameters:
    ///   - projectURL: The project root directory.
    ///   - sampleId: The sample ID to match against bundle filenames.
    /// - Returns: The first matching `.lungfishfastq` bundle URL, or nil.
    private func findBundleInProject(_ projectURL: URL, matchingSampleId sampleId: String) -> URL? {
        let fm = FileManager.default
        let lowerSampleId = sampleId.lowercased()

        func searchDirectory(_ dir: URL) -> URL? {
            guard let entries = try? fm.contentsOfDirectory(
                at: dir,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            ) else { return nil }

            return entries.first { entry in
                guard entry.pathExtension.lowercased() == "lungfishfastq" else { return false }
                var isDir: ObjCBool = false
                guard fm.fileExists(atPath: entry.path, isDirectory: &isDir), isDir.boolValue else { return false }
                let bundleName = entry.deletingPathExtension().lastPathComponent.lowercased()
                return bundleName.contains(lowerSampleId) || lowerSampleId.contains(bundleName)
            }
        }

        // Search project root.
        if let found = searchDirectory(projectURL) { return found }

        // Search project/Imports/.
        let importsDir = projectURL.appendingPathComponent("Imports")
        if let found = searchDirectory(importsDir) { return found }

        return nil
    }

    /// Walks up a file path to find the enclosing `.lungfishfastq` bundle directory.
    ///
    /// Input files inside FASTQ bundles live at paths like:
    /// `.../SampleA.lungfishfastq/reads.fastq.gz`
    /// This helper climbs ancestors until it finds a directory with the `.lungfishfastq` extension.
    ///
    /// - Parameter path: Absolute file path to start from.
    /// - Returns: The `.lungfishfastq` directory URL, or nil if none is found.
    private func resolveBundleURL(fromInputFilePath path: String) -> URL? {
        var url = URL(fileURLWithPath: path)
        // Walk up until we hit the root or find a .lungfishfastq directory.
        while url.pathComponents.count > 1 {
            url = url.deletingLastPathComponent()
            if url.pathExtension.lowercased() == "lungfishfastq" {
                var isDir: ObjCBool = false
                if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue {
                    return url
                }
            }
        }
        return nil
    }

    /// Displays a NAO-MGS surveillance result from its bundle directory.
    ///
    /// Reads the manifest and virus hits JSON from the bundle, then
    /// displays the NAO-MGS result viewer. Falls back to re-parsing the
    /// original TSV if the cached JSON is missing.
    ///
    /// - Parameter url: The `naomgs-*` bundle directory.
    private func displayNaoMgsResultFromSidebar(at url: URL) {
        logger.info("displayNaoMgsResult: Opening '\(url.lastPathComponent, privacy: .public)'")

        // Show a placeholder immediately so the user gets feedback while we load.
        let placeholderVC = NaoMgsResultViewController()
        viewerController.displayNaoMgsResult(placeholderVC)

        // Two-phase load: manifest first (fast) for instant taxon list,
        // then SQLite database (slow) for detail queries.
        let bundleURL = url
        Task {
            do {
                let fm = FileManager.default
                let decoder = JSONDecoder()
                decoder.dateDecodingStrategy = .iso8601

                // Phase 1: Read manifest (fast — small JSON file).
                let manifestURL = bundleURL.appendingPathComponent("manifest.json")
                guard fm.fileExists(atPath: manifestURL.path) else {
                    throw NSError(domain: "NaoMgsDisplay", code: 1,
                                  userInfo: [NSLocalizedDescriptionKey: "manifest.json not found in NAO-MGS bundle"])
                }
                let manifestData = try Data(contentsOf: manifestURL)
                let manifest = try decoder.decode(NaoMgsManifest.self, from: manifestData)

                // If manifest has cached taxon rows, show them immediately.
                if let cachedRows = manifest.cachedTaxonRows, !cachedRows.isEmpty {
                    DispatchQueue.main.async { [weak self] in
                        MainActor.assumeIsolated {
                            guard let self else { return }
                            placeholderVC.configureWithCachedRows(cachedRows, manifest: manifest, bundleURL: bundleURL)
                            self.inspectorController?.updateNaoMgsManifest(manifest)
                            logger.info("displayNaoMgsResult: Showing \(cachedRows.count) cached taxon rows instantly")
                        }
                    }
                }

                // Phase 2: Open SQLite database (slow — full file I/O + SQLite init).
                let dbURL = bundleURL.appendingPathComponent("hits.sqlite")
                guard fm.fileExists(atPath: dbURL.path) else {
                    throw NSError(domain: "NaoMgsDisplay", code: 2,
                                  userInfo: [NSLocalizedDescriptionKey: "hits.sqlite not found — bundle may need re-import"])
                }
                try await upgradeNaoMgsBundleIfNeeded(bundleURL: bundleURL, manifest: manifest)
                let database = try NaoMgsDatabase(at: dbURL)

                DispatchQueue.main.async { [weak self] in
                    MainActor.assumeIsolated {
                        guard let self else { return }
                        // Full configure with database — enables detail queries, filtering, BLAST.
                        placeholderVC.configure(database: database, manifest: manifest, bundleURL: bundleURL)

                        // Update inspector with NAO-MGS manifest info
                        self.inspectorController?.updateNaoMgsManifest(manifest)

                        // Wire sample picker state to Inspector for embedded sample selector
                        let knownIds = Set(placeholderVC.sampleEntries.map(\.id))
                        let metadataStore = SampleMetadataStore.load(from: bundleURL, knownSampleIds: knownIds)
                        metadataStore?.wireAutosave(bundleURL: bundleURL)
                        let attachmentStore = BundleAttachmentStore(bundleURL: bundleURL)
                        placeholderVC.sampleMetadataStore = metadataStore
                        self.inspectorController?.updateClassifierSampleState(
                            pickerState: placeholderVC.samplePickerState,
                            entries: placeholderVC.sampleEntries,
                            strippedPrefix: placeholderVC.strippedPrefix,
                            metadata: metadataStore,
                            attachments: attachmentStore
                        )

                        let totalHits = (try? database.totalHitCount()) ?? manifest.hitCount
                        logger.info("displayNaoMgsResult: Configured with database, \(totalHits) hits")
                    }
                }
            } catch {
                DispatchQueue.main.async { [weak self] in
                    MainActor.assumeIsolated {
                        guard let self else { return }
                        logger.error("displayNaoMgsResult: Failed - \(error.localizedDescription, privacy: .public)")
                        let alert = NSAlert()
                        alert.messageText = "Failed to Load NAO-MGS Result"
                        alert.informativeText = error.localizedDescription
                        alert.alertStyle = .warning
                        alert.addButton(withTitle: "OK")
                        if let window = self.view.window ?? NSApp.keyWindow {
                            alert.beginSheetModal(for: window)
                        }
                    }
                }
            }
        }
    }

    private func upgradeNaoMgsBundleIfNeeded(bundleURL: URL, manifest: NaoMgsManifest) async throws {
        let dbURL = bundleURL.appendingPathComponent("hits.sqlite")
        guard try naomgsBundleNeedsUpgrade(dbURL: dbURL) else { return }

        let sourceURLs = resolveNaoMgsSourceURLs(from: manifest.sourceFilePath)
        guard !sourceURLs.isEmpty else {
            logger.warning("NAO-MGS bundle upgrade skipped: source TSV missing for \(bundleURL.lastPathComponent, privacy: .public)")
            return
        }

        logger.info("Upgrading NAO-MGS bundle derived data from source TSV for \(bundleURL.lastPathComponent, privacy: .public)")

        let tempURL = bundleURL.appendingPathComponent(".hits-upgrade-\(UUID().uuidString).sqlite")
        _ = try await NaoMgsDatabase.createStreaming(at: tempURL, from: sourceURLs)
        do {
            let rwDB = try NaoMgsDatabase.openReadWrite(at: tempURL)
            try rwDB.updateBamPaths(naomgsBamPathsBySample(in: bundleURL))
            try rwDB.deleteVirusHitsAndVacuum()
        }

        try? FileManager.default.removeItem(at: dbURL)
        try? FileManager.default.removeItem(at: URL(fileURLWithPath: dbURL.path + "-wal"))
        try? FileManager.default.removeItem(at: URL(fileURLWithPath: dbURL.path + "-shm"))
        try FileManager.default.moveItem(at: tempURL, to: dbURL)

        let tempWal = URL(fileURLWithPath: tempURL.path + "-wal")
        let tempShm = URL(fileURLWithPath: tempURL.path + "-shm")
        if FileManager.default.fileExists(atPath: tempWal.path) {
            try? FileManager.default.moveItem(at: tempWal, to: URL(fileURLWithPath: dbURL.path + "-wal"))
        }
        if FileManager.default.fileExists(atPath: tempShm.path) {
            try? FileManager.default.moveItem(at: tempShm, to: URL(fileURLWithPath: dbURL.path + "-shm"))
        }
    }

    private func naomgsBundleNeedsUpgrade(dbURL: URL) throws -> Bool {
        let database = try NaoMgsDatabase(at: dbURL)
        let rows = try database.fetchTaxonSummaryRows()
        guard let first = rows.first else { return false }
        let readNames = try database.fetchReadNames(sample: first.sample, taxId: first.taxId)
        return readNames.isEmpty
    }

    private func resolveNaoMgsSourceURLs(from sourceFilePath: String) -> [URL] {
        let sourceURL = URL(fileURLWithPath: sourceFilePath)
        let fm = FileManager.default
        guard fm.fileExists(atPath: sourceURL.path) else { return [] }

        let parent = sourceURL.deletingLastPathComponent()
        let basename = sourceURL.lastPathComponent.lowercased()
        guard let candidates = try? fm.contentsOfDirectory(
            at: parent,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else {
            return [sourceURL]
        }

        let grouped = candidates.filter { url in
            let name = url.lastPathComponent.lowercased()
            guard name.contains("virus_hits") else { return false }
            return name.hasSuffix(".tsv") || name.hasSuffix(".tsv.gz")
        }.sorted { $0.lastPathComponent < $1.lastPathComponent }

        if basename.contains("virus_hits"), !grouped.isEmpty {
            return grouped
        }
        return [sourceURL]
    }

    private func naomgsBamPathsBySample(in bundleURL: URL) -> [String: (bamPath: String, bamIndexPath: String?)] {
        let fm = FileManager.default
        let bamDir = bundleURL.appendingPathComponent("bams")
        guard let bamFiles = try? fm.contentsOfDirectory(
            at: bamDir,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else {
            return [:]
        }

        var result: [String: (bamPath: String, bamIndexPath: String?)] = [:]
        for bamURL in bamFiles where bamURL.pathExtension == "bam" {
            let sample = bamURL.deletingPathExtension().lastPathComponent
            let relativeBamPath = "bams/\(bamURL.lastPathComponent)"
            let baiURL = URL(fileURLWithPath: bamURL.path + ".bai")
            let csiURL = URL(fileURLWithPath: bamURL.path + ".csi")
            let relativeIndexPath: String?
            if fm.fileExists(atPath: baiURL.path) {
                relativeIndexPath = "bams/\(baiURL.lastPathComponent)"
            } else if fm.fileExists(atPath: csiURL.path) {
                relativeIndexPath = "bams/\(csiURL.lastPathComponent)"
            } else {
                relativeIndexPath = nil
            }
            result[sample] = (relativeBamPath, relativeIndexPath)
        }
        return result
    }

    /// Displays an NVD result from its bundle directory.
    ///
    /// Two-phase loading: manifest first (fast) for instant contig list,
    /// then SQLite database (slower) for full detail queries.
    ///
    /// - Parameter url: The `nvd-*` bundle directory.
    private func displayNvdResultFromSidebar(at url: URL) {
        logger.info("displayNvdResult: Opening '\(url.lastPathComponent, privacy: .public)'")

        // Show a placeholder immediately so the user gets feedback while we load.
        let placeholderVC = NvdResultViewController()
        viewerController.displayNvdResult(placeholderVC)

        // Two-phase load: manifest first (fast) for instant contig list,
        // then SQLite database (slower) for detail queries.
        let bundleURL = url
        Task {
            do {
                let fm = FileManager.default
                let decoder = JSONDecoder()
                decoder.dateDecodingStrategy = .iso8601

                // Phase 1: Read manifest (fast — small JSON file).
                let manifestURL = bundleURL.appendingPathComponent("manifest.json")
                guard fm.fileExists(atPath: manifestURL.path) else {
                    throw NSError(domain: "NvdDisplay", code: 1,
                                  userInfo: [NSLocalizedDescriptionKey: "manifest.json not found in NVD bundle"])
                }
                let manifestData = try Data(contentsOf: manifestURL)
                let manifest = try decoder.decode(NvdManifest.self, from: manifestData)

                // If manifest has cached contig rows, show them immediately.
                if let cachedRows = manifest.cachedTopContigs, !cachedRows.isEmpty {
                    DispatchQueue.main.async { [weak self] in
                        MainActor.assumeIsolated {
                            guard let self else { return }
                            placeholderVC.configureWithCachedRows(cachedRows, manifest: manifest, bundleURL: bundleURL)
                            self.inspectorController?.updateNvdManifest(manifest)
                            logger.info("displayNvdResult: Showing \(cachedRows.count) cached contig rows instantly")
                        }
                    }
                }

                // Phase 2: Open SQLite database (slower — full file I/O + SQLite init).
                let dbURL = bundleURL.appendingPathComponent("hits.sqlite")
                guard fm.fileExists(atPath: dbURL.path) else {
                    throw NSError(domain: "NvdDisplay", code: 2,
                                  userInfo: [NSLocalizedDescriptionKey: "hits.sqlite not found — bundle may need re-import"])
                }
                let database = try NvdDatabase(at: dbURL)

                DispatchQueue.main.async { [weak self] in
                    MainActor.assumeIsolated {
                        guard let self else { return }
                        // Full configure with database — enables detail queries, filtering, BLAST.
                        placeholderVC.configure(database: database, manifest: manifest, bundleURL: bundleURL)

                        // Update inspector with NVD manifest info
                        self.inspectorController?.updateNvdManifest(manifest)

                        // Wire sample picker state to Inspector for embedded sample selector
                        let knownIds = Set(placeholderVC.sampleEntries.map(\.id))
                        let metadataStore = SampleMetadataStore.load(from: bundleURL, knownSampleIds: knownIds)
                        metadataStore?.wireAutosave(bundleURL: bundleURL)
                        let attachmentStore = BundleAttachmentStore(bundleURL: bundleURL)
                        placeholderVC.sampleMetadataStore = metadataStore
                        self.inspectorController?.updateClassifierSampleState(
                            pickerState: placeholderVC.samplePickerState,
                            entries: placeholderVC.sampleEntries,
                            strippedPrefix: placeholderVC.strippedPrefix,
                            metadata: metadataStore,
                            attachments: attachmentStore
                        )

                        let totalHits = (try? database.totalHitCount()) ?? manifest.hitCount
                        logger.info("displayNvdResult: Configured with database, \(totalHits) hits")
                    }
                }
            } catch {
                DispatchQueue.main.async { [weak self] in
                    MainActor.assumeIsolated {
                        guard let self else { return }
                        logger.error("displayNvdResult: Failed - \(error.localizedDescription, privacy: .public)")
                        let alert = NSAlert()
                        alert.messageText = "Failed to Load NVD Result"
                        alert.informativeText = error.localizedDescription
                        alert.alertStyle = .warning
                        alert.addButton(withTitle: "OK")
                        if let window = self.view.window ?? NSApp.keyWindow {
                            alert.beginSheetModal(for: window)
                        }
                    }
                }
            }
        }
    }

    /// Reads the first line of each FASTA file in `referencesDirectory` to build
    /// an accession → organism name dictionary.
    ///
    /// FASTA headers have the form: `>{accession} {organism description}`.
    /// Only the first line of each file is read (fast — no full parse needed).
    private static func buildAccessionNameMap(referencesDirectory: URL) -> [String: String] {
        let fm = FileManager.default
        guard fm.fileExists(atPath: referencesDirectory.path),
              let enumerator = fm.enumerator(
                at: referencesDirectory,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants]
              ) else { return [:] }

        var map: [String: String] = [:]
        for case let fileURL as URL in enumerator {
            guard fileURL.pathExtension.lowercased() == "fasta",
                  let handle = try? FileHandle(forReadingFrom: fileURL) else { continue }
            // Read just the first 512 bytes — enough for any FASTA header line.
            let headerData = handle.readData(ofLength: 512)
            try? handle.close()
            guard let headerStr = String(data: headerData, encoding: .utf8) else { continue }
            let firstLine = headerStr.components(separatedBy: "\n").first ?? ""
            guard firstLine.hasPrefix(">") else { continue }
            let withoutCaret = firstLine.dropFirst() // remove ">"
            let parts = withoutCaret.split(separator: " ", maxSplits: 1)
            guard parts.count == 2 else { continue }
            let accession = String(parts[0])
            var organism = String(parts[1])
            // Trim trailing whitespace / carriage return
            organism = organism.trimmingCharacters(in: .whitespacesAndNewlines)
            if !organism.isEmpty {
                map[accession] = organism
            }
        }
        return map
    }

    /// Derives a best-fit organism name for each taxon by finding the most common
    /// accession for that taxon and looking it up in `accessionToName`.
    private static func deriveTaxonNames(
        hits: [NaoMgsVirusHit],
        accessionToName: [String: String]
    ) -> [Int: String] {
        // Count how many times each accession appears per taxId.
        var taxIdAccCounts: [Int: [String: Int]] = [:]
        for hit in hits where !hit.subjectSeqId.isEmpty {
            taxIdAccCounts[hit.taxId, default: [:]][hit.subjectSeqId, default: 0] += 1
        }

        // Also collect subjectTitle from hits (v1 format has these).
        var taxIdTitleCounts: [Int: [String: Int]] = [:]
        for hit in hits where !hit.subjectTitle.isEmpty {
            taxIdTitleCounts[hit.taxId, default: [:]][hit.subjectTitle, default: 0] += 1
        }

        var result: [Int: String] = [:]
        for (taxId, accCounts) in taxIdAccCounts {
            // Pick the accession with the most hits.
            guard let topAcc = accCounts.max(by: { $0.value < $1.value })?.key else { continue }
            // Try exact accession first, then version-stripped (e.g. "KU162869" from "KU162869.1").
            if let name = accessionToName[topAcc] {
                result[taxId] = name
            } else {
                let versionless = String(topAcc.prefix(while: { $0 != "." }))
                if let name = accessionToName.first(where: { $0.key.hasPrefix(versionless) })?.value {
                    result[taxId] = name
                }
            }
        }

        // Fallback: for taxa without FASTA-derived names, use subjectTitle from the hits.
        for (taxId, titleCounts) in taxIdTitleCounts where result[taxId] == nil {
            if let topTitle = titleCounts.max(by: { $0.value < $1.value })?.key {
                // Clean up the title: sometimes it includes accession prefix
                var cleanTitle = topTitle
                // Remove "complete genome" / "complete genome, monopartite" suffixes for cleaner display
                cleanTitle = cleanTitle.trimmingCharacters(in: .whitespacesAndNewlines)
                if !cleanTitle.isEmpty {
                    result[taxId] = cleanTitle
                }
            }
        }

        return result
    }

    /// Navigates to a related metagenomics analysis from TaxTriage cross-links.
    ///
    /// Called when the user clicks a "View Kraken2" or "View EsViritu" button
    /// in the TaxTriage action bar. Routes to the appropriate display method.
    ///
    /// - Parameters:
    ///   - type: The analysis type ("kraken2" or "esviritu").
    ///   - url: The result directory URL.
    func navigateToRelatedAnalysis(type: String, url: URL) {
        logger.info("navigateToRelatedAnalysis: type=\(type, privacy: .public), url=\(url.lastPathComponent, privacy: .public)")
        routeClassifierDisplay(url: url)
    }

    /// Display genomics file - cache-first, then load via DocumentManager.
    private func displayGenomicsFile(url: URL) {
        // FASTQ bundles use the streaming statistics dashboard
        if FASTQBundle.isBundleURL(url) {
            loadFASTQDatasetInBackground(sourceURL: url)
            return
        }

        // Naked FASTQ files in the project: auto-bundle in place, then display the bundle
        if FASTQBundle.isFASTQFileURL(url),
           !FASTQBundle.isBundleURL(url.deletingLastPathComponent()) {
            let parentDir = url.deletingLastPathComponent()
            let baseName = FASTQBundle.deriveBaseName(from: url)
            let bundleURL = parentDir.appendingPathComponent("\(baseName).\(FASTQBundle.directoryExtension)")

            // If bundle already exists (e.g. from a previous partial import), just display it
            if FASTQBundle.isBundleURL(bundleURL) {
                loadFASTQDatasetInBackground(sourceURL: bundleURL)
                return
            }

            // Wrap naked file into a bundle in place (no ingestion — it may already be ingested)
            let fm = FileManager.default
            do {
                try fm.createDirectory(at: bundleURL, withIntermediateDirectories: true)
                let destURL = bundleURL.appendingPathComponent(url.lastPathComponent)
                try fm.moveItem(at: url, to: destURL)
                // Move sidecar too if it exists
                let sidecarName = url.lastPathComponent + ".lungfish-meta.json"
                let sidecarURL = parentDir.appendingPathComponent(sidecarName)
                if fm.fileExists(atPath: sidecarURL.path) {
                    try fm.moveItem(at: sidecarURL, to: bundleURL.appendingPathComponent(sidecarName))
                }
                logger.info("displayGenomicsFile: Auto-bundled naked FASTQ \(url.lastPathComponent) → \(bundleURL.lastPathComponent)")
                sidebarController.reloadFromFilesystem()
                loadFASTQDatasetInBackground(sourceURL: bundleURL)
            } catch {
                logger.error("displayGenomicsFile: Failed to auto-bundle FASTQ: \(error)")
                // Fall back to displaying naked file
                loadFASTQDatasetInBackground(sourceURL: url)
            }
            return
        }

        // FASTQ file inside a bundle — just display it
        if FASTQBundle.resolvePrimaryFASTQURL(for: url) != nil {
            loadFASTQDatasetInBackground(sourceURL: url)
            return
        }

        cancelFASTQLoadIfNeeded(hideProgress: true, reason: "displaying non-FASTQ file \(url.lastPathComponent)")

        // Standalone VCF files use the auto-ingestion pipeline
        if Self.isVCFFile(url) {
            loadVCFFilesInBackground(urls: [url])
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
        FASTQBundle.isBundleURL(url) || FASTQBundle.resolvePrimaryFASTQURL(for: url) != nil
    }

    /// Returns true if the URL points to a VCF file (by extension).
    static func isVCFFile(_ url: URL) -> Bool {
        var checkURL = url
        if checkURL.pathExtension.lowercased() == "gz" {
            checkURL = checkURL.deletingPathExtension()
        }
        return checkURL.pathExtension.lowercased() == "vcf"
    }

    /// Loads one or more standalone VCF files into a single auto-ingested bundle.
    func loadVCFFilesInBackground(urls: [URL]) {
        guard !urls.isEmpty else { return }
        let fileCount = urls.count
        logger.info("loadVCFFilesInBackground: Auto-ingesting \(fileCount) VCF file(s)")

        guard let viewerController = self.viewerController else {
            logger.warning("loadVCFFilesInBackground: Viewer controller not available")
            return
        }

        guard let projectURL = sidebarController.currentProjectURL ?? DocumentManager.shared.activeProject?.url else {
            logger.error("loadVCFFilesInBackground: No active project; refusing non-project bundle import")
            let alert = NSAlert()
            alert.messageText = "No Active Project"
            alert.informativeText = "Open or create a project first. VCF imports are saved as .lungfishref bundles inside the active project."
            alert.alertStyle = .warning
            alert.addButton(withTitle: "OK")
            if let window = self.view.window ?? NSApp.keyWindow {
                alert.beginSheetModal(for: window)
            }
            return
        }
        try? FileManager.default.createDirectory(at: projectURL, withIntermediateDirectories: true)

        let defaultBundleName: String = {
            let base = urls.first?.deletingPathExtension().deletingPathExtension().lastPathComponent ?? "VCF Variants"
            let normalized = base.trimmingCharacters(in: .whitespacesAndNewlines)
            return normalized.isEmpty ? "VCF Variants" : normalized
        }()
        Task { @MainActor [weak self] in
            guard let self else { return }
            guard let bundleSelection = await self.promptForVCFBundleName(
                defaultName: defaultBundleName,
                projectDirectory: projectURL
            ) else {
                logger.info("loadVCFFilesInBackground: User cancelled VCF import bundle naming")
                return
            }

            let label = fileCount == 1
                ? "Importing VCF file\u{2026}"
                : "Importing \(fileCount) VCF files\u{2026}"
            viewerController.showProgress(label)

            Task.detached(priority: .userInitiated) { [weak self] in
                do {
                    let result = try await VCFAutoIngestor.ingest(
                        vcfURLs: urls,
                        outputDirectory: projectURL,
                        preferredBundleName: bundleSelection.bundleName,
                        replaceExistingBundle: bundleSelection.replaceExisting,
                        progressHandler: { progress, message in
                            DispatchQueue.main.async { [weak viewerController] in
                                MainActor.assumeIsolated {
                                    viewerController?.showProgress(message)
                                }
                            }
                        }
                    )

                    logger.info("loadVCFFilesInBackground: Bundle created at \(result.bundleURL.lastPathComponent, privacy: .public) with \(result.variantCount) variants from \(fileCount) file(s)")

                    let bundleURL = result.bundleURL
                    DispatchQueue.main.async { [weak self, weak viewerController] in
                        MainActor.assumeIsolated {
                            viewerController?.hideProgress()
                            self?.displayReferenceBundleViewportFromSidebar(at: bundleURL)
                        }
                    }

                    if !result.ncbiAccessions.isEmpty || result.inferredReference.accession != nil {
                        let assemblyName = result.inferredReference.assembly ?? "reference"
                        logger.info("loadVCFFilesInBackground: Starting background reference download for \(assemblyName, privacy: .public)")
                        DispatchQueue.main.async { [weak self] in
                            MainActor.assumeIsolated {
                                self?.downloadReferenceForNakedBundle(
                                    inferredRef: result.inferredReference,
                                    ncbiAccessions: result.ncbiAccessions,
                                    bundleURL: result.bundleURL
                                )
                            }
                        }
                    }

                } catch {
                    let errorMessage = "\(error)"
                    DispatchQueue.main.async { [weak viewerController] in
                        MainActor.assumeIsolated {
                            viewerController?.hideProgress()
                            logger.error("loadVCFFilesInBackground: Failed - \(errorMessage)")

                            let alert = NSAlert()
                            alert.messageText = "Failed to Import VCF Files"
                            alert.informativeText = errorMessage
                            alert.alertStyle = .warning
                            alert.addButton(withTitle: "OK")
                            if let window = viewerController?.view.window ?? NSApp.keyWindow {
                                alert.beginSheetModal(for: window)
                            }
                        }
                    }
                }
            }
        }
    }

    private struct VCFBundleSelection {
        let bundleName: String
        let replaceExisting: Bool
    }

    private func promptForVCFBundleName(defaultName: String, projectDirectory: URL) async -> VCFBundleSelection? {
        let alert = NSAlert()
        alert.messageText = "Name Imported Variant Bundle"
        alert.informativeText = "This bundle will be saved inside the active project:\n\(projectDirectory.path)"
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Create")
        alert.addButton(withTitle: "Cancel")

        let textField = NSTextField(string: defaultName)
        textField.placeholderString = "Bundle Name"
        textField.frame = NSRect(x: 0, y: 0, width: 320, height: 24)
        alert.accessoryView = textField

        guard let window = self.view.window ?? NSApp.keyWindow else { return nil }
        let response = await alert.beginSheetModal(for: window)
        guard response == .alertFirstButtonReturn else { return nil }
        let trimmed = textField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let bundleName = trimmed.isEmpty ? defaultName : trimmed
        let targetURL = projectDirectory.appendingPathComponent("\(bundleName).lungfishref", isDirectory: true)
        return VCFBundleSelection(
            bundleName: bundleName,
            replaceExisting: FileManager.default.fileExists(atPath: targetURL.path)
        )
    }

    /// Silently downloads reference genome for a naked (variant-only) bundle.
    ///
    /// Tries two strategies in order:
    /// 1. NCBI Assembly search (gives full genome FASTA + GFF3 annotations)
    /// 2. GenBank nucleotide fetch by accession (fallback for single-contig organisms)
    ///
    /// On completion, updates the bundle's manifest with genome info
    /// and reloads the bundle in the viewer.
    private func downloadReferenceForNakedBundle(
        inferredRef: ReferenceInference.Result,
        ncbiAccessions: [String],
        bundleURL: URL
    ) {
        let assemblyName = inferredRef.assembly ?? ncbiAccessions.first ?? "Reference"

        let downloadID = DownloadCenter.shared.start(
            title: "\(assemblyName) Reference",
            detail: "Searching NCBI\u{2026}"
        )

        Task.detached { [weak self] in
            do {
                let tempDir = try ProjectTempDirectory.createFromContext(
                    prefix: "ref-", contextURL: bundleURL)
                defer { try? FileManager.default.removeItem(at: tempDir) }

                // Strategy 1: Try NCBI Assembly search
                let tempBundleURL = try await Self.tryAssemblyDownload(
                    inferredRef: inferredRef,
                    outputDirectory: tempDir,
                    downloadID: downloadID
                )

                if let sourceBundleURL = tempBundleURL {
                    // Assembly download succeeded — merge into naked bundle
                    try Self.mergeGenomeIntoBundle(
                        sourceBundleURL: sourceBundleURL,
                        targetBundleURL: bundleURL
                    )
                } else if let firstAccession = ncbiAccessions.first {
                    // Strategy 2: Fall back to GenBank nucleotide fetch
                    performOnMainRunLoop {
                        DownloadCenter.shared.update(id: downloadID, progress: 0.15, detail: "Fetching \(firstAccession) from GenBank\u{2026}")
                    }

                    let genBankVM = GenBankBundleDownloadViewModel()
                    let genBankBundleURL = try await genBankVM.downloadAndBuild(
                        accession: firstAccession,
                        outputDirectory: tempDir
                    ) { progress, message in
                        let scaledProgress = 0.15 + progress * 0.8
                        performOnMainRunLoop {
                            DownloadCenter.shared.update(id: downloadID, progress: scaledProgress, detail: message)
                        }
                    }

                    try Self.mergeGenomeIntoBundle(
                        sourceBundleURL: genBankBundleURL,
                        targetBundleURL: bundleURL
                    )
                } else {
                    performOnMainRunLoop {
                        DownloadCenter.shared.fail(id: downloadID, detail: "No reference found for '\(assemblyName)'")
                    }
                    return
                }

                performOnMainRunLoop {
                    DownloadCenter.shared.complete(id: downloadID, detail: "Reference genome added to bundle")
                }

                logger.info("downloadReferenceForNakedBundle: Genome merged into \(bundleURL.lastPathComponent, privacy: .public)")

                // Reload the bundle in the viewer (force reload since URL hasn't changed)
                DispatchQueue.main.async { [weak self] in
                    MainActor.assumeIsolated {
                        self?.displayReferenceBundleViewportFromSidebar(at: bundleURL, forceReload: true)
                    }
                }

            } catch {
                let errorMessage = "\(error)"
                performOnMainRunLoop {
                    DownloadCenter.shared.fail(id: downloadID, detail: errorMessage)
                }
                logger.error("downloadReferenceForNakedBundle: Failed - \(errorMessage)")
            }
        }
    }

    /// Attempts to download reference via NCBI Assembly search.
    /// Returns the temp bundle URL on success, or nil if no assembly found.
    private nonisolated static func tryAssemblyDownload(
        inferredRef: ReferenceInference.Result,
        outputDirectory: URL,
        downloadID: UUID
    ) async throws -> URL? {
        guard let assembly = inferredRef.assembly else { return nil }

        let searchTerm: String
        if let accession = inferredRef.accession {
            searchTerm = accession
        } else {
            searchTerm = "\(inferredRef.organism ?? assembly)[Organism] AND \(assembly)[Assembly Name]"
        }

        let ncbi = NCBIService()

        performOnMainRunLoop {
            DownloadCenter.shared.update(id: downloadID, progress: 0.05, detail: "Searching NCBI Assembly for \(assembly)\u{2026}")
        }

        let ids = try await ncbi.esearch(database: .assembly, term: searchTerm, retmax: 5)
        guard !ids.isEmpty else {
            logger.info("tryAssemblyDownload: No assembly found for '\(searchTerm, privacy: .public)', will try GenBank fallback")
            return nil
        }

        performOnMainRunLoop {
            DownloadCenter.shared.update(id: downloadID, progress: 0.1, detail: "Getting assembly info\u{2026}")
        }

        let summaries = try await ncbi.assemblyEsummary(ids: ids)
        guard let assemblySummary = summaries.first else {
            logger.info("tryAssemblyDownload: No assembly summary for ids=\(ids, privacy: .public), will try GenBank fallback")
            return nil
        }

        performOnMainRunLoop {
            DownloadCenter.shared.update(id: downloadID, progress: 0.15, detail: "Downloading genome files\u{2026}")
        }

        let viewModel = GenomeDownloadViewModel()
        let bundleURL = try await viewModel.downloadAndBuild(
            assembly: assemblySummary,
            outputDirectory: outputDirectory
        ) { progress, message in
            let scaledProgress = 0.15 + progress * 0.8
            performOnMainRunLoop {
                DownloadCenter.shared.update(id: downloadID, progress: scaledProgress, detail: message)
            }
        }

        return bundleURL
    }

    /// Merges genome files from a fully-built temp bundle into a naked (variant-only) bundle.
    private nonisolated static func mergeGenomeIntoBundle(sourceBundleURL: URL, targetBundleURL: URL) throws {
        let fm = FileManager.default

        // Load source manifest to get genome info and annotation tracks
        let sourceManifest = try BundleManifest.load(from: sourceBundleURL)

        // Copy genome directory (remove existing first, ignore if absent)
        let sourceGenomeDir = sourceBundleURL.appendingPathComponent("genome")
        let targetGenomeDir = targetBundleURL.appendingPathComponent("genome")
        try? fm.removeItem(at: targetGenomeDir)
        try fm.copyItem(at: sourceGenomeDir, to: targetGenomeDir)

        // Copy annotation files (remove existing first, ignore if absent)
        let sourceAnnoDir = sourceBundleURL.appendingPathComponent("annotations")
        let targetAnnoDir = targetBundleURL.appendingPathComponent("annotations")
        try? fm.removeItem(at: targetAnnoDir)
        if fm.fileExists(atPath: sourceAnnoDir.path) {
            try fm.copyItem(at: sourceAnnoDir, to: targetAnnoDir)
        }

        // Update target manifest: add genome + annotations from source, keep existing variants
        let targetManifest = try BundleManifest.load(from: targetBundleURL)
        let updatedManifest = BundleManifest(
            formatVersion: targetManifest.formatVersion,
            name: sourceManifest.name.isEmpty ? targetManifest.name : sourceManifest.name,
            identifier: targetManifest.identifier,
            description: targetManifest.description,
            createdDate: targetManifest.createdDate,
            modifiedDate: Date(),
            source: sourceManifest.source,
            genome: sourceManifest.genome,
            annotations: sourceManifest.annotations,
            variants: targetManifest.variants,
            alignments: targetManifest.alignments,
            metadata: targetManifest.metadata
        )
        try updatedManifest.save(to: targetBundleURL)
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

        guard let window = self.view.window ?? NSApp.keyWindow else { return }
        Task { @MainActor [weak self] in
            let response = await alert.beginSheetModal(for: window)
            guard response == .alertFirstButtonReturn else { return }
            self?.performDownloadReferenceForVCF(inferredRef, assembly: assembly)
        }
    }

    /// Continuation of downloadReferenceForVCF after user confirms the download.
    private func performDownloadReferenceForVCF(_ inferredRef: ReferenceInference.Result, assembly: String) {
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

                guard let documentsDir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else {
                    throw DocumentLoadError.fileNotFound(URL(fileURLWithPath: NSHomeDirectory()))
                }
                let genomesDir = documentsDir
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
    /// computes statistics in a single streaming pass and caches them.
    private func loadFASTQDatasetInBackground(sourceURL: URL) {
        let standardizedSourceURL = sourceURL.standardizedFileURL
        let fastqURL = FASTQBundle.resolvePrimaryFASTQURL(for: standardizedSourceURL)?.standardizedFileURL
        let derivedManifest = FASTQBundle.isBundleURL(standardizedSourceURL)
            ? FASTQBundle.loadDerivedManifest(in: standardizedSourceURL)
            : nil
        logger.info("loadFASTQDatasetInBackground: Loading source '\(standardizedSourceURL.lastPathComponent, privacy: .public)'")

        guard let viewerController = self.viewerController else {
            logger.warning("loadFASTQDatasetInBackground: Viewer controller not available")
            return
        }

        // Cancel any previous FASTQ work before starting a new request.
        fastqLoadTask?.cancel()
        fastqLoadTask = nil
        fastqLoadGeneration &+= 1
        let generation = fastqLoadGeneration
        activeFASTQLoadURL = fastqURL
        activeFASTQSourceURL = standardizedSourceURL

        let isCurrentRequest: @MainActor () -> Bool = { [weak self] in
            guard let self = self else { return false }
            return self.fastqLoadGeneration == generation &&
                self.activeFASTQSourceURL?.standardizedFileURL == standardizedSourceURL
        }

        // Derived bundles use cached manifest stats (which reflect the true read count,
        // not the preview file's 1,000-read subset).
        if let derivedManifest {
            viewerController.displayFASTQDataset(
                statistics: derivedManifest.cachedStatistics,
                records: [],
                fastqURL: fastqURL,
                sraRunInfo: nil,
                enaReadRecord: nil,
                ingestionMetadata: derivedManifest.pairingMode.map {
                    IngestionMetadata(
                        isClumpified: true,
                        isCompressed: true,
                        pairingMode: $0,
                        qualityBinning: nil,
                        originalFilenames: [],
                        ingestionDate: derivedManifest.createdAt,
                        originalSizeBytes: nil
                    )
                },
                fastqSourceURL: standardizedSourceURL,
                fastqDerivativeManifest: derivedManifest,
                onRunOperation: { [weak self] request in
                    try await self?.runFASTQOperation(request, sourceURL: standardizedSourceURL)
                }
            )
            return
        }

        guard let fastqURL else {
            logger.error("loadFASTQDatasetInBackground: No FASTQ payload or derivative manifest for '\(standardizedSourceURL.path, privacy: .public)'")
            return
        }

        // Check for cached metadata
        let cachedMeta = FASTQMetadataStore.load(for: fastqURL)
        if let cachedStats = cachedMeta?.computedStatistics {
            logger.info("loadFASTQDatasetInBackground: Using cached statistics (\(cachedStats.readCount) reads)")
            viewerController.displayFASTQDataset(
                statistics: cachedStats,
                records: [],
                fastqURL: fastqURL,
                sraRunInfo: cachedMeta?.sraRunInfo,
                enaReadRecord: cachedMeta?.enaReadRecord,
                ingestionMetadata: cachedMeta?.ingestion,
                fastqSourceURL: standardizedSourceURL,
                fastqDerivativeManifest: derivedManifest,
                onRunOperation: { [weak self] request in
                    try await self?.runFASTQOperation(request, sourceURL: standardizedSourceURL)
                }
            )
            logger.info("loadFASTQDatasetInBackground: Displayed from cache without read table scan")
            return
        }

        viewerController.showProgress("Computing FASTQ statistics...")

        fastqLoadTask = Task.detached(priority: .userInitiated) { [weak self] in
            do {
                let statsResult = try await FASTQStatisticsService.compute(
                    for: fastqURL,
                    progress: { count in
                        guard !Task.isCancelled else { return }
                        DispatchQueue.main.async {
                            MainActor.assumeIsolated {
                                guard isCurrentRequest(), !Task.isCancelled else { return }
                                viewerController.showProgress(
                                    "Computing FASTQ statistics... \(count) reads processed"
                                )
                            }
                        }
                    }
                )
                let statistics = statsResult.statistics
                try Task.checkCancellation()

                // Cache the computed statistics for next time.
                // Skip stale/deleted targets so we don't write sidecars into removed paths.
                if FileManager.default.fileExists(atPath: fastqURL.path) {
                    var metadata = cachedMeta ?? PersistedFASTQMetadata()
                    metadata.computedStatistics = statistics
                    metadata.seqkitStats = statsResult.seqkitMetadata
                    FASTQMetadataStore.save(metadata, for: fastqURL)
                } else {
                    logger.debug("loadFASTQDatasetInBackground: FASTQ deleted before cache write, skipping sidecar save")
                }

                let sraRunInfo = cachedMeta?.sraRunInfo
                let enaReadRecord = cachedMeta?.enaReadRecord
                let ingestionMeta = cachedMeta?.ingestion
                DispatchQueue.main.async { [weak self] in
                    MainActor.assumeIsolated {
                        guard let self = self, isCurrentRequest() else { return }
                        self.fastqLoadTask = nil
                        viewerController.hideProgress()
                        viewerController.displayFASTQDataset(
                            statistics: statistics,
                            records: [],
                            fastqURL: fastqURL,
                            sraRunInfo: sraRunInfo,
                            enaReadRecord: enaReadRecord,
                            ingestionMetadata: ingestionMeta,
                            fastqSourceURL: standardizedSourceURL,
                            fastqDerivativeManifest: derivedManifest,
                            onRunOperation: { [weak self] request in
                                try await self?.runFASTQOperation(request, sourceURL: standardizedSourceURL)
                            }
                        )
                        logger.info("loadFASTQDatasetInBackground: Dashboard displayed with \(statistics.readCount) total reads")
                    }
                }
            } catch is CancellationError {
                logger.debug("loadFASTQDatasetInBackground: Statistics computation cancelled (gen=\(generation))")
            } catch {
                let errorMessage = "\(error)"
                DispatchQueue.main.async { [weak self] in
                    MainActor.assumeIsolated {
                        guard let self = self, isCurrentRequest() else { return }
                        self.fastqLoadTask = nil
                        viewerController.hideProgress()
                        logger.error("loadFASTQDatasetInBackground: Failed - \(errorMessage)")

                        let alert = NSAlert()
                        alert.messageText = "Failed to Analyze FASTQ File"
                        alert.informativeText = errorMessage
                        alert.alertStyle = .warning
                        alert.addButton(withTitle: "OK")
                        alert.applyLungfishBranding()
                        if let window = self.view.window ?? NSApp.keyWindow {
                            alert.beginSheetModal(for: window)
                        }
                    }
                }
            }
        }
    }

    private func runFASTQOperation(_ request: FASTQDerivativeRequest, sourceURL: URL) async throws {
        let inputURLs = selectedFASTQOperationSources(fallback: sourceURL)
        let sourceBundleURLs = try inputURLs.map(resolveFASTQOperationSourceBundle(from:))

        // Resolve the FASTQ path for CLI command display.
        // For bundles, use the bundle path as the representative input.
        let displayInputPath = sourceBundleURLs.first?.path ?? sourceURL.path
        let displayOutputPath = "<derived>"
        let cliCmd = request.cliCommand(inputPath: displayInputPath, outputPath: displayOutputPath)

        // Register with OperationCenter for visibility in the Operations panel
        let opTitle = "FASTQ: \(request.operationLabel)"
        let startTime = Date()
        let opID: UUID = OperationCenter.shared.start(
            title: opTitle,
            detail: "Preparing...",
            operationType: .fastqOperation,
            cliCommand: cliCmd
        )
        OperationCenter.shared.log(id: opID, level: .info, message: "Starting \(request.operationLabel)")
        if sourceBundleURLs.count > 1 {
            OperationCenter.shared.log(
                id: opID, level: .info,
                message: "Batch mode: \(sourceBundleURLs.count) input bundles"
            )
        }

        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                self?.viewerController.updateFASTQOperationStatus("Running FASTQ/FASTA operation...")
            }
        }

        do {
            let derivedURLs: [URL]
            let failureCount: Int

            if sourceBundleURLs.count > 1 {
                let commonParentDirectory = sharedFASTQOperationParentDirectory(for: sourceBundleURLs)
                let batchResult = try await FASTQDerivativeService.shared.createBatchDerivative(
                    from: sourceBundleURLs,
                    request: request,
                    commonParentDirectory: commonParentDirectory,
                    progress: { [weak self] fraction, message in
                        DispatchQueue.main.async {
                            MainActor.assumeIsolated {
                                guard let self else { return }
                                self.viewerController.updateFASTQOperationStatus(message)
                                OperationCenter.shared.update(id: opID, progress: fraction, detail: message)
                                OperationCenter.shared.log(id: opID, level: .info, message: message)
                            }
                        }
                    }
                )
                derivedURLs = batchResult.outputBundleURLs
                failureCount = batchResult.failures.count
                if !batchResult.failures.isEmpty {
                    for failure in batchResult.failures {
                        OperationCenter.shared.log(
                            id: opID, level: .warning,
                            message: "Failed: \(failure.inputURL.lastPathComponent) - \(failure.error)"
                        )
                    }
                }
            } else if let sourceBundleURL = sourceBundleURLs.first {
                let derivedURL = try await FASTQDerivativeService.shared.createDerivative(
                    from: sourceBundleURL,
                    request: request,
                    progress: { [weak self] message in
                        DispatchQueue.main.async {
                            MainActor.assumeIsolated {
                                guard let self else { return }
                                self.viewerController.updateFASTQOperationStatus(message)
                                OperationCenter.shared.update(id: opID, progress: -1, detail: message)
                                OperationCenter.shared.log(id: opID, level: .info, message: message)
                            }
                        }
                    }
                )
                derivedURLs = [derivedURL]
                failureCount = 0
            } else {
                derivedURLs = []
                failureCount = 0
            }

            if derivedURLs.isEmpty && sourceBundleURLs.count > 1 && failureCount > 0 {
                throw FASTQDerivativeError.emptyResult
            }

            let elapsed = Date().timeIntervalSince(startTime)
            let doneDetail: String
            if failureCount > 0 {
                doneDetail = "Done (\(derivedURLs.count) produced, \(failureCount) failed) in \(String(format: "%.1f", elapsed))s"
            } else {
                doneDetail = "Done in \(String(format: "%.1f", elapsed))s"
            }

            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    OperationCenter.shared.log(
                        id: opID, level: .info,
                        message: "Completed in \(String(format: "%.1f", elapsed))s"
                    )
                    OperationCenter.shared.complete(id: opID, detail: doneDetail)
                    if let last = derivedURLs.last {
                        self.refreshSidebarAndSelectDerivedURL(last)
                    } else {
                        self.sidebarController.reloadFromFilesystem()
                    }
                    self.requestInspectorDocumentModeAfterDownload()
                }
            }
        } catch is CancellationError {
            let elapsed = Date().timeIntervalSince(startTime)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    OperationCenter.shared.log(
                        id: opID, level: .info,
                        message: "Cancelled after \(String(format: "%.1f", elapsed))s"
                    )
                    OperationCenter.shared.fail(
                        id: opID,
                        detail: "Cancelled by user"
                    )
                }
            }
            throw CancellationError()
        } catch {
            let elapsed = Date().timeIntervalSince(startTime)
            let errorDesc = error.localizedDescription
            let errorDetail: String
            if let derivativeError = error as? FASTQDerivativeError {
                errorDetail = derivativeError.errorDescription ?? "\(error)"
            } else {
                errorDetail = "\(error)"
            }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    OperationCenter.shared.log(
                        id: opID, level: .error,
                        message: "Failed after \(String(format: "%.1f", elapsed))s: \(errorDesc)"
                    )
                    OperationCenter.shared.fail(
                        id: opID,
                        detail: "Failed after \(String(format: "%.1f", elapsed))s",
                        errorMessage: errorDesc,
                        errorDetail: errorDetail
                    )
                }
            }
            throw error
        }
    }

    func runFASTQOperationLaunchRequest(
        _ request: FASTQOperationLaunchRequest,
        preferredOutputDirectory: URL? = nil
    ) {
        if case .assemble(let assemblyRequest, _) = request {
            Task { @MainActor [weak self] in
                guard let self else { return }
                if let warning = await AssemblyRuntimePreflight.warningMessage(for: assemblyRequest) {
                    AssemblyRuntimePreflight.presentWarning(
                        message: warning,
                        for: assemblyRequest.tool,
                        on: self.view.window ?? NSApp.keyWindow
                    )
                    return
                }
                self.runFASTQOperationLaunchRequestValidated(
                    request,
                    preferredOutputDirectory: preferredOutputDirectory
                )
            }
            return
        }

        runFASTQOperationLaunchRequestValidated(request, preferredOutputDirectory: preferredOutputDirectory)
    }

    private func runFASTQOperationLaunchRequestValidated(
        _ request: FASTQOperationLaunchRequest,
        preferredOutputDirectory: URL? = nil
    ) {
        let currentProjectURL = sidebarController.currentProjectURL?.standardizedFileURL
        let destinationRoot = preferredOutputDirectory?.standardizedFileURL
            ?? currentProjectURL?.appendingPathComponent("Analyses", isDirectory: true)
            ?? request.primaryInputURL?.deletingLastPathComponent().standardizedFileURL
            ?? FileManager.default.temporaryDirectory

        do {
            try FileManager.default.createDirectory(at: destinationRoot, withIntermediateDirectories: true)
        } catch {
            logger.error("runFASTQOperationLaunchRequest: Failed to create destination root: \(error.localizedDescription, privacy: .public)")
            return
        }

        let workingDirectory: URL
        if case .assemble(let assemblyRequest, _) = request,
           let currentProjectURL {
            do {
                workingDirectory = try AnalysesFolder.createAnalysisDirectory(
                    tool: assemblyRequest.tool.rawValue,
                    in: currentProjectURL
                )
            } catch {
                logger.error("runFASTQOperationLaunchRequest: Failed to create analysis directory: \(error.localizedDescription, privacy: .public)")
                return
            }
        } else if request.outputMode == .groupedResult || request.isDemultiplexRequest {
            workingDirectory = uniqueFASTQOperationOutputDirectory(
                in: destinationRoot,
                request: request
            )
        } else {
            workingDirectory = destinationRoot
        }

        let executionService = FASTQOperationExecutionService(
            directImporter: BundleFASTQOperationImporter(destinationDirectory: destinationRoot)
        )
        let cliCommand: String? = try? {
            let invocation = try executionService.buildInvocation(for: request)
            return ([ "lungfish-cli", invocation.subcommand ] + invocation.arguments).joined(separator: " ")
        }()

        let opTitle = "FASTQ: \(request.operationDisplayTitle)"
        let startTime = Date()
        let opID: UUID = OperationCenter.shared.start(
            title: opTitle,
            detail: "Preparing...",
            operationType: .fastqOperation,
            cliCommand: cliCommand
        )
        OperationCenter.shared.log(id: opID, level: .info, message: "Starting \(request.operationDisplayTitle)")

        viewerController.updateFASTQOperationStatus("Running FASTQ/FASTA operation...")

        Task.detached(priority: .userInitiated) { [weak self] in
            do {
                let result: FASTQOperationExecutionResult
                if AppUITestConfiguration.current.isEnabled,
                   AppUITestConfiguration.current.backendMode == .deterministic,
                   case .assemble(let assemblyRequest, let outputMode) = request {
                    let uiTestRequest = assemblyRequest.replacingOutputDirectory(with: workingDirectory)
                    try AppUITestAssemblyBackend.writeResult(for: uiTestRequest)
                    result = FASTQOperationExecutionResult(
                        resolvedRequest: .assemble(request: uiTestRequest, outputMode: outputMode),
                        executedInvocations: [],
                        importedURLs: [workingDirectory],
                        groupedContainerURL: outputMode == .groupedResult ? workingDirectory : nil
                    )
                } else {
                    result = try await executionService.execute(
                        request: request,
                        workingDirectory: workingDirectory
                    )
                }
                let elapsed = Date().timeIntervalSince(startTime)
                let completionTarget = result.groupedContainerURL ?? result.importedURLs.last

                DispatchQueue.main.async { [weak self] in
                    MainActor.assumeIsolated {
                        guard let self else { return }
                        OperationCenter.shared.log(
                            id: opID,
                            level: .info,
                            message: "Completed in \(String(format: "%.1f", elapsed))s"
                        )
                        OperationCenter.shared.complete(
                            id: opID,
                            detail: "Done in \(String(format: "%.1f", elapsed))s"
                        )
                        if let completionTarget {
                            self.recordUITestEvent(
                                "fastq.operation.completed target=\(completionTarget.lastPathComponent)"
                            )
                            self.refreshSidebarAndSelectDerivedURL(completionTarget)
                            switch result.resolvedRequest {
                            case .assemble:
                                self.displayAssemblyAnalysisFromSidebar(at: completionTarget)
                            case .map:
                                self.displayMappingAnalysisFromSidebar(at: completionTarget)
                            default:
                                break
                            }
                        } else {
                            self.sidebarController.reloadFromFilesystem()
                        }
                        self.requestInspectorDocumentModeAfterDownload()
                    }
                }
            } catch is CancellationError {
                let elapsed = Date().timeIntervalSince(startTime)
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        OperationCenter.shared.log(
                            id: opID,
                            level: .info,
                            message: "Cancelled after \(String(format: "%.1f", elapsed))s"
                        )
                        OperationCenter.shared.fail(id: opID, detail: "Cancelled by user")
                    }
                }
            } catch {
                let elapsed = Date().timeIntervalSince(startTime)
                let errorDesc = error.localizedDescription
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        OperationCenter.shared.log(
                            id: opID,
                            level: .error,
                            message: "Failed after \(String(format: "%.1f", elapsed))s: \(errorDesc)"
                        )
                        OperationCenter.shared.fail(
                            id: opID,
                            detail: "Failed after \(String(format: "%.1f", elapsed))s",
                            errorMessage: errorDesc,
                            errorDetail: "\(error)"
                        )
                    }
                }
            }
        }
    }

    private func selectedFASTQOperationSources(fallback sourceURL: URL) -> [URL] {
        let selected = sidebarController.selectedItems().compactMap { item -> URL? in
            guard let url = item.url?.standardizedFileURL else { return nil }
            if FASTQBundle.isBundleURL(url) { return url }
            if FASTQBundle.resolvePrimaryFASTQURL(for: url) != nil { return url }
            return nil
        }
        if selected.isEmpty {
            return [sourceURL.standardizedFileURL]
        }

        var deduped: [URL] = []
        var seen: Set<String> = []
        for url in selected {
            let key = url.path
            guard seen.insert(key).inserted else { continue }
            deduped.append(url)
        }
        return deduped
    }

    private func resolveFASTQOperationSourceBundle(from url: URL) throws -> URL {
        let standardizedSourceURL = url.standardizedFileURL
        if FASTQBundle.isBundleURL(standardizedSourceURL) {
            return standardizedSourceURL
        }
        if standardizedSourceURL.deletingLastPathComponent().pathExtension.lowercased() == FASTQBundle.directoryExtension {
            return standardizedSourceURL.deletingLastPathComponent()
        }
        throw FASTQDerivativeError.sourceMustBeBundle
    }

    private func sharedFASTQOperationParentDirectory(for bundleURLs: [URL]) -> URL? {
        guard let firstParent = bundleURLs.first?.deletingLastPathComponent().standardizedFileURL else {
            return nil
        }
        let allShareParent = bundleURLs.dropFirst().allSatisfy {
            $0.deletingLastPathComponent().standardizedFileURL == firstParent
        }
        return allShareParent ? firstParent : nil
    }

    private func uniqueFASTQOperationOutputDirectory(
        in parentDirectory: URL,
        request: FASTQOperationLaunchRequest
    ) -> URL {
        let baseName = request.operationDisplayTitle
            .lowercased()
            .replacingOccurrences(of: "[^a-z0-9]+", with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        let stem = baseName.isEmpty ? "fastq-operation" : baseName

        var candidate = parentDirectory.appendingPathComponent(stem, isDirectory: true)
        var counter = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = parentDirectory.appendingPathComponent("\(stem)-\(counter)", isDirectory: true)
            counter += 1
        }
        return candidate
    }

    private func refreshSidebarAndSelectDerivedURL(_ url: URL) {
        let standardizedURL = url.standardizedFileURL
        let containingDirectory = standardizedURL.deletingLastPathComponent()
        let currentProject = sidebarController.currentProjectURL?.standardizedFileURL

        let targetRoot: URL
        if let currentProject, isURL(standardizedURL, inside: currentProject) {
            targetRoot = currentProject
        } else if let activeProject = DocumentManager.shared.activeProject?.url.standardizedFileURL,
                  isURL(standardizedURL, inside: activeProject) {
            targetRoot = activeProject
        } else {
            targetRoot = containingDirectory
        }

        logger.info("refreshSidebarAndSelectDerivedURL: derived='\(standardizedURL.path, privacy: .public)' targetRoot='\(targetRoot.path, privacy: .public)'")
        if currentProject != targetRoot {
            logger.info("refreshSidebarAndSelectDerivedURL: Rebasing sidebar project root to '\(targetRoot.path, privacy: .public)'")
            sidebarController.openProject(at: targetRoot)
        } else {
            sidebarController.reloadFromFilesystem()
        }

        let selected = sidebarController.selectItem(forURL: standardizedURL)
        if !selected {
            logger.warning("refreshSidebarAndSelectDerivedURL: Could not select derived output '\(standardizedURL.path, privacy: .public)' after reload")
            recordUITestEvent("sidebar.selection.failed \(standardizedURL.lastPathComponent)")
            return
        }
        recordUITestEvent("sidebar.selection.succeeded \(standardizedURL.lastPathComponent)")

        // Programmatic post-run selections happen while the FASTQ viewport still owns
        // focus, so the normal sidebar selection callback can be intentionally ignored.
        if hasActiveSidebarChildViewport,
           let selectedItem = sidebarController.selectedItems().first,
           selectedItem.url?.standardizedFileURL == standardizedURL {
            displayContent(for: selectedItem)
        }
    }

    /// Returns true when `url` is inside `directory` using resolved paths.
    private func isURL(_ url: URL, inside directory: URL) -> Bool {
        let child = url.standardizedFileURL.resolvingSymlinksInPath().pathComponents
        let parent = directory.standardizedFileURL.resolvingSymlinksInPath().pathComponents
        return child.count >= parent.count && child.starts(with: parent)
    }

    private func requestInspectorDocumentModeAfterDownload() {
        NotificationCenter.default.post(
            name: .showInspectorRequested,
            object: nil,
            userInfo: [NotificationUserInfoKey.inspectorTab: "document"]
        )
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

        // Capture the current selection generation so we can discard stale results
        let generation = self.selectionGeneration

        viewerController.showProgress("Loading \(url.lastPathComponent)...")

        // Use detached task for background loading without inheriting actor context.
        // UI callbacks use GCD main queue + MainActor.assumeIsolated (not await MainActor.run)
        // because the cooperative executor doesn't reliably schedule from Task.detached.
        Task.detached(priority: .userInitiated) { [weak self] in
            do {
                let document = try await DocumentManager.shared.loadDocument(at: url)

                // Update UI via GCD main queue (guaranteed to drain)
                DispatchQueue.main.async { [weak self] in
                    MainActor.assumeIsolated {
                        // Check generation counter — if the user has selected something else
                        // while we were loading, discard this result
                        guard let self = self, self.selectionGeneration == generation else {
                            logger.info("loadGenomicsFileInBackground: Discarding stale result for '\(url.lastPathComponent, privacy: .public)' (generation moved on)")
                            viewerController.hideProgress()
                            return
                        }
                        viewerController.hideProgress()
                        viewerController.displayDocument(document)
                        sidebarController.refreshItem(for: url)
                        logger.info("loadGenomicsFileInBackground: Loaded and displayed")
                    }
                }
            } catch {
                let errorMessage = error.localizedDescription
                DispatchQueue.main.async { [weak self] in
                    MainActor.assumeIsolated {
                        guard let self = self, self.selectionGeneration == generation else {
                            viewerController.hideProgress()
                            return
                        }
                        viewerController.hideProgress()
                        logger.error("loadGenomicsFileInBackground: Failed - \(errorMessage)")

                        let alert = NSAlert()
                        alert.messageText = "Failed to Open File"
                        alert.informativeText = errorMessage
                        alert.alertStyle = .warning
                        alert.addButton(withTitle: "OK")
                        if let window = viewerController.view.window ?? NSApp.keyWindow {
                            alert.beginSheetModal(for: window)
                        }
                    }
                }
            }
        }
    }
}
