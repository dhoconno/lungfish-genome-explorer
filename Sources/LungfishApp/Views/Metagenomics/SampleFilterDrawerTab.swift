// SampleFilterDrawerTab.swift - Samples tab for metagenomics drawer filtering
// Copyright (c) 2025 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import LungfishIO
import os.log

private let logger = Logger(subsystem: "com.lungfish.app", category: "SampleFilterDrawerTab")

// MARK: - SampleFilterState

/// Filter state for batch sample visibility.
///
/// Maintained by the `SampleFilterDrawerTab` and consumed by
/// the parent view controller to filter batch overview data.
public struct SampleFilterState: Sendable, Equatable {
    /// All sample IDs in the batch.
    public var allSampleIds: [String]

    /// Sample IDs currently visible (checked in the drawer).
    public var visibleSampleIds: Set<String>

    /// Whether control samples are shown.
    public var showControls: Bool = false

    public init(allSampleIds: [String] = [], visibleSampleIds: Set<String> = []) {
        self.allSampleIds = allSampleIds
        self.visibleSampleIds = visibleSampleIds
    }

    /// Returns visible sample IDs respecting the showControls toggle.
    public func effectiveVisibleIds(metadata: [String: FASTQSampleMetadata]) -> [String] {
        allSampleIds.filter { id in
            guard visibleSampleIds.contains(id) else { return false }
            if !showControls, let meta = metadata[id], meta.sampleRole.isControl {
                return false
            }
            return true
        }
    }
}

// MARK: - SampleFilterDrawerTab

/// The Samples tab within the metagenomics drawer.
///
/// Shows a table of samples in the current batch analysis with:
/// - Checkbox column for visibility filtering
/// - Sample role icon (test, NTC, positive, environmental, extraction blank)
/// - Sample name / display label
/// - Key metadata columns (sample_type, collection_date, geo_loc_name)
///
/// When `sampleCount <= 1`, filtering controls are hidden and the tab
/// shows read-only metadata for the single sample.
@MainActor
final class SampleFilterDrawerTab: NSView {

    // MARK: - Data

    struct SampleRow {
        let sampleId: String
        let metadata: FASTQSampleMetadata?
        var isVisible: Bool
    }

    private var rows: [SampleRow] = []
    private var sampleMetadata: [String: FASTQSampleMetadata] = [:]
    private var filterState = SampleFilterState()

    // MARK: - UI

    private let tableView = NSTableView()
    private let scrollView = NSScrollView()
    private let showControlsButton = NSButton(checkboxWithTitle: "Show Controls", target: nil, action: nil)
    private let sampleCountLabel = NSTextField(labelWithString: "")

    // MARK: - Callbacks

    /// Called when visibility changes. Provides the set of visible sample IDs.
    var onFilterChanged: ((Set<String>) -> Void)?

    // MARK: - Setup

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupUI()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setupUI() {
        // Header bar with controls
        let headerStack = NSStackView()
        headerStack.orientation = .horizontal
        headerStack.spacing = 8
        headerStack.translatesAutoresizingMaskIntoConstraints = false
        headerStack.edgeInsets = NSEdgeInsets(top: 4, left: 8, bottom: 4, right: 8)

        showControlsButton.target = self
        showControlsButton.action = #selector(toggleShowControls(_:))
        showControlsButton.controlSize = .small
        showControlsButton.state = .off

        sampleCountLabel.font = .systemFont(ofSize: 11)
        sampleCountLabel.textColor = .secondaryLabelColor

        headerStack.addArrangedSubview(showControlsButton)
        headerStack.addArrangedSubview(NSView()) // spacer
        headerStack.addArrangedSubview(sampleCountLabel)

        addSubview(headerStack)

        // Table
        setupTableView()
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scrollView)

