// ViralDetectionTableView.swift - Hierarchical viral detection table with NSOutlineView
// Copyright (c) 2025 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import LungfishIO
import SwiftUI

// MARK: - ViralDetectionTableView

/// A hierarchical table using `NSOutlineView` for browsing EsViritu viral detections.
///
/// Displays viral assemblies as expandable parent rows with individual contig
/// detections as child rows. Supports sorting, searching/filtering, and context
/// menu actions for BLAST verification and sequence extraction.
///
/// ## Columns
///
/// | Column     | Content                                |
/// |------------|----------------------------------------|
/// | Virus Name | Name with family-colored indicator dot |
/// | Family     | Taxonomic family                       |
/// | Reads      | Mapped read count                      |
/// | RPKMF      | Reads per kilobase per million filtered |
/// | Coverage   | Sparkline + mean coverage depth        |
/// | Identity   | Average read identity percent          |
/// | Segment    | Genome segment label (contigs only)    |
///
/// ## Data Model
///
/// Parent rows represent ``ViralAssembly`` (assembly-level aggregates).
/// Child rows represent ``ViralDetection`` (per-contig details).
/// The outline view uses `Any` items: either a ``ViralAssemblyItem`` wrapper
/// (parent) or a ``ViralDetectionItem`` wrapper (child), both reference types
/// to satisfy NSOutlineView's identity requirements.
///
/// ## Usage
///
/// ```swift
/// let tableView = ViralDetectionTableView()
/// tableView.result = parsedResult
/// tableView.onAssemblySelected = { assembly in
///     // update detail view
/// }
/// ```
@MainActor
public final class ViralDetectionTableView: NSView, NSOutlineViewDataSource, NSOutlineViewDelegate, NSMenuItemValidation {

    // MARK: - Item Wrappers

    /// Reference-type wrapper for ``ViralAssembly`` to satisfy NSOutlineView identity.
    final class ViralAssemblyItem {
        let assembly: ViralAssembly
        var children: [ViralDetectionItem]

        init(assembly: ViralAssembly) {
            self.assembly = assembly
            self.children = assembly.contigs.map { ViralDetectionItem(detection: $0) }
        }
    }

    /// Reference-type wrapper for ``ViralDetection`` to satisfy NSOutlineView identity.
    final class ViralDetectionItem {
        let detection: ViralDetection

        init(detection: ViralDetection) {
            self.detection = detection
        }
    }

    // MARK: - Data Properties

    /// The EsViritu result to display.
    ///
    /// Setting this property rebuilds the item tree and reloads the outline view.
    public var result: EsVirituResult? {
        didSet {
            rebuildItems()
            filterText = ""
            filteredItems = nil
            refreshSortedItems()
            reloadData()
        }
    }

    /// Coverage windows indexed by accession for sparkline rendering.
    public var coverageWindowsByAccession: [String: [ViralCoverageWindow]] = [:]

    /// Unique (deduplicated) read counts per assembly, keyed by assembly accession.
    /// This is the sum of per-contig unique reads for multi-segment viruses.
    public var uniqueReadCountsByAssembly: [String: Int] = [:]

    /// Unique read counts keyed by "sampleId\tassemblyAccession" for batch mode.
    public var uniqueReadCountsBySampleAssembly: [String: Int] = [:]

    /// Unique (deduplicated) read counts per contig/segment, keyed by contig accession.
    public var uniqueReadCountsByContig: [String: Int] = [:]

    /// Unique read counts keyed by "sampleId\tcontigAccession" for batch mode.
    public var uniqueReadCountsBySampleContig: [String: Int] = [:]

    /// Updates the unique read count for an assembly and refreshes its row.
    public func setUniqueReadCount(_ count: Int, forAssembly accession: String) {
        uniqueReadCountsByAssembly[accession] = count
        // Find and reload the assembly row
        let items = sortedDisplayItems
        if let idx = items.firstIndex(where: { $0.assembly.assembly == accession }) {
            reloadItemPreservingSelection(items[idx], reloadChildren: false)
        }
    }

    /// Updates the unique read count for a single contig/segment and refreshes the display.
    ///
    /// Also recomputes the parent assembly total as the sum of its contig unique reads.
    public func setUniqueReadCount(_ count: Int, forContig contigAccession: String, inAssembly assemblyAccession: String) {
        uniqueReadCountsByContig[contigAccession] = count

        // Recompute assembly total from per-contig values
        let items = sortedDisplayItems
        if let item = items.first(where: { item in
            item.assembly.assembly == assemblyAccession
                && item.assembly.contigs.contains(where: { $0.accession == contigAccession })
        }) {
            let assemblyTotal = item.assembly.contigs.reduce(0) { sum, contig in
                let sampleId = contig.sampleId
                return sum + (uniqueReadCountsBySampleContig["\(sampleId)\t\(contig.accession)"]
                    ?? uniqueReadCountsByContig[contig.accession]
                    ?? 0)
            }
            uniqueReadCountsByAssembly[assemblyAccession] = assemblyTotal
            uniqueReadCountsBySampleAssembly[assemblyKey(for: item.assembly)] = assemblyTotal

            // Reload the assembly row and its children
            reloadItemPreservingSelection(item, reloadChildren: true)
        }
    }

