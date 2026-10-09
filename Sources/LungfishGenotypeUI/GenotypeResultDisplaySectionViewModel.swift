import AppKit
import SwiftUI
import LungfishCore
import LungfishIO
import LungfishKit

@Observable
@MainActor
public final class GenotypeResultDisplaySectionViewModel {
    public var displayState = GenotypeResultDisplayState()
    public var isAvailable = false
    public var visibleRowCount = 0
    public var totalRowCount = 0
    public var hiddenCellCount = 0
    public var hasHaplotypingResult = false
    public var isGenotypeOnlyResult = false
    public var showsViewportAndLayoutControls: Bool { !isGenotypeOnlyResult }
    public var isExpanded = true
    public var genotypeResultSelection: GenotypeResultSelectionState?
    public var genotypeHighlightColor: Color = .blue
    public var genotypeBorderColor: Color = .blue
    public var genotypeHighlightScope: GenotypeResultHighlightScope = .selectedCell
    public var genotypeHighlightChannel: GenotypeResultHighlightChannel = .fill
    public var matrixFillColor: Color = Color(nsColor: NSColor.systemYellow)
    public var matrixTextColor: Color = Color(nsColor: NSColor.labelColor)
    public var matrixBorderColor: Color = Color(nsColor: NSColor.systemOrange)
    public var matrixIsBold = false
    public var matrixIsItalic = false
    public var matrixCommentText = ""
    public var matrixPaletteTarget: GenotypeMatrixPaletteTarget = .fill
    public var supportedCellMinimumReads = 1
    public var isMatrixAppearanceExpanded = false
    public var mhcCandidateControlsAvailable = false
    public var mhcCandidateIntegrityWarnings: [String] = []
    public var mhcCandidatePersistenceWarning: String?
    public var locusDisplayOrderAvailable = false
    public var locusDisplayOrderCanEdit = true
    public var locusDisplayOrderDraft = ""
    public var locusDisplayOrderValidationError: String?
    public var locusDisplayOrderPersistenceWarning: String?
    public private(set) var bundleLocusDisplayOrder: [String]?
    public private(set) var presentationPolicy:
        GenotypeResultPresentationPolicy?
    public var presentationChoices:
        [GenotypeResultPresentationPolicy.Choice] {
        presentationPolicy?.appliesToHaplotypedMiSeq == true
            ? (presentationPolicy?.choices ?? [])
            : []
    }
    public var presentationAccessibilityHelp: String {
        presentationPolicy?.inspectorAccessibilityHelp
            ?? "Choose a genotype result viewport."
    }
    var legacyViewportLenses: [GenotypeResultViewportLens] {
        GenotypeResultViewportLens.allCases
    }
    public private(set) var matrixReviewCapability = GenotypeMatrixReviewCapability.evaluate(
        selection: [],
        evidence: .init(),
        reviews: [],
        comments: [],
        isWritable: false
    )
    public private(set) var matrixVisibilityCapability =
        GenotypeMatrixVisibilityCapabilitySnapshot.empty

    public var onDisplayStateChanged: ((GenotypeResultDisplayState) -> Void)? {
        didSet {
            cancelPendingNumericFilterCommitAndRestoreDrafts()
        }
    }
    public var onGenotypeHighlightRequested: ((GenotypeResultHighlightRequest) -> Void)?
    public var onMatrixStyleRequested: ((GenotypeMatrixStyleRequest) -> Void)?
    public var onMatrixReviewRequested: ((GenotypeMatrixReviewRequest) -> Void)?
    public var onMatrixCommentRequested: ((GenotypeMatrixCommentEditRequest) -> Void)?
    public var onMatrixCommentEditRequested: ((GenotypeMatrixCommentEditRequest) -> Void)? {
        get { onMatrixCommentRequested }
        set { onMatrixCommentRequested = newValue }
    }
    public var onSupportSelectionPreviewChanged: ((Int) -> Void)?
    public var onMatrixVisibilityCommandRequested:
        ((GenotypeMatrixVisibilityCommand) -> Void)?
    @ObservationIgnored
    private var isUpdatingFromSelection = false
    @ObservationIgnored
    private let contentTextSizeAnnouncementPoster: any AccessibilityAnnouncementPosting
    let matrixMinimumReadsDraft: GenotypeNumericFilterDraft
    let matrixMinimumPercentDraft: GenotypeNumericFilterDraft
    let matrixMinimumPrevalencePercentDraft: GenotypeNumericFilterDraft
    @ObservationIgnored
    private let numericFilterCommitCoalescer:
        GenotypeNumericFilterCommitCoalescer
    @ObservationIgnored
    private var dirtyNumericFilterFields: Set<NumericFilterField> = []
    @ObservationIgnored
    private var hasPendingNumericFilterPublication = false
    @ObservationIgnored
    private var isNumericFilterStepperBurstActive = false
    private var matrixCommentDrafts: [GenotypeMatrixCommentScope: String] = [:]
    @ObservationIgnored
    private var loadedMatrixCommentStates:
        [GenotypeMatrixCommentScope: GenotypeMatrixValueState<String>] = [:]

    public convenience init(
        contentTextSizeAnnouncementPoster: any AccessibilityAnnouncementPosting =
            AccessibilityAnnouncementPoster()
    ) {
        self.init(
            contentTextSizeAnnouncementPoster:
                contentTextSizeAnnouncementPoster,
            numericFilterScheduler:
                GenotypeNumericFilterRunLoopScheduler(),
            numericFilterLocale: .autoupdatingCurrent,
            numericFilterValidationAnnouncementPoster:
                AccessibilityAnnouncementPoster()
        )
    }

