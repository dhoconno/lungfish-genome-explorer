// SidebarViewController.swift - Project navigation sidebar
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import LungfishCore
import LungfishIO
import LungfishWorkflow
import os.log
import LungfishKit

/// Logger for sidebar operations
let sidebarLogger = Logger(subsystem: LogSubsystem.app, category: "SidebarViewController")

/// Pasteboard type for internal sidebar item dragging
let sidebarItemPasteboardType = NSPasteboard.PasteboardType("com.lungfish.browser.sidebaritem")

enum SidebarAccessibilityIdentifier {
    static let outline = "sidebar-outline"
    static let analysesGroup = "sidebar-group-analyses"
}

private struct SidebarScrollAnchor {
    let url: URL?
    let offsetFromVisibleTop: CGFloat
    let fallbackY: CGFloat
}

/// Directory entry snapshot type and listing helper.
///
/// F5/F7 moved the scan itself into the nonisolated `SidebarProjectScanner`;
/// these aliases keep the historical names available to the (main-actor)
/// controller and to source-introspection tests.
typealias SidebarDirectoryEntry = SidebarProjectScanner.DirectoryEntry

private func directoryEntries(in directoryURL: URL) throws -> [SidebarDirectoryEntry] {
    try SidebarProjectScanner.directoryEntries(in: directoryURL)
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

/// Controller for the sidebar panel containing project/file navigation.
///
/// Uses NSOutlineView for hierarchical file/sequence display.
@MainActor
public class SidebarViewController: NSViewController {

    // MARK: - UI Components

    /// The outline view for hierarchical navigation
    var outlineView: NSOutlineView!

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
    var rootItems: [SidebarItem] = []

    /// Filtered copy of rootItems when search is active; nil when no filter.
    /// Internal (not private) so the surgical-delete path in the OutlineDataSource
    /// extension can detect an active filter and fall back to a full reload.
    var filteredRootItems: [SidebarItem]?

    /// The items the outline view data source should use.
    var displayItems: [SidebarItem] {
        filteredRootItems ?? rootItems
    }

    /// The currently open project URL (filesystem-backed model)
    var projectURL: URL?

    /// Public read-only accessor for the current project folder URL.
    public var projectFolderURL: URL? { projectURL }

    /// Shared project refresh subscription for auto-refreshing when files change.
    private var projectRefreshSubscriptionID: ProjectFilesystemRefreshCoordinator.SubscriptionID?

    /// Watcher-driven reloads take the background-scan path (F5/F7): they are
    /// already debounced and asynchronous, and nothing observes them synchronously.
    /// Direct `reloadFromFilesystem()` calls stay synchronous because their callers
    /// select a freshly-written URL on the very next line.
    private lazy var refreshScheduler = SidebarRefreshScheduler { [weak self] notifyUnchangedSelectionRefresh in
        self?.reloadFromFilesystemAsync(notifyUnchangedSelectionRefresh: notifyUnchangedSelectionRefresh)
    }

    /// Monotonic token used to discard stale background scan results.
    ///
    /// Bumped by every reload (synchronous or background), by `openProject` and by
    /// `closeProject`, and re-checked on the main actor immediately before the tree
    /// is applied.
    private var sidebarScanGeneration: Int = 0

    #if DEBUG
    /// Test-only hook awaited between a background scan finishing and its result
    /// being applied.
    ///
    /// Lets a test deterministically produce the "scan completed against an older
    /// tree, then a newer reload landed first" ordering that the generation guard
    /// exists to defend against. Always `nil` outside tests, and compiled out of
    /// release builds entirely.
    static var scanBarrierForTesting: (@Sendable () async -> Void)?
    #endif

    /// The barrier a background scan should await before applying, if any.
    ///
    /// Compiles to `nil` in release builds so the hook has zero production cost.
    private static var scanBarrier: (@Sendable () async -> Void)? {
        #if DEBUG
        return scanBarrierForTesting
        #else
        return nil
        #endif
    }

    /// Awaits the test barrier when one is installed. No-op in release builds.
    private static func awaitScanBarrierIfNeeded(_ barrier: (@Sendable () async -> Void)?) async {
        guard let barrier else { return }
        await barrier()
    }

    /// Nesting depth of `withSelectionSuppressed` scopes. Suppression is released
    /// only when this returns to 0, so an inner scope cannot un-suppress an outer
    /// rebuild that still owns the flag.
    private var selectionSuppressionDepth = 0

    /// Universal search coordinator for project-scoped metadata/entity queries.
    private let universalSearchService = UniversalProjectSearchService.shared

    /// In-flight async universal-search query task.
    private var universalSearchTask: Task<Void, Never>?

    /// Monotonic token used to discard stale async query responses.
    private var universalSearchGeneration: Int = 0
    private lazy var searchScheduler = SidebarSearchScheduler(
        onClear: { [weak self] in
            self?.clearSidebarSearchResults()
        },
        onLocalSearch: { [weak self] query, generation in
            self?.applyLocalSidebarSearch(query: query, generation: generation)
        },
        onUniversalSearch: { [weak self] query, generation in
            self?.startUniversalSidebarSearch(query: query, generation: generation)
        }
    )
    /// Current advanced-search popover (if shown).
    private var universalSearchPopover: NSPopover?

    /// Spinner shown during async universal search queries.
    private var searchSpinner: NSProgressIndicator?

    /// Suppresses delegate and notification callbacks during programmatic selection changes.
    var suppressSelectionCallbacks = false

    /// Last selection whose viewport callback and notification were committed.
    /// AppKit updates its row indexes before notifying its delegate, so this
    /// snapshot is used to restore the exact prior selection while an
    /// asynchronous content-transition decision is pending.
    var committedSelectionItems: [SidebarItem] = []

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
        let subscriptionID = projectRefreshSubscriptionID
        Task { @MainActor in
            ProjectFilesystemRefreshCoordinator.shared.unregister(subscriptionID)
        }
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
        searchScheduler.cancel()
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
        sidebarLogger.info("loadSampleData: Sidebar initialized (empty, waiting for documents)")
    }

    // MARK: - Actions

    @objc private func searchFieldChanged(_ sender: NSSearchField) {
        searchScheduler.submit(sender.stringValue)
    }

    private func clearSidebarSearchResults() {
        cancelUniversalSearch(reason: "query changed")
        universalSearchGeneration &+= 1
        filteredRootItems = nil
        outlineView.reloadData()
        setSearchSpinnerVisible(false)
    }

    private func applyLocalSidebarSearch(query searchText: String, generation searchGeneration: Int) {
        cancelUniversalSearch(reason: "query changed")
        universalSearchGeneration = searchGeneration

        let normalizedQuery = searchText.lowercased()
        filteredRootItems = filterItems(rootItems, matching: normalizedQuery)
        outlineView.reloadData()
        expandFilteredSearchResultsIfReasonable()
    }

    private func startUniversalSidebarSearch(query searchText: String, generation searchGeneration: Int) {
        guard let projectURL = projectURL else { return }
        universalSearchGeneration = searchGeneration
        let normalizedQuery = searchText.lowercased()

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
                self.expandFilteredSearchResultsIfReasonable()
            } catch is CancellationError {
                return
            } catch {
                sidebarLogger.debug("searchFieldChanged: universal search unavailable: \(error.localizedDescription, privacy: .public)")
            }

            guard !Task.isCancelled,
                  self.universalSearchGeneration == searchGeneration else { return }
            self.setSearchSpinnerVisible(false)
        }
    }

    private func expandFilteredSearchResultsIfReasonable() {
        guard let filteredRootItems else { return }
        let visibleItemCount = countSidebarItems(filteredRootItems)
        guard visibleItemCount <= 250 else { return }
        outlineView.expandItem(nil, expandChildren: true)
    }

    private func countSidebarItems(_ items: [SidebarItem]) -> Int {
        items.reduce(0) { total, item in
            total + 1 + countSidebarItems(item.children)
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
            self.searchScheduler.submit(query, immediate: true)
            self.universalSearchPopover?.performClose(nil)
            self.universalSearchPopover = nil
        }
        builder.onClear = { [weak self] in
            guard let self else { return }
            self.searchField.stringValue = ""
            self.searchScheduler.submit("", immediate: true)
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
        let sourcePaths = changedPaths.filter {
            !FileSystemWatcher.isUniversalSearchInternalPath($0)
        }
        guard !sourcePaths.isEmpty else { return }
        Task {
            await universalSearchService.scheduleUpdate(
                projectURL: projectURL,
                changedPaths: sourcePaths
            )
        }
    }

    /// Clears universal-search state for a project.
    private func clearUniversalSearchState(for projectURL: URL?) {
        searchScheduler.cancel()
        cancelUniversalSearch(reason: "clearing project state")
        universalSearchGeneration = 0

        guard let projectURL else { return }
        Task {
            await universalSearchService.clearProject(projectURL)
        }
    }

    private func cancelUniversalSearch(reason: String) {
        if universalSearchTask != nil {
            sidebarLogger.debug("cancelUniversalSearch: cancelling in-flight query (\(reason, privacy: .public))")
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

    func reloadOutlineView() {
        // Named `Sidebar.OutlineRefresh` (not `Delete.*`): reloadOutlineView has many
        // callers, only one of which is the delete path. The enclosing `Sidebar.Delete`
        // interval identifies a refresh that belongs to a delete.
        let state = PerfSignpost.sidebar.begin("Sidebar.OutlineRefresh")
        defer { PerfSignpost.sidebar.end("Sidebar.OutlineRefresh", state) }
        outlineView.reloadData()
        postPreferredSidebarWidthIfNeeded()
    }

    func postPreferredSidebarWidthIfNeeded() {
        let width = recommendedSidebarWidth()
        guard abs(width - lastRecommendedSidebarWidth) >= 2 else { return }
        lastRecommendedSidebarWidth = width
        var userInfo: [AnyHashable: Any] = ["width": width]
        if let windowStateScope {
            userInfo[NotificationUserInfoKey.windowStateScope] = windowStateScope
        }
        NotificationCenter.default.post(
            name: .sidebarPreferredWidthRecommended,
            object: self,
            userInfo: userInfo
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
            sidebarLogger.debug("selectItem(forURL:): No item found for \(url.lastPathComponent, privacy: .public)")
            return false
        }

        // Ensure parent items are expanded so the item is visible
        expandParents(of: item)

        let row = outlineView.row(forItem: item)
        if row >= 0 {
            outlineView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            outlineView.scrollRowToVisible(row)
            sidebarLogger.debug("selectItem(forURL:): Selected \(url.lastPathComponent, privacy: .public) at row \(row)")
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
            sidebarLogger.debug("handleNavigateToSidebarItem: No sidebar item found for \(url.lastPathComponent, privacy: .public)")
        }
    }

    private func shouldAcceptScopedNotification(_ notification: Notification) -> Bool {
        guard let notificationScope = notification.userInfo?[NotificationUserInfoKey.windowStateScope] as? WindowStateScope else {
            return true
        }
        guard let windowStateScope else { return true }
        return notificationScope == windowStateScope
    }

    func canWriteSidebarProjectOutputs(workflowName: String, targetURL: URL? = nil) -> Bool {
        let resolvedProjectURL = projectURL
            ?? targetURL.flatMap(ProjectTempDirectory.findProjectRoot)
        return AppDelegate.shared?.canWriteProjectOutputs(
            projectURL: resolvedProjectURL,
            windowStateScope: windowStateScope,
            workflowName: workflowName,
            presentingWindow: view.window
        ) ?? true
    }

    func windowScopedUserInfo(_ userInfo: [AnyHashable: Any]) -> [AnyHashable: Any] {
        guard let windowStateScope else { return userInfo }
        var scopedUserInfo = userInfo
        scopedUserInfo[NotificationUserInfoKey.windowStateScope] = windowStateScope
        return scopedUserInfo
    }

    func rehydrateScientificProvenance(from sourceURL: URL, to destinationURL: URL) {
        if GUIImportedProvenanceRehydrator.finalBundleRoot(containing: destinationURL) != nil {
            do {
                try GUIImportedProvenanceRehydrator.rehydrateImportedCopy(from: sourceURL, to: destinationURL)
                return
            } catch ProvenanceRehydrationError.missingSourceProvenance {
                do {
                    try GUIImportedProvenanceRehydrator.rehydrateRelocatedImportedCopy(
                        from: sourceURL,
                        to: destinationURL
                    )
                    return
                } catch GUIImportedProvenanceRehydratorError.unsupportedSourceProvenance {
                    fallbackToPathRehydration(from: sourceURL, to: destinationURL)
                    return
                } catch ProvenanceRehydrationError.missingSourceProvenance {
                    sidebarLogger.warning("rehydrateScientificProvenance: no source provenance for \(sourceURL.path, privacy: .public)")
                    return
                } catch {
                    sidebarLogger.warning("rehydrateScientificProvenance: failed relocated schema-aware rehydration for \(sourceURL.path, privacy: .public): \(error.localizedDescription, privacy: .public)")
                    return
                }
            } catch GUIImportedProvenanceRehydratorError.unsupportedSourceProvenance {
                fallbackToPathRehydration(from: sourceURL, to: destinationURL)
                return
            } catch {
                sidebarLogger.warning("rehydrateScientificProvenance: failed schema-aware rehydration for \(sourceURL.path, privacy: .public): \(error.localizedDescription, privacy: .public)")
                return
            }
        }

        fallbackToPathRehydration(from: sourceURL, to: destinationURL)
    }

    private func fallbackToPathRehydration(from sourceURL: URL, to destinationURL: URL) {
        ProvenancePathRehydrator.rehydrate(from: sourceURL, to: destinationURL) { message in
            sidebarLogger.warning("rehydrateScientificProvenance: \(message, privacy: .public)")
        }
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
        sidebarLogger.info("openProject: Opening project at '\(url.path, privacy: .public)'")

        // Stop watching previous project, and invalidate any of its in-flight
        // background scans so they cannot land on the newly-opened project.
        refreshScheduler.cancel()
        sidebarScanGeneration &+= 1
        ProjectFilesystemRefreshCoordinator.shared.unregister(projectRefreshSubscriptionID)
        projectRefreshSubscriptionID = nil
        clearUniversalSearchState(for: projectURL)

        // Store the new project URL
        projectURL = url

        // Scan filesystem and build sidebar
        reloadFromFilesystem()
        scheduleUniversalSearchRebuild(immediate: true)

        // Subscribe to shared project filesystem refreshes.
        projectRefreshSubscriptionID = ProjectFilesystemRefreshCoordinator.shared.register(projectURL: url) { [weak self] changedPaths in
            guard let self else { return }
            if changedPaths.nonSidecar.isEmpty && !changedPaths.all.isEmpty {
                // Sidecar-only changes update metadata/search state without rebuilding the outline.
                self.updateSearchIndex(changedPaths: changedPaths.all)
                self.notifySelectedItemsRefreshedIfNeeded(changedPaths: changedPaths.all)
            } else if changedPaths.nonSidecar.isEmpty && changedPaths.all.isEmpty {
                // kFSEventStreamEventFlagMustScanSubDirs — full reload
                self.requestReloadFromFilesystem(notifyUnchangedSelectionRefresh: false)
            } else {
                // Non-sidecar changes detected — incremental sidebar update
                self.updateSidebar(changedPaths: changedPaths)
            }
        }

        sidebarLogger.info("openProject: Project opened, subscribed for filesystem changes")
    }

    /// Closes the current project and clears the sidebar.
    public func closeProject() {
        sidebarLogger.info("closeProject: Closing current project")

        let priorProjectURL = projectURL
        refreshScheduler.cancel()
        // Invalidate any in-flight background scan so it cannot repopulate the
        // sidebar for a project that is no longer open.
        sidebarScanGeneration &+= 1
        ProjectFilesystemRefreshCoordinator.shared.unregister(projectRefreshSubscriptionID)
        projectRefreshSubscriptionID = nil
        projectURL = nil
        clearUniversalSearchState(for: priorProjectURL)
        rootItems = []
        filteredRootItems = nil
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

    public func expandedItemURLsForPersistence() -> [URL] {
        Array(saveExpandedItemURLs()).sorted { $0.path < $1.path }
    }

    public func searchTextForPersistence() -> String? {
        let value = searchField?.stringValue.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return value.isEmpty ? nil : value
    }

    public func applyRestoredState(selectedURL: URL?, expandedURLs: [URL], searchText: String?) {
        if let searchText {
            searchField?.stringValue = searchText
            searchScheduler.submit(searchText, immediate: true)
        }
        restoreExpandedItemURLs(Set(expandedURLs.map(\.standardizedFileURL)))
        if let selectedURL {
            _ = selectItem(forURL: selectedURL)
        }
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
        reloadFromFilesystem(notifyUnchangedSelectionRefresh: true)
    }

    public func requestReloadFromFilesystem() {
        requestReloadFromFilesystem(notifyUnchangedSelectionRefresh: true)
    }

    public func requestReloadFromFilesystem(notifyUnchangedSelectionRefresh: Bool) {
        refreshScheduler.requestFullReload(notifyUnchangedSelectionRefresh: notifyUnchangedSelectionRefresh)
    }

    /// UI state a reload preserves across the rebuild: which rows were selected,
    /// which were expanded, and where the user was scrolled to.
    ///
    /// Captured at APPLY time rather than before the scan. On the background path
    /// the scan can take arbitrarily long, and the user may expand, select or
    /// scroll while it runs; snapshotting up front would silently revert all three
    /// when the result landed.
    private struct SidebarReloadState {
        let selectedURLs: [URL]
        let selectedURLSet: Set<URL>
        let scrollAnchor: SidebarScrollAnchor?
        let expandedURLs: Set<URL>
        let shouldApplyInitialExpansionDefaults: Bool
    }

    /// Captures the live selection, scroll and expansion state.
    ///
    /// Call immediately before mutating `rootItems`, never before an `await`.
    private func captureReloadState() -> SidebarReloadState {
        let selectedURLs = selectedItems().compactMap { $0.url?.standardizedFileURL }
        return SidebarReloadState(
            selectedURLs: selectedURLs,
            selectedURLSet: Set(selectedURLs),
            scrollAnchor: captureScrollAnchor(),
            expandedURLs: saveExpandedItemURLs(),
            shouldApplyInitialExpansionDefaults: rootItems.isEmpty
        )
    }

    /// Runs `body` with sidebar selection callbacks suppressed.
    ///
    /// Suppression must cover ONLY the window in which the outline view is being
    /// mutated — never a background scan, or the user's own clicks during a scan
    /// would be swallowed. The counter makes nesting safe: an inner scope (such as
    /// `applySidebarSelection`) cannot clear suppression an outer rebuild still
    /// owns.
    func withSelectionSuppressed<T>(_ body: () throws -> T) rethrows -> T {
        beginSelectionSuppression()
        defer { endSelectionSuppression() }
        return try body()
    }

    private func beginSelectionSuppression() {
        selectionSuppressionDepth += 1
        suppressSelectionCallbacks = true
    }

    private func endSelectionSuppression() {
        selectionSuppressionDepth = max(0, selectionSuppressionDepth - 1)
        if selectionSuppressionDepth == 0 {
            suppressSelectionCallbacks = false
        }
    }

    /// Runs the project scan off the main actor, then applies the resulting tree.
    ///
    /// F5/F7: this is the path the FSEvents watcher drives (via
    /// `requestReloadFromFilesystem` and the debouncing `SidebarRefreshScheduler`),
    /// and it was the one blocking the main thread for the whole recursive walk.
    /// The scan now runs on a detached task over `Sendable` values; only the cheap
    /// `materialize` + outline-view update happen on the main actor.
    ///
    /// `sidebarScanGeneration` is bumped on every reload and re-checked on the main
    /// actor with NO `await` between the guard and the `rootItems` mutation, so a
    /// slow scan started before a newer reload (or a project close) can never
    /// clobber fresher state.
    ///
    /// Internal rather than private so tests can drive the background path
    /// directly, without waiting on `SidebarRefreshScheduler`'s debounce.
    /// - Returns: The task performing the scan and apply, for tests to await.
    @discardableResult
    func reloadFromFilesystemAsync(notifyUnchangedSelectionRefresh: Bool) -> Task<Void, Never>? {
        sidebarLogger.info("reloadFromFilesystemAsync: CALLED - starting background filesystem scan")
        guard let projectURL = projectURL else {
            sidebarLogger.debug("reloadFromFilesystemAsync: No project URL set")
            sidebarScanGeneration &+= 1
            rootItems = []
            reloadOutlineView()
            return nil
        }

        sidebarLogger.info("reloadFromFilesystemAsync: Scanning '\(projectURL.path, privacy: .public)'")

        sidebarScanGeneration &+= 1
        let generation = sidebarScanGeneration

        let barrier = Self.scanBarrier

        return Task { [weak self] in
            let nodes = await Task.detached(priority: .userInitiated) {
                SidebarProjectScanner.scanRootNodes(from: projectURL)
            }.value

            await Self.awaitScanBarrierIfNeeded(barrier)

            guard let self else { return }
            // No `await` between these guards and the rootItems mutation inside
            // finishReload — that is what makes the generation check sound.
            guard self.sidebarScanGeneration == generation else {
                sidebarLogger.debug("reloadFromFilesystemAsync: Discarding stale scan result")
                return
            }
            guard self.projectURL?.standardizedFileURL == projectURL.standardizedFileURL else {
                sidebarLogger.debug("reloadFromFilesystemAsync: Project changed during scan, discarding result")
                return
            }
            self.finishReload(
                nodes: nodes,
                notifyUnchangedSelectionRefresh: notifyUnchangedSelectionRefresh
            )
        }
    }

    private func reloadFromFilesystem(notifyUnchangedSelectionRefresh: Bool) {
        sidebarLogger.info("reloadFromFilesystem: CALLED - starting filesystem scan")
        guard let projectURL = projectURL else {
            sidebarLogger.debug("reloadFromFilesystem: No project URL set")
            sidebarScanGeneration &+= 1
            rootItems = []
            reloadOutlineView()
            return
        }

        sidebarLogger.info("reloadFromFilesystem: Scanning '\(projectURL.path, privacy: .public)'")

        // Invalidate any in-flight background scan: this synchronous rebuild is
        // now the authoritative tree.
        sidebarScanGeneration &+= 1

        finishReload(
            nodes: SidebarProjectScanner.scanRootNodes(from: projectURL),
            notifyUnchangedSelectionRefresh: notifyUnchangedSelectionRefresh
        )
    }

    /// Materializes a scanned tree and restores the surrounding UI state.
    ///
    /// Shared by the synchronous and background reload paths so both apply the
    /// tree, expansion, selection and scroll position identically. The state is
    /// captured HERE, at apply time, so a background scan cannot revert expansion,
    /// selection or scrolling the user performed while it was running.
    private func finishReload(
        nodes: [SidebarScanNode],
        notifyUnchangedSelectionRefresh: Bool
    ) {
        let state = captureReloadState()
        let selectedURLs = state.selectedURLs
        let selectedURLSet = state.selectedURLSet
        let scrollAnchor = state.scrollAnchor
        let expandedURLs = state.expandedURLs
        let shouldApplyInitialExpansionDefaults = state.shouldApplyInitialExpansionDefaults

        beginSelectionSuppression()

        // Build the sidebar items from the project folder's contents (not the folder itself)
        // This shows the contents at the root level, similar to how Finder shows folder contents
        rootItems = materialize(nodes)

        // Reload the outline view
        reloadOutlineView()

        // On first project load, open top-level folders by default. On later
        // filesystem refreshes, preserve the user's explicit collapse state.
        if shouldApplyInitialExpansionDefaults {
            for item in rootItems where item.type == .folder {
                outlineView.expandItem(item)
            }
        }

        // Restore expansion state captured before rebuilding.
        restoreExpandedItemURLs(expandedURLs)

        // Restore selection if possible
        restoreSelection(urls: selectedURLs)
        restoreScrollAnchor(scrollAnchor)
        endSelectionSuppression()

        // Propagate selection only if it actually changed after refresh.
        let restoredItems = selectedItems()
        let restoredURLSet = Set(restoredItems.compactMap { $0.url?.standardizedFileURL })
        if restoredURLSet != selectedURLSet {
            // During filesystem churn, nested rows can briefly disappear/rebuild between
            // scans. Avoid emitting a synthetic "selection cleared" event from refreshes;
            // explicit user deselection still flows through outlineViewSelectionDidChange.
            //
            // A row that vanished because the file was DELETED is a different case:
            // preserving the viewport there leaves the removed item rendered (and any
            // overlay belonging to it on screen), so propagate the clear.
            if !selectedURLSet.isEmpty && restoredItems.isEmpty
                && !Self.allSelectionURLsRemovedFromDisk(selectedURLSet) {
                sidebarLogger.debug("reloadFromFilesystem: Selection temporarily unavailable after refresh, preserving active content")
            } else {
                handleSelectionChange(restoredItems, source: "reloadFromFilesystem")
            }
        } else if notifyUnchangedSelectionRefresh, !restoredItems.isEmpty {
            handleSelectionRefresh(
                restoredItems,
                source: "reloadFromFilesystem"
            )
        }

        let itemCount = rootItems.reduce(0) { $0 + countItems(in: $1) }
        sidebarLogger.info("reloadFromFilesystem: Sidebar updated with \(itemCount) items")
        scheduleUniversalSearchRebuild()
    }

    /// Whether every previously-selected URL has disappeared from disk.
    ///
    /// Distinguishes a real deletion (clear the viewport) from transient
    /// filesystem churn where the row is rebuilt moments later (keep it).
    static func allSelectionURLsRemovedFromDisk(_ urls: Set<URL>) -> Bool {
        guard !urls.isEmpty else { return false }
        return urls.allSatisfy { !FileManager.default.fileExists(atPath: $0.path) }
    }

    private func captureScrollAnchor() -> SidebarScrollAnchor? {
        guard let scrollView = outlineView.enclosingScrollView else { return nil }
        let visibleTop = scrollView.contentView.bounds.minY
        let row = topVisibleRow(at: visibleTop)
        let item = row.flatMap { outlineView.item(atRow: $0) as? SidebarItem }
        let offset = row.map { outlineView.rect(ofRow: $0).minY - visibleTop } ?? 0
        return SidebarScrollAnchor(
            url: item?.url?.standardizedFileURL,
            offsetFromVisibleTop: offset,
            fallbackY: visibleTop
        )
    }

    private func topVisibleRow(at visibleTop: CGFloat) -> Int? {
        let probes: [CGFloat] = [0, 1, outlineView.rowHeight / 2, outlineView.rowHeight]
        for delta in probes {
            let row = outlineView.row(at: NSPoint(x: 0, y: visibleTop + delta))
            if row >= 0 { return row }
        }
        return nil
    }

    private func restoreScrollAnchor(_ anchor: SidebarScrollAnchor?) {
        guard let anchor,
              let scrollView = outlineView.enclosingScrollView else { return }

        outlineView.layoutSubtreeIfNeeded()
        let targetY: CGFloat
        if let url = anchor.url,
           let item = findItem(byURL: url),
           outlineView.row(forItem: item) >= 0 {
            let row = outlineView.row(forItem: item)
            targetY = outlineView.rect(ofRow: row).minY - anchor.offsetFromVisibleTop
        } else {
            targetY = anchor.fallbackY
        }

        let lastRow = outlineView.numberOfRows - 1
        let contentHeight = lastRow >= 0 ? outlineView.rect(ofRow: lastRow).maxY : 0
        let maximumY = max(0, contentHeight - scrollView.contentView.bounds.height)
        let clampedY = min(max(0, targetY), maximumY)
        scrollView.contentView.scroll(to: NSPoint(
            x: scrollView.contentView.bounds.minX,
            y: clampedY
        ))
        scrollView.reflectScrolledClipView(scrollView.contentView)
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
    /// - Returns: The task performing the off-main rescan and surgical apply, so
    ///   tests can await it. `nil` when the update resolved synchronously (no
    ///   project, nothing to do, or a fall-back to a full reload).
    ///
    /// Internal rather than private so tests can drive overlapping incremental
    /// updates directly.
    @discardableResult
    func updateSidebar(changedPaths: FileSystemWatcher.ChangedPaths) -> Task<Void, Never>? {
        guard let projectURL else { return nil }

        sidebarLogger.debug("updateSidebar: Processing \(changedPaths.nonSidecar.count) non-sidecar changed paths")

        // Also forward ALL paths (including sidecars) to the search index
        updateSearchIndex(changedPaths: changedPaths.all)

        let nonSidecar = changedPaths.nonSidecar
        guard !nonSidecar.isEmpty else { return nil }

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
            sidebarLogger.info("updateSidebar: Root-level or Analyses change — falling back to full reload")
            requestReloadFromFilesystem(notifyUnchangedSelectionRefresh: false)
            return nil
        }

        sidebarLogger.info("updateSidebar: Incremental update for \(affectedTopLevelNames.count) top-level items")

        // Bail out early (on the main actor) if any affected top-level item is new,
        // since that needs a full reload rather than a subtree diff.
        for topLevelName in affectedTopLevelNames {
            let topLevelURL = projectURL.appendingPathComponent(topLevelName)
            guard rootItems.contains(where: {
                $0.url?.standardizedFileURL.path == topLevelURL.standardizedFileURL.path
            }) else {
                sidebarLogger.debug("updateSidebar: New top-level item '\(topLevelName)' — full reload")
                requestReloadFromFilesystem(notifyUnchangedSelectionRefresh: false)
                return nil
            }
        }

        // F7: each affected top-level item is re-scanned recursively, which for a
        // FASTQ bundle means demux/derivative walks plus per-node JSON sidecar
        // decodes. Do that work off the main actor and apply only the surgical
        // insert/remove/reload diff here.
        let affectedURLs = affectedTopLevelNames
            .sorted()
            .map { projectURL.appendingPathComponent($0) }

        // Bump the generation exactly as the full-reload path does. Without this,
        // two overlapping incremental scans are not mutually ordered (an older one
        // could apply last), and an incremental scan would not invalidate an older
        // in-flight full reload whose wholesale rootItems replacement would clobber
        // this surgical patch.
        sidebarScanGeneration &+= 1
        let generation = sidebarScanGeneration
        let allChangedPaths = changedPaths.all
        let barrier = Self.scanBarrier

        return Task { [weak self] in
            let rebuiltNodes = await Task.detached(priority: .userInitiated) {
                affectedURLs.map { SidebarProjectScanner.scanTree(from: $0, isRoot: false) }
            }.value

            await Self.awaitScanBarrierIfNeeded(barrier)

            guard let self else { return }
            // Re-check on the main actor with no `await` before the mutations below:
            // a newer reload or incremental scan owns the tree.
            guard self.sidebarScanGeneration == generation else {
                sidebarLogger.debug("updateSidebar: Discarding stale incremental scan result")
                return
            }
            guard self.projectURL?.standardizedFileURL == projectURL.standardizedFileURL else {
                sidebarLogger.debug("updateSidebar: Project changed during scan, discarding result")
                return
            }

            // Suppress only while the outline view is actually being mutated.
            self.withSelectionSuppressed {
                for (topLevelURL, rebuiltNode) in zip(affectedURLs, rebuiltNodes) {
                    guard let existingItemIndex = self.rootItems.firstIndex(where: {
                        $0.url?.standardizedFileURL.path == topLevelURL.standardizedFileURL.path
                    }) else {
                        // The item disappeared while the scan ran; a later watcher event
                        // covers it, and a blanket reload here would break the surgical
                        // update contract.
                        continue
                    }

                    self.applySubtreeDiff(
                        existingItem: self.rootItems[existingItemIndex],
                        rebuiltItem: self.materialize(rebuiltNode),
                        parent: nil,
                        indexInParent: existingItemIndex
                    )
                }
            }

            self.notifySelectedItemsRefreshedIfNeeded(changedPaths: allChangedPaths)
        }
    }

    private func notifySelectedItemsRefreshedIfNeeded(changedPaths: [URL]) {
        let items = selectedItems()
        guard !items.isEmpty else { return }
        let changedPaths = changedPaths
            .flatMap { selectedItemRefreshPaths(forChangedPath: $0) }
        guard items.contains(where: { item in
            guard let selectedURL = item.url?.standardizedFileURL else { return false }
            return changedPaths.contains { changedPath in
                shouldRefreshSelectedItem(item, selectedURL: selectedURL, forChangedPath: changedPath)
            }
        }) else {
            return
        }
        handleSelectionRefresh(
            items,
            source: "notifySelectedItemsRefreshedIfNeeded"
        )
    }

    private func shouldRefreshSelectedItem(
        _ item: SidebarItem,
        selectedURL: URL,
        forChangedPath changedURL: URL
    ) -> Bool {
        let selectedPath = selectedURL.standardizedFileURL.path
        let changedURL = changedURL.standardizedFileURL
        let changedPath = changedURL.path

        if item.type.isBundle {
            if changedPath == selectedPath {
                return false
            }
            if changedPath.hasPrefix(selectedPath + "/"), changedURL.lastPathComponent.hasPrefix(".") {
                return false
            }
        }

        return changedPath == selectedPath
            || changedPath.hasPrefix(selectedPath + "/")
            || selectedPath.hasPrefix(changedPath + "/")
    }

    private func selectedItemRefreshPaths(forChangedPath url: URL) -> [URL] {
        let standardizedURL = url.standardizedFileURL
        if standardizedURL.lastPathComponent == BundleViewState.filename {
            return []
        }

        let fastqMetadataSuffix = ".lungfish-meta.json"
        guard standardizedURL.lastPathComponent.hasSuffix(fastqMetadataSuffix) else {
            return [standardizedURL]
        }

        let ownerName = String(standardizedURL.lastPathComponent.dropLast(fastqMetadataSuffix.count))
        guard !ownerName.isEmpty else { return [standardizedURL] }
        return [
            standardizedURL,
            standardizedURL.deletingLastPathComponent().appendingPathComponent(ownerName).standardizedFileURL
        ]
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
    // MARK: - Tree Building (main-actor materialization over an off-main scan)
    //
    // F5/F7: the recursive filesystem walk and its per-bundle JSON sidecar probes
    // now live in the nonisolated `SidebarProjectScanner`, which produces a
    // `Sendable` `SidebarScanNode` value tree. The main actor's only remaining job
    // is `materialize`: turning nodes into `SidebarItem`s and rendering badges.
    //
    // The synchronous `buildRootItems`/`buildSidebarTree` wrappers below preserve
    // the existing call contract (notably `updateSidebar`'s surgical per-subtree
    // rebuild). `reloadFromFilesystemAsync` runs the same scan off-main.

    /// Converts a scanned node tree into the `SidebarItem` graph the outline view
    /// displays, rendering text-pill badges into `NSImage`s.
    ///
    /// This is the ONLY step that touches AppKit, which is why it is the only step
    /// that must run on the main actor.
    private func materialize(_ node: SidebarScanNode) -> SidebarItem {
        let icon: String?
        let customImage: NSImage?
        switch node.badge {
        case .symbol(let name):
            icon = name
            customImage = nil
        case .text(let text):
            icon = nil
            customImage = TextBadgeIcon.image(text: text, size: NSSize(width: 16, height: 16))
        case nil:
            icon = nil
            customImage = nil
        }

        let item = SidebarItem(
            title: node.title,
            type: node.type,
            icon: icon,
            customImage: customImage,
            children: node.children.map { materialize($0) },
            url: node.url,
            subtitle: node.subtitle
        )
        item.userInfo = node.userInfo
        return item
    }

    private func materialize(_ nodes: [SidebarScanNode]) -> [SidebarItem] {
        nodes.map { materialize($0) }
    }

    /// Builds root-level sidebar items from the contents of a project directory.
    ///
    /// This scans the project folder and returns its contents as an array of items,
    /// so they appear at the root level of the sidebar (not nested under a project folder).
    ///
    /// - Parameter projectURL: The project directory URL to scan
    /// - Returns: Array of SidebarItems representing the project's contents
    private func buildRootItems(from projectURL: URL) -> [SidebarItem] {
        materialize(SidebarProjectScanner.scanRootNodes(from: projectURL))
    }

    /// Builds a SidebarItem tree from a filesystem directory.
    ///
    /// - Parameters:
    ///   - url: The directory URL to scan
    ///   - isRoot: Whether this is the root project folder
    /// - Returns: A SidebarItem representing the directory and its contents
    private func buildSidebarTree(from url: URL, isRoot: Bool = false) -> SidebarItem {
        materialize(SidebarProjectScanner.scanTree(from: url, isRoot: isRoot))
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
        case .lungfishMultipleSequenceAlignmentBundle:
            return (.multipleSequenceAlignmentBundle, "rectangle.grid.1x2")
        case .lungfishPhylogeneticTreeBundle:
            return (.phylogeneticTreeBundle, "point.3.connected.trianglepath.dotted")
        case .lungfishMHCReferenceBundle:
            return (.mhcReferenceBundle, "cylinder.split.1x2")
        }
    }

    /// Adds a loaded document to the sidebar
    public func addLoadedDocument(_ document: LoadedDocument) {
        sidebarLogger.info("addLoadedDocument: Adding '\(document.name, privacy: .public)' to sidebar")

        // Find or create the "Open Documents" group
        var openDocsGroup = rootItems.first(where: { $0.title == "OPEN DOCUMENTS" })
        if openDocsGroup == nil {
            sidebarLogger.debug("addLoadedDocument: Creating OPEN DOCUMENTS group")
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
            sidebarLogger.debug("addLoadedDocument: Document already in sidebar")
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
        sidebarLogger.info("addLoadedDocument: Added item to sidebar, reloading")

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
        sidebarLogger.info("addDownloadedDocument: Adding '\(document.name, privacy: .public)' to Downloads folder")

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
            sidebarLogger.debug("addDownloadedDocument: No project found, falling back to OPEN DOCUMENTS")
            addLoadedDocument(document)
            return
        }

        sidebarLogger.debug("addDownloadedDocument: Found project '\(projectItem.title, privacy: .public)'")

        // Find or create the "Downloads" folder within the project
        var downloadsFolder = projectItem.children.first(where: {
            $0.title.lowercased() == "downloads" && $0.type == .folder
        })

        if downloadsFolder == nil {
            sidebarLogger.debug("addDownloadedDocument: Creating Downloads folder")
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
            sidebarLogger.debug("addDownloadedDocument: Document already in downloads folder")
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
        sidebarLogger.info("addDownloadedDocument: Added '\(document.name, privacy: .public)' to Downloads folder, reloading")

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
        sidebarLogger.info("addProjectFolder: Adding folder '\(folderURL.lastPathComponent, privacy: .public)' with \(documents.count) documents")

        // Idempotent: Remove existing project folder with same URL if present
        let normalizedURL = folderURL.standardizedFileURL
        if let existingIndex = rootItems.firstIndex(where: {
            $0.type == .project && $0.url?.standardizedFileURL == normalizedURL
        }) {
            sidebarLogger.info("addProjectFolder: Replacing existing folder at index \(existingIndex)")
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
                sidebarLogger.debug("addProjectFolder: Added '\(document.name, privacy: .public)' to root")
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
                    sidebarLogger.debug("addProjectFolder: Created subfolder '\(subfolderName, privacy: .public)'")
                }
                subfolderItems[relativePath]?.children.append(docItem)
                sidebarLogger.debug("addProjectFolder: Added '\(document.name, privacy: .public)' to subfolder '\(relativePath, privacy: .public)'")
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

        sidebarLogger.info("addProjectFolder: Reloading outline view with \(folderItem.children.count) children")
        reloadOutlineView()

        // Expand the folder to show contents
        outlineView.expandItem(folderItem)

        // Select the first document if any
        let firstDoc = folderItem.children.first(where: { $0.type != .folder }) ?? folderItem.children.first?.children.first
        if let firstDoc = firstDoc {
            let row = outlineView.row(forItem: firstDoc)
            if row >= 0 {
                outlineView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
                sidebarLogger.debug("addProjectFolder: Selected first document at row \(row)")
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
        sidebarLogger.info("addFileToProject: Adding '\(document.name, privacy: .public)' to project")

        // Find the project item in the sidebar
        let normalizedProjectURL = projectURL.standardizedFileURL
        guard let projectItem = rootItems.first(where: {
            $0.type == .project && $0.url?.standardizedFileURL == normalizedProjectURL
        }) else {
            sidebarLogger.warning("addFileToProject: Project not found in sidebar, falling back to addLoadedDocument")
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
            sidebarLogger.debug("addFileToProject: Document already exists in project sidebar")
            return
        }

        if relativePath.isEmpty {
            // File is directly in project root folder
            projectItem.children.append(docItem)
            sidebarLogger.info("addFileToProject: Added '\(document.name, privacy: .public)' to project root")
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
                sidebarLogger.info("addFileToProject: Created subfolder '\(subfolderName, privacy: .public)'")
            }

            subfolderItem!.children.append(docItem)
            sidebarLogger.info("addFileToProject: Added '\(document.name, privacy: .public)' to subfolder '\(subfolderName, privacy: .public)'")

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

        sidebarLogger.info("addFileToProject: Sidebar updated successfully")
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
            sidebarLogger.debug("refreshItem: No item found for \(url.lastPathComponent, privacy: .public)")
            return
        }

        // Reload just this item to update its display
        outlineView.reloadItem(item, reloadChildren: false)
        sidebarLogger.debug("refreshItem: Refreshed \(item.title, privacy: .public)")
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
    // `windowStateScope` now lives in the LungfishKit kernel (shared across leaves).
    static let contentSelectionIdentity = "contentSelectionIdentity"
}
