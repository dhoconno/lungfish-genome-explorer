// TaxaCollectionsDrawerView.swift - Bottom drawer for taxa collection browsing and batch extraction
// Copyright (c) 2025 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import LungfishCore
import LungfishIO
import os.log

private let drawerLogger = Logger(subsystem: LogSubsystem.app, category: "TaxaCollectionsDrawer")

// MARK: - TaxaCollectionsDrawerDelegate

/// Delegate protocol for the taxa collections drawer.
///
/// Provides callbacks for drawer resize gestures and batch extraction triggers.
@MainActor
public protocol TaxaCollectionsDrawerDelegate: AnyObject {
    /// Called when the user drags the divider to resize the drawer.
    ///
    /// - Parameters:
    ///   - drawer: The drawer being resized.
    ///   - deltaY: Vertical delta in points (positive = taller).
    func taxaCollectionsDrawerDidDragDivider(_ drawer: TaxaCollectionsDrawerView, deltaY: CGFloat)

    /// Called when the user finishes dragging the divider.
    ///
    /// - Parameter drawer: The drawer that was resized.
    func taxaCollectionsDrawerDidFinishDraggingDivider(_ drawer: TaxaCollectionsDrawerView)

    /// Called when the user clicks "Extract" on a collection.
    ///
    /// - Parameters:
    ///   - drawer: The drawer containing the collection.
    ///   - collection: The collection to extract.
    func taxaCollectionsDrawer(_ drawer: TaxaCollectionsDrawerView, didRequestExtractFor collection: TaxaCollection)
}

// MARK: - TaxaCollectionsDividerView

/// Drag-to-resize handle at the top of the taxa collections drawer.
///
/// Follows the identical divider pattern used by ``DrawerDividerView`` in
/// the annotation drawer and ``FASTQDrawerDividerView`` in the FASTQ drawer.
/// Three subtle horizontal grip lines signal to the user that the divider
/// is draggable.
@MainActor
final class TaxaCollectionsDividerView: NSView {

    /// Called during mouse drag with the vertical delta (positive = dragging up = taller drawer).
    var onDrag: ((CGFloat) -> Void)?

    /// Called when the drag gesture ends.
    var onDragEnd: (() -> Void)?

    private var dragStartY: CGFloat = 0

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .resizeUpDown)
    }

    override func draw(_ dirtyRect: NSRect) {
        // 1px separator line at the bottom of the divider
        NSColor.separatorColor.setFill()
        NSBezierPath.fill(NSRect(x: 0, y: 0, width: bounds.width, height: 1))
        // Three subtle horizontal grip indicator lines
        let cx = bounds.midX
        let cy = bounds.midY
        NSColor.tertiaryLabelColor.setFill()
        for offset: CGFloat in [-2, 0, 2] {
            NSBezierPath.fill(NSRect(x: cx - 8, y: cy + offset, width: 16, height: 0.5))
        }
    }

    override func mouseDown(with event: NSEvent) {
        dragStartY = NSEvent.mouseLocation.y
    }

    override func mouseDragged(with event: NSEvent) {
        let currentY = NSEvent.mouseLocation.y
        let delta = currentY - dragStartY  // screen Y increases upward; drag up = positive = taller
        dragStartY = currentY
        onDrag?(delta)
    }

    override func mouseUp(with event: NSEvent) {
        onDragEnd?()
    }
}

// MARK: - CollectionScopeFilter

/// The active scope filter for the collections list.
enum CollectionScopeFilter: Int, CaseIterable {
    case all = 0
    case builtIn = 1
    case appWide = 2
    case project = 3

    var title: String {
        switch self {
        case .all: return "All"
        case .builtIn: return "Built-in"
        case .appWide: return "App"
        case .project: return "Project"
        }
    }

    /// Whether a given collection tier matches this filter.
    func matches(_ tier: CollectionTier) -> Bool {
        switch self {
        case .all: return true
        case .builtIn: return tier == .builtin
        case .appWide: return tier == .appWide
        case .project: return tier == .project
        }
    }
}