    init(
        contentTextSizeAnnouncementPoster: any AccessibilityAnnouncementPosting =
            AccessibilityAnnouncementPoster(),
        numericFilterScheduler: any GenotypeNumericFilterScheduling,
        numericFilterLocale: Locale,
        numericFilterValidationAnnouncementPoster:
            any AccessibilityAnnouncementPosting
    ) {
        self.contentTextSizeAnnouncementPoster = contentTextSizeAnnouncementPoster
        matrixMinimumReadsDraft = GenotypeNumericFilterDraft(
            configuration: .matrixMinimumReads,
            committedValue: 0,
            locale: numericFilterLocale,
            validationAnnouncementPoster:
                numericFilterValidationAnnouncementPoster
        )
        matrixMinimumPercentDraft = GenotypeNumericFilterDraft(
            configuration: .matrixMinimumPercent,
            committedValue: 0,
            locale: numericFilterLocale,
            validationAnnouncementPoster:
                numericFilterValidationAnnouncementPoster
        )
        matrixMinimumPrevalencePercentDraft = GenotypeNumericFilterDraft(
            configuration: .matrixMinimumPrevalencePercent,
            committedValue: 0,
            locale: numericFilterLocale,
            validationAnnouncementPoster:
                numericFilterValidationAnnouncementPoster
        )
        numericFilterCommitCoalescer = GenotypeNumericFilterCommitCoalescer(
            scheduler: numericFilterScheduler
        )
    }

    public var contentTextSizePreference: ContentTextSizePreference {
        AppSettings.shared.contentTextSizePreference.normalized
    }

    public var contentTextSizeLabel: String {
        switch contentTextSizePreference {
        case .system:
            return "System"
        case .custom(let percentage):
            return "\(percentage)%"
        }
    }

    public var canIncreaseContentTextSize: Bool {
        contentTextSizePreference.larger != contentTextSizePreference
    }

    public var canDecreaseContentTextSize: Bool {
        contentTextSizePreference.smaller != contentTextSizePreference
    }

    public func increaseContentTextSize() {
        applyContentTextSizePreference(contentTextSizePreference.larger)
    }

    public func decreaseContentTextSize() {
        applyContentTextSizePreference(contentTextSizePreference.smaller)
    }

    public func restoreSystemContentTextSize() {
        applyContentTextSizePreference(.system)
    }

    private func applyContentTextSizePreference(
        _ requestedPreference: ContentTextSizePreference
    ) {
        let preference = requestedPreference.normalized
        guard preference != contentTextSizePreference else { return }
        AppSettings.shared.contentTextSizePreference = preference
        AppSettings.shared.save()
        let announcement = switch preference {
        case .system:
            "Content text size System"
        case .custom(let percentage):
            "Content text size \(percentage) percent"
        }
        contentTextSizeAnnouncementPoster.post(announcement, priority: .medium)
    }

    public func update(
        isAvailable: Bool,
        state: GenotypeResultDisplayState = GenotypeResultDisplayState(),
        hasHaplotypingResult: Bool = false,
        isGenotypeOnlyResult: Bool = false
    ) {
        cancelPendingNumericFilterCommit()
        presentationPolicy = nil
        self.isAvailable = isAvailable
        self.hasHaplotypingResult = hasHaplotypingResult
        self.isGenotypeOnlyResult = isGenotypeOnlyResult
        matrixVisibilityCapability = .empty
        setNormalizedDisplayState(state)
        synchronizeLocusDisplayOrderDraft()
        synchronizeNumericFilterDrafts()
        updateSelection(nil)
    }

    public func updateSummary(visibleRows: Int, totalRows: Int, hiddenCells: Int) {
        visibleRowCount = visibleRows
        totalRowCount = totalRows
        hiddenCellCount = hiddenCells
    }

    public func updateDisplayState(_ state: GenotypeResultDisplayState) {
        cancelPendingNumericFilterCommit()
        setNormalizedDisplayState(state)
        synchronizeLocusDisplayOrderDraft()
        synchronizeNumericFilterDrafts()
    }

    public func clear() {
        cancelPendingNumericFilterCommit()
        isAvailable = false
        locusDisplayOrderAvailable = false
        bundleLocusDisplayOrder = nil
        locusDisplayOrderDraft = ""
        locusDisplayOrderValidationError = nil
        locusDisplayOrderPersistenceWarning = nil
        displayState = GenotypeResultDisplayState()
        synchronizeNumericFilterDrafts()
        visibleRowCount = 0
        totalRowCount = 0
        hiddenCellCount = 0
        hasHaplotypingResult = false
        presentationPolicy = nil
        mhcCandidateControlsAvailable = false
        mhcCandidateIntegrityWarnings = []
        mhcCandidatePersistenceWarning = nil
        isGenotypeOnlyResult = false
        matrixReviewCapability = Self.emptyMatrixReviewCapability
        matrixVisibilityCapability = .empty
        matrixCommentDrafts = [:]
        loadedMatrixCommentStates = [:]
        updateSelection(nil)
    }

    public var mhcCandidateDisplaySettings: ONTMHCCandidateDisplaySettings {
        displayState.mhcCandidateDisplaySettings ?? .default
    }

