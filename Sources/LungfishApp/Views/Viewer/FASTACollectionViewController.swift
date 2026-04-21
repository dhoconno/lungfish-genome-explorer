// FASTACollectionViewController.swift - Multi-sequence FASTA collection browser
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import LungfishCore
import os.log

private let logger = Logger(subsystem: LogSubsystem.app, category: "FASTACollection")

// MARK: - FASTACollectionViewController

/// A browsable table view for multi-sequence FASTA files.
///
/// Replaces the genome browser content area when a FASTA file contains multiple
/// sequences. Displays a summary card bar at the top, a sortable table of
/// sequences in the middle, and a detail panel at the bottom showing feature
/// breakdowns and an "Open in Browser" action.
///
/// When displaying sequences from multiple source documents (via multi-selection
/// in the sidebar), a "Source" column appears showing which file each sequence
/// originated from.
///
/// Follows the same child-VC pattern as ``FASTQDatasetViewController`` and
/// ``VCFDatasetViewController``.
@MainActor
public final class FASTACollectionViewController: NSViewController,
    NSTableViewDataSource, NSTableViewDelegate {

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

    // MARK: - Filter State

    private var filterText: String = ""

    // MARK: - UI Components

    private let summaryBar = FASTACollectionSummaryBar()
    private let searchField = NSSearchField()
    private let countLabel = NSTextField(labelWithString: "")
    private let scrollView = NSScrollView()
    private let tableView = NSTableView()
    private let emptyStateLabel = NSTextField(labelWithString: "")
    private let detailPanel = NSView()
    private let detailNameLabel = NSTextField(labelWithString: "")
    private let detailDescLabel = NSTextField(labelWithString: "")
    private let detailFeaturesLabel = NSTextField(labelWithString: "")
    private let openButton = NSButton(title: "Open in Browser", target: nil, action: nil)
    private var scalarPasteboard: PasteboardWriting = DefaultPasteboard()
    private var contextMenu = NSMenu()

    // MARK: - Lifecycle

    public override func loadView() {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        view = container

        setupSummaryBar()
        setupSearchBar()
        setupTableView()
        setupDetailPanel()
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
        detailPanel.isHidden = true
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
        updateCountLabel()
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

    // MARK: - Setup: Table View

    private func setupTableView() {
        let columns: [(id: String, title: String, width: CGFloat, alignment: NSTextAlignment)] = [
            ("name", "Name", 180, .left),
            ("length", "Length", 100, .right),
            ("description", "Description", 220, .left),
            ("annotations", "Annotations", 90, .right),
            ("gc", "GC%", 70, .right),
            ("minimap", "Mini Map", 140, .left),
        ]

        for col in columns {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(col.id))
            column.title = col.title
            column.width = col.width
            column.minWidth = 40

            // All columns except minimap are sortable
            if col.id != "minimap" {
                column.sortDescriptorPrototype = NSSortDescriptor(key: col.id, ascending: true)
            }

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
        view.addSubview(scrollView)
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

    // MARK: - Setup: Detail Panel

    private func setupDetailPanel() {
        detailPanel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(detailPanel)

        // Top separator
        let separator = NSBox()
        separator.boxType = .separator
        separator.translatesAutoresizingMaskIntoConstraints = false
        detailPanel.addSubview(separator)

        // Name label
        detailNameLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        detailNameLabel.textColor = .labelColor
        detailNameLabel.lineBreakMode = .byTruncatingTail
        detailNameLabel.translatesAutoresizingMaskIntoConstraints = false
        detailPanel.addSubview(detailNameLabel)

        // Description label
        detailDescLabel.font = .systemFont(ofSize: 11, weight: .regular)
        detailDescLabel.textColor = .secondaryLabelColor
        detailDescLabel.lineBreakMode = .byTruncatingTail
        detailDescLabel.translatesAutoresizingMaskIntoConstraints = false
        detailPanel.addSubview(detailDescLabel)

        // Feature breakdown label
        detailFeaturesLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        detailFeaturesLabel.textColor = .secondaryLabelColor
        detailFeaturesLabel.lineBreakMode = .byTruncatingTail
        detailFeaturesLabel.translatesAutoresizingMaskIntoConstraints = false
        detailPanel.addSubview(detailFeaturesLabel)

        // Open button
        openButton.bezelStyle = .rounded
        openButton.target = self
        openButton.action = #selector(openInBrowserTapped)
        openButton.translatesAutoresizingMaskIntoConstraints = false
        detailPanel.addSubview(openButton)

        NSLayoutConstraint.activate([
            separator.topAnchor.constraint(equalTo: detailPanel.topAnchor),
            separator.leadingAnchor.constraint(equalTo: detailPanel.leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: detailPanel.trailingAnchor),

            detailNameLabel.topAnchor.constraint(equalTo: detailPanel.topAnchor, constant: 8),
            detailNameLabel.leadingAnchor.constraint(equalTo: detailPanel.leadingAnchor, constant: 12),
            detailNameLabel.trailingAnchor.constraint(lessThanOrEqualTo: openButton.leadingAnchor, constant: -12),

            detailDescLabel.topAnchor.constraint(equalTo: detailNameLabel.bottomAnchor, constant: 2),
            detailDescLabel.leadingAnchor.constraint(equalTo: detailPanel.leadingAnchor, constant: 12),
            detailDescLabel.trailingAnchor.constraint(lessThanOrEqualTo: openButton.leadingAnchor, constant: -12),

            detailFeaturesLabel.topAnchor.constraint(equalTo: detailDescLabel.bottomAnchor, constant: 2),
            detailFeaturesLabel.leadingAnchor.constraint(equalTo: detailPanel.leadingAnchor, constant: 12),
            detailFeaturesLabel.trailingAnchor.constraint(lessThanOrEqualTo: openButton.leadingAnchor, constant: -12),

            openButton.trailingAnchor.constraint(equalTo: detailPanel.trailingAnchor, constant: -12),
            openButton.centerYAnchor.constraint(equalTo: detailPanel.centerYAnchor),
        ])

        detailPanel.isHidden = true
    }

    // MARK: - Setup: Empty State

    private func setupEmptyState() {
        emptyStateLabel.stringValue = "No sequences found in this FASTA file."
        emptyStateLabel.font = .systemFont(ofSize: 16, weight: .medium)
        emptyStateLabel.textColor = .secondaryLabelColor
        emptyStateLabel.alignment = .center
        emptyStateLabel.translatesAutoresizingMaskIntoConstraints = false
        emptyStateLabel.isHidden = true
        view.addSubview(emptyStateLabel)

        NSLayoutConstraint.activate([
            emptyStateLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            emptyStateLabel.centerYAnchor.constraint(equalTo: view.centerYAnchor),
        ])
    }

    // MARK: - Layout

    private func layoutSubviews() {
        guard let searchBarView = view.subviews.first(where: {
            $0.identifier == NSUserInterfaceItemIdentifier("searchBar")
        }) else { return }

        NSLayoutConstraint.activate([
            // Summary bar (top, below safe area to avoid overlapping title bar)
            summaryBar.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            summaryBar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            summaryBar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            summaryBar.heightAnchor.constraint(equalToConstant: 48),

            // Search bar (below summary)
            searchBarView.topAnchor.constraint(equalTo: summaryBar.bottomAnchor),
            searchBarView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            searchBarView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            searchBarView.heightAnchor.constraint(equalToConstant: 30),

            // Detail panel (bottom, fixed height)
            detailPanel.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            detailPanel.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            detailPanel.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            detailPanel.heightAnchor.constraint(equalToConstant: 80),

            // Table (middle, fills remaining space between search bar and detail)
            scrollView.topAnchor.constraint(equalTo: searchBarView.bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: detailPanel.topAnchor),
        ])
    }

    // MARK: - Actions

    @objc private func openInBrowserTapped() {
        let selectedRow = tableView.selectedRow
        guard selectedRow >= 0, selectedRow < displayedSequences.count else { return }
        let seq = displayedSequences[selectedRow]
        let annotations = annotationsBySequence[seq.name] ?? []
        onOpenSequence?(seq, annotations)
    }

    @objc private func tableDoubleClicked(_ sender: Any?) {
        let clickedRow = tableView.clickedRow
        guard clickedRow >= 0, clickedRow < displayedSequences.count else { return }
        let seq = displayedSequences[clickedRow]
        let annotations = annotationsBySequence[seq.name] ?? []
        onOpenSequence?(seq, annotations)
    }

    private func refreshContextMenu() {
        contextMenu = FASTASequenceActionMenuBuilder.buildMenu(
            selectionCount: tableView.numberOfSelectedRows,
            handlers: FASTASequenceActionHandlers(
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
                onRunOperation: onRunOperationRequested == nil ? nil : { [weak self] in
                    guard let self else { return }
                    self.onRunOperationRequested?(self.selectedSequences())
                }
            )
        )
        tableView.menu = contextMenu
    }

    private func selectedSequences() -> [LungfishCore.Sequence] {
        tableView.selectedRowIndexes.compactMap { row in
            guard row >= 0, row < displayedSequences.count else { return nil }
            return displayedSequences[row]
        }
    }

    private func copySelectedSequencesAsFASTA() {
        let fastaText = selectedSequences()
            .map(Self.fastaRecord(for:))
            .joined(separator: "")
        guard !fastaText.isEmpty else { return }
        scalarPasteboard.setString(fastaText)
    }

    private static func fastaRecord(for sequence: LungfishCore.Sequence) -> String {
        ">\(sequence.name)\n\(sequence.asString())\n"
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

    // MARK: - Detail Panel Update

    private func updateDetailPanel() {
        let selectedRow = tableView.selectedRow
        guard selectedRow >= 0, selectedRow < displayedSequences.count else {
            detailPanel.isHidden = true
            return
        }

        let seq = displayedSequences[selectedRow]
        let annotations = annotationsBySequence[seq.name] ?? []

        // Show source file in the detail panel name when in multi-source mode
        if let source = sourceNames[seq.id] {
            detailNameLabel.stringValue = "\(seq.name)  \u{2014}  \(source)"
        } else {
            detailNameLabel.stringValue = seq.name
        }
        detailDescLabel.stringValue = seq.description ?? "No description"

        if annotations.isEmpty {
            detailFeaturesLabel.stringValue = "No annotations"
        } else {
            // Build feature type breakdown
            var typeCounts: [String: Int] = [:]
            for ann in annotations {
                typeCounts[ann.type.rawValue, default: 0] += 1
            }
            let breakdown = typeCounts
                .sorted { $0.value > $1.value }
                .map { "\($0.value) \($0.key)" }
                .joined(separator: ", ")
            detailFeaturesLabel.stringValue = breakdown
        }

        detailPanel.isHidden = false
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
        sortKey = key
        sortAscending = descriptor.ascending
        applySortOrder()
        tableView.reloadData()
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

        // Mini Map column uses a custom view
        if identifier.rawValue == "minimap" {
            return miniMapCell(for: seq, in: tableView, identifier: identifier)
        }

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
        updateDetailPanel()
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

    /// Returns a reusable or newly created ``FASTAAnnotationMapCell`` for the
    /// mini-map column.
    private func miniMapCell(
        for seq: LungfishCore.Sequence,
        in tableView: NSTableView,
        identifier: NSUserInterfaceItemIdentifier
    ) -> NSView {
        let mapCell: FASTAAnnotationMapCell
        if let existing = tableView.makeView(
            withIdentifier: identifier, owner: nil
        ) as? FASTAAnnotationMapCell {
            mapCell = existing
        } else {
            mapCell = FASTAAnnotationMapCell()
            mapCell.identifier = identifier
        }

        let annotations = annotationsBySequence[seq.name] ?? []
        mapCell.configure(sequenceLength: seq.length, annotations: annotations)
        return mapCell
    }
}

#if DEBUG
extension FASTACollectionViewController {
    var testContextMenuTitles: [String] {
        contextMenu.items.map(\.title)
    }

    func testSelectRows(_ rows: [Int]) {
        tableView.selectRowIndexes(IndexSet(rows), byExtendingSelection: false)
        tableViewSelectionDidChange(Notification(name: NSTableView.selectionDidChangeNotification))
    }

    func testInvokeContextMenuItem(titled title: String) {
        guard let item = contextMenu.items.first(where: { $0.title == title }),
              let action = item.action else {
            return
        }
        _ = item.target?.perform(action, with: item)
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

        needsDisplay = true
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
