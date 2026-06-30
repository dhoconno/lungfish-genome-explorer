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

    var onSharedCallSelected: ((ONTGenotypeSharedCall, String?) -> Void)?
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
    private var selectedGenotype: String?
    private var selectedSampleName: String?
    private var selectedRowLocus: String?
    private var selectedMatrixTargets: [GenotypeAnnotationSidecar.MatrixTarget] = []
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
        applyAnnotationSidecar(sidecar, reload: false)
        rebuildRowsFromResult()
        rebuildColumns()
        applyDefaultSortDescriptor()
        applyFilterAndSort()
    }

    func applyDisplayState(_ state: GenotypeResultDisplayState) {
        displayState = state
        rebuildRowsFromResult()
        rebuildColumns()
        applyFilterAndSort()
    }

    func applyAnnotationSidecar(_ sidecar: GenotypeAnnotationSidecar?, reload: Bool = true) {
        sidecarCellStyles = [:]
        sidecarRowStyles = [:]
        sidecarColumnStyles = [:]
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
        if reload {
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
        applyFilterAndSort()
    }

    func applyHighlight(_ request: GenotypeResultHighlightRequest) {
        switch request.scope {
        case .selectedCell:
            guard let sample = request.target.sample else { return }
            let key = CellKey(locus: request.target.locus, genotype: request.target.genotype, sample: sample)
            mutateStyle(&cellStyles, key: key, channel: request.channel, color: request.color)
        case .selectedRow:
            mutateStyle(
                &rowStyles,
                key: RowKey(locus: request.target.locus, genotype: request.target.genotype),
                channel: request.channel,
                color: request.color
            )
        case .clear:
            if let sample = request.target.sample {
                cellStyles.removeValue(
                    forKey: CellKey(locus: request.target.locus, genotype: request.target.genotype, sample: sample)
                )
            }
            rowStyles.removeValue(forKey: RowKey(locus: request.target.locus, genotype: request.target.genotype))
        }
        tableView.reloadData()
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
        onSharedCallSelected?(visibleRows[0], nil)
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
        tableView.allowsMultipleSelection = false
        tableView.columnAutoresizingStyle = .noColumnAutoresizing
        tableView.rowHeight = 22
        tableView.style = .plain
        tableView.delegate = self
        tableView.dataSource = self
        tableView.onCellMouseDown = { [weak self] row, column in
            self?.prepareSelectionFromMouseDown(row: row, column: column)
        }
        tableView.onCellMouseUp = { [weak self] row, column in
            self?.completeSelectionFromMouseUp(row: row, column: column)
        }
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
            totalRowCount = 0
            hiddenCellCount = 0
            rebuildLocusPopup([])
            return
        }

        let unfilteredSummaries = result.locusSummaries
        totalRowCount = unfilteredSummaries.flatMap(\.sharedCalls).count
        let activePercent = max(displayState.activeMinimumSupportPercent, displayState.matrixMinimumPercent)
        let denominator = displayState.matrixMinimumPercent > 0
            ? displayState.matrixPercentDenominator
            : displayState.supportDenominator
        let filteredSummaries = result.locusSummaries(
            minimumSupportPercent: activePercent,
            denominator: denominator
        )
        let minimumReads = max(0, displayState.matrixMinimumReads)
        allRows = filteredSummaries.flatMap(\.sharedCalls).compactMap { row in
            guard minimumReads > 0 else { return row }
            let support = row.sampleSupport.filter { $0.passedUniqueReads >= minimumReads }
            guard !support.isEmpty else { return nil }
            return ONTGenotypeSharedCall(locus: row.locus, genotype: row.genotype, sampleSupport: support)
        }
        let visibleCellCount = allRows.reduce(0) { $0 + $1.sampleCount }
        hiddenCellCount = max(0, result.calls.count - visibleCellCount)
        supportFractionByCell = makeSupportFractionLookup(for: result)
        rebuildLocusPopup(filteredSummaries)
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
                onSharedCallSelected?(visibleRows[newIndex], selectedSampleName)
            }
        } else if tableView.selectedRowIndexes.contains(where: { $0 >= visibleRows.count }) {
            tableView.deselectAll(nil)
            onSelectionCleared?()
        }
        onDisplaySummaryChanged?(visibleRows.count, totalRowCount, hiddenCellCount)
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
                ordered = compare(lhs.support(for: sample)?.passedUniqueReads ?? 0, rhs.support(for: sample)?.passedUniqueReads ?? 0)
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
        let selectedRow = tableView.selectedRow
        guard selectedRow >= 0, selectedRow < visibleRows.count else {
            onSelectionCleared?()
            return
        }
        let preferredSample = pendingClickedSampleName ?? selectedSampleName
        pendingClickedSampleName = nil
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
            return (row.genotype, .left, row.genotype)
        case ColumnID.locus:
            return (row.locus, .left, row.locus)
        case ColumnID.samples:
            return ("\(row.sampleCount)", .right, nil)
        case ColumnID.uniqueReads:
            return (integer(row.totalUniqueReads), .right, "Total unique reads across supporting samples")
        default:
            guard let sample = sampleColumnLookup[identifier],
                  let support = row.support(for: sample) else {
                return ("", .right, nil)
            }
            return (
                integer(support.passedUniqueReads),
                .right,
                sampleTooltip(sample: sample, uniqueReads: support.passedUniqueReads)
            )
        }
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
        guard row >= 0, row < visibleRows.count, tableView.selectedRow == row else { return }
        let sample = sampleName(forColumnAt: column)
        selectVisibleRow(row, sample: sample)
    }

    private func selectVisibleRow(_ rowIndex: Int, sample: String?) {
        guard rowIndex >= 0, rowIndex < visibleRows.count else {
            onSelectionCleared?()
            return
        }
        let row = visibleRows[rowIndex]
        let previousGenotype = selectedGenotype
        let previousLocus = selectedRowLocus
        selectedSampleName = sample
        selectedGenotype = row.genotype
        selectedRowLocus = row.locus
        selectedMatrixTargets = [matrixTarget(row: row, sample: sample)]
        reloadRowsForSelectionChange(
            previousGenotype: previousGenotype,
            previousLocus: previousLocus,
            newGenotype: row.genotype,
            newLocus: row.locus
        )
        onSharedCallSelected?(row, sample)
    }

    private func reloadRowsForSelectionChange(
        previousGenotype: String?,
        previousLocus: String?,
        newGenotype: String,
        newLocus: String
    ) {
        var rowIndexes = IndexSet()
        if let previousGenotype,
           let previousLocus,
           let previousIndex = visibleRows.firstIndex(where: { $0.genotype == previousGenotype && $0.locus == previousLocus }) {
            rowIndexes.insert(previousIndex)
        }
        if let newIndex = visibleRows.firstIndex(where: { $0.genotype == newGenotype && $0.locus == newLocus }) {
            rowIndexes.insert(newIndex)
        }
        guard !rowIndexes.isEmpty, tableView.numberOfColumns > 0 else { return }
        tableView.reloadData(
            forRowIndexes: rowIndexes,
            columnIndexes: IndexSet(integersIn: 0..<tableView.numberOfColumns)
        )
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
        let backgroundColor = backgroundColor(for: identifier, row: row)
        let borderColor = borderColor(for: identifier, row: row)
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
        row: ONTGenotypeSharedCall
    ) -> NSColor? {
        if hidesFilteredCellAppearance(identifier: identifier, row: row) {
            return nil
        }

        if displayState.cellColorMode != .none,
           let color = renderedStyle(for: identifier, row: row).fillColor {
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
        row: ONTGenotypeSharedCall
    ) -> NSColor? {
        if hidesFilteredCellAppearance(identifier: identifier, row: row) {
            return nil
        }

        guard displayState.cellColorMode != .none else { return nil }
        if let color = renderedStyle(for: identifier, row: row).borderColor {
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
        rendered.isBold = rendered.isBold || style.isBold
        rendered.isItalic = rendered.isItalic || style.isItalic
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
        guard row.genotype == selectedGenotype,
              row.locus == selectedRowLocus,
              let selectedSampleName,
              sampleColumnLookup[identifier] == selectedSampleName else {
            return false
        }
        return true
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

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let row = self.row(at: point)
        let column = self.column(at: point)
        onCellMouseDown?(row, column)
        super.mouseDown(with: event)
        onCellMouseUp?(row, column)
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
        return backgroundColor(for: identifier, row: row)
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

    func testingSelectSupportedCellsInSelectedRow(minimumReads: Int) -> [GenotypeAnnotationSidecar.MatrixTarget] {
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
        selectedSampleName = nil
        selectedMatrixTargets = targets
        return targets
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
