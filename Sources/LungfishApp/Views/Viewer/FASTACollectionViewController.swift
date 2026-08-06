// FASTACollectionViewController.swift - Multi-sequence FASTA collection browser
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import LungfishCore
import os.log
import LungfishKit

private let logger = Logger(subsystem: LogSubsystem.app, category: "FASTACollection")

// MARK: - FASTACollectionViewController

/// A browsable table view for multi-sequence FASTA files.
///
/// Replaces the genome browser content area when a FASTA file contains multiple
/// sequences. Displays a summary card bar at the top, a sortable table of
/// sequences in the middle, and a resizable detail pane showing the complete
/// FASTA records selected in the table.
///
/// When displaying sequences from multiple source documents (via multi-selection
/// in the sidebar), a "Source" column appears showing which file each sequence
/// originated from.
///
/// Follows the same child-VC pattern as ``FASTQDatasetViewController`` and
/// ``VCFDatasetViewController``.
@MainActor
public final class FASTACollectionViewController: NSViewController,
    NSTableViewDataSource, NSTableViewDelegate, NSSplitViewDelegate, NSMenuDelegate {

    // MARK: - Data

    private var sequences: [LungfishCore.Sequence] = []
    private var displayedSequences: [LungfishCore.Sequence] = []
    private var annotationsBySequence: [String: [SequenceAnnotation]] = [:]

    /// Source file names keyed by sequence ID.
    ///
    /// When sequences come from multiple documents (multi-select), this maps
    /// each sequence to the name of the file it was loaded from. Empty when
    /// displaying a single document.
    private var sourceNames: [UUID: String] = [:]

    /// Whether the view is showing sequences from multiple source documents.
    private var isMultiSource: Bool { !sourceNames.isEmpty }

    /// Cached GC percentages keyed by sequence ID to avoid recomputation.
    private var gcCache: [UUID: Double] = [:]

    // MARK: - Sort State

    private var sortKey: String = ""
    private var sortAscending: Bool = true

    // MARK: - Callbacks

    /// Invoked when the user double-clicks a sequence or presses "Open in Browser".
    public var onOpenSequence: ((LungfishCore.Sequence, [SequenceAnnotation]) -> Void)?
    public var onExtractSequenceRequested: (([LungfishCore.Sequence]) -> Void)? {
        didSet { refreshContextMenu() }
    }
    public var onBlastRequested: (([LungfishCore.Sequence]) -> Void)? {
        didSet { refreshContextMenu() }
    }
    public var onExportRequested: (([LungfishCore.Sequence]) -> Void)? {
        didSet { refreshContextMenu() }
    }
    public var onCreateBundleRequested: (([LungfishCore.Sequence]) -> Void)? {
        didSet { refreshContextMenu() }
    }
    public var onRunOperationRequested: (([LungfishCore.Sequence]) -> Void)? {
        didSet { refreshContextMenu() }
    }
    public var onAlignWithMAFFTRequested: (([LungfishCore.Sequence]) -> Void)? {
        didSet { refreshContextMenu() }
    }
    public var onBlastCancelRequested: (() -> Void)? {
        didSet {
            if let blastDrawerContainer {
                configureBlastDrawerCallbacks(blastDrawerContainer)
            }
        }
    }
    public var onBlastRerunRequested: (() -> Void)? {
        didSet {
            if let blastDrawerContainer {
                configureBlastDrawerCallbacks(blastDrawerContainer)
            }
        }
    }

    // MARK: - Filter State

    private var filterText: String = ""

    // MARK: - UI Components

    private let summaryBar = FASTACollectionSummaryBar()
    private let searchField = NSSearchField()
    private let countLabel = NSTextField(labelWithString: "")
    private let collectionSplitView = NSSplitView()
    private let tableContainer = NSView()
    private let scrollView = NSScrollView()
    private let tableView = NSTableView()
    private let emptyStateLabel = NSTextField(labelWithString: "")
    private let selectionDetailView = FASTASelectionDetailView()
    private var lastExpandedDetailHeight: CGFloat = 180
    private var isAdjustingDetailSplit = false
    private var scalarPasteboard: PasteboardWriting = DefaultPasteboard()
    private var contextMenu = NSMenu()
    private var collectionSplitBottomConstraint: NSLayoutConstraint?
    private var blastDrawerContainer: BlastResultsDrawerContainerView?
    private var blastDrawerHeightConstraint: NSLayoutConstraint?
    private var lastBlastDrawerHeight: CGFloat = 220
    private var isBlastDrawerOpen = false

    // MARK: - Lifecycle

    public override func loadView() {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        view = container

        setupSummaryBar()
        setupSearchBar()
        setupCollectionSplitView()
        setupTableView()
        setupEmptyState()
        layoutSubviews()
    }

    // MARK: - Public API

    /// Configures the collection view with sequences and annotations.
    ///
    /// Annotations are grouped by their ``SequenceAnnotation/chromosome`` field
    /// to associate them with the correct sequence.
    ///
    /// - Parameters:
    ///   - sequences: All sequences from the FASTA file.
    ///   - annotations: All annotations (from an accompanying GFF/GenBank, etc.).
    public func configure(
        sequences: [LungfishCore.Sequence],
        annotations: [SequenceAnnotation]
    ) {
        configure(sequences: sequences, annotations: annotations, sourceNames: [:])
    }

    /// Configures the collection view with sequences from multiple source documents.
    ///
    /// When `sourceNames` is non-empty, a "Source" column appears in the table
    /// showing which file each sequence originated from. The summary bar also
    /// shows the number of source files.
    ///
    /// - Parameters:
    ///   - sequences: Combined sequences from all selected documents.
    ///   - annotations: Combined annotations from all selected documents.
    ///   - sourceNames: Maps sequence IDs to the source file name they came from.
    ///                  Pass an empty dictionary for single-document display.
    public func configure(
        sequences: [LungfishCore.Sequence],
        annotations: [SequenceAnnotation],
        sourceNames: [UUID: String]
    ) {
        self.sequences = sequences
        self.displayedSequences = sequences

        let wasMultiSource = isMultiSource
        self.sourceNames = sourceNames

        // Add or remove the Source column based on multi-source state
        if isMultiSource && !wasMultiSource {
            insertSourceColumn()
        } else if !isMultiSource && wasMultiSource {
            removeSourceColumn()
        }

        // Group annotations by chromosome/sequence name
        var grouped: [String: [SequenceAnnotation]] = [:]
        for annotation in annotations {
            let key = annotation.chromosome ?? ""
            grouped[key, default: []].append(annotation)
        }
        self.annotationsBySequence = grouped

        // Precompute GC percentages
        gcCache.removeAll(keepingCapacity: true)
        for seq in sequences {
            gcCache[seq.id] = computeGCPercent(for: seq)
        }

        let totalAnnotations = annotations.count
        let sourceCount = isMultiSource ? Set(sourceNames.values).count : 0
        summaryBar.update(
            sequences: sequences,
            annotationCount: totalAnnotations,
            gcCache: gcCache,
            sourceFileCount: sourceCount
        )

        // Update search placeholder for multi-source mode
        if isMultiSource {
            searchField.placeholderString = "Filter sequences by name, description, or source\u{2026}"
        } else {
            searchField.placeholderString = "Filter sequences by name or description\u{2026}"
        }

        // Update empty state message
        if isMultiSource {
            emptyStateLabel.stringValue = "No sequences found in the selected documents."
        } else {
            emptyStateLabel.stringValue = "No sequences found in this FASTA file."
        }

        applySortOrder()

        let isEmpty = sequences.isEmpty
        emptyStateLabel.isHidden = !isEmpty
        scrollView.isHidden = isEmpty
        tableView.deselectAll(nil)
        selectionDetailView.setSequences([])
        closeBlastDrawerIfNeeded(animated: false)
        collapseSelectionDetail()
        refreshContextMenu()

        tableView.reloadData()
        updateCountLabel()

        if isMultiSource {
            logger.info("Configured with \(sequences.count) sequences from \(sourceCount) files, \(totalAnnotations) annotations")
        } else {
            logger.info("Configured with \(sequences.count) sequences, \(totalAnnotations) annotations")
        }
    }

    // MARK: - Setup: Summary Bar

    private func setupSummaryBar() {
        summaryBar.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(summaryBar)
    }

    // MARK: - Setup: Search Bar

    private func setupSearchBar() {
        let searchBar = NSView()
        searchBar.translatesAutoresizingMaskIntoConstraints = false
        searchBar.identifier = NSUserInterfaceItemIdentifier("searchBar")
        view.addSubview(searchBar)

        searchField.translatesAutoresizingMaskIntoConstraints = false
        searchField.placeholderString = "Filter sequences by name or description\u{2026}"
        searchField.sendsSearchStringImmediately = true
        searchField.target = self
        searchField.action = #selector(searchFieldChanged(_:))
        searchBar.addSubview(searchField)

        countLabel.translatesAutoresizingMaskIntoConstraints = false
        countLabel.font = .systemFont(ofSize: 11)
        countLabel.textColor = .secondaryLabelColor
        countLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        searchBar.addSubview(countLabel)

        NSLayoutConstraint.activate([
            searchField.leadingAnchor.constraint(equalTo: searchBar.leadingAnchor, constant: 8),
            searchField.centerYAnchor.constraint(equalTo: searchBar.centerYAnchor),
            searchField.trailingAnchor.constraint(equalTo: countLabel.leadingAnchor, constant: -8),

            countLabel.trailingAnchor.constraint(equalTo: searchBar.trailingAnchor, constant: -8),
            countLabel.centerYAnchor.constraint(equalTo: searchBar.centerYAnchor),
        ])
    }

    @objc private func searchFieldChanged(_ sender: NSSearchField) {
        filterText = sender.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        applyFilter()
    }

    private func applyFilter() {
        let selectedIDs = Set(selectedSequences().map(\.id))
        if filterText.isEmpty {
            displayedSequences = sequences
        } else {
            let query = filterText.lowercased()
            displayedSequences = sequences.filter { seq in
                seq.name.lowercased().contains(query)
                || (seq.description?.lowercased().contains(query) ?? false)
                || (sourceNames[seq.id]?.lowercased().contains(query) ?? false)
            }
        }
        applySortOrder()
        tableView.reloadData()
        restoreSelection(for: selectedIDs)
        updateCountLabel()
        updateSelectionDetail()
    }

    private func updateCountLabel() {
        if filterText.isEmpty {
            if isMultiSource {
                let fileCount = Set(sourceNames.values).count
                countLabel.stringValue = "\(sequences.count) sequences from \(fileCount) files"
            } else {
                countLabel.stringValue = "\(sequences.count) sequences"
            }
        } else {
            countLabel.stringValue = "\(displayedSequences.count) of \(sequences.count)"
        }
    }

    // MARK: - Setup: Collection Split View

    private func setupCollectionSplitView() {
        collectionSplitView.translatesAutoresizingMaskIntoConstraints = false
        collectionSplitView.isVertical = false
        collectionSplitView.dividerStyle = .thin
        collectionSplitView.delegate = self
        collectionSplitView.setAccessibilityIdentifier("fasta-collection-split-view")
        collectionSplitView.setAccessibilityLabel("FASTA sequence table and selected records")

        tableContainer.setAccessibilityElement(true)
        tableContainer.setAccessibilityIdentifier("fasta-collection-table-pane")
        tableContainer.setAccessibilityLabel("FASTA sequence table")

        collectionSplitView.addSubview(tableContainer)
        collectionSplitView.addSubview(selectionDetailView)
        collectionSplitView.setHoldingPriority(.defaultLow, forSubviewAt: 0)
        collectionSplitView.setHoldingPriority(.defaultHigh, forSubviewAt: 1)
        selectionDetailView.isHidden = true
        view.addSubview(collectionSplitView)
    }

    // MARK: - Setup: Table View

    private func setupTableView() {
        let columns: [(id: String, title: String, width: CGFloat, alignment: NSTextAlignment)] = [
            ("name", "Name", 180, .left),
            ("length", "Length", 100, .right),
            ("description", "Description", 220, .left),
            ("annotations", "Annotations", 90, .right),
            ("gc", "GC%", 70, .right),
        ]

        for col in columns {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(col.id))
            column.title = col.title
            column.width = col.width
            column.minWidth = 40

            column.sortDescriptorPrototype = NSSortDescriptor(key: col.id, ascending: true)

            tableView.addTableColumn(column)
        }

        tableView.dataSource = self
        tableView.delegate = self
        tableView.usesAlternatingRowBackgroundColors = true
        tableView.rowHeight = 24
        tableView.allowsMultipleSelection = true
        tableView.headerView = NSTableHeaderView()
        tableView.style = .plain
        tableView.doubleAction = #selector(tableDoubleClicked(_:))
        tableView.target = self
        refreshContextMenu()

        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        tableContainer.addSubview(scrollView)
    }

    /// Inserts the "Source" column after "Name" when showing multi-document sequences.
    private func insertSourceColumn() {
        let sourceID = NSUserInterfaceItemIdentifier("source")
        // Guard against duplicate insertion
        guard tableView.tableColumn(withIdentifier: sourceID) == nil else { return }

        let column = NSTableColumn(identifier: sourceID)
        column.title = "Source"
        column.width = 140
        column.minWidth = 60
        column.sortDescriptorPrototype = NSSortDescriptor(key: "source", ascending: true)

        // Insert after the "name" column (index 0)
        let insertIndex = 1
        tableView.addTableColumn(column)
        if tableView.numberOfColumns > insertIndex + 1 {
            tableView.moveColumn(tableView.numberOfColumns - 1, toColumn: insertIndex)
        }
    }

    /// Removes the "Source" column when returning to single-document display.
    private func removeSourceColumn() {
        let sourceID = NSUserInterfaceItemIdentifier("source")
        if let column = tableView.tableColumn(withIdentifier: sourceID) {
            tableView.removeTableColumn(column)
        }
    }

    // MARK: - Setup: Empty State

    private func setupEmptyState() {
        emptyStateLabel.stringValue = "No sequences found in this FASTA file."
        emptyStateLabel.font = .systemFont(ofSize: 16, weight: .medium)
        emptyStateLabel.textColor = .secondaryLabelColor
        emptyStateLabel.alignment = .center
        emptyStateLabel.translatesAutoresizingMaskIntoConstraints = false
        emptyStateLabel.isHidden = true
        tableContainer.addSubview(emptyStateLabel)

        NSLayoutConstraint.activate([
            emptyStateLabel.centerXAnchor.constraint(equalTo: tableContainer.centerXAnchor),
            emptyStateLabel.centerYAnchor.constraint(equalTo: tableContainer.centerYAnchor),
        ])
    }

    // MARK: - Layout

    private func layoutSubviews() {
        guard let searchBarView = view.subviews.first(where: {
            $0.identifier == NSUserInterfaceItemIdentifier("searchBar")
        }) else { return }
        let summaryHeight = summaryBar.heightAnchor.constraint(
            equalToConstant: summaryBar.preferredContentHeight
        )
        summaryBar.onPreferredContentHeightChanged = { [weak summaryHeight] height in
            summaryHeight?.constant = height
        }

        let splitBottomConstraint = collectionSplitView.bottomAnchor.constraint(
            equalTo: view.bottomAnchor
        )
        collectionSplitBottomConstraint = splitBottomConstraint

        NSLayoutConstraint.activate([
            // Summary bar (top, below safe area to avoid overlapping title bar)
            summaryBar.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            summaryBar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            summaryBar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            summaryHeight,

            // Search bar (below summary)
            searchBarView.topAnchor.constraint(equalTo: summaryBar.bottomAnchor),
            searchBarView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            searchBarView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            searchBarView.heightAnchor.constraint(equalToConstant: 30),

            collectionSplitView.topAnchor.constraint(equalTo: searchBarView.bottomAnchor),
            collectionSplitView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            collectionSplitView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            splitBottomConstraint,

            scrollView.topAnchor.constraint(equalTo: tableContainer.topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: tableContainer.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: tableContainer.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: tableContainer.bottomAnchor),
        ])
    }

    // MARK: - Actions

    @objc private func tableDoubleClicked(_ sender: Any?) {
        let clickedRow = tableView.clickedRow
        guard clickedRow >= 0, clickedRow < displayedSequences.count else { return }
        let seq = displayedSequences[clickedRow]
        let annotations = annotationsBySequence[seq.name] ?? []
        onOpenSequence?(seq, annotations)
    }

    private func refreshContextMenu() {
        contextMenu.delegate = self
        rebuildContextMenu(contextMenu)
        tableView.menu = contextMenu
    }

    private func rebuildContextMenu(_ menu: NSMenu) {
        let rebuiltMenu = FASTASequenceActionMenuBuilder.buildMenu(
            selectionCount: tableView.numberOfSelectedRows,
            handlers: FASTASequenceActionHandlers(
                onExtractSequence: onExtractSequenceRequested == nil ? nil : { [weak self] in
                    guard let self else { return }
                    self.onExtractSequenceRequested?(self.selectedSequences())
                },
                onBlast: onBlastRequested == nil ? nil : { [weak self] in
                    guard let self else { return }
                    self.onBlastRequested?(self.selectedSequences())
                },
                onCopy: { [weak self] in self?.copySelectedSequencesAsFASTA() },
                onExport: onExportRequested == nil ? nil : { [weak self] in
                    guard let self else { return }
                    self.onExportRequested?(self.selectedSequences())
                },
                onCreateBundle: onCreateBundleRequested == nil ? nil : { [weak self] in
                    guard let self else { return }
                    self.onCreateBundleRequested?(self.selectedSequences())
                },
                onAlignWithMAFFT: onAlignWithMAFFTRequested == nil ? nil : { [weak self] in
                    guard let self else { return }
                    self.onAlignWithMAFFTRequested?(self.selectedSequences())
                },
                onRunOperation: onRunOperationRequested == nil ? nil : { [weak self] in
                    guard let self else { return }
                    self.onRunOperationRequested?(self.selectedSequences())
                }
            )
        )
        menu.removeAllItems()
        let rebuiltItems = rebuiltMenu.items
        rebuiltItems.forEach { item in
            rebuiltMenu.removeItem(item)
            menu.addItem(item)
        }
    }

    public func menuNeedsUpdate(_ menu: NSMenu) {
        reconcileContextMenuSelection(clickedRow: tableView.clickedRow)
        rebuildContextMenu(menu)
    }

    private func reconcileContextMenuSelection(clickedRow: Int) {
        guard clickedRow >= 0, clickedRow < displayedSequences.count,
              !tableView.selectedRowIndexes.contains(clickedRow) else { return }
        tableView.selectRowIndexes(IndexSet(integer: clickedRow), byExtendingSelection: false)
        updateSelectionDetail()
    }

    private func selectedSequences() -> [LungfishCore.Sequence] {
        tableView.selectedRowIndexes.compactMap { row in
            guard row >= 0, row < displayedSequences.count else { return nil }
            return displayedSequences[row]
        }
    }

    private func restoreSelection(for sequenceIDs: Set<UUID>) {
        let indexes = IndexSet(
            displayedSequences.indices.filter { sequenceIDs.contains(displayedSequences[$0].id) }
        )
        if indexes.isEmpty {
            tableView.deselectAll(nil)
        } else {
            tableView.selectRowIndexes(indexes, byExtendingSelection: false)
        }
    }

    private func copySelectedSequencesAsFASTA() {
        let fastaText = FASTASelectionDetailFormatter.text(for: selectedSequences())
        guard !fastaText.isEmpty else { return }
        scalarPasteboard.setString(fastaText)
    }

    // MARK: - Sorting

    private func applySortOrder() {
        guard !sortKey.isEmpty else {
            // When filtering, displayedSequences is already filtered; only re-sort
            // the current displayed set rather than resetting to all sequences
            return
        }

        displayedSequences.sort { a, b in
            let result: Bool
            switch sortKey {
            case "name":
                result = a.name.localizedStandardCompare(b.name) == .orderedAscending
            case "length":
                result = a.length < b.length
            case "description":
                result = (a.description ?? "").localizedStandardCompare(b.description ?? "") == .orderedAscending
            case "annotations":
                let countA = annotationsBySequence[a.name]?.count ?? 0
                let countB = annotationsBySequence[b.name]?.count ?? 0
                result = countA < countB
            case "gc":
                let gcA = gcCache[a.id] ?? 0
                let gcB = gcCache[b.id] ?? 0
                result = gcA < gcB
            case "source":
                let srcA = sourceNames[a.id] ?? ""
                let srcB = sourceNames[b.id] ?? ""
                result = srcA.localizedStandardCompare(srcB) == .orderedAscending
            default:
                return false
            }
            return sortAscending ? result : !result
        }
    }

    // MARK: - GC Content Calculation

    /// Computes GC percentage for a sequence by sampling up to 10,000 bases.
    ///
    /// For sequences longer than 10,000 bp, samples evenly-spaced windows
    /// to keep computation bounded.
    private func computeGCPercent(for seq: LungfishCore.Sequence) -> Double {
        let length = seq.length
        guard length > 0 else { return 0 }

        let sampleSize = min(length, 10_000)
        var gcCount = 0
        var totalCount = 0

        if length <= sampleSize {
            // Sample entire sequence
            let bases = seq[0..<length]
            for base in bases {
                switch base {
                case "G", "g", "C", "c":
                    gcCount += 1
                    totalCount += 1
                case "A", "a", "T", "t":
                    totalCount += 1
                default:
                    break // Skip N and ambiguous bases
                }
            }
        } else {
            // Sample evenly-spaced windows
            let windowSize = 100
            let windowCount = sampleSize / windowSize
            let step = length / windowCount

            for i in 0..<windowCount {
                let start = i * step
                let end = min(start + windowSize, length)
                let bases = seq[start..<end]
                for base in bases {
                    switch base {
                    case "G", "g", "C", "c":
                        gcCount += 1
                        totalCount += 1
                    case "A", "a", "T", "t":
                        totalCount += 1
                    default:
                        break
                    }
                }
            }
        }

        guard totalCount > 0 else { return 0 }
        return Double(gcCount) / Double(totalCount) * 100.0
    }

    // MARK: - Selection Detail

    private func updateSelectionDetail() {
        if isBlastDrawerOpen,
           case .loading = blastDrawerContainer?.blastResultsTab.displayState {
            onBlastCancelRequested?()
        }
        closeBlastDrawerIfNeeded(animated: view.window != nil)
        let selection = selectedSequences()
        selectionDetailView.setSequences(selection)
        if selection.isEmpty {
            collapseSelectionDetail()
        } else {
            revealSelectionDetail()
        }
    }

    private func collapseSelectionDetail() {
        guard collectionSplitView.bounds.height > 0 else {
            selectionDetailView.isHidden = true
            return
        }
        isAdjustingDetailSplit = true
        collectionSplitView.setPosition(
            collectionSplitView.bounds.height,
            ofDividerAt: 0
        )
        collectionSplitView.adjustSubviews()
        selectionDetailView.isHidden = true
        isAdjustingDetailSplit = false
    }

    private func revealSelectionDetail() {
        selectionDetailView.isHidden = false
        setDetailHeight(lastExpandedDetailHeight)
    }

    private func setDetailHeight(_ requestedHeight: CGFloat) {
        let totalHeight = collectionSplitView.bounds.height
        guard totalHeight > collectionSplitView.dividerThickness else { return }
        let minimumHeight = min(120, max(1, totalHeight / 2))
        let minimumTableHeight = min(120, max(1, totalHeight / 2))
        let maximumHeight = max(
            minimumHeight,
            totalHeight - minimumTableHeight - collectionSplitView.dividerThickness
        )
        let resolvedHeight = min(max(requestedHeight, minimumHeight), maximumHeight)
        lastExpandedDetailHeight = resolvedHeight
        let dividerPosition = max(
            0,
            totalHeight - resolvedHeight - collectionSplitView.dividerThickness
        )
        isAdjustingDetailSplit = true
        collectionSplitView.setPosition(dividerPosition, ofDividerAt: 0)
        collectionSplitView.adjustSubviews()
        collectionSplitView.layoutSubtreeIfNeeded()
        isAdjustingDetailSplit = false
    }

    // MARK: - Shared BLAST Drawer

    public func showBlastLoading(phase: BlastJobPhase, requestId: String?) {
        collapseSelectionDetail()
        let drawer = ensureBlastDrawer()
        drawer.showLoading(phase: phase, requestId: requestId)
        openBlastDrawerIfNeeded()
    }

    public func showBlastResults(_ result: BlastVerificationResult) {
        collapseSelectionDetail()
        let drawer = ensureBlastDrawer()
        drawer.showResults(result)
        openBlastDrawerIfNeeded()
    }

    public func showBlastFailure(_ message: String) {
        collapseSelectionDetail()
        let drawer = ensureBlastDrawer()
        drawer.showFailure(message: message)
        openBlastDrawerIfNeeded()
    }

    private func ensureBlastDrawer() -> BlastResultsDrawerTab {
        if let blastDrawerContainer {
            configureBlastDrawerCallbacks(blastDrawerContainer)
            return blastDrawerContainer.blastResultsTab
        }

        let container = BlastResultsDrawerContainerView()
        container.translatesAutoresizingMaskIntoConstraints = false
        container.isHidden = true
        view.addSubview(container)

        let heightConstraint = container.heightAnchor.constraint(equalToConstant: 0)
        NSLayoutConstraint.activate([
            container.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            container.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            container.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            heightConstraint,
        ])

        collectionSplitBottomConstraint?.isActive = false
        let newSplitBottom = collectionSplitView.bottomAnchor.constraint(equalTo: container.topAnchor)
        newSplitBottom.isActive = true
        collectionSplitBottomConstraint = newSplitBottom

        blastDrawerContainer = container
        blastDrawerHeightConstraint = heightConstraint
        container.blastResultsTab.presentationStyle = .sequenceBlast
        configureBlastDrawerCallbacks(container)
        container.onDrag = { [weak self] delta in
            guard let self, self.isBlastDrawerOpen,
                  let heightConstraint = self.blastDrawerHeightConstraint else { return }
            let maximum = max(160, self.view.bounds.height - 120)
            let proposed = min(max(heightConstraint.constant + delta, 160), maximum)
            heightConstraint.constant = proposed
            self.lastBlastDrawerHeight = proposed
            self.view.layoutSubtreeIfNeeded()
        }
        container.onDragEnd = { [weak self] in
            self?.view.layoutSubtreeIfNeeded()
        }
        view.layoutSubtreeIfNeeded()
        return container.blastResultsTab
    }

    private func configureBlastDrawerCallbacks(_ container: BlastResultsDrawerContainerView) {
        container.blastResultsTab.onCancelBlast = { [weak self] in
            guard let self else { return }
            self.onBlastCancelRequested?()
            self.closeBlastDrawerIfNeeded(animated: self.view.window != nil)
            let selection = self.selectedSequences()
            self.selectionDetailView.setSequences(selection)
            if selection.isEmpty {
                self.collapseSelectionDetail()
            } else {
                self.revealSelectionDetail()
            }
        }
        container.onRerunBlast = { [weak self] in
            self?.onBlastRerunRequested?()
        }
    }

    private func openBlastDrawerIfNeeded() {
        guard let container = blastDrawerContainer,
              let heightConstraint = blastDrawerHeightConstraint else { return }
        container.isHidden = false
        guard !isBlastDrawerOpen else { return }
        isBlastDrawerOpen = true
        let maximum = max(160, view.bounds.height - 120)
        let targetHeight = min(max(lastBlastDrawerHeight, 160), maximum)
        if view.window == nil {
            heightConstraint.constant = targetHeight
            view.layoutSubtreeIfNeeded()
            return
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.25
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            context.allowsImplicitAnimation = true
            heightConstraint.animator().constant = targetHeight
            view.layoutSubtreeIfNeeded()
        }
    }

    private func closeBlastDrawerIfNeeded(animated _: Bool) {
        guard isBlastDrawerOpen,
              let container = blastDrawerContainer,
              let heightConstraint = blastDrawerHeightConstraint else { return }
        if heightConstraint.constant > 1 {
            lastBlastDrawerHeight = heightConstraint.constant
        }
        isBlastDrawerOpen = false
        heightConstraint.constant = 0
        container.isHidden = true
        view.layoutSubtreeIfNeeded()
    }

    public func splitViewDidResizeSubviews(_ notification: Notification) {
        guard !isAdjustingDetailSplit,
              !selectionDetailView.isHidden,
              selectionDetailView.frame.height > 1 else { return }
        lastExpandedDetailHeight = selectionDetailView.frame.height
    }

    public func splitView(
        _ splitView: NSSplitView,
        constrainMinCoordinate proposedMinimumPosition: CGFloat,
        ofSubviewAt dividerIndex: Int
    ) -> CGFloat {
        min(120, max(0, splitView.bounds.height / 2))
    }

    public func splitView(
        _ splitView: NSSplitView,
        constrainMaxCoordinate proposedMaximumPosition: CGFloat,
        ofSubviewAt dividerIndex: Int
    ) -> CGFloat {
        guard !selectionDetailView.isHidden else { return splitView.bounds.height }
        let minimumDetailHeight = min(120, max(0, splitView.bounds.height / 2))
        return max(
            0,
            splitView.bounds.height - minimumDetailHeight - splitView.dividerThickness
        )
    }

    // MARK: - NSTableViewDataSource

    public func numberOfRows(in tableView: NSTableView) -> Int {
        displayedSequences.count
    }

    public func tableView(
        _ tableView: NSTableView,
        sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]
    ) {
        guard let descriptor = tableView.sortDescriptors.first,
              let key = descriptor.key else { return }
        let selectedIDs = Set(selectedSequences().map(\.id))
        sortKey = key
        sortAscending = descriptor.ascending
        applySortOrder()
        tableView.reloadData()
        restoreSelection(for: selectedIDs)
        updateSelectionDetail()
    }

    // MARK: - NSTableViewDelegate

    public func tableView(
        _ tableView: NSTableView,
        viewFor tableColumn: NSTableColumn?,
        row: Int
    ) -> NSView? {
        guard row < displayedSequences.count,
              let identifier = tableColumn?.identifier else { return nil }

        let seq = displayedSequences[row]

        // Text-based columns
        let cell = reuseOrCreateTextCell(identifier: identifier, in: tableView)
        let textField = cell.textField!

        textField.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        textField.textColor = .labelColor
        textField.alignment = .left

        switch identifier.rawValue {
        case "name":
            textField.stringValue = seq.name
            textField.font = .systemFont(ofSize: 11, weight: .medium)

        case "source":
            textField.stringValue = sourceNames[seq.id] ?? ""
            textField.textColor = .secondaryLabelColor
            textField.font = .systemFont(ofSize: 11, weight: .regular)

        case "length":
            textField.stringValue = GenomicSummaryCardBar.formatBases(seq.length)
            textField.alignment = .right

        case "description":
            textField.stringValue = seq.description ?? ""
            textField.textColor = .secondaryLabelColor

        case "annotations":
            let count = annotationsBySequence[seq.name]?.count ?? 0
            textField.stringValue = count > 0 ? "\(count)" : "\u{2014}"
            textField.alignment = .right
            if count == 0 { textField.textColor = .tertiaryLabelColor }

        case "gc":
            let gc = gcCache[seq.id] ?? 0
            textField.stringValue = String(format: "%.1f%%", gc)
            textField.alignment = .right

        default:
            textField.stringValue = ""
        }

        return cell
    }

    public func tableViewSelectionDidChange(_ notification: Notification) {
        updateSelectionDetail()
        refreshContextMenu()
    }

    // MARK: - Cell Helpers

    private func reuseOrCreateTextCell(
        identifier: NSUserInterfaceItemIdentifier,
        in tableView: NSTableView
    ) -> NSTableCellView {
        if let existing = tableView.makeView(withIdentifier: identifier, owner: nil) as? NSTableCellView {
            return existing
        }

        let cell = NSTableCellView()
        cell.identifier = identifier

        let tf = NSTextField(labelWithString: "")
        tf.translatesAutoresizingMaskIntoConstraints = false
        tf.lineBreakMode = .byTruncatingTail
        cell.addSubview(tf)
        cell.textField = tf

        NSLayoutConstraint.activate([
            tf.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4),
            tf.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4),
            tf.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])

        return cell
    }

}

