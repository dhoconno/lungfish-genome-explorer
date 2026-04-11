// TaxonomyTableView.swift - Hierarchical taxonomy table with NSOutlineView
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import LungfishIO

// MARK: - TaxonomyTableView

/// A hierarchical taxonomy table using `NSOutlineView` for browsing classification results.
///
/// Displays the taxonomy tree as an expandable table with columns for taxon name
/// (with colored phylum dot), rank, direct reads, clade reads, and percentage.
/// Supports sorting, searching/filtering, and selection synchronization with the
/// sunburst chart.
///
/// ## Columns
///
/// | Column | Content |
/// |--------|---------|
/// | Taxon Name | Name with colored phylum indicator dot |
/// | Rank | Taxonomic rank (Domain, Phylum, etc.) |
/// | Reads | Direct read count |
/// | Clade | Cumulative clade count |
/// | % | Clade reads as percent of classified |
///
/// ## Keyboard Shortcuts
///
/// In addition to NSOutlineView's built-in Left/Right arrow expand/collapse:
/// - **Option+Right Arrow**: Expand selected item and all its children recursively
/// - **Cmd+Shift+Right Arrow**: Expand all items in the tree
/// - **Cmd+Shift+Left Arrow**: Collapse all items in the tree
///
/// ## Usage
///
/// ```swift
/// let tableView = TaxonomyTableView()
/// tableView.tree = parsedTree
/// tableView.onNodeSelected = { node in
///     sunburst.selectedNode = node
/// }
/// ```
@MainActor
public class TaxonomyTableView: NSView, NSOutlineViewDataSource, NSOutlineViewDelegate, NSMenuItemValidation {

    // MARK: - Metadata Columns

    /// Controller for dynamic sample metadata columns (from imported CSV/TSV).
    let metadataColumns = MetadataColumnController()

    // MARK: - Data Properties

    /// The taxonomy tree to display.
    ///
    /// Setting this property reloads the outline view.
    public var tree: TaxonTree? {
        didSet {
            filterText = ""
            filteredNodeIDs = nil
            reloadData()
        }
    }

    /// The currently selected node.
    ///
    /// Setting this property programmatically scrolls the outline view to the node.
    /// Use `_selectedNode` directly when you need to clear the tracked node
    /// without triggering a programmatic selection change (e.g., during multi-select).
    public var selectedNode: TaxonNode? {
        get { _selectedNode }
        set {
            _selectedNode = newValue
            selectRowForNode(newValue)
        }
    }
    private var _selectedNode: TaxonNode?

    /// Called when the user selects a row.
    public var onNodeSelected: ((TaxonNode) -> Void)?

    /// Called when multiple rows are selected. Parameter is the count.
    public var onMultipleNodesSelected: ((Int) -> Void)?

    /// Fired when the user invokes "Extract Reads…" from the context menu or
    /// the action bar. The VC reads the current selection from the table view
    /// itself via `outlineView.selectedRowIndexes`.
    public var onExtractReadsRequested: (() -> Void)?

    /// Called when the search filter changes.
    ///
    /// The parameter is the set of taxId values currently passing the filter
    /// (including both direct matches and their ancestors), or `nil` when the
    /// filter is cleared. Consumers such as the sunburst chart can use this to
    /// dim excluded taxa.
    public var onFilterChanged: ((Set<Int>?) -> Void)?

    /// Called when the user right-clicks and selects an NCBI link or BLAST.
    public var onNCBITaxonomyRequested: ((TaxonNode) -> Void)?
    public var onNCBIGenBankRequested: ((TaxonNode) -> Void)?
    public var onNCBIPubMedRequested: ((TaxonNode) -> Void)?
    public var onBlastRequested: ((TaxonNode) -> Void)?

    /// Fallback sample ID to show in the "Sample" column when displaying a
    /// single-sample tree (no synthetic sample grouping nodes).
    public var currentSampleID: String?

    // MARK: - Search / Filter

    /// Current filter text. Empty string means no filter.
    private var filterText: String = "" {
        didSet {
            if filterText != oldValue {
                applyFilter()
            }
        }
    }

    /// Set of node identities that match the current filter (or their ancestors).
    private var filteredNodeIDs: Set<ObjectIdentifier>?

    /// Nodes that directly match the filter (not just ancestors).
    private var directMatchNodeIDs: Set<ObjectIdentifier> = []

    // MARK: - Sort State

    /// Current sort descriptor (nil = default: clade descending).
    private var currentSortKey: String = ColumnID.reads
    private var currentSortAscending: Bool = false

    // MARK: - Per-Column Filters

    /// Per-column filters applied via column header click menus.
    private var columnFilters: [String: ColumnFilter] = [:]

    /// Original column titles before filter indicators were appended.
    private var originalColumnTitles: [String: String] = [:]

    /// Refreshes the outline view and updates column header filter indicators.
    private func reloadDataAndUpdateFilterIndicators() {
        outlineView.reloadData()
        ColumnFilter.updateColumnTitleIndicators(
            columns: outlineView.tableColumns,
            filters: columnFilters,
            originalTitles: &originalColumnTitles
        )
        outlineView.headerView?.needsDisplay = true
    }

    /// Column type hints — true = numeric, false = text.
    private let columnTypes: [String: Bool] = [
        ColumnID.sample: false,
        ColumnID.name: false,
        ColumnID.rank: false,
        ColumnID.reads: true,
        ColumnID.clade: true,
        ColumnID.percent: true,
    ]

    // MARK: - Suppression Flag

    /// When true, programmatic selection changes don't fire the delegate callback.
    /// Prevents infinite loops when syncing selection between sunburst and table.
    private var suppressSelectionCallback = false