    public func updateMHCCandidatePresentation(from result: ONTGenotypeResultBundleData) {
        bundleLocusDisplayOrder = result.genotypeLocusDisplayOrder
        locusDisplayOrderAvailable = bundleLocusDisplayOrder != nil
            || result.manifest.kind == "full-length-ont-mhc-genotype"
            || result.calls.contains { !MHCReferenceGenotypeDisplay.alleleNames(for: $0.genotype).isEmpty }
        locusDisplayOrderCanEdit = FileManager.default.isWritableFile(atPath: result.bundleURL.path)
        synchronizeLocusDisplayOrderDraft()
        presentationPolicy = GenotypeResultPresentationPolicy(
            legacyBundleKind: result.manifest.kind,
            legacyWorkflowDeclarationsAbsent:
                GenotypeResultPresentationPolicy.workflowDeclarationsAreAbsent(
                    in: result.manifest
                ),
            workflowKind: result.manifest.workflowKind,
            workflowMode: result.manifest.workflowMode,
            manualHaplotypeEligibility:
                GenotypeManualHaplotypeEligibility.evaluate(result),
            haplotypeAnalysis: result.haplotypeAnalysis,
            hasNativeGenotypeMatrixContent:
                result.hasNativeGenotypeMatrixContent,
            isReadOnly: !FileManager.default.isWritableFile(
                atPath: result.bundleURL.path
            )
        )
        setNormalizedDisplayState(displayState)
        let isFullLengthMHCResult = result.manifest.kind == "full-length-ont-mhc-genotype"
        let declaration = result.manifest.mhcCandidateArtifacts
        mhcCandidateControlsAvailable = isFullLengthMHCResult
            && declaration.map { (1 ... 2).contains($0.schemaVersion) } == true
            && declaration?.candidateJSON != nil
            && declaration?.candidateFASTA != nil
            && result.mhcCandidates.map { isSupportedMHCCandidateDocumentSchemaVersion($0.schemaVersion) } == true
        mhcCandidateIntegrityWarnings = isFullLengthMHCResult
            ? result.integrityWarnings.map(Self.integrityWarningText)
            : []
        if !mhcCandidateControlsAvailable {
            displayState.mhcCandidateDisplaySettings = nil
        }
        if !isFullLengthMHCResult {
            mhcCandidatePersistenceWarning = nil
        }
    }

    public var locusDisplayOrderStatus: String {
        if displayState.genotypeLocusDisplayOrder != nil { return "Using the saved order for this result." }
        if bundleLocusDisplayOrder != nil { return "Using the bundle default." }
        return "No bundle default. Apply saves the suggested order below."
    }

    private func synchronizeLocusDisplayOrderDraft() {
        let order = displayState.genotypeLocusDisplayOrder
            ?? bundleLocusDisplayOrder ?? MHCAlleleDisplayOrder.miseqLocusDisplayOrder
        locusDisplayOrderDraft = order.map { $0.replacingOccurrences(of: "MHC-", with: "") }.joined(separator: ", ")
        locusDisplayOrderValidationError = nil
    }

    public func applyLocusDisplayOrderDraft() {
        do {
            let tokens = locusDisplayOrderDraft.split(whereSeparator: { $0 == "," || $0 == "\n" }).map(String.init)
            displayState.genotypeLocusDisplayOrder = try MHCAlleleDisplayOrder.validatedLocusDisplayOrder(tokens)
            synchronizeLocusDisplayOrderDraft()
            notifyStateChanged()
        } catch {
            locusDisplayOrderValidationError = error.localizedDescription
        }
    }

    public func resetLocusDisplayOrder() {
        displayState.genotypeLocusDisplayOrder = nil
        synchronizeLocusDisplayOrderDraft()
        notifyStateChanged()
    }

    public func updateLocusDisplayOrderPersistenceWarning(_ warning: String?) {
        locusDisplayOrderPersistenceWarning = warning
    }

    public func setMHCCandidateVisibility(
        showKnown: Bool? = nil,
        showSharedCandidates: Bool? = nil,
        showSingletonCandidates: Bool? = nil
    ) {
        guard mhcCandidateControlsAvailable else { return }
        var settings = mhcCandidateDisplaySettings
        if let showKnown { settings.showKnown = showKnown }
        if let showSharedCandidates { settings.showSharedCandidates = showSharedCandidates }
        if let showSingletonCandidates { settings.showSingletonCandidates = showSingletonCandidates }
        displayState.mhcCandidateDisplaySettings = settings
        notifyStateChanged()
    }

    public func setMHCCandidateTint(
        _ color: AnnotationColor,
        category: ONTMHCCandidateTintCategory
    ) {
        guard mhcCandidateControlsAvailable else { return }
        var settings = mhcCandidateDisplaySettings
        settings.tints[category] = color
        displayState.mhcCandidateDisplaySettings = settings
        notifyStateChanged()
    }

    public func resetMHCCandidateTint(_ category: ONTMHCCandidateTintCategory) {
        guard let color = ONTMHCCandidateDisplaySettings.defaultTints[category] else { return }
        setMHCCandidateTint(color, category: category)
    }

    public func resetAllMHCCandidateTints() {
        guard mhcCandidateControlsAvailable else { return }
        var settings = mhcCandidateDisplaySettings
        settings.tints = ONTMHCCandidateDisplaySettings.defaultTints
        displayState.mhcCandidateDisplaySettings = settings
        notifyStateChanged()
    }

    public func updateMHCCandidatePersistenceWarning(_ warning: String?) {
        mhcCandidatePersistenceWarning = warning
    }

    func setLayout(_ layout: GenotypeResultPanelLayout) {
        displayState.layout = layout
        setNormalizedDisplayState(displayState)
        notifyStateChanged()
    }

    func setViewportLens(_ lens: GenotypeResultViewportLens) {
        displayState.viewportLens = lens
        setNormalizedDisplayState(displayState)
        notifyStateChanged()
    }

    public func setSummaryViewMode(_ mode: GenotypeSummaryViewMode) {
        displayState.viewportLens = .summary
        displayState.summaryViewMode = mode
        setNormalizedDisplayState(displayState)
        notifyStateChanged()
    }

    private func setNormalizedDisplayState(_ state: GenotypeResultDisplayState) {
        if let presentationPolicy {
            displayState = state.normalized(using: presentationPolicy)
        } else {
            displayState = state.normalized(
                forGenotypeOnlyResult: isGenotypeOnlyResult
            )
        }
    }

    func toggleHaplotypeGenotypeSummaryView() {
        setSummaryViewMode(displayState.summaryViewMode == .matrix ? .outline : .matrix)
    }

    func setHideLowSupport(_ enabled: Bool) {
        displayState.hideLowSupport = enabled
        notifyStateChanged()
    }

    func setMinimumSupportPercent(_ percent: Double) {
        displayState.minimumSupportPercent = max(0, min(100, percent))
        notifyStateChanged()
    }

