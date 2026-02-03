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

    // MARK: - Lifecycle

    public override func loadView() {
        // Create the main container view
        let containerView = NSView()
        containerView.translatesAutoresizingMaskIntoConstraints = false

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
                  self.view.window?.firstResponder === self.outlineView else {
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

    /// Validates whether a drop is allowed at the proposed location
    public func outlineView(_ outlineView: NSOutlineView, validateDrop info: NSDraggingInfo, proposedItem item: Any?, proposedChildIndex index: Int) -> NSDragOperation {
        // Get the destination item
        let destinationItem = item as? SidebarItem

        // Determine if this is an internal drag
        let isInternalDrag = info.draggingPasteboard.availableType(from: [sidebarItemPasteboardType]) != nil

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
            // External file drop - allow dropping into folders, projects, or root
            if let dest = destinationItem {
                if dest.type == .folder || dest.type == .project || dest.type == .group {
                    logger.debug("validateDrop: External file - into '\(dest.title, privacy: .public)'")
                    return .copy
                }
                return []
            }
            // Allow drop at root level for external files
            logger.debug("validateDrop: External file - at root level")
            return .copy
        }
    }

    /// Performs the actual drop operation
    public func outlineView(_ outlineView: NSOutlineView, acceptDrop info: NSDraggingInfo, item: Any?, childIndex index: Int) -> Bool {
        let pasteboard = info.draggingPasteboard
        let destinationItem = item as? SidebarItem

        // Check if this is an internal drag
        if let _ = pasteboard.availableType(from: [sidebarItemPasteboardType]),
           let identifierString = pasteboard.string(forType: sidebarItemPasteboardType) {

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
        if let fileURLs = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] {
            logger.info("acceptDrop: Accepting \(fileURLs.count) external files")

            for url in fileURLs {
                // Post notification to load the file
                NotificationCenter.default.post(
                    name: .sidebarFileDropped,
                    object: self,
                    userInfo: ["url": url, "destination": destinationItem as Any]
                )
            }
            return true
        }

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

        // Find and remove from source parent
        if let sourceParent = findParent(of: sourceItem) {
            sourceParent.children.removeAll { $0 === sourceItem }
        } else {
            // Item is at root level
            rootItems.removeAll { $0 === sourceItem }
        }

        // Add to destination
        let insertIndex = index >= 0 ? min(index, destination.children.count) : destination.children.count
        destination.children.insert(sourceItem, at: insertIndex)

        // Move the actual file if URL exists
        if let sourceURL = sourceItem.url, let destFolderURL = destination.url {
            let destURL = destFolderURL.appendingPathComponent(sourceURL.lastPathComponent)
            do {
                try FileManager.default.moveItem(at: sourceURL, to: destURL)
                sourceItem.url = destURL
                logger.info("moveItem: File moved from \(sourceURL.path, privacy: .public) to \(destURL.path, privacy: .public)")
            } catch {
                logger.error("moveItem: Failed to move file - \(error.localizedDescription, privacy: .public)")
                // Revert the sidebar change if file move fails
                // (simplified - in production would need full rollback)
            }
        }

        outlineView.reloadData()
        outlineView.expandItem(destination)

        return true
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
        } catch {
            logger.error("copyItem: Failed to copy file - \(error.localizedDescription, privacy: .public)")
            return false
        }

        // Create a new sidebar item for the copy
        let copyItem = SidebarItem(
            title: destURL.lastPathComponent,
            type: sourceItem.type,
            icon: sourceItem.icon,
            children: [],
            url: destURL
        )

        // Add to destination
        let insertIndex = index >= 0 ? min(index, destination.children.count) : destination.children.count
        destination.children.insert(copyItem, at: insertIndex)

        outlineView.reloadData()
        outlineView.expandItem(destination)

        return true
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

        // Duplicate (files only)
        if hasFiles && !hasFolders && !hasGroups {
            let duplicateItem = NSMenuItem(title: "Duplicate", action: #selector(contextMenuDuplicate(_:)), keyEquivalent: "")
            duplicateItem.target = self
            menu.addItem(duplicateItem)
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
            // Item has no URL, just update the title
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
            item.url = newURL
            item.title = newFilename
            outlineView.reloadData()
            logger.info("performRename: Renamed to '\(newFilename, privacy: .public)'")
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
            guard let url = item.url, let parent = findParent(of: item) else { continue }

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

                // Create sidebar item for the copy
                let copyItem = SidebarItem(
                    title: newURL.lastPathComponent,
                    type: item.type,
                    icon: item.icon,
                    children: [],
                    url: newURL
                )
                parent.children.append(copyItem)
                logger.info("contextMenuDuplicate: Created '\(newURL.lastPathComponent, privacy: .public)'")
            } catch {
                logger.error("contextMenuDuplicate: Failed - \(error.localizedDescription, privacy: .public)")
            }
        }

        outlineView.reloadData()
    }
}

// MARK: - Notifications

public extension Notification.Name {
    static let sidebarSelectionChanged = Notification.Name("SidebarSelectionChanged")
    static let sidebarFileDropped = Notification.Name("SidebarFileDropped")
    static let sidebarItemsDeleted = Notification.Name("SidebarItemsDeleted")
}
