// StrainComparisonView.swift - Basic strain-level comparison between samples
// Copyright (c) 2025 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import LungfishIO
import os.log

private let logger = Logger(subsystem: "com.lungfish.app", category: "StrainComparison")

// MARK: - StrainComparisonEntry

/// A single position where samples differ in their consensus sequence.
struct StrainComparisonEntry: Equatable {
    /// Reference accession (e.g. NC_009539.1).
    let accession: String

    /// 0-based position on the reference.
    let position: Int

    /// Reference base at this position (if available).
    let referenceBase: Character?

    /// Map of sample ID to the consensus base at this position.
    let sampleBases: [String: Character]
}

// MARK: - StrainComparisonView

/// A table view showing nucleotide positions where samples differ for a given organism.
///
/// This is a basic implementation suitable for displaying consensus-level SNP differences
/// between samples in a multi-sample TaxTriage batch run.
@MainActor
final class StrainComparisonView: NSView {

    // MARK: - State

    private var entries: [StrainComparisonEntry] = []
    private var sampleIds: [String] = []
    private var organismName: String = ""

    // MARK: - Child Views

    private let scrollView = NSScrollView()
    private let tableView = NSTableView()
    private let headerLabel = NSTextField(labelWithString: "")

    // MARK: - Init

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupViews()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupViews()
    }

    // MARK: - Setup

    private func setupViews() {
        headerLabel.translatesAutoresizingMaskIntoConstraints = false
        headerLabel.font = .systemFont(ofSize: 12, weight: .semibold)
        headerLabel.textColor = .labelColor
        addSubview(headerLabel)

        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        addSubview(scrollView)

        tableView.usesAlternatingRowBackgroundColors = true
        tableView.allowsColumnReordering = false
        tableView.allowsColumnResizing = true
        tableView.rowHeight = 20
        tableView.style = .plain
        tableView.delegate = self
        tableView.dataSource = self

        scrollView.documentView = tableView

        NSLayoutConstraint.activate([
            headerLabel.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            headerLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            headerLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),

            scrollView.topAnchor.constraint(equalTo: headerLabel.bottomAnchor, constant: 6),
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    private func rebuildColumns() {
        while let col = tableView.tableColumns.last {
            tableView.removeTableColumn(col)
        }

        let accCol = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("accession"))
        accCol.title = "Accession"
        accCol.width = 120
        accCol.minWidth = 80
        tableView.addTableColumn(accCol)

        let posCol = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("position"))
        posCol.title = "Position"
        posCol.width = 80
        posCol.minWidth = 60
        tableView.addTableColumn(posCol)

        let refCol = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("reference"))
        refCol.title = "Ref"
        refCol.width = 40
        refCol.minWidth = 30
        tableView.addTableColumn(refCol)

        for sampleId in sampleIds {
            let col = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("sample_\(sampleId)"))
            col.title = sampleId
            col.width = 60
            col.minWidth = 40
            tableView.addTableColumn(col)
        }
    }

    // MARK: - Public API

    /// Configures the view with strain comparison data.
    ///
    /// - Parameters:
    ///   - entries: The differing positions to display.
    ///   - sampleIds: Ordered sample identifiers.
    ///   - organismName: The organism name for the header.
    func configure(entries: [StrainComparisonEntry], sampleIds: [String], organismName: String) {
        self.entries = entries
        self.sampleIds = sampleIds
        self.organismName = organismName

        if entries.isEmpty {
            headerLabel.stringValue = "\(organismName) \u{2014} No nucleotide differences detected"
        } else {
            headerLabel.stringValue = "\(organismName) \u{2014} \(entries.count) differing position(s)"
        }

        rebuildColumns()
        tableView.reloadData()
        logger.info("Strain comparison: \(entries.count) SNP(s) for \(organismName, privacy: .public) across \(sampleIds.count) samples")
    }
}

// MARK: - NSTableViewDataSource

extension StrainComparisonView: NSTableViewDataSource {
    func numberOfRows(in tableView: NSTableView) -> Int {
        entries.count
    }
}

// MARK: - NSTableViewDelegate

extension StrainComparisonView: NSTableViewDelegate {
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let column = tableColumn, row < entries.count else { return nil }
        let entry = entries[row]
        let id = column.identifier.rawValue

        let field = NSTextField(labelWithString: "")
        field.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        field.lineBreakMode = .byTruncatingTail

        switch id {
        case "accession":
            field.stringValue = entry.accession

        case "position":
            field.stringValue = "\(entry.position + 1)"  // 1-based display
            field.alignment = .right

        case "reference":
            field.stringValue = entry.referenceBase.map(String.init) ?? "-"
            field.alignment = .center

        default:
            if id.hasPrefix("sample_") {
                let sampleId = String(id.dropFirst("sample_".count))
                if let base = entry.sampleBases[sampleId] {
                    field.stringValue = String(base)
                    // Highlight if different from reference
                    if let refBase = entry.referenceBase, base != refBase {
                        field.textColor = .systemRed
                        field.font = .monospacedSystemFont(ofSize: 11, weight: .bold)
                    }
                } else {
                    field.stringValue = "-"
                    field.textColor = .tertiaryLabelColor
                }
                field.alignment = .center
            }
        }

        return field
    }
}
