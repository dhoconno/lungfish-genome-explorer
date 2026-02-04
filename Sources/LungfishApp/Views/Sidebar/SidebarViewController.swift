// SidebarViewController.swift - Project navigation sidebar
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import LungfishCore
import os.log

/// Logger for sidebar operations
private let logger = Logger(subsystem: "com.lungfish.browser", category: "SidebarViewController")

/// Pasteboard type for internal sidebar item dragging
private let sidebarItemPasteboardType = NSPasteboard.PasteboardType("com.lungfish.browser.sidebaritem")

// MARK: - Debug Logging Helper

/// Writes debug info to a file for troubleshooting drag-and-drop
private func sidebarDebugLog(_ message: String) {
    let logFile = "/tmp/lungfish_sidebar_debug.log"
    let timestamp = ISO8601DateFormatter().string(from: Date())
    let line = "[\(timestamp)] \(message)\n"
    if let data = line.data(using: .utf8) {
        if FileManager.default.fileExists(atPath: logFile) {
            if let handle = FileHandle(forWritingAtPath: logFile) {
                handle.seekToEndOfFile()
                handle.write(data)
                handle.closeFile()
            }
        } else {
            FileManager.default.createFile(atPath: logFile, contents: data)
        }
    }
}

// MARK: - Custom Outline View for Drag Debugging

