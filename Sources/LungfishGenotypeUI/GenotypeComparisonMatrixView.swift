import AppKit
import LungfishCore
import LungfishIO
import LungfishKit

struct GenotypeMatrixContentScrollOrigins: Equatable {
    let pinned: NSPoint
    let samples: NSPoint
}

private extension GenotypeCandidateMatrixRowID {
    var accessibilityIdentifierComponent: String {
        switch self {
        case let .known(locus, genotype):
            return "known:\(locus):\(genotype)"
        case let .candidate(stableClusterID):
            return "candidate:\(stableClusterID)"
        }
    }
}

struct GenotypeVisibleSampleAlleleSemantics {
    let isProvisionalExon2: Bool
    let candidateClassification: ONTMHCCandidateClassification?
    let cell: GenotypeMatrixCellSemanticState
}

struct GenotypeVisibleSampleAlleleDetail {
    let rowID: GenotypeCandidateMatrixRowID
    let stableClusterID: String?
    let sharedCall: ONTGenotypeSharedCall
    let support: ONTGenotypeSampleSupport
    let fraction: Double?
    let semantics: GenotypeVisibleSampleAlleleSemantics
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
    let leadingSampleID: String?
    let withinSampleOffset: CGFloat
}

struct GenotypeMatrixSelectorAccessibilitySnapshot: Equatable {
    let role: NSAccessibility.Role?
    let label: String
    let value: Bool
    let numericValue: NSNumber?
    let valueDescription: String?
    let identifier: String
    let supportsPress: Bool
    let acceptsKeyboardFocus: Bool
}

struct GenotypeMatrixRowSelectorAccessibilityTreeSnapshot: Equatable {
    let cellIsAccessibilityElement: Bool
    let chicletIsAccessibilityElement: Bool
    let actionableDescendantCount: Int
}

struct GenotypeMatrixSelectorReuseNotificationSnapshot: Equatable {
    let afterInitialConfiguration: Int
    let afterDifferentIdentityConfiguration: Int
    let afterSameIdentityStateChange: Int
}

struct GenotypeMatrixFixedHeaderTestingSnapshot: Equatable {
    let totalNativeHeaderHeight: CGFloat
    let nativeHeaderRect: NSRect
    let ordinarySampleHeaderRect: NSRect
    let manualSectionRect: NSRect
    let firstTableRowRect: NSRect?
    let sampleTitleRect: NSRect
    let sampleReadTextRect: NSRect
    let sampleColumnRect: NSRect
}

struct GenotypeMatrixManualValueTestingSnapshot: Equatable {
    let textRect: NSRect
    let alignment: NSTextAlignment
    let value: String
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
    private final class ContextMenuCommandPayload: NSObject {
        let command: GenotypeMatrixContextCommand
        let selectionTargets: Set<GenotypeAnnotationSidecar.MatrixTarget>

        init(
            command: GenotypeMatrixContextCommand,
            selectionTargets: [GenotypeAnnotationSidecar.MatrixTarget]
        ) {
            self.command = command
            self.selectionTargets = Set(selectionTargets)
        }
    }

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
        static func sample(_ stableID: String) -> NSUserInterfaceItemIdentifier {
            NSUserInterfaceItemIdentifier("sample.\(stableID)")
        }
    }

    var onSharedCallSelected: ((ONTGenotypeSharedCall, String?, [GenotypeAnnotationSidecar.MatrixTarget]) -> Void)?
    var onCandidateRowSelected: ((GenotypeCandidateMatrixRow, String?, [GenotypeAnnotationSidecar.MatrixTarget]) -> Void)?
    var onMatrixTargetsSelected: (([GenotypeAnnotationSidecar.MatrixTarget]) -> Void)?
    var onMatrixReviewRequested: ((GenotypeMatrixReviewRequest) -> Void)?
    var onMatrixCommentEditRequested: ((GenotypeMatrixCommentEditRequest) -> Void)?
    var onSelectionCleared: (() -> Void)?
    var onDisplaySummaryChanged: ((Int, Int, Int) -> Void)?
    var onSearchProjectionChanged: (() -> Void)?
    var onVisibleProjectionChanged: (() -> Void)?
    var onMatrixVisibilityCapabilityChanged:
        ((GenotypeMatrixVisibilityCapabilitySnapshot) -> Void)?
    var onManualHaplotypeTransitionPreflight:
        ((
            GenotypeManualHaplotypeDraftCoordinator.Transition,
            @escaping @MainActor () -> Void
        ) -> Bool)?
    var onManualHaplotypeEditRequested: ((String) -> Void)?
    var onManualHaplotypeBandExpansionChanged: ((Bool) -> Void)?
    var onHaplotypeBandTargetSelected:
        ((GenotypeHaplotypeBandTarget) -> Void)?
    var matrixCommentBodyProvider: ((String?) -> String?)?
    private var contextMenuSnapshotSourceFactory:
        (GenotypeMatrixContextMenuSnapshot) -> any GenotypeMatrixContextMenuSnapshotProviding = {
            GenotypeMatrixImmutableContextMenuSnapshotSource(snapshot: $0)
        }
    private var visibilityAnnouncementPoster: any AccessibilityAnnouncementPosting =
        AccessibilityAnnouncementPoster()
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
    private let manualHaplotypePinnedBand =
        GenotypeManualHaplotypePinnedBandView()
    private let manualHaplotypeSampleBand =
        GenotypeManualHaplotypeSampleBandView()
    private var manualHaplotypeBandSnapshot =
        GenotypeManualHaplotypeAssignmentBandSnapshot(
            index: GenotypeManualHaplotypeAssignmentIndex(assignments: []),
            samples: []
        )
    private var manualHaplotypeBandAssignments:
        [ManualHaplotypeAssignment] = []
    private var manualHaplotypeEditingEligible = false
    private var haplotypeBandMode: GenotypeHaplotypeBandMode = .none
    private var effectiveHaplotypeBandSnapshot =
        GenotypeHaplotypeCallBandSnapshot.empty
    private var hasExplicitHaplotypeBandConfiguration = false
    private var manualHaplotypeBandGeometryDirty = true
    private var manualHaplotypeBandHorizontalOffset: CGFloat?
    private var manualHaplotypeBandBoundsSize = NSSize.zero
    private var manualHaplotypeBandCachedCoverageRect = NSRect.zero
    private var manualHaplotypeBandCachedOverscanWidth: CGFloat?
    /// Presentation-only minima measured from the expanded assignment band.
    /// User-preferred widths remain exclusively in
    /// `sampleColumnWidthsByStableID`.
    private var manualHaplotypeTransientMinimumWidths: [String: CGFloat] = [:]
    private var isApplyingManualHaplotypeAutoFit = false
#if DEBUG
    private var testingManualHaplotypeBandInvalidatedSampleSet =
        Set<String>()
    private var testingManualHaplotypeBandTypographyScaleOverride: CGFloat?
    private var testingManualHaplotypeGeometryUpdateCount = 0
    private var testingManualHaplotypeGeometryRecomputationCount = 0
    private var testingManualHaplotypeGeometryInspectedColumnCount = 0
    private var testingManualHaplotypeDisclosureHeaderRelayoutCount = 0
    private var testingManualHaplotypeDisclosureAnchorPreservationCount = 0
    private var testingManualHaplotypeMeasurementCountsBySample:
        [String: Int] = [:]
    private var testingForcesLegacyBottomChrome = false
