import AppKit
import LungfishCore
import LungfishIO

@MainActor
final class GenotypeComparisonMatrixView: NSView, NSTableViewDataSource, NSTableViewDelegate {
    private struct CellKey: Hashable {
        let locus: String
        let genotype: String
        let sample: String
    }

    private struct RowKey: Hashable {
        let locus: String
        let genotype: String
    }

    private struct SupportBucketKey: Hashable {
        let sample: String
        let locus: String
    }

    private struct CallSupportContext {
        let call: ONTGenotypeCall
        let locus: String
    }

    private enum ColumnID {
        static let genotype = NSUserInterfaceItemIdentifier("genotype")
        static let locus = NSUserInterfaceItemIdentifier("locus")
        static let samples = NSUserInterfaceItemIdentifier("samples")
        static let uniqueReads = NSUserInterfaceItemIdentifier("uniqueReads")
        static func sample(_ index: Int) -> NSUserInterfaceItemIdentifier {
            NSUserInterfaceItemIdentifier("sample-\(index)")
        }
    }

    var onSharedCallSelected: ((ONTGenotypeSharedCall, String?, [GenotypeAnnotationSidecar.MatrixTarget]) -> Void)?
    var onMatrixTargetsSelected: (([GenotypeAnnotationSidecar.MatrixTarget]) -> Void)?
    var onSelectionCleared: (() -> Void)?
    var onDisplaySummaryChanged: ((Int, Int, Int) -> Void)?