    func setMinimumReads(_ value: Int) {
        displayState.minimumReads = max(0, value)
        notifyStateChanged()
    }

    func setMatrixMinimumReads(_ value: Int) {
        cancelPendingNumericFilterCommit()
        let value = max(0, min(100_000, value))
        displayState.matrixMinimumReads = value
        matrixMinimumReadsDraft.applyCommittedValue(Double(value))
        notifyStateChanged()
    }

    func setMatrixMinimumPercent(_ value: Double) {
        cancelPendingNumericFilterCommit()
        let value = max(0, min(100, value))
        displayState.matrixMinimumPercent = value
        matrixMinimumPercentDraft.applyCommittedValue(value)
        notifyStateChanged()
    }

    func updateMatrixMinimumReadsDraft(_ value: String) {
        matrixMinimumReadsDraft.updateDraftText(value)
        dirtyNumericFilterFields.insert(.minimumReads)
        scheduleNumericFilterCommit()
    }

    func updateMatrixMinimumPercentDraft(_ value: String) {
        matrixMinimumPercentDraft.updateDraftText(value)
        dirtyNumericFilterFields.insert(.minimumPercent)
        scheduleNumericFilterCommit()
    }

    func setMatrixMinimumPrevalencePercent(_ value: Double) {
        cancelPendingNumericFilterCommit()
        let value = max(0, min(100, value))
        displayState.matrixMinimumPrevalencePercent = value
        matrixMinimumPrevalencePercentDraft.applyCommittedValue(value)
        notifyStateChanged()
    }

    func updateMatrixMinimumPrevalencePercentDraft(_ value: String) {
        matrixMinimumPrevalencePercentDraft.updateDraftText(value)
        dirtyNumericFilterFields.insert(.minimumPrevalencePercent)
        scheduleNumericFilterCommit()
    }

    func commitMatrixMinimumPrevalencePercentDraft() {
        commitNumericFilterDrafts(explicitField: .minimumPrevalencePercent)
    }

    func restoreMatrixMinimumPrevalencePercentDraft() {
        restoreNumericFilterDraft(.minimumPrevalencePercent)
    }

    func setMatrixMinimumPrevalencePercentFromStepper(_ value: Double) {
        commitNumericFilterStepperValue(
            value,
            for: .minimumPrevalencePercent
        )
    }

    func commitMatrixMinimumReadsDraft() {
        commitNumericFilterDrafts(explicitField: .minimumReads)
    }

    func commitMatrixMinimumPercentDraft() {
        commitNumericFilterDrafts(explicitField: .minimumPercent)
    }

    /// Settles every pending numeric filter as one export boundary. Invalid
    /// nonempty input is preserved for correction and no filter is committed.
    public func prepareNumericFiltersForExport() throws -> GenotypeResultDisplayState {
        numericFilterCommitCoalescer.cancel()
        let fields = dirtyNumericFilterFields
        let needsPendingPublication = hasPendingNumericFilterPublication
            || isNumericFilterStepperBurstActive
        for field in fields {
            let draft = numericFilterDraft(for: field)
            let text = draft.draftText.trimmingCharacters(in: .whitespacesAndNewlines)
            guard text.isEmpty || draft.parsedValue != nil else {
                hasPendingNumericFilterPublication = false
                isNumericFilterStepperBurstActive = false
                throw NumericFilterExportValidationError(
                    message: draft.configuration.validationDescription
                )
            }
        }

        var changed = false
        for field in fields {
            let draft = numericFilterDraft(for: field)
            let text = draft.draftText.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty, let parsed = draft.parsedValue else {
                draft.restore()
                continue
            }
            let value = min(
                draft.configuration.bounds.upperBound,
                max(draft.configuration.bounds.lowerBound, parsed)
            )
            draft.applyCommittedValue(value)
            switch field {
            case .minimumReads:
                let integerValue = Int(value)
                changed = changed || displayState.matrixMinimumReads != integerValue
                displayState.matrixMinimumReads = integerValue
            case .minimumPercent:
                changed = changed || displayState.matrixMinimumPercent != value
                displayState.matrixMinimumPercent = value
            case .minimumPrevalencePercent:
                changed = changed || displayState.matrixMinimumPrevalencePercent != value
                displayState.matrixMinimumPrevalencePercent = value
            }
        }
        dirtyNumericFilterFields.removeAll()
        hasPendingNumericFilterPublication = false
        isNumericFilterStepperBurstActive = false
        if changed || needsPendingPublication { notifyStateChanged() }
        return displayState
    }

    private struct NumericFilterExportValidationError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    func restoreMatrixMinimumReadsDraft() {
        restoreNumericFilterDraft(.minimumReads)
    }

    func restoreMatrixMinimumPercentDraft() {
        restoreNumericFilterDraft(.minimumPercent)
    }

    func setMatrixMinimumReadsFromStepper(_ value: Int) {
        commitNumericFilterStepperValue(
            Double(value),
            for: .minimumReads
        )
    }

    func setMatrixMinimumPercentFromStepper(_ value: Double) {
        commitNumericFilterStepperValue(
            value,
            for: .minimumPercent
        )
    }

    func setMatrixPercentDenominator(_ denominator: ONTGenotypeSupportDenominator) {
        displayState.matrixPercentDenominator = denominator
        notifyStateChanged()
    }

    func setMatrixRowFilterText(_ value: String) {
        displayState.matrixRowFilterText = value
        notifyStateChanged()
    }

    func setMatrixSampleFilterText(_ value: String) {
        displayState.matrixSampleFilterText = value
        notifyStateChanged()
    }

    public func updateMatrixVisibilityCapability(
        _ capability: GenotypeMatrixVisibilityCapabilitySnapshot
    ) {
        matrixVisibilityCapability = capability
    }

    public var matrixVisibilityScopeSummary: String {
        matrixVisibilityCapability.summary
    }

