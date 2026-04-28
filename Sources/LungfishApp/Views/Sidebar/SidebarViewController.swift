// SidebarViewController.swift - Project navigation sidebar
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import LungfishCore
import LungfishIO
import LungfishWorkflow
import os.log

/// Logger for sidebar operations
private let logger = Logger(subsystem: LogSubsystem.app, category: "SidebarViewController")

/// Pasteboard type for internal sidebar item dragging
let sidebarItemPasteboardType = NSPasteboard.PasteboardType("com.lungfish.browser.sidebaritem")

private enum SidebarAccessibilityIdentifier {
    static let outline = "sidebar-outline"
    static let analysesGroup = "sidebar-group-analyses"
}

private final class LocalEventMonitor {
    private var token: Any?

    init(matching mask: NSEvent.EventTypeMask, handler: @escaping (NSEvent) -> NSEvent?) {
        token = NSEvent.addLocalMonitorForEvents(matching: mask, handler: handler)
    }

    @MainActor
    func invalidate() {
        guard let token else { return }
        NSEvent.removeMonitor(token)
        self.token = nil
    }

    deinit {
        guard let token else { return }
        NSEvent.removeMonitor(token)
    }
}

// MARK: - Sidebar Drop Target View

/// Custom NSView subclass that acts as a fallback drag destination for the sidebar.
/// This ensures file drops are accepted even when the outline view doesn't handle them
/// (e.g., when dropping onto empty space or when the sidebar is empty).
@MainActor
private class SidebarDropTargetView: NSView {

    /// Weak reference to the sidebar controller to forward drop events
    weak var sidebarController: SidebarViewController?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        registerForDraggedTypes([.fileURL])
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        registerForDraggedTypes([.fileURL])
    }

    /// Check if the pasteboard contains valid file URLs.
    ///
    /// Accepts all files since non-genomics files use QuickLook preview.
    private func hasValidFiles(in pasteboard: NSPasteboard) -> Bool {
        guard let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL],
              !urls.isEmpty else {
            return false
        }
        // Accept any file with a non-empty extension (exclude hidden files)
        return urls.contains { url in
            !url.pathExtension.isEmpty
        }
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        hasValidFiles(in: sender.draggingPasteboard) ? .copy : []
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        hasValidFiles(in: sender.draggingPasteboard) ? .copy : []
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        // No action needed
    }

    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
        true
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let pasteboard = sender.draggingPasteboard
        guard let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL],
              !urls.isEmpty else {
            return false
        }

        // Post a single notification with all dropped URLs
        NotificationCenter.default.post(
            name: .sidebarFileDropped,
            object: self.sidebarController,
            userInfo: ["urls": urls, "destination": NSNull()]
        )

        return true
    }

    override func concludeDragOperation(_ sender: NSDraggingInfo?) {
        // No action needed
    }
}

/// Controller for the sidebar panel containing project/file navigation.
///
/// Uses NSOutlineView for hierarchical file/sequence display.
@MainActor
public class SidebarViewController: NSViewController {

    // MARK: - UI Components

    /// The outline view for hierarchical navigation
    private var outlineView: NSOutlineView!

    /// Scroll view containing the outline view
    private var scrollView: NSScrollView!

    /// Returns true if the given responder is the outline view or a descendant of it.
    public func outlineViewIsFirstResponder(_ responder: NSResponder?) -> Bool {
        guard let responder else { return false }
        if responder === outlineView { return true }
        if let view = responder as? NSView {
            return view.isDescendant(of: outlineView)
        }
        return false
    }

    /// Search field for filtering
    private var searchField: NSSearchField!
    /// Button that opens the advanced universal-search builder.
    private var advancedSearchButton: NSButton!
    /// Status label shown while universal search is running.
    private var searchingLabel: NSTextField!

    // MARK: - Data

    /// Root items displayed in the sidebar
    private var rootItems: [SidebarItem] = []

    /// Filtered copy of rootItems when search is active; nil when no filter.
    private var filteredRootItems: [SidebarItem]?

    /// The items the outline view data source should use.
    private var displayItems: [SidebarItem] {
        filteredRootItems ?? rootItems
    }

    /// The currently open project URL (filesystem-backed model)
    private var projectURL: URL?

    /// Public read-only accessor for the current project folder URL.
    public var projectFolderURL: URL? { projectURL }

    /// File system watcher for auto-refreshing when files change
    private var fileSystemWatcher: FileSystemWatcher?

    /// Universal search coordinator for project-scoped metadata/entity queries.
    private let universalSearchService = UniversalProjectSearchService.shared

    /// In-flight async universal-search query task.
    private var universalSearchTask: Task<Void, Never>?

    /// Monotonic token used to discard stale async query responses.
    private var universalSearchGeneration: Int = 0
    /// Current advanced-search popover (if shown).
    private var universalSearchPopover: NSPopover?

    /// Spinner shown during async universal search queries.
    private var searchSpinner: NSProgressIndicator?

    /// Suppresses delegate and notification callbacks during programmatic selection changes.
    private var suppressSelectionCallbacks = false

    /// Last width recommendation posted to the split-view controller.
    private var lastRecommendedSidebarWidth: CGFloat = 0

    /// Local event monitor for Delete and selection shortcuts.
    private var keyEventMonitor: LocalEventMonitor?

    // MARK: - Delegate

    /// Delegate for selection change callbacks.
    ///
    /// Use this delegate instead of observing `sidebarSelectionChanged` notifications
    /// for reliable, synchronous handling of selection changes. This avoids Swift
    /// concurrency issues where Tasks don't execute from notification handlers.
    public weak var selectionDelegate: SidebarSelectionDelegate?

    var windowStateScope: WindowStateScope?

    // MARK: - Lifecycle

    public override func loadView() {
        // Create the main container view as a drop target
        // This ensures file drops are accepted even when outline view doesn't handle them
        let containerView = SidebarDropTargetView()
        // Do NOT set translatesAutoresizingMaskIntoConstraints = false on the root view.
        // NSSplitView manages child view frames via autoresizing masks; disabling TARIC
        // prevents the split view from resizing the sidebar when dividers are dragged.
        containerView.sidebarController = self

        // Create search field
        searchField = NSSearchField()
        searchField.translatesAutoresizingMaskIntoConstraints = false
        searchField.placeholderString = "Search project data and analyses"
        searchField.sendsSearchStringImmediately = true
        searchField.target = self
        searchField.action = #selector(searchFieldChanged(_:))
        searchField.setAccessibilityIdentifier("sidebar-search-field")
        searchField.setAccessibilityLabel("Search project data and analyses")
        containerView.addSubview(searchField)

        // Advanced query builder for HIG-friendly structured search
        advancedSearchButton = NSButton(title: "", target: self, action: #selector(showAdvancedSearchPopover(_:)))
        advancedSearchButton.translatesAutoresizingMaskIntoConstraints = false
        advancedSearchButton.bezelStyle = .rounded
        advancedSearchButton.controlSize = .small
        advancedSearchButton.image = NSImage(
            systemSymbolName: "line.3.horizontal.decrease.circle",
            accessibilityDescription: "Advanced Search"
        )
        advancedSearchButton.imagePosition = .imageOnly
        advancedSearchButton.toolTip = "Advanced Search"
        advancedSearchButton.setAccessibilityIdentifier("sidebar-advanced-search-button")
        advancedSearchButton.setAccessibilityLabel("Open advanced search")
        containerView.addSubview(advancedSearchButton)

        // Create outline view
        outlineView = NSOutlineView()
        outlineView.setAccessibilityIdentifier(SidebarAccessibilityIdentifier.outline)
        outlineView.headerView = nil  // No header for sidebar
        outlineView.rowHeight = 24
        outlineView.indentationPerLevel = 14
        outlineView.autoresizesOutlineColumn = true
        outlineView.floatsGroupRows = false
        outlineView.rowSizeStyle = .default
        outlineView.style = .sourceList  // Modern replacement for selectionHighlightStyle
        outlineView.allowsMultipleSelection = true  // Enable multi-select (Cmd+click, Shift+click)
        outlineView.allowsEmptySelection = true
        outlineView.dataSource = self
        outlineView.delegate = self

        // Set up context menu (right-click menu)
        let contextMenu = NSMenu()
        contextMenu.delegate = self
        outlineView.menu = contextMenu

        // Create name column
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("NameColumn"))
        column.isEditable = false
        column.resizingMask = .autoresizingMask
        outlineView.addTableColumn(column)
        outlineView.outlineTableColumn = column

        // Enable drag and drop for both external files and internal rearrangement
        outlineView.registerForDraggedTypes([.fileURL, sidebarItemPasteboardType])
        outlineView.setDraggingSourceOperationMask(.every, forLocal: true)
        outlineView.setDraggingSourceOperationMask(.copy, forLocal: false)
        outlineView.draggingDestinationFeedbackStyle = .regular

        // Create scroll view
        scrollView = NSScrollView()
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.documentView = outlineView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false
        containerView.addSubview(scrollView)

        // Search progress indicator — shown during async universal search queries
        let spinner = NSProgressIndicator()
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.translatesAutoresizingMaskIntoConstraints = false
        spinner.isHidden = true
        containerView.addSubview(spinner)
        searchSpinner = spinner

        searchingLabel = NSTextField(labelWithString: "Searching project…")
        searchingLabel.font = .systemFont(ofSize: 10)
        searchingLabel.textColor = .tertiaryLabelColor
        searchingLabel.translatesAutoresizingMaskIntoConstraints = false
        searchingLabel.isHidden = true
        searchingLabel.setAccessibilityIdentifier("sidebar-searching-status")
        searchingLabel.setAccessibilityLabel("Searching project")
        containerView.addSubview(searchingLabel)

        // Layout constraints
        // Note: Top margin of 52 accounts for window title bar and traffic light buttons
        NSLayoutConstraint.activate([
            searchField.topAnchor.constraint(equalTo: containerView.topAnchor, constant: 52),
            searchField.leadingAnchor.constraint(equalTo: containerView.leadingAnchor, constant: 8),
            searchField.trailingAnchor.constraint(equalTo: advancedSearchButton.leadingAnchor, constant: -6),

            advancedSearchButton.trailingAnchor.constraint(equalTo: containerView.trailingAnchor, constant: -8),
            advancedSearchButton.centerYAnchor.constraint(equalTo: searchField.centerYAnchor),
            advancedSearchButton.widthAnchor.constraint(equalToConstant: 24),

            spinner.topAnchor.constraint(equalTo: searchField.bottomAnchor, constant: 4),
            spinner.leadingAnchor.constraint(equalTo: containerView.leadingAnchor, constant: 12),

            searchingLabel.centerYAnchor.constraint(equalTo: spinner.centerYAnchor),
            searchingLabel.leadingAnchor.constraint(equalTo: spinner.trailingAnchor, constant: 4),

            scrollView.topAnchor.constraint(equalTo: searchField.bottomAnchor, constant: 8),
            scrollView.leadingAnchor.constraint(equalTo: containerView.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: containerView.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: containerView.bottomAnchor),
        ])

        self.view = containerView
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    public override func viewDidLoad() {
        super.viewDidLoad()

        // Load initial data
        loadSampleData()

        // Observe navigation requests from the Inspector's source-sample links.
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleNavigateToSidebarItem(_:)),
            name: .navigateToSidebarItem,
            object: nil
        )

