import AppKit
import SwiftUI
import LungfishCore
import LungfishIO
import LungfishWorkflow

@MainActor
final class GenotypeResultViewController: NSViewController {
    typealias Lens = GenotypeResultViewportLens

    var onSelectionStateChanged: ((GenotypeResultSelectionState?) -> Void)?
    var onDisplaySummaryChanged: ((Int, Int, Int) -> Void)?
    var onDisplayStateChanged: ((GenotypeResultDisplayState) -> Void)?
    var onAnnotationSidecarChanged: ((GenotypeAnnotationSidecar) -> Void)?
    var windowStateScope: WindowStateScope?

    private let summaryStrip = NSStackView()
    private let lensControl = NSSegmentedControl(
        labels: Lens.allCases.map(\.displayName),
        trackingMode: .selectOne,
        target: nil,
        action: nil
    )
    private let contentHost = NSView()

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
    private var sampleMetadataStore: SampleMetadataStore?
    private var annotationStore: GenotypeAnnotationStore?
    private var manualHaplotypingSelection: Set<String> = []
    private var manualHaplotypingDraftLabel: String = ""
    private var manualHaplotypingDraftColorTokenIndex: Int = 1
    private var activeSmartCohort: GenotypeCohortSmartFilter?
    private var quickFilterPredicate: SmartCohortPredicate?
    private var quickFilterSearchText: String = ""
    private var quickFilterState = GenotypeQuickFilterBarView.FilterState()
    private var sampleDetailHostingController: NSHostingController<GenotypeSampleDetailSheet>?
    private var callEvidenceHost: NSHostingView<GenotypeCallEvidenceView>?
    private var dropoutAbsoluteEnabled: Bool = true
    private var dropoutAbsoluteValue: Int = 50
    private var dropoutSampleFractionEnabled: Bool = false
    private var dropoutSampleFractionPercent: Double = 0.1
    private var dropoutLocusFractionEnabled: Bool = true
    // Default to the 1% threshold the user requested — at 5% the bundle's
    // observed-but-not-diagnostic alleles get flagged "too many genotypes" too
    // often. Per-locus EQ entries override this on a per-locus basis.
    private var dropoutLocusFractionPercent: Double = 1.0
    /// Music-EQ per-locus overrides for the locus-fraction threshold.
    /// Keys are locus names (e.g. "MHC-B"). Percent values (0..100) replace
    /// the global slider for that locus when the analyst wants finer control.
    private var dropoutPerLocusFractionPercents: [String: Double] = [:]
    /// Live re-analyzed haplotype calls — derived from raw calls + current
    /// dropout configuration. Used by the Outline / Cohort Summary
    /// so threshold changes update the display immediately. `nil` falls
    /// back to the bundle's persisted analysis.
    private var liveHaplotypeAnalysis: GenotypeHaplotypeAnalysis?
    /// Per-project haplotype-definition store. Reads from / writes to
    /// `<projectRoot>/Haplotype Definitions/`. Populated from the bundle's
    /// surrounding project root in `configure(result:)`.
    private var haplotypeDefinitionStore = HaplotypeDefinitionStore(projectRoot: nil)
    /// SwiftUI hosting controller for the active definition-editor sheet,
    /// stored so the sheet can be dismissed programmatically on save/cancel.
    private var haplotypeDefinitionEditorHost: NSHostingController<GenotypeHaplotypeDefinitionEditor>?
    private var selectedLens: Lens = .summary
    private var displayState = GenotypeResultDisplayState()
    private var currentSharedCall: ONTGenotypeSharedCall?
    private var currentSelectedSample: String?
    private var currentSelectedLocus: String?
    private var currentSelectionState: GenotypeResultSelectionState?
    private var activeContentView: NSView?
    private var activeContentConstraints: [NSLayoutConstraint] = []
    private var haplotypeSampleActionTags: [Int: String] = [:]
    private var nextHaplotypeSampleActionTag = 1
    private var outlineRowsBySample: [String: GenotypeOutlineView.Row] = [:]
    private var outlineRowOrder: [String] = []

    override func loadView() {
        let root = NSView()
        root.translatesAutoresizingMaskIntoConstraints = false
        root.setAccessibilityElement(true)
        root.setAccessibilityRole(.group)
        root.setAccessibilityLabel("Genotype result viewport")
        root.setAccessibilityIdentifier("genotype-result-view")
        view = root

        configureSummaryStrip()
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
    }

    @objc private func handleSampleDetailSheetRequest(_ notification: Notification) {
        guard let sample = notification.userInfo?["sample"] as? String else { return }
        presentSampleDetailSheet(forAnimal: sample)
    }

    @objc private func handleHaplotypeDefinitionsRequest(_ notification: Notification) {
        showLens(.audit)
        onDisplayStateChanged?(displayState)
    }

    private func applyQuickFilterState(_ state: GenotypeQuickFilterBarView.FilterState) {
        quickFilterState = state
        quickFilterPredicate = state.pillPredicate
        quickFilterSearchText = state.searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        refreshVisibleFilterDependentViews()
    }

    @objc private func handleSmartCohortApplied(_ notification: Notification) {
        guard shouldAcceptScopedNotification(notification) else { return }
        guard let data = notification.userInfo?["cohort"] as? Data else {
            clearActiveSmartCohort()
            return
        }
        if let cohort = try? JSONDecoder().decode(GenotypeCohortSmartFilter.self, from: data) {
            activeSmartCohort = cohort
            quickFilterBar.setSavedCohortName(cohort.name)
            refreshVisibleFilterDependentViews()
        }
    }

    @objc private func handleSmartCohortSaveRequested(_ notification: Notification) {
        guard shouldAcceptScopedNotification(notification) else { return }
        do {
            try saveCurrentFilterAsSmartCohort()
        } catch {
            presentSheetAlert(error: error)
        }
    }