#if DEBUG
extension FASTACollectionViewController {
    var testColumnIdentifiers: [String] {
        tableView.tableColumns.map(\.identifier.rawValue)
    }

    var testDetailText: String {
        selectionDetailView.text
    }

    var testDetailIsCollapsed: Bool {
        selectionDetailView.isHidden
    }

    var testDetailHeight: CGFloat {
        selectionDetailView.frame.height
    }

    var testContextMenuTitles: [String] {
        contextMenu.items.map(\.title)
    }

    func testSelectRows(_ rows: [Int]) {
        if rows.isEmpty {
            tableView.deselectAll(nil)
        } else {
            tableView.selectRowIndexes(IndexSet(rows), byExtendingSelection: false)
        }
        tableViewSelectionDidChange(Notification(name: NSTableView.selectionDidChangeNotification))
    }

    func testSetDetailHeight(_ height: CGFloat) {
        selectionDetailView.isHidden = false
        setDetailHeight(height)
    }

    func testFilter(_ text: String) {
        searchField.stringValue = text
        searchFieldChanged(searchField)
    }

    func testSort(column: String, ascending: Bool) {
        let selectedIDs = Set(selectedSequences().map(\.id))
        sortKey = column
        sortAscending = ascending
        applySortOrder()
        tableView.reloadData()
        restoreSelection(for: selectedIDs)
        updateSelectionDetail()
    }

