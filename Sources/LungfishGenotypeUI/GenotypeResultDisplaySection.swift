import AppKit
import SwiftUI
import LungfishCore
import LungfishIO
import LungfishKit

@inline(__always)
func isSupportedMHCCandidateDocumentSchemaVersion(_ schemaVersion: Int) -> Bool {
    (1 ... 5).contains(schemaVersion)
}

public enum GenotypeMatrixPaletteTarget: String, CaseIterable, Identifiable {
    case fill
    case text
    case border

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .fill: return "Fill"
        case .text: return "Text"
        case .border: return "Border"
        }
    }
}

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
    /// Set by the composition root to route the Filtered Pivot export to the
    /// displayed genotype viewport. The Inspector is where analysts set the
    /// Min Reads and Min Percent filters, so the export that applies them
    /// lives beside those controls rather than in a viewport lens.
    public var onFilteredPivotExportRequested: (() -> Void)?

    /// Whether the export button is shown: a viewport must be bound.
    public var canExportFilteredPivot: Bool { onFilteredPivotExportRequested != nil }

    public func requestFilteredPivotExport() {
        onFilteredPivotExportRequested?()
    }

    @ObservationIgnored
    private var isUpdatingFromSelection = false
    @ObservationIgnored
    private let contentTextSizeAnnouncementPoster: any AccessibilityAnnouncementPosting
    let matrixMinimumReadsDraft: GenotypeNumericFilterDraft
    let matrixMinimumPercentDraft: GenotypeNumericFilterDraft
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
            }
        }
        dirtyNumericFilterFields.removeAll()
        hasPendingNumericFilterPublication = false
        isNumericFilterStepperBurstActive = false
        if changed { notifyStateChanged() }
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

@MainActor
private struct GenotypeNumericFilterStepper: NSViewRepresentable {
    let value: Double
    let configuration: GenotypeNumericFilterConfiguration
    let accessibility: GenotypeNumericFilterAccessibilityState
    let onChange: (Double) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onChange: onChange)
    }

    func makeNSView(context: Context) -> NSStepper {
        let stepper = NSStepper()
        stepper.controlSize = .small
        stepper.valueWraps = false
        stepper.autorepeat = true
        stepper.target = context.coordinator
        stepper.action = #selector(Coordinator.valueChanged(_:))
        return stepper
    }

    func updateNSView(_ stepper: NSStepper, context: Context) {
        context.coordinator.onChange = onChange
        stepper.minValue = configuration.bounds.lowerBound
        stepper.maxValue = configuration.bounds.upperBound
        stepper.increment = configuration.step
        stepper.doubleValue = value
        stepper.setAccessibilityIdentifier(
            configuration.stepperAccessibilityIdentifier
        )
        stepper.setAccessibilityLabel(accessibility.label)
        stepper.setAccessibilityValue(NSNumber(value: value))
        stepper.setAccessibilityValueDescription(accessibility.value)
        stepper.setAccessibilityHelp(
            "\(accessibility.bounds) "
                + "\(accessibility.incrementAction) "
                + accessibility.decrementAction
        )
    }

    final class Coordinator: NSObject {
        var onChange: (Double) -> Void

        init(onChange: @escaping (Double) -> Void) {
            self.onChange = onChange
        }

        @MainActor @objc func valueChanged(_ sender: NSStepper) {
            onChange(sender.doubleValue)
        }
    }
}

public struct GenotypeResultDisplaySection: View {
    private var typography: ContentTypographyModel { .shared }
    @AppStorage(GenotypeOutlineView.densityPreferenceKey) private var compactHaplotypeRows = false
    @State private var showsReviewHelp = false
    @State private var showsAdvancedDisplay = false
    @Bindable var viewModel: GenotypeResultDisplaySectionViewModel
    @FocusState private var focusedNumericFilter: NumericFilterFocus?

    private enum NumericFilterFocus: Hashable {
        case minimumReads
        case minimumPercent
    }

