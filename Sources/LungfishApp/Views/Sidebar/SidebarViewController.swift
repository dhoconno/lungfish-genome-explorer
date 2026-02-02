// SidebarViewController.swift - Project navigation sidebar
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import LungfishCore
import os.log

/// Logger for sidebar operations
private let logger = Logger(subsystem: "com.lungfish.browser", category: "SidebarViewController")

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
        outlineView.dataSource = self
        outlineView.delegate = self

        // Create name column
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("NameColumn"))
        column.isEditable = false
        column.resizingMask = .autoresizingMask
        outlineView.addTableColumn(column)
        outlineView.outlineTableColumn = column

        // Enable drag and drop
        outlineView.registerForDraggedTypes([.fileURL])
        outlineView.setDraggingSourceOperationMask(.every, forLocal: false)

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
        let selectedRow = outlineView.selectedRow
        guard selectedRow >= 0,
              let item = outlineView.item(atRow: selectedRow) as? SidebarItem else {
            logger.debug("outlineViewSelectionDidChange: No valid selection")
            return
        }

        logger.info("outlineViewSelectionDidChange: Selected '\(item.title, privacy: .public)' type=\(String(describing: item.type)) url=\(item.url?.path ?? "nil", privacy: .public)")

        // Notify about selection change
        NotificationCenter.default.post(
            name: .sidebarSelectionChanged,
            object: self,
            userInfo: ["item": item]
        )
        logger.debug("outlineViewSelectionDidChange: Posted notification")
    }
}

// MARK: - SidebarItem Model

/// Represents an item in the sidebar hierarchy
public class SidebarItem: NSObject {
    public let title: String
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

// MARK: - Notifications

public extension Notification.Name {
    static let sidebarSelectionChanged = Notification.Name("SidebarSelectionChanged")
}