    func testInvokeContextMenuItem(titled title: String) {
        guard let item = contextMenu.items.first(where: { $0.title == title }),
              let action = item.action else {
            return
        }
        _ = item.target?.perform(action, with: item)
    }

    func testUpdateContextMenu(clickedRow: Int?) {
        reconcileContextMenuSelection(clickedRow: clickedRow ?? -1)
        rebuildContextMenu(contextMenu)
    }

    func testContextMenuItem(titled title: String) -> NSMenuItem? {
        contextMenu.items.first { $0.title == title }
    }

    func testSetPasteboard(_ pasteboard: PasteboardWriting) {
        scalarPasteboard = pasteboard
    }

    var testBlastDrawerIsOpen: Bool {
        isBlastDrawerOpen
    }

    var testBlastDrawerTab: BlastResultsDrawerTab? {
        blastDrawerContainer?.blastResultsTab
    }

}
#endif

// MARK: - FASTACollectionSummaryBar

/// Summary card bar for the FASTA collection view.
///
/// Displays: Sequences, Total Length, Annotations, GC%, Shortest, Longest.
/// When showing sequences from multiple source files, also displays a "Sources"
/// card with the file count.
@MainActor
final class FASTACollectionSummaryBar: GenomicSummaryCardBar {

    // MARK: - State

