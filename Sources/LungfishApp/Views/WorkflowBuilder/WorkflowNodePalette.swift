// WorkflowNodePalette.swift - Node palette for workflow builder
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import LungfishWorkflow
import os.log

/// Logger for palette operations
private let logger = Logger(subsystem: "com.lungfish.browser", category: "WorkflowNodePalette")

// MARK: - WorkflowNodePalette

/// A sidebar view displaying available workflow node types organized by category.
///
/// Features:
/// - Hierarchical outline view with categories
/// - Search/filter functionality
/// - Drag source for canvas placement
/// - SF Symbols icons for each node type
@MainActor
public class WorkflowNodePalette: NSView {

    // MARK: - Properties

    /// The outline view displaying node types.
    private var outlineView: NSOutlineView!

    /// Scroll view containing the outline view.
    private var scrollView: NSScrollView!

    /// Search field for filtering.
    private var searchField: NSSearchField!

    /// The data model for the outline view.
    private var categories: [PaletteCategory] = []

    /// Filtered data based on search.
    private var filteredCategories: [PaletteCategory] = []

    /// Current search text.
    private var searchText: String = ""

    // MARK: - Data Model

    private struct PaletteCategory {
        let category: NodeCategory
        var items: [WorkflowNodeType]
    }

    // MARK: - Initialization

    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        commonInit()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        commonInit()
    }

    private func commonInit() {
        wantsLayer = true

        buildDataModel()
        setupSearchField()
        setupOutlineView()
        setupAccessibility()

        logger.info("WorkflowNodePalette initialized")
    }

    // MARK: - Data Model

    private func buildDataModel() {
        // Group node types by category
        var categoryMap: [NodeCategory: [WorkflowNodeType]] = [:]

        for nodeType in WorkflowNodeType.allCases {
            categoryMap[nodeType.category, default: []].append(nodeType)
        }

        // Build ordered categories
        categories = NodeCategory.allCases.compactMap { category in
            guard let items = categoryMap[category], !items.isEmpty else { return nil }
            return PaletteCategory(category: category, items: items)
        }

        filteredCategories = categories
    }

    // MARK: - UI Setup

    private func setupSearchField() {
        searchField = NSSearchField()
        searchField.translatesAutoresizingMaskIntoConstraints = false
        searchField.placeholderString = "Filter nodes"
        searchField.sendsSearchStringImmediately = true
        searchField.target = self
        searchField.action = #selector(searchFieldChanged(_:))
        searchField.setAccessibilityIdentifier("workflow-palette-search")
        addSubview(searchField)
    }

    private func setupOutlineView() {
        // Create outline view
        outlineView = NSOutlineView()
        outlineView.headerView = nil
        outlineView.rowHeight = 28
        outlineView.indentationPerLevel = 16
        outlineView.autoresizesOutlineColumn = true
        outlineView.floatsGroupRows = false
        outlineView.rowSizeStyle = .default
        outlineView.style = .sourceList
        outlineView.dataSource = self
        outlineView.delegate = self

        // Create column
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("NodeColumn"))
        column.isEditable = false
        column.resizingMask = .autoresizingMask
        outlineView.addTableColumn(column)
        outlineView.outlineTableColumn = column

        // Enable drag source
        outlineView.setDraggingSourceOperationMask(.copy, forLocal: false)

        // Create scroll view
        scrollView = NSScrollView()
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.documentView = outlineView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false
        addSubview(scrollView)

        // Layout
        NSLayoutConstraint.activate([
            searchField.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            searchField.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            searchField.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),

            scrollView.topAnchor.constraint(equalTo: searchField.bottomAnchor, constant: 8),
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])

        // Expand all categories by default
        for category in filteredCategories {
            outlineView.expandItem(category.category)
        }
    }

    private func setupAccessibility() {
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Node palette")
        setAccessibilityIdentifier("workflow-node-palette")
    }

    // MARK: - Search

    @objc private func searchFieldChanged(_ sender: NSSearchField) {
        searchText = sender.stringValue.lowercased()

        if searchText.isEmpty {
            filteredCategories = categories
        } else {
            filteredCategories = categories.compactMap { category in
                let filteredItems = category.items.filter { nodeType in
                    nodeType.displayName.lowercased().contains(self.searchText)
                }
                guard !filteredItems.isEmpty else { return nil }
                return PaletteCategory(category: category.category, items: filteredItems)
            }
        }

        outlineView.reloadData()

        // Expand all when searching
        if !searchText.isEmpty {
            for category in filteredCategories {
                outlineView.expandItem(category.category)
            }
        }

        let resultCount = self.filteredCategories.flatMap { $0.items }.count
        logger.debug("Filtered nodes with: '\(self.searchText)' - \(resultCount) results")
    }
}

// MARK: - NSOutlineViewDataSource

extension WorkflowNodePalette: NSOutlineViewDataSource {

    public func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        if item == nil {
            return filteredCategories.count
        }

        if let category = item as? NodeCategory {
            return filteredCategories.first { $0.category == category }?.items.count ?? 0
        }