        // Set up key event monitoring for Delete key
        keyEventMonitor = LocalEventMonitor(matching: .keyDown) { [weak self] event in
            guard let self = self,
                  let sidebarWindow = self.view.window,
                  event.window === sidebarWindow,  // Ensure event is for THIS window, not sheets
                  sidebarWindow.firstResponder === self.outlineView else {
                return event
            }

            // Check for Delete or Backspace key
            if event.keyCode == 51 || event.keyCode == 117 {  // Backspace (51) or Delete (117)
                self.deleteSelectedItems()
                return nil  // Consume the event
            }

            // Cmd+Shift+A: Select All Siblings
            if event.modifierFlags.contains([.command, .shift]),
               event.charactersIgnoringModifiers?.lowercased() == "a" {
                self.selectAllSiblings()
                return nil
            }

            return event
        }
    }

    public override func viewWillDisappear() {
        super.viewWillDisappear()
        cancelUniversalSearch(reason: "controller teardown")
        keyEventMonitor?.invalidate()
        keyEventMonitor = nil
    }

    // MARK: - Data Loading

    private func loadSampleData() {
        // Start with empty sidebar - documents will be added when loaded
        // The "OPEN DOCUMENTS" group is created automatically when first document is loaded
        rootItems = []
        reloadOutlineView()
        logger.info("loadSampleData: Sidebar initialized (empty, waiting for documents)")
    }

    // MARK: - Actions

    @objc private func searchFieldChanged(_ sender: NSSearchField) {
        let searchText = sender.stringValue.trimmingCharacters(in: .whitespaces)
        cancelUniversalSearch(reason: "query changed")
        universalSearchGeneration &+= 1
        let searchGeneration = universalSearchGeneration

        if searchText.isEmpty {
            filteredRootItems = nil
            outlineView.reloadData()
            setSearchSpinnerVisible(false)
            return
        }

        let normalizedQuery = searchText.lowercased()
        filteredRootItems = filterItems(rootItems, matching: normalizedQuery)
        outlineView.reloadData()
        if filteredRootItems != nil {
            outlineView.expandItem(nil, expandChildren: true)
        }

        guard let projectURL = projectURL else { return }

        // Show spinner while universal search runs in the background
        setSearchSpinnerVisible(true)

        universalSearchTask = Task { [weak self] in
            guard let self else { return }

            do {
                let results = try await universalSearchService.search(
                    projectURL: projectURL,
                    query: searchText,
                    limit: 500,
                    ensureIndexed: true
                )

                guard !Task.isCancelled else { return }
                guard self.universalSearchGeneration == searchGeneration else { return }
                guard self.projectURL?.standardizedFileURL == projectURL.standardizedFileURL else { return }

                let matchedURLs = Set(results.map { $0.url.standardizedFileURL })
                self.filteredRootItems = self.filterItems(
                    self.rootItems,
                    matching: normalizedQuery,
                    matchingURLs: matchedURLs
                )
                self.outlineView.reloadData()
                if self.filteredRootItems != nil {
                    self.outlineView.expandItem(nil, expandChildren: true)
                }
            } catch {
                logger.debug("searchFieldChanged: universal search unavailable: \(error.localizedDescription, privacy: .public)")
            }

            self.setSearchSpinnerVisible(false)
        }
    }

    /// Shows or hides the search progress spinner and label.
    private func setSearchSpinnerVisible(_ visible: Bool) {
        if visible {
            searchSpinner?.isHidden = false
            searchSpinner?.startAnimation(nil)
        } else {
            searchSpinner?.stopAnimation(nil)
            searchSpinner?.isHidden = true
        }
        searchingLabel.isHidden = !visible
    }

    @objc private func showAdvancedSearchPopover(_ sender: NSButton) {
        if let existing = universalSearchPopover, existing.isShown {
            existing.performClose(sender)
            universalSearchPopover = nil
            return
        }

        let builder = UniversalSearchAdvancedPopoverController()
        builder.configure(from: searchField.stringValue)
        builder.onApply = { [weak self] query in
            guard let self else { return }
            self.searchField.stringValue = query
            self.searchFieldChanged(self.searchField)
            self.universalSearchPopover?.performClose(nil)
            self.universalSearchPopover = nil
        }
        builder.onClear = { [weak self] in
            guard let self else { return }
            self.searchField.stringValue = ""
            self.searchFieldChanged(self.searchField)
            self.universalSearchPopover?.performClose(nil)
            self.universalSearchPopover = nil
        }

        let popover = NSPopover()
        popover.behavior = .transient
        popover.contentSize = NSSize(width: 470, height: 430)
        popover.contentViewController = builder
        popover.show(relativeTo: sender.bounds, of: sender, preferredEdge: .maxY)
        universalSearchPopover = popover
    }

    /// Schedules a project universal-search index rebuild.
    private func scheduleUniversalSearchRebuild(immediate: Bool = false) {
        guard let projectURL else { return }
        let delay = immediate ? 0.05 : 0.75
        Task {
            await universalSearchService.scheduleRebuild(projectURL: projectURL, delaySeconds: delay)
        }
    }

    /// Sends changed paths to the universal search service for targeted re-indexing.
    ///
    /// Unlike `scheduleUniversalSearchRebuild()` which does a full rebuild,
    /// this only updates index entries for the specific files that changed.
    private func updateSearchIndex(changedPaths: [URL]) {
        guard let projectURL else { return }
        Task {
            await universalSearchService.update(
                projectURL: projectURL,
                changedPaths: changedPaths
            )
        }
    }

    /// Clears universal-search state for a project.
    private func clearUniversalSearchState(for projectURL: URL?) {
        cancelUniversalSearch(reason: "clearing project state")
        universalSearchGeneration = 0

        guard let projectURL else { return }
        Task {
            await universalSearchService.clearProject(projectURL)
        }
    }

    private func cancelUniversalSearch(reason: String) {
        if universalSearchTask != nil {
            logger.debug("cancelUniversalSearch: cancelling in-flight query (\(reason, privacy: .public))")
            universalSearchTask?.cancel()
            universalSearchTask = nil
        }
        setSearchSpinnerVisible(false)
    }

    /// Recursively filters the sidebar tree, keeping items whose title, subtitle,
    /// path, or indexed URL matches the query, and any parent with matching descendants.
    private func filterItems(
        _ items: [SidebarItem],
        matching query: String,
        matchingURLs: Set<URL> = []
    ) -> [SidebarItem] {
        var result: [SidebarItem] = []
        for item in items {
            let titleMatch = item.title.lowercased().contains(query)
            let subtitleMatch = item.subtitle?.lowercased().contains(query) == true
            let urlMatch = item.url?.lastPathComponent.lowercased().contains(query) == true
            let universalURLMatch = item.url.map { matchingURLs.contains($0.standardizedFileURL) } ?? false

            let directMatch = titleMatch || subtitleMatch || urlMatch || universalURLMatch
            let filteredChildren = filterItems(item.children, matching: query, matchingURLs: matchingURLs)

            if directMatch || !filteredChildren.isEmpty {
                let copy = SidebarItem(
                    title: item.title,
                    type: item.type,
                    icon: item.icon,
                    children: filteredChildren.isEmpty && directMatch ? item.children : filteredChildren,
                    url: item.url,
                    subtitle: item.subtitle
                )
                result.append(copy)
            }
        }
        return result
    }

    // MARK: - Public API

    /// Reloads the sidebar content
    public func reloadData() {
        reloadOutlineView()
    }

    private func reloadOutlineView() {
        outlineView.reloadData()
        postPreferredSidebarWidthIfNeeded()
    }

    private func postPreferredSidebarWidthIfNeeded() {
        let width = recommendedSidebarWidth()
        guard abs(width - lastRecommendedSidebarWidth) >= 2 else { return }
        lastRecommendedSidebarWidth = width
        NotificationCenter.default.post(
            name: .sidebarPreferredWidthRecommended,
            object: self,
            userInfo: ["width": width]
        )
    }

    private func recommendedSidebarWidth() -> CGFloat {
        let contentWidth = maxLabelWidth(in: rootItems, depth: 0)
        let estimated = contentWidth + 40 // icon + paddings + trailing breathing room
        return min(max(estimated, 220), 720)
    }

    private func maxLabelWidth(in items: [SidebarItem], depth: Int) -> CGFloat {
        var maxWidth: CGFloat = 0

        for item in items {
            let font: NSFont
            if item.type == .group {
                font = .systemFont(ofSize: 11, weight: .semibold)
            } else {
                font = .systemFont(ofSize: 13)
            }

            let titleWidth = (item.title as NSString).size(withAttributes: [.font: font]).width
            let subtitleWidth: CGFloat
            if let subtitle = item.subtitle, !subtitle.isEmpty {
                subtitleWidth = (subtitle as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 10)]).width
            } else {
                subtitleWidth = 0
            }

            let indentWidth = CGFloat(depth) * outlineView.indentationPerLevel
            let iconWidth: CGFloat = item.type == .group ? 0 : 20
            let width = indentWidth + iconWidth + max(titleWidth, subtitleWidth)
            maxWidth = max(maxWidth, width)

            if !item.children.isEmpty {
                maxWidth = max(maxWidth, maxLabelWidth(in: item.children, depth: depth + 1))
            }
        }

        return maxWidth
    }

    /// Selects an item in the sidebar
    public func selectItem(_ item: SidebarItem) {
        let row = outlineView.row(forItem: item)
        if row >= 0 {
            outlineView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            outlineView.scrollRowToVisible(row)
        }
    }

    /// Selects an item in the sidebar by its file URL.
    ///
    /// This method searches the sidebar hierarchy for an item matching the given URL
    /// and selects it if found. Use this after loading a document to highlight
    /// the corresponding file in the sidebar.
    ///
    /// - Parameter url: The file URL to select
    /// - Returns: `true` if an item was found and selected, `false` otherwise
    @discardableResult
    public func selectItem(forURL url: URL) -> Bool {
        guard let item = findItem(byURL: url) else {
            logger.debug("selectItem(forURL:): No item found for \(url.lastPathComponent, privacy: .public)")
            return false
        }

        // Ensure parent items are expanded so the item is visible
        expandParents(of: item)

        let row = outlineView.row(forItem: item)
        if row >= 0 {
            outlineView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            outlineView.scrollRowToVisible(row)
            logger.debug("selectItem(forURL:): Selected \(url.lastPathComponent, privacy: .public) at row \(row)")
            return true
        }
        return false
    }

    /// Handles the `.navigateToSidebarItem` notification posted from the Inspector
    /// when the user clicks a source-sample link.
    ///
    /// Extracts the `url` from the notification's `userInfo` and delegates to
    /// `selectItem(forURL:)` which locates the matching sidebar entry and selects it.
    @objc private func handleNavigateToSidebarItem(_ notification: Notification) {
        guard shouldAcceptScopedNotification(notification) else { return }
        guard let url = notification.userInfo?["url"] as? URL else { return }
        let found = selectItem(forURL: url)
        if !found {
            logger.debug("handleNavigateToSidebarItem: No sidebar item found for \(url.lastPathComponent, privacy: .public)")
        }
    }

    private func shouldAcceptScopedNotification(_ notification: Notification) -> Bool {
        guard let notificationScope = notification.userInfo?[NotificationUserInfoKey.windowStateScope] as? WindowStateScope else {
            return true
        }
        guard let windowStateScope else { return true }
        return notificationScope == windowStateScope
    }

    /// Expands all parent items of the given item to ensure it's visible.
    private func expandParents(of item: SidebarItem) {
        // Find and expand parents by searching from root
        func findAndExpandParent(in items: [SidebarItem], target: SidebarItem) -> Bool {
            for parentItem in items {
                if parentItem.children.contains(where: { $0 === target }) {
                    // Found the parent - expand it
                    outlineView.expandItem(parentItem)
                    return true
                }
                // Recurse into children
                if findAndExpandParent(in: parentItem.children, target: target) {
                    // Child found deeper - expand this parent too
                    outlineView.expandItem(parentItem)
                    return true
                }
            }
            return false
        }

        _ = findAndExpandParent(in: rootItems, target: item)
    }

    // MARK: - Filesystem-Backed Model

    /// Opens a project folder and displays its contents in the sidebar.
    ///
    /// This is the primary entry point for the filesystem-backed model. It:
    /// 1. Stores the project URL
    /// 2. Scans the directory to build the sidebar tree
    /// 3. Starts the file system watcher for auto-refresh
    ///
    /// - Parameter url: The URL of the project folder (.lungfish directory)
    public func openProject(at url: URL) {
        logger.info("openProject: Opening project at '\(url.path, privacy: .public)'")

        // Stop watching previous project
        fileSystemWatcher?.stopWatching()
        clearUniversalSearchState(for: projectURL)

        // Store the new project URL
        projectURL = url

        // Scan filesystem and build sidebar
        reloadFromFilesystem()
        scheduleUniversalSearchRebuild(immediate: true)

        // Start watching for changes
        fileSystemWatcher = FileSystemWatcher { [weak self] changedPaths in
            guard let self else { return }
            if changedPaths.nonSidecar.isEmpty && !changedPaths.all.isEmpty {
                // Sidecar-only changes — just update the search index
                self.updateSearchIndex(changedPaths: changedPaths.all)
            } else if changedPaths.nonSidecar.isEmpty && changedPaths.all.isEmpty {
                // kFSEventStreamEventFlagMustScanSubDirs — full reload
                self.reloadFromFilesystem()
            } else {
                // Non-sidecar changes detected — incremental sidebar update
                self.updateSidebar(changedPaths: changedPaths)
            }
        }
        fileSystemWatcher?.startWatching(directory: url)

        logger.info("openProject: Project opened, watching for changes")
    }

    /// Closes the current project and clears the sidebar.
    public func closeProject() {
        logger.info("closeProject: Closing current project")

        let priorProjectURL = projectURL
        fileSystemWatcher?.stopWatching()
        fileSystemWatcher = nil
        projectURL = nil
        clearUniversalSearchState(for: priorProjectURL)
        rootItems = []
        reloadOutlineView()
    }

    /// Collect URLs of all currently expanded items (recursive).
    private func saveExpandedItemURLs() -> Set<URL> {
        var expanded = Set<URL>()
        func collectExpanded(items: [SidebarItem]) {
            for item in items {
                if outlineView.isItemExpanded(item), let url = item.url {
                    expanded.insert(url.standardizedFileURL)
                }
                if outlineView.isItemExpanded(item) {
                    collectExpanded(items: item.children)
                }
            }
        }
        collectExpanded(items: rootItems)
        return expanded
    }

    /// Re-expand items whose URLs match the saved set (recursive).
    private func restoreExpandedItemURLs(_ urls: Set<URL>) {
        func restoreExpanded(items: [SidebarItem]) {
            for item in items {
                if let url = item.url, urls.contains(url.standardizedFileURL) {
                    outlineView.expandItem(item)
                    restoreExpanded(items: item.children)
                }
            }
        }
        restoreExpanded(items: rootItems)
    }

    /// Reloads the sidebar from the filesystem.
    ///
    /// Scans the project directory and rebuilds the SidebarItem tree to match
    /// the current state of the filesystem. Called automatically by the
    /// FileSystemWatcher when files change.
    public func reloadFromFilesystem() {
        logger.info("reloadFromFilesystem: CALLED - starting filesystem scan")
        guard let projectURL = projectURL else {
            logger.debug("reloadFromFilesystem: No project URL set")
            rootItems = []
            reloadOutlineView()
            return
        }

        logger.info("reloadFromFilesystem: Scanning '\(projectURL.path, privacy: .public)'")

        // Save current selection to restore after reload
        let selectedURLs = selectedItems().compactMap { $0.url?.standardizedFileURL }
        let selectedURLSet = Set(selectedURLs)

        // Suppress selection side effects while rebuilding and restoring rows.
        suppressSelectionCallbacks = true

        // Save expansion state before rebuilding (items are recreated, so match by URL)
        let expandedURLs = saveExpandedItemURLs()

        // Build the sidebar items from the project folder's contents (not the folder itself)
        // This shows the contents at the root level, similar to how Finder shows folder contents
        rootItems = buildRootItems(from: projectURL)

        // Reload the outline view
        reloadOutlineView()

        // Expand all folders at root level
        for item in rootItems where item.type == .folder {
            outlineView.expandItem(item)
        }

        // Restore nested expansion state beyond root level
        restoreExpandedItemURLs(expandedURLs)

        // Restore selection if possible
        restoreSelection(urls: selectedURLs)
        suppressSelectionCallbacks = false

        // Propagate selection only if it actually changed after refresh.
        let restoredItems = selectedItems()
        let restoredURLSet = Set(restoredItems.compactMap { $0.url?.standardizedFileURL })
        if restoredURLSet != selectedURLSet {
            // During filesystem churn, nested rows can briefly disappear/rebuild between
            // scans. Avoid emitting a synthetic "selection cleared" event from refreshes;
            // explicit user deselection still flows through outlineViewSelectionDidChange.
            if !selectedURLSet.isEmpty && restoredItems.isEmpty {
                logger.debug("reloadFromFilesystem: Selection temporarily unavailable after refresh, preserving active content")
            } else {
                handleSelectionChange(restoredItems, source: "reloadFromFilesystem")
            }
        }

        let itemCount = rootItems.reduce(0) { $0 + countItems(in: $1) }
        logger.info("reloadFromFilesystem: Sidebar updated with \(itemCount) items")
        scheduleUniversalSearchRebuild()
    }

    /// Incrementally updates the sidebar for specific changed paths.
    ///
    /// Instead of rebuilding the entire sidebar tree, this method:
    /// 1. Maps changed paths to their top-level parent items in the sidebar
    /// 2. Re-scans only the affected directories
    /// 3. Diffs old vs new children and applies NSOutlineView insert/remove/reload
    ///
    /// For changes that affect the root level (e.g. new top-level file), falls back
    /// to a full reload.
    ///
    /// - Parameter changedPaths: The FSEvents `ChangedPaths` with both filtered and unfiltered paths.
    private func updateSidebar(changedPaths: FileSystemWatcher.ChangedPaths) {
        guard let projectURL else { return }

        logger.debug("updateSidebar: Processing \(changedPaths.nonSidecar.count) non-sidecar changed paths")

        // Also forward ALL paths (including sidecars) to the search index
        updateSearchIndex(changedPaths: changedPaths.all)

        let nonSidecar = changedPaths.nonSidecar
        guard !nonSidecar.isEmpty else { return }

        // Map each changed path to its top-level sidebar parent.
        let projectPath = projectURL.standardizedFileURL.path
        var affectedTopLevelNames: Set<String> = []
        var affectsRoot = false

        for url in nonSidecar {
            let filePath = url.standardizedFileURL.path
            guard filePath.hasPrefix(projectPath) else { continue }

            let relativePath = String(filePath.dropFirst(projectPath.count))
                .trimmingCharacters(in: CharacterSet(charactersIn: "/"))

            let components = relativePath.split(separator: "/", maxSplits: 1)
            if components.isEmpty {
                affectsRoot = true
            } else {
                affectedTopLevelNames.insert(String(components[0]))
            }
        }

        // If the root level itself changed or the Analyses folder is affected, fall back to full reload.
        if affectsRoot || affectedTopLevelNames.contains(AnalysesFolder.directoryName) {
            logger.info("updateSidebar: Root-level or Analyses change — falling back to full reload")
            reloadFromFilesystem()
            return
        }

        logger.info("updateSidebar: Incremental update for \(affectedTopLevelNames.count) top-level items")

        for topLevelName in affectedTopLevelNames {
            let topLevelURL = projectURL.appendingPathComponent(topLevelName)

            guard let existingItemIndex = rootItems.firstIndex(where: {
                $0.url?.standardizedFileURL.path == topLevelURL.standardizedFileURL.path
            }) else {
                logger.debug("updateSidebar: New top-level item '\(topLevelName)' — full reload")
                reloadFromFilesystem()
                return
            }

            let existingItem = rootItems[existingItemIndex]
            let rebuiltItem = buildSidebarTree(from: topLevelURL, isRoot: false)

            applySubtreeDiff(
                existingItem: existingItem,
                rebuiltItem: rebuiltItem,
                parent: nil,
                indexInParent: existingItemIndex
            )
        }
    }

    /// Applies a diff between an existing sidebar item's children and a rebuilt version,
    /// using surgical NSOutlineView operations instead of reloadData().
    private func applySubtreeDiff(
        existingItem: SidebarItem,
        rebuiltItem: SidebarItem,
        parent: SidebarItem?,
        indexInParent: Int
    ) {
        // Update title and subtitle if changed
        var itemNeedsReload = false
        if existingItem.title != rebuiltItem.title {
            existingItem.title = rebuiltItem.title
            itemNeedsReload = true
        }
        if existingItem.subtitle != rebuiltItem.subtitle {
            existingItem.subtitle = rebuiltItem.subtitle
            itemNeedsReload = true
        }

        if itemNeedsReload {
            outlineView.reloadItem(existingItem, reloadChildren: false)
        }

        // Build maps for diffing children by URL
        let existingByURL: [String: (index: Int, item: SidebarItem)] = {
            var map: [String: (Int, SidebarItem)] = [:]
            for (i, child) in existingItem.children.enumerated() {
                if let path = child.url?.standardizedFileURL.path {
                    map[path] = (i, child)
                }
            }
            return map
        }()

        let rebuiltByURL: [String: (index: Int, item: SidebarItem)] = {
            var map: [String: (Int, SidebarItem)] = [:]
            for (i, child) in rebuiltItem.children.enumerated() {
                if let path = child.url?.standardizedFileURL.path {
                    map[path] = (i, child)
                }
            }
            return map
        }()

        let existingURLs = Set(existingByURL.keys)
        let rebuiltURLs = Set(rebuiltByURL.keys)

        let deletedURLs = existingURLs.subtracting(rebuiltURLs)
        let insertedURLs = rebuiltURLs.subtracting(existingURLs)
        let commonURLs = existingURLs.intersection(rebuiltURLs)

        // Apply deletions (in reverse index order to avoid shifting)
        let deletionIndices = deletedURLs
            .compactMap { existingByURL[$0]?.index }
            .sorted(by: >)
        for index in deletionIndices {
            existingItem.children.remove(at: index)
            outlineView.removeItems(
                at: IndexSet(integer: index),
                inParent: existingItem,
                withAnimation: .slideUp
            )
        }

        // Apply insertions (in order of rebuilt indices)
        let insertions = insertedURLs
            .compactMap { url -> (Int, SidebarItem)? in
                guard let (index, item) = rebuiltByURL[url] else { return nil }
                return (index, item)
            }
            .sorted { $0.0 < $1.0 }
        for (targetIndex, newItem) in insertions {
            let insertIndex = min(targetIndex, existingItem.children.count)
            existingItem.children.insert(newItem, at: insertIndex)
            outlineView.insertItems(
                at: IndexSet(integer: insertIndex),
                inParent: existingItem,
                withAnimation: .slideDown
            )
        }

        // Recurse into common items for subtitle/children updates
        for url in commonURLs {
            guard let (_, existingChild) = existingByURL[url],
                  let (_, rebuiltChild) = rebuiltByURL[url] else { continue }
            guard let currentIndex = existingItem.children.firstIndex(where: {
                $0.url?.standardizedFileURL.path == url
            }) else { continue }
            applySubtreeDiff(
                existingItem: existingChild,
                rebuiltItem: rebuiltChild,
                parent: existingItem,
                indexInParent: currentIndex
            )
        }
    }

    /// Builds a SidebarItem tree from a filesystem directory.
    ///
    /// - Parameters:
    ///   - url: The directory URL to scan
    ///   - isRoot: Whether this is the root project folder
    /// - Returns: A SidebarItem representing the directory and its contents
    /// Builds root-level sidebar items from the contents of a project directory.
    ///
    /// This scans the project folder and returns its contents as an array of items,
    /// so they appear at the root level of the sidebar (not nested under a project folder).
    ///
    /// - Parameter projectURL: The project directory URL to scan
    /// - Returns: Array of SidebarItems representing the project's contents
    private func buildRootItems(from projectURL: URL) -> [SidebarItem] {
        let fileManager = FileManager.default

        do {
            let contents = try fileManager.contentsOfDirectory(
                at: projectURL,
                includingPropertiesForKeys: [.isDirectoryKey, .isHiddenKey],
                options: [.skipsHiddenFiles]
            )

            // Sort: folders first, then files alphabetically
            let sorted = contents.sorted { url1, url2 in
                var isDir1: ObjCBool = false
                var isDir2: ObjCBool = false
                fileManager.fileExists(atPath: url1.path, isDirectory: &isDir1)
                fileManager.fileExists(atPath: url2.path, isDirectory: &isDir2)

                if isDir1.boolValue != isDir2.boolValue {
                    return isDir1.boolValue // Directories first
                }
                return url1.lastPathComponent.localizedCaseInsensitiveCompare(url2.lastPathComponent) == .orderedAscending
            }

            // Build items for each entry
            var items: [SidebarItem] = []
            for childURL in sorted {
                var childIsDir: ObjCBool = false
                fileManager.fileExists(atPath: childURL.path, isDirectory: &childIsDir)

                if childIsDir.boolValue {
                    if FASTQBundle.isBundleURL(childURL), FASTQBundle.isProcessing(childURL) {
                        // Hide in-flight imports until ingestion + stats finalize.
                        continue
                    }
                    // Skip the Analyses/ directory — it gets its own top-level group.
                    if childURL.lastPathComponent == AnalysesFolder.directoryName {
                        continue
                    }
                    // Include directories
                    let childItem = buildSidebarTree(from: childURL, isRoot: false)
                    items.append(childItem)
                } else if !isInternalSidecarFile(childURL) {
                    // Only include supported, non-sidecar file types
                    let ext = childURL.pathExtension.lowercased()
                    if isSupportedFileExtension(ext) {
                        let childItem = buildSidebarTree(from: childURL, isRoot: false)
                        items.append(childItem)
                    }
                }
            }

            // Insert a top-level "Analyses" group if the project has any results.
            let analysesChildren = collectAnalyses(in: projectURL)
            if !analysesChildren.isEmpty {
                let analysesGroup = SidebarItem(
                    title: "Analyses",
                    type: .folder,
                    icon: "flask",
                    children: analysesChildren,
                    url: projectURL.appendingPathComponent(AnalysesFolder.directoryName)
                )
                analysesGroup.userInfo["accessibilityIdentifier"] = SidebarAccessibilityIdentifier.analysesGroup
                items.insert(analysesGroup, at: 0)
            }

            return items
        } catch {
            logger.error("buildRootItems: Failed to scan directory: \(error.localizedDescription, privacy: .public)")
            return []
        }
    }

    private func buildSidebarTree(from url: URL, isRoot: Bool = false) -> SidebarItem {
        let fileManager = FileManager.default
        let filename = url.lastPathComponent

        // Determine item type and icon
        let itemType: SidebarItemType
        let icon: String

        if isRoot {
            // Root project folder
            itemType = .project
            icon = "folder.badge.gearshape"
        } else {
            // Determine type based on whether it's a directory or file
            var isDirectory: ObjCBool = false
            fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory)

            if isDirectory.boolValue {
                // Check if it's a reference bundle (.lungfishref)
                if url.pathExtension.lowercased() == "lungfishref" {
                    itemType = .referenceBundle
                    icon = "cylinder.split.1x2"  // Database-like icon for genome bundles
                } else if url.pathExtension.lowercased() == "lungfishprimers" {
                    itemType = .primerSchemeBundle
                    icon = "line.horizontal.3.decrease.circle"
                } else if FASTQBundle.isBundleURL(url) {
                    itemType = .fastqBundle
                    icon = "doc.text"
                } else {
                    itemType = .folder
                    icon = "folder"
                }
            } else {
                // Detect file type from extension
                let (type, iconName) = detectFileType(url: url)
                itemType = type
                icon = iconName
            }
        }

        // Create the item (strip bundle extension for display)
        let displayName = (itemType == .referenceBundle || itemType == .fastqBundle || itemType == .primerSchemeBundle)
            ? url.deletingPathExtension().lastPathComponent
            : filename

        // Load composition subtitle for FASTQ bundles with mixed read types,
        // materialization state badge for virtual derivatives, and processing state.
        var subtitle: String?
        if itemType == .fastqBundle {
            // Check processing state first — overrides other badges
            if case .processing(let detail) = FASTQBundle.processingState(of: url) {
                subtitle = detail
            } else if let manifest = FASTQBundle.loadDerivedManifest(in: url) {
                if let classification = manifest.readClassification {
                    subtitle = classification.compositionLabel
                }
                // Show virtual/materialized status for derivative bundles
                if case .virtual = manifest.resolvedState {
                    subtitle = (subtitle.map { $0 + " · " } ?? "") + "Virtual"
                }
            } else if let readManifest = ReadManifest.load(from: url) {
                subtitle = readManifest.classification.compositionLabel
            }
        }

        let item = SidebarItem(
            title: displayName,
            type: itemType,
            icon: icon,
            children: [],
            url: url,
            subtitle: subtitle
        )

        // For FASTQ bundles, scan for demultiplexed child bundles inside demux/ subdirectory.
        // These appear as expandable children so users can navigate demux output hierarchically.
        if itemType == .fastqBundle {
            let demuxDir = url.appendingPathComponent("demux", isDirectory: true)

            // Load batch manifest first to build exclusion set (prevents duplicate nodes)
            let batchManifest = FASTQBatchManifest.load(from: demuxDir)
            var batchOutputURLs = Set<URL>()
            if let manifest = batchManifest {
                for record in manifest.operations {
                    for relativePath in record.outputBundlePaths {
                        batchOutputURLs.insert(
                            demuxDir.appendingPathComponent(relativePath).standardizedFileURL
                        )
                    }
                }
            }

            // Collect demux child bundles, excluding batch operation outputs
            let childBundles = collectDemuxChildBundles(in: url, excluding: batchOutputURLs)
            for childURL in childBundles {
                let childItem = buildSidebarTree(from: childURL, isRoot: false)
                item.children.append(childItem)
            }

            // Create virtual batch group nodes from batch-operations.json
            if let manifest = batchManifest {
                let batchGroups = buildBatchGroupNodes(manifest: manifest, baseDirectory: demuxDir)
                item.children.append(contentsOf: batchGroups)
            }

            // Scan derivatives/ directory for non-demux child bundles.
            // These are displayed with operation labels instead of filenames.
            let derivatives = FASTQBundle.scanDerivatives(in: url)
            for deriv in derivatives {
                let childItem = buildSidebarTree(from: deriv.url, isRoot: false)
                // Use the operation label as the display name instead of the auto-generated filename
                childItem.title = deriv.manifest.operation.displaySummary
                item.children.append(childItem)
            }

            // Analysis results (classification, EsViritu, TaxTriage, etc.) are now
            // collected from the project-level Analyses/ folder rather than from
            // inside each FASTQ bundle's derivatives/ directory.

            // Scan for extracted read bundles (.lungfishfastq) at the top level.
            // These are created by taxonomy extraction and don't live in derivatives/.
            if let topLevelContents = try? fileManager.contentsOfDirectory(
                at: url,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            ) {
                for childURL in topLevelContents {
                    if childURL.pathExtension == FASTQBundle.directoryExtension {
                        if FASTQBundle.isProcessing(childURL) { continue }
                        let childItem = buildSidebarTree(from: childURL, isRoot: false)
                        item.children.append(childItem)
                    }
                }
            }
        }

        // If it's a directory, scan children (unless it's a bundle)
        // Bundles (.lungfishref) appear as single items and don't show internal structure
        var isDirectory: ObjCBool = false
        if fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue && !itemType.isBundle {
            do {
                let contents = try fileManager.contentsOfDirectory(
                    at: url,
                    includingPropertiesForKeys: [.isDirectoryKey, .isHiddenKey],
                    options: [.skipsHiddenFiles]
                )

                // Sort: folders first, then files alphabetically
                let sorted = contents.sorted { url1, url2 in
                    var isDir1: ObjCBool = false
                    var isDir2: ObjCBool = false
                    fileManager.fileExists(atPath: url1.path, isDirectory: &isDir1)
                    fileManager.fileExists(atPath: url2.path, isDirectory: &isDir2)

                    if isDir1.boolValue != isDir2.boolValue {
                        return isDir1.boolValue // Directories first
                    }
                    return url1.lastPathComponent.localizedCaseInsensitiveCompare(url2.lastPathComponent) == .orderedAscending
                }

                // Build children recursively
                for childURL in sorted {
                    // Skip unsupported file types (only show bioinformatics files and folders)
                    var childIsDir: ObjCBool = false
                    fileManager.fileExists(atPath: childURL.path, isDirectory: &childIsDir)

                    if childIsDir.boolValue {
                        if FASTQBundle.isBundleURL(childURL), FASTQBundle.isProcessing(childURL) {
                            continue
                        }
                        // Skip metagenomics result directories that are already
                        // represented by batch group nodes (via collectTaxTriageResults,
                        // cross-reference sidecars, or similar collectors).
                        if isMetagenomicsResultDirectory(childURL) {
                            continue
                        }
                        // Always include other directories
                        let childItem = buildSidebarTree(from: childURL, isRoot: false)
                        item.children.append(childItem)
                    } else if !isInternalSidecarFile(childURL) {
                        // Only include supported, non-sidecar file types
                        let ext = childURL.pathExtension.lowercased()
                        if isSupportedFileExtension(ext) {
                            let childItem = buildSidebarTree(from: childURL, isRoot: false)
                            item.children.append(childItem)
                        }
                    }
                }
            } catch {
                logger.error("buildSidebarTree: Failed to scan directory: \(error.localizedDescription, privacy: .public)")
            }

            // Scan for NAO-MGS result bundles at this directory level.
            // Unlike classification/esviritu/taxtriage results which live inside
            // FASTQ bundles, NAO-MGS bundles are standalone (in Analyses/ or legacy Imports/).
            let naoMgsItems = collectNaoMgsResults(in: url)
            item.children.append(contentsOf: naoMgsItems)

            // Scan for NVD result bundles at this directory level.
            // Like NAO-MGS, NVD bundles are standalone in Imports/ or Downloads/.
            let nvdItems = collectNvdResults(in: url)
            item.children.append(contentsOf: nvdItems)
        }

        return item
    }

    /// Detects the file type and appropriate icon for a URL.
    ///
    /// Uses the unified FileTypeUtility from LungfishIO for consistent
    /// file type detection across the application.
    private func detectFileType(url: URL) -> (SidebarItemType, String) {
        let fileInfo = FileTypeUtility.detect(url: url)
        let sidebarType = SidebarItemType(from: fileInfo.category)
        return (sidebarType, fileInfo.iconName)
    }

    /// Checks if a file extension is supported.
    ///
    /// All file types are now supported - genomics files get native viewer,
    /// other files get QuickLook preview.
    private func isSupportedFileExtension(_ ext: String) -> Bool {
        // Hidden files (empty extension) are not supported
        !ext.isEmpty
    }

    /// Returns true for internal sidecar/metadata files that should be hidden from the sidebar.
    ///
    /// Hides all JSON files (internal metadata), Lungfish sidecar files, and
    /// CSV metadata used for sample tracking. Users interact with these via
    /// the Inspector and Operations Panel, not the file browser.
    private func isInternalSidecarFile(_ url: URL) -> Bool {
        let name = url.lastPathComponent
        let ext = url.pathExtension.lowercased()
        return ext == "json"
            || name.hasSuffix(".lungfish-meta.json")
            || name == FASTQBundleCSVMetadata.filename
    }

    /// Returns true for metagenomics result directories that should be hidden
    /// from the generic directory scanner because they are already represented
    /// by dedicated batch group or result nodes via collectors.
    ///
    /// Uses prefix-based checks first for speed, then falls back to
    /// ``AnalysesFolder.listAnalyses`` content-based probing so that
    /// user-renamed directories are also recognised.
    private func isMetagenomicsResultDirectory(_ url: URL) -> Bool {
        let name = url.lastPathComponent
        let fm = FileManager.default

        // TaxTriage result directories (taxtriage-XXXXXXXX)
        if name.hasPrefix("taxtriage-") {
            let sidecar = url.appendingPathComponent("taxtriage-result.json")
            if fm.fileExists(atPath: sidecar.path) { return true }
            let hasKraken = fm.fileExists(atPath: url.appendingPathComponent("kraken2").path)
            if hasKraken { return true }
        }

        // Classification result directories
        if name.hasPrefix("classification-") {
            let sidecar = url.appendingPathComponent("classification-result.json")
            if fm.fileExists(atPath: sidecar.path) { return true }
        }

        // EsViritu result directories
        if name.hasPrefix("esviritu-") {
            let sidecar = url.appendingPathComponent("esviritu-result.json")
            if fm.fileExists(atPath: sidecar.path) { return true }
        }

        // NAO-MGS result bundles
        if name.hasPrefix("naomgs-") {
            let sidecar = url.appendingPathComponent("manifest.json")
            if fm.fileExists(atPath: sidecar.path) { return true }
        }

        // NVD result bundles
        if name.hasPrefix("nvd-") {
            let sidecar = url.appendingPathComponent("manifest.json")
            if fm.fileExists(atPath: sidecar.path) { return true }
        }

        // Authoritative metadata sidecar: analysis-metadata.json is written at
        // directory creation time and survives renames.
        if fm.fileExists(atPath: url.appendingPathComponent(AnalysesFolder.metadataFilename).path) {
            return true
        }

        // Content-based fallback: detect renamed analysis directories by their
        // signature files (e.g. manifest.json + hits.sqlite for NAO-MGS).
        // Only directories inside the Analyses/ folder reach this check, so
        // the probe cost is bounded.
        if url.deletingLastPathComponent().lastPathComponent == AnalysesFolder.directoryName {
            if fm.fileExists(atPath: url.appendingPathComponent("classification-result.json").path) { return true }
            if fm.fileExists(atPath: url.appendingPathComponent("manifest.json").path),
               fm.fileExists(atPath: url.appendingPathComponent("hits.sqlite").path) { return true }
        }

        return false
    }

    /// Collects child `.lungfishfastq` bundles from a parent bundle's `demux/` directory.
    ///
    /// Scans the `demux/` subdirectory tree for `.lungfishfastq` bundles, skipping
    /// the `materialized/` directory (intermediate full FASTQs used during processing).
    /// Returns bundles sorted alphabetically.
    private func collectDemuxChildBundles(in bundleURL: URL, excluding: Set<URL> = []) -> [URL] {
        let demuxDir = bundleURL.appendingPathComponent("demux", isDirectory: true)
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: demuxDir.path, isDirectory: &isDir), isDir.boolValue else {
            return []
        }

        var results: [URL] = []
        // Recursively scan demux/ for child .lungfishfastq bundles, skipping materialized/
        func scan(_ dir: URL) {
            guard let contents = try? fm.contentsOfDirectory(
                at: dir,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            ) else { return }

            for childURL in contents {
                var childIsDir: ObjCBool = false
                fm.fileExists(atPath: childURL.path, isDirectory: &childIsDir)
                guard childIsDir.boolValue else { continue }

                // Skip materialized/ directory (temporary full FASTQs during active processing)
                if childURL.lastPathComponent == "materialized" { continue }

                if FASTQBundle.isBundleURL(childURL) {
                    // Skip bundles that are batch operation outputs (shown under batch group nodes)
                    if !excluding.contains(childURL.standardizedFileURL) && !FASTQBundle.isProcessing(childURL) {
                        results.append(childURL)
                    }
                } else {
                    // Recurse into non-bundle subdirectories (e.g., barcode13/)
                    scan(childURL)
                }
            }
        }
        scan(demuxDir)
        return results.sorted { $0.lastPathComponent.localizedCaseInsensitiveCompare($1.lastPathComponent) == .orderedAscending }
    }

    /// Builds virtual batch group sidebar nodes from a pre-loaded batch manifest.
    private func buildBatchGroupNodes(manifest: FASTQBatchManifest, baseDirectory: URL) -> [SidebarItem] {
        return manifest.operations.map { record in
            let groupItem = SidebarItem(
                title: record.label,
                type: .batchGroup,
                icon: "tray.2",
                children: [],
                url: nil,
                subtitle: "\(record.successCount) processed"
            )

            // Resolve output bundle paths to sidebar items
            for relativePath in record.outputBundlePaths {
                let outputURL = baseDirectory.appendingPathComponent(relativePath)
                if FileManager.default.fileExists(atPath: outputURL.path) {
                    let childItem = buildSidebarTree(from: outputURL, isRoot: false)
                    groupItem.children.append(childItem)
                }
            }

            return groupItem
        }
    }

    // MARK: - Analyses/ Folder Scanning

    /// Collects analysis results from the project-level `Analyses/` directory.
    ///
    /// Uses `AnalysesFolder.listAnalyses(in:)` to discover timestamped analysis
    /// directories, filtering out any that are still in-progress (contain a
    /// `.processing` sentinel). Returns sidebar items sorted newest-first.
    private func collectAnalyses(in projectURL: URL) -> [SidebarItem] {
        let analysesDir = projectURL.appendingPathComponent(AnalysesFolder.directoryName, isDirectory: true)
        return collectAnalysisItems(in: analysesDir, includeLooseFolders: true)
    }

    private func collectAnalysisItems(in directoryURL: URL, includeLooseFolders: Bool) -> [SidebarItem] {
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        var items: [SidebarItem] = []
        for url in contents.sorted(by: {
            $0.lastPathComponent.localizedCaseInsensitiveCompare($1.lastPathComponent) == .orderedAscending
        }) {
            guard (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { continue }
            guard !OperationMarker.isInProgress(url) else { continue }

            if let info = AnalysesFolder.analysisInfo(for: url) {
                if let item = buildAnalysisItem(info: info) {
                    items.append(item)
                }
                continue
            }

            let children = collectAnalysisItems(in: url, includeLooseFolders: false)
            if !children.isEmpty {
                let folderItem = SidebarItem(
                    title: url.lastPathComponent,
                    type: .folder,
                    icon: "folder",
                    children: children,
                    url: url
                )
                items.append(folderItem)
            } else if includeLooseFolders {
                items.append(buildSidebarTree(from: url, isRoot: false))
            }
        }

        return items
    }

    private func buildAnalysisItem(info: AnalysesFolder.AnalysisDirectoryInfo) -> SidebarItem? {
        if info.isBatch {
            return buildBatchAnalysisItem(info: info)
        }

        let icon = analysisIcon(for: info.tool)
        let title = analysisDisplayTitle(for: info)
        let badge = classifierBatchBadge(for: info.tool)
        let item: SidebarItem
        if let badge {
            let sidebarItem = SidebarItem(
                title: title,
                type: analysisItemType(for: info.tool),
                customImage: TextBadgeIcon.image(text: badge, size: NSSize(width: 16, height: 16)),
                children: [],
                url: info.url,
                subtitle: AnalysesFolder.formatTimestamp(info.timestamp)
            )
            sidebarItem.userInfo["analysisTool"] = info.tool
            item = sidebarItem
        } else {
            let sidebarItem = SidebarItem(
                title: title,
                type: analysisItemType(for: info.tool),
                icon: icon,
                children: [],
                url: info.url,
                subtitle: AnalysesFolder.formatTimestamp(info.timestamp)
            )
            sidebarItem.userInfo["analysisTool"] = info.tool
            item = sidebarItem
        }
        if info.tool == "esviritu" {
            item.subtitle = esvirituResultTitle(for: info.url)
        } else if info.tool == "kraken2" {
            item.subtitle = classificationResultTitle(for: info.url)
        }
        return item
    }

    /// Builds a batch group item for a classifier or generic tool batch.
    ///
    /// For the three classifier tools (Kraken2, EsViritu, TaxTriage) the batch is
    /// a LEAF node — no per-sample children, no disclosure triangle. Sample
    /// filtering happens inside the batch viewer via the sample picker. The batch
    /// row uses a ``TextBadgeIcon`` pill badge (K2 / Es / TT) in Lungfish Orange.
    ///
    /// For generic tools (SPAdes, minimap2, etc.) this still enumerates
    /// per-sample children for browsing.
    private func buildBatchAnalysisItem(info: AnalysesFolder.AnalysisDirectoryInfo) -> SidebarItem? {
        let title = analysisDisplayTitle(for: info)

        // Classifier batches: build a leaf node with a text badge and no children.
        if let badge = classifierBatchBadge(for: info.tool) {
            let subtitle = classifierBatchSubtitle(for: info)
            guard subtitle != nil else { return nil }  // skip corrupt/empty batches
            return SidebarItem(
                title: title,
                type: .batchGroup,
                customImage: TextBadgeIcon.image(text: badge, size: NSSize(width: 16, height: 16)),
                children: [],
                url: info.url,
                subtitle: subtitle
            )
        }

        // Generic tools: expandable group with per-sample children.
        let groupItem = SidebarItem(
            title: title,
            type: .batchGroup,
            icon: "tray.2",
            children: [],
            url: info.url,
            subtitle: AnalysesFolder.formatTimestamp(info.timestamp)
        )
        buildBatchChildrenFromFilesystem(
            info: info,
            groupItem: groupItem,
            sidecarCheck: { _ in true },
            itemType: .analysisResult,
            icon: analysisIcon(for: info.tool)
        )
        guard !groupItem.children.isEmpty else { return nil }
        return groupItem
    }

    /// The badge text for a classifier batch sidebar icon, or nil for non-classifier tools.
    private func classifierBatchBadge(for tool: String) -> String? {
        switch tool {
        case "kraken2": return "K2"
        case "esviritu": return "ES"
        case "taxtriage": return "TT"
        case "naomgs": return "NM"
        case "nvd": return "NVD"
        default: return nil
        }
    }

    /// Computes the subtitle for a classifier batch sidebar row.
    ///
    /// Prefers the batch manifest (for accurate sample count and database name)
    /// and falls back to a filesystem scan when no manifest is present. Returns
    /// nil when the batch is genuinely empty so the caller can skip it.
    private func classifierBatchSubtitle(for info: AnalysesFolder.AnalysisDirectoryInfo) -> String? {
        let timestamp = AnalysesFolder.formatTimestamp(info.timestamp)

        switch info.tool {
        case "esviritu":
            if let manifest = MetagenomicsBatchResultStore.loadEsViritu(from: info.url) {
                return "\(manifest.header.sampleCount) samples · \(timestamp)"
            }
            let count = countBatchSampleSubdirectories(in: info.url, sidecarCheck: EsVirituResult.exists)
            return count > 0 ? "\(count) samples · \(timestamp)" : nil

        case "kraken2":
            if let manifest = MetagenomicsBatchResultStore.loadClassification(from: info.url) {
                let dbLabel = manifest.databaseName.isEmpty ? "" : " · \(manifest.databaseName)"
                return "\(manifest.header.sampleCount) samples\(dbLabel) · \(timestamp)"
            }
            let count = countBatchSampleSubdirectories(in: info.url, sidecarCheck: ClassificationResult.exists)
            return count > 0 ? "\(count) samples · \(timestamp)" : nil

        case "taxtriage":
            // TaxTriage writes sample subdirectories but no batch manifest.
            let count = countBatchSampleSubdirectories(in: info.url, sidecarCheck: { _ in true })
            return count > 0 ? "\(count) samples · \(timestamp)" : nil

        case "naomgs":
            let manifestURL = info.url.appendingPathComponent("manifest.json")
            if let data = try? Data(contentsOf: manifestURL) {
                let decoder = JSONDecoder()
                decoder.dateDecodingStrategy = .iso8601
                if let manifest = try? decoder.decode(NaoMgsManifest.self, from: data) {
                    let count = max(1, Set(manifest.cachedTaxonRows?.map(\.sample) ?? []).count)
                    return "\(count) samples · \(timestamp)"
                }
            }
            return timestamp

        case "nvd":
            let manifestURL = info.url.appendingPathComponent("manifest.json")
            if let data = try? Data(contentsOf: manifestURL) {
                let decoder = JSONDecoder()
                decoder.dateDecodingStrategy = .iso8601
                if let manifest = try? decoder.decode(NvdManifest.self, from: data) {
                    return "\(manifest.sampleCount) samples · \(timestamp)"
                }
            }
            return timestamp

        default:
            return timestamp
        }
    }

    /// Counts valid sample subdirectories inside a batch directory.
    private func countBatchSampleSubdirectories(
        in batchURL: URL,
        sidecarCheck: (URL) -> Bool
    ) -> Int {
        let fm = FileManager.default
        guard let contents = try? fm.contentsOfDirectory(
            at: batchURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return 0 }

        return contents.reduce(0) { count, child in
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: child.path, isDirectory: &isDir), isDir.boolValue else {
                return count
            }
            return sidecarCheck(child) ? count + 1 : count
        }
    }

    /// Fallback: enumerate subdirectories when no batch manifest is available.
    private func buildBatchChildrenFromFilesystem(
        info: AnalysesFolder.AnalysisDirectoryInfo,
        groupItem: SidebarItem,
        sidecarCheck: (URL) -> Bool,
        itemType: SidebarItemType,
        icon: String
    ) {
        let fm = FileManager.default
        guard let contents = try? fm.contentsOfDirectory(
            at: info.url,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return }

        for child in contents.sorted(by: {
            $0.lastPathComponent.localizedCaseInsensitiveCompare($1.lastPathComponent) == .orderedAscending
        }) {
            var childIsDir: ObjCBool = false
            guard fm.fileExists(atPath: child.path, isDirectory: &childIsDir),
                  childIsDir.boolValue else { continue }
            guard sidecarCheck(child) else { continue }
            let childItem = SidebarItem(
                title: child.lastPathComponent,
                type: itemType,
                icon: icon,
                children: [],
                url: child
            )
            // Identify the child as a specific sample so the routing layer can
            // filter the batch view to just this sample after display.
            childItem.userInfo["sampleId"] = child.lastPathComponent
            groupItem.children.append(childItem)
        }
        groupItem.subtitle = "\(groupItem.children.count) samples"
    }

    private func analysisIcon(for tool: String) -> String {
        switch tool {
        case "esviritu": return "e.circle"
        case "kraken2": return "k.circle"
        case "taxtriage": return "t.circle"
        case "spades", "megahit", "skesa", "flye", "hifiasm": return "s.circle"
        case "minimap2", "bwa-mem2", "bowtie2", "bbmap": return "m.circle"
        case "naomgs": return "n.circle"
        default: return "circle"
        }
    }

    private func analysisDisplayTitle(for info: AnalysesFolder.AnalysisDirectoryInfo) -> String {
        info.url.lastPathComponent
    }

    /// Maps an analysis tool name to the correct SidebarItemType so that
    /// the selection handler in MainSplitViewController dispatches to the
    /// right display method.
    private func analysisItemType(for tool: String) -> SidebarItemType {
        switch tool {
        case "esviritu": return .esvirituResult
        case "kraken2": return .classificationResult
        case "taxtriage": return .taxTriageResult
        case "naomgs": return .naoMgsResult
        case "nvd": return .nvdResult
        default: return .analysisResult
        }
    }

    /// Derives a human-readable title for a classification result directory.
    ///
    /// Attempts to read the sidecar JSON to extract the database name.
    /// Falls back to a generic label if the sidecar cannot be parsed.
    ///
    /// - Parameter directory: The classification result directory.
    /// - Returns: A display title such as "Classification (Viral DB)".
    private func classificationResultTitle(for directory: URL) -> String {
        // Try to load just the sidecar metadata (lightweight, no tree parsing)
        let sidecarURL = directory.appendingPathComponent("classification-result.json")
        if let data = try? Data(contentsOf: sidecarURL),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let config = json["config"] as? [String: Any],
           let dbName = config["databaseName"] as? String {
            return "Classification (\(dbName))"
        }
        return "Classification"
    }

    /// Derives a human-readable title for an EsViritu result directory.
    private func esvirituResultTitle(for directory: URL) -> String {
        let sidecarURL = directory.appendingPathComponent("esviritu-result.json")
        if let data = try? Data(contentsOf: sidecarURL),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let virusCount = json["virusCount"] as? Int {
            return "Viral Detection (\(virusCount) viruses)"
        }
        return "Viral Detection"
    }

    /// Collects NAO-MGS result bundles from inside a directory.
    ///
    /// Scans for `naomgs-*` directories that contain a `manifest.json` sidecar,
    /// builds a sidebar item for each one using the sample name from the manifest.
    ///
    /// - Parameter bundleURL: Directory to scan (typically a FASTQ bundle or Imports/).
    /// - Returns: Array of `SidebarItem` nodes for NAO-MGS result bundles.
    private func collectNaoMgsResults(in bundleURL: URL) -> [SidebarItem] {
        let fm = FileManager.default
        guard let contents = try? fm.contentsOfDirectory(
            at: bundleURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        var results: [SidebarItem] = []

        for childURL in contents {
            guard !OperationMarker.isInProgress(childURL) else { continue }
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: childURL.path, isDirectory: &isDir), isDir.boolValue else { continue }

            // Match by naomgs- prefix or by analysis-metadata.json declaring tool=naomgs
            let hasPrefix = childURL.lastPathComponent.hasPrefix("naomgs-")
            let hasMetadata = AnalysesFolder.readAnalysisMetadata(from: childURL)?.tool == "naomgs"
            guard hasPrefix || hasMetadata else { continue }

            // Require a manifest.json sidecar
            let manifestURL = childURL.appendingPathComponent("manifest.json")
            guard fm.fileExists(atPath: manifestURL.path) else { continue }

            // Read the manifest for display title
            let title = naoMgsResultTitle(for: childURL)

            let item = SidebarItem(
                title: title,
                type: .naoMgsResult,
                customImage: TextBadgeIcon.image(text: "NM", size: NSSize(width: 16, height: 16)),
                children: [],
                url: childURL
            )
            results.append(item)
        }

        return results.sorted {
            $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
        }
    }

    /// Derives a display title for a NAO-MGS result bundle from its manifest.
    ///
    /// Falls back to "NAO-MGS" if the manifest cannot be read.
    private func naoMgsResultTitle(for directory: URL) -> String {
        let manifestURL = directory.appendingPathComponent("manifest.json")
        guard let data = try? Data(contentsOf: manifestURL) else {
            return "NAO-MGS"
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let manifest = try? decoder.decode(NaoMgsManifest.self, from: data) else {
            return "NAO-MGS"
        }
        return "NAO-MGS: \(manifest.sampleName)"
    }

    /// Collects NVD result bundles from inside a directory.
    ///
    /// Scans for `nvd-*` directories that contain a `manifest.json` sidecar,
    /// builds a sidebar item for each one using the experiment name from the manifest.
    ///
    /// - Parameter bundleURL: Directory to scan (typically a FASTQ bundle or Imports/).
    /// - Returns: Array of `SidebarItem` nodes for NVD result bundles.
    private func collectNvdResults(in bundleURL: URL) -> [SidebarItem] {
        let fm = FileManager.default
        guard let contents = try? fm.contentsOfDirectory(
            at: bundleURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        var results: [SidebarItem] = []

        for childURL in contents {
            guard !OperationMarker.isInProgress(childURL) else { continue }
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: childURL.path, isDirectory: &isDir), isDir.boolValue else { continue }

            // Match by nvd- prefix or by analysis-metadata.json declaring tool=nvd
            let hasPrefix = childURL.lastPathComponent.hasPrefix("nvd-")
            let hasMetadata = AnalysesFolder.readAnalysisMetadata(from: childURL)?.tool == "nvd"
            guard hasPrefix || hasMetadata else { continue }

            // Require a manifest.json sidecar
            let manifestURL = childURL.appendingPathComponent("manifest.json")
            guard fm.fileExists(atPath: manifestURL.path) else { continue }

            // Read the manifest for display title
            let title = nvdResultTitle(for: childURL)

            let item = SidebarItem(
                title: title,
                type: .nvdResult,
                customImage: TextBadgeIcon.image(text: "NVD", size: NSSize(width: 16, height: 16)),
                children: [],
                url: childURL
            )
            results.append(item)
        }

        return results.sorted {
            $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
        }
    }

    /// Derives a display title for an NVD result bundle from its manifest.
    ///
    /// Falls back to "NVD" if the manifest cannot be read.
    private func nvdResultTitle(for directory: URL) -> String {
        let manifestURL = directory.appendingPathComponent("manifest.json")
        guard let data = try? Data(contentsOf: manifestURL) else {
            return "NVD"
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let manifest = try? decoder.decode(NvdManifest.self, from: data) else {
            return "NVD"
        }
        return "NVD: \(manifest.experiment)"
    }

    /// Counts the total number of items in a tree.
    private func countItems(in item: SidebarItem) -> Int {
        return 1 + item.children.reduce(0) { $0 + self.countItems(in: $1) }
    }

    /// Restores selection after a reload.
    private func restoreSelection(urls: [URL]) {
        guard !urls.isEmpty else { return }

        var rowsToSelect = IndexSet()

        for url in urls {
            if let item = findItem(byURL: url) {
                // Reload rebuilds tree objects and collapses expandable containers by default.
                // Re-open the parent chain first so nested selections (e.g. metagenomics
                // result nodes under FASTQ bundles/batch groups) remain selectable.
                expandParents(of: item)
                let row = outlineView.row(forItem: item)
                if row >= 0 {
                    rowsToSelect.insert(row)
                }
            }
        }

        if !rowsToSelect.isEmpty {
            if outlineView.selectedRowIndexes == rowsToSelect {
                return
            }
            outlineView.selectRowIndexes(rowsToSelect, byExtendingSelection: false)
        }
    }

    private func urlsMatch(_ lhs: URL, _ rhs: URL) -> Bool {
        let standardizedLHS = lhs.standardizedFileURL
        let standardizedRHS = rhs.standardizedFileURL
        if standardizedLHS == standardizedRHS {
            return true
        }
        return standardizedLHS.resolvingSymlinksInPath() == standardizedRHS.resolvingSymlinksInPath()
    }

    /// Finds a sidebar item by URL.
    private func findItem(byURL url: URL) -> SidebarItem? {
        func search(in items: [SidebarItem]) -> SidebarItem? {
            for item in items {
                if let itemURL = item.url, urlsMatch(itemURL, url) {
                    return item
                }
                if let found = search(in: item.children) {
                    return found
                }
            }
            return nil
        }
        return search(in: rootItems)
    }

    /// Returns the current project URL.
    public var currentProjectURL: URL? {
        return projectURL
    }

    // MARK: - Document Management

    /// Returns the sidebar item type and icon name for a given document type.
    private func sidebarItemInfo(for documentType: DocumentType) -> (type: SidebarItemType, icon: String) {
        switch documentType {
        case .fasta, .fastq:
            return (.sequence, "doc.text")
        case .genbank:
            return (.sequence, "doc.richtext")
        case .gff3, .bed:
            return (.annotation, "list.bullet.rectangle")
        case .vcf:
            return (.annotation, "chart.bar.xaxis")
        case .bam:
            return (.alignment, "chart.bar")
        case .lungfishProject:
            return (.sequence, "folder.badge.gearshape")
        case .lungfishReferenceBundle:
            return (.referenceBundle, "cylinder.split.1x2")
        }
    }

    /// Adds a loaded document to the sidebar
    public func addLoadedDocument(_ document: LoadedDocument) {
        logger.info("addLoadedDocument: Adding '\(document.name, privacy: .public)' to sidebar")

        // Find or create the "Open Documents" group
        var openDocsGroup = rootItems.first(where: { $0.title == "OPEN DOCUMENTS" })
        if openDocsGroup == nil {
            logger.debug("addLoadedDocument: Creating OPEN DOCUMENTS group")
            openDocsGroup = SidebarItem(
                title: "OPEN DOCUMENTS",
                type: .group,
                children: []
            )
            rootItems.insert(openDocsGroup!, at: 0)
        }

        let info = sidebarItemInfo(for: document.type)

        // Check if document already exists in sidebar
        if openDocsGroup!.children.contains(where: { $0.url == document.url }) {
            logger.debug("addLoadedDocument: Document already in sidebar")
            return
        }

        // Create the sidebar item
        let item = SidebarItem(
            title: document.name,
            type: info.type,
            icon: info.icon,
            children: [],
            url: document.url
        )

        openDocsGroup!.children.append(item)
        logger.info("addLoadedDocument: Added item to sidebar, reloading")

        reloadOutlineView()

        // Expand the open documents group and select the new item
        outlineView.expandItem(openDocsGroup)
        let row = outlineView.row(forItem: item)
        if row >= 0 {
            outlineView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        }
    }

    /// Adds a downloaded document to the Downloads folder within the project hierarchy.
    ///
    /// This method places downloaded files (like NCBI downloads) into a "Downloads" subfolder
    /// within the project structure, rather than the "OPEN DOCUMENTS" group.
    ///
    /// - Parameters:
    ///   - document: The loaded document to add
    ///   - projectURL: The project folder URL (if available)
    public func addDownloadedDocument(_ document: LoadedDocument, projectURL: URL?) {
        logger.info("addDownloadedDocument: Adding '\(document.name, privacy: .public)' to Downloads folder")

        // Try to find an existing project folder in the sidebar
        var targetProjectItem: SidebarItem?

        // If projectURL is provided, find the matching project
        if let projectURL = projectURL {
            targetProjectItem = rootItems.first(where: {
                $0.type == .project && $0.url?.standardizedFileURL == projectURL.standardizedFileURL
            })
        }

        // If no project found, try to find any project folder
        if targetProjectItem == nil {
            targetProjectItem = rootItems.first(where: { $0.type == .project })
        }

        // If still no project, fall back to addLoadedDocument behavior
        guard let projectItem = targetProjectItem else {
            logger.debug("addDownloadedDocument: No project found, falling back to OPEN DOCUMENTS")
            addLoadedDocument(document)
            return
        }

        logger.debug("addDownloadedDocument: Found project '\(projectItem.title, privacy: .public)'")

        // Find or create the "Downloads" folder within the project
        var downloadsFolder = projectItem.children.first(where: {
            $0.title.lowercased() == "downloads" && $0.type == .folder
        })

        if downloadsFolder == nil {
            logger.debug("addDownloadedDocument: Creating Downloads folder")
            let downloadsURL = projectItem.url?.appendingPathComponent("Downloads", isDirectory: true)
            downloadsFolder = SidebarItem(
                title: "Downloads",
                type: .folder,
                icon: "arrow.down.circle",
                children: [],
                url: downloadsURL
            )

            // Insert downloads folder at the beginning of project children (after other folders)
            let firstNonFolderIndex = projectItem.children.firstIndex(where: { $0.type != .folder }) ?? projectItem.children.count
            projectItem.children.insert(downloadsFolder!, at: firstNonFolderIndex)
        }

        let info = sidebarItemInfo(for: document.type)

        // Check if document already exists in downloads folder
        if downloadsFolder!.children.contains(where: { $0.url == document.url }) {
            logger.debug("addDownloadedDocument: Document already in downloads folder")
            return
        }

        // Create the sidebar item for the downloaded document
        let item = SidebarItem(
            title: document.name,
            type: info.type,
            icon: info.icon,
            children: [],
            url: document.url
        )

        downloadsFolder!.children.append(item)
        logger.info("addDownloadedDocument: Added '\(document.name, privacy: .public)' to Downloads folder, reloading")

        reloadOutlineView()

        // Expand the project and downloads folder, then select the new item
        outlineView.expandItem(projectItem)
        outlineView.expandItem(downloadsFolder)

        let row = outlineView.row(forItem: item)
        if row >= 0 {
            outlineView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        }
    }

    /// Adds a project folder with all its documents to the sidebar.
    ///
    /// - Parameters:
    ///   - folderURL: The root folder URL
    ///   - documents: The loaded documents from the folder
    public func addProjectFolder(_ folderURL: URL, documents: [LoadedDocument]) {
        logger.info("addProjectFolder: Adding folder '\(folderURL.lastPathComponent, privacy: .public)' with \(documents.count) documents")

        // Idempotent: Remove existing project folder with same URL if present
        let normalizedURL = folderURL.standardizedFileURL
        if let existingIndex = rootItems.firstIndex(where: {
            $0.type == .project && $0.url?.standardizedFileURL == normalizedURL
        }) {
            logger.info("addProjectFolder: Replacing existing folder at index \(existingIndex)")
            rootItems.remove(at: existingIndex)
        }

        // Create the project folder item
        let folderItem = SidebarItem(
            title: folderURL.lastPathComponent,
            type: .project,
            icon: "folder.badge.gearshape",
            children: [],
            url: folderURL
        )

        // Build folder hierarchy from document paths
        var subfolderItems: [String: SidebarItem] = [:]  // Relative path -> item

        for document in documents {
            // Calculate relative path from folder root to file's parent directory
            let fileParentPath = document.url.deletingLastPathComponent().path
            let relativePath = fileParentPath
                .replacingOccurrences(of: folderURL.path, with: "")
                .trimmingCharacters(in: CharacterSet(charactersIn: "/"))

            let info = sidebarItemInfo(for: document.type)

            // Create document item
            let docItem = SidebarItem(
                title: document.name,
                type: info.type,
                icon: info.icon,
                children: [],
                url: document.url
            )

            if relativePath.isEmpty {
                // File is directly in root folder
                folderItem.children.append(docItem)
                logger.debug("addProjectFolder: Added '\(document.name, privacy: .public)' to root")
            } else {
                // File is in a subfolder - create subfolder hierarchy if needed
                if subfolderItems[relativePath] == nil {
                    // Create subfolder item
                    let subfolderName = URL(fileURLWithPath: relativePath).lastPathComponent
                    let subfolderItem = SidebarItem(
                        title: subfolderName,
                        type: .folder,
                        icon: "folder",
                        children: [],
                        url: folderURL.appendingPathComponent(relativePath)
                    )
                    subfolderItems[relativePath] = subfolderItem
                    folderItem.children.append(subfolderItem)
                    logger.debug("addProjectFolder: Created subfolder '\(subfolderName, privacy: .public)'")
                }
                subfolderItems[relativePath]?.children.append(docItem)
                logger.debug("addProjectFolder: Added '\(document.name, privacy: .public)' to subfolder '\(relativePath, privacy: .public)'")
            }
        }

        // Sort children alphabetically (folders first, then files)
        folderItem.children.sort { item1, item2 in
            if item1.type == .folder && item2.type != .folder {
                return true
            } else if item1.type != .folder && item2.type == .folder {
                return false
            }
            return item1.title.localizedCaseInsensitiveCompare(item2.title) == .orderedAscending
        }

        // Sort subfolder children too
        for (_, subfolderItem) in subfolderItems {
            subfolderItem.children.sort { item1, item2 in
                item1.title.localizedCaseInsensitiveCompare(item2.title) == .orderedAscending
            }
        }

        // Add to root items
        rootItems.append(folderItem)

        logger.info("addProjectFolder: Reloading outline view with \(folderItem.children.count) children")
        reloadOutlineView()

        // Expand the folder to show contents
        outlineView.expandItem(folderItem)

        // Select the first document if any
        let firstDoc = folderItem.children.first(where: { $0.type != .folder }) ?? folderItem.children.first?.children.first
        if let firstDoc = firstDoc {
            let row = outlineView.row(forItem: firstDoc)
            if row >= 0 {
                outlineView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
                logger.debug("addProjectFolder: Selected first document at row \(row)")
            }
        }
    }

    /// Adds a single file to an existing project in the sidebar.
    ///
    /// Called when a file is dropped into a project. Adds the file to the
    /// appropriate subfolder based on its path.
    ///
    /// - Parameters:
    ///   - document: The loaded document to add
    ///   - projectURL: The project folder URL
    public func addFileToProject(_ document: LoadedDocument, projectURL: URL) {
        logger.info("addFileToProject: Adding '\(document.name, privacy: .public)' to project")

        // Find the project item in the sidebar
        let normalizedProjectURL = projectURL.standardizedFileURL
        guard let projectItem = rootItems.first(where: {
            $0.type == .project && $0.url?.standardizedFileURL == normalizedProjectURL
        }) else {
            logger.warning("addFileToProject: Project not found in sidebar, falling back to addLoadedDocument")
            addLoadedDocument(document)
            return
        }

        // Calculate relative path from project root to file's parent directory
        let fileParentPath = document.url.deletingLastPathComponent().path
        let relativePath = fileParentPath
            .replacingOccurrences(of: projectURL.path, with: "")
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))

        let info = sidebarItemInfo(for: document.type)

        // Create document item
        let docItem = SidebarItem(
            title: document.name,
            type: info.type,
            icon: info.icon,
            children: [],
            url: document.url
        )

        // Check if document already exists in sidebar
        func documentExists(in items: [SidebarItem]) -> Bool {
            for item in items {
                if item.url?.standardizedFileURL == document.url.standardizedFileURL {
                    return true
                }
                if documentExists(in: item.children) {
                    return true
                }
            }
            return false
        }

        if documentExists(in: projectItem.children) {
            logger.debug("addFileToProject: Document already exists in project sidebar")
            return
        }

        if relativePath.isEmpty {
            // File is directly in project root folder
            projectItem.children.append(docItem)
            logger.info("addFileToProject: Added '\(document.name, privacy: .public)' to project root")
        } else {
            // File is in a subfolder - find or create the subfolder
            let subfolderName = URL(fileURLWithPath: relativePath).lastPathComponent
            var subfolderItem = projectItem.children.first(where: {
                $0.type == .folder && $0.title == subfolderName
            })

            if subfolderItem == nil {
                // Create new subfolder
                subfolderItem = SidebarItem(
                    title: subfolderName,
                    type: .folder,
                    icon: "folder",
                    children: [],
                    url: projectURL.appendingPathComponent(relativePath)
                )
                projectItem.children.append(subfolderItem!)
                logger.info("addFileToProject: Created subfolder '\(subfolderName, privacy: .public)'")
            }

            subfolderItem!.children.append(docItem)
            logger.info("addFileToProject: Added '\(document.name, privacy: .public)' to subfolder '\(subfolderName, privacy: .public)'")

            // Expand the subfolder
            outlineView.expandItem(subfolderItem)
        }

        // Sort children (folders first, then files alphabetically)
        projectItem.children.sort { item1, item2 in
            if item1.type == .folder && item2.type != .folder {
                return true
            } else if item1.type != .folder && item2.type == .folder {
                return false
            }
            return item1.title.localizedCaseInsensitiveCompare(item2.title) == .orderedAscending
        }

        // Reload and select the new item
        reloadOutlineView()
        outlineView.expandItem(projectItem)

        let row = outlineView.row(forItem: docItem)
        if row >= 0 {
            outlineView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            outlineView.scrollRowToVisible(row)
        }

        logger.info("addFileToProject: Sidebar updated successfully")
    }

    /// Refreshes a sidebar item after background loading completes.
    ///
    /// Called when a document finishes loading in the background. Updates
    /// the item's visual state to reflect loaded status.
    ///
    /// - Parameter url: The URL of the document that finished loading
    public func refreshItem(for url: URL) {
        let normalizedURL = url.standardizedFileURL

        // Find the item matching this URL in the sidebar hierarchy
        func findItem(in items: [SidebarItem]) -> SidebarItem? {
            for item in items {
                if item.url?.standardizedFileURL == normalizedURL {
                    return item
                }
                if let found = findItem(in: item.children) {
                    return found
                }
            }
            return nil
        }

        guard let item = findItem(in: rootItems) else {
            logger.debug("refreshItem: No item found for \(url.lastPathComponent, privacy: .public)")
            return
        }

        // Reload just this item to update its display
        outlineView.reloadItem(item, reloadChildren: false)
        logger.debug("refreshItem: Refreshed \(item.title, privacy: .public)")
    }
}

