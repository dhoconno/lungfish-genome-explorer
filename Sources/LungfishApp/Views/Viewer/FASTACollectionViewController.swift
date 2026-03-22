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
/// Follows the same child-VC pattern as ``FASTQDatasetViewController`` and
/// ``VCFDatasetViewController``.
@MainActor
public final class FASTACollectionViewController: NSViewController,
    NSTableViewDataSource, NSTableViewDelegate {

    // MARK: - Data

    private var sequences: [LungfishCore.Sequence] = []
    private var displayedSequences: [LungfishCore.Sequence] = []
    private var annotationsBySequence: [String: [SequenceAnnotation]] = [:]

    /// Cached GC percentages keyed by sequence ID to avoid recomputation.
    private var gcCache: [UUID: Double] = [:]

    // MARK: - Sort State

    private var sortKey: String = ""
    private var sortAscending: Bool = true

    // MARK: - Callbacks

    /// Invoked when the user double-clicks a sequence or presses "Open in Browser".
    public var onOpenSequence: ((LungfishCore.Sequence, [SequenceAnnotation]) -> Void)?

    // MARK: - UI Components

    private let summaryBar = FASTACollectionSummaryBar()
    private let scrollView = NSScrollView()
    private let tableView = NSTableView()
    private let emptyStateLabel = NSTextField(labelWithString: "")
    private let detailPanel = NSView()
    private let detailNameLabel = NSTextField(labelWithString: "")
    private let detailDescLabel = NSTextField(labelWithString: "")
    private let detailFeaturesLabel = NSTextField(labelWithString: "")
    private let openButton = NSButton(title: "Open in Browser", target: nil, action: nil)

    // MARK: - Lifecycle

    public override func loadView() {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        view = container

        setupSummaryBar()
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
        self.sequences = sequences
        self.displayedSequences = sequences

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
        summaryBar.update(sequences: sequences, annotationCount: totalAnnotations, gcCache: gcCache)

        applySortOrder()

        let isEmpty = sequences.isEmpty
        emptyStateLabel.isHidden = !isEmpty
        scrollView.isHidden = isEmpty
        detailPanel.isHidden = true

        tableView.reloadData()

        logger.info("Configured with \(sequences.count) sequences, \(totalAnnotations) annotations")
    }

    // MARK: - Setup: Summary Bar

    private func setupSummaryBar() {
        summaryBar.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(summaryBar)
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
        tableView.allowsMultipleSelection = false
        tableView.headerView = NSTableHeaderView()
        tableView.style = .plain
        tableView.doubleAction = #selector(tableDoubleClicked(_:))
        tableView.target = self

        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(scrollView)
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
        NSLayoutConstraint.activate([
            // Summary bar (top, below safe area to avoid overlapping title bar)
            summaryBar.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            summaryBar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            summaryBar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            summaryBar.heightAnchor.constraint(equalToConstant: 48),

            // Detail panel (bottom, fixed height)
            detailPanel.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            detailPanel.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            detailPanel.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            detailPanel.heightAnchor.constraint(equalToConstant: 80),

            // Table (middle, fills remaining space)
            scrollView.topAnchor.constraint(equalTo: summaryBar.bottomAnchor),
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

    // MARK: - Sorting

    private func applySortOrder() {
        guard !sortKey.isEmpty else {
            displayedSequences = sequences
            return
        }

        displayedSequences = sequences.sorted { a, b in
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

        detailNameLabel.stringValue = seq.name
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

        switch identifier.rawValue {
        case "name":
            textField.stringValue = seq.name
            textField.font = .systemFont(ofSize: 11, weight: .medium)

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

// MARK: - FASTACollectionSummaryBar

/// Summary card bar for the FASTA collection view.
///
/// Displays: Sequences, Total Length, Annotations, GC%, Shortest, Longest.
@MainActor
final class FASTACollectionSummaryBar: GenomicSummaryCardBar {

    // MARK: - State

    private var sequenceCount: Int = 0
    private var totalLength: Int64 = 0
    private var annotationCount: Int = 0
    private var meanGCPercent: Double = 0
    private var shortestLength: Int = 0
    private var longestLength: Int = 0

    // MARK: - Update

    /// Recomputes summary statistics from the provided sequences.
    ///
    /// - Parameters:
    ///   - sequences: All sequences in the FASTA file.
    ///   - annotationCount: Total number of annotations across all sequences.
    ///   - gcCache: Pre-computed GC percentages keyed by sequence ID.
    func update(
        sequences: [LungfishCore.Sequence],
        annotationCount: Int,
        gcCache: [UUID: Double]
    ) {
        self.sequenceCount = sequences.count
        self.annotationCount = annotationCount

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
        [
            Card(label: "Sequences", value: GenomicSummaryCardBar.formatCount(sequenceCount)),
            Card(label: "Total Length", value: GenomicSummaryCardBar.formatBases(totalLength)),
            Card(label: "Annotations", value: GenomicSummaryCardBar.formatCount(annotationCount)),
            Card(label: "GC Content", value: String(format: "%.1f%%", meanGCPercent)),
            Card(label: "Shortest", value: GenomicSummaryCardBar.formatBases(shortestLength)),
            Card(label: "Longest", value: GenomicSummaryCardBar.formatBases(longestLength)),
        ]
    }
}
