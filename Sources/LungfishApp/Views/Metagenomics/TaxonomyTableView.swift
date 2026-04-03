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
            filteredTree = nil
            reloadData()
        }
    }

    /// The currently selected node.
    public var selectedNode: TaxonNode? {
        didSet {
            selectRowForNode(selectedNode)
        }
    }

    /// Called when the user selects a row.
    public var onNodeSelected: ((TaxonNode) -> Void)?

    /// Called when multiple rows are selected. Parameter is the count.
    public var onMultipleNodesSelected: ((Int) -> Void)?

    /// Called when the user right-clicks a row to extract sequences.
    public var onExtractRequested: ((TaxonNode) -> Void)?

    /// Called when the user right-clicks a row to extract sequences including children.
    public var onExtractWithChildrenRequested: ((TaxonNode) -> Void)?

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

    // MARK: - Search / Filter

    /// Current filter text. Empty string means no filter.
    private var filterText: String = "" {
        didSet {
            if filterText != oldValue {
                applyFilter()
            }
        }
    }

    /// Set of node taxIds that match the current filter (or their ancestors).
    private var filteredTree: Set<Int>?

    /// Nodes that directly match the filter (not just ancestors).
    private var directMatches: Set<Int> = []

    // MARK: - Sort State

    /// Current sort descriptor (nil = default: clade descending).
    private var currentSortKey: String = ColumnID.reads
    private var currentSortAscending: Bool = false

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
            "Taxon Name", "Rank", "Reads", "Direct", "%",
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
        if let filtered = filteredTree {
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
            filteredTree = nil
            directMatches = []
        } else {
            guard let tree else { return }

            // Find matching nodes
            var matches = Set<Int>()
            var ancestors = Set<Int>()

            for node in tree.allNodes() {
                if node.name.lowercased().contains(query) {
                    matches.insert(node.taxId)
                    // Include all ancestors so hierarchy context is preserved
                    var parent = node.parent
                    while let p = parent {
                        ancestors.insert(p.taxId)
                        parent = p.parent
                    }
                }
            }

            directMatches = matches
            filteredTree = matches.union(ancestors)
        }

        outlineView.reloadData()
        updateCountLabel()

        // Expand all nodes that match when filtering
        if filteredTree != nil, let root = tree?.root {
            expandFilteredNodes(from: root)
        }

        // Notify listeners (e.g., sunburst chart) of the new filter state
        onFilterChanged?(filteredTree)
    }

    private func expandFilteredNodes(from node: TaxonNode) {
        guard let filtered = filteredTree else { return }
        if filtered.contains(node.taxId) {
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

    /// Returns children of a node sorted by the current sort criteria.
    func sortedChildren(of node: TaxonNode) -> [TaxonNode] {
        var children = node.children

        // Apply filter
        if let filtered = filteredTree {
            children = children.filter { filtered.contains($0.taxId) }
        }

        // Apply sort
        switch currentSortKey {
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
        menu.addItem(withTitle: "Extract Reads for Taxon\u{2026}",
                     action: #selector(contextExtractReads(_:)),
                     keyEquivalent: "")
        menu.addItem(withTitle: "Extract Reads Including Children\u{2026}",
                     action: #selector(contextExtractWithChildren(_:)),
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
        if menuItem.action == #selector(contextBlastReads(_:)) {
            // BLAST requires exactly one selected row
            return outlineView.clickedRow >= 0 && outlineView.selectedRowIndexes.count <= 1
        }
        return true
    }

    @objc private func contextExtractReads(_ sender: Any?) {
        let row = outlineView.clickedRow
        guard row >= 0, let node = outlineView.item(atRow: row) as? TaxonNode else { return }
        onExtractRequested?(node)
    }

    @objc private func contextExtractWithChildren(_ sender: Any?) {
        let row = outlineView.clickedRow
        guard row >= 0, let node = outlineView.item(atRow: row) as? TaxonNode else { return }
        onExtractWithChildrenRequested?(node)
    }

    @objc private func contextCopyName(_ sender: Any?) {
        let row = outlineView.clickedRow
        guard row >= 0, let node = outlineView.item(atRow: row) as? TaxonNode else { return }
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
        let row = outlineView.clickedRow
        guard row >= 0, let node = outlineView.item(atRow: row) as? TaxonNode else { return }
        onBlastRequested?(node)
    }

    @objc private func contextOpenNCBITaxonomy(_ sender: Any?) {
        let row = outlineView.clickedRow
        guard row >= 0, let node = outlineView.item(atRow: row) as? TaxonNode else { return }
        onNCBITaxonomyRequested?(node)
    }

    @objc private func contextOpenNCBIGenBank(_ sender: Any?) {
        let row = outlineView.clickedRow
        guard row >= 0, let node = outlineView.item(atRow: row) as? TaxonNode else { return }
        onNCBIGenBankRequested?(node)
    }

    @objc private func contextOpenNCBIPubMed(_ sender: Any?) {
        let row = outlineView.clickedRow
        guard row >= 0, let node = outlineView.item(atRow: row) as? TaxonNode else { return }
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
        if let filtered = filteredTree {
            return node.children.contains { filtered.contains($0.taxId) }
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
            selectedNode = nil
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
        if filteredTree != nil, !directMatches.contains(node.taxId) {
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
}

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