/// Custom NSOutlineView subclass that logs drag-and-drop events for debugging.
/// This helps identify if drags are reaching the outline view at all.
@MainActor
private class DebugOutlineView: NSOutlineView {
    
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        sidebarDebugLog("DebugOutlineView.draggingEntered called")
        sidebarDebugLog("  dataSource: \(String(describing: self.dataSource))")
        sidebarDebugLog("  delegate: \(String(describing: self.delegate))")
        sidebarDebugLog("  registeredDraggedTypes: \(self.registeredDraggedTypes)")
        sidebarDebugLog("  numberOfRows: \(self.numberOfRows)")
        let result = super.draggingEntered(sender)
        sidebarDebugLog("DebugOutlineView.draggingEntered returning: \(result.rawValue)")
        return result
    }
    
    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        // Don't log every update to avoid log spam
        return super.draggingUpdated(sender)
    }
    
    override func draggingExited(_ sender: NSDraggingInfo?) {
        sidebarDebugLog("DebugOutlineView.draggingExited called")
        super.draggingExited(sender)
    }
    
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        sidebarDebugLog("DebugOutlineView.performDragOperation called")
        let result = super.performDragOperation(sender)
        sidebarDebugLog("DebugOutlineView.performDragOperation returning: \(result)")
        return result
    }
    
    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
        sidebarDebugLog("DebugOutlineView.prepareForDragOperation called")
        let result = super.prepareForDragOperation(sender)
        sidebarDebugLog("DebugOutlineView.prepareForDragOperation returning: \(result)")
        return result
    }
    
    override func concludeDragOperation(_ sender: NSDraggingInfo?) {
        sidebarDebugLog("DebugOutlineView.concludeDragOperation called")
        super.concludeDragOperation(sender)
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
        // Register for file URL drags
        registerForDraggedTypes([.fileURL])
    }
    
    required init?(coder: NSCoder) {
        super.init(coder: coder)
        registerForDraggedTypes([.fileURL])
    }
    
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        sidebarDebugLog("SidebarDropTargetView.draggingEntered called")
        
        // Check if this drag contains file URLs
        let pasteboard = sender.draggingPasteboard
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty {
            // Check if at least one URL is a supported file type
            let hasSupported = urls.contains { url in
                // Import LungfishCore's DocumentType for type detection
                let ext = url.pathExtension.lowercased()
                let supportedExtensions = ["fasta", "fa", "fna", "ffn", "faa", "frn", "fas",
                                          "fastq", "fq", "gb", "gbk", "genbank", "gff", "gff3",
                                          "gtf", "bed", "vcf", "bam", "gz"]
                return supportedExtensions.contains(ext)
            }
            
            if hasSupported {
                sidebarDebugLog("SidebarDropTargetView.draggingEntered: ACCEPTING - has supported file types")
                return .copy
            }
        }
        
        sidebarDebugLog("SidebarDropTargetView.draggingEntered: REJECTING - no supported file types")
        return []
    }
    
    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        // Same logic as draggingEntered
        let pasteboard = sender.draggingPasteboard
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty {
            let hasSupported = urls.contains { url in
                let ext = url.pathExtension.lowercased()
                let supportedExtensions = ["fasta", "fa", "fna", "ffn", "faa", "frn", "fas",
                                          "fastq", "fq", "gb", "gbk", "genbank", "gff", "gff3",
                                          "gtf", "bed", "vcf", "bam", "gz"]
                return supportedExtensions.contains(ext)
            }
            if hasSupported {
                return .copy
            }
        }
        return []
    }
    
    override func draggingExited(_ sender: NSDraggingInfo?) {
        sidebarDebugLog("SidebarDropTargetView.draggingExited called")
    }
    
    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
        sidebarDebugLog("SidebarDropTargetView.prepareForDragOperation called")
        return true
    }
    
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        sidebarDebugLog("SidebarDropTargetView.performDragOperation called")
        
        let pasteboard = sender.draggingPasteboard
        guard let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty else {
            sidebarDebugLog("SidebarDropTargetView.performDragOperation: No URLs found")
            return false
        }
        
        sidebarDebugLog("SidebarDropTargetView.performDragOperation: Got \(urls.count) URLs")
        
        // Post notification for each dropped file
        for url in urls {
            sidebarDebugLog("SidebarDropTargetView.performDragOperation: Posting notification for '\(url.lastPathComponent)'")
            NotificationCenter.default.post(
                name: .sidebarFileDropped,
                object: self.sidebarController,
                userInfo: ["url": url, "destination": NSNull()]
            )
        }
        
        return true
    }
    
    override func concludeDragOperation(_ sender: NSDraggingInfo?) {
        sidebarDebugLog("SidebarDropTargetView.concludeDragOperation called")
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

        // Create outline view (using custom debug subclass to trace drag events)
        outlineView = DebugOutlineView()
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
        print("[SIDEBAR] reloadFromFilesystem CALLED")
        logger.info("reloadFromFilesystem: CALLED - starting filesystem scan")
        guard let projectURL = projectURL else {
            print("[SIDEBAR] No project URL set")
            logger.debug("reloadFromFilesystem: No project URL set")
            rootItems = []
            outlineView.reloadData()
            return
        }

        logger.info("reloadFromFilesystem: Scanning '\(projectURL.path, privacy: .public)'")

        // Save current selection to restore after reload
        let selectedURLs = selectedItems().compactMap { $0.url }

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

        let itemCount = rootItems.reduce(0) { $0 + countItems(in: $1) }
        print("[SIDEBAR] Sidebar updated with \(itemCount) items")
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
                } else {
                    // Only include supported file types
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
                itemType = .folder
                icon = "folder"
            } else {
                // Detect file type from extension
                let (type, iconName) = detectFileType(url: url)
                itemType = type
                icon = iconName
            }
        }

        // Create the item
        let item = SidebarItem(
            title: filename,
            type: itemType,
            icon: icon,
            children: [],
            url: url
        )

        // If it's a directory, scan children
        var isDirectory: ObjCBool = false
        if fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue {
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
                    } else {
                        // Only include supported file types
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
    private func detectFileType(url: URL) -> (SidebarItemType, String) {
        var ext = url.pathExtension.lowercased()

        // Handle gzip-compressed files
        if ext == "gz" {
            ext = url.deletingPathExtension().pathExtension.lowercased()
        }

        switch ext {
        case "fasta", "fa", "fna", "ffn", "faa", "frn", "fas":
            return (.sequence, "doc.text")
        case "fastq", "fq":
            return (.sequence, "doc.text")
        case "gb", "gbk", "genbank":
            return (.sequence, "doc.richtext")
        case "gff", "gff3", "gtf":
            return (.annotation, "list.bullet.rectangle")
        case "bed":
            return (.annotation, "list.bullet.rectangle")
        case "vcf":
            return (.annotation, "chart.bar.xaxis")
        case "bam", "sam", "cram":
            return (.alignment, "chart.bar")
        default:
            return (.sequence, "doc")
        }
    }

    /// Checks if a file extension is supported.
    private func isSupportedFileExtension(_ ext: String) -> Bool {
        let supported = [
            // Sequence formats
            "fasta", "fa", "fna", "ffn", "faa", "frn", "fas",
            "fastq", "fq",
            "gb", "gbk", "genbank",
            // Annotation formats
            "gff", "gff3", "gtf", "bed", "vcf",
            // Alignment formats
            "bam", "sam", "cram",
            // Compressed
            "gz"
        ]
        return supported.contains(ext)
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

    // MARK: - Legacy Methods (Deprecated)
    // These methods are kept for backwards compatibility but should not be used
    // with the new filesystem-backed model. They will be removed in a future version.

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

        // Determine the item type based on document type
        let itemType: SidebarItemType
        let icon: String
        switch document.type {
        case .fasta, .fastq:
            itemType = .sequence
            icon = "doc.text"
        case .genbank:
            itemType = .sequence
            icon = "doc.richtext"
        case .gff3, .bed:
            itemType = .annotation
            icon = "list.bullet.rectangle"
        case .vcf:
            itemType = .annotation
            icon = "chart.bar.xaxis"
        case .bam:
            itemType = .alignment
            icon = "chart.bar"
        case .lungfishProject:
            itemType = .sequence
            icon = "folder.badge.gearshape"
        }

        // Check if document already exists in sidebar
        if openDocsGroup!.children.contains(where: { $0.url == document.url }) {
            logger.debug("addLoadedDocument: Document already in sidebar")
            return
        }

        // Create the sidebar item
        let item = SidebarItem(
            title: document.name,
            type: itemType,
            icon: icon,
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
    /// This method places downloaded files (like NCBI downloads) into a "downloads" subfolder
    /// within the project structure, rather than the "OPEN DOCUMENTS" group.
    ///
    /// - Parameters:
    ///   - document: The loaded document to add
    ///   - projectURL: The project folder URL (if available)
    public func addDownloadedDocument(_ document: LoadedDocument, projectURL: URL?) {
        logger.info("addDownloadedDocument: Adding '\(document.name, privacy: .public)' to downloads folder")

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

        // Find or create the "downloads" folder within the project
        var downloadsFolder = projectItem.children.first(where: {
            $0.title.lowercased() == "downloads" && $0.type == .folder
        })

        if downloadsFolder == nil {
            logger.debug("addDownloadedDocument: Creating downloads folder")
            let downloadsURL = projectItem.url?.appendingPathComponent("downloads", isDirectory: true)
            downloadsFolder = SidebarItem(
                title: "downloads",
                type: .folder,
                icon: "arrow.down.circle",
                children: [],
                url: downloadsURL
            )

            // Insert downloads folder at the beginning of project children (after other folders)
            let firstNonFolderIndex = projectItem.children.firstIndex(where: { $0.type != .folder }) ?? projectItem.children.count
            projectItem.children.insert(downloadsFolder!, at: firstNonFolderIndex)
        }

        // Determine the item type based on document type
        let itemType: SidebarItemType
        let icon: String
        switch document.type {
        case .fasta, .fastq:
            itemType = .sequence
            icon = "doc.text"
        case .genbank:
            itemType = .sequence
            icon = "doc.richtext"
        case .gff3, .bed:
            itemType = .annotation
            icon = "list.bullet.rectangle"
        case .vcf:
            itemType = .annotation
            icon = "chart.bar.xaxis"
        case .bam:
            itemType = .alignment
            icon = "chart.bar"
        case .lungfishProject:
            itemType = .sequence
            icon = "folder.badge.gearshape"
        }

        // Check if document already exists in downloads folder
        if downloadsFolder!.children.contains(where: { $0.url == document.url }) {
            logger.debug("addDownloadedDocument: Document already in downloads folder")
            return
        }

        // Create the sidebar item for the downloaded document
        let item = SidebarItem(
            title: document.name,
            type: itemType,
            icon: icon,
            children: [],
            url: document.url
        )

        downloadsFolder!.children.append(item)
        logger.info("addDownloadedDocument: Added '\(document.name, privacy: .public)' to downloads folder, reloading")

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

            // Determine item type based on document type
            let itemType: SidebarItemType
            let icon: String
            switch document.type {
            case .fasta, .fastq:
                itemType = .sequence
                icon = "doc.text"
            case .genbank:
                itemType = .sequence
                icon = "doc.richtext"
            case .gff3, .bed:
                itemType = .annotation
                icon = "list.bullet.rectangle"
            case .vcf:
                itemType = .annotation
                icon = "chart.bar.xaxis"
            case .bam:
                itemType = .alignment
                icon = "chart.bar"
            case .lungfishProject:
                itemType = .sequence
                icon = "folder.badge.gearshape"
            }

            // Create document item
            let docItem = SidebarItem(
                title: document.name,
                type: itemType,
                icon: icon,
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
        
        // Determine item type based on document type
        let itemType: SidebarItemType
        let icon: String
        switch document.type {
        case .fasta, .fastq:
            itemType = .sequence
            icon = "doc.text"
        case .genbank:
            itemType = .sequence
            icon = "doc.richtext"
        case .gff3, .bed:
            itemType = .annotation
            icon = "list.bullet.rectangle"
        case .vcf:
            itemType = .annotation
            icon = "chart.bar.xaxis"
        case .bam:
            itemType = .alignment
            icon = "chart.bar"
        case .lungfishProject:
            itemType = .sequence
            icon = "folder.badge.gearshape"
        }
        
        // Create document item
        let docItem = SidebarItem(
            title: document.name,
            type: itemType,
            icon: icon,
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
            // For internal drags, only allow dropping into folders or projects
            guard let dest = destinationItem else {
                // Dropping at root level - not allowed for internal items
                return []
            }

            // Can only drop into folders or projects
            if dest.type != .folder && dest.type != .project {
                return []
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

    /// Writes debug info to a file for troubleshooting (wrapper for shared helper)
    private func debugLog(_ message: String) {
        sidebarDebugLog("SidebarVC: \(message)")
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
            guard let sourceItem = findItem(byPath: identifierString) else {
                logger.warning("acceptDrop: Could not find source item with path '\(identifierString, privacy: .public)'")
                return false
            }

            guard let dest = destinationItem, (dest.type == .folder || dest.type == .project) else {
                logger.warning("acceptDrop: Invalid destination for internal drag")
                return false
            }

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
        // Get ALL selected items for multi-selection support
        let items = selectedItems()

        if items.isEmpty {
            // Post notification with empty items to signal viewer should be cleared
            logger.debug("outlineViewSelectionDidChange: Selection cleared")
            NotificationCenter.default.post(
                name: .sidebarSelectionChanged,
                object: self,
                userInfo: ["items": [] as [SidebarItem]]
            )
            return
        }

        // Log all selected items
        let itemNames = items.map { $0.title }.joined(separator: ", ")
        logger.info("outlineViewSelectionDidChange: Selected \(items.count) items: [\(itemNames, privacy: .public)]")

        // Post notification with ALL selected items
        // Include both "item" (for backward compatibility) and "items" (for multi-selection)
        NotificationCenter.default.post(
            name: .sidebarSelectionChanged,
            object: self,
            userInfo: [
                "item": items.first as Any,  // First item for backward compatibility
                "items": items               // All items for multi-selection support
            ]
        )
        logger.debug("outlineViewSelectionDidChange: Posted notification with \(items.count) items")
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

    var tintColor: NSColor {
        switch self {
        case .group: return .secondaryLabelColor
        case .folder: return .systemBlue
        case .sequence: return .systemGreen
        case .annotation: return .systemOrange
        case .alignment: return .systemPurple
        case .coverage: return .systemTeal
        case .project: return .systemGray
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

        guard !items.isEmpty else {
            // No selection - show minimal menu
            let noSelectionItem = NSMenuItem(title: "No Selection", action: nil, keyEquivalent: "")
            noSelectionItem.isEnabled = false
            menu.addItem(noSelectionItem)
            return
        }

        // Check what types we have selected
        let hasFiles = items.contains { $0.type != .group && $0.type != .project && $0.type != .folder }
        let hasFolders = items.contains { $0.type == .folder || $0.type == .project }
        let hasGroups = items.contains { $0.type == .group }
        let hasDeletable = items.contains { $0.type != .group && $0.type != .project }

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

    @objc private func contextMenuNewFolder(_ sender: Any?) {
        // Determine where to create the folder
        let parentURL: URL
        let items = selectedItems()
        
        if let item = items.first, (item.type == .folder || item.type == .project), let url = item.url {
            // Create inside the selected folder/project
            parentURL = url
        } else if let project = projectURL {
            // Create at project root
            parentURL = project
        } else {
            logger.warning("contextMenuNewFolder: No valid location to create folder")
            return
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