// MARK: - NSOutlineViewDataSource

extension SidebarViewController: NSOutlineViewDataSource {

    public func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        if item == nil {
            return displayItems.count
        }
        if let sidebarItem = item as? SidebarItem {
            return sidebarItem.children.count
        }
        return 0
    }

    public func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        if item == nil {
            return displayItems[index]
        }
        if let sidebarItem = item as? SidebarItem {
            return sidebarItem.children[index]
        }
        fatalError("Unexpected item type")
    }

    public func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        if let sidebarItem = item as? SidebarItem {
            return !sidebarItem.children.isEmpty
        }
        return false
    }

    // MARK: - Drag Source

    /// Initiates a drag operation when user starts dragging an item
    public func outlineView(_ outlineView: NSOutlineView, pasteboardWriterForItem item: Any) -> NSPasteboardWriting? {
        guard let sidebarItem = item as? SidebarItem else { return nil }

        // Don't allow dragging groups
        if sidebarItem.type == .group {
            return nil
        }

        logger.debug("pasteboardWriterForItem: Starting drag for '\(sidebarItem.title, privacy: .public)'")

        // Create a pasteboard item with the sidebar item's identifier
        let pasteboardItem = NSPasteboardItem()

        // Use the item's URL path as the identifier (or title if no URL)
        let identifier = sidebarItem.url?.path ?? sidebarItem.title
        pasteboardItem.setString(identifier, forType: sidebarItemPasteboardType)

        // Also provide file URL if available for external drops
        if let url = sidebarItem.url {
            pasteboardItem.setString(url.absoluteString, forType: .fileURL)
        }

        return pasteboardItem
    }

    /// Allows the user to drag multiple items at once
    public func outlineView(_ outlineView: NSOutlineView, draggingSession session: NSDraggingSession, willBeginAt screenPoint: NSPoint, forItems draggedItems: [Any]) {
        logger.debug("draggingSession willBegin: Dragging \(draggedItems.count) items")
        session.draggingFormation = .stack
    }

    /// Called when dragging ends
    public func outlineView(_ outlineView: NSOutlineView, draggingSession session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        logger.debug("draggingSession ended: operation=\(operation.rawValue)")
    }

    // MARK: - Drag Destination

    /// Called by NSOutlineView to update dragging items - required for proper drag feedback
    public func outlineView(_ outlineView: NSOutlineView, updateDraggingItemsForDrag draggingInfo: NSDraggingInfo) {
        debugLog("updateDraggingItemsForDrag: Called")
    }

    /// Validates whether a drop is allowed at the proposed location
    public func outlineView(_ outlineView: NSOutlineView, validateDrop info: NSDraggingInfo, proposedItem item: Any?, proposedChildIndex index: Int) -> NSDragOperation {
        debugLog("validateDrop: ENTERED METHOD")

        // Get the destination item
        let destinationItem = item as? SidebarItem

        debugLog("validateDrop: Called with destinationItem='\(destinationItem?.title ?? "nil")' type=\(String(describing: destinationItem?.type)) index=\(index)")

        // Determine if this is an internal drag
        let isInternalDrag = info.draggingPasteboard.availableType(from: [sidebarItemPasteboardType]) != nil
        debugLog("validateDrop: isInternalDrag=\(isInternalDrag)")

        if isInternalDrag {
            let sourceIdentifier = info.draggingPasteboard.string(forType: sidebarItemPasteboardType)
            let hasLocalSource = sourceIdentifier.flatMap { findItem(byPath: $0) } != nil

            guard Self.internalDropDestinationURL(projectURL: projectURL, destinationItem: destinationItem) != nil else {
                return []
            }

            // Cross-window drags carry the internal type, but source items aren't
            // in this sidebar model. Treat these as copy imports.
            if !hasLocalSource {
                logger.debug("validateDrop: Internal type from another window - COPY import")
                return .copy
            }

            // Check for Control key to copy, otherwise move
            let modifiers = NSEvent.modifierFlags
            if modifiers.contains(.control) || modifiers.contains(.option) {
                logger.debug("validateDrop: Internal drag - COPY")
                return .copy
            } else {
                logger.debug("validateDrop: Internal drag - MOVE")
                return .move
            }
        } else {
            // External file drop - accept anywhere in the sidebar
            debugLog("validateDrop: External file drag detected")

            // For external files, retarget to the project root or accept at root level
            // This ensures drops anywhere in the sidebar are accepted
            if let dest = destinationItem {
                debugLog("validateDrop: External file over '\(dest.title)' type=\(String(describing: dest.type))")

                // If dropping on a specific container, accept there
                if dest.type == .folder || dest.type == .project || dest.type == .group {
                    debugLog("validateDrop: External file - ACCEPTING into container '\(dest.title)'")
                    return .copy
                }

                // If dropping on a file item, retarget to its parent container
                // The drop will still work - we just need to return .copy
                debugLog("validateDrop: External file over non-container - ACCEPTING (will use project root)")
                return .copy
            }

            // Drop at root level - accept it
            debugLog("validateDrop: External file - ACCEPTING at root level")
            return .copy
        }
    }

    /// Logs debug info for drag-and-drop troubleshooting
    private func debugLog(_ message: String) {
        logger.debug("SidebarVC: \(message, privacy: .public)")
    }

    /// Performs the actual drop operation
    public func outlineView(_ outlineView: NSOutlineView, acceptDrop info: NSDraggingInfo, item: Any?, childIndex index: Int) -> Bool {
        debugLog("acceptDrop: CALLED!")
        let pasteboard = info.draggingPasteboard
        let destinationItem = item as? SidebarItem
        debugLog("acceptDrop: destinationItem='\(destinationItem?.title ?? "nil")'")

        // Log all available pasteboard types
        let types = pasteboard.types ?? []
        debugLog("acceptDrop: Available pasteboard types: \(types.map { $0.rawValue }.joined(separator: ", "))")

        // Check if this is an internal drag
        let hasInternalType = pasteboard.availableType(from: [sidebarItemPasteboardType]) != nil
        debugLog("acceptDrop: hasInternalType=\(hasInternalType)")

        if hasInternalType {
            let identifiers = Self.draggedItemIdentifiers(from: pasteboard)
            debugLog("acceptDrop: Internal drag detected with \(identifiers.count) identifier(s)")

            // Find the source item by its identifier
            let sourceItems = identifiers.compactMap { findItem(byPath: $0) }
            if !sourceItems.isEmpty,
               let destinationURL = Self.internalDropDestinationURL(projectURL: projectURL, destinationItem: destinationItem) {
                // Check modifier keys for copy vs move
                let modifiers = NSEvent.modifierFlags
                let isCopy = modifiers.contains(.control) || modifiers.contains(.option)

                if isCopy {
                    // Copy the item
                    return copyItems(sourceItems, toFolderURL: destinationURL, at: index)
                } else {
                    // Move the item
                    return moveItems(sourceItems, toFolderURL: destinationURL, at: index)
                }
            }

            // Cross-window drags include our internal type but the source item
            // is not present in this window's sidebar model; fall through to the
            // external file URL path so the file is copied into this project.
            logger.debug("acceptDrop: Internal identifier not resolvable in this sidebar; falling back to file URL import")
        }

        // External file drop
        debugLog("acceptDrop: Attempting to read file URLs from pasteboard")

        // Try reading with NSURL class
        if let fileURLs = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !fileURLs.isEmpty {
            debugLog("acceptDrop: SUCCESS - got \(fileURLs.count) file URLs")
            for (i, url) in fileURLs.enumerated() {
                debugLog("acceptDrop: URL[\(i)] = \(url.path)")
            }

            logger.info("acceptDrop: Posting notification for \(fileURLs.count) files")
            NotificationCenter.default.post(
                name: .sidebarFileDropped,
                object: self,
                userInfo: ["urls": fileURLs, "destination": destinationItem as Any]
            )
            return true
        }

        // Fallback: try reading file URLs directly from pasteboard
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self]) as? [URL], !urls.isEmpty {
            logger.info("acceptDrop: Fallback - found \(urls.count) URLs")
            let fileURLs = urls.filter { $0.isFileURL }
            logger.info("acceptDrop: Fallback - \(fileURLs.count) are file URLs")

            if !fileURLs.isEmpty {
                logger.info("acceptDrop: Fallback posting notification for \(fileURLs.count) files")
                NotificationCenter.default.post(
                    name: .sidebarFileDropped,
                    object: self,
                    userInfo: ["urls": fileURLs, "destination": destinationItem as Any]
                )
                return true
            }
        }

        debugLog("acceptDrop: FAILED - No file URLs found in pasteboard")
        return false
    }

    // MARK: - Selection Helpers

    static func draggedItemIdentifiers(from pasteboard: NSPasteboard) -> [String] {
        var identifiers: [String] = []
        var seen = Set<String>()

        for item in pasteboard.pasteboardItems ?? [] {
            guard let identifier = item.string(forType: sidebarItemPasteboardType),
                  !seen.contains(identifier) else {
                continue
            }
            identifiers.append(identifier)
            seen.insert(identifier)
        }

        if identifiers.isEmpty,
           let identifier = pasteboard.string(forType: sidebarItemPasteboardType) {
            identifiers.append(identifier)
        }

        return identifiers
    }

    /// Returns all currently selected sidebar items
    public func selectedItems() -> [SidebarItem] {
        var items: [SidebarItem] = []
        outlineView.selectedRowIndexes.forEach { row in
            if let item = outlineView.item(atRow: row) as? SidebarItem {
                items.append(item)
            }
        }
        return items
    }

    /// Returns the URL of the first selected sidebar item that has a file URL.
    public var selectedFileURL: URL? {
        selectedItems().first(where: { $0.url != nil })?.url
    }

    static func suggestedMergedBundleName(for items: [SidebarItem]) -> String {
        let trimmedTitle = items.first?.title.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmedTitle.isEmpty ? "Merged Bundle" : "\(trimmedTitle) merged"
    }

    static func deepestCommonParent(for urls: [URL]) -> URL? {
        let parentComponents = urls.map { $0.deletingLastPathComponent().standardizedFileURL.pathComponents }
        guard var sharedComponents = parentComponents.first else { return nil }

        for components in parentComponents.dropFirst() {
            while sharedComponents.count > 1 && !components.starts(with: sharedComponents) {
                sharedComponents.removeLast()
            }
        }

        guard sharedComponents.count > 1 else { return nil }

        var result = URL(fileURLWithPath: sharedComponents[0], isDirectory: true)
        for component in sharedComponents.dropFirst() {
            result.appendPathComponent(component, isDirectory: true)
        }
        return result.standardizedFileURL
    }

    static func internalDropDestinationURL(projectURL: URL?, destinationItem: SidebarItem?) -> URL? {
        if let destinationItem {
            guard destinationItem.type == .folder || destinationItem.type == .project else {
                return nil
            }
            return destinationItem.url?.standardizedFileURL
        }

        return projectURL?.standardizedFileURL
    }

    // MARK: - Select All Siblings

    /// Selects all sibling items of the currently selected item in the outline view.
    /// Triggered by Cmd+Shift+A. Useful for batch-selecting all barcodes at the same level.
    public func selectAllSiblings() {
        guard let selectedItem = selectedItems().first else { return }

        // Find the parent — siblings are the parent's children (or rootItems if top-level)
        let siblings: [SidebarItem]
        if let parent = findParent(of: selectedItem) {
            siblings = parent.children
        } else {
            // Top-level item — siblings are rootItems
            siblings = rootItems
        }

        guard siblings.count > 1 else { return }

        // Build row index set for all siblings
        var rowIndexes = IndexSet()
        for sibling in siblings {
            let row = outlineView.row(forItem: sibling)
            if row >= 0 {
                rowIndexes.insert(row)
            }
        }

        guard !rowIndexes.isEmpty else { return }
        outlineView.selectRowIndexes(rowIndexes, byExtendingSelection: false)
        logger.info("selectAllSiblings: Selected \(rowIndexes.count) sibling(s)")
    }

    // MARK: - Delete Operations

    /// Deletes the currently selected items, moving files to Trash
    @objc public func deleteSelectedItems() {
        let items = selectedItems()
        guard !items.isEmpty else {
            logger.debug("deleteSelectedItems: No items selected")
            return
        }

        // Filter out items that shouldn't be deleted (groups, projects).
        // Batch groups WITH a URL (analysis batches in Analyses/) are deletable —
        // trashing the batch directory removes all component sample results.
        let deletableItems = items.filter { item in
            if item.type == .group || item.type == .project { return false }
            if item.type == .batchGroup { return item.url != nil }
            return true
        }

        guard !deletableItems.isEmpty else {
            logger.debug("deleteSelectedItems: No deletable items in selection")
            return
        }

        // Show confirmation dialog
        let itemCount = deletableItems.count
        let message = itemCount == 1
            ? "Are you sure you want to move \"\(deletableItems[0].title)\" to the Trash?"
            : "Are you sure you want to move \(itemCount) items to the Trash?"

        let alert = NSAlert()
        alert.messageText = "Move to Trash"
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Move to Trash")
        alert.addButton(withTitle: "Cancel")

        guard let window = view.window else { return }

        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            self?.performDelete(items: deletableItems)
        }
    }

    /// Performs the actual deletion of items
    private func performDelete(items: [SidebarItem]) {
        logger.info("performDelete: Deleting \(items.count) items")

        var failedItems: [(SidebarItem, Error)] = []

        for item in items {
            // Move file to Trash if URL exists
            if let url = item.url {
                do {
                    try FileManager.default.trashItem(at: url, resultingItemURL: nil)
                    logger.info("performDelete: Trashed file \(url.path, privacy: .public)")
                } catch {
                    logger.error("performDelete: Failed to trash \(url.path, privacy: .public) - \(error.localizedDescription, privacy: .public)")
                    failedItems.append((item, error))
                    continue  // Don't remove from sidebar if file deletion failed
                }
            }

            // Remove from sidebar hierarchy
            removeItemFromSidebar(item)
        }

        reloadOutlineView()

        // Show error if some items failed
        if !failedItems.isEmpty {
            let alert = NSAlert()
            alert.messageText = "Some items could not be deleted"
            alert.informativeText = failedItems.map { "\($0.0.title): \($0.1.localizedDescription)" }.joined(separator: "\n")
            alert.alertStyle = .warning
            alert.addButton(withTitle: "OK")
            if let window = view.window {
                alert.beginSheetModal(for: window)
            }
        }

        // Post notification about deletion
        NotificationCenter.default.post(
            name: .sidebarItemsDeleted,
            object: self,
            userInfo: ["items": items]
        )
    }

    /// Removes an item from the sidebar hierarchy (without touching the file)
    private func removeItemFromSidebar(_ item: SidebarItem) {
        if let parent = findParent(of: item) {
            parent.children.removeAll { $0 === item }
            logger.debug("removeItemFromSidebar: Removed '\(item.title, privacy: .public)' from parent '\(parent.title, privacy: .public)'")
        } else {
            // Item is at root level
            rootItems.removeAll { $0 === item }
            logger.debug("removeItemFromSidebar: Removed '\(item.title, privacy: .public)' from root")
        }
    }

    // MARK: - Drag Helper Methods

    /// Finds a sidebar item by its URL path
    private func findItem(byPath path: String) -> SidebarItem? {
        func search(in items: [SidebarItem]) -> SidebarItem? {
            for item in items {
                if item.url?.path == path || item.title == path {
                    return item
                }
                if let found = search(in: item.children) {
                    return found
                }
            }
            return nil
        }
        return search(in: rootItems)
    }

    /// Finds the parent of a sidebar item
    private func findParent(of targetItem: SidebarItem) -> SidebarItem? {
        func search(in items: [SidebarItem], parent: SidebarItem?) -> SidebarItem? {
            for item in items {
                if item === targetItem {
                    return parent
                }
                if let found = search(in: item.children, parent: item) {
                    return found
                }
            }
            return nil
        }
        return search(in: rootItems, parent: nil)
    }

    /// Moves an item from its current location to a new destination
    private func moveItem(_ sourceItem: SidebarItem, to destination: SidebarItem, at index: Int) -> Bool {
        moveItems([sourceItem], to: destination, at: index)
    }

    /// Moves multiple items from their current locations to a new destination.
    private func moveItems(_ sourceItems: [SidebarItem], to destination: SidebarItem, at index: Int) -> Bool {
        guard !sourceItems.isEmpty else { return false }
        if sourceItems.count == 1 {
            logger.info("moveItem: Moving '\(sourceItems[0].title, privacy: .public)' to '\(destination.title, privacy: .public)'")
        } else {
            logger.info("moveItems: Moving \(sourceItems.count) items to '\(destination.title, privacy: .public)'")
        }

        guard let destFolderURL = destination.url else {
            logger.warning("moveItems: Missing URL for destination")
            return false
        }

        return moveItems(sourceItems, toFolderURL: destFolderURL.standardizedFileURL, at: index)
    }

    private func moveItems(_ sourceItems: [SidebarItem], toFolderURL destFolderURL: URL, at index: Int) -> Bool {
        guard !sourceItems.isEmpty else { return false }

        var movedCount = 0
        for sourceItem in sourceItems {
            guard let sourceURL = sourceItem.url else {
                logger.warning("moveItems: Missing URL for source '\(sourceItem.title, privacy: .public)'")
                continue
            }

            let standardizedSourceURL = sourceURL.standardizedFileURL
            let standardizedDestinationFolderURL = destFolderURL.standardizedFileURL

            if standardizedDestinationFolderURL == standardizedSourceURL ||
                standardizedDestinationFolderURL.path.hasPrefix(standardizedSourceURL.path + "/") {
                logger.warning("moveItems: Cannot move '\(sourceItem.title, privacy: .public)' into itself or a descendant")
                continue
            }

            if standardizedSourceURL.deletingLastPathComponent() == standardizedDestinationFolderURL {
                logger.debug("moveItems: '\(sourceItem.title, privacy: .public)' is already in destination")
                movedCount += 1
                continue
            }

            var destURL = standardizedDestinationFolderURL.appendingPathComponent(sourceURL.lastPathComponent)
            if FileManager.default.fileExists(atPath: destURL.path) {
                destURL = uniqueDestinationURL(for: sourceURL, in: standardizedDestinationFolderURL)
            }

            do {
                try FileManager.default.moveItem(at: sourceURL, to: destURL)
                movedCount += 1
                logger.info("moveItems: File moved from \(sourceURL.path, privacy: .public) to \(destURL.path, privacy: .public)")
            } catch {
                logger.error("moveItems: Failed to move \(sourceURL.lastPathComponent, privacy: .public) - \(error.localizedDescription, privacy: .public)")
            }
        }

        if movedCount > 0 {
            reloadFromFilesystem()
        }
        return movedCount == sourceItems.count
    }

    /// Copies an item to a new destination
    private func copyItem(_ sourceItem: SidebarItem, to destination: SidebarItem, at index: Int) -> Bool {
        copyItems([sourceItem], to: destination, at: index)
    }

    /// Copies multiple items to a new destination.
    private func copyItems(_ sourceItems: [SidebarItem], to destination: SidebarItem, at index: Int) -> Bool {
        guard !sourceItems.isEmpty else { return false }
        if sourceItems.count == 1 {
            logger.info("copyItem: Copying '\(sourceItems[0].title, privacy: .public)' to '\(destination.title, privacy: .public)'")
        } else {
            logger.info("copyItems: Copying \(sourceItems.count) items to '\(destination.title, privacy: .public)'")
        }

        guard let destFolderURL = destination.url else {
            logger.warning("copyItems: Missing URL for destination")
            return false
        }

        return copyItems(sourceItems, toFolderURL: destFolderURL.standardizedFileURL, at: index)
    }

    private func copyItems(_ sourceItems: [SidebarItem], toFolderURL destFolderURL: URL, at index: Int) -> Bool {
        guard !sourceItems.isEmpty else { return false }

        var copiedCount = 0
        for sourceItem in sourceItems {
            guard let sourceURL = sourceItem.url else {
                logger.warning("copyItems: Missing URL for source '\(sourceItem.title, privacy: .public)'")
                continue
            }

            let destURL = uniqueDestinationURL(for: sourceURL, in: destFolderURL.standardizedFileURL, copyStyle: true)

            do {
                try FileManager.default.copyItem(at: sourceURL, to: destURL)
                copiedCount += 1
                logger.info("copyItems: File copied to \(destURL.path, privacy: .public)")
            } catch {
                logger.error("copyItems: Failed to copy \(sourceURL.lastPathComponent, privacy: .public) - \(error.localizedDescription, privacy: .public)")
            }
        }

        if copiedCount > 0 {
            reloadFromFilesystem()
        }
        return copiedCount == sourceItems.count
    }

    private func uniqueDestinationURL(for sourceURL: URL, in destinationFolderURL: URL, copyStyle: Bool = false) -> URL {
        var destURL = destinationFolderURL.appendingPathComponent(sourceURL.lastPathComponent)
        guard FileManager.default.fileExists(atPath: destURL.path) else {
            return destURL
        }

        var counter = copyStyle ? 1 : 2
        let baseName = sourceURL.deletingPathExtension().lastPathComponent
        let fileExtension = sourceURL.pathExtension

        while FileManager.default.fileExists(atPath: destURL.path) {
            let suffix: String
            if copyStyle {
                suffix = counter > 1 ? "_copy_\(counter)" : "_copy"
                counter += 1
            } else {
                suffix = " \(counter)"
                counter += 1
            }
            let newName = fileExtension.isEmpty ? "\(baseName)\(suffix)" : "\(baseName)\(suffix).\(fileExtension)"
            destURL = destinationFolderURL.appendingPathComponent(newName)
        }

        return destURL
    }
}

