import AppKit
import LungfishCore
import LungfishIO

@MainActor
final class GenotypeComparisonMatrixView: NSView, NSTableViewDataSource, NSTableViewDelegate {
    private struct CellKey: Hashable {
        let genotype: String
        let sample: String
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
    private var sampleColumnLookup: [NSUserInterfaceItemIdentifier: String] = [:]
    private var selectedGenotype: String?
    private var selectedSampleName: String?
    private var selectedRowLocus: String?
    private var selectedFilterLocus: String?
    private var pendingClickedSampleName: String?
    private var filterText = ""
    /// Set of sample IDs allowed by the active Smart Cohort + Quick Filter.
    /// `nil` means no cohort restriction is active and every sample is allowed.
    /// When non-`nil`, rows are kept only if at least one supporting sample is
    /// in the set, and per-sample columns matching outside the set are also
    /// filtered out of the text-search match path so the matrix view stays
    /// consistent with Outline/Cards.
    private var allowedSampleIDs: Set<String>?
    private var totalRowCount = 0
    private var hiddenCellCount = 0
    private var supportFractionByCell: [CellKey: Double] = [:]
    private var cellStyles: [CellKey: GenotypeResultHighlightStyle] = [:]
    private var rowStyles: [String: GenotypeResultHighlightStyle] = [:]

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        buildView()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        buildView()
    }

    func configure(result: ONTGenotypeResultBundleData, metadataStore: SampleMetadataStore? = nil) {
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
        rebuildRowsFromResult()
        rebuildColumns()
        applyDefaultSortDescriptor()
        applyFilterAndSort()
    }

    func applyDisplayState(_ state: GenotypeResultDisplayState) {
        displayState = state
        rebuildRowsFromResult()
        applyFilterAndSort()
    }

    func applyMetadataStore(_ store: SampleMetadataStore?) {
        metadataStore = store
        applyFilterAndSort()
    }

    func setFilterText(_ text: String) {
        filterField.stringValue = text
        filterText = text
        applyFilterAndSort()
    }

    /// Apply (or clear) the Smart Cohort + Quick Filter sample allow-list.
    /// Pass `nil` to remove cohort filtering and show every row; pass an empty
    /// set to hide every row. The cohort predicate is composed with the
    /// matrix's own search field via `AND` — a row is shown only if it passes
    /// the cohort filter, the locus popup, *and* the search text.
    func applyCohortFilter(_ allowedSampleIDs: Set<String>?) {
        self.allowedSampleIDs = allowedSampleIDs
        applyFilterAndSort()
    }

    func applyHighlight(_ request: GenotypeResultHighlightRequest) {
        switch request.scope {
        case .selectedCell:
            guard let sample = request.target.sample else { return }
            let key = CellKey(genotype: request.target.genotype, sample: sample)
            mutateStyle(&cellStyles, key: key, channel: request.channel, color: request.color)
        case .selectedRow:
            mutateStyle(&rowStyles, key: request.target.genotype, channel: request.channel, color: request.color)
        case .clear:
            if let sample = request.target.sample {
                cellStyles.removeValue(
                    forKey: CellKey(genotype: request.target.genotype, sample: sample)
                )
            }
            rowStyles.removeValue(forKey: request.target.genotype)
        }
        tableView.reloadData()
    }

    func highlightStyle(for target: GenotypeResultHighlightTarget) -> GenotypeResultHighlightStyle {
        if let sample = target.sample {
            return cellStyles[CellKey(genotype: target.genotype, sample: sample)] ?? .default
        }
        return rowStyles[target.genotype] ?? .default
    }