    /// Returns the contig-level GenBank accessions for all selected rows.
    ///
    /// For assembly rows, expands to all constituent contig accessions so the
    /// returned values match BAM @SQ reference names (which use GenBank contig
    /// accessions, not GCF assembly accessions).
    /// For detection (contig) rows, returns the contig accession directly.
    public func selectedAssemblyAccessions() -> [String] {
        var accessions: [String] = []
        for row in outlineView.selectedRowIndexes {
            guard let item = outlineView.item(atRow: row) else { continue }
            if let assemblyItem = item as? ViralAssemblyItem {
                // Expand assembly to its constituent contig accessions so they
                // match the BAM reference names (GenBank accessions, not GCF).
                let contigAccessions = assemblyItem.assembly.contigs.map(\.accession)
                accessions.append(contentsOf: contigAccessions)
            } else if let detectionItem = item as? ViralDetectionItem {
                accessions.append(detectionItem.detection.accession)
            }
        }
        return accessions
    }

    /// Returns sample IDs represented by the current selection.
    ///
    /// Assembly rows contribute the sample ID of their first contig.
    /// Detection rows contribute the detection's sample ID directly.
    public func selectedSampleIDs() -> [String] {
        var sampleIds: [String] = []
        for row in outlineView.selectedRowIndexes {
            guard let item = outlineView.item(atRow: row) else { continue }
            if let assemblyItem = item as? ViralAssemblyItem {
                if let sampleId = assemblyItem.assembly.contigs.first?.sampleId {
                    sampleIds.append(sampleId)
                }
            } else if let detectionItem = item as? ViralDetectionItem {
                sampleIds.append(detectionItem.detection.sampleId)
            }
        }
        return sampleIds
    }

    private func reloadItemPreservingSelection(_ item: Any, reloadChildren: Bool) {
        let selectedItems: [Any] = outlineView.selectedRowIndexes.compactMap { row in
            let selected = outlineView.item(atRow: row)
            return selected as Any
        }

        suppressSelectionCallback = true
        outlineView.reloadItem(item, reloadChildren: reloadChildren)

        let rowsToReselect = IndexSet(selectedItems.compactMap { selected in
            let row = outlineView.row(forItem: selected)
            return row >= 0 ? row : nil
        })
        if !rowsToReselect.isEmpty {
            outlineView.selectRowIndexes(rowsToReselect, byExtendingSelection: false)
        }
        suppressSelectionCallback = false
    }

    /// Called when the user selects an assembly row.
    /// Pass `nil` when the selection is cleared.
    public var onAssemblySelected: ((ViralAssembly?) -> Void)?

    /// Called when the user selects a detection (contig) row.
    public var onDetectionSelected: ((ViralDetection) -> Void)?

    /// Called when multiple rows are selected. Parameter is the count.
    public var onMultipleSelected: ((Int) -> Void)?

    /// Called when the user requests BLAST verification via context menu.
    ///
    /// Parameters:
    /// - detection: Representative detection row for the selected virus.
    /// - readCount: Number of unique reads requested for BLAST.
    /// - accessions: One or more target accessions to extract reads from.
    public var onBlastRequested: ((ViralDetection, Int, [String]) -> Void)?

    /// Called when the user invokes "Extract Reads…" from the context menu.
    /// The VC reads the current selection from the table view itself via
    /// `selectedAssemblyAccessions()` / `selectedSampleIDs()`.
    public var onExtractReadsRequested: (() -> Void)?

    // MARK: - Internal State

    /// The flat list of assembly items (parent rows).
    private var assemblyItems: [ViralAssemblyItem] = []

    /// Filtered subset of assembly items. `nil` means no filter.
    private var filteredItems: [ViralAssemblyItem]?

    /// Current filter text. Empty string means no filter.
    private var filterText: String = "" {
        didSet {
            if filterText != oldValue {
                applyFilter()
            }
        }
    }

    /// Current sort key and direction.
    private var currentSortKey: String = ColumnID.reads
    private var currentSortAscending: Bool = false

    /// Suppresses selection callback during programmatic selection changes.
    private var suppressSelectionCallback = false

    /// Cached root items in their current sorted order.
    private var sortedDisplayItems: [ViralAssemblyItem] = []

