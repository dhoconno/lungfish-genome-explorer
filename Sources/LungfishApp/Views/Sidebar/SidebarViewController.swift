// SidebarViewController.swift - Project navigation sidebar
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import LungfishCore

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
        outlineView.selectionHighlightStyle = .sourceList
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
        NSLayoutConstraint.activate([
            searchField.topAnchor.constraint(equalTo: containerView.topAnchor, constant: 8),
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
        // Create sample hierarchy for demonstration
        let favoritesGroup = SidebarItem(
            title: "FAVORITES",
            type: .group,
            children: [
                SidebarItem(title: "Recent Projects", type: .folder, icon: "clock"),
                SidebarItem(title: "My Sequences", type: .folder, icon: "folder"),
            ]
        )

        let projectGroup = SidebarItem(
            title: "PROJECT",
            type: .group,
            children: [
                SidebarItem(
                    title: "Reference Sequences",
                    type: .folder,
                    icon: "folder",
                    children: [
                        SidebarItem(title: "chr1.fa", type: .sequence, icon: "doc.text"),
                        SidebarItem(title: "chr2.fa", type: .sequence, icon: "doc.text"),
                    ]
                ),
                SidebarItem(
                    title: "Annotations",
                    type: .folder,
                    icon: "folder",
                    children: [
                        SidebarItem(title: "genes.gff3", type: .annotation, icon: "list.bullet.rectangle"),
                    ]
                ),
                SidebarItem(
                    title: "Alignments",
                    type: .folder,
                    icon: "folder",
                    children: [
                        SidebarItem(title: "reads.bam", type: .alignment, icon: "chart.bar"),
                    ]
                ),
            ]
        )

        rootItems = [favoritesGroup, projectGroup]
        outlineView.reloadData()

        // Expand top-level groups
        for item in rootItems {
            outlineView.expandItem(item)
        }
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
            return
        }

        // Notify about selection change
        NotificationCenter.default.post(
            name: .sidebarSelectionChanged,
            object: self,
            userInfo: ["item": item]
        )
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