    public init(viewModel: GenotypeResultDisplaySectionViewModel) {
        self.viewModel = viewModel
    }

    public var body: some View {
        if viewModel.isAvailable {
            DisclosureGroup(isExpanded: $viewModel.isExpanded) {
                VStack(alignment: .leading, spacing: 10) {
                    reviewHelp
                    summary
                    contentTextSizeControls
                    if viewModel.hasHaplotypingResult {
                        Picker("Haplotype spacing", selection: $compactHaplotypeRows) {
                            Text("Comfortable").tag(false)
                            Text("Compact").tag(true)
                        }
                        .pickerStyle(.menu)
                        .help("Comfortable spacing gives each assignment a larger target. Both modes follow Content Text Size.")
                        .onChange(of: compactHaplotypeRows) { _, _ in
                            NotificationCenter.default.post(name: GenotypeOutlineView.densityChanged, object: nil)
                        }
                    }
                    if viewModel.mhcCandidateControlsAvailable
                        || !viewModel.mhcCandidateIntegrityWarnings.isEmpty
                        || viewModel.mhcCandidatePersistenceWarning != nil {
                        GenotypeCandidateEvidenceSection(viewModel: viewModel)
                    }
                    if viewModel.hasHaplotypingResult
                        && viewModel.presentationChoices.isEmpty {
                        haplotypeGenotypeToggle
                    }
                    Divider()
                    if viewModel.showsViewportAndLayoutControls {
                        viewControls
                    }
                    if viewModel.hasHaplotypingResult {
                        diagnosticAlleleControls
                    }
                    thresholdGuidance
                    matrixFilterControls
                    DisclosureGroup("Layout and locus order", isExpanded: $showsAdvancedDisplay) {
                        if viewModel.showsViewportAndLayoutControls { layoutControls }
                        if viewModel.locusDisplayOrderAvailable { locusDisplayOrderControls }
                    }
                    matrixVisibilityControls
                    colorControls
                    highlightControls
                    Text("Visual filters do not change genotype calls.")
                        .font(typography.font(for: .body))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.top, 4)
                .font(typography.font(for: .body))
            } label: {
                Label("Genotype Display", systemImage: "tablecells")
                    .font(typography.font(for: .emphasizedBody))
            }
            .onChange(of: focusedNumericFilter) { oldValue, newValue in
                guard oldValue != newValue else { return }
                switch oldValue {
                case .minimumReads:
                    viewModel.commitMatrixMinimumReadsDraft()
                case .minimumPercent:
                    viewModel.commitMatrixMinimumPercentDraft()
                case nil:
                    break
                }
            }
        }
    }