    @objc private func handleSmartCohortDeleteRequested(_ notification: Notification) {
        guard shouldAcceptScopedNotification(notification) else { return }
        guard let data = notification.userInfo?["cohort"] as? Data,
              let cohort = try? JSONDecoder().decode(GenotypeCohortSmartFilter.self, from: data),
              let store = annotationStore else { return }
        do {
            try store.deleteSmartCohort(name: cohort.name, scope: cohort.scope)
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
        guard let store = annotationStore else { return }
        var predicates: [SmartCohortPredicate] = []
        var summaryParts: [String] = []
        if let activeSmartCohort {
            predicates.append(activeSmartCohort.predicate)
            summaryParts.append(activeSmartCohort.name)
        }
        if let predicate = quickFilterState.saveablePredicate {
            predicates.append(predicate)
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
            predicate: predicate
        )
        try store.saveSmartCohort(cohort)
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

    /// Push the current Smart Cohort + Quick Filter intersection into the
    /// Matrix view. The sample allow-list keeps sample/metadata/comment/
    /// haplotype matches aligned with Outline, while genotype/locus-like text
    /// remains a row filter so Matrix does not leak unrelated rows.
    private func applyComparisonMatrixCohortFilter() {
        guard let result else {
            comparisonMatrix.applyFilters(allowedSampleIDs: nil, text: "")
            return
        }
        if activeSmartCohort == nil && quickFilterPredicate == nil && quickFilterSearchText.isEmpty {
            comparisonMatrix.applyFilters(allowedSampleIDs: nil, text: "")
            return
        }
        let allowed = filteredSampleNames(result: result, sidecar: annotationStore?.sidecar)
        comparisonMatrix.applyFilters(
            allowedSampleIDs: allowed,
            text: matrixRowFilterText(result: result, allowedSamples: allowed)
        )
    }

    private func refreshVisibleFilterDependentViews(rebuildCohortSummary shouldRebuildCohortSummary: Bool = false) {
        if selectedLens == .summary {
            switch displayState.summaryViewMode {
            case .outline:
                rebuildOutline()
            case .matrix:
                if summaryMatrixUsesHaplotypeDefinitions() {
                    rebuildHaplotypeMatrix()
                } else {
                    applyComparisonMatrixCohortFilter()
                }
            }
        } else if !comparisonMatrix.isHidden {
            applyComparisonMatrixCohortFilter()
        }
        if shouldRebuildCohortSummary {
            rebuildCohortSummary()
        }
    }

    private func summaryMatrixUsesHaplotypeDefinitions() -> Bool {
        (result.map { definitionSetForResult($0) != nil } ?? false)
            && !displayState.showsAncillaryLoci
    }

    /// Per-call keyboard shortcuts used by the Review lens:
    /// - `⌘R`: mark the currently selected sample's status as `reviewed`
    /// - `⌘K`: mark as `confirmed`
    /// - `⌘⇧F`: flag as `needsReview`
    /// - `⌘⇧O`: open the Sample Detail sheet for the override editor
    /// Returns true if the event was handled, allowing the responder chain
    /// to continue otherwise.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        // Only intercept when the Review lens is up and a sample is selected.
        guard selectedLens == .review, let animalId = currentSelectedSample else {
            return super.performKeyEquivalent(with: event)
        }
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let cmd: NSEvent.ModifierFlags = .command
        let cmdShift: NSEvent.ModifierFlags = [.command, .shift]
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
        do {
            try store.setSampleStatus(value, sample: animalId)
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

    override func viewDidLayout() {
        super.viewDidLayout()
        guard selectedLens == .summary, splitView.arrangedSubviews.count == 2 else { return }
        if view.window == nil {
            applySplitPositionIfNeeded()
        } else if splitCoordinator.needsInitialSplitValidation {
            scheduleInitialSplitValidationIfNeeded()
        }
    }

    func configure(result: ONTGenotypeResultBundleData) {
        self.result = result
        liveHaplotypeAnalysis = nil
        let knownSampleIDs = Set(
            result.samples.map(\.sample)
                + result.calls.map(\.sample)
                + (result.haplotypeAnalysis?.samples.map(\.sample) ?? [])
        )
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
            author: NSUserName()
        )
        // Hydrate the dropout threshold sliders/steppers from saved sidecar
        // settings so the analyst sees their last-saved values when the
        // bundle reopens, not stale defaults.
        if let settings = annotationStore?.sidecar.settings {
            dropoutAbsoluteEnabled = settings.dropoutAbsolute != nil
            dropoutAbsoluteValue = settings.dropoutAbsolute ?? dropoutAbsoluteValue
            dropoutSampleFractionEnabled = settings.dropoutSampleFraction != nil
            if let f = settings.dropoutSampleFraction { dropoutSampleFractionPercent = f * 100 }
            dropoutLocusFractionEnabled = settings.dropoutLocusFraction != nil
            if let f = settings.dropoutLocusFraction { dropoutLocusFractionPercent = f * 100 }
            if let overrides = settings.locusFractionOverrides {
                dropoutPerLocusFractionPercents = overrides.mapValues { $0 * 100 }
            }
        }
        if shouldEagerlyRecomputeHaplotypeAnalysis(for: result) {
            recomputeLiveHaplotypeAnalysis(evaluator: currentDropoutEvaluator())
        } else {
            liveHaplotypeAnalysis = nil
        }
        comparisonMatrix.configure(result: result, metadataStore: sampleMetadataStore)
        rebuildSummary()
        rebuildOutline()
        rebuildHaplotypeMatrix()
        rebuildCohortSummary()
        applyComparisonMatrixCohortFilter()
        showLens(.summary)
        comparisonMatrix.selectFirstSharedCall()
    }

    /// Build a `GenotypeDropoutEvaluator` matching the current view-model
    /// state (sliders + per-locus EQ). Used when the analyst explicitly
    /// applies dropout settings or when no persisted analysis is available.
    private func currentDropoutEvaluator() -> GenotypeDropoutEvaluator {
        GenotypeDropoutEvaluator(
            absolute: dropoutAbsoluteEnabled ? dropoutAbsoluteValue : nil,
            sampleFraction: dropoutSampleFractionEnabled ? dropoutSampleFractionPercent / 100.0 : nil,
            locusFraction: dropoutLocusFractionEnabled ? dropoutLocusFractionPercent / 100.0 : nil,
            locusFractionOverrides: dropoutLocusFractionEnabled
                ? dropoutPerLocusFractionPercents.mapValues { $0 / 100.0 }
                : [:]
        )
    }

    func applySampleMetadataStore(_ store: SampleMetadataStore?) {
        sampleMetadataStore = store
        comparisonMatrix.applyMetadataStore(store)
        refreshVisibleFilterDependentViews()
        rebuildConsumerLens()
        if let currentSharedCall {
            showSharedCall(currentSharedCall, sample: currentSelectedSample)
        }
    }

    func notifySelectionStateIfAvailable() {
        onSelectionStateChanged?(currentSelectionState)
    }

    func applyDisplayState(_ state: GenotypeResultDisplayState) {
        let previousViewMode = displayState.summaryViewMode
        let previousAncillary = displayState.showsAncillaryLoci
        displayState = state
        if selectedLens != state.viewportLens {
            showLens(state.viewportLens)
        } else {
            lensControl.selectedSegment = segmentIndex(for: state.viewportLens)
            if selectedLens == .summary {
                applySummaryViewModeVisibility()
            }
        }
        comparisonMatrix.applyDisplayState(state)
        rebuildAnchorLens()
        rebuildConsumerLens()
        if previousViewMode != state.summaryViewMode || previousAncillary != state.showsAncillaryLoci {
            rebuildOutline()
            rebuildHaplotypeMatrix()
            rebuildCohortSummary()
        }
        applyLayoutPreference()
        if let currentSharedCall {
            showSharedCall(currentSharedCall, sample: currentSelectedSample)
        }
    }

    func applyHighlight(_ request: GenotypeResultHighlightRequest) {
        let previousColor = previousHighlightColor(for: request)
        comparisonMatrix.applyHighlight(request)
        registerUndo(for: request, previousColor: previousColor)
        if let currentSharedCall {
            showSharedCall(currentSharedCall, sample: currentSelectedSample)
        }
    }

    private func applyHighlightWithoutUndo(_ request: GenotypeResultHighlightRequest) {
        comparisonMatrix.applyHighlight(request)
        if let currentSharedCall {
            showSharedCall(currentSharedCall, sample: currentSelectedSample)
        }
    }

    private func configureSummaryStrip() {
        summaryStrip.translatesAutoresizingMaskIntoConstraints = false
        summaryStrip.orientation = .horizontal
        summaryStrip.alignment = .centerY
        summaryStrip.spacing = 10
        summaryStrip.edgeInsets = NSEdgeInsets(top: 8, left: 12, bottom: 8, right: 12)
        summaryStrip.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        summaryStrip.setContentHuggingPriority(.defaultLow, for: .horizontal)
    }

    private func configureLensControl() {
        lensControl.translatesAutoresizingMaskIntoConstraints = false
        lensControl.target = self
        lensControl.action = #selector(lensChanged(_:))
        lensControl.selectedSegment = segmentIndex(for: .summary)
        lensControl.setAccessibilityIdentifier("genotype-result-lens-control")
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
    }

    private func layout() {
        view.addSubview(summaryStrip)
        view.addSubview(lensControl)
        view.addSubview(contentHost)

        NSLayoutConstraint.activate([
            summaryStrip.topAnchor.constraint(equalTo: view.topAnchor),
            summaryStrip.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            summaryStrip.trailingAnchor.constraint(lessThanOrEqualTo: lensControl.leadingAnchor, constant: -12),
            summaryStrip.heightAnchor.constraint(equalToConstant: 48),

            lensControl.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -12),
            lensControl.centerYAnchor.constraint(equalTo: summaryStrip.centerYAnchor),

            contentHost.topAnchor.constraint(equalTo: summaryStrip.bottomAnchor),
            contentHost.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            contentHost.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            contentHost.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
    }

    private func wireCallbacks() {
        comparisonMatrix.onSharedCallSelected = { [weak self] sharedCall, sample in
            self?.showSharedCall(sharedCall, sample: sample)
        }
        comparisonMatrix.onSelectionCleared = { [weak self] in
            self?.showEmptySelection()
        }
        comparisonMatrix.onDisplaySummaryChanged = { [weak self] visibleRows, totalRows, hiddenCells in
            self?.onDisplaySummaryChanged?(visibleRows, totalRows, hiddenCells)
        }
    }

    @objc private func lensChanged(_ sender: NSSegmentedControl) {
        guard sender.selectedSegment >= 0,
              sender.selectedSegment < Lens.allCases.count else { return }
        let lens = Lens.allCases[sender.selectedSegment]
        showLens(lens)
        onDisplayStateChanged?(displayState)
    }

    private func showLens(_ lens: Lens) {
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
            applyReviewLensVisibility()
            scheduleInitialSplitValidationIfNeeded()
            applyLayoutPreference()
        case .audit:
            rebuildArtifactLens()
            installContentView(artifactScrollView)
        }
    }

    private func applyReviewLensVisibility() {
        outlineView.isHidden = false
        comparisonMatrix.isHidden = true
        cohortSummaryPanel.isHidden = true
        detailScrollView.isHidden = true
        callEvidenceHost?.isHidden = false
        if callEvidenceHost == nil {
            installCallEvidenceHost()
        }
        // The Review lens is meant to walk the Needs Review queue, not
        // show every sample. Use the same built-in smart cohort shown in
        // the inspector so low-support and analyst-flagged samples are
        // included alongside hard errors.
        if quickFilterPredicate == nil && activeSmartCohort == nil && quickFilterSearchText.isEmpty {
            activateNeedsReviewCohort()
        }
        // Auto-select the first review sample so Panel B has evidence
        // to render immediately rather than the empty placeholder.
        if currentSelectedSample == nil,
           let first = outlineRowsBySample.keys.sorted().first {
            currentSelectedSample = first
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
        let host = NSHostingView(rootView: makeCallEvidenceView(evidence: callEvidence))
        host.translatesAutoresizingMaskIntoConstraints = false
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
        guard let host = callEvidenceHost else { return }
        host.rootView = makeCallEvidenceView(evidence: callEvidence)
    }

    private func makeCallEvidenceView(evidence: GenotypeCallEvidenceView.Evidence?) -> GenotypeCallEvidenceView {
        var view = GenotypeCallEvidenceView(evidence: evidence)
        view.onOverrideRequested = { [weak self] haplotypeName in
            self?.applyOverrideFromInspector(haplotype: haplotypeName)
        }
        view.onConfirmRequested = { [weak self] in
            self?.confirmCurrentCallEvidence()
        }
        view.onSkipRequested = { [weak self] in
            self?.skipToNextReviewSample()
        }
        return view
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
        guard let sampleAnalysis = analysis.samples.first(where: { $0.sample == sampleId }) else {
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
        let sampleCalls = result.calls.filter { $0.sample == sampleId }
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
        let observedSet = Set(locusCall.observedGenotypes)
        // Mirror the global evaluator (with per-locus EQ) so the
        // low-support badge in the Review lens agrees with the live
        // analyzer's filtering.
        let evaluator = currentDropoutEvaluator()
        let diagnostic = locusCalls
            .filter { (call: ONTGenotypeCall) -> Bool in
                if observedSet.contains(call.genotype) { return true }
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
                let sampleTotal = sampleCalls.reduce(0) { $0 + max(0, $1.passedUniqueReads) }
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
        let sampleNames = (activeHaplotypeAnalysis()?.samples ?? []).map(\.sample)
        let neighbors = neighborSummaries(for: sampleId, in: sampleNames, analysis: analysis)
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
        let candidates = candidateHaplotypes(for: locusCall, observedAlleles: observedAllelesForCandidates)
        let perHaplotype = perHaplotypeSupport(
            for: locusCall,
            sampleCalls: sampleCalls,
            locusDefinition: locusDefinition,
            locusTotal: locusTotal,
            evaluator: evaluator
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
            locusReadTotal: locusTotal,
            neighborsBefore: neighbors.before,
            neighborsAfter: neighbors.after,
            errorExplanation: explanation,
            candidateHaplotypes: candidates,
            h1Name: displayedH1,
            h2Name: displayedH2,
            perHaplotypeSupport: perHaplotype
        )
    }

    /// Build a per-haplotype supporting-allele table for the inspector. For
    /// each matched haplotype, lists every diagnostic allele observed in
    /// the sample with read count and % of locus reads. Empty for error
    /// calls because the matched-haplotypes list itself is empty.
    private func perHaplotypeSupport(
        for locusCall: GenotypeHaplotypeLocusCall,
        sampleCalls: [ONTGenotypeCall],
        locusDefinition: GenotypeHaplotypeLocusDefinition?,
        locusTotal: Int,
        evaluator: GenotypeDropoutEvaluator
    ) -> [GenotypeCallEvidenceView.PerHaplotypeSupport] {
        guard !locusCall.matchedHaplotypes.isEmpty else { return [] }
        let sampleTotal = sampleCalls.reduce(0) { $0 + max(0, $1.passedUniqueReads) }
        return locusCall.matchedHaplotypes.map { matched in
            let alleles = matched.observedDiagnosticAlleles.map { allele -> GenotypeCallEvidenceView.DiagnosticAllele in
                let reads = diagnosticReads(
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
                    allele: allele,
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
            return "Too many genotypes observed at \(locusCall.locus) (\(locusCall.observedGenotypeCount)). For diploid Class II loci, each raw DPA/DPB or DQA/DQB sub-locus should contribute at most two genotypes to the combined DP or DQ haplotype call. The extra \(extras) genotype\(extras == 1 ? "" : "s") suggests cross-well contamination, a barcoding error, or low-support spurious calls — raise the per-locus dropout threshold to filter them out."
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
        observedAlleles: Set<String>
    ) -> [GenotypeCallEvidenceView.CandidateHaplotype] {
        guard let result, let definitionSet = definitionSetForResult(result) else { return [] }
        guard let locusDef = definitionSet.locusDefinitions.first(where: { $0.locus == locusCall.locus }) else {
            return []
        }
        let candidates = locusDef.haplotypes.compactMap { haplotype -> GenotypeCallEvidenceView.CandidateHaplotype? in
            var present: [String] = []
            var missing: [String] = []
            for allele in haplotype.diagnosticAlleles {
                if observedAlleles.contains(where: { observed in
                    GenotypeHaplotypeDiagnosticMatcher.matches(
                        genotype: observed,
                        diagnosticAllele: allele
                    )
                }) {
                    present.append(allele)
                } else {
                    missing.append(allele)
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
        return fallback
    }

    private func hasCallOverride(sample: String, locus: String, slot: HaplotypeSlot) -> Bool {
        guard let overrides = annotationStore?.sidecar.callOverrides else { return false }
        return overrides.contains {
            $0.sample == sample && $0.locus == locus && $0.slot == slot
        }
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
        let mode = displayState.summaryViewMode
        let usesHaplotypeMatrix = summaryMatrixUsesHaplotypeDefinitions()
        outlineView.isHidden = mode != .outline
        haplotypeMatrixView.isHidden = !(mode == .matrix && usesHaplotypeMatrix)
        comparisonMatrix.isHidden = !(mode == .matrix && !usesHaplotypeMatrix)
        // Panel B: cohort summary visible for Outline; matrix detail visible for Matrix.
        let summaryActive = mode == .outline
        cohortSummaryPanel.isHidden = !summaryActive
        detailScrollView.isHidden = summaryActive
        // Re-push the cohort allow-list whenever the matrix becomes visible
        // so switching view modes never drops the active cohort/quick filter.
        if mode == .matrix && usesHaplotypeMatrix {
            rebuildHaplotypeMatrix()
        }
        if !comparisonMatrix.isHidden {
            applyComparisonMatrixCohortFilter()
        }
    }

    private func tapeCell(for haplotypeName: String, status: GenotypeHaplotypeCallStatus) -> GenotypeHaplotypeTapeView.Cell {
        if status == .notAssayed {
            return .notAssayed(label: haplotypeName.isEmpty ? "Not assayed" : haplotypeName)
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
        Lens.allCases.firstIndex(of: lens) ?? 0
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

    private func rebuildSummary() {
        removeArrangedSubviews(from: summaryStrip)
        guard let result else { return }
        let qcCounts = result.qcStatusCounts
        [
            ("Samples", "\(result.sampleCount)"),
            ("Calls", "\(result.callCount)"),
            ("Genotypes", "\(result.locusSummaries.reduce(0) { $0 + $1.callCount })"),
            ("Loci", "\(result.locusSummaries.count)"),
            ("OK", "\(qcCounts[.ok, default: 0])"),
            ("Review", "\(qcCounts[.review, default: 0])"),
        ].forEach { label, value in
            summaryStrip.addArrangedSubview(summaryPill(label: label, value: value))
        }
        if let context = haplotypeDefinitionContext(for: result) {
            summaryStrip.addArrangedSubview(summaryPill(label: "Definition", value: context.definition.displayName))
            summaryStrip.addArrangedSubview(summaryPill(label: "Source", value: context.source.displayName))
        }
    }

    private func summaryPill(label: String, value: String) -> NSView {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 1
        stack.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let valueLabel = NSTextField(labelWithString: value)
        valueLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        valueLabel.lineBreakMode = .byTruncatingTail
        valueLabel.usesSingleLineMode = true

        let keyLabel = NSTextField(labelWithString: label)
        keyLabel.font = .systemFont(ofSize: 10)
        keyLabel.textColor = .secondaryLabelColor
        keyLabel.lineBreakMode = .byTruncatingTail
        keyLabel.usesSingleLineMode = true

        stack.addArrangedSubview(valueLabel)
        stack.addArrangedSubview(keyLabel)
        return stack
    }

    private func showSharedCall(_ sharedCall: ONTGenotypeSharedCall, sample: String? = nil) {
        currentSharedCall = sharedCall
        currentSelectedSample = sample
        removeArrangedSubviews(from: detailStack)

        detailStack.addArrangedSubview(sectionTitle("Selected Genotype"))
        detailStack.addArrangedSubview(wrappingText(sharedCall.genotype, weight: .medium, maximumLines: 3))
        detailStack.addArrangedSubview(caption(sharedCallMeaning(for: sharedCall)))
        detailStack.addArrangedSubview(sectionTitle("Support Summary"))
        detailStack.addArrangedSubview(detailRows([
            ("Locus", sharedCall.locus),
            ("Samples", "\(sharedCall.sampleCount)"),
            ("Unique Reads", integer(sharedCall.totalUniqueReads)),
            ("Alignments", integer(sharedCall.totalAlignments)),
            ("Top Sample", sharedCall.topSupport.map { "\($0.sample) - \(integer($0.passedUniqueReads)) unique" } ?? "Unavailable"),
            ("Support Metric", supportMetricLabel),
        ]))

        if let sample,
           let support = sharedCall.support(for: sample) {
            detailStack.addArrangedSubview(sectionTitle("Selected Cell"))
            detailStack.addArrangedSubview(detailRows([
                ("Sample", sample),
                ("Unique Reads", integer(support.passedUniqueReads)),
                ("Alignments", integer(support.passedAlignments)),
                ("Support", supportFractionLabel(genotype: sharedCall.genotype, sample: sample)),
            ]))
        }

        if let aliases = sharedCall.aliasDisplay {
            detailStack.addArrangedSubview(sectionTitle("Ambiguous Alleles"))
            detailStack.addArrangedSubview(wrappingText(aliases, maximumLines: 5))
        }

        if let anchorSummary = anchorSummary(for: sharedCall) {
            detailStack.addArrangedSubview(sectionTitle("Anchor Evidence"))
            detailStack.addArrangedSubview(detailRows([
                ("Anchor", anchorSummary.label),
                ("Source", anchorSummary.source.displayName),
                ("Loci", anchorSummary.loci.joined(separator: ", ")),
                ("Samples", "\(anchorSummary.sampleCount)"),
                ("Unique Reads", integer(anchorSummary.totalUniqueReads)),
            ]))
            detailStack.addArrangedSubview(caption(anchorSummary.caveat))
        }

        let coOccurrences = sameLocusCoOccurrences(for: sharedCall)
        if !coOccurrences.isEmpty {
            detailStack.addArrangedSubview(sectionTitle("Same-Locus Co-occurrence"))
            detailStack.addArrangedSubview(caption("These values show sample-level co-observation within \(sharedCall.locus). They are not phase, haplotype, zygosity, copy-number, or absence calls."))
            detailStack.addArrangedSubview(coOccurrenceTable(Array(coOccurrences.prefix(8))))
        }

        detailStack.addArrangedSubview(sectionTitle("Supporting Samples"))
        if sharedCall.sampleSupport.isEmpty {
            detailStack.addArrangedSubview(caption("No assigned samples support this genotype."))
        } else {
            detailStack.addArrangedSubview(sampleSupportTable(Array(sharedCall.sampleSupport.prefix(24))))
            if sharedCall.sampleSupport.count > 24 {
                detailStack.addArrangedSubview(caption("\(sharedCall.sampleSupport.count - 24) additional samples are visible in the matrix."))
            }
        }

        publishSelectionState(selectionState(for: sharedCall, sample: sample))
    }

    private func showEmptySelection() {
        currentSharedCall = nil
        currentSelectedSample = nil
        removeArrangedSubviews(from: detailStack)
        detailStack.addArrangedSubview(caption("Select a genotype row to review shared support."))
        publishSelectionState(nil)
    }

    private func selectionState(for sharedCall: ONTGenotypeSharedCall, sample: String?) -> GenotypeResultSelectionState {
        var rows: [(String, String)] = [
            ("Meaning", sharedCallMeaning(for: sharedCall)),
            ("Locus", sharedCall.locus),
            ("Samples", "\(sharedCall.sampleCount)"),
            ("Unique Reads", integer(sharedCall.totalUniqueReads)),
            ("Alignments", integer(sharedCall.totalAlignments)),
            ("Support Metric", supportMetricLabel),
        ]
        if let sample,
           let support = sharedCall.support(for: sample) {
            rows.append(("Selected Sample", sample))
            rows.append(("Selected Unique", integer(support.passedUniqueReads)))
            rows.append(("Selected Support", supportFractionLabel(genotype: sharedCall.genotype, sample: sample)))
        }
        if let topSupport = sharedCall.topSupport {
            rows.append(("Top Sample", "\(topSupport.sample) - \(integer(topSupport.passedUniqueReads)) unique"))
        }
        if let aliases = sharedCall.aliasDisplay {
            rows.append(("Aliases", aliases))
        }
        let target = GenotypeResultHighlightTarget(
            genotype: sharedCall.genotype,
            locus: sharedCall.locus,
            sample: sample
        )
        let style = comparisonMatrix.highlightStyle(for: target)
        return GenotypeResultSelectionState(
            title: sharedCall.genotype,
            subtitle: "\(sharedCall.locus) - \(sharedCall.sampleCount) samples",
            detailRows: rows,
            highlightTarget: target,
            highlightStyle: style
        )
    }

    private func publishSelectionState(_ state: GenotypeResultSelectionState?) {
        currentSelectionState = state
        onSelectionStateChanged?(state)
    }

    private func rebuildHaplotypeLens() {
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
        removeArrangedSubviews(from: anchorStack)
        guard let result else { return }
        let anchors = result.anchorSummaries(
            minimumSupportPercent: displayState.activeMinimumSupportPercent,
            denominator: displayState.supportDenominator
        )
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
        removeArrangedSubviews(from: artifactStack)
        guard let result else { return }
        if let entries = annotationStore?.sidecar.auditLog, !entries.isEmpty {
            addAuditSection(title: "Audit Timeline", contents: [makeAuditTimelineHost(entries: entries)])
        }
        addAuditSection(title: "Share View", contents: [exportViewButton()])
        let artifactRows: [NSView] = [
            artifactRow(label: "Workbook", url: result.artifacts.workbookURL),
            artifactRow(label: "Long Summary CSV", url: result.artifacts.longSummaryCSVURL),
            artifactRow(label: "Sample Summary CSV", url: result.artifacts.sampleSummaryCSVURL),
            artifactRow(label: "Run Stats JSON", url: result.artifacts.statsJSONURL),
            artifactRow(label: "Provenance", url: result.artifacts.provenanceURL),
        ] + (result.artifacts.haplotypeAnalysisURL.map { [artifactRow(label: "Haplotype Analysis", url: $0)] } ?? [])
        addAuditSection(title: "Bundle Artifacts", contents: artifactRows)

        if manualHaplotypingIsAvailable(result: result) {
            addAuditSection(title: "Manual Haplotyping", contents: [makeManualHaplotypingHost()])
        }
        addAuditSection(title: "Dropout Thresholds", contents: [makeDropoutThresholdHost()])
        addAuditSection(title: "Haplotype Definitions", contents: [makeHaplotypeDefinitionsRow()])
    }

    private func makeAuditTimelineHost(entries: [GenotypeAnnotationSidecar.AuditEntry]) -> NSView {
        let container = NSHostingView(rootView: GenotypeAuditTimelineSection(entries: entries, entryLimit: 12))
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

    /// List of all available haplotype definition sets — built-in
    /// (read-only) plus user-defined (editable, deletable). Each row
    /// surfaces the set's name + locus count + an action.
    private func makeHaplotypeDefinitionsRow() -> NSView {
        let container = NSStackView()
        container.translatesAutoresizingMaskIntoConstraints = false
        container.orientation = .vertical
        container.alignment = .leading
        container.spacing = 6
        container.edgeInsets = NSEdgeInsets(top: 4, left: 8, bottom: 4, right: 8)

        let description = NSTextField(wrappingLabelWithString:
            "Built-in sets ship with Lungfish and are read-only — choose Clone to make an editable copy. User sets live as JSON under \"Haplotype Definitions/\" in the project root, can be edited or deleted, and are versioned alongside the bundle's provenance."
        )
        description.font = NSFont.systemFont(ofSize: 10)
        description.textColor = .secondaryLabelColor
        description.maximumNumberOfLines = 4
        container.addArrangedSubview(description)

        // Built-in sets (read-only).
        let builtInSets = GenotypeHaplotypeDefinitionRegistry.builtIn
            .assays.flatMap(\.definitionSets)
        let activeDefinitionID = activeHaplotypeDefinitionSetID()
        for set in builtInSets {
            container.addArrangedSubview(makeHaplotypeDefinitionRow(
                set: set,
                isUserDefined: false,
                isActive: set.id == activeDefinitionID
            ))
        }

        // User sets (editable + deletable).
        let userSets = haplotypeDefinitionStore.loadAllUserSets()
        if !userSets.isEmpty {
            let sep = NSBox()
            sep.boxType = .separator
            container.addArrangedSubview(sep)
            for set in userSets {
                container.addArrangedSubview(makeHaplotypeDefinitionRow(
                    set: set,
                    isUserDefined: true,
                    isActive: set.id == activeDefinitionID
                ))
            }
        }

        let newButton = NSButton(title: "New empty definition…", target: self, action: #selector(handleNewHaplotypeDefinition(_:)))
        newButton.controlSize = .small
        container.addArrangedSubview(newButton)

        return container
    }

    private func makeHaplotypeDefinitionRow(
        set: GenotypeHaplotypeDefinitionSet,
        isUserDefined: Bool,
        isActive: Bool
    ) -> NSView {
        let row = NSStackView()
        row.orientation = .horizontal
        row.spacing = 8
        row.alignment = .centerY
        let icon = NSImageView()
        icon.image = NSImage(systemSymbolName: isUserDefined ? "person.crop.circle" : "lock.shield",
                             accessibilityDescription: isUserDefined ? "User-defined" : "Built-in")
        icon.contentTintColor = isUserDefined ? .lungfishOrange : .secondaryLabelColor
        icon.widthAnchor.constraint(equalToConstant: 16).isActive = true
        let name = NSTextField(labelWithString: set.displayName)
        name.font = NSFont.systemFont(ofSize: 11, weight: .medium)
        let locusCount = set.locusDefinitions.count
        let haplotypeCount = set.locusDefinitions.reduce(0) { $0 + $1.haplotypes.count }
        let counts = NSTextField(labelWithString: "\(locusCount) loci · \(haplotypeCount) haplotypes")
        counts.font = NSFont.systemFont(ofSize: 10)
        counts.textColor = .secondaryLabelColor
        row.addArrangedSubview(icon)
        row.addArrangedSubview(name)
        row.addArrangedSubview(counts)
        if isActive {
            let active = NSTextField(labelWithString: "Active")
            active.font = NSFont.systemFont(ofSize: 10, weight: .semibold)
            active.textColor = .controlAccentColor
            row.addArrangedSubview(active)
        }
        row.addArrangedSubview(NSView())  // flexible spacer

        if !isActive {
            let useButton = NSButton(title: "Use", target: self, action: #selector(handleUseHaplotypeDefinition(_:)))
            useButton.identifier = NSUserInterfaceItemIdentifier("use:\(set.id)")
            useButton.controlSize = .small
            row.addArrangedSubview(useButton)
        }

        if isUserDefined {
            let editButton = NSButton(title: "Edit…", target: self, action: #selector(handleEditHaplotypeDefinition(_:)))
            editButton.identifier = NSUserInterfaceItemIdentifier("edit:\(set.id)")
            editButton.controlSize = .small
            row.addArrangedSubview(editButton)
            let deleteButton = NSButton(title: "Delete", target: self, action: #selector(handleDeleteHaplotypeDefinition(_:)))
            deleteButton.identifier = NSUserInterfaceItemIdentifier("delete:\(set.id)")
            deleteButton.controlSize = .small
            row.addArrangedSubview(deleteButton)
        } else {
            let cloneButton = NSButton(title: "Clone…", target: self, action: #selector(handleCloneHaplotypeDefinition(_:)))
            cloneButton.identifier = NSUserInterfaceItemIdentifier("clone:\(set.id)")
            cloneButton.controlSize = .small
            row.addArrangedSubview(cloneButton)
            let viewButton = NSButton(title: "View…", target: self, action: #selector(handleViewHaplotypeDefinition(_:)))
            viewButton.identifier = NSUserInterfaceItemIdentifier("view:\(set.id)")
            viewButton.controlSize = .small
            row.addArrangedSubview(viewButton)
        }
        return row
    }

    @objc private func handleUseHaplotypeDefinition(_ sender: NSButton) {
        guard let raw = sender.identifier?.rawValue,
              let id = raw.split(separator: ":", maxSplits: 1).last.map(String.init) else {
            return
        }
        do {
            try useHaplotypeDefinition(id: id)
        } catch {
            presentSheetAlert(error: error)
        }
    }

    @objc private func handleCloneHaplotypeDefinition(_ sender: NSButton) {
        guard let raw = sender.identifier?.rawValue,
              let id = raw.split(separator: ":", maxSplits: 1).last.map(String.init),
              let source = GenotypeHaplotypeDefinitionRegistry.builtIn.definitionSet(id: id) else {
            return
        }
        // Build a new user-defined copy with a fresh ID + bumped name
        // so editing doesn't collide with the source built-in.
        let clone = GenotypeHaplotypeDefinitionSet(
            id: "custom.\(id).\(Int(Date().timeIntervalSince1970))",
            assayID: source.assayID,
            displayName: "\(source.displayName) (Copy)",
            speciesName: source.speciesName,
            speciesCode: source.speciesCode,
            prefix: source.prefix,
            locusDefinitions: source.locusDefinitions
        )
        presentHaplotypeDefinitionEditor(draft: clone)
    }

    @objc private func handleViewHaplotypeDefinition(_ sender: NSButton) {
        guard let raw = sender.identifier?.rawValue,
              let id = raw.split(separator: ":", maxSplits: 1).last.map(String.init),
              let set = GenotypeHaplotypeDefinitionRegistry.builtIn.definitionSet(id: id) else {
            return
        }
        // Built-in sets are read-only; open the editor for inspection
        // but Save is disabled (the editor's save callback also no-ops
        // when the id matches a built-in).
        presentHaplotypeDefinitionEditor(draft: set, isReadOnly: true)
    }

    @objc private func handleDeleteHaplotypeDefinition(_ sender: NSButton) {
        guard let raw = sender.identifier?.rawValue,
              let id = raw.split(separator: ":", maxSplits: 1).last.map(String.init) else {
            return
        }
        let alert = NSAlert()
        alert.messageText = "Delete this haplotype definition?"
        alert.informativeText = "Removes the JSON file under \"Haplotype Definitions/\". This cannot be undone."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: view.window ?? NSApp.keyWindow ?? NSWindow()) { [weak self] response in
            guard response == .alertFirstButtonReturn, let self else { return }
            do {
                try self.haplotypeDefinitionStore.delete(id: id)
                self.refreshAfterHaplotypeDefinitionChange()
            } catch {
                self.presentSheetAlert(error: error)
            }
        }
    }

    @objc private func handleNewHaplotypeDefinition(_ sender: NSButton) {
        let blank = GenotypeHaplotypeDefinitionSet(
            id: "custom.\(Int(Date().timeIntervalSince1970))",
            assayID: "MHC-exon2-miSeq",
            displayName: "New definition",
            speciesName: "Custom",
            speciesCode: "CUS",
            prefix: "",
            locusDefinitions: []
        )
        presentHaplotypeDefinitionEditor(draft: blank)
    }

    @objc private func handleEditHaplotypeDefinition(_ sender: NSButton) {
        guard let raw = sender.identifier?.rawValue,
              let id = raw.split(separator: ":", maxSplits: 1).last.map(String.init),
              let existing = haplotypeDefinitionStore.loadAllUserSets().first(where: { $0.id == id }) else {
            return
        }
        presentHaplotypeDefinitionEditor(draft: existing)
    }

    private func presentHaplotypeDefinitionEditor(
        draft: GenotypeHaplotypeDefinitionSet,
        isReadOnly: Bool = false
    ) {
        let editor = GenotypeHaplotypeDefinitionEditor(
            draft: draft,
            isReadOnly: isReadOnly,
            onSave: { [weak self] saved in
                guard let self else { return }
                guard !isReadOnly else {
                    self.dismissHaplotypeDefinitionEditor()
                    return
                }
                do {
                    try self.haplotypeDefinitionStore.save(saved)
                    self.dismissHaplotypeDefinitionEditor()
                    self.refreshAfterHaplotypeDefinitionChange()
                } catch {
                    self.presentSheetAlert(error: error)
                }
            },
            onCancel: { [weak self] in
                self?.dismissHaplotypeDefinitionEditor()
            }
        )
        let hosting = NSHostingController(rootView: editor)
        hosting.view.frame = NSRect(x: 0, y: 0, width: 760, height: 520)
        haplotypeDefinitionEditorHost = hosting
        guard let window = view.window ?? NSApp.keyWindow else {
            NSApp.presentError(NSError(domain: "Lungfish", code: 0))
            return
        }
        window.beginSheet(NSWindow(contentViewController: hosting), completionHandler: nil)
    }

    private func dismissHaplotypeDefinitionEditor() {
        guard let host = haplotypeDefinitionEditorHost else { return }
        host.view.window?.sheetParent?.endSheet(host.view.window!)
        haplotypeDefinitionEditorHost = nil
    }

    private func makeDropoutThresholdHost() -> NSView {
        let container = NSHostingView(rootView: dropoutThresholdBody())
        container.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            container.heightAnchor.constraint(greaterThanOrEqualToConstant: 200),
        ])
        return container
    }

    private func dropoutThresholdBody() -> some View {
        let settings = annotationStore?.sidecar.settings ?? .default
        let loci: [String] = {
            guard let analysis = activeHaplotypeAnalysis() else { return [] }
            return orderedLoci(from: analysis)
        }()
        return GenotypeDropoutThresholdSection(
            absoluteEnabled: Binding(
                get: { [weak self] in self?.dropoutAbsoluteEnabled ?? (settings.dropoutAbsolute != nil) },
                set: { [weak self] newValue in self?.dropoutAbsoluteEnabled = newValue }
            ),
            absoluteValue: Binding(
                get: { [weak self] in self?.dropoutAbsoluteValue ?? (settings.dropoutAbsolute ?? 50) },
                set: { [weak self] newValue in self?.dropoutAbsoluteValue = newValue }
            ),
            sampleFractionEnabled: Binding(
                get: { [weak self] in self?.dropoutSampleFractionEnabled ?? (settings.dropoutSampleFraction != nil) },
                set: { [weak self] newValue in self?.dropoutSampleFractionEnabled = newValue }
            ),
            sampleFractionPercent: Binding(
                get: { [weak self] in self?.dropoutSampleFractionPercent ?? ((settings.dropoutSampleFraction ?? 0.001) * 100) },
                set: { [weak self] newValue in self?.dropoutSampleFractionPercent = newValue }
            ),
            locusFractionEnabled: Binding(
                get: { [weak self] in self?.dropoutLocusFractionEnabled ?? (settings.dropoutLocusFraction != nil) },
                set: { [weak self] newValue in self?.dropoutLocusFractionEnabled = newValue }
            ),
            locusFractionPercent: Binding(
                get: { [weak self] in self?.dropoutLocusFractionPercent ?? ((settings.dropoutLocusFraction ?? 0.01) * 100) },
                set: { [weak self] newValue in self?.dropoutLocusFractionPercent = newValue }
            ),
            perLocusFractionPercents: Binding(
                get: { [weak self] in self?.dropoutPerLocusFractionPercents ?? [:] },
                set: { [weak self] newValue in self?.dropoutPerLocusFractionPercents = newValue }
            ),
            availableLoci: loci,
            onApply: { [weak self] evaluator in
                self?.applyDropoutThresholds(evaluator)
            }
        )
    }

    private func applyDropoutThresholds(_ evaluator: GenotypeDropoutEvaluator) {
        guard let store = annotationStore else { return }
        do {
            try store.updateSettings { settings in
                settings.dropoutAbsolute = evaluator.absolute
                settings.dropoutSampleFraction = evaluator.sampleFraction
                settings.dropoutLocusFraction = evaluator.locusFraction
                settings.locusFractionOverrides = evaluator.locusFractionOverrides.isEmpty
                    ? nil
                    : evaluator.locusFractionOverrides
            }
        } catch {
            presentSheetAlert(error: error)
            return
        }
        // Re-run the haplotype analyzer against the raw calls with the new
        // dropout config. Calls dropped below threshold disappear from the
        // observed-allele set so the subset-match rule re-evaluates the
        // matched haplotypes. The persisted pipeline output stays
        // authoritative on disk; this in-memory recomputation is what the
        // Outline / Matrix render.
        recomputeLiveHaplotypeAnalysis(evaluator: evaluator)
        rebuildHaplotypeLens()
        rebuildOutline()
        rebuildHaplotypeMatrix()
        rebuildCohortSummary()
        applyComparisonMatrixCohortFilter()
        if selectedLens == .review {
            updateCallEvidence()
        }
    }

    /// Recompute the live (in-memory) haplotype analysis using the current
    /// dropout configuration. Falls back to the pipeline-persisted analysis
    /// when no definition set is available.
    private func recomputeLiveHaplotypeAnalysis(evaluator: GenotypeDropoutEvaluator?) {
        guard let result, let definitionSet = definitionSetForResult(result) else {
            liveHaplotypeAnalysis = nil
            return
        }
        guard !result.calls.isEmpty else {
            liveHaplotypeAnalysis = nil
            return
        }
        liveHaplotypeAnalysis = GenotypeHaplotypeAnalyzer.analyze(
            calls: result.calls,
            definitionSet: definitionSet,
            generatedAt: nil,
            dropoutFilter: evaluator
        )
    }

    private func useHaplotypeDefinition(id: String) throws {
        guard let definitionSet = haplotypeDefinitionStore.mergedRegistry().definitionSet(id: id) else { return }
        guard let store = annotationStore else { return }
        try store.updateSettings { settings in
            settings.activeHaplotypeDefinitionSetID = id
            settings.activeHaplotypeAssayID = definitionSet.assayID
        }
        refreshAfterHaplotypeDefinitionChange()
        onAnnotationSidecarChanged?(store.sidecar)
    }

    private func refreshAfterHaplotypeDefinitionChange() {
        liveHaplotypeAnalysis = nil
        if let result, definitionSetForResult(result) != nil {
            recomputeLiveHaplotypeAnalysis(evaluator: currentDropoutEvaluator())
        }
        rebuildSummary()
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
        // Surface the manual-haplotyping section when there is no built-in
        // analysis or when the bundle already carries manual assignments.
        if result.haplotypeAnalysis == nil { return true }
        return !(annotationStore?.sidecar.manualHaplotypeAssignments.isEmpty ?? true)
    }

    private func makeManualHaplotypingHost() -> NSView {
        let container = NSHostingView(rootView: manualHaplotypingSectionBody())
        container.translatesAutoresizingMaskIntoConstraints = false
        container.frame.size.height = 240
        NSLayoutConstraint.activate([
            container.heightAnchor.constraint(greaterThanOrEqualToConstant: 200),
        ])
        return container
    }

    private func manualHaplotypingSectionBody() -> some View {
        let rows = manualHaplotypingRows()
        let assignments = annotationStore?.sidecar.manualHaplotypeAssignments ?? []
        return GenotypeManualHaplotypingSection(
            rows: rows,
            manualAssignments: assignments,
            selectedGenotypeIds: Binding(
                get: { [weak self] in self?.manualHaplotypingSelection ?? [] },
                set: { [weak self] newValue in self?.manualHaplotypingSelection = newValue }
            ),
            draftLabel: Binding(
                get: { [weak self] in self?.manualHaplotypingDraftLabel ?? "" },
                set: { [weak self] newValue in self?.manualHaplotypingDraftLabel = newValue }
            ),
            draftColorTokenIndex: Binding(
                get: { [weak self] in self?.manualHaplotypingDraftColorTokenIndex ?? 1 },
                set: { [weak self] newValue in self?.manualHaplotypingDraftColorTokenIndex = newValue }
            ),
            onCreateHaplotype: { [weak self] in self?.commitManualHaplotype() },
            onDeleteAssignment: { [weak self] assignment in
                self?.deleteManualHaplotype(matching: assignment)
            },
            onExportDefinitions: { [weak self] in self?.exportManualDefinitions() }
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
        guard let result, let store = annotationStore else { return }
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
            try store.addManualHaplotypeAssignments(bulk)
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
        do {
            try store.removeManualHaplotypeAssignments { other in
                other.label == assignment.label
            }
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
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "manual-haplotype-definitions.json"
        panel.beginSheetModal(for: view.window ?? NSApp.keyWindow ?? NSWindow()) { response in
            guard response == .OK, let url = panel.url else { return }
            do {
                let startedAt = Date()
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                let data = try encoder.encode(store.sidecar.manualHaplotypeAssignments)
                try data.write(to: url, options: .atomic)
                try self.writeManualDefinitionsExportProvenance(
                    outputURL: url,
                    assignmentCount: store.sidecar.manualHaplotypeAssignments.count,
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
            "lungfish-gui",
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
        guard let result, let analysis = activeHaplotypeAnalysis(), !analysis.samples.isEmpty else {
            outlineView.configure(rows: [])
            return
        }
        let observed = GenotypeObservedLociIndex.build(from: result)
        // Default: show only the loci the active haplotype definition set
        // analyzes (e.g. the 7 canonical MCM loci). Toggle in the Inspector
        // expands the tape to include observed-only loci.
        let analyzedLoci = orderedLoci(from: analysis)
        let loci: [String] = displayState.showsAncillaryLoci ? observed.loci : analyzedLoci
        let allowedSamples = filteredSampleNames(result: result, sidecar: annotationStore?.sidecar)
        var rows: [GenotypeOutlineView.Row] = []
        for sample in analysis.samples where allowedSamples.contains(sample.sample) {
            let tapeSlots = outlineTapeSlots(
                for: sample,
                loci: loci,
                observed: observed
            )
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
            let blockKind = GenotypeBlockClassifier.classify(
                calls: effectiveCalls.map { (locus: $0.locus, h1: $0.h1, h2: $0.h2) }
            )
            let comment = outlineCommentSummary(for: sample, effectiveCalls: effectiveCalls)
            let issueCount = outlineNoteIssueCount(for: sample, effectiveCalls: effectiveCalls)
            // Per-locus call text feeds the inline detail block when the
            // analyst opens the row's disclosure triangle.
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
    }

    private func rebuildHaplotypeMatrix() {
        guard selectedLens == .summary && displayState.summaryViewMode == .matrix else {
            return
        }
        if activeHaplotypeAnalysis() == nil {
            recomputeLiveHaplotypeAnalysis(evaluator: currentDropoutEvaluator())
        }
        guard let result,
              let analysis = activeHaplotypeAnalysis(),
              let definitionSet = definitionSetForResult(result),
              !analysis.samples.isEmpty else {
            haplotypeMatrixView.configure(rows: [], definitionName: nil)
            return
        }
        let allowedSamples = filteredSampleNames(
            result: result,
            sidecar: annotationStore?.sidecar,
            includingQuickSearch: false
        )
        var definitionsByLocus: [String: GenotypeHaplotypeLocusDefinition] = [:]
        for definition in definitionSet.locusDefinitions where definitionsByLocus[definition.locus] == nil {
            definitionsByLocus[definition.locus] = definition
        }
        let callsBySample = Dictionary(grouping: result.calls, by: \.sample)
        let search = activeMatrixSearchText()
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
            let sampleWideSearchMatch = matrixSampleWideSearchMatches(sampleId: sample.sample, searchText: search)
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
                        observedCount: observedCount,
                        diagnosticCount: haplotype.diagnosticAlleles.count,
                        minimumMatches: haplotype.effectiveMinimumMatches,
                        status: status,
                        alleles: alleles
                    )
                }.filter { row in
                    search.isEmpty || sampleWideSearchMatch || matrixRow(row, matches: search)
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

    private func activeMatrixSearchText() -> String {
        let quickSearch = quickFilterSearchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let activeSearch = quickSearch.isEmpty
            ? activeSmartCohort?.predicate.visibleTextSearch
            : quickSearch
        return activeSearch?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    private func matrixSampleWideSearchMatches(sampleId: String, searchText: String) -> Bool {
        let search = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !search.isEmpty else { return true }
        return sampleId.localizedCaseInsensitiveContains(search)
            || metadataMatches(sampleId: sampleId, searchText: search)
            || annotationTextMatches(sampleId: sampleId, searchText: search)
    }

    private func matrixRow(_ row: GenotypeHaplotypeDefinitionMatrixView.Row, matches searchText: String) -> Bool {
        let search = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !search.isEmpty else { return true }
        if row.sample.localizedCaseInsensitiveContains(search)
            || row.locus.localizedCaseInsensitiveContains(search)
            || row.callName.localizedCaseInsensitiveContains(search)
            || row.haplotypeName.localizedCaseInsensitiveContains(search)
            || row.status.displayName.localizedCaseInsensitiveContains(search) {
            return true
        }
        return row.alleles.contains {
            $0.name.localizedCaseInsensitiveContains(search)
        }
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
        let predicates: [SmartCohortPredicate] = [
            activeSmartCohort?.predicate,
            quickFilterPredicate,
        ].compactMap { $0 }
        if !predicates.isEmpty {
            let liveSidecar = sidecar ?? GenotypeAnnotationSidecar.empty(generatedAt: "")
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
            let matched = names.filter { sampleMatchesUnifiedSearch(sampleId: $0, searchText: search) }
            allowed.formIntersection(matched)
        }
        return allowed
    }

    private func matrixRowFilterText(
        result: ONTGenotypeResultBundleData,
        allowedSamples: Set<String>?
    ) -> String {
        let quickSearch = quickFilterSearchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let activeSearch = quickSearch.isEmpty
            ? activeSmartCohort?.predicate.visibleTextSearch
            : quickSearch
        let search = activeSearch?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !search.isEmpty else { return "" }
        let summaries = result.locusSummaries(
            minimumSupportPercent: displayState.activeMinimumSupportPercent,
            denominator: displayState.supportDenominator
        )
        let hasMatrixMatch = summaries.lazy.flatMap(\.sharedCalls).contains { row in
            if let allowedSamples,
               !row.sampleSupport.contains(where: { allowedSamples.contains($0.sample) }) {
                return false
            }
            if row.locus.localizedCaseInsensitiveContains(search)
                || row.genotype.localizedCaseInsensitiveContains(search) {
                return true
            }
            return row.sampleSupport.contains { support in
                guard allowedSamples?.contains(support.sample) ?? true else { return false }
                return support.sample.localizedCaseInsensitiveContains(search)
                    || metadataMatches(sampleId: support.sample, searchText: search)
            }
        }
        return hasMatrixMatch ? search : ""
    }

    private func allFilterableSampleNames(result: ONTGenotypeResultBundleData) -> [String] {
        var seen = Set<String>()
        let sources = (activeHaplotypeAnalysis()?.samples ?? []).map(\.sample)
            + (result.haplotypeAnalysis?.samples ?? []).map(\.sample)
            + result.sampleNames
            + result.samples.map(\.sample)
            + result.calls.map(\.sample)
        return sources.filter { seen.insert($0).inserted }
    }

    private func sampleMatchesUnifiedSearch(sampleId: String, searchText: String) -> Bool {
        let search = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !search.isEmpty else { return true }
        if sampleId.localizedCaseInsensitiveContains(search) { return true }
        if metadataMatches(sampleId: sampleId, searchText: search) { return true }
        if annotationTextMatches(sampleId: sampleId, searchText: search) { return true }
        if haplotypeCallMatches(sampleId: sampleId, searchText: search) { return true }
        if genotypeCallMatches(sampleId: sampleId, searchText: search) { return true }
        return false
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

    private func haplotypeCallMatches(sampleId: String, searchText: String) -> Bool {
        guard let sample = activeHaplotypeAnalysis()?.samples.first(where: { $0.sample == sampleId }) else {
            return false
        }
        let separators = CharacterSet(charactersIn: "@:")
        if let range = searchText.rangeOfCharacter(from: separators),
           metadataFieldQuery(from: searchText) == nil {
            let prefix = String(searchText[..<range.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
            let locusRaw = String(searchText[range.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !prefix.isEmpty, !locusRaw.isEmpty else { return false }
            let locus = locusRaw.hasPrefix("MHC-") ? locusRaw : "MHC-\(locusRaw)"
            return sample.calls.contains { call in
                guard call.locus.localizedCaseInsensitiveCompare(locus) == .orderedSame else { return false }
                let effective = effectiveHaplotypeCall(sample: sampleId, call: call)
                return effective.h1.hasPrefix(prefix) || effective.h2.hasPrefix(prefix)
            }
        }
        return sample.calls.contains { call in
            let effective = effectiveHaplotypeCall(sample: sampleId, call: call)
            return call.locus.localizedCaseInsensitiveContains(searchText)
                || effective.h1.localizedCaseInsensitiveContains(searchText)
                || effective.h2.localizedCaseInsensitiveContains(searchText)
                || call.observedGenotypes.contains { $0.localizedCaseInsensitiveContains(searchText) }
        }
    }

    private func genotypeCallMatches(sampleId: String, searchText: String) -> Bool {
        guard let result else { return false }
        return result.calls.contains { call in
            call.sample == sampleId
                && (
                    call.genotype.localizedCaseInsensitiveContains(searchText)
                    || call.locusGroup.localizedCaseInsensitiveContains(searchText)
                )
        }
    }

    private func rebuildCohortSummary() {
        guard let result else {
            cohortSummaryPanel.configure(summary: .init(
                qcCounts: [],
                errorTypeCounts: [],
                annotationCounts: [],
                outlierSamples: [],
                belowThresholdSamples: [],
                belowThresholdValue: 5_000
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
        let belowThresholdValue = 5_000
        let belowThreshold = result.samples
            .filter { $0.passedUniqueReads < belowThresholdValue }
            .map(\.sample)
            .sorted()
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

    private func outlineTapeSlots(
        for sample: GenotypeHaplotypeSampleAnalysis,
        loci: [String],
        observed: GenotypeObservedLociIndex? = nil
    ) -> [GenotypeHaplotypeTapeView.Slot] {
        let callsByLocus = Dictionary(uniqueKeysWithValues: sample.calls.map { ($0.locus, $0) })
        let observedForSample = observed?.observedCallsBySampleAndLocus[sample.sample] ?? [:]
        return loci.map { locus -> GenotypeHaplotypeTapeView.Slot in
            if let call = callsByLocus[locus] {
                let effective = effectiveHaplotypeCall(sample: sample.sample, call: call)
                let h1 = outlineCell(for: effective.h1, status: effective.status)
                let displayedH2 = normalizedHomozygousSecondHaplotype(
                    h1: effective.h1,
                    h2: effective.h2,
                    status: effective.status
                )
                let h2 = outlineCell(for: displayedH2, status: effective.status)
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
        if hasOverride && !h1.hasPrefix("ERR") && !h2.hasPrefix("ERR") {
            return (h1, h2, .called)
        }
        return (h1, h2, call.status)
    }

    private func outlineCell(
        for name: String,
        status: GenotypeHaplotypeCallStatus
    ) -> GenotypeHaplotypeTapeView.Cell {
        if status == .notAssayed {
            return .notAssayed(label: name.isEmpty ? "Not assayed" : name)
        }
        if name == "-" || name.isEmpty {
            return .empty
        }
        if status != .called && status != .notAssayed && status != .specialCase {
            return .error(label: name)
        }
        let token = HaplotypeColorToken.assigned(forName: name)
        return .reference(tokenIndex: token.canonicalIndex, label: name)
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
            showLens(.review)
            onDisplayStateChanged?(displayState)
        } else {
            if callEvidenceHost == nil {
                installCallEvidenceHost()
            }
            updateCallEvidence()
        }
    }

    private func applyOverrideFromInspector(haplotype: String) {
        guard let store = annotationStore else { return }
        guard let evidence = callEvidence, !haplotype.isEmpty else { return }
        let slot = overrideSlotForCandidate(haplotype, evidence: evidence)
        let rawCall = rawLocusCall(sample: evidence.sample, locus: evidence.locus)
        let originalCall = slot == .h1
            ? (rawCall?.haplotype1 ?? evidence.h1Name)
            : (rawCall?.haplotype2 ?? evidence.h2Name)
        do {
            try store.applyOverride(
                sample: evidence.sample,
                locus: evidence.locus,
                slot: slot,
                originalCall: originalCall,
                overrideCall: haplotype,
                reasonTag: .misCall,
                rationale: "Promoted \(haplotype) from Review inspector candidate matrix."
            )
            refreshAfterHaplotypeOverride()
        } catch {
            presentSheetAlert(error: error)
        }
    }

    private func overrideSlotForCandidate(
        _ haplotype: String,
        evidence: GenotypeCallEvidenceView.Evidence
    ) -> HaplotypeSlot {
        let h1 = evidence.h1Name
        let h2 = evidence.h2Name
        if h1.isEmpty || h1 == "-" || h1.hasPrefix("ERR") {
            return .h1
        }
        if h2.isEmpty || h2 == "-" || h2 == h1 || h2.hasPrefix("ERR") {
            return h1 == haplotype ? .h1 : .h2
        }
        if h1 == haplotype {
            return .h1
        }
        return .h2
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
        let h1 = evidence.h1Name.isEmpty ? evidence.callName : evidence.h1Name
        let h2 = evidence.h2Name.isEmpty || evidence.h2Name == "-" ? h1 : evidence.h2Name
        do {
            try store.confirmCall(sample: evidence.sample, locus: evidence.locus, h1: h1, h2: h2)
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
            return names + ["A1_063", "-"]
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
        let originalCall = row.callName
        do {
            try store.applyOverride(
                sample: animalId,
                locus: row.locus,
                slot: row.slot,
                originalCall: originalCall,
                overrideCall: draft.target,
                reasonTag: draft.reason,
                rationale: draft.rationale
            )
        } catch {
            presentSheetAlert(error: error)
        }
        refreshAfterHaplotypeOverride()
        // Re-present the sheet with fresh state so the analyst can keep working.
        dismissSampleDetailSheet()
        presentSampleDetailSheet(forAnimal: animalId)
    }

    private func clearOverride(forAnimal animalId: String,
                               row: GenotypeSampleDetailSheet.CallRow) {
        guard let store = annotationStore else { return }
        do {
            try store.clearOverride(sample: animalId, locus: row.locus, slot: row.slot)
        } catch {
            presentSheetAlert(error: error)
        }
        refreshAfterHaplotypeOverride()
        dismissSampleDetailSheet()
        presentSampleDetailSheet(forAnimal: animalId)
    }

    private func refreshAfterHaplotypeOverride() {
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

    private func definitionSetForResult(_ result: ONTGenotypeResultBundleData) -> GenotypeHaplotypeDefinitionSet? {
        haplotypeDefinitionContext(for: result)?.definition
    }

    private func shouldEagerlyRecomputeHaplotypeAnalysis(for result: ONTGenotypeResultBundleData) -> Bool {
        guard result.haplotypeAnalysis == nil else { return false }
        guard let context = haplotypeDefinitionContext(for: result) else { return false }
        return context.source != .inferredPreview
    }

    private enum HaplotypeDefinitionSource {
        case sidecarOverride
        case bundleAnalysis
        case bundleManifest
        case inferredPreview

        var displayName: String {
            switch self {
            case .sidecarOverride:
                return "Active bundle setting"
            case .bundleAnalysis:
                return "Bundle analysis"
            case .bundleManifest:
                return "Bundle manifest"
            case .inferredPreview:
                return "Inferred preview"
            }
        }
    }

    private func haplotypeDefinitionContext(
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
        if let id = result.manifest.haplotypeDefinitionSetID,
           let definition = registry.definitionSet(id: id, assayID: result.manifest.haplotypeAssayID) {
            return (definition, .bundleManifest)
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
        return nil
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
        guard !sidecar.callOverrides.isEmpty || !sidecar.auditLog.isEmpty else { return base }
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
        return GenotypeViewportExportSnapshot(
            bundleURL: base.bundleURL,
            analysisName: base.analysisName,
            lens: base.lens,
            filters: base.filters,
            sampleNames: base.sampleNames,
            rows: base.rows,
            provenanceInputURLs: base.provenanceInputURLs,
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

    private func fileViewerSelectionURLs(for export: GenotypeViewportExcelExportResult) -> [URL] {
        [export.packageURL]
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
        let panel = NSSavePanel()
        panel.title = "Export Genotype View"
        panel.nameFieldStringValue = "\(result.manifest.outputName)-genotype-view.lungfishexport"
        panel.canCreateDirectories = true
        panel.prompt = "Export"
        panel.beginSheetModal(for: view.window ?? NSApp.keyWindow ?? NSWindow()) { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            Task { @MainActor [weak self] in
                guard let self else { return }
                do {
                    guard let snapshot = self.currentExportSnapshot() else { return }
                    let export = try GenotypeViewportExcelExportService().export(snapshot: snapshot, to: url)
                    NSWorkspace.shared.activateFileViewerSelecting(self.fileViewerSelectionURLs(for: export))
                } catch {
                    if let window = self.view.window ?? NSApp.keyWindow {
                        NSAlert(error: error).beginSheetModal(for: window, completionHandler: { _ in })
                    } else {
                        NSApp.presentError(error)
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
        state.summaryViewMode = .matrix
        applyDisplayState(state)
        quickFilterBar.setSearchText(sample)
        if activeHaplotypeAnalysis() == nil {
            comparisonMatrix.selectFirstSharedCall()
        }
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
        labelField.widthAnchor.constraint(equalToConstant: 120).isActive = true
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
        guard let result,
              let call = result.calls.first(where: { $0.sample == sample && $0.genotype == genotype }),
              let fraction = result.supportFraction(for: call, denominator: displayState.supportDenominator) else {
            return "Unavailable"
        }
        return percent(fraction)
    }

    private func sameLocusCoOccurrences(for sharedCall: ONTGenotypeSharedCall) -> [ONTGenotypeCoOccurrence] {
        result?.sameLocusCoOccurrences(
            for: sharedCall.genotype,
            minimumSupportPercent: displayState.activeMinimumSupportPercent,
            denominator: displayState.supportDenominator
        ) ?? []
    }

    private func anchorSummary(for sharedCall: ONTGenotypeSharedCall) -> ONTGenotypeAnchorSummary? {
        result?.anchorSummaries(
            minimumSupportPercent: displayState.activeMinimumSupportPercent,
            denominator: displayState.supportDenominator
        ).first { anchor in
            anchor.sharedCalls.contains { $0.genotype == sharedCall.genotype && $0.locus == sharedCall.locus }
        }
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
        stack.arrangedSubviews.forEach { view in
            stack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
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
    func splitViewDidResizeSubviews(_ notification: Notification) {
        splitCoordinator.splitViewDidResizeSubviews(
            splitView,
            minimumExtents: minimumSplitExtents()
        )
    }

    func splitView(_ splitView: NSSplitView, resizeSubviewsWithOldSize oldSize: NSSize) {
        splitCoordinator.resizeSubviewsWithOldSize(
            self.splitView,
            oldSize: oldSize,
            defaultLeadingFraction: defaultLeadingFraction(for: displayState.layout),
            defaultLeadingExtent: defaultLeadingExtent(for: displayState.layout),
            minimumExtents: minimumSplitExtents()
        )
    }

    func splitView(
        _ splitView: NSSplitView,
        constrainMinCoordinate proposedMinimumPosition: CGFloat,
        ofSubviewAt dividerIndex: Int
    ) -> CGFloat {
        minimumSplitExtents().leading
    }

    func splitView(
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
extension GenotypeResultViewController {
    func testingSelectFirstSharedCall() {
        comparisonMatrix.selectFirstSharedCall()
    }

    func testingSelectLens(_ lens: Lens) {
        showLens(lens)
    }

    func testingReviewHaplotypeSample(_ sample: String) {
        showAnalystCalls(forHaplotypeSample: sample)
    }

    func testingConfirmCurrentCallEvidence() {
        confirmCurrentCallEvidence()
    }

    var testingCurrentSelectedSample: String? {
        currentSelectedSample
    }

    var testingCurrentCallEvidenceSample: String? {
        callEvidence?.sample
    }

    func testingOutlineIssueCount(sample: String) -> Int? {
        outlineRowsBySample[sample]?.noteIssueCount
    }

    var testingVisibleLensIdentifier: String {
        selectedLens.identifier
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

    var testingSummaryStripText: String {
        textContent(in: summaryStrip).joined(separator: "\n")
    }

    var testingSamplePaneWidth: CGFloat {
        sampleContainer.frame.width
    }

    var testingDetailPaneWidth: CGFloat {
        detailContainer.frame.width
    }

    var testingLocusFilterTitles: [String] {
        comparisonMatrix.testingLocusFilterTitles
    }

    func testingApplyDisplayState(_ state: GenotypeResultDisplayState) {
        applyDisplayState(state)
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
        comparisonMatrix.testingVisibleGenotypes
    }

    func testingSelectFirstSampleCell(sample: String) {
        comparisonMatrix.testingSelectFirstSampleCell(sample: sample)
    }

    var testingHighlightedCellCount: Int {
        comparisonMatrix.testingHighlightedCellCount
    }

    var testingBorderedCellCount: Int {
        comparisonMatrix.testingBorderedCellCount
    }

    var testingCurrentSelectionStyle: GenotypeResultHighlightStyle {
        guard let target = currentSelectionState?.highlightTarget else { return .default }
        return comparisonMatrix.testingHighlightStyle(for: target)
    }

    func testingBackgroundColor(genotype: String, sample: String) -> NSColor? {
        comparisonMatrix.testingBackgroundColor(genotype: genotype, sample: sample)
    }

    var testingDetailContentTopInset: CGFloat {
        detailStack.frame.minY
    }

    func testingRenderVisibleCells(rowLimit: Int) {
        comparisonMatrix.testingRenderVisibleCells(rowLimit: rowLimit)
    }

    func testingSetComparisonFilter(_ text: String) {
        comparisonMatrix.testingSetFilter(text)
    }

    func testingSetUnifiedSampleFilter(_ text: String) {
        quickFilterBar.setSearchText(text)
        applyComparisonMatrixCohortFilter()
    }

    func testingSaveCurrentFilterAsSmartCohort() throws {
        try saveCurrentFilterAsSmartCohort()
    }

    func testingCurrentExportSnapshot() -> GenotypeViewportExportSnapshot? {
        currentExportSnapshot()
    }

    func testingFileViewerSelectionURLs(for export: GenotypeViewportExcelExportResult) -> [URL] {
        fileViewerSelectionURLs(for: export)
    }

    var testingSavedCohortChipTitle: String? {
        quickFilterBar.testingSavedCohortChipTitle
    }

    var testingVisibleOutlineSamples: [String] {
        outlineRowOrder
    }

    var testingHaplotypeMatrixText: String {
        haplotypeMatrixView.testingText
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
        let observed = GenotypeObservedLociIndex.build(from: result)
        return outlineTapeSlots(
            for: sample,
            loci: orderedLoci(from: analysis),
            observed: observed
        )
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