    // MARK: - Subviews

    private let scrollView = NSScrollView()
    internal let outlineView = TaxonomyOutlineView()
    private let searchField = NSSearchField()
    private let countLabel = NSTextField(labelWithString: "")

    // MARK: - Column Identifiers

    private enum ColumnID {
        static let sample = "sample"
        static let name = "name"
        static let rank = "rank"
        static let reads = "reads"
        static let clade = "clade"
        static let percent = "percent"
    }

    // MARK: - Initialization

    public override init(frame: NSRect) {
        super.init(frame: frame)
        commonInit()
    }

    public required init?(coder: NSCoder) {
        super.init(coder: coder)
        commonInit()
    }

    private func commonInit() {
        setupSearchField()
        setupOutlineView()
        setupLayout()
    }

    // MARK: - Setup

    private func setupSearchField() {
        searchField.translatesAutoresizingMaskIntoConstraints = false
        searchField.placeholderString = "Filter taxa..."
        searchField.target = self
        searchField.action = #selector(searchFieldChanged(_:))
        searchField.sendsSearchStringImmediately = true
        searchField.font = .systemFont(ofSize: 12)
        addSubview(searchField)

        countLabel.translatesAutoresizingMaskIntoConstraints = false
        countLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        countLabel.textColor = .secondaryLabelColor
        countLabel.alignment = .right
        countLabel.setContentHuggingPriority(.defaultHigh, for: .horizontal)
        addSubview(countLabel)
    }

    private func setupOutlineView() {
        // Sample column
        let sampleCol = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(ColumnID.sample))
        sampleCol.title = "Sample"
        sampleCol.minWidth = 90
        sampleCol.width = 130
        sampleCol.sortDescriptorPrototype = NSSortDescriptor(key: ColumnID.sample, ascending: true)
        outlineView.addTableColumn(sampleCol)