// MARK: - OutlineItem Wrappers

/// Wraps a `TaxaCollection` for use as an NSOutlineView parent item.
///
/// NSOutlineView uses object identity to track items. Since `TaxaCollection`
/// is a value type (struct), we wrap it in a reference type so the outline
/// view can identify it across reloads.
final class CollectionItem: NSObject {
    let collection: TaxaCollection

    /// Whether each taxon entry is enabled for extraction. Keyed by tax ID.
    var enabledTaxa: [Int: Bool]

    init(collection: TaxaCollection) {
        self.collection = collection
        self.enabledTaxa = Dictionary(uniqueKeysWithValues: collection.taxa.map { ($0.taxId, true) })
    }

    /// Returns the enabled `TaxonTarget` entries.
    var enabledTargets: [TaxonTarget] {
        collection.taxa.filter { enabledTaxa[$0.taxId] ?? true }
    }
}

/// Wraps a `TaxonTarget` entry within a collection for NSOutlineView child items.
final class TaxonEntryItem: NSObject {
    let target: TaxonTarget
    weak var parent: CollectionItem?

    /// Number of reads detected for this taxon in the current classification result.
    var detectedReads: Int = 0

    init(target: TaxonTarget, parent: CollectionItem) {
        self.target = target
        self.parent = parent
    }
}

// MARK: - Column Identifiers

private extension NSUserInterfaceItemIdentifier {
    static let collectionName = NSUserInterfaceItemIdentifier("collectionName")
    static let taxId = NSUserInterfaceItemIdentifier("taxId")
    static let rank = NSUserInterfaceItemIdentifier("rank")
    static let matchStatus = NSUserInterfaceItemIdentifier("matchStatus")
    static let action = NSUserInterfaceItemIdentifier("action")
}

// MARK: - TaxaCollectionsDrawerView

/// A bottom drawer showing taxa collections for batch extraction.
///
/// ## Layout
///
/// ```
/// +------------------------------------------------------------------+
/// | [===== Drag Handle =====] (8pt)                                  |
/// +------------------------------------------------------------------+
/// | Taxa Collections                              [+ New] [Toggle ]  |
/// +------------------------------------------------------------------+
/// | [All] [Built-in] [App] [Project]        [Filter: ____________]   |
/// +------------------------------------------------------------------+
/// |  > Respiratory Viruses (12 taxa)                       [Extract] |
/// |  > Enteric Viruses (6 taxa)                            [Extract] |
/// |  > Wastewater Surveillance (6 taxa)                    [Extract] |
/// |  > AMR Organisms (6 taxa)                              [Extract] |
/// |  ...                                                             |
/// +------------------------------------------------------------------+
/// ```
///
/// The drawer uses an `NSOutlineView` to show collections with expandable
/// taxa entries. Each collection row has an SF Symbol icon, name, taxa count
/// badge, and an "Extract" button. When expanded, individual taxon rows show
/// a checkbox, name, tax ID, and a detection status indicator.
///
/// ## Thread Safety
///
/// This class is `@MainActor` isolated. All data source and delegate methods
/// run on the main thread.
@MainActor
public final class TaxaCollectionsDrawerView: NSView {

    // MARK: - Delegate

    weak var delegate: TaxaCollectionsDrawerDelegate?

    // MARK: - Data

    /// All collection items, unfiltered.
    private var allItems: [CollectionItem] = []

    /// Filtered collection items based on scope and search.
    private var filteredItems: [CollectionItem] = []

    /// Lazily built child item cache: parent CollectionItem -> [TaxonEntryItem].
    private var childItemCache: [ObjectIdentifier: [TaxonEntryItem]] = [:]

    /// Current scope filter selection.
    private var scopeFilter: CollectionScopeFilter = .all

    /// Current search filter text.
    private var searchText: String = ""