#endif
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
        let rowID: GenotypeCandidateMatrixRowID?
        let previousRowIndex: Int?
        let previousRowIDs: [GenotypeCandidateMatrixRowID]
        let withinRowOffset: CGFloat
        let pinnedHorizontalOrigin: CGFloat
        let sampleHorizontalOrigin: CGFloat
        let leadingSampleID: String?
        let leadingSampleIndex: Int?
        let previousSampleIDs: [String]
        let withinSampleOffset: CGFloat
    }
    private struct FocusedSelectorIdentity: Equatable {
        enum Identity: Equatable {
            case row(GenotypeCandidateMatrixRowID)
            case column(String)
            case selectAll
        }

        let identity: Identity
        let usesAccessibilityFocus: Bool
    }
    private struct NativeFilterState: Equatable {
        let text: String
        let selectedRange: NSRange
    }
    private struct NativeTableSelectionState {
        let pinnedRows: IndexSet
        let sampleRows: IndexSet
        let scrollOrigins: GenotypeMatrixContentScrollOrigins
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
    private var preferredSampleColumnOrder: [String] = []
    /// Baseline widths (before the app content-text scale) keyed by stable
    /// sample ID, not by a transient visual column index.
    private var sampleColumnWidthsByStableID: [String: CGFloat] = [:]
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
    private var provisionalExon2Genotypes: Set<String> = []
    private var supportByRowAndSample: [GenotypeCandidateMatrixRowID: [String: ONTGenotypeSampleSupport]] = [:]
    private var selectedGenotype: String?
    private var selectedSampleName: String?
    private var selectedRowLocus: String?
    private var selectedRowID: GenotypeCandidateMatrixRowID?
    private var candidateDisplaySettings = ONTMHCCandidateDisplaySettings.default
    private var selectedMatrixTargets: [GenotypeAnnotationSidecar.MatrixTarget] = [] {
        didSet {
            selectedMatrixTargetSet = Set(selectedMatrixTargets)
            publishVisibilityCapability()
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
    private var visibilityState = GenotypeMatrixVisibilityState()
    private(set) var matrixVisibilityCapability = GenotypeMatrixVisibilityCapabilitySnapshot(
        selection: .init(targets: []),
        visibility: .init()
    )
    private var quickSearchRowIDs: Set<GenotypeCandidateMatrixRowID>?
    private weak var accessibilityFocusedSelectorButton:
        GenotypeMatrixSelectorButton?
    private var filterText = ""
    private var committedNativeFilterState = NativeFilterState(
        text: "",
        selectedRange: NSRange(location: 0, length: 0)
    )
    private var suppressNativeFilterSelectionTracking = false
    private var nativeFilterActionGeneration = 0
    private var pendingNativeTableSelectionState:
        NativeTableSelectionState?
    private var isApplyingApprovedManualHaplotypeTransition = false
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
    private var testingVisibilityMutationPassCount = 0
    private var testingAccessibilityValueChangedCount = 0
    private var testingAccessibilityLayoutChangedCount = 0
    private var testingAccessibilityFocusChangedCount = 0
    private var testingDidFallBackAccessibilityFocusToMatrix = false
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
        if case .eligible = GenotypeManualHaplotypeEligibility.evaluate(result) {
            manualHaplotypeEditingEligible = true
        } else {
            manualHaplotypeEditingEligible = false
        }
        if !hasExplicitHaplotypeBandConfiguration {
            haplotypeBandMode = manualHaplotypeEditingEligible
                ? .manualAssignments
                : .none
        }
        self.metadataStore = metadataStore
        provisionalExon2Genotypes = result.haplotypeAnalysis == nil
            ? Set(result.provisionalExon2SequencesByGenotype.keys)
            : []
        updateReviewLegend()
        configureReferenceColumns(from: result.referenceMetadata)
        sampleNames = result.sampleNames
        if sampleNames.isEmpty {
            sampleNames = orderedSamples(from: result.calls)
        }
        appendMissingCandidateSamples(from: result)
        preferredSampleColumnOrder = sampleNames
        sampleColumnWidthsByStableID = [:]
        manualHaplotypeTransientMinimumWidths = [:]
        sampleReadTitleByName = sampleReadTitles(from: result)
        selectedRowLocus = nil
        selectedFilterLocus = nil
        selectedGenotype = nil
        selectedSampleName = nil
        selectedRowID = nil
        visibilityState = .init()
        selectedMatrixTargets = []
        selectedColumnSamples = []
        columnSelectionAnchorSample = nil
        directSelectionAnchor = nil
        pendingColumnSelectionTargets = nil
        pendingColumnSelectionCleared = false
        quickSearchRowIDs = nil
        applyAnnotationSidecar(sidecar, reload: false)
        applyManualHaplotypeBandPresentation()
        rebuildBaseProjection()
        rebuildColumns()
        applyDefaultSortDescriptor()
        applyFilterAndSort()
        publishVisibilityCapability()
    }

    /// Supplies the neutral haplotype-band presentation independently of the
    /// matrix's lazy scientific-row configuration. Calling this before
    /// `configure` records the newest snapshot; calling it afterward updates
    /// only changed sample columns.
    func setHaplotypeBand(
        mode: GenotypeHaplotypeBandMode,
        snapshot: GenotypeHaplotypeCallBandSnapshot?
    ) {
        let previousMode = haplotypeBandMode
        let previousSnapshot = effectiveHaplotypeBandSnapshot
        hasExplicitHaplotypeBandConfiguration = true
        haplotypeBandMode = mode
        effectiveHaplotypeBandSnapshot = snapshot ?? .empty

        let changedSamples: Set<String>
        if previousMode == .effectiveMiSeqCalls,
           mode == .effectiveMiSeqCalls {
            changedSamples = effectiveHaplotypeBandSnapshot.changedSamples(
                comparedTo: previousSnapshot
            )
        } else {
            changedSamples = Set(sampleNames)
                .union(previousSnapshot.sampleNames)
                .union(effectiveHaplotypeBandSnapshot.sampleNames)
        }

        let structureChanged = previousMode != mode
            || previousSnapshot.orderedLoci
                != effectiveHaplotypeBandSnapshot.orderedLoci
        if structureChanged {
            applyManualHaplotypeBandPresentation()
        } else if mode == .effectiveMiSeqCalls {
            manualHaplotypeSampleBand.setHaplotypeBand(
                mode: mode,
                snapshot: effectiveHaplotypeBandSnapshot,
                invalidateAll: false
            )
        }
#if DEBUG
        testingManualHaplotypeBandInvalidatedSampleSet.formUnion(
            changedSamples.filter { sample in
                manualHaplotypeSampleBand.columnFrames[sample]?
                    .intersects(manualHaplotypeSampleBand.bounds) == true
            }
        )
#endif
        manualHaplotypeSampleBand.invalidate(samples: changedSamples)
        updateManualHaplotypeHeaderAccessibility(samples: changedSamples)
        if displayState.manualHaplotypeBandExpanded {
            refreshManualHaplotypeAutoFit(
                samples: changedSamples,
                remeasure: true
            )
        } else {
            for sample in changedSamples {
                manualHaplotypeTransientMinimumWidths.removeValue(
                    forKey: sample
                )
            }
        }
    }

    /// Replaces workbook-backed scientific rows while preserving analyst view
    /// state (stable sample order/widths, sort, filters, and surviving
    /// selection). This is used after current.xlsx is reloaded.
    func replaceResultPreservingPresentation(
        _ result: ONTGenotypeResultBundleData,
        metadataStore: SampleMetadataStore?,
        sidecar: GenotypeAnnotationSidecar?
    ) {
        captureStableSampleColumnState()
        self.result = result
        if case .eligible = GenotypeManualHaplotypeEligibility.evaluate(result) {
            manualHaplotypeEditingEligible = true
        } else {
            manualHaplotypeEditingEligible = false
        }
        if !hasExplicitHaplotypeBandConfiguration {
            haplotypeBandMode = manualHaplotypeEditingEligible
                ? .manualAssignments
                : .none
        }
        self.metadataStore = metadataStore
        provisionalExon2Genotypes = result.haplotypeAnalysis == nil
            ? Set(result.provisionalExon2SequencesByGenotype.keys)
            : []
        updateReviewLegend()
        configureReferenceColumns(from: result.referenceMetadata)
        sampleNames = result.sampleNames
        if sampleNames.isEmpty {
            sampleNames = orderedSamples(from: result.calls)
        }
        appendMissingCandidateSamples(from: result)
        let validSamples = Set(sampleNames)
        preferredSampleColumnOrder =
            preferredSampleColumnOrder.filter(validSamples.contains)
        let ordered = Set(preferredSampleColumnOrder)
        preferredSampleColumnOrder.append(
            contentsOf: sampleNames.filter { !ordered.contains($0) }
        )
        sampleColumnWidthsByStableID = sampleColumnWidthsByStableID.filter {
            validSamples.contains($0.key)
        }
        manualHaplotypeTransientMinimumWidths =
            manualHaplotypeTransientMinimumWidths.filter {
                validSamples.contains($0.key)
            }
        sampleReadTitleByName = sampleReadTitles(from: result)
        applyAnnotationSidecar(sidecar, reload: false)
        applyManualHaplotypeBandPresentation()
        rebuildBaseProjection()
        rebuildColumns()
        applyFilterAndSort()
    }

    func applyDisplayState(_ state: GenotypeResultDisplayState) {
        let previousState = displayState
        let previousSamples = activeSampleNames()
        let previousEffectiveCandidateSettings = effectiveCandidateDisplaySettings
        let manualHaplotypeAnchor =
            state.manualHaplotypeBandExpanded
                != previousState.manualHaplotypeBandExpanded
                ? captureSemanticScrollAnchor()
                : nil
        displayState = state
        applyManualHaplotypeBandPresentation()
        if state.manualHaplotypeBandExpanded
            != previousState.manualHaplotypeBandExpanded {
            refreshManualHaplotypeAutoFit(
                samples: Set(visibleSampleNames),
                remeasure: state.manualHaplotypeBandExpanded
            )
        }
        if manualHaplotypeAnchor != nil {
            layoutSubtreeIfNeeded()
            restoreSemanticScrollAnchor(manualHaplotypeAnchor)
        }
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
        updateManualHaplotypeBand(
            assignments: sidecar?.manualHaplotypeAssignments ?? []
        )
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
        updateManualHaplotypeHeaderAccessibility()
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

    func applyManualHaplotypeAssignments(
        _ assignments: [ManualHaplotypeAssignment]
    ) {
        updateManualHaplotypeBand(assignments: assignments)
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

    private func publishVisibilityCapability() {
        let next = GenotypeMatrixVisibilityCapabilitySnapshot(
            selection: .init(targets: selectedMatrixTargets),
            visibility: visibilityState
        )
        guard next != matrixVisibilityCapability else { return }
        matrixVisibilityCapability = next
        onMatrixVisibilityCapabilityChanged?(next)
    }

    func setFilterText(
        _ text: String,
        selectedRange: NSRange? = nil
    ) {
        let requestedState = NativeFilterState(
            text: text,
            selectedRange: normalizedFilterSelectionRange(
                selectedRange ?? filterEditorSelectedRange(),
                for: text
            )
        )
        if deferManualHaplotypeTransition(.search, mutation: {
            [weak self] in
            self?.applyFilterState(requestedState)
        }) {
            restoreNativeFilterState(committedNativeFilterState)
            return
        }
        applyFilterState(requestedState)
    }

    private func applyFilterState(_ state: NativeFilterState) {
        let previousSamples = activeSampleNames()
        filterText = state.text
        restoreNativeFilterState(state)
        committedNativeFilterState = state
        if activeSampleNames() != previousSamples {
            rebuildColumns()
            applyDefaultSortDescriptor()
        }
        applyFilterAndSort()
    }

    func applyFilters(allowedSampleIDs: Set<String>?, text: String) {
        let previousSamples = activeSampleNames()
        self.allowedSampleIDs = allowedSampleIDs
        quickSearchRowIDs = nil
        let filterState = NativeFilterState(
            text: text,
            selectedRange: normalizedFilterSelectionRange(
                filterEditorSelectedRange(),
                for: text
            )
        )
        filterText = text
        restoreNativeFilterState(filterState)
        committedNativeFilterState = filterState
        if activeSampleNames() != previousSamples {
            rebuildColumns()
            applyDefaultSortDescriptor()
        }
        applyFilterAndSort()
    }

    /// Applies the controller's already-classified shared quick-search result.
    /// The matrix never reinterprets the query text, so sample/row routing is
    /// identical in Matrix, Outline, and Review.
    func applySharedSearchConstraints(
        allowedSampleIDs: Set<String>?,
        projectedRowIDs: Set<GenotypeCandidateMatrixRowID>?
    ) {
        let previousSamples = activeSampleNames()
        self.allowedSampleIDs = allowedSampleIDs
        quickSearchRowIDs = projectedRowIDs
        let filterState = NativeFilterState(
            text: "",
            selectedRange: NSRange(location: 0, length: 0)
        )
        filterText = ""
        restoreNativeFilterState(filterState)
        committedNativeFilterState = filterState
        if activeSampleNames() != previousSamples {
            rebuildColumns()
            syncSortDescriptorsToTables()
        }
        applyFilterAndSort()
    }

    func sharedSearchProjectedRows() -> [GenotypeSearchIndex.ProjectedRowRecord] {
        let rows = baseProjection?.derive(.unfiltered).rows ?? allRows
        return rows.map { row in
            let visibleMetadata: [String: String]
            if row.population == .known {
                let record = referenceRecords[row.genotype] ?? [:]
                visibleMetadata = record.filter {
                    visibleReferenceFieldKeys.contains($0.key)
                }
            } else {
                visibleMetadata = [:]
            }
            return GenotypeSearchIndex.ProjectedRowRecord(
                id: row.id,
                displayedAllele: biologicalAlleleDisplayName(for: row),
                rawGenotype: row.genotype,
                locus: row.locus,
                stableClusterID: row.stableClusterID,
                identityAliases: isProvisionalExon2(row)
                    ? ["Provisional exon 2"]
                    : [],
                visibleReferenceMetadata: visibleMetadata,
                carrierSampleIDs: Set(row.sampleSupport.map(\.sample))
            )
        }
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
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(filterEditorSelectionDidChange(_:)),
            name: NSTextView.didChangeSelectionNotification,
            object: nil
        )

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
        manualHaplotypePinnedBand.isHidden = true
        manualHaplotypePinnedBand.onDisclosureChanged = { [weak self] expanded in
            guard let self else { return }
            self.setManualHaplotypeBandExpandedPreservingViewport(expanded)
            self.onManualHaplotypeBandExpansionChanged?(expanded)
        }
        manualHaplotypeSampleBand.isHidden = true
        manualHaplotypeSampleBand.onTargetSelected = { [weak self] target in
            self?.onHaplotypeBandTargetSelected?(target)
        }

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
        pinnedHeaderView.selectorIdentityForColumn = { [weak self] column in
            guard let self,
                  self.pinnedColumnIdentifier(at: column) == ColumnID.rowSelector else {
                return nil
            }
            return .selectAll
        }
        pinnedHeaderView.selectorLabelForColumn = { _ in
            "Select all visible allele rows and sample columns"
        }
        pinnedHeaderView.onSelectorAccessibilityValueChanged = { [weak self] in
            self?.recordAccessibilityValueChangedNotification()
        }
        pinnedHeaderView.onSelectorAccessibilityFocusChanged = { [weak self] button, focused in
            self?.selectorAccessibilityFocusChanged(button, focused: focused)
        }
        pinnedHeaderView.onColumnChicletClick = { [weak self] column, modifiers in
            self?.handlePinnedHeaderChicletClick(column: column, modifiers: modifiers) ?? false
        }
        pinnedHeaderView.readTitleForColumn = { [weak self] column in
            self?.readTitle(forColumnAt: column, in: self?.pinnedTableView)
        }
        pinnedHeaderView.manualContentView = manualHaplotypePinnedBand
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
        headerView.selectorIdentityForColumn = { [weak self] column in
            self?.sampleName(forColumnAt: column).map {
                GenotypeMatrixSelectorButton.Identity.column($0)
            }
        }
        headerView.selectorLabelForColumn = { [weak self] column in
            self?.sampleName(forColumnAt: column).map {
                "Select sample column \($0)"
            }
        }
        headerView.onSelectorAccessibilityValueChanged = { [weak self] in
            self?.recordAccessibilityValueChangedNotification()
        }
        headerView.onSelectorAccessibilityFocusChanged = { [weak self] button, focused in
            self?.selectorAccessibilityFocusChanged(button, focused: focused)
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
        headerView.manualContentView = manualHaplotypeSampleBand
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
        let nextDisclosureHeight = manualHaplotypeDisclosureHeight
        let disclosureHeightChanged =
            haplotypeBandIsVisible
                && (
                    manualHaplotypePinnedBand.disclosureHeight
                        != nextDisclosureHeight
                    || manualHaplotypeSampleBand.disclosureHeight
                        != nextDisclosureHeight
                )
        let disclosureAnchor = disclosureHeightChanged
            ? captureSemanticScrollAnchor()
            : nil
        if synchronizeManualHaplotypeDisclosureGeometry() {
#if DEBUG
            testingManualHaplotypeDisclosureHeaderRelayoutCount += 1
            if disclosureAnchor != nil {
                testingManualHaplotypeDisclosureAnchorPreservationCount += 1
            }
#endif
            updateNativeHeaderLayout()
            restoreSemanticScrollAnchor(disclosureAnchor)
        }
        synchronizePinnedScrollBottomInset()
        updateManualHaplotypeBandColumnGeometry()
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
            if manualHaplotypeBandHorizontalOffset
                != sourceContentView.bounds.origin.x {
                updateManualHaplotypeBandColumnGeometry()
            }
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
#if DEBUG
        if testingForcesLegacyBottomChrome {
            return NSScroller.scrollerWidth(
                for: .regular,
                scrollerStyle: .legacy
            )
        }
#endif
        guard let horizontalScroller = scrollView.horizontalScroller,
              scrollView.scrollerStyle == .legacy else {
            return 0
        }
        if horizontalScroller.isHidden,
           scrollView.hasHorizontalScroller,
           !scrollView.autohidesScrollers {
            return NSScroller.scrollerWidth(
                for: .regular,
                scrollerStyle: .legacy
            )
        }
        guard !horizontalScroller.isHidden else { return 0 }
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
        manualHaplotypeBandGeometryDirty = true
        manualHaplotypeBandCachedCoverageRect = .zero
        manualHaplotypeBandCachedOverscanWidth = nil
        let preservedSortDescriptors = activeSortDescriptors
        suppressSortDescriptorSync = true
        captureStableSampleColumnState()
        captureColumnTypographyBaselines()
        removeAllColumns(from: pinnedTableView)
        removeAllColumns(from: tableView)
        sampleColumnLookup.removeAll()
        sampleColumnIdentifierByName.removeAll()
        visibleSampleNames = samplesInPreferredColumnOrder(activeSampleNames())
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

        for sample in visibleSampleNames {
            let identifier = ColumnID.sample(sample)
            sampleColumnLookup[identifier] = sample
            sampleColumnIdentifierByName[sample] = identifier
            let width = sampleColumnWidthsByStableID[sample] ?? 68
            addColumn(
                to: tableView,
                identifier: identifier,
                title: sample,
                width: width,
                minWidth: 58,
                ascending: false
            )
            typographyBaselineColumnWidths[identifier.rawValue] = width
            typographyBaselineColumnMinWidths[identifier.rawValue] = 58
        }
        rebuildVisibleColumnIndex()
        updatePinnedWidth()
        updateNativeHeaderLayout(ordinaryHeight: 34)
        rebuildPinnedColumnMenu()
        updateColumnCommentMetadata()
        registerColumnTypographyBaselines()
        applyContentTypography()
        suppressSortDescriptorSync = false
        activeSortDescriptors = preservedSortDescriptors
        syncSortDescriptorsToTables()
        setHeaderViewsNeedDisplay()
        updateManualHaplotypeBandColumnGeometry()
        updateManualHaplotypeHeaderAccessibility()
        if let header = tableView.headerView {
            postAccessibilityLayoutChanged(for: header)
        }
        if let header = pinnedTableView.headerView {
            postAccessibilityLayoutChanged(for: header)
        }
    }

    private func recordAccessibilityValueChangedNotification() {
#if DEBUG
        testingAccessibilityValueChangedCount += 1
#endif
    }

    private func postAccessibilityLayoutChanged(for element: Any) {
        NSAccessibility.post(element: element, notification: .layoutChanged)
#if DEBUG
        testingAccessibilityLayoutChangedCount += 1
#endif
    }

    private func postAccessibilityFocusChanged(for element: Any) {
        NSAccessibility.post(element: element, notification: .focusedUIElementChanged)
#if DEBUG
        testingAccessibilityFocusChangedCount += 1
#endif
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

    static func searchVisibleReferenceFieldKeys(
        for metadata: ONTGenotypeReferenceMetadata?
    ) -> Set<String> {
        guard let metadata else { return [] }
        if let stored = UserDefaults.standard.array(
            forKey: referenceVisibilityKey
        ) as? [String] {
            return Set(stored).intersection(metadata.fields.map(\.key))
        }
        return metadata.alleleFieldKey.map { Set([$0]) } ?? []
    }

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
            visibleReferenceFieldKeys = Self.searchVisibleReferenceFieldKeys(
                for: metadata
            )
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
        let previous = visibleReferenceFieldKeys
        if visible { visibleReferenceFieldKeys.insert(fieldKey) } else { visibleReferenceFieldKeys.remove(fieldKey) }
        guard previous != visibleReferenceFieldKeys else { return }
        persistColumnVisibility()
        rebuildColumns()
        applyFilterAndSort()
        onSearchProjectionChanged?()
    }


    private func activeSampleNames() -> [String] {
        let sampleFilter = displayState.matrixSampleFilterText.trimmingCharacters(in: .whitespacesAndNewlines)
        let freeTextSampleFilter = implicitSampleFilterText()
        return sampleNames.filter { sample in
            // Required derived-view order: manual visibility first, then the
            // shared Task 7 search/cohort mask, then Inspector text filters.
            if !visibilityState.allows(sample: sample) {
                return false
            }
            if let allowedSampleIDs, !allowedSampleIDs.contains(sample) {
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

    private func samplesInPreferredColumnOrder(_ activeSamples: [String]) -> [String] {
        let active = Set(activeSamples)
        let preferred = preferredSampleColumnOrder.filter(active.contains)
        let preferredSet = Set(preferred)
        return preferred + activeSamples.filter { !preferredSet.contains($0) }
    }

    /// Snapshot user-visible order and widths before any filtering rebuild
    /// removes columns. Replacing only the currently visible positions keeps
    /// filtered-out samples anchored in the full stable order.
    private func captureStableSampleColumnState(
        userResizedSample: String? = nil
    ) {
        let columns = tableView.tableColumns.compactMap { column -> (String, CGFloat)? in
            guard let sample = sampleColumnLookup[column.identifier] else { return nil }
            return (sample, column.width / max(contentTypographyScale, 0.01))
        }
        guard !columns.isEmpty else { return }
        for (sample, width) in columns {
            let transientWidth = displayState.manualHaplotypeBandExpanded
                ? (manualHaplotypeTransientMinimumWidths[sample] ?? 0)
                    / max(contentTypographyScale, 0.01)
                : 0
            // A programmatic auto-fit floor is presentation state, not a user
            // resize. Preserve the stored preference unless the analyst has
            // deliberately widened the column beyond that floor.
            if sample != userResizedSample,
               transientWidth > 0,
               width <= transientWidth + 0.5 {
                if sampleColumnWidthsByStableID[sample] == nil {
                    sampleColumnWidthsByStableID[sample] = 68
                }
            } else {
                sampleColumnWidthsByStableID[sample] = width
            }
        }

        let visibleOrder = columns.map(\.0)
        let visibleSet = Set(visibleOrder)
        var replacement = visibleOrder.makeIterator()
        preferredSampleColumnOrder = preferredSampleColumnOrder.map { sample in
            guard visibleSet.contains(sample) else { return sample }
            return replacement.next() ?? sample
        }
        let known = Set(preferredSampleColumnOrder)
        preferredSampleColumnOrder.append(
            contentsOf: sampleNames.filter { !known.contains($0) }
        )
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

    private func deferManualHaplotypeTransition(
        _ transition: GenotypeManualHaplotypeDraftCoordinator.Transition,
        mutation: @escaping @MainActor () -> Void
    ) -> Bool {
        guard !isApplyingApprovedManualHaplotypeTransition,
              let onManualHaplotypeTransitionPreflight else {
            return false
        }
        return onManualHaplotypeTransitionPreflight(transition) {
            [weak self] in
            guard let self else { return }
            isApplyingApprovedManualHaplotypeTransition = true
            mutation()
            isApplyingApprovedManualHaplotypeTransition = false
        }
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
        suppressNativeFilterSelectionTracking = true
        nativeFilterActionGeneration &+= 1
        let actionGeneration = nativeFilterActionGeneration
        setFilterText(
            sender.stringValue,
            selectedRange: filterEditorSelectedRange()
        )
        DispatchQueue.main.async { [weak self] in
            guard let self,
                  self.nativeFilterActionGeneration
                    == actionGeneration else {
                return
            }
            self.restoreNativeFilterState(
                self.committedNativeFilterState
            )
            self.suppressNativeFilterSelectionTracking = false
        }
    }

    @objc private func filterEditorSelectionDidChange(
        _ notification: Notification
    ) {
        guard !suppressNativeFilterSelectionTracking,
              let editor = filterField.currentEditor() as? NSTextView,
              let sourceEditor = notification.object as? NSTextView,
              sourceEditor === editor,
              editor.string == filterText else {
            return
        }
        committedNativeFilterState = NativeFilterState(
            text: filterText,
            selectedRange: normalizedFilterSelectionRange(
                editor.selectedRange(),
                for: filterText
            )
        )
    }

    private func filterEditorSelectedRange() -> NSRange {
        guard let editor = filterField.currentEditor() as? NSTextView else {
            return committedNativeFilterState.selectedRange
        }
        return normalizedFilterSelectionRange(
            editor.selectedRange(),
            for: editor.string
        )
    }

    private func restoreNativeFilterState(
        _ state: NativeFilterState
    ) {
        filterField.stringValue = state.text
        guard let editor = filterField.currentEditor() as? NSTextView else {
            return
        }
        editor.string = state.text
        editor.setSelectedRange(
            normalizedFilterSelectionRange(
                state.selectedRange,
                for: state.text
            )
        )
    }

    private func normalizedFilterSelectionRange(
        _ range: NSRange,
        for text: String
    ) -> NSRange {
        let length = (text as NSString).length
        let location = min(range.location, length)
        return NSRange(
            location: location,
            length: min(range.length, length - location)
        )
    }

    @objc private func locusChanged(_ sender: NSPopUpButton) {
        let requestedLocus =
            sender.selectedItem?.representedObject as? String
        let previousLocus = selectedFilterLocus
        if deferManualHaplotypeTransition(.filter, mutation: {
            [weak self] in
            self?.applyLocusFilter(requestedLocus)
        }) {
            selectLocusPopupItem(previousLocus)
            return
        }
        selectedFilterLocus = requestedLocus
        applyFilterAndSort()
    }

    private func applyLocusFilter(_ locus: String?) {
        selectedFilterLocus = locus
        selectLocusPopupItem(locus)
        applyFilterAndSort()
    }

    private func selectLocusPopupItem(_ locus: String?) {
        if let index = locusPopup.itemArray.firstIndex(where: {
            ($0.representedObject as? String) == locus
        }) {
            locusPopup.selectItem(at: index)
        }
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
            unnameableDocument: result.mhcUnnameableClusters,
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

    private func isProvisionalExon2(_ row: GenotypeCandidateMatrixRow) -> Bool {
        provisionalExon2Genotypes.contains(row.genotype)
    }

    private var provisionalExon2Tint: AnnotationColor {
        AnnotationColor(
            red: 1.0,
            green: 0.62,
            blue: 0.0,
            alpha: accessibilityDisplayShouldIncreaseContrast ? 0.30 : 0.18
        )
    }

    private func updateReviewLegend() {
        let provisional = provisionalExon2Genotypes.isEmpty
            ? ""
            : "   ◼ Provisional exon 2"
        let text =
            "[n] False positive   ▣ False negative   ◥ Comment\(provisional)"
        let attributed = NSMutableAttributedString(
            string: text,
            attributes: [.foregroundColor: NSColor.secondaryLabelColor]
        )
        if let swatchRange = text.range(of: "◼ Provisional exon 2") {
            attributed.addAttribute(
                .foregroundColor,
                value: NSColor.systemOrange,
                range: NSRange(swatchRange, in: text)
            )
        }
        reviewLegend.attributedStringValue = attributed
        let provisionalAccessibility = provisionalExon2Genotypes.isEmpty
            ? ""
            : " amber allele identity means Provisional exon 2;"
        reviewLegend.setAccessibilityLabel(
            "Matrix review legend:\(provisionalAccessibility) bracketed read count means false positive; inner frame means false negative; folded corner means comment."
        )
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

    private func applyFilterAndSort(
        preserving semanticScrollAnchor: SemanticScrollAnchor? = nil
    ) {
        let semanticScrollAnchor = semanticScrollAnchor ?? captureSemanticScrollAnchor()
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
            // Manual row visibility precedes shared quick search.
            if !visibilityState.allows(row: row.id) {
                return false
            }
            if let quickSearchRowIDs,
               !quickSearchRowIDs.contains(row.id) {
                return false
            }
            // Inspector filters are applied after both stable-ID masks.
            if let selectedFilterLocus, row.locus != selectedFilterLocus {
                return false
            }
            if !matrixRowFilter.isEmpty,
               !rowMatchesIdentity(row, filter: matrixRowFilter) {
                return false
            }
            // Support thresholds are last. A row cannot survive on support
            // from a sample hidden by manual/search/Inspector sample masks.
            guard row.sampleSupport.contains(where: { activeSamples.contains($0.sample) }) else {
                return false
            }
            let minimumReads = displayState.activeMinimumReads
            if minimumReads > 0,
               !row.sampleSupport.contains(where: {
                   activeSamples.contains($0.sample)
                       && $0.passedUniqueReads >= minimumReads
               }) {
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
        onVisibleProjectionChanged?()
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
        let y = pinnedScrollView.contentView.bounds.minY
        let sampleX = scrollView.contentView.bounds.minX
        let row: Int?
        if visibleRows.isEmpty {
            row = nil
        } else {
            let hitRow = pinnedTableView.row(at: NSPoint(x: 0, y: y))
            let resolved = hitRow >= 0
                ? hitRow
                : min(
                    max(Int(floor(y / max(1, pinnedTableView.rowHeight))), 0),
                    visibleRows.count - 1
                )
            row = visibleRows.indices.contains(resolved) ? resolved : nil
        }
        let sampleOrder = visibleSampleNamesInColumnOrder()
        var leadingColumn = tableView.column(at: NSPoint(x: sampleX, y: 0))
        if leadingColumn < 0, !tableView.tableColumns.isEmpty {
            leadingColumn = tableView.tableColumns.indices.min {
                abs(tableView.rect(ofColumn: $0).minX - sampleX)
                    < abs(tableView.rect(ofColumn: $1).minX - sampleX)
            } ?? -1
        }
        let leadingSampleID = leadingColumn >= 0
            ? sampleName(forColumnAt: leadingColumn)
            : nil
        let leadingSampleIndex = leadingSampleID.flatMap {
            sampleOrder.firstIndex(of: $0)
        }
        let withinSampleOffset = leadingColumn >= 0
            ? sampleX - tableView.rect(ofColumn: leadingColumn).minX
            : 0
        return SemanticScrollAnchor(
            rowID: row.map { visibleRows[$0].id },
            previousRowIndex: row,
            previousRowIDs: visibleRows.map(\.id),
            withinRowOffset: row.map {
                y - pinnedTableView.rect(ofRow: $0).minY
            } ?? 0,
            pinnedHorizontalOrigin: pinnedScrollView.contentView.bounds.minX,
            sampleHorizontalOrigin: sampleX,
            leadingSampleID: leadingSampleID,
            leadingSampleIndex: leadingSampleIndex,
            previousSampleIDs: sampleOrder,
            withinSampleOffset: withinSampleOffset
        )
    }

    private func restoreSemanticScrollAnchor(_ anchor: SemanticScrollAnchor?) {
        guard let anchor else { return }
        var nextIndex: Int?
        if let rowID = anchor.rowID,
           let stableIndex = visibleRowIndexByID[rowID] {
            nextIndex = stableIndex
        } else if let previousRowIndex = anchor.previousRowIndex,
                  !visibleRows.isEmpty {
            let survivingIDs = Set(visibleRows.map(\.id))
            var nearestID: GenotypeCandidateMatrixRowID?
            for distance in 1...max(1, anchor.previousRowIDs.count) {
                let successor = previousRowIndex + distance
                if anchor.previousRowIDs.indices.contains(successor),
                   survivingIDs.contains(anchor.previousRowIDs[successor]) {
                    nearestID = anchor.previousRowIDs[successor]
                    break
                }
                let predecessor = previousRowIndex - distance
                if anchor.previousRowIDs.indices.contains(predecessor),
                   survivingIDs.contains(anchor.previousRowIDs[predecessor]) {
                    nearestID = anchor.previousRowIDs[predecessor]
                    break
                }
            }
            nextIndex = nearestID.flatMap { visibleRowIndexByID[$0] }
                ?? min(previousRowIndex, visibleRows.count - 1)
        }
        let proposedY = nextIndex.map {
            pinnedTableView.rect(ofRow: $0).minY + anchor.withinRowOffset
        } ?? 0
        let proposedSampleX = restoredSampleHorizontalOrigin(for: anchor)
        withScrollSyncSuppressed {
            scroll(
                pinnedScrollView,
                to: NSPoint(x: anchor.pinnedHorizontalOrigin, y: proposedY)
            )
            scroll(
                scrollView,
                to: NSPoint(x: proposedSampleX, y: proposedY)
            )
        }
    }

    private func restoredSampleHorizontalOrigin(
        for anchor: SemanticScrollAnchor
    ) -> CGFloat {
        let nextOrder = visibleSampleNamesInColumnOrder()
        guard !nextOrder.isEmpty else { return 0 }
        let nextSet = Set(nextOrder)
        let sample: String?
        if let leadingSampleID = anchor.leadingSampleID,
           nextSet.contains(leadingSampleID) {
            sample = leadingSampleID
        } else if let leadingSampleIndex = anchor.leadingSampleIndex {
            var nearest: String?
            for distance in 1...max(1, anchor.previousSampleIDs.count) {
                let successor = leadingSampleIndex + distance
                if anchor.previousSampleIDs.indices.contains(successor),
                   nextSet.contains(anchor.previousSampleIDs[successor]) {
                    nearest = anchor.previousSampleIDs[successor]
                    break
                }
                let predecessor = leadingSampleIndex - distance
                if anchor.previousSampleIDs.indices.contains(predecessor),
                   nextSet.contains(anchor.previousSampleIDs[predecessor]) {
                    nearest = anchor.previousSampleIDs[predecessor]
                    break
                }
            }
            sample = nearest
        } else {
            sample = nil
        }
        guard let sample,
              let column = tableView.tableColumns.firstIndex(where: {
                  sampleColumnLookup[$0.identifier] == sample
              }) else {
            return anchor.sampleHorizontalOrigin
        }
        return tableView.rect(ofColumn: column).minX + anchor.withinSampleOffset
    }

    private func scroll(_ scrollView: NSScrollView, to origin: NSPoint) {
        let clipView = scrollView.contentView
        var bounds = clipView.bounds
        bounds.origin = origin
        clipView.scroll(to: clipView.constrainBoundsRect(bounds).origin)
        scrollView.reflectScrolledClipView(clipView)
    }

    private func withScrollSyncSuppressed(_ action: () -> Void) {
        let wasSuppressed = suppressScrollSync
        let previousSampleX = scrollView.contentView.bounds.origin.x
        suppressScrollSync = true
        action()
        suppressScrollSync = wasSuppressed
        guard !wasSuppressed,
              scrollView.contentView.bounds.origin.x
                != previousSampleX else {
            return
        }
        updateManualHaplotypeBandColumnGeometry()
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

    private func rowMatchesIdentity(_ row: GenotypeCandidateMatrixRow, filter: String) -> Bool {
        if row.locus.localizedCaseInsensitiveContains(filter)
            || row.genotype.localizedCaseInsensitiveContains(filter)
            || (row.stableClusterID?.localizedCaseInsensitiveContains(filter) ?? false)
            || (isProvisionalExon2(row)
                && "Provisional exon 2".localizedCaseInsensitiveContains(filter)) {
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

    /// The toolbar's shared quick search intentionally spans both matrix axes.
    /// Keep that behavior separate from the Inspector's allele-only filter.
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
                } else if let sample = sampleID(forSortKey: key) {
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

    private func sampleID(forSortKey key: String) -> String? {
        let prefix = "sample."
        guard key.hasPrefix(prefix) else { return nil }
        let sample = String(key.dropFirst(prefix.count))
        return sampleNames.contains(sample) ? sample : nil
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
        var seen = Set(sampleNames)
        let interpretedUnnameableIDs = Set(result.mhcUnnameableClusters?.clusters.compactMap {
            $0.candidateInterpretation == nil ? nil : $0.stableClusterID
        } ?? [])
        let candidateSamples = (
            validatedMHCCandidateDocument(from: result)?.observations.map(\.sampleID) ?? []
        ) + (result.mhcUnnameableClusters?.observations.compactMap {
            interpretedUnnameableIDs.contains($0.stableClusterID) ? $0.sampleID : nil
        } ?? [])
        let sortedCandidateSamples = candidateSamples.sorted {
            $0.localizedStandardCompare($1) == .orderedAscending
        }
        sampleNames.append(contentsOf: sortedCandidateSamples.filter { seen.insert($0).inserted })
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
        guard !isApplyingManualHaplotypeAutoFit else { return }
        guard !isApplyingContentTypography else { return }
        guard let resizedTable = notification.object as? NSTableView,
              resizedTable === pinnedTableView || resizedTable === tableView else {
            return
        }
        captureColumnTypographyBaselines(in: resizedTable)
        if resizedTable === tableView {
            let resizedSample: String? =
                (notification.userInfo?["NSTableColumn"]
                    as? NSTableColumn).flatMap { resizedColumn in
                        guard resizedTable.tableColumns.contains(
                            where: { $0 === resizedColumn }
                        ) else {
                            return nil
                        }
                        return sampleColumnLookup[
                            resizedColumn.identifier
                        ]
                    }
            captureStableSampleColumnState(
                userResizedSample: resizedSample
            )
            manualHaplotypeBandGeometryDirty = true
            manualHaplotypeBandCachedCoverageRect = .zero
            updateManualHaplotypeBandColumnGeometry()
            return
        }
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
            let selectorLabel = "Select allele row \(biologicalAlleleDisplayName(for: sharedCall))"
            cell.configure(
                rowID: sharedCall.id,
                label: hasNativeRowComment
                    ? "\(selectorLabel). \(rowAccessibilityLabel(sharedCall))"
                    : selectorLabel,
                isSelected: selectedTargetsContainRow(sharedCall),
                commentFoldSize: hasNativeRowComment ? semanticGeometry().commentFoldSize : nil,
                onAccessibilityValueChanged: { [weak self] in
                    self?.recordAccessibilityValueChangedNotification()
                },
                onAccessibilityFocusChanged: { [weak self] button, focused in
                    self?.selectorAccessibilityFocusChanged(button, focused: focused)
                },
                onPress: { [weak self] rowID, modifiers in
                    self?.selectRowFromSelector(rowID, modifiers: modifiers) ?? false
                }
            )
            cell.toolTip = rowTooltip(
                row: sharedCall,
                fallback: "Select \(sharedCall.genotype)"
            )
            cell.setAccessibilityElement(false)
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
        // AppKit also emits selection notifications after row reloads and
        // programmatic restoration. Only a delegate-approved native selection
        // gesture owns a snapshot and may change the semantic matrix selection.
        guard let nativeState = pendingNativeTableSelectionState else { return }
        pendingNativeTableSelectionState = nil
        let sourceTable = notification.object as? NSTableView
        let selectedRows = IndexSet((sourceTable ?? tableView).selectedRowIndexes.filter { $0 >= 0 && $0 < visibleRows.count })
        let selectedRowIDs = selectedRows.map {
            visibleRows[$0].id
        }
        let preferredSample = selectedSampleName
        let previousPinnedRows = nativeState.pinnedRows
        let previousSampleRows = nativeState.sampleRows
        let scrollOrigins = nativeState.scrollOrigins
        if deferManualHaplotypeTransition(.selection, mutation: {
            [weak self] in
            guard let self else { return }
            self.applyNativeTableSelection(
                rowIDs: selectedRowIDs,
                preferredSample: preferredSample
            )
        }) {
            restoreNativeTableSelection(
                pinnedRows: previousPinnedRows,
                sampleRows: previousSampleRows,
                scrollOrigins: scrollOrigins
            )
            return
        }
        applyNativeTableSelection(
            selectedRows,
            preferredSample: selectedSampleName
        )
    }

    func selectionShouldChange(in tableView: NSTableView) -> Bool {
        guard tableView === pinnedTableView
                || tableView === self.tableView else {
            return true
        }
        pendingNativeTableSelectionState =
            NativeTableSelectionState(
                pinnedRows:
                    pinnedTableView.selectedRowIndexes,
                sampleRows:
                    self.tableView.selectedRowIndexes,
                scrollOrigins: matrixContentScrollOrigins
            )
        return true
    }

    private func applyNativeTableSelection(
        _ selectedRows: IndexSet,
        preferredSample: String?
    ) {
        guard !selectedRows.isEmpty else {
            clearSelectionAfterColumnToggle()
            return
        }
        selectRowIndexes(selectedRows, byExtendingSelection: false)
        if selectedRows.count > 1 {
            selectVisibleRows(Array(selectedRows), sample: preferredSample)
            return
        }
        let selectedRow = selectedRows[selectedRows.startIndex]
        selectVisibleRow(selectedRow, sample: preferredSample)
    }

    private func applyNativeTableSelection(
        rowIDs: [GenotypeCandidateMatrixRowID],
        preferredSample: String?
    ) {
        let indexes = IndexSet(rowIDs.compactMap { rowID in
            visibleRows.firstIndex(where: { $0.id == rowID })
        })
        guard rowIDs.isEmpty || !indexes.isEmpty else { return }
        let visiblePreferredSample = preferredSample.flatMap { sample in
            visibleSampleNames.contains(sample) ? sample : nil
        }
        applyNativeTableSelection(
            indexes,
            preferredSample: visiblePreferredSample
        )
    }

    private var matrixContentScrollOrigins:
        GenotypeMatrixContentScrollOrigins {
        GenotypeMatrixContentScrollOrigins(
            pinned: pinnedScrollView.contentView.bounds.origin,
            samples: scrollView.contentView.bounds.origin
        )
    }

    private func restoreNativeTableSelection(
        pinnedRows: IndexSet,
        sampleRows: IndexSet,
        scrollOrigins: GenotypeMatrixContentScrollOrigins
    ) {
        suppressSelectionClearedCallback = true
        pinnedTableView.selectRowIndexes(
            pinnedRows,
            byExtendingSelection: false
        )
        tableView.selectRowIndexes(
            sampleRows,
            byExtendingSelection: false
        )
        suppressSelectionClearedCallback = false
        withScrollSyncSuppressed {
            pinnedScrollView.contentView.setBoundsOrigin(
                scrollOrigins.pinned
            )
            scrollView.contentView.setBoundsOrigin(
                scrollOrigins.samples
            )
        }
        pinnedScrollView.reflectScrolledClipView(
            pinnedScrollView.contentView
        )
        scrollView.reflectScrolledClipView(
            scrollView.contentView
        )
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
        if isProvisionalExon2(row) {
            lines.append("Provisional exon 2")
        }
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
        let manualHaplotypeEditSample: String?
        if manualHaplotypeEditorEnabled,
           selectedMatrixTargets.count == 1,
           case let .column(sample) = selectedMatrixTargets[0] {
            manualHaplotypeEditSample = sample
        } else {
            manualHaplotypeEditSample = nil
        }
        return GenotypeMatrixContextMenuSnapshot(
            selectionTargets: selectedMatrixTargets,
            capability: matrixReviewCapability,
            visibilityCapability: matrixVisibilityCapability,
            keyModifierRawValue: NSEvent.ModifierFlags([.command, .option]).rawValue,
            manualHaplotypeEditSample: manualHaplotypeEditSample,
            selectedRowCallSampleCount: selectedRowCallSamples()?.count
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
            menu.addItem(makeContextMenuItem(
                from: itemState,
                selectionTargets: state.selectionTargets
            ))
        }
        if !state.visibilityItems.isEmpty || !state.visibilitySubmenus.isEmpty {
            menu.addItem(.separator())
        }
        for itemState in state.visibilityItems where itemState.command != .resetVisibility {
            menu.addItem(makeContextMenuItem(
                from: itemState,
                selectionTargets: state.selectionTargets
            ))
        }
        for submenuState in state.visibilitySubmenus {
            let item = NSMenuItem(
                title: submenuState.title,
                action: nil,
                keyEquivalent: ""
            )
            item.identifier = NSUserInterfaceItemIdentifier(
                submenuState.kind == .rowVisibility
                    ? "genotype-matrix-visibility-rows"
                    : "genotype-matrix-visibility-columns"
            )
            let submenu = NSMenu(title: submenuState.title)
            submenu.autoenablesItems = false
            for childState in submenuState.items {
                submenu.addItem(makeContextMenuItem(
                    from: childState,
                    selectionTargets: state.selectionTargets
                ))
            }
            item.submenu = submenu
            menu.addItem(item)
        }
        for itemState in state.visibilityItems where itemState.command == .resetVisibility {
            menu.addItem(makeContextMenuItem(
                from: itemState,
                selectionTargets: state.selectionTargets
            ))
        }
        return menu
    }

    private func makeContextMenuItem(
        from state: GenotypeMatrixContextMenuItemState,
        selectionTargets: [GenotypeAnnotationSidecar.MatrixTarget]
    ) -> NSMenuItem {
        let item = NSMenuItem(
            title: state.title,
            action: #selector(performMatrixContextMenuCommand(_:)),
            keyEquivalent: state.keyEquivalent
        )
        item.target = self
        item.representedObject = ContextMenuCommandPayload(
            command: state.command,
            selectionTargets: selectionTargets
        )
        item.keyEquivalentModifierMask = NSEvent.ModifierFlags(
            rawValue: state.keyModifierRawValue
        )
        item.isEnabled = state.availability.isEnabled
        item.toolTip = state.availability.disabledReason
        item.identifier = contextMenuIdentifier(for: state.command)
        return item
    }

    private func contextMenuIdentifier(
        for command: GenotypeMatrixContextCommand
    ) -> NSUserInterfaceItemIdentifier? {
        let value: String
        switch command {
        case .hideSelectedRows:
            value = "genotype-matrix-visibility-hide-rows"
        case .showOnlySelectedRows:
            value = "genotype-matrix-visibility-show-only-rows"
        case .hideSelectedColumns:
            value = "genotype-matrix-visibility-hide-columns"
        case .showOnlySelectedColumns:
            value = "genotype-matrix-visibility-show-only-columns"
        case .showOnlyColumnsWithSelectedRowCalls:
            value = "genotype-matrix-visibility-show-only-row-calls"
        case .resetVisibility:
            value = "genotype-matrix-visibility-show-all"
        case .markFalsePositive, .markFalseNegative, .clearReview,
             .editComment, .removeComments, .selectSupportedCells:
            return nil
        case .editManualHaplotypeAssignments:
            value = "genotype-matrix-edit-manual-haplotypes"
        }
        return NSUserInterfaceItemIdentifier(value)
    }

    @objc private func performMatrixContextMenuCommand(_ sender: NSMenuItem) {
        guard let payload = sender.representedObject as? ContextMenuCommandPayload else {
            return
        }
        if payload.command.isSelectionTargetedVisibilityCommand,
           payload.selectionTargets != Set(selectedMatrixTargets) {
            return
        }
        if payload.command == .editManualHaplotypeAssignments,
           payload.selectionTargets != Set(selectedMatrixTargets) {
            return
        }
        _ = performContextCommand(payload.command)
    }

    @discardableResult
    private func performContextCommand(_ command: GenotypeMatrixContextCommand) -> Bool {
        let state = makeContextMenuState()
        let currentItems = state.visibilityItems
            + state.visibilitySubmenus.flatMap(\.items)
            + state.items
        guard let item = currentItems.first(where: { $0.command == command }),
              item.availability.isEnabled else {
            return false
        }
        guard visibilityCommandIsCurrentlyEnabled(command) else {
            return false
        }
        let targets = selectedMatrixTargets
        switch command {
        case .hideSelectedRows:
            return hideSelectedRows()
        case .showOnlySelectedRows:
            return showOnlySelectedRows()
        case .hideSelectedColumns:
            return hideSelectedColumns()
        case .showOnlySelectedColumns:
            return showOnlySelectedColumns()
        case .showOnlyColumnsWithSelectedRowCalls:
            return showOnlyColumnsWithSelectedRowCalls()
        case .resetVisibility:
            return resetVisibility()
        case .markFalsePositive:
            guard !targets.isEmpty else { return false }
            onMatrixReviewRequested?(.init(targets: targets, intent: .set(.falsePositive)))
        case .markFalseNegative:
            guard !targets.isEmpty else { return false }
            onMatrixReviewRequested?(.init(targets: targets, intent: .set(.falseNegative)))
        case .clearReview:
            guard !targets.isEmpty else { return false }
            onMatrixReviewRequested?(.init(targets: targets, intent: .clear))
        case .editComment:
            guard !targets.isEmpty else { return false }
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
            guard !targets.isEmpty else { return false }
            onMatrixCommentEditRequested?(.init(targets: targets, intent: .remove))
        case .selectSupportedCells:
            guard !targets.isEmpty else { return false }
            let supported = supportedCellTargets(from: targets, minimumReads: 1)
            publishMatrixTargetSelection(supported, anchor: supported.last)
        case .editManualHaplotypeAssignments:
            guard targets.count == 1,
                  case let .column(sample) = targets[0],
                  manualHaplotypeEditorEnabled else {
                return false
            }
            onManualHaplotypeEditRequested?(sample)
        }
        return true
    }

    private func visibilityCommandIsCurrentlyEnabled(
        _ command: GenotypeMatrixContextCommand
    ) -> Bool {
        switch command {
        case .hideSelectedRows:
            return matrixVisibilityCapability.canHideSelectedRows
        case .showOnlySelectedRows:
            return matrixVisibilityCapability.canShowOnlySelectedRows
        case .hideSelectedColumns:
            return matrixVisibilityCapability.canHideSelectedColumns
        case .showOnlySelectedColumns:
            return matrixVisibilityCapability.canShowOnlySelectedColumns
        case .showOnlyColumnsWithSelectedRowCalls:
            return !(selectedRowCallSamples()?.isEmpty ?? true)
        case .resetVisibility:
            return matrixVisibilityCapability.canResetVisibility
        case .markFalsePositive, .markFalseNegative, .clearReview,
             .editComment, .removeComments, .selectSupportedCells,
             .editManualHaplotypeAssignments:
            return true
        }
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
        guard row >= 0, row < visibleRows.count else { return }
        let rowID = visibleRows[row].id
        if deferManualHaplotypeTransition(.selection, mutation: {
            [weak self] in
            _ = self?.selectRowFromSelector(
                rowID,
                modifiers: modifiers
            )
        }) {
            return
        }
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

    private func selectRowFromSelector(
        _ rowID: GenotypeCandidateMatrixRowID,
        modifiers: NSEvent.ModifierFlags
    ) -> Bool {
        guard let row = visibleRows.firstIndex(where: { $0.id == rowID }) else {
            return false
        }
        selectRowFromDirectClick(row, modifiers: modifiers)
        return true
    }

    private func selectCellFromDirectClick(_ row: Int, sample: String, modifiers: NSEvent.ModifierFlags) {
        guard row >= 0, row < visibleRows.count else { return }
        let rowID = visibleRows[row].id
        if deferManualHaplotypeTransition(.selection, mutation: {
            [weak self] in
            self?.selectCellFromSelector(
                rowID,
                sample: sample,
                modifiers: modifiers
            )
        }) {
            return
        }
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

    private func selectCellFromSelector(
        _ rowID: GenotypeCandidateMatrixRowID,
        sample: String,
        modifiers: NSEvent.ModifierFlags
    ) {
        guard let row = visibleRows.firstIndex(where: {
            $0.id == rowID
        }), visibleSampleNames.contains(sample) else {
            return
        }
        selectCellFromDirectClick(
            row,
            sample: sample,
            modifiers: modifiers
        )
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
        if deferManualHaplotypeTransition(.selection, mutation: {
            [weak self] in
            self?.selectSampleColumn(
                clicked: sample,
                modifiers: modifiers
            )
        }) {
            return
        }
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
        if deferManualHaplotypeTransition(.selection, mutation: {
            [weak self] in self?.clearSelectionAfterColumnToggle()
        }) {
            return
        }
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
        if deferManualHaplotypeTransition(.selection, mutation: {
            [weak self] in self?.publishColumnSelection(samples)
        }) {
            return
        }
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

    func visibleSampleEvidenceRows(
        sample: String
    ) -> [GenotypeSampleEvidenceRow] {
        visibleRows.compactMap { row -> GenotypeSampleEvidenceRow? in
            let support = support(for: sample, row: row)
            let semantics = semanticCellState(
                for: sample,
                row: row
            )
            guard support != nil
                    || semantics.review == .falseNegative else {
                return nil
            }
            var indicators:
                GenotypeSampleEvidenceRow.Indicators = []
            switch semantics.review {
            case .falsePositive:
                indicators.insert(.falsePositive)
            case .falseNegative:
                indicators.insert(.falseNegative)
            case nil:
                break
            }
            if semantics.commentCounts.total > 0 {
                indicators.insert(.comment)
            }
            return GenotypeSampleEvidenceRow(
                id: row.id,
                allele: biologicalAlleleDisplayName(for: row),
                readSupport: support?.passedUniqueReads,
                indicators: indicators,
                accessibilityLabel:
                    sampleEvidenceAccessibilityLabel(
                        row: row,
                        semantics: semantics
                    ),
                semanticQualifiers:
                    sampleEvidenceSemanticQualifiers(row: row),
                commentCounts: semantics.commentCounts
            )
        }
    }

    private func sampleEvidenceSemanticQualifiers(
        row: GenotypeCandidateMatrixRow
    ) -> [String] {
        if isProvisionalExon2(row) {
            return ["Provisional exon 2"]
        }
        var qualifiers: [String] = []
        switch row.candidateClassification {
        case .novel:
            qualifiers.append("Novel candidate")
        case .extension:
            qualifiers.append("Extension candidate")
        case .partialExtension:
            qualifiers.append("Partial extension candidate")
        case nil:
            break
        }
        if row.isIncompleteReferenceSpanCandidate {
            qualifiers.append("Incomplete reference span")
        }
        return qualifiers
    }

    private func sampleEvidenceAccessibilityLabel(
        row: GenotypeCandidateMatrixRow,
        semantics: GenotypeMatrixCellSemanticState
    ) -> String {
        var parts: [String] = []
        if isProvisionalExon2(row) {
            parts.append("Designation: Provisional exon 2.")
        }
        switch row.candidateClassification {
        case .novel:
            parts.append("Candidate classification: novel.")
        case .extension:
            parts.append("Candidate classification: extension.")
        case .partialExtension:
            parts.append("Candidate classification: partial extension.")
        case nil:
            break
        }
        if row.isIncompleteReferenceSpanCandidate {
            parts.append("Incomplete reference span; reviewable but not reference-ready.")
        }
        parts.append(semantics.accessibilityLabel)
        return parts.joined(separator: " ")
    }

    var visibleComparisonRowIDs: [GenotypeCandidateMatrixRowID] {
        visibleRows.map(\.id)
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
            fraction: fraction,
            semantics: GenotypeVisibleSampleAlleleSemantics(
                isProvisionalExon2: isProvisionalExon2(row),
                candidateClassification: row.candidateClassification,
                cell: semanticCellState(for: sample, row: row)
            )
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
        if deferManualHaplotypeTransition(.selection, mutation: {
            [weak self] in
            self?.selectVisibleRow(rowIndex, sample: sample)
        }) {
            return
        }
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
        if deferManualHaplotypeTransition(.selection, mutation: {
            [weak self] in
            self?.selectVisibleRows(rowIndexes, sample: sample)
        }) {
            return
        }
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
        if deferManualHaplotypeTransition(.selection, mutation: {
            [weak self] in
            self?.publishMatrixTargetSelection(targets, anchor: anchor)
        }) {
            return
        }
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
        (pinnedTableView.headerView as? GenotypeMatrixHeaderView)?
            .refreshSelectorButtons()
        (tableView.headerView as? GenotypeMatrixHeaderView)?
            .refreshSelectorButtons()
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
        captureStableSampleColumnState()
        rebuildVisibleColumnIndex()
        manualHaplotypeBandGeometryDirty = true
        manualHaplotypeBandCachedCoverageRect = .zero
        updateManualHaplotypeBandColumnGeometry()
    }

    @discardableResult
    func showOnlySelectedRows() -> Bool {
        return applyVisibilityState(
            visibilityState.showingOnlyRows(
                matrixVisibilityCapability.selection.rowIDs
            ),
            announcement: "Showing only selected rows."
        )
    }

    @discardableResult
    func hideSelectedRows() -> Bool {
        return applyVisibilityState(
            visibilityState.hidingRows(
                matrixVisibilityCapability.selection.rowIDs
            ),
            announcement: "Selected rows hidden."
        )
    }

    @discardableResult
    func showAllRows() -> Bool {
        applyVisibilityState(
            visibilityState.showingAllRows(),
            announcement: "All rows shown."
        )
    }

    @discardableResult
    func showOnlySelectedColumns() -> Bool {
        return applyVisibilityState(
            visibilityState.showingOnlySamples(
                matrixVisibilityCapability.selection.sampleIDs
            ),
            announcement: "Showing only selected columns."
        )
    }

    @discardableResult
    private func showOnlyColumnsWithSelectedRowCalls() -> Bool {
        guard let samples = selectedRowCallSamples(), !samples.isEmpty else {
            return false
        }
        return applyVisibilityState(
            visibilityState.showingOnlySamples(samples),
            announcement: "Showing only columns with genotype calls in the selected row."
        )
    }

    private func selectedRowCallSamples() -> Set<String>? {
        guard selectedMatrixTargets.count == 1,
              case let .row(locus, genotype, stableClusterID) = selectedMatrixTargets[0] else {
            return nil
        }
        let rowID: GenotypeCandidateMatrixRowID = stableClusterID.map {
            .candidate(stableClusterID: $0)
        } ?? .known(locus: locus, genotype: genotype)
        guard let row = allRows.first(where: { $0.id == rowID }) else { return nil }
        return Set(row.sampleSupport.compactMap { support in
            support.passedUniqueReads > 0 ? support.sample : nil
        })
    }

    @discardableResult
    func hideSelectedColumns() -> Bool {
        return applyVisibilityState(
            visibilityState.hidingSamples(
                matrixVisibilityCapability.selection.sampleIDs
            ),
            announcement: "Selected columns hidden."
        )
    }

    @discardableResult
    func showAllColumns() -> Bool {
        applyVisibilityState(
            visibilityState.showingAllSamples(),
            announcement: "All columns shown."
        )
    }

    func clearSelectionFilter() {
        resetVisibility()
    }

    @discardableResult
    func resetVisibility() -> Bool {
        applyVisibilityState(
            visibilityState.reset(),
            announcement: "All rows and columns shown."
        )
    }

    @discardableResult
    private func applyVisibilityState(
        _ next: GenotypeMatrixVisibilityState,
        announcement: String
    ) -> Bool {
        if deferManualHaplotypeTransition(.visibility, mutation: {
            [weak self] in
            _ = self?.applyVisibilityState(
                next,
                announcement: announcement
            )
        }) {
            return false
        }
        guard next != visibilityState else { return false }
#if DEBUG
        testingDidFallBackAccessibilityFocusToMatrix = false
#endif
        let semanticScrollAnchor = captureSemanticScrollAnchor()
        let focusedSelector = focusedSelectorIdentity()
        let previousRows = visibleRows.map(\.id)
        let previousSamples = visibleSampleNamesInColumnOrder()
        let previousActiveSamples = activeSampleNames()
        visibilityState = next
#if DEBUG
        testingVisibilityMutationPassCount += 1
#endif
        if activeSampleNames() != previousActiveSamples {
            rebuildColumns()
        }
        applyFilterAndSort(preserving: semanticScrollAnchor)
        publishVisibilityCapability()
        restoreFocusedSelector(
            focusedSelector,
            previousRows: previousRows,
            previousSamples: previousSamples
        )
        visibilityAnnouncementPoster.post(announcement, priority: .medium)
        return true
    }

    private func selectorAccessibilityFocusChanged(
        _ button: GenotypeMatrixSelectorButton,
        focused: Bool
    ) {
        if focused {
            if let previous = accessibilityFocusedSelectorButton,
               previous !== button {
                previous.setAccessibilityFocused(false)
            }
            accessibilityFocusedSelectorButton = button
        } else if accessibilityFocusedSelectorButton === button {
            accessibilityFocusedSelectorButton = nil
        }
    }

    private func focusedSelectorIdentity() -> FocusedSelectorIdentity? {
        let accessibilityButton = accessibilityFocusedSelectorButton
        let button = accessibilityButton
            ?? (window?.firstResponder as? GenotypeMatrixSelectorButton)
        guard let button, let identity = button.selectorIdentity else {
            return nil
        }
        let usesAccessibilityFocus = accessibilityButton === button
        switch identity {
        case let .row(rowID):
            return .init(
                identity: .row(rowID),
                usesAccessibilityFocus: usesAccessibilityFocus
            )
        case let .column(sample):
            return .init(
                identity: .column(sample),
                usesAccessibilityFocus: usesAccessibilityFocus
            )
        case .selectAll:
            return .init(
                identity: .selectAll,
                usesAccessibilityFocus: usesAccessibilityFocus
            )
        }
    }

    private func restoreFocusedSelector(
        _ identity: FocusedSelectorIdentity?,
        previousRows: [GenotypeCandidateMatrixRowID],
        previousSamples: [String]
    ) {
        guard let identity, let window else { return }
        let target: NSView?
        switch identity.identity {
        case let .row(rowID):
            let survivingRows = visibleRows.map(\.id)
            let resolved = nearestSurvivingIdentity(
                rowID,
                previousOrder: previousRows,
                surviving: Set(survivingRows)
            )
            target = resolved.flatMap { rowSelectorButton(for: $0) }
        case let .column(sample):
            let survivingSamples = Set(visibleSampleNamesInColumnOrder())
            let resolved = nearestSurvivingIdentity(
                sample,
                previousOrder: previousSamples,
                surviving: survivingSamples
            )
            target = resolved.flatMap { columnSelectorButton(for: $0) }
        case .selectAll:
            target = selectAllSelectorButton()
        }
        let resolvedTarget = target ?? pinnedTableView
        if identity.usesAccessibilityFocus {
            if let button = resolvedTarget as? GenotypeMatrixSelectorButton {
                button.setAccessibilityFocused(true)
            } else {
                resolvedTarget.setAccessibilityFocused(true)
#if DEBUG
                testingDidFallBackAccessibilityFocusToMatrix = true
#endif
            }
            postAccessibilityFocusChanged(for: resolvedTarget)
        } else if window.makeFirstResponder(resolvedTarget) {
            postAccessibilityFocusChanged(for: resolvedTarget)
        }
    }

    private func nearestSurvivingIdentity<Identity: Hashable>(
        _ identity: Identity,
        previousOrder: [Identity],
        surviving: Set<Identity>
    ) -> Identity? {
        if surviving.contains(identity) {
            return identity
        }
        guard let index = previousOrder.firstIndex(of: identity) else {
            return previousOrder.first(where: surviving.contains)
        }
        for distance in 1...max(1, previousOrder.count) {
            let successor = index + distance
            if previousOrder.indices.contains(successor),
               surviving.contains(previousOrder[successor]) {
                return previousOrder[successor]
            }
            let predecessor = index - distance
            if previousOrder.indices.contains(predecessor),
               surviving.contains(previousOrder[predecessor]) {
                return previousOrder[predecessor]
            }
        }
        return nil
    }

    private func rowSelectorButton(
        for rowID: GenotypeCandidateMatrixRowID
    ) -> GenotypeMatrixSelectorButton? {
        guard let row = visibleRows.firstIndex(where: { $0.id == rowID }),
              let column = pinnedTableView.tableColumns.firstIndex(where: {
                  $0.identifier == ColumnID.rowSelector
              }),
              let cell = pinnedTableView.view(
                  atColumn: column,
                  row: row,
                  makeIfNecessary: true
              ) as? GenotypeMatrixRowSelectorCellView else {
            return nil
        }
        return cell.accessibilitySelectorButton
    }

    private func columnSelectorButton(
        for sample: String
    ) -> GenotypeMatrixSelectorButton? {
        (tableView.headerView as? GenotypeMatrixHeaderView)?
            .selectorButton(matching: .column(sample))
    }

    private func selectAllSelectorButton() -> GenotypeMatrixSelectorButton? {
        (pinnedTableView.headerView as? GenotypeMatrixHeaderView)?
            .selectorButton(matching: .selectAll)
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
        let designation = isProvisionalExon2(row)
            ? " Designation: Provisional exon 2."
            : ""
        return "Allele row \(row.genotype), locus \(row.locus).\(designation) \(count) allele row \(suffix)."
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
            "Sample \(sample), genotype "
                + "\(biologicalAlleleDisplayName(for: row)), "
                + "locus \(row.locus).",
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

    private var manualHaplotypeEditorEnabled: Bool {
        manualHaplotypeEditingEligible
            && haplotypeBandMode == .manualAssignments
    }

    private var haplotypeBandIsVisible: Bool {
        haplotypeBandMode != .none
    }

    private var activeHaplotypeBandLoci: [String] {
        switch haplotypeBandMode {
        case .none:
            return []
        case .manualAssignments:
            return GenotypeManualHaplotypeAssignmentBandSnapshot.loci
                .map(\.workbookLabel)
        case .effectiveMiSeqCalls:
            return effectiveHaplotypeBandSnapshot.orderedLoci
        }
    }

    private func activeHaplotypeBandValues(sample: String) -> [String] {
        switch haplotypeBandMode {
        case .none:
            return []
        case .manualAssignments:
            return manualHaplotypeBandSnapshot.valuesBySample[sample]
                ?? Array(repeating: "—", count: 7)
        case .effectiveMiSeqCalls:
            return effectiveHaplotypeBandSnapshot.renderedValues(
                sample: sample
            )
        }
    }

    private func updateManualHaplotypeBand(
        assignments: [ManualHaplotypeAssignment]
    ) {
        guard manualHaplotypeEditorEnabled else {
            manualHaplotypeBandAssignments = []
            return
        }
        guard assignments != manualHaplotypeBandAssignments
                || Set(manualHaplotypeBandSnapshot.valuesBySample.keys)
                    != Set(sampleNames) else {
            return
        }
        manualHaplotypeBandAssignments = assignments
        let next = GenotypeManualHaplotypeAssignmentBandSnapshot(
            index: GenotypeManualHaplotypeAssignmentIndex(
                assignments: assignments
            ),
            samples: sampleNames
        )
        let changedSamples = next.changedSamples(
            comparedTo: manualHaplotypeBandSnapshot
        )
        manualHaplotypeBandSnapshot = next
        manualHaplotypeSampleBand.snapshot = next
#if DEBUG
        testingManualHaplotypeBandInvalidatedSampleSet.formUnion(
            changedSamples.filter { sample in
                manualHaplotypeSampleBand.columnFrames[sample]?
                    .intersects(manualHaplotypeSampleBand.bounds) == true
            }
        )
#endif
        manualHaplotypeSampleBand.invalidate(samples: changedSamples)
        updateManualHaplotypeHeaderAccessibility(samples: changedSamples)
        if displayState.manualHaplotypeBandExpanded {
            refreshManualHaplotypeAutoFit(
                samples: changedSamples,
                remeasure: true
            )
        } else {
            for sample in changedSamples {
                manualHaplotypeTransientMinimumWidths.removeValue(
                    forKey: sample
                )
            }
        }
    }

    private var manualHaplotypeBandRowHeight: CGFloat {
#if DEBUG
        if let scale = testingManualHaplotypeBandTypographyScaleOverride {
            return ceil(max(22, 22 * scale))
        }
#endif
        return resolvedContentTypography().tableRowHeight(
            minimum: 22,
            verticalPadding: 6
        )
    }

    private var manualHaplotypeBandFont: NSFont {
        let base = resolvedContentTypography().font(for: .body)
#if DEBUG
        if let scale = testingManualHaplotypeBandTypographyScaleOverride {
            return NSFont(
                descriptor: base.fontDescriptor,
                size: max(1, base.pointSize * scale)
            ) ?? base
        }
#endif
        return base
    }

    private var manualHaplotypeDisclosureAvailableWidth: CGFloat {
        max(1, pinnedWidthConstraint?.constant ?? 360)
    }

    private var manualHaplotypeDisclosureHeight: CGFloat {
        GenotypeManualHaplotypePinnedBandView.requiredDisclosureHeight(
            font: manualHaplotypeBandFont,
            availableWidth: manualHaplotypeDisclosureAvailableWidth,
            minimumHeight: manualHaplotypeBandRowHeight
        )
    }

    private var manualHaplotypeBandHeight: CGFloat {
        manualHaplotypeHeaderLayout(ordinaryHeight: 0).manualHeight
    }

    @discardableResult
    private func synchronizeManualHaplotypeDisclosureGeometry(
        force: Bool = false
    ) -> Bool {
        guard haplotypeBandIsVisible else { return false }
        let width = manualHaplotypeDisclosureAvailableWidth
        let height = manualHaplotypeDisclosureHeight
        let widthChanged =
            manualHaplotypePinnedBand.availableDisclosureWidth != width
        let heightChanged =
            manualHaplotypePinnedBand.disclosureHeight != height
                || manualHaplotypeSampleBand.disclosureHeight != height
        guard force || widthChanged || heightChanged else {
            return false
        }
        if force || widthChanged {
            manualHaplotypePinnedBand.availableDisclosureWidth = width
        }
        if force || heightChanged {
            manualHaplotypePinnedBand.disclosureHeight = height
            manualHaplotypeSampleBand.disclosureHeight = height
        }
        return heightChanged
    }

    private func applyManualHaplotypeBandPresentation() {
        let hidden = !haplotypeBandIsVisible
        pinnedScrollView.automaticallyAdjustsContentInsets = true
        scrollView.automaticallyAdjustsContentInsets = true
        if pinnedScrollView.contentInsets.top != 0 {
            var insets = pinnedScrollView.contentInsets
            insets.top = 0
            pinnedScrollView.contentInsets = insets
        }
        if scrollView.contentInsets.top != 0 {
            var insets = scrollView.contentInsets
            insets.top = 0
            scrollView.contentInsets = insets
        }
        manualHaplotypePinnedBand.isHidden = hidden
        manualHaplotypeSampleBand.isHidden = hidden
        let effectiveSnapshot = haplotypeBandMode == .effectiveMiSeqCalls
            ? effectiveHaplotypeBandSnapshot
            : nil
        manualHaplotypePinnedBand.setHaplotypeBand(
            mode: haplotypeBandMode,
            snapshot: effectiveSnapshot
        )
        manualHaplotypeSampleBand.setHaplotypeBand(
            mode: haplotypeBandMode,
            snapshot: effectiveSnapshot
        )
        manualHaplotypePinnedBand.isExpanded =
            displayState.manualHaplotypeBandExpanded
        manualHaplotypeSampleBand.isExpanded =
            displayState.manualHaplotypeBandExpanded
        manualHaplotypePinnedBand.font = manualHaplotypeBandFont
        manualHaplotypeSampleBand.font = manualHaplotypeBandFont
        synchronizeManualHaplotypeDisclosureGeometry(force: true)
        manualHaplotypePinnedBand.rowHeight =
            manualHaplotypeBandRowHeight
        manualHaplotypeSampleBand.rowHeight =
            manualHaplotypeBandRowHeight
        manualHaplotypePinnedBand.needsLayout = true
        manualHaplotypePinnedBand.needsDisplay = true
        manualHaplotypeSampleBand.needsDisplay = true
        manualHaplotypeBandGeometryDirty = true
        manualHaplotypeBandCachedCoverageRect = .zero
        updateNativeHeaderLayout()
        needsLayout = true
    }

    private func setManualHaplotypeBandExpandedPreservingViewport(
        _ expanded: Bool
    ) {
        guard displayState.manualHaplotypeBandExpanded != expanded else {
            return
        }
        let anchor = captureSemanticScrollAnchor()
        displayState.manualHaplotypeBandExpanded = expanded
        applyManualHaplotypeBandPresentation()
        if expanded {
            let unmeasuredSamples = Set(visibleSampleNames).filter {
                manualHaplotypeTransientMinimumWidths[$0] == nil
            }
            measureManualHaplotypeTransientMinimumWidths(
                samples: Set(unmeasuredSamples)
            )
        }
        refreshManualHaplotypeAutoFit(
            samples: Set(visibleSampleNames),
            remeasure: false
        )
        layoutSubtreeIfNeeded()
        restoreSemanticScrollAnchor(anchor)
    }

    private func manualHaplotypeHeaderLayout(
        ordinaryHeight: CGFloat
    ) -> GenotypeManualHaplotypeHeaderLayout {
        GenotypeManualHaplotypeHeaderLayout(
            isEligible: haplotypeBandIsVisible,
            isExpanded: displayState.manualHaplotypeBandExpanded,
            ordinaryHeight: ordinaryHeight,
            disclosureHeight: manualHaplotypeDisclosureHeight,
            rowHeight: manualHaplotypeBandRowHeight,
            locusCount: activeHaplotypeBandLoci.count
        )
    }

    private func updateNativeHeaderLayout(
        ordinaryHeight: CGFloat? = nil
    ) {
        let resolvedOrdinaryHeight = ordinaryHeight
            ?? (tableView.headerView as? GenotypeMatrixHeaderView)?
                .ordinaryHeaderHeight
            ?? 34
        let layout = manualHaplotypeHeaderLayout(
            ordinaryHeight: resolvedOrdinaryHeight
        )
        for header in [
            pinnedTableView.headerView as? GenotypeMatrixHeaderView,
            tableView.headerView as? GenotypeMatrixHeaderView,
        ].compactMap({ $0 }) {
            header.headerLayout = layout
        }
        pinnedScrollView.tile()
        scrollView.tile()
        updateManualHaplotypeBandColumnGeometry()
    }

    private func updateManualHaplotypeBandColumnGeometry() {
#if DEBUG
        testingManualHaplotypeGeometryUpdateCount += 1
#endif
        guard haplotypeBandIsVisible,
              manualHaplotypeBandHeight > 0,
              !manualHaplotypeSampleBand.bounds.isEmpty else {
            if !manualHaplotypeSampleBand.columnFrames.isEmpty {
                manualHaplotypeSampleBand.columnFrames = [:]
            }
            manualHaplotypeBandGeometryDirty = true
            manualHaplotypeBandHorizontalOffset = nil
            manualHaplotypeBandBoundsSize = .zero
            manualHaplotypeBandCachedCoverageRect = .zero
            return
        }
        let horizontalOffset = scrollView.contentView.bounds.origin.x
        let visibleBandRect = NSRect(
            x: horizontalOffset,
            y: 0,
            width: scrollView.contentView.bounds.width,
            height: manualHaplotypeBandHeight
        )
        if !manualHaplotypeBandGeometryDirty,
           manualHaplotypeBandHorizontalOffset != nil,
           manualHaplotypeBandBoundsSize == visibleBandRect.size,
           !manualHaplotypeSampleBand.columnFrames.isEmpty {
            if manualHaplotypeBandCachedCoverageRect.contains(
                visibleBandRect
            ) {
                manualHaplotypeBandHorizontalOffset = horizontalOffset
                return
            }
        }
        let overscanWidth: CGFloat
        if let cached = manualHaplotypeBandCachedOverscanWidth {
            overscanWidth = cached
        } else {
            overscanWidth =
                (tableView.tableColumns.lazy.map(\.width).max() ?? 68)
                    * 4
            manualHaplotypeBandCachedOverscanWidth = overscanWidth
        }
#if DEBUG
        testingManualHaplotypeGeometryRecomputationCount += 1
#endif
        let cachedBandRect = visibleBandRect.insetBy(
            dx: -overscanWidth,
            dy: 0
        )
        let cachedTableRect = NSRect(
            x: cachedBandRect.minX,
            y: tableView.bounds.minY,
            width: cachedBandRect.width,
            height: max(1, tableView.bounds.height)
        )
        let boundedColumnIndexes: ClosedRange<Int>?
        if tableView.numberOfColumns > 0 {
            let firstColumnRect = tableView.rect(ofColumn: 0)
            let lastColumnRect = tableView.rect(
                ofColumn: tableView.numberOfColumns - 1
            )
            let firstIndex = cachedTableRect.minX
                <= firstColumnRect.minX
                ? 0
                : tableView.column(
                    at: NSPoint(
                        x: cachedTableRect.minX,
                        y: tableView.bounds.midY
                    )
                )
            let lastIndex = cachedTableRect.maxX
                >= lastColumnRect.maxX
                ? tableView.numberOfColumns - 1
                : tableView.column(
                    at: NSPoint(
                        x: cachedTableRect.maxX.nextDown,
                        y: tableView.bounds.midY
                    )
                )
            boundedColumnIndexes =
                firstIndex >= 0 && lastIndex >= firstIndex
                ? firstIndex...lastIndex
                : nil
        } else {
            boundedColumnIndexes = nil
        }
        var nextFrames: [String: NSRect] = [:]
        nextFrames.reserveCapacity(
            boundedColumnIndexes.map {
                $0.upperBound - $0.lowerBound + 1
            } ?? 0
        )
        if let boundedColumnIndexes {
            for columnIndex in boundedColumnIndexes {
#if DEBUG
                testingManualHaplotypeGeometryInspectedColumnCount += 1
#endif
                let column = tableView.tableColumns[columnIndex]
                guard let sample =
                        sampleColumnLookup[column.identifier] else {
                    continue
                }
                let sampleColumnRect = tableView.rect(
                    ofColumn: columnIndex
                )
                let renderedWidth = min(
                    column.width,
                    sampleColumnRect.width
                )
                let renderedRect = NSRect(
                    x: sampleColumnRect.midX - renderedWidth / 2,
                    y: 0,
                    width: renderedWidth,
                    height: cachedBandRect.height
                )
                guard renderedRect.intersects(cachedBandRect) else {
                    continue
                }
                let frame = NSRect(
                    x: renderedRect.minX,
                    y: 0,
                    width: renderedRect.width,
                    height: manualHaplotypeBandHeight
                )
                nextFrames[sample] = frame
            }
        }
        manualHaplotypeBandGeometryDirty = false
        manualHaplotypeBandHorizontalOffset = horizontalOffset
        manualHaplotypeBandBoundsSize = visibleBandRect.size
        manualHaplotypeBandCachedCoverageRect = cachedBandRect
        guard nextFrames != manualHaplotypeSampleBand.columnFrames else {
            return
        }
        manualHaplotypeSampleBand.columnFrames = nextFrames
        manualHaplotypeSampleBand.needsDisplay = true
    }

    private func updateManualHaplotypeHeaderAccessibility(
        samples: Set<String>? = nil
    ) {
        guard haplotypeBandIsVisible else {
            updateColumnCommentMetadata()
            return
        }
        for column in tableView.tableColumns {
            guard let sample = sampleColumnLookup[column.identifier],
                  samples?.contains(sample) ?? true else {
                continue
            }
            let summary: String
            switch haplotypeBandMode {
            case .none:
                summary = ""
            case .manualAssignments:
                summary = manualHaplotypeBandSnapshot
                    .accessibilitySummaryBySample[sample]
                    ?? "No manual haplotype assignments"
            case .effectiveMiSeqCalls:
                summary = effectiveHaplotypeBandSnapshot
                    .accessibilitySummary(sample: sample)
            }
            let commentCount =
                sidecarColumnCommentTooltips[sample] == nil ? 0 : 1
            let commentSuffix =
                commentCount == 1 ? "comment" : "comments"
            column.headerCell.setAccessibilityLabel(
                "Sample column \(sample). \(commentCount) sample column "
                    + "\(commentSuffix). \(summary)"
            )
        }
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
        updateNativeHeaderLayout(ordinaryHeight: headerHeight)
        filterHeightConstraint?.constant = max(24, ceil(typography.font(for: .body).boundingRectForFont.height + 8))
        reviewLegendHeightConstraint?.constant = max(
            15,
            ceil(typography.font(for: .caption).boundingRectForFont.height + 4)
        )
        applyManualHaplotypeBandPresentation()
        if displayState.manualHaplotypeBandExpanded {
            measureManualHaplotypeTransientMinimumWidths(
                samples: Set(visibleSampleNames)
            )
        }
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
        withScrollSyncSuppressed {
            scrollView.contentView.setBoundsOrigin(origin)
        }
    }

    private var tableViewHeaderHeight: CGFloat {
        (tableView.headerView as? GenotypeMatrixHeaderView)?
            .ordinaryHeaderHeight ?? 34
    }

    private func measureManualHaplotypeTransientMinimumWidths(
        samples: Set<String>
    ) {
        guard haplotypeBandIsVisible,
              displayState.manualHaplotypeBandExpanded,
              !samples.isEmpty else {
            return
        }
        let visible = Set(visibleSampleNames)
        let measuredSamples = samples.intersection(visible)
        guard !measuredSamples.isEmpty else { return }
        let assignmentFont = manualHaplotypeBandFont
        let headerFont = resolvedContentTypography().font(for: .tableHeader)
        for sample in measuredSamples {
            manualHaplotypeTransientMinimumWidths[sample] =
                GenotypeManualHaplotypeColumnMeasurement.requiredWidth(
                    values: activeHaplotypeBandValues(sample: sample),
                    sampleTitle: sample,
                    retainedReadTitle: sampleReadTitleByName[sample],
                    font: assignmentFont,
                    headerFont: headerFont
                )
#if DEBUG
            testingManualHaplotypeMeasurementCountsBySample[
                sample,
                default: 0
            ] += 1
#endif
        }
    }

    private func refreshManualHaplotypeAutoFit(
        samples: Set<String>,
        remeasure: Bool
    ) {
        let visible = Set(visibleSampleNames)
        let affectedSamples = samples.intersection(visible)
        guard !affectedSamples.isEmpty else { return }
        let semanticScrollAnchor = captureSemanticScrollAnchor()
        if remeasure {
            measureManualHaplotypeTransientMinimumWidths(
                samples: affectedSamples
            )
        }
        let scale = contentTypographyScale
        let headerFont = resolvedContentTypography().font(for: .tableHeader)
        isApplyingManualHaplotypeAutoFit = true
        defer { isApplyingManualHaplotypeAutoFit = false }
        var changedColumnGeometry = false
        for column in tableView.tableColumns {
            guard let sample = sampleColumnLookup[column.identifier],
                  affectedSamples.contains(sample) else {
                continue
            }
            let preferredWidth =
                (sampleColumnWidthsByStableID[sample] ?? 68) * scale
            let baselineMinimum =
                (typographyBaselineColumnMinWidths[
                    column.identifier.rawValue
                ] ?? 58) * scale
            let headerWidth =
                GenotypeManualHaplotypeColumnMeasurement.requiredWidth(
                    values: [],
                    sampleTitle: sample,
                    retainedReadTitle: sampleReadTitleByName[sample],
                    font: manualHaplotypeBandFont,
                    headerFont: headerFont
                )
            let transientMinimum =
                displayState.manualHaplotypeBandExpanded
                    ? manualHaplotypeTransientMinimumWidths[sample] ?? 0
                    : 0
            let headerMinimum = max(baselineMinimum, headerWidth)
            let assignmentMinimum = transientMinimum
            let minimum = max(headerMinimum, assignmentMinimum)
            let width = max(
                headerMinimum,
                preferredWidth,
                assignmentMinimum
            )
            guard abs(column.minWidth - minimum) > 0.5
                    || abs(column.width - width) > 0.5 else {
                continue
            }
            if width > column.width {
                // Raising minWidth first silently clamps NSTableColumn.width
                // before NSTableView observes a width change, leaving its live
                // column rectangles stale. Publish the width first on growth.
                column.width = width
                column.minWidth = minimum
            } else {
                // Lower the transient floor first so a genuine narrower user
                // preference is not clamped by the old assignment minimum.
                column.minWidth = minimum
                column.width = width
            }
            changedColumnGeometry = true
        }
        guard changedColumnGeometry else { return }

        // NSTableColumn accepts its new width before NSTableView has rebuilt
        // column rectangles. Finish that native layout synchronously so the
        // fixed header and its manual-assignment band cannot render one frame
        // behind a completed save.
        manualHaplotypeBandGeometryDirty = true
        manualHaplotypeBandCachedCoverageRect = .zero
        manualHaplotypeBandCachedOverscanWidth = nil
        tableView.needsLayout = true
        tableView.headerView?.needsLayout = true
        manualHaplotypeSampleBand.needsLayout = true
        tableView.tile()
        scrollView.tile()
        tableView.layoutSubtreeIfNeeded()
        tableView.headerView?.layoutSubtreeIfNeeded()
        scrollView.contentView.layoutSubtreeIfNeeded()
        scrollView.layoutSubtreeIfNeeded()
        layoutSubtreeIfNeeded()
        updateManualHaplotypeBandColumnGeometry()
        restoreSemanticScrollAnchor(semanticScrollAnchor)
        updateManualHaplotypeBandColumnGeometry()
        manualHaplotypeSampleBand.needsDisplay = true
        setHeaderViewsNeedDisplay()
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
            if let sample = sampleColumnLookup[column.identifier] {
                typographyBaselineColumnWidths[key] =
                    sampleColumnWidthsByStableID[sample] ?? 68
                typographyBaselineColumnMinWidths[key] =
                    typographyBaselineColumnMinWidths[key] ?? 58
            } else {
                typographyBaselineColumnWidths[key] = column.width / scale
                typographyBaselineColumnMinWidths[key] =
                    column.minWidth / scale
            }
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
                let sample = sampleColumnLookup[column.identifier]
                let retainedReadHeaderWidth = sample.map {
                    GenotypeManualHaplotypeColumnMeasurement.requiredWidth(
                        values: [],
                        sampleTitle: $0,
                        retainedReadTitle: sampleReadTitleByName[$0],
                        font: manualHaplotypeBandFont,
                        headerFont: headerFont
                    )
                } ?? 0
                let transientMinimum = sample.flatMap {
                    displayState.manualHaplotypeBandExpanded
                        ? manualHaplotypeTransientMinimumWidths[$0]
                        : nil
                } ?? 0
                let minimum = max(
                    baselineMinimum * scale,
                    headerWidth,
                    retainedReadHeaderWidth,
                    transientMinimum
                )
                if column.identifier == ColumnID.rowSelector {
                    column.maxWidth = max(baselineWidth * scale, minimum)
                }
                column.minWidth = minimum
                let preferredWidth = sample.flatMap {
                    sampleColumnWidthsByStableID[$0]
                }.map { $0 * scale } ?? baselineWidth * scale
                column.width = max(preferredWidth, minimum)
                if column.identifier == ColumnID.rowSelector {
                    column.maxWidth = column.width
                }
            }
        }
        manualHaplotypeBandGeometryDirty = true
        manualHaplotypeBandCachedCoverageRect = .zero
        manualHaplotypeBandCachedOverscanWidth = nil
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

        if isAlleleIdentityColumn(identifier), isProvisionalExon2(row) {
            return Self.color(from: provisionalExon2Tint)
        }

        if isAlleleIdentityColumn(identifier),
           let category = row.tintCategory,
           let tint = effectiveCandidateDisplaySettings.tints[category] {
            return Self.color(from: tint)
        }

        guard displayState.cellColorMode == .support,
              let sample = sampleColumnLookup[identifier] else {
            return nil
        }

        if manualHaplotypeEditingEligible {
            guard let support = supportByRowAndSample[row.id]?[sample],
                  support.passedUniqueReads > 0 else {
                return nil
            }
            return NSColor.systemBlue.withAlphaComponent(0.20)
        }

        // Authoritative haplotyped results keep their established known-call
        // heatmap. The fixed fill is a genotype-only review affordance.
        guard row.population == .known,
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
                  isProvisionalExon2(row) {
            effectiveBackground = provisionalExon2Tint
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
    private var hasExplicitAccessibilityFocus = false

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

    override func isAccessibilityFocused() -> Bool {
        hasExplicitAccessibilityFocus || super.isAccessibilityFocused()
    }

    override func setAccessibilityFocused(_ focused: Bool) {
        hasExplicitAccessibilityFocus = focused
    }

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

private final class GenotypeMatrixSelectorButton: NSButton {
    enum Identity: Equatable {
        case row(GenotypeCandidateMatrixRowID)
        case column(String)
        case selectAll
    }

    var selectorIdentity: Identity?
    var onPress: ((NSEvent.ModifierFlags) -> Bool)?
    var onAccessibilityValueChanged: (() -> Void)?
    var onAccessibilityFocusChanged:
        ((GenotypeMatrixSelectorButton, Bool) -> Void)?
    private var hasConfiguredSelectionState = false
    private var hasExplicitAccessibilityFocus = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        buildView()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        buildView()
    }

    private func buildView() {
        setButtonType(.switch)
        title = ""
        image = nil
        isBordered = false
        focusRingType = .exterior
        setAccessibilityElement(true)
        setAccessibilityRole(.checkBox)
        target = self
        action = #selector(pressed(_:))
    }

    func configure(
        identity: Identity,
        label: String,
        identifier: String,
        isSelected: Bool,
        onPress: @escaping (NSEvent.ModifierFlags) -> Bool
    ) {
        let previousIdentity = selectorIdentity
        let changed = hasConfiguredSelectionState
            && previousIdentity == identity
            && ((state == .on) != isSelected)
        if previousIdentity != identity, hasExplicitAccessibilityFocus {
            setAccessibilityFocused(false)
        }
        selectorIdentity = identity
        self.onPress = onPress
        setAccessibilityLabel(label)
        setAccessibilityIdentifier(identifier)
        state = isSelected ? .on : .off
        hasConfiguredSelectionState = true
        if changed {
            NSAccessibility.post(element: self, notification: .valueChanged)
            onAccessibilityValueChanged?()
        }
    }

    @objc private func pressed(_ sender: NSButton) {
        _ = performPress(modifiers: NSApp.currentEvent?.modifierFlags ?? [])
    }

    @discardableResult
    private func performPress(modifiers: NSEvent.ModifierFlags) -> Bool {
        return onPress?(modifiers) == true
    }

    override func accessibilityPerformPress() -> Bool {
        performPress(modifiers: [])
    }

    override func accessibilityValue() -> Any? {
        NSNumber(value: state == .on ? 1 : 0)
    }

    override func accessibilityValueDescription() -> String? {
        state == .on ? "Selected" : "Not selected"
    }

    override func isAccessibilityFocused() -> Bool {
        hasExplicitAccessibilityFocus || super.isAccessibilityFocused()
    }

    override func setAccessibilityFocused(_ focused: Bool) {
        guard hasExplicitAccessibilityFocus != focused else { return }
        hasExplicitAccessibilityFocus = focused
        onAccessibilityFocusChanged?(self, focused)
    }

    override func draw(_ dirtyRect: NSRect) {
        // Visuals are drawn by the established matrix chiclet beneath this
        // transparent native checkbox. The real control supplies keyboard,
        // focus, and accessibility behavior without changing matrix density.
        if window?.firstResponder === self {
            NSFocusRingPlacement.only.set()
            bounds.fill()
        }
    }
}

private final class GenotypeMatrixRowSelectorCellView: NSTableCellView {
    private let chiclet = GenotypeMatrixRowSelectorChicletView()
    private let selectorButton = GenotypeMatrixSelectorButton()
    private var commentFoldSize: CGFloat?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        buildView()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        buildView()
    }

    func configure(
        rowID: GenotypeCandidateMatrixRowID,
        label: String,
        isSelected: Bool,
        commentFoldSize: CGFloat?,
        onAccessibilityValueChanged: @escaping () -> Void,
        onAccessibilityFocusChanged:
            @escaping (GenotypeMatrixSelectorButton, Bool) -> Void,
        onPress: @escaping (GenotypeCandidateMatrixRowID, NSEvent.ModifierFlags) -> Bool
    ) {
        chiclet.configure(isSelected: isSelected)
        selectorButton.onAccessibilityValueChanged = onAccessibilityValueChanged
        selectorButton.onAccessibilityFocusChanged = onAccessibilityFocusChanged
        selectorButton.configure(
            identity: .row(rowID),
            label: label,
            identifier: "genotype-row-selector.\(rowID.accessibilityIdentifierComponent)",
            isSelected: isSelected,
            onPress: { modifiers in onPress(rowID, modifiers) }
        )
        self.commentFoldSize = commentFoldSize
        needsDisplay = true
    }

    private func buildView() {
        setAccessibilityElement(false)
        chiclet.setAccessibilityElement(false)
        chiclet.translatesAutoresizingMaskIntoConstraints = false
        selectorButton.translatesAutoresizingMaskIntoConstraints = false
        addSubview(chiclet)
        addSubview(selectorButton)
        NSLayoutConstraint.activate([
            chiclet.widthAnchor.constraint(equalToConstant: 12),
            chiclet.heightAnchor.constraint(equalToConstant: 12),
            chiclet.centerXAnchor.constraint(equalTo: centerXAnchor),
            chiclet.centerYAnchor.constraint(equalTo: centerYAnchor),
            selectorButton.widthAnchor.constraint(equalToConstant: 16),
            selectorButton.heightAnchor.constraint(equalToConstant: 16),
            selectorButton.centerXAnchor.constraint(equalTo: chiclet.centerXAnchor),
            selectorButton.centerYAnchor.constraint(equalTo: chiclet.centerYAnchor),
        ])
    }

    var accessibilitySelectorButton: GenotypeMatrixSelectorButton {
        selectorButton
    }

#if DEBUG
    var accessibilityTreeSnapshot:
        GenotypeMatrixRowSelectorAccessibilityTreeSnapshot {
        return GenotypeMatrixRowSelectorAccessibilityTreeSnapshot(
            cellIsAccessibilityElement: isAccessibilityElement(),
            chicletIsAccessibilityElement: chiclet.isAccessibilityElement(),
            actionableDescendantCount:
                selectorButton.isAccessibilityElement() ? 1 : 0
        )
    }
#endif

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
    var selectorIdentityForColumn: ((Int) -> GenotypeMatrixSelectorButton.Identity?)?
    var selectorLabelForColumn: ((Int) -> String?)?
    var onSelectorAccessibilityValueChanged: (() -> Void)?
    var onSelectorAccessibilityFocusChanged:
        ((GenotypeMatrixSelectorButton, Bool) -> Void)?
    var onColumnChicletClick: ((Int, NSEvent.ModifierFlags) -> Bool)?
    var readTitleForColumn: ((Int) -> String?)?
    var hasCommentForColumn: ((Int) -> Bool)?
    var commentFoldSize: (() -> CGFloat)?
    var titleFont: (() -> NSFont)?
    var readFont: (() -> NSFont)?
    var chicletSize: (() -> CGFloat)?
    var onContextMenuRequest: ((Int) -> NSMenu?)?
    var headerLayout = GenotypeManualHaplotypeHeaderLayout(
        isEligible: false,
        isExpanded: false,
        ordinaryHeight: 34,
        disclosureHeight: 22,
        rowHeight: 22
    ) {
        didSet {
            if frame.height != headerLayout.totalHeight {
                frame.size.height = headerLayout.totalHeight
            }
            needsLayout = true
            needsDisplay = true
        }
    }
    var manualContentView: NSView? {
        didSet {
            guard oldValue !== manualContentView else { return }
            oldValue?.removeFromSuperview()
            if let manualContentView {
                addSubview(manualContentView)
            }
            needsLayout = true
        }
    }
    private var selectorButtons:
        [NSUserInterfaceItemIdentifier: GenotypeMatrixSelectorButton] = [:]

    var ordinaryHeaderHeight: CGFloat {
        headerLayout.ordinaryHeight
    }

    var ordinaryHeaderBounds: NSRect {
        headerLayout.ordinaryRect(in: bounds, isFlipped: isFlipped)
    }

    var manualHeaderBounds: NSRect {
        headerLayout.manualRect(in: bounds, isFlipped: isFlipped)
    }

    func ordinaryHeaderRect(ofColumn column: Int) -> NSRect {
        let columnRect = headerRect(ofColumn: column)
        let ordinaryBounds = ordinaryHeaderBounds
        return NSRect(
            x: columnRect.minX,
            y: ordinaryBounds.minY,
            width: columnRect.width,
            height: ordinaryBounds.height
        )
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let tableView else { return }
        synchronizeSelectorButtons()
        NSColor.controlBackgroundColor.setFill()
        dirtyRect.fill()

        for column in 0..<tableView.numberOfColumns {
            let rect = ordinaryHeaderRect(ofColumn: column)
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

    override func layout() {
        super.layout()
        manualContentView?.frame = manualHeaderBounds
        synchronizeSelectorButtons()
    }

    func refreshSelectorButtons() {
        synchronizeSelectorButtons()
    }

    func selectorButton(
        matching identity: GenotypeMatrixSelectorButton.Identity
    ) -> GenotypeMatrixSelectorButton? {
        synchronizeSelectorButtons()
        return selectorButtons.values.first { $0.selectorIdentity == identity }
    }

    private func synchronizeSelectorButtons() {
        guard let tableView else { return }
        var activeIdentifiers: Set<NSUserInterfaceItemIdentifier> = []
        for column in tableView.tableColumns.indices
        where isColumnSelectable?(column) == true {
            let tableColumn = tableView.tableColumns[column]
            let identifier = tableColumn.identifier
            guard let identity = selectorIdentityForColumn?(column),
                  let label = selectorLabelForColumn?(column) else {
                continue
            }
            activeIdentifiers.insert(identifier)
            let button: GenotypeMatrixSelectorButton
            if let existing = selectorButtons[identifier] {
                button = existing
            } else {
                button = GenotypeMatrixSelectorButton()
                button.translatesAutoresizingMaskIntoConstraints = true
                selectorButtons[identifier] = button
                addSubview(button)
            }
            let accessibilityIdentifier: String
            switch identity {
            case .selectAll:
                accessibilityIdentifier = "genotype-matrix-select-all"
            case let .column(sample):
                accessibilityIdentifier = "genotype-column-selector.\(sample)"
            case let .row(rowID):
                accessibilityIdentifier =
                    "genotype-row-selector.\(rowID.accessibilityIdentifierComponent)"
            }
            button.onAccessibilityValueChanged = onSelectorAccessibilityValueChanged
            button.onAccessibilityFocusChanged = onSelectorAccessibilityFocusChanged
            button.configure(
                identity: identity,
                label: label,
                identifier: accessibilityIdentifier,
                isSelected: isColumnSelected?(column) == true,
                onPress: { [weak self] modifiers in
                    guard let self,
                          let tableView = self.tableView,
                          let currentColumn = tableView.tableColumns.firstIndex(
                              where: { $0.identifier == identifier }
                          ) else {
                        return false
                    }
                    return self.onColumnChicletClick?(currentColumn, modifiers) == true
                }
            )
            button.frame = chicletRect(forColumn: column).insetBy(dx: -2, dy: -2)
        }
        for identifier in Set(selectorButtons.keys).subtracting(activeIdentifiers) {
            selectorButtons.removeValue(forKey: identifier)?.removeFromSuperview()
        }
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard ordinaryHeaderBounds.contains(point) else { return }
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
        guard ordinaryHeaderBounds.contains(point) else {
            return super.menu(for: event)
        }
        let column = self.column(at: point)
        if column >= 0, let menu = onContextMenuRequest?(column) {
            return menu
        }
        return super.menu(for: event)
    }

    private func chicletRect(forColumn column: Int) -> NSRect {
        chicletRect(in: ordinaryHeaderRect(ofColumn: column))
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
    static func testingResetPersistedReferenceVisibility() {
        UserDefaults.standard.removeObject(forKey: referenceVisibilityKey)
    }

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
        let documentRect = scrollView.contentView.documentRect
        let maximumX = max(
            documentRect.minX,
            documentRect.maxX - scrollView.contentView.bounds.width
        )
        let constrainedOrigin = NSPoint(
            x: min(max(origin.x, documentRect.minX), maximumX),
            y: origin.y
        )
        scrollView.contentView.scroll(to: constrainedOrigin)
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }
    func testingScrollSampleMatrixVertically(to y: CGFloat) {
        let origin = NSPoint(
            x: scrollView.contentView.bounds.origin.x,
            y: y
        )
        scrollView.contentView.scroll(to: origin)
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }
    func testingConfigureSampleMatrixLegacyHorizontalScroller() {
        testingForcesLegacyBottomChrome = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = false
        scrollView.scrollerStyle = .legacy
        scrollView.tile()
        scrollView.horizontalScroller?.isHidden = false
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
    func testingMoveSampleColumn(sample: String, to targetIndex: Int) {
        guard let sourceIndex = tableView.tableColumns.firstIndex(where: {
            sampleColumnLookup[$0.identifier] == sample
        }) else { return }
        let boundedTarget = min(max(0, targetIndex), max(0, tableView.numberOfColumns - 1))
        tableView.moveColumn(sourceIndex, toColumn: boundedTarget)
        captureStableSampleColumnState()
        rebuildVisibleColumnIndex()
        updateManualHaplotypeBandColumnGeometry()
    }
    func testingSetSampleColumnWidth(sample: String, width: CGFloat) {
        guard let column = tableView.tableColumns.first(where: {
            sampleColumnLookup[$0.identifier] == sample
        }) else { return }
        column.width = max(column.minWidth, width)
        captureStableSampleColumnState()
        updateManualHaplotypeBandColumnGeometry()
    }
    func testingSampleColumnWidth(sample: String) -> CGFloat {
        tableView.tableColumns.first(where: {
            sampleColumnLookup[$0.identifier] == sample
        })?.width ?? 0
    }
    func testingUserPreferredSampleColumnWidth(
        sample: String
    ) -> CGFloat {
        sampleColumnWidthsByStableID[sample] ?? 68
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
    func testingResetManualHaplotypeDisclosureLayoutCounters() {
        testingManualHaplotypeDisclosureHeaderRelayoutCount = 0
        testingManualHaplotypeDisclosureAnchorPreservationCount = 0
    }
    var testingManualHaplotypeDisclosureLayoutCounters:
        (headerRelayouts: Int, anchorPreservations: Int) {
        (
            testingManualHaplotypeDisclosureHeaderRelayoutCount,
            testingManualHaplotypeDisclosureAnchorPreservationCount
        )
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

    func testingSetLocusFilter(_ locus: String?) {
        applyLocusFilter(locus)
    }

    var testingSelectedMatrixTargets: [GenotypeAnnotationSidecar.MatrixTarget] {
        selectedMatrixTargets
    }

    func testingSelectMatrixTargets(
        _ targets: [GenotypeAnnotationSidecar.MatrixTarget]
    ) {
        publishMatrixTargetSelection(targets, anchor: targets.last)
    }

    var testingManualHaplotypeBandLoci: [String] {
        GenotypeManualHaplotypeAssignmentBandSnapshot.loci
            .map(\.workbookLabel)
    }

    var testingHaplotypeBandMode: GenotypeHaplotypeBandMode {
        haplotypeBandMode
    }

    var testingHaplotypeBandLoci: [String] {
        activeHaplotypeBandLoci
    }

    var testingHaplotypeBandExpandedRowCount: Int {
        displayState.manualHaplotypeBandExpanded
            ? activeHaplotypeBandLoci.count
            : 0
    }

    func testingHaplotypeBandValue(
        sample: String,
        locus: String,
        slot: HaplotypeSlot
    ) -> GenotypeHaplotypeCallBandSlotValue? {
        guard haplotypeBandMode == .effectiveMiSeqCalls else { return nil }
        return effectiveHaplotypeBandSnapshot.value(
            sample: sample,
            locus: locus,
            slot: slot
        )
    }

    func testingHaplotypeBandHitTarget(
        _ target: GenotypeHaplotypeBandTarget
    ) -> NSButton? {
        updateManualHaplotypeBandColumnGeometry()
        manualHaplotypeSampleBand.layoutSubtreeIfNeeded()
        return manualHaplotypeSampleBand.testingHitTarget(target)
    }

    func testingManualHaplotypeBandValues(sample: String) -> [String] {
        manualHaplotypeBandSnapshot.valuesBySample[sample]
            ?? Array(repeating: "—", count: 7)
    }

    var testingManualHaplotypeBandPerSampleControlCount: Int {
        manualHaplotypeSampleBand.subviews.compactMap { $0 as? NSControl }.count
    }

    var testingManualHaplotypeBandCellsAreFocusable: Bool {
        manualHaplotypeSampleBand.acceptsFirstResponder
    }

    var testingManualHaplotypeBandIsExpanded: Bool {
        displayState.manualHaplotypeBandExpanded
    }

    var testingManualHaplotypeBandCoverageWidth: CGFloat {
        let pinnedFrame = manualHaplotypePinnedBand.convert(
            manualHaplotypePinnedBand.bounds,
            to: self
        )
        let sampleFrame = manualHaplotypeSampleBand.convert(
            manualHaplotypeSampleBand.visibleRect,
            to: self
        )
        return pinnedFrame.union(sampleFrame).width
    }

    var testingVisibleMatrixWidth: CGFloat {
        pinnedScrollView.frame.width
            + paneDivider.frame.width
            + scrollView.frame.width
    }

    var testingManualHaplotypeDisclosureFrame: NSRect {
        manualHaplotypePinnedBand.testingDisclosureFrame
    }

    var testingManualHaplotypeDisclosureIsBordered: Bool {
        manualHaplotypePinnedBand.testingDisclosureIsBordered
    }

    func testingSetManualHaplotypeBandDisclosureExpanded(
        _ expanded: Bool
    ) {
        setManualHaplotypeBandExpandedPreservingViewport(expanded)
        onManualHaplotypeBandExpansionChanged?(expanded)
    }

    var testingManualHaplotypeBandDisclosureLabel: String {
        manualHaplotypePinnedBand.disclosureLabel
    }

    func testingManualHaplotypeBandTooltip(
        sample: String,
        locus: String
    ) -> String? {
        guard let locus = GenotypeManualHaplotypeLocus(
            normalizing: locus
        ) else {
            return nil
        }
        return manualHaplotypeBandSnapshot.tooltip(
            sample: sample,
            locus: locus
        )
    }

    func testingRegisteredManualHaplotypeBandTooltip(
        sample: String,
        locus: String
    ) -> String? {
        guard let locus = GenotypeManualHaplotypeLocus(
            normalizing: locus
        ),
        let locusIndex =
            GenotypeManualHaplotypeAssignmentBandSnapshot.loci
                .firstIndex(of: locus),
        let frame = manualHaplotypeSampleBand.columnFrames[sample]
        else {
            return nil
        }
        return manualHaplotypeSampleBand.testingRegisteredToolTip(
            at: NSPoint(
                x: frame.midX,
                y: manualHaplotypeDisclosureHeight
                    + manualHaplotypeBandRowHeight
                        * (CGFloat(locusIndex) + 0.5)
            )
        )
    }

    var testingManualHaplotypeBandTopInsets: [CGFloat] {
        [
            pinnedScrollView.contentInsets.top,
            scrollView.contentInsets.top,
        ]
    }

    var testingManualHaplotypeBandAutomaticInsetAdjustment: [Bool] {
        [
            pinnedScrollView.automaticallyAdjustsContentInsets,
            scrollView.automaticallyAdjustsContentInsets,
        ]
    }

    var testingManualHaplotypeBandRowHeight: CGFloat {
        manualHaplotypeBandRowHeight
    }

    var testingManualHaplotypeBandFontPointSize: CGFloat {
        manualHaplotypeBandFont.pointSize
    }

    func testingFixedHeaderSnapshot(
        sample: String
    ) -> GenotypeMatrixFixedHeaderTestingSnapshot? {
        guard let header =
                tableView.headerView as? GenotypeMatrixHeaderView,
              let columnIndex = tableView.tableColumns.firstIndex(
                where: {
                    sampleColumnLookup[$0.identifier] == sample
                }
              )
        else {
            return nil
        }
        let ordinaryLocalRect = header.ordinaryHeaderRect(
            ofColumn: columnIndex
        )
        let textBands = header.textBandRects(
            in: ordinaryLocalRect,
            leftInset: 20
        )
        let ordinaryRect = header.convert(
            ordinaryLocalRect,
            to: self
        )
        let manualLocalRect = header.manualHeaderBounds
        let manualRect = manualHaplotypeSampleBand.isHidden
            || manualLocalRect.isEmpty
            ? .zero
            : header.convert(
                manualLocalRect,
                to: self
            )
        let firstRowRect = tableView.numberOfRows > 0
            ? tableView.convert(
                tableView.rect(ofRow: 0),
                to: self
            )
            : nil
        return GenotypeMatrixFixedHeaderTestingSnapshot(
            totalNativeHeaderHeight: header.frame.height,
            nativeHeaderRect: header.convert(
                header.bounds,
                to: self
            ),
            ordinarySampleHeaderRect: ordinaryRect,
            manualSectionRect: manualRect,
            firstTableRowRect: firstRowRect,
            sampleTitleRect: header.convert(
                textBands.title,
                to: self
            ),
            sampleReadTextRect: header.convert(
                textBands.read,
                to: self
            ),
            sampleColumnRect: tableView.convert(
                tableView.rect(ofColumn: columnIndex),
                to: self
            )
        )
    }

    func testingManualValueSnapshot(
        sample: String,
        locus: String
    ) -> GenotypeMatrixManualValueTestingSnapshot? {
        guard manualHaplotypeEditorEnabled,
              displayState.manualHaplotypeBandExpanded,
              let normalizedLocus =
                GenotypeManualHaplotypeLocus(normalizing: locus),
              let locusIndex =
                GenotypeManualHaplotypeAssignmentBandSnapshot.loci
                    .firstIndex(of: normalizedLocus)
        else {
            return nil
        }
        guard let valueLayout =
                manualHaplotypeSampleBand.valueLayout(
                    sample: sample,
                    locusIndex: locusIndex
                )
        else {
            return nil
        }
        return GenotypeMatrixManualValueTestingSnapshot(
            textRect: manualHaplotypeSampleBand.convert(
                valueLayout.textRect,
                to: self
            ),
            alignment: valueLayout.alignment,
            value: valueLayout.value
        )
    }

    func testingSetManualHaplotypeBandTypographyScale(_ scale: CGFloat?) {
        testingManualHaplotypeBandTypographyScaleOverride = scale
        applyManualHaplotypeBandPresentation()
        refreshManualHaplotypeAutoFit(
            samples: Set(visibleSampleNames),
            remeasure: displayState.manualHaplotypeBandExpanded
        )
        layoutSubtreeIfNeeded()
    }

    var testingManualHaplotypeBandColumnFrames: [String: NSRect] {
        updateManualHaplotypeBandColumnGeometry()
        let horizontalOffset =
            scrollView.contentView.bounds.origin.x
        return manualHaplotypeSampleBand.columnFrames.mapValues {
            $0.offsetBy(dx: -horizontalOffset, dy: 0)
        }
    }

    var testingRenderedManualHaplotypeBandColumnFrames:
        [String: NSRect] {
        manualHaplotypeSampleBand.columnFrames
    }

    func testingResetManualHaplotypeGeometryCounters() {
        testingManualHaplotypeGeometryUpdateCount = 0
        testingManualHaplotypeGeometryRecomputationCount = 0
        testingManualHaplotypeGeometryInspectedColumnCount = 0
    }

    func testingResetManualHaplotypeAutoFitMeasurementCounts() {
        testingManualHaplotypeMeasurementCountsBySample.removeAll()
    }

    var testingManualHaplotypeAutoFitMeasurementCounts:
        [String: Int] {
        testingManualHaplotypeMeasurementCountsBySample
    }

    func testingResetManualHaplotypeAutoFitValueMeasurementCounts() {
        testingManualHaplotypeMeasurementCountsBySample.removeAll()
    }

    var testingManualHaplotypeAutoFitValueMeasurementCounts:
        [String: Int] {
        testingManualHaplotypeMeasurementCountsBySample.mapValues {
            $0 * GenotypeManualHaplotypeLocus.allCases.count
        }
    }

    var testingManualHaplotypeGeometryCounters:
        (
            updates: Int,
            recomputations: Int,
            inspectedColumns: Int
        ) {
        (
            testingManualHaplotypeGeometryUpdateCount,
            testingManualHaplotypeGeometryRecomputationCount,
            testingManualHaplotypeGeometryInspectedColumnCount
        )
    }

    func testingResizeSampleColumnThroughProductionCallback(
        sample: String,
        width: CGFloat
    ) {
        guard let column = tableView.tableColumns.first(where: {
            sampleColumnLookup[$0.identifier] == sample
        }) else {
            return
        }
        column.width = max(column.minWidth, width)
        tableViewColumnDidResize(
            Notification(
                name: NSTableView.columnDidResizeNotification,
                object: tableView,
                userInfo: ["NSTableColumn": column]
            )
        )
    }

    func testingMoveSampleColumnThroughProductionCallback(
        sample: String,
        to targetIndex: Int
    ) {
        guard let sourceIndex = tableView.tableColumns.firstIndex(where: {
            sampleColumnLookup[$0.identifier] == sample
        }) else {
            return
        }
        let boundedTarget = min(
            max(0, targetIndex),
            max(0, tableView.numberOfColumns - 1)
        )
        tableView.moveColumn(sourceIndex, toColumn: boundedTarget)
        tableViewColumnDidMove(
            Notification(
                name: NSTableView.columnDidMoveNotification,
                object: tableView
            )
        )
    }

    func testingRegisteredManualHaplotypeTooltipAtLiveColumn(
        sample: String,
        locus: String
    ) -> String? {
        guard let locus = GenotypeManualHaplotypeLocus(
            normalizing: locus
        ),
              let locusIndex =
                GenotypeManualHaplotypeAssignmentBandSnapshot.loci
                    .firstIndex(of: locus),
              let columnIndex = tableView.tableColumns.firstIndex(where: {
                  sampleColumnLookup[$0.identifier] == sample
              })
        else {
            return nil
        }
        let liveColumnRect = tableView.convert(
            tableView.rect(ofColumn: columnIndex),
            to: manualHaplotypeSampleBand
        )
        return manualHaplotypeSampleBand.testingRegisteredToolTip(
            at: NSPoint(
                x: liveColumnRect.midX,
                y: manualHaplotypeDisclosureHeight
                    + manualHaplotypeBandRowHeight
                        * (CGFloat(locusIndex) + 0.5)
            )
        )
    }

    func testingResetManualHaplotypeBandInvalidations() {
        testingManualHaplotypeBandInvalidatedSampleSet.removeAll()
    }

    var testingManualHaplotypeBandInvalidatedSamples: [String] {
        testingManualHaplotypeBandInvalidatedSampleSet.sorted()
    }

    var testingVisibilityCapability: GenotypeMatrixVisibilityCapabilitySnapshot {
        matrixVisibilityCapability
    }

    var testingVisibilityMutationCount: Int {
        testingVisibilityMutationPassCount
    }

    func testingHideRows(_ rowIDs: Set<GenotypeCandidateMatrixRowID>) {
        _ = applyVisibilityState(
            visibilityState.hidingRows(rowIDs),
            announcement: "Selected rows hidden."
        )
    }

    func testingHideSamples(_ samples: Set<String>) {
        _ = applyVisibilityState(
            visibilityState.hidingSamples(samples),
            announcement: "Selected columns hidden."
        )
    }

    var testingAccessibilityValueChangedNotificationCount: Int {
        testingAccessibilityValueChangedCount
    }

    var testingAccessibilityLayoutChangedNotificationCount: Int {
        testingAccessibilityLayoutChangedCount
    }

    var testingAccessibilityFocusChangedNotificationCount: Int {
        testingAccessibilityFocusChangedCount
    }

    func testingRowSelectorObjectIdentifier(
        genotype: String
    ) -> ObjectIdentifier? {
        guard let rowID = visibleRows.first(where: {
            $0.genotype == genotype
        })?.id,
              let button = rowSelectorButton(for: rowID) else {
            return nil
        }
        return ObjectIdentifier(button)
    }

    func testingColumnSelectorObjectIdentifier(
        sample: String
    ) -> ObjectIdentifier? {
        columnSelectorButton(for: sample).map(ObjectIdentifier.init)
    }

    var testingSelectAllSelectorObjectIdentifier: ObjectIdentifier? {
        selectAllSelectorButton().map(ObjectIdentifier.init)
    }

    func testingRowSelectorIsSelected(genotype: String) -> Bool {
        guard let row = visibleRows.first(where: { $0.genotype == genotype }) else {
            return false
        }
        return selectedTargetsContainRow(row)
    }

    func testingColumnSelectorIsSelected(sample: String) -> Bool {
        selectedMatrixTargetSet.contains(.column(sample: sample))
    }

    func testingRowSelectorAccessibility(
        genotype: String
    ) -> GenotypeMatrixSelectorAccessibilitySnapshot? {
        guard let rowID = visibleRows.first(where: {
            $0.genotype == genotype
        })?.id else {
            return nil
        }
        return rowSelectorButton(for: rowID).map(accessibilitySnapshot)
    }

    func testingColumnSelectorAccessibility(
        sample: String
    ) -> GenotypeMatrixSelectorAccessibilitySnapshot? {
        columnSelectorButton(for: sample).map(accessibilitySnapshot)
    }

    var testingSelectAllAccessibility:
        GenotypeMatrixSelectorAccessibilitySnapshot? {
        selectAllSelectorButton().map(accessibilitySnapshot)
    }

    func testingRowSelectorAccessibilityTree(
        genotype: String
    ) -> GenotypeMatrixRowSelectorAccessibilityTreeSnapshot? {
        guard let rowID = visibleRows.first(where: {
            $0.genotype == genotype
        })?.id,
              let row = visibleRows.firstIndex(where: { $0.id == rowID }),
              let column = pinnedTableView.tableColumns.firstIndex(where: {
                  $0.identifier == ColumnID.rowSelector
              }),
              let cell = pinnedTableView.view(
                  atColumn: column,
                  row: row,
                  makeIfNecessary: true
              ) as? GenotypeMatrixRowSelectorCellView else {
            return nil
        }
        return cell.accessibilityTreeSnapshot
    }

    func testingSelectorReuseNotificationSnapshot()
        -> GenotypeMatrixSelectorReuseNotificationSnapshot {
        let button = GenotypeMatrixSelectorButton()
        var notifications = 0
        button.onAccessibilityValueChanged = { notifications += 1 }
        button.configure(
            identity: .column("AnimalA"),
            label: "AnimalA",
            identifier: "AnimalA",
            isSelected: false,
            onPress: { _ in true }
        )
        let afterInitial = notifications
        button.configure(
            identity: .column("AnimalB"),
            label: "AnimalB",
            identifier: "AnimalB",
            isSelected: true,
            onPress: { _ in true }
        )
        let afterDifferentIdentity = notifications
        button.configure(
            identity: .column("AnimalB"),
            label: "AnimalB",
            identifier: "AnimalB",
            isSelected: false,
            onPress: { _ in true }
        )
        return GenotypeMatrixSelectorReuseNotificationSnapshot(
            afterInitialConfiguration: afterInitial,
            afterDifferentIdentityConfiguration: afterDifferentIdentity,
            afterSameIdentityStateChange: notifications
        )
    }

    func testingAccessibilityPressModifiers() -> NSEvent.ModifierFlags {
        let button = GenotypeMatrixSelectorButton()
        var observed: NSEvent.ModifierFlags = [.command, .shift]
        button.configure(
            identity: .selectAll,
            label: "Select all",
            identifier: "select-all",
            isSelected: false,
            onPress: {
                observed = $0
                return true
            }
        )
        _ = button.accessibilityPerformPress()
        return observed
    }

    var testingAccessibilityFocusFallsBackToMatrix: Bool {
        testingDidFallBackAccessibilityFocusToMatrix
    }

    func testingPerformRowSelectorAccessibilityPress(
        genotype: String
    ) -> Bool {
        guard let rowID = visibleRows.first(where: {
            $0.genotype == genotype
        })?.id else {
            return false
        }
        return rowSelectorButton(for: rowID)?.accessibilityPerformPress() == true
    }

    func testingPerformColumnSelectorAccessibilityPress(
        sample: String
    ) -> Bool {
        columnSelectorButton(for: sample)?.accessibilityPerformPress() == true
    }

    func testingPerformSelectAllAccessibilityPress() -> Bool {
        selectAllSelectorButton()?.accessibilityPerformPress() == true
    }

    func testingFocusRowSelector(genotype: String) -> Bool {
        guard let rowID = visibleRows.first(where: {
            $0.genotype == genotype
        })?.id,
              let button = rowSelectorButton(for: rowID),
              let window else {
            return false
        }
        return window.makeFirstResponder(button)
    }

    func testingSetAccessibilityFocusedRowSelector(
        genotype: String
    ) -> Bool {
        guard let rowID = visibleRows.first(where: {
            $0.genotype == genotype
        })?.id,
              let button = rowSelectorButton(for: rowID) else {
            return false
        }
        button.setAccessibilityFocused(true)
        return button.isAccessibilityFocused()
    }

    var testingAccessibilityFocusedRowSelectorGenotype: String? {
        guard let button = accessibilityFocusedSelectorButton,
              button.isAccessibilityFocused(),
              case let .row(rowID)? = button.selectorIdentity else {
            return nil
        }
        return visibleRows.first(where: { $0.id == rowID })?.genotype
    }

    var testingFocusedRowSelectorGenotype: String? {
        guard let button = window?.firstResponder as? GenotypeMatrixSelectorButton,
              case let .row(rowID)? = button.selectorIdentity else {
            return nil
        }
        return visibleRows.first(where: { $0.id == rowID })?.genotype
    }

    private func accessibilitySnapshot(
        _ button: GenotypeMatrixSelectorButton
    ) -> GenotypeMatrixSelectorAccessibilitySnapshot {
        GenotypeMatrixSelectorAccessibilitySnapshot(
            role: button.accessibilityRole(),
            label: button.accessibilityLabel() ?? "",
            value: button.state == .on,
            numericValue: button.accessibilityValue() as? NSNumber,
            valueDescription: button.accessibilityValueDescription(),
            identifier: button.accessibilityIdentifier(),
            supportsPress: true,
            acceptsKeyboardFocus: button.acceptsFirstResponder
        )
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
        if let rowSelector = cell as? GenotypeMatrixRowSelectorCellView {
            return rowSelector.accessibilitySelectorButton.accessibilityLabel()
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

    func testingAlleleIdentityToolTip(genotype: String) -> String? {
        guard let row = visibleRows.first(where: { $0.genotype == genotype }) else {
            return nil
        }
        return rowTooltip(row: row, fallback: row.genotype)
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
        tableView.tableColumns.first(where: {
            sampleColumnLookup[$0.identifier] == sample
        })?.headerCell.accessibilityLabel()
    }

    var testingReviewLegendText: String {
        reviewLegend.stringValue
    }

    var testingReviewLegendProvisionalSwatchColor: NSColor? {
        let text = reviewLegend.attributedStringValue.string
        guard let range = text.range(of: "◼ Provisional exon 2") else {
            return nil
        }
        return reviewLegend.attributedStringValue.attribute(
            .foregroundColor,
            at: NSRange(range, in: text).location,
            effectiveRange: nil
        ) as? NSColor
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

    func testingSetVisibilityAnnouncementPoster(
        _ poster: any AccessibilityAnnouncementPosting
    ) {
        visibilityAnnouncementPoster = poster
    }

    func testingPerformContextCommand(_ command: GenotypeMatrixContextCommand) -> Bool {
        performContextCommand(command)
    }

    func testingActivateContextMenuItem(_ item: NSMenuItem) -> Bool {
        let previous = matrixVisibilityCapability
        performMatrixContextMenuCommand(item)
        return matrixVisibilityCapability != previous
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

    var testingContentScrollOrigins:
        GenotypeMatrixContentScrollOrigins {
        matrixContentScrollOrigins
    }

    var testingNativeSelectedRowIndexes: IndexSet {
        tableView.selectedRowIndexes
    }

    func testingApplyNativeRowSelection(
        _ indexes: IndexSet,
        simulatedAppKitScrollOrigins:
            GenotypeMatrixContentScrollOrigins? = nil
    ) {
        _ = selectionShouldChange(in: tableView)
        if let simulatedAppKitScrollOrigins {
            testingSetContentScrollOrigins(
                pinned: simulatedAppKitScrollOrigins.pinned,
                samples: simulatedAppKitScrollOrigins.samples
            )
        }
        if indexes.isEmpty {
            tableView.deselectAll(nil)
        } else {
            tableView.selectRowIndexes(
                indexes,
                byExtendingSelection: false
            )
        }
        tableViewSelectionDidChange(
            Notification(
                name: NSTableView.selectionDidChangeNotification,
                object: tableView
            )
        )
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
                sampleHorizontalOrigin: scrollView.contentView.bounds.minX,
                leadingSampleID: nil,
                withinSampleOffset: 0
            )
        }
        return GenotypeMatrixSemanticScrollSnapshot(
            rowID: anchor.rowID,
            withinRowOffset: anchor.withinRowOffset,
            sampleHorizontalOrigin: anchor.sampleHorizontalOrigin,
            leadingSampleID: anchor.leadingSampleID,
            withinSampleOffset: anchor.withinSampleOffset
        )
    }

    func testingSetLeadingSampleScrollAnchor(
        sample: String,
        offset: CGFloat
    ) {
        guard let column = tableView.tableColumns.firstIndex(where: {
            sampleColumnLookup[$0.identifier] == sample
        }) else {
            return
        }
        let origin = NSPoint(
            x: tableView.rect(ofColumn: column).minX + offset,
            y: scrollView.contentView.bounds.minY
        )
        scrollView.contentView.scroll(to: origin)
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }

    var testingHeaderTextBandsFit: Bool {
        guard let header = tableView.headerView as? GenotypeMatrixHeaderView else {
            return false
        }
        let titleFont = header.titleFont?() ?? .systemFont(ofSize: 11, weight: .semibold)
        let readFont = header.readFont?()
            ?? .monospacedDigitSystemFont(ofSize: 10, weight: .regular)
        return tableView.tableColumns.indices.allSatisfy { column in
            let rect = header.ordinaryHeaderRect(ofColumn: column)
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

    func testingPerformNativeFilterAction(
        text: String,
        selectedRange: NSRange,
        in window: NSWindow
    ) -> Bool {
        filterField.isHidden = false
        guard window.makeFirstResponder(filterField),
              let editor = filterField.currentEditor()
                as? NSTextView else {
            return false
        }
        filterField.stringValue = text
        editor.string = text
        editor.setSelectedRange(
            normalizedFilterSelectionRange(
                selectedRange,
                for: text
            )
        )
        return filterField.sendAction(
            filterField.action,
            to: filterField.target
        )
    }

    var testingFilterModelText: String {
        filterText
    }

    var testingFilterNativeText: String {
        (filterField.currentEditor() as? NSTextView)?.string
            ?? filterField.stringValue
    }

    var testingFilterNativeSelectedRange: NSRange {
        guard let editor = filterField.currentEditor()
            as? NSTextView else {
            return committedNativeFilterState.selectedRange
        }
        return normalizedFilterSelectionRange(
            editor.selectedRange(),
            for: editor.string
        )
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