    func exportSnapshot(bundleURL: URL, analysisName: String, lens: String) -> GenotypeViewportExportSnapshot {
        let filters: [String: String] = [
            "searchText": filterText,
            "locus": selectedFilterLocus ?? "All Loci",
            "hideLowSupport": String(displayState.hideLowSupport),
            "minimumSupportPercent": String(format: "%.1f", displayState.minimumSupportPercent),
            "supportDenominator": displayState.supportDenominator.displayName,
            "cellColorMode": displayState.cellColorMode.displayName,
            "hideFilteredHighlights": String(displayState.hideFilteredHighlights),
        ]
        let rows = visibleRows.map { row in
            let reads = Dictionary(uniqueKeysWithValues: row.sampleSupport.map { ($0.sample, $0.passedUniqueReads) })
            let styles = Dictionary(uniqueKeysWithValues: sampleNames.compactMap { sample -> (String, GenotypeResultHighlightStyle)? in
                let style = cellStyles[CellKey(genotype: row.genotype, sample: sample)] ?? .default
                return style.isDefault ? nil : (sample, style)
            })
            return GenotypeViewportExportRow(
                genotype: row.genotype,
                locus: row.locus,
                sampleCount: row.sampleCount,
                totalUniqueReads: row.totalUniqueReads,
                sampleReads: reads,
                rowStyle: rowStyles[row.genotype] ?? .default,
                cellStyles: styles
            )
        }
        return GenotypeViewportExportSnapshot(
            bundleURL: bundleURL,
            analysisName: analysisName,
            lens: lens,
            filters: filters,
            sampleNames: sampleNames,
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
        addSubview(filterField)

        locusPopup.translatesAutoresizingMaskIntoConstraints = false
        locusPopup.controlSize = .small
        locusPopup.target = self
        locusPopup.action = #selector(locusChanged(_:))
        locusPopup.setAccessibilityIdentifier("genotype-locus-filter")
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

            scrollView.topAnchor.constraint(equalTo: filterField.bottomAnchor, constant: 4),
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

        addColumn(identifier: ColumnID.genotype, title: "Genotype", width: 280, minWidth: 160, ascending: true)
        addColumn(identifier: ColumnID.locus, title: "Locus", width: 92, minWidth: 78, ascending: true)
        addColumn(identifier: ColumnID.samples, title: "Samples", width: 70, minWidth: 58, ascending: false)
        addColumn(identifier: ColumnID.uniqueReads, title: "Unique", width: 78, minWidth: 62, ascending: false)

        for (index, sample) in sampleNames.enumerated() {
            let identifier = ColumnID.sample(index)
            sampleColumnLookup[identifier] = sample
            addColumn(identifier: identifier, title: sample, width: 62, minWidth: 50, ascending: false)
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
        let filteredSummaries = result.locusSummaries(
            minimumSupportPercent: displayState.activeMinimumSupportPercent,
            denominator: displayState.supportDenominator
        )
        allRows = filteredSummaries.flatMap(\.sharedCalls)
        hiddenCellCount = countHiddenCells(in: result)
        supportFractionByCell = makeSupportFractionLookup(for: result)
        rebuildLocusPopup(filteredSummaries)
    }

    private func applyFilterAndSort() {
        let normalizedFilter = filterText.trimmingCharacters(in: .whitespacesAndNewlines)
        let allowedSampleIDs = self.allowedSampleIDs
        visibleRows = allRows.filter { row in
            if let selectedFilterLocus, row.locus != selectedFilterLocus {
                return false
            }
            if let allowedSampleIDs {
                // A row stays if any of its supporting samples are in the
                // active cohort + quick-filter intersection. Rows whose
                // supporters all fall outside the allow-list are hidden so the
                // matrix mirrors what Outline/Cards render.
                guard row.sampleSupport.contains(where: { allowedSampleIDs.contains($0.sample) }) else {
                    return false
                }
            }
            guard !normalizedFilter.isEmpty else { return true }
            if row.locus.localizedCaseInsensitiveContains(normalizedFilter) { return true }
            if row.genotype.localizedCaseInsensitiveContains(normalizedFilter) { return true }
            if row.sampleSupport.contains(where: { support in
                guard allowedSampleIDs?.contains(support.sample) ?? true else { return false }
                return support.sample.localizedCaseInsensitiveContains(normalizedFilter)
            }) {
                return true
            }
            if row.sampleSupport.contains(where: { support in
                guard allowedSampleIDs?.contains(support.sample) ?? true else { return false }
                return metadataMatches(sample: support.sample, filter: normalizedFilter)
            }) {
                return true
            }
            return false
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

    private func countHiddenCells(in result: ONTGenotypeResultBundleData) -> Int {
        result.hiddenSupportCallCount(
            minimumSupportPercent: displayState.activeMinimumSupportPercent,
            denominator: displayState.supportDenominator
        )
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
                fractions[CellKey(genotype: context.call.genotype, sample: context.call.sample)] =
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
                fractions[CellKey(genotype: call.genotype, sample: call.sample)] =
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
        selectVisibleRow(selectedRow, sample: supportedSample(preferredSample, in: visibleRows[selectedRow]))
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
        return record.values.contains { $0.localizedCaseInsensitiveContains(filter) }
            || record.keys.contains { $0.localizedCaseInsensitiveContains(filter) }
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
        selectVisibleRow(row, sample: supportedSample(sample, in: visibleRows[row]))
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

    private func supportedSample(_ sample: String?, in row: ONTGenotypeSharedCall) -> String? {
        guard let sample, row.support(for: sample) != nil else { return nil }
        return sample
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
        cell.wantsLayer = true
        cell.layer?.cornerRadius = 3
        cell.layer?.masksToBounds = true
        cell.textField?.textColor = .labelColor
        cell.layer?.borderWidth = 0
        cell.layer?.borderColor = nil
        cell.layer?.backgroundColor = backgroundColor(for: identifier, row: row)?.cgColor
        if let borderColor = borderColor(for: identifier, row: row) {
            cell.layer?.borderColor = borderColor.cgColor
            cell.layer?.borderWidth = 1.5
        }
        if isSelectedCell(identifier: identifier, row: row) {
            cell.layer?.borderColor = NSColor.keyboardFocusIndicatorColor.cgColor
            cell.layer?.borderWidth = 2
        }
    }

    private func backgroundColor(
        for identifier: NSUserInterfaceItemIdentifier,
        row: ONTGenotypeSharedCall
    ) -> NSColor? {
        if hidesFilteredCellAppearance(identifier: identifier, row: row) {
            return nil
        }

        if displayState.cellColorMode != .none,
           let sample = sampleColumnLookup[identifier],
           let color = cellStyles[CellKey(genotype: row.genotype, sample: sample)]?.fillColor {
            return Self.color(from: color).withAlphaComponent(0.24)
        }

        if displayState.cellColorMode != .none,
           let color = rowStyles[row.genotype]?.fillColor {
            return Self.color(from: color).withAlphaComponent(0.13)
        }

        guard displayState.cellColorMode == .support,
              let sample = sampleColumnLookup[identifier],
              let fraction = supportFractionByCell[CellKey(genotype: row.genotype, sample: sample)] else {
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
        if let sample = sampleColumnLookup[identifier],
           let color = cellStyles[CellKey(genotype: row.genotype, sample: sample)]?.borderColor {
            return Self.color(from: color).withAlphaComponent(0.95)
        }
        if let color = rowStyles[row.genotype]?.borderColor {
            return Self.color(from: color).withAlphaComponent(0.80)
        }
        return nil
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
        return supportFractionByCell[CellKey(genotype: row.genotype, sample: sample)] != nil
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