    private let filterField = NSSearchField()
    private let locusPopup = NSPopUpButton()
    private let scrollView = NSScrollView()
    private let tableView = GenotypeMatrixTableView()
    private var result: ONTGenotypeResultBundleData?
    private var displayState = GenotypeResultDisplayState()
    private var metadataStore: SampleMetadataStore?
    private var allRows: [ONTGenotypeSharedCall] = []
    private var visibleRows: [ONTGenotypeSharedCall] = []
    private var sampleNames: [String] = []
    private var visibleSampleNames: [String] = []
    private var sampleColumnLookup: [NSUserInterfaceItemIdentifier: String] = [:]
    private var supportByRowAndSample: [RowKey: [String: ONTGenotypeSampleSupport]] = [:]
    private var selectedGenotype: String?
    private var selectedSampleName: String?
    private var selectedRowLocus: String?
    private var selectedMatrixTargets: [GenotypeAnnotationSidecar.MatrixTarget] = []
    private var selectedColumnSamples: [String] = []
    private var columnSelectionAnchorSample: String?
    private var suppressSelectionClearedCallback = false
    private var pendingColumnSelectionTargets: [GenotypeAnnotationSidecar.MatrixTarget]?
    private var pendingColumnSelectionCleared = false
    private var selectedFilterLocus: String?
    private var pendingClickedSampleName: String?
    private var filterText = ""
    /// Set of sample IDs allowed by the active Smart Cohort + Quick Filter.
    /// `nil` means no cohort restriction is active and every sample is allowed.
    /// When non-`nil`, rows are kept only if at least one supporting sample is
    /// in the set, and per-sample columns matching outside the set are also
    /// filtered out of the text-search match path so the matrix view stays
    /// consistent with Outline.
    private var allowedSampleIDs: Set<String>?
    private var totalRowCount = 0
    private var hiddenCellCount = 0
    private var supportFractionByCell: [CellKey: Double] = [:]
    private var cellStyles: [CellKey: GenotypeResultHighlightStyle] = [:]
    private var rowStyles: [RowKey: GenotypeResultHighlightStyle] = [:]
    private var sidecarCellStyles: [CellKey: GenotypeAnnotationSidecar.MatrixStyle] = [:]
    private var sidecarRowStyles: [RowKey: GenotypeAnnotationSidecar.MatrixStyle] = [:]
    private var sidecarColumnStyles: [String: GenotypeAnnotationSidecar.MatrixStyle] = [:]
    private var sidecarCellComments: [CellKey: [String]] = [:]
    private var sidecarRowComments: [RowKey: [String]] = [:]
    private var sidecarColumnComments: [String: [String]] = [:]

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        buildView()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        buildView()
    }

    func configure(
        result: ONTGenotypeResultBundleData,
        metadataStore: SampleMetadataStore? = nil,
        sidecar: GenotypeAnnotationSidecar? = nil
    ) {
        self.result = result
        self.metadataStore = metadataStore
        sampleNames = result.sampleNames
        if sampleNames.isEmpty {
            sampleNames = orderedSamples(from: result.calls)
        }
        selectedRowLocus = nil
        selectedFilterLocus = nil
        selectedGenotype = nil
        selectedSampleName = nil
        selectedMatrixTargets = []
        selectedColumnSamples = []
        columnSelectionAnchorSample = nil
        pendingColumnSelectionTargets = nil
        pendingColumnSelectionCleared = false
        applyAnnotationSidecar(sidecar, reload: false)
        rebuildRowsFromResult()
        rebuildColumns()
        applyDefaultSortDescriptor()
        applyFilterAndSort()
    }

    func applyDisplayState(_ state: GenotypeResultDisplayState) {
        let previousState = displayState
        let previousSamples = activeSampleNames()
        displayState = state

        if state.requiresMatrixRowRebuild(comparedTo: previousState) {
            rebuildRowsFromResult()
        } else if state.supportDenominator != previousState.supportDenominator, let result {
            supportFractionByCell = makeSupportFractionLookup(for: result)
        }

        if activeSampleNames() != previousSamples {
            rebuildColumns()
            applyDefaultSortDescriptor()
        }

        if state.requiresMatrixFilterPass(comparedTo: previousState) {
            applyFilterAndSort()
        } else if state.requiresMatrixRedraw(comparedTo: previousState) {
            reloadVisibleMatrix()
            onDisplaySummaryChanged?(visibleRows.count, totalRowCount, hiddenCellCount)
        }
    }

    func applyAnnotationSidecar(
        _ sidecar: GenotypeAnnotationSidecar?,
        reload: Bool = true,
        reloading targets: [GenotypeAnnotationSidecar.MatrixTarget]? = nil
    ) {
        sidecarCellStyles = [:]
        sidecarRowStyles = [:]
        sidecarColumnStyles = [:]
        sidecarCellComments = [:]
        sidecarRowComments = [:]
        sidecarColumnComments = [:]
        for annotation in sidecar?.matrixStyles ?? [] {
            switch annotation.target {
            case let .row(locus, genotype):
                sidecarRowStyles[RowKey(locus: locus, genotype: genotype)] = annotation.style
            case let .column(sample):
                sidecarColumnStyles[sample] = annotation.style
            case let .cell(locus, genotype, sample):
                sidecarCellStyles[CellKey(locus: locus, genotype: genotype, sample: sample)] = annotation.style
            }
        }
        for comment in sidecar?.matrixComments ?? [] {
            switch comment.target {
            case let .row(locus, genotype):
                sidecarRowComments[RowKey(locus: locus, genotype: genotype), default: []].append(comment.body)
            case let .column(sample):
                sidecarColumnComments[sample, default: []].append(comment.body)
            case let .cell(locus, genotype, sample):
                sidecarCellComments[CellKey(locus: locus, genotype: genotype, sample: sample), default: []].append(comment.body)
            }
        }
        if reload, let targets, !targets.isEmpty {
            reloadMatrixTargets(targets)
        } else if reload {
            tableView.reloadData()
        }
    }

    func applyMetadataStore(_ store: SampleMetadataStore?, reload: Bool = true) {
        metadataStore = store
        if reload {
            applyFilterAndSort()
        }
    }

    func setFilterText(_ text: String) {
        filterField.stringValue = text
        filterText = text
        applyFilterAndSort()
    }

    func applyFilters(allowedSampleIDs: Set<String>?, text: String) {
        self.allowedSampleIDs = allowedSampleIDs
        filterField.stringValue = text
        filterText = text
        rebuildColumns()
        applyDefaultSortDescriptor()
        applyFilterAndSort()
    }

    /// Apply (or clear) the Smart Cohort + Quick Filter sample allow-list.
    /// Pass `nil` to remove cohort filtering and show every row; pass an empty
    /// set to hide every row. The cohort predicate is composed with the
    /// matrix's row filter via `AND` — a row is shown only if it passes
    /// the sample filter, the locus popup, and any programmatic row text.
    func applyCohortFilter(_ allowedSampleIDs: Set<String>?) {
        self.allowedSampleIDs = allowedSampleIDs
        rebuildColumns()
        applyDefaultSortDescriptor()
        applyFilterAndSort()
    }

    func applyHighlight(_ request: GenotypeResultHighlightRequest) {
        let affectedTarget: GenotypeAnnotationSidecar.MatrixTarget
        switch request.scope {
        case .selectedCell:
            guard let sample = request.target.sample else { return }
            let key = CellKey(locus: request.target.locus, genotype: request.target.genotype, sample: sample)
            mutateStyle(&cellStyles, key: key, channel: request.channel, color: request.color)
            affectedTarget = .cell(locus: request.target.locus, genotype: request.target.genotype, sample: sample)
        case .selectedRow:
            mutateStyle(
                &rowStyles,
                key: RowKey(locus: request.target.locus, genotype: request.target.genotype),
                channel: request.channel,
                color: request.color
            )
            affectedTarget = .row(locus: request.target.locus, genotype: request.target.genotype)
        case .clear:
            if let sample = request.target.sample {
                cellStyles.removeValue(
                    forKey: CellKey(locus: request.target.locus, genotype: request.target.genotype, sample: sample)
                )
            }
            rowStyles.removeValue(forKey: RowKey(locus: request.target.locus, genotype: request.target.genotype))
            affectedTarget = .row(locus: request.target.locus, genotype: request.target.genotype)
        }
        reloadMatrixTargets([affectedTarget])
    }

    func highlightStyle(for target: GenotypeResultHighlightTarget) -> GenotypeResultHighlightStyle {
        if let sample = target.sample {
            return cellStyles[CellKey(locus: target.locus, genotype: target.genotype, sample: sample)] ?? .default
        }
        return rowStyles[RowKey(locus: target.locus, genotype: target.genotype)] ?? .default
    }

    func exportSnapshot(bundleURL: URL, analysisName: String, lens: String) -> GenotypeViewportExportSnapshot {
        let exportSampleNames = activeSampleNames()
        let exportSampleSet = Set(exportSampleNames)
        let filters: [String: String] = [
            "searchText": filterText,
            "locus": selectedFilterLocus ?? "All Loci",
            "hideLowSupport": String(displayState.hideLowSupport),
            "minimumSupportPercent": String(format: "%.1f", displayState.minimumSupportPercent),
            "supportDenominator": displayState.supportDenominator.displayName,
            "matrixMinimumReads": "\(displayState.matrixMinimumReads)",
            "matrixMinimumPercent": String(format: "%.1f", displayState.matrixMinimumPercent),
            "matrixPercentDenominator": displayState.matrixPercentDenominator.displayName,
            "matrixRowFilterText": displayState.matrixRowFilterText,
            "matrixSampleFilterText": displayState.matrixSampleFilterText,
            "cellColorMode": displayState.cellColorMode.displayName,
            "hideFilteredHighlights": String(displayState.hideFilteredHighlights),
        ]
        let rows = visibleRows.map { row in
            let reads = Dictionary(uniqueKeysWithValues: row.sampleSupport.compactMap { support -> (String, Int)? in
                guard exportSampleSet.contains(support.sample) else { return nil }
                return (support.sample, support.passedUniqueReads)
            })
            let styles = Dictionary(uniqueKeysWithValues: exportSampleNames.compactMap { sample -> (String, GenotypeResultHighlightStyle)? in
                let rendered = renderedStyle(for: sample, row: row)
                let style = GenotypeResultHighlightStyle(
                    fillColor: rendered.fillColor,
                    borderColor: rendered.borderColor
                )
                return style.isDefault ? nil : (sample, style)
            })
            return GenotypeViewportExportRow(
                genotype: row.genotype,
                locus: row.locus,
                sampleCount: reads.count,
                totalUniqueReads: reads.values.reduce(0, +),
                sampleReads: reads,
                rowStyle: rowStyles[RowKey(locus: row.locus, genotype: row.genotype)] ?? .default,
                cellStyles: styles
            )
        }
        return GenotypeViewportExportSnapshot(
            bundleURL: bundleURL,
            analysisName: analysisName,
            lens: lens,
            filters: filters,
            sampleNames: exportSampleNames,
            rows: rows
        )
    }

    func selectFirstSharedCall() {
        guard !visibleRows.isEmpty else {
            onSelectionCleared?()
            return
        }
        selectedSampleName = nil
        selectedGenotype = visibleRows[0].genotype
        selectedRowLocus = visibleRows[0].locus
        selectedMatrixTargets = [matrixTarget(row: visibleRows[0], sample: nil)]
        tableView.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        tableView.scrollRowToVisible(0)
        onSharedCallSelected?(visibleRows[0], nil, selectedMatrixTargets)
    }

    private func buildView() {
        translatesAutoresizingMaskIntoConstraints = false
        setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        setContentHuggingPriority(.defaultLow, for: .horizontal)

        filterField.translatesAutoresizingMaskIntoConstraints = false
        filterField.placeholderString = "Filter genotypes, loci, or samples"
        filterField.controlSize = .small
        filterField.font = .systemFont(ofSize: 11)
        filterField.sendsSearchStringImmediately = true
        filterField.target = self
        filterField.action = #selector(filterChanged(_:))
        filterField.setAccessibilityIdentifier("genotype-comparison-filter")
        filterField.isHidden = true
        addSubview(filterField)

        locusPopup.translatesAutoresizingMaskIntoConstraints = false
        locusPopup.controlSize = .small
        locusPopup.target = self
        locusPopup.action = #selector(locusChanged(_:))
        locusPopup.setAccessibilityIdentifier("genotype-locus-filter")
        locusPopup.isHidden = true
        addSubview(locusPopup)

        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        addSubview(scrollView)

        tableView.usesAlternatingRowBackgroundColors = true
        tableView.allowsColumnReordering = true
        tableView.allowsColumnResizing = true
        tableView.allowsMultipleSelection = true
        tableView.columnAutoresizingStyle = .noColumnAutoresizing
        tableView.rowHeight = 22
        tableView.style = .plain
        tableView.selectionHighlightStyle = .none
        tableView.delegate = self
        tableView.dataSource = self
        tableView.onCellMouseDown = { [weak self] row, column in
            self?.prepareSelectionFromMouseDown(row: row, column: column)
        }
        tableView.onCellMouseUp = { [weak self] row, column in
            self?.completeSelectionFromMouseUp(row: row, column: column)
        }
        let headerView = GenotypeMatrixHeaderView()
        headerView.onHeaderClick = { [weak self] column, point, modifiers in
            self?.handleHeaderClick(column: column, point: point, modifiers: modifiers) ?? false
        }
        tableView.headerView = headerView
        tableView.setAccessibilityIdentifier("genotype-comparison-table")
        tableView.setAccessibilityLabel("Shared genotype calls by locus and sample")
        scrollView.documentView = tableView

        NSLayoutConstraint.activate([
            filterField.topAnchor.constraint(equalTo: topAnchor, constant: 4),
            filterField.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            filterField.trailingAnchor.constraint(equalTo: locusPopup.leadingAnchor, constant: -8),
            filterField.heightAnchor.constraint(equalToConstant: 24),

            locusPopup.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            locusPopup.centerYAnchor.constraint(equalTo: filterField.centerYAnchor),
            locusPopup.widthAnchor.constraint(equalToConstant: 130),

            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    private func rebuildLocusPopup(_ summaries: [ONTGenotypeLocusSummary]) {
        let previousLocus = selectedFilterLocus
        locusPopup.removeAllItems()
        locusPopup.addItem(withTitle: "All Loci")
        locusPopup.lastItem?.representedObject = nil
        for summary in summaries {
            locusPopup.addItem(withTitle: summary.locus)
            locusPopup.lastItem?.representedObject = summary.locus
        }
        if let previousLocus,
           let item = locusPopup.itemArray.first(where: { ($0.representedObject as? String) == previousLocus }) {
            locusPopup.select(item)
            selectedFilterLocus = previousLocus
        } else {
            locusPopup.selectItem(at: 0)
            selectedFilterLocus = nil
        }
    }

    private func rebuildColumns() {
        for column in tableView.tableColumns {
            tableView.removeTableColumn(column)
        }
        sampleColumnLookup.removeAll()
        visibleSampleNames = activeSampleNames()
        pruneSelectedColumnsForVisibleSamples()

        addColumn(identifier: ColumnID.genotype, title: "Genotype", width: 280, minWidth: 160, ascending: true)
        addColumn(identifier: ColumnID.locus, title: "Locus", width: 92, minWidth: 78, ascending: true)
        addColumn(identifier: ColumnID.samples, title: "Samples", width: 70, minWidth: 58, ascending: false)
        addColumn(identifier: ColumnID.uniqueReads, title: "Unique", width: 78, minWidth: 62, ascending: false)

        for (index, sample) in visibleSampleNames.enumerated() {
            let identifier = ColumnID.sample(index)
            sampleColumnLookup[identifier] = sample
            addColumn(identifier: identifier, title: sample, width: 62, minWidth: 50, ascending: false)
        }
    }

    private func activeSampleNames() -> [String] {
        let sampleFilter = displayState.matrixSampleFilterText.trimmingCharacters(in: .whitespacesAndNewlines)
        return sampleNames.filter { sample in
            if let allowedSampleIDs, !allowedSampleIDs.contains(sample) {
                return false
            }
            guard !sampleFilter.isEmpty else { return true }
            return sample.localizedCaseInsensitiveContains(sampleFilter)
                || metadataMatches(sample: sample, filter: sampleFilter)
        }
    }

    private func applyDefaultSortDescriptor() {
        tableView.sortDescriptors = [
            NSSortDescriptor(key: ColumnID.genotype.rawValue, ascending: true)
        ]
    }

    private func addColumn(
        identifier: NSUserInterfaceItemIdentifier,
        title: String,
        width: CGFloat,
        minWidth: CGFloat,
        ascending: Bool
    ) {
        let column = NSTableColumn(identifier: identifier)
        column.title = title
        column.width = width
        column.minWidth = minWidth
        column.headerToolTip = title
        column.sortDescriptorPrototype = NSSortDescriptor(key: identifier.rawValue, ascending: ascending)
        tableView.addTableColumn(column)
    }

    @objc private func filterChanged(_ sender: NSSearchField) {
        filterText = sender.stringValue
        applyFilterAndSort()
    }

    @objc private func locusChanged(_ sender: NSPopUpButton) {
        selectedFilterLocus = sender.selectedItem?.representedObject as? String
        applyFilterAndSort()
    }

    private func rebuildRowsFromResult() {
        guard let result else {
            allRows = []
            supportByRowAndSample = [:]
            totalRowCount = 0
            hiddenCellCount = 0
            rebuildLocusPopup([])
            return
        }

        let unfilteredSummaries = result.locusSummaries
        totalRowCount = unfilteredSummaries.flatMap(\.sharedCalls).count
        let globalThreshold = displayState.activeMinimumSupportPercent / 100
        let matrixThreshold = displayState.matrixMinimumPercent / 100
        let minimumReads = max(0, displayState.matrixMinimumReads)
        let filteredCalls = result.calls.filter { call in
            if globalThreshold > 0 {
                guard let fraction = result.supportFraction(
                    for: call,
                    denominator: displayState.supportDenominator
                ),
                      fraction >= globalThreshold else {
                    return false
                }
            }
            if matrixThreshold > 0 {
                guard let fraction = result.supportFraction(
                    for: call,
                    denominator: displayState.matrixPercentDenominator
                ),
                      fraction >= matrixThreshold else {
                    return false
                }
            }
            if minimumReads > 0, call.passedUniqueReads < minimumReads {
                return false
            }
            return true
        }
        let filteredSummaries = makeLocusSummaries(from: filteredCalls)
        allRows = filteredSummaries.flatMap(\.sharedCalls)
        rebuildSupportLookup()
        let visibleCellCount = allRows.reduce(0) { $0 + $1.sampleCount }
        hiddenCellCount = max(0, result.calls.count - visibleCellCount)
        supportFractionByCell = makeSupportFractionLookup(for: result)
        rebuildLocusPopup(filteredSummaries)
    }

    private func rebuildSupportLookup() {
        supportByRowAndSample = Dictionary(uniqueKeysWithValues: allRows.map { row in
            var supportBySample: [String: ONTGenotypeSampleSupport] = [:]
            supportBySample.reserveCapacity(row.sampleSupport.count)
            for support in row.sampleSupport where supportBySample[support.sample] == nil {
                supportBySample[support.sample] = support
            }
            return (RowKey(locus: row.locus, genotype: row.genotype), supportBySample)
        })
    }

    private func makeLocusSummaries(from calls: [ONTGenotypeCall]) -> [ONTGenotypeLocusSummary] {
        let callsByLocus = Dictionary(grouping: calls, by: \.locusGroup)
        return callsByLocus.map { locus, callsForLocus in
            let callsByGenotype = Dictionary(grouping: callsForLocus, by: \.genotype)
            let sharedCalls = callsByGenotype.map { genotype, genotypeCalls in
                ONTGenotypeSharedCall(
                    locus: locus,
                    genotype: genotype,
                    sampleSupport: genotypeCalls.map {
                        ONTGenotypeSampleSupport(
                            sample: $0.sample,
                            passedAlignments: $0.passedAlignments,
                            passedUniqueReads: $0.passedUniqueReads,
                            sampleUniqueRetainedReads: $0.sampleUniqueRetainedReads
                        )
                    }
                )
            }
            return ONTGenotypeLocusSummary(locus: locus, sharedCalls: sharedCalls)
        }.sorted { lhs, rhs in
            lhs.locus.localizedStandardCompare(rhs.locus) == .orderedAscending
        }
    }

    private func applyFilterAndSort() {
        let normalizedFilter = filterText.trimmingCharacters(in: .whitespacesAndNewlines)
        let matrixRowFilter = displayState.matrixRowFilterText.trimmingCharacters(in: .whitespacesAndNewlines)
        let activeSamples = Set(activeSampleNames())
        visibleRows = allRows.filter { row in
            if let selectedFilterLocus, row.locus != selectedFilterLocus {
                return false
            }
            // A row stays only when at least one threshold-surviving cell is
            // in the current sample-column set.
            guard row.sampleSupport.contains(where: { activeSamples.contains($0.sample) }) else {
                return false
            }
            // Editable minimum-reads row filter. When active (`> 0`), a row is
            // hidden unless at least one supporting sample clears the threshold,
            // mirroring 12S's `row.totalExactReads >= minimumExactReads` keep
            // rule. `0` (the default) leaves every row visible.
            let minimumReads = displayState.activeMinimumReads
            if minimumReads > 0,
               !row.sampleSupport.contains(where: { $0.passedUniqueReads >= minimumReads }) {
                return false
            }
            if !matrixRowFilter.isEmpty, !rowMatches(row, filter: matrixRowFilter, activeSamples: activeSamples) {
                return false
            }
            if !normalizedFilter.isEmpty {
                return rowMatches(row, filter: normalizedFilter, activeSamples: activeSamples)
            }
            return true
        }

        if let descriptor = tableView.sortDescriptors.first, let key = descriptor.key {
            visibleRows.sort { compare($0, $1, key: key, ascending: descriptor.ascending) }
        }
        tableView.reloadData()
        publishPendingColumnSelectionChange()
        if let selectedGenotype {
            guard let newIndex = visibleRows.firstIndex(where: {
                $0.genotype == selectedGenotype && (selectedRowLocus == nil || $0.locus == selectedRowLocus)
            }) else {
                self.selectedGenotype = nil
                selectedSampleName = nil
                selectedRowLocus = nil
                tableView.deselectAll(nil)
                onSelectionCleared?()
                onDisplaySummaryChanged?(visibleRows.count, totalRowCount, hiddenCellCount)
                return
            }
            if tableView.selectedRow != newIndex {
                tableView.selectRowIndexes(IndexSet(integer: newIndex), byExtendingSelection: false)
                tableView.scrollRowToVisible(newIndex)
            } else {
                onSharedCallSelected?(visibleRows[newIndex], selectedSampleName, selectedMatrixTargets)
            }
        } else if tableView.selectedRowIndexes.contains(where: { $0 >= visibleRows.count }) {
            tableView.deselectAll(nil)
            onSelectionCleared?()
        }
        onDisplaySummaryChanged?(visibleRows.count, totalRowCount, hiddenCellCount)
    }

    private func pruneSelectedColumnsForVisibleSamples() {
        guard !selectedColumnSamples.isEmpty else { return }
        let visibleSet = Set(visibleSampleNames)
        let prunedSamples = selectedColumnSamples.filter { visibleSet.contains($0) }
        guard prunedSamples != selectedColumnSamples else { return }
        selectedColumnSamples = prunedSamples
        selectedMatrixTargets = prunedSamples.map { .column(sample: $0) }
        if let anchor = columnSelectionAnchorSample, !visibleSet.contains(anchor) {
            columnSelectionAnchorSample = prunedSamples.last
        }
        if prunedSamples.isEmpty {
            columnSelectionAnchorSample = nil
            pendingColumnSelectionCleared = true
        } else {
            pendingColumnSelectionTargets = selectedMatrixTargets
        }
    }

    private func publishPendingColumnSelectionChange() {
        if pendingColumnSelectionCleared {
            pendingColumnSelectionCleared = false
            pendingColumnSelectionTargets = nil
            onSelectionCleared?()
        } else if let targets = pendingColumnSelectionTargets {
            pendingColumnSelectionTargets = nil
            onMatrixTargetsSelected?(targets)
        }
    }

    private func rowMatches(
        _ row: ONTGenotypeSharedCall,
        filter: String,
        activeSamples: Set<String>
    ) -> Bool {
        if row.locus.localizedCaseInsensitiveContains(filter) { return true }
        if row.genotype.localizedCaseInsensitiveContains(filter) { return true }
        return row.sampleSupport.contains { support in
            guard activeSamples.contains(support.sample) else { return false }
            return support.sample.localizedCaseInsensitiveContains(filter)
                || metadataMatches(sample: support.sample, filter: filter)
        }
    }

    private func makeSupportFractionLookup(for result: ONTGenotypeResultBundleData) -> [CellKey: Double] {
        switch displayState.supportDenominator {
        case .viewedLocus:
            let contexts = result.calls.map { CallSupportContext(call: $0, locus: $0.locusGroup) }
            var denominators: [SupportBucketKey: Int] = [:]
            denominators.reserveCapacity(contexts.count)
            for context in contexts {
                denominators[
                    SupportBucketKey(sample: context.call.sample, locus: context.locus),
                    default: 0
                ] += context.call.passedUniqueReads
            }
            var fractions: [CellKey: Double] = [:]
            fractions.reserveCapacity(contexts.count)
            for context in contexts {
                guard let denominator = denominators[
                    SupportBucketKey(sample: context.call.sample, locus: context.locus)
                ],
                      denominator > 0 else {
                    continue
                }
                fractions[
                    CellKey(locus: context.locus, genotype: context.call.genotype, sample: context.call.sample)
                ] =
                    Double(context.call.passedUniqueReads) / Double(denominator)
            }
            return fractions
        case .sampleRetained:
            let retainedBySample = Dictionary(uniqueKeysWithValues: result.samples.map {
                ($0.sample, $0.passedUniqueReads)
            })
            var fractions: [CellKey: Double] = [:]
            fractions.reserveCapacity(result.calls.count)
            for call in result.calls {
                guard let denominator = call.sampleUniqueRetainedReads ?? retainedBySample[call.sample],
                      denominator > 0 else {
                    continue
                }
                fractions[CellKey(locus: call.locusGroup, genotype: call.genotype, sample: call.sample)] =
                    Double(call.passedUniqueReads) / Double(denominator)
            }
            return fractions
        }
    }

    private func compare(
        _ lhs: ONTGenotypeSharedCall,
        _ rhs: ONTGenotypeSharedCall,
        key: String,
        ascending: Bool
    ) -> Bool {
        let ordered: ComparisonResult
        switch key {
        case ColumnID.locus.rawValue:
            ordered = lhs.locus.localizedStandardCompare(rhs.locus)
        case ColumnID.samples.rawValue:
            ordered = compare(lhs.sampleCount, rhs.sampleCount)
        case ColumnID.uniqueReads.rawValue:
            ordered = compare(lhs.totalUniqueReads, rhs.totalUniqueReads)
        default:
            if let sample = sampleColumnLookup[NSUserInterfaceItemIdentifier(key)] {
                ordered = compare(
                    support(for: sample, row: lhs)?.passedUniqueReads ?? 0,
                    support(for: sample, row: rhs)?.passedUniqueReads ?? 0
                )
            } else {
                ordered = lhs.genotype.localizedStandardCompare(rhs.genotype)
            }
        }
        return ascending ? ordered == .orderedAscending : ordered == .orderedDescending
    }

    private func compare<T: Comparable>(_ lhs: T, _ rhs: T) -> ComparisonResult {
        if lhs == rhs { return .orderedSame }
        return lhs < rhs ? .orderedAscending : .orderedDescending
    }

    private func orderedSamples(from calls: [ONTGenotypeCall]) -> [String] {
        var names: [String] = []
        var seen = Set<String>()
        for call in calls where seen.insert(call.sample).inserted {
            names.append(call.sample)
        }
        return names
    }

    func numberOfRows(in tableView: NSTableView) -> Int {
        visibleRows.count
    }

    func tableView(_ tableView: NSTableView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
        applyFilterAndSort()
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let tableColumn, row < visibleRows.count else { return nil }
        let sharedCall = visibleRows[row]
        let identifier = tableColumn.identifier
        let cell = tableView.makeView(withIdentifier: identifier, owner: self) as? NSTableCellView
            ?? makeCellView(identifier: identifier)
        let value = cellValue(for: identifier, row: sharedCall)
        cell.textField?.stringValue = value.text
        cell.textField?.alignment = value.alignment
        cell.textField?.toolTip = value.toolTip
        applyCellStyle(cell, identifier: identifier, row: sharedCall)
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !suppressSelectionClearedCallback else { return }
        let selectedRows = tableView.selectedRowIndexes.filter { $0 >= 0 && $0 < visibleRows.count }
        guard !selectedRows.isEmpty else {
            onSelectionCleared?()
            return
        }
        let preferredSample = pendingClickedSampleName ?? selectedSampleName
        pendingClickedSampleName = nil
        if selectedRows.count > 1 {
            selectVisibleRows(selectedRows, sample: preferredSample)
            return
        }
        let selectedRow = selectedRows[selectedRows.startIndex]
        selectVisibleRow(selectedRow, sample: preferredSample)
    }

    private func makeCellView(identifier: NSUserInterfaceItemIdentifier) -> NSTableCellView {
        let cell = NSTableCellView()
        cell.identifier = identifier
        let field = NSTextField(labelWithString: "")
        field.translatesAutoresizingMaskIntoConstraints = false
        field.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        field.lineBreakMode = .byTruncatingMiddle
        field.usesSingleLineMode = true
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        cell.addSubview(field)
        cell.textField = field
        NSLayoutConstraint.activate([
            field.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4),
            field.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4),
            field.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        return cell
    }

    private func cellValue(
        for identifier: NSUserInterfaceItemIdentifier,
        row: ONTGenotypeSharedCall
    ) -> (text: String, alignment: NSTextAlignment, toolTip: String?) {
        switch identifier {
        case ColumnID.genotype:
            return (row.genotype, .left, rowTooltip(row: row, fallback: row.genotype))
        case ColumnID.locus:
            return (row.locus, .left, rowTooltip(row: row, fallback: row.locus))
        case ColumnID.samples:
            return ("\(row.sampleCount)", .right, nil)
        case ColumnID.uniqueReads:
            return (integer(row.totalUniqueReads), .right, "Total unique reads across supporting samples")
        default:
            guard let sample = sampleColumnLookup[identifier] else {
                return ("", .right, nil)
            }
            guard let support = support(for: sample, row: row) else {
                return ("", .right, matrixTooltip(sample: sample, row: row, base: nil))
            }
            return (
                integer(support.passedUniqueReads),
                .right,
                matrixTooltip(
                    sample: sample,
                    row: row,
                    base: sampleTooltip(sample: sample, uniqueReads: support.passedUniqueReads)
                )
            )
        }
    }

    private func support(for sample: String, row: ONTGenotypeSharedCall) -> ONTGenotypeSampleSupport? {
        supportByRowAndSample[RowKey(locus: row.locus, genotype: row.genotype)]?[sample]
    }

    private func metadataMatches(sample: String, filter: String) -> Bool {
        guard let record = metadataStore?.records[sample] else { return false }
        if let query = metadataFieldQuery(from: filter) {
            return record.contains { key, value in
                key.localizedCaseInsensitiveContains(query.field)
                    && value.localizedCaseInsensitiveContains(query.value)
            }
        }
        return record.values.contains { $0.localizedCaseInsensitiveContains(filter) }
            || record.keys.contains { $0.localizedCaseInsensitiveContains(filter) }
    }

    private func metadataFieldQuery(from filter: String) -> (field: String, value: String)? {
        for separator in ["=", ":"] {
            guard let range = filter.range(of: separator) else { continue }
            let field = String(filter[..<range.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
            let value = String(filter[range.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !field.isEmpty, !value.isEmpty else { continue }
            if field.range(of: #"^M[0-9]+$"#, options: .regularExpression) != nil { continue }
            return (field, value)
        }
        return nil
    }

    private func sampleTooltip(sample: String, uniqueReads: Int) -> String {
        var lines = ["\(sample): \(uniqueReads.formatted(.number)) unique reads"]
        if let record = metadataStore?.records[sample] {
            for key in metadataStore?.columnNames.prefix(6) ?? [] {
                if let value = record[key], !value.isEmpty {
                    lines.append("\(key): \(value)")
                }
            }
        }
        return lines.joined(separator: "\n")
    }

    private func rowTooltip(row: ONTGenotypeSharedCall, fallback: String) -> String {
        let comments = sidecarRowComments[RowKey(locus: row.locus, genotype: row.genotype)] ?? []
        guard !comments.isEmpty else { return fallback }
        return ([fallback, "Row comments:"] + comments).joined(separator: "\n")
    }

    private func matrixTooltip(sample: String, row: ONTGenotypeSharedCall, base: String?) -> String? {
        var lines: [String] = []
        if let base, !base.isEmpty {
            lines.append(base)
        }
        let rowKey = RowKey(locus: row.locus, genotype: row.genotype)
        let cellKey = CellKey(locus: row.locus, genotype: row.genotype, sample: sample)
        appendComments(sidecarRowComments[rowKey] ?? [], title: "Row comments", to: &lines)
        appendComments(sidecarColumnComments[sample] ?? [], title: "Column comments", to: &lines)
        appendComments(sidecarCellComments[cellKey] ?? [], title: "Cell comments", to: &lines)
        return lines.isEmpty ? nil : lines.joined(separator: "\n")
    }

    private func appendComments(_ comments: [String], title: String, to lines: inout [String]) {
        guard !comments.isEmpty else { return }
        lines.append(title + ":")
        lines += comments
    }

    private func integer(_ value: Int) -> String {
        value.formatted(.number)
    }

    private func prepareSelectionFromMouseDown(row: Int, column: Int) {
        guard row >= 0, row < visibleRows.count else {
            pendingClickedSampleName = nil
            return
        }
        pendingClickedSampleName = sampleName(forColumnAt: column)
    }

    private func completeSelectionFromMouseUp(row: Int, column: Int) {
        guard tableView.selectedRowIndexes.count <= 1 else { return }
        guard row >= 0, row < visibleRows.count, tableView.selectedRow == row else { return }
        let sample = sampleName(forColumnAt: column)
        selectVisibleRow(row, sample: sample)
    }

    private func handleHeaderClick(column: Int, point: NSPoint, modifiers: NSEvent.ModifierFlags) -> Bool {
        guard !isNearHeaderColumnEdge(column: column, point: point),
              let sample = sampleName(forColumnAt: column) else {
            return false
        }
        selectSampleColumn(clicked: sample, modifiers: modifiers)
        return true
    }

    private func isNearHeaderColumnEdge(column: Int, point: NSPoint) -> Bool {
        guard column >= 0, column < tableView.tableColumns.count else { return false }
        let rect = tableView.headerView?.headerRect(ofColumn: column) ?? .zero
        let resizeSlop: CGFloat = 5
        return point.x <= rect.minX + resizeSlop || point.x >= rect.maxX - resizeSlop
    }

    private func selectSampleColumn(clicked sample: String, modifiers: NSEvent.ModifierFlags) {
        let command = modifiers.contains(.command)
        let shift = modifiers.contains(.shift)
        var samples: [String]
        if shift,
           let anchor = columnSelectionAnchorSample,
           let anchorIndex = visibleSampleNamesInColumnOrder().firstIndex(of: anchor),
           let sampleIndex = visibleSampleNamesInColumnOrder().firstIndex(of: sample) {
            let range = min(anchorIndex, sampleIndex)...max(anchorIndex, sampleIndex)
            samples = visibleSampleNamesInColumnOrder().enumerated().compactMap { range.contains($0.offset) ? $0.element : nil }
        } else if command {
            var existing = selectedColumnSamples
            if let index = existing.firstIndex(of: sample) {
                existing.remove(at: index)
            } else {
                existing.append(sample)
            }
            samples = existing
        } else {
            samples = [sample]
        }
        if samples.isEmpty {
            clearSelectionAfterColumnToggle()
            return
        }
        publishColumnSelection(samples)
        columnSelectionAnchorSample = sample
    }

    private func clearSelectionAfterColumnToggle() {
        let previousTargets = selectedMatrixTargets
        selectedColumnSamples = []
        selectedMatrixTargets = []
        selectedGenotype = nil
        selectedRowLocus = nil
        selectedSampleName = nil
        columnSelectionAnchorSample = nil
        pendingColumnSelectionTargets = nil
        pendingColumnSelectionCleared = false
        suppressSelectionClearedCallback = true
        tableView.deselectAll(nil)
        suppressSelectionClearedCallback = false
        reloadSelectionTransition(from: previousTargets, to: [])
        onSelectionCleared?()
    }

    private func publishColumnSelection(_ samples: [String]) {
        let visible = samples.filter { visibleSampleNames.contains($0) }
        guard !visible.isEmpty else {
            clearSelectionAfterColumnToggle()
            return
        }
        let previousTargets = selectedMatrixTargets
        selectedColumnSamples = uniqueSamples(visible)
        selectedGenotype = nil
        selectedRowLocus = nil
        selectedSampleName = nil
        selectedMatrixTargets = selectedColumnSamples.map { .column(sample: $0) }
        pendingColumnSelectionTargets = nil
        pendingColumnSelectionCleared = false
        suppressSelectionClearedCallback = true
        tableView.deselectAll(nil)
        suppressSelectionClearedCallback = false
        reloadSelectionTransition(from: previousTargets, to: selectedMatrixTargets)
        onMatrixTargetsSelected?(selectedMatrixTargets)
    }

    private func visibleSampleNamesInColumnOrder() -> [String] {
        tableView.tableColumns.compactMap { sampleColumnLookup[$0.identifier] }
    }

    private func uniqueSamples(_ samples: [String]) -> [String] {
        var seen = Set<String>()
        return samples.filter { seen.insert($0).inserted }
    }

    private func selectVisibleRow(_ rowIndex: Int, sample: String?) {
        guard rowIndex >= 0, rowIndex < visibleRows.count else {
            onSelectionCleared?()
            return
        }
        selectedColumnSamples = []
        columnSelectionAnchorSample = nil
        let row = visibleRows[rowIndex]
        let previousTargets = selectedMatrixTargets
        selectedSampleName = sample
        selectedGenotype = row.genotype
        selectedRowLocus = row.locus
        selectedMatrixTargets = [matrixTarget(row: row, sample: sample)]
        reloadSelectionTransition(from: previousTargets, to: selectedMatrixTargets)
        onSharedCallSelected?(row, sample, selectedMatrixTargets)
    }

    private func selectVisibleRows(_ rowIndexes: [Int], sample: String?) {
        let validIndexes = rowIndexes.filter { $0 >= 0 && $0 < visibleRows.count }
        guard let firstIndex = validIndexes.first else {
            onSelectionCleared?()
            return
        }
        selectedColumnSamples = []
        columnSelectionAnchorSample = nil
        let firstRow = visibleRows[firstIndex]
        let previousTargets = selectedMatrixTargets
        selectedSampleName = sample
        selectedGenotype = firstRow.genotype
        selectedRowLocus = firstRow.locus
        selectedMatrixTargets = validIndexes.map { matrixTarget(row: visibleRows[$0], sample: sample) }
        reloadSelectionTransition(from: previousTargets, to: selectedMatrixTargets)
        onSharedCallSelected?(firstRow, sample, selectedMatrixTargets)
    }

    private func reloadSelectionTransition(
        from previousTargets: [GenotypeAnnotationSidecar.MatrixTarget],
        to nextTargets: [GenotypeAnnotationSidecar.MatrixTarget]
    ) {
        reloadMatrixTargets(previousTargets + nextTargets)
    }

    private func reloadVisibleMatrix() {
        guard tableView.numberOfRows > 0, tableView.numberOfColumns > 0 else { return }
        tableView.reloadData(
            forRowIndexes: IndexSet(integersIn: 0..<tableView.numberOfRows),
            columnIndexes: IndexSet(integersIn: 0..<tableView.numberOfColumns)
        )
    }

    private func reloadMatrixTargets(_ targets: [GenotypeAnnotationSidecar.MatrixTarget]) {
        guard !targets.isEmpty, tableView.numberOfColumns > 0 else { return }
        var rowIndexes = IndexSet()
        var columnIndexes = IndexSet()
        let allColumns = IndexSet(integersIn: 0..<tableView.numberOfColumns)

        for target in targets {
            switch target {
            case let .row(locus, genotype):
                if let rowIndex = visibleRowIndex(locus: locus, genotype: genotype) {
                    rowIndexes.insert(rowIndex)
                    columnIndexes.formUnion(allColumns)
                }
            case let .column(sample):
                if let columnIndex = visibleColumnIndex(sample: sample), tableView.numberOfRows > 0 {
                    rowIndexes.formUnion(IndexSet(integersIn: 0..<tableView.numberOfRows))
                    columnIndexes.insert(columnIndex)
                }
            case let .cell(locus, genotype, sample):
                if let rowIndex = visibleRowIndex(locus: locus, genotype: genotype),
                   let columnIndex = visibleColumnIndex(sample: sample) {
                    rowIndexes.insert(rowIndex)
                    columnIndexes.insert(columnIndex)
                }
            }
        }

        guard !rowIndexes.isEmpty, !columnIndexes.isEmpty else { return }
        tableView.reloadData(forRowIndexes: rowIndexes, columnIndexes: columnIndexes)
    }

    private func visibleRowIndex(locus: String, genotype: String) -> Int? {
        visibleRows.firstIndex { $0.locus == locus && $0.genotype == genotype }
    }

    private func visibleColumnIndex(sample: String) -> Int? {
        tableView.tableColumns.firstIndex { sampleColumnLookup[$0.identifier] == sample }
    }

    private func matrixTarget(
        row: ONTGenotypeSharedCall,
        sample: String?
    ) -> GenotypeAnnotationSidecar.MatrixTarget {
        if let sample {
            return .cell(locus: row.locus, genotype: row.genotype, sample: sample)
        }
        return .row(locus: row.locus, genotype: row.genotype)
    }

    func selectSupportedCellsInSelectedRow(minimumReads: Int) -> [GenotypeAnnotationSidecar.MatrixTarget] {
        guard let selectedGenotype,
              let selectedRowLocus,
              let row = visibleRows.first(where: {
                  $0.genotype == selectedGenotype && $0.locus == selectedRowLocus
              }) else {
            selectedMatrixTargets = []
            return []
        }
        let threshold = max(0, minimumReads)
        let activeSamples = Set(visibleSampleNames)
        let targets = row.sampleSupport
            .filter { activeSamples.contains($0.sample) && $0.passedUniqueReads >= threshold }
            .map {
                GenotypeAnnotationSidecar.MatrixTarget.cell(
                    locus: row.locus,
                    genotype: row.genotype,
                    sample: $0.sample
                )
            }
        let previousTargets = selectedMatrixTargets
        selectedSampleName = nil
        selectedColumnSamples = []
        columnSelectionAnchorSample = nil
        selectedMatrixTargets = targets
        reloadSelectionTransition(from: previousTargets, to: targets)
        return targets
    }

    func selectVisibleSupportedCells(minimumReads: Int) -> [GenotypeAnnotationSidecar.MatrixTarget] {
        let threshold = max(0, minimumReads)
        let activeSamples = Set(visibleSampleNames)
        let targets = visibleRows.flatMap { row in
            row.sampleSupport.compactMap { support -> GenotypeAnnotationSidecar.MatrixTarget? in
                guard activeSamples.contains(support.sample),
                      support.passedUniqueReads >= threshold else {
                    return nil
                }
                return .cell(locus: row.locus, genotype: row.genotype, sample: support.sample)
            }
        }
        let previousTargets = selectedMatrixTargets
        selectedSampleName = nil
        selectedGenotype = nil
        selectedRowLocus = nil
        selectedColumnSamples = []
        columnSelectionAnchorSample = nil
        selectedMatrixTargets = targets
        suppressSelectionClearedCallback = true
        tableView.deselectAll(nil)
        suppressSelectionClearedCallback = false
        reloadSelectionTransition(from: previousTargets, to: targets)
        if targets.isEmpty {
            onSelectionCleared?()
        } else {
            onMatrixTargetsSelected?(targets)
        }
        return targets
    }

    private func sampleName(forColumnAt columnIndex: Int) -> String? {
        guard columnIndex >= 0, columnIndex < tableView.tableColumns.count else { return nil }
        return sampleColumnLookup[tableView.tableColumns[columnIndex].identifier]
    }

    private func mutateStyle<Key: Hashable>(
        _ styles: inout [Key: GenotypeResultHighlightStyle],
        key: Key,
        channel: GenotypeResultHighlightChannel,
        color: AnnotationColor?
    ) {
        var style = styles[key] ?? .default
        style.setColor(color, for: channel)
        if style.isDefault {
            styles.removeValue(forKey: key)
        } else {
            styles[key] = style
        }
    }

    private func applyCellStyle(
        _ cell: NSTableCellView,
        identifier: NSUserInterfaceItemIdentifier,
        row: ONTGenotypeSharedCall
    ) {
        let renderedStyle = renderedStyle(for: identifier, row: row)
        let backgroundColor = backgroundColor(for: identifier, row: row, renderedStyle: renderedStyle)
        let borderColor = borderColor(for: identifier, row: row, renderedStyle: renderedStyle)
        let selected = isSelectedCell(identifier: identifier, row: row)

        cell.textField?.textColor = renderedStyle.textColor.map(Self.color(from:)) ?? .labelColor
        cell.textField?.font = font(for: renderedStyle)
        guard backgroundColor != nil || borderColor != nil || selected || renderedStyle.textColor != nil || renderedStyle.isBold || renderedStyle.isItalic else {
            if cell.wantsLayer {
                cell.layer?.backgroundColor = nil
                cell.layer?.borderWidth = 0
                cell.layer?.borderColor = nil
                cell.wantsLayer = false
            }
            return
        }

        cell.wantsLayer = true
        cell.layer?.cornerRadius = 3
        cell.layer?.masksToBounds = true
        cell.layer?.borderWidth = 0
        cell.layer?.borderColor = nil
        cell.layer?.backgroundColor = backgroundColor?.cgColor
        if let borderColor {
            cell.layer?.borderColor = borderColor.cgColor
            cell.layer?.borderWidth = 1.5
        }
        if selected {
            cell.layer?.borderColor = NSColor.keyboardFocusIndicatorColor.cgColor
            cell.layer?.borderWidth = 2
        }
    }

    private func font(for style: GenotypeMatrixRenderedStyle) -> NSFont {
        let base = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: style.isBold ? .semibold : .regular)
        guard style.isItalic else {
            return base
        }
        return NSFontManager.shared.convert(base, toHaveTrait: .italicFontMask)
    }

    private func backgroundColor(
        for identifier: NSUserInterfaceItemIdentifier,
        row: ONTGenotypeSharedCall,
        renderedStyle: GenotypeMatrixRenderedStyle
    ) -> NSColor? {
        if hidesFilteredCellAppearance(identifier: identifier, row: row) {
            return nil
        }

        if displayState.cellColorMode != .none,
           let color = renderedStyle.fillColor {
            let alpha = sampleColumnLookup[identifier] == nil ? 0.13 : 0.24
            return Self.color(from: color).withAlphaComponent(alpha)
        }

        guard displayState.cellColorMode == .support,
              let sample = sampleColumnLookup[identifier],
              let fraction = supportFractionByCell[
                CellKey(locus: row.locus, genotype: row.genotype, sample: sample)
              ] else {
            return nil
        }

        let alpha = min(0.20, max(0.06, 0.05 + fraction * 0.22))
        return NSColor.systemBlue.withAlphaComponent(alpha)
    }

    private func borderColor(
        for identifier: NSUserInterfaceItemIdentifier,
        row: ONTGenotypeSharedCall,
        renderedStyle: GenotypeMatrixRenderedStyle
    ) -> NSColor? {
        if hidesFilteredCellAppearance(identifier: identifier, row: row) {
            return nil
        }

        guard displayState.cellColorMode != .none else { return nil }
        if let color = renderedStyle.borderColor {
            let alpha = sampleColumnLookup[identifier] == nil ? 0.80 : 0.95
            return Self.color(from: color).withAlphaComponent(alpha)
        }
        return nil
    }

    private func renderedStyle(
        for identifier: NSUserInterfaceItemIdentifier,
        row: ONTGenotypeSharedCall
    ) -> GenotypeMatrixRenderedStyle {
        renderedStyle(for: sampleColumnLookup[identifier], row: row)
    }

    private func renderedStyle(
        for sample: String?,
        row: ONTGenotypeSharedCall
    ) -> GenotypeMatrixRenderedStyle {
        var rendered = GenotypeMatrixRenderedStyle.default
        let rowKey = RowKey(locus: row.locus, genotype: row.genotype)
        merge(sidecarRowStyles[rowKey], into: &rendered)
        if let sample {
            merge(sidecarColumnStyles[sample], into: &rendered)
            merge(
                sidecarCellStyles[CellKey(locus: row.locus, genotype: row.genotype, sample: sample)],
                into: &rendered
            )
        }
        if let rowHighlight = rowStyles[rowKey] {
            rendered.fillColor = rowHighlight.fillColor ?? rendered.fillColor
            rendered.borderColor = rowHighlight.borderColor ?? rendered.borderColor
        }
        if let sample,
           let cellHighlight = cellStyles[CellKey(locus: row.locus, genotype: row.genotype, sample: sample)] {
            rendered.fillColor = cellHighlight.fillColor ?? rendered.fillColor
            rendered.borderColor = cellHighlight.borderColor ?? rendered.borderColor
        }
        return rendered
    }

    private func merge(
        _ style: GenotypeAnnotationSidecar.MatrixStyle?,
        into rendered: inout GenotypeMatrixRenderedStyle
    ) {
        guard let style else { return }
        if let fillColor = style.fillColor.flatMap(AnnotationColor.init(hex:)) {
            rendered.fillColor = fillColor
        }
        if let textColor = style.textColor.flatMap(AnnotationColor.init(hex:)) {
            rendered.textColor = textColor
        }
        if let borderColor = style.borderColor.flatMap(AnnotationColor.init(hex:)) {
            rendered.borderColor = borderColor
        }
        if let boldOverride = style.boldOverride {
            rendered.isBold = boldOverride
        } else if style.isBold {
            rendered.isBold = true
        }
        if let italicOverride = style.italicOverride {
            rendered.isItalic = italicOverride
        } else if style.isItalic {
            rendered.isItalic = true
        }
    }

    private func hidesFilteredCellAppearance(
        identifier: NSUserInterfaceItemIdentifier,
        row: ONTGenotypeSharedCall
    ) -> Bool {
        guard displayState.hideLowSupport,
              displayState.hideFilteredHighlights,
              displayState.activeMinimumSupportPercent > 0,
              let sample = sampleColumnLookup[identifier],
              row.support(for: sample) == nil else {
            return false
        }
        return supportFractionByCell[CellKey(locus: row.locus, genotype: row.genotype, sample: sample)] != nil
    }

    private func isSelectedCell(
        identifier: NSUserInterfaceItemIdentifier,
        row: ONTGenotypeSharedCall
    ) -> Bool {
        guard !selectedMatrixTargets.isEmpty else { return false }
        let sample = sampleColumnLookup[identifier]
        return selectedMatrixTargets.contains { target in
            switch target {
            case let .row(locus, genotype):
                return row.locus == locus && row.genotype == genotype
            case let .column(selectedSample):
                return sample == selectedSample
            case let .cell(locus, genotype, selectedSample):
                return row.locus == locus && row.genotype == genotype && sample == selectedSample
            }
        }
    }

    private static func color(from annotationColor: AnnotationColor) -> NSColor {
        NSColor(
            calibratedRed: annotationColor.red,
            green: annotationColor.green,
            blue: annotationColor.blue,
            alpha: annotationColor.alpha
        )
    }
}

private final class GenotypeMatrixTableView: NSTableView {
    var onCellMouseDown: ((Int, Int) -> Void)?
    var onCellMouseUp: ((Int, Int) -> Void)?

#if DEBUG
    private(set) var testingFullReloadCount = 0
    private(set) var testingPartialReloadCount = 0

    func testingResetReloadCounters() {
        testingFullReloadCount = 0
        testingPartialReloadCount = 0
    }
#endif

    override func reloadData() {
#if DEBUG
        testingFullReloadCount += 1
#endif
        super.reloadData()
    }

    override func reloadData(forRowIndexes rowIndexes: IndexSet, columnIndexes: IndexSet) {
#if DEBUG
        testingPartialReloadCount += 1
#endif
        super.reloadData(forRowIndexes: rowIndexes, columnIndexes: columnIndexes)
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let row = self.row(at: point)
        let column = self.column(at: point)
        onCellMouseDown?(row, column)
        super.mouseDown(with: event)
        onCellMouseUp?(row, column)
    }
}

private final class GenotypeMatrixHeaderView: NSTableHeaderView {
    var onHeaderClick: ((Int, NSPoint, NSEvent.ModifierFlags) -> Bool)?

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let column = self.column(at: point)
        if column >= 0, onHeaderClick?(column, point, event.modifierFlags) == true {
            return
        }
        super.mouseDown(with: event)
    }
}

#if DEBUG
extension GenotypeComparisonMatrixView {
    var testingVisibleRows: [ONTGenotypeSharedCall] { visibleRows }
    var testingVisibleGenotypes: [String] { visibleRows.map(\.genotype) }
    var testingHighlightedCellCount: Int {
        cellStyles.values.filter { $0.fillColor != nil }.count
    }
    var testingBorderedCellCount: Int {
        cellStyles.values.filter { $0.borderColor != nil }.count
    }
    var testingLocusFilterTitles: [String] {
        locusPopup.itemArray.map(\.title)
    }

    var testingSelectedMatrixTargets: [GenotypeAnnotationSidecar.MatrixTarget] {
        selectedMatrixTargets
    }

    func testingSelectFirstSampleCell(sample: String) {
        guard let rowIndex = visibleRows.firstIndex(where: { $0.support(for: sample) != nil }) else {
            onSelectionCleared?()
            return
        }
        let row = visibleRows[rowIndex]
        selectedSampleName = sample
        selectedGenotype = row.genotype
        selectedRowLocus = row.locus
        tableView.selectRowIndexes(IndexSet(integer: rowIndex), byExtendingSelection: false)
        tableView.scrollRowToVisible(rowIndex)
        selectVisibleRow(rowIndex, sample: sample)
    }

    func testingHighlightStyle(for target: GenotypeResultHighlightTarget) -> GenotypeResultHighlightStyle {
        highlightStyle(for: target)
    }

    func testingBackgroundColor(genotype: String, sample: String) -> NSColor? {
        guard let row = visibleRows.first(where: { $0.genotype == genotype }),
              let identifier = sampleColumnLookup.first(where: { $0.value == sample })?.key else {
            return nil
        }
        return backgroundColor(for: identifier, row: row, renderedStyle: renderedStyle(for: identifier, row: row))
    }

    func testingSelectCell(genotype: String, sample: String) {
        guard let rowIndex = visibleRows.firstIndex(where: { $0.genotype == genotype }),
              visibleSampleNames.contains(sample) else {
            onSelectionCleared?()
            return
        }
        tableView.selectRowIndexes(IndexSet(integer: rowIndex), byExtendingSelection: false)
        tableView.scrollRowToVisible(rowIndex)
        selectVisibleRow(rowIndex, sample: sample)
    }

    func testingSelectRows(genotypes: [String], sample: String?) {
        var indexes = IndexSet()
        for genotype in genotypes {
            if let rowIndex = visibleRows.firstIndex(where: { $0.genotype == genotype }) {
                indexes.insert(rowIndex)
            }
        }
        selectVisibleRows(Array(indexes), sample: sample)
    }

    func testingSelectColumn(sample: String) {
        publishColumnSelection([sample])
    }

    func testingSelectColumns(samples: [String]) {
        publishColumnSelection(samples)
    }

    func testingCellValue(genotype: String, sample: String) -> String? {
        guard let row = visibleRows.first(where: { $0.genotype == genotype }),
              let identifier = sampleColumnLookup.first(where: { $0.value == sample })?.key else {
            return nil
        }
        return cellValue(for: identifier, row: row).text
    }

    func testingRenderedStyle(genotype: String, sample: String) -> GenotypeMatrixRenderedStyle? {
        guard let row = visibleRows.first(where: { $0.genotype == genotype }),
              visibleSampleNames.contains(sample) else {
            return nil
        }
        return renderedStyle(for: sample, row: row)
    }

    func testingIsSelectedCell(genotype: String, sample: String) -> Bool {
        guard let row = visibleRows.first(where: { $0.genotype == genotype }),
              let identifier = sampleColumnLookup.first(where: { $0.value == sample })?.key else {
            return false
        }
        return isSelectedCell(identifier: identifier, row: row)
    }

    func testingSelectSupportedCellsInSelectedRow(minimumReads: Int) -> [GenotypeAnnotationSidecar.MatrixTarget] {
        selectSupportedCellsInSelectedRow(minimumReads: minimumReads)
    }

    func testingSelectVisibleSupportedCells(minimumReads: Int) -> [GenotypeAnnotationSidecar.MatrixTarget] {
        selectVisibleSupportedCells(minimumReads: minimumReads)
    }

    func testingResetReloadCounters() {
        tableView.testingResetReloadCounters()
    }

    var testingFullReloadCount: Int {
        tableView.testingFullReloadCount
    }

    var testingPartialReloadCount: Int {
        tableView.testingPartialReloadCount
    }

    func testingRenderVisibleCells(rowLimit: Int) {
        let rowCount = min(rowLimit, visibleRows.count)
        for row in 0..<rowCount {
            for column in tableView.tableColumns {
                _ = self.tableView(tableView, viewFor: column, row: row)
            }
        }
    }

    func testingSetFilter(_ text: String) {
        setFilterText(text)
    }
}
#endif
