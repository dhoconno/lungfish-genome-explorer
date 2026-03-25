// TaxTriageBatchOverviewView.swift - Cross-sample batch overview for TaxTriage
// Copyright (c) 2025 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import LungfishIO
import os.log

private let logger = Logger(subsystem: "com.lungfish.app", category: "TaxTriageBatchOverview")

// MARK: - TaxTriageBatchOverviewView

/// A scrollable overview showing an organism x sample heatmap and cross-sample summary table
/// for multi-sample TaxTriage batch results.
///
/// ## Layout
///
/// ```
/// +-----------------------------------------------+
/// | Summary Cards (samples, high-conf per sample)  |
/// +-----------------------------------------------+
/// | Cross-Sample Table                             |
/// | Organism | #Samples | Mean TASS | Min/Max Reads|
/// +-----------------------------------------------+
/// | Organism x Sample Heatmap                      |
/// | (rows=organisms, cols=samples, cells=TASS)     |
/// +-----------------------------------------------+
/// ```
///
/// ## Thread Safety
///
/// `@MainActor` isolated. All data is set via ``configure(metrics:sampleIds:)``.
@MainActor
final class TaxTriageBatchOverviewView: NSView {

    // MARK: - Data Model

    /// One row in the cross-sample summary table.
    struct CrossSampleRow {
        let organism: String
        let sampleCount: Int
        let meanTASS: Double
        let minReads: Int
        let maxReads: Int
        /// Per-sample TASS scores keyed by sample ID.
        let perSampleTASS: [String: Double]
        /// Whether this organism was detected in a negative control sample.
        let isContaminationRisk: Bool
    }

    // MARK: - State

    private var sampleIds: [String] = []
    private var crossSampleRows: [CrossSampleRow] = []
    /// Sample IDs flagged as negative controls.
    private var negativeControlSampleIds: Set<String> = []

    /// Called when a cell in the heatmap is clicked.
    /// Parameters: (organism name, sample ID).
    var onCellSelected: ((String, String) -> Void)?

    // MARK: - Child Views

    private let scrollView = NSScrollView()
    private let tableView = NSTableView()

