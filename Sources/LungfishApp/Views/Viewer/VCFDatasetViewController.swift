// VCFDatasetViewController.swift - Standalone VCF dataset dashboard
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import LungfishIO
import os.log

private let logger = Logger(subsystem: "com.lungfish.browser", category: "VCFDataset")

// MARK: - VCFDatasetViewController

/// Dashboard view controller for standalone VCF files (not loaded into a bundle).
///
/// Displays:
/// - Summary bar with reference inference, variant count, type breakdown
/// - Searchable/sortable variant table
/// - "Download Reference" button when a reference genome is inferred
@MainActor
public final class VCFDatasetViewController: NSViewController,
    NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate {

    // MARK: - Properties

    private var summary: VCFSummary?
    private var allVariants: [VCFVariant] = []
    private var displayedVariants: [VCFVariant] = []
    private var filterText: String = ""
    private var typeFilter: String? = nil

    private var sortKey: String = ""
    private var sortAscending: Bool = true

    /// Callback invoked when the user requests to download the inferred reference.
    public var onDownloadReferenceRequested: ((ReferenceInference.Result) -> Void)?

    // MARK: - UI Components

    private let summaryBar = VCFSummaryBar()
    private let typeChipsBar = NSView()
    private let searchBar = NSView()
    private let searchField = NSSearchField()
    private let countLabel = NSTextField(labelWithString: "")
    private let scrollView = NSScrollView()
    private let tableView = NSTableView()
    private let emptyStateLabel = NSTextField(labelWithString: "")

    // MARK: - Lifecycle

    public override func loadView() {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        container.wantsLayer = true
        view = container

        setupSummaryBar()
        setupTypeChipsBar()
        setupSearchBar()
        setupTableView()
        setupEmptyState()
        layoutSubviews()
    }

    // MARK: - Public API

    /// Configure the dashboard with a VCF summary and variant list.
    public func configure(summary: VCFSummary, variants: [VCFVariant]) {
        self.summary = summary
        self.allVariants = variants
        self.displayedVariants = variants

        summaryBar.update(with: summary)
        updateTypeChips()
        updateCountLabel()
        tableView.reloadData()

        let isEmpty = variants.isEmpty
        emptyStateLabel.isHidden = !isEmpty
        scrollView.isHidden = isEmpty
        searchBar.isHidden = isEmpty
    }

    // MARK: - Setup

    private func setupSummaryBar() {
        summaryBar.translatesAutoresizingMaskIntoConstraints = false
        summaryBar.onDownloadReference = { [weak self] result in
            self?.onDownloadReferenceRequested?(result)
        }
        view.addSubview(summaryBar)
    }

    private func setupTypeChipsBar() {
        typeChipsBar.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(typeChipsBar)
    }

    private func setupSearchBar() {
        searchBar.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(searchBar)

        searchField.placeholderString = "Filter variants by position, ref, alt..."
        searchField.delegate = self
        searchField.translatesAutoresizingMaskIntoConstraints = false
        searchField.sendsSearchStringImmediately = true
        searchBar.addSubview(searchField)

        countLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        countLabel.textColor = .secondaryLabelColor
        countLabel.alignment = .right
        countLabel.translatesAutoresizingMaskIntoConstraints = false
        searchBar.addSubview(countLabel)

        NSLayoutConstraint.activate([
            searchField.leadingAnchor.constraint(equalTo: searchBar.leadingAnchor, constant: 8),
            searchField.centerYAnchor.constraint(equalTo: searchBar.centerYAnchor),
            searchField.widthAnchor.constraint(lessThanOrEqualToConstant: 300),

            countLabel.trailingAnchor.constraint(equalTo: searchBar.trailingAnchor, constant: -8),
            countLabel.centerYAnchor.constraint(equalTo: searchBar.centerYAnchor),
            countLabel.leadingAnchor.constraint(greaterThanOrEqualTo: searchField.trailingAnchor, constant: 8),
        ])
    }

    private func setupTableView() {
        let columns: [(id: String, title: String, width: CGFloat)] = [
            ("index", "#", 50),
            ("chrom", "Chrom", 120),
            ("pos", "Position", 80),
            ("ref", "Ref", 60),
            ("alt", "Alt", 60),
            ("type", "Type", 60),
            ("qual", "Quality", 80),
            ("filter", "Filter", 80),
            ("af", "AF", 60),
            ("dp", "DP", 60),
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
        tableView.rowHeight = 20
        tableView.allowsMultipleSelection = false
        tableView.headerView = NSTableHeaderView()
        tableView.style = .plain

        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(scrollView)
    }

    private func setupEmptyState() {
        emptyStateLabel.stringValue = "No variants found in this VCF file."
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

    private func layoutSubviews() {
        NSLayoutConstraint.activate([
            // Summary bar
            summaryBar.topAnchor.constraint(equalTo: view.topAnchor),
            summaryBar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            summaryBar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            summaryBar.heightAnchor.constraint(equalToConstant: 64),

            // Type chips bar
            typeChipsBar.topAnchor.constraint(equalTo: summaryBar.bottomAnchor),
            typeChipsBar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            typeChipsBar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            typeChipsBar.heightAnchor.constraint(equalToConstant: 32),

            // Search bar
            searchBar.topAnchor.constraint(equalTo: typeChipsBar.bottomAnchor, constant: 2),
            searchBar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            searchBar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            searchBar.heightAnchor.constraint(equalToConstant: 32),

            // Table
            scrollView.topAnchor.constraint(equalTo: searchBar.bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
    }

    // MARK: - Type Chip Filtering

    private func updateTypeChips() {
        // Clear existing chips
        typeChipsBar.subviews.forEach { $0.removeFromSuperview() }

        guard let summary = summary, !summary.variantTypes.isEmpty else { return }

        var xOffset: CGFloat = 8
        let sorted = summary.variantTypes.sorted { $0.value > $1.value }

        // "All" chip
        let allButton = makeChipButton(title: "All (\(summary.variantCount))", tag: -1)
        allButton.state = (typeFilter == nil) ? .on : .off
        allButton.frame.origin = CGPoint(x: xOffset, y: 4)
        typeChipsBar.addSubview(allButton)
        xOffset += allButton.frame.width + 6

        for (index, entry) in sorted.enumerated() {
            let chip = makeChipButton(title: "\(entry.key) (\(entry.value))", tag: index)
            chip.state = (typeFilter == entry.key) ? .on : .off
            chip.frame.origin = CGPoint(x: xOffset, y: 4)
            chip.toolTip = entry.key
            typeChipsBar.addSubview(chip)
            xOffset += chip.frame.width + 6
        }
    }

    private func makeChipButton(title: String, tag: Int) -> NSButton {
        let button = NSButton(title: title, target: self, action: #selector(chipTapped(_:)))
        button.bezelStyle = .inline
        button.setButtonType(.pushOnPushOff)
        button.tag = tag
        button.font = .systemFont(ofSize: 11)
        button.sizeToFit()
        return button
    }

    @objc private func chipTapped(_ sender: NSButton) {
        if sender.tag == -1 {
            // "All" chip
            typeFilter = nil
        } else {
            guard let summary = summary else { return }
            let sorted = summary.variantTypes.sorted { $0.value > $1.value }
            guard sender.tag < sorted.count else { return }
            let key = sorted[sender.tag].key
            typeFilter = (typeFilter == key) ? nil : key
        }
        applyFilter()
        updateTypeChips()
    }

    // MARK: - Filtering

    private func applyFilter() {
        let trimmed = filterText.trimmingCharacters(in: .whitespaces).lowercased()
        displayedVariants = allVariants.filter { variant in
            // Type filter
            if let tf = typeFilter {
                let variantType = classifyVariantType(variant)
                if variantType != tf { return false }
            }
            // Text filter
            if !trimmed.isEmpty {
                let posStr = "\(variant.position)"
                let combined = "\(variant.chromosome) \(posStr) \(variant.ref) \(variant.alt.joined(separator: ","))".lowercased()
                if !combined.contains(trimmed) { return false }
            }
            return true
        }
        applySortOrder()
        updateCountLabel()
        tableView.reloadData()
    }

    private func classifyVariantType(_ variant: VCFVariant) -> String {
        let ref = variant.ref
        guard let firstAlt = variant.alt.first else { return "OTHER" }
        if ref.count == 1 && firstAlt.count == 1 { return "SNP" }
        if ref.count < firstAlt.count { return "INS" }
        if ref.count > firstAlt.count { return "DEL" }
        if ref.count == firstAlt.count && ref.count > 1 { return "MNP" }
        return "OTHER"
    }

    private func updateCountLabel() {
        let total = allVariants.count
        let shown = displayedVariants.count
        if shown == total {
            countLabel.stringValue = "\(formatCount(total)) variants"
        } else {
            countLabel.stringValue = "\(formatCount(shown)) of \(formatCount(total)) variants"
        }
    }

    private func formatCount(_ count: Int) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        return formatter.string(from: NSNumber(value: count)) ?? "\(count)"
    }

    // MARK: - Sorting

    private func applySortOrder() {
        guard !sortKey.isEmpty else { return }
        displayedVariants.sort { a, b in
            let result: Bool
            switch sortKey {
            case "pos":
                result = a.position < b.position
            case "chrom":
                result = a.chromosome < b.chromosome
            case "ref":
                result = a.ref < b.ref
            case "alt":
                result = (a.alt.first ?? "") < (b.alt.first ?? "")
            case "qual":
                result = (a.quality ?? 0) < (b.quality ?? 0)
            case "type":
                result = classifyVariantType(a) < classifyVariantType(b)
            case "filter":
                result = (a.filter ?? "") < (b.filter ?? "")
            case "af":
                result = (Double(a.info["AF"] ?? "0") ?? 0) < (Double(b.info["AF"] ?? "0") ?? 0)
            case "dp":
                result = (Int(a.info["DP"] ?? "0") ?? 0) < (Int(b.info["DP"] ?? "0") ?? 0)
            default:
                return false
            }
            return sortAscending ? result : !result
        }
    }

    // MARK: - NSSearchFieldDelegate

    public func controlTextDidChange(_ obj: Notification) {
        guard let field = obj.object as? NSSearchField, field === searchField else { return }
        filterText = field.stringValue
        applyFilter()
    }

    // MARK: - NSTableViewDataSource

    public func numberOfRows(in tableView: NSTableView) -> Int {
        displayedVariants.count
    }

    public func tableView(_ tableView: NSTableView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
        guard let descriptor = tableView.sortDescriptors.first,
              let key = descriptor.key else { return }
        sortKey = key
        sortAscending = descriptor.ascending
        applySortOrder()
        tableView.reloadData()
    }

    // MARK: - NSTableViewDelegate

    public func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard row < displayedVariants.count,
              let identifier = tableColumn?.identifier else { return nil }
        let variant = displayedVariants[row]

        let cell = reuseOrCreate(identifier: identifier, in: tableView)
        let textField = cell.textField ?? {
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
            return tf
        }()

        textField.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        textField.textColor = .labelColor

        switch identifier.rawValue {
        case "index":
            textField.stringValue = "\(row + 1)"
            textField.alignment = .right
            textField.textColor = .secondaryLabelColor

        case "chrom":
            textField.stringValue = variant.chromosome
            textField.font = .monospacedSystemFont(ofSize: 11, weight: .regular)

        case "pos":
            textField.stringValue = formatCount(variant.position)
            textField.alignment = .right

        case "ref":
            textField.stringValue = variant.ref
            textField.font = .monospacedSystemFont(ofSize: 11, weight: .regular)

        case "alt":
            textField.stringValue = variant.alt.joined(separator: ",")
            textField.font = .monospacedSystemFont(ofSize: 11, weight: .regular)

        case "type":
            let vtype = classifyVariantType(variant)
            textField.stringValue = vtype
            textField.textColor = colorForVariantType(vtype)

        case "qual":
            if let q = variant.quality {
                textField.stringValue = q >= 100 ? formatCount(Int(q)) : String(format: "%.1f", q)
            } else {
                textField.stringValue = "."
                textField.textColor = .tertiaryLabelColor
            }
            textField.alignment = .right

        case "filter":
            textField.stringValue = variant.filter ?? "."
            if variant.isPassing {
                textField.textColor = .systemGreen
            } else {
                textField.textColor = .systemOrange
            }

        case "af":
            if let afStr = variant.info["AF"], let af = Double(afStr) {
                textField.stringValue = String(format: "%.4f", af)
            } else {
                textField.stringValue = "."
                textField.textColor = .tertiaryLabelColor
            }
            textField.alignment = .right

        case "dp":
            if let dpStr = variant.info["DP"] {
                textField.stringValue = dpStr
            } else {
                textField.stringValue = "."
                textField.textColor = .tertiaryLabelColor
            }
            textField.alignment = .right

        default:
            textField.stringValue = ""
        }

        return cell
    }

    private func reuseOrCreate(identifier: NSUserInterfaceItemIdentifier, in tableView: NSTableView) -> NSTableCellView {
        if let existing = tableView.makeView(withIdentifier: identifier, owner: nil) as? NSTableCellView {
            return existing
        }
        let cell = NSTableCellView()
        cell.identifier = identifier
        return cell
    }

    private func colorForVariantType(_ type: String) -> NSColor {
        switch type {
        case "SNP": return .systemBlue
        case "INS": return .systemGreen
        case "DEL": return .systemRed
        case "MNP": return .systemPurple
        default: return .secondaryLabelColor
        }
    }
}

// MARK: - VCFSummaryBar

/// Header bar showing VCF summary information and optional download button.
@MainActor
final class VCFSummaryBar: NSView {

    var onDownloadReference: ((ReferenceInference.Result) -> Void)?
    private var inferredReference: ReferenceInference.Result?

    private let titleLabel = NSTextField(labelWithString: "")
    private let subtitleLabel = NSTextField(labelWithString: "")
    private let downloadButton = NSButton(title: "Download Reference", target: nil, action: nil)

    override init(frame: NSRect) {
        super.init(frame: frame)
        setup()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    private func setup() {
        wantsLayer = true

        titleLabel.font = .systemFont(ofSize: 16, weight: .semibold)
        titleLabel.textColor = .labelColor
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(titleLabel)

        subtitleLabel.font = .systemFont(ofSize: 12, weight: .regular)
        subtitleLabel.textColor = .secondaryLabelColor
        subtitleLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(subtitleLabel)

        downloadButton.bezelStyle = .rounded
        downloadButton.target = self
        downloadButton.action = #selector(downloadTapped)
        downloadButton.translatesAutoresizingMaskIntoConstraints = false
        downloadButton.isHidden = true
        addSubview(downloadButton)

        NSLayoutConstraint.activate([
            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            titleLabel.topAnchor.constraint(equalTo: topAnchor, constant: 8),

            subtitleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            subtitleLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 2),

            downloadButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            downloadButton.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    func update(with summary: VCFSummary) {
        // Title: organism/assembly or chromosome names
        if let ref = summary.inferredReference {
            titleLabel.stringValue = "\(ref.organism) (\(ref.assembly))"
            inferredReference = ref
            downloadButton.isHidden = false
        } else if !summary.chromosomes.isEmpty {
            let chroms = summary.chromosomes.sorted().prefix(5)
            let chromStr = chroms.joined(separator: ", ")
            titleLabel.stringValue = summary.chromosomes.count > 5 ? "\(chromStr), ..." : chromStr
            inferredReference = nil
            downloadButton.isHidden = true
        } else {
            titleLabel.stringValue = "VCF File"
            inferredReference = nil
            downloadButton.isHidden = true
        }

        // Subtitle: variant count + type breakdown
        var parts: [String] = ["\(summary.variantCount) variants"]

        let typeBreakdown = summary.variantTypes.sorted { $0.value > $1.value }
            .map { "\($0.value) \($0.key)s" }
        if !typeBreakdown.isEmpty {
            parts.append(typeBreakdown.joined(separator: ", "))
        }

        if !summary.hasSampleColumns {
            parts.append("no sample columns")
        } else {
            let sampleCount = summary.header.sampleNames.count
            parts.append("\(sampleCount) sample\(sampleCount == 1 ? "" : "s")")
        }

        // Quality range
        if let qMin = summary.qualityStats.min, let qMax = summary.qualityStats.max {
            parts.append("QUAL \(Int(qMin))\u{2013}\(Int(qMax))")
        }

        // Filter breakdown
        let passCount = summary.filterCounts["PASS"] ?? 0
        let filteredCount = summary.variantCount - passCount
        if filteredCount > 0 {
            parts.append("\(passCount) PASS, \(filteredCount) filtered")
        }

        subtitleLabel.stringValue = parts.joined(separator: "  \u{2022}  ")
    }

    @objc private func downloadTapped() {
        guard let ref = inferredReference else { return }
        onDownloadReference?(ref)
    }
}
