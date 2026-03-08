// SidebarViewController.swift - Project navigation sidebar
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import LungfishCore
import LungfishIO
import LungfishWorkflow
import os.log

/// Logger for sidebar operations
private let logger = Logger(subsystem: "com.lungfish.browser", category: "SidebarViewController")

/// Pasteboard type for internal sidebar item dragging
private let sidebarItemPasteboardType = NSPasteboard.PasteboardType("com.lungfish.browser.sidebaritem")


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

        // Post notification for each dropped file
        for url in urls {
            NotificationCenter.default.post(
                name: .sidebarFileDropped,
                object: self.sidebarController,
                userInfo: ["url": url, "destination": NSNull()]
            )
        }

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

    /// Search field for filtering
    private var searchField: NSSearchField!

    // MARK: - Data

    /// Root items displayed in the sidebar
    private var rootItems: [SidebarItem] = []

    /// The currently open project URL (filesystem-backed model)
    private var projectURL: URL?

    /// File system watcher for auto-refreshing when files change
    private var fileSystemWatcher: FileSystemWatcher?

    /// Suppresses delegate and notification callbacks during programmatic selection changes.
    private var suppressSelectionCallbacks = false

    // MARK: - Delegate

    /// Delegate for selection change callbacks.
    ///
    /// Use this delegate instead of observing `sidebarSelectionChanged` notifications
    /// for reliable, synchronous handling of selection changes. This avoids Swift
    /// concurrency issues where Tasks don't execute from notification handlers.
    public weak var selectionDelegate: SidebarSelectionDelegate?

    // MARK: - Lifecycle

    public override func loadView() {
        // Create the main container view as a drop target
        // This ensures file drops are accepted even when outline view doesn't handle them
        let containerView = SidebarDropTargetView()
        containerView.translatesAutoresizingMaskIntoConstraints = false
        containerView.sidebarController = self

        // Create search field
        searchField = NSSearchField()
        searchField.translatesAutoresizingMaskIntoConstraints = false
        searchField.placeholderString = "Filter"
        searchField.sendsSearchStringImmediately = true
        searchField.target = self
        searchField.action = #selector(searchFieldChanged(_:))
        containerView.addSubview(searchField)

        // Create outline view
        outlineView = NSOutlineView()
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

        // Layout constraints
        // Note: Top margin of 52 accounts for window title bar and traffic light buttons
        NSLayoutConstraint.activate([
            searchField.topAnchor.constraint(equalTo: containerView.topAnchor, constant: 52),
            searchField.leadingAnchor.constraint(equalTo: containerView.leadingAnchor, constant: 8),
            searchField.trailingAnchor.constraint(equalTo: containerView.trailingAnchor, constant: -8),

            scrollView.topAnchor.constraint(equalTo: searchField.bottomAnchor, constant: 8),
            scrollView.leadingAnchor.constraint(equalTo: containerView.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: containerView.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: containerView.bottomAnchor),
        ])

        self.view = containerView
    }

    public override func viewDidLoad() {
        super.viewDidLoad()

        // Configure visual effect for sidebar vibrancy
        view.wantsLayer = true

        // Load initial data
        loadSampleData()

        // Set up key event monitoring for Delete key
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
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
            return event
        }
    }

    // MARK: - Data Loading

    private func loadSampleData() {
        // Start with empty sidebar - documents will be added when loaded
        // The "OPEN DOCUMENTS" group is created automatically when first document is loaded
        rootItems = []
        outlineView.reloadData()
        logger.info("loadSampleData: Sidebar initialized (empty, waiting for documents)")
    }

    // MARK: - Actions

    @objc private func searchFieldChanged(_ sender: NSSearchField) {
        // Filter outline view based on search text
        let searchText = sender.stringValue
        if searchText.isEmpty {
            // Reset filter
            loadSampleData()
        } else {
            // Filter items
            // TODO: Implement filtering
        }
    }

    // MARK: - Public API

    /// Reloads the sidebar content
    public func reloadData() {
        outlineView.reloadData()
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

        // Store the new project URL
        projectURL = url

        // Scan filesystem and build sidebar
        reloadFromFilesystem()

        // Start watching for changes
        fileSystemWatcher = FileSystemWatcher { [weak self] in
            self?.reloadFromFilesystem()
        }
        fileSystemWatcher?.startWatching(directory: url)

        logger.info("openProject: Project opened, watching for changes")
    }

    /// Closes the current project and clears the sidebar.
    public func closeProject() {
        logger.info("closeProject: Closing current project")

        fileSystemWatcher?.stopWatching()
        fileSystemWatcher = nil
        projectURL = nil
        rootItems = []
        outlineView.reloadData()
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
            outlineView.reloadData()
            return
        }

        logger.info("reloadFromFilesystem: Scanning '\(projectURL.path, privacy: .public)'")

        // Save current selection to restore after reload
        let selectedURLs = selectedItems().compactMap { $0.url?.standardizedFileURL }
        let selectedURLSet = Set(selectedURLs)

        // Suppress selection side effects while rebuilding and restoring rows.
        suppressSelectionCallbacks = true

        // Build the sidebar items from the project folder's contents (not the folder itself)
        // This shows the contents at the root level, similar to how Finder shows folder contents
        rootItems = buildRootItems(from: projectURL)

        // Reload the outline view
        outlineView.reloadData()

        // Expand all folders at root level
        for item in rootItems where item.type == .folder {
            outlineView.expandItem(item)
        }

        // Restore selection if possible
        restoreSelection(urls: selectedURLs)
        suppressSelectionCallbacks = false

        // Propagate selection only if it actually changed after refresh.
        let restoredItems = selectedItems()
        let restoredURLSet = Set(restoredItems.compactMap { $0.url?.standardizedFileURL })
        if restoredURLSet != selectedURLSet {
            handleSelectionChange(restoredItems, source: "reloadFromFilesystem")
        }

        let itemCount = rootItems.reduce(0) { $0 + countItems(in: $1) }
        logger.info("reloadFromFilesystem: Sidebar updated with \(itemCount) items")
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
        let displayName = (itemType == .referenceBundle || itemType == .fastqBundle)
            ? url.deletingPathExtension().lastPathComponent
            : filename
        let item = SidebarItem(
            title: displayName,
            type: itemType,
            icon: icon,
            children: [],
            url: url
        )

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
                        // Always include directories
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
    private func isInternalSidecarFile(_ url: URL) -> Bool {
        url.lastPathComponent.hasSuffix(".lungfish-meta.json")
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

    /// Finds a sidebar item by URL.
    private func findItem(byURL url: URL) -> SidebarItem? {
        func search(in items: [SidebarItem]) -> SidebarItem? {
            for item in items {
                if item.url?.standardizedFileURL == url.standardizedFileURL {
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

        outlineView.reloadData()

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

        outlineView.reloadData()

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
        outlineView.reloadData()

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
        outlineView.reloadData()
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
            return rootItems.count
        }
        if let sidebarItem = item as? SidebarItem {
            return sidebarItem.children.count
        }
        return 0
    }

    public func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        if item == nil {
            return rootItems[index]
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

            // For internal drags, only allow dropping into folders or projects
            guard let dest = destinationItem else {
                // Dropping at root level - not allowed for internal items
                return []
            }

            // Can only drop into folders or projects
            if dest.type != .folder && dest.type != .project {
                return []
            }

            // Cross-window drags carry the internal type, but source items aren't
            // in this sidebar model. Treat these as copy imports.
            if !hasLocalSource {
                logger.debug("validateDrop: Internal type from another window - COPY import to '\(dest.title, privacy: .public)'")
                return .copy
            }

            // Check for Control key to copy, otherwise move
            let modifiers = NSEvent.modifierFlags
            if modifiers.contains(.control) || modifiers.contains(.option) {
                logger.debug("validateDrop: Internal drag - COPY to '\(dest.title, privacy: .public)'")
                return .copy
            } else {
                logger.debug("validateDrop: Internal drag - MOVE to '\(dest.title, privacy: .public)'")
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

        if hasInternalType,
           let identifierString = pasteboard.string(forType: sidebarItemPasteboardType) {
            debugLog("acceptDrop: Internal drag detected with identifier='\(identifierString)'")

            // Find the source item by its identifier
            if let sourceItem = findItem(byPath: identifierString),
               let dest = destinationItem, (dest.type == .folder || dest.type == .project) {
                // Check modifier keys for copy vs move
                let modifiers = NSEvent.modifierFlags
                let isCopy = modifiers.contains(.control) || modifiers.contains(.option)

                if isCopy {
                    // Copy the item
                    return copyItem(sourceItem, to: dest, at: index)
                } else {
                    // Move the item
                    return moveItem(sourceItem, to: dest, at: index)
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

            for url in fileURLs {
                logger.info("acceptDrop: Posting notification for '\(url.lastPathComponent, privacy: .public)'")
                // Post notification to load the file
                NotificationCenter.default.post(
                    name: .sidebarFileDropped,
                    object: self,
                    userInfo: ["url": url, "destination": destinationItem as Any]
                )
            }
            return true
        }

        // Fallback: try reading file URLs directly from pasteboard
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self]) as? [URL], !urls.isEmpty {
            logger.info("acceptDrop: Fallback - found \(urls.count) URLs")
            let fileURLs = urls.filter { $0.isFileURL }
            logger.info("acceptDrop: Fallback - \(fileURLs.count) are file URLs")

            for url in fileURLs {
                logger.info("acceptDrop: Fallback posting notification for '\(url.lastPathComponent, privacy: .public)'")
                NotificationCenter.default.post(
                    name: .sidebarFileDropped,
                    object: self,
                    userInfo: ["url": url, "destination": destinationItem as Any]
                )
            }
            if !fileURLs.isEmpty {
                return true
            }
        }

        debugLog("acceptDrop: FAILED - No file URLs found in pasteboard")
        return false
    }

    // MARK: - Selection Helpers

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

    // MARK: - Delete Operations

    /// Deletes the currently selected items, moving files to Trash
    @objc public func deleteSelectedItems() {
        let items = selectedItems()
        guard !items.isEmpty else {
            logger.debug("deleteSelectedItems: No items selected")
            return
        }

        // Filter out items that shouldn't be deleted (groups, projects)
        let deletableItems = items.filter { item in
            item.type != .group && item.type != .project
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

        outlineView.reloadData()

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
        logger.info("moveItem: Moving '\(sourceItem.title, privacy: .public)' to '\(destination.title, privacy: .public)'")

        guard let sourceURL = sourceItem.url, let destFolderURL = destination.url else {
            logger.warning("moveItem: Missing URL for source or destination")
            return false
        }

        // Move the actual file
        let destURL = destFolderURL.appendingPathComponent(sourceURL.lastPathComponent)
        do {
            try FileManager.default.moveItem(at: sourceURL, to: destURL)
            logger.info("moveItem: File moved from \(sourceURL.path, privacy: .public) to \(destURL.path, privacy: .public)")
            // Immediately refresh sidebar for instant feedback
            reloadFromFilesystem()
            return true
        } catch {
            logger.error("moveItem: Failed to move file - \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    /// Copies an item to a new destination
    private func copyItem(_ sourceItem: SidebarItem, to destination: SidebarItem, at index: Int) -> Bool {
        logger.info("copyItem: Copying '\(sourceItem.title, privacy: .public)' to '\(destination.title, privacy: .public)'")

        guard let sourceURL = sourceItem.url, let destFolderURL = destination.url else {
            logger.warning("copyItem: Missing URL for source or destination")
            return false
        }

        // Generate unique filename
        var destURL = destFolderURL.appendingPathComponent(sourceURL.lastPathComponent)
        var counter = 1
        let baseName = sourceURL.deletingPathExtension().lastPathComponent
        let fileExtension = sourceURL.pathExtension

        while FileManager.default.fileExists(atPath: destURL.path) {
            let newName = "\(baseName)_copy\(counter > 1 ? "_\(counter)" : "").\(fileExtension)"
            destURL = destFolderURL.appendingPathComponent(newName)
            counter += 1
        }

        // Copy the file
        do {
            try FileManager.default.copyItem(at: sourceURL, to: destURL)
            logger.info("copyItem: File copied to \(destURL.path, privacy: .public)")
            // Immediately refresh sidebar for instant feedback
            reloadFromFilesystem()
            return true
        } catch {
            logger.error("copyItem: Failed to copy file - \(error.localizedDescription, privacy: .public)")
            return false
        }
    }
}

// MARK: - NSOutlineViewDelegate

extension SidebarViewController: NSOutlineViewDelegate {

    public func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let sidebarItem = item as? SidebarItem else { return nil }

        let identifier = NSUserInterfaceItemIdentifier("SidebarCell")
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

        // Configure cell
        cellView?.textField?.stringValue = sidebarItem.title

        if sidebarItem.type == .group {
            cellView?.textField?.font = NSFont.systemFont(ofSize: 11, weight: .semibold)
            cellView?.textField?.textColor = .secondaryLabelColor
            cellView?.imageView?.image = nil
        } else {
            cellView?.textField?.font = NSFont.systemFont(ofSize: 13)
            cellView?.textField?.textColor = .labelColor

            if let iconName = sidebarItem.icon {
                cellView?.imageView?.image = NSImage(systemSymbolName: iconName, accessibilityDescription: sidebarItem.title)
                cellView?.imageView?.contentTintColor = sidebarItem.type.tintColor
            }
        }

        return cellView
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
                userInfo: ["items": [] as [SidebarItem]]
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
            userInfo: [
                "item": items.first as Any,
                "items": items
            ]
        )
        logger.debug("\(source, privacy: .public): Called delegate and posted notification with \(items.count) items")
    }
}

// MARK: - SidebarItem Model

/// Represents an item in the sidebar hierarchy
public class SidebarItem: NSObject {
    public var title: String
    public let type: SidebarItemType
    public let icon: String?
    public var children: [SidebarItem]
    public var url: URL?

    public init(title: String, type: SidebarItemType, icon: String? = nil, children: [SidebarItem] = [], url: URL? = nil) {
        self.title = title
        self.type = type
        self.icon = icon
        self.children = children
        self.url = url
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
        case .referenceBundle, .fastqBundle:
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
        let hasFiles = items.contains { $0.type != .group && $0.type != .project && $0.type != .folder && $0.type != .referenceBundle }
        let hasFolders = items.contains { $0.type == .folder || $0.type == .project }
        let hasGroups = items.contains { $0.type == .group }
        let hasDeletable = items.contains { $0.type != .group && $0.type != .project }
        let hasBundles = items.contains { $0.type == .referenceBundle }

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
        guard let item = items.first, item.type != .group && item.type != .project else { return }

        logger.info("contextMenuOpen: Opening '\(item.title, privacy: .public)'")

        // Post notification to open the document
        NotificationCenter.default.post(
            name: .sidebarSelectionChanged,
            object: self,
            userInfo: ["item": item]
        )
    }

    /// Shows the internal contents of a bundle in Finder (like "Show Package Contents" in macOS).
    @objc private func contextMenuShowBundleContents(_ sender: Any?) {
        let items = selectedItems()
        guard let item = items.first, item.type == .referenceBundle, let url = item.url else { return }

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

            if let window = self.view.window {
                alert.beginSheetModal(for: window)
            } else {
                alert.runModal()
            }
        }
    }

    @objc private func contextMenuImportSampleMetadata(_ sender: Any?) {
        let items = selectedItems()
        guard let item = items.first, item.type == .referenceBundle, let bundleURL = item.url else { return }

        logger.info("contextMenuImportSampleMetadata: Importing metadata into '\(item.title, privacy: .public)'")
        guard let appDelegate = NSApp.delegate as? AppDelegate else { return }
        appDelegate.presentMetadataImportPanel(for: bundleURL, presentingWindow: view.window)
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
                        if let window = self.view.window {
                            alert.beginSheetModal(for: window)
                        } else {
                            alert.runModal()
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

        AssemblySheetPresenter.present(
            from: window,
            inputFiles: inputFiles,
            outputDirectory: outputDir,
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

    /// Posts a notification to show the selected bundle in the inspector.
    @objc private func contextMenuShowInInspector(_ sender: Any?) {
        let items = selectedItems()
        guard let item = items.first else { return }

        logger.info("contextMenuShowInInspector: Showing '\(item.title, privacy: .public)' in inspector")

        // Post notification to show inspector with Document tab
        NotificationCenter.default.post(
            name: .showInspectorRequested,
            object: self,
            userInfo: [NotificationUserInfoKey.inspectorTab: "document"]
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

            self?.createFolder(named: folderName, in: parentURL)
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
            outlineView.reloadData()
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
    static let sidebarItemsDeleted = Notification.Name("SidebarItemsDeleted")
}