// MARK: - NSOutlineViewDelegate

extension SidebarViewController: NSOutlineViewDelegate {

    public func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let sidebarItem = item as? SidebarItem else { return nil }

        let hasSubtitle = sidebarItem.subtitle != nil
        let identifier = NSUserInterfaceItemIdentifier(hasSubtitle ? "SidebarCellWithSubtitle" : "SidebarCell")
        var cellView = outlineView.makeView(withIdentifier: identifier, owner: self) as? NSTableCellView

        if cellView == nil {
            cellView = NSTableCellView()
            cellView?.identifier = identifier

            let imageView = NSImageView()
            imageView.translatesAutoresizingMaskIntoConstraints = false
            cellView?.addSubview(imageView)
            cellView?.imageView = imageView

            let textField = NSTextField(labelWithString: "")
            textField.translatesAutoresizingMaskIntoConstraints = false
            textField.lineBreakMode = .byTruncatingTail
            cellView?.addSubview(textField)
            cellView?.textField = textField

            if hasSubtitle {
                let subtitleField = NSTextField(labelWithString: "")
                subtitleField.translatesAutoresizingMaskIntoConstraints = false
                subtitleField.lineBreakMode = .byTruncatingTail
                subtitleField.font = NSFont.systemFont(ofSize: 10)
                subtitleField.textColor = .secondaryLabelColor
                subtitleField.tag = 999
                cellView?.addSubview(subtitleField)

                NSLayoutConstraint.activate([
                    imageView.leadingAnchor.constraint(equalTo: cellView!.leadingAnchor, constant: 2),
                    imageView.centerYAnchor.constraint(equalTo: cellView!.centerYAnchor),
                    imageView.widthAnchor.constraint(equalToConstant: 16),
                    imageView.heightAnchor.constraint(equalToConstant: 16),

                    textField.leadingAnchor.constraint(equalTo: imageView.trailingAnchor, constant: 4),
                    textField.trailingAnchor.constraint(equalTo: cellView!.trailingAnchor, constant: -2),
                    textField.topAnchor.constraint(equalTo: cellView!.topAnchor, constant: 2),

                    subtitleField.leadingAnchor.constraint(equalTo: textField.leadingAnchor),
                    subtitleField.trailingAnchor.constraint(equalTo: textField.trailingAnchor),
                    subtitleField.topAnchor.constraint(equalTo: textField.bottomAnchor, constant: 0),
                    subtitleField.bottomAnchor.constraint(lessThanOrEqualTo: cellView!.bottomAnchor, constant: -2),
                ])
            } else {
                NSLayoutConstraint.activate([
                    imageView.leadingAnchor.constraint(equalTo: cellView!.leadingAnchor, constant: 2),
                    imageView.centerYAnchor.constraint(equalTo: cellView!.centerYAnchor),
                    imageView.widthAnchor.constraint(equalToConstant: 16),
                    imageView.heightAnchor.constraint(equalToConstant: 16),

                    textField.leadingAnchor.constraint(equalTo: imageView.trailingAnchor, constant: 4),
                    textField.trailingAnchor.constraint(equalTo: cellView!.trailingAnchor, constant: -2),
                    textField.centerYAnchor.constraint(equalTo: cellView!.centerYAnchor),
                ])
            }
        }