    public var matrixVisibilityStatus: String {
        switch (
            matrixVisibilityCapability.isRowVisibilityActive,
            matrixVisibilityCapability.isColumnVisibilityActive
        ) {
        case (false, false):
            return "No manual visibility restrictions."
        case (true, false):
            return "Manual allele-row visibility is active."
        case (false, true):
            return "Manual sample-column visibility is active."
        case (true, true):
            return "Manual allele-row and sample-column visibility are active."
        }
    }

    public var canResetMatrixVisibility: Bool {
        matrixVisibilityCapability.canResetVisibility
    }

    func hideSelectedMatrixRows() {
        guard matrixVisibilityCapability.canHideSelectedRows else { return }
        onMatrixVisibilityCommandRequested?(.hideSelectedRows)
    }

    func showOnlySelectedMatrixRows() {
        guard matrixVisibilityCapability.canShowOnlySelectedRows else { return }
        onMatrixVisibilityCommandRequested?(.showOnlySelectedRows)
    }

    func showAllMatrixRows() {
        guard matrixVisibilityCapability.canShowAllRows else { return }
        onMatrixVisibilityCommandRequested?(.showAllRows)
    }

    func hideSelectedMatrixColumns() {
        guard matrixVisibilityCapability.canHideSelectedColumns else { return }
        onMatrixVisibilityCommandRequested?(.hideSelectedColumns)
    }

    func showOnlySelectedMatrixColumns() {
        guard matrixVisibilityCapability.canShowOnlySelectedColumns else { return }
        onMatrixVisibilityCommandRequested?(.showOnlySelectedColumns)
    }

    func showAllMatrixColumns() {
        guard matrixVisibilityCapability.canShowAllColumns else { return }
        onMatrixVisibilityCommandRequested?(.showAllColumns)
    }

    func resetMatrixVisibility() {
        guard matrixVisibilityCapability.canResetVisibility else { return }
        onMatrixVisibilityCommandRequested?(.reset)
    }

    func setSupportDenominator(_ denominator: ONTGenotypeSupportDenominator) {
        displayState.supportDenominator = denominator
        notifyStateChanged()
    }

    public func setDiagnosticAllelesOnly(_ enabled: Bool) {
        displayState.diagnosticAllelesOnly = enabled
        notifyStateChanged()
    }

    func setCellColorMode(_ mode: GenotypeResultCellColorMode) {
        displayState.cellColorMode = mode
        notifyStateChanged()
    }

    func setHideFilteredHighlights(_ enabled: Bool) {
        displayState.hideFilteredHighlights = enabled
        notifyStateChanged()
    }

    public func setShowsAncillaryLoci(_ enabled: Bool) {
        displayState.showsAncillaryLoci = enabled
        notifyStateChanged()
    }

    public func setIncludedLoci(_ loci: Set<String>?) {
        displayState.includedLoci = loci
        notifyStateChanged()
    }

    public func updateSelection(_ selection: GenotypeResultSelectionState?) {
        isUpdatingFromSelection = true
        defer { isUpdatingFromSelection = false }

        if genotypeResultSelection?.matrixTargets != selection?.matrixTargets {
            matrixCommentDrafts = [:]
            loadedMatrixCommentStates = [:]
        }
        genotypeResultSelection = selection
        genotypeHighlightColor = selection?.highlightStyle.fillColor.map(Self.swiftUIColor) ?? .blue
        genotypeBorderColor = selection?.highlightStyle.borderColor.map(Self.swiftUIColor) ?? .blue
        genotypeHighlightScope = selection?.highlightTarget?.sample == nil ? .selectedRow : .selectedCell
        genotypeHighlightChannel = selection?.highlightStyle.fillColor == nil && selection?.highlightStyle.borderColor != nil
            ? .border
            : .fill
    }

    public func updateMatrixReviewCapability(_ capability: GenotypeMatrixReviewCapabilityState) {
        let previousStates = loadedMatrixCommentStates
        matrixReviewCapability = capability
        let cards = matrixCommentCards
        var nextStates: [GenotypeMatrixCommentScope: GenotypeMatrixValueState<String>] = [:]
        for card in cards {
            let priorState = previousStates[card.scope]
            let priorDefault = priorState.map(Self.defaultCommentDraft(for:))
            if priorState == nil || matrixCommentDrafts[card.scope] == priorDefault {
                matrixCommentDrafts[card.scope] = Self.defaultCommentDraft(for: card.valueState)
            }
            nextStates[card.scope] = card.valueState
        }
        loadedMatrixCommentStates = nextStates
    }

    public var matrixSelectionSummary: String {
        let count = selectedMatrixTargets.count
        switch matrixReviewCapability.selectionShape {
        case .none:
            return "No matrix targets selected"
        case .cells:
            return "\(count) genotype \(count == 1 ? "cell" : "cells") selected"
        case .rows:
            return "\(count) allele \(count == 1 ? "row" : "rows") selected"
        case .columns:
            return "\(count) sample \(count == 1 ? "column" : "columns") selected"
        case .mixed:
            return "\(count) mixed matrix targets selected"
        }
    }

    public var matrixEvidenceSummary: String {
        let support = matrixReviewCapability.support
        guard support.selectedCount > 0 else {
            return "Read support is unavailable for this selection."
        }
        if support.unknownCount > 0 {
            return "Read support is unavailable for this selection."
        }
        if support.supportedCount == support.selectedCount {
            return "All have read support."
        }
        if support.unsupportedCount == support.selectedCount {
            return "No read support."
        }
        return "Selection contains cells with and without read support."
    }

    public var matrixCurrentReviewSummary: String {
        switch matrixReviewCapability.reviewState {
        case .none:
            return "None"
        case let .uniform(disposition):
            switch disposition {
            case .falsePositive:
                return "False positive"
            case .falseNegative:
                return "False negative"
            }
        case .mixed:
            return "Multiple review states"
        }
    }

    public var matrixFalsePositiveAvailability: GenotypeMatrixCommandAvailability {
        matrixReviewCapability.falsePositive
    }