    // MARK: - Init

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupTableView()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupTableView()
    }

    // MARK: - Setup

    private func setupTableView() {
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        addSubview(scrollView)

        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])

        tableView.usesAlternatingRowBackgroundColors = true
        tableView.allowsColumnReordering = false
        tableView.allowsColumnResizing = true
        tableView.rowHeight = 22
        tableView.style = .plain
        tableView.delegate = self
        tableView.dataSource = self
        tableView.target = self
        tableView.doubleAction = #selector(tableDoubleClicked(_:))

        scrollView.documentView = tableView
    }

    /// Rebuilds table columns for the current sample IDs.
    private func rebuildColumns() {
        // Remove old columns
        while let col = tableView.tableColumns.last {
            tableView.removeTableColumn(col)
        }

        // Fixed columns
        let organismCol = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("organism"))
        organismCol.title = "Organism"
        organismCol.width = 200
        organismCol.minWidth = 120
        tableView.addTableColumn(organismCol)

        let countCol = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("sampleCount"))
        countCol.title = "# Samples"
        countCol.width = 80
        countCol.minWidth = 60
        tableView.addTableColumn(countCol)

        let meanCol = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("meanTASS"))
        meanCol.title = "Mean TASS"
        meanCol.width = 80
        meanCol.minWidth = 60
        tableView.addTableColumn(meanCol)

        let readsCol = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("reads"))
        readsCol.title = "Reads (min-max)"
        readsCol.width = 110
        readsCol.minWidth = 80
        tableView.addTableColumn(readsCol)

        // Contamination risk column (only when negative controls exist)
        if !negativeControlSampleIds.isEmpty {
            let riskCol = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("risk"))
            riskCol.title = "Risk"
            riskCol.width = 50
            riskCol.minWidth = 40
            tableView.addTableColumn(riskCol)
        }

        // One column per sample (heatmap cells)
        for sampleId in sampleIds {
            let col = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("sample_\(sampleId)"))
            col.title = sampleId
            col.width = 70
            col.minWidth = 50
            tableView.addTableColumn(col)
        }
    }

    // MARK: - Public API

    /// Configures the overview with parsed metrics and sample identifiers.
    ///
    /// - Parameters:
    ///   - metrics: All parsed TaxTriageMetric records across all samples.
    ///   - sampleIds: Ordered sample identifiers.
    /// Configures the overview with parsed metrics and sample identifiers.
    ///
    /// - Parameters:
    ///   - metrics: All parsed TaxTriageMetric records across all samples.
    ///   - sampleIds: Ordered sample identifiers.
    ///   - negativeControlSampleIds: Sample IDs that are negative controls.
    func configure(metrics: [TaxTriageMetric], sampleIds: [String], negativeControlSampleIds: Set<String> = []) {
        self.sampleIds = sampleIds
        self.negativeControlSampleIds = negativeControlSampleIds
        self.crossSampleRows = buildCrossSampleRows(from: metrics, sampleIds: sampleIds, negativeControlSampleIds: negativeControlSampleIds)
        rebuildColumns()
        tableView.reloadData()
        logger.info("Batch overview configured: \(self.crossSampleRows.count) organisms across \(sampleIds.count) samples, \(negativeControlSampleIds.count) negative controls")
    }

    // MARK: - Data Building

    private func buildCrossSampleRows(from metrics: [TaxTriageMetric], sampleIds: [String], negativeControlSampleIds: Set<String> = []) -> [CrossSampleRow] {
        // Group metrics by organism
        var byOrganism: [String: [TaxTriageMetric]] = [:]
        for metric in metrics {
            let key = metric.organism.lowercased().trimmingCharacters(in: .whitespaces)
            byOrganism[key, default: []].append(metric)
        }

        var rows: [CrossSampleRow] = []
        for (_, group) in byOrganism {
            guard let first = group.first else { continue }
            let detectedSamples = Set(group.compactMap(\.sample))
            let tassScores = group.map(\.tassScore)
            let readCounts = group.map(\.reads)
            let meanTASS = tassScores.isEmpty ? 0 : tassScores.reduce(0, +) / Double(tassScores.count)

            var perSample: [String: Double] = [:]
            for metric in group {
                if let sample = metric.sample {
                    perSample[sample] = metric.tassScore
                }
            }

            // Flag contamination risk: organism detected in any negative control sample
            let inNegativeControl = !negativeControlSampleIds.isEmpty
                && !detectedSamples.intersection(negativeControlSampleIds).isEmpty

            rows.append(CrossSampleRow(
                organism: first.organism,
                sampleCount: detectedSamples.count,
                meanTASS: meanTASS,
                minReads: readCounts.min() ?? 0,
                maxReads: readCounts.max() ?? 0,
                perSampleTASS: perSample,
                isContaminationRisk: inNegativeControl
            ))
        }

        // Sort by number of samples detected (desc), then by mean TASS (desc)
        return rows.sorted {
            if $0.sampleCount != $1.sampleCount {
                return $0.sampleCount > $1.sampleCount
            }
            return $0.meanTASS > $1.meanTASS
        }
    }

    // MARK: - Actions

    @objc private func tableDoubleClicked(_ sender: Any?) {
        let row = tableView.clickedRow
        let col = tableView.clickedColumn
        guard row >= 0, row < crossSampleRows.count else { return }

        let rowData = crossSampleRows[row]

        // If clicked on a sample column, navigate to that organism in that sample
        let fixedColumnCount = negativeControlSampleIds.isEmpty ? 4 : 5
        if col >= fixedColumnCount, col - fixedColumnCount < sampleIds.count {
            let sampleId = sampleIds[col - fixedColumnCount]
            onCellSelected?(rowData.organism, sampleId)
        }
    }

    // MARK: - TASS Color

    /// Returns a background color for a TASS score in the heatmap.
    private static func tassColor(for score: Double?) -> NSColor {
        guard let score else {
            return .clear
        }
        if score >= 0.8 {
            return NSColor.systemGreen.withAlphaComponent(0.35)
        } else if score >= 0.4 {
            return NSColor.systemYellow.withAlphaComponent(0.35)
        } else if score > 0 {
            return NSColor.systemOrange.withAlphaComponent(0.25)
        } else {
            return .clear
        }
    }
}