        // Configure cell
        cellView?.textField?.stringValue = sidebarItem.title

        if let accessibilityIdentifier = sidebarItem.userInfo["accessibilityIdentifier"] {
            cellView?.setAccessibilityIdentifier(accessibilityIdentifier)
            cellView?.textField?.setAccessibilityIdentifier(accessibilityIdentifier)
        }

        // Update subtitle field if present
        if let subtitleField = cellView?.viewWithTag(999) as? NSTextField {
            subtitleField.stringValue = sidebarItem.subtitle ?? ""
        }

        if sidebarItem.type == .group {
            cellView?.textField?.font = NSFont.systemFont(ofSize: 11, weight: .semibold)
            cellView?.textField?.textColor = .secondaryLabelColor
            cellView?.imageView?.image = nil
            cellView?.toolTip = nil
            cellView?.textField?.toolTip = nil
        } else {
            cellView?.textField?.font = NSFont.systemFont(ofSize: 13)
            cellView?.textField?.textColor = .labelColor

            if let customImage = sidebarItem.customImage {
                cellView?.imageView?.image = customImage
                cellView?.imageView?.contentTintColor = nil  // custom image has its own colors
            } else if let iconName = sidebarItem.icon {
                cellView?.imageView?.image = NSImage(systemSymbolName: iconName, accessibilityDescription: sidebarItem.title)
                cellView?.imageView?.contentTintColor = sidebarItem.type.tintColor
            }

            let detail = sidebarItem.url?.path ?? sidebarItem.title
            cellView?.toolTip = detail
            cellView?.textField?.toolTip = detail
        }