    public var matrixFalseNegativeAvailability: GenotypeMatrixCommandAvailability {
        matrixReviewCapability.falseNegative
    }

    public var matrixClearReviewAvailability: GenotypeMatrixCommandAvailability {
        matrixReviewCapability.clearReview
    }

    public var matrixReviewDisabledReason: String? {
        let reasons = [
            matrixReviewCapability.falsePositive.disabledReason,
            matrixReviewCapability.falseNegative.disabledReason,
            matrixReviewCapability.clearReview.disabledReason,
        ].compactMap { $0 }
        return reasons.first
    }

    public func markMatrixFalsePositive() {
        guard matrixReviewCapability.falsePositive.isEnabled else { return }
        onMatrixReviewRequested?(.init(
            targets: selectedMatrixTargets,
            intent: .set(.falsePositive)
        ))
    }

    public func markMatrixFalseNegative() {
        guard matrixReviewCapability.falseNegative.isEnabled else { return }
        onMatrixReviewRequested?(.init(
            targets: selectedMatrixTargets,
            intent: .set(.falseNegative)
        ))
    }

    public func clearMatrixReview() {
        guard matrixReviewCapability.clearReview.isEnabled else { return }
        onMatrixReviewRequested?(.init(targets: selectedMatrixTargets, intent: .clear))
    }

    public var matrixCommentCards: [GenotypeMatrixCommentCardState] {
        let targetsByScope = matrixCommentTargetsByScope
        return GenotypeMatrixCommentScope.allCases.compactMap { scope in
            guard let targets = targetsByScope[scope], !targets.isEmpty else { return nil }
            let comments = targets.compactMap { matrixReviewCapability.commentsByTarget[$0] }
            let valueState = Self.commentValueState(
                targets.map { matrixReviewCapability.commentsByTarget[$0]?.body }
            )
            return GenotypeMatrixCommentCardState(
                scope: scope,
                targets: targets,
                valueState: valueState,
                currentComments: comments
            )
        }
    }

    public func matrixCommentDraft(scope: GenotypeMatrixCommentScope) -> String {
        matrixCommentDrafts[scope] ?? matrixCommentCards
            .first(where: { $0.scope == scope })?
            .displayBody ?? ""
    }

    public func setMatrixCommentDraft(_ body: String, scope: GenotypeMatrixCommentScope) {
        matrixCommentDrafts[scope] = body
    }

    public func matrixCommentRemovalAvailability(
        scope: GenotypeMatrixCommentScope
    ) -> GenotypeMatrixCommandAvailability {
        let targets = matrixCommentCards.first(where: { $0.scope == scope })?.targets ?? []
        return matrixReviewCapability.removeCommentsAvailability(for: targets)
    }

    public var matrixCommentMutationDisabledReason: String? {
        matrixReviewCapability.upsertComment.disabledReason
    }

    public var isMatrixCommentEditorEnabled: Bool {
        matrixReviewCapability.upsertComment.isEnabled
    }

    public func saveMatrixComment(scope: GenotypeMatrixCommentScope) {
        guard matrixReviewCapability.upsertComment.isEnabled,
              let card = matrixCommentCards.first(where: { $0.scope == scope }) else { return }
        let body = matrixCommentDraft(scope: scope)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else { return }
        let intent: GenotypeMatrixCommentEditRequest.Intent = card.requiresExplicitReplace
            ? .replace(body: body)
            : .upsert(body: body)
        onMatrixCommentRequested?(.init(targets: card.targets, intent: intent))
        matrixCommentDrafts[scope] = body
    }

    public func removeMatrixComment(scope: GenotypeMatrixCommentScope) {
        guard matrixCommentRemovalAvailability(scope: scope).isEnabled,
              let card = matrixCommentCards.first(where: { $0.scope == scope }) else { return }
        onMatrixCommentRequested?(.init(targets: card.targets, intent: .remove))
        matrixCommentDrafts[scope] = ""
    }

    func setGenotypeHighlightChannel(_ channel: GenotypeResultHighlightChannel) {
        genotypeHighlightChannel = channel
    }

    func setGenotypeHighlightColor(_ color: NSColor) {
        guard let annotationColor = Self.annotationColor(from: color) else { return }
        let swiftUIColor = Self.swiftUIColor(from: annotationColor)
        switch genotypeHighlightChannel {
        case .fill:
            genotypeHighlightColor = swiftUIColor
        case .border:
            genotypeBorderColor = swiftUIColor
        }
        guard !isUpdatingFromSelection else { return }
        applyGenotypeHighlight(channel: genotypeHighlightChannel, annotationColor: annotationColor)
    }

    func clearGenotypeHighlight(_ channel: GenotypeResultHighlightChannel) {
        applyGenotypeHighlight(channel: channel, annotationColor: nil)
    }

    func revertGenotypeHighlightToDefault() {
        clearGenotypeHighlight(.fill)
        clearGenotypeHighlight(.border)
    }

    var selectedMatrixTargets: [GenotypeAnnotationSidecar.MatrixTarget] {
        genotypeResultSelection?.matrixTargets ?? []
    }

    var hasMatrixSelection: Bool {
        !selectedMatrixTargets.isEmpty
    }

    var canUseSupportedCellThreshold: Bool {
        selectedMatrixTargets.contains { target in
            switch target {
            case .row, .column:
                return true
            case .cell:
                return false
            }
        }
    }

    func setMatrixFillColor(_ color: NSColor) {
        matrixFillColor = Self.swiftUIColor(from: Self.annotationColor(from: color) ?? AnnotationColor(red: 1, green: 0.8, blue: 0, alpha: 1))
        applyMatrixStyle(.fillColor(Self.annotationColor(from: color)))
    }

    func setMatrixTextColor(_ color: NSColor) {
        matrixTextColor = Self.swiftUIColor(from: Self.annotationColor(from: color) ?? AnnotationColor(red: 0, green: 0, blue: 0, alpha: 1))
        applyMatrixStyle(.textColor(Self.annotationColor(from: color)))
    }