// MARK: - NSTableViewDataSource

extension TaxTriageBatchOverviewView: NSTableViewDataSource {

    func numberOfRows(in tableView: NSTableView) -> Int {
        crossSampleRows.count
    }
}

// MARK: - NSTableViewDelegate

extension TaxTriageBatchOverviewView: NSTableViewDelegate {

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let column = tableColumn, row < crossSampleRows.count else { return nil }
        let data = crossSampleRows[row]
        let id = column.identifier.rawValue

        let cellView = tableView.makeView(withIdentifier: column.identifier, owner: self) as? NSTableCellView
            ?? makeCellView(identifier: column.identifier)

        switch id {
        case "organism":
            cellView.textField?.stringValue = data.organism
            cellView.textField?.font = .systemFont(ofSize: 12, weight: .medium)
            cellView.wantsLayer = false
            cellView.layer?.backgroundColor = nil

        case "sampleCount":
            cellView.textField?.stringValue = "\(data.sampleCount)/\(sampleIds.count)"
            cellView.textField?.alignment = .center
            cellView.wantsLayer = false
            cellView.layer?.backgroundColor = nil

        case "meanTASS":
            cellView.textField?.stringValue = String(format: "%.2f", data.meanTASS)
            cellView.textField?.alignment = .right
            let color = Self.tassColor(for: data.meanTASS)
            cellView.layer?.backgroundColor = color.cgColor

        case "reads":
            if data.minReads == data.maxReads {
                cellView.textField?.stringValue = formatReadCount(data.minReads)
            } else {
                cellView.textField?.stringValue = "\(formatReadCount(data.minReads))-\(formatReadCount(data.maxReads))"
            }
            cellView.textField?.alignment = .right
            cellView.wantsLayer = false
            cellView.layer?.backgroundColor = nil

        case "risk":
            if data.isContaminationRisk {
                cellView.textField?.stringValue = "\u{26A0}"  // warning sign
                cellView.textField?.alignment = .center
                cellView.textField?.toolTip = "Detected in negative control sample"
                cellView.layer?.backgroundColor = NSColor.systemRed.withAlphaComponent(0.15).cgColor
            } else {
                cellView.textField?.stringValue = ""
                cellView.layer?.backgroundColor = nil
            }

        default:
            // Sample heatmap column
            if id.hasPrefix("sample_") {
                let sampleId = String(id.dropFirst("sample_".count))
                let score = data.perSampleTASS[sampleId]
                if let score {
                    cellView.textField?.stringValue = String(format: "%.2f", score)
                } else {
                    cellView.textField?.stringValue = "-"
                }
                cellView.textField?.alignment = .center
                let color = Self.tassColor(for: score)
                cellView.layer?.backgroundColor = color.cgColor
            }
        }

        return cellView
    }

    private func makeCellView(identifier: NSUserInterfaceItemIdentifier) -> NSTableCellView {
        let cell = NSTableCellView()
        cell.identifier = identifier
        let tf = NSTextField(labelWithString: "")
        tf.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        tf.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(tf)
        cell.textField = tf
        NSLayoutConstraint.activate([
            tf.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4),
            tf.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4),
            tf.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        return cell
    }

    private func formatReadCount(_ count: Int) -> String {
        if count >= 1_000_000 {
            return String(format: "%.1fM", Double(count) / 1_000_000)
        } else if count >= 1_000 {
            return String(format: "%.1fK", Double(count) / 1_000)
        }
        return "\(count)"
    }
}
