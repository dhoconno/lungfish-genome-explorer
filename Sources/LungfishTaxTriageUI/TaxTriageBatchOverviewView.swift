// TaxTriageBatchOverviewView.swift - Cross-sample batch overview for TaxTriage
// Copyright (c) 2025 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import LungfishIO
import LungfishKit
import os.log

private let logger = Logger(subsystem: "com.lungfish.app", category: "TaxTriageBatchOverview")

/// A reusable table cell that paints its semantic background through AppKit's
/// normal drawing lifecycle. This keeps heatmap and risk fills independent of
/// explicit Core Animation layer backing.
private final class TaxTriageBackgroundCellView: NSTableCellView {
    var backgroundFillColor: NSColor? {
        didSet {
            guard oldValue != backgroundFillColor else { return }
            needsDisplay = true
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        if let backgroundFillColor {
            backgroundFillColor.setFill()
            dirtyRect.fill()
        }
        super.draw(dirtyRect)
    }
}

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

    /// The value facet displayed in per-sample columns.
    enum ValueFacet: Int, CaseIterable {
        case tass = 0
        case reads = 1
        case uniqueReads = 2
        case coverage = 3

        var label: String {
            switch self {
            case .tass: return "TASS Score"
            case .reads: return "Total Reads"
            case .uniqueReads: return "Unique Reads"
            case .coverage: return "Coverage"
            }
        }
    }

    /// One row in the cross-sample summary table.
    struct CrossSampleRow {
        let organism: String
        let sampleCount: Int
        let meanTASS: Double
        let minReads: Int
        let maxReads: Int
        /// Per-sample TASS scores keyed by sample ID.
        let perSampleTASS: [String: Double]
        /// Per-sample read counts keyed by sample ID.
        let perSampleReads: [String: Int]
        /// Per-sample coverage breadth keyed by sample ID.
        let perSampleCoverage: [String: Double]
        /// Per-sample deduplicated (unique) read counts keyed by sample ID.
        let perSampleUniqueReads: [String: Int]
        /// Whether this organism was detected in a negative control sample.
        let isContaminationRisk: Bool
    }

    // MARK: - State

    /// FULL logical sample set. Used for the per-organism sample-count
    /// denominator (`"\(sampleCount)/\(sampleIds.count)"`) and cross-sample row
    /// construction. Never replaced by the display window.
    private var sampleIds: [String] = []

    /// Display-only cap on instantiated per-sample columns. Windowing only ever
    /// affects which columns `rebuildColumns()` instantiates and the
    /// double-click column->sample mapping; `sampleIds` stays full.
    private var columnWindow = SampleColumnWindow()

    /// The display-only slice of `sampleIds` currently instantiated as columns.
    /// The double-click handler maps clicked sample columns through THIS list so
    /// the mapping stays aligned with the instantiated columns.
    private var windowedSampleIds: [String] = []

    private var crossSampleRows: [CrossSampleRow] = []
    /// Unsorted rows, preserved for re-sorting.
    private var unsortedRows: [CrossSampleRow] = []
    /// Sample IDs flagged as negative controls.
    private var negativeControlSampleIds: Set<String> = []
    /// Current value facet for per-sample columns.
    private(set) var currentFacet: ValueFacet = .tass

    /// Called when a cell in the heatmap is clicked.
    /// Parameters: (organism name, sample ID).
    var onCellSelected: ((String, String) -> Void)?

    // MARK: - Child Views

    private let facetControl = NSSegmentedControl()
    private let columnWindowBanner = SampleColumnWindowBanner()
    private let scrollView = NSScrollView()
    private let tableView = TaxTriageTableView()
    private var preferredFontProvider: any ContentPreferredFontProviding =
        AppKitContentPreferredFontProvider()
    private nonisolated(unsafe) var contentTypographyObserver: NSObjectProtocol?
#if DEBUG
    private var typographyRealizedCellResolutionCount = 0
#endif