        return 0
    }

    public func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        if item == nil {
            return filteredCategories[index].category
        }

        if let category = item as? NodeCategory,
           let paletteCategory = filteredCategories.first(where: { $0.category == category }) {
            return paletteCategory.items[index]
        }

        fatalError("Unexpected item type")
    }

    public func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        return item is NodeCategory
    }

    // MARK: - Drag Source

    public func outlineView(
        _ outlineView: NSOutlineView,
        pasteboardWriterForItem item: Any
    ) -> NSPasteboardWriting? {
        guard let nodeType = item as? WorkflowNodeType else { return nil }

        let pasteboardItem = NSPasteboardItem()
        pasteboardItem.setString(nodeType.rawValue, forType: .workflowNodeType)

        return pasteboardItem
    }

    public func outlineView(
        _ outlineView: NSOutlineView,
        draggingSession session: NSDraggingSession,
        willBeginAt screenPoint: NSPoint,
        forItems draggedItems: [Any]
    ) {
        logger.debug("Drag session started for \(draggedItems.count) items")
    }
}

// MARK: - NSOutlineViewDelegate

extension WorkflowNodePalette: NSOutlineViewDelegate {

    public func outlineView(
        _ outlineView: NSOutlineView,
        viewFor tableColumn: NSTableColumn?,
        item: Any
    ) -> NSView? {
        let identifier = NSUserInterfaceItemIdentifier("PaletteCell")

        if let category = item as? NodeCategory {
            // Category header
            var cellView = outlineView.makeView(withIdentifier: identifier, owner: self) as? NSTableCellView
            if cellView == nil {
                cellView = createCellView(identifier: identifier)
            }

            cellView?.textField?.stringValue = category.displayName.uppercased()
            cellView?.textField?.font = NSFont.systemFont(ofSize: 11, weight: .semibold)
            cellView?.textField?.textColor = .secondaryLabelColor
            cellView?.imageView?.image = NSImage(
                systemSymbolName: category.iconName,
                accessibilityDescription: category.displayName
            )
            cellView?.imageView?.contentTintColor = .secondaryLabelColor

            return cellView
        }

        if let nodeType = item as? WorkflowNodeType {
            // Node type item
            var cellView = outlineView.makeView(withIdentifier: identifier, owner: self) as? NSTableCellView
            if cellView == nil {
                cellView = createCellView(identifier: identifier)
            }

            cellView?.textField?.stringValue = nodeType.displayName
            cellView?.textField?.font = NSFont.systemFont(ofSize: 13)
            cellView?.textField?.textColor = .labelColor
            cellView?.imageView?.image = NSImage(
                systemSymbolName: nodeType.iconName,
                accessibilityDescription: nodeType.displayName
            )
            cellView?.imageView?.contentTintColor = colorForCategory(nodeType.category)

            return cellView
        }

        return nil
    }

    private func createCellView(identifier: NSUserInterfaceItemIdentifier) -> NSTableCellView {
        let cellView = NSTableCellView()
        cellView.identifier = identifier

        let imageView = NSImageView()
        imageView.translatesAutoresizingMaskIntoConstraints = false
        imageView.imageScaling = .scaleProportionallyDown
        cellView.addSubview(imageView)
        cellView.imageView = imageView

        let textField = NSTextField(labelWithString: "")
        textField.translatesAutoresizingMaskIntoConstraints = false
        textField.lineBreakMode = .byTruncatingTail
        cellView.addSubview(textField)
        cellView.textField = textField

        NSLayoutConstraint.activate([
            imageView.leadingAnchor.constraint(equalTo: cellView.leadingAnchor, constant: 4),
            imageView.centerYAnchor.constraint(equalTo: cellView.centerYAnchor),
            imageView.widthAnchor.constraint(equalToConstant: 18),
            imageView.heightAnchor.constraint(equalToConstant: 18),

            textField.leadingAnchor.constraint(equalTo: imageView.trailingAnchor, constant: 6),
            textField.trailingAnchor.constraint(equalTo: cellView.trailingAnchor, constant: -4),
            textField.centerYAnchor.constraint(equalTo: cellView.centerYAnchor)
        ])

        return cellView
    }

    public func outlineView(_ outlineView: NSOutlineView, isGroupItem item: Any) -> Bool {
        return item is NodeCategory
    }

    public func outlineView(_ outlineView: NSOutlineView, shouldSelectItem item: Any) -> Bool {
        // Only allow selecting node types, not categories
        return item is WorkflowNodeType
    }

    private func colorForCategory(_ category: NodeCategory) -> NSColor {
        switch category {
        case .input:
            return .systemBlue
        case .preprocessing:
            return .systemOrange
        case .analysis:
            return .systemPurple
        case .output:
            return .systemGreen
        }
    }
}

// MARK: - Tooltip Support

extension WorkflowNodePalette {

    public func view(
        _ view: NSView,
        stringForToolTip tag: NSView.ToolTipTag,
        point: NSPoint,
        userData data: UnsafeMutableRawPointer?
    ) -> String {
        // Get row at point
        let row = outlineView.row(at: convert(point, to: outlineView))
        guard row >= 0,
              let nodeType = outlineView.item(atRow: row) as? WorkflowNodeType else {
            return ""
        }

        var tooltip = nodeType.displayName
        tooltip += "\n\nInputs:"
        if nodeType.inputPorts.isEmpty {
            tooltip += "\n  (none)"
        } else {
            for port in nodeType.inputPorts {
                tooltip += "\n  - \(port.name) (\(port.dataType.displayName))"
            }
        }

        tooltip += "\n\nOutputs:"
        if nodeType.outputPorts.isEmpty {
            tooltip += "\n  (none)"
        } else {
            for port in nodeType.outputPorts {
                tooltip += "\n  - \(port.name) (\(port.dataType.displayName))"
            }
        }

        return tooltip
    }
}