        // Name column (flexible width)
        let nameCol = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(ColumnID.name))
        nameCol.title = "Taxon Name"
        nameCol.minWidth = 140
        nameCol.width = 200
        nameCol.sortDescriptorPrototype = NSSortDescriptor(key: ColumnID.name, ascending: true)
        outlineView.addTableColumn(nameCol)

        // Rank column
        let rankCol = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(ColumnID.rank))
        rankCol.title = "Rank"
        rankCol.width = 70
        rankCol.minWidth = 50
        rankCol.sortDescriptorPrototype = NSSortDescriptor(key: ColumnID.rank, ascending: true)
        outlineView.addTableColumn(rankCol)

        // Reads column -- shows CLADE count (all reads in this taxon + descendants)
        // This is what users expect: "how many reads belong to this group?"
        let readsCol = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(ColumnID.reads))
        readsCol.title = "Reads"
        readsCol.width = 80
        readsCol.minWidth = 50
        readsCol.sortDescriptorPrototype = NSSortDescriptor(key: ColumnID.reads, ascending: false)
        outlineView.addTableColumn(readsCol)

        // Direct column -- shows reads classified directly to this taxon (not descendants)
        let cladeCol = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(ColumnID.clade))
        cladeCol.title = "Direct"
        cladeCol.width = 80
        cladeCol.minWidth = 50
        cladeCol.sortDescriptorPrototype = NSSortDescriptor(key: ColumnID.clade, ascending: false)
        outlineView.addTableColumn(cladeCol)

        // Percent column
        let pctCol = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(ColumnID.percent))
        pctCol.title = "%"
        pctCol.width = 55
        pctCol.minWidth = 40
        pctCol.sortDescriptorPrototype = NSSortDescriptor(key: ColumnID.percent, ascending: false)
        outlineView.addTableColumn(pctCol)

        outlineView.outlineTableColumn = nameCol
        outlineView.dataSource = self
        outlineView.delegate = self
        outlineView.menu = buildContextMenu()
        outlineView.usesAlternatingRowBackgroundColors = true
        outlineView.rowHeight = 22
        outlineView.allowsColumnReordering = false
        outlineView.allowsMultipleSelection = true
        outlineView.headerView = NSTableHeaderView()
        outlineView.indentationPerLevel = 16

        // Wire the outline view's keyboard handler to this table view
        outlineView.taxonomyTableView = self

        // Install metadata column controller for dynamic sample metadata columns.
        metadataColumns.standardColumnNames = [
            "Sample", "Taxon Name", "Rank", "Reads", "Direct", "%",
        ]
        metadataColumns.install(on: outlineView)

        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.documentView = outlineView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        addSubview(scrollView)
    }

    private func setupLayout() {
        // Use .defaultHigh priority for padding/spacing constraints so they
        // don't conflict with NSAutoresizingMaskLayoutConstraint (required
        // priority) when the NSSplitView container starts at zero size during
        // initial layout. Once the container has real bounds the constraints
        // are always satisfiable.
        let searchTop = searchField.topAnchor.constraint(equalTo: topAnchor, constant: 4)
        let searchLeading = searchField.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8)
        let searchHeight = searchField.heightAnchor.constraint(equalToConstant: 24)
        let labelGap = countLabel.leadingAnchor.constraint(equalTo: searchField.trailingAnchor, constant: 8)
        let labelTrailing = countLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8)
        let scrollBottom = scrollView.bottomAnchor.constraint(equalTo: bottomAnchor)

        for c in [searchTop, searchLeading, searchHeight, labelGap, labelTrailing, scrollBottom] {
            c.priority = .defaultHigh
        }

        NSLayoutConstraint.activate([
            searchTop,
            searchLeading,
            searchHeight,

            // Count label to the right of search
            countLabel.centerYAnchor.constraint(equalTo: searchField.centerYAnchor),
            labelGap,
            labelTrailing,

            // Scroll view fills remaining space
            scrollView.topAnchor.constraint(equalTo: searchField.bottomAnchor, constant: 4),
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollBottom,
        ])
    }

    // MARK: - Data Reload

    private func reloadData() {
        outlineView.reloadData()
        updateCountLabel()

        // Expand root children by default.
        // The data source maps nil item -> root's children, so the top-level items
        // are root's children. We expand each top-level item so the first two
        // levels of the tree are visible on load.
        if let root = tree?.root {
            for child in sortedChildren(of: root) {
                outlineView.expandItem(child)
            }
        }
    }

    private func updateCountLabel() {
        guard let tree else {
            countLabel.stringValue = ""
            return
        }
        let total = tree.allNodes().count
        if let filtered = filteredNodeIDs {
            countLabel.stringValue = "\(filtered.count) of \(total) taxa"
        } else {
            countLabel.stringValue = "\(total) taxa"
        }
    }

    // MARK: - Search

    @objc private func searchFieldChanged(_ sender: NSSearchField) {
        filterText = sender.stringValue
    }

    private func applyFilter() {
        let query = filterText.trimmingCharacters(in: .whitespaces).lowercased()

        if query.isEmpty {
            filteredNodeIDs = nil
            directMatchNodeIDs = []
        } else {
            guard let tree else { return }

            // Find matching nodes
            var matches = Set<ObjectIdentifier>()
            var ancestors = Set<ObjectIdentifier>()

            for node in tree.allNodes() {
                if nodeMatchesFilter(node: node, query: query) {
                    matches.insert(ObjectIdentifier(node))
                    // Include all ancestors so hierarchy context is preserved
                    var parent = node.parent
                    while let p = parent {
                        ancestors.insert(ObjectIdentifier(p))
                        parent = p.parent
                    }
                }
            }

            directMatchNodeIDs = matches
            filteredNodeIDs = matches.union(ancestors)
        }

        outlineView.reloadData()
        updateCountLabel()

        // Expand all nodes that match when filtering
        if filteredNodeIDs != nil, let root = tree?.root {
            expandFilteredNodes(from: root)
        }

        // Notify listeners (e.g., sunburst chart) of the new filter state
        if let filteredNodeIDs, let tree {
            var filteredTaxIds = Set<Int>()
            for node in tree.allNodes() where filteredNodeIDs.contains(ObjectIdentifier(node)) {
                filteredTaxIds.insert(node.taxId)
            }
            onFilterChanged?(filteredTaxIds)
        } else {
            onFilterChanged?(nil)
        }
    }

    private func expandFilteredNodes(from node: TaxonNode) {
        guard let filtered = filteredNodeIDs else { return }
        if filtered.contains(ObjectIdentifier(node)) {
            outlineView.expandItem(node)
            for child in node.children {
                expandFilteredNodes(from: child)
            }
        }
    }

    // MARK: - Selection Synchronization

    /// Selects and scrolls to the row for the given node.
    ///
    /// Called by the sunburst view to keep the table in sync.
    public func selectAndScrollTo(node: TaxonNode?) {
        selectRowForNode(node)
    }

    private func selectRowForNode(_ node: TaxonNode?) {
        guard let node else {
            suppressSelectionCallback = true
            outlineView.deselectAll(nil)
            suppressSelectionCallback = false
            return
        }

        // Ensure the path to the node is expanded
        let path = node.pathFromRoot()
        for ancestor in path.dropLast() {
            outlineView.expandItem(ancestor)
        }

        let row = outlineView.row(forItem: node)
        if row >= 0 {
            suppressSelectionCallback = true
            outlineView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            outlineView.scrollRowToVisible(row)
            suppressSelectionCallback = false
        }
    }

    // MARK: - Expand / Collapse

    /// Expands all items in the outline view.
    ///
    /// Accessible from View > Expand All (Cmd+Shift+Right) and Cmd+Shift+Right
    /// keyboard shortcut when the outline view has focus.
    ///
    /// Uses `expandItem(nil, expandChildren: true)` which tells NSOutlineView
    /// to expand the invisible root and all descendants recursively.
    public func expandAll() {
        guard tree != nil else { return }
        outlineView.expandItem(nil, expandChildren: true)
    }

    /// Collapses all items in the outline view.
    ///
    /// Accessible from View > Collapse All (Cmd+Shift+Left) and Cmd+Shift+Left
    /// keyboard shortcut when the outline view has focus.
    ///
    /// After collapsing, the top-level items (root's children) remain visible
    /// since they are always shown by the outline view.
    public func collapseAll() {
        guard tree != nil else { return }
        outlineView.collapseItem(nil, collapseChildren: true)
    }

    /// Recursively expands the selected item and all its descendants.
    ///
    /// Triggered by Option+Right Arrow when the outline view has focus.
    public func expandSelectedRecursively() {
        let row = outlineView.selectedRow
        guard row >= 0, let node = outlineView.item(atRow: row) else { return }
        outlineView.expandItem(node, expandChildren: true)
    }

    // MARK: - Sorting

    /// Tests whether a TaxonNode passes a column filter.
    private func nodeMatchesColumnFilter(_ filter: ColumnFilter, node: TaxonNode) -> Bool {
        guard filter.isActive else { return true }
        switch filter.columnId {
        case ColumnID.sample:
            return filter.matchesString(sampleID(for: node))
        case ColumnID.name:
            return filter.matchesString(node.name)
        case ColumnID.rank:
            return filter.matchesString(node.rank.displayName)
        case ColumnID.reads:
            return filter.matchesNumeric(Double(node.readsClade))
        case ColumnID.clade:
            return filter.matchesNumeric(Double(node.readsDirect))
        case ColumnID.percent:
            return filter.matchesNumeric(node.fractionClade * 100.0)
        default:
            // Metadata columns
            if filter.columnId.hasPrefix("metadata_"),
               let store = metadataColumns.store {
                let metaCol = String(filter.columnId.dropFirst("metadata_".count))
                let sid = sampleID(for: node)
                if let value = store.records[sid]?[metaCol] {
                    if let num = Double(value) {
                        return filter.matchesNumeric(num)
                    }
                    return filter.matchesString(value)
                }
                return false
            }
            return true
        }
    }

    /// Returns children of a node sorted by the current sort criteria.
    func sortedChildren(of node: TaxonNode) -> [TaxonNode] {
        var children = node.children

        // Apply text search filter
        if let filtered = filteredNodeIDs {
            children = children.filter { filtered.contains(ObjectIdentifier($0)) }
        }

        // Apply per-column filters
        for (_, filter) in columnFilters where filter.isActive {
            children = children.filter { nodeMatchesColumnFilter(filter, node: $0) }
        }

        // Apply sort
        switch currentSortKey {
        case ColumnID.sample:
            children.sort {
                let l = sampleID(for: $0)
                let r = sampleID(for: $1)
                return currentSortAscending
                    ? l.localizedCaseInsensitiveCompare(r) == .orderedAscending
                    : l.localizedCaseInsensitiveCompare(r) == .orderedDescending
            }
        case ColumnID.name:
            children.sort { currentSortAscending
                ? $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
                : $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedDescending
            }
        case ColumnID.rank:
            children.sort { currentSortAscending
                ? $0.rank.ringIndex < $1.rank.ringIndex
                : $0.rank.ringIndex > $1.rank.ringIndex
            }
        case ColumnID.reads:
            // "Reads" column shows clade counts
            children.sort { currentSortAscending
                ? $0.readsClade < $1.readsClade
                : $0.readsClade > $1.readsClade
            }
        case ColumnID.clade:
            // "Direct" column shows direct counts
            children.sort { currentSortAscending
                ? $0.readsDirect < $1.readsDirect
                : $0.readsDirect > $1.readsDirect
            }
        case ColumnID.percent:
            children.sort { currentSortAscending
                ? $0.fractionClade < $1.fractionClade
                : $0.fractionClade > $1.fractionClade
            }
        default:
            // Default: clade descending
            children.sort { $0.readsClade > $1.readsClade }
        }

        return children
    }

    // MARK: - Context Menu

    private func buildContextMenu() -> NSMenu {
        let menu = NSMenu()

        // Extraction
        menu.addItem(withTitle: "Extract Reads\u{2026}",
                     action: #selector(contextExtractReads(_:)),
                     keyEquivalent: "")

        menu.addItem(.separator())

        // Expand/Collapse
        menu.addItem(withTitle: "Expand",
                     action: #selector(contextExpandItem(_:)),
                     keyEquivalent: "")
        menu.addItem(withTitle: "Expand All Below",
                     action: #selector(contextExpandAllBelow(_:)),
                     keyEquivalent: "")
        menu.addItem(withTitle: "Collapse",
                     action: #selector(contextCollapseItem(_:)),
                     keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Expand All",
                     action: #selector(contextExpandAll(_:)),
                     keyEquivalent: "")
        menu.addItem(withTitle: "Collapse All",
                     action: #selector(contextCollapseAll(_:)),
                     keyEquivalent: "")

        menu.addItem(.separator())

        // BLAST
        let blastItem = NSMenuItem(
            title: "BLAST Matching Reads\u{2026}",
            action: #selector(contextBlastReads(_:)),
            keyEquivalent: ""
        )
        blastItem.image = NSImage(systemSymbolName: "bolt.circle", accessibilityDescription: "BLAST")
        menu.addItem(blastItem)

        menu.addItem(.separator())

        // NCBI links
        let ncbiSubmenu = NSMenu()
        ncbiSubmenu.addItem(withTitle: "NCBI Taxonomy",
                           action: #selector(contextOpenNCBITaxonomy(_:)),
                           keyEquivalent: "")
        ncbiSubmenu.addItem(withTitle: "GenBank Sequences",
                           action: #selector(contextOpenNCBIGenBank(_:)),
                           keyEquivalent: "")
        ncbiSubmenu.addItem(withTitle: "PubMed Literature",
                           action: #selector(contextOpenNCBIPubMed(_:)),
                           keyEquivalent: "")
        let ncbiItem = NSMenuItem(title: "Look Up on NCBI", action: nil, keyEquivalent: "")
        ncbiItem.submenu = ncbiSubmenu
        ncbiItem.image = NSImage(systemSymbolName: "globe", accessibilityDescription: "NCBI")
        menu.addItem(ncbiItem)

        menu.addItem(.separator())

        // Copy
        menu.addItem(withTitle: "Copy Taxon Name",
                     action: #selector(contextCopyName(_:)),
                     keyEquivalent: "")

        return menu
    }

    // MARK: - Menu Item Validation

    public func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        let clickedNode = actionableNode(at: outlineView.clickedRow)

        if menuItem.action == #selector(contextBlastReads(_:)) {
            // BLAST requires exactly one selected row
            return clickedNode != nil && outlineView.selectedRowIndexes.count <= 1
        }
        if menuItem.action == #selector(contextOpenNCBITaxonomy(_:))
            || menuItem.action == #selector(contextOpenNCBIGenBank(_:))
            || menuItem.action == #selector(contextOpenNCBIPubMed(_:))
            || menuItem.action == #selector(contextCopyName(_:))
        {
            return clickedNode != nil
        }
        if menuItem.action == #selector(contextExtractReads(_:)) {
            // Gate must mirror the handler's read source. `contextExtractReads`
            // dispatches to `presentUnifiedExtractionDialog()`, which reads
            // `selectedRowIndexes` (via `buildKraken2Selectors(explicit: nil)`).
            // NSOutlineView's default right-click behavior auto-selects the
            // clicked row before showing the menu, so `clickedNode` is
            // already in `selectedRowIndexes` whenever the menu is shown —
            // a `|| clickedNode != nil` clause would create an asymmetric
            // gate that enables the item on a clicked row that the handler
            // cannot see.
            return !outlineView.selectedRowIndexes.isEmpty
        }
        return true
    }

    @objc private func contextExtractReads(_ sender: Any?) {
        onExtractReadsRequested?()
    }

    @objc private func contextCopyName(_ sender: Any?) {
        guard let node = actionableNode(at: outlineView.clickedRow) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(node.name, forType: .string)
    }

    @objc private func contextExpandItem(_ sender: Any?) {
        let row = outlineView.clickedRow
        guard row >= 0, let node = outlineView.item(atRow: row) else { return }
        outlineView.expandItem(node)
    }

    @objc private func contextExpandAllBelow(_ sender: Any?) {
        let row = outlineView.clickedRow
        guard row >= 0, let node = outlineView.item(atRow: row) else { return }
        outlineView.expandItem(node, expandChildren: true)
    }

    @objc private func contextCollapseItem(_ sender: Any?) {
        let row = outlineView.clickedRow
        guard row >= 0, let node = outlineView.item(atRow: row) else { return }
        outlineView.collapseItem(node)
    }

    @objc private func contextExpandAll(_ sender: Any?) {
        expandAll()
    }

    @objc private func contextCollapseAll(_ sender: Any?) {
        collapseAll()
    }

    @objc private func contextBlastReads(_ sender: Any?) {
        guard let node = actionableNode(at: outlineView.clickedRow) else { return }
        onBlastRequested?(node)
    }

    @objc private func contextOpenNCBITaxonomy(_ sender: Any?) {
        guard let node = actionableNode(at: outlineView.clickedRow) else { return }
        onNCBITaxonomyRequested?(node)
    }

    @objc private func contextOpenNCBIGenBank(_ sender: Any?) {
        guard let node = actionableNode(at: outlineView.clickedRow) else { return }
        onNCBIGenBankRequested?(node)
    }

    @objc private func contextOpenNCBIPubMed(_ sender: Any?) {
        guard let node = actionableNode(at: outlineView.clickedRow) else { return }
        onNCBIPubMedRequested?(node)
    }

    // MARK: - NSOutlineViewDataSource

    public func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        guard let tree else { return 0 }

        let node: TaxonNode
        if let item = item as? TaxonNode {
            node = item
        } else {
            node = tree.root
        }

        return sortedChildren(of: node).count
    }

    public func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        let node: TaxonNode
        if let item = item as? TaxonNode {
            node = item
        } else {
            node = tree!.root
        }

        return sortedChildren(of: node)[index]
    }

    public func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        guard let node = item as? TaxonNode else { return false }
        if let filtered = filteredNodeIDs {
            return node.children.contains { filtered.contains(ObjectIdentifier($0)) }
        }
        return !node.children.isEmpty
    }

    public func outlineView(
        _ outlineView: NSOutlineView,
        sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]
    ) {
        guard let descriptor = outlineView.sortDescriptors.first,
              let key = descriptor.key else { return }
        currentSortKey = key
        currentSortAscending = descriptor.ascending
        outlineView.reloadData()
    }

    // MARK: - Column Header Filter Menus

    public func outlineView(_ outlineView: NSOutlineView, didClick tableColumn: NSTableColumn) {
        showColumnHeaderFilterMenu(for: tableColumn)
    }

    private func showColumnHeaderFilterMenu(for tableColumn: NSTableColumn) {
        guard let headerView = outlineView.headerView,
              let colIndex = outlineView.tableColumns.firstIndex(of: tableColumn) else { return }

        let columnId = tableColumn.identifier.rawValue
        let displayName = tableColumn.title.isEmpty ? "Column" : tableColumn.title
        let isNumeric = columnTypes[columnId] ?? false

        let menu = NSMenu()

        // Sort options
        let sortAscItem = NSMenuItem(title: "Sort Ascending", action: #selector(sortColumnAsc(_:)), keyEquivalent: "")
        sortAscItem.target = self
        sortAscItem.representedObject = tableColumn
        menu.addItem(sortAscItem)

        let sortDescItem = NSMenuItem(title: "Sort Descending", action: #selector(sortColumnDesc(_:)), keyEquivalent: "")
        sortDescItem.target = self
        sortDescItem.representedObject = tableColumn
        menu.addItem(sortDescItem)

        menu.addItem(NSMenuItem.separator())

        // Filter options (type-appropriate)
        if isNumeric {
            for (label, op) in [
                ("Filter \(displayName) \u{2265}\u{2026}", FilterOperator.greaterOrEqual),
                ("Filter \(displayName) \u{2264}\u{2026}", FilterOperator.lessOrEqual),
                ("Filter \(displayName) =\u{2026}", FilterOperator.equal),
                ("Filter \(displayName) Between\u{2026}", FilterOperator.between),
            ] {
                let item = NSMenuItem(title: label, action: #selector(promptColumnFilter(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = ["columnId": columnId, "op": op] as [String: Any]
                menu.addItem(item)
            }
        } else {
            for (label, op) in [
                ("Filter \(displayName) Contains\u{2026}", FilterOperator.contains),
                ("Filter \(displayName) Equals\u{2026}", FilterOperator.equal),
                ("Filter \(displayName) Starts With\u{2026}", FilterOperator.startsWith),
            ] {
                let item = NSMenuItem(title: label, action: #selector(promptColumnFilter(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = ["columnId": columnId, "op": op] as [String: Any]
                menu.addItem(item)
            }
        }

        if columnFilters[columnId]?.isActive == true {
            menu.addItem(NSMenuItem.separator())
            let clearItem = NSMenuItem(title: "Clear \(displayName) Filter", action: #selector(clearColumnFilter(_:)), keyEquivalent: "")
            clearItem.target = self
            clearItem.representedObject = columnId
            menu.addItem(clearItem)
        }

        if !columnFilters.filter({ $0.value.isActive }).isEmpty {
            let clearAllItem = NSMenuItem(title: "Clear All Filters", action: #selector(clearAllColumnFilters(_:)), keyEquivalent: "")
            clearAllItem.target = self
            menu.addItem(clearAllItem)
        }

        let rect = headerView.headerRect(ofColumn: colIndex)
        let anchorPoint = NSPoint(x: rect.minX + 8, y: rect.minY - 2)
        menu.popUp(positioning: nil, at: anchorPoint, in: headerView)
    }

    @objc private func promptColumnFilter(_ sender: NSMenuItem) {
        guard let payload = sender.representedObject as? [String: Any],
              let columnId = payload["columnId"] as? String,
              let op = payload["op"] as? FilterOperator,
              let window = window else { return }

        let alert = NSAlert()
        alert.messageText = "Column Filter"
        let displayName = outlineView.tableColumns
            .first { $0.identifier.rawValue == columnId }?.title ?? columnId
        alert.informativeText = "Enter a value for \(displayName) (\(op.rawValue))."
        alert.addButton(withTitle: "Apply")
        alert.addButton(withTitle: "Cancel")

        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        field.placeholderString = op == .between ? "min value" : "filter value"

        if op == .between {
            let stack = NSStackView(frame: NSRect(x: 0, y: 0, width: 240, height: 52))
            stack.orientation = .vertical
            stack.spacing = 4
            let field2 = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
            field2.placeholderString = "max value"
            stack.addArrangedSubview(field)
            stack.addArrangedSubview(field2)
            alert.accessoryView = stack
        } else {
            alert.accessoryView = field
        }

        if let existing = columnFilters[columnId] {
            field.stringValue = existing.value
        }

        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn, let self else { return }
            let value = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty else { return }

            var value2: String? = nil
            if op == .between, let stack = alert.accessoryView as? NSStackView,
               let field2 = stack.arrangedSubviews.last as? NSTextField {
                value2 = field2.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            }

            self.columnFilters[columnId] = ColumnFilter(columnId: columnId, op: op, value: value, value2: value2)
            self.reloadDataAndUpdateFilterIndicators()
        }
    }

    @objc private func sortColumnAsc(_ sender: NSMenuItem) {
        guard let column = sender.representedObject as? NSTableColumn,
              let proto = column.sortDescriptorPrototype,
              let key = proto.key else { return }
        currentSortKey = key
        currentSortAscending = true
        outlineView.reloadData()
    }

    @objc private func sortColumnDesc(_ sender: NSMenuItem) {
        guard let column = sender.representedObject as? NSTableColumn,
              let proto = column.sortDescriptorPrototype,
              let key = proto.key else { return }
        currentSortKey = key
        currentSortAscending = false
        outlineView.reloadData()
    }

    @objc private func clearColumnFilter(_ sender: NSMenuItem) {
        guard let columnId = sender.representedObject as? String else { return }
        columnFilters.removeValue(forKey: columnId)
        reloadDataAndUpdateFilterIndicators()
    }

    @objc private func clearAllColumnFilters(_ sender: Any?) {
        columnFilters.removeAll()
        reloadDataAndUpdateFilterIndicators()
    }

    // MARK: - NSOutlineViewDelegate

    public func outlineView(
        _ outlineView: NSOutlineView,
        viewFor tableColumn: NSTableColumn?,
        item: Any
    ) -> NSView? {
        guard let node = item as? TaxonNode,
              let column = tableColumn else { return nil }

        let colID = column.identifier.rawValue

        switch colID {
        case ColumnID.sample:
            return makeTextCell(text: sampleID(for: node), alignment: .left)
        case ColumnID.name:
            return makeNameCell(for: node)
        case ColumnID.rank:
            return makeTextCell(text: node.rank.displayName, alignment: .center)
        case ColumnID.reads:
            return makeNumberCell(value: node.readsClade)
        case ColumnID.clade:
            return makeNumberCell(value: node.readsDirect)
        case ColumnID.percent:
            return makePercentCell(for: node)
        default:
            // Check for dynamic metadata columns
            if let cell = metadataColumns.cellForColumn(column) {
                return cell
            }
            return nil
        }
    }

    public func outlineViewSelectionDidChange(_ notification: Notification) {
        guard !suppressSelectionCallback else { return }

        let selectedRows = outlineView.selectedRowIndexes
        if selectedRows.count == 1 {
            let row = selectedRows.first!
            guard let node = outlineView.item(atRow: row) as? TaxonNode else {
                onNodeSelected?(tree!.root)
                return
            }
            selectedNode = node
            onNodeSelected?(node)
        } else if selectedRows.count > 1 {
            // Clear selectedNode WITHOUT triggering didSet (which calls
            // selectRowForNode → deselectAll, destroying the multi-selection).
            suppressSelectionCallback = true
            _selectedNode = nil
            suppressSelectionCallback = false
            onMultipleNodesSelected?(selectedRows.count)
        } else {
            selectedNode = nil
            onNodeSelected?(tree!.root)
        }
    }

    // MARK: - Cell Factories

    /// Creates a name cell with a phylum-colored indicator dot.
    private func makeNameCell(for node: TaxonNode) -> NSView {
        let cellView = NSTableCellView()
        cellView.identifier = NSUserInterfaceItemIdentifier(ColumnID.name)

        // Colored dot
        let dot = PhylumDotView(frame: NSRect(x: 0, y: 5, width: 8, height: 8))
        dot.color = PhylumPalette.color(for: node)
        dot.translatesAutoresizingMaskIntoConstraints = false

        // Name label
        let textField = NSTextField(labelWithString: node.name)
        textField.font = .systemFont(ofSize: 12)
        textField.lineBreakMode = .byTruncatingTail
        textField.translatesAutoresizingMaskIntoConstraints = false

        // Dim non-matching nodes during filter
        if filteredNodeIDs != nil, !directMatchNodeIDs.contains(ObjectIdentifier(node)) {
            textField.textColor = .tertiaryLabelColor
        } else {
            textField.textColor = .labelColor
        }

        cellView.addSubview(dot)
        cellView.addSubview(textField)
        cellView.textField = textField

        NSLayoutConstraint.activate([
            dot.leadingAnchor.constraint(equalTo: cellView.leadingAnchor, constant: 2),
            dot.centerYAnchor.constraint(equalTo: cellView.centerYAnchor),
            dot.widthAnchor.constraint(equalToConstant: 8),
            dot.heightAnchor.constraint(equalToConstant: 8),

            textField.leadingAnchor.constraint(equalTo: dot.trailingAnchor, constant: 4),
            textField.trailingAnchor.constraint(equalTo: cellView.trailingAnchor, constant: -2),
            textField.centerYAnchor.constraint(equalTo: cellView.centerYAnchor),
        ])

        // Accessibility
        dot.setAccessibilityRole(.image)
        let (phylumIndex, _) = PhylumPalette.phylumInfo(for: node)
        dot.setAccessibilityLabel("Phylum color: slot \(phylumIndex)")

        return cellView
    }

    /// Creates a simple text cell.
    private func makeTextCell(text: String, alignment: NSTextAlignment) -> NSView {
        let cellView = NSTableCellView()
        let textField = NSTextField(labelWithString: text)
        textField.font = .systemFont(ofSize: 12)
        textField.alignment = alignment
        textField.translatesAutoresizingMaskIntoConstraints = false
        cellView.addSubview(textField)
        cellView.textField = textField

        NSLayoutConstraint.activate([
            textField.leadingAnchor.constraint(equalTo: cellView.leadingAnchor, constant: 2),
            textField.trailingAnchor.constraint(equalTo: cellView.trailingAnchor, constant: -2),
            textField.centerYAnchor.constraint(equalTo: cellView.centerYAnchor),
        ])

        return cellView
    }

    /// Creates a right-aligned numeric cell.
    private func makeNumberCell(value: Int) -> NSView {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.groupingSeparator = ","
        let text = formatter.string(from: NSNumber(value: value)) ?? "\(value)"

        let cellView = NSTableCellView()
        let textField = NSTextField(labelWithString: text)
        textField.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        textField.alignment = .right
        textField.translatesAutoresizingMaskIntoConstraints = false
        cellView.addSubview(textField)
        cellView.textField = textField

        NSLayoutConstraint.activate([
            textField.leadingAnchor.constraint(equalTo: cellView.leadingAnchor, constant: 2),
            textField.trailingAnchor.constraint(equalTo: cellView.trailingAnchor, constant: -2),
            textField.centerYAnchor.constraint(equalTo: cellView.centerYAnchor),
        ])

        return cellView
    }

    /// Creates a percent cell with a background bar indicator.
    private func makePercentCell(for node: TaxonNode) -> NSView {
        let percentage = node.fractionClade * 100
        let text = String(format: "%.1f%%", percentage)

        let cellView = NSTableCellView()

        // Background bar
        let barView = NSView()
        barView.translatesAutoresizingMaskIntoConstraints = false
        let barColor = PhylumPalette.color(for: node).withAlphaComponent(0.2)
        barView.layer = CALayer()
        barView.layer?.backgroundColor = barColor.cgColor
        cellView.addSubview(barView)

        // Percentage label
        let textField = NSTextField(labelWithString: text)
        textField.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        textField.alignment = .right
        textField.translatesAutoresizingMaskIntoConstraints = false
        cellView.addSubview(textField)
        cellView.textField = textField

        // Bar width proportional to percentage (max 100%)
        let barFraction = min(1.0, max(0.0, CGFloat(node.fractionClade)))

        NSLayoutConstraint.activate([
            barView.leadingAnchor.constraint(equalTo: cellView.leadingAnchor),
            barView.topAnchor.constraint(equalTo: cellView.topAnchor, constant: 1),
            barView.bottomAnchor.constraint(equalTo: cellView.bottomAnchor, constant: -1),
            barView.widthAnchor.constraint(equalTo: cellView.widthAnchor, multiplier: barFraction),

            textField.leadingAnchor.constraint(equalTo: cellView.leadingAnchor, constant: 2),
            textField.trailingAnchor.constraint(equalTo: cellView.trailingAnchor, constant: -2),
            textField.centerYAnchor.constraint(equalTo: cellView.centerYAnchor),
        ])

        return cellView
    }

    /// Returns sample identifier for a taxonomy node in merged multi-sample trees.
    private func sampleID(for node: TaxonNode) -> String {
        var current: TaxonNode? = node
        while let c = current {
            if c.parent?.taxId == 1, c.taxId < 0 {
                return c.name
            }
            current = c.parent
        }
        return currentSampleID ?? ""
    }

    private func actionableNode(at row: Int) -> TaxonNode? {
        guard row >= 0, let node = outlineView.item(atRow: row) as? TaxonNode else { return nil }
        if node.taxId <= 1 { return nil } // Root and synthetic sample grouping rows.
        return node
    }

    /// Global filter predicate that matches any visible taxonomy column.
    private func nodeMatchesFilter(node: TaxonNode, query: String) -> Bool {
        let pct = String(format: "%.1f%%", node.fractionClade * 100.0).lowercased()
        if sampleID(for: node).lowercased().contains(query) { return true }
        if node.name.lowercased().contains(query) { return true }
        if node.rank.displayName.lowercased().contains(query) { return true }
        if "\(node.readsClade)".contains(query) { return true }
        if "\(node.readsDirect)".contains(query) { return true }
        if pct.contains(query) { return true }
        return false
    }

    #if DEBUG
    /// Test-only: the outline view's configured context menu. Exposed so
    /// Phase 6 I1 invariant tests can inspect the menu without reaching
    /// into a private subview.
    public var testingContextMenu: NSMenu? {
        outlineView.menu
    }

    /// Test-only: installs a minimal stub data source with `rowCount` rows so
    /// `outlineView.selectedRowIndexes` can hold a non-empty selection, then
    /// programmatically selects the given indices.
    ///
    /// Used by the Phase 6 I2 invariant test to exercise
    /// `validateMenuItem(_:)` when rows are selected, without needing a full
    /// Kraken2 classification result to back the table.
    public func setTestingSelection(indices: [Int]) {
        let rowCount = (indices.max() ?? -1) + 1
        let stub = _TestingTaxonomyStubOutlineDataSource(rows: max(rowCount, 1))
        objc_setAssociatedObject(
            self,
            &Self._testingStubKey,
            stub,
            .OBJC_ASSOCIATION_RETAIN_NONATOMIC
        )
        outlineView.dataSource = stub
        outlineView.reloadData()
        outlineView.selectRowIndexes(IndexSet(indices), byExtendingSelection: false)
    }

    /// Test-only: fires `contextExtractReads(_:)` directly so I3 tests can
    /// verify the menu-click wiring without synthesizing AppKit events.
    public func simulateContextMenuExtractReads() {
        contextExtractReads(nil)
    }

    private static var _testingStubKey: UInt8 = 0
    #endif
}

#if DEBUG
/// Minimal stub NSOutlineViewDataSource used by the Phase 6 I2 invariant
/// test to seed a non-empty `selectedRowIndexes` without instantiating a
/// real taxonomy tree.
fileprivate final class _TestingTaxonomyStubOutlineDataSource: NSObject, NSOutlineViewDataSource {
    let rows: Int
    init(rows: Int) { self.rows = rows }

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        item == nil ? rows : 0
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        NSNumber(value: index)
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        false
    }
}
#endif

// MARK: - TaxonomyOutlineView

/// Custom NSOutlineView subclass that intercepts keyboard shortcuts for
/// taxonomy tree navigation.
///
/// Handles:
/// - **Option+Right Arrow**: Expand selected item and all children recursively
/// - **Cmd+Shift+Right Arrow**: Expand all items in the tree
/// - **Cmd+Shift+Left Arrow**: Collapse all items in the tree
///
/// Left Arrow / Right Arrow for expand/collapse of individual items are
/// handled by NSOutlineView's built-in behavior and are not overridden here.
@MainActor
public class TaxonomyOutlineView: NSOutlineView {

    /// Back-reference to the owning table view for expand/collapse operations.
    weak var taxonomyTableView: TaxonomyTableView?

    /// Intercepts keyboard shortcuts for tree navigation.
    ///
    /// This override catches modifier+arrow combinations before they reach
    /// the default NSOutlineView handler. Plain Left/Right arrow keys pass
    /// through to the super implementation for built-in expand/collapse.
    public override func keyDown(with event: NSEvent) {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)

        switch event.keyCode {
        case 124: // Right Arrow
            if modifiers == [.command, .shift] {
                // Cmd+Shift+Right: Expand all
                taxonomyTableView?.expandAll()
                return
            } else if modifiers == .option {
                // Option+Right: Expand selected recursively
                taxonomyTableView?.expandSelectedRecursively()
                return
            }

        case 123: // Left Arrow
            if modifiers == [.command, .shift] {
                // Cmd+Shift+Left: Collapse all
                taxonomyTableView?.collapseAll()
                return
            }

        default:
            break
        }

        super.keyDown(with: event)
    }
}

// MARK: - PhylumDotView

/// A small circular indicator view filled with a phylum color.
@MainActor
final class PhylumDotView: NSView {

    /// The fill color for the dot.
    var color: NSColor = .gray {
        didSet { needsDisplay = true }
    }

    override func draw(_ dirtyRect: NSRect) {
        let dotPath = NSBezierPath(ovalIn: bounds)
        color.setFill()
        dotPath.fill()
    }
}