        return cellView
    }

    public func outlineView(_ outlineView: NSOutlineView, heightOfRowByItem item: Any) -> CGFloat {
        if let sidebarItem = item as? SidebarItem, sidebarItem.subtitle != nil {
            return 36
        }
        return 24
    }

    public func outlineView(_ outlineView: NSOutlineView, isGroupItem item: Any) -> Bool {
        if let sidebarItem = item as? SidebarItem {
            return sidebarItem.type == .group
        }
        return false
    }

    public func outlineView(_ outlineView: NSOutlineView, shouldSelectItem item: Any) -> Bool {
        if let sidebarItem = item as? SidebarItem {
            return sidebarItem.type != .group
        }
        return true
    }

    public func outlineViewSelectionDidChange(_ notification: Notification) {
        if suppressSelectionCallbacks {
            logger.debug("outlineViewSelectionDidChange: Suppressed during programmatic update")
            return
        }

        // Get ALL selected items for multi-selection support
        let items = selectedItems()
        handleSelectionChange(items, source: "outlineViewSelectionDidChange")
    }

    private func handleSelectionChange(_ items: [SidebarItem], source: String) {

        if items.isEmpty {
            logger.debug("\(source, privacy: .public): Selection cleared")

            // Call delegate directly - synchronous, no Task needed
            selectionDelegate?.sidebarDidSelectItem(nil)

            // Keep notification for other observers (e.g., InspectorViewController)
            NotificationCenter.default.post(
                name: .sidebarSelectionChanged,
                object: self,
                userInfo: sidebarSelectionUserInfo(items: [])
            )
            return
        }

        // Log all selected items
        let itemNames = items.map { $0.title }.joined(separator: ", ")
        logger.info("\(source, privacy: .public): Selected \(items.count) items: [\(itemNames, privacy: .public)]")

        // Call delegate directly - synchronous, reliable
        // This is the primary way to handle selection changes for content display
        if items.count == 1 {
            selectionDelegate?.sidebarDidSelectItem(items.first)
        } else {
            selectionDelegate?.sidebarDidSelectItems(items)
        }

        // Keep notification for other observers (e.g., InspectorViewController)
        // but document loading should NOT be triggered by this notification
        NotificationCenter.default.post(
            name: .sidebarSelectionChanged,
            object: self,
            userInfo: sidebarSelectionUserInfo(items: items)
        )
        logger.debug("\(source, privacy: .public): Called delegate and posted notification with \(items.count) items")
    }

    private func sidebarSelectionUserInfo(items: [SidebarItem]) -> [String: Any] {
        var userInfo: [String: Any] = ["items": items]
        if let first = items.first {
            userInfo["item"] = first
            if let scope = windowStateScope {
                userInfo[NotificationUserInfoKey.contentSelectionIdentity] = ContentSelectionIdentity(
                    url: first.url,
                    kind: first.type.description,
                    resultID: first.title,
                    windowID: scope.id
                )
            }
        }
        if let scope = windowStateScope {
            userInfo[NotificationUserInfoKey.windowStateScope] = scope
        }
        return userInfo
    }
}

// MARK: - Public Selection Accessors

extension SidebarViewController {
    /// Returns the file URLs of all currently selected sidebar items.
    public func selectedFileURLs() -> [URL] {
        var urls: [URL] = []
        for index in outlineView.selectedRowIndexes {
            if let item = outlineView.item(atRow: index) as? SidebarItem,
               let url = item.url {
                urls.append(url)
            }
        }
        return urls
    }
}

// MARK: - SidebarItem Model

/// Represents an item in the sidebar hierarchy
public class SidebarItem: NSObject {
    public var title: String
    public let type: SidebarItemType
    public let icon: String?
    /// Custom pre-rendered image for this item. When set, takes precedence over `icon`.
    public var customImage: NSImage?
    public var children: [SidebarItem]
    public var url: URL?
    /// Optional subtitle for additional context (e.g. read composition label).
    public var subtitle: String?
    /// Arbitrary key-value metadata for routing (e.g. sampleId for batch children).
    public var userInfo: [String: String] = [:]

    public init(title: String, type: SidebarItemType, icon: String? = nil, customImage: NSImage? = nil, children: [SidebarItem] = [], url: URL? = nil, subtitle: String? = nil) {
        self.title = title
        self.type = type
        self.icon = icon
        self.customImage = customImage
        self.children = children
        self.url = url
        self.subtitle = subtitle
        super.init()
    }
}

/// Types of sidebar items
public enum SidebarItemType {
    case group
    case folder
    case sequence
    case annotation
    case alignment
    case coverage
    case project
    case document  // PDFs, text files, etc. - uses QuickLook preview
    case image     // Image files - uses QuickLook preview
    case unknown   // Unknown file type - uses QuickLook preview
    case referenceBundle  // .lungfishref reference genome bundle
    case fastqBundle  // .lungfishfastq FASTQ package bundle
    case primerSchemeBundle  // .lungfishprimers primer-scheme bundle
    case batchGroup   // Virtual node representing a batch operation across multiple bundles
    case classificationResult  // Kraken2 classification result folder
    case esvirituResult        // EsViritu viral detection result folder
    case taxTriageResult       // TaxTriage comprehensive triage result folder
    case naoMgsResult          // NAO-MGS surveillance result bundle
    case nvdResult             // NVD (Novel Virus Diagnostics) result bundle
    case analysisResult        // Analysis result in Analyses/ folder

    var tintColor: NSColor {
        switch self {
        case .group: return .secondaryLabelColor
        case .folder: return .systemBlue
        case .sequence: return .systemGreen
        case .annotation: return .systemOrange
        case .alignment: return .systemPurple
        case .coverage: return .systemTeal
        case .project: return .systemGray
        case .document: return .systemBrown
        case .image: return .systemPink
        case .unknown: return .tertiaryLabelColor
        case .referenceBundle: return .systemIndigo
        case .fastqBundle: return .systemGreen
        case .primerSchemeBundle: return .systemYellow
        case .batchGroup: return .systemCyan
        case .classificationResult: return .lungfishOrange
        case .esvirituResult: return .lungfishOrange
        case .taxTriageResult: return .lungfishOrange
        case .naoMgsResult: return .lungfishOrange
        case .nvdResult: return .lungfishOrange
        case .analysisResult: return .lungfishOrange
        }
    }

    /// Whether this item type should use QuickLook for preview
    var usesQuickLook: Bool {
        switch self {
        case .document, .image, .unknown:
            return true
        default:
            return false
        }
    }

    /// Whether this item type is a bundle that should appear as a single item
    var isBundle: Bool {
        switch self {
        case .referenceBundle, .fastqBundle, .primerSchemeBundle:
            return true
        default:
            return false
        }
    }

    /// Creates a sidebar item type from a LungfishIO UICategory.
    ///
    /// - Parameter category: The UICategory from format detection
    init(from category: UICategory) {
        switch category {
        case .sequence:
            self = .sequence
        case .annotation:
            self = .annotation
        case .alignment:
            self = .alignment
        case .variant:
            self = .annotation  // Variants shown as annotations
        case .coverage:
            self = .coverage
        case .index:
            self = .unknown  // Index files shown as unknown
        case .document:
            self = .document
        case .image:
            self = .image
        case .compressed:
            self = .unknown
        case .referenceBundle:
            self = .referenceBundle
        case .unknown:
            self = .unknown
        }
    }
}

// MARK: - NSMenuDelegate

extension SidebarViewController: NSMenuDelegate {

    public func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        // Get clicked row
        let clickedRow = outlineView.clickedRow

        // If clicked on a row that's not selected, select it first
        if clickedRow >= 0 && !outlineView.selectedRowIndexes.contains(clickedRow) {
            outlineView.selectRowIndexes(IndexSet(integer: clickedRow), byExtendingSelection: false)
        }

        let items = selectedItems()

        // Check if clicked on empty space (no row)
        let clickedOnEmptySpace = clickedRow < 0

        guard !items.isEmpty || clickedOnEmptySpace else {
            // No selection and not on empty space - show minimal menu
            let noSelectionItem = NSMenuItem(title: "No Selection", action: nil, keyEquivalent: "")
            noSelectionItem.isEnabled = false
            menu.addItem(noSelectionItem)
            return
        }

