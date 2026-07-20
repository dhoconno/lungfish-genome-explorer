import AppKit
import LungfishCore
import LungfishIO
import LungfishKit

struct GenotypeVisibleSampleAlleleDetail {
    let rowID: GenotypeCandidateMatrixRowID
    let stableClusterID: String?
    let sharedCall: ONTGenotypeSharedCall
    let support: ONTGenotypeSampleSupport
    let fraction: Double?
}

/// Enforces the vertical document bounds for every AppKit scroll request while
/// preserving the requested horizontal position. `NSScrollView` normally
/// performs this constraint for wheel events, but a direct/provisional clip
/// origin can otherwise be outside the document while a trackpad gesture is
/// active.
private final class VerticallyClampedClipView: NSClipView {
    override func scroll(to newOrigin: NSPoint) {
        var proposedBounds = bounds
        proposedBounds.origin.y = newOrigin.y
        let constrainedY = super.constrainBoundsRect(proposedBounds).origin.y
        super.scroll(to: NSPoint(x: newOrigin.x, y: constrainedY))
    }
}

private final class GenotypeMatrixPaneDivider: NSView {
    var onDrag: ((CGFloat) -> Void)?
    private var previousWindowX: CGFloat?

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .resizeLeftRight)
    }

    override func mouseDown(with event: NSEvent) {
        previousWindowX = event.locationInWindow.x
    }

    override func mouseDragged(with event: NSEvent) {
        guard let previousWindowX else { return }
        let currentX = event.locationInWindow.x
        self.previousWindowX = currentX
        onDrag?(currentX - previousWindowX)
    }

    override func mouseUp(with event: NSEvent) {
        previousWindowX = nil
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.separatorColor.setFill()
        NSRect(x: bounds.midX, y: bounds.minY, width: 1, height: bounds.height).fill()
    }
}

@MainActor
final class GenotypeComparisonMatrixView: NSView, NSTableViewDataSource, NSTableViewDelegate {
    private struct CellKey: Hashable {
        let locus: String
        let genotype: String
        let sample: String
        let stableClusterID: String?

        init(locus: String, genotype: String, sample: String, stableClusterID: String? = nil) {
            self.locus = locus
            self.genotype = genotype
            self.sample = sample
            self.stableClusterID = stableClusterID
        }
    }

    private struct RowKey: Hashable {
        let locus: String
        let genotype: String
        let stableClusterID: String?

        init(locus: String, genotype: String, stableClusterID: String? = nil) {
            self.locus = locus
            self.genotype = genotype
            self.stableClusterID = stableClusterID
        }
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
        static let rowSelector = NSUserInterfaceItemIdentifier("rowSelector")
        static let genotype = NSUserInterfaceItemIdentifier("genotype")
        static let stableClusterID = NSUserInterfaceItemIdentifier("stableClusterID")
        static let locus = NSUserInterfaceItemIdentifier("locus")
        static let samples = NSUserInterfaceItemIdentifier("samples")
        static let uniqueReads = NSUserInterfaceItemIdentifier("uniqueReads")
        static let referencePrefix = "reference."
        static func reference(_ fieldKey: String) -> NSUserInterfaceItemIdentifier {
            NSUserInterfaceItemIdentifier(referencePrefix + fieldKey)
        }
        static func sample(_ index: Int) -> NSUserInterfaceItemIdentifier {
            NSUserInterfaceItemIdentifier("sample-\(index)")
        }
    }

    var onSharedCallSelected: ((ONTGenotypeSharedCall, String?, [GenotypeAnnotationSidecar.MatrixTarget]) -> Void)?
    var onCandidateRowSelected: ((GenotypeCandidateMatrixRow, String?, [GenotypeAnnotationSidecar.MatrixTarget]) -> Void)?
    var onMatrixTargetsSelected: (([GenotypeAnnotationSidecar.MatrixTarget]) -> Void)?
    var onSelectionCleared: (() -> Void)?
    var onDisplaySummaryChanged: ((Int, Int, Int) -> Void)?

    private let filterField = NSSearchField()
    private let locusPopup = NSPopUpButton()
    private let pinnedScrollView = NSScrollView()
    private let pinnedTableView = GenotypeMatrixTableView()
    private let paneDivider = GenotypeMatrixPaneDivider()
    private let scrollView = NSScrollView()
    private let tableView = GenotypeMatrixTableView()
    private var pinnedWidthConstraint: NSLayoutConstraint?
    private var result: ONTGenotypeResultBundleData?
    private var referenceFields: [GenBankRecordDatabase.FieldDefinition] = []
    private var referenceRecords: [String: [String: String]] = [:]
    private var alleleFieldKey: String?
    private var visibleReferenceFieldKeys: Set<String> = []
    private var visibleStandardColumnIDs: Set<String> = []
    private var restoredColumnWidths: [String: CGFloat] = [:]
    private let columnDefaults = UserDefaults.standard
    private static let pinnedPaneWidthKey = "GenotypeMatrix.pinnedPaneWidth"
    private var displayState = GenotypeResultDisplayState()
    private var metadataStore: SampleMetadataStore?
    private var allRows: [GenotypeCandidateMatrixRow] = []
    private var visibleRows: [GenotypeCandidateMatrixRow] = []
    private var sampleNames: [String] = []
    /// FULL filtered logical sample set. Read PERVASIVELY by export
    /// (`exportSnapshot`), annotation-target computation (`selectAllVisibleRowsAndColumns`,
    /// `isAllVisibleRowsAndColumnsSelected`), support-cell selection, sort, and
    /// selection. This is the caller-visible logical set and is NEVER replaced by
    /// the display window.
    private var visibleSampleNames: [String] = []
    private var sampleColumnLookup: [NSUserInterfaceItemIdentifier: String] = [:]
    private var sampleReadTitleByName: [String: String] = [:]
    private var supportByRowAndSample: [GenotypeCandidateMatrixRowID: [String: ONTGenotypeSampleSupport]] = [:]
    private var selectedGenotype: String?
    private var selectedSampleName: String?
    private var selectedRowLocus: String?
    private var selectedRowID: GenotypeCandidateMatrixRowID?
    private var candidateDisplaySettings = ONTMHCCandidateDisplaySettings.default
    private var selectedMatrixTargets: [GenotypeAnnotationSidecar.MatrixTarget] = []
    private var selectedColumnSamples: [String] = []
    private var columnSelectionAnchorSample: String?
    private var directSelectionAnchor: GenotypeAnnotationSidecar.MatrixTarget?
    private var suppressSelectionClearedCallback = false
    private var pendingColumnSelectionTargets: [GenotypeAnnotationSidecar.MatrixTarget]?
    private var pendingColumnSelectionCleared = false
    private var activeSortDescriptors: [NSSortDescriptor] = [
        NSSortDescriptor(key: ColumnID.genotype.rawValue, ascending: true)
    ]
    private var suppressSortDescriptorSync = false
    private var suppressScrollSync = false
    private var selectedFilterLocus: String?
    private var selectedRowFilter: Set<GenotypeCandidateMatrixRowID>?
    private var selectedSampleFilter: Set<String>?
    private var filterText = ""
    private var supportSelectionPreviewMinimumReads = 1
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

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    func configure(
        result: ONTGenotypeResultBundleData,
        metadataStore: SampleMetadataStore? = nil,
        sidecar: GenotypeAnnotationSidecar? = nil
    ) {
        self.result = result
        self.metadataStore = metadataStore
        configureReferenceColumns(from: result.referenceMetadata)
        sampleNames = result.sampleNames
        if sampleNames.isEmpty {
            sampleNames = orderedSamples(from: result.calls)
        }
        appendMissingCandidateSamples(from: result)
        sampleReadTitleByName = sampleReadTitles(from: result)
        selectedRowLocus = nil
        selectedFilterLocus = nil
        selectedGenotype = nil
        selectedSampleName = nil
        selectedRowID = nil
        selectedMatrixTargets = []
        selectedColumnSamples = []
        columnSelectionAnchorSample = nil
        directSelectionAnchor = nil
        pendingColumnSelectionTargets = nil
        pendingColumnSelectionCleared = false
        selectedRowFilter = nil
        selectedSampleFilter = nil
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
        let previousCandidateDisplaySettings = candidateDisplaySettings
        candidateDisplaySettings = sidecar?.settings.mhcCandidateDisplay ?? .default
        sidecarCellStyles = [:]
        sidecarRowStyles = [:]
        sidecarColumnStyles = [:]
        sidecarCellComments = [:]
        sidecarRowComments = [:]
        sidecarColumnComments = [:]
        for annotation in sidecar?.matrixStyles ?? [] {
            switch annotation.target {
            case let .row(locus, genotype, stableClusterID):
                sidecarRowStyles[RowKey(locus: locus, genotype: genotype, stableClusterID: stableClusterID)] = annotation.style
            case let .column(sample):
                sidecarColumnStyles[sample] = annotation.style
            case let .cell(locus, genotype, sample, stableClusterID):
                sidecarCellStyles[CellKey(locus: locus, genotype: genotype, sample: sample, stableClusterID: stableClusterID)] = annotation.style
            }
        }
        for comment in sidecar?.matrixComments ?? [] {
            switch comment.target {
            case let .row(locus, genotype, stableClusterID):
                sidecarRowComments[RowKey(locus: locus, genotype: genotype, stableClusterID: stableClusterID), default: []].append(comment.body)
            case let .column(sample):
                sidecarColumnComments[sample, default: []].append(comment.body)
            case let .cell(locus, genotype, sample, stableClusterID):
                sidecarCellComments[CellKey(locus: locus, genotype: genotype, sample: sample, stableClusterID: stableClusterID), default: []].append(comment.body)
            }
        }
        if reload, candidateDisplaySettings != previousCandidateDisplaySettings {
            rebuildRowsFromResult()
            applyFilterAndSort()
        } else if reload, let targets, !targets.isEmpty {
            reloadMatrixTargets(targets)
        } else if reload {
            reloadAllTables()
        }
    }

    func applyMetadataStore(_ store: SampleMetadataStore?, reload: Bool = true) {
        metadataStore = store
        if reload {
            applyFilterAndSort()
        }
    }

