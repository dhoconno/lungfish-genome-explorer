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

    // MARK: - Lifecycle

    public override func viewDidLoad() {
        super.viewDidLoad()
        logger.info("viewDidLoad: MainSplitViewController loading")
        configureSplitView()
        configureChildControllers()
        configureActivityIndicator()
        configureNotifications()
        restorePanelState()
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                self?.applySidebarPreferredWidth(self?.sidebarDefaultWidth ?? 240, allowShrink: true)
            }
        }
        // One-time migration: clear stale split view autosave from broken TARIC configuration
        let autosaveMigrationKey = "com.lungfish.splitview.autosave.v2.migrated"
        if !UserDefaults.standard.bool(forKey: autosaveMigrationKey) {
            if let autosaveName = splitView.autosaveName {
                UserDefaults.standard.removeObject(forKey: "NSSplitView Subview Frames \(autosaveName)")
            }
            UserDefaults.standard.set(true, forKey: autosaveMigrationKey)
        }

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
            return allURLs[0].deletingLastPathComponent()
        }()

        // Partition URLs into FASTQ files, ONT directories, and other files
        var fastqURLs: [URL] = []
        var otherURLs: [URL] = []

        for url in allURLs {
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
                        url: url, projectURL: projectURL, targetDir: targetDir, requestID: requestID
                    )
                }
            }
        }
    }

    /// Imports a single non-FASTQ file, handling duplicate resolution via sheet.
    private func importNonFASTQFile(url: URL, projectURL: URL?, targetDir: URL, requestID: String?) async {
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
        loadGenomicsFileInBackground(url: urlToLoad)
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
        let detectedPlatform = SequencingPlatform.detect(fromFASTQ: pairs[0].r1) ?? .unknown

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
        applySidebarPreferredWidth(rawWidth, allowShrink: false)
    }

    private func applySidebarPreferredWidth(_ width: CGFloat, allowShrink: Bool) {
        guard splitView.subviews.count > 1 else { return }
        guard !sidebarItem.isCollapsed else { return }

        let clamped = min(max(width, sidebarMinWidth), sidebarMaxWidth)
        let current = splitView.subviews[0].frame.width
        let target = allowShrink ? clamped : max(current, clamped)
        guard abs(target - current) >= 1 else { return }

        splitView.setPosition(target, ofDividerAt: 0)
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
    //
    // NOTE: Do NOT override canCollapseSubview, constrainMinCoordinate, or
    // constrainMaxCoordinate on NSSplitViewController — these legacy delegate
    // methods are incompatible with constraint-based layout and cause an
    // assertion failure on macOS Tahoe. Use NSSplitViewItem properties instead:
    //   - canCollapse, minimumThickness, maximumThickness (set in configureChildControllers)

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
            item.type != .folder && item.type != .project && item.type != .group && item.type != .batchGroup
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
        guard item.type != .folder && item.type != .project && item.type != .group && item.type != .batchGroup else {
            logger.debug("displayContent: Skipping container item type")
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
            displayReferenceBundle(at: url)
            return
        }

        // Classification results (Kraken2 kreport/kraken output)
        if item.type == .classificationResult, let url = item.url {
            displayClassificationResult(at: url)
            return
        }

        // EsViritu viral detection results
        if item.type == .esvirituResult, let url = item.url {
            displayEsVirituResult(at: url)
            return
        }

        // TaxTriage results (including per-sample children of batch groups)
        if item.type == .taxTriageResult, let url = item.url {
            let sampleId = item.userInfo["sampleId"]
            displayTaxTriageResultFromSidebar(at: url, sampleId: sampleId)
            return
        }

        // NAO-MGS surveillance result bundles
        if item.type == .naoMgsResult, let url = item.url {
            displayNaoMgsResultFromSidebar(at: url)
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
    private func displayReferenceBundle(at url: URL, forceReload: Bool = false) {
        if !forceReload,
           viewerController.currentBundleDataProvider != nil,
           viewerController.currentBundleURL?.standardizedFileURL == url.standardizedFileURL {
            logger.debug("displayReferenceBundle: '\(url.lastPathComponent, privacy: .public)' already displayed, skipping reload")
            viewerController.openAnnotationDrawerIfBundleHasData()
            return
        }

        logger.info("displayReferenceBundle: Opening '\(url.lastPathComponent, privacy: .public)'")

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
                    try self.viewerController.displayBundle(at: url)
                    logger.info("displayReferenceBundle: Bundle displayed successfully")
                } catch {
                    logger.error("displayReferenceBundle: Failed - \(error.localizedDescription, privacy: .public)")
                    let alert = NSAlert()
                    alert.messageText = "Failed to Open Reference Bundle"
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


    /// Display a saved classification result from a classification directory.
    ///
    /// Loads the `ClassificationResult` from the directory's sidecar JSON,
    /// rebuilds the taxonomy tree from the kreport, and shows the taxonomy browser.
    ///
    /// - Parameter url: The classification result directory URL.
    private func displayClassificationResult(at url: URL) {
        logger.info("displayClassificationResult: Opening '\(url.lastPathComponent, privacy: .public)'")

        do {
            let result = try ClassificationResult.load(from: url)
            viewerController.displayTaxonomyResult(result)
            logger.info("displayClassificationResult: Loaded \(result.tree.totalReads) reads, \(result.tree.speciesCount) species")
        } catch {
            logger.error("displayClassificationResult: Failed - \(error.localizedDescription, privacy: .public)")
            let alert = NSAlert()
            alert.messageText = "Failed to Load Classification Result"
            alert.informativeText = error.localizedDescription
            alert.alertStyle = .warning
            alert.addButton(withTitle: "OK")
            if let window = self.view.window ?? NSApp.keyWindow {
                alert.beginSheetModal(for: window)
            }
        }
    }

    /// Display a saved EsViritu result from a result directory.
    ///
    /// Loads the `EsVirituResult` from the directory's sidecar JSON,
    /// parses the detection TSV files, and shows the viral detection browser.
    ///
    /// - Parameter url: The EsViritu result directory URL.
    private func displayEsVirituResult(at url: URL) {
        logger.info("displayEsVirituResult: Opening '\(url.lastPathComponent, privacy: .public)'")

        do {
            let pipelineResult = try LungfishWorkflow.EsVirituResult.load(from: url)

            // Parse the TSV output files into the display model
            let detections = (try? EsVirituDetectionParser.parse(url: pipelineResult.detectionURL)) ?? []
            let assemblies = EsVirituDetectionParser.groupByAssembly(detections)
            let taxProfile: [ViralTaxProfile]
            if let tpURL = pipelineResult.taxProfileURL {
                taxProfile = (try? EsVirituTaxProfileParser.parse(url: tpURL)) ?? []
            } else {
                taxProfile = []
            }
            let coverageWindows: [ViralCoverageWindow]
            if let cvURL = pipelineResult.coverageURL {
                coverageWindows = (try? EsVirituCoverageParser.parse(url: cvURL)) ?? []
            } else {
                coverageWindows = []
            }

            let ioResult = LungfishIO.EsVirituResult(
                sampleId: pipelineResult.config.sampleName,
                detections: detections,
                assemblies: assemblies,
                taxProfile: taxProfile,
                coverageWindows: coverageWindows,
                totalFilteredReads: detections.first?.filteredReadsInSample ?? 0,
                detectedFamilyCount: Set(detections.compactMap(\.family)).count,
                detectedSpeciesCount: Set(detections.compactMap(\.species)).count,
                runtime: pipelineResult.runtime,
                toolVersion: pipelineResult.toolVersion
            )

            viewerController.displayEsVirituResult(ioResult, config: pipelineResult.config)
            logger.info("displayEsVirituResult: Loaded \(detections.count) detections, \(assemblies.count) assemblies")
        } catch {
            logger.error("displayEsVirituResult: Failed - \(error.localizedDescription, privacy: .public)")
            let alert = NSAlert()
            alert.messageText = "Failed to Load EsViritu Result"
            alert.informativeText = error.localizedDescription
            alert.alertStyle = .warning
            alert.addButton(withTitle: "OK")
            if let window = self.view.window ?? NSApp.keyWindow {
                alert.beginSheetModal(for: window)
            }
        }
    }

    /// Display a saved TaxTriage result from a result directory.
    ///
    /// - Parameters:
    ///   - url: The result output directory.
    ///   - sampleId: Optional sample ID to pre-select in the per-sample filter.
    ///     `nil` shows the "All Samples" merged view.
    private func displayTaxTriageResultFromSidebar(at url: URL, sampleId: String? = nil) {
        logger.info("displayTaxTriageResult: Opening '\(url.lastPathComponent, privacy: .public)', sampleId=\(sampleId ?? "all", privacy: .public)")

        // Prefer the persisted sidecar so view parsing matches pipeline-time discovery.
        if let persisted = try? TaxTriageResult.load(from: url) {
            viewerController.displayTaxTriageResult(persisted, config: persisted.config, sampleId: sampleId)
            return
        }

        // Fallback: rebuild from on-disk contents when sidecar is missing/corrupt.
        let fm = FileManager.default
        let allFiles: [URL]
        if let enumerator = fm.enumerator(
            at: url,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) {
            allFiles = enumerator.compactMap { element -> URL? in
                guard let fileURL = element as? URL else { return nil }
                let isRegularFile = (try? fileURL.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) ?? false
                return isRegularFile ? fileURL : nil
            }
        } else {
            allFiles = []
        }

        let reportFiles = allFiles.filter {
            let name = $0.lastPathComponent.lowercased()
            let ext = $0.pathExtension.lowercased()
            return name.contains("report") && (ext == "txt" || ext == "tsv")
        }

        let metricsFiles = allFiles.filter {
            let name = $0.lastPathComponent.lowercased()
            let ext = $0.pathExtension.lowercased()
            return name.contains("tass")
                || name.contains("metrics")
                || name.contains("confidence")
                || (ext == "tsv" && !name.contains("trace") && !name.contains("samplesheet"))
        }

        let kronaFiles = allFiles.filter {
            let name = $0.lastPathComponent.lowercased()
            let ext = $0.pathExtension.lowercased()
            let path = $0.path.lowercased()
            return ext == "html" && (name.contains("krona") || path.contains("/krona/"))
        }

        let result = TaxTriageResult(
            config: TaxTriageConfig(samples: [], outputDirectory: url),
            runtime: 0,
            exitCode: 0,
            outputDirectory: url,
            reportFiles: reportFiles,
            metricsFiles: metricsFiles,
            kronaFiles: kronaFiles,
            logFile: nil,
            traceFile: nil,
            allOutputFiles: allFiles
        )

        viewerController.displayTaxTriageResult(result, config: nil, sampleId: sampleId)
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

        // Decode and enrich on a background thread (virus_hits.json can be >50 MB).
        let bundleURL = url
        Task {
            do {
                let fm = FileManager.default
                let decoder = JSONDecoder()
                decoder.dateDecodingStrategy = .iso8601

                // Read manifest
                let manifestURL = bundleURL.appendingPathComponent("manifest.json")
                guard fm.fileExists(atPath: manifestURL.path) else {
                    throw NSError(domain: "NaoMgsDisplay", code: 1,
                                  userInfo: [NSLocalizedDescriptionKey: "manifest.json not found in NAO-MGS bundle"])
                }
                let manifestData = try Data(contentsOf: manifestURL)
                let manifest = try decoder.decode(NaoMgsManifest.self, from: manifestData)

                // Load cached virus hits JSON (always present after import)
                let hitsURL = bundleURL.appendingPathComponent("virus_hits.json")
                guard fm.fileExists(atPath: hitsURL.path) else {
                    throw NSError(domain: "NaoMgsDisplay", code: 2,
                                  userInfo: [NSLocalizedDescriptionKey: "virus_hits.json not found — bundle may be incomplete"])
                }
                let hitsData = try Data(contentsOf: hitsURL)
                let hitsFile = try decoder.decode(NaoMgsVirusHitsFile.self, from: hitsData)

                // Build accession → organism name from downloaded reference FASTAs.
                // The TSV often lacks subjectTitle, so we derive names from FASTA headers.
                let refsDir = bundleURL.appendingPathComponent("references")
                let accessionToName = Self.buildAccessionNameMap(referencesDirectory: refsDir)

                // Derive taxId → best organism name from the hits' accessions.
                let taxIdToName = Self.deriveTaxonNames(
                    hits: hitsFile.virusHits,
                    accessionToName: accessionToName
                )

                // Rebuild taxon summaries with enriched names.
                let enrichedSummaries = hitsFile.taxonSummaries.map { summary in
                    let resolvedName = summary.name.isEmpty
                        ? (taxIdToName[summary.taxId] ?? "Taxid \(summary.taxId)")
                        : summary.name
                    return NaoMgsTaxonSummary(
                        taxId: summary.taxId,
                        name: resolvedName,
                        hitCount: summary.hitCount,
                        avgIdentity: summary.avgIdentity,
                        avgBitScore: summary.avgBitScore,
                        avgEditDistance: summary.avgEditDistance,
                        accessions: summary.accessions
                    )
                }

                let naoResult = NaoMgsResult(
                    virusHits: hitsFile.virusHits,
                    taxonSummaries: enrichedSummaries,
                    totalHitReads: manifest.hitCount > 0 ? manifest.hitCount : hitsFile.virusHits.count,
                    sampleName: manifest.sampleName,
                    sourceDirectory: bundleURL,
                    virusHitsFile: URL(fileURLWithPath: manifest.sourceFilePath)
                )

                DispatchQueue.main.async { [weak self] in
                    MainActor.assumeIsolated {
                        guard let self else { return }
                        // Configure the already-displayed placeholder VC with real data.
                        placeholderVC.configure(result: naoResult, bundleURL: bundleURL)

                        // Update inspector with NAO-MGS manifest info
                        self.inspectorController?.updateNaoMgsManifest(manifest)

                        logger.info("displayNaoMgsResult: Configured with \(naoResult.totalHitReads) hits, \(enrichedSummaries.count) taxa")
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
        switch type {
        case "kraken2":
            displayClassificationResult(at: url)
        case "esviritu":
            displayEsVirituResult(at: url)
        default:
            logger.warning("Unknown related analysis type: \(type, privacy: .public)")
        }
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
                            self?.displayReferenceBundle(at: bundleURL)
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
                let tempDir = FileManager.default.temporaryDirectory
                    .appendingPathComponent("lungfish-ref-\(UUID().uuidString)", isDirectory: true)
                try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
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
                        self?.displayReferenceBundle(at: bundleURL, forceReload: true)
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
                self?.viewerController.updateFASTQOperationStatus("Running FASTQ operation...")
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