    func setMatrixBorderColor(_ color: NSColor) {
        matrixBorderColor = Self.swiftUIColor(from: Self.annotationColor(from: color) ?? AnnotationColor(red: 1, green: 0.5, blue: 0, alpha: 1))
        applyMatrixStyle(.borderColor(Self.annotationColor(from: color)))
    }

    public var matrixQuickPaletteColors: [AnnotationColor] {
        matrixGenericQuickPaletteColors
    }

    public var matrixMCMQuickPaletteColors: [AnnotationColor] {
        HaplotypeColorToken.canonicalBudde2010Tokens.map(\.fillColor)
    }

    public var matrixGenericQuickPaletteColors: [AnnotationColor] {
        HaplotypeColorToken.genericOptimizedAnnotationPalette
    }

    public func applyMatrixPaletteColor(_ color: AnnotationColor) {
        switch matrixPaletteTarget {
        case .fill:
            setMatrixFillColor(Self.nsColor(from: color))
        case .text:
            setMatrixTextColor(Self.nsColor(from: color))
        case .border:
            setMatrixBorderColor(Self.nsColor(from: color))
        }
    }

    func setMatrixBold(_ enabled: Bool) {
        matrixIsBold = enabled
        applyMatrixStyle(.isBold(enabled))
    }

    func setMatrixItalic(_ enabled: Bool) {
        matrixIsItalic = enabled
        applyMatrixStyle(.isItalic(enabled))
    }

    func clearMatrixStyle() {
        applyMatrixStyle(.clear)
    }

    func addMatrixComment() {
        let body = matrixCommentText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty, hasMatrixSelection else { return }
        onMatrixCommentRequested?(GenotypeMatrixCommentEditRequest(
            targets: selectedMatrixTargets,
            intent: .upsert(body: body)
        ))
        matrixCommentText = ""
    }

    func setSupportedCellMinimumReads(_ minimumReads: Int) {
        supportedCellMinimumReads = max(0, minimumReads)
        onSupportSelectionPreviewChanged?(supportedCellMinimumReads)
    }

    var activeGenotypeHighlightNSColor: NSColor {
        switch genotypeHighlightChannel {
        case .fill:
            return Self.nsColor(from: genotypeHighlightColor)
        case .border:
            return Self.nsColor(from: genotypeBorderColor)
        }
    }

    private func applyGenotypeHighlight(
        channel: GenotypeResultHighlightChannel,
        annotationColor: AnnotationColor?
    ) {
        guard let target = genotypeResultSelection?.highlightTarget else { return }
        onGenotypeHighlightRequested?(
            GenotypeResultHighlightRequest(
                target: target,
                scope: genotypeHighlightScope,
                channel: channel,
                color: annotationColor
            )
        )
    }

    private func applyMatrixStyle(_ field: GenotypeMatrixStyleField) {
        guard hasMatrixSelection else { return }
        onMatrixStyleRequested?(
            GenotypeMatrixStyleRequest(
                targets: selectedMatrixTargets,
                field: field,
                minimumReads: canUseSupportedCellThreshold ? max(0, supportedCellMinimumReads) : nil
            )
        )
    }

    private var matrixCommentTargetsByScope:
        [GenotypeMatrixCommentScope: [GenotypeAnnotationSidecar.MatrixTarget]] {
        var result: [GenotypeMatrixCommentScope: [GenotypeAnnotationSidecar.MatrixTarget]] = [:]
        for target in selectedMatrixTargets {
            switch target {
            case let .cell(locus, genotype, sample, stableClusterID):
                result[.cell, default: []].append(target)
                result[.alleleRow, default: []].append(.row(
                    locus: locus,
                    genotype: genotype,
                    stableClusterID: stableClusterID
                ))
                result[.sampleColumn, default: []].append(.column(sample: sample))
            case .row:
                result[.alleleRow, default: []].append(target)
            case .column:
                result[.sampleColumn, default: []].append(target)
            }
        }
        return result.mapValues(Self.uniqueMatrixTargets)
    }

    private static func uniqueMatrixTargets(
        _ targets: [GenotypeAnnotationSidecar.MatrixTarget]
    ) -> [GenotypeAnnotationSidecar.MatrixTarget] {
        var seen: Set<GenotypeAnnotationSidecar.MatrixTarget> = []
        return targets.filter { seen.insert($0).inserted }
    }

    private static func commentValueState(
        _ values: [String?]
    ) -> GenotypeMatrixValueState<String> {
        guard let first = values.first else { return .none }
        guard values.dropFirst().allSatisfy({ $0 == first }) else { return .mixed }
        return first.map(GenotypeMatrixValueState.uniform) ?? .none
    }

    private static func defaultCommentDraft(
        for state: GenotypeMatrixValueState<String>
    ) -> String {
        guard case let .uniform(body) = state else { return "" }
        return body
    }

    private enum NumericFilterField: Hashable {
        case minimumReads
        case minimumPercent
        case minimumPrevalencePercent
    }

    private func scheduleNumericFilterCommit() {
        numericFilterCommitCoalescer.schedule(after: 0.2) { [weak self] in
            self?.commitNumericFilterDrafts(explicitField: nil)
        }
    }