    /// The taxonomy tree from the current classification result, for match status.
    private var tree: TaxonTree?

    // MARK: - Callbacks

    /// Called when the user clicks "Extract" on a collection.
    var onBatchExtract: ((TaxaCollection) -> Void)?

    // MARK: - Subviews

    let dividerView = TaxaCollectionsDividerView()
    private let headerBar = NSView()
    private let titleLabel = NSTextField(labelWithString: "Taxa Collections")
    private let scopeFilterControl = NSSegmentedControl()
    private let searchField = NSSearchField()
    private let scrollView = NSScrollView()
    let outlineView = NSOutlineView()

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
        setupDivider()
        setupHeader()
        setupScopeFilter()
        setupOutlineView()
        layoutAllSubviews()
        loadCollections()

        setAccessibilityRole(.group)
        setAccessibilityLabel("Taxa Collections Drawer")
    }

    // MARK: - Public API

    /// Updates the taxonomy tree used for match status indicators.
    ///
    /// After setting the tree, the drawer recomputes which taxa in each
    /// collection were detected in the current classification result.
    ///
    /// - Parameter tree: The taxonomy tree from the current classification result.
    func setTree(_ tree: TaxonTree?) {
        self.tree = tree
        updateMatchStatus()
        outlineView.reloadData()
    }

    /// Returns the number of currently displayed collections (after filtering).
    var displayedCollectionCount: Int {
        filteredItems.count
    }

    /// Returns the collection item at the given index, or `nil` if out of range.
    func collectionItem(at index: Int) -> CollectionItem? {
        guard index >= 0, index < filteredItems.count else { return nil }
        return filteredItems[index]
    }

    // MARK: - Setup: Divider

    private func setupDivider() {
        dividerView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(dividerView)

        dividerView.onDrag = { [weak self] delta in
            guard let self else { return }
            self.delegate?.taxaCollectionsDrawerDidDragDivider(self, deltaY: delta)
        }
        dividerView.onDragEnd = { [weak self] in
            guard let self else { return }
            self.delegate?.taxaCollectionsDrawerDidFinishDraggingDivider(self)
        }
    }

    // MARK: - Setup: Header

    private func setupHeader() {
        headerBar.translatesAutoresizingMaskIntoConstraints = false
        addSubview(headerBar)

        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.font = .systemFont(ofSize: 13, weight: .bold)
        titleLabel.textColor = .labelColor
        headerBar.addSubview(titleLabel)
    }

    // MARK: - Setup: Scope Filter + Search

    private func setupScopeFilter() {
        scopeFilterControl.translatesAutoresizingMaskIntoConstraints = false
        scopeFilterControl.segmentStyle = .rounded
        scopeFilterControl.segmentCount = CollectionScopeFilter.allCases.count
        for (index, scope) in CollectionScopeFilter.allCases.enumerated() {
            scopeFilterControl.setLabel(scope.title, forSegment: index)
            scopeFilterControl.setWidth(0, forSegment: index)  // auto-width
        }
        scopeFilterControl.selectedSegment = 0
        scopeFilterControl.target = self
        scopeFilterControl.action = #selector(scopeFilterChanged(_:))
        headerBar.addSubview(scopeFilterControl)

        searchField.translatesAutoresizingMaskIntoConstraints = false
        searchField.placeholderString = "Filter collections..."
        searchField.delegate = self
        searchField.sendsSearchStringImmediately = true
        searchField.sendsWholeSearchString = false
        headerBar.addSubview(searchField)
    }

    // MARK: - Setup: Outline View

    private func setupOutlineView() {
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        addSubview(scrollView)

        outlineView.headerView = nil
        outlineView.rowHeight = 28
        outlineView.intercellSpacing = NSSize(width: 4, height: 0)
        outlineView.usesAlternatingRowBackgroundColors = false
        outlineView.allowsMultipleSelection = false
        outlineView.indentationPerLevel = 18

        // Name column (flexible)
        let nameColumn = NSTableColumn(identifier: .collectionName)
        nameColumn.title = "Name"
        nameColumn.minWidth = 200
        nameColumn.resizingMask = .autoresizingMask
        outlineView.addTableColumn(nameColumn)

        // Tax ID column (fixed)
        let taxIdColumn = NSTableColumn(identifier: .taxId)
        taxIdColumn.title = "Tax ID"
        taxIdColumn.width = 80
        taxIdColumn.minWidth = 60
        taxIdColumn.maxWidth = 100
        outlineView.addTableColumn(taxIdColumn)

        // Action column (fixed, for Extract button)
        let actionColumn = NSTableColumn(identifier: .action)
        actionColumn.title = ""
        actionColumn.width = 70
        actionColumn.minWidth = 70
        actionColumn.maxWidth = 70
        outlineView.addTableColumn(actionColumn)

        outlineView.outlineTableColumn = nameColumn
        outlineView.dataSource = self
        outlineView.delegate = self

        scrollView.documentView = outlineView

        outlineView.setAccessibilityLabel("Taxa Collections List")
    }

    // MARK: - Layout

    private func layoutAllSubviews() {
        NSLayoutConstraint.activate([
            // Divider at top (8pt)
            dividerView.topAnchor.constraint(equalTo: topAnchor),
            dividerView.leadingAnchor.constraint(equalTo: leadingAnchor),
            dividerView.trailingAnchor.constraint(equalTo: trailingAnchor),
            dividerView.heightAnchor.constraint(equalToConstant: 8),

            // Header bar below divider (60pt: title row + scope/search row)
            headerBar.topAnchor.constraint(equalTo: dividerView.bottomAnchor),
            headerBar.leadingAnchor.constraint(equalTo: leadingAnchor),
            headerBar.trailingAnchor.constraint(equalTo: trailingAnchor),
            headerBar.heightAnchor.constraint(equalToConstant: 60),

            // Title label (top row of header, 32pt)
            titleLabel.leadingAnchor.constraint(equalTo: headerBar.leadingAnchor, constant: 12),
            titleLabel.topAnchor.constraint(equalTo: headerBar.topAnchor, constant: 6),

            // Scope filter (bottom row of header)
            scopeFilterControl.leadingAnchor.constraint(equalTo: headerBar.leadingAnchor, constant: 12),
            scopeFilterControl.bottomAnchor.constraint(equalTo: headerBar.bottomAnchor, constant: -6),

            // Search field (bottom row, right-aligned)
            searchField.trailingAnchor.constraint(equalTo: headerBar.trailingAnchor, constant: -12),
            searchField.centerYAnchor.constraint(equalTo: scopeFilterControl.centerYAnchor),
            searchField.widthAnchor.constraint(equalToConstant: 160),
            searchField.leadingAnchor.constraint(greaterThanOrEqualTo: scopeFilterControl.trailingAnchor, constant: 12),

            // Scroll view (fills remaining space)
            scrollView.topAnchor.constraint(equalTo: headerBar.bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    // MARK: - Data Loading

    /// Loads collections from all tiers.
    ///
    /// Currently only loads built-in collections. App-wide and project-specific
    /// collections will be loaded from disk in a future phase.
    private func loadCollections() {
        allItems = TaxaCollection.builtIn.map { CollectionItem(collection: $0) }
        applyFilters()
    }

    /// Applies scope and search filters to produce the displayed list.
    private func applyFilters() {
        filteredItems = allItems.filter { item in
            // Scope filter
            guard scopeFilter.matches(item.collection.tier) else { return false }

            // Search filter
            if !searchText.isEmpty {
                let lowered = searchText.lowercased()
                let nameMatch = item.collection.name.lowercased().contains(lowered)
                let taxaMatch = item.collection.taxa.contains { target in
                    target.name.lowercased().contains(lowered)
                        || target.displayName.lowercased().contains(lowered)
                }
                return nameMatch || taxaMatch
            }

            return true
        }

        childItemCache.removeAll()
        outlineView.reloadData()
    }

    /// Computes match status for each taxon entry against the current tree.
    private func updateMatchStatus() {
        for item in allItems {
            let key = ObjectIdentifier(item)
            if let children = childItemCache[key] {
                for child in children {
                    child.detectedReads = tree?.node(taxId: child.target.taxId)?.readsClade ?? 0
                }
            }
        }
    }

    // MARK: - Child Item Cache

    /// Returns or creates child items for a collection item.
    private func childItems(for parent: CollectionItem) -> [TaxonEntryItem] {
        let key = ObjectIdentifier(parent)
        if let cached = childItemCache[key] {
            return cached
        }
        let children = parent.collection.taxa.map { target -> TaxonEntryItem in
            let entry = TaxonEntryItem(target: target, parent: parent)
            entry.detectedReads = tree?.node(taxId: target.taxId)?.readsClade ?? 0
            return entry
        }
        childItemCache[key] = children
        return children
    }

    // MARK: - Actions

    @objc private func scopeFilterChanged(_ sender: NSSegmentedControl) {
        scopeFilter = CollectionScopeFilter(rawValue: sender.selectedSegment) ?? .all
        applyFilters()
    }

    @objc private func extractButtonClicked(_ sender: NSButton) {
        let row = outlineView.row(for: sender)
        guard row >= 0 else { return }

        let item = outlineView.item(atRow: row)
        if let collectionItem = item as? CollectionItem {
            drawerLogger.info("Extract requested for collection: \(collectionItem.collection.name, privacy: .public)")
            delegate?.taxaCollectionsDrawer(self, didRequestExtractFor: collectionItem.collection)
            onBatchExtract?(collectionItem.collection)
        }
    }

    @objc private func checkboxToggled(_ sender: NSButton) {
        let row = outlineView.row(for: sender)
        guard row >= 0, let entryItem = outlineView.item(atRow: row) as? TaxonEntryItem else { return }
        guard let parent = entryItem.parent else { return }
        parent.enabledTaxa[entryItem.target.taxId] = (sender.state == .on)
    }
}

// MARK: - NSOutlineViewDataSource

extension TaxaCollectionsDrawerView: NSOutlineViewDataSource {

    public func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        if item == nil {
            return filteredItems.count
        }
        if let collectionItem = item as? CollectionItem {
            return childItems(for: collectionItem).count
        }
        return 0
    }

    public func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        if item == nil {
            return filteredItems[index]
        }
        if let collectionItem = item as? CollectionItem {
            return childItems(for: collectionItem)[index]
        }
        fatalError("Unexpected item type in outline view data source")
    }

    public func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        item is CollectionItem
    }
}