    /// Shared formatter for integer read counts.
    private static let countFormatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.groupingSeparator = ","
        return formatter
    }()

    // MARK: - Subviews

    // MARK: - Metadata Columns

    /// Controller for dynamic sample metadata columns (from imported CSV/TSV).
    let metadataColumns = MetadataColumnController()

    private let scrollView = NSScrollView()
    private let outlineView = NSOutlineView()
    private let searchField = NSSearchField()
    private let countLabel = NSTextField(labelWithString: "")

    // MARK: - Column Identifiers

    private enum ColumnID {
        static let sample = "sample"
        static let name = "name"
        static let family = "family"
        static let reads = "reads"
        static let uniqueReads = "uniqueReads"
        static let rpkmf = "rpkmf"
        static let coverage = "coverage"
        static let identity = "identity"
        static let segment = "segment"
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
        searchField.placeholderString = "Filter viruses..."
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
        nameCol.title = "Virus Name"
        nameCol.minWidth = 160
        nameCol.width = 220
        nameCol.sortDescriptorPrototype = NSSortDescriptor(key: ColumnID.name, ascending: true)
        outlineView.addTableColumn(nameCol)

        // Family column
        let familyCol = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(ColumnID.family))
        familyCol.title = "Family"
        familyCol.width = 100
        familyCol.minWidth = 60
        familyCol.sortDescriptorPrototype = NSSortDescriptor(key: ColumnID.family, ascending: true)
        outlineView.addTableColumn(familyCol)

        // Reads column
        let readsCol = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(ColumnID.reads))
        readsCol.title = "Reads"
        readsCol.width = 70
        readsCol.minWidth = 50
        readsCol.sortDescriptorPrototype = NSSortDescriptor(key: ColumnID.reads, ascending: false)
        outlineView.addTableColumn(readsCol)

        // Unique Reads column
        let uniqueReadsCol = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(ColumnID.uniqueReads))
        uniqueReadsCol.title = "Unique Reads"
        uniqueReadsCol.width = 85
        uniqueReadsCol.minWidth = 60
        uniqueReadsCol.sortDescriptorPrototype = NSSortDescriptor(key: ColumnID.uniqueReads, ascending: false)
        outlineView.addTableColumn(uniqueReadsCol)

        // RPKMF column
        let rpkmfCol = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(ColumnID.rpkmf))
        rpkmfCol.title = "RPKMF"
        rpkmfCol.width = 70
        rpkmfCol.minWidth = 50
        rpkmfCol.sortDescriptorPrototype = NSSortDescriptor(key: ColumnID.rpkmf, ascending: false)
        outlineView.addTableColumn(rpkmfCol)

        // Coverage column (sparkline + text)
        let covCol = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(ColumnID.coverage))
        covCol.title = "Coverage"
        covCol.width = 120
        covCol.minWidth = 80
        covCol.sortDescriptorPrototype = NSSortDescriptor(key: ColumnID.coverage, ascending: false)
        outlineView.addTableColumn(covCol)

        // Identity column
        let idCol = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(ColumnID.identity))
        idCol.title = "Identity"
        idCol.width = 65
        idCol.minWidth = 45
        idCol.sortDescriptorPrototype = NSSortDescriptor(key: ColumnID.identity, ascending: false)
        outlineView.addTableColumn(idCol)

        // Segment column
        let segCol = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(ColumnID.segment))
        segCol.title = "Segment"
        segCol.width = 60
        segCol.minWidth = 40
        segCol.sortDescriptorPrototype = NSSortDescriptor(key: ColumnID.segment, ascending: true)
        outlineView.addTableColumn(segCol)

        outlineView.outlineTableColumn = nameCol
        outlineView.dataSource = self
        outlineView.delegate = self
        outlineView.menu = buildContextMenu()
        outlineView.usesAlternatingRowBackgroundColors = true
        outlineView.rowHeight = 24
        outlineView.allowsColumnReordering = true
        outlineView.allowsMultipleSelection = true
        outlineView.headerView = NSTableHeaderView()
        outlineView.indentationPerLevel = 16

        // Install metadata column controller for dynamic sample metadata columns.
        metadataColumns.standardColumnNames = [
            "Sample", "Virus Name", "Family", "Reads", "Unique Reads", "RPKMF", "Coverage", "Identity", "Segment",
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
        let searchTop = searchField.topAnchor.constraint(equalTo: topAnchor, constant: 4)
        let searchLeading = searchField.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8)
        let searchHeight = searchField.heightAnchor.constraint(equalToConstant: 24)
        let labelGap = countLabel.leadingAnchor.constraint(equalTo: searchField.trailingAnchor, constant: 8)
        let labelTrailing = countLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8)
        let scrollBottom = scrollView.bottomAnchor.constraint(equalTo: bottomAnchor)

        // Use .defaultHigh priority for padding constraints so they don't
        // conflict with NSSplitView's zero-size initial layout.
        for c in [searchTop, searchLeading, searchHeight, labelGap, labelTrailing, scrollBottom] {
            c.priority = .defaultHigh
        }

        NSLayoutConstraint.activate([
            searchTop,
            searchLeading,
            searchHeight,

            countLabel.centerYAnchor.constraint(equalTo: searchField.centerYAnchor),
            labelGap,
            labelTrailing,

            scrollView.topAnchor.constraint(equalTo: searchField.bottomAnchor, constant: 4),
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollBottom,
        ])
    }

    // MARK: - Item Rebuilding

    /// Rebuilds the reference-type item wrappers from the current result.
    private func rebuildItems() {
        guard let result else {
            assemblyItems = []
            return
        }
        assemblyItems = result.assemblies.map { ViralAssemblyItem(assembly: $0) }
    }

    /// Returns the items to display, respecting the current filter.
    private var displayItems: [ViralAssemblyItem] {
        filteredItems ?? assemblyItems
    }

    // MARK: - Data Reload

    private func reloadData() {
        refreshSortedItems()
        outlineView.reloadData()
        updateCountLabel()

        // Expand assemblies with more than one contig by default.
        for item in sortedDisplayItems where item.children.count > 1 {
            outlineView.expandItem(item)
        }
    }

    private func updateCountLabel() {
        let total = assemblyItems.count
        if let filtered = filteredItems {
            countLabel.stringValue = "\(filtered.count) of \(total) assemblies"
        } else {
            countLabel.stringValue = "\(total) assemblies"
        }
    }

    // MARK: - Search / Filter

    @objc private func searchFieldChanged(_ sender: NSSearchField) {
        filterText = sender.stringValue
    }

    private func applyFilter() {
        let query = filterText.trimmingCharacters(in: .whitespaces).lowercased()

        if query.isEmpty {
            filteredItems = nil
        } else {
            filteredItems = assemblyItems.filter { item in
                let assembly = item.assembly
                let sample = sampleID(for: assembly).lowercased()
                if sample.contains(query) { return true }
                if assembly.name.lowercased().contains(query) { return true }
                if assembly.family?.lowercased().contains(query) == true { return true }
                if assembly.genus?.lowercased().contains(query) == true { return true }
                if assembly.species?.lowercased().contains(query) == true { return true }
                if assembly.assembly.lowercased().contains(query) { return true }
                // Check contigs too
                return assembly.contigs.contains { contig in
                    contig.name.lowercased().contains(query) ||
                    contig.accession.lowercased().contains(query)
                }
            }
        }

        refreshSortedItems()
        outlineView.reloadData()
        updateCountLabel()

        // Expand all when filtering
        if filteredItems != nil {
            for item in sortedDisplayItems {
                outlineView.expandItem(item)
            }
        }
    }

    // MARK: - Selection

    /// Selects and scrolls to the row for the given assembly.
    public func selectAssembly(_ assembly: ViralAssembly) {
        guard let item = sortedDisplayItems.first(where: { $0.assembly.assembly == assembly.assembly }) else {
            return
        }

        let row = outlineView.row(forItem: item)
        if row >= 0 {
            suppressSelectionCallback = true
            outlineView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            outlineView.scrollRowToVisible(row)
            suppressSelectionCallback = false
        }
    }

    // MARK: - Sorting

    /// Recomputes and caches root-item ordering for the current display/sort state.
    private func refreshSortedItems() {
        sortedDisplayItems = sortItems(displayItems)
    }

    /// Returns a sorted copy of `items` using the current sort criteria.
    private func sortItems(_ items: [ViralAssemblyItem]) -> [ViralAssemblyItem] {
        var items = items

        switch currentSortKey {
        case ColumnID.sample:
            items.sort { currentSortAscending
                ? sampleID(for: $0.assembly).localizedCaseInsensitiveCompare(sampleID(for: $1.assembly)) == .orderedAscending
                : sampleID(for: $0.assembly).localizedCaseInsensitiveCompare(sampleID(for: $1.assembly)) == .orderedDescending
            }
        case ColumnID.name:
            items.sort { currentSortAscending
                ? $0.assembly.name.localizedCaseInsensitiveCompare($1.assembly.name) == .orderedAscending
                : $0.assembly.name.localizedCaseInsensitiveCompare($1.assembly.name) == .orderedDescending
            }
        case ColumnID.family:
            items.sort { currentSortAscending
                ? ($0.assembly.family ?? "").localizedCaseInsensitiveCompare($1.assembly.family ?? "") == .orderedAscending
                : ($0.assembly.family ?? "").localizedCaseInsensitiveCompare($1.assembly.family ?? "") == .orderedDescending
            }
        case ColumnID.reads:
            items.sort { currentSortAscending
                ? $0.assembly.totalReads < $1.assembly.totalReads
                : $0.assembly.totalReads > $1.assembly.totalReads
            }
        case ColumnID.uniqueReads:
            items.sort { a, b in
                let aVal = uniqueReadCountsBySampleAssembly[assemblyKey(for: a.assembly)]
                    ?? uniqueReadCountsByAssembly[a.assembly.assembly]
                    ?? 0
                let bVal = uniqueReadCountsBySampleAssembly[assemblyKey(for: b.assembly)]
                    ?? uniqueReadCountsByAssembly[b.assembly.assembly]
                    ?? 0
                return currentSortAscending ? aVal < bVal : aVal > bVal
            }
        case ColumnID.rpkmf:
            items.sort { currentSortAscending
                ? $0.assembly.rpkmf < $1.assembly.rpkmf
                : $0.assembly.rpkmf > $1.assembly.rpkmf
            }
        case ColumnID.coverage:
            items.sort { currentSortAscending
                ? $0.assembly.meanCoverage < $1.assembly.meanCoverage
                : $0.assembly.meanCoverage > $1.assembly.meanCoverage
            }
        case ColumnID.identity:
            items.sort { currentSortAscending
                ? $0.assembly.avgReadIdentity < $1.assembly.avgReadIdentity
                : $0.assembly.avgReadIdentity > $1.assembly.avgReadIdentity
            }
        default:
            items.sort { $0.assembly.totalReads > $1.assembly.totalReads }
        }

        return items
    }

    // MARK: - Context Menu

    private func buildContextMenu() -> NSMenu {
        let menu = NSMenu()

        menu.addItem(withTitle: "Extract Reads\u{2026}",
                     action: #selector(contextExtractReads(_:)),
                     keyEquivalent: "")

        menu.addItem(.separator())

        let blastItem = NSMenuItem(
            title: "BLAST Verify\u{2026}",
            action: #selector(contextBlastVerify(_:)),
            keyEquivalent: ""
        )
        blastItem.image = NSImage(systemSymbolName: "bolt.circle", accessibilityDescription: "BLAST")
        menu.addItem(blastItem)

        menu.addItem(.separator())

        // NCBI links
        let ncbiSubmenu = NSMenu()
        ncbiSubmenu.addItem(withTitle: "GenBank Accession",
                            action: #selector(contextOpenGenBank(_:)),
                            keyEquivalent: "")
        ncbiSubmenu.addItem(withTitle: "Assembly Record",
                            action: #selector(contextOpenAssembly(_:)),
                            keyEquivalent: "")
        ncbiSubmenu.addItem(withTitle: "PubMed Literature",
                            action: #selector(contextOpenPubMed(_:)),
                            keyEquivalent: "")
        ncbiSubmenu.addItem(withTitle: "Taxonomy Browser",
                            action: #selector(contextOpenTaxonomy(_:)),
                            keyEquivalent: "")
        let ncbiItem = NSMenuItem(title: "Look Up on NCBI", action: nil, keyEquivalent: "")
        ncbiItem.submenu = ncbiSubmenu
        ncbiItem.image = NSImage(systemSymbolName: "globe", accessibilityDescription: "NCBI")
        menu.addItem(ncbiItem)

        menu.addItem(.separator())

        menu.addItem(withTitle: "Copy Virus Name",
                     action: #selector(contextCopyName(_:)),
                     keyEquivalent: "")
        menu.addItem(withTitle: "Copy Accession",
                     action: #selector(contextCopyAccession(_:)),
                     keyEquivalent: "")
        menu.addItem(withTitle: "Copy Row as TSV",
                     action: #selector(contextCopyRowTSV(_:)),
                     keyEquivalent: "")

        menu.addItem(.separator())

        menu.addItem(withTitle: "Expand All",
                     action: #selector(contextExpandAll(_:)),
                     keyEquivalent: "")
        menu.addItem(withTitle: "Collapse All",
                     action: #selector(contextCollapseAll(_:)),
                     keyEquivalent: "")

        return menu
    }

    // MARK: - Menu Item Validation

    public func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(contextBlastVerify(_:)) {
            // BLAST Verify requires exactly one selected row
            return outlineView.clickedRow >= 0 && outlineView.selectedRowIndexes.count <= 1
        }
        if menuItem.action == #selector(contextExtractReads(_:)) {
            // Extract Reads is a no-op on empty selection — disable instead
            // of presenting a blank dialog.
            return !outlineView.selectedRowIndexes.isEmpty
        }
        return true
    }

    // MARK: - Context Menu Actions

    @objc private func contextExtractReads(_ sender: Any?) {
        onExtractReadsRequested?()
    }

    /// Shows the BLAST config popover for the currently selected row.
    ///
    /// Called by the action bar BLAST button. If there is no single selection,
    /// this is a no-op.
    public func showBlastPopoverForSelectedRow() {
        let row = outlineView.selectedRow
        guard row >= 0, outlineView.selectedRowIndexes.count == 1 else { return }
        showBlastPopover(forRow: row)
    }

    /// Shows the BLAST config popover anchored to the given row.
    private func showBlastPopover(forRow row: Int) {
        let item = outlineView.item(atRow: row)
        let detection: ViralDetection
        let accessions: [String]
        let availableUniqueReads: Int

        if let detectionItem = item as? ViralDetectionItem {
            detection = detectionItem.detection
            accessions = [detection.accession]
            availableUniqueReads = uniqueReadCountsByContig[detection.accession] ?? detection.readCount
        } else if let assemblyItem = item as? ViralAssemblyItem,
                  let firstContig = assemblyItem.assembly.contigs.first {
            detection = firstContig
            accessions = assemblyItem.assembly.contigs.map(\.accession)
            availableUniqueReads = uniqueReadCountsByAssembly[assemblyItem.assembly.assembly] ?? assemblyItem.assembly.totalReads
        } else {
            return
        }

        let popover = NSPopover()
        popover.behavior = .transient
        popover.contentSize = NSSize(width: 280, height: 160)
        popover.contentViewController = NSHostingController(
            rootView: BlastConfigPopoverView(
                taxonName: detection.name,
                readsClade: availableUniqueReads
            ) { [weak self, weak popover] readCount in
                popover?.close()
                self?.onBlastRequested?(detection, readCount, accessions)
            }
        )

        let rowRect = outlineView.rect(ofRow: row)
        popover.show(relativeTo: rowRect, of: outlineView, preferredEdge: .maxY)
    }

    @objc private func contextBlastVerify(_ sender: Any?) {
        let row = outlineView.clickedRow
        guard row >= 0 else { return }
        showBlastPopover(forRow: row)
    }

    @objc private func contextCopyName(_ sender: Any?) {
        let row = outlineView.clickedRow
        guard row >= 0 else { return }
        let name: String
        let item = outlineView.item(atRow: row)
        if let assemblyItem = item as? ViralAssemblyItem {
            name = assemblyItem.assembly.name
        } else if let detectionItem = item as? ViralDetectionItem {
            name = detectionItem.detection.name
        } else {
            return
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(name, forType: .string)
    }

    @objc private func contextCopyAccession(_ sender: Any?) {
        let row = outlineView.clickedRow
        guard row >= 0 else { return }
        let accession: String
        let item = outlineView.item(atRow: row)
        if let assemblyItem = item as? ViralAssemblyItem {
            accession = assemblyItem.assembly.assembly
        } else if let detectionItem = item as? ViralDetectionItem {
            accession = detectionItem.detection.accession
        } else {
            return
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(accession, forType: .string)
    }

    @objc private func contextOpenGenBank(_ sender: Any?) {
        let row = outlineView.clickedRow
        guard row >= 0 else { return }
        let item = outlineView.item(atRow: row)
        let accession: String
        if let detectionItem = item as? ViralDetectionItem {
            accession = detectionItem.detection.accession
        } else if let assemblyItem = item as? ViralAssemblyItem,
                  let first = assemblyItem.assembly.contigs.first {
            accession = first.accession
        } else {
            return
        }
        if let url = URL(string: "https://www.ncbi.nlm.nih.gov/nuccore/\(accession)") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func contextOpenAssembly(_ sender: Any?) {
        let row = outlineView.clickedRow
        guard row >= 0 else { return }
        let item = outlineView.item(atRow: row)
        let assembly: String
        if let assemblyItem = item as? ViralAssemblyItem {
            assembly = assemblyItem.assembly.assembly
        } else if let detectionItem = item as? ViralDetectionItem {
            assembly = detectionItem.detection.assembly
        } else {
            return
        }
        if let url = URL(string: "https://www.ncbi.nlm.nih.gov/datasets/genome/\(assembly)/") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func contextOpenPubMed(_ sender: Any?) {
        let row = outlineView.clickedRow
        guard row >= 0 else { return }
        let item = outlineView.item(atRow: row)
        let name: String
        if let assemblyItem = item as? ViralAssemblyItem {
            name = assemblyItem.assembly.name
        } else if let detectionItem = item as? ViralDetectionItem {
            name = detectionItem.detection.name
        } else {
            return
        }
        let encoded = name.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? name
        if let url = URL(string: "https://pubmed.ncbi.nlm.nih.gov/?term=\(encoded)") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func contextOpenTaxonomy(_ sender: Any?) {
        let row = outlineView.clickedRow
        guard row >= 0 else { return }
        let item = outlineView.item(atRow: row)
        let name: String
        if let assemblyItem = item as? ViralAssemblyItem {
            name = assemblyItem.assembly.name
        } else if let detectionItem = item as? ViralDetectionItem {
            name = detectionItem.detection.species ?? detectionItem.detection.name
        } else {
            return
        }
        let encoded = name.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? name
        if let url = URL(string: "https://www.ncbi.nlm.nih.gov/Taxonomy/Browser/wwwtax.cgi?name=\(encoded)") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func contextCopyRowTSV(_ sender: Any?) {
        let row = outlineView.clickedRow
        guard row >= 0 else { return }
        let item = outlineView.item(atRow: row)
        let fields: [String]
        if let assemblyItem = item as? ViralAssemblyItem {
            let a = assemblyItem.assembly
            fields = [
                a.name, a.assembly, a.family ?? "", a.genus ?? "", a.species ?? "",
                "\(a.totalReads)", String(format: "%.2f", a.rpkmf),
                String(format: "%.2f", a.meanCoverage), String(format: "%.2f", a.avgReadIdentity),
                "\(a.contigs.count) segments", "\(a.assemblyLength)",
            ]
        } else if let detectionItem = item as? ViralDetectionItem {
            let d = detectionItem.detection
            fields = [
                d.name, d.accession, d.family ?? "", d.genus ?? "", d.species ?? "",
                "\(d.readCount)", String(format: "%.2f", d.rpkmf),
                String(format: "%.2f", d.meanCoverage), String(format: "%.2f", d.avgReadIdentity),
                d.segment ?? "", "\(d.length)",
            ]
        } else {
            return
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(fields.joined(separator: "\t"), forType: .string)
    }

    @objc private func contextExpandAll(_ sender: Any?) {
        outlineView.expandItem(nil, expandChildren: true)
    }

    @objc private func contextCollapseAll(_ sender: Any?) {
        outlineView.collapseItem(nil, collapseChildren: true)
    }

    // MARK: - Public Expand/Collapse

    /// Expands all items in the outline view.
    public func expandAll() {
        outlineView.expandItem(nil, expandChildren: true)
    }

    /// Collapses all items in the outline view.
    public func collapseAll() {
        outlineView.collapseItem(nil, collapseChildren: true)
    }

    // MARK: - NSOutlineViewDataSource

    public func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        if item == nil {
            return sortedDisplayItems.count
        }
        if let assemblyItem = item as? ViralAssemblyItem {
            return assemblyItem.children.count
        }
        return 0
    }

    public func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        if item == nil {
            return sortedDisplayItems[index]
        }
        if let assemblyItem = item as? ViralAssemblyItem {
            return assemblyItem.children[index]
        }
        fatalError("Unexpected item type in ViralDetectionTableView")
    }

    public func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        if let assemblyItem = item as? ViralAssemblyItem {
            return assemblyItem.children.count > 1
        }
        return false
    }

    public func outlineView(
        _ outlineView: NSOutlineView,
        sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]
    ) {
        guard let descriptor = outlineView.sortDescriptors.first,
              let key = descriptor.key else { return }
        currentSortKey = key
        currentSortAscending = descriptor.ascending
        refreshSortedItems()
        outlineView.reloadData()
    }

    // MARK: - NSOutlineViewDelegate

    public func outlineView(
        _ outlineView: NSOutlineView,
        viewFor tableColumn: NSTableColumn?,
        item: Any
    ) -> NSView? {
        guard let column = tableColumn else { return nil }
        let colID = column.identifier.rawValue

        // Check for dynamic metadata columns first (same value for all rows in single-sample)
        if let cell = metadataColumns.cellForColumn(column) {
            return cell
        }

        if let assemblyItem = item as? ViralAssemblyItem {
            return cellForAssembly(assemblyItem.assembly, columnID: colID)
        }
        if let detectionItem = item as? ViralDetectionItem {
            return cellForDetection(detectionItem.detection, columnID: colID)
        }
        return nil
    }

    public func outlineViewSelectionDidChange(_ notification: Notification) {
        guard !suppressSelectionCallback else { return }

        let selectedRows = outlineView.selectedRowIndexes
        if selectedRows.count > 1 {
            onMultipleSelected?(selectedRows.count)
            return
        }

        let row = outlineView.selectedRow
        guard row >= 0 else {
            // NSOutlineView may briefly report no selection during row reloads.
            // Defer nil callbacks to avoid transient "overview bounce" on segment selection.
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                guard !self.suppressSelectionCallback, self.outlineView.selectedRow < 0 else { return }
                self.onAssemblySelected?(nil)
            }
            return
        }

        let item = outlineView.item(atRow: row)
        if let assemblyItem = item as? ViralAssemblyItem {
            onAssemblySelected?(assemblyItem.assembly)
        } else if let detectionItem = item as? ViralDetectionItem {
            if let parent = outlineView.parent(forItem: detectionItem) as? ViralAssemblyItem {
                onAssemblySelected?(parent.assembly)
            } else if let assemblyItem = sortedDisplayItems.first(where: { candidate in
                candidate.assembly.assembly == detectionItem.detection.assembly
            }) {
                // Fallback by assembly accession if outline parent lookup is transiently unavailable.
                onAssemblySelected?(assemblyItem.assembly)
            }
            onDetectionSelected?(detectionItem.detection)
        }
    }

    // MARK: - Cell Factories (Assembly)

    private func cellForAssembly(_ assembly: ViralAssembly, columnID: String) -> NSView? {
        switch columnID {
        case ColumnID.sample:
            return makeTextCell(text: sampleID(for: assembly), alignment: .left)
        case ColumnID.name:
            return makeNameCell(
                name: assembly.name,
                familyName: assembly.family,
                tooltip: assemblyTooltip(assembly)
            )
        case ColumnID.family:
            return makeTextCell(text: assembly.family ?? "\u{2014}", alignment: .left)
        case ColumnID.reads:
            return makeNumberCell(value: assembly.totalReads)
        case ColumnID.uniqueReads:
            if let unique = uniqueReadCountsBySampleAssembly[assemblyKey(for: assembly)]
                ?? uniqueReadCountsByAssembly[assembly.assembly]
            {
                return makeNumberCell(value: unique)
            }
            return makeTextCell(text: "\u{2026}", alignment: .right)  // ellipsis while computing
        case ColumnID.rpkmf:
            return makeDecimalCell(value: assembly.rpkmf, format: "%.1f")
        case ColumnID.coverage:
            // For single-contig assemblies, show the contig's sparkline.
            // For multi-segment assemblies, show the primary (largest) contig's sparkline.
            let sparklineAccession: String?
            if assembly.contigs.count == 1 {
                sparklineAccession = assembly.contigs.first?.accession
            } else {
                // Pick the contig with the most reads for the assembly sparkline
                sparklineAccession = assembly.contigs.max(by: { $0.readCount < $1.readCount })?.accession
            }
            return makeCoverageCell(meanCoverage: assembly.meanCoverage, accession: sparklineAccession)
        case ColumnID.identity:
            return makeDecimalCell(value: assembly.avgReadIdentity, format: "%.1f%%")
        case ColumnID.segment:
            // Assembly rows show segment count summary
            let segments = assembly.contigs.compactMap(\.segment)
            let text = segments.isEmpty ? "\u{2014}" : segments.joined(separator: ",")
            return makeTextCell(text: text, alignment: .center)
        default:
            return nil
        }
    }

    // MARK: - Cell Factories (Detection)

    private func cellForDetection(_ detection: ViralDetection, columnID: String) -> NSView? {
        switch columnID {
        case ColumnID.sample:
            return makeTextCell(text: detection.sampleId, alignment: .left)
        case ColumnID.name:
            return makeNameCell(
                name: disambiguatedDetectionName(detection),
                familyName: detection.family,
                tooltip: detectionTooltip(detection)
            )
        case ColumnID.family:
            return makeTextCell(text: detection.family ?? "\u{2014}", alignment: .left)
        case ColumnID.reads:
            return makeNumberCell(value: detection.readCount)
        case ColumnID.uniqueReads:
            if let unique = uniqueReadCountsBySampleContig["\(detection.sampleId)\t\(detection.accession)"]
                ?? uniqueReadCountsByContig[detection.accession]
            {
                return makeNumberCell(value: unique)
            }
            return makeTextCell(text: "\u{2026}", alignment: .right)
        case ColumnID.rpkmf:
            return makeDecimalCell(value: detection.rpkmf, format: "%.1f")
        case ColumnID.coverage:
            return makeCoverageCell(
                meanCoverage: detection.meanCoverage,
                accession: detection.accession
            )
        case ColumnID.identity:
            return makeDecimalCell(value: detection.avgReadIdentity, format: "%.1f%%")
        case ColumnID.segment:
            return makeTextCell(text: detection.segment ?? "\u{2014}", alignment: .center)
        default:
            return nil
        }
    }

    // MARK: - Cell Factories (Shared)

    /// Creates a name cell with a family-colored indicator dot.
    private func makeNameCell(name: String, familyName: String?, tooltip: String? = nil) -> NSView {
        let cellView = NSTableCellView()
        cellView.identifier = NSUserInterfaceItemIdentifier(ColumnID.name)

        // Colored dot based on family name hash
        let dot = ViralFamilyDotView(frame: NSRect(x: 0, y: 5, width: 8, height: 8))
        dot.color = viralFamilyColor(familyName)
        dot.translatesAutoresizingMaskIntoConstraints = false

        let textField = NSTextField(labelWithString: name)
        textField.font = .systemFont(ofSize: 12)
        textField.lineBreakMode = .byTruncatingTail
        textField.translatesAutoresizingMaskIntoConstraints = false

        cellView.addSubview(dot)
        cellView.addSubview(textField)
        cellView.textField = textField

        if let tooltip {
            cellView.toolTip = tooltip
        }

        NSLayoutConstraint.activate([
            dot.leadingAnchor.constraint(equalTo: cellView.leadingAnchor, constant: 2),
            dot.centerYAnchor.constraint(equalTo: cellView.centerYAnchor),
            dot.widthAnchor.constraint(equalToConstant: 8),
            dot.heightAnchor.constraint(equalToConstant: 8),

            textField.leadingAnchor.constraint(equalTo: dot.trailingAnchor, constant: 4),
            textField.trailingAnchor.constraint(equalTo: cellView.trailingAnchor, constant: -2),
            textField.centerYAnchor.constraint(equalTo: cellView.centerYAnchor),
        ])

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

    /// Creates a right-aligned numeric cell with thousands separators.
    private func makeNumberCell(value: Int) -> NSView {
        let text = Self.countFormatter.string(from: NSNumber(value: value)) ?? "\(value)"

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

    /// Creates a right-aligned decimal cell.
    private func makeDecimalCell(value: Double, format: String) -> NSView {
        let text = String(format: format, value)

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

    /// Creates a coverage cell with sparkline (if data available) and text.
    private func makeCoverageCell(meanCoverage: Double, accession: String?) -> NSView {
        let cellView = NSTableCellView()

        let text = String(format: "%.1fx", meanCoverage)
        let textField = NSTextField(labelWithString: text)
        textField.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        textField.alignment = .right
        textField.translatesAutoresizingMaskIntoConstraints = false
        textField.setContentHuggingPriority(.required, for: .horizontal)

        cellView.addSubview(textField)
        cellView.textField = textField

        // Add sparkline if we have coverage data for this accession
        if let accession,
           let windows = coverageWindowsByAccession[accession],
           !windows.isEmpty {
            let sparkline = ViralCoverageSparklineView()
            sparkline.windows = windows
            sparkline.fillColor = .controlAccentColor
            sparkline.translatesAutoresizingMaskIntoConstraints = false
            cellView.addSubview(sparkline)

            NSLayoutConstraint.activate([
                sparkline.leadingAnchor.constraint(equalTo: cellView.leadingAnchor, constant: 2),
                sparkline.centerYAnchor.constraint(equalTo: cellView.centerYAnchor),
                sparkline.heightAnchor.constraint(equalToConstant: 18),
                sparkline.trailingAnchor.constraint(equalTo: textField.leadingAnchor, constant: -4),

                textField.trailingAnchor.constraint(equalTo: cellView.trailingAnchor, constant: -2),
                textField.centerYAnchor.constraint(equalTo: cellView.centerYAnchor),
            ])
        } else {
            NSLayoutConstraint.activate([
                textField.leadingAnchor.constraint(equalTo: cellView.leadingAnchor, constant: 2),
                textField.trailingAnchor.constraint(equalTo: cellView.trailingAnchor, constant: -2),
                textField.centerYAnchor.constraint(equalTo: cellView.centerYAnchor),
            ])
        }

        return cellView
    }

    // MARK: - Display Name Disambiguation

    /// Builds a disambiguated display name for a child detection row.
    ///
    /// When multiple contigs share the same virus name under a parent assembly,
    /// this appends the genome segment label and/or the GenBank accession
    /// so that each row is visually distinguishable.
    private func disambiguatedDetectionName(_ detection: ViralDetection) -> String {
        var parts: [String] = [detection.name]
        if let segment = detection.segment, !segment.isEmpty {
            parts.append("- Segment \(segment)")
        }
        parts.append("[\(detection.accession)]")
        return parts.joined(separator: " ")
    }

    /// Builds a multi-line tooltip for a detection (child) row.
    private func detectionTooltip(_ detection: ViralDetection) -> String {
        var lines: [String] = [detection.name, "Accession: \(detection.accession)"]
        if let segment = detection.segment, !segment.isEmpty {
            lines.append("Segment: \(segment)")
        }
        if !detection.description.isEmpty {
            lines.append("Description: \(detection.description)")
        }
        lines.append("Length: \(detection.length) bp")
        lines.append("Reads: \(detection.readCount)")
        lines.append("Coverage: \(String(format: "%.1fx", detection.meanCoverage))")
        lines.append("Identity: \(String(format: "%.1f%%", detection.avgReadIdentity))")
        if let species = detection.species, !species.isEmpty {
            let displaySpecies = species.hasPrefix("s__") ? String(species.dropFirst(3)) : species
            lines.append("Species: \(displaySpecies)")
        }
        return lines.joined(separator: "\n")
    }

    /// Builds a multi-line tooltip for an assembly (parent) row.
    private func assemblyTooltip(_ assembly: ViralAssembly) -> String {
        var lines: [String] = [assembly.name, "Assembly: \(assembly.assembly)"]
        if let family = assembly.family { lines.append("Family: \(family)") }
        if let genus = assembly.genus { lines.append("Genus: \(genus)") }
        if let species = assembly.species {
            let displaySpecies = species.hasPrefix("s__") ? String(species.dropFirst(3)) : species
            lines.append("Species: \(displaySpecies)")
        }
        let segments = assembly.contigs.compactMap(\.segment).filter { !$0.isEmpty }
        if !segments.isEmpty { lines.append("Segments: \(segments.joined(separator: ", "))") }
        lines.append("Total Reads: \(assembly.totalReads)")
        lines.append("Coverage: \(String(format: "%.1fx", assembly.meanCoverage))")
        lines.append("Contigs: \(assembly.contigs.count)")
        return lines.joined(separator: "\n")
    }

    // MARK: - Family Color

    /// Returns a stable color for a viral family name.
    ///
    /// Uses the same palette as ``PhylumPalette`` with a hash of the family
    /// name to pick a slot. `nil` family maps to the "Other" color.
    private func viralFamilyColor(_ family: String?) -> NSColor {
        guard let family, !family.isEmpty else {
            return PhylumPalette.phylumColors[PhylumPalette.slotCount - 1]
        }
        var hash: UInt64 = 5381
        for byte in family.utf8 {
            hash = ((hash &<< 5) &+ hash) &+ UInt64(byte)
        }
        let index = Int(hash % UInt64(PhylumPalette.slotCount - 1))
        return PhylumPalette.phylumColors[index]
    }

    private func sampleID(for assembly: ViralAssembly) -> String {
        assembly.contigs.first?.sampleId ?? ""
    }

    private func assemblyKey(for assembly: ViralAssembly) -> String {
        "\(sampleID(for: assembly))\t\(assembly.assembly)"
    }

    // MARK: - Testing Accessors

    /// Returns the outline view for testing.
    var testOutlineView: NSOutlineView { outlineView }

    /// Returns the number of currently displayed assembly items.
    var testDisplayedAssemblyCount: Int { displayItems.count }
}

// MARK: - ViralFamilyDotView

/// A small circular indicator view filled with a viral family color.
@MainActor
final class ViralFamilyDotView: NSView {

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