    private var reviewHelp: some View {
        Button("How to review this result", systemImage: "questionmark.circle") {
            showsReviewHelp = true
        }
        .help("Learn how allele observations support haplotype assignments.")
        .accessibilityIdentifier("genotype-review-help")
        .popover(isPresented: $showsReviewHelp) {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Text("Review a genotype result").font(typography.font(for: .emphasizedBody))
                    if viewModel.hasHaplotypingResult {
                        Text("Haplotype Calls shows assignments inferred from allele evidence. Select a call to inspect its support.")
                    }
                    Text("Genotype Matrix compares allele read support across samples. Slash-separated names can represent alleles the assay cannot distinguish.")
                    if viewModel.hasHaplotypingResult { Text("Diagnostic alleles only shows evidence used by the active definitions. Turn it off to inspect all observed alleles. Display filters do not change calls.") }
                    Text("Use Columns to choose the identifiers and read totals you need. Total reads includes all samples in the result, even hidden columns.")
                    if viewModel.hasHaplotypingResult { Text("To correct an assignment, inspect its evidence and choose Change. Custom names require a rationale, acknowledgement and explicit application; the original call remains in the audit history.") }
                    Text("Export to Excel offers a filtered copy for sharing and current.xlsx for supported review and import workflows.")
                    Button("Done") { showsReviewHelp = false }.keyboardShortcut(.cancelAction)
                }
                .font(typography.font(for: .body))
                .textSelection(.enabled)
                .padding(20)
            }
            .frame(width: 420, height: 480)
        }
    }

    private var locusDisplayOrderControls: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Locus display order")
                .font(typography.font(for: .body))
                .foregroundStyle(.secondary)
            Text(viewModel.locusDisplayOrderStatus)
                .font(typography.font(for: .body))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            TextField("F, G, AG, A1, A2/A3/A4/A5, K, L, E, B, DRB, DQA, DQB, DPA, DPB",
                      text: $viewModel.locusDisplayOrderDraft, axis: .vertical)
                .lineLimit(3...6)
                .textFieldStyle(.roundedBorder)
                .accessibilityLabel("Locus display order")
                .accessibilityHint("Separate ordered loci with commas. A slash groups loci together.")
                .accessibilityIdentifier("genotype-locus-display-order")
                .disabled(!viewModel.locusDisplayOrderCanEdit)
            HStack {
                Button("Apply") { viewModel.applyLocusDisplayOrderDraft() }
                    .accessibilityIdentifier("genotype-locus-display-order-apply")
                Button("Use Bundle Default") { viewModel.resetLocusDisplayOrder() }
                    .accessibilityIdentifier("genotype-locus-display-order-reset")
            }
            .controlSize(.regular)
            .disabled(!viewModel.locusDisplayOrderCanEdit)
            Text("Changes row order only.")
                .help("Commas separate groups; / joins loci. Unlisted loci appear afterward. Included Loci and haplotype calls stay unchanged.")
                .font(typography.font(for: .body))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let error = viewModel.locusDisplayOrderValidationError ?? viewModel.locusDisplayOrderPersistenceWarning {
                Text(error).font(typography.font(for: .body)).foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("genotype-locus-display-order-error")
            }
        }
    }

    private var contentTextSizeControls: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Content Text Size")
                .font(typography.font(for: .body))
                .foregroundStyle(.secondary)
            HStack(spacing: 8) {
                Button("A−") {
                    viewModel.decreaseContentTextSize()
                }
                .disabled(!viewModel.canDecreaseContentTextSize)
                .accessibilityLabel("Decrease content text size")
                .accessibilityIdentifier("genotype-view-content-text-size-decrease")

                Text(viewModel.contentTextSizeLabel)
                    .frame(minWidth: 48)
                    .accessibilityLabel("Content text size")
                    .accessibilityValue(viewModel.contentTextSizeLabel)
                    .accessibilityIdentifier("genotype-view-content-text-size-value")

                Button("A+") {
                    viewModel.increaseContentTextSize()
                }
                .disabled(!viewModel.canIncreaseContentTextSize)
                .accessibilityLabel("Increase content text size")
                .accessibilityIdentifier("genotype-view-content-text-size-increase")

                Button("Default") {
                    viewModel.restoreSystemContentTextSize()
                }
                .disabled(viewModel.contentTextSizePreference == .system)
                .accessibilityLabel("Use system content text size")
                .accessibilityIdentifier("genotype-view-content-text-size-default")
            }
            .buttonStyle(.borderless)
            .controlSize(.regular)
        }
    }

    private var haplotypeGenotypeToggle: some View {
        Button {
            viewModel.toggleHaplotypeGenotypeSummaryView()
        } label: {
            Label(
                viewModel.displayState.summaryViewMode == .matrix
                    ? "Show haplotyping view"
                    : "Show genotype matrix",
                systemImage: viewModel.displayState.summaryViewMode == .matrix
                    ? "list.bullet.rectangle"
                    : "tablecells"
            )
        }
        .buttonStyle(.borderless)
        .controlSize(.regular)
    }

    private var summary: some View {
        VStack(alignment: .leading, spacing: 4) {
            LabeledContent("Rows", value: "\(viewModel.visibleRowCount) of \(viewModel.totalRowCount)")
            LabeledContent("Hidden Cells", value: "\(viewModel.hiddenCellCount)")
        }
        .font(typography.font(for: .body))
    }

    private var viewControls: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(
                viewModel.presentationChoices.isEmpty
                    ? "Viewport"
                    : "View Presentation"
            )
                .font(typography.font(for: .body))
                .foregroundStyle(.secondary)
            if viewModel.presentationChoices.isEmpty {
                Picker("Viewport", selection: Binding(
                    get: { viewModel.displayState.viewportLens },
                    set: { viewModel.setViewportLens($0) }
                )) {
                    ForEach(viewModel.legacyViewportLenses, id: \.self) { lens in
                        Label(lens.displayName, systemImage: lens.inspectorSystemImage)
                        .tag(lens)
                    }
                }
                .pickerStyle(.radioGroup)
                .controlSize(.regular)
                .labelsHidden()
            } else {
                Picker("View Presentation", selection: Binding(
                    get: { viewModel.displayState.summaryViewMode },
                    set: { viewModel.setSummaryViewMode($0) }
                )) {
                    ForEach(viewModel.presentationChoices, id: \.self) {
                        choice in
                        Text(choice.displayName)
                            .tag(choice.summaryViewMode)
                    }
                }
                .pickerStyle(.radioGroup)
                .controlSize(.regular)
                .labelsHidden()
                .accessibilityHint(
                    viewModel.presentationAccessibilityHelp
                )
            }
        }
    }

    private var layoutControls: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Panel Layout")
                .font(typography.font(for: .body))
                .foregroundStyle(.secondary)
            Picker("Layout", selection: Binding(
                get: { viewModel.displayState.layout },
                set: { viewModel.setLayout($0) }
            )) {
                Label("Detail | List", systemImage: "sidebar.left")
                    .tag(GenotypeResultPanelLayout.listTrailing)
                Label("List | Detail", systemImage: "sidebar.right")
                    .tag(GenotypeResultPanelLayout.listLeading)
                Label("List Over Detail", systemImage: "rectangle.split.1x2")
                    .tag(GenotypeResultPanelLayout.listTop)
            }
            .pickerStyle(.radioGroup)
            .controlSize(.regular)
            .labelsHidden()
        }
    }

    private var thresholdGuidance: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Run and Calling Thresholds")
                .font(typography.font(for: .body))
                .foregroundStyle(.secondary)
            Text(
                "Display filters do not change calls. Re-run the analysis to change calling thresholds."
            )
                .font(typography.font(for: .body))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var matrixFilterControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Search and Support Filters")
                .font(typography.font(for: .body))
                .foregroundStyle(.secondary)
            TextField("Alleles", text: Binding(
                get: { viewModel.displayState.matrixRowFilterText },
                set: { viewModel.setMatrixRowFilterText($0) }
            ))
            .textFieldStyle(.roundedBorder)
            .controlSize(.regular)
            TextField("Samples", text: Binding(
                get: { viewModel.displayState.matrixSampleFilterText },
                set: { viewModel.setMatrixSampleFilterText($0) }
            ))
            .textFieldStyle(.roundedBorder)
            .controlSize(.regular)
            HStack(spacing: 6) {
                Text(
                    viewModel.matrixMinimumReadsDraft.configuration.label
                )
                Spacer(minLength: 6)
                TextField(
                    viewModel.matrixMinimumReadsDraft.configuration.label,
                    text: Binding(
                        get: {
                            viewModel.matrixMinimumReadsDraft.draftText
                        },
                        set: {
                            viewModel.updateMatrixMinimumReadsDraft($0)
                        }
                    )
                )
                .multilineTextAlignment(.trailing)
                .textFieldStyle(.roundedBorder)
                .controlSize(.regular)
                .frame(minWidth: 88, idealWidth: 112)
                .focused($focusedNumericFilter, equals: .minimumReads)
                .onSubmit {
                    viewModel.commitMatrixMinimumReadsDraft()
                }
                .onExitCommand {
                    viewModel.restoreMatrixMinimumReadsDraft()
                }
                .accessibilityIdentifier(
                    viewModel.matrixMinimumReadsDraft.configuration
                        .fieldAccessibilityIdentifier
                )
                .accessibilityLabel(
                    viewModel.matrixMinimumReadsDraft.accessibility.label
                )
                .accessibilityValue(
                    viewModel.matrixMinimumReadsDraft.accessibility.value
                )
                .accessibilityHint(
                    viewModel.matrixMinimumReadsDraft.accessibility
                        .validationDescription
                        ?? viewModel.matrixMinimumReadsDraft.accessibility.bounds
                )
                GenotypeNumericFilterStepper(
                    value: viewModel.matrixMinimumReadsDraft.stepperValue,
                    configuration:
                        viewModel.matrixMinimumReadsDraft.configuration,
                    accessibility:
                        viewModel.matrixMinimumReadsDraft.accessibility,
                    onChange: {
                        viewModel.setMatrixMinimumReadsFromStepper(Int($0))
                    }
                )
                .labelsHidden()
                .controlSize(.regular)
            }
            HStack(spacing: 6) {
                Text(
                    viewModel.matrixMinimumPercentDraft.configuration.label
                )
                Spacer(minLength: 6)
                TextField(
                    viewModel.matrixMinimumPercentDraft.configuration.label,
                    text: Binding(
                        get: {
                            viewModel.matrixMinimumPercentDraft.draftText
                        },
                        set: {
                            viewModel.updateMatrixMinimumPercentDraft($0)
                        }
                    )
                )
                .multilineTextAlignment(.trailing)
                .textFieldStyle(.roundedBorder)
                .controlSize(.regular)
                .frame(minWidth: 88, idealWidth: 112)
                .focused($focusedNumericFilter, equals: .minimumPercent)
                .onSubmit {
                    viewModel.commitMatrixMinimumPercentDraft()
                }
                .onExitCommand {
                    viewModel.restoreMatrixMinimumPercentDraft()
                }
                .accessibilityIdentifier(
                    viewModel.matrixMinimumPercentDraft.configuration
                        .fieldAccessibilityIdentifier
                )
                .accessibilityLabel(
                    viewModel.matrixMinimumPercentDraft.accessibility.label
                )
                .accessibilityValue(
                    viewModel.matrixMinimumPercentDraft.accessibility.value
                )
                .accessibilityHint(
                    viewModel.matrixMinimumPercentDraft.accessibility
                        .validationDescription
                        ?? viewModel.matrixMinimumPercentDraft.accessibility
                            .bounds
                )
                Text("%")
                    .foregroundStyle(.secondary)
                GenotypeNumericFilterStepper(
                    value: viewModel.matrixMinimumPercentDraft.stepperValue,
                    configuration:
                        viewModel.matrixMinimumPercentDraft.configuration,
                    accessibility:
                        viewModel.matrixMinimumPercentDraft.accessibility,
                    onChange: {
                        viewModel.setMatrixMinimumPercentFromStepper($0)
                    }
                )
                .labelsHidden()
                .controlSize(.regular)
            }
            Text("0 = Off.")
                .font(typography.font(for: .body))
                .foregroundStyle(.secondary)
            Picker("Percent Basis", selection: Binding(
                get: { viewModel.displayState.matrixPercentDenominator },
                set: { viewModel.setMatrixPercentDenominator($0) }
            )) {
                ForEach(ONTGenotypeSupportDenominator.allCases, id: \.self) { denominator in
                    Text(denominator.displayName).tag(denominator)
                }
            }
            .pickerStyle(.segmented)
            .controlSize(.regular)
        }
    }

    private var matrixVisibilityControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Selected Rows and Columns")
                .font(typography.font(for: .body))
                .foregroundStyle(.secondary)
            Text(viewModel.matrixVisibilityScopeSummary)
                .font(typography.font(for: .body))
                .accessibilityIdentifier("genotype-view-visibility-scope")
            Text(viewModel.matrixVisibilityStatus)
                .font(typography.font(for: .body))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("genotype-view-visibility-status")
            Text(
                "Select allele row markers or sample column headers to change visibility. "
                    + "Visibility actions use the selection. Search and support filters always "
                    + "apply to the currently visible matrix."
            )
            .font(typography.font(for: .body))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityIdentifier("genotype-view-visibility-guidance")
            HStack(spacing: 8) {
                Menu("Rows…") {
                    Button("Hide Selected Rows") {
                        viewModel.hideSelectedMatrixRows()
                    }
                    .disabled(!viewModel.matrixVisibilityCapability.canHideSelectedRows)
                    .accessibilityIdentifier("genotype-view-hide-selected-rows")
                    Button("Show Only Selected Rows") {
                        viewModel.showOnlySelectedMatrixRows()
                    }
                    .disabled(!viewModel.matrixVisibilityCapability.canShowOnlySelectedRows)
                    .accessibilityIdentifier("genotype-view-show-only-selected-rows")
                    Divider()
                    Button("Show All Rows") {
                        viewModel.showAllMatrixRows()
                    }
                    .disabled(!viewModel.matrixVisibilityCapability.canShowAllRows)
                    .accessibilityIdentifier("genotype-view-show-all-rows")
                }
                .accessibilityIdentifier("genotype-view-row-visibility-menu")

                Menu("Columns…") {
                    Button("Hide Selected Columns") {
                        viewModel.hideSelectedMatrixColumns()
                    }
                    .disabled(!viewModel.matrixVisibilityCapability.canHideSelectedColumns)
                    .accessibilityIdentifier("genotype-view-hide-selected-columns")
                    Button("Show Only Selected Columns") {
                        viewModel.showOnlySelectedMatrixColumns()
                    }
                    .disabled(!viewModel.matrixVisibilityCapability.canShowOnlySelectedColumns)
                    .accessibilityIdentifier("genotype-view-show-only-selected-columns")
                    Divider()
                    Button("Show All Columns") {
                        viewModel.showAllMatrixColumns()
                    }
                    .disabled(!viewModel.matrixVisibilityCapability.canShowAllColumns)
                    .accessibilityIdentifier("genotype-view-show-all-columns")
                }
                .accessibilityIdentifier("genotype-view-column-visibility-menu")
            }
            .controlSize(.regular)

            Button {
                viewModel.resetMatrixVisibility()
            } label: {
                Label("Reset Visibility", systemImage: "arrow.counterclockwise")
            }
            .buttonStyle(.borderless)
            .controlSize(.regular)
            .disabled(!viewModel.canResetMatrixVisibility)
            .accessibilityIdentifier("genotype-view-reset-visibility")
        }
        .accessibilityIdentifier("genotype-view-visibility-group")
    }

    private var diagnosticAlleleControls: some View {
        VStack(alignment: .leading, spacing: 4) {
            Toggle("Diagnostic alleles only", isOn: Binding(
                get: { viewModel.displayState.diagnosticAllelesOnly },
                set: { viewModel.setDiagnosticAllelesOnly($0) }
            ))
            .accessibilityIdentifier("genotype-display-diagnostic-alleles-only")
            Text(viewModel.displayState.diagnosticAllelesOnly ? "Showing diagnostic evidence" : "Showing all observed alleles")
                .help("Diagnostic alleles come from all active haplotype definitions, including unresolved calls. This filters Haplotype Calls evidence and Genotype Matrix without changing assignments.")
                .font(typography.font(for: .body))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var colorControls: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Cell Color")
                .font(typography.font(for: .body))
                .foregroundStyle(.secondary)
            Picker("Cell Color", selection: Binding(
                get: { viewModel.displayState.cellColorMode },
                set: { viewModel.setCellColorMode($0) }
            )) {
                ForEach(GenotypeResultCellColorMode.allCases.filter { $0 != .haplotype || viewModel.hasHaplotypingResult }, id: \.self) { mode in
                    Text(mode.displayName).tag(mode)
                }
            }
            .pickerStyle(.menu)
            .controlSize(.regular)
            if viewModel.displayState.cellColorMode == .haplotype {
                Text("Shared support: gray · Unmatched: neutral")
                    .help("Colors identify support for displayed haplotype calls using the active definitions. Inspect a cell for its supporting haplotypes.")
                    .font(typography.font(for: .body))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("genotype-display-haplotype-color-legend")
            }
        }
    }

    @ViewBuilder
    private var highlightControls: some View {
        if let target = viewModel.genotypeResultSelection?.highlightTarget {
            VStack(alignment: .leading, spacing: 8) {
                Text("Selected Highlight")
                    .font(typography.font(for: .body))
                    .foregroundStyle(.secondary)

                valueRow(label: "Target", value: target.sample.map { "\(target.locus) / \($0)" } ?? target.locus)
                    .font(typography.font(for: .body))

                Picker("Target Scope", selection: $viewModel.genotypeHighlightScope) {
                    if target.sample != nil {
                        Text("Cell").tag(GenotypeResultHighlightScope.selectedCell)
                    }
                    Text("Row").tag(GenotypeResultHighlightScope.selectedRow)
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .controlSize(.regular)

                Picker("Color Target", selection: Binding(
                    get: { viewModel.genotypeHighlightChannel },
                    set: { viewModel.setGenotypeHighlightChannel($0) }
                )) {
                    ForEach(GenotypeResultHighlightChannel.allCases, id: \.self) { channel in
                        Text(channel.displayName).tag(channel)
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .controlSize(.regular)

                HStack(spacing: 10) {
                    ContinuousColorWell(
                        color: viewModel.activeGenotypeHighlightNSColor,
                        onChange: { viewModel.setGenotypeHighlightColor($0) }
                    )
                    .frame(width: 44, height: 24)
                    Text(viewModel.genotypeHighlightChannel == .fill ? "Cell Fill" : "Outer Border")
                        .font(typography.font(for: .body))
                        .foregroundStyle(.secondary)
                }

                HStack(spacing: 12) {
                    Button {
                        viewModel.clearGenotypeHighlight(.fill)
                    } label: {
                        Label("Clear Fill", systemImage: "xmark.circle")
                    }
                    .buttonStyle(.borderless)
                    .controlSize(.regular)

                    Button {
                        viewModel.clearGenotypeHighlight(.border)
                    } label: {
                        Label("Clear Border", systemImage: "square.dashed")
                    }
                    .buttonStyle(.borderless)
                    .controlSize(.regular)
                }

                Button {
                    viewModel.revertGenotypeHighlightToDefault()
                } label: {
                    Label("Revert to Default", systemImage: "arrow.uturn.backward.circle")
                }
                .buttonStyle(.borderless)
                .controlSize(.regular)
            }
        }
    }

    private func valueRow(label: String, value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(label)
                .foregroundStyle(.secondary)
                .frame(width: 72, alignment: .trailing)
            Text(value)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
        }
    }
}

private struct ContinuousColorWell: NSViewRepresentable {
    var color: NSColor
    var onChange: (NSColor) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onChange: onChange)
    }

    func makeNSView(context: Context) -> NSColorWell {
        let colorWell = NSColorWell(frame: .zero)
        colorWell.isContinuous = true
        colorWell.color = color
        colorWell.target = context.coordinator
        colorWell.action = #selector(Coordinator.colorChanged(_:))
        return colorWell
    }

    func updateNSView(_ colorWell: NSColorWell, context: Context) {
        context.coordinator.onChange = onChange
        if colorWell.color != color {
            colorWell.color = color
        }
    }

    final class Coordinator: NSObject {
        var onChange: (NSColor) -> Void

        init(onChange: @escaping (NSColor) -> Void) {
            self.onChange = onChange
        }

        @MainActor @objc func colorChanged(_ sender: NSColorWell) {
            onChange(sender.color)
        }
    }
}