        NSLayoutConstraint.activate([
            headerStack.topAnchor.constraint(equalTo: topAnchor),
            headerStack.leadingAnchor.constraint(equalTo: leadingAnchor),
            headerStack.trailingAnchor.constraint(equalTo: trailingAnchor),
            headerStack.heightAnchor.constraint(equalToConstant: 28),

            scrollView.topAnchor.constraint(equalTo: headerStack.bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    private func setupTableView() {
        let columns: [(id: String, title: String, width: CGFloat)] = [
            ("visible", "", 24),
            ("role", "", 24),
            ("name", "Sample Name", 140),
            ("type", "Type", 120),
            ("date", "Date", 90),
            ("location", "Location", 100),
        ]

        for col in columns {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(col.id))
            column.title = col.title
            column.width = col.width
            column.minWidth = col.width == 24 ? 24 : 50
            tableView.addTableColumn(column)
        }

        tableView.dataSource = self
        tableView.delegate = self
        tableView.usesAlternatingRowBackgroundColors = true
        tableView.rowHeight = 20
        tableView.headerView = NSTableHeaderView()
        tableView.allowsMultipleSelection = false

        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
    }

    // MARK: - Configuration

    /// Configures the tab with sample data.
    func configure(sampleIds: [String], metadata: [String: FASTQSampleMetadata]) {
        self.sampleMetadata = metadata
        self.filterState = SampleFilterState(
            allSampleIds: sampleIds,
            visibleSampleIds: Set(sampleIds)
        )

        self.rows = sampleIds.map { id in
            SampleRow(sampleId: id, metadata: metadata[id], isVisible: true)
        }

        updateSampleCountLabel()
        tableView.reloadData()

        // Hide filtering controls for single-sample views
        showControlsButton.isHidden = sampleIds.count <= 1
    }

    /// Returns the set of currently visible (checked) sample IDs.
    var visibleSampleIds: Set<String> {
        filterState.effectiveVisibleIds(metadata: sampleMetadata).reduce(into: Set<String>()) { $0.insert($1) }
    }

    // MARK: - Actions

    @objc private func toggleShowControls(_ sender: NSButton) {
        filterState.showControls = sender.state == .on
        tableView.reloadData()
        notifyFilterChanged()
    }

    private func toggleVisibility(at row: Int) {
        guard row < rows.count else { return }
        rows[row].isVisible.toggle()
        let id = rows[row].sampleId
        if rows[row].isVisible {
            filterState.visibleSampleIds.insert(id)
        } else {
            filterState.visibleSampleIds.remove(id)
        }
        tableView.reloadData(forRowIndexes: IndexSet(integer: row), columnIndexes: IndexSet(0..<tableView.numberOfColumns))
        updateSampleCountLabel()
        notifyFilterChanged()
    }

    private func notifyFilterChanged() {
        let visible = visibleSampleIds
        onFilterChanged?(visible)
    }

    private func updateSampleCountLabel() {
        let total = rows.count
        let visible = visibleSampleIds.count
        if visible == total {
            sampleCountLabel.stringValue = "\(total) samples"
        } else {
            sampleCountLabel.stringValue = "\(visible)/\(total) visible"
        }
    }

    // MARK: - Role Icon

    private func roleIcon(for role: SampleRole) -> NSImage? {
        let symbolName: String
        switch role {
        case .testSample: symbolName = "person.fill"
        case .negativeControl: symbolName = "minus.circle"
        case .positiveControl: symbolName = "plus.circle"
        case .environmentalControl: symbolName = "leaf"
        case .extractionBlank: symbolName = "flask"
        }
        return NSImage(systemSymbolName: symbolName, accessibilityDescription: role.displayLabel)
    }
}

// MARK: - NSTableViewDataSource

extension SampleFilterDrawerTab: NSTableViewDataSource {
    func numberOfRows(in tableView: NSTableView) -> Int {
        rows.count
    }
}

// MARK: - NSTableViewDelegate

extension SampleFilterDrawerTab: NSTableViewDelegate {
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let columnID = tableColumn?.identifier.rawValue, row < rows.count else { return nil }
        let sampleRow = rows[row]
        let meta = sampleRow.metadata

        switch columnID {
        case "visible":
            let checkbox = NSButton(checkboxWithTitle: "", target: self, action: #selector(checkboxClicked(_:)))
            checkbox.state = sampleRow.isVisible ? .on : .off
            checkbox.tag = row
            return checkbox

        case "role":
            let imageView = NSImageView()
            let role = meta?.sampleRole ?? .testSample
            imageView.image = roleIcon(for: role)
            imageView.imageScaling = .scaleProportionallyDown
            imageView.toolTip = role.displayLabel
            return imageView

        case "name":
            return makeLabelView(text: meta?.sampleName ?? sampleRow.sampleId, tableView: tableView, id: columnID)

        case "type":
            return makeLabelView(text: meta?.sampleType ?? "", tableView: tableView, id: columnID)

        case "date":
            return makeLabelView(text: meta?.collectionDate ?? "", tableView: tableView, id: columnID)

        case "location":
            return makeLabelView(text: meta?.geoLocName ?? "", tableView: tableView, id: columnID)

        default:
            return nil
        }
    }

    @objc private func checkboxClicked(_ sender: NSButton) {
        toggleVisibility(at: sender.tag)
    }

    private func makeLabelView(text: String, tableView: NSTableView, id: String) -> NSTableCellView {
        let cellID = NSUserInterfaceItemIdentifier("SampleFilter_\(id)")
        if let existing = tableView.makeView(withIdentifier: cellID, owner: self) as? NSTableCellView {
            existing.textField?.stringValue = text
            return existing
        }

        let cell = NSTableCellView()
        cell.identifier = cellID
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 11)
        label.lineBreakMode = .byTruncatingTail
        label.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(label)
        cell.textField = label

        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
            label.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -2),
            label.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])

        return cell
    }
}
