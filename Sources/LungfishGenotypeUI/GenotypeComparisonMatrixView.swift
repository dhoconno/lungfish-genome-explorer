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

#if DEBUG
struct GenotypeMatrixProjectionPerformanceSnapshot: Equatable {
    let baseProjectionBuildCount: Int
    let derivedProjectionPassCount: Int
    let derivedProjectionTotalSeconds: TimeInterval
    let derivedProjectionMaximumSeconds: TimeInterval
    let commitToVisibleCount: Int
    let commitToVisibleTotalSeconds: TimeInterval
    let commitToVisibleMaximumSeconds: TimeInterval
    let columnRebuildCount: Int
    let pinnedFullReloadCount: Int
    let sampleFullReloadCount: Int
}

struct GenotypeMatrixSemanticScrollSnapshot: Equatable {
    let rowID: GenotypeCandidateMatrixRowID?
    let withinRowOffset: CGFloat
    let sampleHorizontalOrigin: CGFloat
}
#endif

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
    var onMatrixReviewRequested: ((GenotypeMatrixReviewRequest) -> Void)?
    var onMatrixCommentEditRequested: ((GenotypeMatrixCommentEditRequest) -> Void)?
    var onSelectionCleared: (() -> Void)?
    var onDisplaySummaryChanged: ((Int, Int, Int) -> Void)?
    var matrixCommentBodyProvider: ((String?) -> String?)?
    private var contextMenuSnapshotSourceFactory:
        (GenotypeMatrixContextMenuSnapshot) -> any GenotypeMatrixContextMenuSnapshotProviding = {
            GenotypeMatrixImmutableContextMenuSnapshotSource(snapshot: $0)
        }
    private(set) var matrixReviewCapability = GenotypeMatrixReviewCapability.evaluate(
        selection: [],
        evidence: .init(),
        reviews: [],
        comments: [],
        isWritable: false
    )

    private let filterField = NSSearchField()
    private let locusPopup = NSPopUpButton()
    private let reviewLegend = NSTextField(labelWithString: "")
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
    private var typographyBaselineColumnWidths: [String: CGFloat] = [:]
    private var typographyBaselineColumnMinWidths: [String: CGFloat] = [:]
    private var contentTypographyObservation: ContentTypographyViewObservation?
    private var contentPreferredFontProvider: any ContentPreferredFontProviding =
        AppKitContentPreferredFontProvider()
    private var filterHeightConstraint: NSLayoutConstraint?
    private var reviewLegendHeightConstraint: NSLayoutConstraint?
    private var isApplyingContentTypography = false
    private struct TypographyScrollAnchor {
        let row: Int
        let withinRowOffset: CGFloat
        let horizontalOrigin: CGFloat
    }
    private struct SemanticScrollAnchor {
        let rowID: GenotypeCandidateMatrixRowID
        let previousRowIndex: Int
        let previousRowIDs: [GenotypeCandidateMatrixRowID]
        let withinRowOffset: CGFloat
        let pinnedHorizontalOrigin: CGFloat
        let sampleHorizontalOrigin: CGFloat
    }
    private let columnDefaults = UserDefaults.standard
    private static let pinnedPaneWidthKey = "GenotypeMatrix.pinnedPaneWidth"
    private var displayState = GenotypeResultDisplayState()
    private var baseProjection: GenotypeMatrixBaseProjection?
    private var metadataStore: SampleMetadataStore?
    private var allRows: [GenotypeCandidateMatrixRow] = []
    private var visibleRows: [GenotypeCandidateMatrixRow] = []
    private var visibleRowIndexByKey: [RowKey: Int] = [:]
    private var visibleRowIndexByID: [GenotypeCandidateMatrixRowID: Int] = [:]
    private var sampleNames: [String] = []
    /// FULL filtered logical sample set. Read PERVASIVELY by export
    /// (`exportSnapshot`), annotation-target computation (`selectAllVisibleRowsAndColumns`,
    /// `isAllVisibleRowsAndColumnsSelected`), support-cell selection, sort, and
    /// selection. This is the caller-visible logical set and is NEVER replaced by
    /// the display window.
    private var visibleSampleNames: [String] = []
    private var sampleColumnLookup: [NSUserInterfaceItemIdentifier: String] = [:]
    private var sampleColumnIdentifierByName: [String: NSUserInterfaceItemIdentifier] = [:]
    private var visibleColumnIndexBySample: [String: Int] = [:]
    private var sampleReadTitleByName: [String: String] = [:]
    private var supportByRowAndSample: [GenotypeCandidateMatrixRowID: [String: ONTGenotypeSampleSupport]] = [:]
    private var selectedGenotype: String?
    private var selectedSampleName: String?
    private var selectedRowLocus: String?
    private var selectedRowID: GenotypeCandidateMatrixRowID?
    private var candidateDisplaySettings = ONTMHCCandidateDisplaySettings.default
    private var selectedMatrixTargets: [GenotypeAnnotationSidecar.MatrixTarget] = [] {
        didSet {
            selectedMatrixTargetSet = Set(selectedMatrixTargets)
        }
    }
    private var selectedMatrixTargetSet: Set<GenotypeAnnotationSidecar.MatrixTarget> = []
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
    private var sidecarCellComments: [CellKey: String] = [:]
    private var sidecarRowComments: [RowKey: String] = [:]
    private var sidecarColumnComments: [String: String] = [:]
    private var sidecarCellCommentTooltips: [CellKey: String] = [:]
    private var sidecarRowCommentTooltips: [RowKey: String] = [:]
    private var sidecarColumnCommentTooltips: [String: String] = [:]
    private var sidecarCellReviews: [
        CellKey: GenotypeAnnotationSidecar.MatrixReviewAnnotation
    ] = [:]
#if DEBUG
    private var testingLastReloadTargets: [GenotypeAnnotationSidecar.MatrixTarget] = []
    private var testingIncreaseContrastOverride: Bool?
    private var testingBaseProjectionBuildCount = 0
    private var testingDerivedProjectionPassCount = 0
    private var testingDerivedProjectionTotalSeconds: TimeInterval = 0
    private var testingDerivedProjectionMaximumSeconds: TimeInterval = 0
    private var testingCommitToVisibleCount = 0
    private var testingCommitToVisibleTotalSeconds: TimeInterval = 0
    private var testingCommitToVisibleMaximumSeconds: TimeInterval = 0
    private var testingColumnRebuildCount = 0
    private var testingVisibleSettlementGeneration = 0