    private func commitNumericFilterDrafts(
        explicitField: NumericFilterField?
    ) {
        numericFilterCommitCoalescer.cancel()
        let fields: Set<NumericFilterField>
        if let explicitField {
            fields = [explicitField]
        } else {
            fields = dirtyNumericFilterFields
        }
        var changed = false
        for field in fields {
            let draft = numericFilterDraft(for: field)
            let isEmpty = draft.draftText
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .isEmpty
            if isEmpty {
                if explicitField != nil {
                    draft.restore()
                }
                dirtyNumericFilterFields.remove(field)
                continue
            }
            guard let value = draft.commitIfValid() else {
                dirtyNumericFilterFields.remove(field)
                continue
            }
            switch field {
            case .minimumReads:
                let integerValue = Int(value)
                if displayState.matrixMinimumReads != integerValue {
                    displayState.matrixMinimumReads = integerValue
                    changed = true
                }
            case .minimumPercent:
                if displayState.matrixMinimumPercent != value {
                    displayState.matrixMinimumPercent = value
                    changed = true
                }
            case .minimumPrevalencePercent:
                if displayState.matrixMinimumPrevalencePercent != value {
                    displayState.matrixMinimumPrevalencePercent = value
                    changed = true
                }
            }
            dirtyNumericFilterFields.remove(field)
        }
        if changed {
            hasPendingNumericFilterPublication = true
        }
        if explicitField != nil || dirtyNumericFilterFields.isEmpty {
            publishPendingNumericFilterStateIfNeeded()
            isNumericFilterStepperBurstActive = false
        }
        if !dirtyNumericFilterFields.isEmpty {
            scheduleNumericFilterCommit()
        }
    }

    private func commitNumericFilterStepperValue(
        _ value: Double,
        for field: NumericFilterField
    ) {
        numericFilterCommitCoalescer.cancel()
        let draft = numericFilterDraft(for: field)
        draft.applyCommittedValue(value)
        dirtyNumericFilterFields.remove(field)
        var changed = false
        switch field {
        case .minimumReads:
            let integerValue = Int(draft.committedValue)
            if displayState.matrixMinimumReads != integerValue {
                displayState.matrixMinimumReads = integerValue
                changed = true
            }
        case .minimumPercent:
            if displayState.matrixMinimumPercent != draft.committedValue {
                displayState.matrixMinimumPercent = draft.committedValue
                changed = true
            }
        case .minimumPrevalencePercent:
            if displayState.matrixMinimumPrevalencePercent != draft.committedValue {
                displayState.matrixMinimumPrevalencePercent = draft.committedValue
                changed = true
            }
        }
        if changed {
            if isNumericFilterStepperBurstActive {
                hasPendingNumericFilterPublication = true
            } else {
                isNumericFilterStepperBurstActive = true
                notifyStateChanged()
            }
        }
        if isNumericFilterStepperBurstActive
            || hasPendingNumericFilterPublication
            || !dirtyNumericFilterFields.isEmpty {
            scheduleNumericFilterCommit()
        }
    }

    private func restoreNumericFilterDraft(_ field: NumericFilterField) {
        numericFilterCommitCoalescer.cancel()
        numericFilterDraft(for: field).restore()
        dirtyNumericFilterFields.remove(field)
        if isNumericFilterStepperBurstActive
            || hasPendingNumericFilterPublication
            || !dirtyNumericFilterFields.isEmpty {
            scheduleNumericFilterCommit()
        }
    }

    private func publishPendingNumericFilterStateIfNeeded() {
        guard hasPendingNumericFilterPublication else { return }
        hasPendingNumericFilterPublication = false
        notifyStateChanged()
    }

    private func numericFilterDraft(
        for field: NumericFilterField
    ) -> GenotypeNumericFilterDraft {
        switch field {
        case .minimumReads:
            matrixMinimumReadsDraft
        case .minimumPercent:
            matrixMinimumPercentDraft
        case .minimumPrevalencePercent:
            matrixMinimumPrevalencePercentDraft
        }
    }

    private func cancelPendingNumericFilterCommit() {
        numericFilterCommitCoalescer.cancel()
        dirtyNumericFilterFields.removeAll()
        hasPendingNumericFilterPublication = false
        isNumericFilterStepperBurstActive = false
    }

    private func cancelPendingNumericFilterCommitAndRestoreDrafts() {
        cancelPendingNumericFilterCommit()
        synchronizeNumericFilterDrafts()
    }

    private func synchronizeNumericFilterDrafts() {
        matrixMinimumReadsDraft.applyCommittedValue(
            Double(displayState.matrixMinimumReads)
        )
        matrixMinimumPercentDraft.applyCommittedValue(
            displayState.matrixMinimumPercent
        )
        matrixMinimumPrevalencePercentDraft.applyCommittedValue(
            displayState.matrixMinimumPrevalencePercent
        )
    }

    func notifyStateChanged() {
        onDisplayStateChanged?(displayState)
    }

    private static var emptyMatrixReviewCapability: GenotypeMatrixReviewCapabilityState {
        GenotypeMatrixReviewCapability.evaluate(
            selection: [],
            evidence: .init(),
            reviews: [],
            comments: [],
            isWritable: false
        )
    }

    private static func integrityWarningText(_ warning: ONTGenotypeIntegrityWarning) -> String {
        let location = warning.path.map { " (\($0))" } ?? ""
        return "\(warning.code.rawValue): \(warning.detail)\(location)"
    }

    private static func swiftUIColor(from annotationColor: AnnotationColor) -> Color {
        Color(
            red: annotationColor.red,
            green: annotationColor.green,
            blue: annotationColor.blue,
            opacity: annotationColor.alpha
        )
    }

    static func nsColor(from color: Color) -> NSColor {
        if let cgColor = color.cgColor {
            return NSColor(cgColor: cgColor) ?? .systemBlue
        }
        return NSColor(color)
    }

    static func nsColor(from annotationColor: AnnotationColor) -> NSColor {
        NSColor(
            srgbRed: annotationColor.red,
            green: annotationColor.green,
            blue: annotationColor.blue,
            alpha: annotationColor.alpha
        )
    }

    private static func annotationColor(from color: NSColor) -> AnnotationColor? {
        guard let rgbColor = color.usingColorSpace(.sRGB) ?? color.usingColorSpace(.deviceRGB) else {
            return nil
        }
        return AnnotationColor(
            red: rgbColor.redComponent,
            green: rgbColor.greenComponent,
            blue: rgbColor.blueComponent,
            alpha: rgbColor.alphaComponent
        )
    }
}