    func setFilterText(_ text: String) {
        let previousSamples = activeSampleNames()
        filterField.stringValue = text
        filterText = text
        if activeSampleNames() != previousSamples {
            rebuildColumns()
            applyDefaultSortDescriptor()
        }
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
            let key = CellKey(locus: request.target.locus, genotype: request.target.genotype, sample: sample, stableClusterID: request.target.stableClusterID)
            mutateStyle(&cellStyles, key: key, channel: request.channel, color: request.color)
            affectedTarget = .cell(locus: request.target.locus, genotype: request.target.genotype, sample: sample, stableClusterID: request.target.stableClusterID)
        case .selectedRow:
            mutateStyle(
                &rowStyles,
                key: RowKey(locus: request.target.locus, genotype: request.target.genotype, stableClusterID: request.target.stableClusterID),
                channel: request.channel,
                color: request.color
            )
            affectedTarget = .row(locus: request.target.locus, genotype: request.target.genotype, stableClusterID: request.target.stableClusterID)
        case .clear:
            if let sample = request.target.sample {
                cellStyles.removeValue(
                    forKey: CellKey(locus: request.target.locus, genotype: request.target.genotype, sample: sample, stableClusterID: request.target.stableClusterID)
                )
            }
            rowStyles.removeValue(forKey: RowKey(locus: request.target.locus, genotype: request.target.genotype, stableClusterID: request.target.stableClusterID))
            affectedTarget = .row(locus: request.target.locus, genotype: request.target.genotype, stableClusterID: request.target.stableClusterID)
        }
        reloadMatrixTargets([affectedTarget])
    }

    func highlightStyle(for target: GenotypeResultHighlightTarget) -> GenotypeResultHighlightStyle {
        if let sample = target.sample {
            return cellStyles[CellKey(locus: target.locus, genotype: target.genotype, sample: sample, stableClusterID: target.stableClusterID)] ?? .default
        }
        return rowStyles[RowKey(locus: target.locus, genotype: target.genotype, stableClusterID: target.stableClusterID)] ?? .default
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
                rowStyle: rowStyles[RowKey(locus: row.locus, genotype: row.genotype, stableClusterID: row.stableClusterID)] ?? .default,
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
        selectedRowID = visibleRows[0].id
        selectedMatrixTargets = [matrixTarget(row: visibleRows[0], sample: nil)]
        selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        scrollRowToVisibleInBothTables(0)
        if visibleRows[0].population == .known {
            onSharedCallSelected?(visibleRows[0].sharedCall, nil, selectedMatrixTargets)
        } else {
            onCandidateRowSelected?(visibleRows[0], nil, selectedMatrixTargets)
        }
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

        pinnedScrollView.translatesAutoresizingMaskIntoConstraints = false
        pinnedScrollView.hasVerticalScroller = false
        pinnedScrollView.hasHorizontalScroller = true
        pinnedScrollView.autohidesScrollers = true
        pinnedScrollView.verticalScrollElasticity = .none
        pinnedScrollView.contentView = VerticallyClampedClipView()
        pinnedScrollView.borderType = .noBorder
        pinnedScrollView.postsFrameChangedNotifications = true
        pinnedScrollView.setContentCompressionResistancePriority(.required, for: .horizontal)
        addSubview(pinnedScrollView)

        paneDivider.translatesAutoresizingMaskIntoConstraints = false
        paneDivider.onDrag = { [weak self] delta in
            guard let self else { return }
            self.setPinnedPaneWidth((self.pinnedWidthConstraint?.constant ?? 360) + delta, persist: true)
        }
        addSubview(paneDivider)

        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.verticalScrollElasticity = .none
        scrollView.contentView = VerticallyClampedClipView()
        scrollView.borderType = .noBorder
        scrollView.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        addSubview(scrollView)

        configureTableView(pinnedTableView)
        configureTableView(tableView)
        pinnedTableView.onCellClick = { [weak self] row, column, modifiers in
            self?.handlePinnedCellClick(row: row, column: column, modifiers: modifiers) ?? false
        }
        tableView.onCellClick = { [weak self] row, column, modifiers in
            self?.handleCellClick(row: row, column: column, modifiers: modifiers) ?? false
        }

        let pinnedHeaderView = GenotypeMatrixHeaderView()
        pinnedHeaderView.isColumnSelectable = { [weak self] column in
            self?.pinnedColumnIdentifier(at: column) == ColumnID.rowSelector
        }
        pinnedHeaderView.isColumnSelected = { [weak self] column in
            guard let self,
                  self.pinnedColumnIdentifier(at: column) == ColumnID.rowSelector else {
                return false
            }
            return self.isAllVisibleRowsAndColumnsSelected()
        }
        pinnedHeaderView.onColumnChicletClick = { [weak self] column, modifiers in
            self?.handlePinnedHeaderChicletClick(column: column, modifiers: modifiers) ?? false
        }
        pinnedHeaderView.readTitleForColumn = { [weak self] column in
            self?.readTitle(forColumnAt: column, in: self?.pinnedTableView)
        }
        pinnedTableView.headerView = pinnedHeaderView
        pinnedTableView.setAccessibilityIdentifier("genotype-comparison-pinned-table")
        pinnedTableView.setAccessibilityLabel("Shared genotype calls, loci, and summary statistics")
        pinnedScrollView.documentView = pinnedTableView

        let headerView = GenotypeMatrixHeaderView()
        headerView.isColumnSelectable = { [weak self] column in
            self?.sampleName(forColumnAt: column) != nil
        }
        headerView.isColumnSelected = { [weak self] column in
            guard let self, let sample = self.sampleName(forColumnAt: column) else { return false }
            return self.selectedColumnSamples.contains(sample) || self.selectedMatrixTargets.contains(.column(sample: sample))
        }
        headerView.onColumnChicletClick = { [weak self] column, modifiers in
            self?.handleHeaderChicletClick(column: column, modifiers: modifiers) ?? false
        }
        headerView.readTitleForColumn = { [weak self] column in
            self?.readTitle(forColumnAt: column, in: self?.tableView)
        }
        tableView.headerView = headerView
        tableView.setAccessibilityIdentifier("genotype-comparison-table")
        tableView.setAccessibilityLabel("Shared genotype calls by sample")
        scrollView.documentView = tableView
        scrollView.contentView.postsBoundsChangedNotifications = true
        pinnedScrollView.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(scrollViewBoundsChanged(_:)),
            name: NSView.boundsDidChangeNotification,
            object: scrollView.contentView
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(scrollViewBoundsChanged(_:)),
            name: NSView.boundsDidChangeNotification,
            object: pinnedScrollView.contentView
        )

        NSLayoutConstraint.activate([
            filterField.topAnchor.constraint(equalTo: topAnchor, constant: 4),
            filterField.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            filterField.trailingAnchor.constraint(equalTo: locusPopup.leadingAnchor, constant: -8),
            filterField.heightAnchor.constraint(equalToConstant: 24),

            locusPopup.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            locusPopup.centerYAnchor.constraint(equalTo: filterField.centerYAnchor),
            locusPopup.widthAnchor.constraint(equalToConstant: 130),

            pinnedScrollView.topAnchor.constraint(equalTo: topAnchor),
            pinnedScrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            pinnedScrollView.bottomAnchor.constraint(equalTo: bottomAnchor),

            paneDivider.topAnchor.constraint(equalTo: topAnchor),
            paneDivider.leadingAnchor.constraint(equalTo: pinnedScrollView.trailingAnchor),
            paneDivider.bottomAnchor.constraint(equalTo: bottomAnchor),
            paneDivider.widthAnchor.constraint(equalToConstant: 7),

            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: paneDivider.trailingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        let rememberedWidth = columnDefaults.double(forKey: Self.pinnedPaneWidthKey)
        pinnedWidthConstraint = pinnedScrollView.widthAnchor.constraint(equalToConstant: rememberedWidth > 0 ? rememberedWidth : 360)
        pinnedWidthConstraint?.isActive = true
    }

    private func configureTableView(_ tableView: GenotypeMatrixTableView) {
        tableView.usesAlternatingRowBackgroundColors = true
        tableView.allowsColumnReordering = tableView === self.tableView
        tableView.allowsColumnResizing = true
        tableView.allowsMultipleSelection = true
        tableView.columnAutoresizingStyle = .noColumnAutoresizing
        tableView.rowHeight = 22
        tableView.style = .plain
        tableView.selectionHighlightStyle = .none
        tableView.delegate = self
        tableView.dataSource = self
    }

    override func layout() {
        super.layout()
        setPinnedPaneWidth(pinnedWidthConstraint?.constant ?? 360, persist: false)
        synchronizePinnedScrollBottomInset()
    }

    @objc private func scrollViewBoundsChanged(_ notification: Notification) {
        guard !suppressScrollSync,
              let sourceContentView = notification.object as? NSClipView else {
            return
        }

        let destinationContentView: NSClipView
        switch sourceContentView {
        case scrollView.contentView:
            destinationContentView = pinnedScrollView.contentView
        case pinnedScrollView.contentView:
            destinationContentView = scrollView.contentView
        default:
            return
        }

        suppressScrollSync = true
        defer { suppressScrollSync = false }
        synchronizePinnedScrollBottomInset()

        let y = sourceContentView.bounds.origin.y
        guard destinationContentView.bounds.origin.y != y else { return }
        var destinationBounds = destinationContentView.bounds
        destinationBounds.origin.y = y
        destinationContentView.setBoundsOrigin(destinationBounds.origin)
    }

    private func synchronizePinnedScrollBottomInset() {
        let bottomChrome = sampleMatrixBottomChromeHeight()
        guard pinnedScrollView.contentInsets.bottom != bottomChrome else { return }
        var contentInsets = pinnedScrollView.contentInsets
        contentInsets.bottom = bottomChrome
        pinnedScrollView.contentInsets = contentInsets
    }

    private func sampleMatrixBottomChromeHeight() -> CGFloat {
        guard let horizontalScroller = scrollView.horizontalScroller,
              !horizontalScroller.isHidden,
              scrollView.scrollerStyle == .legacy else {
            return 0
        }
        return max(0, scrollView.bounds.maxY - horizontalScroller.frame.minY)
    }

    private func rebuildLocusPopup(_ loci: [String]) {
        let previousLocus = selectedFilterLocus
        locusPopup.removeAllItems()
        locusPopup.addItem(withTitle: "All Loci")
        locusPopup.lastItem?.representedObject = nil
        for locus in loci {
            locusPopup.addItem(withTitle: locus)
            locusPopup.lastItem?.representedObject = locus
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
        removeAllColumns(from: pinnedTableView)
        removeAllColumns(from: tableView)
        sampleColumnLookup.removeAll()
        visibleSampleNames = activeSampleNames()
        pruneSelectedColumnsForVisibleSamples()

        addRowSelectorColumn(to: pinnedTableView)
        if visibleStandardColumnIDs.contains(ColumnID.genotype.rawValue) {
            addColumn(to: pinnedTableView, identifier: ColumnID.genotype, title: "Genotype", width: 280, minWidth: 80, ascending: true)
        }
        for field in referenceFields where visibleReferenceFieldKeys.contains(field.key) {
            addColumn(
                to: pinnedTableView,
                identifier: ColumnID.reference(field.key),
                title: field.displayTitle,
                width: field.key == alleleFieldKey ? 220 : 150,
                minWidth: 60,
                ascending: true
            )
        }
        if isMHCCandidateViewportEnabled {
            addColumn(
                to: pinnedTableView,
                identifier: ColumnID.stableClusterID,
                title: "Cluster ID",
                width: 150,
                minWidth: 110,
                ascending: true,
                headerToolTip: "Stable cluster identifier; blank for known alleles"
            )
        }
        if visibleStandardColumnIDs.contains(ColumnID.locus.rawValue) {
            addColumn(to: pinnedTableView, identifier: ColumnID.locus, title: "Locus", width: 92, minWidth: 60, ascending: true)
        }
        if visibleStandardColumnIDs.contains(ColumnID.samples.rawValue) {
            addColumn(to: pinnedTableView, identifier: ColumnID.samples, title: "Samples", width: 70, minWidth: 50, ascending: false)
        }
        if visibleStandardColumnIDs.contains(ColumnID.uniqueReads.rawValue) {
            addColumn(to: pinnedTableView, identifier: ColumnID.uniqueReads, title: "Unique", width: 78, minWidth: 50, ascending: false)
        }
        updatePinnedTableAccessibilityLabel()

        for (index, sample) in visibleSampleNames.enumerated() {
            let identifier = ColumnID.sample(index)
            sampleColumnLookup[identifier] = sample
            addColumn(to: tableView, identifier: identifier, title: sample, width: 68, minWidth: 58, ascending: false)
        }
        updatePinnedWidth()
        pinnedTableView.headerView?.frame.size.height = 34
        tableView.headerView?.frame.size.height = 34
        rebuildPinnedColumnMenu()
    }

    private func updatePinnedTableAccessibilityLabel() {
        let label = isMHCCandidateViewportEnabled
            ? "Known and candidate genotype calls, stable cluster identifiers, loci, and summary statistics"
            : "Shared genotype calls, loci, and summary statistics"
        pinnedTableView.setAccessibilityLabel(label)
    }

    private static let genBankStandardVisibilityKey = "GenotypeMatrix.genbank.visibleStandardColumns"
    private static let fastaStandardVisibilityKey = "GenotypeMatrix.fasta.visibleStandardColumns"
    private static let referenceVisibilityKey = "GenotypeMatrix.genbank.visibleReferenceFields"
    private static let columnWidthsKey = "GenotypeMatrix.pinnedColumnWidths"

    private func configureReferenceColumns(from metadata: ONTGenotypeReferenceMetadata?) {
        referenceFields = metadata?.fields.sorted {
            if $0.preferredOrder != $1.preferredOrder { return $0.preferredOrder < $1.preferredOrder }
            return $0.displayTitle.localizedStandardCompare($1.displayTitle) == .orderedAscending
        } ?? []
        referenceRecords = metadata?.recordsBySequenceName ?? [:]
        alleleFieldKey = metadata?.alleleFieldKey

        let standardKey = metadata == nil ? Self.fastaStandardVisibilityKey : Self.genBankStandardVisibilityKey
        if let stored = columnDefaults.array(forKey: standardKey) as? [String] {
            visibleStandardColumnIDs = Set(stored)
        } else if metadata == nil {
            visibleStandardColumnIDs = [ColumnID.genotype.rawValue, ColumnID.locus.rawValue, ColumnID.samples.rawValue, ColumnID.uniqueReads.rawValue]
        } else {
            visibleStandardColumnIDs = [ColumnID.locus.rawValue, ColumnID.samples.rawValue, ColumnID.uniqueReads.rawValue]
        }

        if metadata != nil {
            if let stored = columnDefaults.array(forKey: Self.referenceVisibilityKey) as? [String] {
                visibleReferenceFieldKeys = Set(stored).intersection(referenceFields.map(\.key))
            } else if let alleleFieldKey {
                visibleReferenceFieldKeys = [alleleFieldKey]
            } else {
                visibleReferenceFieldKeys = []
            }
        } else {
            visibleReferenceFieldKeys = []
        }
        restoredColumnWidths = (columnDefaults.dictionary(forKey: Self.columnWidthsKey) as? [String: Double])?
            .mapValues { CGFloat($0) } ?? [:]
    }

    private func persistColumnVisibility() {
        let standardKey = referenceFields.isEmpty ? Self.fastaStandardVisibilityKey : Self.genBankStandardVisibilityKey
        columnDefaults.set(visibleStandardColumnIDs.sorted(), forKey: standardKey)
        if !referenceFields.isEmpty {
            columnDefaults.set(visibleReferenceFieldKeys.sorted(), forKey: Self.referenceVisibilityKey)
        }
    }

    private func rebuildPinnedColumnMenu() {
        let menu = NSMenu(title: "Columns")
        let standardHeader = NSMenuItem(title: "Standard Columns", action: nil, keyEquivalent: "")
        standardHeader.isEnabled = false
        menu.addItem(standardHeader)
        for (identifier, title) in [
            (ColumnID.genotype.rawValue, "Genotype"),
            (ColumnID.locus.rawValue, "Locus"),
            (ColumnID.samples.rawValue, "Samples"),
            (ColumnID.uniqueReads.rawValue, "Unique"),
        ] {
            let item = NSMenuItem(title: title, action: #selector(togglePinnedStandardColumn(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = identifier
            item.state = visibleStandardColumnIDs.contains(identifier) ? .on : .off
            menu.addItem(item)
        }
        if !referenceFields.isEmpty {
            menu.addItem(.separator())
            let header = NSMenuItem(title: "GenBank Fields", action: nil, keyEquivalent: "")
            header.isEnabled = false
            menu.addItem(header)
            for field in referenceFields {
                let item = NSMenuItem(title: field.displayTitle, action: #selector(toggleReferenceColumn(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = field.key
                item.toolTip = field.key
                item.state = visibleReferenceFieldKeys.contains(field.key) ? .on : .off
                menu.addItem(item)
            }
        }
        pinnedTableView.headerView?.menu = menu
    }

    @objc private func togglePinnedStandardColumn(_ sender: NSMenuItem) {
        guard let identifier = sender.representedObject as? String else { return }
        setStandardColumnVisible(identifier, visible: !visibleStandardColumnIDs.contains(identifier))
    }

    @objc private func toggleReferenceColumn(_ sender: NSMenuItem) {
        guard let fieldKey = sender.representedObject as? String else { return }
        setReferenceColumnVisible(fieldKey, visible: !visibleReferenceFieldKeys.contains(fieldKey))
    }

    private func setStandardColumnVisible(_ identifier: String, visible: Bool) {
        if visible { visibleStandardColumnIDs.insert(identifier) } else { visibleStandardColumnIDs.remove(identifier) }
        persistColumnVisibility()
        rebuildColumns()
        applyDefaultSortDescriptor()
        applyFilterAndSort()
    }

    private func setReferenceColumnVisible(_ fieldKey: String, visible: Bool) {
        guard referenceFields.contains(where: { $0.key == fieldKey }) else { return }
        if visible { visibleReferenceFieldKeys.insert(fieldKey) } else { visibleReferenceFieldKeys.remove(fieldKey) }
        persistColumnVisibility()
        rebuildColumns()
        applyFilterAndSort()
    }


    private func activeSampleNames() -> [String] {
        let sampleFilter = displayState.matrixSampleFilterText.trimmingCharacters(in: .whitespacesAndNewlines)
        let freeTextSampleFilter = implicitSampleFilterText()
        return sampleNames.filter { sample in
            if let allowedSampleIDs, !allowedSampleIDs.contains(sample) {
                return false
            }
            if let selectedSampleFilter, !selectedSampleFilter.contains(sample) {
                return false
            }
            if !sampleFilter.isEmpty, !sampleMatches(sample, filter: sampleFilter) {
                return false
            }
            if let freeTextSampleFilter, !sampleMatches(sample, filter: freeTextSampleFilter) {
                return false
            }
            return true
        }
    }

    private func implicitSampleFilterText() -> String? {
        let search = filterText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !search.isEmpty else { return nil }
        if sampleNames.contains(where: { $0.localizedCaseInsensitiveContains(search) }) {
            return search
        }
        guard !freeTextMatchesAnyGenotypeRow(search) else { return nil }
        return sampleNames.contains { sampleMatches($0, filter: search) } ? search : nil
    }

    private func freeTextMatchesAnyGenotypeRow(_ search: String) -> Bool {
        allRows.contains { rowMatchesIdentity($0, filter: search) }
    }

    private func sampleMatches(_ sample: String, filter: String) -> Bool {
        sample.localizedCaseInsensitiveContains(filter)
            || metadataMatches(sample: sample, filter: filter)
    }

    private func applyDefaultSortDescriptor() {
        let key = alleleFieldKey.map { ColumnID.reference($0).rawValue } ?? ColumnID.genotype.rawValue
        activeSortDescriptors = [
            NSSortDescriptor(key: key, ascending: true)
        ]
        syncSortDescriptorsToTables()
    }

    private func syncSortDescriptorsToTables() {
        suppressSortDescriptorSync = true
        pinnedTableView.sortDescriptors = activeSortDescriptors
        tableView.sortDescriptors = activeSortDescriptors
        suppressSortDescriptorSync = false
    }

    private func removeAllColumns(from tableView: NSTableView) {
        for column in tableView.tableColumns {
            tableView.removeTableColumn(column)
        }
    }

    private func addColumn(
        to tableView: NSTableView,
        identifier: NSUserInterfaceItemIdentifier,
        title: String,
        width: CGFloat,
        minWidth: CGFloat,
        ascending: Bool,
        headerToolTip: String? = nil
    ) {
        let column = NSTableColumn(identifier: identifier)
        column.title = title
        column.width = max(minWidth, restoredColumnWidths[identifier.rawValue] ?? width)
        column.minWidth = minWidth
        column.headerToolTip = headerToolTip ?? title.trimmingCharacters(in: .whitespacesAndNewlines)
        column.sortDescriptorPrototype = NSSortDescriptor(key: identifier.rawValue, ascending: ascending)
        tableView.addTableColumn(column)
    }

    private func addRowSelectorColumn(to tableView: NSTableView) {
        let column = NSTableColumn(identifier: ColumnID.rowSelector)
        column.title = ""
        column.width = 24
        column.minWidth = 24
        column.maxWidth = 24
        column.resizingMask = []
        column.headerToolTip = "Select row"
        tableView.addTableColumn(column)
    }

    private func updatePinnedWidth() {
        setPinnedPaneWidth(pinnedWidthConstraint?.constant ?? 360, persist: false)
    }

    private func setPinnedPaneWidth(_ width: CGFloat, persist: Bool) {
        let maximum = bounds.width >= 427 ? bounds.width - 240 - 7 : CGFloat.greatestFiniteMagnitude
        let constrained = min(maximum, max(180, width))
        pinnedWidthConstraint?.constant = constrained
        if persist {
            columnDefaults.set(Double(constrained), forKey: Self.pinnedPaneWidthKey)
        }
    }

    @objc private func filterChanged(_ sender: NSSearchField) {
        setFilterText(sender.stringValue)
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
        let candidateDocument = validatedMHCCandidateDocument(from: result)
        totalRowCount = unfilteredSummaries.flatMap(\.sharedCalls).count
            + (candidateDocument?.candidates.count ?? 0)
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
        allRows = GenotypeCandidateMatrixProjection.rows(
            knownRows: filteredSummaries.flatMap(\.sharedCalls),
            candidateDocument: candidateDocument,
            settings: effectiveCandidateDisplaySettings
        )
        if globalThreshold > 0 || matrixThreshold > 0 || minimumReads > 0 {
            allRows = allRows.compactMap { row in
                guard row.population != .known else { return row }
                if globalThreshold > 0 {
                    guard let fraction = candidatePopulationSupportFraction(for: row),
                          fraction >= globalThreshold else {
                        return nil
                    }
                }
                if matrixThreshold > 0 {
                    guard let fraction = candidatePopulationSupportFraction(for: row),
                          fraction >= matrixThreshold else {
                        return nil
                    }
                }
                let support = minimumReads > 0
                    ? row.sampleSupport.filter { $0.passedUniqueReads >= minimumReads }
                    : row.sampleSupport
                guard !support.isEmpty else { return nil }
                return GenotypeCandidateMatrixRow(
                    id: row.id,
                    alleleName: row.alleleName,
                    locus: row.locus,
                    stableClusterID: row.stableClusterID,
                    population: row.population,
                    tintCategory: row.tintCategory,
                    sampleSupport: support,
                    evidenceBySample: row.evidenceBySample,
                    candidate: row.candidate
                )
            }
        }
        rebuildSupportLookup()
        let visibleCellCount = allRows.reduce(0) { $0 + $1.sampleCount }
        let candidateCellCount = candidateDocument.map { document in
            Set(document.observations.map { "\($0.stableClusterID)\u{0}\($0.sampleID)" }).count
        } ?? 0
        hiddenCellCount = max(0, result.calls.count + candidateCellCount - visibleCellCount)
        supportFractionByCell = makeSupportFractionLookup(for: result)
        rebuildLocusPopup(Set(allRows.map(\.locus)).sorted {
            $0.localizedStandardCompare($1) == .orderedAscending
        })
    }

    /// Candidate percentage support is a population occurrence fraction, not
    /// a read-share fraction: distinct samples supporting this stable sequence
    /// divided by the full logical sample union represented by the matrix.
    private func candidatePopulationSupportFraction(for row: GenotypeCandidateMatrixRow) -> Double? {
        let eligibleSamples = Set(sampleNames)
        guard !eligibleSamples.isEmpty else { return nil }
        let supportingSamples = Set(row.sampleSupport.map(\.sample)).intersection(eligibleSamples)
        return Double(supportingSamples.count) / Double(eligibleSamples.count)
    }

    private func rebuildSupportLookup() {
        supportByRowAndSample = Dictionary(uniqueKeysWithValues: allRows.map { row in
            var supportBySample: [String: ONTGenotypeSampleSupport] = [:]
            supportBySample.reserveCapacity(row.sampleSupport.count)
            for support in row.sampleSupport where supportBySample[support.sample] == nil {
                supportBySample[support.sample] = support
            }
            return (row.id, supportBySample)
        })
    }

    private var effectiveCandidateDisplaySettings: ONTMHCCandidateDisplaySettings {
        guard isMHCCandidateViewportEnabled else { return .default }
        return displayState.mhcCandidateDisplaySettings ?? candidateDisplaySettings
    }

    /// Candidate projection is deliberately confined to the full-length MHC
    /// result surface. A manifest declaration alone is insufficient: the
    /// loader must also have rehydrated a schema-compatible candidate document
    /// from a paired JSON/FASTA declaration.
    private var isMHCCandidateViewportEnabled: Bool {
        guard let result else { return false }
        return validatedMHCCandidateDocument(from: result) != nil
    }

    private func validatedMHCCandidateDocument(
        from result: ONTGenotypeResultBundleData
    ) -> ONTMHCCandidateAllelesDocument? {
        guard result.manifest.kind == "full-length-ont-mhc-genotype",
              let artifacts = result.manifest.mhcCandidateArtifacts,
              artifacts.schemaVersion == 1,
              artifacts.candidateJSON != nil,
              artifacts.candidateFASTA != nil,
              let document = result.mhcCandidates,
              document.schemaVersion == 1 else {
            return nil
        }
        return document
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
        let normalizedFilterMatchesRowIdentity = !normalizedFilter.isEmpty
            && freeTextMatchesAnyGenotypeRow(normalizedFilter)
        let activeSamples = Set(activeSampleNames())
        visibleRows = allRows.filter { row in
            if let selectedFilterLocus, row.locus != selectedFilterLocus {
                return false
            }
            if let selectedRowFilter,
               !selectedRowFilter.contains(row.id) {
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
                if normalizedFilterMatchesRowIdentity {
                    return rowMatchesIdentity(row, filter: normalizedFilter)
                }
                return rowMatches(row, filter: normalizedFilter, activeSamples: activeSamples)
            }
            return true
        }

        if let descriptor = activeSortDescriptors.first, let key = descriptor.key {
            visibleRows.sort { compare($0, $1, key: key, ascending: descriptor.ascending) }
        }
        reloadAllTables()
        reconcileSelectionAfterFilter()
        onDisplaySummaryChanged?(visibleRows.count, totalRowCount, hiddenCellCount)
    }

    private func reconcileSelectionAfterFilter() {
        let hadPendingClear = pendingColumnSelectionCleared
        let hadPendingTargets = pendingColumnSelectionTargets != nil
        pendingColumnSelectionCleared = false
        pendingColumnSelectionTargets = nil
        guard !selectedMatrixTargets.isEmpty || hadPendingClear || hadPendingTargets else { return }
        let visibleSamples = Set(visibleSampleNames)
        let previousTargets = selectedMatrixTargets
        let survivors = selectedMatrixTargets.filter { target in
            switch target {
            case .row:
                return visibleRowIndex(for: target) != nil
            case let .column(sample):
                return visibleSamples.contains(sample)
            case let .cell(_, _, sample, _):
                return visibleRowIndex(for: target) != nil && visibleSamples.contains(sample)
            }
        }
        guard !survivors.isEmpty else {
            selectedMatrixTargets = []
            selectedColumnSamples = []
            columnSelectionAnchorSample = nil
            directSelectionAnchor = nil
            selectedGenotype = nil
            selectedRowLocus = nil
            selectedSampleName = nil
            deselectAllRows()
            reloadSelectionTransition(from: previousTargets, to: [])
            setHeaderViewsNeedDisplay()
            onSelectionCleared?()
            return
        }
        selectedMatrixTargets = survivors
        let survivingColumnSamples: [String] = survivors.compactMap {
            guard case let .column(sample) = $0 else { return nil }
            return sample
        }
        selectedColumnSamples = survivingColumnSamples.count == survivors.count
            ? survivingColumnSamples
            : []
        if let anchor = directSelectionAnchor, !survivors.contains(anchor) {
            directSelectionAnchor = survivors.last
        }
        if let anchor = columnSelectionAnchorSample, !selectedColumnSamples.contains(anchor) {
            columnSelectionAnchorSample = selectedColumnSamples.last
        }
        let firstRowTarget = firstRowOrCellTarget(in: survivors)
        selectedRowLocus = firstRowTarget?.locus
        selectedGenotype = firstRowTarget?.genotype
        selectedSampleName = firstRowTarget?.sample
        selectedRowID = firstRowTarget.flatMap { target in
            visibleRowIndex(
                locus: target.locus,
                genotype: target.genotype,
                stableClusterID: target.stableClusterID
            ).map { visibleRows[$0].id }
        }
        let indexes = rowIndexes(for: survivors)
        if indexes.isEmpty {
            deselectAllRows()
        } else {
            selectRowIndexes(indexes, byExtendingSelection: false)
        }
        reloadSelectionTransition(from: previousTargets, to: survivors)
        setHeaderViewsNeedDisplay()
        onMatrixTargetsSelected?(survivors)
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

    private func rowMatches(
        _ row: GenotypeCandidateMatrixRow,
        filter: String,
        activeSamples: Set<String>
    ) -> Bool {
        if rowMatchesIdentity(row, filter: filter) { return true }
        return row.sampleSupport.contains { support in
            guard activeSamples.contains(support.sample) else { return false }
            return support.sample.localizedCaseInsensitiveContains(filter)
                || metadataMatches(sample: support.sample, filter: filter)
        }
    }

    private func rowMatchesIdentity(_ row: GenotypeCandidateMatrixRow, filter: String) -> Bool {
        if row.locus.localizedCaseInsensitiveContains(filter)
            || row.genotype.localizedCaseInsensitiveContains(filter)
            || (row.stableClusterID?.localizedCaseInsensitiveContains(filter) ?? false) {
            return true
        }
        guard let record = referenceRecords[row.genotype] else { return false }
        if let query = metadataFieldQuery(from: filter) {
            return record.contains { key, value in
                let title = referenceFields.first(where: { $0.key == key })?.displayTitle ?? key
                return (key.localizedCaseInsensitiveContains(query.field)
                    || title.localizedCaseInsensitiveContains(query.field))
                    && value.localizedCaseInsensitiveContains(query.value)
            }
        }
        return record.contains { key, value in
            let title = referenceFields.first(where: { $0.key == key })?.displayTitle ?? key
            return key.localizedCaseInsensitiveContains(filter)
                || title.localizedCaseInsensitiveContains(filter)
                || value.localizedCaseInsensitiveContains(filter)
        }
    }

    private func makeSupportFractionLookup(for result: ONTGenotypeResultBundleData) -> [CellKey: Double] {
        var fractions: [CellKey: Double]
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
            fractions = [:]
            fractions.reserveCapacity(contexts.count)
            for context in contexts {
                guard let denominator = denominators[
                    SupportBucketKey(sample: context.call.sample, locus: context.locus)
                ],
                      denominator > 0 else {
                    continue
                }
                let key = CellKey(
                    locus: context.locus,
                    genotype: context.call.genotype,
                    sample: context.call.sample
                )
                insertFirstSupportFraction(
                    Double(context.call.passedUniqueReads) / Double(denominator),
                    for: key,
                    into: &fractions
                )
            }
        case .sampleRetained:
            let retainedBySample = Dictionary(uniqueKeysWithValues: result.samples.map {
                ($0.sample, $0.passedUniqueReads)
            })
            fractions = [:]
            fractions.reserveCapacity(result.calls.count)
            for call in result.calls {
                guard let denominator = call.sampleUniqueRetainedReads ?? retainedBySample[call.sample],
                      denominator > 0 else {
                    continue
                }
                let key = CellKey(locus: call.locusGroup, genotype: call.genotype, sample: call.sample)
                insertFirstSupportFraction(
                    Double(call.passedUniqueReads) / Double(denominator),
                    for: key,
                    into: &fractions
                )
            }
        }

        guard let candidateDocument = validatedMHCCandidateDocument(from: result) else {
            return fractions
        }
        let eligibleSampleCount = Set(sampleNames).count
        guard eligibleSampleCount > 0 else { return fractions }
        let observationsByCluster = Dictionary(grouping: candidateDocument.observations, by: \.stableClusterID)
        for candidate in candidateDocument.candidates {
            let supportingSamples = Set(
                (observationsByCluster[candidate.stableClusterID] ?? []).map(\.sampleID)
            )
            let populationFraction = Double(supportingSamples.count) / Double(eligibleSampleCount)
            for sample in supportingSamples {
                fractions[CellKey(
                    locus: candidate.locus,
                    genotype: candidate.provisionalName,
                    sample: sample,
                    stableClusterID: candidate.stableClusterID
                )] = populationFraction
            }
        }
        return fractions
    }

    private func insertFirstSupportFraction(
        _ fraction: Double,
        for key: CellKey,
        into fractions: inout [CellKey: Double]
    ) {
        guard fractions[key] == nil else { return }
        fractions[key] = fraction
    }

    private func compare(
        _ lhs: GenotypeCandidateMatrixRow,
        _ rhs: GenotypeCandidateMatrixRow,
        key: String,
        ascending: Bool
    ) -> Bool {
        let ordered: ComparisonResult
        switch key {
        case ColumnID.stableClusterID.rawValue:
            ordered = (lhs.stableClusterID ?? "").localizedStandardCompare(rhs.stableClusterID ?? "")
        case ColumnID.locus.rawValue:
            ordered = lhs.locus.localizedStandardCompare(rhs.locus)
        case ColumnID.samples.rawValue:
            ordered = compare(lhs.sampleCount, rhs.sampleCount)
        case ColumnID.uniqueReads.rawValue:
            ordered = compare(lhs.totalUniqueReads, rhs.totalUniqueReads)
        default:
            if key.hasPrefix(ColumnID.referencePrefix) {
                let fieldKey = String(key.dropFirst(ColumnID.referencePrefix.count))
                ordered = referenceValue(for: lhs, fieldKey: fieldKey)
                    .localizedStandardCompare(referenceValue(for: rhs, fieldKey: fieldKey))
            } else if let sample = sampleColumnLookup[NSUserInterfaceItemIdentifier(key)] {
                ordered = compare(
                    support(for: sample, row: lhs)?.passedUniqueReads ?? 0,
                    support(for: sample, row: rhs)?.passedUniqueReads ?? 0
                )
            } else {
                ordered = lhs.genotype.localizedStandardCompare(rhs.genotype)
            }
        }
        let resolvedOrder: ComparisonResult
        if ordered == .orderedSame {
            let locusOrder = lhs.locus.localizedStandardCompare(rhs.locus)
            if locusOrder != .orderedSame {
                resolvedOrder = locusOrder
            } else {
                let nameOrder = lhs.genotype.localizedStandardCompare(rhs.genotype)
                if nameOrder != .orderedSame {
                    resolvedOrder = nameOrder
                } else {
                    resolvedOrder = compare(lhs.id.deterministicSortKey, rhs.id.deterministicSortKey)
                }
            }
        } else {
            resolvedOrder = ordered
        }
        return ascending ? resolvedOrder == .orderedAscending : resolvedOrder == .orderedDescending
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

    private func appendMissingCandidateSamples(from result: ONTGenotypeResultBundleData) {
        guard let candidateDocument = validatedMHCCandidateDocument(from: result) else { return }
        var seen = Set(sampleNames)
        let candidateSamples = candidateDocument.observations.map(\.sampleID).sorted {
            $0.localizedStandardCompare($1) == .orderedAscending
        }
        sampleNames.append(contentsOf: candidateSamples.filter { seen.insert($0).inserted })
    }

    private func sampleReadTitles(from result: ONTGenotypeResultBundleData) -> [String: String] {
        Dictionary(uniqueKeysWithValues: result.samples.map {
            ($0.sample, integer($0.passedUniqueReads))
        })
    }

    func numberOfRows(in tableView: NSTableView) -> Int {
        visibleRows.count
    }

    func tableView(_ tableView: NSTableView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
        guard !suppressSortDescriptorSync else { return }
        activeSortDescriptors = tableView.sortDescriptors
        syncSortDescriptorsToTables()
        applyFilterAndSort()
    }

    func tableViewColumnDidResize(_ notification: Notification) {
        guard notification.object as? NSTableView === pinnedTableView else { return }
        var widths = restoredColumnWidths
        for column in pinnedTableView.tableColumns where column.identifier != ColumnID.rowSelector {
            widths[column.identifier.rawValue] = column.width
        }
        restoredColumnWidths = widths
        columnDefaults.set(widths.mapValues { Double($0) }, forKey: Self.columnWidthsKey)
        updatePinnedWidth()
        setHeaderViewsNeedDisplay()
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let tableColumn, row < visibleRows.count else { return nil }
        let sharedCall = visibleRows[row]
        let identifier = tableColumn.identifier
        if identifier == ColumnID.rowSelector {
            let cell = tableView.makeView(withIdentifier: identifier, owner: self) as? GenotypeMatrixRowSelectorCellView
                ?? makeRowSelectorCellView(identifier: identifier)
            cell.configure(isSelected: isSelectedCell(identifier: identifier, row: sharedCall))
            cell.toolTip = "Select \(sharedCall.genotype)"
            return cell
        }
        let cell = tableView.makeView(withIdentifier: identifier, owner: self) as? NSTableCellView
            ?? makeCellView(identifier: identifier)
        let value = cellValue(for: identifier, row: sharedCall)
        cell.textField?.stringValue = value.text
        cell.textField?.alignment = value.alignment
        cell.textField?.toolTip = value.toolTip
        cell.textField?.isSelectable = identifier == ColumnID.stableClusterID
        if identifier == ColumnID.stableClusterID {
            cell.textField?.setAccessibilityLabel(value.toolTip ?? "Stable cluster ID: None")
        }
        applyCellStyle(cell, identifier: identifier, row: sharedCall)
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !suppressSelectionClearedCallback else { return }
        let sourceTable = notification.object as? NSTableView
        let selectedRows = IndexSet((sourceTable ?? tableView).selectedRowIndexes.filter { $0 >= 0 && $0 < visibleRows.count })
        guard !selectedRows.isEmpty else {
            deselectAllRows()
            onSelectionCleared?()
            return
        }
        selectRowIndexes(selectedRows, byExtendingSelection: false)
        let preferredSample = selectedSampleName
        if selectedRows.count > 1 {
            selectVisibleRows(Array(selectedRows), sample: preferredSample)
            return
        }
        let selectedRow = selectedRows[selectedRows.startIndex]
        selectVisibleRow(selectedRow, sample: preferredSample)
    }

    private func selectRowIndexes(_ indexes: IndexSet, byExtendingSelection: Bool) {
        suppressSelectionClearedCallback = true
        pinnedTableView.selectRowIndexes(indexes, byExtendingSelection: byExtendingSelection)
        tableView.selectRowIndexes(indexes, byExtendingSelection: byExtendingSelection)
        suppressSelectionClearedCallback = false
    }

    private func deselectAllRows() {
        suppressSelectionClearedCallback = true
        pinnedTableView.deselectAll(nil)
        tableView.deselectAll(nil)
        suppressSelectionClearedCallback = false
    }

    private func scrollRowToVisibleInBothTables(_ row: Int) {
        pinnedTableView.scrollRowToVisible(row)
        tableView.scrollRowToVisible(row)
    }

    private func makeCellView(identifier: NSUserInterfaceItemIdentifier) -> NSTableCellView {
        let cell = GenotypeMatrixStyledCellView()
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

    private func makeRowSelectorCellView(identifier: NSUserInterfaceItemIdentifier) -> GenotypeMatrixRowSelectorCellView {
        let cell = GenotypeMatrixRowSelectorCellView()
        cell.identifier = identifier
        return cell
    }

    private func cellValue(
        for identifier: NSUserInterfaceItemIdentifier,
        row: GenotypeCandidateMatrixRow
    ) -> (text: String, alignment: NSTextAlignment, toolTip: String?) {
        switch identifier {
        case ColumnID.rowSelector:
            return ("", .center, "Select row")
        case ColumnID.genotype:
            return (row.genotype, .left, rowTooltip(row: row, fallback: row.genotype))
        case ColumnID.stableClusterID:
            guard let stableClusterID = row.stableClusterID else {
                return ("", .left, "Known allele; no stable cluster ID")
            }
            return (stableClusterID, .left, "Stable cluster ID: \(stableClusterID)")
        case ColumnID.locus:
            return (row.locus, .left, rowTooltip(row: row, fallback: row.locus))
        case ColumnID.samples:
            return ("\(row.sampleCount)", .right, nil)
        case ColumnID.uniqueReads:
            return (integer(row.totalUniqueReads), .right, "Total unique reads across supporting samples")
        default:
            if identifier.rawValue.hasPrefix(ColumnID.referencePrefix) {
                let key = String(identifier.rawValue.dropFirst(ColumnID.referencePrefix.count))
                let text = referenceValue(for: row, fieldKey: key)
                return (text, .left, text.isEmpty ? nil : text)
            }
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

    private func referenceValue(for row: GenotypeCandidateMatrixRow, fieldKey: String) -> String {
        let value = referenceRecords[row.genotype]?[fieldKey] ?? ""
        if value.isEmpty, fieldKey == alleleFieldKey {
            return row.genotype
        }
        return value
    }

    private func isAlleleIdentityColumn(_ identifier: NSUserInterfaceItemIdentifier) -> Bool {
        if identifier == ColumnID.genotype { return true }
        guard let alleleFieldKey else { return false }
        return identifier == ColumnID.reference(alleleFieldKey)
    }

    private func support(for sample: String, row: GenotypeCandidateMatrixRow) -> ONTGenotypeSampleSupport? {
        supportByRowAndSample[row.id]?[sample]
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

    private func rowTooltip(row: GenotypeCandidateMatrixRow, fallback: String) -> String {
        let comments = commentsForRow(row)
        var lines = [fallback]
        if let stableClusterID = row.stableClusterID {
            lines.append("Stable cluster ID: \(stableClusterID)")
        }
        if !comments.isEmpty {
            lines.append("Row comments:")
            lines.append(contentsOf: comments)
        }
        return lines.joined(separator: "\n")
    }

    private func matrixTooltip(sample: String, row: GenotypeCandidateMatrixRow, base: String?) -> String? {
        var lines: [String] = []
        if let base, !base.isEmpty {
            lines.append(base)
        }
        appendComments(commentsForRow(row), title: "Row comments", to: &lines)
        appendComments(sidecarColumnComments[sample] ?? [], title: "Column comments", to: &lines)
        appendComments(commentsForCell(row, sample: sample), title: "Cell comments", to: &lines)
        return lines.isEmpty ? nil : lines.joined(separator: "\n")
    }

    private func commentsForRow(_ row: GenotypeCandidateMatrixRow) -> [String] {
        let legacy = sidecarRowComments[RowKey(locus: row.locus, genotype: row.genotype)] ?? []
        guard let stableClusterID = row.stableClusterID else { return legacy }
        return legacy + (sidecarRowComments[
            RowKey(locus: row.locus, genotype: row.genotype, stableClusterID: stableClusterID)
        ] ?? [])
    }

    private func commentsForCell(_ row: GenotypeCandidateMatrixRow, sample: String) -> [String] {
        let legacy = sidecarCellComments[CellKey(locus: row.locus, genotype: row.genotype, sample: sample)] ?? []
        guard let stableClusterID = row.stableClusterID else { return legacy }
        return legacy + (sidecarCellComments[
            CellKey(locus: row.locus, genotype: row.genotype, sample: sample, stableClusterID: stableClusterID)
        ] ?? [])
    }

    private func appendComments(_ comments: [String], title: String, to lines: inout [String]) {
        guard !comments.isEmpty else { return }
        lines.append(title + ":")
        lines += comments
    }

    private func integer(_ value: Int) -> String {
        value.formatted(.number)
    }

    private func handlePinnedCellClick(row: Int, column: Int, modifiers: NSEvent.ModifierFlags) -> Bool {
        guard row >= 0, row < visibleRows.count else {
            return false
        }
        guard column >= 0, column < pinnedTableView.tableColumns.count else { return false }
        let identifier = pinnedTableView.tableColumns[column].identifier
        if identifier == ColumnID.rowSelector {
            selectRowFromDirectClick(row, modifiers: modifiers)
            return true
        }
        return false
    }

    private func handleCellClick(row: Int, column: Int, modifiers: NSEvent.ModifierFlags) -> Bool {
        guard row >= 0, row < visibleRows.count else {
            return false
        }
        guard column >= 0, column < tableView.tableColumns.count else { return false }
        let identifier = tableView.tableColumns[column].identifier
        if identifier == ColumnID.rowSelector {
            selectRowFromDirectClick(row, modifiers: modifiers)
            return true
        }
        if let sample = sampleName(forColumnAt: column) {
            selectCellFromDirectClick(row, sample: sample, modifiers: modifiers)
            return true
        }
        return false
    }

    private func selectRowFromDirectClick(_ row: Int, modifiers: NSEvent.ModifierFlags) {
        let target = matrixTarget(row: visibleRows[row], sample: nil)
        if modifiers.contains(.shift) {
            publishMatrixTargetSelection(rowRangeTargets(to: row), anchor: target)
            return
        }
        if modifiers.contains(.command) {
            publishMatrixTargetSelection(toggle(target, in: selectedMatrixTargets), anchor: target)
            return
        }
        selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        directSelectionAnchor = target
        selectVisibleRow(row, sample: nil)
    }

    private func selectCellFromDirectClick(_ row: Int, sample: String, modifiers: NSEvent.ModifierFlags) {
        let target = matrixTarget(row: visibleRows[row], sample: sample)
        if modifiers.contains(.shift) {
            publishMatrixTargetSelection(cellRangeTargets(toRow: row, sample: sample), anchor: target)
            return
        }
        if modifiers.contains(.command) {
            publishMatrixTargetSelection(toggle(target, in: selectedMatrixTargets), anchor: target)
            return
        }
        selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        directSelectionAnchor = target
        selectVisibleRow(row, sample: sample)
    }

    private func handleHeaderChicletClick(column: Int, modifiers: NSEvent.ModifierFlags) -> Bool {
        guard let sample = sampleName(forColumnAt: column) else {
            return false
        }
        selectSampleColumn(clicked: sample, modifiers: modifiers)
        return true
    }

    private func handlePinnedHeaderChicletClick(column: Int, modifiers: NSEvent.ModifierFlags) -> Bool {
        guard pinnedColumnIdentifier(at: column) == ColumnID.rowSelector else {
            return false
        }
        if isAllVisibleRowsAndColumnsSelected() {
            clearSelectionAfterColumnToggle()
        } else {
            selectAllVisibleRowsAndColumns()
        }
        return true
    }

    private func pinnedColumnIdentifier(at column: Int) -> NSUserInterfaceItemIdentifier? {
        guard column >= 0, column < pinnedTableView.tableColumns.count else { return nil }
        return pinnedTableView.tableColumns[column].identifier
    }

    private func selectAllVisibleRowsAndColumns() {
        let rowTargets = visibleRows.map { matrixTarget(row: $0, sample: nil) }
        let columnTargets = visibleSampleNames.map { GenotypeAnnotationSidecar.MatrixTarget.column(sample: $0) }
        let targets = rowTargets + columnTargets
        guard !targets.isEmpty else {
            clearSelectionAfterColumnToggle()
            return
        }
        publishMatrixTargetSelection(targets, anchor: targets.last)
    }

    private func isAllVisibleRowsAndColumnsSelected() -> Bool {
        let requiredTargets = Set(
            visibleRows.map { matrixTarget(row: $0, sample: nil) }
                + visibleSampleNames.map { GenotypeAnnotationSidecar.MatrixTarget.column(sample: $0) }
        )
        guard !requiredTargets.isEmpty else { return false }
        return requiredTargets.isSubset(of: Set(selectedMatrixTargets))
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
        selectedRowID = nil
        selectedSampleName = nil
        columnSelectionAnchorSample = nil
        directSelectionAnchor = nil
        pendingColumnSelectionTargets = nil
        pendingColumnSelectionCleared = false
        deselectAllRows()
        reloadSelectionTransition(from: previousTargets, to: [])
        setHeaderViewsNeedDisplay()
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
        selectedRowID = nil
        selectedSampleName = nil
        directSelectionAnchor = .column(sample: selectedColumnSamples.last ?? visible[0])
        selectedMatrixTargets = selectedColumnSamples.map { .column(sample: $0) }
        pendingColumnSelectionTargets = nil
        pendingColumnSelectionCleared = false
        deselectAllRows()
        reloadSelectionTransition(from: previousTargets, to: selectedMatrixTargets)
        setHeaderViewsNeedDisplay()
        onMatrixTargetsSelected?(selectedMatrixTargets)
    }

    private func visibleSampleNamesInColumnOrder() -> [String] {
        tableView.tableColumns.compactMap { sampleColumnLookup[$0.identifier] }
    }

    func visibleSampleAlleleDetails(sample: String) -> [GenotypeVisibleSampleAlleleDetail] {
        visibleRows.compactMap { row in
            sampleAlleleDetail(row: row, sample: sample)
        }
    }

    func sampleAlleleDetail(
        row: GenotypeCandidateMatrixRow,
        sample: String
    ) -> GenotypeVisibleSampleAlleleDetail? {
        guard let support = supportByRowAndSample[row.id]?[sample] else { return nil }
        let fraction = supportFractionByCell[
            CellKey(
                locus: row.locus,
                genotype: row.genotype,
                sample: sample,
                stableClusterID: row.stableClusterID
            )
        ]
        return GenotypeVisibleSampleAlleleDetail(
            rowID: row.id,
            stableClusterID: row.stableClusterID,
            sharedCall: row.sharedCall,
            support: support,
            fraction: fraction
        )
    }

    func cachedSupportFraction(locus: String, genotype: String, sample: String) -> Double? {
        supportFractionByCell[CellKey(locus: locus, genotype: genotype, sample: sample)]
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
        selectedRowID = row.id
        selectedMatrixTargets = [matrixTarget(row: row, sample: sample)]
        directSelectionAnchor = selectedMatrixTargets.first
        reloadSelectionTransition(from: previousTargets, to: selectedMatrixTargets)
        setHeaderViewsNeedDisplay()
        if row.population == .known {
            onSharedCallSelected?(row.sharedCall, sample, selectedMatrixTargets)
        } else {
            onCandidateRowSelected?(row, sample, selectedMatrixTargets)
        }
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
        selectedRowID = firstRow.id
        selectedMatrixTargets = validIndexes.map { matrixTarget(row: visibleRows[$0], sample: sample) }
        directSelectionAnchor = selectedMatrixTargets.last
        reloadSelectionTransition(from: previousTargets, to: selectedMatrixTargets)
        setHeaderViewsNeedDisplay()
        if firstRow.population == .known {
            onSharedCallSelected?(firstRow.sharedCall, sample, selectedMatrixTargets)
        } else {
            onCandidateRowSelected?(firstRow, sample, selectedMatrixTargets)
        }
    }

    private func publishMatrixTargetSelection(
        _ targets: [GenotypeAnnotationSidecar.MatrixTarget],
        anchor: GenotypeAnnotationSidecar.MatrixTarget?
    ) {
        let uniqueTargets = uniqueMatrixTargets(targets)
        guard !uniqueTargets.isEmpty else {
            clearSelectionAfterColumnToggle()
            return
        }
        let previousTargets = selectedMatrixTargets
        selectedMatrixTargets = uniqueTargets
        selectedColumnSamples = uniqueTargets.compactMap { target in
            guard case let .column(sample) = target else { return nil }
            return sample
        }
        if selectedColumnSamples.count != uniqueTargets.count {
            selectedColumnSamples = []
        }
        columnSelectionAnchorSample = selectedColumnSamples.last
        directSelectionAnchor = anchor ?? uniqueTargets.last
        let firstRowTarget = firstRowOrCellTarget(in: uniqueTargets)
        selectedRowLocus = firstRowTarget?.locus
        selectedGenotype = firstRowTarget?.genotype
        selectedRowID = firstRowTarget.flatMap { target in
            visibleRows.first {
                $0.locus == target.locus
                    && $0.genotype == target.genotype
                    && (target.stableClusterID == nil || $0.stableClusterID == target.stableClusterID)
            }?.id
        }
        selectedSampleName = firstRowTarget?.sample
        pendingColumnSelectionTargets = nil
        pendingColumnSelectionCleared = false
        let selectedRowIndexes = rowIndexes(for: uniqueTargets)
        if selectedRowIndexes.isEmpty {
            deselectAllRows()
        } else {
            selectRowIndexes(selectedRowIndexes, byExtendingSelection: false)
        }
        reloadSelectionTransition(from: previousTargets, to: uniqueTargets)
        setHeaderViewsNeedDisplay()
        onMatrixTargetsSelected?(uniqueTargets)
    }

    private func rowRangeTargets(to row: Int) -> [GenotypeAnnotationSidecar.MatrixTarget] {
        guard let anchorIndex = visibleRowIndex(for: directSelectionAnchor) else {
            return [matrixTarget(row: visibleRows[row], sample: nil)]
        }
        let range = min(anchorIndex, row)...max(anchorIndex, row)
        return range.map { matrixTarget(row: visibleRows[$0], sample: nil) }
    }

    private func cellRangeTargets(toRow row: Int, sample: String) -> [GenotypeAnnotationSidecar.MatrixTarget] {
        guard let anchor = directSelectionAnchor,
              let anchorRow = visibleRowIndex(for: anchor),
              let anchorSample = sampleName(for: anchor),
              let anchorSampleIndex = visibleSampleNamesInColumnOrder().firstIndex(of: anchorSample),
              let sampleIndex = visibleSampleNamesInColumnOrder().firstIndex(of: sample) else {
            return [matrixTarget(row: visibleRows[row], sample: sample)]
        }
        let rowRange = min(anchorRow, row)...max(anchorRow, row)
        let sampleRange = min(anchorSampleIndex, sampleIndex)...max(anchorSampleIndex, sampleIndex)
        let orderedSamples = visibleSampleNamesInColumnOrder()
        return rowRange.flatMap { rowIndex in
            sampleRange.map { sampleIndex in
                matrixTarget(row: visibleRows[rowIndex], sample: orderedSamples[sampleIndex])
            }
        }
    }

    private func toggle(
        _ target: GenotypeAnnotationSidecar.MatrixTarget,
        in targets: [GenotypeAnnotationSidecar.MatrixTarget]
    ) -> [GenotypeAnnotationSidecar.MatrixTarget] {
        var next = targets
        if let index = next.firstIndex(of: target) {
            next.remove(at: index)
        } else {
            next.append(target)
        }
        return next
    }

    private func uniqueMatrixTargets(
        _ targets: [GenotypeAnnotationSidecar.MatrixTarget]
    ) -> [GenotypeAnnotationSidecar.MatrixTarget] {
        var seen = Set<GenotypeAnnotationSidecar.MatrixTarget>()
        return targets.filter { seen.insert($0).inserted }
    }

    private func rowIndexes(for targets: [GenotypeAnnotationSidecar.MatrixTarget]) -> IndexSet {
        var indexes = IndexSet()
        for target in targets {
            if let rowIndex = visibleRowIndex(for: target) {
                indexes.insert(rowIndex)
            }
        }
        return indexes
    }

    private func visibleRowIndex(for target: GenotypeAnnotationSidecar.MatrixTarget?) -> Int? {
        guard let target else { return nil }
        switch target {
        case let .row(locus, genotype, stableClusterID),
             let .cell(locus, genotype, _, stableClusterID):
            return visibleRowIndex(locus: locus, genotype: genotype, stableClusterID: stableClusterID)
        case .column:
            return nil
        }
    }

    private func sampleName(for target: GenotypeAnnotationSidecar.MatrixTarget?) -> String? {
        guard let target else { return nil }
        switch target {
        case let .cell(_, _, sample, _), let .column(sample):
            return sample
        case .row:
            return nil
        }
    }

    private func firstRowOrCellTarget(
        in targets: [GenotypeAnnotationSidecar.MatrixTarget]
    ) -> (locus: String, genotype: String, sample: String?, stableClusterID: String?)? {
        for target in targets {
            switch target {
            case let .row(locus, genotype, stableClusterID):
                return (locus, genotype, nil, stableClusterID)
            case let .cell(locus, genotype, sample, stableClusterID):
                return (locus, genotype, sample, stableClusterID)
            case .column:
                continue
            }
        }
        return nil
    }

    private func reloadSelectionTransition(
        from previousTargets: [GenotypeAnnotationSidecar.MatrixTarget],
        to nextTargets: [GenotypeAnnotationSidecar.MatrixTarget]
    ) {
        reloadMatrixTargets(previousTargets + nextTargets)
    }

    private func reloadAllTables() {
        pinnedTableView.reloadData()
        tableView.reloadData()
    }

    private func setHeaderViewsNeedDisplay() {
        pinnedTableView.headerView?.needsDisplay = true
        tableView.headerView?.needsDisplay = true
    }

    private func reloadVisibleMatrix() {
        reloadVisibleRows(in: pinnedTableView)
        reloadVisibleRows(in: tableView)
    }

    private func reloadVisibleRows(in tableView: NSTableView) {
        guard tableView.numberOfRows > 0, tableView.numberOfColumns > 0 else { return }
        tableView.reloadData(
            forRowIndexes: IndexSet(integersIn: 0..<tableView.numberOfRows),
            columnIndexes: IndexSet(integersIn: 0..<tableView.numberOfColumns)
        )
    }

    private func reloadMatrixTargets(_ targets: [GenotypeAnnotationSidecar.MatrixTarget]) {
        guard !targets.isEmpty else { return }
        var pinnedRowIndexes = IndexSet()
        var sampleRowIndexes = IndexSet()
        var sampleColumnIndexes = IndexSet()
        let pinnedAllColumns = IndexSet(integersIn: 0..<pinnedTableView.numberOfColumns)
        let sampleAllColumns = IndexSet(integersIn: 0..<tableView.numberOfColumns)

        for target in targets {
            switch target {
            case let .row(locus, genotype, stableClusterID):
                if let rowIndex = visibleRowIndex(locus: locus, genotype: genotype, stableClusterID: stableClusterID) {
                    pinnedRowIndexes.insert(rowIndex)
                    sampleRowIndexes.insert(rowIndex)
                    sampleColumnIndexes.formUnion(sampleAllColumns)
                }
            case let .column(sample):
                if let columnIndex = visibleColumnIndex(sample: sample), tableView.numberOfRows > 0 {
                    sampleRowIndexes.formUnion(IndexSet(integersIn: 0..<tableView.numberOfRows))
                    sampleColumnIndexes.insert(columnIndex)
                }
            case let .cell(locus, genotype, sample, stableClusterID):
                if let rowIndex = visibleRowIndex(locus: locus, genotype: genotype, stableClusterID: stableClusterID),
                   let columnIndex = visibleColumnIndex(sample: sample) {
                    sampleRowIndexes.insert(rowIndex)
                    sampleColumnIndexes.insert(columnIndex)
                }
            }
        }

        if !pinnedRowIndexes.isEmpty, !pinnedAllColumns.isEmpty {
            pinnedTableView.reloadData(forRowIndexes: pinnedRowIndexes, columnIndexes: pinnedAllColumns)
        }
        if !sampleRowIndexes.isEmpty, !sampleColumnIndexes.isEmpty {
            tableView.reloadData(forRowIndexes: sampleRowIndexes, columnIndexes: sampleColumnIndexes)
        }
    }

    private func visibleRowIndex(
        locus: String,
        genotype: String,
        stableClusterID: String? = nil
    ) -> Int? {
        if let stableClusterID {
            return visibleRows.firstIndex {
                $0.locus == locus && $0.genotype == genotype && $0.stableClusterID == stableClusterID
            }
        }
        return visibleRows.firstIndex { $0.locus == locus && $0.genotype == genotype }
    }

    private func visibleColumnIndex(sample: String) -> Int? {
        tableView.tableColumns.firstIndex { sampleColumnLookup[$0.identifier] == sample }
    }

    func showOnlySelectedRows() {
        let rows: Set<GenotypeCandidateMatrixRowID>
        if let selectedRowID, selectedMatrixTargets.count == 1 {
            rows = [selectedRowID]
        } else {
            rows = Set(selectedMatrixTargets.flatMap { target -> [GenotypeCandidateMatrixRowID] in
                switch target {
                case let .row(locus, genotype, stableClusterID),
                     let .cell(locus, genotype, _, stableClusterID):
                    if let stableClusterID {
                        return visibleRows.filter {
                            $0.locus == locus && $0.genotype == genotype && $0.stableClusterID == stableClusterID
                        }.map(\.id)
                    }
                    return visibleRows.filter { $0.locus == locus && $0.genotype == genotype }.map(\.id)
                case .column:
                    return []
                }
            })
        }
        guard !rows.isEmpty else { return }
        selectedRowFilter = rows
        applyFilterAndSort()
    }

    func showOnlySelectedColumns() {
        let samples = Set(selectedMatrixTargets.compactMap { target -> String? in
            switch target {
            case let .column(sample), let .cell(_, _, sample, _):
                return sample
            case .row:
                return nil
            }
        })
        guard !samples.isEmpty else { return }
        selectedSampleFilter = samples
        rebuildColumns()
        applyDefaultSortDescriptor()
        applyFilterAndSort()
    }

    func clearSelectionFilter() {
        guard selectedRowFilter != nil || selectedSampleFilter != nil else { return }
        selectedRowFilter = nil
        selectedSampleFilter = nil
        rebuildColumns()
        applyDefaultSortDescriptor()
        applyFilterAndSort()
    }

    private func readTitle(forColumnAt columnIndex: Int, in tableView: NSTableView?) -> String? {
        guard let tableView,
              columnIndex >= 0,
              columnIndex < tableView.tableColumns.count else { return nil }
        let identifier = tableView.tableColumns[columnIndex].identifier
        if identifier == ColumnID.uniqueReads {
            return "Reads"
        }
        guard let sample = sampleColumnLookup[identifier] else { return nil }
        return sampleReadTitleByName[sample]
    }

    private func matrixTarget(
        row: GenotypeCandidateMatrixRow,
        sample: String?
    ) -> GenotypeAnnotationSidecar.MatrixTarget {
        if let sample {
            return .cell(
                locus: row.locus,
                genotype: row.genotype,
                sample: sample,
                stableClusterID: row.stableClusterID
            )
        }
        return .row(locus: row.locus, genotype: row.genotype, stableClusterID: row.stableClusterID)
    }

    func selectSupportedCellsInSelectedRow(minimumReads: Int) -> [GenotypeAnnotationSidecar.MatrixTarget] {
        guard let selectedGenotype,
              let selectedRowLocus,
              let row = visibleRows.first(where: {
                  if let selectedRowID { return $0.id == selectedRowID }
                  return $0.genotype == selectedGenotype && $0.locus == selectedRowLocus
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
                    sample: $0.sample,
                    stableClusterID: row.stableClusterID
                )
            }
        let previousTargets = selectedMatrixTargets
        selectedSampleName = nil
        selectedColumnSamples = []
        columnSelectionAnchorSample = nil
        selectedMatrixTargets = targets
        reloadSelectionTransition(from: previousTargets, to: targets)
        setHeaderViewsNeedDisplay()
        return targets
    }

    func setSupportSelectionPreviewMinimumReads(_ minimumReads: Int) {
        let next = max(0, minimumReads)
        guard supportSelectionPreviewMinimumReads != next else { return }
        supportSelectionPreviewMinimumReads = next
        reloadMatrixTargets(selectedMatrixTargets)
    }

    func supportedCellTargets(
        from targets: [GenotypeAnnotationSidecar.MatrixTarget],
        minimumReads: Int
    ) -> [GenotypeAnnotationSidecar.MatrixTarget] {
        let threshold = max(0, minimumReads)
        let visibleSamples = Set(visibleSampleNames)
        let expandedTargets = targets.flatMap { target -> [GenotypeAnnotationSidecar.MatrixTarget] in
            switch target {
            case let .row(locus, genotype, stableClusterID):
                guard let rowIndex = visibleRowIndex(locus: locus, genotype: genotype, stableClusterID: stableClusterID) else {
                    return []
                }
                let row = visibleRows[rowIndex]
                return row.sampleSupport
                    .filter { visibleSamples.contains($0.sample) && $0.passedUniqueReads >= threshold }
                    .map { .cell(locus: locus, genotype: genotype, sample: $0.sample, stableClusterID: row.stableClusterID) }
            case let .column(sample):
                guard visibleSamples.contains(sample) else { return [] }
                return visibleRows.compactMap { row in
                    guard let support = row.support(for: sample),
                          support.passedUniqueReads >= threshold else {
                        return nil
                    }
                    return .cell(locus: row.locus, genotype: row.genotype, sample: sample, stableClusterID: row.stableClusterID)
                }
            case let .cell(locus, genotype, sample, stableClusterID):
                guard visibleSamples.contains(sample),
                      let rowIndex = visibleRowIndex(locus: locus, genotype: genotype, stableClusterID: stableClusterID) else {
                    return []
                }
                let row = visibleRows[rowIndex]
                guard let support = row.support(for: sample),
                      support.passedUniqueReads >= threshold else {
                    return []
                }
                return [target]
            }
        }
        return uniqueMatrixTargets(expandedTargets)
    }

    func replaceMatrixTargetSelection(_ targets: [GenotypeAnnotationSidecar.MatrixTarget]) {
        let uniqueTargets = uniqueMatrixTargets(targets)
        let previousTargets = selectedMatrixTargets
        selectedMatrixTargets = uniqueTargets
        selectedColumnSamples = uniqueTargets.compactMap { target in
            if case let .column(sample) = target { return sample }
            return nil
        }
        columnSelectionAnchorSample = selectedColumnSamples.last
        directSelectionAnchor = uniqueTargets.last
        if let firstTarget = uniqueTargets.first {
            switch firstTarget {
            case let .row(locus, genotype, stableClusterID):
                selectedRowLocus = locus
                selectedGenotype = genotype
                selectedRowID = visibleRowIndex(locus: locus, genotype: genotype, stableClusterID: stableClusterID).map { visibleRows[$0].id }
                selectedSampleName = nil
            case let .cell(locus, genotype, sample, stableClusterID):
                selectedRowLocus = locus
                selectedGenotype = genotype
                selectedRowID = visibleRowIndex(locus: locus, genotype: genotype, stableClusterID: stableClusterID).map { visibleRows[$0].id }
                selectedSampleName = sample
            case .column:
                selectedRowLocus = nil
                selectedGenotype = nil
                selectedRowID = nil
                selectedSampleName = nil
            }
        } else {
            selectedRowLocus = nil
            selectedGenotype = nil
            selectedRowID = nil
            selectedSampleName = nil
        }
        reloadSelectionTransition(from: previousTargets, to: uniqueTargets)
        setHeaderViewsNeedDisplay()
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
        row: GenotypeCandidateMatrixRow
    ) {
        let renderedStyle = renderedStyle(for: identifier, row: row)
        let backgroundColor = backgroundColor(for: identifier, row: row, renderedStyle: renderedStyle)
        let borderColor = borderColor(for: identifier, row: row, renderedStyle: renderedStyle)
        let selected = drawsMatrixCellSelectionFocus(identifier: identifier, row: row)
        let showsPreviewBorder = showsSupportSelectionPreviewBorder(identifier: identifier, row: row)

        cell.alphaValue = 1.0
        cell.textField?.textColor = renderedStyle.textColor.map(Self.color(from:)) ?? .labelColor
        cell.textField?.font = font(for: renderedStyle)
        var finalBorderColor = borderColor
        var finalBorderWidth: CGFloat = borderColor == nil ? 0 : 1.5
        if showsPreviewBorder {
            finalBorderColor = .systemOrange
            finalBorderWidth = 2
        }
        if selected {
            finalBorderColor = .keyboardFocusIndicatorColor
            finalBorderWidth = 2
        }
        (cell as? GenotypeMatrixStyledCellView)?.configureChrome(
            backgroundColor: backgroundColor,
            borderColor: finalBorderColor,
            borderWidth: finalBorderWidth
        )
    }

    private func drawsMatrixCellSelectionFocus(
        identifier: NSUserInterfaceItemIdentifier,
        row: GenotypeCandidateMatrixRow
    ) -> Bool {
        guard let sample = sampleColumnLookup[identifier],
              !selectedMatrixTargets.isEmpty else {
            return false
        }
        return selectedMatrixTargets.contains { target in
            switch target {
            case let .cell(locus, genotype, selectedSample, stableClusterID):
                return row.locus == locus && row.genotype == genotype && sample == selectedSample
                    && targetIdentity(stableClusterID, allows: row)
            case .row, .column:
                return false
            }
        }
    }

    private func showsSupportSelectionPreviewBorder(
        identifier: NSUserInterfaceItemIdentifier,
        row: GenotypeCandidateMatrixRow
    ) -> Bool {
        guard let sample = sampleColumnLookup[identifier],
              selectedMatrixTargets.contains(where: { target in
                  switch target {
                  case let .row(locus, genotype, stableClusterID):
                      return row.locus == locus && row.genotype == genotype
                          && targetIdentity(stableClusterID, allows: row)
                  case let .column(selectedSample):
                      return sample == selectedSample
                  case .cell:
                      return false
                  }
              }) else {
            return false
        }
        let threshold = max(0, supportSelectionPreviewMinimumReads)
        guard let support = row.support(for: sample) else { return false }
        return support.passedUniqueReads >= threshold
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
        row: GenotypeCandidateMatrixRow,
        renderedStyle: GenotypeMatrixRenderedStyle
    ) -> NSColor? {
        if hidesFilteredCellAppearance(identifier: identifier, row: row) {
            return nil
        }

        if displayState.cellColorMode != .none,
           let color = renderedStyle.fillColor {
            return Self.color(from: color)
        }

        if isAlleleIdentityColumn(identifier),
           let category = row.tintCategory,
           let tint = effectiveCandidateDisplaySettings.tints[category] {
            return Self.color(from: tint)
        }

        // Candidate population fractions drive percentage filtering but do not
        // introduce the known-call blue support heatmap. Their configurable
        // category tint remains confined to the allele-name cell.
        guard row.population == .known,
              displayState.cellColorMode == .support,
              let sample = sampleColumnLookup[identifier],
              let fraction = supportFractionByCell[
                CellKey(
                    locus: row.locus,
                    genotype: row.genotype,
                    sample: sample,
                    stableClusterID: row.stableClusterID
                )
              ] else {
            return nil
        }

        let alpha = min(0.20, max(0.06, 0.05 + fraction * 0.22))
        return NSColor.systemBlue.withAlphaComponent(alpha)
    }

    private func borderColor(
        for identifier: NSUserInterfaceItemIdentifier,
        row: GenotypeCandidateMatrixRow,
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
        row: GenotypeCandidateMatrixRow
    ) -> GenotypeMatrixRenderedStyle {
        var rendered = mergedRenderedStyle(for: sampleColumnLookup[identifier], row: row)
        let effectiveBackground: AnnotationColor?
        if displayState.cellColorMode != .none, let fillColor = rendered.fillColor {
            effectiveBackground = fillColor
        } else if isAlleleIdentityColumn(identifier),
                  let category = row.tintCategory {
            effectiveBackground = effectiveCandidateDisplaySettings.tints[category]
        } else {
            effectiveBackground = nil
        }
        applyAutomaticTextContrast(to: &rendered, against: effectiveBackground)
        return rendered
    }

    private func renderedStyle(
        for sample: String?,
        row: GenotypeCandidateMatrixRow
    ) -> GenotypeMatrixRenderedStyle {
        var rendered = mergedRenderedStyle(for: sample, row: row)
        let background = rendered.fillColor
        applyAutomaticTextContrast(to: &rendered, against: background)
        return rendered
    }

    private func mergedRenderedStyle(
        for sample: String?,
        row: GenotypeCandidateMatrixRow
    ) -> GenotypeMatrixRenderedStyle {
        var rendered = GenotypeMatrixRenderedStyle.default
        let legacyRowKey = RowKey(locus: row.locus, genotype: row.genotype)
        let exactRowKey = RowKey(
            locus: row.locus,
            genotype: row.genotype,
            stableClusterID: row.stableClusterID
        )
        merge(sidecarRowStyles[legacyRowKey], into: &rendered)
        if exactRowKey != legacyRowKey {
            merge(sidecarRowStyles[exactRowKey], into: &rendered)
        }
        if let sample {
            merge(sidecarColumnStyles[sample], into: &rendered)
            let legacyCellKey = CellKey(locus: row.locus, genotype: row.genotype, sample: sample)
            let exactCellKey = CellKey(
                locus: row.locus,
                genotype: row.genotype,
                sample: sample,
                stableClusterID: row.stableClusterID
            )
            merge(sidecarCellStyles[legacyCellKey], into: &rendered)
            if exactCellKey != legacyCellKey {
                merge(sidecarCellStyles[exactCellKey], into: &rendered)
            }
        }
        if let rowHighlight = rowStyles[exactRowKey] ?? rowStyles[legacyRowKey] {
            rendered.fillColor = rowHighlight.fillColor ?? rendered.fillColor
            rendered.borderColor = rowHighlight.borderColor ?? rendered.borderColor
        }
        if let sample,
           let cellHighlight = cellStyles[
               CellKey(locus: row.locus, genotype: row.genotype, sample: sample, stableClusterID: row.stableClusterID)
           ] ?? cellStyles[CellKey(locus: row.locus, genotype: row.genotype, sample: sample)] {
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

    private func applyAutomaticTextContrast(
        to rendered: inout GenotypeMatrixRenderedStyle,
        against background: AnnotationColor?
    ) {
        guard rendered.textColor == nil, let background else { return }
        let black = AnnotationColor(red: 0, green: 0, blue: 0)
        let white = AnnotationColor(red: 1, green: 1, blue: 1)
        let alpha = max(0, min(1, background.alpha))
        let canvas = contrastCanvasColor()
        let composited = AnnotationColor(
            red: background.red * alpha + canvas.red * (1 - alpha),
            green: background.green * alpha + canvas.green * (1 - alpha),
            blue: background.blue * alpha + canvas.blue * (1 - alpha),
            alpha: 1
        )
        let fillLuminance = relativeLuminance(composited)
        let blackContrast = contrastRatio(fillLuminance, relativeLuminance(black))
        let whiteContrast = contrastRatio(fillLuminance, relativeLuminance(white))
        rendered.textColor = whiteContrast > blackContrast ? white : black
    }

    private func contrastCanvasColor() -> AnnotationColor {
        var resolved = AnnotationColor(red: 1, green: 1, blue: 1)
        effectiveAppearance.performAsCurrentDrawingAppearance {
            guard let color = NSColor.controlBackgroundColor.usingColorSpace(.sRGB) else { return }
            resolved = AnnotationColor(
                red: Double(color.redComponent),
                green: Double(color.greenComponent),
                blue: Double(color.blueComponent),
                alpha: Double(color.alphaComponent)
            )
        }
        return resolved
    }

    private func relativeLuminance(_ color: AnnotationColor) -> Double {
        func channel(_ value: Double) -> Double {
            let value = max(0, min(1, value))
            return value <= 0.03928 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * channel(color.red)
            + 0.7152 * channel(color.green)
            + 0.0722 * channel(color.blue)
    }

    private func contrastRatio(_ lhs: Double, _ rhs: Double) -> Double {
        let lighter = max(lhs, rhs)
        let darker = min(lhs, rhs)
        return (lighter + 0.05) / (darker + 0.05)
    }

    private func hidesFilteredCellAppearance(
        identifier: NSUserInterfaceItemIdentifier,
        row: GenotypeCandidateMatrixRow
    ) -> Bool {
        guard displayState.hideLowSupport,
              displayState.hideFilteredHighlights,
              displayState.activeMinimumSupportPercent > 0,
              let sample = sampleColumnLookup[identifier],
              row.support(for: sample) == nil else {
            return false
        }
        return supportFractionByCell[CellKey(
            locus: row.locus,
            genotype: row.genotype,
            sample: sample,
            stableClusterID: row.stableClusterID
        )] != nil
    }

    private func isSelectedCell(
        identifier: NSUserInterfaceItemIdentifier,
        row: GenotypeCandidateMatrixRow
    ) -> Bool {
        guard !selectedMatrixTargets.isEmpty else { return false }
        let sample = sampleColumnLookup[identifier]
        return selectedMatrixTargets.contains { target in
            switch target {
            case let .row(locus, genotype, stableClusterID):
                return row.locus == locus && row.genotype == genotype
                    && targetIdentity(stableClusterID, allows: row)
            case let .column(selectedSample):
                return sample == selectedSample
            case let .cell(locus, genotype, selectedSample, stableClusterID):
                return row.locus == locus && row.genotype == genotype && sample == selectedSample
                    && targetIdentity(stableClusterID, allows: row)
            }
        }
    }

    /// Matrix annotation targets predate stable candidate IDs. Restrict an
    /// otherwise ambiguous target only when it addresses the same displayed
    /// locus/name as the selected candidate; distinct targets and all known
    /// rows retain the existing multi-selection behavior.
    private func stableSelectionAllows(_ row: GenotypeCandidateMatrixRow) -> Bool {
        guard let selectedRowID,
              case .candidate = selectedRowID,
              case .candidate = row.id,
              let selected = visibleRows.first(where: { $0.id == selectedRowID }),
              selected.locus == row.locus,
              selected.genotype == row.genotype else {
            return true
        }
        return selectedRowID == row.id
    }

    private func targetIdentity(_ stableClusterID: String?, allows row: GenotypeCandidateMatrixRow) -> Bool {
        if let stableClusterID {
            return row.stableClusterID == stableClusterID
        }
        return stableSelectionAllows(row)
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
    var onCellClick: ((Int, Int, NSEvent.ModifierFlags) -> Bool)?

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
        if onCellClick?(row, column, event.modifierFlags) == true {
            return
        }
        super.mouseDown(with: event)
    }
}

private final class GenotypeMatrixStyledCellView: NSTableCellView {
    private var chromeBackgroundColor: NSColor?
    private var chromeBorderColor: NSColor?
    private var chromeBorderWidth: CGFloat = 0

    func configureChrome(backgroundColor: NSColor?, borderColor: NSColor?, borderWidth: CGFloat) {
        chromeBackgroundColor = backgroundColor
        chromeBorderColor = borderColor
        chromeBorderWidth = borderWidth
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard chromeBackgroundColor != nil || chromeBorderColor != nil else { return }

        let inset = max(chromeBorderWidth / 2, 0.5)
        let rect = bounds.insetBy(dx: inset, dy: inset)
        guard rect.width > 0, rect.height > 0 else { return }

        let path = NSBezierPath(roundedRect: rect, xRadius: 3, yRadius: 3)
        if let chromeBackgroundColor {
            chromeBackgroundColor.setFill()
            path.fill()
        }
        if let chromeBorderColor, chromeBorderWidth > 0 {
            chromeBorderColor.setStroke()
            path.lineWidth = chromeBorderWidth
            path.stroke()
        }
    }
}

private final class GenotypeMatrixRowSelectorCellView: NSTableCellView {
    private let chiclet = GenotypeMatrixRowSelectorChicletView()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        buildView()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        buildView()
    }

    func configure(isSelected: Bool) {
        chiclet.configure(isSelected: isSelected)
    }

    private func buildView() {
        chiclet.translatesAutoresizingMaskIntoConstraints = false
        addSubview(chiclet)
        NSLayoutConstraint.activate([
            chiclet.widthAnchor.constraint(equalToConstant: 12),
            chiclet.heightAnchor.constraint(equalToConstant: 12),
            chiclet.centerXAnchor.constraint(equalTo: centerXAnchor),
            chiclet.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }
}

private final class GenotypeMatrixRowSelectorChicletView: NSView {
    private var fillColor = NSColor.clear
    private var strokeColor = NSColor.tertiaryLabelColor
    private var strokeWidth: CGFloat = 1

    func configure(isSelected: Bool) {
        fillColor = isSelected ? NSColor.controlAccentColor.withAlphaComponent(0.24) : .clear
        strokeColor = isSelected ? .controlAccentColor : .tertiaryLabelColor
        strokeWidth = isSelected ? 1.5 : 1
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let inset = max(strokeWidth / 2, 0.5)
        let rect = bounds.insetBy(dx: inset, dy: inset)
        guard rect.width > 0, rect.height > 0 else { return }

        let path = NSBezierPath(roundedRect: rect, xRadius: 5, yRadius: 5)
        fillColor.setFill()
        path.fill()
        strokeColor.setStroke()
        path.lineWidth = strokeWidth
        path.stroke()
    }
}

private final class GenotypeMatrixHeaderView: NSTableHeaderView {
    var isColumnSelectable: ((Int) -> Bool)?
    var isColumnSelected: ((Int) -> Bool)?
    var onColumnChicletClick: ((Int, NSEvent.ModifierFlags) -> Bool)?
    var readTitleForColumn: ((Int) -> String?)?

    override func draw(_ dirtyRect: NSRect) {
        guard let tableView else { return }
        NSColor.controlBackgroundColor.setFill()
        dirtyRect.fill()

        for column in 0..<tableView.numberOfColumns {
            let rect = headerRect(ofColumn: column)
            guard rect.intersects(dirtyRect) else { continue }
            drawHeaderCell(
                in: rect,
                title: tableView.tableColumns[column].title,
                readTitle: readTitleForColumn?(column),
                selectable: isColumnSelectable?(column) == true,
                selected: isColumnSelected?(column) == true
            )
        }
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let column = self.column(at: point)
        if column >= 0,
           isColumnSelectable?(column) == true,
           chicletRect(forColumn: column).contains(point),
           onColumnChicletClick?(column, event.modifierFlags) == true {
            return
        }
        super.mouseDown(with: event)
    }

    private func chicletRect(forColumn column: Int) -> NSRect {
        chicletRect(in: headerRect(ofColumn: column))
    }

    private func drawHeaderCell(
        in rect: NSRect,
        title: String,
        readTitle: String?,
        selectable: Bool,
        selected: Bool
    ) {
        NSColor.separatorColor.setStroke()
        let divider = NSBezierPath()
        divider.move(to: NSPoint(x: rect.maxX - 0.5, y: rect.minY))
        divider.line(to: NSPoint(x: rect.maxX - 0.5, y: rect.maxY))
        divider.stroke()

        if selectable {
            drawChiclet(in: chicletRect(in: rect), selected: selected)
        }

        let leftInset: CGFloat = selectable ? 20 : 6
        let titleRect = NSRect(
            x: rect.minX + leftInset,
            y: rect.midY - 1,
            width: max(0, rect.width - leftInset - 4),
            height: rect.height / 2
        )
        let readRect = NSRect(
            x: rect.minX + 6,
            y: rect.minY + 2,
            width: max(0, rect.width - 10),
            height: rect.height / 2 - 2
        )
        drawText(title, in: titleRect, font: .systemFont(ofSize: 11, weight: .semibold), alignment: .left, color: .labelColor)
        if let readTitle {
            drawText(readTitle, in: readRect, font: .monospacedDigitSystemFont(ofSize: 10, weight: .regular), alignment: .right, color: .secondaryLabelColor)
        }
    }

    private func chicletRect(in rect: NSRect) -> NSRect {
        let size: CGFloat = 11
        return NSRect(
            x: rect.minX + 5,
            y: rect.midY + 1,
            width: size,
            height: size
        )
    }

    private func drawText(
        _ text: String,
        in rect: NSRect,
        font: NSFont,
        alignment: NSTextAlignment,
        color: NSColor
    ) {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = alignment
        paragraph.lineBreakMode = .byTruncatingTail
        (text as NSString).draw(
            in: rect,
            withAttributes: [
                .font: font,
                .foregroundColor: color,
                .paragraphStyle: paragraph,
            ]
        )
    }

    private func drawChiclet(in rect: NSRect, selected: Bool) {
        let path = NSBezierPath(roundedRect: rect, xRadius: 4, yRadius: 4)
        let fillColor = selected
            ? NSColor.controlAccentColor.withAlphaComponent(0.24)
            : NSColor.windowBackgroundColor.withAlphaComponent(0.70)
        fillColor.setFill()
        path.fill()
        (selected ? NSColor.controlAccentColor : NSColor.tertiaryLabelColor).setStroke()
        path.lineWidth = selected ? 1.5 : 1
        path.stroke()
    }
}

#if DEBUG
enum GenotypeCandidateMatrixTestingColumn {
    case alleleName
    case stableClusterID
    case locus
    case sample(String)
}

extension GenotypeComparisonMatrixView {
    var testingVisibleRows: [GenotypeCandidateMatrixRow] { visibleRows }
    var testingVisibleGenotypes: [String] { visibleRows.map(\.genotype) }
    var testingSelectedRowID: GenotypeCandidateMatrixRowID? { selectedRowID }

    func testingSupportFraction(
        rowID: GenotypeCandidateMatrixRowID,
        sample: String
    ) -> Double? {
        guard let row = allRows.first(where: { $0.id == rowID }) else { return nil }
        return supportFractionByCell[CellKey(
            locus: row.locus,
            genotype: row.genotype,
            sample: sample,
            stableClusterID: row.stableClusterID
        )]
    }

    func testingBackgroundColor(
        rowID: GenotypeCandidateMatrixRowID,
        column: GenotypeCandidateMatrixTestingColumn
    ) -> NSColor? {
        guard let row = visibleRows.first(where: { $0.id == rowID }) else { return nil }
        let identifier: NSUserInterfaceItemIdentifier
        switch column {
        case .alleleName:
            identifier = ColumnID.genotype
        case .stableClusterID:
            identifier = ColumnID.stableClusterID
        case .locus:
            identifier = ColumnID.locus
        case .sample(let sample):
            guard let sampleIdentifier = sampleColumnLookup.first(where: { $0.value == sample })?.key else {
                return nil
            }
            identifier = sampleIdentifier
        }
        return backgroundColor(for: identifier, row: row, renderedStyle: renderedStyle(for: identifier, row: row))
    }

    func testingRenderedTextColor(
        rowID: GenotypeCandidateMatrixRowID,
        column: GenotypeCandidateMatrixTestingColumn
    ) -> AnnotationColor? {
        guard let row = visibleRows.first(where: { $0.id == rowID }) else { return nil }
        let identifier: NSUserInterfaceItemIdentifier
        switch column {
        case .alleleName:
            identifier = ColumnID.genotype
        case .stableClusterID:
            identifier = ColumnID.stableClusterID
        case .locus:
            identifier = ColumnID.locus
        case .sample(let sample):
            guard let sampleIdentifier = sampleColumnLookup.first(where: { $0.value == sample })?.key else {
                return nil
            }
            identifier = sampleIdentifier
        }
        return renderedStyle(for: identifier, row: row).textColor
    }

    func testingPinnedCellValue(
        rowID: GenotypeCandidateMatrixRowID,
        column: GenotypeCandidateMatrixTestingColumn
    ) -> String? {
        guard let (identifier, rowIndex) = testingPinnedCellTarget(rowID: rowID, column: column) else { return nil }
        return cellValue(for: identifier, row: visibleRows[rowIndex]).text
    }

    func testingPinnedCellToolTip(
        rowID: GenotypeCandidateMatrixRowID,
        column: GenotypeCandidateMatrixTestingColumn
    ) -> String? {
        guard let (identifier, rowIndex) = testingPinnedCellTarget(rowID: rowID, column: column) else { return nil }
        return cellValue(for: identifier, row: visibleRows[rowIndex]).toolTip
    }

    func testingPinnedCellAccessibilityLabel(
        rowID: GenotypeCandidateMatrixRowID,
        column: GenotypeCandidateMatrixTestingColumn
    ) -> String? {
        guard let (identifier, row) = testingPinnedCellTarget(rowID: rowID, column: column),
              let column = pinnedTableView.tableColumns.first(where: { $0.identifier == identifier }),
              let cell = tableView(pinnedTableView, viewFor: column, row: row) as? NSTableCellView else {
            return nil
        }
        return cell.textField?.accessibilityLabel()
    }

    func testingPinnedCellIsSelectable(
        rowID: GenotypeCandidateMatrixRowID,
        column: GenotypeCandidateMatrixTestingColumn
    ) -> Bool {
        guard let (identifier, row) = testingPinnedCellTarget(rowID: rowID, column: column),
              let column = pinnedTableView.tableColumns.first(where: { $0.identifier == identifier }),
              let cell = tableView(pinnedTableView, viewFor: column, row: row) as? NSTableCellView else {
            return false
        }
        return cell.textField?.isSelectable == true
    }

    private func testingPinnedCellTarget(
        rowID: GenotypeCandidateMatrixRowID,
        column: GenotypeCandidateMatrixTestingColumn
    ) -> (NSUserInterfaceItemIdentifier, Int)? {
        guard let row = visibleRows.firstIndex(where: { $0.id == rowID }) else { return nil }
        let identifier: NSUserInterfaceItemIdentifier
        switch column {
        case .alleleName:
            identifier = ColumnID.genotype
        case .stableClusterID:
            identifier = ColumnID.stableClusterID
        case .locus:
            identifier = ColumnID.locus
        case .sample:
            return nil
        }
        guard pinnedTableView.tableColumns.contains(where: { $0.identifier == identifier }) else { return nil }
        return (identifier, row)
    }

    func testingSelectCandidateCell(rowID: GenotypeCandidateMatrixRowID, sample: String) {
        guard let rowIndex = visibleRows.firstIndex(where: { $0.id == rowID }),
              visibleSampleNames.contains(sample) else {
            onSelectionCleared?()
            return
        }
        selectRowIndexes(IndexSet(integer: rowIndex), byExtendingSelection: false)
        selectVisibleRow(rowIndex, sample: sample)
    }

    func testingClickCandidateRowChiclet(
        rowID: GenotypeCandidateMatrixRowID,
        modifiers: NSEvent.ModifierFlags = []
    ) {
        guard let rowIndex = visibleRows.firstIndex(where: { $0.id == rowID }),
              let columnIndex = pinnedTableView.tableColumns.firstIndex(where: { $0.identifier == ColumnID.rowSelector }) else {
            onSelectionCleared?()
            return
        }
        _ = handlePinnedCellClick(row: rowIndex, column: columnIndex, modifiers: modifiers)
    }

    func testingDrawsSelectionFocus(rowID: GenotypeCandidateMatrixRowID, sample: String) -> Bool {
        guard let row = visibleRows.first(where: { $0.id == rowID }),
              let identifier = sampleColumnLookup.first(where: { $0.value == sample })?.key else {
            return false
        }
        return drawsMatrixCellSelectionFocus(identifier: identifier, row: row)
    }
    var testingVisibleSampleNames: [String] { visibleSampleNames }
    var testingPinnedVerticalScrollOffset: CGFloat {
        pinnedScrollView.contentView.bounds.origin.y
    }
    var testingSampleMatrixScrollOffset: NSPoint {
        scrollView.contentView.bounds.origin
    }
    func testingScrollPinnedPanel(toY y: CGFloat) {
        var origin = pinnedScrollView.contentView.bounds.origin
        origin.y = y
        pinnedScrollView.contentView.setBoundsOrigin(origin)
    }
    func testingScrollSampleMatrix(to origin: NSPoint) {
        scrollView.contentView.setBoundsOrigin(origin)
    }
    func testingConfigureSampleMatrixLegacyHorizontalScroller() {
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = false
        scrollView.scrollerStyle = .legacy
        scrollView.tile()
        layoutSubtreeIfNeeded()
    }
    var testingSampleMatrixBottomChromeHeight: CGFloat {
        sampleMatrixBottomChromeHeight()
    }
    func testingScrollSampleMatrixToBottom(x: CGFloat) {
        scrollView.contentView.setBoundsOrigin(NSPoint(x: x, y: CGFloat.greatestFiniteMagnitude))
    }
    func testingPinnedRowYInMatrix(row: Int) -> CGFloat {
        pinnedTableView.convert(pinnedTableView.rect(ofRow: row), to: self).minY
    }
    func testingSampleMatrixRowYInMatrix(row: Int) -> CGFloat {
        tableView.convert(tableView.rect(ofRow: row), to: self).minY
    }
    /// Count of instantiated per-sample columns.
    var testingSampleColumnCount: Int {
        tableView.tableColumns.filter { sampleColumnLookup[$0.identifier] != nil }.count
    }
    var testingActiveSampleNames: [String] { activeSampleNames() }
    var testingIsColumnWindowActive: Bool { false }
    var testingColumnWindowBannerVisible: Bool { false }
    var testingVisibleSampleColumnTitles: [String] {
        tableView.tableColumns.compactMap { column in
            sampleColumnLookup[column.identifier] == nil ? nil : column.title
        }
    }
    var testingPinnedColumnTitles: [String] {
        pinnedTableView.tableColumns.map(\.title)
    }
    var testingPinnedTableAccessibilityLabel: String? {
        pinnedTableView.accessibilityLabel()
    }
    var testingPinnedPaneWidth: CGFloat {
        pinnedWidthConstraint?.constant ?? 0
    }
    func testingSetPinnedPaneWidth(_ width: CGFloat) {
        setPinnedPaneWidth(width, persist: true)
        layoutSubtreeIfNeeded()
    }
    var testingAvailableReferenceColumnTitles: [String] {
        referenceFields.map(\.displayTitle)
    }
    func testingReferenceValue(genotype: String, fieldKey: String) -> String? {
        referenceRecords[genotype]?[fieldKey]
    }
    func testingSetReferenceColumnVisible(fieldKey: String, visible: Bool) {
        setReferenceColumnVisible(fieldKey, visible: visible)
    }
    var testingVisibleSampleReadTitles: [String] {
        visibleSampleNames.map { sampleReadTitleByName[$0] ?? "" }
    }
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
        selectedRowID = row.id
        selectRowIndexes(IndexSet(integer: rowIndex), byExtendingSelection: false)
        scrollRowToVisibleInBothTables(rowIndex)
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
        selectRowIndexes(IndexSet(integer: rowIndex), byExtendingSelection: false)
        scrollRowToVisibleInBothTables(rowIndex)
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

    func testingClickCell(
        genotype: String,
        sample: String,
        modifiers: NSEvent.ModifierFlags = []
    ) {
        guard let rowIndex = visibleRows.firstIndex(where: { $0.genotype == genotype }),
              let columnIndex = tableView.tableColumns.firstIndex(where: { sampleColumnLookup[$0.identifier] == sample }) else {
            onSelectionCleared?()
            return
        }
        _ = handleCellClick(row: rowIndex, column: columnIndex, modifiers: modifiers)
    }

    func testingClickRowChiclet(
        genotype: String,
        modifiers: NSEvent.ModifierFlags = []
    ) {
        guard let rowIndex = visibleRows.firstIndex(where: { $0.genotype == genotype }),
              let columnIndex = pinnedTableView.tableColumns.firstIndex(where: { $0.identifier == ColumnID.rowSelector }) else {
            onSelectionCleared?()
            return
        }
        _ = handlePinnedCellClick(row: rowIndex, column: columnIndex, modifiers: modifiers)
    }

    func testingClickColumnChiclet(
        sample: String,
        modifiers: NSEvent.ModifierFlags = []
    ) {
        guard let columnIndex = tableView.tableColumns.firstIndex(where: { sampleColumnLookup[$0.identifier] == sample }) else {
            onSelectionCleared?()
            return
        }
        _ = handleHeaderChicletClick(column: columnIndex, modifiers: modifiers)
    }

    func testingClickSelectAllChiclet() {
        guard let columnIndex = pinnedTableView.tableColumns.firstIndex(where: { $0.identifier == ColumnID.rowSelector }) else {
            onSelectionCleared?()
            return
        }
        _ = handlePinnedHeaderChicletClick(column: columnIndex, modifiers: [])
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

    func testingShowsSupportSelectionPreviewBorder(genotype: String, sample: String) -> Bool {
        guard let row = visibleRows.first(where: { $0.genotype == genotype }),
              let identifier = sampleColumnLookup.first(where: { $0.value == sample })?.key else {
            return false
        }
        return showsSupportSelectionPreviewBorder(identifier: identifier, row: row)
    }

    func testingDrawsMatrixCellSelectionFocus(genotype: String, sample: String) -> Bool {
        guard let row = visibleRows.first(where: { $0.genotype == genotype }),
              let identifier = sampleColumnLookup.first(where: { $0.value == sample })?.key else {
            return false
        }
        return drawsMatrixCellSelectionFocus(identifier: identifier, row: row)
    }

    func testingSetSupportSelectionPreviewMinimumReads(_ minimumReads: Int) {
        setSupportSelectionPreviewMinimumReads(minimumReads)
    }

    func testingSelectSupportedCellsInSelectedRow(minimumReads: Int) -> [GenotypeAnnotationSidecar.MatrixTarget] {
        selectSupportedCellsInSelectedRow(minimumReads: minimumReads)
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
            for column in pinnedTableView.tableColumns {
                _ = self.tableView(pinnedTableView, viewFor: column, row: row)
            }
            for column in tableView.tableColumns {
                _ = self.tableView(tableView, viewFor: column, row: row)
            }
        }
    }

    func testingSetFilter(_ text: String) {
        setFilterText(text)
    }

    var testingActiveSortDescriptorKey: String? {
        activeSortDescriptors.first?.key
    }

    var testingStableClusterIDSortKey: String { ColumnID.stableClusterID.rawValue }

    func testingSortKey(forSample sample: String) -> String? {
        sampleColumnLookup.first(where: { $0.value == sample })?.key.rawValue
    }

    func testingSetSortDescriptor(key: String, ascending: Bool) {
        activeSortDescriptors = [NSSortDescriptor(key: key, ascending: ascending)]
        syncSortDescriptorsToTables()
        applyFilterAndSort()
    }
}
#endif