#endif

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
        rebuildBaseProjection()
        rebuildColumns()
        applyDefaultSortDescriptor()
        applyFilterAndSort()
    }

    func applyDisplayState(_ state: GenotypeResultDisplayState) {
        let previousState = displayState
        let previousSamples = activeSampleNames()
        let previousEffectiveCandidateSettings = effectiveCandidateDisplaySettings
        displayState = state
        let nextEffectiveCandidateSettings = effectiveCandidateDisplaySettings
        let candidateVisibilityDidChange = candidateVisibilityChanged(
            from: previousEffectiveCandidateSettings,
            to: nextEffectiveCandidateSettings
        )
        let candidateTintDidChange =
            previousEffectiveCandidateSettings.tints
                != nextEffectiveCandidateSettings.tints

        if candidateVisibilityDidChange {
            rebuildBaseProjection()
        } else if state.requiresMatrixDerivedProjection(comparedTo: previousState) {
            applyDerivedProjection()
        }

        if activeSampleNames() != previousSamples {
            rebuildColumns()
            applyDefaultSortDescriptor()
        }

        if candidateVisibilityDidChange
            || state.requiresMatrixFilterPass(comparedTo: previousState) {
            applyFilterAndSort()
            if candidateTintDidChange {
                reloadVisibleMatrix()
            }
        } else if nextEffectiveCandidateSettings != previousEffectiveCandidateSettings
                    || state.requiresMatrixRedraw(comparedTo: previousState) {
            reloadVisibleMatrix()
            onDisplaySummaryChanged?(visibleRows.count, totalRowCount, hiddenCellCount)
        }
    }

    func applyAnnotationSidecar(
        _ sidecar: GenotypeAnnotationSidecar?,
        reload: Bool = true,
        reloading targets: [GenotypeAnnotationSidecar.MatrixTarget]? = nil
    ) {
        let previousEffectiveCandidateDisplaySettings = effectiveCandidateDisplaySettings
        candidateDisplaySettings = sidecar?.settings.mhcCandidateDisplay ?? .default
        sidecarCellStyles = [:]
        sidecarRowStyles = [:]
        sidecarColumnStyles = [:]
        sidecarCellComments = [:]
        sidecarRowComments = [:]
        sidecarColumnComments = [:]
        sidecarCellCommentTooltips = [:]
        sidecarRowCommentTooltips = [:]
        sidecarColumnCommentTooltips = [:]
        sidecarCellReviews = [:]
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
        let resolvedComments = sidecar?.resolvedMatrixComments ?? [:]
        for comment in resolvedComments.values {
            switch comment.target {
            case let .row(locus, genotype, stableClusterID):
                let key = RowKey(locus: locus, genotype: genotype, stableClusterID: stableClusterID)
                sidecarRowComments[key] = comment.body
                sidecarRowCommentTooltips[key] = "Allele Row: \(comment.body)"
            case let .column(sample):
                sidecarColumnComments[sample] = comment.body
                sidecarColumnCommentTooltips[sample] = "Sample Column: \(comment.body)"
            case let .cell(locus, genotype, sample, stableClusterID):
                let key = CellKey(
                    locus: locus,
                    genotype: genotype,
                    sample: sample,
                    stableClusterID: stableClusterID
                )
                sidecarCellComments[key] = comment.body
                sidecarCellCommentTooltips[key] = "Cell: \(comment.body)"
            }
        }
        for review in sidecar?.matrixReviews ?? [] {
            guard case let .cell(locus, genotype, sample, stableClusterID) = review.target else {
                continue
            }
            sidecarCellReviews[CellKey(
                locus: locus,
                genotype: genotype,
                sample: sample,
                stableClusterID: stableClusterID
            )] = review
        }
        updateColumnCommentMetadata()
        let nextEffectiveCandidateDisplaySettings = effectiveCandidateDisplaySettings
        if reload,
           candidateVisibilityChanged(
               from: previousEffectiveCandidateDisplaySettings,
               to: nextEffectiveCandidateDisplaySettings
        ) {
            rebuildBaseProjection()
            applyFilterAndSort()
            // Sidecar replacement may also change surviving row/cell chrome
            // (styles, comments, or reviews). It is an infrequent persistence
            // path, so redraw the visible projection after any visibility diff.
            reloadVisibleMatrix()
        } else if reload,
                  nextEffectiveCandidateDisplaySettings
                    != previousEffectiveCandidateDisplaySettings {
            reloadVisibleMatrix()
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

    func applyMatrixReviewCapability(_ capability: GenotypeMatrixReviewCapabilityState) {
        matrixReviewCapability = capability
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
                stableClusterID: row.stableClusterID,
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

        reviewLegend.translatesAutoresizingMaskIntoConstraints = false
        reviewLegend.stringValue = "[n] False positive   ▣ False negative   ◥ Comment"
        reviewLegend.font = .systemFont(ofSize: 10)
        reviewLegend.textColor = .secondaryLabelColor
        reviewLegend.lineBreakMode = .byTruncatingTail
        reviewLegend.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        reviewLegend.setAccessibilityIdentifier("genotype-matrix-review-legend")
        reviewLegend.setAccessibilityLabel(
            "Matrix review legend: bracketed read count means false positive; inner frame means false negative; folded corner means comment."
        )
        addSubview(reviewLegend)

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
        pinnedTableView.onContextMenuRequest = { [weak self] row, _ in
            guard let self, row >= 0, row < self.visibleRows.count else { return nil }
            return self.contextMenu(for: self.matrixTarget(row: self.visibleRows[row], sample: nil))
        }
        tableView.onCellClick = { [weak self] row, column, modifiers in
            self?.handleCellClick(row: row, column: column, modifiers: modifiers) ?? false
        }
        tableView.onContextMenuRequest = { [weak self] row, column in
            guard let self,
                  row >= 0,
                  row < self.visibleRows.count,
                  let sample = self.sampleName(forColumnAt: column) else {
                return nil
            }
            return self.contextMenu(for: self.matrixTarget(row: self.visibleRows[row], sample: sample))
        }

        let pinnedHeaderView = GenotypeMatrixHeaderView()
        pinnedHeaderView.titleFont = { [weak self] in
            self?.resolvedContentTypography().font(for: .tableHeader)
                ?? .systemFont(ofSize: 11, weight: .semibold)
        }
        pinnedHeaderView.readFont = { [weak self] in
            self?.resolvedContentTypography().font(for: .caption)
                ?? .monospacedDigitSystemFont(ofSize: 10, weight: .regular)
        }
        pinnedHeaderView.chicletSize = { [weak self] in self?.headerChicletSize ?? 11 }
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
        headerView.titleFont = { [weak self] in
            self?.resolvedContentTypography().font(for: .tableHeader)
                ?? .systemFont(ofSize: 11, weight: .semibold)
        }
        headerView.readFont = { [weak self] in
            self?.resolvedContentTypography().font(for: .caption)
                ?? .monospacedDigitSystemFont(ofSize: 10, weight: .regular)
        }
        headerView.chicletSize = { [weak self] in self?.headerChicletSize ?? 11 }
        headerView.isColumnSelectable = { [weak self] column in
            self?.sampleName(forColumnAt: column) != nil
        }
        headerView.isColumnSelected = { [weak self] column in
            guard let self, let sample = self.sampleName(forColumnAt: column) else { return false }
            return self.selectedMatrixTargetSet.contains(.column(sample: sample))
        }
        headerView.onColumnChicletClick = { [weak self] column, modifiers in
            self?.handleHeaderChicletClick(column: column, modifiers: modifiers) ?? false
        }
        headerView.readTitleForColumn = { [weak self] column in
            self?.readTitle(forColumnAt: column, in: self?.tableView)
        }
        headerView.hasCommentForColumn = { [weak self] column in
            guard let self, let sample = self.sampleName(forColumnAt: column) else { return false }
            return self.sidecarColumnComments[sample] != nil
        }
        headerView.commentFoldSize = { [weak self] in
            self?.semanticGeometry().commentFoldSize ?? 7
        }
        headerView.onContextMenuRequest = { [weak self] column in
            guard let self, let sample = self.sampleName(forColumnAt: column) else { return nil }
            return self.contextMenu(for: .column(sample: sample))
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

        filterHeightConstraint = filterField.heightAnchor.constraint(equalToConstant: 24)
        reviewLegendHeightConstraint = reviewLegend.heightAnchor.constraint(equalToConstant: 15)
        NSLayoutConstraint.activate([
            filterField.topAnchor.constraint(equalTo: topAnchor, constant: 4),
            filterField.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            filterField.trailingAnchor.constraint(equalTo: locusPopup.leadingAnchor, constant: -8),
            filterHeightConstraint!,

            locusPopup.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            locusPopup.centerYAnchor.constraint(equalTo: filterField.centerYAnchor),
            locusPopup.widthAnchor.constraint(equalToConstant: 130),

            pinnedScrollView.topAnchor.constraint(equalTo: topAnchor),
            pinnedScrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            pinnedScrollView.bottomAnchor.constraint(equalTo: reviewLegend.topAnchor, constant: -2),

            paneDivider.topAnchor.constraint(equalTo: topAnchor),
            paneDivider.leadingAnchor.constraint(equalTo: pinnedScrollView.trailingAnchor),
            paneDivider.bottomAnchor.constraint(equalTo: reviewLegend.topAnchor, constant: -2),
            paneDivider.widthAnchor.constraint(equalToConstant: 7),

            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: paneDivider.trailingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: reviewLegend.topAnchor, constant: -2),

            reviewLegend.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            reviewLegend.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -6),
            reviewLegend.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -2),
            reviewLegendHeightConstraint!,
        ])
        let rememberedWidth = columnDefaults.double(forKey: Self.pinnedPaneWidthKey)
        pinnedWidthConstraint = pinnedScrollView.widthAnchor.constraint(equalToConstant: rememberedWidth > 0 ? rememberedWidth : 360)
        pinnedWidthConstraint?.isActive = true
        contentTypographyObservation = ContentTypographyViewObservation(
            applicator: ContentTypographyViewApplicator(excludedSubtree: { _ in true }),
            rootProvider: { [weak self] in self },
            afterApply: { [weak self] in
                self?.applyContentTypography()
            }
        )
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
#if DEBUG
        testingColumnRebuildCount += 1
#endif
        captureColumnTypographyBaselines()
        removeAllColumns(from: pinnedTableView)
        removeAllColumns(from: tableView)
        sampleColumnLookup.removeAll()
        sampleColumnIdentifierByName.removeAll()
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
            sampleColumnIdentifierByName[sample] = identifier
            addColumn(to: tableView, identifier: identifier, title: sample, width: 68, minWidth: 58, ascending: false)
        }
        rebuildVisibleColumnIndex()
        updatePinnedWidth()
        pinnedTableView.headerView?.frame.size.height = 34
        tableView.headerView?.frame.size.height = 34
        rebuildPinnedColumnMenu()
        updateColumnCommentMetadata()
        registerColumnTypographyBaselines()
        applyContentTypography()
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

    private func rebuildBaseProjection() {
        guard let result else {
            baseProjection = nil
            allRows = []
            supportByRowAndSample = [:]
            totalRowCount = 0
            hiddenCellCount = 0
            rebuildLocusPopup([])
            return
        }

        let candidateDocument = validatedMHCCandidateDocument(from: result)
        baseProjection = GenotypeMatrixBaseProjection(
            calls: result.calls,
            samples: result.samples,
            candidateDocument: candidateDocument,
            logicalSampleNames: sampleNames,
            candidateSettings: effectiveCandidateDisplaySettings,
            usesBiologicalAlleleOrder: usesBiologicalAlleleOrder
        )
#if DEBUG
        testingBaseProjectionBuildCount += 1
#endif
        applyDerivedProjection()
    }

    private func applyDerivedProjection() {
        guard let baseProjection else {
            allRows = []
            supportByRowAndSample = [:]
            supportFractionByCell = [:]
            totalRowCount = 0
            hiddenCellCount = 0
            rebuildLocusPopup([])
            return
        }
#if DEBUG
        let derivedStart = ContinuousClock.now
#endif
        let derived = baseProjection.derive(.init(
            globalMinimumPercent: displayState.activeMinimumSupportPercent,
            globalDenominator: displayState.supportDenominator,
            matrixMinimumReads: displayState.matrixMinimumReads,
            matrixMinimumPercent: displayState.matrixMinimumPercent,
            matrixDenominator: displayState.matrixPercentDenominator
        ))
        allRows = derived.rows
        totalRowCount = derived.totalRowCount
        hiddenCellCount = derived.hiddenCellCount
        rebuildSupportLookup()
        supportFractionByCell = Dictionary(uniqueKeysWithValues:
            baseProjection.supportFractions(for: displayState.supportDenominator).map {
                identity, fraction in
                (
                    CellKey(
                        locus: identity.locus,
                        genotype: identity.genotype,
                        sample: identity.sample,
                        stableClusterID: identity.stableClusterID
                    ),
                    fraction
                )
            }
        )
        rebuildLocusPopup(Set(allRows.map(\.locus)).sorted {
            $0.localizedStandardCompare($1) == .orderedAscending
        })
#if DEBUG
        let elapsed = Self.seconds(ContinuousClock.now - derivedStart)
        testingDerivedProjectionPassCount += 1
        testingDerivedProjectionTotalSeconds += elapsed
        testingDerivedProjectionMaximumSeconds = max(
            testingDerivedProjectionMaximumSeconds,
            elapsed
        )
#endif
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

    private func candidateVisibilityChanged(
        from previous: ONTMHCCandidateDisplaySettings,
        to next: ONTMHCCandidateDisplaySettings
    ) -> Bool {
        previous.showKnown != next.showKnown
            || previous.showSharedCandidates != next.showSharedCandidates
            || previous.showSingletonCandidates != next.showSingletonCandidates
    }

    private var usesBiologicalAlleleOrder: Bool {
        result?.manifest.kind == "full-length-ont-mhc-genotype"
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
              (1 ... 2).contains(artifacts.schemaVersion),
              artifacts.candidateJSON != nil,
              artifacts.candidateFASTA != nil,
              let document = result.mhcCandidates,
              isSupportedMHCCandidateDocumentSchemaVersion(document.schemaVersion) else {
            return nil
        }
        return document
    }

    private func applyFilterAndSort() {
        let semanticScrollAnchor = captureSemanticScrollAnchor()
        let previousVisibleRows = visibleRows
#if DEBUG
        let commitStart = ContinuousClock.now
#endif
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
        rebuildVisibleRowIndex()
        reloadRowsAfterProjectionChange(previousRows: previousVisibleRows)
        if bounds.width > 0, bounds.height > 0 {
            layoutSubtreeIfNeeded()
        }
        restoreSemanticScrollAnchor(semanticScrollAnchor)
        reconcileSelectionAfterFilter()
        onDisplaySummaryChanged?(visibleRows.count, totalRowCount, hiddenCellCount)
#if DEBUG
        testingVisibleSettlementGeneration &+= 1
        let settlementGeneration = testingVisibleSettlementGeneration
        DispatchQueue.main.async { [weak self] in
            guard let self,
                  self.testingVisibleSettlementGeneration == settlementGeneration else {
                return
            }
            self.layoutSubtreeIfNeeded()
            let elapsed = Self.seconds(ContinuousClock.now - commitStart)
            self.testingCommitToVisibleCount += 1
            self.testingCommitToVisibleTotalSeconds += elapsed
            self.testingCommitToVisibleMaximumSeconds = max(
                self.testingCommitToVisibleMaximumSeconds,
                elapsed
            )
        }
#endif
    }

#if DEBUG
    private static func seconds(_ duration: Duration) -> TimeInterval {
        let components = duration.components
        return TimeInterval(components.seconds)
            + TimeInterval(components.attoseconds) / 1_000_000_000_000_000_000
    }
#endif

    private func captureSemanticScrollAnchor() -> SemanticScrollAnchor? {
        guard !visibleRows.isEmpty else { return nil }
        let y = pinnedScrollView.contentView.bounds.minY
        var row = pinnedTableView.row(at: NSPoint(x: 0, y: y))
        if row < 0 {
            row = min(max(Int(floor(y / max(1, pinnedTableView.rowHeight))), 0), visibleRows.count - 1)
        }
        guard visibleRows.indices.contains(row) else { return nil }
        return SemanticScrollAnchor(
            rowID: visibleRows[row].id,
            previousRowIndex: row,
            previousRowIDs: visibleRows.map(\.id),
            withinRowOffset: y - pinnedTableView.rect(ofRow: row).minY,
            pinnedHorizontalOrigin: pinnedScrollView.contentView.bounds.minX,
            sampleHorizontalOrigin: scrollView.contentView.bounds.minX
        )
    }

    private func restoreSemanticScrollAnchor(_ anchor: SemanticScrollAnchor?) {
        guard let anchor, !visibleRows.isEmpty else { return }
        let nextIndex: Int?
        if let stableIndex = visibleRowIndexByID[anchor.rowID] {
            nextIndex = stableIndex
        } else {
            let survivingIDs = Set(visibleRows.map(\.id))
            var nearestID: GenotypeCandidateMatrixRowID?
            for distance in 1...max(1, anchor.previousRowIDs.count) {
                let successor = anchor.previousRowIndex + distance
                if anchor.previousRowIDs.indices.contains(successor),
                   survivingIDs.contains(anchor.previousRowIDs[successor]) {
                    nearestID = anchor.previousRowIDs[successor]
                    break
                }
                let predecessor = anchor.previousRowIndex - distance
                if anchor.previousRowIDs.indices.contains(predecessor),
                   survivingIDs.contains(anchor.previousRowIDs[predecessor]) {
                    nearestID = anchor.previousRowIDs[predecessor]
                    break
                }
            }
            nextIndex = nearestID.flatMap { visibleRowIndexByID[$0] }
                ?? min(anchor.previousRowIndex, visibleRows.count - 1)
        }
        guard let nextIndex else { return }
        let proposedY = pinnedTableView.rect(ofRow: nextIndex).minY
            + anchor.withinRowOffset
        suppressScrollSync = true
        scroll(
            pinnedScrollView,
            to: NSPoint(x: anchor.pinnedHorizontalOrigin, y: proposedY)
        )
        scroll(
            scrollView,
            to: NSPoint(x: anchor.sampleHorizontalOrigin, y: proposedY)
        )
        suppressScrollSync = false
    }

    private func scroll(_ scrollView: NSScrollView, to origin: NSPoint) {
        let clipView = scrollView.contentView
        var bounds = clipView.bounds
        bounds.origin = origin
        clipView.scroll(to: clipView.constrainBoundsRect(bounds).origin)
        scrollView.reflectScrolledClipView(clipView)
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
        if survivors.count == 1,
           let target = firstRowOrCellTarget(in: survivors),
           let rowIndex = visibleRowIndex(
               locus: target.locus,
               genotype: target.genotype,
               stableClusterID: target.stableClusterID
           ),
           visibleRows[rowIndex].population != .known {
            let row = visibleRows[rowIndex]
            onCandidateRowSelected?(row, target.sample, survivors)
            return
        }
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

    private func compare(
        _ lhs: GenotypeCandidateMatrixRow,
        _ rhs: GenotypeCandidateMatrixRow,
        key: String,
        ascending: Bool
    ) -> Bool {
        let ordered: ComparisonResult
        if isBiologicalAlleleSortKey(key) {
            ordered = MHCAlleleDisplayOrder.compare(
                biologicalAlleleDisplayName(for: lhs),
                biologicalAlleleDisplayName(for: rhs),
                lhsStableID: lhs.biologicalSortTieID,
                rhsStableID: rhs.biologicalSortTieID
            )
        } else {
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

    private func isBiologicalAlleleSortKey(_ key: String) -> Bool {
        guard usesBiologicalAlleleOrder else { return false }
        if key == ColumnID.genotype.rawValue { return true }
        guard let alleleFieldKey else { return false }
        return key == ColumnID.reference(alleleFieldKey).rawValue
    }

    private func biologicalAlleleDisplayName(for row: GenotypeCandidateMatrixRow) -> String {
        guard row.population == .known, let alleleFieldKey else { return row.alleleName }
        let value = referenceRecords[row.alleleName]?[alleleFieldKey] ?? ""
        return value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? row.alleleName : value
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
        guard !isApplyingContentTypography else { return }
        guard let resizedTable = notification.object as? NSTableView,
              resizedTable === pinnedTableView || resizedTable === tableView else {
            return
        }
        captureColumnTypographyBaselines(in: resizedTable)
        guard resizedTable === pinnedTableView else { return }
        var widths = restoredColumnWidths
        for column in pinnedTableView.tableColumns where column.identifier != ColumnID.rowSelector {
            widths[column.identifier.rawValue] =
                typographyBaselineColumnWidths[column.identifier.rawValue] ?? column.width
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
            let hasNativeRowComment = isNativeRowCommentMarkerColumn(identifier)
                && !commentsForRow(sharedCall).isEmpty
            cell.configure(
                isSelected: isSelectedCell(identifier: identifier, row: sharedCall),
                commentFoldSize: hasNativeRowComment ? semanticGeometry().commentFoldSize : nil
            )
            cell.toolTip = rowTooltip(
                row: sharedCall,
                fallback: "Select \(sharedCall.genotype)"
            )
            cell.setAccessibilityLabel(
                hasNativeRowComment
                    ? rowAccessibilityLabel(sharedCall)
                    : "Select allele row \(sharedCall.genotype)"
            )
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
        field.setAccessibilityElement(true)
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
        cell.setAccessibilityElement(true)
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
                let toolTip = key == alleleFieldKey
                    ? rowTooltip(row: row, fallback: text)
                    : (text.isEmpty ? nil : text)
                return (text, .left, toolTip)
            }
            guard let sample = sampleColumnLookup[identifier] else {
                return ("", .right, nil)
            }
            guard let support = support(for: sample, row: row) else {
                let text = reviewDisposition(for: sample, row: row) == .falseNegative ? "—" : ""
                return (text, .right, matrixTooltip(sample: sample, row: row, base: nil))
            }
            let text = reviewDisposition(for: sample, row: row) == .falsePositive
                ? "[\(integer(support.passedUniqueReads))]"
                : integer(support.passedUniqueReads)
            return (
                text,
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

    private func isNativeRowCommentMarkerColumn(
        _ identifier: NSUserInterfaceItemIdentifier
    ) -> Bool {
        if pinnedTableView.tableColumns.contains(where: { $0.identifier == ColumnID.genotype }) {
            return identifier == ColumnID.genotype
        }
        if let alleleFieldKey,
           pinnedTableView.tableColumns.contains(where: {
               $0.identifier == ColumnID.reference(alleleFieldKey)
           }) {
            return identifier == ColumnID.reference(alleleFieldKey)
        }
        if pinnedTableView.tableColumns.contains(where: { $0.identifier == ColumnID.locus }) {
            return identifier == ColumnID.locus
        }
        return identifier == pinnedTableView.tableColumns.first?.identifier
    }

    private func support(for sample: String, row: GenotypeCandidateMatrixRow) -> ONTGenotypeSampleSupport? {
        supportByRowAndSample[row.id]?[sample]
    }

    private func reviewDisposition(
        for sample: String,
        row: GenotypeCandidateMatrixRow
    ) -> GenotypeAnnotationSidecar.MatrixReviewDisposition? {
        let legacyKey = CellKey(
            locus: row.locus,
            genotype: row.genotype,
            sample: sample
        )
        let exactKey = CellKey(
            locus: row.locus,
            genotype: row.genotype,
            sample: sample,
            stableClusterID: row.stableClusterID
        )
        if row.stableClusterID != nil {
            return sidecarCellReviews[exactKey]?.disposition
        }
        return sidecarCellReviews[legacyKey]?.disposition
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
        var lines = [fallback]
        if let stableClusterID = row.stableClusterID {
            lines.append("Stable cluster ID: \(stableClusterID)")
        }
        lines.append(contentsOf: cachedRowCommentTooltips(row))
        return lines.joined(separator: "\n")
    }

    private func matrixTooltip(sample: String, row: GenotypeCandidateMatrixRow, base: String?) -> String? {
        var lines: [String] = []
        if let base, !base.isEmpty {
            lines.append(base)
        }
        lines.append(contentsOf: cachedRowCommentTooltips(row))
        if let column = sidecarColumnCommentTooltips[sample] {
            lines.append(column)
        }
        lines.append(contentsOf: cachedCellCommentTooltips(row, sample: sample))
        return lines.isEmpty ? nil : lines.joined(separator: "\n")
    }

    private func cachedRowCommentTooltips(_ row: GenotypeCandidateMatrixRow) -> [String] {
        let legacyKey = RowKey(locus: row.locus, genotype: row.genotype)
        let exactKey = RowKey(
            locus: row.locus,
            genotype: row.genotype,
            stableClusterID: row.stableClusterID
        )
        var tooltips = sidecarRowCommentTooltips[legacyKey].map { [$0] } ?? []
        if exactKey != legacyKey, let exact = sidecarRowCommentTooltips[exactKey] {
            tooltips.append(exact)
        }
        return tooltips
    }

    private func cachedCellCommentTooltips(
        _ row: GenotypeCandidateMatrixRow,
        sample: String
    ) -> [String] {
        let legacyKey = CellKey(locus: row.locus, genotype: row.genotype, sample: sample)
        let exactKey = CellKey(
            locus: row.locus,
            genotype: row.genotype,
            sample: sample,
            stableClusterID: row.stableClusterID
        )
        var tooltips = sidecarCellCommentTooltips[legacyKey].map { [$0] } ?? []
        if exactKey != legacyKey, let exact = sidecarCellCommentTooltips[exactKey] {
            tooltips.append(exact)
        }
        return tooltips
    }

    private func commentsForRow(_ row: GenotypeCandidateMatrixRow) -> [String] {
        let legacy = sidecarRowComments[RowKey(locus: row.locus, genotype: row.genotype)]
            .map { [$0] } ?? []
        guard let stableClusterID = row.stableClusterID else { return legacy }
        return legacy + (sidecarRowComments[
            RowKey(locus: row.locus, genotype: row.genotype, stableClusterID: stableClusterID)
        ].map { [$0] } ?? [])
    }

    private func commentsForCell(_ row: GenotypeCandidateMatrixRow, sample: String) -> [String] {
        let legacy = sidecarCellComments[
            CellKey(locus: row.locus, genotype: row.genotype, sample: sample)
        ].map { [$0] } ?? []
        guard let stableClusterID = row.stableClusterID else { return legacy }
        return legacy + (sidecarCellComments[
            CellKey(locus: row.locus, genotype: row.genotype, sample: sample, stableClusterID: stableClusterID)
        ].map { [$0] } ?? [])
    }

    private func integer(_ value: Int) -> String {
        value.formatted(.number)
    }

    private func contextMenu(
        for target: GenotypeAnnotationSidecar.MatrixTarget
    ) -> NSMenu? {
        guard let snapshot = prepareContextMenuSnapshot(for: target) else { return nil }
        return makeContextMenu(
            using: contextMenuSnapshotSourceFactory(snapshot)
        )
    }

    private func prepareContextMenuSnapshot(
        for target: GenotypeAnnotationSidecar.MatrixTarget
    ) -> GenotypeMatrixContextMenuSnapshot? {
        guard isVisibleContextTarget(target) else { return nil }
        if !contextTargetIsInsideSelection(target) {
            publishMatrixTargetSelection([target], anchor: target)
        }
        return makeContextMenuSnapshot()
    }

    private func isVisibleContextTarget(
        _ target: GenotypeAnnotationSidecar.MatrixTarget
    ) -> Bool {
        switch target {
        case let .row(locus, genotype, stableClusterID):
            return visibleRowIndex(
                locus: locus,
                genotype: genotype,
                stableClusterID: stableClusterID
            ) != nil
        case let .column(sample):
            return visibleColumnIndex(sample: sample) != nil
        case let .cell(locus, genotype, sample, stableClusterID):
            return visibleRowIndex(
                locus: locus,
                genotype: genotype,
                stableClusterID: stableClusterID
            ) != nil && visibleColumnIndex(sample: sample) != nil
        }
    }

    private func contextTargetIsInsideSelection(
        _ target: GenotypeAnnotationSidecar.MatrixTarget
    ) -> Bool {
        if selectedMatrixTargetSet.contains(target) {
            return true
        }
        guard case let .cell(locus, genotype, sample, stableClusterID) = target else {
            return false
        }
        guard let rowIndex = visibleRowIndex(
            locus: locus,
            genotype: genotype,
            stableClusterID: stableClusterID
        ) else {
            return false
        }
        return selectedTargetsContainRow(visibleRows[rowIndex])
            || selectedMatrixTargetSet.contains(.column(sample: sample))
    }

    private func makeContextMenuSnapshot() -> GenotypeMatrixContextMenuSnapshot {
        GenotypeMatrixContextMenuSnapshot(
            selectionTargets: selectedMatrixTargets,
            capability: matrixReviewCapability,
            keyModifierRawValue: NSEvent.ModifierFlags([.command, .option]).rawValue
        )
    }

    private func makeContextMenuState() -> GenotypeMatrixContextMenuState {
        GenotypeMatrixContextMenuBuilder.make(snapshot: makeContextMenuSnapshot())
    }

    private func makeContextMenu(
        using snapshotSource: any GenotypeMatrixContextMenuSnapshotProviding
    ) -> NSMenu {
        makeContextMenu(from: GenotypeMatrixContextMenuBuilder.make(
            snapshot: snapshotSource.cachedSnapshot
        ))
    }

    private func makeContextMenu(from state: GenotypeMatrixContextMenuState) -> NSMenu {
        let menu = NSMenu(title: "Matrix Review")
        menu.autoenablesItems = false
        for itemState in state.items {
            if itemState.command == .editComment || itemState.command == .selectSupportedCells {
                menu.addItem(.separator())
            }
            let item = NSMenuItem(
                title: itemState.title,
                action: #selector(performMatrixContextMenuCommand(_:)),
                keyEquivalent: itemState.keyEquivalent
            )
            item.target = self
            item.representedObject = NSNumber(value: itemState.command.rawValue)
            item.keyEquivalentModifierMask = NSEvent.ModifierFlags(
                rawValue: itemState.keyModifierRawValue
            )
            item.isEnabled = itemState.availability.isEnabled
            item.toolTip = itemState.availability.disabledReason
            menu.addItem(item)
        }
        return menu
    }

    @objc private func performMatrixContextMenuCommand(_ sender: NSMenuItem) {
        guard let value = sender.representedObject as? NSNumber,
              let command = GenotypeMatrixContextCommand(rawValue: value.intValue) else {
            return
        }
        _ = performContextCommand(command)
    }

    @discardableResult
    private func performContextCommand(_ command: GenotypeMatrixContextCommand) -> Bool {
        let state = makeContextMenuState()
        guard let item = state.items.first(where: { $0.command == command }),
              item.availability.isEnabled else {
            return false
        }
        let targets = selectedMatrixTargets
        guard !targets.isEmpty else { return false }
        switch command {
        case .markFalsePositive:
            onMatrixReviewRequested?(.init(targets: targets, intent: .set(.falsePositive)))
        case .markFalseNegative:
            onMatrixReviewRequested?(.init(targets: targets, intent: .set(.falseNegative)))
        case .clearReview:
            onMatrixReviewRequested?(.init(targets: targets, intent: .clear))
        case .editComment:
            let currentBody: String?
            switch matrixReviewCapability.commentState {
            case let .uniform(body):
                currentBody = body
            case .none, .mixed:
                currentBody = nil
            }
            let requestedBody: String?
            if let matrixCommentBodyProvider {
                requestedBody = matrixCommentBodyProvider(currentBody)
            } else {
                requestedBody = requestCommentBody(currentBody: currentBody)
            }
            guard let body = requestedBody?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !body.isEmpty else {
                return false
            }
            let intent: GenotypeMatrixCommentEditRequest.Intent
            if targets.count > 1, matrixReviewCapability.commentState != .none {
                intent = .replace(body: body)
            } else {
                intent = .upsert(body: body)
            }
            onMatrixCommentEditRequested?(.init(targets: targets, intent: intent))
        case .removeComments:
            onMatrixCommentEditRequested?(.init(targets: targets, intent: .remove))
        case .selectSupportedCells:
            let supported = supportedCellTargets(from: targets, minimumReads: 1)
            publishMatrixTargetSelection(supported, anchor: supported.last)
        }
        return true
    }

    private func requestCommentBody(currentBody: String?) -> String? {
        let alert = NSAlert()
        alert.messageText = currentBody == nil ? "Add Matrix Comment" : "Edit Matrix Comment"
        alert.informativeText = "The comment applies to the current matrix selection."
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        let field = NSTextField(string: currentBody ?? "")
        field.placeholderString = "Comment"
        field.frame = NSRect(x: 0, y: 0, width: 340, height: 24)
        alert.accessoryView = field
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        return field.stringValue
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let state = makeContextMenuState()
        if let item = state.items.first(where: {
            !$0.keyEquivalent.isEmpty
                && $0.keyEquivalent == event.charactersIgnoringModifiers?.lowercased()
                && NSEvent.ModifierFlags(rawValue: $0.keyModifierRawValue) == modifiers
        }) {
            return performContextCommand(item.command)
        }
        return super.performKeyEquivalent(with: event)
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

    private func reloadRowsAfterProjectionChange(
        previousRows: [GenotypeCandidateMatrixRow]
    ) {
        let wasSuppressingSelectionCallbacks = suppressSelectionClearedCallback
        suppressSelectionClearedCallback = true
        defer {
            suppressSelectionClearedCallback = wasSuppressingSelectionCallbacks
        }
        let previousIDs = previousRows.map(\.id)
        let nextIDs = visibleRows.map(\.id)
        let previousByID = Dictionary(uniqueKeysWithValues:
            previousRows.map { ($0.id, $0) }
        )
        let changedNextIndexes = IndexSet(
            visibleRows.indices.filter { index in
                previousByID[visibleRows[index].id] != visibleRows[index]
            }
        )
        let nextIDSet = Set(nextIDs)
        let previousIDSet = Set(previousIDs)
        let isDeletionOnly = previousIDs.filter(nextIDSet.contains) == nextIDs
        let isInsertionOnly = nextIDs.filter(previousIDSet.contains) == previousIDs
        let removedIndexes = IndexSet(
            previousIDs.indices.filter { !nextIDSet.contains(previousIDs[$0]) }
        )
        let insertedIndexes = IndexSet(
            nextIDs.indices.filter { !previousIDSet.contains(nextIDs[$0]) }
        )

        for matrixTableView in [pinnedTableView, tableView] {
            if isDeletionOnly, !removedIndexes.isEmpty {
                matrixTableView.beginUpdates()
                matrixTableView.removeRows(
                    at: removedIndexes,
                    withAnimation: []
                )
                matrixTableView.endUpdates()
            } else if isInsertionOnly, !insertedIndexes.isEmpty {
                matrixTableView.beginUpdates()
                matrixTableView.insertRows(
                    at: insertedIndexes,
                    withAnimation: []
                )
                matrixTableView.endUpdates()
            } else if previousIDs != nextIDs {
                matrixTableView.noteNumberOfRowsChanged()
            }
            guard matrixTableView.numberOfRows > 0,
                  matrixTableView.numberOfColumns > 0 else {
                continue
            }
            if previousIDs == nextIDs
                || isDeletionOnly
                || isInsertionOnly {
                let validChangedIndexes = changedNextIndexes.intersection(
                    IndexSet(integersIn: 0..<matrixTableView.numberOfRows)
                )
                guard !validChangedIndexes.isEmpty else { continue }
                matrixTableView.reloadData(
                    forRowIndexes: validChangedIndexes,
                    columnIndexes: IndexSet(
                        integersIn: 0..<matrixTableView.numberOfColumns
                    )
                )
                continue
            }
            let visibleRange = matrixTableView.rows(in: matrixTableView.visibleRect)
            guard visibleRange.location != NSNotFound else { continue }
            let lowerBound = max(0, visibleRange.location)
            let upperBound = min(
                matrixTableView.numberOfRows,
                visibleRange.location + visibleRange.length
            )
            guard lowerBound < upperBound else { continue }
            matrixTableView.reloadData(
                forRowIndexes: IndexSet(integersIn: lowerBound..<upperBound),
                columnIndexes: IndexSet(
                    integersIn: 0..<matrixTableView.numberOfColumns
                )
            )
        }
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
#if DEBUG
        testingLastReloadTargets = targets
#endif
        guard !targets.isEmpty else { return }
        var pinnedRowIndexes = IndexSet()
        var broadRowTargetIndexes = IndexSet()
        var broadColumnTargetIndexes = IndexSet()
        var exactSampleColumnsByRow: [Int: IndexSet] = [:]
        let pinnedAllColumns = IndexSet(integersIn: 0..<pinnedTableView.numberOfColumns)
        let sampleAllColumns = IndexSet(integersIn: 0..<tableView.numberOfColumns)

        for target in targets {
            switch target {
            case let .row(locus, genotype, stableClusterID):
                if let rowIndex = visibleRowIndex(locus: locus, genotype: genotype, stableClusterID: stableClusterID) {
                    pinnedRowIndexes.insert(rowIndex)
                    broadRowTargetIndexes.insert(rowIndex)
                }
            case let .column(sample):
                if let columnIndex = visibleColumnIndex(sample: sample), tableView.numberOfRows > 0 {
                    broadColumnTargetIndexes.insert(columnIndex)
                }
            case let .cell(locus, genotype, sample, stableClusterID):
                if let rowIndex = visibleRowIndex(locus: locus, genotype: genotype, stableClusterID: stableClusterID),
                   let columnIndex = visibleColumnIndex(sample: sample) {
                    exactSampleColumnsByRow[rowIndex, default: []].insert(columnIndex)
                }
            }
        }

        if !pinnedRowIndexes.isEmpty, !pinnedAllColumns.isEmpty {
            pinnedTableView.reloadData(forRowIndexes: pinnedRowIndexes, columnIndexes: pinnedAllColumns)
        }
        if !broadRowTargetIndexes.isEmpty, !sampleAllColumns.isEmpty {
            tableView.reloadData(
                forRowIndexes: broadRowTargetIndexes,
                columnIndexes: sampleAllColumns
            )
        }
        if tableView.numberOfRows > 0, !broadColumnTargetIndexes.isEmpty {
            tableView.reloadData(
                forRowIndexes: IndexSet(integersIn: 0..<tableView.numberOfRows),
                columnIndexes: broadColumnTargetIndexes
            )
        }
        for rowIndex in exactSampleColumnsByRow.keys.sorted() {
            guard var columnIndexes = exactSampleColumnsByRow[rowIndex] else { continue }
            if broadRowTargetIndexes.contains(rowIndex) {
                continue
            }
            columnIndexes.subtract(broadColumnTargetIndexes)
            guard !columnIndexes.isEmpty else { continue }
            tableView.reloadData(
                forRowIndexes: IndexSet(integer: rowIndex),
                columnIndexes: columnIndexes
            )
        }
    }

    private func rebuildVisibleRowIndex() {
        visibleRowIndexByKey = [:]
        visibleRowIndexByID = [:]
        visibleRowIndexByKey.reserveCapacity(visibleRows.count * 2)
        visibleRowIndexByID.reserveCapacity(visibleRows.count)
        for (index, row) in visibleRows.enumerated() {
            visibleRowIndexByID[row.id] = index
            visibleRowIndexByKey[
                RowKey(
                    locus: row.locus,
                    genotype: row.genotype,
                    stableClusterID: row.stableClusterID
                )
            ] = index
            let legacyKey = RowKey(locus: row.locus, genotype: row.genotype)
            if visibleRowIndexByKey[legacyKey] == nil {
                visibleRowIndexByKey[legacyKey] = index
            }
        }
    }

    private func rebuildVisibleColumnIndex() {
        visibleColumnIndexBySample = Dictionary(
            uniqueKeysWithValues: tableView.tableColumns.enumerated().compactMap { index, column in
                sampleColumnLookup[column.identifier].map { ($0, index) }
            }
        )
    }

    private func visibleRowIndex(
        locus: String,
        genotype: String,
        stableClusterID: String? = nil
    ) -> Int? {
        visibleRowIndexByKey[
            RowKey(
                locus: locus,
                genotype: genotype,
                stableClusterID: stableClusterID
            )
        ]
    }

    private func visibleColumnIndex(sample: String) -> Int? {
        visibleColumnIndexBySample[sample]
    }

    func tableViewColumnDidMove(_ notification: Notification) {
        guard let movedTableView = notification.object as? NSTableView,
              movedTableView === tableView else {
            return
        }
        rebuildVisibleColumnIndex()
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

    private func updateColumnCommentMetadata() {
        for column in tableView.tableColumns {
            guard let sample = sampleColumnLookup[column.identifier] else { continue }
            let comment = sidecarColumnCommentTooltips[sample]
            column.headerToolTip = comment
            let count = comment == nil ? 0 : 1
            let suffix = count == 1 ? "comment" : "comments"
            column.headerCell.setAccessibilityLabel(
                "Sample column \(sample). \(count) sample column \(suffix)."
            )
        }
        tableView.headerView?.needsDisplay = true
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

    func orderedVisibleRowTargets(
        from targets: [GenotypeAnnotationSidecar.MatrixTarget]
    ) -> [GenotypeAnnotationSidecar.MatrixTarget] {
        let selectedRowIDs = Set(targets.compactMap { target -> GenotypeCandidateMatrixRowID? in
            guard case let .row(locus, genotype, stableClusterID) = target else {
                return nil
            }
            if let stableClusterID {
                return .candidate(stableClusterID: stableClusterID)
            }
            return .known(locus: locus, genotype: genotype)
        })
        return visibleRows.compactMap { row in
            selectedRowIDs.contains(row.id) ? matrixTarget(row: row, sample: nil) : nil
        }
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
        let decorativeBorderColor = borderColor(for: identifier, row: row, renderedStyle: renderedStyle)
        let selected = drawsMatrixCellSelectionFocus(identifier: identifier, row: row)
        let showsPreviewBorder = showsSupportSelectionPreviewBorder(identifier: identifier, row: row)
        let geometry = semanticGeometry()
        let semantic = sampleColumnLookup[identifier].map {
            semanticCellState(for: $0, row: row, providedRenderedStyle: renderedStyle)
        }
        let hasNativeCommentMarker: Bool
        if let semantic {
            hasNativeCommentMarker = semantic.hasNativeCellCommentMarker
        } else if isNativeRowCommentMarkerColumn(identifier) {
            hasNativeCommentMarker = !commentsForRow(row).isEmpty
        } else {
            hasNativeCommentMarker = false
        }

        cell.alphaValue = 1.0
        if semantic?.text.colorRole == .secondary {
            let fpFont = NSFontManager.shared.convert(font(for: renderedStyle), toHaveTrait: .italicFontMask)
            cell.textField?.font = fpFont
            cell.textField?.textColor = .secondaryLabelColor
        } else {
            cell.textField?.font = font(for: renderedStyle)
            cell.textField?.textColor = renderedStyle.textColor.map(Self.color(from:)) ?? .labelColor
        }
        if let semantic {
            cell.textField?.setAccessibilityLabel(semantic.accessibilityLabel)
        } else if isNativeRowCommentMarkerColumn(identifier) {
            cell.textField?.setAccessibilityLabel(rowAccessibilityLabel(row))
        } else if identifier != ColumnID.stableClusterID {
            cell.textField?.setAccessibilityLabel(nil)
        }
        (cell as? GenotypeMatrixStyledCellView)?.configureChrome(
            backgroundColor: backgroundColor,
            decorativeBorderColor: decorativeBorderColor,
            decorativeBorderWidth: decorativeBorderColor == nil ? 0 : geometry.decorativeBorderWidth,
            previewBorderColor: showsPreviewBorder ? .systemOrange : nil,
            previewBorderWidth: showsPreviewBorder ? geometry.previewBorderWidth : 0,
            semanticInnerFrameColor: semantic?.review == .falseNegative ? .systemRed : nil,
            semanticInnerFrameWidth: semantic?.chrome.semanticInnerFrameWidth ?? 0,
            selectionAccentColor: selected ? .controlAccentColor : nil,
            selectionCornerBracketWidth: semantic?.chrome.selectionCornerBracketWidth ?? 0,
            selectionCornerBracketLength: geometry.selectionCornerBracketLength,
            commentFoldColor: hasNativeCommentMarker ? .controlAccentColor : nil,
            commentFoldSize: hasNativeCommentMarker ? geometry.commentFoldSize : 0
        )
    }

    private struct SemanticGeometry {
        let decorativeBorderWidth: CGFloat
        let previewBorderWidth: CGFloat
        let semanticInnerFrameWidth: CGFloat
        let selectionCornerBracketWidth: CGFloat
        let selectionCornerBracketLength: CGFloat
        let commentFoldSize: CGFloat
    }

    private func semanticGeometry() -> SemanticGeometry {
        if accessibilityDisplayShouldIncreaseContrast {
            return SemanticGeometry(
                decorativeBorderWidth: 2,
                previewBorderWidth: 2.5,
                semanticInnerFrameWidth: 3.5,
                selectionCornerBracketWidth: 3,
                selectionCornerBracketLength: 8,
                commentFoldSize: 9
            )
        }
        return SemanticGeometry(
            decorativeBorderWidth: 1.5,
            previewBorderWidth: 2,
            semanticInnerFrameWidth: 2.5,
            selectionCornerBracketWidth: 2,
            selectionCornerBracketLength: 6,
            commentFoldSize: 7
        )
    }

    private var accessibilityDisplayShouldIncreaseContrast: Bool {
#if DEBUG
        if let testingIncreaseContrastOverride {
            return testingIncreaseContrastOverride
        }
#endif
        return NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
    }

    private func semanticCellState(
        for sample: String,
        row: GenotypeCandidateMatrixRow,
        providedRenderedStyle: GenotypeMatrixRenderedStyle? = nil
    ) -> GenotypeMatrixCellSemanticState {
        let support = support(for: sample, row: row)
        let review = reviewDisposition(for: sample, row: row)
        let value: String
        let colorRole: GenotypeMatrixSemanticTextColorRole
        let isItalic: Bool
        switch (review, support?.passedUniqueReads) {
        case let (.falsePositive, reads?):
            value = "[\(integer(reads))]"
            colorRole = .secondary
            isItalic = true
        case (.falseNegative, nil):
            value = "—"
            colorRole = .primary
            isItalic = false
        case let (_, reads?):
            value = integer(reads)
            colorRole = .primary
            isItalic = false
        case (_, nil):
            value = ""
            colorRole = .primary
            isItalic = false
        }

        let rowCommentCount = commentsForRow(row).count
        let columnCommentCount = sidecarColumnComments[sample] == nil ? 0 : 1
        let cellCommentCount = commentsForCell(row, sample: sample).count
        let counts = GenotypeMatrixScopedCommentCounts(
            alleleRow: rowCommentCount,
            sampleColumn: columnCommentCount,
            cell: cellCommentCount
        )
        let identifier = sampleColumnIdentifierByName[sample]
        let effectiveStyle = providedRenderedStyle ?? renderedStyle(for: sample, row: row)
        let decorativeVisible = identifier.map {
            borderColor(for: $0, row: row, renderedStyle: effectiveStyle) != nil
        } ?? false
        let selected = identifier.map {
            drawsMatrixCellSelectionFocus(identifier: $0, row: row)
        } ?? false
        let selectedForAccessibility = identifier.map {
            isSelectedCell(identifier: $0, row: row)
        } ?? false
        let geometry = semanticGeometry()
        let chrome = GenotypeMatrixCellChromeState(
            decorativeBorderWidth: decorativeVisible ? geometry.decorativeBorderWidth : nil,
            semanticInnerFrameWidth: review == .falseNegative ? geometry.semanticInnerFrameWidth : nil,
            selectionCornerBracketWidth: selected ? geometry.selectionCornerBracketWidth : nil,
            selectionCornerBracketLength: geometry.selectionCornerBracketLength,
            commentFoldSize: cellCommentCount > 0 ? geometry.commentFoldSize : nil
        )
        return GenotypeMatrixCellSemanticState(
            text: .init(value: value, colorRole: colorRole, isItalic: isItalic),
            evidenceReads: support?.passedUniqueReads,
            review: review,
            chrome: chrome,
            commentCounts: counts,
            hasNativeCellCommentMarker: cellCommentCount > 0,
            isSelected: selectedForAccessibility,
            accessibilityLabel: cellAccessibilityLabel(
                sample: sample,
                row: row,
                evidenceReads: support?.passedUniqueReads,
                review: review,
                isSelected: selectedForAccessibility,
                commentCounts: counts
            )
        )
    }

    private func rowAccessibilityLabel(_ row: GenotypeCandidateMatrixRow) -> String {
        let count = commentsForRow(row).count
        let suffix = count == 1 ? "comment" : "comments"
        return "Allele row \(row.genotype), locus \(row.locus). \(count) allele row \(suffix)."
    }

    private func cellAccessibilityLabel(
        sample: String,
        row: GenotypeCandidateMatrixRow,
        evidenceReads: Int?,
        review: GenotypeAnnotationSidecar.MatrixReviewDisposition?,
        isSelected: Bool,
        commentCounts: GenotypeMatrixScopedCommentCounts
    ) -> String {
        let evidence: String
        if let evidenceReads {
            evidence = "Evidence: \(integer(evidenceReads)) unique reads."
        } else {
            evidence = "Evidence: no supporting reads."
        }
        let reviewText: String
        switch review {
        case .falsePositive:
            reviewText = "Review: false positive."
        case .falseNegative:
            reviewText = "Review: false negative."
        case nil:
            reviewText = "Review: unreviewed."
        }
        let selection = isSelected ? "Selected." : "Not selected."
        return [
            "Sample \(sample), genotype \(row.genotype), locus \(row.locus).",
            evidence,
            reviewText,
            selection,
            "Comments: allele row \(commentCounts.alleleRow), sample column \(commentCounts.sampleColumn), cell \(commentCounts.cell).",
        ].joined(separator: " ")
    }

    private func drawsMatrixCellSelectionFocus(
        identifier: NSUserInterfaceItemIdentifier,
        row: GenotypeCandidateMatrixRow
    ) -> Bool {
        guard let sample = sampleColumnLookup[identifier],
              !selectedMatrixTargetSet.isEmpty else {
            return false
        }
        return selectedTargetsContainCell(row, sample: sample)
    }

    private func showsSupportSelectionPreviewBorder(
        identifier: NSUserInterfaceItemIdentifier,
        row: GenotypeCandidateMatrixRow
    ) -> Bool {
        guard let sample = sampleColumnLookup[identifier],
              selectedTargetsContainRow(row)
                || selectedMatrixTargetSet.contains(.column(sample: sample)) else {
            return false
        }
        let threshold = max(0, supportSelectionPreviewMinimumReads)
        guard let support = row.support(for: sample) else { return false }
        return support.passedUniqueReads >= threshold
    }

    private func font(for style: GenotypeMatrixRenderedStyle) -> NSFont {
        let resolved = resolvedContentTypography().font(for: .monospaced)
        let base = NSFont.monospacedDigitSystemFont(
            ofSize: resolved.pointSize,
            weight: style.isBold ? .semibold : .regular
        )
        guard style.isItalic else {
            return base
        }
        return NSFontManager.shared.convert(base, toHaveTrait: .italicFontMask)
    }

    private func resolvedContentTypography() -> ContentTypography {
        ContentTypography(
            preference: AppSettings.shared.contentTextSizePreference,
            preferredFontProvider: contentPreferredFontProvider
        )
    }

    private var contentTypographyScale: CGFloat {
        let providerBaseline = max(
            contentPreferredFontProvider.canonicalUnscaledPointSize(for: .body),
            1
        )
        return resolvedContentTypography().font(for: .body).pointSize / providerBaseline
    }

    private var headerChicletSize: CGFloat {
        min(max(11, ceil(11 * contentTypographyScale)), max(11, tableViewHeaderHeight - 8))
    }

    private func applyContentTypography() {
        let pinnedScrollAnchor = captureTypographyScrollAnchor(
            scrollView: pinnedScrollView,
            tableView: pinnedTableView
        )
        let sampleScrollAnchor = captureTypographyScrollAnchor(
            scrollView: scrollView,
            tableView: tableView
        )
        let typography = resolvedContentTypography()
        filterField.font = typography.font(for: .body)
        reviewLegend.font = typography.font(for: .caption)
        let rowHeight = typography.tableRowHeight(minimum: 22, verticalPadding: 6)
        pinnedTableView.rowHeight = rowHeight
        tableView.rowHeight = rowHeight
        let headerHeight = max(
            typography.tableHeaderHeight(minimum: 34, verticalPadding: 10),
            ceil(typography.font(for: .tableHeader).boundingRectForFont.height)
                + ceil(typography.font(for: .caption).boundingRectForFont.height)
                + 8
        )
        pinnedTableView.headerView?.frame.size.height = headerHeight
        tableView.headerView?.frame.size.height = headerHeight
        filterHeightConstraint?.constant = max(24, ceil(typography.font(for: .body).boundingRectForFont.height + 8))
        reviewLegendHeightConstraint?.constant = max(
            15,
            ceil(typography.font(for: .caption).boundingRectForFont.height + 4)
        )
        applyColumnTypography()
        for table in [pinnedTableView, tableView] {
            for column in table.tableColumns {
                column.headerCell.font = typography.font(for: .tableHeader)
            }
            table.reloadData()
            table.headerView?.needsDisplay = true
        }
        restoreTypographyScrollAnchor(
            pinnedScrollAnchor,
            scrollView: pinnedScrollView,
            tableView: pinnedTableView
        )
        restoreTypographyScrollAnchor(
            sampleScrollAnchor,
            scrollView: scrollView,
            tableView: tableView
        )
        invalidateIntrinsicContentSize()
        needsLayout = true
    }

    private func captureTypographyScrollAnchor(
        scrollView: NSScrollView,
        tableView: NSTableView
    ) -> TypographyScrollAnchor {
        let origin = scrollView.contentView.bounds.origin
        guard tableView.numberOfRows > 0 else {
            return .init(row: 0, withinRowOffset: 0, horizontalOrigin: origin.x)
        }
        let candidate = tableView.row(at: NSPoint(x: 0, y: origin.y))
        let row = min(max(candidate >= 0 ? candidate : Int(origin.y / max(tableView.rowHeight, 1)), 0),
                      tableView.numberOfRows - 1)
        return .init(
            row: row,
            withinRowOffset: origin.y - tableView.rect(ofRow: row).minY,
            horizontalOrigin: origin.x
        )
    }

    private func restoreTypographyScrollAnchor(
        _ anchor: TypographyScrollAnchor,
        scrollView: NSScrollView,
        tableView: NSTableView
    ) {
        guard tableView.numberOfRows > 0 else { return }
        tableView.layoutSubtreeIfNeeded()
        let row = min(max(anchor.row, 0), tableView.numberOfRows - 1)
        let origin = NSPoint(
            x: anchor.horizontalOrigin,
            y: tableView.rect(ofRow: row).minY + anchor.withinRowOffset
        )
        suppressScrollSync = true
        scrollView.contentView.setBoundsOrigin(origin)
        scrollView.reflectScrolledClipView(scrollView.contentView)
        suppressScrollSync = false
    }

    private var tableViewHeaderHeight: CGFloat {
        tableView.headerView?.frame.height ?? 34
    }

    private func allMatrixTables() -> [NSTableView] {
        [pinnedTableView, tableView]
    }

    private func registerColumnTypographyBaselines() {
        for table in allMatrixTables() {
            for column in table.tableColumns {
                let key = column.identifier.rawValue
                if typographyBaselineColumnWidths[key] == nil {
                    typographyBaselineColumnWidths[key] = column.width
                }
                if typographyBaselineColumnMinWidths[key] == nil {
                    typographyBaselineColumnMinWidths[key] = column.minWidth
                }
            }
        }
    }

    private func captureColumnTypographyBaselines() {
        for table in allMatrixTables() {
            captureColumnTypographyBaselines(in: table)
        }
    }

    private func captureColumnTypographyBaselines(in table: NSTableView) {
        let scale = max(contentTypographyScale, 0.01)
        for column in table.tableColumns {
            let key = column.identifier.rawValue
            typographyBaselineColumnWidths[key] = column.width / scale
            typographyBaselineColumnMinWidths[key] = column.minWidth / scale
        }
    }

    private func applyColumnTypography() {
        registerColumnTypographyBaselines()
        let scale = contentTypographyScale
        let headerFont = resolvedContentTypography().font(for: .tableHeader)
        isApplyingContentTypography = true
        defer { isApplyingContentTypography = false }
        for table in allMatrixTables() {
            for column in table.tableColumns {
                let key = column.identifier.rawValue
                let baselineWidth = typographyBaselineColumnWidths[key] ?? column.width
                let baselineMinimum = typographyBaselineColumnMinWidths[key] ?? column.minWidth
                let headerWidth = ceil(
                    (column.title as NSString).size(withAttributes: [.font: headerFont]).width + 24
                )
                let minimum = max(baselineMinimum * scale, headerWidth)
                if column.identifier == ColumnID.rowSelector {
                    column.maxWidth = max(baselineWidth * scale, minimum)
                }
                column.minWidth = minimum
                column.width = max(baselineWidth * scale, minimum)
                if column.identifier == ColumnID.rowSelector {
                    column.maxWidth = column.width
                }
            }
        }
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
        guard !selectedMatrixTargetSet.isEmpty,
              let sample = sampleColumnLookup[identifier] else {
            return false
        }
        return selectedTargetsContainRow(row)
            || selectedMatrixTargetSet.contains(.column(sample: sample))
            || selectedTargetsContainCell(row, sample: sample)
    }

    private func selectedTargetsContainRow(_ row: GenotypeCandidateMatrixRow) -> Bool {
        let exact = GenotypeAnnotationSidecar.MatrixTarget.row(
            locus: row.locus,
            genotype: row.genotype,
            stableClusterID: row.stableClusterID
        )
        if selectedMatrixTargetSet.contains(exact) {
            return true
        }
        let legacy = GenotypeAnnotationSidecar.MatrixTarget.row(
            locus: row.locus,
            genotype: row.genotype,
            stableClusterID: nil
        )
        return exact != legacy
            && stableSelectionAllows(row)
            && selectedMatrixTargetSet.contains(legacy)
    }

    private func selectedTargetsContainCell(
        _ row: GenotypeCandidateMatrixRow,
        sample: String
    ) -> Bool {
        let exact = GenotypeAnnotationSidecar.MatrixTarget.cell(
            locus: row.locus,
            genotype: row.genotype,
            sample: sample,
            stableClusterID: row.stableClusterID
        )
        if selectedMatrixTargetSet.contains(exact) {
            return true
        }
        let legacy = GenotypeAnnotationSidecar.MatrixTarget.cell(
            locus: row.locus,
            genotype: row.genotype,
            sample: sample,
            stableClusterID: nil
        )
        return exact != legacy
            && stableSelectionAllows(row)
            && selectedMatrixTargetSet.contains(legacy)
    }

    /// Matrix annotation targets predate stable candidate IDs. Restrict an
    /// otherwise ambiguous target only when it addresses the same displayed
    /// locus/name as the selected candidate; distinct targets and all known
    /// rows retain the existing multi-selection behavior.
    private func stableSelectionAllows(_ row: GenotypeCandidateMatrixRow) -> Bool {
        guard let selectedRowID,
              case .candidate = selectedRowID,
              case .candidate = row.id,
              let selectedRowIndex = visibleRowIndexByID[selectedRowID] else {
            return true
        }
        let selected = visibleRows[selectedRowIndex]
        guard selected.locus == row.locus,
              selected.genotype == row.genotype else {
            return true
        }
        return selectedRowID == row.id
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
    var onContextMenuRequest: ((Int, Int) -> NSMenu?)?

#if DEBUG
    private(set) var testingFullReloadCount = 0
    private(set) var testingPartialReloadCount = 0
    private(set) var testingPartialReloadedCellCount = 0

    func testingResetReloadCounters() {
        testingFullReloadCount = 0
        testingPartialReloadCount = 0
        testingPartialReloadedCellCount = 0
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
        testingPartialReloadedCellCount += rowIndexes.count * columnIndexes.count
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

    override func menu(for event: NSEvent) -> NSMenu? {
        let point = convert(event.locationInWindow, from: nil)
        if let menu = onContextMenuRequest?(row(at: point), column(at: point)) {
            return menu
        }
        return super.menu(for: event)
    }
}

private final class GenotypeMatrixStyledCellView: NSTableCellView {
    private var chromeBackgroundColor: NSColor?
    private var decorativeBorderColor: NSColor?
    private var decorativeBorderWidth: CGFloat = 0
    private var previewBorderColor: NSColor?
    private var previewBorderWidth: CGFloat = 0
    private var semanticInnerFrameColor: NSColor?
    private var semanticInnerFrameWidth: CGFloat = 0
    private var selectionAccentColor: NSColor?
    private var selectionCornerBracketWidth: CGFloat = 0
    private var selectionCornerBracketLength: CGFloat = 0
    private var commentFoldColor: NSColor?
    private var commentFoldSize: CGFloat = 0

#if DEBUG
    var testingChromeBackgroundColor: NSColor? {
        chromeBackgroundColor
    }
#endif

    func configureChrome(
        backgroundColor: NSColor?,
        decorativeBorderColor: NSColor?,
        decorativeBorderWidth: CGFloat,
        previewBorderColor: NSColor?,
        previewBorderWidth: CGFloat,
        semanticInnerFrameColor: NSColor?,
        semanticInnerFrameWidth: CGFloat,
        selectionAccentColor: NSColor?,
        selectionCornerBracketWidth: CGFloat,
        selectionCornerBracketLength: CGFloat,
        commentFoldColor: NSColor?,
        commentFoldSize: CGFloat
    ) {
        chromeBackgroundColor = backgroundColor
        self.decorativeBorderColor = decorativeBorderColor
        self.decorativeBorderWidth = decorativeBorderWidth
        self.previewBorderColor = previewBorderColor
        self.previewBorderWidth = previewBorderWidth
        self.semanticInnerFrameColor = semanticInnerFrameColor
        self.semanticInnerFrameWidth = semanticInnerFrameWidth
        self.selectionAccentColor = selectionAccentColor
        self.selectionCornerBracketWidth = selectionCornerBracketWidth
        self.selectionCornerBracketLength = selectionCornerBracketLength
        self.commentFoldColor = commentFoldColor
        self.commentFoldSize = commentFoldSize
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let maximumStroke = max(
            max(decorativeBorderWidth, previewBorderWidth),
            max(semanticInnerFrameWidth, selectionCornerBracketWidth)
        )
        let inset = max(maximumStroke / 2, 0.5)
        let rect = bounds.insetBy(dx: inset, dy: inset)
        guard rect.width > 0, rect.height > 0 else { return }

        let path = NSBezierPath(roundedRect: rect, xRadius: 3, yRadius: 3)
        if let chromeBackgroundColor {
            chromeBackgroundColor.setFill()
            path.fill()
        }
        if let decorativeBorderColor, decorativeBorderWidth > 0 {
            decorativeBorderColor.setStroke()
            path.lineWidth = decorativeBorderWidth
            path.stroke()
        }
        if let previewBorderColor, previewBorderWidth > 0 {
            previewBorderColor.setStroke()
            path.lineWidth = previewBorderWidth
            path.stroke()
        }
        if let semanticInnerFrameColor, semanticInnerFrameWidth > 0 {
            let semanticInset = max(3, semanticInnerFrameWidth + 1)
            let semanticRect = bounds.insetBy(dx: semanticInset, dy: semanticInset)
            if semanticRect.width > 0, semanticRect.height > 0 {
                let semanticPath = NSBezierPath(roundedRect: semanticRect, xRadius: 2, yRadius: 2)
                semanticInnerFrameColor.setStroke()
                semanticPath.lineWidth = semanticInnerFrameWidth
                semanticPath.stroke()
            }
        }
        if let selectionAccentColor, selectionCornerBracketWidth > 0 {
            drawSelectionCornerBrackets(
                in: rect,
                color: selectionAccentColor,
                width: selectionCornerBracketWidth,
                length: selectionCornerBracketLength
            )
        }
        if let commentFoldColor, commentFoldSize > 0 {
            drawCommentFold(color: commentFoldColor, size: commentFoldSize)
        }
    }

    private func drawSelectionCornerBrackets(
        in rect: NSRect,
        color: NSColor,
        width: CGFloat,
        length: CGFloat
    ) {
        let length = min(length, min(rect.width, rect.height) / 2)
        let path = NSBezierPath()
        path.lineWidth = width
        path.lineCapStyle = .round
        for (corner, horizontal, vertical) in [
            (NSPoint(x: rect.minX, y: rect.minY), CGFloat(1), CGFloat(1)),
            (NSPoint(x: rect.maxX, y: rect.minY), CGFloat(-1), CGFloat(1)),
            (NSPoint(x: rect.minX, y: rect.maxY), CGFloat(1), CGFloat(-1)),
            (NSPoint(x: rect.maxX, y: rect.maxY), CGFloat(-1), CGFloat(-1)),
        ] {
            path.move(to: NSPoint(x: corner.x + horizontal * length, y: corner.y))
            path.line(to: corner)
            path.line(to: NSPoint(x: corner.x, y: corner.y + vertical * length))
        }
        color.setStroke()
        path.stroke()
    }

    private func drawCommentFold(color: NSColor, size: CGFloat) {
        let top = isFlipped ? bounds.minY : bounds.maxY
        let inwardY: CGFloat = isFlipped ? size : -size
        let path = NSBezierPath()
        path.move(to: NSPoint(x: bounds.maxX - size, y: top))
        path.line(to: NSPoint(x: bounds.maxX, y: top))
        path.line(to: NSPoint(x: bounds.maxX, y: top + inwardY))
        path.close()
        color.setFill()
        path.fill()
    }
}

private final class GenotypeMatrixRowSelectorCellView: NSTableCellView {
    private let chiclet = GenotypeMatrixRowSelectorChicletView()
    private var commentFoldSize: CGFloat?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        buildView()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        buildView()
    }

    func configure(isSelected: Bool, commentFoldSize: CGFloat?) {
        chiclet.configure(isSelected: isSelected)
        self.commentFoldSize = commentFoldSize
        needsDisplay = true
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

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard let size = commentFoldSize else { return }
        let top = isFlipped ? bounds.minY : bounds.maxY
        let inwardY: CGFloat = isFlipped ? size : -size
        let path = NSBezierPath()
        path.move(to: NSPoint(x: bounds.maxX - size, y: top))
        path.line(to: NSPoint(x: bounds.maxX, y: top))
        path.line(to: NSPoint(x: bounds.maxX, y: top + inwardY))
        path.close()
        NSColor.controlAccentColor.setFill()
        path.fill()
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
    var hasCommentForColumn: ((Int) -> Bool)?
    var commentFoldSize: (() -> CGFloat)?
    var titleFont: (() -> NSFont)?
    var readFont: (() -> NSFont)?
    var chicletSize: (() -> CGFloat)?
    var onContextMenuRequest: ((Int) -> NSMenu?)?

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
                selected: isColumnSelected?(column) == true,
                hasComment: hasCommentForColumn?(column) == true
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

    override func menu(for event: NSEvent) -> NSMenu? {
        let point = convert(event.locationInWindow, from: nil)
        let column = self.column(at: point)
        if column >= 0, let menu = onContextMenuRequest?(column) {
            return menu
        }
        return super.menu(for: event)
    }

    private func chicletRect(forColumn column: Int) -> NSRect {
        chicletRect(in: headerRect(ofColumn: column))
    }

    private func drawHeaderCell(
        in rect: NSRect,
        title: String,
        readTitle: String?,
        selectable: Bool,
        selected: Bool,
        hasComment: Bool
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
        let bands = textBandRects(in: rect, leftInset: leftInset)
        let titleRect = bands.title
        let readRect = bands.read
        drawText(
            title,
            in: titleRect,
            font: titleFont?() ?? .systemFont(ofSize: 11, weight: .semibold),
            alignment: .left,
            color: .labelColor
        )
        if let readTitle {
            drawText(
                readTitle,
                in: readRect,
                font: readFont?() ?? .monospacedDigitSystemFont(ofSize: 10, weight: .regular),
                alignment: .right,
                color: .secondaryLabelColor
            )
        }
        if hasComment {
            drawCommentFold(in: rect, size: commentFoldSize?() ?? 7)
        }
    }

    private func drawCommentFold(in rect: NSRect, size: CGFloat) {
        let top = isFlipped ? rect.minY : rect.maxY
        let inwardY: CGFloat = isFlipped ? size : -size
        let path = NSBezierPath()
        path.move(to: NSPoint(x: rect.maxX - size, y: top))
        path.line(to: NSPoint(x: rect.maxX, y: top))
        path.line(to: NSPoint(x: rect.maxX, y: top + inwardY))
        path.close()
        NSColor.controlAccentColor.setFill()
        path.fill()
    }

    fileprivate func textBandRects(
        in rect: NSRect,
        leftInset: CGFloat
    ) -> (title: NSRect, read: NSRect) {
        let titleHeight = ceil(
            (titleFont?() ?? .systemFont(ofSize: 11, weight: .semibold))
                .boundingRectForFont.height
        )
        let readHeight = ceil(
            (readFont?() ?? .monospacedDigitSystemFont(ofSize: 10, weight: .regular))
                .boundingRectForFont.height
        )
        let gap: CGFloat = 2
        let totalHeight = titleHeight + gap + readHeight
        let lowerY = rect.midY - totalHeight / 2
        let readRect = NSRect(
            x: rect.minX + 6,
            y: lowerY,
            width: max(0, rect.width - 10),
            height: readHeight
        )
        let titleRect = NSRect(
            x: rect.minX + leftInset,
            y: readRect.maxY + gap,
            width: max(0, rect.width - leftInset - 4),
            height: titleHeight
        )
        return (titleRect, readRect)
    }

    private func chicletRect(in rect: NSRect) -> NSRect {
        let size = min(chicletSize?() ?? 11, max(11, rect.height - 6))
        return NSRect(
            x: rect.minX + 5,
            y: rect.midY - size / 2,
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
struct GenotypeMatrixBenchmarkSample {
    let wallTime: TimeInterval
    let targetCount: Int
}

struct GenotypeMatrixRepresentativeBenchmarkRecord {
    let smallSelectionAggregation: GenotypeMatrixBenchmarkSample
    let largeSelectionAggregation: GenotypeMatrixBenchmarkSample
    let menuConstruction: GenotypeMatrixBenchmarkSample
    let visibleRedraw: GenotypeMatrixBenchmarkSample
    let bulkSidecarMutation: GenotypeMatrixBenchmarkSample
}

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
            guard let sampleIdentifier = sampleColumnIdentifierByName[sample] else {
                return nil
            }
            identifier = sampleIdentifier
        }
        return backgroundColor(for: identifier, row: row, renderedStyle: renderedStyle(for: identifier, row: row))
    }

    func testingRenderedPinnedCellBackgroundColor(
        rowID: GenotypeCandidateMatrixRowID,
        column: GenotypeCandidateMatrixTestingColumn
    ) -> NSColor? {
        guard let (identifier, rowIndex) = testingPinnedCellTarget(
            rowID: rowID,
            column: column
        ),
              let columnIndex = pinnedTableView.tableColumns.firstIndex(
                where: { $0.identifier == identifier }
              ),
              let cell = pinnedTableView.view(
                atColumn: columnIndex,
                row: rowIndex,
                makeIfNecessary: true
              ) as? GenotypeMatrixStyledCellView else {
            return nil
        }
        return cell.testingChromeBackgroundColor
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
            guard let sampleIdentifier = sampleColumnIdentifierByName[sample] else {
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
              let identifier = sampleColumnIdentifierByName[sample] else {
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
    func testingSetReferenceColumnVisibleWithoutPersist(fieldKey: String, visible: Bool) {
        guard referenceFields.contains(where: { $0.key == fieldKey }) else { return }
        if visible {
            visibleReferenceFieldKeys.insert(fieldKey)
        } else {
            visibleReferenceFieldKeys.remove(fieldKey)
        }
        rebuildColumns()
        applyFilterAndSort()
    }
    func testingSetStandardColumnVisibleWithoutPersist(_ identifier: String, visible: Bool) {
        if visible {
            visibleStandardColumnIDs.insert(identifier)
        } else {
            visibleStandardColumnIDs.remove(identifier)
        }
        rebuildColumns()
        applyDefaultSortDescriptor()
        applyFilterAndSort()
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
              let identifier = sampleColumnIdentifierByName[sample] else {
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
              let identifier = sampleColumnIdentifierByName[sample] else {
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

    func testingSemanticCellState(
        genotype: String,
        sample: String
    ) -> GenotypeMatrixCellSemanticState? {
        guard let row = visibleRows.first(where: { $0.genotype == genotype }),
              visibleSampleNames.contains(sample) else {
            return nil
        }
        return semanticCellState(for: sample, row: row)
    }

    func testingRenderedCellAlpha(genotype: String, sample: String) -> CGFloat? {
        guard let row = visibleRows.firstIndex(where: { $0.genotype == genotype }),
              let column = tableView.tableColumns.first(where: { sampleColumnLookup[$0.identifier] == sample }),
              let cell = tableView(tableView, viewFor: column, row: row) as? NSTableCellView else {
            return nil
        }
        return cell.alphaValue
    }

    func testingResolvedSemanticTextColor(
        genotype: String,
        sample: String,
        appearance: NSAppearance.Name
    ) -> AnnotationColor? {
        guard let semantic = testingSemanticCellState(genotype: genotype, sample: sample),
              let appearance = NSAppearance(named: appearance) else {
            return nil
        }
        let dynamicColor: NSColor = semantic.text.colorRole == .secondary
            ? .secondaryLabelColor
            : .labelColor
        var resolved: AnnotationColor?
        appearance.performAsCurrentDrawingAppearance {
            guard let color = dynamicColor.usingColorSpace(.sRGB) else { return }
            resolved = AnnotationColor(
                red: Double(color.redComponent),
                green: Double(color.greenComponent),
                blue: Double(color.blueComponent),
                alpha: Double(color.alphaComponent)
            )
        }
        return resolved
    }

    func testingHasRowCommentMarker(genotype: String) -> Bool {
        guard let row = visibleRows.first(where: { $0.genotype == genotype }) else { return false }
        return !commentsForRow(row).isEmpty
    }

    func testingNativeRowCommentMarkerColumnIdentifier(genotype: String) -> String? {
        guard let row = visibleRows.first(where: { $0.genotype == genotype }),
              !commentsForRow(row).isEmpty else {
            return nil
        }
        return pinnedTableView.tableColumns.first {
            isNativeRowCommentMarkerColumn($0.identifier)
        }?.identifier.rawValue
    }

    func testingNativeRowCommentAccessibilityLabel(genotype: String) -> String? {
        guard let rowIndex = visibleRows.firstIndex(where: { $0.genotype == genotype }),
              let column = pinnedTableView.tableColumns.first(where: {
                  isNativeRowCommentMarkerColumn($0.identifier)
              }),
              let cell = tableView(
                  pinnedTableView,
                  viewFor: column,
                  row: rowIndex
              ) as? NSTableCellView else {
            return nil
        }
        return cell.textField?.accessibilityLabel() ?? cell.accessibilityLabel()
    }

    func testingNativeRowCommentToolTip(genotype: String) -> String? {
        guard let rowIndex = visibleRows.firstIndex(where: { $0.genotype == genotype }),
              let column = pinnedTableView.tableColumns.first(where: {
                  isNativeRowCommentMarkerColumn($0.identifier)
              }),
              let cell = tableView(
                  pinnedTableView,
                  viewFor: column,
                  row: rowIndex
              ) as? NSTableCellView else {
            return nil
        }
        return cell.textField?.toolTip ?? cell.toolTip
    }

    func testingHasColumnCommentMarker(sample: String) -> Bool {
        sidecarColumnComments[sample] != nil
    }

    func testingHasCellCommentMarker(genotype: String, sample: String) -> Bool {
        guard let row = visibleRows.first(where: { $0.genotype == genotype }) else { return false }
        return !commentsForCell(row, sample: sample).isEmpty
    }

    func testingCellToolTip(genotype: String, sample: String) -> String? {
        guard let row = visibleRows.first(where: { $0.genotype == genotype }),
              let support = support(for: sample, row: row) else {
            return nil
        }
        return matrixTooltip(
            sample: sample,
            row: row,
            base: sampleTooltip(sample: sample, uniqueReads: support.passedUniqueReads)
        )
    }

    func testingCellCommentMarkerHost(genotype: String, sample: String) -> NSView? {
        guard let rowIndex = visibleRows.firstIndex(where: { $0.genotype == genotype }),
              !commentsForCell(visibleRows[rowIndex], sample: sample).isEmpty,
              let column = tableView.tableColumns.first(where: {
                  sampleColumnLookup[$0.identifier] == sample
              }) else {
            return nil
        }
        return tableView(tableView, viewFor: column, row: rowIndex)
    }

    func testingSetIncreaseContrastOverride(_ value: Bool?) {
        testingIncreaseContrastOverride = value
        reloadVisibleMatrix()
        setHeaderViewsNeedDisplay()
    }

    func testingCellAccessibilityLabel(genotype: String, sample: String) -> String? {
        testingSemanticCellState(genotype: genotype, sample: sample)?.accessibilityLabel
    }

    func testingColumnAccessibilityLabel(sample: String) -> String? {
        tableView.tableColumns
            .first(where: { sampleColumnLookup[$0.identifier] == sample })?
            .headerCell
            .accessibilityLabel()
    }

    var testingReviewLegendText: String {
        reviewLegend.stringValue
    }

    func testingBuildContextMenu(
        for target: GenotypeAnnotationSidecar.MatrixTarget
    ) -> GenotypeMatrixContextMenuState? {
        prepareContextMenuSnapshot(for: target).map {
            GenotypeMatrixContextMenuBuilder.make(snapshot: $0)
        }
    }

    func testingBuildActualContextMenu(
        for target: GenotypeAnnotationSidecar.MatrixTarget
    ) -> NSMenu? {
        contextMenu(for: target)
    }

    func testingSetContextMenuSnapshotSourceFactory(
        _ factory: (
            (GenotypeMatrixContextMenuSnapshot)
                -> any GenotypeMatrixContextMenuSnapshotProviding
        )?
    ) {
        contextMenuSnapshotSourceFactory = factory ?? {
            GenotypeMatrixImmutableContextMenuSnapshotSource(snapshot: $0)
        }
    }

    func testingPerformContextCommand(_ command: GenotypeMatrixContextCommand) -> Bool {
        performContextCommand(command)
    }

    func testingPerformKeyboardCommand(_ command: GenotypeMatrixContextCommand) -> Bool {
        performContextCommand(command)
    }

    func testingRecordRepresentativeBenchmark(
        smallSelectionCount: Int,
        largeSelectionCount: Int,
        visibleRowLimit: Int
    ) -> GenotypeMatrixRepresentativeBenchmarkRecord {
        let allTargets = visibleRows.flatMap { row in
            visibleSampleNames.map { matrixTarget(row: row, sample: $0) }
        }
        let smallTargets = Array(allTargets.prefix(max(0, smallSelectionCount)))
        let largeTargets = Array(allTargets.prefix(max(0, largeSelectionCount)))

        func record(
            targetCount: Int,
            action: () -> Void
        ) -> GenotypeMatrixBenchmarkSample {
            let start = Date()
            action()
            return GenotypeMatrixBenchmarkSample(
                wallTime: Date().timeIntervalSince(start),
                targetCount: targetCount
            )
        }

        let smallSelectionAggregation = record(targetCount: smallTargets.count) {
            replaceMatrixTargetSelection(smallTargets)
        }
        let largeSelectionAggregation = record(targetCount: largeTargets.count) {
            replaceMatrixTargetSelection(largeTargets)
        }

        let menuConstruction = record(targetCount: largeTargets.count) {
            let source = GenotypeMatrixImmutableContextMenuSnapshotSource(
                snapshot: makeContextMenuSnapshot()
            )
            _ = GenotypeMatrixContextMenuBuilder.make(snapshot: source.cachedSnapshot)
        }

        let rowsToRender = min(max(0, visibleRowLimit), visibleRows.count)
        let visibleRedraw = record(targetCount: rowsToRender * visibleSampleNames.count) {
            testingRenderVisibleCells(rowLimit: rowsToRender)
        }

        var sidecar = GenotypeAnnotationSidecar.empty(generatedAt: "2026-07-24T00:00:00Z")
        sidecar.matrixComments = largeTargets.enumerated().map { index, target in
            .init(
                target: target,
                body: "Benchmark comment \(index)",
                author: "benchmark",
                timestamp: String(format: "2026-07-24T00:%02d:%02dZ", (index / 60) % 60, index % 60)
            )
        }
        let bulkSidecarMutation = record(targetCount: largeTargets.count) {
            applyAnnotationSidecar(sidecar, reload: false)
        }

        return GenotypeMatrixRepresentativeBenchmarkRecord(
            smallSelectionAggregation: smallSelectionAggregation,
            largeSelectionAggregation: largeSelectionAggregation,
            menuConstruction: menuConstruction,
            visibleRedraw: visibleRedraw,
            bulkSidecarMutation: bulkSidecarMutation
        )
    }

    func testingIsSelectedCell(genotype: String, sample: String) -> Bool {
        guard let row = visibleRows.first(where: { $0.genotype == genotype }),
              let identifier = sampleColumnIdentifierByName[sample] else {
            return false
        }
        return isSelectedCell(identifier: identifier, row: row)
    }

    func testingShowsSupportSelectionPreviewBorder(genotype: String, sample: String) -> Bool {
        guard let row = visibleRows.first(where: { $0.genotype == genotype }),
              let identifier = sampleColumnIdentifierByName[sample] else {
            return false
        }
        return showsSupportSelectionPreviewBorder(identifier: identifier, row: row)
    }

    func testingDrawsMatrixCellSelectionFocus(genotype: String, sample: String) -> Bool {
        guard let row = visibleRows.first(where: { $0.genotype == genotype }),
              let identifier = sampleColumnIdentifierByName[sample] else {
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
        pinnedTableView.testingResetReloadCounters()
        tableView.testingResetReloadCounters()
        testingLastReloadTargets = []
    }

    func testingResetProjectionPerformanceCounters() {
        testingDerivedProjectionPassCount = 0
        testingDerivedProjectionTotalSeconds = 0
        testingDerivedProjectionMaximumSeconds = 0
        testingCommitToVisibleCount = 0
        testingCommitToVisibleTotalSeconds = 0
        testingCommitToVisibleMaximumSeconds = 0
        testingColumnRebuildCount = 0
        testingVisibleSettlementGeneration &+= 1
        testingResetReloadCounters()
    }

    var testingProjectionPerformanceSnapshot:
        GenotypeMatrixProjectionPerformanceSnapshot {
        GenotypeMatrixProjectionPerformanceSnapshot(
            baseProjectionBuildCount: testingBaseProjectionBuildCount,
            derivedProjectionPassCount: testingDerivedProjectionPassCount,
            derivedProjectionTotalSeconds: testingDerivedProjectionTotalSeconds,
            derivedProjectionMaximumSeconds: testingDerivedProjectionMaximumSeconds,
            commitToVisibleCount: testingCommitToVisibleCount,
            commitToVisibleTotalSeconds: testingCommitToVisibleTotalSeconds,
            commitToVisibleMaximumSeconds: testingCommitToVisibleMaximumSeconds,
            columnRebuildCount: testingColumnRebuildCount,
            pinnedFullReloadCount: pinnedTableView.testingFullReloadCount,
            sampleFullReloadCount: tableView.testingFullReloadCount
        )
    }

    var testingFullReloadCount: Int {
        pinnedTableView.testingFullReloadCount + tableView.testingFullReloadCount
    }

    var testingPinnedFullReloadCount: Int {
        pinnedTableView.testingFullReloadCount
    }

    var testingSampleFullReloadCount: Int {
        tableView.testingFullReloadCount
    }

    var testingPartialReloadCount: Int {
        pinnedTableView.testingPartialReloadCount + tableView.testingPartialReloadCount
    }

    var testingPinnedPartialReloadCount: Int {
        pinnedTableView.testingPartialReloadCount
    }

    var testingSamplePartialReloadCount: Int {
        tableView.testingPartialReloadCount
    }

    var testingPartialReloadedCellCount: Int {
        pinnedTableView.testingPartialReloadedCellCount + tableView.testingPartialReloadedCellCount
    }

    var testingReloadTargets: [GenotypeAnnotationSidecar.MatrixTarget] {
        testingLastReloadTargets
    }

    var testingMatrixCellFontPointSize: CGFloat {
        font(for: .init()).pointSize
    }

    var testingMatrixHeaderFontPointSize: CGFloat {
        (tableView.headerView as? GenotypeMatrixHeaderView)?.titleFont?().pointSize ?? 0
    }

    var testingMatrixRowHeight: CGFloat {
        tableView.rowHeight
    }

    var testingMatrixHeaderHeight: CGFloat {
        tableView.headerView?.frame.height ?? 0
    }

    var testingAllColumnWidths: [CGFloat] {
        pinnedTableView.tableColumns.map(\.width) + tableView.tableColumns.map(\.width)
    }

    var testingSemanticDecorationFramesAreContained: Bool {
        let geometry = semanticGeometry()
        return geometry.commentFoldSize <= min(tableView.rowHeight, testingMatrixHeaderHeight)
            && geometry.selectionCornerBracketLength <= tableView.rowHeight
            && headerChicletSize <= testingMatrixHeaderHeight
    }

    func testingSetContentScrollOrigins(pinned: NSPoint, samples: NSPoint) {
        suppressScrollSync = true
        pinnedScrollView.contentView.setBoundsOrigin(pinned)
        scrollView.contentView.setBoundsOrigin(samples)
        suppressScrollSync = false
    }

    var testingContentScrollAnchors: [CGFloat] {
        let pinned = captureTypographyScrollAnchor(
            scrollView: pinnedScrollView,
            tableView: pinnedTableView
        )
        let samples = captureTypographyScrollAnchor(
            scrollView: scrollView,
            tableView: tableView
        )
        return [
            CGFloat(pinned.row), pinned.withinRowOffset, pinned.horizontalOrigin,
            CGFloat(samples.row), samples.withinRowOffset, samples.horizontalOrigin,
        ]
    }

    var testingSemanticScrollAnchor: GenotypeMatrixSemanticScrollSnapshot {
        guard let anchor = captureSemanticScrollAnchor() else {
            return GenotypeMatrixSemanticScrollSnapshot(
                rowID: nil,
                withinRowOffset: 0,
                sampleHorizontalOrigin: scrollView.contentView.bounds.minX
            )
        }
        return GenotypeMatrixSemanticScrollSnapshot(
            rowID: anchor.rowID,
            withinRowOffset: anchor.withinRowOffset,
            sampleHorizontalOrigin: anchor.sampleHorizontalOrigin
        )
    }

    var testingHeaderTextBandsFit: Bool {
        guard let header = tableView.headerView as? GenotypeMatrixHeaderView else {
            return false
        }
        let titleFont = header.titleFont?() ?? .systemFont(ofSize: 11, weight: .semibold)
        let readFont = header.readFont?()
            ?? .monospacedDigitSystemFont(ofSize: 10, weight: .regular)
        return tableView.tableColumns.indices.allSatisfy { column in
            let rect = header.headerRect(ofColumn: column)
            let bands = header.textBandRects(in: rect, leftInset: 20)
            return rect.contains(bands.title)
                && rect.contains(bands.read)
                && bands.title.height >= ceil(titleFont.boundingRectForFont.height)
                && bands.read.height >= ceil(readFont.boundingRectForFont.height)
                && bands.title.intersection(bands.read).isEmpty
        }
    }

    func testingSetContentPreferredFontProvider(
        _ provider: any ContentPreferredFontProviding
    ) {
        contentPreferredFontProvider = provider
        applyContentTypography()
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
        sampleColumnIdentifierByName[sample]?.rawValue
    }

    func testingSetSortDescriptor(key: String, ascending: Bool) {
        activeSortDescriptors = [NSSortDescriptor(key: key, ascending: ascending)]
        syncSortDescriptorsToTables()
        applyFilterAndSort()
    }
}
#endif