        // If clicked on empty space with a project open, show New Folder option
        if clickedOnEmptySpace && projectURL != nil {
            let newFolderItem = NSMenuItem(title: "New Folder", action: #selector(contextMenuNewFolder(_:)), keyEquivalent: "N")
            newFolderItem.keyEquivalentModifierMask = [.command, .shift]
            newFolderItem.target = self
            menu.addItem(newFolderItem)
            return
        }

        // If no items selected (shouldn't happen at this point, but safety check)
        guard !items.isEmpty else { return }

        // Check what types we have selected
        let hasFiles = items.contains { $0.type != .group && $0.type != .project && $0.type != .folder && $0.type != .referenceBundle && $0.type != .fastqBundle && $0.type != .batchGroup }
        let hasFolders = items.contains { $0.type == .folder || $0.type == .project }
        let hasGroups = items.contains { $0.type == .group }
        let hasDeletable = items.contains { item in
            if item.type == .group || item.type == .project { return false }
            if item.type == .batchGroup { return item.url != nil }
            return true
        }
        let hasBundles = items.contains { $0.type == .referenceBundle }
        let hasFASTQBundles = items.contains { $0.type == .fastqBundle }
        let mergeSelectionKind = BundleMergeSelection.detectKind(for: items)

        // Reference bundle(s) selected — export sequences
        if hasBundles {
            let bundleCount = items.filter { $0.type == .referenceBundle }.count
            let exportTitle = bundleCount > 1
                ? "Export \(bundleCount) Sequences\u{2026}"
                : "Export Sequences\u{2026}"
            let exportSeqItem = NSMenuItem(title: exportTitle, action: #selector(FileMenuActions.exportFASTA(_:)), keyEquivalent: "")
            menu.addItem(exportSeqItem)

            if mergeSelectionKind == .reference {
                let mergeItem = NSMenuItem(
                    title: "Merge into New Bundle\u{2026}",
                    action: #selector(contextMenuMergeIntoNewBundle(_:)),
                    keyEquivalent: ""
                )
                mergeItem.target = self
                menu.addItem(mergeItem)
            }

            menu.addItem(NSMenuItem.separator())
        }

        // Single bundle selected - show bundle-specific options
        if items.count == 1 && hasBundles {
            let openItem = NSMenuItem(title: "Open Bundle", action: #selector(contextMenuOpen(_:)), keyEquivalent: "")
            openItem.target = self
            menu.addItem(openItem)

            let showContentsItem = NSMenuItem(title: "Show Package Contents", action: #selector(contextMenuShowBundleContents(_:)), keyEquivalent: "")
            showContentsItem.target = self
            menu.addItem(showContentsItem)

            let getInfoItem = NSMenuItem(title: "Get Bundle Info", action: #selector(contextMenuGetBundleInfo(_:)), keyEquivalent: "")
            getInfoItem.target = self
            menu.addItem(getInfoItem)

            let importMetadataItem = NSMenuItem(title: "Import Sample Metadata…", action: #selector(contextMenuImportSampleMetadata(_:)), keyEquivalent: "")
            importMetadataItem.target = self
            menu.addItem(importMetadataItem)

            // Delete Variant Tracks — only if bundle has variant tracks
            if let url = items.first?.url, bundleHasVariantTracks(url) {
                menu.addItem(NSMenuItem.separator())
                let deleteVariantsItem = NSMenuItem(title: "Delete Variant Tracks\u{2026}", action: #selector(contextMenuDeleteVariantTracks(_:)), keyEquivalent: "")
                deleteVariantsItem.target = self
                menu.addItem(deleteVariantsItem)
            }

            // Reassemble — only if bundle has assembly provenance
            if let url = items.first?.url, bundleHasAssemblyProvenance(url) {
                let reassembleItem = NSMenuItem(title: "Reassemble\u{2026}", action: #selector(contextMenuReassemble(_:)), keyEquivalent: "")
                reassembleItem.target = self
                menu.addItem(reassembleItem)
            }

            menu.addItem(NSMenuItem.separator())
        }

        // FASTQ bundle(s) selected - show FASTQ-specific options
        if hasFASTQBundles {
            if items.count == 1 {
                let openItem = NSMenuItem(title: "Open Bundle", action: #selector(contextMenuOpen(_:)), keyEquivalent: "")
                openItem.target = self
                menu.addItem(openItem)
            }

            let fastqCount = items.filter { $0.type == .fastqBundle }.count
            let exportTitle = fastqCount > 1
                ? "Export \(fastqCount) as FASTQ\u{2026}"
                : "Export as FASTQ\u{2026}"
            let exportItem = NSMenuItem(title: exportTitle, action: #selector(contextMenuExportFASTQ(_:)), keyEquivalent: "")
            exportItem.target = self
            menu.addItem(exportItem)

            if mergeSelectionKind == .fastq {
                let mergeItem = NSMenuItem(
                    title: "Merge into New Bundle\u{2026}",
                    action: #selector(contextMenuMergeIntoNewBundle(_:)),
                    keyEquivalent: ""
                )
                mergeItem.target = self
                menu.addItem(mergeItem)
            }

            if items.count == 1 {
                let showContentsItem = NSMenuItem(title: "Show Package Contents", action: #selector(contextMenuShowBundleContents(_:)), keyEquivalent: "")
                showContentsItem.target = self
                menu.addItem(showContentsItem)
            }

            // Clone Metadata From... — available for FASTQ bundles
            let cloneItem = NSMenuItem(title: "Clone Metadata From\u{2026}", action: #selector(contextMenuCloneMetadata(_:)), keyEquivalent: "")
            cloneItem.target = self
            menu.addItem(cloneItem)

            menu.addItem(NSMenuItem.separator())
        }

        // Classification result selected - show Copy Classification Command
        if items.count == 1, let item = items.first, item.type == .classificationResult {
            let copyCommandItem = NSMenuItem(
                title: "Copy Classification Command",
                action: #selector(contextMenuCopyClassificationCommand(_:)),
                keyEquivalent: ""
            )
            copyCommandItem.target = self
            menu.addItem(copyCommandItem)
            menu.addItem(NSMenuItem.separator())
        }

        // Single item selected - show Open
        if items.count == 1 && hasFiles {
            let openItem = NSMenuItem(title: "Open", action: #selector(contextMenuOpen(_:)), keyEquivalent: "")
            openItem.target = self
            menu.addItem(openItem)
            menu.addItem(NSMenuItem.separator())
        }

        // New Folder (when folder or project is selected, or when we have a project open)
        if (items.count == 1 && hasFolders) || projectURL != nil {
            let newFolderItem = NSMenuItem(title: "New Folder", action: #selector(contextMenuNewFolder(_:)), keyEquivalent: "N")
            newFolderItem.keyEquivalentModifierMask = [.command, .shift]
            newFolderItem.target = self
            menu.addItem(newFolderItem)
            menu.addItem(NSMenuItem.separator())
        }

        // Edit / Export / Import Sample Metadata (for folders containing FASTQ bundles)
        if items.count == 1 && hasFolders, let folderItem = items.first, let folderURL = folderItem.url {
            let hasFASTQChildren = folderItem.children.contains { $0.type == .fastqBundle }
            if hasFASTQChildren {
                let editMetaItem = NSMenuItem(
                    title: "Edit Sample Metadata\u{2026}",
                    action: #selector(contextMenuEditFolderMetadata(_:)),
                    keyEquivalent: ""
                )
                editMetaItem.target = self
                menu.addItem(editMetaItem)

                let exportMetaItem = NSMenuItem(
                    title: "Export Sample Metadata (CSV)\u{2026}",
                    action: #selector(contextMenuExportProjectMetadata(_:)),
                    keyEquivalent: ""
                )
                exportMetaItem.target = self
                menu.addItem(exportMetaItem)

                let importMetaItem = NSMenuItem(
                    title: "Import Sample Metadata (CSV)\u{2026}",
                    action: #selector(contextMenuImportProjectMetadata(_:)),
                    keyEquivalent: ""
                )
                importMetaItem.target = self
                menu.addItem(importMetaItem)

                menu.addItem(NSMenuItem.separator())
            }
        }

        // Show in Finder
        if !hasGroups {
            let showInFinderItem = NSMenuItem(title: "Show in Finder", action: #selector(contextMenuShowInFinder(_:)), keyEquivalent: "")
            showInFinderItem.target = self
            menu.addItem(showInFinderItem)
        }

        // Copy Path
        if !hasGroups && items.count == 1 {
            let copyPathItem = NSMenuItem(title: "Copy Path", action: #selector(contextMenuCopyPath(_:)), keyEquivalent: "")
            copyPathItem.target = self
            menu.addItem(copyPathItem)
        }

        // Show in Inspector (for reference bundles)
        if items.count == 1 && hasBundles {
            let showInInspectorItem = NSMenuItem(title: "Show in Inspector", action: #selector(contextMenuShowInInspector(_:)), keyEquivalent: "")
            showInInspectorItem.target = self
            menu.addItem(showInInspectorItem)
        }

        menu.addItem(NSMenuItem.separator())

        // Rename (single item only, not groups)
        if items.count == 1 && !hasGroups {
            let renameItem = NSMenuItem(title: "Rename...", action: #selector(contextMenuRename(_:)), keyEquivalent: "")
            renameItem.target = self
            menu.addItem(renameItem)
        }

        // Duplicate (files and folders, not groups)
        if !hasGroups && (hasFiles || hasFolders) {
            let duplicateItem = NSMenuItem(title: "Duplicate", action: #selector(contextMenuDuplicate(_:)), keyEquivalent: "D")
            duplicateItem.keyEquivalentModifierMask = .command
            duplicateItem.target = self
            menu.addItem(duplicateItem)
        }

        // Move to... submenu (for files and non-project folders)
        if !hasGroups && projectURL != nil {
            let moveToItem = NSMenuItem(title: "Move to", action: nil, keyEquivalent: "")
            let moveToSubmenu = buildMoveToSubmenu(for: items)
            if moveToSubmenu.items.count > 0 {
                moveToItem.submenu = moveToSubmenu
                menu.addItem(moveToItem)
            }
        }

        // Move to Trash
        if hasDeletable {
            menu.addItem(NSMenuItem.separator())
            let deleteTitle = items.count == 1 ? "Move to Trash" : "Move \(items.count) Items to Trash"
            let deleteItem = NSMenuItem(title: deleteTitle, action: #selector(deleteSelectedItems), keyEquivalent: "\u{8}")  // Backspace key
            deleteItem.target = self
            menu.addItem(deleteItem)
        }
    }

    @objc private func contextMenuOpen(_ sender: Any?) {
        let items = selectedItems()
        guard let item = items.first, item.type != .group && item.type != .project && item.type != .batchGroup else { return }

        logger.info("contextMenuOpen: Opening '\(item.title, privacy: .public)'")

        selectionDelegate?.sidebarDidSelectItem(item)

        // Keep notification for other observers; display routes through the delegate.
        NotificationCenter.default.post(
            name: .sidebarSelectionChanged,
            object: self,
            userInfo: sidebarSelectionUserInfo(items: [item])
        )
    }

    @objc private func contextMenuMergeIntoNewBundle(_ sender: Any?) {
        let items = selectedItems()
        guard let mergeKind = BundleMergeSelection.detectKind(for: items) else { return }

        let selectedURLs = items.compactMap(\.url)
        guard selectedURLs.count == items.count,
              let destinationDirectory = Self.deepestCommonParent(for: selectedURLs) else { return }

        let alert = NSAlert()
        alert.messageText = "Merge into New Bundle"
        alert.informativeText = "Enter a name for the merged bundle:"
        alert.addButton(withTitle: "Merge")
        alert.addButton(withTitle: "Cancel")

        let textField = NSTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24))
        textField.stringValue = Self.suggestedMergedBundleName(for: items)
        alert.accessoryView = textField

        guard let window = view.window ?? NSApp.keyWindow else { return }
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }

            let bundleName = textField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !bundleName.isEmpty else { return }

            Task { @MainActor [weak self] in
                guard let self else { return }

                do {
                    let mergedURL: URL
                    switch mergeKind {
                    case .fastq:
                        mergedURL = try await FASTQBundleMergeService.merge(
                            sourceBundleURLs: selectedURLs,
                            outputDirectory: destinationDirectory,
                            bundleName: bundleName
                        )
                    case .reference:
                        mergedURL = try await ReferenceBundleMergeService.merge(
                            sourceBundleURLs: selectedURLs,
                            outputDirectory: destinationDirectory,
                            bundleName: bundleName
                        )
                    }

                    self.reloadFromFilesystem()
                    _ = self.selectItem(forURL: mergedURL)
                } catch {
                    self.presentError(error)
                }
            }
        }
    }

    /// Shows the internal contents of a bundle in Finder (like "Show Package Contents" in macOS).
    @objc private func contextMenuShowBundleContents(_ sender: Any?) {
        let items = selectedItems()
        guard let item = items.first, (item.type == .referenceBundle || item.type == .fastqBundle), let url = item.url else { return }

        logger.info("contextMenuShowBundleContents: Showing contents of '\(item.title, privacy: .public)'")

        // Open the bundle directory in Finder to show its internal structure
        NSWorkspace.shared.open(url)
    }

    /// Shows bundle metadata info in an alert dialog.
    @objc private func contextMenuGetBundleInfo(_ sender: Any?) {
        let items = selectedItems()
        guard let item = items.first, item.type == .referenceBundle, let url = item.url else { return }

        logger.info("contextMenuGetBundleInfo: Getting info for '\(item.title, privacy: .public)'")

        // Try to load the bundle manifest
        let manifestURL = url.appendingPathComponent("manifest.json")

        Task { @MainActor in
            var infoText = "Bundle: \(item.title)\n"
            infoText += "Location: \(url.path)\n\n"

            if FileManager.default.fileExists(atPath: manifestURL.path) {
                do {
                    let data = try Data(contentsOf: manifestURL)
                    if let manifest = try JSONSerialization.jsonObject(with: data) as? [String: Any] {
                        // Extract key info from manifest
                        if let name = manifest["name"] as? String {
                            infoText += "Name: \(name)\n"
                        }
                        if let identifier = manifest["identifier"] as? String {
                            infoText += "Identifier: \(identifier)\n"
                        }
                        if let description = manifest["description"] as? String {
                            infoText += "Description: \(description)\n"
                        }
                        if let formatVersion = manifest["formatVersion"] as? String {
                            infoText += "Format Version: \(formatVersion)\n"
                        }

                        // Source info
                        if let source = manifest["source"] as? [String: Any] {
                            infoText += "\nSource:\n"
                            if let organism = source["organism"] as? String {
                                infoText += "  Organism: \(organism)\n"
                            }
                            if let assembly = source["assembly"] as? String {
                                infoText += "  Assembly: \(assembly)\n"
                            }
                        }

                        // Genome info
                        if let genome = manifest["genome"] as? [String: Any] {
                            infoText += "\nGenome:\n"
                            if let totalLength = genome["totalLength"] as? Int {
                                infoText += "  Total Length: \(totalLength.formatted()) bp\n"
                            }
                            if let chromosomes = genome["chromosomes"] as? [[String: Any]] {
                                infoText += "  Chromosomes: \(chromosomes.count)\n"
                            }
                        }

                        // Track counts
                        if let annotations = manifest["annotations"] as? [[String: Any]] {
                            infoText += "\nAnnotation Tracks: \(annotations.count)\n"
                        }
                        if let variants = manifest["variants"] as? [[String: Any]] {
                            infoText += "Variant Tracks: \(variants.count)\n"
                        }
                        if let tracks = manifest["tracks"] as? [[String: Any]] {
                            infoText += "Signal Tracks: \(tracks.count)\n"
                        }
                    }
                } catch {
                    infoText += "Error reading manifest: \(error.localizedDescription)\n"
                    logger.error("contextMenuGetBundleInfo: Failed to read manifest - \(error.localizedDescription, privacy: .public)")
                }
            } else {
                infoText += "No manifest.json found in bundle.\n"
            }

            // Show info alert
            let alert = NSAlert()
            alert.messageText = "Bundle Info"
            alert.informativeText = infoText
            alert.alertStyle = .informational
            alert.addButton(withTitle: "OK")

            if let window = self.view.window ?? NSApp.keyWindow {
                alert.beginSheetModal(for: window)
            }

        }
    }

    @objc private func contextMenuImportSampleMetadata(_ sender: Any?) {
        let items = selectedItems()
        guard let item = items.first,
              (item.type == .referenceBundle || item.type == .fastqBundle),
              let bundleURL = item.url else { return }

        logger.info("contextMenuImportSampleMetadata: Importing metadata into '\(item.title, privacy: .public)'")
        guard let appDelegate = NSApp.delegate as? AppDelegate else { return }
        appDelegate.presentMetadataImportPanel(for: bundleURL, presentingWindow: view.window)
    }

    @objc private func contextMenuEditFolderMetadata(_ sender: Any?) {
        let items = selectedItems()
        guard let item = items.first,
              (item.type == .folder || item.type == .project),
              let folderURL = item.url else { return }

        logger.info("contextMenuEditFolderMetadata: Opening metadata editor for '\(item.title, privacy: .public)'")

        let editorSheet = FolderMetadataEditorSheet(folderURL: folderURL)
        guard let window = view.window else { return }

        window.contentViewController?.presentAsSheet(editorSheet)
    }

    @objc private func contextMenuExportProjectMetadata(_ sender: Any?) {
        let items = selectedItems()
        guard let item = items.first,
              (item.type == .folder || item.type == .project),
              let folderURL = item.url else { return }

        logger.info("contextMenuExportProjectMetadata: Exporting metadata from '\(item.title, privacy: .public)'")

        let sheet = MetadataExportSheet(folderURL: folderURL)
        guard let window = view.window else { return }
        window.contentViewController?.presentAsSheet(sheet)
    }

    @objc private func contextMenuImportProjectMetadata(_ sender: Any?) {
        let items = selectedItems()
        guard let item = items.first,
              (item.type == .folder || item.type == .project),
              let folderURL = item.url else { return }

        logger.info("contextMenuImportProjectMetadata: Importing metadata into '\(item.title, privacy: .public)'")

        let sheet = MetadataImportSheet(folderURL: folderURL)
        guard let window = view.window else { return }
        window.contentViewController?.presentAsSheet(sheet)
    }

    /// Checks if a bundle URL has variant tracks by reading its manifest.
    private func bundleHasVariantTracks(_ bundleURL: URL) -> Bool {
        let manifestURL = bundleURL.appendingPathComponent("manifest.json")
        guard FileManager.default.fileExists(atPath: manifestURL.path) else { return false }
        guard let data = try? Data(contentsOf: manifestURL),
              let manifest = try? JSONDecoder().decode(BundleManifest.self, from: data) else { return false }
        return !manifest.variants.isEmpty
    }

    @objc private func contextMenuDeleteVariantTracks(_ sender: Any?) {
        let items = selectedItems()
        guard let item = items.first, item.type == .referenceBundle, let bundleURL = item.url else { return }

        let manifestURL = bundleURL.appendingPathComponent("manifest.json")
        guard let data = try? Data(contentsOf: manifestURL),
              let manifest = try? JSONDecoder().decode(BundleManifest.self, from: data),
              !manifest.variants.isEmpty else { return }

        let tracks = manifest.variants
        let trackNames = tracks.map(\.name).joined(separator: ", ")
        let alert = NSAlert()
        alert.messageText = "Delete Variant Tracks?"
        alert.informativeText = "This will permanently delete \(tracks.count) variant track\(tracks.count == 1 ? "" : "s") (\(trackNames)) and their database files from the bundle. This cannot be undone."
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        alert.alertStyle = .critical

        guard let window = self.view.window else { return }
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            self?.performDeleteVariantTracks(bundleURL: bundleURL, manifest: manifest)
        }
    }

    private func performDeleteVariantTracks(bundleURL: URL, manifest: BundleManifest) {
        let tracks = manifest.variants
        guard !tracks.isEmpty else { return }

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let fm = FileManager.default
            var deletedFiles: [String] = []
            var errors: [String] = []
            var warnings: [String] = []

            func removeFile(_ url: URL, label: String, critical: Bool) {
                guard fm.fileExists(atPath: url.path) else { return }
                do {
                    try fm.removeItem(at: url)
                    deletedFiles.append(label)
                } catch {
                    let msg = "Failed to delete \(label): \(error.localizedDescription)"
                    if critical {
                        errors.append(msg)
                    } else {
                        warnings.append(msg)
                    }
                }
            }

            for track in tracks {
                // Delete BCF file
                let bcfURL = bundleURL.appendingPathComponent(track.path)
                removeFile(bcfURL, label: track.path, critical: true)

                // Delete CSI index file
                let csiURL = bundleURL.appendingPathComponent(track.indexPath)
                removeFile(csiURL, label: track.indexPath, critical: true)

                // Delete SQLite variant database
                if let dbPath = track.databasePath {
                    let dbURL = bundleURL.appendingPathComponent(dbPath)
                    removeFile(dbURL, label: dbPath, critical: true)
                    // WAL/SHM are transient journal files — warn but don't block
                    let walURL = dbURL.appendingPathExtension("wal")
                    let shmURL = dbURL.appendingPathExtension("shm")
                    removeFile(walURL, label: "\(dbPath).wal", critical: false)
                    removeFile(shmURL, label: "\(dbPath).shm", critical: false)
                }
            }

            // Update manifest to remove variant tracks
            let updatedManifest = BundleManifest(
                formatVersion: manifest.formatVersion,
                name: manifest.name,
                identifier: manifest.identifier,
                description: manifest.description,
                createdDate: manifest.createdDate,
                modifiedDate: Date(),
                source: manifest.source,
                genome: manifest.genome,
                annotations: manifest.annotations,
                variants: [],
                tracks: manifest.tracks,
                metadata: manifest.metadata
            )

            let manifestURL = bundleURL.appendingPathComponent("manifest.json")
            do {
                let jsonData = try JSONEncoder().encode(updatedManifest)
                try jsonData.write(to: manifestURL, options: .atomic)
            } catch {
                errors.append("Failed to write manifest.json: \(error.localizedDescription)")
            }

            let finalDeletedCount = deletedFiles.count
            let finalErrors = errors
            let finalWarnings = warnings
            DispatchQueue.main.async {
                guard let self else { return }
                MainActor.assumeIsolated {
                    for w in finalWarnings {
                        logger.warning("performDeleteVariantTracks: \(w, privacy: .public)")
                    }

                    if finalErrors.isEmpty {
                        logger.info("performDeleteVariantTracks: Deleted \(finalDeletedCount) files from bundle")
                        NotificationCenter.default.post(
                            name: .bundleVariantTracksDeleted,
                            object: nil,
                            userInfo: [NotificationUserInfoKey.bundleURL: bundleURL]
                        )
                    }

                    if !finalErrors.isEmpty {
                        logger.error("performDeleteVariantTracks: Completed with \(finalErrors.count) error(s)")
                        let alert = NSAlert()
                        alert.messageText = "Variant Track Deletion Completed with Errors"
                        alert.informativeText = finalErrors.joined(separator: "\n")
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

    private func bundleHasAssemblyProvenance(_ bundleURL: URL) -> Bool {
        let provenanceURL = bundleURL.appendingPathComponent("assembly/provenance.json")
        return FileManager.default.fileExists(atPath: provenanceURL.path)
    }

    @objc private func contextMenuReassemble(_ sender: Any?) {
        let items = selectedItems()
        guard let item = items.first, item.type == .referenceBundle, let bundleURL = item.url else { return }

        let assemblyDir = bundleURL.appendingPathComponent("assembly")
        guard let provenance = try? AssemblyProvenance.load(from: assemblyDir) else {
            logger.error("contextMenuReassemble: Failed to load provenance from \(bundleURL.lastPathComponent)")
            return
        }

        // Try to locate original input files from provenance
        let inputFiles = provenance.inputs.compactMap { record -> URL? in
            if let originalPath = record.originalPath {
                let originalURL = URL(fileURLWithPath: originalPath)
                if FileManager.default.fileExists(atPath: originalURL.path) {
                    return originalURL
                }
            }

            // Look for files relative to current project
            if let projectURL = self.projectURL {
                let candidates = [
                    projectURL.appendingPathComponent(record.filename),
                    projectURL.appendingPathComponent("FASTQ").appendingPathComponent(record.filename),
                    projectURL.appendingPathComponent("Reads").appendingPathComponent(record.filename),
                ]
                return candidates.first { FileManager.default.fileExists(atPath: $0.path) }
            }
            return nil
        }

        guard let window = self.view.window else { return }
        let outputDir = bundleURL.deletingLastPathComponent()
        let initialTool = AssemblyTool(
            rawValue: provenance.assembler.lowercased()
                .replacingOccurrences(of: " ", with: "")
        ) ?? .spades

        AssemblySheetPresenter.present(
            from: window,
            inputFiles: inputFiles,
            outputDirectory: outputDir,
            initialTool: initialTool,
            onCancel: nil
        )
    }

    @objc private func contextMenuShowInFinder(_ sender: Any?) {
        let items = selectedItems()
        let urls = items.compactMap { $0.url }

        guard !urls.isEmpty else { return }

        logger.info("contextMenuShowInFinder: Revealing \(urls.count) items in Finder")
        NSWorkspace.shared.activateFileViewerSelecting(urls)
    }

    @objc private func contextMenuCopyPath(_ sender: Any?) {
        let items = selectedItems()
        guard let item = items.first, let url = item.url else { return }

        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(url.path, forType: .string)

        logger.info("contextMenuCopyPath: Copied path '\(url.path, privacy: .public)'")
    }

    /// Copies the classification command(s) to the system clipboard.
    ///
    /// Loads provenance or config from the classification result directory
    /// and builds a shell-ready command string for kraken2 (and bracken,
    /// if profiling was performed).
    @objc private func contextMenuCopyClassificationCommand(_ sender: Any?) {
        let items = selectedItems()
        guard let item = items.first,
              item.type == .classificationResult,
              let url = item.url else { return }

        guard let command = ClassificationResult.copyableCommandString(from: url) else {
            logger.warning("contextMenuCopyClassificationCommand: Failed to build command for '\(item.title, privacy: .public)'")
            return
        }

        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(command, forType: .string)

        logger.info("contextMenuCopyClassificationCommand: Copied command for '\(item.title, privacy: .public)'")
    }

    /// Posts a notification to show the selected bundle in the inspector.
    @objc private func contextMenuShowInInspector(_ sender: Any?) {
        let items = selectedItems()
        guard let item = items.first else { return }

        logger.info("contextMenuShowInInspector: Showing '\(item.title, privacy: .public)' in inspector")

        // Post notification to show inspector with Document tab
        var userInfo: [AnyHashable: Any] = [NotificationUserInfoKey.inspectorTab: "document"]
        if let windowStateScope {
            userInfo[NotificationUserInfoKey.windowStateScope] = windowStateScope
        }
        NotificationCenter.default.post(
            name: .showInspectorRequested,
            object: self,
            userInfo: userInfo
        )
    }

    @objc private func contextMenuNewFolder(_ sender: Any?) {
        // Determine where to create the folder
        let parentURL: URL
        let clickedRow = outlineView.clickedRow

        // If clicked on empty space (row == -1), always create at project root
        if clickedRow < 0 {
            if let project = projectURL {
                parentURL = project
                logger.info("contextMenuNewFolder: Clicked on empty space, creating at project root")
            } else {
                logger.warning("contextMenuNewFolder: No project open")
                return
            }
        } else {
            // Clicked on a specific item - check if it's a folder/project
            let items = selectedItems()
            if let item = items.first, (item.type == .folder || item.type == .project), let url = item.url {
                // Create inside the selected folder/project
                parentURL = url
            } else if let project = projectURL {
                // Selected item is a file - create at project root
                parentURL = project
            } else {
                logger.warning("contextMenuNewFolder: No valid location to create folder")
                return
            }
        }

        logger.info("contextMenuNewFolder: Creating new folder in '\(parentURL.lastPathComponent, privacy: .public)'")

        // Show dialog for folder name
        let alert = NSAlert()
        alert.messageText = "New Folder"
        alert.informativeText = "Enter a name for the new folder:"
        alert.addButton(withTitle: "Create")
        alert.addButton(withTitle: "Cancel")

        let textField = NSTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 24))
        textField.stringValue = "untitled folder"
        textField.selectText(nil)
        alert.accessoryView = textField

        guard let window = view.window else { return }

        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }

            let folderName = textField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !folderName.isEmpty else { return }

            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated {
                    self?.createFolder(named: folderName, in: parentURL)
                }
            }
        }
    }

    private func createFolder(named name: String, in parentURL: URL) {
        var folderURL = parentURL.appendingPathComponent(name, isDirectory: true)

        // Handle duplicate names
        var counter = 1
        while FileManager.default.fileExists(atPath: folderURL.path) {
            counter += 1
            folderURL = parentURL.appendingPathComponent("\(name) \(counter)", isDirectory: true)
        }

        do {
            try FileManager.default.createDirectory(at: folderURL, withIntermediateDirectories: true)
            logger.info("createFolder: Created '\(folderURL.lastPathComponent, privacy: .public)'")
            // Immediately refresh sidebar for instant feedback
            reloadFromFilesystem()
        } catch {
            logger.error("createFolder: Failed - \(error.localizedDescription, privacy: .public)")

            let alert = NSAlert()
            alert.messageText = "Create Folder Failed"
            alert.informativeText = error.localizedDescription
            alert.alertStyle = .warning
            alert.addButton(withTitle: "OK")
            if let window = view.window {
                alert.beginSheetModal(for: window)
            }
        }
    }

    @objc private func contextMenuRename(_ sender: Any?) {
        let items = selectedItems()
        guard let item = items.first else { return }

        logger.info("contextMenuRename: Renaming '\(item.title, privacy: .public)'")

        // Show rename dialog
        let alert = NSAlert()
        alert.messageText = "Rename"
        alert.informativeText = "Enter a new name:"
        alert.addButton(withTitle: "Rename")
        alert.addButton(withTitle: "Cancel")

        let textField = NSTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 24))
        textField.stringValue = item.url?.deletingPathExtension().lastPathComponent ?? item.title
        alert.accessoryView = textField

        guard let window = view.window else { return }

        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }

            let newName = textField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !newName.isEmpty else { return }

            self?.performRename(item: item, newName: newName)
        }
    }

    private func performRename(item: SidebarItem, newName: String) {
        guard let url = item.url else {
            // Item has no URL, just update the title (legacy behavior)
            item.title = newName
            reloadOutlineView()
            return
        }

        // Construct new URL with same extension
        let fileExtension = url.pathExtension
        let newFilename = fileExtension.isEmpty ? newName : "\(newName).\(fileExtension)"
        let newURL = url.deletingLastPathComponent().appendingPathComponent(newFilename)

        do {
            try FileManager.default.moveItem(at: url, to: newURL)
            logger.info("performRename: Renamed to '\(newFilename, privacy: .public)'")
            // Immediately refresh sidebar for instant feedback
            reloadFromFilesystem()
        } catch {
            logger.error("performRename: Failed - \(error.localizedDescription, privacy: .public)")

            let alert = NSAlert()
            alert.messageText = "Rename Failed"
            alert.informativeText = error.localizedDescription
            alert.alertStyle = .warning
            alert.addButton(withTitle: "OK")
            if let window = view.window {
                alert.beginSheetModal(for: window)
            }
        }
    }

    @objc private func contextMenuDuplicate(_ sender: Any?) {
        let items = selectedItems()
        logger.info("contextMenuDuplicate: Duplicating \(items.count) items")

        for item in items {
            guard let url = item.url else { continue }

            // Generate unique name
            let baseName = url.deletingPathExtension().lastPathComponent
            let ext = url.pathExtension
            var counter = 1
            var newURL = url.deletingLastPathComponent().appendingPathComponent("\(baseName) copy.\(ext)")

            while FileManager.default.fileExists(atPath: newURL.path) {
                counter += 1
                newURL = url.deletingLastPathComponent().appendingPathComponent("\(baseName) copy \(counter).\(ext)")
            }

            do {
                try FileManager.default.copyItem(at: url, to: newURL)
                logger.info("contextMenuDuplicate: Created '\(newURL.lastPathComponent, privacy: .public)'")
            } catch {
                logger.error("contextMenuDuplicate: Failed - \(error.localizedDescription, privacy: .public)")
            }
        }
        // Immediately refresh sidebar for instant feedback
        reloadFromFilesystem()
    }
    // MARK: - FASTQ Export

    /// Exports a FASTQ bundle to a standalone FASTQ file via NSSavePanel.
    @objc private func contextMenuExportFASTQ(_ sender: Any?) {
        // Delegate to the AppDelegate's exportFASTQ which handles single and multi-selection
        NSApp.sendAction(#selector(FileMenuActions.exportFASTQ(_:)), to: nil, from: sender)
    }

    // MARK: - Clone Metadata

    @objc private func contextMenuCloneMetadata(_ sender: Any?) {
        let targetItems = selectedItems().filter { $0.type == .fastqBundle }
        guard !targetItems.isEmpty else { return }

        // Find all FASTQ bundles in the same parent folder as potential sources
        guard let parentURL = targetItems.first?.url?.deletingLastPathComponent() else { return }
        let targetURLs = Set(targetItems.compactMap { $0.url })

        let fm = FileManager.default
        let allBundles: [URL]
        do {
            allBundles = try fm.contentsOfDirectory(at: parentURL, includingPropertiesForKeys: nil)
                .filter { $0.pathExtension == "lungfishfastq" && !targetURLs.contains($0) }
                .sorted { $0.lastPathComponent < $1.lastPathComponent }
        } catch {
            return
        }

        guard !allBundles.isEmpty else { return }

        // Build a picker menu as an alert with a popup button
        let alert = NSAlert()
        alert.messageText = "Clone Metadata From"
        alert.informativeText = "Select a sample to copy metadata from. All fields except sample name will be copied."
        alert.addButton(withTitle: "Clone")
        alert.addButton(withTitle: "Cancel")

        let popUp = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 300, height: 24), pullsDown: false)
        for bundle in allBundles {
            let name = bundle.deletingPathExtension().lastPathComponent
            popUp.addItem(withTitle: name)
            popUp.lastItem?.representedObject = bundle
        }
        alert.accessoryView = popUp

        guard let window = view.window else { return }
        alert.beginSheetModal(for: window) { [weak self] response in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard response == .alertFirstButtonReturn,
                          let sourceURL = popUp.selectedItem?.representedObject as? URL else {
                        return
                    }

                    // Load source metadata
                    let sourceName = sourceURL.deletingPathExtension().lastPathComponent
                    let sourceCSV = FASTQBundleCSVMetadata.load(from: sourceURL)
                    let sourceMeta: FASTQSampleMetadata
                    if let csv = sourceCSV {
                        sourceMeta = FASTQSampleMetadata(from: csv, fallbackName: sourceName)
                    } else {
                        sourceMeta = FASTQSampleMetadata(sampleName: sourceName)
                    }

                    // Apply to each target bundle
                    for targetURL in targetURLs {
                        let targetName = targetURL.deletingPathExtension().lastPathComponent
                        let cloned = sourceMeta.cloned(withName: targetName)
                        let legacyCSV = cloned.toLegacyCSV()
                        try? FASTQBundleCSVMetadata.save(legacyCSV, to: targetURL)
                    }

                    // Post notification to refresh the inspector if needed
                    NotificationCenter.default.post(
                        name: .sampleMetadataDidChange,
                        object: self,
                        userInfo: nil
                    )
                }
            }
        }
    }

    // MARK: - Move To Submenu

    /// Builds a submenu with available folder destinations for moving items
    private func buildMoveToSubmenu(for items: [SidebarItem]) -> NSMenu {
        let submenu = NSMenu()

        guard let projectURL = projectURL else { return submenu }

        // Get URLs of items being moved (to exclude them from destinations)
        let movingURLs = Set(items.compactMap { $0.url?.standardizedFileURL })

        // Add project root as a destination
        let projectRootItem = NSMenuItem(title: projectURL.lastPathComponent + " (Root)", action: #selector(contextMenuMoveToFolder(_:)), keyEquivalent: "")
        projectRootItem.target = self
        projectRootItem.representedObject = projectURL
        submenu.addItem(projectRootItem)

        submenu.addItem(NSMenuItem.separator())

        // Recursively find all folders in the project
        let folders = findAllFolders(in: projectURL, excludingURLs: movingURLs)

        for folder in folders {
            // Create relative path for display
            let relativePath = folder.path.replacingOccurrences(of: projectURL.path + "/", with: "")
            let menuItem = NSMenuItem(title: relativePath, action: #selector(contextMenuMoveToFolder(_:)), keyEquivalent: "")
            menuItem.target = self
            menuItem.representedObject = folder
            submenu.addItem(menuItem)
        }

        return submenu
    }

    /// Finds all folders recursively in a directory
    private func findAllFolders(in directory: URL, excludingURLs: Set<URL>) -> [URL] {
        var folders: [URL] = []
        let fileManager = FileManager.default

        guard let enumerator = fileManager.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey, .isHiddenKey],
            options: [.skipsHiddenFiles]
        ) else {
            return folders
        }

        for case let url as URL in enumerator {
            // Skip excluded URLs and their children
            if excludingURLs.contains(url.standardizedFileURL) {
                enumerator.skipDescendants()
                continue
            }

            // Check if it's a directory
            var isDirectory: ObjCBool = false
            if fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue {
                folders.append(url)
            }
        }

        // Sort alphabetically
        return folders.sorted { $0.path.localizedCaseInsensitiveCompare($1.path) == .orderedAscending }
    }

    @objc private func contextMenuMoveToFolder(_ sender: NSMenuItem) {
        guard let destinationURL = sender.representedObject as? URL else {
            logger.warning("contextMenuMoveToFolder: No destination URL")
            return
        }

        let items = selectedItems()
        logger.info("contextMenuMoveToFolder: Moving \(items.count) items to '\(destinationURL.lastPathComponent, privacy: .public)'")

        var failedItems: [(SidebarItem, Error)] = []

        for item in items {
            guard let sourceURL = item.url else { continue }

            // Skip if trying to move into itself or a child
            if destinationURL.path.hasPrefix(sourceURL.path) {
                logger.warning("contextMenuMoveToFolder: Cannot move '\(item.title, privacy: .public)' into itself or a subdirectory")
                continue
            }

            // Skip if already in the destination
            if sourceURL.deletingLastPathComponent().standardizedFileURL == destinationURL.standardizedFileURL {
                logger.debug("contextMenuMoveToFolder: '\(item.title, privacy: .public)' is already in destination")
                continue
            }

            let destURL = destinationURL.appendingPathComponent(sourceURL.lastPathComponent)

            do {
                // Check for existing file with same name
                if FileManager.default.fileExists(atPath: destURL.path) {
                    // Generate unique name
                    var uniqueURL = destURL
                    var counter = 1
                    let baseName = sourceURL.deletingPathExtension().lastPathComponent
                    let ext = sourceURL.pathExtension

                    while FileManager.default.fileExists(atPath: uniqueURL.path) {
                        counter += 1
                        let newName = ext.isEmpty ? "\(baseName) \(counter)" : "\(baseName) \(counter).\(ext)"
                        uniqueURL = destinationURL.appendingPathComponent(newName)
                    }

                    try FileManager.default.moveItem(at: sourceURL, to: uniqueURL)
                    logger.info("contextMenuMoveToFolder: Moved '\(item.title, privacy: .public)' to '\(uniqueURL.lastPathComponent, privacy: .public)'")
                } else {
                    try FileManager.default.moveItem(at: sourceURL, to: destURL)
                    logger.info("contextMenuMoveToFolder: Moved '\(item.title, privacy: .public)'")
                }
            } catch {
                logger.error("contextMenuMoveToFolder: Failed to move '\(item.title, privacy: .public)' - \(error.localizedDescription, privacy: .public)")
                failedItems.append((item, error))
            }
        }

        // Refresh sidebar
        reloadFromFilesystem()

        // Show error if some items failed
        if !failedItems.isEmpty {
            let alert = NSAlert()
            alert.messageText = "Some items could not be moved"
            alert.informativeText = failedItems.map { "\($0.0.title): \($0.1.localizedDescription)" }.joined(separator: "\n")
            alert.alertStyle = .warning
            alert.addButton(withTitle: "OK")
            if let window = view.window {
                alert.beginSheetModal(for: window)
            }
        }
    }
}

// MARK: - Notifications

public extension Notification.Name {
    static let sidebarSelectionChanged = Notification.Name("SidebarSelectionChanged")
    static let sidebarFileDropped = Notification.Name("SidebarFileDropped")
    static let sidebarFileDropCompleted = Notification.Name("SidebarFileDropCompleted")
    static let sidebarPreferredWidthRecommended = Notification.Name("SidebarPreferredWidthRecommended")
    static let sidebarItemsDeleted = Notification.Name("SidebarItemsDeleted")
    /// Posted from the Inspector when the user clicks a source sample link to navigate the sidebar.
    /// userInfo: `["url": URL]` — the bundle URL to navigate to.
    static let navigateToSidebarItem = Notification.Name("NavigateToSidebarItem")
}

public extension NotificationUserInfoKey {
    static let windowStateScope = "windowStateScope"
    static let contentSelectionIdentity = "contentSelectionIdentity"
}