// MARK: - NSOutlineViewDelegate

extension TaxaCollectionsDrawerView: NSOutlineViewDelegate {

    public func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let columnID = tableColumn?.identifier else { return nil }

        if let collectionItem = item as? CollectionItem {
            return viewForCollection(collectionItem, column: columnID)
        }

        if let entryItem = item as? TaxonEntryItem {
            return viewForEntry(entryItem, column: columnID)
        }

        return nil
    }

    // MARK: - Collection Row Views

    /// Creates a view for a collection-level row.
    private func viewForCollection(_ item: CollectionItem, column: NSUserInterfaceItemIdentifier) -> NSView? {
        switch column {
        case .collectionName:
            let cell = NSTableCellView()

            // SF Symbol icon
            let image = NSImage(systemSymbolName: item.collection.sfSymbol, accessibilityDescription: nil)
                ?? NSImage(systemSymbolName: "square.stack.3d.up", accessibilityDescription: "Collection")!
            let imageView = NSImageView(image: image)
            imageView.translatesAutoresizingMaskIntoConstraints = false
            imageView.contentTintColor = .secondaryLabelColor
            imageView.setContentHuggingPriority(.required, for: .horizontal)
            cell.addSubview(imageView)

            // Name label
            let nameLabel = NSTextField(labelWithString: item.collection.name)
            nameLabel.translatesAutoresizingMaskIntoConstraints = false
            nameLabel.font = .systemFont(ofSize: 13, weight: .medium)
            nameLabel.lineBreakMode = .byTruncatingTail
            cell.addSubview(nameLabel)
            cell.textField = nameLabel

            // Taxa count badge
            let countLabel = NSTextField(labelWithString: "(\(item.collection.taxonCount) taxa)")
            countLabel.translatesAutoresizingMaskIntoConstraints = false
            countLabel.font = .systemFont(ofSize: 10)
            countLabel.textColor = .secondaryLabelColor
            countLabel.setContentHuggingPriority(.required, for: .horizontal)
            cell.addSubview(countLabel)

            NSLayoutConstraint.activate([
                imageView.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
                imageView.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                imageView.widthAnchor.constraint(equalToConstant: 16),
                imageView.heightAnchor.constraint(equalToConstant: 16),

                nameLabel.leadingAnchor.constraint(equalTo: imageView.trailingAnchor, constant: 6),
                nameLabel.centerYAnchor.constraint(equalTo: cell.centerYAnchor),

                countLabel.leadingAnchor.constraint(equalTo: nameLabel.trailingAnchor, constant: 6),
                countLabel.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                countLabel.trailingAnchor.constraint(lessThanOrEqualTo: cell.trailingAnchor, constant: -4),
            ])

            return cell

        case .taxId:
            // Empty for collection rows
            return NSTableCellView()

        case .action:
            let cell = NSTableCellView()
            let button = NSButton(title: "Extract", target: self, action: #selector(extractButtonClicked(_:)))
            button.translatesAutoresizingMaskIntoConstraints = false
            button.bezelStyle = .accessoryBarAction
            button.controlSize = .small
            button.font = .systemFont(ofSize: 10)
            button.setAccessibilityLabel("Extract all taxa in \(item.collection.name)")
            cell.addSubview(button)

            NSLayoutConstraint.activate([
                button.centerXAnchor.constraint(equalTo: cell.centerXAnchor),
                button.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            ])

            return cell

        default:
            return nil
        }
    }

    // MARK: - Entry Row Views

    /// Creates a view for a taxon entry row within an expanded collection.
    private func viewForEntry(_ item: TaxonEntryItem, column: NSUserInterfaceItemIdentifier) -> NSView? {
        switch column {
        case .collectionName:
            let cell = NSTableCellView()

            // Checkbox
            let checkbox = NSButton(checkboxWithTitle: "", target: self, action: #selector(checkboxToggled(_:)))
            checkbox.translatesAutoresizingMaskIntoConstraints = false
            let isEnabled = item.parent?.enabledTaxa[item.target.taxId] ?? true
            checkbox.state = isEnabled ? .on : .off
            checkbox.setAccessibilityLabel("Enable \(item.target.displayName) for extraction")
            cell.addSubview(checkbox)

            // Detection indicator
            let detected = item.detectedReads > 0
            let indicatorSymbol = detected ? "circle.fill" : "circle"
            let indicatorColor: NSColor = detected ? .systemGreen : .tertiaryLabelColor
            let indicator = NSImageView(
                image: NSImage(systemSymbolName: indicatorSymbol, accessibilityDescription: detected ? "Detected" : "Not detected")!
            )
            indicator.translatesAutoresizingMaskIntoConstraints = false
            indicator.contentTintColor = indicatorColor
            indicator.setContentHuggingPriority(.required, for: .horizontal)
            if detected {
                let formatter = NumberFormatter()
                formatter.numberStyle = .decimal
                let readStr = formatter.string(from: NSNumber(value: item.detectedReads)) ?? "\(item.detectedReads)"
                indicator.toolTip = "\(readStr) reads"
            }
            cell.addSubview(indicator)

            // Name label
            let displayName = item.target.displayName
            let nameLabel = NSTextField(labelWithString: displayName)
            nameLabel.translatesAutoresizingMaskIntoConstraints = false
            nameLabel.font = .systemFont(ofSize: 13)
            nameLabel.lineBreakMode = .byTruncatingTail
            if !detected {
                nameLabel.textColor = .tertiaryLabelColor
                // Apply strikethrough via attributed string
                let attributes: [NSAttributedString.Key: Any] = [
                    .strikethroughStyle: NSUnderlineStyle.single.rawValue,
                    .foregroundColor: NSColor.tertiaryLabelColor,
                    .font: NSFont.systemFont(ofSize: 13),
                ]
                nameLabel.attributedStringValue = NSAttributedString(string: displayName, attributes: attributes)
            }
            cell.addSubview(nameLabel)
            cell.textField = nameLabel

            // Include-children indicator
            if item.target.includeChildren {
                let childrenLabel = NSTextField(labelWithString: "+children")
                childrenLabel.translatesAutoresizingMaskIntoConstraints = false
                childrenLabel.font = .systemFont(ofSize: 9)
                childrenLabel.textColor = .tertiaryLabelColor
                childrenLabel.setContentHuggingPriority(.required, for: .horizontal)
                cell.addSubview(childrenLabel)

                NSLayoutConstraint.activate([
                    checkbox.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
                    checkbox.centerYAnchor.constraint(equalTo: cell.centerYAnchor),

                    indicator.leadingAnchor.constraint(equalTo: checkbox.trailingAnchor, constant: 4),
                    indicator.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                    indicator.widthAnchor.constraint(equalToConstant: 8),
                    indicator.heightAnchor.constraint(equalToConstant: 8),

                    nameLabel.leadingAnchor.constraint(equalTo: indicator.trailingAnchor, constant: 6),
                    nameLabel.centerYAnchor.constraint(equalTo: cell.centerYAnchor),

                    childrenLabel.leadingAnchor.constraint(equalTo: nameLabel.trailingAnchor, constant: 4),
                    childrenLabel.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                    childrenLabel.trailingAnchor.constraint(lessThanOrEqualTo: cell.trailingAnchor, constant: -4),
                ])
            } else {
                NSLayoutConstraint.activate([
                    checkbox.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
                    checkbox.centerYAnchor.constraint(equalTo: cell.centerYAnchor),

                    indicator.leadingAnchor.constraint(equalTo: checkbox.trailingAnchor, constant: 4),
                    indicator.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                    indicator.widthAnchor.constraint(equalToConstant: 8),
                    indicator.heightAnchor.constraint(equalToConstant: 8),

                    nameLabel.leadingAnchor.constraint(equalTo: indicator.trailingAnchor, constant: 6),
                    nameLabel.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                    nameLabel.trailingAnchor.constraint(lessThanOrEqualTo: cell.trailingAnchor, constant: -4),
                ])
            }

            return cell

        case .taxId:
            let cell = NSTableCellView()
            let label = NSTextField(labelWithString: "\(item.target.taxId)")
            label.translatesAutoresizingMaskIntoConstraints = false
            label.font = .monospacedSystemFont(ofSize: 10, weight: .regular)
            label.textColor = .tertiaryLabelColor
            label.alignment = .right
            cell.addSubview(label)
            cell.textField = label

            NSLayoutConstraint.activate([
                label.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4),
                label.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            ])

            return cell

        case .action:
            // Empty for entry rows
            return NSTableCellView()

        default:
            return nil
        }
    }
}

// MARK: - NSSearchFieldDelegate

extension TaxaCollectionsDrawerView: NSSearchFieldDelegate {

    public func controlTextDidChange(_ obj: Notification) {
        guard let field = obj.object as? NSSearchField else { return }
        searchText = field.stringValue
        applyFilters()
    }
}