    // MARK: - Init

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setAccessibilityIdentifier("taxtriage-batch-overview")
        setAccessibilityLabel("TaxTriage batch overview")
        setupFacetControl()
        setupTableView()
        installContentTypographyObservation()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setAccessibilityIdentifier("taxtriage-batch-overview")
        setAccessibilityLabel("TaxTriage batch overview")
        setupFacetControl()
        setupTableView()
        installContentTypographyObservation()
    }

    deinit {
        if let contentTypographyObserver {
            NotificationCenter.default.removeObserver(contentTypographyObserver)
        }
    }

    // MARK: - Setup

    private func setupFacetControl() {
        facetControl.segmentCount = ValueFacet.allCases.count
        for facet in ValueFacet.allCases {
            facetControl.setLabel(facet.label, forSegment: facet.rawValue)
        }
        facetControl.selectedSegment = 0
        facetControl.segmentStyle = .rounded
        facetControl.controlSize = .small
        facetControl.target = self
        facetControl.action = #selector(facetChanged(_:))
        facetControl.translatesAutoresizingMaskIntoConstraints = false
        facetControl.setAccessibilityIdentifier("taxtriage-batch-overview-facet-control")
        facetControl.setAccessibilityLabel("Value facet")
        addSubview(facetControl)
    }

    private func setupTableView() {
        columnWindowBanner.onShowAll = { [weak self] in self?.showAllSampleColumns() }
        addSubview(columnWindowBanner)

        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        addSubview(scrollView)

        NSLayoutConstraint.activate([
            facetControl.topAnchor.constraint(equalTo: topAnchor, constant: 6),
            facetControl.centerXAnchor.constraint(equalTo: centerXAnchor),

            columnWindowBanner.topAnchor.constraint(equalTo: facetControl.bottomAnchor, constant: 6),
            columnWindowBanner.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            columnWindowBanner.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),

            scrollView.topAnchor.constraint(equalTo: columnWindowBanner.bottomAnchor, constant: 6),
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])

        tableView.usesAlternatingRowBackgroundColors = true
        tableView.allowsColumnReordering = false
        tableView.allowsColumnResizing = true
        tableView.allowsColumnSelection = false
        tableView.columnAutoresizingStyle = .noColumnAutoresizing
        tableView.rowHeight = 22
        tableView.style = .plain
        tableView.delegate = self
        tableView.dataSource = self
        tableView.target = self
        tableView.doubleAction = #selector(tableDoubleClicked(_:))
        tableView.setAccessibilityIdentifier("taxtriage-batch-overview-summary-table")
        tableView.setAccessibilityLabel("Cross-sample summary table")

        scrollView.documentView = tableView
    }

    private func installContentTypographyObservation() {
        contentTypographyObserver = NotificationCenter.default.addObserver(
            forName: .contentTextSizeDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.applyContentTypography()
            }
        }
        applyContentTypography()
    }

    private func applyContentTypography() {
        taxTriageApplyTableGeometry(
            to: tableView,
            minimumRowHeight: 22,
            preferredFontProvider: preferredFontProvider
        )
        let realizedCount = taxTriageForEachRealizedCell(in: tableView) {
            [weak self] column, _, view in
            guard let self,
                  let cell = view as? NSTableCellView,
                  let field = cell.textField else {
                return
            }
            self.applyContentTypography(to: field, column: column.identifier)
        }
#if DEBUG
        typographyRealizedCellResolutionCount = realizedCount
#endif
    }

    private func applyContentTypography(
        to field: NSTextField,
        column: NSUserInterfaceItemIdentifier
    ) {
        if column.rawValue == "organism" {
            field.font = taxTriageContentFont(
                canonicalPointSize: 12,
                weight: .medium,
                preferredFontProvider: preferredFontProvider
            )
        } else {
            field.font = taxTriageContentFont(
                canonicalPointSize: 11,
                digitsOnly: true,
                preferredFontProvider: preferredFontProvider
            )
        }
    }

    func setContentPreferredFontProvider(
        _ provider: any ContentPreferredFontProviding
    ) {
        preferredFontProvider = provider
        columnWindowBanner.setContentPreferredFontProvider(provider)
        applyContentTypography()
    }

    @objc private func facetChanged(_ sender: NSSegmentedControl) {
        guard let newFacet = ValueFacet(rawValue: sender.selectedSegment) else { return }
        currentFacet = newFacet
        tableView.reloadData()
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
        organismCol.sortDescriptorPrototype = NSSortDescriptor(key: "organism", ascending: true)
        tableView.addTableColumn(organismCol)

        let countCol = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("sampleCount"))
        countCol.title = "# Samples"
        countCol.width = 80
        countCol.minWidth = 60
        countCol.sortDescriptorPrototype = NSSortDescriptor(key: "sampleCount", ascending: false)
        tableView.addTableColumn(countCol)

        let meanCol = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("meanTASS"))
        meanCol.title = "Mean TASS"
        meanCol.width = 80
        meanCol.minWidth = 60
        meanCol.sortDescriptorPrototype = NSSortDescriptor(key: "meanTASS", ascending: false)
        tableView.addTableColumn(meanCol)

        let readsCol = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("reads"))
        readsCol.title = "Reads (min-max)"
        readsCol.width = 110
        readsCol.minWidth = 80
        readsCol.sortDescriptorPrototype = NSSortDescriptor(key: "reads", ascending: false)
        tableView.addTableColumn(readsCol)

        // Contamination risk column (only when negative controls exist)
        if !negativeControlSampleIds.isEmpty {
            let riskCol = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("risk"))
            riskCol.title = "Risk"
            riskCol.width = 50
            riskCol.minWidth = 40
            riskCol.sortDescriptorPrototype = NSSortDescriptor(key: "risk", ascending: false)
            tableView.addTableColumn(riskCol)
        }

        // Display-only window: instantiate at most `columnWindow.limit` sample
        // columns. `sampleIds` (the full logical set) is unchanged; per-cell
        // values still resolve from `perSample*` dictionaries keyed by sample ID.
        windowedSampleIds = columnWindow.windowedSamples(from: sampleIds)
        for sampleId in windowedSampleIds {
            let col = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("sample_\(sampleId)"))
            col.title = sampleLabels[sampleId] ?? sampleId
            col.headerToolTip = sampleId
            col.width = 70
            col.minWidth = 50
            col.sortDescriptorPrototype = NSSortDescriptor(key: "sample_\(sampleId)", ascending: false)
            tableView.addTableColumn(col)
        }
        applyCurrentColumnHeaderTypography()
    }

    private func applyCurrentColumnHeaderTypography() {
        let typography = ContentTypography.current(
            preferredFontProvider: preferredFontProvider
        )
        for column in tableView.tableColumns {
            column.headerCell.font = typography.font(for: .tableHeader)
            column.headerToolTip = column.headerToolTip ?? column.title
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
    /// Optional display labels for sample IDs (from CSV metadata).
    /// Keyed by sample ID, value is the display label.
    private var sampleLabels: [String: String] = [:]

    /// Per-sample deduplicated read counts, keyed by normalized organism name then sample ID.
    private var perSampleDedup: [String: [String: Int]] = [:]

    func configure(
        metrics: [TaxTriageMetric],
        sampleIds: [String],
        negativeControlSampleIds: Set<String> = [],
        sampleLabels: [String: String] = [:],
        perSampleDeduplicatedReadCounts: [String: [String: Int]] = [:]
    ) {
        self.sampleIds = sampleIds
        self.negativeControlSampleIds = negativeControlSampleIds
        self.sampleLabels = sampleLabels
        self.perSampleDedup = perSampleDeduplicatedReadCounts
        let rows = buildCrossSampleRows(from: metrics, sampleIds: sampleIds, negativeControlSampleIds: negativeControlSampleIds, perSampleDedup: perSampleDeduplicatedReadCounts)
        self.unsortedRows = rows
        self.crossSampleRows = rows
        columnWindow.reset()
        rebuildColumns()
        syncColumnWindowBanner()
        tableView.reloadData()
        logger.info("Batch overview configured: \(self.crossSampleRows.count) organisms across \(sampleIds.count) samples, \(negativeControlSampleIds.count) negative controls")
    }

    /// Whether the per-sample columns are currently capped by the display window.
    var isColumnWindowActive: Bool { columnWindow.caps(sampleIds) }

    /// Reveal every per-sample column, defeating the display cap.
    func showAllSampleColumns() {
        guard columnWindow.caps(sampleIds) else { return }
        columnWindow.revealAll()
        rebuildColumns()
        syncColumnWindowBanner()
        tableView.reloadData()
    }

    /// Keep the reveal banner in sync with the current window state.
    private func syncColumnWindowBanner() {
        columnWindowBanner.update(
            isWindowActive: isColumnWindowActive,
            shownCount: windowedSampleIds.count,
            totalCount: sampleIds.count
        )
    }

    // MARK: - Data Building

    private func buildCrossSampleRows(from metrics: [TaxTriageMetric], sampleIds: [String], negativeControlSampleIds: Set<String> = [], perSampleDedup: [String: [String: Int]] = [:]) -> [CrossSampleRow] {
        // Build a lowercased lookup for the dedup cache, whose keys use a different
        // normalization (strips decoration characters but does NOT lowercase) than
        // the organism grouping key below (which lowercases).
        var dedupByLowercasedKey: [String: [String: Int]] = [:]
        for (key, value) in perSampleDedup {
            dedupByLowercasedKey[key.lowercased()] = value
        }

        // Group metrics by organism
        var byOrganism: [String: [TaxTriageMetric]] = [:]
        for metric in metrics {
            let key = metric.organism.lowercased().trimmingCharacters(in: .whitespaces)
            byOrganism[key, default: []].append(metric)
        }

        var rows: [CrossSampleRow] = []
        for (normalizedKey, group) in byOrganism {
            guard let first = group.first else { continue }
            let detectedSamples = Set(group.compactMap(\.sample))
            let tassScores = group.map(\.tassScore)
            let readCounts = group.map(\.reads)
            let meanTASS = tassScores.isEmpty ? 0 : tassScores.reduce(0, +) / Double(tassScores.count)

            var perSampleTASS: [String: Double] = [:]
            var perSampleReads: [String: Int] = [:]
            var perSampleCoverage: [String: Double] = [:]
            for metric in group {
                if let sample = metric.sample {
                    perSampleTASS[sample] = metric.tassScore
                    perSampleReads[sample] = metric.reads
                    perSampleCoverage[sample] = metric.coverageBreadth ?? 0
                }
            }

            // Lookup per-sample unique reads from the lowercased dedup cache
            let perSampleUnique = dedupByLowercasedKey[normalizedKey] ?? [:]

            // Flag contamination risk: organism detected in any negative control sample
            let inNegativeControl = !negativeControlSampleIds.isEmpty
                && !detectedSamples.intersection(negativeControlSampleIds).isEmpty

            rows.append(CrossSampleRow(
                organism: first.organism,
                sampleCount: detectedSamples.count,
                meanTASS: meanTASS,
                minReads: readCounts.min() ?? 0,
                maxReads: readCounts.max() ?? 0,
                perSampleTASS: perSampleTASS,
                perSampleReads: perSampleReads,
                perSampleCoverage: perSampleCoverage,
                perSampleUniqueReads: perSampleUnique,
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

        // If clicked on a sample column, navigate to that organism in that sample.
        // The clicked column index maps through the *instantiated* (windowed)
        // sample columns, not the full logical `sampleIds`, so the mapping stays
        // aligned when the display window caps columns.
        let fixedColumnCount = negativeControlSampleIds.isEmpty ? 4 : 5
        if col >= fixedColumnCount, col - fixedColumnCount < windowedSampleIds.count {
            let sampleId = windowedSampleIds[col - fixedColumnCount]
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

    func tableView(_ tableView: NSTableView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
        guard let descriptor = tableView.sortDescriptors.first,
              let key = descriptor.key else {
            crossSampleRows = unsortedRows
            tableView.reloadData()
            return
        }

        let ascending = descriptor.ascending
        crossSampleRows = unsortedRows.sorted { a, b in
            let result: Bool
            switch key {
            case "organism":
                result = a.organism.localizedCaseInsensitiveCompare(b.organism) == .orderedAscending
            case "sampleCount":
                result = a.sampleCount < b.sampleCount
            case "meanTASS":
                result = a.meanTASS < b.meanTASS
            case "reads":
                result = a.maxReads < b.maxReads
            case "risk":
                // Contamination risks sort first
                result = !a.isContaminationRisk && b.isContaminationRisk
            default:
                // Per-sample column sorting — sort by the active facet value
                if key.hasPrefix("sample_") {
                    let sampleId = String(key.dropFirst("sample_".count))
                    let valA: Double
                    let valB: Double
                    switch currentFacet {
                    case .tass:
                        valA = a.perSampleTASS[sampleId] ?? -1
                        valB = b.perSampleTASS[sampleId] ?? -1
                    case .reads:
                        valA = Double(a.perSampleReads[sampleId] ?? -1)
                        valB = Double(b.perSampleReads[sampleId] ?? -1)
                    case .uniqueReads:
                        valA = Double(a.perSampleUniqueReads[sampleId] ?? -1)
                        valB = Double(b.perSampleUniqueReads[sampleId] ?? -1)
                    case .coverage:
                        valA = a.perSampleCoverage[sampleId] ?? -1
                        valB = b.perSampleCoverage[sampleId] ?? -1
                    }
                    result = valA < valB
                } else {
                    result = false
                }
            }
            return ascending ? result : !result
        }
        tableView.reloadData()
    }
}

// MARK: - NSTableViewDelegate

extension TaxTriageBatchOverviewView: NSTableViewDelegate {

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let column = tableColumn, row < crossSampleRows.count else { return nil }
        let data = crossSampleRows[row]

        let cellView = tableView.makeView(withIdentifier: column.identifier, owner: self) as? NSTableCellView
            ?? makeCellView(identifier: column.identifier)
        configure(cellView, column: column, rowData: data)
        return cellView
    }

    private func configure(
        _ cellView: NSTableCellView,
        column: NSTableColumn,
        rowData data: CrossSampleRow
    ) {
        guard let field = cellView.textField else { return }
        let id = column.identifier.rawValue

        // NSTableView reuses views across rows and after facet reloads. Reset
        // every semantic/display property before assigning the new value so a
        // warning explanation or an old facet value can never leak.
        field.stringValue = ""
        field.alignment = .natural
        field.toolTip = nil
        field.setAccessibilityLabel(nil)
        field.setAccessibilityValue(nil)
        field.setAccessibilityHelp(nil)
        cellView.toolTip = nil
        setBackgroundFillColor(nil, on: cellView)

        switch id {
        case "organism":
            field.stringValue = data.organism

        case "sampleCount":
            field.stringValue = "\(data.sampleCount)/\(sampleIds.count)"
            field.alignment = .center

        case "meanTASS":
            field.stringValue = String(format: "%.2f", data.meanTASS)
            field.alignment = .right
            let color = Self.tassColor(for: data.meanTASS)
            setBackgroundFillColor(color, on: cellView)

        case "reads":
            if data.minReads == data.maxReads {
                field.stringValue = formatReadCount(data.minReads)
            } else {
                field.stringValue = "\(formatReadCount(data.minReads))-\(formatReadCount(data.maxReads))"
            }
            field.alignment = .right

        case "risk":
            if data.isContaminationRisk {
                field.stringValue = "\u{26A0}"  // warning sign
                field.alignment = .center
                setBackgroundFillColor(
                    NSColor.lungfishDanger.withAlphaComponent(0.15),
                    on: cellView
                )
            }

        default:
            // Sample heatmap column — value depends on current facet
            if id.hasPrefix("sample_") {
                let sampleId = String(id.dropFirst("sample_".count))
                let score = data.perSampleTASS[sampleId]
                switch currentFacet {
                case .tass:
                    if let score {
                        field.stringValue = String(format: "%.2f", score)
                    } else {
                        field.stringValue = "-"
                    }
                    field.alignment = .center
                    setBackgroundFillColor(Self.tassColor(for: score), on: cellView)

                case .reads:
                    if let reads = data.perSampleReads[sampleId] {
                        field.stringValue = formatReadCount(reads)
                    } else {
                        field.stringValue = "-"
                    }
                    field.alignment = .center
                    setBackgroundFillColor(Self.tassColor(for: score), on: cellView)

                case .uniqueReads:
                    if let unique = data.perSampleUniqueReads[sampleId] {
                        field.stringValue = formatReadCount(unique)
                    } else if score != nil {
                        // Organism detected in this sample but unique reads not yet computed
                        field.stringValue = "\u{2026}"  // ellipsis
                    } else {
                        field.stringValue = "-"
                    }
                    field.alignment = .center
                    setBackgroundFillColor(Self.tassColor(for: score), on: cellView)

                case .coverage:
                    if let cov = data.perSampleCoverage[sampleId], cov > 0 {
                        field.stringValue = String(format: "%.1f%%", cov)
                    } else {
                        field.stringValue = "-"
                    }
                    field.alignment = .center
                    setBackgroundFillColor(Self.tassColor(for: score), on: cellView)
                }
            }
        }

        applyContentTypography(to: field, column: column.identifier)
        if id == "risk", data.isContaminationRisk {
            let explanation = "Detected in negative control sample"
            field.toolTip = explanation
            field.setAccessibilityLabel("Contamination risk")
            field.setAccessibilityValue("Contamination risk")
            field.setAccessibilityHelp(explanation)
            cellView.toolTip = explanation
        } else if !field.stringValue.isEmpty {
            field.toolTip = field.stringValue
            field.setAccessibilityValue(field.stringValue)
        }
    }

    private func setBackgroundFillColor(_ color: NSColor?, on cellView: NSTableCellView) {
        (cellView as? TaxTriageBackgroundCellView)?.backgroundFillColor = color
    }

    private func makeCellView(identifier: NSUserInterfaceItemIdentifier) -> NSTableCellView {
        let cell = TaxTriageBackgroundCellView()
        cell.identifier = identifier
        let tf = NSTextField(labelWithString: "")
        applyContentTypography(to: tf, column: identifier)
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

#if DEBUG
extension TaxTriageBatchOverviewView {
    /// Number of instantiated per-sample columns (identifier `sample_*`).
    var testingSampleColumnCount: Int {
        tableView.tableColumns.filter { $0.identifier.rawValue.hasPrefix("sample_") }.count
    }

    /// The FULL logical sample set (never windowed).
    var testingFullSampleIds: [String] { sampleIds }

    /// Per-organism sample-count denominator string for the given row, which must
    /// reflect the FULL sample count, not the windowed column count.
    func testingSampleCountLabel(row: Int) -> String? {
        guard row >= 0, row < crossSampleRows.count else { return nil }
        return "\(crossSampleRows[row].sampleCount)/\(sampleIds.count)"
    }

    /// Whether the "Show all" reveal banner is currently visible.
    var testingColumnWindowBannerVisible: Bool { !columnWindowBanner.isHidden }

    /// Invoke the banner's "Show all" action, exercising the wired callback.
    func testingTapShowAllBanner() { columnWindowBanner.onShowAll?() }

    var testingTableView: NSTableView { tableView }
    var testingBannerHeight: CGFloat { columnWindowBanner.testingPreferredHeight }
    var testingBannerLabelWraps: Bool { columnWindowBanner.testingMessageWraps }
    var testingTableReloadCount: Int { tableView.testingReloadDataCallCount }
    var testingTypographyRealizedCellResolutionCount: Int {
        typographyRealizedCellResolutionCount
    }
    var testingPresentationState: TaxTriageTablePresentationState {
        TaxTriageTablePresentationState(tableView: tableView)
    }

    func testingSetContentPreferredFontProvider(
        _ provider: any ContentPreferredFontProviding
    ) {
        setContentPreferredFontProvider(provider)
    }

    func testingCellView(column identifier: String, row: Int) -> NSView? {
        guard let columnIndex = tableView.tableColumns.firstIndex(where: {
            $0.identifier.rawValue == identifier
        }) else {
            return nil
        }
        return tableView.view(
            atColumn: columnIndex,
            row: row,
            makeIfNecessary: true
        )
    }

    func testingCell(column identifier: String, row: Int) -> NSTextField? {
        (testingCellView(column: identifier, row: row) as? NSTableCellView)?.textField
    }

    func testingBackgroundFillColor(in cell: NSTableCellView) -> NSColor? {
        (cell as? TaxTriageBackgroundCellView)?.backgroundFillColor
    }

    func testingRowIndex(organism: String) -> Int? {
        crossSampleRows.firstIndex { $0.organism == organism }
    }

    func testingSelectFacet(_ facet: ValueFacet) {
        facetControl.selectedSegment = facet.rawValue
        facetChanged(facetControl)
    }

    func testingConfigureReusableCell(
        column identifier: String,
        row: Int,
        reusing cell: NSTableCellView?
    ) -> NSTableCellView? {
        guard row >= 0, row < crossSampleRows.count,
              let column = tableView.tableColumns.first(where: {
                  $0.identifier.rawValue == identifier
              }) else {
            return nil
        }
        let resolvedCell = cell ?? makeCellView(identifier: column.identifier)
        configure(resolvedCell, column: column, rowData: crossSampleRows[row])
        return resolvedCell
    }

    func testingScroll(to origin: NSPoint) {
        scrollView.contentView.scroll(to: origin)
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }
}
#endif
