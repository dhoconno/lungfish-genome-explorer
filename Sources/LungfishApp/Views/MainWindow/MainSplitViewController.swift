// MainSplitViewController.swift - Three-panel split view controller
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import LungfishCore
import LungfishIO
import LungfishWorkflow
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
        let requestID = notification.userInfo?["requestID"] as? String

        logger.info("handleSidebarFileDropped: Processing dropped file '\(url.lastPathComponent, privacy: .public)' at path '\(url.path, privacy: .public)'")

        // Determine destination - use the new filesystem-backed project URL
        let destinationItem = notification.userInfo?["destination"] as? SidebarItem
        var urlToLoad = url

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
            return url.deletingLastPathComponent()
        }()

        // ONT directory detection — route to ONT import pipeline
        if isONTDirectory(url) {
            importONTDirectoryInBackground(sourceURL: url, projectURL: targetDir, requestID: requestID)
            return
        }

        // FASTQ files: ingest in temp → create bundle in project
        if FASTQBundle.isFASTQFileURL(url) {
            importFASTQFileInBackground(sourceURL: url, projectDirectory: targetDir, requestID: requestID)
            return
        }

        // Non-FASTQ files: copy to project as before
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
                let resolution = showDuplicateFileDialog(filename: url.lastPathComponent)
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

        alert.applyLungfishBranding()
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
        var effectiveBundleName = baseName

        let bundleExt = FASTQBundle.directoryExtension
        var bundleURL = projectDirectory.appendingPathComponent("\(effectiveBundleName).\(bundleExt)")

        // Check for existing bundle
        if FileManager.default.fileExists(atPath: bundleURL.path) {
            let resolution = showDuplicateFileDialog(filename: "\(effectiveBundleName).\(bundleExt)")
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
                    alert.runModal()
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
                postSidebarFileDropCompleted(requestID: requestID, sourceURL: sourceURL, success: true, error: nil)
                return
            }
        }

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
                alert.runModal()
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
    private func importONTDirectoryInBackground(sourceURL: URL, projectURL: URL, requestID: String?) {
        guard let viewerController = self.viewerController else {
            postSidebarFileDropCompleted(
                requestID: requestID,
                sourceURL: sourceURL,
                success: false,
                error: "Viewer unavailable while importing ONT directory."
            )
            return
        }

        // Ask whether to include unclassified reads
        let includeUnclassified: Bool = {
            let importer = ONTDirectoryImporter()
            guard let layout = try? importer.detectLayout(at: sourceURL),
                  layout.hasUnclassified else { return false }
            let alert = NSAlert()
            alert.messageText = "ONT Directory Import"
            alert.informativeText = "Found \(layout.barcodeDirectories.count) barcode directories. Include unclassified reads?"
            alert.addButton(withTitle: "Include Unclassified")
            alert.addButton(withTitle: "Barcoded Only")
            alert.applyLungfishBranding()
            return alert.runModal() == .alertFirstButtonReturn
        }()

        let config = ONTImportConfig(
            sourceDirectory: sourceURL,
            outputDirectory: projectURL,
            includeUnclassified: includeUnclassified
        )

        viewerController.showProgress("Importing ONT directory\u{2026}")

        let opID = OperationCenter.shared.start(
            title: "ONT Import: \(sourceURL.lastPathComponent)",
            detail: "Detecting layout\u{2026}",
            operationType: .ingestion
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
                        alert.runModal()
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

    public func sidebarDidSelectItem(_ item: SidebarItem?) {
        guard let item = item else {
            logger.info("sidebarDidSelectItem: Selection cleared, clearing viewer")
            cancelFASTQLoadIfNeeded(hideProgress: true, reason: "selection cleared")
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
                    alert.runModal()
                }
            }
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
            alert.runModal()
            return
        }
        try? FileManager.default.createDirectory(at: projectURL, withIntermediateDirectories: true)

        let defaultBundleName: String = {
            let base = urls.first?.deletingPathExtension().deletingPathExtension().lastPathComponent ?? "VCF Variants"
            let normalized = base.trimmingCharacters(in: .whitespacesAndNewlines)
            return normalized.isEmpty ? "VCF Variants" : normalized
        }()
        guard let bundleSelection = promptForVCFBundleName(
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
                        alert.runModal()
                    }
                }
            }
        }
    }

    private struct VCFBundleSelection {
        let bundleName: String
        let replaceExisting: Bool
    }

    private func promptForVCFBundleName(defaultName: String, projectDirectory: URL) -> VCFBundleSelection? {
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

        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
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

    /// Loads FASTQ file using the streaming statistics collector, then displays the dashboard.
    ///
    /// Checks for cached statistics in the sidecar metadata file first. If found,
    /// uses them directly (still loads sample records for the table). Otherwise,
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

        // Pointer-only derived bundles can render immediately from cached manifest stats.
        if fastqURL == nil, let derivedManifest {
            viewerController.displayFASTQDataset(
                statistics: derivedManifest.cachedStatistics,
                records: [],
                fastqURL: nil,
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
                let summary = try await Self.fetchSeqkitSummary(for: fastqURL)
                let (histogram, processedReads) = try await Self.collectFASTQHistogram(
                    from: fastqURL,
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
                let statistics = Self.buildFASTQStatistics(
                    summary: summary,
                    histogram: histogram,
                    fallbackReadCount: processedReads
                )
                try Task.checkCancellation()

                // Cache the computed statistics for next time.
                // Skip stale/deleted targets so we don't write sidecars into removed paths.
                if FileManager.default.fileExists(atPath: fastqURL.path) {
                    var metadata = cachedMeta ?? PersistedFASTQMetadata()
                    metadata.computedStatistics = statistics
                    metadata.seqkitStats = summary.asMetadata()
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
                        alert.runModal()
                    }
                }
            }
        }
    }

    private func runFASTQOperation(_ request: FASTQDerivativeRequest, sourceURL: URL) async throws {
        let standardizedSourceURL = sourceURL.standardizedFileURL
        let sourceBundleURL: URL
        if FASTQBundle.isBundleURL(standardizedSourceURL) {
            sourceBundleURL = standardizedSourceURL
        } else if standardizedSourceURL.deletingLastPathComponent().pathExtension.lowercased() == FASTQBundle.directoryExtension {
            let parent = standardizedSourceURL.deletingLastPathComponent()
            sourceBundleURL = parent
        } else {
            throw FASTQDerivativeError.sourceMustBeBundle
        }

        await MainActor.run {
            self.viewerController.showProgress("Running FASTQ operation...")
        }
        defer {
            Task { @MainActor in
                self.viewerController.hideProgress()
            }
        }

        let derivedURL = try await FASTQDerivativeService.shared.createDerivative(
            from: sourceBundleURL,
            request: request,
            progress: { [weak self] message in
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        self?.viewerController.showProgress(message)
                    }
                }
            }
        )

        await MainActor.run {
            self.sidebarController.reloadFromFilesystem()
            self.sidebarController.selectItem(forURL: derivedURL)
            self.requestInspectorDocumentModeAfterDownload()
        }
    }

    private func requestInspectorDocumentModeAfterDownload() {
        NotificationCenter.default.post(
            name: .showInspectorRequested,
            object: nil,
            userInfo: [NotificationUserInfoKey.inspectorTab: "document"]
        )
    }

    private struct SeqkitSummary {
        let numSeqs: Int
        let sumLen: Int64
        let minLen: Int
        let avgLen: Double
        let maxLen: Int
        let q20Percentage: Double
        let q30Percentage: Double
        let averageQuality: Double
        let gcPercentage: Double

        func asMetadata() -> SeqkitStatsMetadata {
            SeqkitStatsMetadata(
                numSeqs: numSeqs,
                sumLen: sumLen,
                minLen: minLen,
                avgLen: avgLen,
                maxLen: maxLen,
                q20Percentage: q20Percentage,
                q30Percentage: q30Percentage,
                averageQuality: averageQuality,
                gcPercentage: gcPercentage
            )
        }
    }

    nonisolated private static func fetchSeqkitSummary(for fastqURL: URL) async throws -> SeqkitSummary {
        let runner = NativeToolRunner.shared
        let result = try await runner.run(
            .seqkit,
            arguments: ["stats", "-a", "-T", fastqURL.path],
            timeout: 900
        )
        guard result.isSuccess else {
            throw DatabaseServiceError.parseError(
                message: "seqkit stats failed: \(result.stderr)"
            )
        }

        let lines = result.stdout
            .split(whereSeparator: \.isNewline)
            .map(String.init)
            .filter { !$0.isEmpty }
        guard lines.count >= 2 else {
            throw DatabaseServiceError.parseError(
                message: "seqkit stats returned unexpected output"
            )
        }

        let headers = lines[0].split(separator: "\t").map(String.init)
        let values = lines[1].split(separator: "\t").map(String.init)
        guard headers.count == values.count else {
            throw DatabaseServiceError.parseError(
                message: "seqkit stats header/value mismatch"
            )
        }

        var map: [String: String] = [:]
        for (header, value) in zip(headers, values) {
            map[header] = value
        }

        func int(_ key: String) -> Int { Int(map[key] ?? "") ?? 0 }
        func int64(_ key: String) -> Int64 { Int64(map[key] ?? "") ?? 0 }
        func dbl(_ key: String) -> Double { Double(map[key] ?? "") ?? 0 }

        return SeqkitSummary(
            numSeqs: int("num_seqs"),
            sumLen: int64("sum_len"),
            minLen: int("min_len"),
            avgLen: dbl("avg_len"),
            maxLen: int("max_len"),
            q20Percentage: dbl("Q20(%)"),
            q30Percentage: dbl("Q30(%)"),
            averageQuality: dbl("AvgQual"),
            gcPercentage: dbl("GC(%)")
        )
    }

    nonisolated private static func collectFASTQHistogram(
        from fastqURL: URL,
        progress: (@Sendable (Int) -> Void)? = nil
    ) async throws -> (histogram: [Int: Int], readCount: Int) {
        let reader = FASTQReader(validateSequence: false)
        var histogram: [Int: Int] = [:]
        var readCount = 0

        for try await record in reader.records(from: fastqURL) {
            histogram[record.length, default: 0] += 1
            readCount += 1
            if readCount % 10_000 == 0 {
                progress?(readCount)
                try Task.checkCancellation()
            }
        }
        progress?(readCount)
        return (histogram, readCount)
    }

    nonisolated private static func buildFASTQStatistics(
        summary: SeqkitSummary,
        histogram: [Int: Int],
        fallbackReadCount: Int
    ) -> FASTQDatasetStatistics {
        let readCount = summary.numSeqs > 0 ? summary.numSeqs : fallbackReadCount
        let baseCount = summary.sumLen > 0 ? summary.sumLen : histogram.reduce(Int64(0)) { total, item in
            total + Int64(item.key * item.value)
        }
        let minLength = summary.minLen > 0 ? summary.minLen : histogram.keys.min() ?? 0
        let maxLength = summary.maxLen > 0 ? summary.maxLen : histogram.keys.max() ?? 0
        let meanLength = summary.avgLen > 0 ? summary.avgLen : (readCount > 0 ? Double(baseCount) / Double(readCount) : 0)

        func medianLength() -> Int {
            guard readCount > 0 else { return 0 }
            let target = (readCount + 1) / 2
            var cumulative = 0
            for (length, count) in histogram.sorted(by: { $0.key < $1.key }) {
                cumulative += count
                if cumulative >= target { return length }
            }
            return histogram.keys.max() ?? 0
        }

        func n50Length() -> Int {
            guard baseCount > 0 else { return 0 }
            let target = Double(baseCount) / 2.0
            var cumulative = 0.0
            for (length, count) in histogram.sorted(by: { $0.key > $1.key }) {
                cumulative += Double(length * count)
                if cumulative >= target { return length }
            }
            return histogram.keys.max() ?? 0
        }

        return FASTQDatasetStatistics(
            readCount: readCount,
            baseCount: baseCount,
            meanReadLength: meanLength,
            minReadLength: minLength,
            maxReadLength: maxLength,
            medianReadLength: medianLength(),
            n50ReadLength: n50Length(),
            meanQuality: summary.averageQuality,
            q20Percentage: summary.q20Percentage,
            q30Percentage: summary.q30Percentage,
            gcContent: summary.gcPercentage / 100.0,
            readLengthHistogram: histogram,
            qualityScoreHistogram: [:],
            perPositionQuality: []
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
