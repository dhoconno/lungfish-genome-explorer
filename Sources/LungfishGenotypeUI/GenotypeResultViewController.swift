import AppKit
import SwiftUI
import LungfishCore
import LungfishIO
import LungfishWorkflow
import LungfishKit

public struct GenotypeResultDesiredConfigurationAuthority:
    Equatable, Sendable {
    public let bundleURL: URL?
    fileprivate let generation: UInt64

    fileprivate init(bundleURL: URL?, generation: UInt64) {
        self.bundleURL = bundleURL
        self.generation = generation
    }
}

struct GenotypeManualHaplotypeMultiSamplePresentation: Equatable {
    static let maximumVisibleSamples = 12

    let visibleSamples: [String]
    let omittedSampleCount: Int

    init(samples: [String]) {
        visibleSamples = Array(
            samples.prefix(Self.maximumVisibleSamples)
        )
        omittedSampleCount = max(0, samples.count - visibleSamples.count)
    }

    var omissionSummary: String? {
        guard omittedSampleCount > 0 else { return nil }
        let noun = omittedSampleCount == 1 ? "sample" : "samples"
        return
            "\(omittedSampleCount) additional selected \(noun) "
            + (omittedSampleCount == 1 ? "is" : "are")
            + " not shown."
    }
}

@MainActor
protocol GenotypeMatrixWorkbookUpdateCancellation: AnyObject {
    func cancel()
}

@MainActor
protocol GenotypeMatrixWorkbookUpdateScheduling: AnyObject {
    func schedule(
        _ action: @escaping @MainActor () -> Void
    ) -> GenotypeMatrixWorkbookUpdateCancellation
}

@MainActor
private final class DelayedGenotypeMatrixWorkbookUpdateScheduler:
    GenotypeMatrixWorkbookUpdateScheduling
{
    private final class Cancellation: GenotypeMatrixWorkbookUpdateCancellation {
        private var task: Task<Void, Never>?

        init(delayNanoseconds: UInt64, action: @escaping @MainActor () -> Void) {
            task = Task { @MainActor in
                do {
                    try await Task.sleep(nanoseconds: delayNanoseconds)
                } catch {
                    return
                }
                guard !Task.isCancelled else { return }
                action()
            }
        }

        func cancel() {
            task?.cancel()
            task = nil
        }
    }

    private let delayNanoseconds: UInt64

    init(delayNanoseconds: UInt64 = 350_000_000) {
        self.delayNanoseconds = delayNanoseconds
    }

    func schedule(
        _ action: @escaping @MainActor () -> Void
    ) -> GenotypeMatrixWorkbookUpdateCancellation {
        Cancellation(delayNanoseconds: delayNanoseconds, action: action)
    }
}

public enum GenotypeAIHaplotypingUIMode: String, CaseIterable, Sendable {
    case aiDiscovery
    case aiRefinement

    public var displayName: String {
        switch self {
        case .aiDiscovery: return "AI Discovery"
        case .aiRefinement: return "AI Refinement"
        }
    }
}

public struct GenotypeAIHaplotypingUIRequest: Equatable, Sendable {
    public let mode: GenotypeAIHaplotypingUIMode

    public init(mode: GenotypeAIHaplotypingUIMode) {
        self.mode = mode
    }
}

struct GenotypeCandidateSelectionCallbackCounts: Equatable {
    let known: Int
    let candidate: Int
}

struct GenotypeKnownSelectionDiagnostics: Equatable {
    fileprivate(set) var indexedCellSupportLookupCount = 0
    fileprivate(set) var supportFractionLabelEntryCount = 0
    fileprivate(set) var sameLocusCoOccurrenceEntryCount = 0
    fileprivate(set) var anchorSummaryEntryCount = 0
    fileprivate(set) var anchorSummariesEntryCount = 0
    fileprivate(set) var supportingSampleTableEntryCount = 0
    fileprivate(set) var coOccurrenceTableEntryCount = 0

    var aggregateEvidenceHelperEntryCount: Int {
        supportFractionLabelEntryCount
            + sameLocusCoOccurrenceEntryCount
            + anchorSummaryEntryCount
            + anchorSummariesEntryCount
            + supportingSampleTableEntryCount
            + coOccurrenceTableEntryCount
    }
}

@MainActor
public final class GenotypeResultViewController: NSViewController {
    typealias Lens = GenotypeResultViewportLens
    typealias GenotypeResultLoader = @Sendable (URL) async throws -> ONTGenotypeResultBundleData

    private enum DeferredMatrixAnnotationMutation {
        case style(
            request: GenotypeMatrixStyleRequest,
            store: GenotypeAnnotationStore,
            author: String
        )
        case review(
            request: GenotypeMatrixReviewRequest,
            store: GenotypeAnnotationStore,
            author: String
        )
        case comment(
            request: GenotypeMatrixCommentEditRequest,
            store: GenotypeAnnotationStore,
            author: String
        )

        var store: GenotypeAnnotationStore {
            switch self {
            case let .style(_, store, _),
                 let .review(_, store, _),
                 let .comment(_, store, _):
                return store
            }
        }
    }

    private enum MatrixAnnotationMutationAttempt {
        case success
        case lockHeld
        case failure(Error, sidecarBeforeAttempt: GenotypeAnnotationSidecar)
    }

    private enum ManualHaplotypeEditorError: Error, LocalizedError {
        case unavailable

        var errorDescription: String? {
            "The manual haplotype assignment store is no longer available."
        }
    }

    private struct SharedCallKey: Hashable {
        let locus: String
        let genotype: String
    }

    private struct CellEvidenceKey: Hashable {
        let locus: String
        let genotype: String
        let sample: String
    }

    public var onSelectionStateChanged: ((GenotypeResultSelectionState?) -> Void)?
    public var onDisplaySummaryChanged: ((Int, Int, Int) -> Void)?
    public var onDisplayStateChanged: ((GenotypeResultDisplayState) -> Void)?
    public var manualHaplotypeBandDisclosureStore:
        GenotypeManualHaplotypeBandDisclosureStore?
    public var onAnnotationSidecarChanged: ((GenotypeAnnotationSidecar) -> Void)?
    public var onMatrixReviewCapabilityChanged: ((GenotypeMatrixReviewCapabilityState) -> Void)?
    public var onMatrixVisibilityCapabilityChanged:
        ((GenotypeMatrixVisibilityCapabilitySnapshot) -> Void)?
    public var onMatrixAnnotationCommandError: ((Error) -> Void)?
    public var onCandidatePersistenceWarningChanged: ((String?) -> Void)?
    public var onCurrentWorkbookSyncRequested: ((GenotypeCurrentWorkbookUIRequest) -> Void)?
    public var onDeferredMatrixAnnotationMutationsDrained: (() -> Void)?

    public var currentResultBundleURL: URL? {
        result?.bundleURL
    }

    public var desiredResultConfigurationAuthority:
        GenotypeResultDesiredConfigurationAuthority {
        GenotypeResultDesiredConfigurationAuthority(
            bundleURL: desiredResultConfigurationBundleURL,
            generation: resultConfigurationGeneration
        )
    }

    public func ownsDesiredResultConfiguration(
        _ authority: GenotypeResultDesiredConfigurationAuthority
    ) -> Bool {
        resultConfigurationGeneration == authority.generation
            && desiredResultConfigurationBundleURL
                == authority.bundleURL
    }

    public var currentResultBundleIsReadOnly: Bool {
        annotationStore?.isReadOnly ?? true
    }

    public var hasDeferredMatrixAnnotationMutations: Bool {
        !deferredMatrixAnnotationMutations.isEmpty
    }

    public func detachHostPresentationCallbacks() {
        onSelectionStateChanged = nil
        onDisplaySummaryChanged = nil
        onDisplayStateChanged = nil
        onAnnotationSidecarChanged = nil
        onMatrixReviewCapabilityChanged = nil
        onMatrixVisibilityCapabilityChanged = nil
        onMatrixAnnotationCommandError = nil
        onCandidatePersistenceWarningChanged = nil
        onAIHaplotypingRequested = nil
    }

    public var onAIHaplotypingRequested: ((URL, GenotypeAIHaplotypingUIRequest) -> Void)?
    /// Supplied by the host application so annotations capture the active identity at edit time.
    public var annotationAuthorProvider: () -> String = { NSUserName() }
    public var windowStateScope: WindowStateScope?
    var genotypeResultLoader: GenotypeResultLoader = { bundleURL in
        try await ONTGenotypeResultBundle.loadResultAsync(from: bundleURL)
    }

    private let lensControl = NSSegmentedControl(
        labels: Lens.allCases.map(\.displayName),
        trackingMode: .selectOne,
        target: nil,
        action: nil
    )
    private let contentHost = NSView()
    private var contentHostTopConstraint: NSLayoutConstraint!

    private let splitView = TrackedDividerSplitView()
    private let sampleContainer = NSView()
    private let detailContainer = NSView()
    private let comparisonMatrix = GenotypeComparisonMatrixView()
    private let outlineView = GenotypeOutlineView()
    private let haplotypeMatrixView = GenotypeHaplotypeDefinitionMatrixView()
    private let cohortSummaryPanel = GenotypeCohortSummaryPanelView()
    private let quickFilterBar = GenotypeQuickFilterBarView()
    private let detailScrollView = NSScrollView()
    private let detailDocumentView = FlippedDocumentView()
    private let detailStack = NSStackView()
    private let knownAlleleDetailView = GenotypeKnownAlleleDetailView()
    private let candidateAlleleDetailView = GenotypeCandidateAlleleDetailView()
    private let alleleSequenceDetailView = GenotypeAlleleSequenceDetailView()
    private var detailContentTypographyObservation: ContentTypographyViewObservation?
    private var styledGeneratedDetailFields: [NSTextField] = []
    private var lensContentTypographyObservations:
        [ObjectIdentifier: ContentTypographyViewObservation] = [:]
    private var haplotypeLensBuildCount = 0
    private var consumerLensBuildCount = 0
    private var anchorLensBuildCount = 0
    private var artifactLensBuildCount = 0
#if DEBUG
    private var testingLayoutApplicationCount = 0
    private var testingCohortSummaryRebuildCount = 0
#endif
    private static let generatedContentHostingViewIdentifier =
        NSUserInterfaceItemIdentifier("GenotypeGeneratedContentHostingView")

    private let haplotypeScrollView = NSScrollView()
    private let haplotypeStack = NSStackView()
    private let consumerScrollView = NSScrollView()
    private let consumerStack = NSStackView()
    private let anchorScrollView = NSScrollView()
    private let anchorStack = NSStackView()
    private let artifactScrollView = NSScrollView()
    private let artifactStack = NSStackView()

    private let splitCoordinator = TwoPaneTrackedSplitCoordinator()

    private var result: ONTGenotypeResultBundleData?
    public private(set) var manualHaplotypeEligibility:
        GenotypeManualHaplotypeEligibility = .ineligible(
            reason: "No genotype result is loaded."
        )
    public var manualHaplotypeDisabledReason: String? {
        guard case .ineligible(let reason) = manualHaplotypeEligibility else { return nil }
        return reason
    }
    private var hasHaplotypingResult = false
    private var sampleMetadataStore: SampleMetadataStore?
    private var annotationStore: GenotypeAnnotationStore?
    private var manualHaplotypeEditorModel:
        GenotypeManualHaplotypeEditorModel?
    private weak var manualHaplotypeEditorHostView: NSView?
    private var sampleCurationWorkbench:
        GenotypeSampleCurationWorkbenchView?
    private var sampleWorkbenchWidthConstraint: NSLayoutConstraint?
    private var sampleSupportedAllelesSnapshot:
        GenotypeSupportedAllelesSnapshot?
#if DEBUG
    private var testingLastManualHaplotypeFocusIdentifier: String?
#endif
    private let manualHaplotypeEditorTypographyModel =
        ContentTypographyModel.shared
    private lazy var manualHaplotypeDraftCoordinator =
        GenotypeManualHaplotypeDraftCoordinator(
            hasUnsavedChanges: { [weak self] in
                self?.manualHaplotypeEditorModel?.draft.isDirty == true
            },
            revisionToken: { [weak self] in
                self?.manualHaplotypeEditorModel?.draftRevisionToken
            },
            save: { [weak self] in
                guard let model = self?.manualHaplotypeEditorModel else {
                    return true
                }
                model.save()
                return !model.draft.isDirty
            },
            prepareSave: { [weak self] in
                guard let model = self?.manualHaplotypeEditorModel else {
                    return true
                }
                return model.prepareSave()
            },
            finalizePreparedSave: { [weak self] in
                guard let model = self?.manualHaplotypeEditorModel else {
                    return true
                }
                return model.finalizePreparedSave()
            },
            cancelPreparedSave: { [weak self] in
                self?.manualHaplotypeEditorModel?.cancelPreparedSave()
            },
            discard: { [weak self] in
                guard let model = self?.manualHaplotypeEditorModel else {
                    return true
                }
                model.reload()
                return !model.draft.isDirty
            }
        )
    private var manualHaplotypeDraftDecisionProvider:
        ((GenotypeManualHaplotypeDraftCoordinator.Transition) async
            -> GenotypeManualHaplotypeDraftDecision)?
    private let manualHaplotypeTransitionMutationCoordinator =
        GenotypeManualHaplotypeTransitionMutationCoordinator()
    private var manualHaplotypingSelection: Set<String> = []
    private var manualHaplotypingDraftLabel: String = ""
    private var manualHaplotypingDraftColorTokenIndex: Int = 1
    private var activeSmartCohort: GenotypeCohortSmartFilter?
    private var quickFilterPredicate: SmartCohortPredicate?
    private var quickFilterSearchText: String = ""
    private var quickFilterState = GenotypeQuickFilterBarView.FilterState()
    private var genotypeSearchIndex: GenotypeSearchIndex?
    private var latestGenotypeSearchResult = GenotypeSearchIndex.Result.empty
    private var latestGenotypeSearchQuery = ""
    private var searchableAnnotationRecords:
        Set<GenotypeSearchIndex.AnnotationOrCommentRecord> = []
    private var searchIndexBuildCount = 0
    private var searchQueryCount = 0
    private var searchHaplotypeRecordBuildCount = 0
    private var callsBySample: [String: [ONTGenotypeCall]] = [:]
    private var sharedCallsByKey: [SharedCallKey: ONTGenotypeSharedCall] = [:]
    private var sampleSupportByCellKey: [CellEvidenceKey: ONTGenotypeSampleSupport] = [:]
    private var candidatePresentationsByStableClusterID: [
        String: GenotypeCandidateEvidenceProjection.IndexedPresentation
    ] = [:]
    private var callIndexBySample: [String: CallIndex] = [:]
    private var sampleResultsByName: [String: ONTGenotypeSampleResult] = [:]
    private var diagnosticDisplayGenotypeByIdentifier: [String: String] = [:]
    private var activeHaplotypeSamplesByName: [String: GenotypeHaplotypeSampleAnalysis] = [:]
    private var activeHaplotypeSampleNames: [String] = []
    private var diagnosticIdentifierSetsBySample: [String: Set<String>] = [:]
    private var animalGenotypesBySample: [String: [GenotypeCallEvidenceView.AnimalGenotype]] = [:]
    private var allFilterableSampleNamesCache: [String] = []
    private var observedLociIndex: GenotypeObservedLociIndex?
    private var matrixEvidenceIndex = GenotypeMatrixEvidenceIndex()
    private var matrixReviewsByTarget: [
        GenotypeAnnotationSidecar.MatrixTarget: GenotypeAnnotationSidecar.MatrixReviewAnnotation
    ] = [:]
    private var matrixCommentsByTarget: [
        GenotypeAnnotationSidecar.MatrixTarget: GenotypeAnnotationSidecar.MatrixComment
    ] = [:]
    private var matrixReviewCapability = GenotypeMatrixReviewCapability.evaluate(
        selection: [],
        evidence: .init(),
        reviews: [],
        comments: [],
        isWritable: false
    )
    private var matrixVisibilityCapability = GenotypeMatrixVisibilityCapabilitySnapshot(
        selection: .init(targets: []),
        visibility: .init()
    )
    private var matrixEvidenceIndexBuildCount = 0
    private var matrixAnnotationIndexBuildCount = 0
    private var cohortSubjectBuildCount = 0
    private var haplotypeWorkCount = 0
    private var indexedMatrixMutationRevision: UInt64?
    private var comparisonMatrixConfigured = false
    private var sampleDetailHostingController: NSHostingController<GenotypeSampleDetailSheet>?
    private var callEvidenceHost: NSHostingView<GenotypeCallEvidenceView>?
    /// Live re-analyzed haplotype calls — derived from raw calls + the
    /// thresholds recorded by the genotyping run when no persisted analysis is
    /// available or when the active project definition changes. `nil` falls
    /// back to the bundle's persisted analysis.
    private var liveHaplotypeAnalysis: GenotypeHaplotypeAnalysis?
    /// Per-project haplotype-definition store. Reads from / writes to
    /// `<projectRoot>/Haplotype Definitions/`. Populated from the bundle's
    /// surrounding project root in `configure(result:)`.
    private var haplotypeDefinitionStore = HaplotypeDefinitionStore(projectRoot: nil)
    private var cachedHaplotypeDefinitionContext: HaplotypeDefinitionContext?
    private var selectedLens: Lens = .summary
    private var displayState = GenotypeResultDisplayState()
    private var currentSharedCall: ONTGenotypeSharedCall?
    private var currentCandidateRow: GenotypeCandidateMatrixRow?
    private var candidatePersistenceWarning: String?
    private var candidateSettingsPersistenceTask: Task<Void, Never>?
    private var candidateSettingsPersistenceGeneration: UInt64 = 0
    private var pendingCandidateSettingsRequest: (
        settings: ONTMHCCandidateDisplaySettings,
        state: GenotypeResultDisplayState
    )?
    private var knownSelectionCallbackCount = 0
    private var candidateSelectionCallbackCount = 0
    private var knownSelectionDiagnostics = GenotypeKnownSelectionDiagnostics()
    private var knownAlleleDetailMountCount = 0
    private var candidateAlleleDetailMountCount = 0
    private var alleleSequenceDetailMountCount = 0
    private var candidateAlleleDetailWidthConstraint: NSLayoutConstraint?
    private var alleleSequenceDetailWidthConstraint: NSLayoutConstraint?
    private var alleleSequenceDetailHeightConstraint: NSLayoutConstraint?
    private var candidateSequenceRecordsByStableClusterID: [
        String: GenotypeAlleleSequenceRecord
    ] = [:]
    private var knownSequenceRecordsByRowID: [
        GenotypeCandidateMatrixRowID: GenotypeAlleleSequenceRecord
    ] = [:]
    private var provisionalExon2SequenceRecordsByGenotype: [
        String: GenotypeAlleleSequenceRecord
    ] = [:]
    private var renderedAlleleSequenceRecordIdentities: [String] = []
    private var knownAlleleSequenceRecordBuildCount = 0
    private var provisionalExon2SequenceRecordBuildCount = 0
    private var legacyNonRowDetailBuildCount = 0
    private var currentSelectedSample: String?
    private var currentSelectedLocus: String?
    private var currentSelectionState: GenotypeResultSelectionState?
    private var activeContentView: NSView?
    private var activeContentConstraints: [NSLayoutConstraint] = []
    private var haplotypeSampleActionTags: [Int: String] = [:]
    private var nextHaplotypeSampleActionTag = 1
    private var currentWorkbookNeedsRefresh = false
    private var currentWorkbookRequiresFullUpdate = false
    private var currentWorkbookUpdateStatus: String?
    private var currentWorkbookSyncPhase: GenotypeCurrentWorkbookUIPhase?
    private var currentWorkbookIsReadOnly = false
    private var testingCurrentWorkbookDirtyMarkCount = 0
    private var showsDeferredMatrixAnnotationStatus = false
    private var currentWorkbookAnnotationAutoUpdateTask: GenotypeMatrixWorkbookUpdateCancellation?
    var matrixWorkbookUpdateScheduler: GenotypeMatrixWorkbookUpdateScheduling =
        DelayedGenotypeMatrixWorkbookUpdateScheduler()
    var matrixAnnotationRetryScheduler: GenotypeMatrixWorkbookUpdateScheduling =
        DelayedGenotypeMatrixWorkbookUpdateScheduler(delayNanoseconds: 500_000_000)
    private var deferredMatrixAnnotationMutations: [DeferredMatrixAnnotationMutation] = []
    private var deferredMatrixAnnotationMutationHead = 0
    private var deferredMatrixAnnotationRetryTask: GenotypeMatrixWorkbookUpdateCancellation?
    private var pendingConfigurationResult: ONTGenotypeResultBundleData?
    private var currentWorkbookResultReloadTask: Task<Void, Never>?
    private var resultConfigurationGeneration: UInt64 = 0
    private var desiredResultConfigurationBundleURL: URL?
    private var aiHaplotypingStatus: String?
    private var outlineRowsBySample: [String: GenotypeOutlineView.Row] = [:]
    private var outlineRowOrder: [String] = []

    private var isGenotypeOnlyResult: Bool {
        guard case .eligible = manualHaplotypeEligibility else {
            return false
        }
        return true
    }

    private var availableLenses: [Lens] {
        isGenotypeOnlyResult ? [.summary, .audit] : Lens.allCases
    }

    private var viewportHeaderHeight: CGFloat {
        isGenotypeOnlyResult ? 36 : 48
    }

    private var isFullLengthMHCGenotypeViewport: Bool {
        guard case .eligible(let resultKind) = manualHaplotypeEligibility else {
            return false
        }
        return resultKind == .fullLengthONTMHCGenotype
    }

    public override func loadView() {
        let root = NSView()
        root.translatesAutoresizingMaskIntoConstraints = false
        root.setAccessibilityElement(true)
        root.setAccessibilityRole(.group)
        root.setAccessibilityLabel("Genotype result viewport")
        root.setAccessibilityIdentifier("genotype-result-view")
        view = root

        configureLensControl()
        configureContentHost()
        configureSplitView()
        configureDetailPane()
        configureScrollLens(haplotypeScrollView, stack: haplotypeStack, identifier: "genotype-haplotype-lens")
        configureScrollLens(anchorScrollView, stack: anchorStack, identifier: "genotype-anchor-lens")
        configureScrollLens(consumerScrollView, stack: consumerStack, identifier: "genotype-consumer-lens")
        configureScrollLens(artifactScrollView, stack: artifactStack, identifier: "genotype-artifacts-lens")
        layout()
        wireCallbacks()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleSmartCohortApplied(_:)),
            name: .genotypeResultSmartCohortApplied,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleSmartCohortSaveRequested(_:)),
            name: .genotypeResultSmartCohortSaveRequested,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleSmartCohortDeleteRequested(_:)),
            name: .genotypeResultSmartCohortDeleteRequested,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleSampleDetailSheetRequest(_:)),
            name: .genotypeResultRequestSampleDetailSheet,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleHaplotypeDefinitionsRequest(_:)),
            name: .genotypeResultOpenHaplotypeDefinitions,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleCurrentWorkbookUpdateRequest(_:)),
            name: .genotypeResultCurrentWorkbookUpdateRequested,
            object: nil
        )
    }

    @objc private func handleSampleDetailSheetRequest(_ notification: Notification) {
        guard let sample = notification.userInfo?["sample"] as? String else { return }
        presentSampleDetailSheet(forAnimal: sample)
    }

    @objc private func handleHaplotypeDefinitionsRequest(_ notification: Notification) {
        showLens(.audit)
        onDisplayStateChanged?(displayState)
    }

    @objc private func handleCurrentWorkbookUpdateRequest(_ notification: Notification) {
        guard shouldAcceptScopedNotification(notification) else { return }
        updateCurrentWorkbookFromOverrides()
    }

    private func applyQuickFilterState(_ state: GenotypeQuickFilterBarView.FilterState) {
        if requiresManualHaplotypeTransitionCoordination {
            quickFilterBar.restoreStateWithoutEmitting(quickFilterState)
            deferManualHaplotypeTransition(.search) { [weak self] in
                guard let self else { return }
                self.quickFilterBar.restoreStateWithoutEmitting(state)
                self.applyQuickFilterState(state)
            }
            return
        }
        quickFilterState = state
        quickFilterPredicate = state.pillPredicate
        quickFilterSearchText = state.searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        if quickFilterSearchText.isEmpty {
            quickFilterBar.updateEmptyState(query: "", hasMatches: true)
        } else {
            let matches = searchGenotypeViewport(quickFilterSearchText)
            quickFilterBar.updateEmptyState(
                query: quickFilterSearchText,
                hasMatches: matches.mode != .none
            )
        }
        refreshVisibleFilterDependentViews()
    }

    @objc private func handleSmartCohortApplied(_ notification: Notification) {
        guard shouldAcceptScopedNotification(notification) else { return }
        guard hasHaplotypingResult else {
            activeSmartCohort = nil
            quickFilterBar.setSavedCohortName(nil)
            return
        }
        guard let data = notification.userInfo?["cohort"] as? Data else {
            clearActiveSmartCohort()
            return
        }
        if let cohort = try? JSONDecoder().decode(GenotypeCohortSmartFilter.self, from: data) {
            applySmartCohort(cohort)
        }
    }

    private func applySmartCohort(_ cohort: GenotypeCohortSmartFilter) {
        guard hasHaplotypingResult else { return }
        activeSmartCohort = cohort
        quickFilterBar.setSavedCohortName(cohort.name)
        refreshVisibleFilterDependentViews()
    }

    @objc private func handleSmartCohortSaveRequested(_ notification: Notification) {
        guard shouldAcceptScopedNotification(notification) else { return }
        guard hasHaplotypingResult else { return }
        do {
            try saveCurrentFilterAsSmartCohort()
        } catch {
            presentSheetAlert(error: error)
        }
    }

    @objc private func handleSmartCohortDeleteRequested(_ notification: Notification) {
        guard shouldAcceptScopedNotification(notification) else { return }
        guard hasHaplotypingResult else { return }
        guard let data = notification.userInfo?["cohort"] as? Data,
              let cohort = try? JSONDecoder().decode(GenotypeCohortSmartFilter.self, from: data),
              let store = annotationStore else { return }
        let author = annotationAuthorProvider()
        do {
            try store.deleteSmartCohort(name: cohort.name, scope: cohort.scope, author: author)
            if activeSmartCohort?.name == cohort.name && activeSmartCohort?.scope == cohort.scope {
                activeSmartCohort = nil
                quickFilterBar.setSavedCohortName(nil)
            }
            refreshVisibleFilterDependentViews(rebuildCohortSummary: true)
            onAnnotationSidecarChanged?(store.sidecar)
        } catch {
            presentSheetAlert(error: error)
        }
    }

    private func saveCurrentFilterAsSmartCohort() throws {
        guard hasHaplotypingResult else { return }
        guard let store = annotationStore else { return }
        let author = annotationAuthorProvider()
        var predicates: [SmartCohortPredicate] = []
        var summaryParts: [String] = []
        if let activeSmartCohort {
            predicates.append(activeSmartCohort.predicate)
            summaryParts.append(activeSmartCohort.name)
        }
        if let predicate = quickFilterState.pillPredicate {
            predicates.append(predicate)
        }
        var searchProjectionText = activeSmartCohort.flatMap(
            savedSearchProjectionText
        )
        let search = quickFilterSearchText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !search.isEmpty {
            searchProjectionText = search
            let parsed = GenotypeQuickFilterBarView.parseSearchText(search)
            if case .metadataFieldContains = parsed {
                predicates.append(parsed)
            } else {
                let carriers = GenotypeCohortSmartFilter.canonicalSampleIDs(
                    sharedSearchCarrierSampleIDs(
                        for: searchGenotypeViewport(search)
                    )
                )
                predicates.append(
                    .animalIdIn(carriers)
                )
            }
        }
        if quickFilterState.pillPredicate != nil || !search.isEmpty {
            let summary = quickFilterState.displaySummary
            if !summary.isEmpty {
                summaryParts.append(summary)
            }
        }
        guard !predicates.isEmpty else { return }
        let predicate: SmartCohortPredicate = predicates.count == 1 ? predicates[0] : .all(predicates)
        let summary = summaryParts.isEmpty ? "Current Filter" : summaryParts.joined(separator: " + ")
        let cohort = GenotypeCohortSmartFilter(
            name: savedSmartCohortName(for: summary),
            description: "Saved from the current genotype filter.",
            scope: "bundle",
            isStarred: true,
            predicate: predicate,
            searchProjectionText: searchProjectionText
        )
        try store.saveSmartCohort(cohort, author: author)
        activeSmartCohort = cohort
        quickFilterBar.setSavedCohortName(cohort.name)
        refreshVisibleFilterDependentViews(rebuildCohortSummary: true)
        onAnnotationSidecarChanged?(store.sidecar)
    }

    private func savedSmartCohortName(for summary: String) -> String {
        let trimmed = summary.trimmingCharacters(in: .whitespacesAndNewlines)
        let fallback = trimmed.isEmpty ? "Current Filter" : trimmed
        let maxBodyLength = 56
        let body = fallback.count <= maxBodyLength
            ? fallback
            : String(fallback.prefix(maxBodyLength - 1)) + "…"
        return "Filter: \(body)"
    }

    private func clearActiveSmartCohort() {
        activeSmartCohort = nil
        quickFilterBar.setSavedCohortName(nil)
        refreshVisibleFilterDependentViews()
    }

    private func shouldAcceptScopedNotification(_ notification: Notification) -> Bool {
        guard let notificationScope = notification.userInfo?[NotificationUserInfoKey.windowStateScope] as? WindowStateScope else {
            return true
        }
        guard let windowStateScope else { return true }
        return notificationScope == windowStateScope
    }

    /// Push the current Smart Cohort + shared quick-search constraints into the
    /// Matrix. Query classification happens once in `GenotypeSearchIndex`;
    /// the matrix consumes stable IDs and never reinterprets the raw text.
    private func applyComparisonMatrixCohortFilter() {
        guard comparisonMatrixConfigured else { return }
        guard let result else {
            comparisonMatrix.applySharedSearchConstraints(
                allowedSampleIDs: nil,
                projectedRowIDs: nil
            )
            quickFilterBar.updateEmptyState(query: "", hasMatches: true)
            return
        }
        if activeSmartCohort == nil && quickFilterPredicate == nil && quickFilterSearchText.isEmpty {
            latestGenotypeSearchResult = .empty
            comparisonMatrix.applySharedSearchConstraints(
                allowedSampleIDs: nil,
                projectedRowIDs: nil
            )
            quickFilterBar.updateEmptyState(query: "", hasMatches: true)
            return
        }
        let baseAllowed = filteredSampleNames(
            result: result,
            sidecar: annotationStore?.sidecar,
            includingQuickSearch: false
        )
        let quickSearch = quickFilterSearchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let matrixSearch = quickSearch.isEmpty
            ? activeSmartCohort.flatMap(savedSearchProjectionText)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            : quickSearch
        guard !matrixSearch.isEmpty else {
            latestGenotypeSearchResult = .empty
            comparisonMatrix.applySharedSearchConstraints(
                allowedSampleIDs: baseAllowed,
                projectedRowIDs: nil
            )
            quickFilterBar.updateEmptyState(query: "", hasMatches: true)
            return
        }

        let matches = searchGenotypeViewport(matrixSearch)
        let constraints = sharedSearchConstraints(
            for: matches,
            baseAllowedSampleIDs: baseAllowed
        )
        comparisonMatrix.applySharedSearchConstraints(
            allowedSampleIDs: constraints.allowedSampleIDs,
            projectedRowIDs: constraints.projectedRowIDs
        )
        if quickSearch.isEmpty {
            quickFilterBar.updateEmptyState(query: "", hasMatches: true)
        } else {
            quickFilterBar.updateEmptyState(
                query: quickSearch,
                hasMatches: matches.mode != .none
            )
        }
    }

    private func refreshVisibleFilterDependentViews(rebuildCohortSummary shouldRebuildCohortSummary: Bool = false) {
        if selectedLens == .summary {
            if !comparisonMatrix.isHidden {
                applyComparisonMatrixCohortFilter()
            } else if !haplotypeMatrixView.isHidden {
                rebuildHaplotypeMatrix()
            } else {
                rebuildOutline()
            }
        } else if selectedLens == .review {
            rebuildOutline()
        } else if !comparisonMatrix.isHidden {
            applyComparisonMatrixCohortFilter()
        }
        if shouldRebuildCohortSummary {
            rebuildCohortSummary()
        }
    }

    private func ensureComparisonMatrixConfigured() {
        guard !comparisonMatrixConfigured, let result else { return }
        comparisonMatrixConfigured = true
        comparisonMatrix.configure(
            result: result,
            metadataStore: sampleMetadataStore,
            sidecar: annotationStore?.sidecar
        )
        // The configured matrix owns the exact projected/displayed row fields.
        // Replace any outline-built fallback index before applying quick search.
        invalidateGenotypeSearchIndex()
        comparisonMatrix.applyMatrixReviewCapability(matrixReviewCapability)
        comparisonMatrix.applyDisplayState(displayState)
        applyComparisonMatrixCohortFilter()
    }

    private func summaryMatrixUsesHaplotypeDefinitions() -> Bool {
        (result.map { $0.haplotypeAnalysis != nil && definitionSetForResult($0) != nil } ?? false)
            && !displayState.showsAncillaryLoci
    }

    private func defaultSummaryViewMode(for result: ONTGenotypeResultBundleData) -> GenotypeSummaryViewMode {
        result.haplotypeAnalysis == nil && !result.calls.isEmpty ? .matrix : .outline
    }

    private func initialSummaryViewMode(for result: ONTGenotypeResultBundleData) -> GenotypeSummaryViewMode {
        if let rawValue = annotationStore?.sidecar.settings.preferredSummaryViewMode,
           let mode = GenotypeSummaryViewMode(rawValue: rawValue) {
            return mode
        }
        return defaultSummaryViewMode(for: result)
    }

    /// Per-call keyboard shortcuts used by the Review lens:
    /// - `⌘R`: mark the currently selected sample's status as `reviewed`
    /// - `⌘K`: mark as `confirmed`
    /// - `⌘⇧F`: flag as `needsReview`
    /// - `⌘⇧O`: open the Sample Detail sheet for the override editor
    /// Returns true if the event was handled, allowing the responder chain
    /// to continue otherwise.
    public override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let cmd: NSEvent.ModifierFlags = .command
        let cmdShift: NSEvent.ModifierFlags = [.command, .shift]
        if modifiers == cmd,
           event.charactersIgnoringModifiers?.lowercased() == "f" {
            return quickFilterBar.focusSearchField()
                || super.performKeyEquivalent(with: event)
        }
        if modifiers.isEmpty,
           event.charactersIgnoringModifiers == "\u{1b}",
           !quickFilterSearchText.isEmpty {
            quickFilterBar.clearSearch()
            return true
        }
        // Review-only call shortcuts still require an active sample.
        guard selectedLens == .review, let animalId = currentSelectedSample else {
            return super.performKeyEquivalent(with: event)
        }
        switch (event.charactersIgnoringModifiers, modifiers) {
        case ("r", cmd):
            transitionSampleStatus(animalId: animalId, to: .reviewed)
            return true
        case ("k", cmd):
            transitionSampleStatus(animalId: animalId, to: .confirmed)
            return true
        case ("F", cmdShift):
            transitionSampleStatus(animalId: animalId, to: .needsReview)
            return true
        case ("O", cmdShift):
            presentSampleDetailSheet(forAnimal: animalId)
            return true
        default:
            return super.performKeyEquivalent(with: event)
        }
    }

    private func transitionSampleStatus(
        animalId: String, to value: GenotypeAnnotationSidecar.StatusValue
    ) {
        guard let store = annotationStore else { return }
        let author = annotationAuthorProvider()
        do {
            try store.setSampleStatus(value, sample: animalId, author: author)
        } catch {
            presentSheetAlert(error: error)
        }
        // Refresh the Smart Cohort counts and any Needs Review filter so the
        // user's status change reflects in the cohort list immediately.
        rebuildOutline()
        rebuildHaplotypeMatrix()
        rebuildCohortSummary()
        applyComparisonMatrixCohortFilter()
        onAnnotationSidecarChanged?(store.sidecar)
    }

    public override func viewDidLayout() {
        super.viewDidLayout()
        guard selectedLens == .summary, splitView.arrangedSubviews.count == 2 else { return }
        if view.window == nil {
            applySplitPositionIfNeeded()
        } else if splitCoordinator.needsInitialSplitValidation {
            scheduleInitialSplitValidationIfNeeded()
        }
    }

    public func configure(result: ONTGenotypeResultBundleData) {
        desiredResultConfigurationBundleURL =
            result.bundleURL.standardizedFileURL
        invalidateCurrentWorkbookResultReload()
        let requestedAuthority = desiredResultConfigurationAuthority
        if requiresManualHaplotypeTransitionCoordination {
            deferManualHaplotypeTransition(
                .eligibilityChange,
                mutation: { [weak self] in
                    self?.configureImmediately(result: result)
                },
                rejection: { [weak self] in
                    self?.restoreDisplayedResultAsDesiredConfiguration(
                        ifCurrent: requestedAuthority
                    )
                }
            )
            return
        }
        guard deferredMatrixAnnotationMutationCount == 0 else {
            pendingConfigurationResult = result
            return
        }
        configureImmediately(result: result)
    }

    private func restoreDisplayedResultAsDesiredConfiguration(
        ifCurrent authority:
            GenotypeResultDesiredConfigurationAuthority
    ) {
        guard ownsDesiredResultConfiguration(authority) else {
            return
        }
        desiredResultConfigurationBundleURL =
            result?.bundleURL.standardizedFileURL
        invalidateCurrentWorkbookResultReload()
    }

    private func configureImmediately(result: ONTGenotypeResultBundleData) {
        invalidateCurrentWorkbookResultReload()
        teardownSampleCurationWorkbench()
        currentWorkbookAnnotationAutoUpdateTask?.cancel()
        currentWorkbookAnnotationAutoUpdateTask = nil
        candidateSettingsPersistenceTask?.cancel()
        candidateSettingsPersistenceTask = nil
        pendingCandidateSettingsRequest = nil
        candidateSettingsPersistenceGeneration &+= 1
        self.result = result
        manualHaplotypeEligibility = GenotypeManualHaplotypeEligibility.evaluate(result)
        configureAvailableLensSegments()
        if case .eligible = manualHaplotypeEligibility {
            // A newly viewed eligible bundle is collapsed. Only an existing
            // window-owned, bundle-keyed presentation entry restores expansion.
            displayState.manualHaplotypeBandExpanded =
                manualHaplotypeBandDisclosureStore?
                    .expansion(for: result.bundleURL) ?? false
        }
        hasHaplotypingResult = result.haplotypeAnalysis != nil
        quickFilterBar.configureSearchCapability(
            hasHaplotypingResult: hasHaplotypingResult
        )
        invalidateGenotypeSearchIndex()
        if !hasHaplotypingResult {
            activeSmartCohort = nil
            quickFilterBar.setSavedCohortName(nil)
        }
        displayState = displayState.normalized(forGenotypeOnlyResult: isGenotypeOnlyResult)
        applyViewportHeaderVisibility()
        liveHaplotypeAnalysis = nil
        cachedHaplotypeDefinitionContext = nil
        comparisonMatrixConfigured = false
        matrixVisibilityCapability = GenotypeMatrixVisibilityCapabilitySnapshot(
            selection: .init(targets: []),
            visibility: .init()
        )
        onMatrixVisibilityCapabilityChanged?(matrixVisibilityCapability)
        currentWorkbookNeedsRefresh = false
        currentWorkbookRequiresFullUpdate = false
        currentWorkbookUpdateStatus = nil
        currentWorkbookSyncPhase = nil
        showsDeferredMatrixAnnotationStatus = false
        currentCandidateRow = nil
        candidatePersistenceWarning = nil
        onCandidatePersistenceWarningChanged?(nil)
        knownSelectionCallbackCount = 0
        candidateSelectionCallbackCount = 0
        knownSelectionDiagnostics = GenotypeKnownSelectionDiagnostics()
        knownAlleleDetailMountCount = 0
        candidateAlleleDetailMountCount = 0
        alleleSequenceDetailMountCount = 0
        knownAlleleSequenceRecordBuildCount = 0
        provisionalExon2SequenceRecordBuildCount = 0
        legacyNonRowDetailBuildCount = 0
        alleleSequenceDetailView.resetForNewResult()
        renderedAlleleSequenceRecordIdentities = []
        candidateAlleleDetailWidthConstraint?.isActive = false
        candidateAlleleDetailWidthConstraint = nil
        alleleSequenceDetailWidthConstraint?.isActive = false
        alleleSequenceDetailWidthConstraint = nil
        alleleSequenceDetailHeightConstraint?.isActive = false
        alleleSequenceDetailHeightConstraint = nil
        if isGenotypeOnlyResult {
            provisionalExon2SequenceRecordsByGenotype =
                result.provisionalExon2SequencesByGenotype.mapValues(
                    GenotypeAlleleSequenceRecord.provisionalExon2
                )
            provisionalExon2SequenceRecordBuildCount =
                provisionalExon2SequenceRecordsByGenotype.count
        } else {
            provisionalExon2SequenceRecordsByGenotype = [:]
        }
        if isFullLengthMHCGenotypeViewport {
            knownSequenceRecordsByRowID = [:]
            for sharedCall in result.locusSummaries.flatMap(\.sharedCalls) {
                let rowID = GenotypeCandidateMatrixRowID.known(
                    locus: sharedCall.locus,
                    genotype: sharedCall.genotype
                )
                guard knownSequenceRecordsByRowID[rowID] == nil else { continue }
                if let source = result.mhcReferenceVisualizations?
                    .recordsByKnownCallGenotype[sharedCall.genotype] {
                    knownSequenceRecordsByRowID[rowID] = .known(source)
                    knownAlleleSequenceRecordBuildCount += 1
                } else {
                    knownSequenceRecordsByRowID[rowID] = .unavailable(
                        identity: sharedCall.genotype,
                        displayName: alleleDisplayLabel(for: sharedCall.genotype)
                    )
                }
            }
            candidateSequenceRecordsByStableClusterID = GenotypeAlleleSequenceRecord
                .candidateCatalogRetainingValidRecords(
                    candidates: result.mhcCandidates?.candidates ?? [],
                    genBankURL: result.mhcCandidateGenBankArtifactURLs.candidateAlleles
                )
        } else {
            knownSequenceRecordsByRowID = [:]
            candidateSequenceRecordsByStableClusterID = [:]
        }
        let knownSampleIDs = Set(
            result.samples.map(\.sample)
                + result.calls.map(\.sample)
                + (result.haplotypeAnalysis?.samples.map(\.sample) ?? [])
        )
        rebuildResultIndexes(for: result)
        sampleMetadataStore = SampleMetadataStore.load(from: result.bundleURL, knownSampleIds: knownSampleIDs)
        // Wire the haplotype-definition store to the project root.
        // bundleURL is .../Analyses/<analysis-folder>/<bundle>; climb two
        // levels to reach the project root (where "Reference Sequences" /
        // "Haplotype Definitions" / "Primer Schemes" siblings live).
        let projectRoot = result.bundleURL
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        haplotypeDefinitionStore = HaplotypeDefinitionStore(projectRoot: projectRoot)
        annotationStore = try? GenotypeAnnotationStore(
            bundleURL: result.bundleURL,
            author: annotationAuthorProvider(),
            seedBuiltInSmartCohorts: result.haplotypeAnalysis != nil
        )
        currentWorkbookIsReadOnly = annotationStore?.isReadOnly ?? false
        rebuildMatrixAnnotationIndexes()
        publishMatrixReviewCapability(for: [])
        displayState.mhcCandidateDisplaySettings = validatedMHCCandidateDocument(from: result) == nil
            ? nil
            : (annotationStore?.sidecar.settings.mhcCandidateDisplay ?? .default)
        displayState.summaryViewMode = initialSummaryViewMode(for: result)
        displayState = displayState.normalized(forGenotypeOnlyResult: isGenotypeOnlyResult)
        if hasHaplotypingResult {
            if shouldEagerlyRecomputeHaplotypeAnalysis(for: result) {
                recomputeLiveHaplotypeAnalysis(evaluator: runHaplotypeDropoutEvaluator())
            } else {
                liveHaplotypeAnalysis = nil
            }
            rebuildActiveHaplotypeAnalysisIndexes()
            rebuildOutline()
            rebuildHaplotypeMatrix()
            rebuildCohortSummary()
        } else {
            clearUnsupportedHaplotypePresentation()
        }
        if isGenotypeOnlyResult || isFullLengthMHCGenotypeViewport {
            showEmptySelection()
        }
        showLens(.summary)
    }

    private func rebuildResultIndexes(for result: ONTGenotypeResultBundleData) {
        invalidateGenotypeSearchIndex()
        rebuildMatrixEvidenceIndex(for: result)
        callsBySample = Dictionary(grouping: result.calls, by: \.sample)
        sharedCallsByKey = Dictionary(uniqueKeysWithValues: result.locusSummaries
            .flatMap(\.sharedCalls)
            .map { (SharedCallKey(locus: $0.locus, genotype: $0.genotype), $0) })
        sampleSupportByCellKey = [:]
        sampleSupportByCellKey.reserveCapacity(result.calls.count)
        for call in result.calls {
            let key = CellEvidenceKey(
                locus: call.locusGroup,
                genotype: call.genotype,
                sample: call.sample
            )
            guard sampleSupportByCellKey[key] == nil else { continue }
            sampleSupportByCellKey[key] = ONTGenotypeSampleSupport(
                sample: call.sample,
                passedAlignments: call.passedAlignments,
                passedUniqueReads: call.passedUniqueReads,
                sampleUniqueRetainedReads: call.sampleUniqueRetainedReads
            )
        }
        callIndexBySample = callsBySample.mapValues { callIndex(for: $0) }
        sampleResultsByName = Dictionary(uniqueKeysWithValues: result.samples.map { ($0.sample, $0) })
        if let document = validatedMHCCandidateDocument(from: result),
           let artifacts = result.manifest.mhcCandidateArtifacts {
            candidatePresentationsByStableClusterID = GenotypeCandidateEvidenceProjection.indexedPresentations(
                document: document,
                artifacts: artifacts
            )
        } else {
            candidatePresentationsByStableClusterID = [:]
        }
        observedLociIndex = GenotypeObservedLociIndex.build(from: result)
        allFilterableSampleNamesCache = []
        var bestByIdentifier: [String: ONTGenotypeCall] = [:]
        bestByIdentifier.reserveCapacity(result.calls.count)
        for call in result.calls {
            let identifier = Self.genotypeIdentifier(call.genotype)
            guard !identifier.isEmpty else { continue }
            if let existing = bestByIdentifier[identifier] {
                if call.passedUniqueReads > existing.passedUniqueReads
                    || (
                        call.passedUniqueReads == existing.passedUniqueReads
                        && call.genotype.localizedStandardCompare(existing.genotype) == .orderedAscending
                    ) {
                    bestByIdentifier[identifier] = call
                }
            } else {
                bestByIdentifier[identifier] = call
            }
        }
        diagnosticDisplayGenotypeByIdentifier = bestByIdentifier.mapValues(\.genotype)
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

    private func rebuildActiveHaplotypeAnalysisIndexes() {
        invalidateGenotypeSearchIndex()
        activeHaplotypeSamplesByName.removeAll()
        activeHaplotypeSampleNames.removeAll()
        diagnosticIdentifierSetsBySample.removeAll()
        animalGenotypesBySample.removeAll()
        guard hasHaplotypingResult else {
            allFilterableSampleNamesCache = []
            return
        }
        haplotypeWorkCount += 1
        guard let analysis = activeHaplotypeAnalysis() else { return }
        activeHaplotypeSampleNames.reserveCapacity(analysis.samples.count)
        diagnosticIdentifierSetsBySample.reserveCapacity(analysis.samples.count)
        for sample in analysis.samples {
            activeHaplotypeSamplesByName[sample.sample] = sample
            activeHaplotypeSampleNames.append(sample.sample)
            diagnosticIdentifierSetsBySample[sample.sample] = diagnosticIdentifiers(for: sample)
        }
        allFilterableSampleNamesCache = []
    }

    private func clearUnsupportedHaplotypePresentation() {
        liveHaplotypeAnalysis = nil
        activeHaplotypeSamplesByName.removeAll()
        activeHaplotypeSampleNames.removeAll()
        diagnosticIdentifierSetsBySample.removeAll()
        animalGenotypesBySample.removeAll()
        allFilterableSampleNamesCache = []
        outlineRowsBySample.removeAll()
        outlineRowOrder.removeAll()
        outlineView.configure(rows: [])
        haplotypeMatrixView.configure(rows: [], definitionName: nil)
        manualHaplotypingSelection = []
    }

    /// Thresholds that were fixed at genotyping time and recorded in the run
    /// stats. These are the only thresholds the viewport uses to explain
    /// haplotype omissions; Inspector controls no longer recompute calls live.
    private func runHaplotypeDropoutEvaluator() -> GenotypeDropoutEvaluator? {
        guard let result else { return nil }
        let metrics = result.stats.rawMetrics
        let absolute = Self.intMetric(metrics["minSupport"]).flatMap { $0 > 1 ? $0 : nil }
        let sampleFraction = Self.percentMetric(metrics["haplotypeMinSamplePercent"])
        let locusFraction = Self.percentMetric(metrics["haplotypeMinLocusPercent"])
        let overrides = Self.locusPercentOverridesMetric(metrics["haplotypeMinLocusPercentOverrides"])
        guard absolute != nil || sampleFraction != nil || locusFraction != nil || !overrides.isEmpty else {
            return nil
        }
        return GenotypeDropoutEvaluator(
            absolute: absolute,
            sampleFraction: sampleFraction,
            locusFraction: locusFraction,
            locusFractionOverrides: overrides
        )
    }

    private static func intMetric(_ value: String?) -> Int? {
        guard let number = doubleMetric(value) else { return nil }
        return Int(number)
    }

    private static func percentMetric(_ value: String?) -> Double? {
        guard let percent = doubleMetric(value), percent > 0 else { return nil }
        return min(percent / 100.0, 1.0)
    }

    private static func doubleMetric(_ value: String?) -> Double? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.lowercased() != "null" else { return nil }
        return Double(trimmed)
    }

    private static func locusPercentOverridesMetric(_ value: String?) -> [String: Double] {
        guard let value else { return [:] }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.lowercased() != "null" else { return [:] }
        let entries: [String]
        if let data = trimmed.data(using: .utf8),
           let decoded = try? JSONSerialization.jsonObject(with: data) as? [String] {
            entries = decoded
        } else {
            entries = trimmed
                .split(separator: ",")
                .map { String($0) }
        }
        var overrides: [String: Double] = [:]
        for entry in entries {
            let parts = entry.split(separator: "=", maxSplits: 1).map {
                String($0).trimmingCharacters(in: .whitespacesAndNewlines)
            }
            guard parts.count == 2,
                  !parts[0].isEmpty,
                  let percent = Double(parts[1]),
                  percent > 0 else { continue }
            overrides[parts[0]] = min(percent / 100.0, 1.0)
        }
        return overrides
    }

    public func applySampleMetadataStore(_ store: SampleMetadataStore?) {
        sampleMetadataStore = store
        invalidateGenotypeSearchIndex()
        if comparisonMatrixConfigured {
            comparisonMatrix.applyMetadataStore(store)
        }
        refreshVisibleFilterDependentViews()
        rebuildConsumerLens()
        if let currentSharedCall {
            showSharedCall(currentSharedCall, sample: currentSelectedSample)
        }
    }

    private func rebuildMatrixEvidenceIndex(for result: ONTGenotypeResultBundleData) {
        var readsByTarget: [GenotypeAnnotationSidecar.MatrixTarget: Int] = [:]
        readsByTarget.reserveCapacity(
            result.calls.count + (result.mhcCandidates?.observations.count ?? 0)
        )
        for call in result.calls {
            let target = GenotypeAnnotationSidecar.MatrixTarget.cell(
                locus: call.locusGroup,
                genotype: call.genotype,
                sample: call.sample
            )
            readsByTarget[target] = max(readsByTarget[target] ?? 0, call.passedUniqueReads)
        }
        if let candidateDocument = result.mhcCandidates {
            let candidatesByStableID = Dictionary(
                candidateDocument.candidates.map { ($0.stableClusterID, $0) },
                uniquingKeysWith: { _, latest in latest }
            )
            for observation in candidateDocument.observations {
                guard let candidate = candidatesByStableID[observation.stableClusterID] else {
                    continue
                }
                let target = GenotypeAnnotationSidecar.MatrixTarget.cell(
                    locus: candidate.locus,
                    genotype: candidate.provisionalName,
                    sample: observation.sampleID,
                    stableClusterID: candidate.stableClusterID
                )
                readsByTarget[target, default: 0] += observation.aggregatedSampleReadCount
            }
        }
        matrixEvidenceIndex = GenotypeMatrixEvidenceIndex(readsByTarget)
        matrixEvidenceIndexBuildCount += 1
    }

    @discardableResult
    private func rebuildMatrixAnnotationIndexes() -> Bool {
        let nextSearchableAnnotations = Set(searchAnnotationAndCommentRecords())
        let searchDependenciesChanged =
            nextSearchableAnnotations != searchableAnnotationRecords
        searchableAnnotationRecords = nextSearchableAnnotations
        if searchDependenciesChanged {
            invalidateGenotypeSearchIndex()
        }
        guard let sidecar = annotationStore?.sidecar else {
            matrixReviewsByTarget = [:]
            matrixCommentsByTarget = [:]
            matrixAnnotationIndexBuildCount += 1
            indexedMatrixMutationRevision = nil
            return searchDependenciesChanged
        }
        matrixReviewsByTarget = Dictionary(
            sidecar.matrixReviews.map { ($0.target, $0) },
            uniquingKeysWith: { _, latest in latest }
        )
        matrixCommentsByTarget = sidecar.resolvedMatrixComments
        matrixAnnotationIndexBuildCount += 1
        indexedMatrixMutationRevision = annotationStore?.matrixMutationRevision
        return searchDependenciesChanged
    }

    private func publishMatrixReviewCapability(
        for targets: [GenotypeAnnotationSidecar.MatrixTarget]
    ) {
        matrixReviewCapability = GenotypeMatrixReviewCapability.evaluate(
            selection: targets,
            evidence: matrixEvidenceIndex,
            reviews: targets.compactMap { matrixReviewsByTarget[$0] },
            comments: applicableCommentTargets(for: targets).compactMap {
                matrixCommentsByTarget[$0]
            },
            isWritable: !(annotationStore?.isReadOnly ?? true)
        )
        comparisonMatrix.applyMatrixReviewCapability(matrixReviewCapability)
        onMatrixReviewCapabilityChanged?(matrixReviewCapability)
    }

    public func notifySelectionStateIfAvailable() {
        onMatrixReviewCapabilityChanged?(matrixReviewCapability)
        onSelectionStateChanged?(currentSelectionState)
    }

    public func notifyMatrixVisibilityCapabilityIfAvailable() {
        onMatrixVisibilityCapabilityChanged?(matrixVisibilityCapability)
    }

    public func notifyDisplayStateIfAvailable() {
        onDisplayStateChanged?(displayState)
    }

    public func applyDisplayState(_ state: GenotypeResultDisplayState) {
        if requiresManualHaplotypeTransitionCoordination {
            let transition:
                GenotypeManualHaplotypeDraftCoordinator.Transition =
                    state.viewportLens != displayState.viewportLens
                        ? .lens
                        : .filter
            deferManualHaplotypeTransition(transition) { [weak self] in
                self?.applyDisplayState(state)
            }
            return
        }
        if state.mhcCandidateDisplaySettings != displayState.mhcCandidateDisplaySettings,
           let result,
           validatedMHCCandidateDocument(from: result) != nil,
           let requestedSettings = state.mhcCandidateDisplaySettings {
            persistCandidateDisplaySettings(requestedSettings, requestedState: state)
            return
        }
        applyDisplayStateImmediately(state)
    }

    private func applyDisplayStateImmediately(_ state: GenotypeResultDisplayState) {
        let state = state.normalized(forGenotypeOnlyResult: isGenotypeOnlyResult)
        let previousDisplayState = displayState
        let candidateSearchProjectionChanged = candidateVisibilityChanged(
            from: previousDisplayState.mhcCandidateDisplaySettings,
            to: state.mhcCandidateDisplaySettings
        )
        let hasMatrixBackedSelection = currentSelectionState?.matrixTargets.isEmpty == false
        let matrixWillRefreshActiveSelection = comparisonMatrixConfigured
            && hasMatrixBackedSelection
            && state.requiresMatrixFilterPass(comparedTo: previousDisplayState)
        let previousViewMode = displayState.summaryViewMode
        let previousAncillary = displayState.showsAncillaryLoci
        let previousIncludedLoci = displayState.includedLoci
        let previousCohortFlagThreshold = displayState.cohortFlagThreshold
        let previousLayout = displayState.layout
        let lensChanged = selectedLens != state.viewportLens
        let anchorProjectionChanged =
            displayState.activeMinimumSupportPercent
                != state.activeMinimumSupportPercent
            || displayState.supportDenominator != state.supportDenominator
        let matrixOnlyChange = state != displayState
            && state == displayState.replacingMatrixPresentation(from: state)
        var cohortFlagState = displayState
        cohortFlagState.cohortFlagThreshold = state.cohortFlagThreshold
        let cohortFlagOnlyChange = state != displayState
            && state == cohortFlagState
        let narrowDisplayChange = matrixOnlyChange || cohortFlagOnlyChange
        displayState = state
        persistSummaryViewPreferenceIfNeeded(
            previousViewMode: previousViewMode,
            nextViewMode: state.summaryViewMode
        )
        if lensChanged {
            showLens(state.viewportLens)
        } else {
            lensControl.selectedSegment = segmentIndex(for: state.viewportLens)
            if selectedLens == .summary {
                applySummaryViewModeVisibility()
            }
        }
        if state.summaryViewMode == .matrix {
            ensureComparisonMatrixConfigured()
            comparisonMatrix.applyDisplayState(state)
        } else if comparisonMatrixConfigured {
            comparisonMatrix.applyDisplayState(state)
        }
        if anchorProjectionChanged || !narrowDisplayChange {
            rebuildAnchorLens()
        }
        if !narrowDisplayChange {
            rebuildConsumerLens()
        }
        if previousViewMode != state.summaryViewMode
            || previousAncillary != state.showsAncillaryLoci
            || previousIncludedLoci != state.includedLoci {
            rebuildOutline()
            rebuildHaplotypeMatrix()
            rebuildCohortSummary()
        } else if previousCohortFlagThreshold != state.cohortFlagThreshold {
            rebuildCohortSummary()
        }
        if !lensChanged,
           previousLayout != state.layout
            || previousViewMode != state.summaryViewMode {
            applyLayoutPreference()
        }
        if !matrixWillRefreshActiveSelection,
           currentSelectionState?.matrixTargets.isEmpty == false {
            refreshCurrentSelectionDetails()
        }
        if candidateSearchProjectionChanged {
            invalidateGenotypeSearchIndex()
            refreshActiveSharedSearchAfterDependencyChange()
        }
    }

    private func candidateVisibilityChanged(
        from previous: ONTMHCCandidateDisplaySettings?,
        to next: ONTMHCCandidateDisplaySettings?
    ) -> Bool {
        let previous = previous ?? .default
        let next = next ?? .default
        return previous.showKnown != next.showKnown
            || previous.showSharedCandidates != next.showSharedCandidates
            || previous.showSingletonCandidates != next.showSingletonCandidates
    }

    private func persistCandidateDisplaySettings(
        _ requestedSettings: ONTMHCCandidateDisplaySettings,
        requestedState: GenotypeResultDisplayState
    ) {
        guard let store = annotationStore, !store.isReadOnly else {
            candidatePersistenceWarning = "Candidate display settings could not be saved because this bundle is read-only."
            onCandidatePersistenceWarningChanged?(candidatePersistenceWarning)
            onDisplayStateChanged?(displayState)
            refreshCandidateSelectionDetails()
            return
        }
        if candidateSettingsPersistenceTask != nil {
            pendingCandidateSettingsRequest = (requestedSettings, requestedState)
            return
        }
        candidateSettingsPersistenceGeneration &+= 1
        let generation = candidateSettingsPersistenceGeneration
        let expectedSettings = store.sidecar.settings.mhcCandidateDisplay
        let bundleURL = store.bundleURL
        let author = annotationAuthorProvider()
        candidateSettingsPersistenceTask = Task { @MainActor [weak self] in
            guard let self, !Task.isCancelled,
                  generation == self.candidateSettingsPersistenceGeneration else { return }
            do {
                let published = try await GenotypeCandidateDisplayPersistence.persist(
                    display: requestedSettings,
                    expectedDisplay: expectedSettings,
                    bundleURL: bundleURL,
                    author: author
                )
                guard !Task.isCancelled,
                      generation == self.candidateSettingsPersistenceGeneration else { return }
                self.annotationStore = try? GenotypeAnnotationStore(
                    bundleURL: bundleURL,
                    author: author,
                    seedBuiltInSmartCohorts: self.hasHaplotypingResult
                )
                self.rebuildMatrixAnnotationIndexes()
                self.publishMatrixReviewCapability(
                    for: self.currentSelectionState?.matrixTargets ?? []
                )
                self.candidatePersistenceWarning = nil
                self.onCandidatePersistenceWarningChanged?(nil)
                var persistedState = requestedState
                persistedState.mhcCandidateDisplaySettings = published.settings.mhcCandidateDisplay
                self.applyDisplayStateImmediately(persistedState)
                self.comparisonMatrix.applyAnnotationSidecar(published, reload: false)
                self.onAnnotationSidecarChanged?(published)
                self.onDisplayStateChanged?(persistedState)
                if expectedSettings.tints != published.settings.mhcCandidateDisplay.tints {
                    self.markCurrentWorkbookDirty(
                        requiresFullUpdate: true,
                        legacyStatus: "current.xlsx does not include candidate tint changes."
                    )
                }
                self.finishCandidateSettingsPersistence(processPending: true)
            } catch {
                guard !Task.isCancelled,
                      generation == self.candidateSettingsPersistenceGeneration else { return }
                self.candidatePersistenceWarning = error.localizedDescription
                self.onCandidatePersistenceWarningChanged?(self.candidatePersistenceWarning)
                let latest: GenotypeAnnotationSidecar
                if let conflict = error as? GenotypeCandidateDisplayPersistenceError {
                    latest = conflict.latestSidecar
                } else {
                    latest = (try? GenotypeAnnotationStore(
                        bundleURL: bundleURL,
                        author: author,
                        seedBuiltInSmartCohorts: self.hasHaplotypingResult
                    ).sidecar)
                        ?? store.sidecar
                }
                self.annotationStore = try? GenotypeAnnotationStore(
                    bundleURL: bundleURL,
                    author: author,
                    seedBuiltInSmartCohorts: self.hasHaplotypingResult
                )
                self.rebuildMatrixAnnotationIndexes()
                self.publishMatrixReviewCapability(
                    for: self.currentSelectionState?.matrixTargets ?? []
                )
                var restoredState = self.displayState
                restoredState.mhcCandidateDisplaySettings = latest.settings.mhcCandidateDisplay
                self.applyDisplayStateImmediately(restoredState)
                self.comparisonMatrix.applyAnnotationSidecar(latest, reload: false)
                self.onAnnotationSidecarChanged?(latest)
                self.onDisplayStateChanged?(restoredState)
                self.refreshCandidateSelectionDetails()
                self.finishCandidateSettingsPersistence(processPending: false)
            }
        }
    }

    private func finishCandidateSettingsPersistence(processPending: Bool) {
        candidateSettingsPersistenceTask = nil
        guard processPending, let pendingCandidateSettingsRequest else {
            self.pendingCandidateSettingsRequest = nil
            return
        }
        self.pendingCandidateSettingsRequest = nil
        persistCandidateDisplaySettings(
            pendingCandidateSettingsRequest.settings,
            requestedState: pendingCandidateSettingsRequest.state
        )
    }

    private func refreshCandidateSelectionDetails() {
        if let currentCandidateRow {
            showCandidateRow(
                currentCandidateRow,
                sample: currentSelectedSample,
                matrixTargets: currentSelectionState?.matrixTargets ?? []
            )
        }
    }

    private func persistSummaryViewPreferenceIfNeeded(
        previousViewMode: GenotypeSummaryViewMode,
        nextViewMode: GenotypeSummaryViewMode
    ) {
        guard previousViewMode != nextViewMode,
              let store = annotationStore,
              !store.isReadOnly else { return }
        let author = annotationAuthorProvider()
        do {
            try store.updateSettings(author: author) { settings in
                settings.preferredSummaryViewMode = nextViewMode.rawValue
            }
            onAnnotationSidecarChanged?(store.sidecar)
        } catch {
            presentSheetAlert(error: error)
        }
    }

    public func applyHighlight(_ request: GenotypeResultHighlightRequest) {
        let previousColor = previousHighlightColor(for: request)
        ensureComparisonMatrixConfigured()
        comparisonMatrix.applyHighlight(request)
        registerUndo(for: request, previousColor: previousColor)
        if currentSelectionState?.matrixTargets.isEmpty == false {
            refreshCurrentSelectionDetails()
        }
    }

    public func applyMatrixStyle(_ request: GenotypeMatrixStyleRequest) {
        guard let store = annotationStore else { return }
        submitMatrixAnnotationMutation(.style(
            request: request,
            store: store,
            author: annotationAuthorProvider()
        ))
    }

    private func applyMatrixStyle(
        _ request: GenotypeMatrixStyleRequest,
        store: GenotypeAnnotationStore,
        author: String
    ) throws {
        let requestedTargets = uniqueMatrixTargets(request.targets)
        if case .clear = request.field {
            let targets = matrixStyleTargetsToClear(for: requestedTargets, in: store.sidecar)
            let reloadTargets = uniqueMatrixTargets(requestedTargets + targets)
            guard !reloadTargets.isEmpty else { return }
            if !targets.isEmpty {
                try store.setMatrixStyles(targets.map { (target: $0, style: nil) }, author: author)
            }
            comparisonMatrix.applyAnnotationSidecar(store.sidecar, reloading: reloadTargets)
            refreshCurrentSelectionDetails()
            onAnnotationSidecarChanged?(store.sidecar)
            scheduleCurrentWorkbookUpdateForMatrixAnnotation()
            return
        }
        let broadTargets = request.minimumReads == nil
            ? []
            : requestedTargets.filter {
                switch $0 {
                case .row, .column:
                    return true
                case .cell:
                    return false
                }
            }
        let targets = request.minimumReads.map {
            comparisonMatrix.supportedCellTargets(from: requestedTargets, minimumReads: $0)
        } ?? requestedTargets
        let reloadTargets = uniqueMatrixTargets(broadTargets + targets)
        guard !reloadTargets.isEmpty else { return }
        let broadEdits = broadTargets.map { target in
            let current = matrixStyle(for: target, in: store.sidecar)
            let next = matrixStyle(current, removing: request.field)
            return (target: target, style: next)
        }
        let cellEdits = targets.map { target in
            let current = matrixStyle(for: target, in: store.sidecar)
            let next = matrixStyle(current, applying: request.field)
            return (target: target, style: next)
        }
        let edits = broadEdits + cellEdits
        try store.setMatrixStyles(edits, author: author)
        comparisonMatrix.applyAnnotationSidecar(store.sidecar, reloading: reloadTargets)
        if targets != requestedTargets {
            comparisonMatrix.replaceMatrixTargetSelection(targets)
            if targets.isEmpty {
                publishSelectionState(nil)
            } else {
                showMatrixTargetSelection(targets)
            }
        } else {
            refreshCurrentSelectionDetails()
        }
        onAnnotationSidecarChanged?(store.sidecar)
        scheduleCurrentWorkbookUpdateForMatrixAnnotation()
    }

    public func applyMatrixReview(_ request: GenotypeMatrixReviewRequest) {
        guard let store = annotationStore else { return }
        submitMatrixAnnotationMutation(.review(
            request: request,
            store: store,
            author: annotationAuthorProvider()
        ))
    }

    private func applyMatrixReview(
        _ request: GenotypeMatrixReviewRequest,
        store: GenotypeAnnotationStore,
        author: String
    ) throws {
        let targets = uniqueMatrixTargets(request.targets)
        switch request.intent {
        case let .set(disposition):
            try store.setMatrixReviewSynchronously(
                disposition,
                targets: targets,
                evidence: matrixEvidenceIndex,
                author: author
            )
        case .clear:
            try store.clearMatrixReviewSynchronously(targets: targets, author: author)
        }
        finishMatrixAnnotationPublication(store: store, targets: targets)
    }

    public func editMatrixComment(_ request: GenotypeMatrixCommentEditRequest) {
        guard let store = annotationStore else { return }
        submitMatrixAnnotationMutation(.comment(
            request: request,
            store: store,
            author: annotationAuthorProvider()
        ))
    }

    private func editMatrixComment(
        _ request: GenotypeMatrixCommentEditRequest,
        store: GenotypeAnnotationStore,
        author: String
    ) throws {
        let targets = uniqueMatrixTargets(request.targets)
        switch request.intent {
        case let .upsert(body):
            if targets.count > 1,
               targets.contains(where: { matrixCommentsByTarget[$0] != nil }) {
                throw GenotypeMatrixAnnotationCommandError.explicitBulkCommentReplaceRequired
            }
            try store.upsertMatrixCommentSynchronously(
                body: body.trimmingCharacters(in: .whitespacesAndNewlines),
                targets: targets,
                author: author
            )
        case .remove:
            try store.removeMatrixCommentsSynchronously(targets: targets, author: author)
        case let .replace(body):
            try store.upsertMatrixCommentSynchronously(
                body: body.trimmingCharacters(in: .whitespacesAndNewlines),
                targets: targets,
                author: author
            )
        }
        finishMatrixAnnotationPublication(store: store, targets: targets)
    }

    public func addMatrixComment(_ request: GenotypeMatrixCommentEditRequest) {
        editMatrixComment(request)
    }

    private var deferredMatrixAnnotationMutationCount: Int {
        deferredMatrixAnnotationMutations.count - deferredMatrixAnnotationMutationHead
    }

    private static let deferredMatrixAnnotationStatus =
        "Saving annotation after the workbook update finishes."

    private func submitMatrixAnnotationMutation(
        _ mutation: DeferredMatrixAnnotationMutation
    ) {
        guard deferredMatrixAnnotationMutationCount == 0 else {
            deferredMatrixAnnotationMutations.append(mutation)
            reportDeferredMatrixAnnotationSave()
            scheduleDeferredMatrixAnnotationRetry()
            return
        }
        switch attemptMatrixAnnotationMutation(mutation) {
        case .success:
            return
        case .lockHeld:
            deferredMatrixAnnotationMutations.append(mutation)
            reportDeferredMatrixAnnotationSave()
            scheduleDeferredMatrixAnnotationRetry()
        case let .failure(error, sidecarBeforeAttempt):
            surfaceMatrixAnnotationMutationFailure(
                error,
                mutation: mutation,
                sidecarBeforeAttempt: sidecarBeforeAttempt
            )
        }
    }

    private func attemptMatrixAnnotationMutation(
        _ mutation: DeferredMatrixAnnotationMutation
    ) -> MatrixAnnotationMutationAttempt {
        let sidecarBeforeAttempt = mutation.store.sidecar
        do {
            switch mutation {
            case let .style(request, store, author):
                try applyMatrixStyle(request, store: store, author: author)
            case let .review(request, store, author):
                try applyMatrixReview(request, store: store, author: author)
            case let .comment(request, store, author):
                try editMatrixComment(request, store: store, author: author)
            }
            return .success
        } catch {
            if isWorkbookPublicationLockHeld(error) {
                return .lockHeld
            }
            return .failure(error, sidecarBeforeAttempt: sidecarBeforeAttempt)
        }
    }

    private func surfaceMatrixAnnotationMutationFailure(
        _ error: Error,
        mutation: DeferredMatrixAnnotationMutation,
        sidecarBeforeAttempt: GenotypeAnnotationSidecar
    ) {
        switch mutation {
        case .style:
            presentSheetAlert(error: error)
        case .review, .comment:
            handleMatrixAnnotationCommandFailure(
                error,
                store: mutation.store,
                sidecarBeforeAttempt: sidecarBeforeAttempt
            )
        }
    }

    private func scheduleDeferredMatrixAnnotationRetry() {
        guard deferredMatrixAnnotationMutationCount > 0,
              deferredMatrixAnnotationRetryTask == nil else { return }
        deferredMatrixAnnotationRetryTask = matrixAnnotationRetryScheduler.schedule {
            [weak self] in
            guard let self else { return }
            self.deferredMatrixAnnotationRetryTask = nil
            self.retryDeferredMatrixAnnotationMutations()
        }
    }

    private func retryDeferredMatrixAnnotationMutations() {
        while deferredMatrixAnnotationMutationCount > 0 {
            let mutation = deferredMatrixAnnotationMutations[
                deferredMatrixAnnotationMutationHead
            ]
            switch attemptMatrixAnnotationMutation(mutation) {
            case .success:
                discardFirstDeferredMatrixAnnotationMutation()
            case .lockHeld:
                reportDeferredMatrixAnnotationSave()
                scheduleDeferredMatrixAnnotationRetry()
                return
            case let .failure(error, sidecarBeforeAttempt):
                discardFirstDeferredMatrixAnnotationMutation()
                surfaceMatrixAnnotationMutationFailure(
                    error,
                    mutation: mutation,
                    sidecarBeforeAttempt: sidecarBeforeAttempt
                )
            }
        }
        clearDeferredMatrixAnnotationStatusIfNeeded()
        if let pendingConfigurationResult {
            self.pendingConfigurationResult = nil
            configure(result: pendingConfigurationResult)
        }
        onDeferredMatrixAnnotationMutationsDrained?()
    }

    private func reportDeferredMatrixAnnotationSave() {
        guard !showsDeferredMatrixAnnotationStatus else {
            return
        }
        showsDeferredMatrixAnnotationStatus = true
        rebuildArtifactLens()
    }

    private func clearDeferredMatrixAnnotationStatusIfNeeded() {
        guard deferredMatrixAnnotationMutationCount == 0,
              showsDeferredMatrixAnnotationStatus else {
            return
        }
        showsDeferredMatrixAnnotationStatus = false
        rebuildArtifactLens()
    }

    private func discardFirstDeferredMatrixAnnotationMutation() {
        deferredMatrixAnnotationMutationHead += 1
        guard deferredMatrixAnnotationMutationHead == deferredMatrixAnnotationMutations.count else {
            if deferredMatrixAnnotationMutationHead >= 32,
               deferredMatrixAnnotationMutationHead * 2 >= deferredMatrixAnnotationMutations.count {
                deferredMatrixAnnotationMutations.removeFirst(
                    deferredMatrixAnnotationMutationHead
                )
                deferredMatrixAnnotationMutationHead = 0
            }
            return
        }
        deferredMatrixAnnotationMutations.removeAll(keepingCapacity: true)
        deferredMatrixAnnotationMutationHead = 0
    }

    private func isWorkbookPublicationLockHeld(_ error: Error) -> Bool {
        var visitedNSErrorObjects: Set<ObjectIdentifier> = []
        return isWorkbookPublicationLockHeld(
            error,
            depth: 0,
            visitedNSErrorObjects: &visitedNSErrorObjects
        )
    }

    private func isWorkbookPublicationLockHeld(
        _ error: Error,
        depth: Int,
        visitedNSErrorObjects: inout Set<ObjectIdentifier>
    ) -> Bool {
        guard depth < 16 else { return false }
        if let recoveryError = error as? ONTGenotypeWorkbookUpdateRecoveryError,
           case .lockHeld = recoveryError {
            return true
        }
        if let transactionError = error as? GenotypeAnnotationPublicationTransactionError {
            return isWorkbookPublicationLockHeld(
                transactionError.primaryError,
                depth: depth + 1,
                visitedNSErrorObjects: &visitedNSErrorObjects
            )
        }
        let nsError = error as NSError
        guard visitedNSErrorObjects.insert(ObjectIdentifier(nsError)).inserted,
              let underlyingError = nsError.userInfo[NSUnderlyingErrorKey] as? Error else {
            return false
        }
        return isWorkbookPublicationLockHeld(
            underlyingError,
            depth: depth + 1,
            visitedNSErrorObjects: &visitedNSErrorObjects
        )
    }

    private func finishMatrixAnnotationPublication(
        store: GenotypeAnnotationStore,
        targets: [GenotypeAnnotationSidecar.MatrixTarget]
    ) {
        let searchDependenciesChanged = rebuildMatrixAnnotationIndexes()
        comparisonMatrix.applyAnnotationSidecar(store.sidecar, reloading: targets)
        if searchDependenciesChanged {
            refreshActiveSharedSearchAfterDependencyChange()
        }
        refreshCurrentSelectionDetails()
        publishMatrixReviewCapability(for: currentSelectionState?.matrixTargets ?? [])
        onAnnotationSidecarChanged?(store.sidecar)
        scheduleCurrentWorkbookUpdateForMatrixAnnotation()
    }

    private func refreshActiveSharedSearchAfterDependencyChange() {
        guard !activeSharedMatrixSearchText().isEmpty else { return }
        refreshVisibleFilterDependentViews()
    }

    private func handleMatrixAnnotationCommandFailure(
        _ error: Error,
        store: GenotypeAnnotationStore,
        sidecarBeforeAttempt: GenotypeAnnotationSidecar
    ) {
        if indexedMatrixMutationRevision != store.matrixMutationRevision {
            let changedTargets = matrixAnnotationChangedTargets(
                from: sidecarBeforeAttempt,
                to: store.sidecar
            )
            let candidateDisplayChanged =
                sidecarBeforeAttempt.settings.mhcCandidateDisplay
                    != store.sidecar.settings.mhcCandidateDisplay
            let searchDependenciesChanged = rebuildMatrixAnnotationIndexes()
            if candidateDisplayChanged {
                comparisonMatrix.applyAnnotationSidecar(store.sidecar, reload: false)
                var reconciledDisplayState = displayState
                reconciledDisplayState.mhcCandidateDisplaySettings =
                    store.sidecar.settings.mhcCandidateDisplay
                applyDisplayStateImmediately(reconciledDisplayState)
                onDisplayStateChanged?(reconciledDisplayState)
                refreshCandidateSelectionDetails()
            } else if changedTargets.isEmpty {
                comparisonMatrix.applyAnnotationSidecar(store.sidecar, reload: false)
            } else {
                comparisonMatrix.applyAnnotationSidecar(
                    store.sidecar,
                    reloading: changedTargets
                )
            }
            if searchDependenciesChanged {
                refreshActiveSharedSearchAfterDependencyChange()
            }
            refreshCurrentSelectionDetails()
            publishMatrixReviewCapability(for: currentSelectionState?.matrixTargets ?? [])
            onAnnotationSidecarChanged?(store.sidecar)
        }
        if let onMatrixAnnotationCommandError {
            onMatrixAnnotationCommandError(error)
        } else {
            presentSheetAlert(error: error)
        }
    }

    private func matrixAnnotationChangedTargets(
        from previous: GenotypeAnnotationSidecar,
        to latest: GenotypeAnnotationSidecar
    ) -> [GenotypeAnnotationSidecar.MatrixTarget] {
        let previousStyles = Dictionary(
            previous.matrixStyles.map { ($0.target, $0) },
            uniquingKeysWith: { _, latest in latest }
        )
        let latestStyles = Dictionary(
            latest.matrixStyles.map { ($0.target, $0) },
            uniquingKeysWith: { _, latest in latest }
        )
        let previousReviews = Dictionary(
            previous.matrixReviews.map { ($0.target, $0) },
            uniquingKeysWith: { _, latest in latest }
        )
        let latestReviews = Dictionary(
            latest.matrixReviews.map { ($0.target, $0) },
            uniquingKeysWith: { _, latest in latest }
        )
        var changedTargets = changedMatrixAnnotationTargets(
            previous: previousStyles,
            latest: latestStyles
        )
        changedTargets.formUnion(changedMatrixAnnotationTargets(
            previous: previousReviews,
            latest: latestReviews
        ))
        changedTargets.formUnion(changedMatrixAnnotationTargets(
            previous: previous.resolvedMatrixComments,
            latest: latest.resolvedMatrixComments
        ))
        return Array(changedTargets)
    }

    private func changedMatrixAnnotationTargets<Value: Equatable>(
        previous: [GenotypeAnnotationSidecar.MatrixTarget: Value],
        latest: [GenotypeAnnotationSidecar.MatrixTarget: Value]
    ) -> Set<GenotypeAnnotationSidecar.MatrixTarget> {
        let allTargets = Set(previous.keys).union(latest.keys)
        return Set(allTargets.filter { previous[$0] != latest[$0] })
    }

    public func selectSupportedMatrixCellsInCurrentRow(minimumReads: Int) {
        ensureComparisonMatrixConfigured()
        let targets = comparisonMatrix.selectSupportedCellsInSelectedRow(minimumReads: minimumReads)
        if isFullLengthMHCGenotypeViewport {
            showAlleleSequenceRows(for: [])
        }
        if targets.isEmpty {
            publishSelectionState(nil)
        } else if let currentSharedCall {
            publishSelectionState(selectionState(for: currentSharedCall, sample: nil, matrixTargets: targets))
        } else {
            publishSelectionState(matrixTargetSelectionState(for: targets))
        }
    }

    public func setMatrixSupportSelectionPreviewMinimumReads(_ minimumReads: Int) {
        ensureComparisonMatrixConfigured()
        comparisonMatrix.setSupportSelectionPreviewMinimumReads(minimumReads)
    }

    @discardableResult
    public func performMatrixVisibilityCommand(
        _ command: GenotypeMatrixVisibilityCommand
    ) -> Bool {
        ensureComparisonMatrixConfigured()
        switch command {
        case .hideSelectedRows:
            guard matrixVisibilityCapability.canHideSelectedRows else { return false }
            return comparisonMatrix.hideSelectedRows()
        case .showOnlySelectedRows:
            guard matrixVisibilityCapability.canShowOnlySelectedRows else { return false }
            return comparisonMatrix.showOnlySelectedRows()
        case .showAllRows:
            guard matrixVisibilityCapability.canShowAllRows else { return false }
            return comparisonMatrix.showAllRows()
        case .hideSelectedColumns:
            guard matrixVisibilityCapability.canHideSelectedColumns else { return false }
            return comparisonMatrix.hideSelectedColumns()
        case .showOnlySelectedColumns:
            guard matrixVisibilityCapability.canShowOnlySelectedColumns else { return false }
            return comparisonMatrix.showOnlySelectedColumns()
        case .showAllColumns:
            guard matrixVisibilityCapability.canShowAllColumns else { return false }
            return comparisonMatrix.showAllColumns()
        case .reset:
            guard matrixVisibilityCapability.canResetVisibility else { return false }
            return comparisonMatrix.resetVisibility()
        }
    }

    public func showOnlySelectedMatrixRows() {
        performMatrixVisibilityCommand(.showOnlySelectedRows)
    }

    public func hideSelectedMatrixRows() {
        performMatrixVisibilityCommand(.hideSelectedRows)
    }

    public func showAllMatrixRows() {
        performMatrixVisibilityCommand(.showAllRows)
    }

    public func showOnlySelectedMatrixColumns() {
        performMatrixVisibilityCommand(.showOnlySelectedColumns)
    }

    public func hideSelectedMatrixColumns() {
        performMatrixVisibilityCommand(.hideSelectedColumns)
    }

    public func showAllMatrixColumns() {
        performMatrixVisibilityCommand(.showAllColumns)
    }

    public func resetMatrixVisibility() {
        performMatrixVisibilityCommand(.reset)
    }

    public func clearMatrixSelectionFilter() {
        resetMatrixVisibility()
    }

    private func applyHighlightWithoutUndo(_ request: GenotypeResultHighlightRequest) {
        ensureComparisonMatrixConfigured()
        comparisonMatrix.applyHighlight(request)
        if let currentSharedCall {
            showSharedCall(
                currentSharedCall,
                sample: currentSelectedSample,
                matrixTargets: currentSelectionState?.matrixTargets
            )
        }
    }

    private func uniqueMatrixTargets(
        _ targets: [GenotypeAnnotationSidecar.MatrixTarget]
    ) -> [GenotypeAnnotationSidecar.MatrixTarget] {
        var seen: Set<GenotypeAnnotationSidecar.MatrixTarget> = []
        return targets.filter { seen.insert($0).inserted }
    }

    private func matrixStyleTargetsToClear(
        for selectedTargets: [GenotypeAnnotationSidecar.MatrixTarget],
        in sidecar: GenotypeAnnotationSidecar
    ) -> [GenotypeAnnotationSidecar.MatrixTarget] {
        let selectedTargets = uniqueMatrixTargets(selectedTargets)
        guard !selectedTargets.isEmpty else { return [] }
        return uniqueMatrixTargets(sidecar.matrixStyles.compactMap { annotation in
            selectedTargets.contains { selectionClearsMatrixStyleTarget(annotation.target, selectedBy: $0) }
                ? annotation.target
                : nil
        })
    }

    private func selectionClearsMatrixStyleTarget(
        _ styleTarget: GenotypeAnnotationSidecar.MatrixTarget,
        selectedBy selectedTarget: GenotypeAnnotationSidecar.MatrixTarget
    ) -> Bool {
        switch selectedTarget {
        case let .row(selectedLocus, selectedGenotype, selectedStableClusterID):
            switch styleTarget {
            case let .row(locus, genotype, stableClusterID),
                 let .cell(locus, genotype, _, stableClusterID):
                return matrixRowIdentityMatches(
                    locus: locus,
                    genotype: genotype,
                    stableClusterID: stableClusterID,
                    selectedLocus: selectedLocus,
                    selectedGenotype: selectedGenotype,
                    selectedStableClusterID: selectedStableClusterID
                )
            case .column:
                return false
            }
        case let .column(selectedSample):
            switch styleTarget {
            case let .column(sample), let .cell(_, _, sample, _):
                return sample == selectedSample
            case .row:
                return false
            }
        case let .cell(selectedLocus, selectedGenotype, selectedSample, selectedStableClusterID):
            guard case let .cell(locus, genotype, sample, stableClusterID) = styleTarget else { return false }
            return sample == selectedSample && matrixRowIdentityMatches(
                locus: locus,
                genotype: genotype,
                stableClusterID: stableClusterID,
                selectedLocus: selectedLocus,
                selectedGenotype: selectedGenotype,
                selectedStableClusterID: selectedStableClusterID
            )
        }
    }

    private func matrixRowIdentityMatches(
        locus: String,
        genotype: String,
        stableClusterID: String?,
        selectedLocus: String,
        selectedGenotype: String,
        selectedStableClusterID: String?
    ) -> Bool {
        guard locus == selectedLocus, genotype == selectedGenotype else { return false }
        guard let selectedStableClusterID else { return true }
        return stableClusterID == selectedStableClusterID
    }

    private func matrixStyle(
        for target: GenotypeAnnotationSidecar.MatrixTarget,
        in sidecar: GenotypeAnnotationSidecar
    ) -> GenotypeAnnotationSidecar.MatrixStyle {
        sidecar.matrixStyles.first { $0.target == target }?.style
            ?? GenotypeAnnotationSidecar.MatrixStyle(
                fillColor: nil,
                textColor: nil,
                borderColor: nil,
                isBold: false,
                isItalic: false,
                boldOverride: nil,
                italicOverride: nil
            )
    }

    private func matrixStyle(
        _ style: GenotypeAnnotationSidecar.MatrixStyle,
        applying field: GenotypeMatrixStyleField
    ) -> GenotypeAnnotationSidecar.MatrixStyle? {
        var style = style
        switch field {
        case .fillColor(let color):
            style.fillColor = color?.hexString
        case .textColor(let color):
            style.textColor = color?.hexString
        case .borderColor(let color):
            style.borderColor = color?.hexString
        case .isBold(let enabled):
            style.isBold = enabled
            style.boldOverride = enabled
        case .isItalic(let enabled):
            style.isItalic = enabled
            style.italicOverride = enabled
        case .clear:
            return nil
        }
        return style.isEmpty ? nil : style
    }

    private func matrixStyle(
        _ style: GenotypeAnnotationSidecar.MatrixStyle,
        removing field: GenotypeMatrixStyleField
    ) -> GenotypeAnnotationSidecar.MatrixStyle? {
        var style = style
        switch field {
        case .fillColor:
            style.fillColor = nil
        case .textColor:
            style.textColor = nil
        case .borderColor:
            style.borderColor = nil
        case .isBold:
            style.isBold = false
            style.boldOverride = nil
        case .isItalic:
            style.isItalic = false
            style.italicOverride = nil
        case .clear:
            return nil
        }
        return style.isEmpty ? nil : style
    }

    private func refreshCurrentSelectionDetails() {
        guard !hasUnsavedManualHaplotypeDraft else {
            return
        }
        if let currentSharedCall {
            showSharedCall(
                currentSharedCall,
                sample: currentSelectedSample,
                matrixTargets: currentSelectionState?.matrixTargets
            )
        } else if let currentCandidateRow {
            showCandidateRow(
                currentCandidateRow,
                sample: currentSelectedSample,
                matrixTargets: currentSelectionState?.matrixTargets ?? []
            )
        } else if let targets = currentSelectionState?.matrixTargets, !targets.isEmpty {
            showMatrixTargetSelection(targets)
        } else {
            publishSelectionState(nil)
        }
    }

    private func configureLensControl() {
        lensControl.translatesAutoresizingMaskIntoConstraints = false
        lensControl.target = self
        lensControl.action = #selector(lensChanged(_:))
        lensControl.selectedSegment = segmentIndex(for: .summary)
        lensControl.setAccessibilityIdentifier("genotype-result-lens-control")
    }

    private func configureAvailableLensSegments() {
        guard isViewLoaded else { return }
        let lenses = availableLenses
        lensControl.segmentCount = lenses.count
        for (index, lens) in lenses.enumerated() {
            lensControl.setLabel(lens.displayName, forSegment: index)
        }
        lensControl.controlSize = isGenotypeOnlyResult ? .small : .regular
        lensControl.selectedSegment = segmentIndex(for: selectedLens)
        lensControl.invalidateIntrinsicContentSize()
    }

    private func configureContentHost() {
        contentHost.translatesAutoresizingMaskIntoConstraints = false
        contentHost.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        contentHost.setContentHuggingPriority(.defaultLow, for: .horizontal)
    }

    private func configureSplitView() {
        splitView.translatesAutoresizingMaskIntoConstraints = false
        splitView.isVertical = true
        splitView.dividerStyle = .thin
        splitView.delegate = self
        splitView.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        splitView.setContentHuggingPriority(.defaultLow, for: .horizontal)

        sampleContainer.translatesAutoresizingMaskIntoConstraints = false
        detailContainer.translatesAutoresizingMaskIntoConstraints = false
        sampleContainer.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        detailContainer.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        sampleContainer.addSubview(quickFilterBar)
        sampleContainer.addSubview(comparisonMatrix)
        sampleContainer.addSubview(outlineView)
        sampleContainer.addSubview(haplotypeMatrixView)
        outlineView.isHidden = true
        haplotypeMatrixView.isHidden = true
        outlineView.onRowSelected = { [weak self] animalId in
            self?.handleOutlineRowSelected(animalId)
        }
        outlineView.onLocusCellClicked = { [weak self] animalId, locus in
            self?.selectCellEvidence(animalId: animalId, locus: locus)
        }
        quickFilterBar.onStateChanged = { [weak self] state in
            self?.applyQuickFilterState(state)
        }
        quickFilterBar.onSavedCohortCleared = { [weak self] in
            self?.clearActiveSmartCohort()
        }

        splitView.addArrangedSubview(sampleContainer)
        splitView.addArrangedSubview(detailContainer)
        splitView.setHoldingPriority(.defaultLow, forSubviewAt: 0)
        splitView.setHoldingPriority(.defaultLow, forSubviewAt: 1)

        NSLayoutConstraint.activate([
            quickFilterBar.topAnchor.constraint(equalTo: sampleContainer.topAnchor),
            quickFilterBar.leadingAnchor.constraint(equalTo: sampleContainer.leadingAnchor),
            quickFilterBar.trailingAnchor.constraint(equalTo: sampleContainer.trailingAnchor),
            comparisonMatrix.topAnchor.constraint(equalTo: quickFilterBar.bottomAnchor),
            comparisonMatrix.leadingAnchor.constraint(equalTo: sampleContainer.leadingAnchor),
            comparisonMatrix.trailingAnchor.constraint(equalTo: sampleContainer.trailingAnchor),
            comparisonMatrix.bottomAnchor.constraint(equalTo: sampleContainer.bottomAnchor),
            outlineView.topAnchor.constraint(equalTo: quickFilterBar.bottomAnchor),
            outlineView.leadingAnchor.constraint(equalTo: sampleContainer.leadingAnchor),
            outlineView.trailingAnchor.constraint(equalTo: sampleContainer.trailingAnchor),
            outlineView.bottomAnchor.constraint(equalTo: sampleContainer.bottomAnchor),
            haplotypeMatrixView.topAnchor.constraint(equalTo: quickFilterBar.bottomAnchor),
            haplotypeMatrixView.leadingAnchor.constraint(equalTo: sampleContainer.leadingAnchor),
            haplotypeMatrixView.trailingAnchor.constraint(equalTo: sampleContainer.trailingAnchor),
            haplotypeMatrixView.bottomAnchor.constraint(equalTo: sampleContainer.bottomAnchor),
        ])
    }

    private func configureDetailPane() {
        detailScrollView.translatesAutoresizingMaskIntoConstraints = false
        detailScrollView.hasVerticalScroller = true
        detailScrollView.hasHorizontalScroller = false
        detailScrollView.autohidesScrollers = true
        detailScrollView.borderType = .noBorder
        detailScrollView.drawsBackground = false
        detailDocumentView.translatesAutoresizingMaskIntoConstraints = false
        detailScrollView.documentView = detailDocumentView
        detailScrollView.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        detailContainer.addSubview(detailScrollView)
        detailContainer.addSubview(cohortSummaryPanel)
        cohortSummaryPanel.isHidden = true

        detailStack.translatesAutoresizingMaskIntoConstraints = false
        detailStack.orientation = .vertical
        detailStack.alignment = .width
        detailStack.spacing = 8
        detailStack.edgeInsets = NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0)
        detailStack.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        detailDocumentView.addSubview(detailStack)

        NSLayoutConstraint.activate([
            detailScrollView.topAnchor.constraint(equalTo: detailContainer.topAnchor),
            detailScrollView.leadingAnchor.constraint(equalTo: detailContainer.leadingAnchor),
            detailScrollView.trailingAnchor.constraint(equalTo: detailContainer.trailingAnchor),
            detailScrollView.bottomAnchor.constraint(equalTo: detailContainer.bottomAnchor),
            detailDocumentView.widthAnchor.constraint(equalTo: detailScrollView.contentView.widthAnchor),
            detailDocumentView.heightAnchor.constraint(greaterThanOrEqualTo: detailScrollView.contentView.heightAnchor),
            detailStack.topAnchor.constraint(equalTo: detailDocumentView.topAnchor, constant: 8),
            detailStack.leadingAnchor.constraint(equalTo: detailDocumentView.leadingAnchor, constant: 10),
            detailStack.trailingAnchor.constraint(equalTo: detailDocumentView.trailingAnchor, constant: -10),
            detailStack.bottomAnchor.constraint(lessThanOrEqualTo: detailDocumentView.bottomAnchor, constant: -8),
            cohortSummaryPanel.topAnchor.constraint(equalTo: detailContainer.topAnchor),
            cohortSummaryPanel.leadingAnchor.constraint(equalTo: detailContainer.leadingAnchor),
            cohortSummaryPanel.trailingAnchor.constraint(equalTo: detailContainer.trailingAnchor),
            cohortSummaryPanel.bottomAnchor.constraint(equalTo: detailContainer.bottomAnchor),
        ])
        detailContentTypographyObservation = makeGeneratedContentTypographyObservation(
            root: detailStack,
            scrollView: detailScrollView
        )
    }

    private func configureScrollLens(_ scrollView: NSScrollView, stack: NSStackView, identifier: String) {
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false
        scrollView.documentView = stack
        scrollView.setAccessibilityIdentifier(identifier)
        scrollView.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.orientation = .vertical
        // .leading keeps section titles at the left margin rather than
        // stretching across the lens width. Each section uses width
        // anchors on its own subviews to fill the lens when needed.
        stack.alignment = .leading
        stack.spacing = 14
        stack.edgeInsets = NSEdgeInsets(top: 14, left: 16, bottom: 16, right: 16)
        stack.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        stack.widthAnchor.constraint(equalTo: scrollView.contentView.widthAnchor).isActive = true
        lensContentTypographyObservations[ObjectIdentifier(stack)] =
            makeGeneratedContentTypographyObservation(root: stack, scrollView: scrollView)
    }

    private func makeGeneratedContentTypographyObservation(
        root: NSView,
        scrollView: NSScrollView
    ) -> ContentTypographyViewObservation {
        var preservedOrigin = NSPoint.zero
        return ContentTypographyViewObservation(
            applicator: ContentTypographyViewApplicator(excludedSubtree: { [weak self] view in
                self?.isGeneratedContentTypographyExcludedSubtree(view) ?? true
            }),
            rootProvider: { root },
            beforeApply: {
                preservedOrigin = scrollView.contentView.bounds.origin
            },
            afterApply: { [weak self, weak root, weak scrollView] in
                guard let self, let root, let scrollView else { return }
                self.finishGeneratedContentTypographyUpdate(in: root)
                if root === self.detailStack {
                    self.sampleCurationWorkbench?
                        .updateContentTypographyScale(
                            self.currentContentTypographyScale()
                        )
                    self.sampleCurationWorkbench?
                        .layoutSubtreeIfNeeded()
                }
                root.layoutSubtreeIfNeeded()
                scrollView.contentView.setBoundsOrigin(preservedOrigin)
                scrollView.reflectScrolledClipView(scrollView.contentView)
            }
        )
    }

    private func finishGeneratedContentTypographyUpdate(in root: NSView) {
        for field in generatedDetailTextFields(in: root) {
            field.maximumNumberOfLines = 0
            field.lineBreakMode = .byWordWrapping
            field.usesSingleLineMode = false
            if !field.stringValue.isEmpty {
                field.toolTip = field.stringValue
                field.setAccessibilityValue(field.stringValue)
            }
        }
        root.needsLayout = true
    }

    private func generatedDetailTextFields(in root: NSView) -> [NSTextField] {
        root.subviews.flatMap { subview -> [NSTextField] in
            guard !isGeneratedContentTypographyExcludedSubtree(subview) else { return [] }
            let field = (subview as? NSTextField).map { [$0] } ?? []
            return field + generatedDetailTextFields(in: subview)
        }
    }

    private func isGeneratedContentTypographyExcludedSubtree(_ view: NSView) -> Bool {
        view is NSButton
            || view is NSSegmentedControl
            || view is NSPopUpButton
            || view is NSSlider
            || view === knownAlleleDetailView
            || view === candidateAlleleDetailView
            || view === alleleSequenceDetailView
            || view.identifier == Self.generatedContentHostingViewIdentifier
    }

    private func refreshGeneratedContentTypography(in stack: NSStackView) {
        lensContentTypographyObservations[ObjectIdentifier(stack)]?.refresh()
    }

    private func layout() {
        view.addSubview(lensControl)
        view.addSubview(contentHost)

        contentHostTopConstraint = contentHost.topAnchor.constraint(
            equalTo: view.safeAreaLayoutGuide.topAnchor,
            constant: viewportHeaderHeight
        )
        lensControl.isHidden = false

        NSLayoutConstraint.activate([
            lensControl.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -12),
            lensControl.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 8),

            contentHostTopConstraint,
            contentHost.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            contentHost.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            contentHost.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
    }

    private func applyViewportHeaderVisibility() {
        guard isViewLoaded else { return }
        lensControl.isHidden = false
        contentHostTopConstraint.constant = viewportHeaderHeight
    }

    private func wireCallbacks() {
        comparisonMatrix.onSharedCallSelected = { [weak self] sharedCall, sample, matrixTargets in
            guard let self else { return }
            self.knownSelectionCallbackCount += 1
            if matrixTargets.count > 1 {
                self.showMatrixTargetSelection(matrixTargets)
            } else {
                self.showSharedCall(sharedCall, sample: sample, matrixTargets: matrixTargets)
            }
        }
        comparisonMatrix.onCandidateRowSelected = { [weak self] row, sample, matrixTargets in
            self?.candidateSelectionCallbackCount += 1
            self?.showCandidateRow(row, sample: sample, matrixTargets: matrixTargets)
        }
        comparisonMatrix.onMatrixTargetsSelected = { [weak self] targets in
            self?.showMatrixTargetSelection(targets)
        }
        comparisonMatrix.onMatrixReviewRequested = { [weak self] request in
            self?.applyMatrixReview(request)
        }
        comparisonMatrix.onMatrixCommentEditRequested = { [weak self] request in
            self?.editMatrixComment(request)
        }
        comparisonMatrix.onSelectionCleared = { [weak self] in
            self?.showEmptySelection()
        }
        comparisonMatrix.onDisplaySummaryChanged = { [weak self] visibleRows, totalRows, hiddenCells in
            self?.onDisplaySummaryChanged?(visibleRows, totalRows, hiddenCells)
        }
        comparisonMatrix.onSearchProjectionChanged = { [weak self] in
            guard let self else { return }
            self.invalidateGenotypeSearchIndex()
            self.refreshVisibleFilterDependentViews()
        }
        comparisonMatrix.onMatrixVisibilityCapabilityChanged = { [weak self] capability in
            guard let self else { return }
            self.matrixVisibilityCapability = capability
            self.onMatrixVisibilityCapabilityChanged?(capability)
        }
        comparisonMatrix.onManualHaplotypeTransitionPreflight = {
            [weak self] transition, mutation in
            guard let self else {
                return false
            }
            return self.deferManualHaplotypeTransition(
                transition,
                mutation: mutation
            )
        }
        comparisonMatrix.onManualHaplotypeEditRequested = {
            [weak self] sample in
            self?.focusManualHaplotypeEditor(sample: sample)
        }
        comparisonMatrix.onManualHaplotypeBandExpansionChanged = {
            [weak self] expanded in
            guard let self else { return }
            self.displayState.manualHaplotypeBandExpanded = expanded
            if let bundleURL = self.result?.bundleURL {
                self.manualHaplotypeBandDisclosureStore?
                    .setExpansion(expanded, for: bundleURL)
            }
            self.onDisplayStateChanged?(self.displayState)
        }
    }

    @objc private func lensChanged(_ sender: NSSegmentedControl) {
        guard sender.selectedSegment >= 0,
              sender.selectedSegment < availableLenses.count else { return }
        let lens = availableLenses[sender.selectedSegment]
        if requiresManualHaplotypeTransitionCoordination {
            sender.selectedSegment = segmentIndex(for: selectedLens)
            deferManualHaplotypeTransition(.lens) { [weak self] in
                guard let self else { return }
                self.showLens(lens)
                self.onDisplayStateChanged?(self.displayState)
            }
            return
        }
        showLens(lens)
        onDisplayStateChanged?(displayState)
    }

    private func showLens(_ lens: Lens, autoActivateReviewCohort: Bool = true) {
        if requiresManualHaplotypeTransitionCoordination {
            deferManualHaplotypeTransition(.lens) { [weak self] in
                self?.showLens(
                    lens,
                    autoActivateReviewCohort:
                        autoActivateReviewCohort
                )
            }
            return
        }
        displayState = displayState.normalized(forGenotypeOnlyResult: isGenotypeOnlyResult)
        let lens: Lens = availableLenses.contains(lens) ? lens : .summary
        selectedLens = lens
        displayState.viewportLens = lens
        lensControl.selectedSegment = segmentIndex(for: lens)
        switch lens {
        case .summary:
            installContentView(splitView)
            applySummaryViewModeVisibility()
            scheduleInitialSplitValidationIfNeeded()
            applyLayoutPreference()
        case .review:
            rebuildHaplotypeLens()
            installContentView(splitView)
            applyReviewLensVisibility(autoActivateNeedsReview: autoActivateReviewCohort)
            scheduleInitialSplitValidationIfNeeded()
            applyLayoutPreference()
        case .audit:
            rebuildArtifactLens()
            installContentView(artifactScrollView)
        }
        lensContentTypographyObservations.values.forEach { $0.refresh() }
    }

    private func applyReviewLensVisibility(autoActivateNeedsReview: Bool = true) {
        outlineView.isHidden = false
        comparisonMatrix.isHidden = true
        cohortSummaryPanel.isHidden = true
        detailScrollView.isHidden = true
        if callEvidenceHost == nil {
            installCallEvidenceHost()
        }
        callEvidenceHost?.isHidden = false
        // The Review lens is meant to walk the Needs Review queue, not
        // show every sample. Use the same built-in smart cohort shown in
        // the inspector so low-support and analyst-flagged samples are
        // included alongside hard errors.
        if autoActivateNeedsReview
            && quickFilterPredicate == nil
            && activeSmartCohort == nil
            && quickFilterSearchText.isEmpty {
            activateNeedsReviewCohort()
        }
        updateCallEvidence()
        // Force the divider closer to 50/50 so the evidence panel has
        // room — Summary leaves the bottom narrow because the cohort
        // summary contents are small, but Review's evidence has more
        // content (diagnostic alleles, candidate haplotypes, neighbors)
        // and needs more vertical space.
        if displayState.layout == .listTop {
            splitCoordinator.invalidateInitialSplitPosition()
            scheduleInitialSplitValidationIfNeeded()
        }
    }

    private func activateNeedsReviewCohort() {
        guard hasHaplotypingResult else { return }
        let cohort = annotationStore?.sidecar.smartCohorts.first {
            $0.name == "Needs review" && $0.scope == "bundle"
        } ?? GenotypeCohortSmartFilter(
            name: "Needs review",
            description: "Errors, low support, or analyst-flagged samples.",
            scope: "bundle",
            isStarred: true,
            predicate: .any([
                .hasErrorAtAnyLocus,
                .qcStatus([.review, .lowSupport]),
                .hasAnalystFlag(.needsReview),
            ])
        )
        activeSmartCohort = cohort
        quickFilterBar.setSavedCohortName(cohort.name)
        rebuildOutline()
        rebuildHaplotypeMatrix()
        applyComparisonMatrixCohortFilter()
    }

    private func installCallEvidenceHost() {
        let evidence = callEvidence
        let host = NSHostingView(rootView: makeCallEvidenceView(evidence: evidence))
        host.translatesAutoresizingMaskIntoConstraints = false
        host.isHidden = evidence == nil
        detailContainer.addSubview(host)
        NSLayoutConstraint.activate([
            host.topAnchor.constraint(equalTo: detailContainer.topAnchor),
            host.leadingAnchor.constraint(equalTo: detailContainer.leadingAnchor),
            host.trailingAnchor.constraint(equalTo: detailContainer.trailingAnchor),
            host.bottomAnchor.constraint(equalTo: detailContainer.bottomAnchor),
        ])
        callEvidenceHost = host
    }

    private func updateCallEvidence() {
        guard let host = callEvidenceHost else {
            syncOutlineReviewSelection()
            return
        }
        let evidence = callEvidence
        host.rootView = makeCallEvidenceView(evidence: evidence)
        host.isHidden = evidence == nil
        detailContainer.isHidden = selectedLens == .review && evidence == nil
        syncOutlineReviewSelection()
    }

    private func makeCallEvidenceView(evidence: GenotypeCallEvidenceView.Evidence?) -> GenotypeCallEvidenceView {
        var view = GenotypeCallEvidenceView(evidence: evidence)
        view.onOverrideRequested = { [weak self] haplotypeName, slot in
            self?.applyOverrideFromInspector(haplotype: haplotypeName, slot: slot)
        }
        view.onOverridesRequested = { [weak self] requests in
            self?.applyOverridesFromInspector(requests)
        }
        view.onConfirmRequested = { [weak self] in
            self?.confirmCurrentCallEvidence()
        }
        view.onSkipRequested = { [weak self] in
            self?.skipToNextReviewSample()
        }
        return view
    }

    private func syncOutlineReviewSelection() {
        guard let sample = currentSelectedSample else {
            outlineView.setReviewSelection(sample: nil, locus: nil)
            return
        }
        let selectedLocus = currentSelectedLocus ?? callEvidence(sample: sample, locus: nil)?.locus
        outlineView.setReviewSelection(sample: sample, locus: selectedLocus)
    }

    /// Computes a `GenotypeCallEvidenceView.Evidence` for the currently
    /// selected sample's first non-OK call (or first call if none flagged).
    /// Returns nil when no sample is selected or the bundle has no analysis.
    private var callEvidence: GenotypeCallEvidenceView.Evidence? {
        guard let sampleId = currentSelectedSample else { return nil }
        return callEvidence(sample: sampleId, locus: currentSelectedLocus)
    }

    /// Build an Evidence struct for an arbitrary (sample, locus). When
    /// `locus` is nil the first error call (or first call) is chosen;
    /// otherwise the named locus call is used. Returns nil when the
    /// bundle has no analysis or the sample is unknown.
    func callEvidence(sample sampleId: String, locus: String?) -> GenotypeCallEvidenceView.Evidence? {
        guard let result, let analysis = activeHaplotypeAnalysis() else { return nil }
        guard let sampleAnalysis = activeHaplotypeSamplesByName[sampleId]
            ?? analysis.samples.first(where: { $0.sample == sampleId }) else {
            return nil
        }
        let locusCall: GenotypeHaplotypeLocusCall? = {
            if let locus, let named = sampleAnalysis.calls.first(where: { $0.locus == locus }) {
                return named
            }
            return sampleAnalysis.calls.first {
                !isCallReviewResolved(sample: sampleId, locus: $0.locus)
                    && $0.status != .called
                    && $0.status != .notAssayed
                    && $0.status != .specialCase
            } ?? sampleAnalysis.calls.first {
                !isCallReviewResolved(sample: sampleId, locus: $0.locus)
            }
        }()
        guard let locusCall else { return nil }
        // Pull per-allele read counts using the same locus/diagnostic
        // resolver as the analyzer. MCM class-I definitions intentionally
        // use F/G/AG/E/70 support, while class-II raw calls carry DQA1/DPA1
        // suffixes; broad string contains checks are not reliable here.
        let sampleCalls = callsBySample[sampleId] ?? result.calls.filter { $0.sample == sampleId }
        let sampleResult = sampleResultsByName[sampleId] ?? result.samples.first { $0.sample == sampleId }
        let sampleCallIndex = callIndexBySample[sampleId] ?? callIndex(for: sampleCalls)
        let locusDefinition = definitionSetForResult(result)?.locusDefinitions.first { $0.locus == locusCall.locus }
        let locusCalls = sampleCalls.filter { call in
            if let locusDefinition {
                return GenotypeHaplotypeLocusResolver.diagnosticCall(call, belongsTo: locusDefinition)
            }
            let group = GenotypeHaplotypeLocusResolver.canonicalLocusName(call.locusGroup)
            return group == locusCall.locus
                || group == GenotypeHaplotypeLocusResolver.canonicalLocusName(locusCall.sourceLocus)
        }
        let locusTotal = locusCalls.reduce(0) { $0 + max(0, $1.passedUniqueReads) }
        let sampleTotal = sampleCalls.reduce(0) { $0 + max(0, $1.passedUniqueReads) }
        let observedSet = Set(locusCall.observedGenotypes)
        let runEvaluator = runHaplotypeDropoutEvaluator()
        let evaluator = runEvaluator ?? GenotypeDropoutEvaluator(
            absolute: nil,
            sampleFraction: nil,
            locusFraction: nil
        )
        let omittedGenotypes = omittedHaplotypeGenotypes(
            from: locusCalls,
            locusDefinition: locusDefinition,
            observedSet: observedSet,
            sampleTotal: sampleTotal,
            locusTotal: locusTotal,
            locus: locusCall.locus,
            evaluator: runEvaluator
        )
        let observedIdentifiers = Set(locusCall.observedGenotypes.map(Self.genotypeIdentifier))
        let matchedDiagnosticIdentifiers = Set(
            locusCall.matchedHaplotypes.flatMap(\.diagnosticAlleles).map(Self.genotypeIdentifier)
        )
        let diagnostic = locusCalls
            .filter { (call: ONTGenotypeCall) -> Bool in
                let identifier = Self.genotypeIdentifier(call.genotype)
                if observedIdentifiers.contains(identifier) || observedSet.contains(call.genotype) { return true }
                if matchedDiagnosticIdentifiers.contains(identifier) { return true }
                if Self.isExactMiSeqIdentifier(identifier) { return false }
                for matched in locusCall.matchedHaplotypes {
                    if matched.diagnosticAlleles.contains(where: {
                        GenotypeHaplotypeDiagnosticMatcher.matches(
                            genotype: call.genotype,
                            diagnosticAllele: $0
                        )
                    }) { return true }
                }
                return false
            }
            .sorted { $0.passedUniqueReads > $1.passedUniqueReads }
            .prefix(8)
            .map { call -> GenotypeCallEvidenceView.DiagnosticAllele in
                let pct = locusTotal > 0 ? Double(call.passedUniqueReads) / Double(locusTotal) : 0
                let isLow = evaluator.isLowSupport(
                    reads: call.passedUniqueReads,
                    sampleTotal: sampleTotal,
                    locusTotal: locusTotal,
                    locus: locusCall.locus
                )
                return GenotypeCallEvidenceView.DiagnosticAllele(
                    allele: call.genotype,
                    reads: call.passedUniqueReads,
                    percentOfLocus: pct,
                    isLowSupport: isLow
                )
            }
        let effectiveCall = effectiveHaplotypeCall(sample: sampleId, call: locusCall)
        let displayedH1 = effectiveCall.h1
        let displayedH2 = effectiveCall.h2
        let displayedCall = diploidDisplayName(h1: displayedH1, h2: displayedH2)
        let isResolved = isCallReviewResolved(sample: sampleId, locus: locusCall.locus)
        let explanation = !isResolved && (effectiveCall.status == .notAssayed
            || (haplotypeStatusNeedsReview(
                effectiveCall.status,
                observedGenotypeCount: locusCall.observedGenotypeCount
            ) && effectiveCall.status != .called))
            ? errorExplanation(for: locusCall, observed: observedSet)
            : ""
        // Candidate rows must use the same post-dropout observed set as the
        // live haplotype call. Using raw locus calls here made the evidence
        // pane claim "all alleles observed" for haplotypes that had actually
        // been filtered below threshold.
        let observedAllelesForCandidates = Set(locusCall.observedGenotypes)
        let candidates = candidateHaplotypes(
            for: locusCall,
            observedAlleles: observedAllelesForCandidates,
            sampleCalls: sampleCalls,
            sampleCallIndex: sampleCallIndex
        )
        let availableHaplotypeNames = availableHaplotypeNames(for: locusDefinition)
        let perHaplotype = perHaplotypeSupport(
            for: locusCall,
            sampleCalls: sampleCalls,
            sampleCallIndex: sampleCallIndex,
            locusDefinition: locusDefinition,
            locusTotal: locusTotal,
            evaluator: evaluator
        )
        let animalGenotypes = cachedAnimalGenotypes(
            sampleId: sampleId,
            for: sampleCalls,
            sampleAnalysis: sampleAnalysis
        )
        return GenotypeCallEvidenceView.Evidence(
            sample: sampleId,
            locus: locusCall.locus,
            slot: .h1,
            callName: displayedCall,
            status: effectiveCall.status,
            observedGenotypeCount: locusCall.observedGenotypeCount,
            observedGenotypes: locusCall.observedGenotypes,
            diagnosticAlleles: Array(diagnostic),
            omittedHaplotypeGenotypes: omittedGenotypes,
            sampleTotalReads: sampleResult?.sampleTotalReads,
            sampleFullLengthReads: sampleResult?.passedUniqueReads,
            sampleAssignedGenotypeReads: sampleCalls.reduce(0) { $0 + max(0, $1.passedUniqueReads) },
            locusReadTotal: locusTotal,
            neighborsBefore: [],
            neighborsAfter: [],
            errorExplanation: explanation,
            candidateHaplotypes: candidates,
            animalGenotypes: animalGenotypes,
            h1Name: displayedH1,
            h2Name: displayedH2,
            perHaplotypeSupport: perHaplotype,
            availableHaplotypeNames: availableHaplotypeNames
        )
    }

    private func availableHaplotypeNames(
        for locusDefinition: GenotypeHaplotypeLocusDefinition?
    ) -> [String] {
        var seen = Set<String>()
        return locusDefinition?.haplotypes.compactMap { haplotype in
            let name = haplotype.name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty, seen.insert(name).inserted else { return nil }
            return name
        } ?? []
    }

    private func omittedHaplotypeGenotypes(
        from locusCalls: [ONTGenotypeCall],
        locusDefinition: GenotypeHaplotypeLocusDefinition?,
        observedSet: Set<String>,
        sampleTotal: Int,
        locusTotal: Int,
        locus: String,
        evaluator: GenotypeDropoutEvaluator?
    ) -> [GenotypeCallEvidenceView.OmittedHaplotypeGenotype] {
        guard let evaluator, let locusDefinition else { return [] }
        return locusCalls
            .filter { call in
                !observedSet.contains(call.genotype)
                    && isDiagnosticGenotype(call.genotype, in: locusDefinition)
                    && evaluator.isLowSupport(
                        reads: call.passedUniqueReads,
                        sampleTotal: sampleTotal,
                        locusTotal: locusTotal,
                        locus: locus
                    )
            }
            .sorted {
                if $0.passedUniqueReads != $1.passedUniqueReads {
                    return $0.passedUniqueReads > $1.passedUniqueReads
                }
                return $0.genotype < $1.genotype
            }
            .map { call in
                GenotypeCallEvidenceView.OmittedHaplotypeGenotype(
                    genotype: call.genotype,
                    reads: call.passedUniqueReads,
                    percentOfLocus: locusTotal > 0 ? Double(call.passedUniqueReads) / Double(locusTotal) : 0,
                    reason: haplotypeOmissionReason(
                        reads: call.passedUniqueReads,
                        sampleTotal: sampleTotal,
                        locusTotal: locusTotal,
                        locus: locus,
                        evaluator: evaluator
                    )
                )
            }
    }

    private func isDiagnosticGenotype(
        _ genotype: String,
        in locusDefinition: GenotypeHaplotypeLocusDefinition
    ) -> Bool {
        locusDefinition.haplotypes.contains { haplotype in
            haplotype.diagnosticAlleles.contains {
                GenotypeHaplotypeDiagnosticMatcher.matches(
                    genotype: genotype,
                    diagnosticAllele: $0
                )
            }
        }
    }

    private func haplotypeOmissionReason(
        reads: Int,
        sampleTotal: Int,
        locusTotal: Int,
        locus: String,
        evaluator: GenotypeDropoutEvaluator
    ) -> String {
        if let absolute = evaluator.absolute, reads < absolute {
            return "below read minimum \(absolute)"
        }
        if let sampleFraction = evaluator.sampleFraction, sampleTotal > 0 {
            let sampleSupport = Double(reads) / Double(sampleTotal)
            if sampleSupport < sampleFraction {
                return "below sample threshold \(Self.percentLabel(sampleFraction))"
            }
        }
        if let locusFraction = evaluator.effectiveLocusFraction(forLocus: locus), locusTotal > 0 {
            let locusSupport = Double(reads) / Double(locusTotal)
            if locusSupport < locusFraction {
                return "below locus threshold \(Self.percentLabel(locusFraction))"
            }
        }
        return "below haplotype threshold"
    }

    private static func percentLabel(_ fraction: Double) -> String {
        let percent = fraction * 100
        if abs(percent.rounded() - percent) < 0.000_001 {
            return String(format: "%.0f%%", percent)
        }
        return String(format: "%.1f%%", percent)
    }

    /// Build a per-haplotype supporting-allele table for the inspector. For
    /// each matched haplotype, lists every diagnostic allele observed in
    /// the sample with read count and % of locus reads. Empty for error
    /// calls because the matched-haplotypes list itself is empty.
    private func perHaplotypeSupport(
        for locusCall: GenotypeHaplotypeLocusCall,
        sampleCalls: [ONTGenotypeCall],
        sampleCallIndex: CallIndex,
        locusDefinition: GenotypeHaplotypeLocusDefinition?,
        locusTotal: Int,
        evaluator: GenotypeDropoutEvaluator
    ) -> [GenotypeCallEvidenceView.PerHaplotypeSupport] {
        guard !locusCall.matchedHaplotypes.isEmpty else { return [] }
        let sampleTotal = sampleCalls.reduce(0) { $0 + max(0, $1.passedUniqueReads) }
        return locusCall.matchedHaplotypes.map { matched in
            let alleles = matched.observedDiagnosticAlleles.map { allele -> GenotypeCallEvidenceView.DiagnosticAllele in
                let identifier = Self.genotypeIdentifier(allele)
                let reads = sampleCallIndex.readsByIdentifier[identifier] ?? diagnosticReads(
                    for: allele,
                    in: sampleCalls,
                    locusDefinition: locusDefinition
                )
                let pct = locusTotal > 0 ? Double(reads) / Double(locusTotal) : 0
                let isLow = evaluator.isLowSupport(
                    reads: reads,
                    sampleTotal: sampleTotal,
                    locusTotal: locusTotal,
                    locus: locusCall.locus
                )
                return GenotypeCallEvidenceView.DiagnosticAllele(
                    allele: sampleCallIndex.displayGenotypeByIdentifier[identifier] ?? diagnosticDisplayGenotype(
                        for: allele,
                        in: sampleCalls,
                        locusDefinition: locusDefinition
                    ) ?? allele,
                    reads: reads,
                    percentOfLocus: pct,
                    isLowSupport: isLow
                )
            }
            return GenotypeCallEvidenceView.PerHaplotypeSupport(
                haplotypeName: matched.name,
                supportingAlleles: alleles
            )
        }
    }

    private func cachedAnimalGenotypes(
        sampleId: String,
        for sampleCalls: [ONTGenotypeCall],
        sampleAnalysis: GenotypeHaplotypeSampleAnalysis
    ) -> [GenotypeCallEvidenceView.AnimalGenotype] {
        if let cached = animalGenotypesBySample[sampleId] {
            return cached
        }
        let rows = animalGenotypes(
            for: sampleCalls,
            sampleAnalysis: sampleAnalysis
        )
        animalGenotypesBySample[sampleId] = rows
        return rows
    }

    private func animalGenotypes(
        for sampleCalls: [ONTGenotypeCall],
        sampleAnalysis: GenotypeHaplotypeSampleAnalysis
    ) -> [GenotypeCallEvidenceView.AnimalGenotype] {
        let diagnosticIdentifiers = diagnosticIdentifierSetsBySample[sampleAnalysis.sample]
            ?? diagnosticIdentifiers(for: sampleAnalysis)
        return sampleCalls
            .sorted {
                if $0.locusGroup != $1.locusGroup {
                    return $0.locusGroup.localizedStandardCompare($1.locusGroup) == .orderedAscending
                }
                if $0.passedUniqueReads != $1.passedUniqueReads {
                    return $0.passedUniqueReads > $1.passedUniqueReads
                }
                return $0.genotype.localizedStandardCompare($1.genotype) == .orderedAscending
            }
            .map { call in
                GenotypeCallEvidenceView.AnimalGenotype(
                    genotype: call.genotype,
                    locus: call.locusGroup,
                    reads: call.passedUniqueReads,
                    isDiagnosticForCall: isDiagnosticForAnyHaplotypeCall(
                        genotype: call.genotype,
                        sampleAnalysis: sampleAnalysis,
                        diagnosticIdentifiers: diagnosticIdentifiers
                    ),
                    associatedHaplotypes: associatedHaplotypes(for: call)
                )
            }
    }

    private func diagnosticIdentifiers(
        for sampleAnalysis: GenotypeHaplotypeSampleAnalysis
    ) -> Set<String> {
        var identifiers = Set<String>()
        for locusCall in sampleAnalysis.calls {
            for matched in locusCall.matchedHaplotypes {
                for allele in matched.diagnosticAlleles {
                    let identifier = Self.genotypeIdentifier(allele)
                    if !identifier.isEmpty {
                        identifiers.insert(identifier)
                    }
                }
                for allele in matched.observedDiagnosticAlleles {
                    let identifier = Self.genotypeIdentifier(allele)
                    if !identifier.isEmpty {
                        identifiers.insert(identifier)
                    }
                }
            }
        }
        return identifiers
    }

    private func isDiagnosticForAnyHaplotypeCall(
        genotype: String,
        sampleAnalysis: GenotypeHaplotypeSampleAnalysis,
        diagnosticIdentifiers: Set<String>
    ) -> Bool {
        let identifier = Self.genotypeIdentifier(genotype)
        if diagnosticIdentifiers.contains(identifier) {
            return true
        }
        if Self.isExactMiSeqIdentifier(identifier) {
            return false
        }
        return sampleAnalysis.calls.contains { locusCall in
            locusCall.matchedHaplotypes.contains { matched in
                matched.diagnosticAlleles.contains {
                    GenotypeHaplotypeDiagnosticMatcher.matches(
                        genotype: genotype,
                        diagnosticAllele: $0
                    )
                } || matched.observedDiagnosticAlleles.contains {
                    GenotypeHaplotypeDiagnosticMatcher.matches(
                        genotype: genotype,
                        diagnosticAllele: $0
                    )
                }
            }
        }
    }

    private func associatedHaplotypes(for call: ONTGenotypeCall) -> [String] {
        if let metadataValue = pipeMetadataValue("haplotypes", in: call.genotype) {
            let tokens = metadataValue.split(separator: ",").map {
                String($0).trimmingCharacters(in: .whitespacesAndNewlines)
            }
            return uniqueHaplotypeTokens(tokens)
        }
        return uniqueHaplotypeTokens(call.haplotypeTokens)
    }

    private struct CallIndex {
        let displayGenotypeByIdentifier: [String: String]
        let readsByIdentifier: [String: Int]
    }

    private func callIndex(for calls: [ONTGenotypeCall]) -> CallIndex {
        var displayByIdentifier: [String: ONTGenotypeCall] = [:]
        var readsByIdentifier: [String: Int] = [:]
        displayByIdentifier.reserveCapacity(calls.count)
        readsByIdentifier.reserveCapacity(calls.count)
        for call in calls {
            let identifier = Self.genotypeIdentifier(call.genotype)
            guard !identifier.isEmpty else { continue }
            readsByIdentifier[identifier, default: 0] += max(0, call.passedUniqueReads)
            if let existing = displayByIdentifier[identifier] {
                if call.passedUniqueReads > existing.passedUniqueReads
                    || (
                        call.passedUniqueReads == existing.passedUniqueReads
                        && call.genotype.localizedStandardCompare(existing.genotype) == .orderedAscending
                    ) {
                    displayByIdentifier[identifier] = call
                }
            } else {
                displayByIdentifier[identifier] = call
            }
        }
        return CallIndex(
            displayGenotypeByIdentifier: displayByIdentifier.mapValues(\.genotype),
            readsByIdentifier: readsByIdentifier
        )
    }

    private func indexedDiagnosticDisplayGenotype(
        for allele: String,
        locusDefinition: GenotypeHaplotypeLocusDefinition?
    ) -> String? {
        let identifier = Self.genotypeIdentifier(allele)
        if let indexed = diagnosticDisplayGenotypeByIdentifier[identifier] {
            return indexed
        }
        if allele.contains("|") {
            return allele
        }
        return nil
    }

    private static func genotypeIdentifier(_ value: String) -> String {
        value.split(separator: "|", maxSplits: 1, omittingEmptySubsequences: false)
            .first
            .map(String.init)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? value
    }

    private static func isExactMiSeqIdentifier(_ value: String) -> Bool {
        value.uppercased().hasPrefix("MCM_MHC_MISEQ_")
    }

    private func pipeMetadataValue(_ key: String, in genotype: String) -> String? {
        for part in genotype.split(separator: "|").dropFirst() {
            let pieces = part.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard pieces.count == 2 else { continue }
            if String(pieces[0]).trimmingCharacters(in: .whitespacesAndNewlines) == key {
                return String(pieces[1]).trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        return nil
    }

    private func uniqueHaplotypeTokens(_ tokens: [String]) -> [String] {
        var seen = Set<String>()
        return tokens.compactMap { token in
            let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, seen.insert(trimmed).inserted else { return nil }
            return trimmed
        }
    }

    /// Plain-English explanation of why a call is in error. Empty string
    /// when the call is healthy (called or special-case). Reviewers see
    /// this in the Review-lens panel and source-level tests.
    private func errorExplanation(
        for locusCall: GenotypeHaplotypeLocusCall,
        observed: Set<String>
    ) -> String {
        switch locusCall.status {
        case .called, .specialCase:
            return ""
        case .notAssayed:
            return locusCall.notes.isEmpty
                ? "\(locusCall.locus) was not observed anywhere in this run for the active definition set. Treat this as assay/reference coverage not available, not as a sample-level haplotype failure."
                : locusCall.notes
        case .noHaplotype:
            return "No defined haplotype matched. The observed alleles at \(locusCall.locus) do not form a complete diagnostic set for any haplotype in the active definition set. Either the sample carries a novel allele combination, or one or more defining alleles dropped below the read threshold."
        case .tooManyHaplotypes:
            let names = locusCall.matchedHaplotypes.map(\.name).joined(separator: ", ")
            return "Too many haplotypes matched (\(locusCall.matchedHaplotypes.count)): \(names). A diploid sample should match at most two. Likely cross-well contamination, an over-permissive threshold, or shared diagnostic alleles between haplotypes."
        case .tooManyGenotypes:
            let extras = max(0, locusCall.observedGenotypeCount - 2)
            return "Too many genotypes observed at \(locusCall.locus) (\(locusCall.observedGenotypeCount)). For diploid Class II loci, each raw DPA/DPB or DQA/DQB sub-locus should contribute at most two genotypes to the combined DP or DQ haplotype call. The extra \(extras) genotype\(extras == 1 ? "" : "s") suggests cross-well contamination, a barcoding error, or low-support spurious calls. If the automatic 10x dominance rule cannot resolve the call, this locus requires human curation."
        }
    }

    /// Per-candidate-haplotype breakdown for NO HAP / TMG situations: which
    /// diagnostic alleles are observed in the sample vs missing. Empty
    /// list for healthy calls and TMH (where the matched-haplotype list
    /// already conveys the relevant info).
    /// Surface ALL candidate haplotypes for the locus with their
    /// per-allele observed/missing breakdown — even when the locus call
    /// is healthy. The analyst can then see at a glance "why M3B was
    /// called and not M2B" by comparing observed-allele counts. Sorted
    /// by observed-count descending so the strongest candidates appear
    /// first; haplotypes with no overlap are dropped.
    private func candidateHaplotypes(
        for locusCall: GenotypeHaplotypeLocusCall,
        observedAlleles: Set<String>,
        sampleCalls: [ONTGenotypeCall],
        sampleCallIndex: CallIndex
    ) -> [GenotypeCallEvidenceView.CandidateHaplotype] {
        guard let result, let definitionSet = definitionSetForResult(result) else { return [] }
        guard let locusDef = definitionSet.locusDefinitions.first(where: { $0.locus == locusCall.locus }) else {
            return []
        }
        let observedIdentifiers = Set(observedAlleles.map(Self.genotypeIdentifier))
        let candidates = locusDef.haplotypes.compactMap { haplotype -> GenotypeCallEvidenceView.CandidateHaplotype? in
            var present: [String] = []
            var missing: [String] = []
            for allele in haplotype.diagnosticAlleles {
                let identifier = Self.genotypeIdentifier(allele)
                let hasObservedIdentifier = observedIdentifiers.contains(identifier)
                let hasObservedDiagnostic = hasObservedIdentifier
                    || (!Self.isExactMiSeqIdentifier(identifier) && observedAlleles.contains(where: { observed in
                        GenotypeHaplotypeDiagnosticMatcher.matches(genotype: observed, diagnosticAllele: allele)
                    }))
                if hasObservedDiagnostic {
                    present.append(
                        sampleCallIndex.displayGenotypeByIdentifier[identifier] ?? diagnosticDisplayGenotype(
                            for: allele,
                            in: sampleCalls,
                            locusDefinition: locusDef
                        ) ?? allele
                    )
                } else {
                    missing.append(
                        indexedDiagnosticDisplayGenotype(
                            for: allele,
                            locusDefinition: locusDef
                        ) ?? allele
                    )
                }
            }
            guard !present.isEmpty else { return nil }
            return GenotypeCallEvidenceView.CandidateHaplotype(
                name: haplotype.name,
                observed: present,
                missing: missing
            )
        }
        return candidates.sorted {
            if $0.observed.count != $1.observed.count {
                return $0.observed.count > $1.observed.count
            }
            return $0.name < $1.name
        }
    }

    private func displayedCallName(sample: String, locus: String, slot: HaplotypeSlot, fallback: String) -> String {
        if let override = annotationStore?.sidecar.callOverrides.first(where: {
            $0.sample == sample && $0.locus == locus && $0.slot == slot
        }) {
            return override.overrideCall
        }
        if let assignment = manualHaplotypeAssignment(sample: sample, locus: locus, slot: slot) {
            return assignment.label
        }
        return fallback
    }

    private func hasCallOverride(sample: String, locus: String, slot: HaplotypeSlot) -> Bool {
        guard let overrides = annotationStore?.sidecar.callOverrides else { return false }
        return overrides.contains {
            $0.sample == sample && $0.locus == locus && $0.slot == slot
        }
    }

    private func manualHaplotypeAssignment(
        sample: String,
        locus: String,
        slot: HaplotypeSlot
    ) -> ManualHaplotypeAssignment? {
        annotationStore?.sidecar.manualHaplotypeAssignments.reversed().first {
            $0.sample == sample && $0.locus == locus && $0.slot == slot
        }
    }

    private func hasManualHaplotypeAssignment(sample: String, locus: String, slot: HaplotypeSlot) -> Bool {
        manualHaplotypeAssignment(sample: sample, locus: locus, slot: slot) != nil
    }

    private func diploidDisplayName(h1: String, h2: String) -> String {
        if h2.isEmpty || h2 == "-" || h2 == h1 {
            return h1
        }
        return "\(h1) / \(h2)"
    }

    private func neighborSummaries(
        for sampleId: String,
        in sampleNames: [String],
        analysis: GenotypeHaplotypeAnalysis
    ) -> (before: [GenotypeCallEvidenceView.Neighbor], after: [GenotypeCallEvidenceView.Neighbor]) {
        guard let index = sampleNames.firstIndex(of: sampleId) else { return ([], []) }
        let analysesBySample = Dictionary(uniqueKeysWithValues: analysis.samples.map { ($0.sample, $0) })
        func summary(for name: String) -> String {
            guard let analysis = analysesBySample[name] else { return "—" }
            return analysis.calls.map { "\($0.haplotype1)/\($0.haplotype2)" }
                .prefix(2)
                .joined(separator: ", ")
        }
        var before: [GenotypeCallEvidenceView.Neighbor] = []
        var after: [GenotypeCallEvidenceView.Neighbor] = []
        if index > 0 {
            let name = sampleNames[index - 1]
            before.append(.init(animalId: name, summary: summary(for: name)))
        }
        if index < sampleNames.count - 1 {
            let name = sampleNames[index + 1]
            after.append(.init(animalId: name, summary: summary(for: name)))
        }
        return (before, after)
    }

    private func applySummaryViewModeVisibility() {
        let isMatrixMode = displayState.summaryViewMode == .matrix
        let usesDefinitionMatrix = isMatrixMode && summaryMatrixUsesHaplotypeDefinitions()
        let showsRawMatrix = isMatrixMode
            && !usesDefinitionMatrix
            && (isGenotypeOnlyResult || !displayState.showsAncillaryLoci)
        let showsOutline = !isMatrixMode || (!usesDefinitionMatrix && !showsRawMatrix)
        outlineView.isHidden = !showsOutline
        haplotypeMatrixView.isHidden = !usesDefinitionMatrix
        comparisonMatrix.isHidden = !showsRawMatrix
        cohortSummaryPanel.isHidden = false
        detailScrollView.isHidden = true
        detailContainer.isHidden = false

        if isGenotypeOnlyResult && showsRawMatrix {
            cohortSummaryPanel.isHidden = true
            detailScrollView.isHidden = false
            detailContainer.isHidden = false
            callEvidenceHost?.isHidden = true
        }

        if showsRawMatrix {
            ensureComparisonMatrixConfigured()
        }
    }

    private func tapeCell(for haplotypeName: String, status: GenotypeHaplotypeCallStatus) -> GenotypeHaplotypeTapeView.Cell {
        if status == .notAssayed {
            return .notAssayed(label: haplotypeName.isEmpty ? "Not assayed" : haplotypeName)
        }
        if haplotypeName == GenotypeHaplotypeOverrideTargets.unresolved {
            return .error(label: haplotypeName)
        }
        if haplotypeName.isEmpty || haplotypeName == "-" {
            return .empty
        }
        if haplotypeName.hasPrefix("ERR:") {
            return .error(label: haplotypeName)
        }
        if status != .called && status != .notAssayed && status != .specialCase {
            return .error(label: haplotypeName)
        }
        let token = HaplotypeColorToken.assigned(forName: haplotypeName)
        return .reference(tokenIndex: token.canonicalIndex, label: haplotypeName)
    }

    private func segmentIndex(for lens: Lens) -> Int {
        availableLenses.firstIndex(of: lens) ?? 0
    }

    private func installContentView(_ contentView: NSView) {
        guard activeContentView !== contentView else { return }
        NSLayoutConstraint.deactivate(activeContentConstraints)
        activeContentConstraints = []
        activeContentView?.removeFromSuperview()

        contentHost.addSubview(contentView)
        activeContentView = contentView
        activeContentConstraints = [
            contentView.topAnchor.constraint(equalTo: contentHost.topAnchor),
            contentView.leadingAnchor.constraint(equalTo: contentHost.leadingAnchor),
            contentView.trailingAnchor.constraint(equalTo: contentHost.trailingAnchor),
            contentView.bottomAnchor.constraint(equalTo: contentHost.bottomAnchor),
        ]
        NSLayoutConstraint.activate(activeContentConstraints)
    }

    private func applySplitPositionIfNeeded() {
        splitCoordinator.applyInitialSplitPositionIfNeeded(
            to: splitView,
            defaultLeadingFraction: defaultLeadingFraction(for: displayState.layout),
            defaultLeadingExtent: defaultLeadingExtent(for: displayState.layout),
            minimumExtents: minimumSplitExtents()
        )
    }

    private func scheduleInitialSplitValidationIfNeeded() {
        splitCoordinator.scheduleInitialSplitValidationIfNeeded(
            ownerView: view,
            splitView: splitView,
            minimumExtents: { [weak self] in
                self?.minimumSplitExtents() ?? (360, 280)
            },
            defaultLeadingFraction: { [weak self] in
                self?.defaultLeadingFraction(for: self?.displayState.layout ?? .listLeading) ?? 0.62
            },
            defaultLeadingExtent: { [weak self] in
                self?.defaultLeadingExtent(for: self?.displayState.layout ?? .listLeading)
            }
        )
    }

    private func minimumSplitExtents() -> (leading: CGFloat, trailing: CGFloat) {
        switch displayState.layout {
        case .listLeading, .listTrailing:
            return (leading: 280, trailing: 240)
        case .listTop:
            // Keep enough room for the quick filter plus at least a few rows
            // while still allowing either pane to collapse substantially.
            return (leading: 128, trailing: 100)
        }
    }

    private func defaultLeadingFraction(for layout: GenotypeResultPanelLayout) -> CGFloat {
        switch layout {
        case .listLeading:
            return 0.68
        case .listTrailing:
            return 0.32
        case .listTop:
            // Review lens shows per-call evidence in Panel B which needs
            // more vertical room than Summary's thin cohort summary;
            // bias the divider 60/40 in Review and 75/25 in Summary so
            // the two lenses are visually distinct.
            return selectedLens == .review ? 0.55 : 0.75
        }
    }

    private func defaultLeadingExtent(for layout: GenotypeResultPanelLayout) -> CGFloat? {
        switch layout {
        case .listLeading:
            return 720
        case .listTrailing:
            return 360
        case .listTop:
            return nil
        }
    }

    private func applyLayoutPreference() {
#if DEBUG
        testingLayoutApplicationCount += 1
#endif
        guard splitView.arrangedSubviews.count > 1 else { return }
        let listFirst = displayState.layout != .listTrailing
        splitCoordinator.applyLayoutPreference(
            to: splitView,
            desiredIsVertical: displayState.layout != .listTop,
            desiredFirstPane: listFirst ? sampleContainer : detailContainer,
            desiredSecondPane: listFirst ? detailContainer : sampleContainer,
            defaultLeadingFraction: defaultLeadingFraction(for: displayState.layout),
            defaultLeadingExtent: defaultLeadingExtent(for: displayState.layout),
            minimumExtents: minimumSplitExtents(),
            isViewInWindow: view.window != nil
        )
    }

    private func showSharedCall(
        _ sharedCall: ONTGenotypeSharedCall,
        sample: String? = nil,
        matrixTargets: [GenotypeAnnotationSidecar.MatrixTarget]? = nil
    ) {
        if let sample, !hasSelectedCellSupport(for: sharedCall, sample: sample) {
            let targets = matrixTargets ?? [
                .cell(locus: sharedCall.locus, genotype: sharedCall.genotype, sample: sample),
            ]
            if isFullLengthMHCGenotypeViewport {
                currentSharedCall = nil
                currentCandidateRow = nil
                currentSelectedSample = nil
                showAlleleSequenceRows(for: [])
                publishSelectionState(matrixTargetSelectionState(for: targets))
            } else {
                showCellSelection(targets)
            }
            return
        }
        currentSharedCall = sharedCall
        currentCandidateRow = nil
        currentSelectedSample = sample
        let displayLabel = alleleDisplayLabel(for: sharedCall.genotype)
        let referenceRows = genBankFieldRows(for: sharedCall.genotype)
        let resolvedMatrixTargets = matrixTargets ?? [
            sample.map {
                GenotypeAnnotationSidecar.MatrixTarget.cell(
                    locus: sharedCall.locus,
                    genotype: sharedCall.genotype,
                    sample: $0
                )
            } ?? .row(locus: sharedCall.locus, genotype: sharedCall.genotype),
        ]
        let commentTargets = applicableCommentTargets(for: resolvedMatrixTargets)
        let commentRows = matrixCommentDetailRows(for: commentTargets)
        if let provisional =
            result?.provisionalExon2SequencesByGenotype[sharedCall.genotype],
           let sequenceRecord =
            provisionalExon2SequenceRecordsByGenotype[sharedCall.genotype] {
            showProvisionalExon2Selection(
                provisional,
                sequenceRecord: sequenceRecord,
                sharedCall: sharedCall,
                sample: sample,
                matrixTargets: resolvedMatrixTargets,
                commentRows: commentRows
            )
            return
        }
        if isFullLengthMHCGenotypeViewport {
            showAlleleSequenceRows(for: resolvedMatrixTargets)
            publishSelectionState(selectionState(
                for: sharedCall,
                sample: sample,
                matrixTargets: resolvedMatrixTargets,
                providedCommentRows: commentRows
            ))
            return
        }
        if let record = result?.mhcReferenceVisualizations?.recordsByKnownCallGenotype[sharedCall.genotype] {
            knownAlleleDetailView.configure(
                record: record,
                observedSample: sample,
                comments: commentRows
            )
        } else {
            knownAlleleDetailView.configureFallback(
                alleleName: displayLabel,
                rawReferenceID: sharedCall.genotype,
                fields: referenceRows,
                observedSample: sample,
                comments: commentRows
            )
        }
        if detailStack.arrangedSubviews.count != 1
            || detailStack.arrangedSubviews.first !== knownAlleleDetailView {
            removeArrangedSubviews(from: detailStack)
            detailStack.addArrangedSubview(knownAlleleDetailView)
            knownAlleleDetailMountCount += 1
        }

        publishSelectionState(selectionState(
            for: sharedCall,
            sample: sample,
            matrixTargets: resolvedMatrixTargets,
            providedCommentRows: commentRows
        ))
    }

    private func hasSelectedCellSupport(
        for sharedCall: ONTGenotypeSharedCall,
        sample: String
    ) -> Bool {
        knownSelectionDiagnostics.indexedCellSupportLookupCount += 1
        return sampleSupportByCellKey[CellEvidenceKey(
            locus: sharedCall.locus,
            genotype: sharedCall.genotype,
            sample: sample
        )] != nil
    }

    private func showCandidateRow(
        _ row: GenotypeCandidateMatrixRow,
        sample: String?,
        matrixTargets: [GenotypeAnnotationSidecar.MatrixTarget]
    ) {
        guard let result,
              validatedMHCCandidateDocument(from: result) != nil,
              let candidate = row.candidate,
              let stableClusterID = row.stableClusterID,
              let presentation = candidatePresentationsByStableClusterID[stableClusterID] else {
            showEmptySelection()
            return
        }
        currentSharedCall = nil
        currentCandidateRow = row
        currentSelectedSample = sample
        let commentRows = matrixCommentDetailRows(
            for: row.sharedCall,
            sample: sample,
            matrixTargets: matrixTargets
        )
        let rows = presentation.detailRows(selectedSample: sample) + commentRows
        if isFullLengthMHCGenotypeViewport {
            showAlleleSequenceRows(for: matrixTargets)
            let target = GenotypeResultHighlightTarget(
                genotype: row.genotype,
                locus: row.locus,
                sample: sample,
                stableClusterID: row.stableClusterID
            )
            publishSelectionState(GenotypeResultSelectionState(
                title: row.alleleName,
                subtitle: "\(row.locus) candidate - \(row.stableClusterID ?? "Unavailable")",
                detailRows: rows,
                highlightTarget: target,
                highlightStyle: comparisonMatrix.highlightStyle(for: target),
                matrixTargets: matrixTargets
            ))
            return
        }
        let warning = [
            candidatePersistenceWarning,
            GenotypeCandidateEvidenceProjection.warningText(result.integrityWarnings),
        ]
            .compactMap { value -> String? in
                guard let value, !value.isEmpty else { return nil }
                return value
            }
            .joined(separator: "\n")
        candidateAlleleDetailView.configure(
            candidate: candidate,
            closestReference: result.mhcReferenceVisualizations?
                .recordsByCandidateStableClusterID[stableClusterID],
            candidateSequence: result.mhcCandidateSequencesByStableClusterID[stableClusterID],
            selectedSampleID: sample,
            selectedSampleReadCount: sample.flatMap {
                presentation.selectedSampleReadCounts[$0]
            },
            comments: commentRows,
            warning: warning.isEmpty ? nil : warning
        )
        if detailStack.arrangedSubviews.count != 1
            || detailStack.arrangedSubviews.first !== candidateAlleleDetailView {
            removeArrangedSubviews(from: detailStack)
            detailStack.addArrangedSubview(candidateAlleleDetailView)
            candidateAlleleDetailWidthConstraint = candidateAlleleDetailView.widthAnchor.constraint(
                equalTo: detailStack.widthAnchor
            )
            candidateAlleleDetailWidthConstraint?.isActive = true
            candidateAlleleDetailMountCount += 1
        }

        let target = GenotypeResultHighlightTarget(
            genotype: row.genotype,
            locus: row.locus,
            sample: sample,
            stableClusterID: row.stableClusterID
        )
        publishSelectionState(GenotypeResultSelectionState(
            title: row.alleleName,
            subtitle: "\(row.locus) candidate - \(row.stableClusterID ?? "Unavailable")",
            detailRows: rows,
            highlightTarget: target,
            highlightStyle: comparisonMatrix.highlightStyle(for: target),
            matrixTargets: matrixTargets
        ))
    }

    private func showEmptySelection() {
        currentSharedCall = nil
        currentCandidateRow = nil
        currentSelectedSample = nil
        manualHaplotypeEditorModel = nil
        manualHaplotypeEditorHostView = nil
        alleleSequenceDetailWidthConstraint?.isActive = false
        alleleSequenceDetailWidthConstraint = nil
        alleleSequenceDetailHeightConstraint?.isActive = false
        alleleSequenceDetailHeightConstraint = nil
        removeArrangedSubviews(from: detailStack)
        renderedAlleleSequenceRecordIdentities = []
        alleleSequenceDetailView.clear()
        if !isFullLengthMHCGenotypeViewport {
            detailStack.addArrangedSubview(caption("Select a sample column or allele row to view details."))
        }
        publishSelectionState(nil)
    }

    private func showMatrixTargetSelection(_ targets: [GenotypeAnnotationSidecar.MatrixTarget]) {
        currentSharedCall = nil
        currentCandidateRow = nil
        currentSelectedSample = nil
        let uniqueTargets = uniqueMatrixTargets(targets)
        guard !uniqueTargets.isEmpty else {
            showEmptySelection()
            return
        }
        let selectionKind = matrixSelectionKind(for: uniqueTargets)
        if isFullLengthMHCGenotypeViewport,
           selectionKind != .columns {
            let rowTargets = comparisonMatrix.orderedVisibleRowTargets(from: uniqueTargets)
            if !rowTargets.isEmpty {
                showAlleleSequenceRows(for: rowTargets)
                publishSelectionState(matrixTargetSelectionState(for: uniqueTargets))
                return
            }
            showAlleleSequenceRows(for: [])
            publishSelectionState(matrixTargetSelectionState(for: uniqueTargets))
            return
        }
        switch selectionKind {
        case .rows:
            showAlleleRowSelection(uniqueTargets)
        case .columns:
            showSampleColumnSelection(uniqueTargets)
        case .cells:
            showCellSelection(uniqueTargets)
        case .mixed:
            showGenericMatrixTargetSelection(uniqueTargets)
        }
    }

    private func showAlleleSequenceRows(
        for targets: [GenotypeAnnotationSidecar.MatrixTarget]
    ) {
        let rowTargets = comparisonMatrix.orderedVisibleRowTargets(from: targets)
        guard !rowTargets.isEmpty else {
            candidateAlleleDetailWidthConstraint?.isActive = false
            candidateAlleleDetailWidthConstraint = nil
            alleleSequenceDetailWidthConstraint?.isActive = false
            alleleSequenceDetailWidthConstraint = nil
            alleleSequenceDetailHeightConstraint?.isActive = false
            alleleSequenceDetailHeightConstraint = nil
            removeArrangedSubviews(from: detailStack)
            alleleSequenceDetailView.clear()
            renderedAlleleSequenceRecordIdentities = []
            return
        }
        let records = rowTargets.compactMap { target -> GenotypeAlleleSequenceRecord? in
            guard case let .row(locus, genotype, stableClusterID) = target else {
                return nil
            }
            if let stableClusterID {
                return candidateSequenceRecordsByStableClusterID[stableClusterID]
                    ?? .unavailable(identity: stableClusterID, displayName: genotype)
            }
            return knownSequenceRecordsByRowID[
                .known(locus: locus, genotype: genotype)
            ]
                ?? .unavailable(identity: genotype, displayName: alleleDisplayLabel(for: genotype))
        }
        showAlleleSequenceRecords(records)
    }

    private func showAlleleSequenceRecords(
        _ records: [GenotypeAlleleSequenceRecord]
    ) {
        candidateAlleleDetailWidthConstraint?.isActive = false
        candidateAlleleDetailWidthConstraint = nil
        if detailStack.arrangedSubviews.count != 1
            || detailStack.arrangedSubviews.first !== alleleSequenceDetailView {
            removeArrangedSubviews(from: detailStack)
            detailStack.addArrangedSubview(alleleSequenceDetailView)
            alleleSequenceDetailWidthConstraint = alleleSequenceDetailView.widthAnchor.constraint(
                equalTo: detailStack.widthAnchor
            )
            alleleSequenceDetailHeightConstraint = alleleSequenceDetailView.heightAnchor.constraint(
                greaterThanOrEqualTo: detailScrollView.contentView.heightAnchor,
                constant: -16
            )
            NSLayoutConstraint.activate([
                alleleSequenceDetailWidthConstraint,
                alleleSequenceDetailHeightConstraint,
            ].compactMap { $0 })
            alleleSequenceDetailMountCount += 1
        }
        renderedAlleleSequenceRecordIdentities = records.map(\.identity)
        alleleSequenceDetailView.show(records: records)
    }

    private func showProvisionalExon2Selection(
        _ provisional: ONTGenotypeProvisionalExon2Sequence,
        sequenceRecord: GenotypeAlleleSequenceRecord,
        sharedCall: ONTGenotypeSharedCall,
        sample: String?,
        matrixTargets: [GenotypeAnnotationSidecar.MatrixTarget],
        commentRows: [(String, String)]
    ) {
        showAlleleSequenceRecords([sequenceRecord])
        var rows: [(String, String)] = [
            ("Designation", provisional.designation),
            (
                "Interpretation",
                "Short exon 2 exact run reference match; not an IPD-qualified novel-allele designation."
            ),
            ("Run Identifier", provisional.genotype),
            ("Locus", provisional.locus),
            ("Sequence Length", "\(provisional.sequence.utf8.count) bp"),
            ("Observed Samples", "\(provisional.sampleSupport.count)"),
        ]
        rows += provisional.sampleSupport.map { support in
            (
                "\(support.sample) Support",
                "\(integer(support.passedUniqueReads)) unique reads; "
                    + "\(integer(support.passedAlignments)) alignments"
            )
        }
        if let sample,
           let support = provisional.sampleSupport.first(where: {
               $0.sample == sample
           }) {
            rows += [
                ("Selected Sample", sample),
                ("Selected Unique Reads", integer(support.passedUniqueReads)),
                ("Selected Alignments", integer(support.passedAlignments)),
            ]
        }
        rows += commentRows
        let target = GenotypeResultHighlightTarget(
            genotype: sharedCall.genotype,
            locus: sharedCall.locus,
            sample: sample
        )
        publishSelectionState(GenotypeResultSelectionState(
            title: provisional.genotype,
            subtitle: "\(provisional.locus) · Provisional exon 2",
            detailRows: rows,
            highlightTarget: target,
            highlightStyle: comparisonMatrix.highlightStyle(for: target),
            matrixTargets: matrixTargets
        ))
    }

    private func showGenericMatrixTargetSelection(_ uniqueTargets: [GenotypeAnnotationSidecar.MatrixTarget]) {
        legacyNonRowDetailBuildCount += 1
        removeArrangedSubviews(from: detailStack)
        detailStack.addArrangedSubview(sectionTitle("Matrix Annotation Targets"))
        let rows = matrixTargetDetailRows(for: uniqueTargets) + matrixCommentDetailRows(for: uniqueTargets)
        detailStack.addArrangedSubview(detailRows(rows))
        publishSelectionState(matrixTargetSelectionState(for: uniqueTargets))
    }

    private enum MatrixSelectionKind {
        case rows
        case columns
        case cells
        case mixed
    }

    private func matrixSelectionKind(
        for targets: [GenotypeAnnotationSidecar.MatrixTarget]
    ) -> MatrixSelectionKind {
        var hasRows = false
        var hasColumns = false
        var hasCells = false
        for target in targets {
            switch target {
            case .row: hasRows = true
            case .column: hasColumns = true
            case .cell: hasCells = true
            }
        }
        let count = [hasRows, hasColumns, hasCells].filter { $0 }.count
        guard count == 1 else { return .mixed }
        if hasRows { return .rows }
        if hasColumns { return .columns }
        return .cells
    }

    private func showAlleleRowSelection(_ targets: [GenotypeAnnotationSidecar.MatrixTarget]) {
        let calls = sharedCalls(for: targets)
        if calls.count == 1, let call = calls.first {
            showSharedCall(call, matrixTargets: targets)
            return
        }
        removeArrangedSubviews(from: detailStack)
        detailStack.addArrangedSubview(sectionTitle("Selected Alleles: \(targets.count)"))
        var stateRows: [(String, String)] = [("Selection Type", "Rows"), ("Selected Alleles", "\(targets.count)")]
        var renderedEntries: [String] = []
        renderedEntries.reserveCapacity(calls.count)
        for (index, call) in calls.enumerated() {
            let label = alleleDisplayLabel(for: call.genotype)
            var rows: [(String, String)] = []
            if label != call.genotype {
                rows.append(("Reference Sequence", call.genotype))
            }
            rows += [
                ("Locus", call.locus),
                ("Samples", "\(call.sampleCount)"),
                ("Unique Reads", integer(call.totalUniqueReads)),
                ("Alignments", integer(call.totalAlignments)),
            ]
            rows += genBankFieldRows(for: call.genotype)
            renderedEntries.append(compactSelectionEntry(label: label, rows: rows))
            stateRows.append(("Allele \(index + 1)", label))
            stateRows += rows
        }
        if !renderedEntries.isEmpty {
            detailStack.addArrangedSubview(wrappingText(renderedEntries.joined(separator: "\n\n")))
        }
        let comments = matrixCommentDetailRows(for: targets)
        appendCommentsToDetail(comments)
        stateRows += comments
        publishSelectionState(GenotypeResultSelectionState(
            title: "Selected Alleles: \(targets.count)",
            subtitle: "Matrix rows",
            detailRows: stateRows,
            highlightTarget: nil,
            matrixTargets: targets
        ))
    }

    private func showSampleColumnSelection(_ targets: [GenotypeAnnotationSidecar.MatrixTarget]) {
        legacyNonRowDetailBuildCount += 1
        let samples = targets.compactMap { target -> String? in
            guard case let .column(sample) = target else { return nil }
            return sample
        }.sorted {
            let order = $0.localizedStandardCompare($1)
            return order == .orderedSame ? $0 < $1 : order == .orderedAscending
        }
        manualHaplotypeEditorModel = nil
        manualHaplotypeEditorHostView = nil
        removeArrangedSubviews(from: detailStack)
        var stateRows: [(String, String)] = [
            ("Selection Type", samples.count == 1 ? "Column" : "Columns"),
        ]
        if samples.count == 1, let sample = samples.first {
            showSingleSampleColumnSelection(
                sample: sample,
                targets: targets,
                stateRows: &stateRows
            )
            publishSelectionState(GenotypeResultSelectionState(
                title: sample,
                subtitle: "Sample column",
                detailRows: stateRows,
                highlightTarget: nil,
                matrixTargets: targets
            ))
            return
        }

        detailStack.addArrangedSubview(sectionTitle("Selected Samples"))
        let manualAssignmentIndex =
            GenotypeManualHaplotypeAssignmentIndex(
                assignments:
                    annotationStore?.sidecar
                        .manualHaplotypeAssignments ?? []
            )
        let multiSamplePresentation =
            GenotypeManualHaplotypeMultiSamplePresentation(
                samples: samples
            )
        for (index, sample) in
            multiSamplePresentation.visibleSamples.enumerated() {
            detailStack.addArrangedSubview(wrappingText(sample, weight: .medium))
            let summary = sampleResultsByName[sample]
            var rows: [(String, String)] = [("Sample", sample)]
            if let summary {
                rows += [
                    ("Retained Unique Reads", integer(summary.passedUniqueReads)),
                    ("Alignments", integer(summary.passedAlignments)),
                    ("QC", summary.qcStatus.displayName),
                ]
            }
            let assignments =
                manualAssignmentIndex
                    .sampleAssignments(for: sample)
                    .assignments
            let totalSlots =
                GenotypeManualHaplotypeLocus.allCases.count
                * HaplotypeSlot.allCases.count
            let completeness =
                "\(assignments.count) of \(totalSlots) assigned"
            let labels = Array(
                Set(assignments.map(\.label))
            ).sorted {
                let order =
                    $0.localizedStandardCompare($1)
                return order == .orderedSame
                    ? $0 < $1
                    : order == .orderedAscending
            }
            let boundedLabels = labels.prefix(6)
            var labelSummary = boundedLabels.isEmpty
                ? "None"
                : boundedLabels.joined(separator: ", ")
            let remainingLabels =
                labels.count - boundedLabels.count
            if remainingLabels > 0 {
                labelSummary +=
                    " (+\(remainingLabels) more)"
            }
            rows += [
                ("Haplotype Completeness", completeness),
                ("Haplotype Labels", labelSummary),
            ]
            stateRows += [
                (
                    "\(sample) Haplotype Completeness",
                    completeness
                ),
                (
                    "\(sample) Haplotype Labels",
                    labelSummary
                ),
            ]
            detailStack.addArrangedSubview(detailRows(rows))
            stateRows.append(("Sample \(index + 1)", sample))
            stateRows += rows.filter {
                !$0.0.hasPrefix("Haplotype ")
            }
        }
        if let omissionSummary =
            multiSamplePresentation.omissionSummary {
            detailStack.addArrangedSubview(
                caption(omissionSummary)
            )
            stateRows.append(
                (
                    "Additional Selected Samples",
                    "\(multiSamplePresentation.omittedSampleCount)"
                )
            )
        }
        let comments = matrixCommentDetailRows(for: targets)
        appendCommentsToDetail(comments)
        stateRows += comments
        publishSelectionState(GenotypeResultSelectionState(
            title: "Selected Samples: \(samples.count)",
            subtitle: "Sample columns",
            detailRows: stateRows,
            highlightTarget: nil,
            matrixTargets: targets
        ))
    }

    private func showSingleSampleColumnSelection(
        sample: String,
        targets: [GenotypeAnnotationSidecar.MatrixTarget],
        stateRows: inout [(String, String)]
    ) {
        let summary = sampleResultsByName[sample]
        var sampleRows: [(String, String)] = [("Sample", sample)]
        if let summary {
            sampleRows += [
                (
                    "Retained Unique Reads",
                    integer(summary.passedUniqueReads)
                ),
                ("Alignments", integer(summary.passedAlignments)),
                ("QC", summary.qcStatus.displayName),
            ]
        }
        stateRows.append(("Selected Sample", sample))
        stateRows += sampleRows

        let supported = sortedVisibleSampleAlleleDetails(sample: sample)
        let snapshot = supportedAllelesSnapshot(from: supported)
        for (index, item) in supported.enumerated() {
            let label = alleleDisplayLabel(
                for: item.sharedCall.genotype
            )
            let supportLabel =
                item.fraction.map(percent) ?? "Unavailable"
            stateRows.append(("Allele \(index + 1)", label))
            stateRows += [
                ("Locus", item.sharedCall.locus),
                (
                    "Unique Reads",
                    integer(item.support.passedUniqueReads)
                ),
                (
                    "Alignments",
                    integer(item.support.passedAlignments)
                ),
                ("Support", supportLabel),
            ]
        }
        let comments = matrixCommentDetailRows(for: targets)
        stateRows += comments

        guard let editor = makeManualHaplotypeEditorHost(
            for: sample
        ) else {
            showLegacySingleSampleColumnSelection(
                sample: sample,
                sampleRows: sampleRows,
                supported: supported,
                comments: comments
            )
            return
        }

        let header = makeSampleCurationHeader(
            sample: sample,
            summary: summary
        )
        let assignment = NSView()
        assignment.translatesAutoresizingMaskIntoConstraints = false
        editor.translatesAutoresizingMaskIntoConstraints = false
        assignment.addSubview(editor)
        NSLayoutConstraint.activate([
            editor.topAnchor.constraint(equalTo: assignment.topAnchor),
            editor.leadingAnchor.constraint(
                equalTo: assignment.leadingAnchor
            ),
            editor.trailingAnchor.constraint(
                equalTo: assignment.trailingAnchor
            ),
            editor.bottomAnchor.constraint(
                equalTo: assignment.bottomAnchor
            ),
        ])

        let evidence = makeSampleEvidenceColumn(
            snapshot: snapshot,
            comments: comments
        )
        let workbench = GenotypeSampleCurationWorkbenchView(
            headerView: header,
            assignmentView: assignment,
            evidenceView: evidence,
            typographyScale: currentContentTypographyScale()
        )
        sampleSupportedAllelesSnapshot = snapshot
        sampleCurationWorkbench = workbench
        detailStack.addArrangedSubview(workbench)
        sampleWorkbenchWidthConstraint =
            workbench.widthAnchor.constraint(
                equalTo: detailStack.widthAnchor
            )
        sampleWorkbenchWidthConstraint?.isActive = true
    }

    private func sortedVisibleSampleAlleleDetails(
        sample: String
    ) -> [GenotypeVisibleSampleAlleleDetail] {
        comparisonMatrix.visibleSampleAlleleDetails(sample: sample)
            .sorted { lhs, rhs in
                let locusOrder =
                    lhs.sharedCall.locus.localizedStandardCompare(
                        rhs.sharedCall.locus
                    )
                if locusOrder != .orderedSame {
                    return locusOrder == .orderedAscending
                }
                if lhs.sharedCall.locus != rhs.sharedCall.locus {
                    return lhs.sharedCall.locus
                        < rhs.sharedCall.locus
                }
                if lhs.support.passedUniqueReads
                    != rhs.support.passedUniqueReads {
                    return lhs.support.passedUniqueReads
                        > rhs.support.passedUniqueReads
                }
                let labelOrder =
                    alleleDisplayLabel(
                        for: lhs.sharedCall.genotype
                    ).localizedStandardCompare(
                        alleleDisplayLabel(
                            for: rhs.sharedCall.genotype
                        )
                    )
                if labelOrder != .orderedSame {
                    return labelOrder == .orderedAscending
                }
                return lhs.sharedCall.genotype
                    < rhs.sharedCall.genotype
            }
    }

    private func supportedAllelesSnapshot(
        from details: [GenotypeVisibleSampleAlleleDetail]
    ) -> GenotypeSupportedAllelesSnapshot {
        GenotypeSupportedAllelesSnapshot(
            rows: details.map { item in
                GenotypeSupportedAllelePresentation(
                    id: item.stableClusterID.map {
                        "candidate:\($0)"
                    } ?? "known:\(item.sharedCall.locus):"
                        + item.sharedCall.genotype,
                    allele: alleleDisplayLabel(
                        for: item.sharedCall.genotype
                    ),
                    locus: item.sharedCall.locus,
                    uniqueReads: integer(
                        item.support.passedUniqueReads
                    ),
                    alignments: integer(
                        item.support.passedAlignments
                    ),
                    support:
                        item.fraction.map(percent) ?? "Unavailable"
                )
            }
        )
    }

    private func showLegacySingleSampleColumnSelection(
        sample: String,
        sampleRows: [(String, String)],
        supported: [GenotypeVisibleSampleAlleleDetail],
        comments: [(String, String)]
    ) {
        detailStack.addArrangedSubview(
            sectionTitle("Selected Sample")
        )
        detailStack.addArrangedSubview(
            wrappingText(sample, weight: .medium)
        )
        detailStack.addArrangedSubview(detailRows(sampleRows))
        if !supported.isEmpty {
            detailStack.addArrangedSubview(
                sectionTitle("Supported Alleles")
            )
            let renderedEntries = supported.map { item in
                let label = alleleDisplayLabel(
                    for: item.sharedCall.genotype
                )
                let supportLabel =
                    item.fraction.map(percent) ?? "Unavailable"
                return "\(label)\nLocus: \(item.sharedCall.locus)"
                    + "  •  Unique Reads: "
                    + integer(item.support.passedUniqueReads)
                    + "  •  Alignments: "
                    + integer(item.support.passedAlignments)
                    + "  •  Support: \(supportLabel)"
            }
            detailStack.addArrangedSubview(
                wrappingText(
                    renderedEntries.joined(separator: "\n\n")
                )
            )
        }
        appendCommentsToDetail(comments)
    }

    private func makeSampleCurationHeader(
        sample: String,
        summary: ONTGenotypeSampleResult?
    ) -> NSView {
        var metrics = [
            GenotypeSampleCurationHeaderView.Metric(
                label: "Selected Sample",
                value: sample,
                emphasized: true
            ),
        ]
        if let summary {
            metrics += [
                .init(
                    label: "Retained Unique Reads",
                    value: integer(summary.passedUniqueReads)
                ),
                .init(
                    label: "Alignments",
                    value: integer(summary.passedAlignments)
                ),
                .init(
                    label: "QC",
                    value: summary.qcStatus.displayName
                ),
            ]
        }
        return GenotypeSampleCurationHeaderView(
            metrics: metrics,
            typographyScale: currentContentTypographyScale()
        )
    }

    private func makeSampleEvidenceColumn(
        snapshot: GenotypeSupportedAllelesSnapshot,
        comments: [(String, String)]
    ) -> NSView {
        let evidence = NSStackView()
        evidence.orientation = .vertical
        evidence.alignment = .width
        evidence.spacing = 12
        evidence.setContentCompressionResistancePriority(
            .defaultLow,
            for: .horizontal
        )

        let panel = NSHostingView(
            rootView: GenotypeSupportedAllelesPanel(
                snapshot: snapshot,
                typographyModel:
                    manualHaplotypeEditorTypographyModel
            )
        )
        panel.identifier = Self.generatedContentHostingViewIdentifier
        panel.translatesAutoresizingMaskIntoConstraints = false
        panel.sizingOptions = [.intrinsicContentSize]
        panel.setContentHuggingPriority(
            .defaultLow,
            for: .horizontal
        )
        panel.setContentCompressionResistancePriority(
            .defaultLow,
            for: .horizontal
        )
        evidence.addArrangedSubview(panel)

        if !comments.isEmpty {
            evidence.addArrangedSubview(sectionTitle("Comments"))
            evidence.addArrangedSubview(detailRows(comments))
        }
        return evidence
    }

    private func currentContentTypographyScale() -> CGFloat {
        let canonical = max(NSFont.systemFontSize, 1)
        return manualHaplotypeEditorTypographyModel.scaledPointSize(
            fromCanonicalPointSize: canonical
        ) / canonical
    }

    private func showCellSelection(_ targets: [GenotypeAnnotationSidecar.MatrixTarget]) {
        legacyNonRowDetailBuildCount += 1
        currentSharedCall = nil
        currentCandidateRow = nil
        currentSelectedSample = nil
        let cells = targets.compactMap { target -> (target: GenotypeAnnotationSidecar.MatrixTarget, locus: String, genotype: String, sample: String, stableClusterID: String?)? in
            guard case let .cell(locus, genotype, sample, stableClusterID) = target else { return nil }
            return (target, locus, genotype, sample, stableClusterID)
        }.sorted { lhs, rhs in
            let lhsLabel = alleleDisplayLabel(for: lhs.genotype)
            let rhsLabel = alleleDisplayLabel(for: rhs.genotype)
            let labelOrder = lhsLabel.localizedStandardCompare(rhsLabel)
            if labelOrder != .orderedSame {
                return labelOrder == .orderedAscending
            }
            let locusOrder = lhs.locus.localizedStandardCompare(rhs.locus)
            if locusOrder != .orderedSame { return locusOrder == .orderedAscending }
            if lhs.locus != rhs.locus { return lhs.locus < rhs.locus }
            if lhs.genotype != rhs.genotype { return lhs.genotype < rhs.genotype }
            let sampleOrder = lhs.sample.localizedStandardCompare(rhs.sample)
            return sampleOrder == .orderedSame ? lhs.sample < rhs.sample : sampleOrder == .orderedAscending
        }
        removeArrangedSubviews(from: detailStack)
        detailStack.addArrangedSubview(sectionTitle(cells.count == 1 ? "Selected Cell" : "Selected Cells: \(cells.count)"))
        var stateRows: [(String, String)] = [
            ("Selection Type", cells.count == 1 ? "Cell" : "Cells"),
        ]
        if cells.count == 1, let cell = cells.first {
            stateRows.append(("Selected Sample", cell.sample))
        }
        var renderedEntries: [String] = []
        renderedEntries.reserveCapacity(cells.count)
        for (index, cell) in cells.enumerated() {
            let label = alleleDisplayLabel(for: cell.genotype)
            var rows: [(String, String)] = [("Sample", cell.sample), ("Allele", label)]
            if label != cell.genotype {
                rows.append(("Reference Sequence", cell.genotype))
            }
            rows.append(("Locus", cell.locus))
            if let stableClusterID = cell.stableClusterID {
                rows.append(("Cluster ID", stableClusterID))
            }
            if let support = sampleSupportByCellKey[
                CellEvidenceKey(locus: cell.locus, genotype: cell.genotype, sample: cell.sample)
            ] {
                let fraction = comparisonMatrix.cachedSupportFraction(
                    locus: cell.locus, genotype: cell.genotype, sample: cell.sample
                )
                rows += [
                    ("Unique Reads", integer(support.passedUniqueReads)),
                    ("Alignments", integer(support.passedAlignments)),
                    ("Support", fraction.map(percent) ?? "Unavailable"),
                ]
                rows += genBankFieldRows(for: cell.genotype)
            } else {
                rows.append(("Evidence", "No supporting reads"))
            }
            if cells.count == 1 {
                detailStack.addArrangedSubview(wrappingText(label, weight: .medium))
                detailStack.addArrangedSubview(wrappingText(cell.sample))
                detailStack.addArrangedSubview(detailRows(rows))
            } else {
                renderedEntries.append(compactSelectionEntry(label: label, rows: rows))
            }
            if cells.count > 1 {
                stateRows.append(("Cell \(index + 1)", "\(label) — \(cell.sample)"))
            }
            stateRows += rows
        }
        if cells.count > 1, !renderedEntries.isEmpty {
            detailStack.addArrangedSubview(wrappingText(renderedEntries.joined(separator: "\n\n")))
        }
        let commentTargets = applicableCommentTargets(for: targets)
        let comments = matrixCommentDetailRows(for: commentTargets)
        appendCommentsToDetail(comments)
        stateRows += comments
        publishSelectionState(GenotypeResultSelectionState(
            title: cells.count == 1 ? (cells.first.map { "\(alleleDisplayLabel(for: $0.genotype)) — \($0.sample)" } ?? "Selected Cell") : "Selected Cells: \(cells.count)",
            subtitle: "Matrix evidence",
            detailRows: stateRows,
            highlightTarget: nil,
            matrixTargets: targets
        ))
    }

    private func appendCommentsToDetail(_ rows: [(String, String)]) {
        guard !rows.isEmpty else { return }
        detailStack.addArrangedSubview(sectionTitle("Comments"))
        detailStack.addArrangedSubview(detailRows(rows))
    }

    private func compactSelectionEntry(label: String, rows: [(String, String)]) -> String {
        ([label] + rows.map { "\($0.0): \($0.1)" }).joined(separator: "\n")
    }

    private func sharedCalls(
        for targets: [GenotypeAnnotationSidecar.MatrixTarget]
    ) -> [ONTGenotypeSharedCall] {
        return targets.compactMap { target in
            guard case let .row(locus, genotype, stableClusterID) = target,
                  stableClusterID == nil else { return nil }
            return sharedCallsByKey[SharedCallKey(locus: locus, genotype: genotype)]
        }.sorted { lhs, rhs in
            let locusOrder = lhs.locus.localizedStandardCompare(rhs.locus)
            if locusOrder != .orderedSame {
                return locusOrder == .orderedAscending
            }
            if lhs.locus != rhs.locus { return lhs.locus < rhs.locus }
            let labelOrder = alleleDisplayLabel(for: lhs.genotype).localizedStandardCompare(
                alleleDisplayLabel(for: rhs.genotype)
            )
            if labelOrder != .orderedSame { return labelOrder == .orderedAscending }
            return lhs.genotype < rhs.genotype
        }
    }

    private func referenceRecord(for genotype: String) -> [String: String]? {
        result?.referenceMetadata?.recordsBySequenceName[genotype]
    }

    private func alleleDisplayLabel(for genotype: String) -> String {
        guard let metadata = result?.referenceMetadata,
              let key = metadata.alleleFieldKey,
              let value = metadata.recordsBySequenceName[genotype]?[key]?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else {
            return genotype
        }
        return value
    }

    private func genBankFieldRows(for genotype: String) -> [(String, String)] {
        guard let metadata = result?.referenceMetadata,
              let record = referenceRecord(for: genotype) else { return [] }
        return metadata.fields.compactMap { field in
            guard let value = record[field.key]?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !value.isEmpty else { return nil }
            return (field.displayTitle, value)
        }
    }

    private func applicableCommentTargets(
        for targets: [GenotypeAnnotationSidecar.MatrixTarget]
    ) -> [GenotypeAnnotationSidecar.MatrixTarget] {
        var expanded = targets
        for target in targets {
            guard case let .cell(locus, genotype, sample, stableClusterID) = target else { continue }
            expanded.append(.row(
                locus: locus,
                genotype: genotype,
                stableClusterID: stableClusterID
            ))
            expanded.append(.column(sample: sample))
        }
        return uniqueMatrixTargets(expanded)
    }

    private func matrixTargetSelectionState(
        for targets: [GenotypeAnnotationSidecar.MatrixTarget]
    ) -> GenotypeResultSelectionState {
        let title = targets.count == 1
            ? matrixTargetTitle(targets[0])
            : "\(targets.count) Matrix Targets"
        return GenotypeResultSelectionState(
            title: title,
            subtitle: "Matrix annotations",
            detailRows: matrixTargetDetailRows(for: targets) + matrixCommentDetailRows(for: targets),
            highlightTarget: nil,
            matrixTargets: targets
        )
    }

    private func matrixTargetTitle(_ target: GenotypeAnnotationSidecar.MatrixTarget) -> String {
        switch target {
        case let .row(locus, genotype, stableClusterID):
            return "\(locus) \(genotype)" + (stableClusterID.map { " [\($0)]" } ?? "")
        case let .column(sample):
            return sample
        case let .cell(locus, genotype, sample, stableClusterID):
            return "\(sample) \(locus) \(genotype)" + (stableClusterID.map { " [\($0)]" } ?? "")
        }
    }

    private func matrixTargetDetailRows(
        for targets: [GenotypeAnnotationSidecar.MatrixTarget]
    ) -> [(String, String)] {
        if targets.count == 1, let target = targets.first {
            switch target {
            case let .row(locus, genotype, stableClusterID):
                return [("Selection Type", "Row"), ("Locus", locus), ("Genotype", genotype)]
                    + (stableClusterID.map { [("Cluster ID", $0)] } ?? [])
            case let .column(sample):
                return [("Selection Type", "Column"), ("Sample", sample)]
            case let .cell(locus, genotype, sample, stableClusterID):
                return [("Selection Type", "Cell"), ("Sample", sample), ("Locus", locus), ("Genotype", genotype)]
                    + (stableClusterID.map { [("Cluster ID", $0)] } ?? [])
            }
        }
        return [
            ("Selection Type", matrixTargetTypeLabel(for: targets)),
            ("Targets", "\(targets.count)"),
            ("Selection", targets.map(matrixTargetSummary).joined(separator: ", ")),
        ]
    }

    private func matrixTargetTypeLabel(for targets: [GenotypeAnnotationSidecar.MatrixTarget]) -> String {
        let types = Set(targets.map { target in
            switch target {
            case .row: return "Row"
            case .column: return "Column"
            case .cell: return "Cell"
            }
        })
        if types.count == 1, let type = types.first {
            return targets.count == 1 ? type : type + "s"
        }
        return "Mixed"
    }

    private func matrixTargetSummary(_ target: GenotypeAnnotationSidecar.MatrixTarget) -> String {
        switch target {
        case let .row(locus, genotype, stableClusterID):
            return "\(locus) \(genotype)" + (stableClusterID.map { " [\($0)]" } ?? "")
        case let .column(sample):
            return sample
        case let .cell(locus, genotype, sample, stableClusterID):
            return "\(sample) \(locus) \(genotype)" + (stableClusterID.map { " [\($0)]" } ?? "")
        }
    }

    private func selectionState(
        for sharedCall: ONTGenotypeSharedCall,
        sample: String?,
        matrixTargets providedMatrixTargets: [GenotypeAnnotationSidecar.MatrixTarget]? = nil,
        providedCommentRows: [(String, String)]? = nil
    ) -> GenotypeResultSelectionState {
        let displayLabel = alleleDisplayLabel(for: sharedCall.genotype)
        var rows: [(String, String)] = [("Allele", displayLabel)]
        if let sample {
            rows.append(("Sample", sample))
        }
        if displayLabel != sharedCall.genotype {
            rows.append(("Reference Sequence", sharedCall.genotype))
        }
        rows.append(("Locus", sharedCall.locus))
        if let aliases = sharedCall.aliasDisplay {
            rows.append(("Aliases", aliases))
        }
        rows += genBankFieldRows(for: sharedCall.genotype)
        let matrixTargets = providedMatrixTargets ?? [
            sample.map {
                GenotypeAnnotationSidecar.MatrixTarget.cell(
                    locus: sharedCall.locus,
                    genotype: sharedCall.genotype,
                    sample: $0
                )
            } ?? .row(locus: sharedCall.locus, genotype: sharedCall.genotype),
        ]
        rows.insert(("Selection Type", matrixTargetTypeLabel(for: matrixTargets)), at: 0)
        rows += providedCommentRows
            ?? matrixCommentDetailRows(for: applicableCommentTargets(for: matrixTargets))
        let target = GenotypeResultHighlightTarget(
            genotype: sharedCall.genotype,
            locus: sharedCall.locus,
            sample: sample,
            stableClusterID: matrixTargets.first(where: { $0.stableClusterID != nil })?.stableClusterID
        )
        let style = comparisonMatrix.highlightStyle(for: target)
        return GenotypeResultSelectionState(
            title: displayLabel,
            subtitle: "\(sharedCall.locus) known allele",
            detailRows: rows,
            highlightTarget: target,
            highlightStyle: style,
            matrixTargets: matrixTargets
        )
    }

    private func matrixCommentDetailRows(
        for sharedCall: ONTGenotypeSharedCall,
        sample: String?,
        matrixTargets: [GenotypeAnnotationSidecar.MatrixTarget]
    ) -> [(String, String)] {
        var targets = matrixTargets
        for target in matrixTargets {
            switch target {
            case let .row(locus, genotype, stableClusterID),
                 let .cell(locus, genotype, _, stableClusterID):
                if let stableClusterID {
                    targets.append(.row(
                        locus: locus,
                        genotype: genotype,
                        stableClusterID: stableClusterID
                    ))
                }
            case .column:
                break
            }
        }
        let rowTarget = GenotypeAnnotationSidecar.MatrixTarget.row(
            locus: sharedCall.locus,
            genotype: sharedCall.genotype
        )
        targets.append(rowTarget)
        if let sample {
            let columnTarget = GenotypeAnnotationSidecar.MatrixTarget.column(sample: sample)
            targets.append(columnTarget)
        }
        return matrixCommentDetailRows(for: targets)
    }

    private func matrixCommentDetailRows(
        for targets: [GenotypeAnnotationSidecar.MatrixTarget]
    ) -> [(String, String)] {
        uniqueMatrixTargets(targets).compactMap { target in
            guard let comment = matrixCommentsByTarget[target] else { return nil }
            return (matrixCommentLabel(for: target), comment.body)
        }
    }

    private func matrixCommentLabel(for target: GenotypeAnnotationSidecar.MatrixTarget) -> String {
        switch target {
        case .row:
            return "Row Comment"
        case .column:
            return "Column Comment"
        case .cell:
            return "Cell Comment"
        }
    }

    private func publishSelectionState(_ state: GenotypeResultSelectionState?) {
        currentSelectionState = state
        publishMatrixReviewCapability(for: state?.matrixTargets ?? [])
        refreshGeneratedDetailTypographyIfNeeded()
        onSelectionStateChanged?(state)
    }

    private func refreshGeneratedDetailTypographyIfNeeded() {
        let fields = generatedDetailTextFields(in: detailStack)
        guard !fields.isEmpty else {
            styledGeneratedDetailFields = []
            return
        }
        let fieldsAreAlreadyStyled = fields.count == styledGeneratedDetailFields.count
            && zip(fields, styledGeneratedDetailFields).allSatisfy { pair in
                pair.0 === pair.1
            }
        guard !fieldsAreAlreadyStyled else { return }
        styledGeneratedDetailFields = fields
        detailContentTypographyObservation?.refresh()
    }

    private func rebuildHaplotypeLens() {
        haplotypeLensBuildCount += 1
        defer { refreshGeneratedContentTypography(in: haplotypeStack) }
        removeArrangedSubviews(from: haplotypeStack)
        haplotypeSampleActionTags.removeAll()
        nextHaplotypeSampleActionTag = 1
        guard result != nil else { return }
        haplotypeStack.addArrangedSubview(sectionTitle("Deterministic Haplotype Review"))
        guard let analysis = activeHaplotypeAnalysis() else {
            haplotypeStack.addArrangedSubview(caption("No haplotype definition was selected for this genotype result. Deterministic haplotyping is not inferred automatically."))
            return
        }

        let reviewSamples = analysis.samples.filter(haplotypeSampleNeedsReview)
        haplotypeStack.addArrangedSubview(detailRows([
            ("Definition", analysis.definitionSetName),
            ("Assay", analysis.assayID),
            ("Samples", "\(analysis.samples.count)"),
            ("Review", "\(reviewSamples.count)"),
        ]))
        haplotypeStack.addArrangedSubview(caption("Calls are deterministic matches against the selected assay definition. Review samples are those with too many haplotypes/genotypes, no matching definition, or extra observed genotype labels."))

        if analysis.samples.isEmpty {
            haplotypeStack.addArrangedSubview(caption("No assigned samples were available for haplotype review."))
            return
        }

        let sortedSamples = analysis.samples.sorted { lhs, rhs in
            let lhsNeedsReview = haplotypeSampleNeedsReview(lhs)
            let rhsNeedsReview = haplotypeSampleNeedsReview(rhs)
            if lhsNeedsReview != rhsNeedsReview {
                return lhsNeedsReview && !rhsNeedsReview
            }
            return lhs.sample.localizedStandardCompare(rhs.sample) == .orderedAscending
        }

        for sample in sortedSamples.prefix(80) {
            haplotypeStack.addArrangedSubview(haplotypeSampleRow(sample))
        }
        if analysis.samples.count > 80 {
            haplotypeStack.addArrangedSubview(caption("\(analysis.samples.count - 80) additional samples are hidden in this summary."))
        }
    }

    private func rebuildConsumerLens() {
        consumerLensBuildCount += 1
        defer { refreshGeneratedContentTypography(in: consumerStack) }
        removeArrangedSubviews(from: consumerStack)
        guard let result else { return }
        let qcCounts = result.qcStatusCounts

        consumerStack.addArrangedSubview(sectionTitle("Run Summary"))
        consumerStack.addArrangedSubview(detailRows([
            ("Run", result.manifest.analysisName),
            ("Samples", "\(result.sampleCount)"),
            ("Usable", "\(qcCounts[.ok, default: 0])"),
            ("Needs Review", "\(qcCounts[.review, default: 0] + qcCounts[.lowSupport, default: 0])"),
            ("Retained Reads", integer(result.stats.retainedUniqueReads)),
            ("Assigned Retained", integer(result.stats.assignedUniqueRetainedReads)),
        ]))

        consumerStack.addArrangedSubview(sectionTitle("Locus Summary"))
        if result.locusSummaries.isEmpty {
            consumerStack.addArrangedSubview(caption("No assigned genotype calls were found in this bundle."))
        } else {
            for summary in result.locusSummaries {
                consumerStack.addArrangedSubview(locusSummaryRow(summary))
            }
        }

        consumerStack.addArrangedSubview(sectionTitle("Interpretation"))
        consumerStack.addArrangedSubview(caption("Shared rows indicate shared support for the same reference label. They do not by themselves prove phased haplotypes, zygosity, copy number, allele absence, or inherited identity."))
    }

    private func rebuildAnchorLens() {
        anchorLensBuildCount += 1
        defer { refreshGeneratedContentTypography(in: anchorStack) }
        removeArrangedSubviews(from: anchorStack)
        guard let result else { return }
        let anchors = anchorSummaries(in: result)
        anchorStack.addArrangedSubview(sectionTitle("Anchor-Oriented Review"))
        anchorStack.addArrangedSubview(caption("Anchor groups are derived from source labels and sample-level co-observation. They are not phased haplotype calls, zygosity calls, copy-number calls, absence calls, or inheritance assertions."))
        if anchors.isEmpty {
            anchorStack.addArrangedSubview(caption("No genotype calls are available for anchor review."))
            return
        }
        for anchor in anchors.prefix(40) {
            anchorStack.addArrangedSubview(anchorSummaryRow(anchor))
        }
        if anchors.count > 40 {
            anchorStack.addArrangedSubview(caption("\(anchors.count - 40) additional anchors are hidden in this summary. Use the Analyst matrix for full row-level review."))
        }
    }

    private func rebuildArtifactLens() {
        artifactLensBuildCount += 1
        defer { refreshGeneratedContentTypography(in: artifactStack) }
        removeArrangedSubviews(from: artifactStack)
        guard let result else { return }
        if let entries = annotationStore?.sidecar.auditLog, !entries.isEmpty {
            addAuditSection(title: "Audit Timeline", contents: [makeAuditTimelineHost(entries: entries)])
        }
        addAuditSection(title: "Share View", contents: [exportViewButton()])
        addAuditSection(title: "AI Haplotyping", contents: [makeAIHaplotypingHost()])
        addAuditSection(title: "Current Workbook", contents: [makeCurrentWorkbookUpdateHost()])
        var artifactRows: [NSView] = [
            artifactRow(label: "Workbook", url: result.artifacts.workbookURL),
        ]
        if result.artifacts.primaryWorkbookURL != result.artifacts.workbookURL {
            artifactRows.append(artifactRow(
                label: "Original Workbook",
                url: result.artifacts.primaryWorkbookURL
            ))
        }
        artifactRows += [
            artifactRow(label: "Long Summary CSV", url: result.artifacts.longSummaryCSVURL),
            artifactRow(label: "Sample Summary CSV", url: result.artifacts.sampleSummaryCSVURL),
            artifactRow(label: "Run Stats JSON", url: result.artifacts.statsJSONURL),
            artifactRow(label: "Provenance", url: result.artifacts.provenanceURL),
        ]
        if let fastaURL = result.artifacts.deduplicatedUnmatchedClustersFASTAURL {
            artifactRows.append(artifactRow(label: "Deduplicated Unmatched FASTA", url: fastaURL))
        }
        let candidateGenBankURLs = result.mhcCandidateGenBankArtifactURLs
        if let candidateURL = candidateGenBankURLs.candidateFASTA {
            artifactRows.append(artifactRow(label: "Candidate Alleles FASTA", url: candidateURL))
        }
        if let unnameableURL = candidateGenBankURLs.unnameableFASTA {
            artifactRows.append(artifactRow(label: "Un-nameable Clusters FASTA", url: unnameableURL))
        }
        if let candidateURL = candidateGenBankURLs.candidateAlleles {
            artifactRows.append(artifactRow(label: "Candidate Alleles GenBank", url: candidateURL))
        }
        if let unnameableURL = candidateGenBankURLs.unnameableClusters {
            artifactRows.append(artifactRow(label: "Un-nameable Clusters GenBank", url: unnameableURL))
        }
        let alignmentArtifactURLs = result.alignmentArtifactURLs
        if let genotypingBAMURL = alignmentArtifactURLs.genotypingBAM {
            artifactRows.append(artifactRow(label: "Genotyping Evidence BAM", url: genotypingBAMURL))
        }
        if let genotypingBAIURL = alignmentArtifactURLs.genotypingBAI {
            artifactRows.append(artifactRow(label: "Genotyping Evidence BAI", url: genotypingBAIURL))
        }
        if result.manifest.kind == "full-length-ont-mhc-genotype",
           let reciprocalBAMURL = alignmentArtifactURLs.reciprocalBAM {
            artifactRows.append(artifactRow(label: "Reciprocal Evidence BAM", url: reciprocalBAMURL))
        }
        if result.manifest.kind == "full-length-ont-mhc-genotype",
           let reciprocalBAIURL = alignmentArtifactURLs.reciprocalBAI {
            artifactRows.append(artifactRow(label: "Reciprocal Evidence BAI", url: reciprocalBAIURL))
        }
        if !hasHaplotypingResult,
           let catalogURL = result.provisionalExon2ArtifactURLs.catalogJSON {
            artifactRows.append(artifactRow(
                label: "Observed Provisional Exon 2 JSON",
                url: catalogURL
            ))
        }
        if !hasHaplotypingResult,
           let fastaURL = result.provisionalExon2ArtifactURLs.sequencesFASTA {
            artifactRows.append(artifactRow(
                label: "Observed Provisional Exon 2 FASTA",
                url: fastaURL
            ))
        }
        if let haplotypeAnalysisURL = result.artifacts.haplotypeAnalysisURL {
            artifactRows.append(artifactRow(label: "Haplotype Analysis", url: haplotypeAnalysisURL))
        }
        addAuditSection(title: "Bundle Artifacts", contents: artifactRows)

        if manualHaplotypingIsAvailable(result: result) {
            addAuditSection(
                title: "Manual Haplotyping",
                contents: [makeManualHaplotypingHost()]
            )
        } else if result.haplotypeAnalysis == nil,
                  let reason = manualHaplotypeDisabledReason {
            addAuditSection(
                title: "Manual Haplotyping",
                contents: [caption(reason)]
            )
        }
        addAuditSection(title: "Haplotype Thresholds", contents: [makeRunHaplotypeThresholdSummaryHost()])
        addAuditSection(title: "Haplotype Definition", contents: [makeActiveHaplotypeDefinitionRow()])
    }

    private func makeAIHaplotypingHost() -> NSView {
        let stack = NSStackView()
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6

        let isReadOnly = annotationStore?.isReadOnly ?? false
        let hasAnalysis = activeHaplotypeAnalysis() != nil
        let statusText: String
        if let aiHaplotypingStatus {
            statusText = aiHaplotypingStatus
        } else if isReadOnly {
            statusText = "Bundle is read-only. Save a writable copy to run AI haplotyping."
        } else if hasAnalysis {
            statusText = "Run AI discovery from raw genotype observations or refine the active haplotype calls."
        } else {
            statusText = "Run AI discovery from raw genotype observations. Refinement becomes available after a current analysis exists."
        }
        stack.addArrangedSubview(caption(statusText))
        stack.addArrangedSubview(caption("AI revisions write finalized haplotype calls and are marked for manual review."))

        let row = NSStackView()
        row.translatesAutoresizingMaskIntoConstraints = false
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 8

        let discoveryButton = NSButton(title: "AI Discovery", target: self, action: #selector(runAIHaplotypingDiscovery))
        discoveryButton.bezelStyle = .rounded
        discoveryButton.controlSize = .small
        discoveryButton.isEnabled = !isReadOnly
        discoveryButton.toolTip = "Infer haplotype calls from genotype evidence without using deterministic definitions."
        row.addArrangedSubview(discoveryButton)

        let refinementButton = NSButton(title: "AI Refinement", target: self, action: #selector(runAIHaplotypingRefinement))
        refinementButton.bezelStyle = .rounded
        refinementButton.controlSize = .small
        refinementButton.isEnabled = hasAnalysis && !isReadOnly
        refinementButton.toolTip = "Ask AI to refine the active deterministic, manual, or AI haplotype analysis."
        row.addArrangedSubview(refinementButton)

        stack.addArrangedSubview(row)
        return stack
    }

    @objc private func runAIHaplotypingDiscovery() {
        requestAIHaplotyping(mode: .aiDiscovery)
    }

    @objc private func runAIHaplotypingRefinement() {
        requestAIHaplotyping(mode: .aiRefinement)
    }

    private func requestAIHaplotyping(mode: GenotypeAIHaplotypingUIMode) {
        guard let result else { return }
        guard let onAIHaplotypingRequested else {
            aiHaplotypingStatus = "AI haplotyping is not available in this app context."
            rebuildArtifactLens()
            return
        }
        aiHaplotypingStatus = "Queued \(mode.displayName) in Operations Panel."
        rebuildArtifactLens()
        onAIHaplotypingRequested(result.bundleURL, GenotypeAIHaplotypingUIRequest(mode: mode))
    }

    public func applyAIHaplotypingCompleted(result updatedResult: ONTGenotypeResultBundleData) {
        if requiresManualHaplotypeTransitionCoordination {
            deferManualHaplotypeTransition(.eligibilityChange) {
                [weak self] in
                self?.applyAIHaplotypingCompleted(result: updatedResult)
            }
            return
        }
        teardownSampleCurationWorkbench()
        result = updatedResult
        manualHaplotypeEligibility =
            GenotypeManualHaplotypeEligibility.evaluate(updatedResult)
        hasHaplotypingResult = updatedResult.haplotypeAnalysis != nil
        if hasHaplotypingResult {
            provisionalExon2SequenceRecordsByGenotype = [:]
        } else {
            provisionalExon2SequenceRecordsByGenotype =
                updatedResult.provisionalExon2SequencesByGenotype.mapValues(
                    GenotypeAlleleSequenceRecord.provisionalExon2
                )
            provisionalExon2SequenceRecordBuildCount +=
                provisionalExon2SequenceRecordsByGenotype.count
        }
        renderedAlleleSequenceRecordIdentities = []
        alleleSequenceDetailView.clear()
        quickFilterBar.configureSearchCapability(
            hasHaplotypingResult: hasHaplotypingResult
        )
        invalidateGenotypeSearchIndex()
        applyViewportHeaderVisibility()
        liveHaplotypeAnalysis = nil
        comparisonMatrixConfigured = false
        rebuildResultIndexes(for: updatedResult)
        annotationStore = try? GenotypeAnnotationStore(
            bundleURL: updatedResult.bundleURL,
            author: annotationAuthorProvider(),
            seedBuiltInSmartCohorts: updatedResult.haplotypeAnalysis != nil
        )
        rebuildMatrixAnnotationIndexes()
        publishMatrixReviewCapability(for: currentSelectionState?.matrixTargets ?? [])
        displayState.summaryViewMode = initialSummaryViewMode(for: updatedResult)
        aiHaplotypingStatus = "AI haplotype revision created. Calls require manual review."
        if hasHaplotypingResult {
            rebuildActiveHaplotypeAnalysisIndexes()
            rebuildHaplotypeLens()
            rebuildOutline()
            rebuildHaplotypeMatrix()
            rebuildCohortSummary()
        } else {
            activeSmartCohort = nil
            quickFilterBar.setSavedCohortName(nil)
            displayState = displayState.normalized(forGenotypeOnlyResult: isGenotypeOnlyResult)
            clearUnsupportedHaplotypePresentation()
        }
        rebuildArtifactLens()
        if hasHaplotypingResult, selectedLens == .summary {
            applySummaryViewModeVisibility()
        } else if !hasHaplotypingResult {
            showLens(.summary)
        }
        onDisplayStateChanged?(displayState)
        if let sidecar = annotationStore?.sidecar {
            onAnnotationSidecarChanged?(sidecar)
        }
    }

    public func applyAIHaplotypingFailed(_ error: Error) {
        aiHaplotypingStatus = "AI haplotyping failed — see Operations Panel."
        rebuildArtifactLens()
    }

    private func makeCurrentWorkbookUpdateHost() -> NSView {
        let stack = NSStackView()
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6

        let statusText = displayedCurrentWorkbookStatus
            ?? "Checking whether current.xlsx represents the latest LGE review state."

        stack.addArrangedSubview(caption(statusText))
        stack.addArrangedSubview(caption("Regenerates the bundle workbook from displayed haplotype calls and matrix annotations, then records a workbook revision."))

        let button = NSButton(
            title: Self.currentWorkbookActionTitle,
            target: self,
            action: #selector(updateCurrentWorkbookFromOverrides)
        )
        button.bezelStyle = .rounded
        button.controlSize = .small
        button.isEnabled = currentWorkbookActionIsEnabled
        button.toolTip = "Open current.xlsx immediately when current; otherwise update it once and open the successful revision."
        stack.addArrangedSubview(button)
        return stack
    }

    private static let currentWorkbookActionTitle =
        "Update and View Current Excel Version"

    private var displayedCurrentWorkbookStatus: String? {
        if showsDeferredMatrixAnnotationStatus {
            return Self.deferredMatrixAnnotationStatus
        }
        if let currentWorkbookSyncPhase {
            return currentWorkbookSyncPhase.presentation(
                isReadOnly: currentWorkbookIsReadOnly,
                manualChangeCount: currentWorkbookRelevantChangeCount
            ).statusText
        }
        return currentWorkbookUpdateStatus
    }

    private var currentWorkbookActionIsEnabled: Bool {
        if let currentWorkbookSyncPhase {
            return currentWorkbookSyncPhase.presentation(
                isReadOnly: currentWorkbookIsReadOnly,
                manualChangeCount: currentWorkbookRelevantChangeCount
            ).isEnabled
        }
        return (currentWorkbookRelevantChangeCount > 0 || currentWorkbookNeedsRefresh)
            && !currentWorkbookIsReadOnly
    }

    private var currentWorkbookRelevantChangeCount: Int {
        let candidateProjection = result?.manifest.mhcCandidateArtifacts == nil ? 0 : 1
        guard let sidecar = annotationStore?.sidecar else { return candidateProjection }
        return sidecar.callOverrides.count
            + sidecar.manualHaplotypeAssignments.count
            + sidecar.matrixStyles.count
            + sidecar.matrixReviews.count
            + sidecar.matrixComments.count
            + candidateProjection
    }

    private var currentWorkbookHasMatrixAnnotations: Bool {
        guard let sidecar = annotationStore?.sidecar else { return false }
        return !sidecar.matrixStyles.isEmpty
            || !sidecar.matrixReviews.isEmpty
            || !sidecar.matrixComments.isEmpty
    }

    private var currentWorkbookRelevantChangeLabel: String {
        let count = currentWorkbookRelevantChangeCount
        if currentWorkbookHasMatrixAnnotations {
            return count == 1 ? "workbook annotation change" : "workbook annotation changes"
        }
        return count == 1 ? "manual haplotype change" : "manual haplotype changes"
    }

    private func scheduleCurrentWorkbookUpdateForMatrixAnnotation() {
        markCurrentWorkbookDirty(
            requiresFullUpdate: false,
            legacyStatus: "current.xlsx does not include workbook annotation changes."
        )
    }

    @objc private func updateCurrentWorkbookFromOverrides() {
        requestCurrentWorkbookSync(intent: .updateAndView)
    }

    public func requestCurrentWorkbookRegistration() {
        emitCurrentWorkbookRequest(action: .register)
    }

    public func requestCurrentWorkbookSyncForBundleSwitch() {
        emitCurrentWorkbookRequest(action: .synchronize(.bundleSwitch))
    }

    public func applyCurrentWorkbookSyncPhase(
        _ phase: GenotypeCurrentWorkbookUIPhase,
        isReadOnly: Bool
    ) {
        currentWorkbookSyncPhase = phase
        currentWorkbookIsReadOnly = isReadOnly
        switch phase {
        case .current:
            currentWorkbookNeedsRefresh = false
        case .dirty, .dirtyWhileUpdating, .failed:
            currentWorkbookNeedsRefresh = true
        case .updating:
            break
        }
        rebuildArtifactLens()
    }

    private func requestCurrentWorkbookSync(intent: GenotypeCurrentWorkbookSyncIntent) {
        emitCurrentWorkbookRequest(action: .synchronize(intent))
    }

    private func markCurrentWorkbookDirty(
        requiresFullUpdate: Bool,
        legacyStatus: String
    ) {
        guard result != nil, !(annotationStore?.isReadOnly ?? true) else { return }
        testingCurrentWorkbookDirtyMarkCount += 1
        currentWorkbookNeedsRefresh = true
        currentWorkbookRequiresFullUpdate =
            currentWorkbookRequiresFullUpdate || requiresFullUpdate
        currentWorkbookUpdateStatus = legacyStatus
        currentWorkbookSyncPhase = .dirty
        rebuildArtifactLens()
        emitCurrentWorkbookRequest(action: .markDirty)
    }

    private func emitCurrentWorkbookRequest(
        action: GenotypeCurrentWorkbookUIRequest.Action
    ) {
        guard let snapshot = currentWorkbookUISnapshot() else { return }
        onCurrentWorkbookSyncRequested?(.init(snapshot: snapshot, action: action))
    }

    private func currentWorkbookUISnapshot() -> GenotypeCurrentWorkbookUISnapshot? {
        guard let result, let store = annotationStore else { return nil }
        let annotationURL = ONTGenotypeResultBundleData.annotationSidecarURL(
            forBundleAt: result.bundleURL
        )
        do {
            return try GenotypeCurrentWorkbookUISnapshot.encodingAnnotationSidecar(
                bundleURL: result.bundleURL,
                calls: currentWorkbookEffectiveHaplotypeCalls(),
                includedLoci: currentWorkbookIncludedLoci(),
                annotationSidecar: store.sidecar,
                annotationSidecarURL: annotationURL,
                candidateArtifacts: result.manifest.mhcCandidateArtifacts,
                reviewableRowCatalog: result.manifest.reviewableRowCatalog,
                reviewableRowCatalogSchemaVersion:
                    result.reviewableRowCatalog?.schemaVersion,
                annotationOnly: !currentWorkbookRequiresFullUpdate,
                isReadOnly: store.isReadOnly,
                haplotypeProjectionMode:
                    currentWorkbookHaplotypeProjectionMode()
            )
        } catch {
            currentWorkbookNeedsRefresh = true
            currentWorkbookSyncPhase = .failed(
                "Could not encode annotations for current.xlsx: \(error.localizedDescription)"
            )
            rebuildArtifactLens()
            return nil
        }
    }

    public func applyCurrentWorkbookUpdateCompleted(
        result updatedResult: ONTGenotypeResultBundleData,
        annotationOnly: Bool = false
    ) {
        if requiresManualHaplotypeTransitionCoordination {
            deferManualHaplotypeTransition(.reload) { [weak self] in
                self?.applyCurrentWorkbookUpdateCompleted(
                    result: updatedResult,
                    annotationOnly: annotationOnly
                )
            }
            return
        }
        invalidateCurrentWorkbookResultReload()
        applyCurrentWorkbookUpdatedResult(updatedResult)
        if !annotationOnly {
            currentWorkbookRequiresFullUpdate = false
        }
        currentWorkbookNeedsRefresh = currentWorkbookRequiresFullUpdate
        currentWorkbookSyncPhase = currentWorkbookRequiresFullUpdate ? .dirty : .current
        currentWorkbookUpdateStatus = currentWorkbookRequiresFullUpdate
            ? "Updated workbook annotations. Other current.xlsx changes still require an explicit update."
            : "Updated current.xlsx. Previous workbook saved in revisions."
        rebuildArtifactLens()
        if let sidecar = annotationStore?.sidecar {
            onAnnotationSidecarChanged?(sidecar)
        }
    }

    public func applyCurrentWorkbookUpdateFailed(_ error: Error) {
        invalidateCurrentWorkbookResultReload()
        currentWorkbookNeedsRefresh = true
        currentWorkbookSyncPhase = .failed(error.localizedDescription)
        currentWorkbookUpdateStatus =
            "Annotations were saved, but current.xlsx update failed. Use Update current.xlsx to retry."
        rebuildArtifactLens()
    }

    private func invalidateCurrentWorkbookResultReload() {
        currentWorkbookResultReloadTask?.cancel()
        currentWorkbookResultReloadTask = nil
        resultConfigurationGeneration &+= 1
    }

    private func reloadCurrentWorkbookResult(
        from bundleURL: URL,
        annotationOnly: Bool = false
    ) {
        if requiresManualHaplotypeTransitionCoordination {
            deferManualHaplotypeTransition(.reload) { [weak self] in
                self?.reloadCurrentWorkbookResult(
                    from: bundleURL,
                    annotationOnly: annotationOnly
                )
            }
            return
        }
        currentWorkbookResultReloadTask?.cancel()
        resultConfigurationGeneration &+= 1
        let expectedBundleURL = bundleURL.standardizedFileURL
        let expectedGeneration = resultConfigurationGeneration
        let loader = genotypeResultLoader
        currentWorkbookResultReloadTask = Task { @MainActor [weak self] in
            do {
                let updatedResult = try await loader(expectedBundleURL)
                try Task.checkCancellation()
                guard let self,
                      self.resultConfigurationGeneration == expectedGeneration,
                      self.result?.bundleURL.standardizedFileURL == expectedBundleURL,
                      updatedResult.bundleURL.standardizedFileURL == expectedBundleURL else {
                    return
                }
                self.currentWorkbookResultReloadTask = nil
                self.applyReloadedCurrentWorkbookResult(
                    updatedResult,
                    annotationOnly: annotationOnly,
                    expectedBundleURL: expectedBundleURL,
                    expectedGeneration: expectedGeneration
                )
            } catch is CancellationError {
                return
            } catch {
                guard let self,
                      self.resultConfigurationGeneration == expectedGeneration,
                      self.result?.bundleURL.standardizedFileURL == expectedBundleURL else {
                    return
                }
                self.currentWorkbookResultReloadTask = nil
                self.currentWorkbookUpdateStatus = error.localizedDescription
                self.rebuildArtifactLens()
                self.presentSheetAlert(error: error)
            }
        }
    }

    private func applyReloadedCurrentWorkbookResult(
        _ updatedResult: ONTGenotypeResultBundleData,
        annotationOnly: Bool,
        expectedBundleURL: URL,
        expectedGeneration: UInt64
    ) {
        guard resultConfigurationGeneration == expectedGeneration,
              result?.bundleURL.standardizedFileURL == expectedBundleURL,
              updatedResult.bundleURL.standardizedFileURL
                == expectedBundleURL else {
            return
        }
        if requiresManualHaplotypeTransitionCoordination {
            deferManualHaplotypeTransition(.reload) { [weak self] in
                self?.applyReloadedCurrentWorkbookResult(
                    updatedResult,
                    annotationOnly: annotationOnly,
                    expectedBundleURL: expectedBundleURL,
                    expectedGeneration: expectedGeneration
                )
            }
            return
        }
        applyCurrentWorkbookUpdatedResult(updatedResult)
        if !annotationOnly {
            currentWorkbookRequiresFullUpdate = false
        }
        currentWorkbookNeedsRefresh = currentWorkbookRequiresFullUpdate
        currentWorkbookUpdateStatus = currentWorkbookRequiresFullUpdate
            ? "Updated workbook annotations. Other current.xlsx changes still require an explicit update."
            : "Updated current.xlsx. Previous workbook saved in revisions."
        rebuildArtifactLens()
        if let sidecar = annotationStore?.sidecar {
            onAnnotationSidecarChanged?(sidecar)
        }
    }

    private func applyCurrentWorkbookUpdatedResult(_ updatedResult: ONTGenotypeResultBundleData) {
        let matrixWasConfigured = comparisonMatrixConfigured
        result = updatedResult
        manualHaplotypeEligibility =
            GenotypeManualHaplotypeEligibility.evaluate(updatedResult)
        rebuildResultIndexes(for: updatedResult)
        publishMatrixReviewCapability(for: currentSelectionState?.matrixTargets ?? [])
        rebuildActiveHaplotypeAnalysisIndexes()
        guard matrixWasConfigured else { return }
        comparisonMatrix.replaceResultPreservingPresentation(
            updatedResult,
            metadataStore: sampleMetadataStore,
            sidecar: annotationStore?.sidecar
        )
        comparisonMatrix.applyDisplayState(displayState)
        applyComparisonMatrixCohortFilter()
    }

    private func currentWorkbookEffectiveHaplotypeCalls() -> [GenotypeWorkbookHaplotypeCall] {
        if case .eligible = manualHaplotypeEligibility, let result {
            let index = GenotypeManualHaplotypeAssignmentIndex(
                assignments:
                    annotationStore?.sidecar.manualHaplotypeAssignments ?? []
            )
            return result.sampleNames.flatMap { sample in
                GenotypeManualHaplotypeLocus.allCases.map { locus in
                    let assignments = index.assignments(
                        sample: sample,
                        locus: locus
                    )
                    let notes = [assignments.h1?.notes, assignments.h2?.notes]
                        .compactMap {
                            $0?.trimmingCharacters(
                                in: .whitespacesAndNewlines
                            )
                        }
                        .filter { !$0.isEmpty }
                        .reduce(into: [String]()) { values, note in
                            if !values.contains(note) {
                                values.append(note)
                            }
                        }
                        .joined(separator: "; ")
                    return GenotypeWorkbookHaplotypeCall(
                        sample: sample,
                        locus: locus.rawValue,
                        haplotype1: assignments.h1?.label ?? "",
                        haplotype2: assignments.h2?.label ?? "",
                        status: GenotypeHaplotypeCallStatus.called.rawValue,
                        notes: notes
                    )
                }
            }
        }
        guard let analysis = activeHaplotypeAnalysis() else { return [] }
        let includedLoci = Set(currentWorkbookIncludedLoci())
        return analysis.samples.flatMap { sample in
            sample.calls.filter {
                includedLoci.contains($0.locus)
                    && GenotypeWorkbookHaplotypeCall.isWritableCurrentWorkbookLocus($0.locus)
            }.map { call in
                let effective = effectiveHaplotypeCall(sample: sample.sample, call: call)
                return GenotypeWorkbookHaplotypeCall(
                    sample: sample.sample,
                    locus: call.locus,
                    haplotype1: effective.h1,
                    haplotype2: effective.h2,
                    status: effective.status.rawValue,
                    notes: currentWorkbookNotes(sample: sample.sample, locus: call.locus, base: call.notes)
                )
            }
        }
    }

    private func currentWorkbookHaplotypeProjectionMode()
        -> GenotypeWorkbookHaplotypeProjectionMode
    {
        if case .eligible = manualHaplotypeEligibility {
            return .manualGenotypeOnly
        }
        return .haplotyped
    }

    private func currentWorkbookNotes(sample: String, locus: String, base: String) -> String {
        let assignmentNotes = [HaplotypeSlot.h1, .h2].compactMap { slot in
            manualHaplotypeAssignment(sample: sample, locus: locus, slot: slot)?.notes
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return ([base.trimmingCharacters(in: .whitespacesAndNewlines)] + assignmentNotes)
            .filter { !$0.isEmpty }
            .reduce(into: [String]()) { values, note in
                if !values.contains(note) {
                    values.append(note)
                }
            }
            .joined(separator: "; ")
    }

    private func currentWorkbookIncludedLoci() -> [String] {
        if case .eligible = manualHaplotypeEligibility {
            return GenotypeManualHaplotypeLocus.allCases.map(\.rawValue)
        }
        guard let analysis = activeHaplotypeAnalysis() else { return [] }
        return effectiveIncludedLoci(for: analysis)
            .filter { GenotypeWorkbookHaplotypeCall.isWritableCurrentWorkbookLocus($0) }
    }

    private func currentWorkbookRevisionProvenanceContext(
        bundleURL: URL,
        includedLoci: [String]
    ) -> GenotypeWorkbookRevisionProvenanceContext {
        var argv = [
            "lungfish-app",
            "genotype-result",
            "update-current-workbook",
            bundleURL.path,
        ]
        for locus in includedLoci {
            argv += ["--included-locus", locus]
        }
        return GenotypeWorkbookRevisionProvenanceContext(
            toolName: "Lungfish app genotype-result update-current-workbook",
            toolKind: "app",
            argv: argv
        )
    }

    private func makeAuditTimelineHost(entries: [GenotypeAnnotationSidecar.AuditEntry]) -> NSView {
        let container = NSHostingView(rootView: GenotypeAuditTimelineSection(entries: entries, entryLimit: 12))
        container.identifier = Self.generatedContentHostingViewIdentifier
        container.translatesAutoresizingMaskIntoConstraints = false
        container.frame.size.height = 240
        NSLayoutConstraint.activate([
            container.heightAnchor.constraint(greaterThanOrEqualToConstant: 160),
        ])
        return container
    }

    /// Adds an Audit-lens section: a title followed by a content block,
    /// each constrained to the lens width and visually grouped. Replaces
    /// the previous free-form sectionTitle + content additions that
    /// produced inconsistent alignment.
    private func addAuditSection(title: String, contents: [NSView]) {
        let group = NSStackView()
        group.translatesAutoresizingMaskIntoConstraints = false
        group.orientation = .vertical
        group.alignment = .leading
        group.spacing = 6
        let header = sectionTitle(title)
        group.addArrangedSubview(header)
        for view in contents {
            view.translatesAutoresizingMaskIntoConstraints = false
            group.addArrangedSubview(view)
            view.leadingAnchor.constraint(equalTo: group.leadingAnchor).isActive = true
            view.trailingAnchor.constraint(equalTo: group.trailingAnchor).isActive = true
        }
        artifactStack.addArrangedSubview(group)
        group.leadingAnchor.constraint(equalTo: artifactStack.leadingAnchor, constant: 0).isActive = true
        group.trailingAnchor.constraint(equalTo: artifactStack.trailingAnchor, constant: 0).isActive = true
    }

    /// A read-only, provenance-only indicator of the haplotype definition the
    /// analysis was run against. Definition CRUD now lives solely in the Tools
    /// menu manager window; the analysis view only reports the active/recorded
    /// definition. Shows the live definition's display name when a matching
    /// project bundle is present, otherwise the recorded definition id so past
    /// analyses still surface their provenance even with no live bundle.
    private func makeActiveHaplotypeDefinitionRow() -> NSView {
        let container = NSStackView()
        container.translatesAutoresizingMaskIntoConstraints = false
        container.orientation = .vertical
        container.alignment = .leading
        container.spacing = 6
        container.edgeInsets = NSEdgeInsets(top: 4, left: 8, bottom: 4, right: 8)

        let name = activeHaplotypeDefinitionDisplayName()
        let label = NSTextField(labelWithString: "Definition: \(name)")
        label.font = NSFont.systemFont(ofSize: 11, weight: .medium)
        container.addArrangedSubview(label)

        let hint = NSTextField(wrappingLabelWithString:
            "Manage haplotype definitions from Tools \u{203A} Haplotype Definitions\u{2026}. Each definition is a project .lungfishmhcref bundle that pairs its diagnostic alleles with a reference FASTA."
        )
        hint.font = NSFont.systemFont(ofSize: 10)
        hint.textColor = .secondaryLabelColor
        hint.maximumNumberOfLines = 3
        container.addArrangedSubview(hint)

        return container
    }

    /// Resolves the definition name to show in the read-only indicator:
    /// the live definition's display name when a project bundle matches,
    /// otherwise the recorded definition id from the bundle's analysis or
    /// manifest provenance.
    private func activeHaplotypeDefinitionDisplayName() -> String {
        if let result, let definition = definitionSetForResult(result) {
            return definition.displayName
        }
        if let result,
           let recordedID = result.haplotypeAnalysis?.definitionSetID
               ?? result.manifest.haplotypeDefinitionSetID {
            return recordedID
        }
        return "None recorded"
    }

    private func makeRunHaplotypeThresholdSummaryHost() -> NSView {
        let container = NSStackView()
        container.translatesAutoresizingMaskIntoConstraints = false
        container.orientation = .vertical
        container.alignment = .leading
        container.spacing = 6
        container.edgeInsets = NSEdgeInsets(top: 4, left: 8, bottom: 4, right: 8)

        let summary = NSTextField(labelWithString: runHaplotypeThresholdSummary())
        summary.font = NSFont.systemFont(ofSize: 11, weight: .medium)
        summary.textColor = .labelColor
        container.addArrangedSubview(summary)

        let hint = NSTextField(wrappingLabelWithString:
            "These thresholds affect haplotype assignment only. Genotyping worksheets and call evidence keep all retained reads. Rerun miSeq amplicon MHC genotyping to change haplotype thresholds."
        )
        hint.font = NSFont.systemFont(ofSize: 10)
        hint.textColor = .secondaryLabelColor
        hint.maximumNumberOfLines = 4
        container.addArrangedSubview(hint)

        return container
    }

    private func runHaplotypeThresholdSummary() -> String {
        guard let evaluator = runHaplotypeDropoutEvaluator() else {
            return "No haplotype filtering thresholds recorded."
        }
        var parts: [String] = []
        if let absolute = evaluator.absolute {
            parts.append("min reads \(absolute)")
        }
        if let sample = evaluator.sampleFraction {
            parts.append("sample \(Self.percentLabel(sample))")
        }
        if let locus = evaluator.locusFraction {
            parts.append("locus \(Self.percentLabel(locus))")
        }
        let overrides = evaluator.locusFractionOverrides
            .sorted { $0.key < $1.key }
            .map { "\($0.key) \(Self.percentLabel($0.value))" }
        if !overrides.isEmpty {
            parts.append("overrides: \(overrides.joined(separator: ", "))")
        }
        return parts.isEmpty ? "No haplotype filtering thresholds recorded." : parts.joined(separator: " · ")
    }

    /// Recompute the live (in-memory) haplotype analysis using the
    /// genotyping-run thresholds. Falls back to the pipeline-persisted
    /// analysis when no definition set is available.
    private func recomputeLiveHaplotypeAnalysis(evaluator: GenotypeDropoutEvaluator?) {
        guard hasHaplotypingResult else {
            liveHaplotypeAnalysis = nil
            return
        }
        haplotypeWorkCount += 1
        guard let result, let definitionSet = definitionSetForResult(result) else {
            liveHaplotypeAnalysis = nil
            rebuildActiveHaplotypeAnalysisIndexes()
            return
        }
        guard !result.calls.isEmpty else {
            liveHaplotypeAnalysis = nil
            rebuildActiveHaplotypeAnalysisIndexes()
            return
        }
        liveHaplotypeAnalysis = GenotypeHaplotypeAnalyzer.analyze(
            calls: result.calls,
            definitionSet: definitionSet,
            generatedAt: nil,
            dropoutFilter: evaluator
        )
        rebuildActiveHaplotypeAnalysisIndexes()
    }

    private func useHaplotypeDefinition(id: String) throws {
        guard let definitionSet = haplotypeDefinitionStore.mergedRegistry().definitionSet(id: id) else { return }
        guard let store = annotationStore else { return }
        let author = annotationAuthorProvider()
        try store.updateSettings(author: author) { settings in
            settings.activeHaplotypeDefinitionSetID = id
            settings.activeHaplotypeAssayID = definitionSet.assayID
        }
        refreshAfterHaplotypeDefinitionChange()
        onAnnotationSidecarChanged?(store.sidecar)
    }

    private func refreshAfterHaplotypeDefinitionChange() {
        liveHaplotypeAnalysis = nil
        cachedHaplotypeDefinitionContext = nil
        if let result, definitionSetForResult(result) != nil {
            recomputeLiveHaplotypeAnalysis(evaluator: runHaplotypeDropoutEvaluator())
        } else {
            rebuildActiveHaplotypeAnalysisIndexes()
        }
        rebuildHaplotypeLens()
        rebuildOutline()
        rebuildHaplotypeMatrix()
        rebuildCohortSummary()
        applyComparisonMatrixCohortFilter()
        updateCallEvidence()
        rebuildArtifactLens()
    }

    /// Returns the haplotype analysis the UI should consult: the
    /// dropout-aware recomputation when present, otherwise the
    /// pipeline-persisted version embedded in the bundle.
    private func activeHaplotypeAnalysis() -> GenotypeHaplotypeAnalysis? {
        guard hasHaplotypingResult else { return nil }
        if let liveHaplotypeAnalysis { return liveHaplotypeAnalysis }
        return result?.haplotypeAnalysis
    }

    private func resultWithActiveHaplotypeAnalysis(_ result: ONTGenotypeResultBundleData) -> ONTGenotypeResultBundleData {
        guard let active = activeHaplotypeAnalysis(),
              active != result.haplotypeAnalysis else {
            return result
        }
        return ONTGenotypeResultBundleData(
            bundleURL: result.bundleURL,
            manifest: result.manifest,
            artifacts: result.artifacts,
            stats: result.stats,
            calls: result.calls,
            samples: result.samples,
            haplotypeAnalysis: active
        )
    }

    private func manualHaplotypingIsAvailable(result: ONTGenotypeResultBundleData) -> Bool {
        if result.haplotypeAnalysis != nil {
            return !(annotationStore?.sidecar.manualHaplotypeAssignments.isEmpty ?? true)
        }
        guard case .eligible = manualHaplotypeEligibility else { return false }
        return true
    }

    private var usesLegacyManualHaplotypingSection: Bool {
        result?.haplotypeAnalysis != nil
    }

    private func makeManualHaplotypeEditorHost(for sample: String) -> NSView? {
        guard case .eligible = manualHaplotypeEligibility,
              let result,
              let store = annotationStore else {
            return nil
        }
        let editorBundleURL = result.bundleURL.standardizedFileURL

        let model = GenotypeManualHaplotypeEditorModel(
            snapshot: manualHaplotypeEditorSnapshot(
                sample: sample,
                result: result,
                store: store
            ),
            onSave: { [weak self] draft in
                guard let self,
                      case .eligible = self.manualHaplotypeEligibility,
                      self.result?.bundleURL.standardizedFileURL
                        == editorBundleURL,
                      let currentStore = self.annotationStore else {
                    throw ManualHaplotypeEditorError.unavailable
                }
                let assignments = try draft.validatedAssignments()
                let replacement =
                    try currentStore.replaceManualHaplotypeAssignments(
                        for: draft.sample,
                        with: assignments,
                        copySource: draft.copySource,
                        author: self.annotationAuthorProvider()
                    )
                if replacement.didChange {
                    self.comparisonMatrix.applyManualHaplotypeAssignments(
                        currentStore.sidecar.manualHaplotypeAssignments
                    )
                    self.markCurrentWorkbookDirty(
                        requiresFullUpdate: true,
                        legacyStatus:
                            "current.xlsx does not include manual haplotype changes."
                    )
                    self.onAnnotationSidecarChanged?(currentStore.sidecar)
                }
                let currentIndex = GenotypeManualHaplotypeAssignmentIndex(
                    assignments:
                        currentStore.sidecar.manualHaplotypeAssignments
                )
                return GenotypeManualHaplotypeDraft(
                    sample: draft.sample,
                    index: currentIndex
                )
            },
            onReload: { [weak self] in
                guard let self,
                      let currentResult = self.result else {
                    throw ManualHaplotypeEditorError.unavailable
                }
                let reloadedStore = try GenotypeAnnotationStore(
                    bundleURL: currentResult.bundleURL,
                    author: self.annotationAuthorProvider(),
                    seedBuiltInSmartCohorts: false
                )
                self.annotationStore = reloadedStore
                self.currentWorkbookIsReadOnly = reloadedStore.isReadOnly
                self.rebuildMatrixAnnotationIndexes()
                self.comparisonMatrix.applyAnnotationSidecar(
                    reloadedStore.sidecar,
                    reload: false
                )
                self.rebuildArtifactLens()
                return self.manualHaplotypeEditorSnapshot(
                    sample: sample,
                    result: currentResult,
                    store: reloadedStore
                )
            },
            onExport: { [weak self] in
                self?.exportManualDefinitions()
            }
        )
        manualHaplotypeEditorModel = model

        let container = makeGenotypeManualHaplotypeEditorHostingView(
            model: model,
            typographyModel: manualHaplotypeEditorTypographyModel
        )
        container.identifier = Self.generatedContentHostingViewIdentifier
        container.translatesAutoresizingMaskIntoConstraints = false
        container.setAccessibilityIdentifier(
            "manual-haplotype-detail-editor"
        )
        manualHaplotypeEditorHostView = container
        return container
    }

    private func focusManualHaplotypeEditor(sample: String) {
#if DEBUG
        testingLastManualHaplotypeFocusIdentifier = nil
#endif
        let target: GenotypeAnnotationSidecar.MatrixTarget =
            .column(sample: sample)
        if currentSelectionState?.matrixTargets != [target] {
            showMatrixTargetSelection([target])
        }
        guard let host = manualHaplotypeEditorHostView else { return }
        detailScrollView.isHidden = false
        sampleCurationWorkbench?.layoutSubtreeIfNeeded()
        view.layoutSubtreeIfNeeded()
        let identifier = "manual-haplotype-MHC-A-h1"
        DispatchQueue.main.async { [weak self, weak host] in
            guard let self, let host,
                  host === self.manualHaplotypeEditorHostView else {
                return
            }
            self.sampleCurationWorkbench?.layoutSubtreeIfNeeded()
            self.view.layoutSubtreeIfNeeded()
            guard
                  let combo = self.descendantComboBox(
                      in: host,
                      accessibilityIdentifier: identifier
                  ) else {
                return
            }
            let fieldRect = combo.convert(
                combo.bounds,
                to: self.detailDocumentView
            )
            self.detailScrollView.contentView.scrollToVisible(fieldRect)
            self.detailScrollView.reflectScrolledClipView(
                self.detailScrollView.contentView
            )
            guard self.view.window?.makeFirstResponder(combo) == true else {
                return
            }
#if DEBUG
            self.testingLastManualHaplotypeFocusIdentifier = identifier
#endif
        }
    }

    private func descendantComboBox(
        in root: NSView,
        accessibilityIdentifier: String
    ) -> NSComboBox? {
        if let combo = root as? NSComboBox,
           combo.accessibilityIdentifier()
                == accessibilityIdentifier {
            return combo
        }
        for subview in root.subviews {
            if let match = descendantComboBox(
                in: subview,
                accessibilityIdentifier: accessibilityIdentifier
            ) {
                return match
            }
        }
        return nil
    }

    private func manualHaplotypeEditorSnapshot(
        sample: String,
        result: ONTGenotypeResultBundleData,
        store: GenotypeAnnotationStore
    ) -> GenotypeManualHaplotypeEditorModel.Snapshot {
        let assignments = store.sidecar.manualHaplotypeAssignments
        let normalizedSample =
            GenotypeManualHaplotypeAssignmentInputValidator
                .normalizedSampleIdentity(sample)
        let index = GenotypeManualHaplotypeAssignmentIndex(
            assignments: assignments
        )
        let orphanLegacyAssignments = assignments.filter { assignment in
            GenotypeManualHaplotypeAssignmentInputValidator
                .normalizedSampleIdentity(assignment.sample)
                == normalizedSample
                && GenotypeManualHaplotypeLocus(
                    normalizing: assignment.locus
                ) == nil
        }
        let normalizedSampleNames = Set(
            (result.samples.map(\.sample)
                + result.calls.map(\.sample)
                + [sample])
                .map {
                    GenotypeManualHaplotypeAssignmentInputValidator
                        .normalizedSampleIdentity($0)
                }
        )
        let copyCandidates = normalizedSampleNames
            .sorted {
                $0.localizedStandardCompare($1) == .orderedAscending
            }
            .map(index.sampleAssignments(for:))

        return GenotypeManualHaplotypeEditorModel.Snapshot(
            draft: GenotypeManualHaplotypeDraft(
                sample: normalizedSample,
                index: index
            ),
            copyCandidates: copyCandidates,
            orphanLegacyAssignments: orphanLegacyAssignments,
            isReadOnly: store.isReadOnly
        )
    }

    private func makeManualHaplotypingHost() -> NSView {
        let container = NSHostingView(rootView: manualHaplotypingSectionBody())
        container.identifier = Self.generatedContentHostingViewIdentifier
        container.translatesAutoresizingMaskIntoConstraints = false
        container.frame.size.height = 240
        NSLayoutConstraint.activate([
            container.heightAnchor.constraint(greaterThanOrEqualToConstant: 200),
        ])
        return container
    }

    private func manualHaplotypingSectionBody() -> AnyView {
        let storedAssignments =
            annotationStore?.sidecar.manualHaplotypeAssignments ?? []
        if usesLegacyManualHaplotypingSection {
            return AnyView(
                GenotypeLegacyManualHaplotypingSection(
                    rows: manualHaplotypingRows(),
                    manualAssignments: storedAssignments,
                    selectedGenotypeIds: Binding(
                        get: {
                            [weak self] in
                            self?.manualHaplotypingSelection ?? []
                        },
                        set: {
                            [weak self] newValue in
                            self?.manualHaplotypingSelection = newValue
                        }
                    ),
                    draftLabel: Binding(
                        get: {
                            [weak self] in
                            self?.manualHaplotypingDraftLabel ?? ""
                        },
                        set: {
                            [weak self] newValue in
                            self?.manualHaplotypingDraftLabel = newValue
                        }
                    ),
                    draftColorTokenIndex: Binding(
                        get: {
                            [weak self] in
                            self?.manualHaplotypingDraftColorTokenIndex
                                ?? 1
                        },
                        set: {
                            [weak self] newValue in
                            self?.manualHaplotypingDraftColorTokenIndex =
                                newValue
                        }
                    ),
                    onCreateHaplotype: {
                        [weak self] in
                        self?.commitManualHaplotype()
                    },
                    onDeleteAssignment: {
                        [weak self] assignment in
                        self?.deleteManualHaplotype(
                            matching: assignment
                        )
                    },
                    onExportDefinitions: {
                        [weak self] in
                        self?.exportManualDefinitions()
                    }
                )
            )
        }
        let assignments = GenotypeManualHaplotypeAssignmentIndex(
            assignments:
                storedAssignments
        ).currentAssignments
        return AnyView(
            GenotypeManualHaplotypingSection(
                manualAssignments: assignments,
                onExportDefinitions: {
                    [weak self] in
                    self?.exportManualDefinitions()
                }
            )
        )
    }

    private func manualHaplotypingRows() -> [GenotypeManualHaplotypingSection.GenotypeRow] {
        guard let result else { return [] }
        let digest = GenotypeManualHaplotypingDigest.build(from: result.calls)
        return digest.observations.map { observation in
            GenotypeManualHaplotypingSection.GenotypeRow(
                locus: observation.locus,
                genotype: observation.genotype,
                sampleCount: observation.sampleCount,
                totalReads: observation.totalReads
            )
        }
    }

    private func commitManualHaplotype() {
        guard let result,
              manualHaplotypingIsAvailable(result: result),
              let store = annotationStore else {
            return
        }
        let author = annotationAuthorProvider()
        let label = manualHaplotypingDraftLabel.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !label.isEmpty, !manualHaplotypingSelection.isEmpty else { return }
        let selectedIds = manualHaplotypingSelection
        let observations = GenotypeManualHaplotypingDigest.build(from: result.calls).observations
        let matching = observations.filter { selectedIds.contains("\($0.locus)::\($0.genotype)") }
        guard !matching.isEmpty else { return }
        let tokenIndex = manualHaplotypingDraftColorTokenIndex
        do {
            var bulk: [ManualHaplotypeAssignment] = []
            for observation in matching {
                for sampleId in observation.sampleIds {
                    bulk.append(.init(
                        sample: sampleId,
                        locus: observation.locus,
                        slot: .h1,
                        label: label,
                        colorTokenIndex: tokenIndex,
                        diagnosticAlleles: [observation.genotype],
                        notes: ""
                    ))
                }
            }
            guard !bulk.isEmpty else { return }
            try store.addManualHaplotypeAssignments(bulk, author: author)
            markCurrentWorkbookDirty(
                requiresFullUpdate: true,
                legacyStatus: "current.xlsx does not include workbook changes."
            )
            onAnnotationSidecarChanged?(store.sidecar)
        } catch {
            if let window = view.window ?? NSApp.keyWindow {
                NSAlert(error: error).beginSheetModal(for: window, completionHandler: { _ in })
            } else {
                NSApp.presentError(error)
            }
        }
        manualHaplotypingSelection.removeAll()
        manualHaplotypingDraftLabel = ""
        rebuildArtifactLens()
    }

    private func deleteManualHaplotype(matching assignment: ManualHaplotypeAssignment) {
        guard let store = annotationStore else { return }
        let author = annotationAuthorProvider()
        do {
            try store.removeManualHaplotypeAssignments(
                matching: { other in other.label == assignment.label },
                author: author
            )
            markCurrentWorkbookDirty(
                requiresFullUpdate: true,
                legacyStatus: "current.xlsx does not include workbook changes."
            )
            onAnnotationSidecarChanged?(store.sidecar)
        } catch {
            if let window = view.window ?? NSApp.keyWindow {
                NSAlert(error: error).beginSheetModal(for: window, completionHandler: { _ in })
            } else {
                NSApp.presentError(error)
            }
        }
        rebuildArtifactLens()
    }

    private func exportManualDefinitions() {
        guard let store = annotationStore else { return }
        let assignments = GenotypeManualHaplotypeAssignmentIndex(
            assignments: store.sidecar.manualHaplotypeAssignments
        ).currentAssignments
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "manual-haplotype-definitions.json"
        panel.beginSheetModal(for: view.window ?? NSApp.keyWindow ?? NSWindow()) { response in
            guard response == .OK, let url = panel.url else { return }
            do {
                let startedAt = Date()
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                let data = try encoder.encode(assignments)
                try data.write(to: url, options: .atomic)
                try self.writeManualDefinitionsExportProvenance(
                    outputURL: url,
                    assignmentCount: assignments.count,
                    startedAt: startedAt
                )
            } catch {
                if let window = self.view.window ?? NSApp.keyWindow {
                    NSAlert(error: error).beginSheetModal(for: window, completionHandler: { _ in })
                } else {
                    NSApp.presentError(error)
                }
            }
        }
    }

    private func writeManualDefinitionsExportProvenance(
        outputURL: URL,
        assignmentCount: Int,
        startedAt: Date
    ) throws {
        guard let store = annotationStore else { return }
        let annotationURL = store.bundleURL.appendingPathComponent(GenotypeAnnotationSidecar.filename)
        let argv = [
            CLICommandIdentity.executableName,
            "export-manual-haplotype-definitions",
            "--bundle", store.bundleURL.path,
            "--output", outputURL.path,
        ]
        var builder = ProvenanceRunBuilder(
            workflowName: "Manual haplotype definition export",
            workflowVersion: WorkflowRun.currentAppVersion,
            toolName: "Lungfish Genome Explorer",
            toolVersion: WorkflowRun.currentAppVersion
        )
        .argv(argv)
        .options(
            explicit: [
                "bundle": .file(store.bundleURL),
                "output": .file(outputURL),
            ],
            defaults: [
                "format": .string("json"),
            ],
            resolved: [
                "assignmentCount": .integer(assignmentCount),
            ]
        )
        .runtime(ProvenanceRuntimeIdentity())
        if FileManager.default.fileExists(atPath: annotationURL.path) {
            builder = try builder.input(annotationURL, format: .json, role: .input)
        }
        builder = try builder.output(outputURL, format: .json, role: .output)
        let envelope = try builder.complete(exitStatus: 0, startedAt: startedAt, endedAt: Date())
        try ProvenanceWriter(signingProvider: nil).write(envelope, toSidecar: outputURL.appendingPathExtension("provenance.json"))
    }

    private func rebuildOutline() {
        outlineRowsBySample.removeAll()
        outlineRowOrder.removeAll()
        guard hasHaplotypingResult else {
            outlineView.configure(rows: [])
            syncOutlineReviewSelection()
            return
        }
        haplotypeWorkCount += 1
        guard let result, let analysis = activeHaplotypeAnalysis(), !analysis.samples.isEmpty else {
            outlineView.configure(rows: [])
            syncOutlineReviewSelection()
            return
        }
        let observed = observedLociIndex ?? GenotypeObservedLociIndex.build(from: result)
        let loci = effectiveIncludedLoci(for: analysis, observed: observed)
        let includedLoci = Set(loci)
        let allowedSamples = filteredSampleNames(result: result, sidecar: annotationStore?.sidecar)
        var rows: [GenotypeOutlineView.Row] = []
        for sample in analysis.samples where allowedSamples.contains(sample.sample) {
            let tapeSlots = outlineTapeSlots(
                for: sample,
                loci: loci,
                observed: observed
            )
            let effectiveCalls = sample.calls.filter { includedLoci.contains($0.locus) }.map { call in
                let effective = effectiveHaplotypeCall(sample: sample.sample, call: call)
                return (
                    locus: call.locus,
                    h1: effective.h1,
                    h2: effective.h2,
                    status: effective.status,
                    observedGenotypeCount: call.observedGenotypeCount,
                    observedGenotypes: call.observedGenotypes
                )
            }
            let blockKind = GenotypeBlockClassifier.classify(
                calls: effectiveCalls.map { (locus: $0.locus, h1: $0.h1, h2: $0.h2) }
            )
            let comment = outlineCommentSummary(for: sample, effectiveCalls: effectiveCalls)
            let issueCount = outlineNoteIssueCount(for: sample, effectiveCalls: effectiveCalls)
            // Per-locus call text is retained for export and inspector context.
            let perLocusCallText: [(locus: String, h1: String, h2: String, status: GenotypeHaplotypeCallStatus)] =
                effectiveCalls.map { (locus: $0.locus, h1: $0.h1, h2: $0.h2, status: $0.status) }
            let row = GenotypeOutlineView.Row(
                animalId: sample.sample,
                gsId: nil,
                loci: loci,
                tapeSlots: tapeSlots,
                blockKind: blockKind,
                commentSummary: comment,
                noteIssueCount: issueCount,
                perLocusCallText: perLocusCallText
            )
            rows.append(row)
            outlineRowsBySample[sample.sample] = row
            outlineRowOrder.append(sample.sample)
        }
        outlineView.configure(rows: rows)
        syncOutlineReviewSelection()
    }

    private func rebuildHaplotypeMatrix() {
        guard hasHaplotypingResult else {
            haplotypeMatrixView.configure(rows: [], definitionName: nil)
            return
        }
        guard selectedLens == .summary && displayState.summaryViewMode == .matrix else {
            return
        }
        haplotypeWorkCount += 1
        if activeHaplotypeAnalysis() == nil {
            recomputeLiveHaplotypeAnalysis(evaluator: runHaplotypeDropoutEvaluator())
        }
        guard let result,
              let analysis = activeHaplotypeAnalysis(),
              let definitionSet = definitionSetForResult(result),
              !analysis.samples.isEmpty else {
            haplotypeMatrixView.configure(rows: [], definitionName: nil)
            return
        }
        var allowedSamples = filteredSampleNames(
            result: result,
            sidecar: annotationStore?.sidecar,
            includingQuickSearch: false
        )
        let sharedSearch = activeSharedMatrixSearchText()
        if !sharedSearch.isEmpty {
            allowedSamples.formIntersection(
                sharedSearchCarrierSampleIDs(
                    for: searchGenotypeViewport(sharedSearch)
                )
            )
        }
        var definitionsByLocus: [String: GenotypeHaplotypeLocusDefinition] = [:]
        for definition in definitionSet.locusDefinitions where definitionsByLocus[definition.locus] == nil {
            definitionsByLocus[definition.locus] = definition
        }
        let callsBySample = Dictionary(grouping: result.calls, by: \.sample)
        var rows: [GenotypeHaplotypeDefinitionMatrixView.Row] = []
        for sample in analysis.samples where allowedSamples.contains(sample.sample) {
            let sampleCalls = callsBySample[sample.sample] ?? []
            var diagnosticReadCache: [String: Int] = [:]
            func cachedDiagnosticReads(
                for allele: String,
                locusDefinition: GenotypeHaplotypeLocusDefinition
            ) -> Int {
                let key = "\(locusDefinition.locus)|\(allele)"
                if let cached = diagnosticReadCache[key] {
                    return cached
                }
                let value = diagnosticReads(
                    for: allele,
                    in: sampleCalls,
                    locusDefinition: locusDefinition
                )
                diagnosticReadCache[key] = value
                return value
            }
            for locusCall in sample.calls {
                guard let locusDefinition = definitionsByLocus[locusCall.locus] else { continue }
                let effective = effectiveHaplotypeCall(sample: sample.sample, call: locusCall)
                let displayedH2 = normalizedHomozygousSecondHaplotype(
                    h1: effective.h1,
                    h2: effective.h2,
                    status: effective.status
                )
                let retainedObservedGenotypes = Set(locusCall.observedGenotypes)
                let calledNames = Set([effective.h1, displayedH2].filter { !$0.isEmpty && $0 != "-" })
                let callName = diploidDisplayName(h1: effective.h1, h2: displayedH2)
                let locusRows = locusDefinition.haplotypes.map { haplotype -> GenotypeHaplotypeDefinitionMatrixView.Row in
                    let alleles = haplotype.diagnosticAlleles.map { allele in
                        GenotypeHaplotypeDefinitionMatrixView.DiagnosticAllele(
                            name: allele,
                            reads: retainedObservedGenotypes.contains(where: {
                                GenotypeHaplotypeDiagnosticMatcher.matches(
                                    genotype: $0,
                                    diagnosticAllele: allele
                                )
                            })
                                ? cachedDiagnosticReads(
                                    for: allele,
                                    locusDefinition: locusDefinition
                                )
                                : 0
                        )
                    }
                    let observedCount = alleles.filter(\.isObserved).count
                    let status: GenotypeHaplotypeDefinitionMatrixView.Row.Status
                    if calledNames.contains(haplotype.name) {
                        status = .called
                    } else if observedCount > 0 {
                        status = .candidate
                    } else {
                        status = .absent
                    }
                    return GenotypeHaplotypeDefinitionMatrixView.Row(
                        sample: sample.sample,
                        locus: locusCall.locus,
                        callName: callName,
                        haplotypeName: haplotype.name,
                        haplotypeColor: haplotype.effectiveFillColor,
                        observedCount: observedCount,
                        diagnosticCount: haplotype.diagnosticAlleles.count,
                        minimumMatches: haplotype.effectiveMinimumMatches,
                        status: status,
                        alleles: alleles
                    )
                }
                rows.append(contentsOf: locusRows.sorted { lhs, rhs in
                    if lhs.status != rhs.status {
                        return matrixStatusRank(lhs.status) < matrixStatusRank(rhs.status)
                    }
                    if lhs.observedCount != rhs.observedCount {
                        return lhs.observedCount > rhs.observedCount
                    }
                    return lhs.haplotypeName.localizedStandardCompare(rhs.haplotypeName) == .orderedAscending
                })
            }
        }
        haplotypeMatrixView.configure(rows: rows, definitionName: analysis.definitionSetName)
    }

    private func activeSharedMatrixSearchText() -> String {
        let quickSearch = quickFilterSearchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let activeSearch = quickSearch.isEmpty
            ? activeSmartCohort.flatMap(savedSearchProjectionText)
            : quickSearch
        return activeSearch?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    private func savedSearchProjectionText(
        for cohort: GenotypeCohortSmartFilter
    ) -> String? {
        let explicit = cohort.searchProjectionText?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let explicit, !explicit.isEmpty {
            return explicit
        }
        return cohort.predicate.visibleTextSearch
    }

    private func matrixStatusRank(_ status: GenotypeHaplotypeDefinitionMatrixView.Row.Status) -> Int {
        switch status {
        case .called:
            return 0
        case .candidate:
            return 1
        case .absent:
            return 2
        }
    }

    private func diagnosticReads(
        for allele: String,
        in calls: [ONTGenotypeCall],
        locusDefinition: GenotypeHaplotypeLocusDefinition?
    ) -> Int {
        calls.reduce(0) { total, call in
            if let locusDefinition,
               !GenotypeHaplotypeLocusResolver.rawCall(call, belongsTo: locusDefinition),
               !GenotypeHaplotypeLocusResolver.allowsCrossFamilyDiagnostics(for: locusDefinition) {
                return total
            }
            if GenotypeHaplotypeDiagnosticMatcher.matches(genotype: call.genotype, diagnosticAllele: allele) {
                return total + max(0, call.passedUniqueReads)
            }
            return total
        }
    }

    private func diagnosticDisplayGenotype(
        for allele: String,
        in calls: [ONTGenotypeCall],
        locusDefinition: GenotypeHaplotypeLocusDefinition?
    ) -> String? {
        calls
            .filter { call in
                if let locusDefinition,
                   !GenotypeHaplotypeLocusResolver.rawCall(call, belongsTo: locusDefinition),
                   !GenotypeHaplotypeLocusResolver.allowsCrossFamilyDiagnostics(for: locusDefinition) {
                    return false
                }
                return GenotypeHaplotypeDiagnosticMatcher.matches(
                    genotype: call.genotype,
                    diagnosticAllele: allele
                )
            }
            .sorted {
                if $0.passedUniqueReads != $1.passedUniqueReads {
                    return $0.passedUniqueReads > $1.passedUniqueReads
                }
                return $0.genotype.localizedStandardCompare($1.genotype) == .orderedAscending
            }
            .first?
            .genotype
    }

    /// Returns the set of sample names that should appear in Outline/Matrix,
    /// after applying both the active smart cohort predicate and the
    /// ad-hoc filter (if either is active).
    private func filteredSampleNames(
        result: ONTGenotypeResultBundleData,
        sidecar: GenotypeAnnotationSidecar?,
        includingQuickSearch: Bool = true
    ) -> Set<String> {
        let names = allFilterableSampleNames(result: result)
        var allowed = Set(names)
        let predicates: [SmartCohortPredicate] = hasHaplotypingResult
            ? [
                activeSmartCohort?.predicate,
                quickFilterPredicate,
            ].compactMap { $0 }
            : []
        if !predicates.isEmpty {
            let liveSidecar = sidecar ?? GenotypeAnnotationSidecar.empty(generatedAt: "")
            cohortSubjectBuildCount += 1
            let subjects = GenotypeCohortSubjectBuilder.buildSubjects(
                result: resultWithActiveHaplotypeAnalysis(result),
                sidecar: liveSidecar,
                metadataBySample: sampleMetadataStore?.records ?? [:]
            )
            let combined: SmartCohortPredicate = predicates.count == 1 ? predicates[0] : .all(predicates)
            let matched = subjects.filter { combined.evaluate($0) }.map(\.animalId)
            allowed.formIntersection(matched)
        }

        let search = quickFilterSearchText.trimmingCharacters(in: .whitespacesAndNewlines)
        if includingQuickSearch && !search.isEmpty {
            let matches = searchGenotypeViewport(search)
            allowed.formIntersection(sharedSearchCarrierSampleIDs(for: matches))
        }
        return allowed
    }

    private func allFilterableSampleNames(result: ONTGenotypeResultBundleData) -> [String] {
        if !allFilterableSampleNamesCache.isEmpty {
            return allFilterableSampleNamesCache
        }
        var seen = Set<String>()
        let haplotypeSources = hasHaplotypingResult
            ? activeHaplotypeSampleNames
                + (activeHaplotypeAnalysis()?.samples ?? []).map(\.sample)
                + (result.haplotypeAnalysis?.samples ?? []).map(\.sample)
            : []
        let sources = haplotypeSources
            + result.sampleNames
            + result.samples.map(\.sample)
            + callsBySample.keys.sorted {
                $0.localizedStandardCompare($1) == .orderedAscending
            }
        allFilterableSampleNamesCache = sources.filter { seen.insert($0).inserted }
        return allFilterableSampleNamesCache
    }

    private struct SharedSearchConstraints {
        let allowedSampleIDs: Set<String>
        let projectedRowIDs: Set<GenotypeCandidateMatrixRowID>?
    }

    private func invalidateGenotypeSearchIndex() {
        genotypeSearchIndex = nil
        latestGenotypeSearchResult = .empty
        latestGenotypeSearchQuery = ""
    }

    private func searchGenotypeViewport(_ query: String) -> GenotypeSearchIndex.Result {
        guard let result else { return .empty }
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if genotypeSearchIndex != nil,
           query == latestGenotypeSearchQuery {
            return latestGenotypeSearchResult
        }
        if genotypeSearchIndex == nil {
            genotypeSearchIndex = buildGenotypeSearchIndex(result: result)
            searchIndexBuildCount += 1
        }
        searchQueryCount += 1
        let matches = genotypeSearchIndex?.search(query) ?? .empty
        latestGenotypeSearchResult = matches
        latestGenotypeSearchQuery = query
        return matches
    }

    private func buildGenotypeSearchIndex(
        result: ONTGenotypeResultBundleData
    ) -> GenotypeSearchIndex {
        let samples = allFilterableSampleNames(result: result).map { sampleID in
            GenotypeSearchIndex.SampleRecord(
                stableID: sampleID,
                metadata: sampleMetadataStore?.records[sampleID] ?? [:]
            )
        }
        let projectedRows = comparisonMatrixConfigured
            ? comparisonMatrix.sharedSearchProjectedRows()
            : projectedSearchRows(result: result)
        return GenotypeSearchIndex(
            samples: samples,
            projectedRows: projectedRows,
            annotationsAndComments: searchAnnotationAndCommentRecords(),
            hasHaplotypingResult: hasHaplotypingResult,
            haplotypeCarriers: { [weak self] in
                self?.searchHaplotypeCarrierRecords() ?? []
            }
        )
    }

    private func projectedSearchRows(
        result: ONTGenotypeResultBundleData
    ) -> [GenotypeSearchIndex.ProjectedRowRecord] {
        let knownRows = result.locusSummaries.flatMap(\.sharedCalls)
        let settings = displayState.mhcCandidateDisplaySettings
            ?? annotationStore?.sidecar.settings.mhcCandidateDisplay
            ?? .default
        let rows = GenotypeCandidateMatrixProjection.rows(
            knownRows: knownRows,
            candidateDocument: validatedMHCCandidateDocument(from: result),
            settings: settings,
            usesBiologicalAlleleOrder:
                result.manifest.kind == "full-length-ont-mhc-genotype"
        )
        let referenceMetadata = result.referenceMetadata
        let visibleReferenceFieldKeys =
            GenotypeComparisonMatrixView.searchVisibleReferenceFieldKeys(
                for: referenceMetadata
            )
        return rows.map { row in
            let record = referenceMetadata?.recordsBySequenceName[row.genotype] ?? [:]
            let visibleRecord = record.filter {
                visibleReferenceFieldKeys.contains($0.key)
            }
            let displayedAllele: String = {
                guard row.population == .known,
                      let alleleFieldKey = referenceMetadata?.alleleFieldKey,
                      let value = record[alleleFieldKey],
                      !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    return row.genotype
                }
                return value
            }()
            return GenotypeSearchIndex.ProjectedRowRecord(
                id: row.id,
                displayedAllele: displayedAllele,
                rawGenotype: row.genotype,
                locus: row.locus,
                stableClusterID: row.stableClusterID,
                identityAliases: !hasHaplotypingResult
                    && result.provisionalExon2SequencesByGenotype[row.genotype] != nil
                    ? ["Provisional exon 2"]
                    : [],
                visibleReferenceMetadata: visibleRecord,
                carrierSampleIDs: Set(row.sampleSupport.map(\.sample))
            )
        }
    }

    private func searchAnnotationAndCommentRecords()
        -> [GenotypeSearchIndex.AnnotationOrCommentRecord] {
        guard let sidecar = annotationStore?.sidecar else { return [] }
        var records = sidecar.sampleNotes.map {
            GenotypeSearchIndex.AnnotationOrCommentRecord(
                target: .sample($0.sample),
                text: $0.body
            )
        }
        records.append(contentsOf: sidecar.cellComments.map {
            GenotypeSearchIndex.AnnotationOrCommentRecord(
                target: .sample($0.sample),
                text: $0.body
            )
        })
        records.append(contentsOf: sidecar.resolvedMatrixComments.values.compactMap {
            comment in
            let target: GenotypeSearchIndex.AnnotationOrCommentRecord.Target
            switch comment.target {
            case let .column(sample):
                target = .sample(sample)
            case let .row(locus, genotype, stableClusterID):
                target = .row(searchRowID(
                    locus: locus,
                    genotype: genotype,
                    stableClusterID: stableClusterID
                ))
            case let .cell(locus, genotype, sample, stableClusterID):
                target = .cell(
                    rowID: searchRowID(
                        locus: locus,
                        genotype: genotype,
                        stableClusterID: stableClusterID
                    ),
                    sampleID: sample
                )
            }
            return GenotypeSearchIndex.AnnotationOrCommentRecord(
                target: target,
                text: comment.body
            )
        })
        return records
    }

    private func searchRowID(
        locus: String,
        genotype: String,
        stableClusterID: String?
    ) -> GenotypeCandidateMatrixRowID {
        if let stableClusterID {
            return .candidate(stableClusterID: stableClusterID)
        }
        return .known(locus: locus, genotype: genotype)
    }

    private func searchHaplotypeCarrierRecords()
        -> [GenotypeSearchIndex.HaplotypeCarrierRecord] {
        guard hasHaplotypingResult,
              let analysis = activeHaplotypeAnalysis() else {
            return []
        }
        searchHaplotypeRecordBuildCount += 1
        struct HaplotypeKey: Hashable {
            let name: String
            let locus: String
        }
        var carriersByHaplotype: [HaplotypeKey: Set<String>] = [:]
        for sample in analysis.samples {
            for call in sample.calls {
                let effective = effectiveHaplotypeCall(
                    sample: sample.sample,
                    call: call
                )
                for name in [effective.h1, effective.h2]
                where !name.isEmpty && name != "-" {
                    carriersByHaplotype[
                        HaplotypeKey(name: name, locus: call.locus),
                        default: []
                    ].insert(sample.sample)
                }
            }
        }
        return carriersByHaplotype.map { key, sampleIDs in
            GenotypeSearchIndex.HaplotypeCarrierRecord(
                name: key.name,
                locus: key.locus,
                carrierSampleIDs: sampleIDs
            )
        }
    }

    private func sharedSearchCarrierSampleIDs(
        for matches: GenotypeSearchIndex.Result
    ) -> Set<String> {
        switch matches.mode {
        case .none:
            return []
        case .sample:
            return !matches.sampleIdentityAndMetadataIDs.isEmpty
                ? matches.sampleIdentityAndMetadataIDs
                : matches.annotationAndCommentSampleIDs
        case .projectedRow:
            return !matches.projectedRowIDs.isEmpty
                ? matches.alleleCarrierSampleIDs
                : matches.annotationAndCommentCarrierSampleIDs
        case .haplotypeCarrier:
            return matches.haplotypeCarrierSampleIDs
        }
    }

    private func sharedSearchConstraints(
        for matches: GenotypeSearchIndex.Result,
        baseAllowedSampleIDs: Set<String>
    ) -> SharedSearchConstraints {
        switch matches.mode {
        case .none:
            return SharedSearchConstraints(
                allowedSampleIDs: [],
                projectedRowIDs: nil
            )
        case .sample, .haplotypeCarrier:
            return SharedSearchConstraints(
                allowedSampleIDs: baseAllowedSampleIDs.intersection(
                    sharedSearchCarrierSampleIDs(for: matches)
                ),
                projectedRowIDs: nil
            )
        case .projectedRow:
            let rowIDs = !matches.projectedRowIDs.isEmpty
                ? matches.projectedRowIDs
                : matches.annotationAndCommentRowIDs
            return SharedSearchConstraints(
                allowedSampleIDs: baseAllowedSampleIDs,
                projectedRowIDs: rowIDs
            )
        }
    }

    private func metadataMatches(sampleId: String, searchText: String) -> Bool {
        guard let record = sampleMetadataStore?.records[sampleId] else { return false }
        if let query = metadataFieldQuery(from: searchText) {
            return record.contains { key, value in
                key.localizedCaseInsensitiveContains(query.field)
                    && value.localizedCaseInsensitiveContains(query.value)
            }
        }
        return record.contains { key, value in
            key.localizedCaseInsensitiveContains(searchText)
                || value.localizedCaseInsensitiveContains(searchText)
        }
    }

    private func metadataFieldQuery(from searchText: String) -> (field: String, value: String)? {
        let separators = ["=", ":"]
        for separator in separators {
            guard let range = searchText.range(of: separator) else { continue }
            let field = String(searchText[..<range.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
            let value = String(searchText[range.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !field.isEmpty, !value.isEmpty else { continue }
            if field.range(of: #"^M[0-9]+$"#, options: .regularExpression) != nil { continue }
            return (field, value)
        }
        return nil
    }

    private func annotationTextMatches(sampleId: String, searchText: String) -> Bool {
        guard let sidecar = annotationStore?.sidecar else { return false }
        let notes = sidecar.sampleNotes
            .filter { $0.sample == sampleId }
            .map(\.body)
        let comments = sidecar.cellComments
            .filter { $0.sample == sampleId }
            .map(\.body)
        return (notes + comments).contains {
            $0.localizedCaseInsensitiveContains(searchText)
        }
    }


    private func rebuildCohortSummary() {
#if DEBUG
        testingCohortSummaryRebuildCount += 1
#endif
        guard let result else {
            cohortSummaryPanel.configure(summary: .init(
                qcCounts: [],
                errorTypeCounts: [],
                annotationCounts: [],
                outlierSamples: [],
                belowThresholdSamples: [],
                belowThresholdValue: displayState.cohortFlagThreshold
            ))
            return
        }
        let qcRaw = result.qcStatusCounts
        let qcCounts: [(String, Int)] = [
            ("OK", qcRaw[.ok, default: 0]),
            ("Low support", qcRaw[.lowSupport, default: 0]),
            ("Needs review", qcRaw[.review, default: 0]),
        ]
        let errorTypeCounts = cohortErrorTypeCounts(for: result)
        let annotationCounts = cohortAnnotationCounts(for: result)
        let outliers = cohortLowCoverageOutliers(for: result)
        let belowThresholdValue = displayState.cohortFlagThreshold
        let belowThreshold = displayState.samplesBelowCohortFlag(
            result.samples.map { ($0.sample, $0.passedUniqueReads) }
        )
        cohortSummaryPanel.configure(summary: .init(
            qcCounts: qcCounts,
            errorTypeCounts: errorTypeCounts,
            annotationCounts: annotationCounts,
            outlierSamples: outliers,
            belowThresholdSamples: belowThreshold,
            belowThresholdValue: belowThresholdValue,
            isReadOnlyBundle: annotationStore?.isReadOnly ?? false
        ))
    }

    /// Returns sample IDs whose `passedUniqueReads` are more than one standard
    /// deviation below the cohort mean. Used by the Cohort Summary panel as a
    /// quick way to flag re-run candidates without forcing the analyst to
    /// open a per-sample read-count table.
    private func cohortLowCoverageOutliers(for result: ONTGenotypeResultBundleData) -> [String] {
        let pairs = result.samples.map { ($0.sample, Double($0.passedUniqueReads)) }
        guard pairs.count >= 4 else { return [] }
        let mean = pairs.reduce(0.0) { $0 + $1.1 } / Double(pairs.count)
        let variance = pairs.reduce(0.0) { $0 + ($1.1 - mean) * ($1.1 - mean) } / Double(pairs.count)
        let stddev = variance.squareRoot()
        guard stddev > 0 else { return [] }
        let threshold = mean - stddev
        return pairs
            .filter { $0.1 < threshold }
            .sorted { $0.1 < $1.1 }
            .map(\.0)
    }

    private func orderedLoci(from analysis: GenotypeHaplotypeAnalysis) -> [String] {
        guard let firstSample = analysis.samples.first else { return [] }
        return firstSample.calls.map(\.locus)
    }

    private func effectiveIncludedLoci(
        for analysis: GenotypeHaplotypeAnalysis,
        observed: GenotypeObservedLociIndex? = nil
    ) -> [String] {
        let analyzedLoci = orderedLoci(from: analysis)
        let baseLoci = displayState.showsAncillaryLoci
            ? (observed?.loci ?? analyzedLoci)
            : analyzedLoci
        let included = displayState.includedLoci ?? defaultIncludedLoci(for: analysis)
        return baseLoci.filter { included.contains($0) }
    }

    private func defaultIncludedLoci(for analysis: GenotypeHaplotypeAnalysis) -> Set<String> {
        var included = Set(orderedLoci(from: analysis))
        if haplotypeAnalysisLooksLikeMCM(analysis) {
            included.remove("MHC-E")
        }
        return included
    }

    private func haplotypeAnalysisLooksLikeMCM(_ analysis: GenotypeHaplotypeAnalysis) -> Bool {
        let metadata = [
            analysis.definitionSetID,
            analysis.definitionSetName,
            analysis.assayID,
        ]
        if metadata.contains(where: { $0.localizedCaseInsensitiveContains("mcm") }) {
            return true
        }
        return Set(orderedLoci(from: analysis)).isSuperset(of: ["MHC-A", "MHC-B", "MHC-DR"])
    }

    private func outlineTapeSlots(
        for sample: GenotypeHaplotypeSampleAnalysis,
        loci: [String],
        observed: GenotypeObservedLociIndex? = nil
    ) -> [GenotypeHaplotypeTapeView.Slot] {
        let callsByLocus = Dictionary(uniqueKeysWithValues: sample.calls.map { ($0.locus, $0) })
        let observedForSample = observed?.observedCallsBySampleAndLocus[sample.sample] ?? [:]
        let sampleCalls = callsBySample[sample.sample] ?? []
        let sampleCallIndex = callIndexBySample[sample.sample] ?? callIndex(for: sampleCalls)
        let locusDefinitionsByName = (result.flatMap(definitionSetForResult)?.locusDefinitions ?? [])
            .reduce(into: [String: GenotypeHaplotypeLocusDefinition]()) { definitions, locusDefinition in
                definitions[locusDefinition.locus] = locusDefinition
            }
        let readTotalsByLocus = sampleCalls.reduce(into: [String: Int]()) { totals, call in
            totals[call.locusGroup, default: 0] += max(0, call.passedUniqueReads)
        }
        return loci.map { locus -> GenotypeHaplotypeTapeView.Slot in
            if let call = callsByLocus[locus] {
                let effective = effectiveHaplotypeCall(sample: sample.sample, call: call)
                let h1Manual = hasManualHaplotypeAssignment(sample: sample.sample, locus: call.locus, slot: .h1)
                let h1Overridden = hasCallOverride(sample: sample.sample, locus: call.locus, slot: .h1)
                let h1 = outlineCell(
                    for: effective.h1,
                    status: effective.status,
                    isWeakSupport: !h1Manual && !h1Overridden && isWeakAutomatedHaplotype(
                        effective.h1,
                        in: call,
                        sampleCalls: sampleCalls,
                        sampleCallIndex: sampleCallIndex,
                        locusDefinition: locusDefinitionsByName[call.locus],
                        locusTotal: readTotalsByLocus[call.locus, default: 0]
                    ),
                    isManual: h1Manual
                )
                let displayedH2 = normalizedHomozygousSecondHaplotype(
                    h1: effective.h1,
                    h2: effective.h2,
                    status: effective.status
                )
                let h2Manual = hasManualHaplotypeAssignment(sample: sample.sample, locus: call.locus, slot: .h2)
                let h2Overridden = hasCallOverride(sample: sample.sample, locus: call.locus, slot: .h2)
                let h2 = outlineCell(
                    for: displayedH2,
                    status: effective.status,
                    isWeakSupport: !h2Manual && !h2Overridden && call.haplotype2 == displayedH2 && isWeakAutomatedHaplotype(
                        displayedH2,
                        in: call,
                        sampleCalls: sampleCalls,
                        sampleCallIndex: sampleCallIndex,
                        locusDefinition: locusDefinitionsByName[call.locus],
                        locusTotal: readTotalsByLocus[call.locus, default: 0]
                    ),
                    isManual: h2Manual
                )
                return GenotypeHaplotypeTapeView.Slot(locus: locus, h1: h1, h2: h2)
            }
            // Locus wasn't part of the haplotype analysis; show unanalyzed
            // status when raw reads support it, otherwise truly empty.
            let observedCount = observedForSample[locus]?.count ?? 0
            if observedCount > 0 {
                let cell: GenotypeHaplotypeTapeView.Cell = .unanalyzed(observedGenotypes: observedCount)
                return GenotypeHaplotypeTapeView.Slot(locus: locus, h1: cell, h2: cell)
            }
            return GenotypeHaplotypeTapeView.Slot(locus: locus, h1: .empty, h2: .empty)
        }
    }

    private func normalizedHomozygousSecondHaplotype(
        h1: String,
        h2: String,
        status: GenotypeHaplotypeCallStatus
    ) -> String {
        guard status == .called || status == .notAssayed || status == .specialCase else { return h2 }
        guard h2.isEmpty || h2 == "-" else { return h2 }
        guard !h1.isEmpty, h1 != "-", !h1.hasPrefix("ERR") else { return h2 }
        return h1
    }

    private func effectiveHaplotypeCall(
        sample sampleId: String,
        call: GenotypeHaplotypeLocusCall
    ) -> (h1: String, h2: String, status: GenotypeHaplotypeCallStatus) {
        let h1 = displayedCallName(sample: sampleId, locus: call.locus, slot: .h1, fallback: call.haplotype1)
        let h2 = displayedCallName(sample: sampleId, locus: call.locus, slot: .h2, fallback: call.haplotype2)
        let hasOverride = hasCallOverride(sample: sampleId, locus: call.locus, slot: .h1)
            || hasCallOverride(sample: sampleId, locus: call.locus, slot: .h2)
            || hasManualHaplotypeAssignment(sample: sampleId, locus: call.locus, slot: .h1)
            || hasManualHaplotypeAssignment(sample: sampleId, locus: call.locus, slot: .h2)
        let hasUnresolvedOverride = h1 == GenotypeHaplotypeOverrideTargets.unresolved
            || h2 == GenotypeHaplotypeOverrideTargets.unresolved
        if hasOverride && !hasUnresolvedOverride && !h1.hasPrefix("ERR") && !h2.hasPrefix("ERR") {
            return (h1, h2, .called)
        }
        return (h1, h2, call.status)
    }

    private func outlineCell(
        for name: String,
        status: GenotypeHaplotypeCallStatus,
        isWeakSupport: Bool = false,
        isManual: Bool = false
    ) -> GenotypeHaplotypeTapeView.Cell {
        if status == .notAssayed {
            return .notAssayed(label: name.isEmpty ? "Not assayed" : name)
        }
        if name == GenotypeHaplotypeOverrideTargets.unresolved {
            return .error(label: name)
        }
        if name == "-" || name.isEmpty {
            return .empty
        }
        if status != .called && status != .notAssayed && status != .specialCase {
            return .error(label: name)
        }
        let token = HaplotypeColorToken.assigned(forName: name)
        if isManual {
            return .manual(tokenIndex: token.canonicalIndex, label: name)
        }
        if isWeakSupport {
            return .weakReference(tokenIndex: token.canonicalIndex, label: name)
        }
        return .reference(tokenIndex: token.canonicalIndex, label: name)
    }

    private func isWeakAutomatedHaplotype(
        _ haplotypeName: String,
        in locusCall: GenotypeHaplotypeLocusCall,
        sampleCalls: [ONTGenotypeCall],
        sampleCallIndex: CallIndex,
        locusDefinition: GenotypeHaplotypeLocusDefinition?,
        locusTotal: Int
    ) -> Bool {
        guard locusCall.status == .called || locusCall.status == .specialCase else { return false }
        guard !haplotypeName.isEmpty,
              haplotypeName != "-",
              !haplotypeName.hasPrefix("ERR:"),
              haplotypeName != GenotypeHaplotypeOverrideTargets.unresolved else {
            return false
        }
        guard let matched = locusCall.matchedHaplotypes.first(where: { $0.name == haplotypeName }) else {
            return false
        }
        let supportReads = matched.observedDiagnosticAlleles.reduce(0) { total, allele in
            let identifier = Self.genotypeIdentifier(allele)
            let indexedReads = sampleCallIndex.readsByIdentifier[identifier]
            return total + (indexedReads ?? diagnosticReads(
                for: allele,
                in: sampleCalls,
                locusDefinition: locusDefinition
            ))
        }
        guard supportReads > 0 else { return false }
        if supportReads < 5 {
            return true
        }
        guard locusTotal > 0 else { return false }
        return Double(supportReads) / Double(locusTotal) < 0.05
    }

    /// Count of distinct review-worthy notes on a sample's calls. Used by the
    /// Outline to render a progressive-disclosure alert glyph instead of the
    /// full notes text (which dominated the row visually).
    private func outlineNoteIssueCount(
        for sample: GenotypeHaplotypeSampleAnalysis,
        effectiveCalls: [(locus: String, h1: String, h2: String, status: GenotypeHaplotypeCallStatus, observedGenotypeCount: Int, observedGenotypes: [String])]
    ) -> Int {
        let clearWholeMHCHomozygote = isClearWholeMHCHomozygote(effectiveCalls)
        let reviewCount = effectiveCalls.filter {
            !isCallReviewResolved(sample: sample.sample, locus: $0.locus)
                && haplotypeStatusNeedsReview(
                $0.status,
                observedGenotypeCount: $0.observedGenotypeCount,
                suppressMultiallelicReview: clearWholeMHCHomozygote
            )
        }.count
        let specialCount = effectiveCalls.filter { $0.status == .specialCase }.count
        return reviewCount + specialCount
    }

    private func outlineCommentSummary(
        for sample: GenotypeHaplotypeSampleAnalysis,
        effectiveCalls: [(locus: String, h1: String, h2: String, status: GenotypeHaplotypeCallStatus, observedGenotypeCount: Int, observedGenotypes: [String])]
    ) -> String {
        let clearWholeMHCHomozygote = isClearWholeMHCHomozygote(effectiveCalls)
        let reviewCalls = effectiveCalls.filter {
            !isCallReviewResolved(sample: sample.sample, locus: $0.locus)
                && haplotypeStatusNeedsReview(
                $0.status,
                observedGenotypeCount: $0.observedGenotypeCount,
                suppressMultiallelicReview: clearWholeMHCHomozygote
            )
        }
        if !reviewCalls.isEmpty {
            return reviewCalls.map { "\($0.locus): \(haplotypeStatusLabel($0.status))" }
                .joined(separator: "; ")
        }
        if let firstSpecial = effectiveCalls.first(where: { $0.status == .specialCase }) {
            return "\(firstSpecial.locus): special case"
        }
        return ""
    }

    private func cohortErrorTypeCounts(for result: ONTGenotypeResultBundleData) -> [(String, Int)] {
        guard let analysis = activeHaplotypeAnalysis() else { return [] }
        var tmh = 0
        var noHap = 0
        var tmg = 0
        for sample in analysis.samples {
            for call in sample.calls {
                switch call.status {
                case .tooManyHaplotypes: tmh += 1
                case .noHaplotype: noHap += 1
                case .tooManyGenotypes: tmg += 1
                case .called, .notAssayed, .specialCase: break
                }
            }
        }
        return [
            ("TMH", tmh),
            ("NO HAP", noHap),
            ("TMG", tmg),
        ]
    }

    private func cohortAnnotationCounts(for result: ONTGenotypeResultBundleData) -> [(String, Int)] {
        // Read from the live in-memory annotation store rather than re-loading
        // from disk. Un-persisted writes happening on this turn show up
        // immediately, and we honor the "inspector is the sidecar's sole
        // author" invariant.
        let sidecar = annotationStore?.sidecar ?? GenotypeAnnotationSidecar.empty(generatedAt: "")
        return [
            ("Overrides", sidecar.callOverrides.count),
            ("Comments", sidecar.cellComments.count + sidecar.sampleNotes.count),
            ("Highlights", sidecar.cellHighlights.count + sidecar.rowHighlights.count),
        ]
    }

    private func handleOutlineRowSelected(_ animalId: String) {
        guard let row = outlineRowsBySample[animalId] else { return }
        currentSelectedSample = animalId
        currentSelectedLocus = nil
        syncOutlineReviewSelection()
        let detailRows: [(String, String)] = [
            ("Animal", animalId),
            ("Loci", row.loci.joined(separator: ", ")),
            ("Block", outlineBlockLabel(row.blockKind)),
            ("Notes", row.commentSummary.isEmpty ? "None" : row.commentSummary),
        ]
        let state = GenotypeResultSelectionState(
            title: animalId,
            subtitle: "Outline sample",
            detailRows: detailRows,
            highlightTarget: nil,
            highlightColor: nil,
            highlightStyle: .default,
            animalId: animalId
        )
        publishSelectionState(state)
        if selectedLens == .review {
            updateCallEvidence()
        } else {
            syncOutlineReviewSelection()
        }
        // Clicking a row in the Outline lens shouldn't auto-open the
        // detail sheet — the user expects the cell-click inspector, or
        // the explicit "Edit calls…" button. Auto-opening a modal sheet
        // on every row tap is too aggressive.
    }

    private func selectCellEvidence(animalId: String, locus: String) {
        guard let row = outlineRowsBySample[animalId] else { return }
        currentSelectedSample = animalId
        currentSelectedLocus = locus
        syncOutlineReviewSelection()
        let detailRows: [(String, String)] = [
            ("Animal", animalId),
            ("Selected locus", locus),
            ("Loci", row.loci.joined(separator: ", ")),
            ("Block", outlineBlockLabel(row.blockKind)),
            ("Notes", row.commentSummary.isEmpty ? "None" : row.commentSummary),
        ]
        publishSelectionState(.init(
            title: animalId,
            subtitle: "Review cell \(locus)",
            detailRows: detailRows,
            highlightTarget: nil,
            highlightColor: nil,
            highlightStyle: .default,
            animalId: animalId
        ))
        if selectedLens != .review {
            showLens(.review, autoActivateReviewCohort: false)
            onDisplayStateChanged?(displayState)
        } else {
            if callEvidenceHost == nil {
                installCallEvidenceHost()
            }
            updateCallEvidence()
        }
    }

    private func applyOverrideFromInspector(haplotype: String, slot: HaplotypeSlot) {
        applyOverridesFromInspector([.init(slot: slot, haplotypeName: haplotype)])
    }

    private func applyOverridesFromInspector(_ requests: [GenotypeCallEvidenceView.HaplotypeOverrideRequest]) {
        guard let store = annotationStore else { return }
        guard let evidence = callEvidence else { return }
        let author = annotationAuthorProvider()
        let requests = requests.filter { !$0.haplotypeName.isEmpty }
        guard !requests.isEmpty else { return }
        let rawCall = rawLocusCall(sample: evidence.sample, locus: evidence.locus)
        do {
            for request in requests {
                let originalCall = request.slot == .h1
                    ? (rawCall?.haplotype1 ?? evidence.h1Name)
                    : (rawCall?.haplotype2 ?? evidence.h2Name)
                let displayOriginal = originalCall.isEmpty ? "-" : originalCall
                try store.applyOverride(
                    sample: evidence.sample,
                    locus: evidence.locus,
                    slot: request.slot,
                    originalCall: originalCall,
                    overrideCall: request.haplotypeName,
                    reasonTag: .misCall,
                    rationale: "Replaced \(evidence.locus) \(request.slot.displayName) \(displayOriginal) -> \(request.haplotypeName) from Review inspector candidate matrix.",
                    author: author
                )
            }
            markCurrentWorkbookDirty(
                requiresFullUpdate: true,
                legacyStatus: "current.xlsx does not include workbook changes."
            )
            refreshAfterHaplotypeOverride()
        } catch {
            presentSheetAlert(error: error)
        }
    }

    private func rawLocusCall(sample sampleId: String, locus: String) -> GenotypeHaplotypeLocusCall? {
        guard let analysis = activeHaplotypeAnalysis(),
              let sample = analysis.samples.first(where: { $0.sample == sampleId }) else {
            return nil
        }
        return sample.calls.first { $0.locus == locus }
    }

    private func isCallReviewResolved(sample sampleId: String, locus: String) -> Bool {
        guard let sidecar = annotationStore?.sidecar else { return false }
        if let sampleStatus = sidecar.sampleStatusFlags.first(where: { $0.sample == sampleId })?.value {
            switch sampleStatus {
            case .confirmed, .reviewed:
                return true
            case .needsReview, .unflagged:
                break
            }
        }
        let statusValues = sidecar.callStatusFlags
            .filter { $0.sample == sampleId && $0.locus == locus }
            .map(\.value)
        guard !statusValues.isEmpty else { return false }
        if statusValues.contains(.needsReview) {
            return false
        }
        return statusValues.allSatisfy { $0 == .confirmed || $0 == .reviewed }
    }

    private func confirmCurrentCallEvidence() {
        guard let store = annotationStore, let evidence = callEvidence else { return }
        let author = annotationAuthorProvider()
        let h1 = evidence.h1Name.isEmpty ? evidence.callName : evidence.h1Name
        let h2 = evidence.h2Name.isEmpty || evidence.h2Name == "-" ? h1 : evidence.h2Name
        do {
            try store.confirmCall(sample: evidence.sample, locus: evidence.locus, h1: h1, h2: h2, author: author)
            rebuildHaplotypeLens()
            rebuildOutline()
            rebuildHaplotypeMatrix()
            rebuildCohortSummary()
            applyComparisonMatrixCohortFilter()
            if selectedLens == .review {
                advanceToNextReviewSample(fallbackToAll: false, afterLocus: evidence.locus)
            } else {
                updateCallEvidence()
            }
            if selectedLens == .audit {
                rebuildArtifactLens()
            }
            onAnnotationSidecarChanged?(store.sidecar)
        } catch {
            presentSheetAlert(error: error)
        }
    }

    private func skipToNextReviewSample() {
        advanceToNextReviewSample(fallbackToAll: true, afterLocus: currentSelectedLocus)
    }

    private func advanceToNextReviewSample(fallbackToAll: Bool, afterLocus: String? = nil) {
        guard !outlineRowOrder.isEmpty else { return }
        if let currentSelectedSample,
           let nextLocus = nextUnresolvedReviewLocus(
            for: currentSelectedSample,
            after: afterLocus
           ) {
            selectCellEvidence(animalId: currentSelectedSample, locus: nextLocus)
            return
        }
        let reviewOrder = outlineRowOrder.filter { sample in
            !(unresolvedReviewLoci(for: sample).isEmpty)
                || (outlineRowsBySample[sample]?.noteIssueCount ?? 0) > 0
        }
        let order = reviewOrder.isEmpty && fallbackToAll ? outlineRowOrder : reviewOrder
        guard !order.isEmpty else {
            currentSelectedSample = nil
            currentSelectedLocus = nil
            updateCallEvidence()
            return
        }
        let currentIndex = currentSelectedSample.flatMap { order.firstIndex(of: $0) }
        let nextIndex = currentIndex.map { $0 + 1 } ?? order.startIndex
        let wrappedIndex = nextIndex < order.endIndex ? nextIndex : order.startIndex
        let nextSample = order[wrappedIndex]
        guard let row = outlineRowsBySample[nextSample] else { return }
        let nextLocus = nextUnresolvedReviewLocus(for: nextSample, after: nil)
            ?? currentSelectedLocus.flatMap { row.loci.contains($0) ? $0 : nil }
            ?? row.loci.first
        guard let nextLocus else { return }
        selectCellEvidence(animalId: nextSample, locus: nextLocus)
    }

    private func nextUnresolvedReviewLocus(for sampleId: String, after locus: String?) -> String? {
        let unresolved = Set(unresolvedReviewLoci(for: sampleId))
        guard !unresolved.isEmpty else { return nil }
        let rowLoci = outlineRowsBySample[sampleId]?.loci ?? unresolved.sorted()
        if let locus,
           let index = rowLoci.firstIndex(of: locus) {
            for candidate in rowLoci.suffix(from: rowLoci.index(after: index)) where unresolved.contains(candidate) {
                return candidate
            }
        }
        return rowLoci.first { unresolved.contains($0) } ?? unresolved.sorted().first
    }

    private func unresolvedReviewLoci(for sampleId: String) -> [String] {
        guard let analysis = activeHaplotypeAnalysis(),
              let sample = analysis.samples.first(where: { $0.sample == sampleId }) else {
            return []
        }
        let effectiveCalls = sample.calls.map { call in
            let effective = effectiveHaplotypeCall(sample: sampleId, call: call)
            return (
                locus: call.locus,
                h1: effective.h1,
                h2: effective.h2,
                status: effective.status,
                observedGenotypeCount: call.observedGenotypeCount,
                observedGenotypes: call.observedGenotypes
            )
        }
        let suppressMultiallelicReview = isClearWholeMHCHomozygote(effectiveCalls)
        return effectiveCalls.compactMap { call in
            guard !isCallReviewResolved(sample: sampleId, locus: call.locus),
                  haplotypeStatusNeedsReview(
                    call.status,
                    observedGenotypeCount: call.observedGenotypeCount,
                    suppressMultiallelicReview: suppressMultiallelicReview
                  ) else {
                return nil
            }
            return call.locus
        }
    }

    private func presentSampleDetailSheet(forAnimal animalId: String) {
        guard let result, let analysis = activeHaplotypeAnalysis() else { return }
        guard let sampleAnalysis = analysis.samples.first(where: { $0.sample == animalId }) else { return }
        let rows: [GenotypeSampleDetailSheet.CallRow] = sampleAnalysis.calls.flatMap { call -> [GenotypeSampleDetailSheet.CallRow] in
            let effective = effectiveHaplotypeCall(sample: animalId, call: call)
            return [
                GenotypeSampleDetailSheet.CallRow(
                    locus: call.locus, slot: .h1,
                    callName: effective.h1, status: effective.status,
                    observedGenotypeCount: call.observedGenotypeCount
                ),
                GenotypeSampleDetailSheet.CallRow(
                    locus: call.locus, slot: .h2,
                    callName: effective.h2, status: effective.status,
                    observedGenotypeCount: call.observedGenotypeCount
                ),
            ]
        }
        let overrides = annotationStore?.sidecar.callOverrides
            .filter { $0.sample == animalId } ?? []
        let definitionSet = definitionSetForResult(result)
        let allowedTargets: (String) -> [String] = { locus in
            guard let definitionSet else { return [] }
            let names = definitionSet.locusDefinitions
                .first { $0.locus == locus }?
                .haplotypes
                .map(\.name) ?? []
            return GenotypeHaplotypeOverrideTargets.expandedTargets(
                from: names + ["A1_063", "-"],
                includeUnknown: true
            )
        }

        let hostingController = NSHostingController(
            rootView: GenotypeSampleDetailSheet(
                sampleId: animalId,
                rows: rows,
                overrides: overrides,
                allowedTargetsForLocus: allowedTargets,
                onSaveOverride: { [weak self] row, draft in
                    self?.saveOverride(forAnimal: animalId, row: row, draft: draft)
                },
                onClearOverride: { [weak self] row in
                    self?.clearOverride(forAnimal: animalId, row: row)
                },
                onDismiss: { [weak self] in
                    self?.dismissSampleDetailSheet()
                }
            )
        )
        sampleDetailHostingController = hostingController
        presentAsSheet(hostingController)
    }

    private func dismissSampleDetailSheet() {
        if let hosting = sampleDetailHostingController {
            dismiss(hosting)
            sampleDetailHostingController = nil
        }
    }

    private func saveOverride(forAnimal animalId: String,
                              row: GenotypeSampleDetailSheet.CallRow,
                              draft: GenotypeOverrideSection.OverrideDraft) {
        guard let store = annotationStore else { return }
        let author = annotationAuthorProvider()
        let originalCall = row.callName
        do {
            try store.applyOverride(
                sample: animalId,
                locus: row.locus,
                slot: row.slot,
                originalCall: originalCall,
                overrideCall: draft.target,
                reasonTag: draft.reason,
                rationale: draft.rationale,
                author: author
            )
        } catch {
            presentSheetAlert(error: error)
            return
        }
        markCurrentWorkbookDirty(
            requiresFullUpdate: true,
            legacyStatus: "current.xlsx does not include workbook changes."
        )
        refreshAfterHaplotypeOverride()
        // Re-present the sheet with fresh state so the analyst can keep working.
        dismissSampleDetailSheet()
        presentSampleDetailSheet(forAnimal: animalId)
    }

    private func clearOverride(forAnimal animalId: String,
                               row: GenotypeSampleDetailSheet.CallRow) {
        guard let store = annotationStore else { return }
        let author = annotationAuthorProvider()
        do {
            try store.clearOverride(sample: animalId, locus: row.locus, slot: row.slot, author: author)
        } catch {
            presentSheetAlert(error: error)
            return
        }
        markCurrentWorkbookDirty(
            requiresFullUpdate: true,
            legacyStatus: "current.xlsx does not include workbook changes."
        )
        refreshAfterHaplotypeOverride()
        dismissSampleDetailSheet()
        presentSampleDetailSheet(forAnimal: animalId)
    }

    private func refreshAfterHaplotypeOverride() {
        invalidateGenotypeSearchIndex()
        rebuildHaplotypeLens()
        rebuildOutline()
        rebuildHaplotypeMatrix()
        rebuildCohortSummary()
        applyComparisonMatrixCohortFilter()
        updateCallEvidence()
        if selectedLens == .audit {
            rebuildArtifactLens()
        }
        if let sidecar = annotationStore?.sidecar {
            onAnnotationSidecarChanged?(sidecar)
        }
    }

    private func presentSheetAlert(error: Error) {
        if let window = view.window ?? NSApp.keyWindow {
            NSAlert(error: error).beginSheetModal(for: window, completionHandler: { _ in })
        } else {
            NSApp.presentError(error)
        }
    }

    public var hasUnsavedManualHaplotypeDraft: Bool {
        manualHaplotypeDraftCoordinator.hasUnsavedDraft
    }

    public var requiresManualHaplotypeTransitionCoordination: Bool {
        hasUnsavedManualHaplotypeDraft
            || manualHaplotypeDraftCoordinator.hasPendingResolution
            || manualHaplotypeTransitionMutationCoordinator
                .hasPendingMutation
    }

    public func prepareForManualHaplotypeTransition(
        _ transition: GenotypeManualHaplotypeDraftCoordinator.Transition
    ) async -> Bool {
        await manualHaplotypeDraftCoordinator.prepare(
            for: transition
        ) { [weak self] in
            guard let self else { return .cancel }
            if let manualHaplotypeDraftDecisionProvider {
                return await manualHaplotypeDraftDecisionProvider(transition)
            }
            return await presentManualHaplotypeDraftDecision(
                for: transition
            )
        }
    }

    public func resolveManualHaplotypeTransition(
        _ transition: GenotypeManualHaplotypeDraftCoordinator.Transition
    ) async -> GenotypeManualHaplotypeDraftCoordinator.Resolution {
        await manualHaplotypeDraftCoordinator.resolve(
            for: transition
        ) { [weak self] in
            guard let self else { return .cancel }
            if let manualHaplotypeDraftDecisionProvider {
                return await manualHaplotypeDraftDecisionProvider(transition)
            }
            return await presentManualHaplotypeDraftDecision(
                for: transition
            )
        }
    }

    public func commitManualHaplotypeTransition(
        _ resolution: GenotypeManualHaplotypeDraftCoordinator.Resolution
    ) async -> Bool {
        await manualHaplotypeDraftCoordinator.commit(resolution)
    }

    public func prepareManualHaplotypeTransitionCommit(
        _ resolution: GenotypeManualHaplotypeDraftCoordinator.Resolution
    ) async -> Bool {
        await manualHaplotypeDraftCoordinator
            .prepareTransactionalCommit(resolution)
    }

    public func finalizeManualHaplotypeTransitionCommit(
        _ resolution: GenotypeManualHaplotypeDraftCoordinator.Resolution
    ) async -> Bool {
        await manualHaplotypeDraftCoordinator
            .finalizeTransactionalCommit(resolution)
    }

    public func cancelManualHaplotypeTransitionCommit(
        _ resolution: GenotypeManualHaplotypeDraftCoordinator.Resolution
    ) {
        manualHaplotypeDraftCoordinator
            .cancelTransactionalCommit(resolution)
    }

    public func isManualHaplotypeTransitionResolutionCurrent(
        _ resolution: GenotypeManualHaplotypeDraftCoordinator.Resolution
    ) -> Bool {
        manualHaplotypeDraftCoordinator.isCurrent(resolution)
    }

    public var manualHaplotypeDraftRevisionToken: UUID? {
        manualHaplotypeDraftCoordinator.draftRevisionToken
    }

    public func abandonManualHaplotypeTransition(
        _ resolution: GenotypeManualHaplotypeDraftCoordinator.Resolution
    ) {
        manualHaplotypeDraftCoordinator.abandon(resolution)
    }

    @discardableResult
    public func deferManualHaplotypeTransition(
        _ transition: GenotypeManualHaplotypeDraftCoordinator.Transition,
        mutation: @escaping @MainActor () -> Void,
        rejection: @escaping @MainActor () -> Void = {}
    ) -> Bool {
        guard requiresManualHaplotypeTransitionCoordination else {
            return false
        }
        manualHaplotypeTransitionMutationCoordinator.enqueue(
            transition: transition,
            prepare: { [weak self] transition in
                guard let self else { return false }
                return await self.prepareForManualHaplotypeTransition(
                    transition
                )
            },
            mutation: mutation,
            rejection: rejection
        )
        return true
    }

    private func presentManualHaplotypeDraftDecision(
        for transition: GenotypeManualHaplotypeDraftCoordinator.Transition
    ) async -> GenotypeManualHaplotypeDraftDecision {
        guard let window = view.window ?? NSApp.keyWindow else {
            return .cancel
        }
        let alert = NSAlert()
        alert.messageText = "Save Haplotype Assignment Changes?"
        alert.informativeText =
            "The requested \(transition.rawValue) change will close the current sample editor."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Discard Changes")
        alert.addButton(withTitle: "Cancel")
        return await withCheckedContinuation { continuation in
            alert.beginSheetModal(for: window) { response in
                switch response {
                case .alertFirstButtonReturn:
                    continuation.resume(returning: .save)
                case .alertSecondButtonReturn:
                    continuation.resume(returning: .discard)
                default:
                    continuation.resume(returning: .cancel)
                }
            }
        }
    }

    private func definitionSetForResult(_ result: ONTGenotypeResultBundleData) -> GenotypeHaplotypeDefinitionSet? {
        haplotypeDefinitionContext(for: result)?.definition
    }

    private func shouldEagerlyRecomputeHaplotypeAnalysis(for result: ONTGenotypeResultBundleData) -> Bool {
        guard let context = haplotypeDefinitionContext(for: result) else { return false }
        if let analysis = result.haplotypeAnalysis {
            if case .sidecarOverride = context.source {
                let settings = annotationStore?.sidecar.settings
                let activeID = settings?.activeHaplotypeDefinitionSetID?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                let activeAssayID = settings?.activeHaplotypeAssayID?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                let analysisID = analysis.definitionSetID.trimmingCharacters(in: .whitespacesAndNewlines)
                let analysisAssayID = analysis.assayID.trimmingCharacters(in: .whitespacesAndNewlines)
                let definitionChanged = activeID != nil && activeID != analysisID
                let assayChanged = activeAssayID != nil && activeAssayID != analysisAssayID
                return definitionChanged || assayChanged
            }
            return false
        }
        return context.source != .inferredPreview && context.source != .synthesizedBundleAnalysis
    }

    private enum HaplotypeDefinitionSource {
        case sidecarOverride
        case bundleAnalysis
        case synthesizedBundleAnalysis
        case bundleManifest
        case bundleSnapshot
        case inferredPreview

        var displayName: String {
            switch self {
            case .sidecarOverride:
                return "Active bundle setting"
            case .bundleAnalysis:
                return "Bundle analysis"
            case .synthesizedBundleAnalysis:
                return "Bundle analysis"
            case .bundleManifest:
                return "Bundle manifest"
            case .bundleSnapshot:
                return "Bundle definition snapshot"
            case .inferredPreview:
                return "Inferred preview"
            }
        }
    }

    private struct HaplotypeDefinitionContext {
        let definition: GenotypeHaplotypeDefinitionSet
        let source: HaplotypeDefinitionSource
    }

    private func haplotypeDefinitionContext(
        for result: ONTGenotypeResultBundleData
    ) -> (definition: GenotypeHaplotypeDefinitionSet, source: HaplotypeDefinitionSource)? {
        if let cachedHaplotypeDefinitionContext {
            return (cachedHaplotypeDefinitionContext.definition, cachedHaplotypeDefinitionContext.source)
        }
        guard let context = resolveHaplotypeDefinitionContext(for: result) else { return nil }
        cachedHaplotypeDefinitionContext = HaplotypeDefinitionContext(
            definition: context.definition,
            source: context.source
        )
        return context
    }

    private func resolveHaplotypeDefinitionContext(
        for result: ONTGenotypeResultBundleData
    ) -> (definition: GenotypeHaplotypeDefinitionSet, source: HaplotypeDefinitionSource)? {
        let registry = haplotypeDefinitionStore.mergedRegistry()
        if let id = annotationStore?.sidecar.settings.activeHaplotypeDefinitionSetID,
           let definition = registry.definitionSet(
            id: id,
            assayID: annotationStore?.sidecar.settings.activeHaplotypeAssayID
           ) {
            return (definition, .sidecarOverride)
        }
        if let id = result.haplotypeAnalysis?.definitionSetID,
           let definition = registry.definitionSet(id: id, assayID: result.haplotypeAnalysis?.assayID) {
            return (definition, .bundleAnalysis)
        }
        if result.haplotypeAnalysis?.source == .ai,
           let recorded = result.haplotypeAnalysis,
           let synthesized = Self.synthesizedDefinitionSet(from: recorded) {
            return (synthesized, .bundleAnalysis)
        }
        if let id = result.manifest.haplotypeDefinitionSetID,
           let definition = registry.definitionSet(id: id, assayID: result.manifest.haplotypeAssayID) {
            return (definition, .bundleManifest)
        }
        if let definition = GenotypeHaplotypeAnalysisResolver.bundleDefinitionSnapshot(for: result.bundleURL) {
            return (definition, .bundleSnapshot)
        }
        if let id = activeHaplotypeAnalysis()?.definitionSetID,
           let definition = registry.definitionSet(id: id, assayID: activeHaplotypeAnalysis()?.assayID) {
            let inferred = inferredDefinitionSetID(for: result, registry: registry)
            return (definition, inferred == id ? .inferredPreview : .bundleAnalysis)
        }
        if let id = inferredDefinitionSetID(for: result, registry: registry),
           let definition = registry.definitionSet(id: id) {
            return (definition, .inferredPreview)
        }
        // Provenance-only fallback: built-in/global definition scopes were
        // removed, so a result whose recorded definition has no live project
        // bundle would otherwise resolve to nothing. Reconstruct the definition
        // from the analysis's own recorded diagnostic alleles so the diagnostic
        // matrix still renders exactly what was used to make the call.
        if let recorded = result.haplotypeAnalysis,
           let synthesized = Self.synthesizedDefinitionSet(from: recorded) {
            return (synthesized, .synthesizedBundleAnalysis)
        }
        if let recorded = activeHaplotypeAnalysis(),
           let synthesized = Self.synthesizedDefinitionSet(from: recorded) {
            return (synthesized, .synthesizedBundleAnalysis)
        }
        return nil
    }

    /// Reconstructs a `GenotypeHaplotypeDefinitionSet` from a recorded
    /// `GenotypeHaplotypeAnalysis`. The analysis carries, per locus, the matched
    /// haplotype names + their diagnostic alleles, which is exactly the data the
    /// diagnostic-allele matrix needs. Used as a provenance-only display source
    /// when no live definition bundle matches the recorded definition id.
    static func synthesizedDefinitionSet(
        from analysis: GenotypeHaplotypeAnalysis
    ) -> GenotypeHaplotypeDefinitionSet? {
        var orderedLoci: [String] = []
        var sourceLocusByLocus: [String: String] = [:]
        var haplotypesByLocus: [String: [String: [String]]] = [:]
        var haplotypeOrderByLocus: [String: [String]] = [:]

        for sample in analysis.samples {
            for call in sample.calls {
                if haplotypesByLocus[call.locus] == nil {
                    orderedLoci.append(call.locus)
                    haplotypesByLocus[call.locus] = [:]
                    haplotypeOrderByLocus[call.locus] = []
                    sourceLocusByLocus[call.locus] = call.sourceLocus
                }
                for matched in call.matchedHaplotypes {
                    if haplotypesByLocus[call.locus]?[matched.name] == nil {
                        haplotypeOrderByLocus[call.locus]?.append(matched.name)
                    }
                    // Prefer the richest diagnostic-allele list seen for a haplotype.
                    let existing = haplotypesByLocus[call.locus]?[matched.name] ?? []
                    if matched.diagnosticAlleles.count >= existing.count {
                        haplotypesByLocus[call.locus]?[matched.name] = matched.diagnosticAlleles
                    }
                }
                for label in [call.haplotype1, call.haplotype2] {
                    guard label != "-", !label.hasPrefix("ERR:") else { continue }
                    if haplotypesByLocus[call.locus]?[label] == nil {
                        haplotypeOrderByLocus[call.locus]?.append(label)
                        haplotypesByLocus[call.locus]?[label] = []
                    }
                }
            }
        }

        let locusDefinitions: [GenotypeHaplotypeLocusDefinition] = orderedLoci.compactMap { locus in
            guard let names = haplotypeOrderByLocus[locus], !names.isEmpty else { return nil }
            let haplotypes = names.map { name in
                GenotypeHaplotypeDefinition(
                    name: name,
                    diagnosticAlleles: haplotypesByLocus[locus]?[name] ?? []
                )
            }
            return GenotypeHaplotypeLocusDefinition(
                locus: locus,
                sourceLocus: sourceLocusByLocus[locus] ?? locus,
                haplotypes: haplotypes
            )
        }
        guard !locusDefinitions.isEmpty else { return nil }

        return GenotypeHaplotypeDefinitionSet(
            id: analysis.definitionSetID,
            assayID: analysis.assayID,
            displayName: analysis.definitionSetName,
            speciesName: analysis.speciesName,
            speciesCode: "",
            prefix: "",
            locusDefinitions: locusDefinitions
        )
    }

    private func activeHaplotypeDefinitionSetID() -> String? {
        guard let result else {
            return annotationStore?.sidecar.settings.activeHaplotypeDefinitionSetID
        }
        return haplotypeDefinitionContext(for: result)?.definition.id
    }

    private func inferredDefinitionSetID(
        for result: ONTGenotypeResultBundleData,
        registry: GenotypeHaplotypeDefinitionRegistry
    ) -> String? {
        guard result.manifest.haplotypeDefinitionSetID == nil,
              result.haplotypeAnalysis == nil,
              !result.calls.isEmpty else {
            return nil
        }
        let genotypes = result.calls.lazy.map(\.genotype)
        let candidateDefinitions: [GenotypeHaplotypeDefinitionSet]
        if let assayID = result.manifest.haplotypeAssayID,
           registry.assay(id: assayID) != nil {
            candidateDefinitions = registry.definitionSets(assayID: assayID)
        } else {
            candidateDefinitions = registry.assays.flatMap(\.definitionSets)
        }
        let scored = candidateDefinitions
            .map { definitionSet -> (id: String, score: Int) in
                let prefix = definitionSet.prefix
                guard !prefix.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    return (definitionSet.id, 0)
                }
                let score = genotypes.reduce(0) { partial, genotype in
                    partial + (genotype.localizedCaseInsensitiveContains(prefix) ? 1 : 0)
                }
                return (definitionSet.id, score)
            }
            .filter { $0.score > 0 }
            .sorted { lhs, rhs in
                if lhs.score != rhs.score { return lhs.score > rhs.score }
                return lhs.id.localizedStandardCompare(rhs.id) == .orderedAscending
            }
        guard let best = scored.first else { return nil }
        guard scored.dropFirst().first?.score != best.score else { return nil }
        return best.id
    }

    /// Attaches a sidecar snapshot to a base export snapshot when the
    /// annotation store has overrides or audit entries to surface in the
    /// resulting workbook. Pure transformation; no I/O.
    private func attachSidecarSnapshot(
        to base: GenotypeViewportExportSnapshot
    ) -> GenotypeViewportExportSnapshot {
        guard let store = annotationStore else { return base }
        let sidecar = store.sidecar
        let hasMatrixAnnotations = !sidecar.matrixStyles.isEmpty
            || !sidecar.matrixReviews.isEmpty
            || !sidecar.matrixComments.isEmpty
        guard !sidecar.callOverrides.isEmpty || !sidecar.auditLog.isEmpty || hasMatrixAnnotations else { return base }
        let overrides = sidecar.callOverrides.map { o in
            GenotypeAnnotationOverrideEntry(
                sample: o.sample, locus: o.locus, slot: o.slot.rawValue,
                originalCall: o.originalCall, overrideCall: o.overrideCall,
                reasonTag: o.reasonTag.rawValue, rationale: o.rationale,
                author: o.author, timestamp: o.timestamp
            )
        }
        let auditEntries = sidecar.auditLog.map { e in
            GenotypeAnnotationAuditEntry(
                action: e.action,
                sample: e.sample,
                locus: e.locus ?? "",
                slot: e.slot?.rawValue ?? "",
                before: e.before ?? "",
                after: e.after ?? "",
                author: e.author,
                timestamp: e.timestamp
            )
        }
        let annotationSidecarURL = ONTGenotypeResultBundleData.annotationSidecarURL(forBundleAt: base.bundleURL)
        var provenanceInputURLs = base.provenanceInputURLs
        if FileManager.default.fileExists(atPath: annotationSidecarURL.path),
           !provenanceInputURLs.contains(annotationSidecarURL) {
            provenanceInputURLs.append(annotationSidecarURL)
        }
        return GenotypeViewportExportSnapshot(
            bundleURL: base.bundleURL,
            analysisName: base.analysisName,
            lens: base.lens,
            filters: base.filters,
            sampleNames: base.sampleNames,
            rows: base.rows,
            provenanceInputURLs: provenanceInputURLs,
            annotationSidecarURL: FileManager.default.fileExists(atPath: annotationSidecarURL.path)
                ? annotationSidecarURL
                : nil,
            sidecar: GenotypeAnnotationSidecarSnapshot(
                overrides: overrides,
                auditEntries: auditEntries
            )
        )
    }

    private func attachFilterContext(
        to base: GenotypeViewportExportSnapshot
    ) -> GenotypeViewportExportSnapshot {
        let context = exportFilterContext()
        guard !context.isEmpty else { return base }
        return GenotypeViewportExportSnapshot(
            bundleURL: base.bundleURL,
            analysisName: base.analysisName,
            lens: base.lens,
            filters: base.filters.merging(context) { _, contextValue in contextValue },
            sampleNames: base.sampleNames,
            rows: base.rows,
            provenanceInputURLs: base.provenanceInputURLs,
            annotationSidecarURL: base.annotationSidecarURL,
            sidecar: base.sidecar
        )
    }

    private func attachHaplotypeDefinitionProvenanceContext(
        to base: GenotypeViewportExportSnapshot
    ) -> GenotypeViewportExportSnapshot {
        guard let result,
              let definitionID = activeHaplotypeDefinitionSetID() else {
            return base
        }
        var filters = base.filters
        filters["activeHaplotypeDefinitionSetID"] = definitionID
        if let definition = definitionSetForResult(result) {
            filters["activeHaplotypeAssayID"] = definition.assayID
            filters["activeHaplotypeDefinitionName"] = definition.displayName
            if let schemaVersion = definition.schemaVersion {
                filters["activeHaplotypeDefinitionSchemaVersion"] = "\(schemaVersion)"
            }
            if let lastModified = definition.lastModified {
                filters["activeHaplotypeDefinitionLastModified"] = lastModified
            }
        }
        var provenanceInputURLs = base.provenanceInputURLs
        if let url = haplotypeDefinitionStore.definitionURL(for: definitionID),
           FileManager.default.fileExists(atPath: url.path),
           !provenanceInputURLs.contains(url) {
            provenanceInputURLs.append(url)
            filters["activeHaplotypeDefinitionPath"] = url.path
        }
        return GenotypeViewportExportSnapshot(
            bundleURL: base.bundleURL,
            analysisName: base.analysisName,
            lens: base.lens,
            filters: filters,
            sampleNames: base.sampleNames,
            rows: base.rows,
            provenanceInputURLs: provenanceInputURLs,
            annotationSidecarURL: base.annotationSidecarURL,
            sidecar: base.sidecar
        )
    }

    private func exportFilterContext() -> [String: String] {
        var context: [String: String] = [:]
        if let activeSmartCohort {
            context["activeSmartCohortName"] = activeSmartCohort.name
            context["activeSmartCohortScope"] = activeSmartCohort.scope
            context["activeSmartCohortPredicate"] = encodedPredicate(activeSmartCohort.predicate)
        }
        let summary = quickFilterState.displaySummary.trimmingCharacters(in: .whitespacesAndNewlines)
        if !summary.isEmpty {
            context["quickFilter"] = summary
        }
        let search = quickFilterSearchText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !search.isEmpty {
            context["quickFilterSearchText"] = search
        }
        if let predicate = quickFilterState.saveablePredicate {
            context["quickFilterPredicate"] = encodedPredicate(predicate)
        }
        return context
    }

    private func encodedPredicate(_ predicate: SmartCohortPredicate) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(predicate),
              let text = String(data: data, encoding: .utf8) else {
            return String(describing: predicate)
        }
        return text
    }

    private func currentExportSnapshot() -> GenotypeViewportExportSnapshot? {
        guard let result else { return nil }
        let baseSnapshot: GenotypeViewportExportSnapshot
        if selectedLens == .summary,
           displayState.summaryViewMode == .matrix,
           definitionSetForResult(result) != nil,
           !displayState.showsAncillaryLoci {
            baseSnapshot = haplotypeMatrixView.exportSnapshot(
                bundleURL: result.bundleURL,
                analysisName: result.manifest.analysisName,
                lens: "summary.matrix.haplotypeDefinitions"
            )
        } else {
            ensureComparisonMatrixConfigured()
            baseSnapshot = comparisonMatrix.exportSnapshot(
                bundleURL: result.bundleURL,
                analysisName: result.manifest.analysisName,
                lens: selectedLens.identifier
            )
        }
        return attachSidecarSnapshot(
            to: attachHaplotypeDefinitionProvenanceContext(
                to: attachFilterContext(to: baseSnapshot)
            )
        )
    }

    private func fileViewerSelectionURLs(for export: GenotypeViewportExportResult) -> [URL] {
        [export.outputURL]
    }

    private func outlineBlockLabel(_ kind: GenotypeBlockKind) -> String {
        switch kind {
        case .blockCoherent: return "Block coherent"
        case .regionalRecombinant: return "Regional recombinant"
        case .atypical: return "Atypical"
        case .unknown: return "Unknown"
        }
    }

    private func exportViewButton() -> NSView {
        let stack = NSStackView()
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 8
        let button = NSButton(title: "Export Excel View...", target: self, action: #selector(exportExcelView(_:)))
        button.bezelStyle = .rounded
        button.controlSize = .small
        button.toolTip = "Export the current genotype matrix view, including viewport colors, into a provenance-tracked Excel package."
        stack.addArrangedSubview(button)
        stack.addArrangedSubview(caption("Exports visible matrix rows, support filters, and viewport fill/border colors."))
        return stack
    }

    @objc private func exportExcelView(_ sender: Any?) {
        guard let result else { return }
        let format = GenotypeViewportExportFormat.excel
        let panel = NSSavePanel()
        panel.title = "Export Genotype View"
        panel.nameFieldStringValue = "\(result.manifest.outputName)-genotype-view.\(format.fileExtension)"
        panel.allowedContentTypes = [format.contentType]
        panel.canCreateDirectories = true
        panel.prompt = "Export"
        panel.beginSheetModal(for: view.window ?? NSApp.keyWindow ?? NSWindow()) { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            guard let self else { return }
            // Capture the snapshot while still on the main actor: currentExportSnapshot()
            // reads main-actor UI state. Only the export (which shells out to the CLI and
            // blocks on process.waitUntilExit) is moved off the main thread.
            guard let snapshot = self.currentExportSnapshot() else { return }
            let outputURL = url
            Task { [weak self] in
                do {
                    let export = try await Task.detached {
                        try GenotypeViewportExportService().export(
                            snapshot: snapshot,
                            format: format,
                            to: outputURL
                        )
                    }.value
                    await MainActor.run {
                        guard let self else { return }
                        NSWorkspace.shared.activateFileViewerSelecting(self.fileViewerSelectionURLs(for: export))
                    }
                } catch {
                    await MainActor.run {
                        guard let self else { return }
                        if let window = self.view.window ?? NSApp.keyWindow {
                            NSAlert(error: error).beginSheetModal(for: window, completionHandler: { _ in })
                        } else {
                            NSApp.presentError(error)
                        }
                    }
                }
            }
        }
    }

    private func locusSummaryRow(_ summary: ONTGenotypeLocusSummary) -> NSView {
        let topCall = summary.sharedCalls.first
        return detailRows([
            ("Locus", summary.locus),
            ("Genotypes", "\(summary.callCount)"),
            ("Samples", "\(summary.sampleCount)"),
            ("Unique Reads", integer(summary.totalUniqueReads)),
            ("Top Shared", topCall.map { "\($0.genotype) (\($0.sampleCount) samples)" } ?? "None"),
        ])
    }

    private func anchorSummaryRow(_ anchor: ONTGenotypeAnchorSummary) -> NSView {
        detailRows([
            ("Anchor", anchor.label),
            ("Source", anchor.source.displayName),
            ("Loci", anchor.loci.joined(separator: ", ")),
            ("Genotypes", "\(anchor.sharedCalls.count)"),
            ("Samples", "\(anchor.sampleCount)"),
            ("Unique Reads", integer(anchor.totalUniqueReads)),
        ])
    }

    private func haplotypeSampleRow(_ sample: GenotypeHaplotypeSampleAnalysis) -> NSView {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .width
        stack.spacing = 4
        stack.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let effectiveCalls = sample.calls.map { call in
            let effective = effectiveHaplotypeCall(sample: sample.sample, call: call)
            return (
                locus: call.locus,
                h1: effective.h1,
                h2: effective.h2,
                status: effective.status,
                observedGenotypeCount: call.observedGenotypeCount,
                observedGenotypes: call.observedGenotypes
            )
        }
        let clearWholeMHCHomozygote = isClearWholeMHCHomozygote(effectiveCalls)
        let reviewCalls = effectiveCalls.filter {
            !isCallReviewResolved(sample: sample.sample, locus: $0.locus)
                && haplotypeStatusNeedsReview(
                $0.status,
                observedGenotypeCount: $0.observedGenotypeCount,
                suppressMultiallelicReview: clearWholeMHCHomozygote
            )
        }
        stack.addArrangedSubview(detailRows([
            ("Sample", sample.sample),
            ("Status", reviewCalls.isEmpty ? "Simple" : "Review"),
            ("Loci", "\(sample.calls.count)"),
            ("Issues", reviewCalls.isEmpty ? "None" : reviewCalls.map(\.locus).joined(separator: ", ")),
        ]))

        let actionRow = NSStackView()
        actionRow.orientation = .horizontal
        actionRow.alignment = .centerY
        actionRow.spacing = 8
        let button = NSButton(title: "Review in Analyst", target: self, action: #selector(reviewHaplotypeSample(_:)))
        button.bezelStyle = .rounded
        button.controlSize = .small
        button.tag = nextHaplotypeSampleActionTag
        nextHaplotypeSampleActionTag += 1
        haplotypeSampleActionTags[button.tag] = sample.sample
        button.toolTip = "Switch to the genotype matrix filtered to this sample."
        actionRow.addArrangedSubview(button)
        actionRow.addArrangedSubview(caption(reviewCalls.isEmpty ? "Called haplotypes follow the selected deterministic definition." : "Review the retained genotype evidence for this sample."))
        stack.addArrangedSubview(actionRow)

        let calls = effectiveCalls.map { call in
            "\(call.locus) \(call.h1)/\(call.h2)"
        }.joined(separator: "; ")
        stack.addArrangedSubview(wrappingText(calls, maximumLines: 4))
        if !reviewCalls.isEmpty {
            stack.addArrangedSubview(caption(reviewCalls.map { call in
                "\(call.locus): \(haplotypeStatusLabel(call.status))"
            }.joined(separator: "; ")))
        }
        return stack
    }

    private func haplotypeSampleNeedsReview(_ sample: GenotypeHaplotypeSampleAnalysis) -> Bool {
        let effectiveCalls = sample.calls.map { call in
            let effective = effectiveHaplotypeCall(sample: sample.sample, call: call)
            return (
                locus: call.locus,
                h1: effective.h1,
                h2: effective.h2,
                status: effective.status,
                observedGenotypeCount: call.observedGenotypeCount,
                observedGenotypes: call.observedGenotypes
            )
        }
        let clearWholeMHCHomozygote = isClearWholeMHCHomozygote(effectiveCalls)
        return effectiveCalls.contains { call in
            !isCallReviewResolved(sample: sample.sample, locus: call.locus)
                && haplotypeStatusNeedsReview(
                call.status,
                observedGenotypeCount: call.observedGenotypeCount,
                suppressMultiallelicReview: clearWholeMHCHomozygote
            )
        }
    }

    @objc private func reviewHaplotypeSample(_ sender: NSButton) {
        guard let sample = haplotypeSampleActionTags[sender.tag] else { return }
        showAnalystCalls(forHaplotypeSample: sample)
    }

    private func showAnalystCalls(forHaplotypeSample sample: String) {
        activeSmartCohort = nil
        quickFilterPredicate = nil
        quickFilterSearchText = sample
        quickFilterBar.setActivePills([])
        var state = displayState
        state.viewportLens = .summary
        state.summaryViewMode = .outline
        applyDisplayState(state)
        quickFilterBar.setSearchText(sample)
        handleOutlineRowSelected(sample)
        onDisplayStateChanged?(displayState)
    }

    private func haplotypeStatusNeedsReview(
        _ status: GenotypeHaplotypeCallStatus,
        observedGenotypeCount: Int,
        suppressMultiallelicReview: Bool = false
    ) -> Bool {
        if status == .notAssayed {
            return false
        }
        if status != .called && status != .specialCase {
            return true
        }
        if suppressMultiallelicReview {
            return false
        }
        return observedGenotypeCount > 2
    }

    private func isClearWholeMHCHomozygote(
        _ calls: [(locus: String, h1: String, h2: String, status: GenotypeHaplotypeCallStatus, observedGenotypeCount: Int, observedGenotypes: [String])]
    ) -> Bool {
        let assayedCalls = calls.filter { $0.status != .notAssayed }
        guard !assayedCalls.isEmpty else { return false }
        return assayedCalls.allSatisfy { call in
            guard call.status == .called || call.status == .specialCase else { return false }
            guard !call.h1.isEmpty, call.h1 != "-", !call.h1.hasPrefix("ERR") else { return false }
            guard !call.h2.hasPrefix("ERR") else { return false }
            guard call.h2.isEmpty || call.h2 == "-" || call.h1 == call.h2 else { return false }
            return observedGenotypesAreCompatibleWithHomozygousCall(
                haplotype: call.h1,
                observedGenotypeCount: call.observedGenotypeCount,
                observedGenotypes: call.observedGenotypes
            )
        }
    }

    private func observedGenotypesAreCompatibleWithHomozygousCall(
        haplotype: String,
        observedGenotypeCount: Int,
        observedGenotypes: [String]
    ) -> Bool {
        guard observedGenotypeCount > 2 else { return true }
        guard let family = haplotypeFamilyPrefix(haplotype) else { return false }
        let labels = observedGenotypes.isEmpty ? [] : observedGenotypes
        guard labels.count == observedGenotypeCount || !labels.isEmpty else { return false }
        return labels.allSatisfy { observedGenotypeLabel($0, containsFamily: family) }
    }

    private func haplotypeFamilyPrefix(_ haplotype: String) -> String? {
        guard haplotype.first?.uppercased() == "M" else { return nil }
        let digits = haplotype.dropFirst().prefix { $0.isNumber }
        guard !digits.isEmpty else { return nil }
        return "M\(digits)"
    }

    private func observedGenotypeLabel(_ label: String, containsFamily family: String) -> Bool {
        var searchRange = label.startIndex..<label.endIndex
        while let range = label.range(of: family, options: [.caseInsensitive], range: searchRange) {
            let beforeOK: Bool
            if range.lowerBound == label.startIndex {
                beforeOK = true
            } else {
                let previous = label[label.index(before: range.lowerBound)]
                beforeOK = !(previous.isLetter || previous.isNumber)
            }
            let afterOK: Bool
            if range.upperBound == label.endIndex {
                afterOK = true
            } else {
                afterOK = !label[range.upperBound].isNumber
            }
            if beforeOK && afterOK { return true }
            searchRange = range.upperBound..<label.endIndex
        }
        return false
    }

    private func haplotypeStatusLabel(_ status: GenotypeHaplotypeCallStatus) -> String {
        switch status {
        case .called:
            return "called"
        case .specialCase:
            return "special case"
        case .notAssayed:
            return "not assayed"
        case .noHaplotype:
            return "no matching haplotype"
        case .tooManyHaplotypes:
            return "too many matching haplotypes"
        case .tooManyGenotypes:
            return "too many genotype labels"
        }
    }

    private func sampleSupportTable(_ supports: [ONTGenotypeSampleSupport]) -> NSView {
        knownSelectionDiagnostics.supportingSampleTableEntryCount += 1
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 3
        stack.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        stack.addArrangedSubview(sampleSupportTableRow(
            sample: "Sample",
            uniqueReads: "Unique",
            alignments: "Alignments",
            isHeader: true
        ))
        for support in supports {
            stack.addArrangedSubview(sampleSupportTableRow(
                sample: support.sample,
                uniqueReads: integer(support.passedUniqueReads),
                alignments: integer(support.passedAlignments),
                isHeader: false
            ))
        }
        return stack
    }

    private func sampleSupportTableRow(
        sample: String,
        uniqueReads: String,
        alignments: String,
        isHeader: Bool
    ) -> NSView {
        let row = NSStackView()
        row.orientation = .horizontal
        row.alignment = .firstBaseline
        row.spacing = 10

        let sampleField = tableField(sample, width: 92, alignment: .left, isHeader: isHeader)
        let uniqueField = tableField(uniqueReads, width: 72, alignment: .right, isHeader: isHeader)
        let alignmentField = tableField(alignments, width: 76, alignment: .right, isHeader: isHeader)
        row.addArrangedSubview(sampleField)
        row.addArrangedSubview(uniqueField)
        row.addArrangedSubview(alignmentField)
        return row
    }

    private func coOccurrenceTable(_ coOccurrences: [ONTGenotypeCoOccurrence]) -> NSView {
        knownSelectionDiagnostics.coOccurrenceTableEntryCount += 1
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 3
        stack.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        stack.addArrangedSubview(coOccurrenceTableRow(
            genotype: "Genotype",
            probability: "P(Y|X)",
            shared: "Shared",
            isHeader: true
        ))
        for item in coOccurrences {
            stack.addArrangedSubview(coOccurrenceTableRow(
                genotype: compactGenotypeLabel(item.candidateGenotype),
                probability: percent(item.probabilityCandidateGivenSelected),
                shared: "\(item.sharedSampleCount)/\(item.selectedSampleCount)",
                isHeader: false
            ))
        }
        return stack
    }

    private func coOccurrenceTableRow(
        genotype: String,
        probability: String,
        shared: String,
        isHeader: Bool
    ) -> NSView {
        let row = NSStackView()
        row.orientation = .horizontal
        row.alignment = .firstBaseline
        row.spacing = 10
        row.addArrangedSubview(tableField(genotype, width: 220, alignment: .left, isHeader: isHeader))
        row.addArrangedSubview(tableField(probability, width: 60, alignment: .right, isHeader: isHeader))
        row.addArrangedSubview(tableField(shared, width: 58, alignment: .right, isHeader: isHeader))
        return row
    }

    private func tableField(
        _ text: String,
        width: CGFloat,
        alignment: NSTextAlignment,
        isHeader: Bool
    ) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.font = isHeader
            ? .systemFont(ofSize: 11, weight: .medium)
            : .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        field.textColor = isHeader ? .secondaryLabelColor : .labelColor
        field.alignment = alignment
        field.lineBreakMode = .byTruncatingMiddle
        field.usesSingleLineMode = true
        field.toolTip = text
        field.widthAnchor.constraint(equalToConstant: width).isActive = true
        return field
    }

    private func detailRows(_ rows: [(String, String)]) -> NSView {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .width
        stack.spacing = 4
        stack.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        for (label, value) in rows {
            let row = NSStackView()
            row.orientation = .horizontal
            row.alignment = .firstBaseline
            row.spacing = 8
            row.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

            let labelField = NSTextField(labelWithString: label)
            labelField.font = .systemFont(ofSize: 11)
            labelField.textColor = .secondaryLabelColor
            labelField.setContentCompressionResistancePriority(.required, for: .horizontal)
            labelField.widthAnchor.constraint(equalToConstant: 92).isActive = true

            let valueField = NSTextField(labelWithString: value)
            valueField.font = .systemFont(ofSize: 11)
            valueField.lineBreakMode = .byTruncatingMiddle
            valueField.usesSingleLineMode = true
            valueField.toolTip = value
            valueField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            valueField.setContentHuggingPriority(.defaultLow, for: .horizontal)

            row.addArrangedSubview(labelField)
            row.addArrangedSubview(valueField)
            stack.addArrangedSubview(row)
        }
        return stack
    }

    private func artifactRow(label: String, url: URL) -> NSView {
        let stack = NSStackView()
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 8
        stack.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let labelField = NSTextField(labelWithString: label)
        labelField.font = .systemFont(ofSize: 11, weight: .medium)
        labelField.widthAnchor.constraint(equalToConstant: 176).isActive = true
        labelField.setContentCompressionResistancePriority(.required, for: .horizontal)

        let pathField = NSTextField(labelWithString: url.path)
        pathField.font = .systemFont(ofSize: 11)
        pathField.textColor = .secondaryLabelColor
        pathField.lineBreakMode = .byTruncatingMiddle
        pathField.usesSingleLineMode = true
        pathField.toolTip = url.path
        pathField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        pathField.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let statusField = NSTextField(labelWithString: artifactStatus(url))
        statusField.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        statusField.textColor = .secondaryLabelColor
        statusField.widthAnchor.constraint(equalToConstant: 82).isActive = true

        let button = GenotypeArtifactButton(title: "Reveal", target: self, action: #selector(openArtifact(_:)))
        button.bezelStyle = .rounded
        button.controlSize = .small
        button.artifactURL = url
        button.toolTip = url.path

        stack.addArrangedSubview(labelField)
        stack.addArrangedSubview(pathField)
        stack.addArrangedSubview(statusField)
        stack.addArrangedSubview(button)
        return stack
    }

    @objc private func openArtifact(_ sender: NSButton) {
        guard let url = (sender as? GenotypeArtifactButton)?.artifactURL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    private func sectionTitle(_ text: String) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.font = .systemFont(ofSize: 13, weight: .semibold)
        field.lineBreakMode = .byTruncatingTail
        field.usesSingleLineMode = true
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return field
    }

    private func wrappingText(
        _ text: String,
        weight: NSFont.Weight = .regular,
        maximumLines: Int = 0
    ) -> NSTextField {
        let field = NSTextField(wrappingLabelWithString: text)
        field.font = .systemFont(ofSize: 11, weight: weight)
        field.lineBreakMode = .byWordWrapping
        field.maximumNumberOfLines = maximumLines
        field.toolTip = text
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return field
    }

    private func caption(_ text: String) -> NSTextField {
        let field = wrappingText(text)
        field.textColor = .secondaryLabelColor
        return field
    }

    private var supportMetricLabel: String {
        switch displayState.supportDenominator {
        case .viewedLocus:
            return "Unique reads / viewed-locus unique reads"
        case .sampleRetained:
            return "Unique reads / sample retained unique reads"
        }
    }

    private func supportFractionLabel(genotype: String, sample: String) -> String {
        knownSelectionDiagnostics.supportFractionLabelEntryCount += 1
        guard let result,
              let call = result.calls.first(where: { $0.sample == sample && $0.genotype == genotype }),
              let fraction = result.supportFraction(for: call, denominator: displayState.supportDenominator) else {
            return "Unavailable"
        }
        return percent(fraction)
    }

    private func sameLocusCoOccurrences(for sharedCall: ONTGenotypeSharedCall) -> [ONTGenotypeCoOccurrence] {
        knownSelectionDiagnostics.sameLocusCoOccurrenceEntryCount += 1
        return result?.sameLocusCoOccurrences(
            for: sharedCall.genotype,
            minimumSupportPercent: displayState.activeMinimumSupportPercent,
            denominator: displayState.supportDenominator
        ) ?? []
    }

    private func anchorSummary(for sharedCall: ONTGenotypeSharedCall) -> ONTGenotypeAnchorSummary? {
        knownSelectionDiagnostics.anchorSummaryEntryCount += 1
        guard let result else { return nil }
        return anchorSummaries(in: result).first { anchor in
            anchor.sharedCalls.contains { $0.genotype == sharedCall.genotype && $0.locus == sharedCall.locus }
        }
    }

    private func anchorSummaries(in result: ONTGenotypeResultBundleData) -> [ONTGenotypeAnchorSummary] {
        knownSelectionDiagnostics.anchorSummariesEntryCount += 1
        return result.anchorSummaries(
            minimumSupportPercent: displayState.activeMinimumSupportPercent,
            denominator: displayState.supportDenominator
        )
    }

    private func compactGenotypeLabel(_ genotype: String) -> String {
        guard genotype.count > 42 else { return genotype }
        let prefix = genotype.prefix(22)
        let suffix = genotype.suffix(14)
        return "\(prefix)...\(suffix)"
    }

    private func percent(_ value: Double) -> String {
        String(format: "%.1f%%", value * 100)
    }

    private func sharedCallMeaning(for sharedCall: ONTGenotypeSharedCall) -> String {
        "This row is one exact reference genotype label observed in \(sharedCall.sampleCount) assigned samples. Counts summarize retained unique-read support for this label, not phased haplotypes or allele absence."
    }

    private func artifactStatus(_ url: URL) -> String {
        guard FileManager.default.fileExists(atPath: url.path) else { return "Missing" }
        if let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize {
            return byteCount(size)
        }
        return "Present"
    }

    private func byteCount(_ value: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(value), countStyle: .file)
    }

    private func integer(_ value: Int?) -> String {
        value.map { $0.formatted(.number) } ?? "Unavailable"
    }

    private func removeArrangedSubviews(from stack: NSStackView) {
        if stack === detailStack {
            teardownSampleCurationWorkbench()
        }
        stack.arrangedSubviews.forEach { view in
            if stack === detailStack, view === candidateAlleleDetailView {
                candidateAlleleDetailWidthConstraint?.isActive = false
                candidateAlleleDetailWidthConstraint = nil
            }
            if stack === detailStack, view === alleleSequenceDetailView {
                alleleSequenceDetailWidthConstraint?.isActive = false
                alleleSequenceDetailWidthConstraint = nil
                alleleSequenceDetailHeightConstraint?.isActive = false
                alleleSequenceDetailHeightConstraint = nil
            }
            stack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
    }

    private func teardownSampleCurationWorkbench() {
        sampleWorkbenchWidthConstraint?.isActive = false
        sampleWorkbenchWidthConstraint = nil
        if let workbench = sampleCurationWorkbench {
            if detailStack.arrangedSubviews.contains(where: {
                $0 === workbench
            }) {
                detailStack.removeArrangedSubview(workbench)
            }
            workbench.removeFromSuperview()
        }
        sampleCurationWorkbench = nil
        sampleSupportedAllelesSnapshot = nil
        manualHaplotypeEditorModel = nil
        manualHaplotypeEditorHostView = nil
    }

    private func previousHighlightColor(for request: GenotypeResultHighlightRequest) -> AnnotationColor? {
        guard request.scope != .clear else { return nil }
        return comparisonMatrix.highlightStyle(for: request.target).color(for: request.channel)
    }

    private func registerUndo(for request: GenotypeResultHighlightRequest, previousColor: AnnotationColor?) {
        guard request.scope != .clear,
              previousColor != request.color,
              let undoManager = view.window?.undoManager else {
            return
        }
        let inverse = GenotypeResultHighlightRequest(
            target: request.target,
            scope: request.scope,
            channel: request.channel,
            color: previousColor
        )
        undoManager.registerUndo(withTarget: self) { target in
            target.applyHighlight(inverse)
        }
        undoManager.setActionName(request.color == nil ? "Clear Genotype \(request.channel.displayName)" : "Change Genotype \(request.channel.displayName)")
    }
}

private final class GenotypeArtifactButton: NSButton {
    var artifactURL: URL?
}

private final class FlippedDocumentView: NSView {
    override var isFlipped: Bool { true }
}

extension GenotypeResultViewController: NSSplitViewDelegate {
    public func splitViewDidResizeSubviews(_ notification: Notification) {
        splitCoordinator.splitViewDidResizeSubviews(
            splitView,
            minimumExtents: minimumSplitExtents()
        )
    }

    public func splitView(_ splitView: NSSplitView, resizeSubviewsWithOldSize oldSize: NSSize) {
        splitCoordinator.resizeSubviewsWithOldSize(
            self.splitView,
            oldSize: oldSize,
            defaultLeadingFraction: defaultLeadingFraction(for: displayState.layout),
            defaultLeadingExtent: defaultLeadingExtent(for: displayState.layout),
            minimumExtents: minimumSplitExtents()
        )
    }

    public func splitView(
        _ splitView: NSSplitView,
        constrainMinCoordinate proposedMinimumPosition: CGFloat,
        ofSubviewAt dividerIndex: Int
    ) -> CGFloat {
        minimumSplitExtents().leading
    }

    public func splitView(
        _ splitView: NSSplitView,
        constrainMaxCoordinate proposedMaximumPosition: CGFloat,
        ofSubviewAt dividerIndex: Int
    ) -> CGFloat {
        let extent = splitView.isVertical ? splitView.bounds.width : splitView.bounds.height
        return max(
            minimumSplitExtents().leading,
            extent - splitView.dividerThickness - minimumSplitExtents().trailing
        )
    }
}

#if DEBUG
enum GenotypeGeneratedContentSurface: CaseIterable {
    case detail
    case haplotype
    case consumer
    case anchor
    case artifact
}

struct GenotypeGeneratedContentTypographySnapshot: Equatable {
    let fontPointSizes: [CGFloat]
    let fieldTexts: [String]
    let fieldIdentities: [ObjectIdentifier]
    let arrangedSubviewIdentities: [ObjectIdentifier]
    let allFieldsAllowWrapping: Bool
    let scrollOriginY: CGFloat
}

struct GenotypeResultProjectionPerformanceSnapshot: Equatable {
    let matrix: GenotypeMatrixProjectionPerformanceSnapshot
    let anchorLensRebuildCount: Int
    let consumerLensRebuildCount: Int
    let cohortSummaryRebuildCount: Int
    let layoutApplicationCount: Int
}

extension GenotypeResultViewController {
    var testingComparisonMatrix: GenotypeComparisonMatrixView {
        ensureComparisonMatrixConfigured()
        return comparisonMatrix
    }

    func testingResetProjectionPerformanceCounters() {
        ensureComparisonMatrixConfigured()
        comparisonMatrix.testingResetProjectionPerformanceCounters()
        anchorLensBuildCount = 0
        consumerLensBuildCount = 0
        testingCohortSummaryRebuildCount = 0
        testingLayoutApplicationCount = 0
    }

    var testingProjectionPerformanceSnapshot:
        GenotypeResultProjectionPerformanceSnapshot {
        ensureComparisonMatrixConfigured()
        return GenotypeResultProjectionPerformanceSnapshot(
            matrix: comparisonMatrix.testingProjectionPerformanceSnapshot,
            anchorLensRebuildCount: anchorLensBuildCount,
            consumerLensRebuildCount: consumerLensBuildCount,
            cohortSummaryRebuildCount: testingCohortSummaryRebuildCount,
            layoutApplicationCount: testingLayoutApplicationCount
        )
    }

    func testingGeneratedContentSnapshot(
        _ surface: GenotypeGeneratedContentSurface
    ) -> GenotypeGeneratedContentTypographySnapshot {
        let (stack, scrollView) = generatedContentTestSurface(surface)
        let fields = generatedDetailTextFields(in: stack)
        return GenotypeGeneratedContentTypographySnapshot(
            fontPointSizes: fields.compactMap { $0.font?.pointSize },
            fieldTexts: fields.map(\.stringValue),
            fieldIdentities: fields.map(ObjectIdentifier.init),
            arrangedSubviewIdentities: stack.arrangedSubviews.map(ObjectIdentifier.init),
            allFieldsAllowWrapping: fields.allSatisfy {
                !$0.usesSingleLineMode && $0.maximumNumberOfLines != 1
            },
            scrollOriginY: scrollView.contentView.bounds.origin.y
        )
    }

    func testingSetGeneratedContentScrollOriginY(
        _ y: CGFloat,
        surface: GenotypeGeneratedContentSurface
    ) {
        let (_, scrollView) = generatedContentTestSurface(surface)
        var origin = scrollView.contentView.bounds.origin
        origin.y = y
        scrollView.contentView.setBoundsOrigin(origin)
    }

    var testingGeneratedContentRebuildCounts:
        (haplotype: Int, consumer: Int, anchor: Int, artifact: Int) {
        (
            haplotypeLensBuildCount,
            consumerLensBuildCount,
            anchorLensBuildCount,
            artifactLensBuildCount
        )
    }

    private func generatedContentTestSurface(
        _ surface: GenotypeGeneratedContentSurface
    ) -> (NSStackView, NSScrollView) {
        switch surface {
        case .detail:
            return (detailStack, detailScrollView)
        case .haplotype:
            return (haplotypeStack, haplotypeScrollView)
        case .consumer:
            return (consumerStack, consumerScrollView)
        case .anchor:
            return (anchorStack, anchorScrollView)
        case .artifact:
            return (artifactStack, artifactScrollView)
        }
    }

    func testingSelectFirstSharedCall() {
        ensureComparisonMatrixConfigured()
        comparisonMatrix.selectFirstSharedCall()
    }

    func testingSelectLens(_ lens: Lens) {
        showLens(lens)
    }

    func testingReviewHaplotypeSample(_ sample: String) {
        showAnalystCalls(forHaplotypeSample: sample)
    }

    func testingSelectCellEvidence(animalId: String, locus: String) {
        selectCellEvidence(animalId: animalId, locus: locus)
    }

    func testingConfirmCurrentCallEvidence() {
        confirmCurrentCallEvidence()
    }

    func testingApplyOverrideFromInspector(haplotype: String, slot: HaplotypeSlot) {
        applyOverrideFromInspector(haplotype: haplotype, slot: slot)
    }

    func testingApplyOverridesFromInspector(_ requests: [GenotypeCallEvidenceView.HaplotypeOverrideRequest]) {
        applyOverridesFromInspector(requests)
    }

    var testingCurrentSelectedSample: String? {
        currentSelectedSample
    }

    var testingCurrentCallEvidenceSample: String? {
        callEvidence?.sample
    }

    var testingCallEvidencePaneHidden: Bool {
        detailContainer.isHidden || (callEvidenceHost?.isHidden ?? true)
    }

    func testingOutlineIssueCount(sample: String) -> Int? {
        outlineRowsBySample[sample]?.noteIssueCount
    }

    var testingVisibleLensIdentifier: String {
        selectedLens.identifier
    }

    var testingSummaryViewMode: GenotypeSummaryViewMode {
        displayState.summaryViewMode
    }

    var testingPanelLayout: GenotypeResultPanelLayout {
        displayState.layout
    }

    var testingLensControlIsHidden: Bool {
        lensControl.isHidden
    }

    var testingContentHostTopInset: CGFloat {
        contentHostTopConstraint.constant
    }

    var testingDetailScrollViewIsHidden: Bool {
        detailScrollView.isHidden
    }

    var testingCohortSummaryIsHidden: Bool {
        cohortSummaryPanel.isHidden
    }

    var testingDetailText: String {
        textContent(in: detailStack).joined(separator: "\n")
    }

    var testingDetailArrangedSubviewCount: Int {
        detailStack.arrangedSubviews.count
    }

    var testingSampleWorkbenchLayoutMode:
        GenotypeSampleCurationWorkbenchView.LayoutMode? {
        sampleCurationWorkbench?.layoutMode
    }

    var testingSampleWorkbenchFrame: NSRect? {
        guard let sampleCurationWorkbench else { return nil }
        return sampleCurationWorkbench.convert(
            sampleCurationWorkbench.bounds,
            to: detailDocumentView
        )
    }

    var testingDetailStackFrame: NSRect {
        detailStack.convert(detailStack.bounds, to: detailDocumentView)
    }

    var testingDetailStackWidth: CGFloat {
        detailStack.bounds.width
    }

    var testingSampleWorkbenchIdentity: ObjectIdentifier? {
        sampleCurationWorkbench.map(ObjectIdentifier.init)
    }

    var testingSampleHeaderLayoutMode:
        GenotypeSampleCurationHeaderView.LayoutMode? {
        (sampleCurationWorkbench?.headerView
            as? GenotypeSampleCurationHeaderView)?.layoutMode
    }

    var testingSampleHeaderMetricValues: [String: String] {
        guard let header = sampleCurationWorkbench?.headerView
            as? GenotypeSampleCurationHeaderView else {
            return [:]
        }
        return Dictionary(
            uniqueKeysWithValues: header.metricFields.map {
                ($0.label.stringValue, $0.value.stringValue)
            }
        )
    }

    var testingSampleHeaderMetricIdentities: [ObjectIdentifier] {
        guard let header = sampleCurationWorkbench?.headerView
            as? GenotypeSampleCurationHeaderView else {
            return []
        }
        return header.metricViews.map(ObjectIdentifier.init)
    }

    var testingSampleHeaderMetricFramesAreContained: Bool {
        guard let header = sampleCurationWorkbench?.headerView
            as? GenotypeSampleCurationHeaderView else {
            return false
        }
        header.layoutSubtreeIfNeeded()
        return header.metricViews.allSatisfy { metric in
            let frame = metric.convert(metric.bounds, to: header)
            return frame.minX >= header.bounds.minX - 0.5
                && frame.maxX <= header.bounds.maxX + 0.5
                && frame.minY >= header.bounds.minY - 0.5
                && frame.maxY <= header.bounds.maxY + 0.5
        }
    }

    var testingSampleHeaderFieldsAllowWrapping: Bool {
        guard let header = sampleCurationWorkbench?.headerView
            as? GenotypeSampleCurationHeaderView else {
            return false
        }
        return header.metricFields.flatMap { [$0.label, $0.value] }
            .allSatisfy {
                $0.maximumNumberOfLines == 0
                    && !$0.usesSingleLineMode
                    && $0.lineBreakMode == .byWordWrapping
            }
    }

    var testingSampleHeaderSemanticElementCounts: [Int] {
        guard let header = sampleCurationWorkbench?.headerView
            as? GenotypeSampleCurationHeaderView else {
            return []
        }
        return header.metricFields.map { fields in
            [fields.label, fields.value]
                .filter { $0.isAccessibilityElement() }
                .count
        }
    }

    var testingMountedSampleWorkbenchCount: Int {
        detailStack.arrangedSubviews
            .compactMap {
                $0 as? GenotypeSampleCurationWorkbenchView
            }
            .count
    }

    var testingRetainedManualHaplotypeEditorModel:
        GenotypeManualHaplotypeEditorModel? {
        manualHaplotypeEditorModel
    }

    var testingManualHaplotypeEditorHostIdentity:
        ObjectIdentifier? {
        manualHaplotypeEditorHostView.map(ObjectIdentifier.init)
    }

    var testingManualHaplotypeEditorModelIdentity:
        ObjectIdentifier? {
        manualHaplotypeEditorModel.map(ObjectIdentifier.init)
    }

    var testingManualHaplotypeComboIdentities: [ObjectIdentifier] {
        guard let host = manualHaplotypeEditorHostView else {
            return []
        }
        return GenotypeManualHaplotypeLocus.allCases.flatMap {
            locus in
            HaplotypeSlot.allCases.compactMap { slot in
                descendantComboBox(
                    in: host,
                    accessibilityIdentifier:
                        "manual-haplotype-\(locus.rawValue)-"
                        + slot.rawValue
                )
            }
        }.map(ObjectIdentifier.init)
    }

    var testingFirstManualHaplotypeComboBox: NSComboBox? {
        guard let host = manualHaplotypeEditorHostView else {
            return nil
        }
        return descendantComboBox(
            in: host,
            accessibilityIdentifier: "manual-haplotype-MHC-A-h1"
        )
    }

    var testingSupportedAllelesSnapshotRowCount: Int? {
        sampleSupportedAllelesSnapshot?.rows.count
    }

    var testingGeneratedDetailLargestFontPointSize: CGFloat {
        generatedDetailTextFields(in: detailStack)
            .compactMap { $0.font?.pointSize }
            .max() ?? 0
    }

    var testingGeneratedDetailFieldsAllowWrapping: Bool {
        generatedDetailTextFields(in: detailStack).allSatisfy {
            !$0.usesSingleLineMode && $0.maximumNumberOfLines != 1
        }
    }

    func testingSetDetailScrollOriginY(_ y: CGFloat) {
        var origin = detailScrollView.contentView.bounds.origin
        origin.y = y
        detailScrollView.contentView.setBoundsOrigin(origin)
    }

    var testingDetailScrollOriginY: CGFloat {
        detailScrollView.contentView.bounds.origin.y
    }

    var testingAlleleSequenceText: String {
        alleleSequenceDetailView.renderedText
    }

    var testingAlleleSequenceFormat: GenotypeAlleleSequenceDetailView.Format {
        alleleSequenceDetailView.currentFormat
    }

    var testingAlleleSequenceRecordIdentities: [String] {
        renderedAlleleSequenceRecordIdentities
    }

    var testingAlleleSequenceDetailMountCount: Int {
        alleleSequenceDetailMountCount
    }

    var testingKnownAlleleSequenceRecordBuildCount: Int {
        knownAlleleSequenceRecordBuildCount
    }

    var testingKnownAlleleSequenceCacheCount: Int {
        knownSequenceRecordsByRowID.count
    }

    var testingProvisionalExon2SequenceRecordBuildCount: Int {
        provisionalExon2SequenceRecordBuildCount
    }

    var testingProvisionalExon2SequenceCacheCount: Int {
        provisionalExon2SequenceRecordsByGenotype.count
    }

    var testingLegacyNonRowDetailBuildCount: Int {
        legacyNonRowDetailBuildCount
    }

    func testingSelectAlleleSequenceFormat(
        _ format: GenotypeAlleleSequenceDetailView.Format
    ) {
        alleleSequenceDetailView.testingSelectFormat(format)
    }

    var testingKnownAlleleDetailMountCount: Int {
        knownAlleleDetailMountCount
    }

    var testingCandidateAlleleDetailMountCount: Int {
        candidateAlleleDetailMountCount
    }

    var testingComparisonMatrixIsHidden: Bool {
        comparisonMatrix.isHidden
    }

    var testingAnchorLensText: String {
        if anchorStack.arrangedSubviews.isEmpty {
            rebuildAnchorLens()
        }
        return textContent(in: anchorStack).joined(separator: "\n")
    }

    var testingHaplotypeLensText: String {
        if haplotypeStack.arrangedSubviews.isEmpty {
            rebuildHaplotypeLens()
        }
        return textContent(in: haplotypeStack).joined(separator: "\n")
    }

    var testingHasSummaryStatisticsStrip: Bool {
        false
    }

    var testingSamplePaneWidth: CGFloat {
        sampleContainer.frame.width
    }

    var testingDetailPaneWidth: CGFloat {
        detailContainer.frame.width
    }

    var testingLocusFilterTitles: [String] {
        ensureComparisonMatrixConfigured()
        return comparisonMatrix.testingLocusFilterTitles
    }

    func testingApplyDisplayState(_ state: GenotypeResultDisplayState) {
        applyDisplayState(state)
    }

    func testingApplyDisplayStateImmediately(_ state: GenotypeResultDisplayState) {
        applyDisplayStateImmediately(state)
    }

    func testingSetUnappliedDisplayState(_ state: GenotypeResultDisplayState) {
        displayState = state
    }

    func testingSaveHaplotypeDefinition(_ definition: GenotypeHaplotypeDefinitionSet) throws {
        try haplotypeDefinitionStore.save(definition)
        refreshAfterHaplotypeDefinitionChange()
    }

    func testingUseHaplotypeDefinition(id: String) throws {
        try useHaplotypeDefinition(id: id)
    }

    var testingSplitIsVertical: Bool {
        splitView.isVertical
    }

    var testingFirstPaneIsMatrix: Bool {
        splitView.arrangedSubviews.first === sampleContainer
    }

    var testingMinimumSplitExtents: (leading: CGFloat, trailing: CGFloat) {
        minimumSplitExtents()
    }

    var testingSplitDividerThickness: CGFloat {
        splitView.dividerThickness
    }

    func testingConstrainedMaxSplitCoordinate(containerExtent: CGFloat) -> CGFloat {
        if splitView.isVertical {
            splitView.frame.size.width = containerExtent
            splitView.bounds.size.width = containerExtent
        } else {
            splitView.frame.size.height = containerExtent
            splitView.bounds.size.height = containerExtent
        }
        return self.splitView(
            splitView,
            constrainMaxCoordinate: containerExtent,
            ofSubviewAt: 0
        )
    }

    var testingVisibleGenotypes: [String] {
        ensureComparisonMatrixConfigured()
        return comparisonMatrix.testingVisibleGenotypes
    }

    var testingVisibleMatrixSamples: [String] {
        ensureComparisonMatrixConfigured()
        return comparisonMatrix.testingVisibleSampleNames
    }

    var testingVisibleMatrixSampleColumnTitles: [String] {
        ensureComparisonMatrixConfigured()
        return comparisonMatrix.testingVisibleSampleColumnTitles
    }

    var testingPinnedMatrixColumnTitles: [String] {
        ensureComparisonMatrixConfigured()
        return comparisonMatrix.testingPinnedColumnTitles
    }

    var testingVisibleMatrixSampleReadTitles: [String] {
        ensureComparisonMatrixConfigured()
        return comparisonMatrix.testingVisibleSampleReadTitles
    }

    func testingSelectFirstSampleCell(sample: String) {
        ensureComparisonMatrixConfigured()
        comparisonMatrix.testingSelectFirstSampleCell(sample: sample)
    }

    var testingHighlightedCellCount: Int {
        ensureComparisonMatrixConfigured()
        return comparisonMatrix.testingHighlightedCellCount
    }

    var testingBorderedCellCount: Int {
        ensureComparisonMatrixConfigured()
        return comparisonMatrix.testingBorderedCellCount
    }

    var testingCurrentSelectionStyle: GenotypeResultHighlightStyle {
        guard let target = currentSelectionState?.highlightTarget else { return .default }
        ensureComparisonMatrixConfigured()
        return comparisonMatrix.testingHighlightStyle(for: target)
    }

    func testingBackgroundColor(genotype: String, sample: String) -> NSColor? {
        ensureComparisonMatrixConfigured()
        return comparisonMatrix.testingBackgroundColor(genotype: genotype, sample: sample)
    }

    func testingSelectMatrixCell(genotype: String, sample: String) {
        ensureComparisonMatrixConfigured()
        comparisonMatrix.testingSelectCell(genotype: genotype, sample: sample)
    }

    func testingSelectCandidateCell(stableClusterID: String, sample: String) {
        ensureComparisonMatrixConfigured()
        comparisonMatrix.testingSelectCandidateCell(
            rowID: .candidate(stableClusterID: stableClusterID),
            sample: sample
        )
    }

    func testingSelectCandidateRow(stableClusterID: String) {
        ensureComparisonMatrixConfigured()
        comparisonMatrix.testingClickCandidateRowChiclet(
            rowID: .candidate(stableClusterID: stableClusterID)
        )
    }

    var testingSelectedCandidateStableClusterID: String? {
        currentCandidateRow?.stableClusterID
    }

    var testingCandidateSelectionCallbackCounts: GenotypeCandidateSelectionCallbackCounts {
        .init(known: knownSelectionCallbackCount, candidate: candidateSelectionCallbackCount)
    }

    var testingKnownSelectionDiagnostics: GenotypeKnownSelectionDiagnostics {
        knownSelectionDiagnostics
    }

    var testingCandidateIntegrityWarningText: String {
        guard let result,
              result.manifest.kind == "full-length-ont-mhc-genotype" else { return "" }
        return GenotypeCandidateEvidenceProjection.warningText(result.integrityWarnings)
    }

    var testingVisibleMatrixGenotypes: [String] {
        ensureComparisonMatrixConfigured()
        return comparisonMatrix.testingVisibleGenotypes
    }

    var testingDisplayState: GenotypeResultDisplayState {
        displayState
    }

    var testingCandidatePersistenceWarning: String? {
        candidatePersistenceWarning
    }

    func testingWaitForCandidateSettingsPersistence() async {
        while candidateSettingsPersistenceTask != nil {
            await Task.yield()
        }
    }

    func testingSelectMatrixRows(genotypes: [String], sample: String?) {
        ensureComparisonMatrixConfigured()
        comparisonMatrix.testingSelectRows(genotypes: genotypes, sample: sample)
    }

    func testingSelectMatrixColumn(sample: String) {
        ensureComparisonMatrixConfigured()
        comparisonMatrix.testingSelectColumn(sample: sample)
    }

    func testingSelectMatrixColumns(samples: [String]) {
        ensureComparisonMatrixConfigured()
        comparisonMatrix.testingSelectColumns(samples: samples)
    }

    func testingSetMatrixContentScrollOrigins(
        pinned: NSPoint,
        samples: NSPoint
    ) {
        ensureComparisonMatrixConfigured()
        comparisonMatrix.testingSetContentScrollOrigins(
            pinned: pinned,
            samples: samples
        )
    }

    var testingMatrixContentScrollOrigins:
        GenotypeMatrixContentScrollOrigins {
        ensureComparisonMatrixConfigured()
        return comparisonMatrix.testingContentScrollOrigins
    }

    var testingNativeMatrixSelectedRowIndexes: IndexSet {
        ensureComparisonMatrixConfigured()
        return comparisonMatrix.testingNativeSelectedRowIndexes
    }

    func testingApplyNativeMatrixRowSelection(
        _ indexes: IndexSet,
        simulatedAppKitScrollOrigins:
            GenotypeMatrixContentScrollOrigins? = nil
    ) {
        ensureComparisonMatrixConfigured()
        comparisonMatrix.testingApplyNativeRowSelection(
            indexes,
            simulatedAppKitScrollOrigins:
                simulatedAppKitScrollOrigins
        )
    }

    func testingShowMatrixTargetSelection(_ targets: [GenotypeAnnotationSidecar.MatrixTarget]) {
        showMatrixTargetSelection(targets)
    }

    func testingClickMatrixCell(
        genotype: String,
        sample: String,
        modifiers: NSEvent.ModifierFlags = []
    ) {
        ensureComparisonMatrixConfigured()
        comparisonMatrix.testingClickCell(genotype: genotype, sample: sample, modifiers: modifiers)
    }

    func testingClickMatrixRowChiclet(
        genotype: String,
        modifiers: NSEvent.ModifierFlags = []
    ) {
        ensureComparisonMatrixConfigured()
        comparisonMatrix.testingClickRowChiclet(genotype: genotype, modifiers: modifiers)
    }

    func testingClickMatrixColumnChiclet(
        sample: String,
        modifiers: NSEvent.ModifierFlags = []
    ) {
        ensureComparisonMatrixConfigured()
        comparisonMatrix.testingClickColumnChiclet(sample: sample, modifiers: modifiers)
    }

    func testingClickMatrixSelectAllChiclet() {
        ensureComparisonMatrixConfigured()
        comparisonMatrix.testingClickSelectAllChiclet()
    }

    var testingCurrentSelectionMatrixTargets: [GenotypeAnnotationSidecar.MatrixTarget] {
        currentSelectionState?.matrixTargets ?? []
    }

    var testingMatrixReviewCapability: GenotypeMatrixReviewCapabilityState {
        matrixReviewCapability
    }

    var testingComparisonMatrixReviewCapability: GenotypeMatrixReviewCapabilityState {
        comparisonMatrix.matrixReviewCapability
    }

    func testingBuildMatrixContextMenu(
        for target: GenotypeAnnotationSidecar.MatrixTarget
    ) -> GenotypeMatrixContextMenuState? {
        ensureComparisonMatrixConfigured()
        return comparisonMatrix.testingBuildContextMenu(for: target)
    }

    func testingBuildActualMatrixContextMenu(
        for target: GenotypeAnnotationSidecar.MatrixTarget
    ) -> NSMenu? {
        ensureComparisonMatrixConfigured()
        return comparisonMatrix.testingBuildActualContextMenu(for: target)
    }

    func testingSetMatrixContextMenuSnapshotSourceFactory(
        _ factory: (
            (GenotypeMatrixContextMenuSnapshot)
                -> any GenotypeMatrixContextMenuSnapshotProviding
        )?
    ) {
        ensureComparisonMatrixConfigured()
        comparisonMatrix.testingSetContextMenuSnapshotSourceFactory(factory)
    }

    func testingSetMatrixVisibilityAnnouncementPoster(
        _ poster: any AccessibilityAnnouncementPosting
    ) {
        ensureComparisonMatrixConfigured()
        comparisonMatrix.testingSetVisibilityAnnouncementPoster(poster)
    }

    func testingPerformMatrixContextCommand(_ command: GenotypeMatrixContextCommand) -> Bool {
        ensureComparisonMatrixConfigured()
        return comparisonMatrix.testingPerformContextCommand(command)
    }

    func testingActivateMatrixContextMenuItem(_ item: NSMenuItem) -> Bool {
        ensureComparisonMatrixConfigured()
        return comparisonMatrix.testingActivateContextMenuItem(item)
    }

    func testingPerformMatrixKeyboardCommand(_ command: GenotypeMatrixContextCommand) -> Bool {
        ensureComparisonMatrixConfigured()
        return comparisonMatrix.testingPerformKeyboardCommand(command)
    }

    func testingSetMatrixCommentBodyProvider(_ provider: @escaping (String?) -> String?) {
        ensureComparisonMatrixConfigured()
        comparisonMatrix.matrixCommentBodyProvider = provider
    }

    var testingMatrixEvidenceIndexBuildCount: Int {
        matrixEvidenceIndexBuildCount
    }

    var testingMatrixAnnotationIndexBuildCount: Int {
        matrixAnnotationIndexBuildCount
    }

    var testingDeferredMatrixAnnotationMutationCount: Int {
        deferredMatrixAnnotationMutationCount
    }

    func testingIsWorkbookPublicationLockHeld(_ error: Error) -> Bool {
        isWorkbookPublicationLockHeld(error)
    }

    var testingCurrentSelectionDetailRows: [(String, String)] {
        currentSelectionState?.detailRows ?? []
    }

    func testingRenderedMatrixStyle(genotype: String, sample: String) -> GenotypeMatrixRenderedStyle? {
        ensureComparisonMatrixConfigured()
        return comparisonMatrix.testingRenderedStyle(genotype: genotype, sample: sample)
    }

    func testingIsSelectedMatrixCell(genotype: String, sample: String) -> Bool {
        ensureComparisonMatrixConfigured()
        return comparisonMatrix.testingIsSelectedCell(genotype: genotype, sample: sample)
    }

    func testingShowsSupportSelectionPreviewBorder(genotype: String, sample: String) -> Bool {
        ensureComparisonMatrixConfigured()
        return comparisonMatrix.testingShowsSupportSelectionPreviewBorder(genotype: genotype, sample: sample)
    }

    func testingDrawsMatrixCellSelectionFocus(genotype: String, sample: String) -> Bool {
        ensureComparisonMatrixConfigured()
        return comparisonMatrix.testingDrawsMatrixCellSelectionFocus(genotype: genotype, sample: sample)
    }

    func testingSetMatrixSupportSelectionPreviewMinimumReads(_ minimumReads: Int) {
        setMatrixSupportSelectionPreviewMinimumReads(minimumReads)
    }

    func testingShowOnlySelectedMatrixRows() {
        showOnlySelectedMatrixRows()
    }

    func testingHideSelectedMatrixRows() {
        hideSelectedMatrixRows()
    }

    func testingShowAllMatrixRows() {
        showAllMatrixRows()
    }

    func testingShowOnlySelectedMatrixColumns() {
        showOnlySelectedMatrixColumns()
    }

    func testingHideSelectedMatrixColumns() {
        hideSelectedMatrixColumns()
    }

    func testingShowAllMatrixColumns() {
        showAllMatrixColumns()
    }

    func testingResetMatrixVisibility() {
        resetMatrixVisibility()
    }

    func testingClearMatrixSelectionFilter() {
        clearMatrixSelectionFilter()
    }

    var testingMatrixVisibilityCapability:
        GenotypeMatrixVisibilityCapabilitySnapshot {
        matrixVisibilityCapability
    }

    func testingMatrixRowSelectorIsSelected(genotype: String) -> Bool {
        ensureComparisonMatrixConfigured()
        return comparisonMatrix.testingRowSelectorIsSelected(genotype: genotype)
    }

    func testingMatrixColumnSelectorIsSelected(sample: String) -> Bool {
        ensureComparisonMatrixConfigured()
        return comparisonMatrix.testingColumnSelectorIsSelected(sample: sample)
    }

    func testingMatrixRowSelectorAccessibility(
        genotype: String
    ) -> GenotypeMatrixSelectorAccessibilitySnapshot? {
        ensureComparisonMatrixConfigured()
        return comparisonMatrix.testingRowSelectorAccessibility(genotype: genotype)
    }

    func testingMatrixColumnSelectorAccessibility(
        sample: String
    ) -> GenotypeMatrixSelectorAccessibilitySnapshot? {
        ensureComparisonMatrixConfigured()
        return comparisonMatrix.testingColumnSelectorAccessibility(sample: sample)
    }

    var testingMatrixSelectAllAccessibility:
        GenotypeMatrixSelectorAccessibilitySnapshot? {
        ensureComparisonMatrixConfigured()
        return comparisonMatrix.testingSelectAllAccessibility
    }

    func testingPerformMatrixRowSelectorAccessibilityPress(
        genotype: String
    ) -> Bool {
        ensureComparisonMatrixConfigured()
        return comparisonMatrix.testingPerformRowSelectorAccessibilityPress(
            genotype: genotype
        )
    }

    func testingPerformMatrixColumnSelectorAccessibilityPress(
        sample: String
    ) -> Bool {
        ensureComparisonMatrixConfigured()
        return comparisonMatrix.testingPerformColumnSelectorAccessibilityPress(
            sample: sample
        )
    }

    func testingPerformMatrixSelectAllAccessibilityPress() -> Bool {
        ensureComparisonMatrixConfigured()
        return comparisonMatrix.testingPerformSelectAllAccessibilityPress()
    }

    func testingFocusMatrixRowSelector(genotype: String) -> Bool {
        ensureComparisonMatrixConfigured()
        return comparisonMatrix.testingFocusRowSelector(genotype: genotype)
    }

    var testingFocusedMatrixRowSelectorGenotype: String? {
        ensureComparisonMatrixConfigured()
        return comparisonMatrix.testingFocusedRowSelectorGenotype
    }

    func testingCellValue(genotype: String, sample: String) -> String? {
        ensureComparisonMatrixConfigured()
        return comparisonMatrix.testingCellValue(genotype: genotype, sample: sample)
    }

    func testingSelectSupportedCellsInSelectedRow(minimumReads: Int) -> [GenotypeAnnotationSidecar.MatrixTarget] {
        selectSupportedMatrixCellsInCurrentRow(minimumReads: minimumReads)
        return currentSelectionState?.matrixTargets ?? []
    }

    func testingResetMatrixReloadCounters() {
        ensureComparisonMatrixConfigured()
        comparisonMatrix.testingResetReloadCounters()
    }

    var testingMatrixFullReloadCount: Int {
        ensureComparisonMatrixConfigured()
        return comparisonMatrix.testingFullReloadCount
    }

    var testingPinnedMatrixFullReloadCount: Int {
        ensureComparisonMatrixConfigured()
        return comparisonMatrix.testingPinnedFullReloadCount
    }

    var testingSampleMatrixFullReloadCount: Int {
        ensureComparisonMatrixConfigured()
        return comparisonMatrix.testingSampleFullReloadCount
    }

    var testingMatrixPartialReloadCount: Int {
        ensureComparisonMatrixConfigured()
        return comparisonMatrix.testingPartialReloadCount
    }

    var testingPinnedMatrixPartialReloadCount: Int {
        ensureComparisonMatrixConfigured()
        return comparisonMatrix.testingPinnedPartialReloadCount
    }

    var testingSampleMatrixPartialReloadCount: Int {
        ensureComparisonMatrixConfigured()
        return comparisonMatrix.testingSamplePartialReloadCount
    }

    var testingMatrixPartialReloadedCellCount: Int {
        ensureComparisonMatrixConfigured()
        return comparisonMatrix.testingPartialReloadedCellCount
    }

    var testingLastMatrixReloadTargets: [GenotypeAnnotationSidecar.MatrixTarget] {
        ensureComparisonMatrixConfigured()
        return comparisonMatrix.testingReloadTargets
    }

    var testingDetailContentTopInset: CGFloat {
        detailStack.frame.minY
    }

    func testingRenderVisibleCells(rowLimit: Int) {
        ensureComparisonMatrixConfigured()
        comparisonMatrix.testingRenderVisibleCells(rowLimit: rowLimit)
    }

    func testingSetComparisonFilter(_ text: String) {
        ensureComparisonMatrixConfigured()
        comparisonMatrix.testingSetFilter(text)
    }

    func testingPerformNativeComparisonFilterAction(
        text: String,
        selectedRange: NSRange,
        in window: NSWindow
    ) -> Bool {
        ensureComparisonMatrixConfigured()
        return comparisonMatrix.testingPerformNativeFilterAction(
            text: text,
            selectedRange: selectedRange,
            in: window
        )
    }

    var testingComparisonFilterModelText: String {
        ensureComparisonMatrixConfigured()
        return comparisonMatrix.testingFilterModelText
    }

    var testingComparisonFilterNativeText: String {
        ensureComparisonMatrixConfigured()
        return comparisonMatrix.testingFilterNativeText
    }

    var testingComparisonFilterNativeSelectedRange: NSRange {
        ensureComparisonMatrixConfigured()
        return comparisonMatrix.testingFilterNativeSelectedRange
    }

    func testingSetUnifiedSampleFilter(_ text: String) {
        quickFilterBar.setSearchText(text)
        if comparisonMatrixConfigured {
            applyComparisonMatrixCohortFilter()
        }
    }

    func testingSetQuickFilterSearchText(_ text: String) {
        quickFilterBar.setSearchText(text)
    }

    var testingQuickSearchPlaceholder: String {
        quickFilterBar.testingSearchPlaceholder
    }

    var testingQuickSearchAccessibilityLabel: String {
        quickFilterBar.testingSearchAccessibilityLabel
    }

    var testingQuickSearchAccessibilityIdentifier: String {
        quickFilterBar.testingSearchAccessibilityIdentifier
    }

    var testingQuickSearchEmptyMessage: String {
        quickFilterBar.testingEmptyStateMessage
    }

    var testingQuickSearchIsFocused: Bool {
        quickFilterBar.testingSearchField.currentEditor() != nil
    }

    var testingQuickSearchText: String {
        quickFilterBar.testingSearchField.stringValue
    }

    @discardableResult
    func testingFocusQuickSearch() -> Bool {
        quickFilterBar.focusSearchField()
    }

    func testingTypeQuickSearchDebounced(_ text: String) {
        let field = quickFilterBar.testingSearchField
        field.stringValue = text
        quickFilterBar.controlTextDidChange(
            Notification(name: NSControl.textDidChangeNotification, object: field)
        )
    }

    func testingSetSearchAnnouncementPoster(
        _ poster: any AccessibilityAnnouncementPosting
    ) {
        quickFilterBar.testingSetAnnouncementPoster(poster)
    }

    var testingSearchIndexBuildCount: Int {
        searchIndexBuildCount
    }

    var testingSearchQueryCount: Int {
        searchQueryCount
    }

    var testingSearchHaplotypeRecordBuildCount: Int {
        searchHaplotypeRecordBuildCount
    }

    func testingResetSearchPerformanceCounters() {
        searchIndexBuildCount = 0
        searchQueryCount = 0
        searchHaplotypeRecordBuildCount = 0
        invalidateGenotypeSearchIndex()
    }

    func testingSaveCurrentFilterAsSmartCohort() throws {
        try saveCurrentFilterAsSmartCohort()
    }

    func testingApplySmartCohort(_ cohort: GenotypeCohortSmartFilter) {
        applySmartCohort(cohort)
    }

    var testingHasHaplotypingResult: Bool {
        hasHaplotypingResult
    }

    var testingActiveSmartCohort: GenotypeCohortSmartFilter? {
        activeSmartCohort
    }

    var testingCohortSubjectBuildCount: Int {
        cohortSubjectBuildCount
    }

    var testingHaplotypeWorkCount: Int {
        haplotypeWorkCount
    }

    func testingResetHaplotypeCapabilityWorkCounters() {
        cohortSubjectBuildCount = 0
        haplotypeWorkCount = 0
    }

    func testingCurrentExportSnapshot() -> GenotypeViewportExportSnapshot? {
        currentExportSnapshot()
    }

    func testingFileViewerSelectionURLs(for export: GenotypeViewportExportResult) -> [URL] {
        fileViewerSelectionURLs(for: export)
    }

    var testingSavedCohortChipTitle: String? {
        quickFilterBar.testingSavedCohortChipTitle
    }

    var testingVisibleOutlineSamples: [String] {
        outlineRowOrder
    }

    var testingOutlineSelectedSample: String? {
        outlineView.testingReviewSelectedSample
    }

    var testingOutlineSelectedLocus: String? {
        outlineView.testingReviewSelectedLocus
    }

    var testingHaplotypeMatrixText: String {
        rebuildHaplotypeMatrix()
        return haplotypeMatrixView.testingText
    }

    func testingIsClearWholeMHCHomozygote(
        calls: [(locus: String, h1: String, h2: String, status: GenotypeHaplotypeCallStatus, observedGenotypeCount: Int, observedGenotypes: [String])]
    ) -> Bool {
        isClearWholeMHCHomozygote(calls)
    }

    func testingOutlineSlots(sample sampleId: String) -> [GenotypeHaplotypeTapeView.Slot] {
        guard let result, let analysis = activeHaplotypeAnalysis(),
              let sample = analysis.samples.first(where: { $0.sample == sampleId }) else {
            return []
        }
        let observed = observedLociIndex ?? GenotypeObservedLociIndex.build(from: result)
        return outlineTapeSlots(
            for: sample,
            loci: effectiveIncludedLoci(for: analysis, observed: observed),
            observed: observed
        )
    }

    func testingCurrentWorkbookHaplotypeCalls() -> [GenotypeWorkbookHaplotypeCall] {
        currentWorkbookEffectiveHaplotypeCalls()
    }

    func testingCurrentWorkbookHaplotypeProjectionMode()
        -> GenotypeWorkbookHaplotypeProjectionMode
    {
        currentWorkbookHaplotypeProjectionMode()
    }

    var testingManualHaplotypingCreatorIsAvailable: Bool {
        guard let result else { return false }
        return manualHaplotypingIsAvailable(result: result)
    }

    var testingUsesLegacyManualHaplotypingSection: Bool {
        usesLegacyManualHaplotypingSection
    }

    var testingManualHaplotypeEditorOrphanWarning: String? {
        manualHaplotypeEditorModel?.orphanLegacyWarningMessage
    }

    var testingManualHaplotypeEditorOrphans:
        [ManualHaplotypeAssignment] {
        manualHaplotypeEditorModel?.orphanLegacyAssignments ?? []
    }

    var testingManualHaplotypeEditorEmptyStateMessage: String? {
        manualHaplotypeEditorModel?.emptyStateMessage
    }

    var testingManualHaplotypeEditorSample: String? {
        manualHaplotypeEditorModel?.draft.sample
    }

    var testingLastManualHaplotypeFocusedFieldIdentifier: String? {
        testingLastManualHaplotypeFocusIdentifier
    }

    func testingSetManualHaplotypeBandDisclosureExpanded(
        _ expanded: Bool
    ) {
        ensureComparisonMatrixConfigured()
        comparisonMatrix
            .testingSetManualHaplotypeBandDisclosureExpanded(expanded)
    }

    var testingManualHaplotypeEditorIsDirty: Bool {
        manualHaplotypeEditorModel?.draft.isDirty == true
    }

    var testingManualHaplotypeEditorCanSave: Bool {
        manualHaplotypeEditorModel?.canSave == true
    }

    var testingManualHaplotypeEditorPersistenceError: String? {
        manualHaplotypeEditorModel?.persistenceErrorMessage
    }

    var testingManualHaplotypeWorkbookDirtyMarkCount: Int {
        testingCurrentWorkbookDirtyMarkCount
    }

    func testingUpdateManualHaplotypeLabel(
        _ label: String,
        locus: GenotypeManualHaplotypeLocus = .a,
        slot: HaplotypeSlot = .h1
    ) {
        manualHaplotypeEditorModel?.updateLabel(
            label,
            locus: locus,
            slot: slot
        )
    }

    func testingClearManualHaplotypeLabel(
        locus: GenotypeManualHaplotypeLocus = .a,
        slot: HaplotypeSlot = .h1
    ) {
        manualHaplotypeEditorModel?.clear(locus: locus, slot: slot)
    }

    func testingManualHaplotypeAutocompleteSuggestions(
        matching query: String,
        locus: GenotypeManualHaplotypeLocus = .a,
        slot: HaplotypeSlot = .h1
    ) -> [String] {
        manualHaplotypeEditorModel?
            .autocompleteSuggestions(
                matching: query,
                locus: locus,
                slot: slot
            )
            .map(\.label) ?? []
    }

    func testingCopyManualHaplotypes(from sample: String) {
        manualHaplotypeEditorModel?.copyAssignments(from: sample)
    }

    func testingSaveManualHaplotypeDraft() {
        manualHaplotypeEditorModel?.save()
    }

    func testingSetManualHaplotypeDraftDecisionProvider(
        _ provider: @escaping (
            GenotypeManualHaplotypeDraftCoordinator.Transition
        ) async -> GenotypeManualHaplotypeDraftDecision
    ) {
        manualHaplotypeDraftDecisionProvider = provider
    }

    func testingWaitForManualHaplotypeTransitions() async {
        while manualHaplotypeTransitionMutationCoordinator.hasPendingMutation
            || manualHaplotypeDraftCoordinator.hasPendingResolution {
            await Task.yield()
        }
    }

    var testingPendingManualHaplotypeMutationCount: Int {
        manualHaplotypeTransitionMutationCoordinator.retainedMutationCount
    }

    var testingManualHaplotypeAssignments: [ManualHaplotypeAssignment] {
        annotationStore?.sidecar.manualHaplotypeAssignments ?? []
    }

    func testingAttemptManualHaplotypeCreation(
        selectedGenotypeIDs: Set<String>,
        label: String
    ) {
        manualHaplotypingSelection = selectedGenotypeIDs
        manualHaplotypingDraftLabel = label
        commitManualHaplotype()
    }

    func testingReloadCurrentWorkbookResult() {
        guard let bundleURL = result?.bundleURL else { return }
        reloadCurrentWorkbookResult(from: bundleURL)
    }

    var testingCurrentWorkbookNeedsRefresh: Bool {
        currentWorkbookNeedsRefresh
    }

    var testingCurrentWorkbookRequiresFullUpdate: Bool {
        currentWorkbookRequiresFullUpdate
    }

    func testingRequireFullCurrentWorkbookUpdate() {
        currentWorkbookRequiresFullUpdate = true
        currentWorkbookNeedsRefresh = true
    }

    var testingCurrentWorkbookUpdateStatus: String? {
        displayedCurrentWorkbookStatus
    }

    var testingCurrentWorkbookUpdateButtonEnabled: Bool {
        makeCurrentWorkbookUpdateHost().subviews
            .compactMap { $0 as? NSButton }
            .first { $0.title == Self.currentWorkbookActionTitle }?
            .isEnabled ?? false
    }

    var testingCurrentWorkbookActionTitle: String {
        Self.currentWorkbookActionTitle
    }

    func testingRequestCurrentWorkbookUpdate() {
        updateCurrentWorkbookFromOverrides()
    }

    func testingRequestCurrentWorkbookUpdateAndView() {
        updateCurrentWorkbookFromOverrides()
    }

    func testingApplyCurrentWorkbookSyncPhase(
        _ phase: GenotypeCurrentWorkbookUIPhase,
        isReadOnly: Bool
    ) {
        applyCurrentWorkbookSyncPhase(phase, isReadOnly: isReadOnly)
    }

    var testingPendingConfigurationBundleURL: URL? {
        pendingConfigurationResult?.bundleURL.standardizedFileURL
    }

    var testingResultBundleURL: URL? {
        result?.bundleURL.standardizedFileURL
    }

    var testingResultTotalInputReads: Int? {
        result?.stats.totalInputReads
    }

    func testingArtifactLabelLayout(label: String) -> (renderedWidth: CGFloat, intrinsicWidth: CGFloat)? {
        artifactStack.layoutSubtreeIfNeeded()
        guard let field = testingTextField(in: artifactStack, text: label) else { return nil }
        field.superview?.layoutSubtreeIfNeeded()
        return (field.frame.width, field.intrinsicContentSize.width)
    }

    private func testingTextField(in view: NSView, text: String) -> NSTextField? {
        if let field = view as? NSTextField, field.stringValue == text {
            return field
        }
        for subview in view.subviews {
            if let field = testingTextField(in: subview, text: text) {
                return field
            }
        }
        return nil
    }

    private func textContent(in view: NSView) -> [String] {
        var values: [String] = []
        if let field = view as? NSTextField {
            values.append(field.stringValue)
        }
        if let button = view as? NSButton {
            values.append(button.title)
        }
        for subview in view.subviews {
            values.append(contentsOf: textContent(in: subview))
        }
        return values
    }
}
#endif