    private var sequenceCount: Int = 0
    private var totalLength: Int64 = 0
    private var annotationCount: Int = 0
    private var meanGCPercent: Double = 0
    private var shortestLength: Int = 0
    private var longestLength: Int = 0
    private var sourceFileCount: Int = 0

    // MARK: - Update

    /// Recomputes summary statistics from the provided sequences.
    ///
    /// - Parameters:
    ///   - sequences: All sequences in the collection.
    ///   - annotationCount: Total number of annotations across all sequences.
    ///   - gcCache: Pre-computed GC percentages keyed by sequence ID.
    ///   - sourceFileCount: Number of distinct source files (0 for single-document).
    func update(
        sequences: [LungfishCore.Sequence],
        annotationCount: Int,
        gcCache: [UUID: Double],
        sourceFileCount: Int = 0
    ) {
        self.sequenceCount = sequences.count
        self.annotationCount = annotationCount
        self.sourceFileCount = sourceFileCount

        if sequences.isEmpty {
            totalLength = 0
            meanGCPercent = 0
            shortestLength = 0
            longestLength = 0
        } else {
            var total: Int64 = 0
            var shortest = Int.max
            var longest = 0
            var gcSum = 0.0

            for seq in sequences {
                let len = seq.length
                total += Int64(len)
                if len < shortest { shortest = len }
                if len > longest { longest = len }
                gcSum += gcCache[seq.id] ?? 0
            }

            totalLength = total
            shortestLength = shortest
            longestLength = longest
            meanGCPercent = gcSum / Double(sequences.count)
        }

        cardsDidChange()
    }

    // MARK: - Cards

    override var cards: [Card] {
        var result = [
            Card(label: "Sequences", value: GenomicSummaryCardBar.formatCount(sequenceCount)),
        ]

        // Show "Sources" card when combining multiple documents
        if sourceFileCount > 0 {
            result.append(
                Card(label: "Sources", value: "\(sourceFileCount) files")
            )
        }

        result.append(contentsOf: [
            Card(label: "Total Length", value: GenomicSummaryCardBar.formatBases(totalLength)),
            Card(label: "Annotations", value: GenomicSummaryCardBar.formatCount(annotationCount)),
            Card(label: "GC Content", value: String(format: "%.1f%%", meanGCPercent)),
            Card(label: "Shortest", value: GenomicSummaryCardBar.formatBases(shortestLength)),
            Card(label: "Longest", value: GenomicSummaryCardBar.formatBases(longestLength)),
        ])

        return result
    }
}
