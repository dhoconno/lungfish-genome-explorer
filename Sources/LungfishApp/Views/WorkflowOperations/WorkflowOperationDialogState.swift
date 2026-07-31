import Foundation
import LungfishCore
import LungfishIO
import LungfishWorkflow
import Observation

enum WorkflowOperationToolKind: Equatable, Sendable {
    case ontGenotyping
    case fullLengthONTMHCGenotyping
    case twelveSAmpliconMatching
    case workflowPackage(WorkflowPackageValidationResult)
}

struct WorkflowOperationTool: Identifiable, Equatable, Sendable {
    let id: String
    let title: String
    let subtitle: String
    let kind: WorkflowOperationToolKind
    let availability: DatasetOperationAvailability
}

enum WorkflowOperationLaunchRequest: Equatable {
    case ontGenotyping(ONTBarcodeDemuxGenotypingRunRequest)
    case fullLengthONTMHCGenotyping(FullLengthONTMHCGenotypingRunRequest)
    case twelveSAmpliconMatching(TwelveSAmpliconMatchingConfiguration)
    case workflowPackage(LocalWorkflowRunRequest, bundleRoot: URL)
}

enum WorkflowOperationProjectDiscoveryMode: Sendable {
    case synchronous
    case asynchronous
}

enum WorkflowOperationAmpliconAnalysisMode: String, CaseIterable, Sendable {
    case aiSpecialistPreset
    case deterministicHaplotyping
    case genotypeOnly

    var displayName: String {
        switch self {
        case .aiSpecialistPreset: return "AI preset"
        case .deterministicHaplotyping: return "Deterministic"
        case .genotypeOnly: return "Genotype only"
        }
    }

    var helpText: String {
        switch self {
        case .aiSpecialistPreset:
            return "Uses a preset reference and specialist analyst prompt."
        case .deterministicHaplotyping:
            return "Uses the selected reference and a haplotype definition."
        case .genotypeOnly:
            return "Maps reads and reports genotypes without haplotyping."
        }
    }
}

private struct WorkflowOperationProjectDiscoverySnapshot: Sendable {
    let referenceCandidates: [URL]
    let guideCandidates: [URL]
    let barcodeDefinitionCandidates: [URL]
    let haplotypeRecords: [HaplotypeDefinitionRecord]
    let referenceBundleSummaries: [URL: String]
    let bundledHaplotypeDefinitions: [URL: GenotypeHaplotypeDefinitionSet]
    let fullLengthOrientReferenceURL: URL?
    let fullLengthForwardPrimerURL: URL?
    let fullLengthReversePrimerURL: URL?

    static let empty = WorkflowOperationProjectDiscoverySnapshot(
        referenceCandidates: [],
        guideCandidates: [],
        barcodeDefinitionCandidates: [],
        haplotypeRecords: [],
        referenceBundleSummaries: [:],
        bundledHaplotypeDefinitions: [:],
        fullLengthOrientReferenceURL: nil,
        fullLengthForwardPrimerURL: nil,
        fullLengthReversePrimerURL: nil
    )
}

private final class WorkflowOperationNotificationObserver: @unchecked Sendable {
    private let token: NSObjectProtocol

    init(_ token: NSObjectProtocol) {
        self.token = token
    }

    deinit {
        NotificationCenter.default.removeObserver(token)
    }
}

@MainActor
@Observable
final class WorkflowOperationDialogState {
    private let enablementStore: WorkflowLibraryEnablementStore
    private let packageStore: WorkflowLibraryImportedPackageStore
    @ObservationIgnored private var enablementObserver: WorkflowOperationNotificationObserver?
    @ObservationIgnored private let projectDiscoveryMode: WorkflowOperationProjectDiscoveryMode
    @ObservationIgnored private var projectDiscoveryTask: Task<Void, Never>?
    @ObservationIgnored private var projectDiscoveryGeneration: UInt64 = 0
    @ObservationIgnored private var workflowPackageRefreshTask: Task<Void, Never>?
    @ObservationIgnored private var workflowPackageRefreshGeneration: UInt64 = 0
    #if DEBUG
    @ObservationIgnored static var testingProjectDiscoveryDelay: Duration?
    #endif

    var projectURL: URL?
    var selectedToolID: String
    var selectedReferenceURL: URL?
    var selectedGuideURL: URL?
    var selectedBarcodeDefinitionURL: URL?
    var sidebarInputSelection: WorkflowSidebarInputSelection?
    var includeSubfolderBundles: Bool
    var selectedReadURLs: [URL]
    var outputDirectoryURL: URL?
    var outputName: String
    var threads: Int
    var minSupport: Int
    var keepIntermediates: Bool
    var haplotypeDropoutSamplePercent: Double
    var haplotypeDropoutLocusPercent: Double
    var haplotypeDropoutLocusOverridePercents: [String: Double]
    var selectedGenotypingMode: AmpliconGenotypingMode
    var selectedGenotypingReadType: AmpliconGenotypingReadType
    var selectedAmpliconAnalysisMode: WorkflowOperationAmpliconAnalysisMode
    var selectedAmpliconPresetID: String?
    var aiSpecialistPresetsAvailable: Bool
    var twelveSMinimumSoftClipBases: Int
    var twelveSMaximumIndelBases: Int
    var twelveSMatchingMode: TwelveSAmpliconMatchingMode
    var twelveSRunChimeraReview: Bool
    var twelveSSampleMetadataURL: URL?
    var fullLengthOrientReferenceURL: URL?
    var fullLengthForwardPrimerURL: URL?
    var fullLengthReversePrimerURL: URL?
    var fullLengthMinimumLength: Int
    var fullLengthMaximumLength: Int
    var selectedHaplotypeAssayID: String?
    var selectedHaplotypeSpeciesCode: String?
    var selectedHaplotypeDefinitionScope: HaplotypeDefinitionScope?
    var selectedHaplotypeDefinitionSetID: String?
    var extraArgumentsText: String
    var advancedOptionsExpanded: Bool
    var projectReferenceCandidates: [URL]
    var projectGuideCandidates: [URL]
    var projectBarcodeDefinitionCandidates: [URL]
    var isDiscoveringProjectResources: Bool
    var errorMessage: String?
    var showingError: Bool
    var workflowAvailabilityRevision: Int
    private var cachedTools: [WorkflowOperationTool]
    private var cachedHaplotypeRecords: [HaplotypeDefinitionRecord]
    private var cachedHaplotypeRegistry: GenotypeHaplotypeDefinitionRegistry
    private var cachedReferenceBundleSummaries: [URL: String]
    private var cachedBundledHaplotypeDefinitions: [URL: GenotypeHaplotypeDefinitionSet]

    init(
        projectURL: URL?,
        selectedReadURLs: [URL] = [],
        sidebarInputSelection: WorkflowSidebarInputSelection? = nil,
        projectDiscoveryMode: WorkflowOperationProjectDiscoveryMode = .synchronous,
        aiSpecialistPresetsAvailable: Bool = false,
        initialToolID requestedInitialToolID: String? = nil,
        enablementStore: WorkflowLibraryEnablementStore = .shared,
        packageStore: WorkflowLibraryImportedPackageStore = .shared
    ) {
        let resolvedReadURLs = sidebarInputSelection?.selectedReadURLs(includeSubfolders: false) ?? selectedReadURLs
        let standardizedReadURLs = Self.deduplicated(resolvedReadURLs.map(\.standardizedFileURL))
        let standardizedProjectURL = projectURL?.standardizedFileURL
        self.projectURL = standardizedProjectURL
        self.enablementStore = enablementStore
        self.packageStore = packageStore
        self.projectDiscoveryMode = projectDiscoveryMode
        self.sidebarInputSelection = sidebarInputSelection
        self.includeSubfolderBundles = false
        self.selectedReadURLs = standardizedReadURLs
        self.outputName = Self.defaultONTGenotypingOutputName(for: standardizedReadURLs)
        self.threads = max(1, ProcessInfo.processInfo.activeProcessorCount)
        self.minSupport = 1
        self.keepIntermediates = false
        self.haplotypeDropoutSamplePercent = 0.0
        self.haplotypeDropoutLocusPercent = 1.0
        self.haplotypeDropoutLocusOverridePercents = [:]
        self.selectedGenotypingMode = .auto
        self.selectedGenotypingReadType = Self.defaultGenotypingReadType(for: standardizedReadURLs)
        self.aiSpecialistPresetsAvailable = aiSpecialistPresetsAvailable
        self.selectedAmpliconAnalysisMode = aiSpecialistPresetsAvailable ? .aiSpecialistPreset : .genotypeOnly
        self.selectedAmpliconPresetID = MCMHaplotypingPreset.mcmMHCmiseq.id
        self.twelveSMinimumSoftClipBases = 1
        self.twelveSMaximumIndelBases = 3
        self.twelveSMatchingMode = .illuminaExact
        self.twelveSRunChimeraReview = true
        self.twelveSSampleMetadataURL = nil
        let initialDiscovery = projectDiscoveryMode == .synchronous
            ? Self.projectDiscoverySnapshot(projectURL: standardizedProjectURL)
            : .empty
        self.fullLengthOrientReferenceURL = initialDiscovery.fullLengthOrientReferenceURL
        self.fullLengthForwardPrimerURL = initialDiscovery.fullLengthForwardPrimerURL
        self.fullLengthReversePrimerURL = initialDiscovery.fullLengthReversePrimerURL
        self.fullLengthMinimumLength = 2_000
        self.fullLengthMaximumLength = 4_000
        self.selectedHaplotypeAssayID = Self.defaultHaplotypeAssayID()
        self.selectedHaplotypeSpeciesCode = nil
        self.selectedHaplotypeDefinitionScope = nil
        self.selectedHaplotypeDefinitionSetID = nil
        self.extraArgumentsText = ""
        self.advancedOptionsExpanded = false
        self.projectReferenceCandidates = initialDiscovery.referenceCandidates
        self.projectGuideCandidates = initialDiscovery.guideCandidates
        self.projectBarcodeDefinitionCandidates = initialDiscovery.barcodeDefinitionCandidates
        self.selectedReferenceURL = initialDiscovery.referenceCandidates.first
        self.selectedGuideURL = initialDiscovery.guideCandidates.first
        self.selectedBarcodeDefinitionURL = initialDiscovery.barcodeDefinitionCandidates.first
        self.isDiscoveringProjectResources = false
        self.errorMessage = nil
        self.showingError = false
        self.workflowAvailabilityRevision = 0

        let initialTools = Self.makeTools(
            enablementStore: enablementStore,
            packages: packageStore.cachedValidatedPackages()
        )
        self.cachedTools = initialTools
        self.cachedHaplotypeRecords = initialDiscovery.haplotypeRecords
        self.cachedHaplotypeRegistry = Self.makeHaplotypeRegistry(from: initialDiscovery.haplotypeRecords)
        self.cachedReferenceBundleSummaries = initialDiscovery.referenceBundleSummaries
        self.cachedBundledHaplotypeDefinitions = initialDiscovery.bundledHaplotypeDefinitions
        let initialToolID = requestedInitialToolID.flatMap { requested in
            initialTools.first { $0.id == requested && $0.availability == .available }?.id
        }
            ?? initialTools.first(where: { $0.availability == .available })?.id
            ?? initialTools.first?.id
            ?? Self.ontGenotypingID
        self.selectedToolID = initialToolID
        self.outputDirectoryURL = Self.defaultOutputDirectory(
            projectURL: self.projectURL,
            toolKind: initialTools.first { $0.id == initialToolID }?.kind
        )
        applyReferenceDefaultsForCurrentAmpliconMode()
        cacheReferenceBundleSummaryIfNeeded(self.selectedReferenceURL)
        self.enablementObserver = WorkflowOperationNotificationObserver(
            NotificationCenter.default.addObserver(
                forName: .workflowLibraryEnablementDidChange,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.refreshWorkflowAvailability()
                }
            }
        )
        if projectDiscoveryMode == .asynchronous {
            startProjectResourceDiscovery(
                selecting: nil,
                resetReferenceSelection: true,
                resetBarcodeSelection: true,
                updateFullLengthDefaults: true
            )
        }
        startWorkflowPackageRefresh()
    }

    deinit {
        projectDiscoveryTask?.cancel()
        workflowPackageRefreshTask?.cancel()
    }

    var tools: [WorkflowOperationTool] {
        _ = workflowAvailabilityRevision
        return cachedTools
    }

    var sidebarItems: [DatasetOperationToolSidebarItem] {
        tools.map {
            DatasetOperationToolSidebarItem(
                id: $0.id,
                title: $0.title,
                subtitle: $0.subtitle,
                availability: $0.availability
            )
        }
    }

    var selectedTool: WorkflowOperationTool? {
        tools.first { $0.id == selectedToolID }
    }

    var haplotypeDefinitionRegistry: GenotypeHaplotypeDefinitionRegistry {
        cachedHaplotypeRegistry
    }

    var compatibleHaplotypeDefinitionRecords: [HaplotypeDefinitionRecord] {
        if let bundleURL = selectedMHCReferenceBundleURL {
            return cachedHaplotypeRecords.filter { record in
                guard record.referenceBundleURL == bundleURL else { return false }
                if let assayID = selectedHaplotypeAssayID,
                   !assayID.isEmpty,
                   record.definitionSet.assayID != assayID {
                    return false
                }
                if let speciesCode = selectedHaplotypeSpeciesCode?.trimmingCharacters(in: .whitespacesAndNewlines),
                   !speciesCode.isEmpty,
                   record.definitionSet.speciesCode.caseInsensitiveCompare(speciesCode) != .orderedSame {
                    return false
                }
                return true
            }
        }
        return activeCachedHaplotypeRecords(
            assayID: selectedHaplotypeAssayID,
            speciesCode: selectedHaplotypeSpeciesCode,
            scope: selectedHaplotypeDefinitionScope
        )
    }

    var haplotypeSpeciesOptions: [(code: String, label: String)] {
        let records: [HaplotypeDefinitionRecord]
        if let bundleURL = selectedMHCReferenceBundleURL {
            records = cachedHaplotypeRecords.filter {
                $0.referenceBundleURL == bundleURL
                    && (selectedHaplotypeAssayID == nil || $0.definitionSet.assayID == selectedHaplotypeAssayID)
            }
        } else {
            records = activeCachedHaplotypeRecords(
                assayID: selectedHaplotypeAssayID,
                scope: selectedHaplotypeDefinitionScope
            )
        }
        var seen = Set<String>()
        return records.compactMap { record in
            let code = record.definitionSet.speciesCode
            guard seen.insert(code).inserted else { return nil }
            return (code: code, label: "\(record.definitionSet.speciesName) (\(code))")
        }
    }

    var haplotypeScopeOptions: [HaplotypeDefinitionScope] {
        if selectedMHCReferenceBundleURL != nil {
            return []
        }
        let scopes = Set(
            activeCachedHaplotypeRecords(
                assayID: selectedHaplotypeAssayID,
                speciesCode: selectedHaplotypeSpeciesCode
            )
            .map(\.scope)
        )
        return HaplotypeDefinitionScope.allCases.filter { scopes.contains($0) }
    }

    var selectedMHCReferenceBundleURL: URL? {
        guard let selectedReferenceURL,
              MHCAmpliconReferenceBundle.isBundleURL(selectedReferenceURL) else {
            return nil
        }
        return selectedReferenceURL.standardizedFileURL
    }

    /// True when an `.lungfishmhcref` bundle supplies the haplotype definition, so the
    /// dialog should collapse the assay/species/scope/definition pickers in favour of the
    /// bundle's paired definition.
    var usesBundledHaplotypeDefinitions: Bool {
        selectedMHCReferenceBundleURL != nil
    }

    var availableAmpliconPresets: [AmpliconGenotypingPreset] {
        MCMHaplotypingPreset.builtInPresets
    }

    var selectedAmpliconPreset: AmpliconGenotypingPreset? {
        MCMHaplotypingPreset.preset(id: selectedAmpliconPresetID)
    }

    var selectedAmpliconPresetDisplayName: String {
        selectedAmpliconPreset?.displayName ?? "No preset selected"
    }

    var selectedAmpliconPresetReferenceSummary: String {
        guard let preset = selectedAmpliconPreset else {
            return "No preset reference selected"
        }
        return "\(preset.displayName) reference, \(preset.referenceFASTARecordCount) records"
    }

    var selectedAmpliconPresetPromptSummary: String {
        guard let preset = selectedAmpliconPreset else {
            return "No specialist prompt selected"
        }
        return "Specialist prompt \(preset.aiPromptTemplateVersion), \(preset.aiOpenAIModel) \(preset.aiReasoningEffort)"
    }

    var shouldShowManualAmpliconReferencePicker: Bool {
        selectedTool?.kind != .ontGenotyping || selectedAmpliconAnalysisMode != .aiSpecialistPreset
    }

    var effectiveGenotypingMode: AmpliconGenotypingMode {
        switch selectedGenotypingReadType {
        case .ont:
            return .ontSampleBundles
        case .illumina:
            return .illuminaPaired
        case .auto:
            return selectedReadURLs.contains { Self.genotypingReadTypeFromFASTQMetadata($0) == .illumina }
                ? .illuminaPaired
                : .ontSampleBundles
        }
    }

    var effectiveGenotypingReadType: AmpliconGenotypingReadType {
        switch effectiveGenotypingMode {
        case .illuminaPaired:
            return .illumina
        case .ontBarcodeDemux, .ontSampleBundles:
            return .ont
        case .auto:
            return selectedGenotypingReadType == .illumina ? .illumina : .ont
        }
    }

    /// "From bundle: <name>" caption shown in place of the haplotype picker stack when an
    /// `.lungfishmhcref` bundle is selected; `nil` otherwise.
    var referenceBundleSummary: String? {
        guard let bundleURL = selectedMHCReferenceBundleURL else { return nil }
        return cachedReferenceBundleSummaries[bundleURL]
    }

    var datasetLabel: String {
        guard !selectedReadURLs.isEmpty else { return "No read bundles selected" }
        if selectedReadURLs.count == 1 {
            return selectedReadURLs[0].lastPathComponent
        }
        return "\(selectedReadURLs.count) read bundles selected"
    }

    var selectedReferenceDisplay: String {
        guard let selectedReferenceURL else { return "No reference selected" }
        return Self.displayPath(for: selectedReferenceURL, relativeTo: projectURL)
    }

    var selectedGuideDisplay: String {
        guard let selectedGuideURL else { return "No guide selected" }
        return Self.displayPath(for: selectedGuideURL, relativeTo: projectURL)
    }

    var selectedReadsDisplay: String {
        if let sidebarInputSelection {
            return sidebarInputSelection.summaryText(includeSubfolders: includeSubfolderBundles)
        }
        guard !selectedReadURLs.isEmpty else { return "No read bundles selected" }
        return selectedReadURLs
            .map { Self.displayPath(for: $0, relativeTo: projectURL) }
            .joined(separator: ", ")
    }

    var folderSubfolderNoticeText: String? {
        sidebarInputSelection?.subfolderSummaryText
    }

    var folderDuplicateNoticeText: String? {
        sidebarInputSelection?.duplicateSummaryText(includeSubfolders: includeSubfolderBundles)
    }

    var folderEmptyNoticeText: String? {
        sidebarInputSelection?.emptyFolderSummaryText
    }

    var resolvedReadDetailRows: [WorkflowSidebarInputSelection.DetailRow] {
        if let sidebarInputSelection {
            return sidebarInputSelection.detailRows(includeSubfolders: includeSubfolderBundles)
        }
        return selectedReadURLs.map {
            WorkflowSidebarInputSelection.DetailRow(
                url: $0,
                displayPath: Self.displayPath(for: $0, relativeTo: projectURL)
            )
        }
    }

    var outputDirectoryDisplay: String {
        guard let outputDirectoryURL else { return "No output directory selected" }
        return Self.displayPath(for: outputDirectoryURL, relativeTo: projectURL)
    }

    var twelveSSampleMetadataDisplay: String {
        guard let twelveSSampleMetadataURL else { return "No analysis metadata selected" }
        return Self.displayPath(for: twelveSSampleMetadataURL, relativeTo: projectURL)
    }

    func referenceURLForSelectedTool() -> URL? {
        guard selectedTool?.kind == .ontGenotyping,
              selectedAmpliconAnalysisMode == .aiSpecialistPreset else {
            return selectedReferenceURL
        }
        return try? selectedAmpliconPreset?.bundledReferenceBundleURL()
    }

    var selectedToolSummary: String {
        selectedTool?.subtitle ?? "Select a workflow to configure."
    }

    var readinessText: String {
        if selectedTool == nil {
            return "Enable a workflow in the Workflow Library before running."
        }
        guard selectedTool?.availability == .available else {
            return selectedTool?.availability.badgeText ?? "Workflow unavailable."
        }
        guard referenceURLForSelectedTool() != nil else {
            return selectedTool?.kind == .ontGenotyping && selectedAmpliconAnalysisMode == .aiSpecialistPreset
                ? "Select an AI specialist preset."
                : "Select a reference bundle or FASTA file."
        }
        guard selectedTool?.kind != .ontGenotyping
                || selectedAmpliconAnalysisMode != .aiSpecialistPreset
                || aiSpecialistPresetsAvailable else {
            return "Configure AI API access before using an AI specialist preset."
        }
        if selectedTool?.kind == .twelveSAmpliconMatching,
           Self.twelveSReferenceInput(for: referenceURLForSelectedTool()!) == nil {
            return "Select a 12S reference FASTA file or reference bundle."
        }
        if selectedTool?.kind == .twelveSAmpliconMatching,
           let twelveSSampleMetadataURL,
           !FileManager.default.fileExists(atPath: twelveSSampleMetadataURL.path) {
            return "Select a valid analysis metadata CSV or TSV file."
        }
        guard !selectedReadURLs.isEmpty else {
            return "Select one or more FASTQ bundles."
        }
        guard outputDirectoryURL != nil else {
            return "Select an output directory."
        }
        guard !outputName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return "Enter an output name."
        }
        if case .workflowPackage(let package) = selectedTool?.kind,
           !Self.packageIsRunnable(package) {
            return "This package must declare a Nextflow or Snakemake runner with lungfishref and lungfishfastq inputs."
        }
        if case .workflowPackage = selectedTool?.kind,
           selectedReadURLs.count > 1 {
            return "Imported workflow packages currently accept one FASTQ bundle. Select one bundle, or choose a built-in workflow for folder batches."
        }
        if threads < 1 {
            return "Threads must be at least 1."
        }
        if selectedTool?.kind == .ontGenotyping, minSupport < 1 {
            return "Minimum read threshold must be at least 1."
        }
        if selectedTool?.kind == .ontGenotyping,
           selectedAmpliconAnalysisMode == .deterministicHaplotyping,
           selectedHaplotypeDefinitionSetID == nil {
            return "Select a deterministic haplotype definition, or choose genotype-only."
        }
        if selectedTool?.kind == .fullLengthONTMHCGenotyping,
           haplotypeDropoutLocusPercent < 0 || haplotypeDropoutLocusPercent > 100 {
            return "Locus percent threshold must be between 0 and 100."
        }
        if selectedTool?.kind == .twelveSAmpliconMatching,
           twelveSMinimumSoftClipBases < 0 {
            return "Minimum soft clip must be at least 0."
        }
        if selectedTool?.kind == .twelveSAmpliconMatching,
           twelveSMaximumIndelBases < 0 {
            return "Maximum indels must be at least 0."
        }
        if selectedTool?.kind == .fullLengthONTMHCGenotyping,
           fullLengthMinimumLength < 1 {
            return "Minimum length must be at least 1."
        }
        if selectedTool?.kind == .fullLengthONTMHCGenotyping,
           fullLengthMaximumLength < fullLengthMinimumLength {
            return "Maximum length must be greater than or equal to minimum length."
        }
        if selectedTool?.kind == .ontGenotyping,
           effectiveGenotypingMode == .illuminaPaired,
           selectedReadURLs.isEmpty {
            return "Select one or more prepared Illumina sample FASTQ bundles."
        }
        if selectedTool?.kind == .ontGenotyping,
           (try? AdvancedCommandLineOptions.parse(extraArgumentsText)) == nil {
            return "Advanced minimap2 arguments could not be parsed."
        }
        return "Ready to run."
    }

    var isRunEnabled: Bool {
        readinessText == "Ready to run."
    }

    func selectTool(_ id: String) {
        guard tools.first(where: { $0.id == id })?.availability == .available else { return }
        let previousToolKind = selectedTool?.kind
        let previousDefaultOutputDirectory = Self.defaultOutputDirectory(
            projectURL: projectURL,
            toolKind: previousToolKind
        )
        selectedToolID = id
        let nextDefaultOutputDirectory = Self.defaultOutputDirectory(
            projectURL: projectURL,
            toolKind: selectedTool?.kind
        )
        if outputDirectoryURL == nil
            || outputDirectoryURL?.standardizedFileURL == previousDefaultOutputDirectory?.standardizedFileURL {
            outputDirectoryURL = nextDefaultOutputDirectory
        }
        if case .workflowPackage = selectedTool?.kind {
            outputName = selectedTool?.title
                .lowercased()
                .components(separatedBy: CharacterSet.alphanumerics.inverted)
                .filter { !$0.isEmpty }
                .joined(separator: "-") ?? "workflow-output"
        } else if selectedTool?.kind == .fullLengthONTMHCGenotyping {
            outputName = Self.defaultFullLengthONTMHCOutputName(for: selectedReadURLs)
            if selectedHaplotypeAssayID == nil {
                selectedHaplotypeAssayID = Self.defaultHaplotypeAssayID()
            }
        } else if selectedTool?.kind == .twelveSAmpliconMatching {
            outputName = Self.defaultTwelveSOutputName(for: selectedReadURLs)
        } else {
            outputName = Self.defaultONTGenotypingOutputName(for: selectedReadURLs)
            applyReferenceDefaultsForCurrentAmpliconMode()
        }
    }

    func setAmpliconAnalysisMode(_ mode: WorkflowOperationAmpliconAnalysisMode) {
        guard mode != .aiSpecialistPreset || aiSpecialistPresetsAvailable else {
            selectedAmpliconAnalysisMode = .genotypeOnly
            return
        }
        selectedAmpliconAnalysisMode = mode
        applyReferenceDefaultsForCurrentAmpliconMode()
    }

    func setAmpliconPreset(_ id: String?) {
        selectedAmpliconPresetID = MCMHaplotypingPreset.preset(id: id)?.id
            ?? MCMHaplotypingPreset.mcmMHCmiseq.id
        applyReferenceDefaultsForCurrentAmpliconMode()
    }

    func setAISpecialistPresetsAvailable(_ available: Bool) {
        aiSpecialistPresetsAvailable = available
        if !available, selectedAmpliconAnalysisMode == .aiSpecialistPreset {
            selectedAmpliconAnalysisMode = .genotypeOnly
        }
        applyReferenceDefaultsForCurrentAmpliconMode()
    }

    func refreshWorkflowAvailability() {
        cachedTools = Self.makeTools(
            enablementStore: enablementStore,
            packages: packageStore.cachedValidatedPackages()
        )
        workflowAvailabilityRevision &+= 1
        startWorkflowPackageRefresh()
    }

#if DEBUG
    func testingReplaceTools(_ tools: [WorkflowOperationTool]) {
        workflowPackageRefreshTask?.cancel()
        workflowPackageRefreshGeneration &+= 1
        cachedTools = tools
        selectedToolID = tools.first?.id ?? Self.ontGenotypingID
        workflowAvailabilityRevision &+= 1
    }
#endif

    private func refreshCachedHaplotypeDefinitions() {
        cachedHaplotypeRecords = Self.loadHaplotypeRecords(projectURL: projectURL)
        cachedHaplotypeRegistry = Self.makeHaplotypeRegistry(from: cachedHaplotypeRecords)
        cachedReferenceBundleSummaries = Self.referenceBundleSummaries(from: cachedHaplotypeRecords)
        cachedBundledHaplotypeDefinitions = Self.bundledHaplotypeDefinitions(from: projectReferenceCandidates)
        cacheReferenceBundleSummaryIfNeeded(selectedReferenceURL)
    }

    private func activeCachedHaplotypeRecords(
        assayID: String? = nil,
        speciesCode: String? = nil,
        scope: HaplotypeDefinitionScope? = nil
    ) -> [HaplotypeDefinitionRecord] {
        cachedHaplotypeRecords.filter { record in
            guard !record.isShadowed else { return false }
            if let assayID, !assayID.isEmpty, record.definitionSet.assayID != assayID {
                return false
            }
            if let speciesCode = speciesCode?.trimmingCharacters(in: .whitespacesAndNewlines),
               !speciesCode.isEmpty,
               record.definitionSet.speciesCode.caseInsensitiveCompare(speciesCode) != .orderedSame {
                return false
            }
            if let scope, record.scope != scope {
                return false
            }
            return true
        }
    }

    private func cacheReferenceBundleSummaryIfNeeded(_ url: URL?) {
        guard let url,
              MHCAmpliconReferenceBundle.isBundleURL(url) else {
            return
        }
        let bundleURL = url.standardizedFileURL
        if cachedReferenceBundleSummaries[bundleURL] == nil,
           let summary = Self.referenceBundleSummary(for: bundleURL) {
            cachedReferenceBundleSummaries[bundleURL] = summary
        }
    }

    func refreshProjectReferences(selecting url: URL? = nil) {
        if projectDiscoveryMode == .asynchronous {
            startProjectResourceDiscovery(
                selecting: url,
                resetReferenceSelection: selectedReferenceURL == nil,
                resetBarcodeSelection: false,
                updateFullLengthDefaults: false
            )
        } else {
            applyProjectDiscoverySnapshot(
                Self.projectDiscoverySnapshot(projectURL: projectURL),
                selecting: url,
                resetReferenceSelection: selectedReferenceURL == nil,
                resetGuideSelection: true,
                resetBarcodeSelection: false,
                updateFullLengthDefaults: false
            )
        }
    }

    private func startProjectResourceDiscovery(
        selecting url: URL?,
        resetReferenceSelection: Bool,
        resetBarcodeSelection: Bool,
        updateFullLengthDefaults: Bool
    ) {
        projectDiscoveryTask?.cancel()
        projectDiscoveryGeneration &+= 1
        let generation = projectDiscoveryGeneration
        let discoveryProjectURL = projectURL?.standardizedFileURL
        let selectedURL = url?.standardizedFileURL
        let initialReferenceURL = selectedReferenceURL?.standardizedFileURL
        let initialGuideURL = selectedGuideURL?.standardizedFileURL
        let initialBarcodeDefinitionURL = selectedBarcodeDefinitionURL?.standardizedFileURL
        let initialFullLengthOrientReferenceURL = fullLengthOrientReferenceURL?.standardizedFileURL
        let initialFullLengthForwardPrimerURL = fullLengthForwardPrimerURL?.standardizedFileURL
        let initialFullLengthReversePrimerURL = fullLengthReversePrimerURL?.standardizedFileURL
        #if DEBUG
        let testingDelay = Self.testingProjectDiscoveryDelay
        #endif
        isDiscoveringProjectResources = true
        projectDiscoveryTask = Task { @MainActor [weak self] in
            #if DEBUG
            if let testingDelay {
                do {
                    try await Task.sleep(for: testingDelay)
                } catch {
                    return
                }
            }
            #endif
            let workerTask = Task.detached(priority: .userInitiated) {
                Self.projectDiscoverySnapshot(projectURL: discoveryProjectURL)
            }
            let snapshot = await withTaskCancellationHandler {
                await workerTask.value
            } onCancel: {
                workerTask.cancel()
            }

            guard let self,
                  !Task.isCancelled,
                  generation == self.projectDiscoveryGeneration,
                  self.projectURL?.standardizedFileURL == discoveryProjectURL else {
                return
            }

            self.projectDiscoveryTask = nil
            let referenceUnchanged = self.selectedReferenceURL?.standardizedFileURL == initialReferenceURL
            let guideUnchanged = self.selectedGuideURL?.standardizedFileURL == initialGuideURL
            let barcodeUnchanged = self.selectedBarcodeDefinitionURL?.standardizedFileURL == initialBarcodeDefinitionURL
            let fullLengthDefaultsUnchanged = self.fullLengthOrientReferenceURL?.standardizedFileURL == initialFullLengthOrientReferenceURL
                && self.fullLengthForwardPrimerURL?.standardizedFileURL == initialFullLengthForwardPrimerURL
                && self.fullLengthReversePrimerURL?.standardizedFileURL == initialFullLengthReversePrimerURL
            self.applyProjectDiscoverySnapshot(
                snapshot,
                selecting: referenceUnchanged ? selectedURL : nil,
                resetReferenceSelection: resetReferenceSelection && referenceUnchanged,
                resetGuideSelection: guideUnchanged,
                resetBarcodeSelection: resetBarcodeSelection && barcodeUnchanged,
                updateFullLengthDefaults: updateFullLengthDefaults && fullLengthDefaultsUnchanged
            )
            self.isDiscoveringProjectResources = false
        }
    }

    private func startWorkflowPackageRefresh() {
        workflowPackageRefreshTask?.cancel()
        workflowPackageRefreshGeneration &+= 1
        let generation = workflowPackageRefreshGeneration
        let packageStore = packageStore
        workflowPackageRefreshTask = Task { @MainActor [weak self, packageStore] in
            let packages = await packageStore.validatedPackagesInBackground()
            guard let self else { return }
            guard !Task.isCancelled,
                  generation == self.workflowPackageRefreshGeneration else {
                return
            }
            self.cachedTools = Self.makeTools(
                enablementStore: self.enablementStore,
                packages: packages
            )
            if self.cachedTools.first(where: { $0.id == self.selectedToolID })?.availability != .available,
               let firstAvailable = self.cachedTools.first(where: { $0.availability == .available }) {
                self.selectTool(firstAvailable.id)
            }
            self.workflowAvailabilityRevision &+= 1
        }
    }

    private func clearProjectDiscoverySnapshot() {
        projectReferenceCandidates = []
        projectGuideCandidates = []
        projectBarcodeDefinitionCandidates = []
        selectedReferenceURL = nil
        selectedGuideURL = nil
        selectedBarcodeDefinitionURL = nil
        cachedHaplotypeRecords = []
        cachedHaplotypeRegistry = Self.makeHaplotypeRegistry(from: [])
        cachedReferenceBundleSummaries = [:]
        cachedBundledHaplotypeDefinitions = [:]
        fullLengthOrientReferenceURL = nil
        fullLengthForwardPrimerURL = nil
        fullLengthReversePrimerURL = nil
    }

    private func applyProjectDiscoverySnapshot(
        _ snapshot: WorkflowOperationProjectDiscoverySnapshot,
        selecting url: URL?,
        resetReferenceSelection: Bool,
        resetGuideSelection: Bool,
        resetBarcodeSelection: Bool,
        updateFullLengthDefaults: Bool
    ) {
        projectReferenceCandidates = snapshot.referenceCandidates
        projectGuideCandidates = snapshot.guideCandidates
        projectBarcodeDefinitionCandidates = snapshot.barcodeDefinitionCandidates
        cachedHaplotypeRecords = snapshot.haplotypeRecords
        cachedHaplotypeRegistry = Self.makeHaplotypeRegistry(from: snapshot.haplotypeRecords)
        cachedReferenceBundleSummaries = snapshot.referenceBundleSummaries
        cachedBundledHaplotypeDefinitions = snapshot.bundledHaplotypeDefinitions

        if let url {
            setReference(url)
        } else if resetReferenceSelection || selectedReferenceURL == nil {
            setReference(snapshot.referenceCandidates.first)
        } else {
            cacheReferenceBundleSummaryIfNeeded(selectedReferenceURL)
        }

        if resetGuideSelection,
           selectedGuideURL == nil || !snapshot.guideCandidates.contains(selectedGuideURL!.standardizedFileURL) {
            setGuide(snapshot.guideCandidates.first)
        }

        refreshHaplotypeSelectionForCurrentProject()
        if resetBarcodeSelection || selectedBarcodeDefinitionURL == nil {
            selectedBarcodeDefinitionURL = snapshot.barcodeDefinitionCandidates.first
        }
        if updateFullLengthDefaults {
            fullLengthOrientReferenceURL = snapshot.fullLengthOrientReferenceURL
            fullLengthForwardPrimerURL = snapshot.fullLengthForwardPrimerURL
            fullLengthReversePrimerURL = snapshot.fullLengthReversePrimerURL
        }
    }

    func setHaplotypeAssay(_ assayID: String?) {
        let trimmedAssayID = assayID?.trimmingCharacters(in: .whitespacesAndNewlines)
        selectedHaplotypeAssayID = trimmedAssayID?.isEmpty == true ? nil : trimmedAssayID
        selectedHaplotypeSpeciesCode = nil
        selectedHaplotypeDefinitionScope = nil
        refreshHaplotypeSelectionForCurrentFilters()
    }

    func setHaplotypeSpecies(_ speciesCode: String?) {
        let trimmedSpeciesCode = speciesCode?.trimmingCharacters(in: .whitespacesAndNewlines)
        selectedHaplotypeSpeciesCode = trimmedSpeciesCode?.isEmpty == true ? nil : trimmedSpeciesCode
        if let selectedHaplotypeDefinitionScope,
           !haplotypeScopeOptions.contains(selectedHaplotypeDefinitionScope) {
            self.selectedHaplotypeDefinitionScope = nil
        }
        refreshHaplotypeSelectionForCurrentFilters()
    }

    func setHaplotypeDefinitionScope(_ scope: HaplotypeDefinitionScope?) {
        selectedHaplotypeDefinitionScope = scope
        refreshHaplotypeSelectionForCurrentFilters()
    }

    func setHaplotypeDefinition(_ definitionSetID: String?) {
        let trimmedDefinitionSetID = definitionSetID?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let id = trimmedDefinitionSetID, !id.isEmpty else {
            selectedHaplotypeDefinitionSetID = nil
            return
        }
        if let record = compatibleHaplotypeDefinitionRecords.first(where: { $0.definitionSet.id == id }) {
            selectedHaplotypeAssayID = record.definitionSet.assayID
            selectedHaplotypeSpeciesCode = record.definitionSet.speciesCode
            selectedHaplotypeDefinitionScope = record.referenceBundleURL == nil ? record.scope : nil
            selectedHaplotypeDefinitionSetID = id
            return
        }
        if let record = activeCachedHaplotypeRecords().first(where: { $0.definitionSet.id == id }) {
            selectedHaplotypeAssayID = record.definitionSet.assayID
            selectedHaplotypeSpeciesCode = record.definitionSet.speciesCode
            selectedHaplotypeDefinitionScope = record.referenceBundleURL == nil ? record.scope : nil
            selectedHaplotypeDefinitionSetID = id
        }
    }

    private func refreshHaplotypeSelectionForCurrentProject() {
        let registry = haplotypeDefinitionRegistry
        if let selectedHaplotypeAssayID,
           registry.assay(id: selectedHaplotypeAssayID) == nil {
            self.selectedHaplotypeAssayID = registry.assays.first?.id
            selectedHaplotypeDefinitionSetID = nil
        } else if selectedHaplotypeAssayID == nil {
            selectedHaplotypeAssayID = registry.assays.first?.id
        }
        guard let selectedHaplotypeDefinitionSetID else { return }
        refreshHaplotypeSelectionForCurrentFilters(selectedDefinitionID: selectedHaplotypeDefinitionSetID)
    }

    private func refreshHaplotypeSelectionForCurrentFilters(selectedDefinitionID: String? = nil) {
        let selectedID = selectedDefinitionID ?? selectedHaplotypeDefinitionSetID
        if let selectedID,
           compatibleHaplotypeDefinitionRecords.contains(where: { $0.definitionSet.id == selectedID }) {
            selectedHaplotypeDefinitionSetID = selectedID
            return
        }
        selectedHaplotypeDefinitionSetID = nil
    }

    func setReference(_ url: URL?) {
        selectedReferenceURL = url?.standardizedFileURL
        cacheReferenceBundleSummaryIfNeeded(selectedReferenceURL)
        if selectedAmpliconAnalysisMode == .deterministicHaplotyping {
            applyBundledMHCReferenceDefaultsIfAvailable(for: selectedReferenceURL)
        }
    }

    private func applyReferenceDefaultsForCurrentAmpliconMode() {
        guard selectedToolID == Self.ontGenotypingID else { return }
        switch selectedAmpliconAnalysisMode {
        case .aiSpecialistPreset:
            applySelectedAmpliconPresetReference()
        case .deterministicHaplotyping:
            applyBundledMHCReferenceDefaultsIfAvailable(for: selectedReferenceURL)
        case .genotypeOnly:
            selectedHaplotypeAssayID = nil
            selectedHaplotypeSpeciesCode = nil
            selectedHaplotypeDefinitionScope = nil
            selectedHaplotypeDefinitionSetID = nil
        }
    }

    private func applySelectedAmpliconPresetReference() {
        let preset = MCMHaplotypingPreset.mcmMHCmiseq
        guard let bundleURL = try? preset.bundledReferenceBundleURL() else {
            selectedReferenceURL = nil
            selectedHaplotypeAssayID = nil
            selectedHaplotypeSpeciesCode = nil
            selectedHaplotypeDefinitionScope = nil
            selectedHaplotypeDefinitionSetID = nil
            return
        }
        selectedReferenceURL = bundleURL
        cacheReferenceBundleSummaryIfNeeded(bundleURL)
        selectedHaplotypeAssayID = nil
        selectedHaplotypeSpeciesCode = nil
        selectedHaplotypeDefinitionScope = nil
        selectedHaplotypeDefinitionSetID = nil
    }

    func setGuide(_ url: URL?) {
        guard let url else {
            selectedGuideURL = nil
            return
        }
        let standardizedURL = url.standardizedFileURL
        guard projectURL == nil || projectGuideCandidates.isEmpty || projectGuideCandidates.contains(standardizedURL) else {
            selectedGuideURL = nil
            return
        }
        selectedGuideURL = standardizedURL
    }

    private func applyBundledMHCReferenceDefaultsIfAvailable(for url: URL?) {
        guard let url,
              MHCAmpliconReferenceBundle.isBundleURL(url) else {
            return
        }
        let bundleURL = url.standardizedFileURL
        let definition: GenotypeHaplotypeDefinitionSet?
        if let cachedDefinition = cachedBundledHaplotypeDefinitions[bundleURL] {
            definition = cachedDefinition
        } else {
            definition = try? MHCAmpliconReferenceBundle.defaultHaplotypeDefinition(in: bundleURL)
        }
        guard let definition else { return }
        selectedHaplotypeAssayID = definition.assayID
        selectedHaplotypeSpeciesCode = definition.speciesCode
        selectedHaplotypeDefinitionScope = nil
        selectedHaplotypeDefinitionSetID = definition.id
    }

    func setBarcodeDefinition(_ url: URL?) {
        selectedBarcodeDefinitionURL = url?.standardizedFileURL
    }

    func setReads(_ urls: [URL]) {
        selectedReadURLs = Self.deduplicated(urls.map(\.standardizedFileURL))
        if selectedGenotypingReadType == .auto {
            selectedGenotypingReadType = Self.defaultGenotypingReadType(for: selectedReadURLs)
        }
    }

    func setIncludeSubfolderBundles(_ include: Bool) {
        includeSubfolderBundles = include
        guard let sidebarInputSelection else { return }
        setReads(sidebarInputSelection.selectedReadURLs(includeSubfolders: include))
    }

    func setOutputDirectory(_ url: URL?) {
        outputDirectoryURL = url?.standardizedFileURL
    }

    func setTwelveSSampleMetadata(_ url: URL?) {
        twelveSSampleMetadataURL = url?.standardizedFileURL
    }

    func configureProject(
        projectURL: URL?,
        selectedReadURLs: [URL],
        sidebarInputSelection: WorkflowSidebarInputSelection? = nil
    ) {
        let standardizedProjectURL = projectURL?.standardizedFileURL
        let projectChanged = self.projectURL != standardizedProjectURL
        let resolvedReadURLs = sidebarInputSelection?.selectedReadURLs(includeSubfolders: false) ?? selectedReadURLs

        self.projectURL = standardizedProjectURL
        self.sidebarInputSelection = sidebarInputSelection
        includeSubfolderBundles = false
        setReads(resolvedReadURLs)
        if projectDiscoveryMode == .asynchronous {
            if projectChanged {
                clearProjectDiscoverySnapshot()
            }
            startProjectResourceDiscovery(
                selecting: nil,
                resetReferenceSelection: projectChanged || selectedReferenceURL == nil,
                resetBarcodeSelection: projectChanged || selectedBarcodeDefinitionURL == nil,
                updateFullLengthDefaults: projectChanged
            )
        } else {
            applyProjectDiscoverySnapshot(
                Self.projectDiscoverySnapshot(projectURL: standardizedProjectURL),
                selecting: nil,
                resetReferenceSelection: projectChanged || selectedReferenceURL == nil,
                resetGuideSelection: true,
                resetBarcodeSelection: projectChanged || selectedBarcodeDefinitionURL == nil,
                updateFullLengthDefaults: projectChanged
            )
        }
        if projectChanged {
            selectedGenotypingReadType = Self.defaultGenotypingReadType(for: self.selectedReadURLs)
        }
        if projectChanged || outputDirectoryURL == nil {
            outputDirectoryURL = Self.defaultOutputDirectory(
                projectURL: standardizedProjectURL,
                toolKind: selectedTool?.kind
            )
        }
    }

    func makeLaunchRequest() throws -> WorkflowOperationLaunchRequest {
        guard let selectedTool,
              let outputDirectoryURL else {
            throw WorkflowOperationError.incompleteConfiguration(readinessText)
        }
        guard isRunEnabled else {
            throw WorkflowOperationError.incompleteConfiguration(readinessText)
        }
        switch selectedTool.kind {
        case .ontGenotyping:
            guard !selectedReadURLs.isEmpty else {
                throw WorkflowOperationError.incompleteConfiguration(readinessText)
            }
            guard let referenceURL = referenceURLForSelectedTool() else {
                throw WorkflowOperationError.incompleteConfiguration(readinessText)
            }
            let launchMode = effectiveGenotypingMode
            let readType = effectiveGenotypingReadType
            let outputBundleURL = Self.ontGenotypingBundleURL(
                outputLocationURL: outputDirectoryURL,
                outputName: outputName
            )
            let parsedExtraArguments = try AdvancedCommandLineOptions.parse(extraArgumentsText)
            let request: ONTBarcodeDemuxGenotypingRunRequest
            switch selectedAmpliconAnalysisMode {
            case .aiSpecialistPreset:
                guard aiSpecialistPresetsAvailable,
                      let preset = selectedAmpliconPreset else {
                    throw WorkflowOperationError.incompleteConfiguration(readinessText)
                }
                request = try preset.makeGenotypingRunRequest(
                    inputFASTQURLs: selectedReadURLs,
                    barcodeDefinitionsURL: nil,
                    outputDirectory: outputBundleURL,
                    outputName: outputName,
                    analysisName: outputName,
                    projectURL: projectURL,
                    threads: threads,
                    minSupport: minSupport,
                    keepIntermediates: keepIntermediates,
                    haplotypeDropoutSampleFraction: nil,
                    haplotypeDropoutLocusFraction: nil,
                    haplotypeDropoutLocusFractionOverrides: [:],
                    extraArguments: parsedExtraArguments,
                    mode: launchMode,
                    readType: readType,
                    includeDeterministicHaplotyping: false,
                    aiSpecialistPresetID: preset.id
                )
            case .deterministicHaplotyping:
                request = ONTBarcodeDemuxGenotypingRunRequest(
                    inputFASTQURLs: selectedReadURLs,
                    referenceSourceURL: referenceURL,
                    barcodeDefinitionsURL: nil,
                    outputDirectory: outputBundleURL,
                    outputName: outputName,
                    analysisName: outputName,
                    projectURL: projectURL,
                    threads: threads,
                    minSupport: minSupport,
                    keepIntermediates: keepIntermediates,
                    haplotypeDropoutSampleFraction: Self.fraction(fromPercent: haplotypeDropoutSamplePercent),
                    haplotypeDropoutLocusFraction: Self.fraction(fromPercent: haplotypeDropoutLocusPercent),
                    haplotypeDropoutLocusFractionOverrides: Self.fractionOverrides(
                        fromPercents: haplotypeDropoutLocusOverridePercents
                    ),
                    haplotypeAssayID: selectedHaplotypeAssayID,
                    haplotypeSpeciesCode: selectedHaplotypeSpeciesCode,
                    haplotypeDefinitionScope: selectedHaplotypeDefinitionScope,
                    haplotypeDefinitionSetID: selectedHaplotypeDefinitionSetID,
                    extraArguments: parsedExtraArguments,
                    mode: launchMode,
                    readType: readType
                )
            case .genotypeOnly:
                request = ONTBarcodeDemuxGenotypingRunRequest(
                    inputFASTQURLs: selectedReadURLs,
                    referenceSourceURL: referenceURL,
                    barcodeDefinitionsURL: nil,
                    outputDirectory: outputBundleURL,
                    outputName: outputName,
                    analysisName: outputName,
                    projectURL: projectURL,
                    threads: threads,
                    minSupport: minSupport,
                    keepIntermediates: keepIntermediates,
                    extraArguments: parsedExtraArguments,
                    mode: launchMode,
                    readType: readType
                )
            }
            return .ontGenotyping(request)

        case .fullLengthONTMHCGenotyping:
            guard !selectedReadURLs.isEmpty else {
                throw WorkflowOperationError.incompleteConfiguration(readinessText)
            }
            guard let selectedReferenceURL = referenceURLForSelectedTool() else {
                throw WorkflowOperationError.incompleteConfiguration(readinessText)
            }
            let request = FullLengthONTMHCGenotypingRunRequest(
                inputFASTQURLs: selectedReadURLs,
                referenceSourceURL: selectedReferenceURL,
                orientReferenceURL: fullLengthOrientReferenceURL,
                forwardPrimerURL: fullLengthForwardPrimerURL,
                reversePrimerURL: fullLengthReversePrimerURL,
                outputDirectory: Self.genotypeBundleURL(
                    outputLocationURL: outputDirectoryURL,
                    outputName: outputName
                ),
                outputName: outputName,
                projectURL: projectURL,
                threads: threads,
                minimumLength: fullLengthMinimumLength,
                maximumLength: fullLengthMaximumLength,
                keepIntermediates: keepIntermediates,
                haplotypeDropoutSampleFraction: nil,
                haplotypeDropoutLocusFraction: selectedHaplotypeDefinitionSetID == nil
                    ? nil
                    : Self.fraction(fromPercent: haplotypeDropoutLocusPercent),
                haplotypeDropoutLocusFractionOverrides: [:],
                haplotypeAssayID: selectedHaplotypeDefinitionSetID == nil ? nil : selectedHaplotypeAssayID,
                haplotypeSpeciesCode: selectedHaplotypeDefinitionSetID == nil ? nil : selectedHaplotypeSpeciesCode,
                haplotypeDefinitionScope: selectedHaplotypeDefinitionSetID == nil ? nil : selectedHaplotypeDefinitionScope,
                haplotypeDefinitionSetID: selectedHaplotypeDefinitionSetID
            )
            return .fullLengthONTMHCGenotyping(request)

        case .twelveSAmpliconMatching:
            guard !selectedReadURLs.isEmpty else {
                throw WorkflowOperationError.incompleteConfiguration(readinessText)
            }
            guard let selectedReferenceURL = referenceURLForSelectedTool(),
                  let referenceInput = Self.twelveSReferenceInput(for: selectedReferenceURL) else {
                throw WorkflowOperationError.incompleteConfiguration(readinessText)
            }
            let config = TwelveSAmpliconMatchingConfiguration(
                inputFASTQs: selectedReadURLs,
                referenceFASTA: referenceInput.fasta,
                referenceMetadata: referenceInput.metadata,
                referenceBundleURL: referenceInput.bundle,
                sampleMetadata: twelveSSampleMetadataURL,
                outputDirectory: outputDirectoryURL,
                outputName: outputName,
                minimumSoftClipBases: twelveSMinimumSoftClipBases,
                maximumIndelBases: twelveSMaximumIndelBases,
                matchingMode: twelveSMatchingMode,
                threads: threads,
                runChimeraReview: twelveSRunChimeraReview,
                forceOverwrite: false
            )
            return .twelveSAmpliconMatching(config)

        case .workflowPackage(let package):
            return .workflowPackage(
                try makeLocalWorkflowRunRequest(package: package),
                bundleRoot: outputDirectoryURL.appendingPathComponent("Workflow Runs", isDirectory: true)
            )
        }
    }

    private static func fraction(fromPercent percent: Double) -> Double? {
        guard percent.isFinite, percent > 0 else { return nil }
        return min(percent, 100.0) / 100.0
    }

    private static func fractionOverrides(fromPercents percents: [String: Double]) -> [String: Double] {
        percents.reduce(into: [:]) { result, item in
            guard let fraction = Self.fraction(fromPercent: item.value) else { return }
            result[item.key] = fraction
        }
    }

    private func makeLocalWorkflowRunRequest(
        package: WorkflowPackageValidationResult
    ) throws -> LocalWorkflowRunRequest {
        guard Self.packageIsRunnable(package) else {
            throw WorkflowOperationError.unsupportedPackage(package.manifest.name)
        }
        guard let referenceURL = selectedReferenceURL,
              let readURL = selectedReadURLs.first,
              let outputDirectoryURL else {
            throw WorkflowOperationError.incompleteConfiguration(readinessText)
        }
        let entrypointURL = package.packageURL.appendingPathComponent(package.manifest.runner.entrypoint)
        let engine: WorkflowEngineType
        switch package.manifest.runner.kind {
        case .nextflow:
            engine = .nextflow
        case .snakemake:
            engine = .snakemake
        case .command:
            throw WorkflowOperationError.unsupportedPackage(package.manifest.name)
        }

        var params: [String: String] = [:]
        for input in package.manifest.inputs {
            if input.bundleTypes.contains(.lungfishref) {
                params[input.id] = referenceURL.path
                params["reference_bundle"] = referenceURL.path
            }
            if input.bundleTypes.contains(.lungfishfastq) {
                params[input.id] = readURL.path
                params["reads_bundle"] = readURL.path
            }
        }
        params["outdir"] = outputDirectoryURL.path

        return LocalWorkflowRunRequest(
            workflowURL: entrypointURL,
            engine: engine,
            inputURLs: [referenceURL] + selectedReadURLs,
            outputDirectory: outputDirectoryURL,
            expectedOutputURLs: expectedOutputURLs(for: package, outputDirectoryURL: outputDirectoryURL),
            params: params,
            cpus: threads
        )
    }

    private func projectOwnedBarcodeDefinitionURL(for selectedURL: URL) throws -> URL {
        let sourceURL = selectedURL.standardizedFileURL
        guard let projectURL = projectURL?.standardizedFileURL,
              !Self.isURL(sourceURL, inside: projectURL) else {
            return sourceURL
        }

        let importDirectory = projectURL.appendingPathComponent("Barcode Definitions", isDirectory: true)
        let startedAt = Date()
        try FileManager.default.createDirectory(at: importDirectory, withIntermediateDirectories: true)
        let destinationURL = try Self.uniqueBarcodeDefinitionImportURL(
            for: sourceURL,
            in: importDirectory
        )

        if !FileManager.default.fileExists(atPath: destinationURL.path) {
            try FileManager.default.copyItem(at: sourceURL, to: destinationURL)
        }
        try writeBarcodeDefinitionImportProvenance(
            sourceURL: sourceURL,
            destinationURL: destinationURL,
            startedAt: startedAt,
            completedAt: Date()
        )

        projectBarcodeDefinitionCandidates = Self.discoverBarcodeDefinitionFiles(in: projectURL)
        selectedBarcodeDefinitionURL = destinationURL
        return destinationURL
    }

    private func writeBarcodeDefinitionImportProvenance(
        sourceURL: URL,
        destinationURL: URL,
        startedAt: Date,
        completedAt: Date
    ) throws {
        let argv = [
            "Lungfish.app",
            "workflow-operations",
            "import-barcode-definition",
            "--input",
            sourceURL.path,
            "--output",
            destinationURL.path,
        ]
        let options: [String: ParameterValue] = [
            "source": .file(sourceURL),
            "destination": .file(destinationURL),
            "importDirectory": .file(destinationURL.deletingLastPathComponent()),
        ]
        let envelope = try ProvenanceRunBuilder(
            workflowName: "Workflow Operations Barcode Definition Import",
            workflowVersion: WorkflowRun.currentAppVersion,
            toolName: "Lungfish.app",
            toolVersion: WorkflowRun.currentAppVersion
        )
        .argv(argv)
        .durableReplayArgv(argv)
        .options(explicit: options, defaults: [:], resolved: options)
        .input(sourceURL, format: Self.barcodeDefinitionFileFormat(for: sourceURL), role: .input)
        .output(destinationURL, format: Self.barcodeDefinitionFileFormat(for: destinationURL), role: .output)
        .runtime(ProvenanceRuntimeIdentity())
        .complete(exitStatus: 0, startedAt: startedAt, endedAt: completedAt)
        try ProvenanceWriter(signingProvider: nil).write(
            envelope,
            toSidecar: ProvenanceRecorder.fileSidecarURL(for: destinationURL)
        )
    }

    private func expectedOutputURLs(
        for package: WorkflowPackageValidationResult,
        outputDirectoryURL: URL
    ) -> [URL] {
        package.manifest.outputs.map { output in
            outputDirectoryURL.appendingPathComponent(
                renderPathTemplate(output.pathTemplate),
                isDirectory: output.bundleType.rawValue.hasPrefix("lungfish")
            )
        }
    }

    private func renderPathTemplate(_ template: String) -> String {
        template
            .replacingOccurrences(of: "{outputName}", with: outputName)
            .replacingOccurrences(of: "{{outputName}}", with: outputName)
    }

    private static let ontGenotypingID = "builtin.ont-genotyping"
    private static let fullLengthONTMHCGenotypingID = WorkflowLibraryCatalog.fullLengthONTMHCGenotypingID
    private static let twelveSAmpliconMatchingID = WorkflowLibraryCatalog.twelveSAmpliconMatchingID
    private static let ontGenotypingResultsDirectoryName = "Amplicon genotyping results"
    private static let fullLengthONTMHCResultsDirectoryName = "Full-length ONT MHC genotyping results"
    private static let twelveSResultsDirectoryName = "12S amplicon results"

    private struct TwelveSReferenceInput {
        let fasta: URL
        let metadata: URL?
        let bundle: URL?
    }

    private static func defaultHaplotypeAssayID() -> String? {
        // Definitions now come exclusively from project `.lungfishmhcref` bundles
        // (built-in/global scopes were removed), so there is no compiled-in assay to
        // pre-select. The assay is resolved from the chosen bundle/definition instead.
        nil
    }

    private static func ontGenotypingBundleURL(
        outputLocationURL: URL,
        outputName: String
    ) -> URL {
        genotypeBundleURL(outputLocationURL: outputLocationURL, outputName: outputName)
    }

    private static func genotypeBundleURL(
        outputLocationURL: URL,
        outputName: String
    ) -> URL {
        let standardized = outputLocationURL.standardizedFileURL
        if ONTGenotypeResultBundle.isBundleURL(standardized) {
            return standardized
        }
        let stem = sanitizeFilenameStem(outputName)
        return standardized.appendingPathComponent(
            "\(stem).\(ONTGenotypeResultBundle.directoryExtension)",
            isDirectory: true
        )
    }

    private static func defaultOutputDirectory(
        projectURL: URL?,
        toolKind: WorkflowOperationToolKind?
    ) -> URL? {
        guard let projectURL else { return nil }
        let analysesDirectory = projectURL.standardizedFileURL
            .appendingPathComponent("Analyses", isDirectory: true)
        switch toolKind {
        case .ontGenotyping:
            return analysesDirectory.appendingPathComponent(
                ontGenotypingResultsDirectoryName,
                isDirectory: true
            )
        case .fullLengthONTMHCGenotyping:
            return analysesDirectory.appendingPathComponent(
                fullLengthONTMHCResultsDirectoryName,
                isDirectory: true
            )
        case .twelveSAmpliconMatching:
            return analysesDirectory.appendingPathComponent(
                twelveSResultsDirectoryName,
                isDirectory: true
            )
        case .workflowPackage:
            return analysesDirectory
        case nil:
            return analysesDirectory
        }
    }

    private static func makeTools(
        enablementStore: WorkflowLibraryEnablementStore,
        packages: [WorkflowPackageValidationResult]
    ) -> [WorkflowOperationTool] {
        var tools: [WorkflowOperationTool] = []
        if let ont = WorkflowLibraryCatalog.item(for: .ontGenotyping) {
            tools.append(WorkflowOperationTool(
                id: ontGenotypingID,
                title: ont.title,
                subtitle: ont.subtitle,
                kind: .ontGenotyping,
                availability: enablementStore.isWorkflowEnabled(.ontGenotyping)
                    ? .available
                    : .disabled(reason: "Enable in Library")
            ))
        }
        if let fullLengthONTMHC = WorkflowLibraryCatalog.item(id: fullLengthONTMHCGenotypingID) {
            tools.append(WorkflowOperationTool(
                id: fullLengthONTMHCGenotypingID,
                title: fullLengthONTMHC.title,
                subtitle: fullLengthONTMHC.subtitle,
                kind: .fullLengthONTMHCGenotyping,
                availability: enablementStore.isWorkflowEnabled(fullLengthONTMHC)
                    ? .available
                    : .disabled(reason: "Enable in Library")
            ))
        }
        if let twelveS = WorkflowLibraryCatalog.item(id: twelveSAmpliconMatchingID) {
            tools.append(WorkflowOperationTool(
                id: twelveSAmpliconMatchingID,
                title: twelveS.title,
                subtitle: twelveS.subtitle,
                kind: .twelveSAmpliconMatching,
                availability: enablementStore.isWorkflowEnabled(twelveS)
                    ? .available
                    : .disabled(reason: "Enable in Library")
            ))
        }

        tools += packages.map { package in
            let enabled = enablementStore.isUserWorkflowEnabled(package)
            let runnable = packageIsRunnable(package)
            return WorkflowOperationTool(
                id: "package.\(package.manifest.id)",
                title: package.manifest.name,
                subtitle: package.manifest.description ?? "User workflow package",
                kind: .workflowPackage(package),
                availability: enabled && runnable
                    ? .available
                    : .disabled(reason: runnable ? "Enable in Library" : "Unsupported")
            )
        }
        return tools
    }

    private static func packageIsRunnable(_ package: WorkflowPackageValidationResult) -> Bool {
        package.supportsWorkflowLibraryExecution
    }

    nonisolated private static func projectDiscoverySnapshot(
        projectURL: URL?
    ) -> WorkflowOperationProjectDiscoverySnapshot {
        let referenceCandidates = discoverReferenceBundles(in: projectURL)
        guard !Task.isCancelled else { return .empty }
        let haplotypeRecords = loadHaplotypeRecords(projectURL: projectURL)
        guard !Task.isCancelled else { return .empty }
        return WorkflowOperationProjectDiscoverySnapshot(
            referenceCandidates: referenceCandidates,
            guideCandidates: discoverGuideBundles(from: referenceCandidates, relativeTo: projectURL),
            barcodeDefinitionCandidates: discoverBarcodeDefinitionFiles(in: projectURL),
            haplotypeRecords: haplotypeRecords,
            referenceBundleSummaries: referenceBundleSummaries(from: haplotypeRecords),
            bundledHaplotypeDefinitions: bundledHaplotypeDefinitions(from: referenceCandidates),
            fullLengthOrientReferenceURL: defaultFullLengthPrimerReferenceURL(
                filename: "MHC_class_I_orient.fasta",
                projectURL: projectURL
            ),
            fullLengthForwardPrimerURL: defaultFullLengthPrimerReferenceURL(
                filename: "MHC_class_I_F.fasta",
                projectURL: projectURL
            ),
            fullLengthReversePrimerURL: defaultFullLengthPrimerReferenceURL(
                filename: "MHC_class_I_R.fasta",
                projectURL: projectURL
            )
        )
    }

    nonisolated private static func loadHaplotypeRecords(projectURL: URL?) -> [HaplotypeDefinitionRecord] {
        HaplotypeDefinitionLibrary(projectRoot: projectURL).records(includeReferenceBundles: true)
    }

    private static func makeHaplotypeRegistry(
        from records: [HaplotypeDefinitionRecord]
    ) -> GenotypeHaplotypeDefinitionRegistry {
        let activeRecords = records.filter { !$0.isShadowed }
        let groupedRecords = Dictionary(grouping: activeRecords, by: { $0.definitionSet.assayID })
        let assays = groupedRecords.keys.sorted().map { assayID in
            let recordsForAssay = groupedRecords[assayID] ?? []
            return GenotypeHaplotypeAssay(
                id: assayID,
                displayName: recordsForAssay.first?.assayDisplayName ?? assayID,
                definitionSets: recordsForAssay.map(\.definitionSet).sorted {
                    $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending
                }
            )
        }
        return GenotypeHaplotypeDefinitionRegistry(
            assays: assays,
            defaultDefinitionSetID: nil
        )
    }

    nonisolated private static func referenceBundleSummaries(
        from records: [HaplotypeDefinitionRecord]
    ) -> [URL: String] {
        var summaries: [URL: String] = [:]
        for bundleURL in records.compactMap(\.referenceBundleURL) where summaries[bundleURL] == nil {
            summaries[bundleURL] = referenceBundleSummary(for: bundleURL)
        }
        return summaries
    }

    nonisolated private static func referenceBundleSummary(for bundleURL: URL) -> String? {
        guard let manifest = try? MHCAmpliconReferenceBundle.loadManifest(from: bundleURL) else {
            return nil
        }
        return "From bundle: \(manifest.name)"
    }

    nonisolated private static func bundledHaplotypeDefinitions(
        from referenceCandidates: [URL]
    ) -> [URL: GenotypeHaplotypeDefinitionSet] {
        var definitions: [URL: GenotypeHaplotypeDefinitionSet] = [:]
        for url in referenceCandidates where MHCAmpliconReferenceBundle.isBundleURL(url) {
            guard !Task.isCancelled else { return definitions }
            let bundleURL = url.standardizedFileURL
            if let definition = try? MHCAmpliconReferenceBundle.defaultHaplotypeDefinition(in: bundleURL) {
                definitions[bundleURL] = definition
            }
        }
        return definitions
    }

    nonisolated private static func discoverReferenceBundles(in projectURL: URL?) -> [URL] {
        guard let projectURL else { return [] }
        guard let enumerator = FileManager.default.enumerator(
            at: projectURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }
        var refs: [URL] = []
        let referenceBundleExtensions = Set([
            "lungfishref",
            TwelveSReferenceBundle.directoryExtension,
            MHCAmpliconReferenceBundle.directoryExtension,
        ])
        for case let url as URL in enumerator {
            guard !Task.isCancelled else { return refs }
            guard referenceBundleExtensions.contains(url.pathExtension.lowercased()) else { continue }
            refs.append(url.standardizedFileURL)
            enumerator.skipDescendants()
        }
        return refs.sorted {
            displayPath(for: $0, relativeTo: projectURL)
                .localizedStandardCompare(displayPath(for: $1, relativeTo: projectURL)) == .orderedAscending
        }
    }

    nonisolated private static func discoverGuideBundles(from referenceCandidates: [URL], relativeTo projectURL: URL?) -> [URL] {
        referenceCandidates
            .filter { $0.pathExtension.lowercased() == "lungfishref" }
            .sorted { lhs, rhs in
                let lhsLikelyGuide = isLikelyPBAAGuideBundle(lhs)
                let rhsLikelyGuide = isLikelyPBAAGuideBundle(rhs)
                if lhsLikelyGuide != rhsLikelyGuide {
                    return lhsLikelyGuide
                }
                return displayPath(for: lhs, relativeTo: projectURL)
                    .localizedStandardCompare(displayPath(for: rhs, relativeTo: projectURL)) == .orderedAscending
            }
    }

    nonisolated private static func isLikelyPBAAGuideBundle(_ url: URL) -> Bool {
        let name = url.deletingPathExtension().lastPathComponent.lowercased()
        return name.contains("guide") || name.contains("pbaa")
    }

    private static func isTwelveSReferenceFASTA(_ url: URL) -> Bool {
        let lowercasedName = url.lastPathComponent.lowercased()
        let fastaExtensions = ["fa", "fasta", "fna", "fas"]
        if fastaExtensions.contains(url.pathExtension.lowercased()) {
            return true
        }
        return fastaExtensions.contains { lowercasedName.hasSuffix(".\($0).gz") }
    }

    private static func twelveSReferenceInput(for url: URL) -> TwelveSReferenceInput? {
        let standardizedURL = url.standardizedFileURL
        if isTwelveSReferenceFASTA(standardizedURL) {
            return TwelveSReferenceInput(fasta: standardizedURL, metadata: nil, bundle: nil)
        }
        if TwelveSReferenceBundle.isBundleURL(standardizedURL),
           let fastaURL = TwelveSReferenceBundle.referenceFASTAURL(in: standardizedURL) {
            return TwelveSReferenceInput(
                fasta: fastaURL.standardizedFileURL,
                metadata: TwelveSReferenceBundle.targetMetadataURL(in: standardizedURL)?.standardizedFileURL,
                bundle: standardizedURL
            )
        }
        guard standardizedURL.pathExtension.lowercased() == "lungfishref" else {
            return nil
        }
        if let fastaURL = ReferenceSequenceFolder.fastaURL(in: standardizedURL) {
            return TwelveSReferenceInput(fasta: fastaURL.standardizedFileURL, metadata: nil, bundle: nil)
        }
        guard let manifest = try? BundleManifest.load(from: standardizedURL),
              let genomePath = manifest.genome?.path else {
            return nil
        }
        let fastaURL = standardizedURL.appendingPathComponent(genomePath).standardizedFileURL
        return FileManager.default.fileExists(atPath: fastaURL.path)
            ? TwelveSReferenceInput(fasta: fastaURL, metadata: nil, bundle: nil)
            : nil
    }

    nonisolated private static func discoverBarcodeDefinitionFiles(in projectURL: URL?) -> [URL] {
        guard let projectURL else { return [] }
        let allowedExtensions = Set(["csv", "tsv", "txt"])
        guard let enumerator = FileManager.default.enumerator(
            at: projectURL,
            includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey],
            options: [.skipsPackageDescendants]
        ) else {
            return []
        }

        var candidates: [URL] = []
        for case let url as URL in enumerator {
            guard !Task.isCancelled else { return candidates }
            let name = url.lastPathComponent
            if name.hasPrefix(".") {
                if (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                    enumerator.skipDescendants()
                }
                continue
            }
            if url.pathExtension.lowercased().hasPrefix("lungfish") {
                enumerator.skipDescendants()
                continue
            }
            guard allowedExtensions.contains(url.pathExtension.lowercased()),
                  (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else {
                continue
            }
            candidates.append(url.standardizedFileURL)
        }
        return candidates.sorted {
            displayPath(for: $0, relativeTo: projectURL)
                .localizedStandardCompare(displayPath(for: $1, relativeTo: projectURL)) == .orderedAscending
        }
    }

    private static func uniqueBarcodeDefinitionImportURL(
        for sourceURL: URL,
        in directoryURL: URL
    ) throws -> URL {
        let sourceExtension = sourceURL.pathExtension.lowercased()
        let sourceStem = sourceURL.deletingPathExtension().lastPathComponent
        let sanitizedStem = sanitizeFilenameStem(sourceStem)
        let baseName = sourceExtension.isEmpty ? sanitizedStem : "\(sanitizedStem).\(sourceExtension)"
        let firstCandidate = directoryURL.appendingPathComponent(baseName)
        if try candidate(firstCandidate, matchesSource: sourceURL) {
            return firstCandidate.standardizedFileURL
        }

        var suffix = 2
        while true {
            let candidateName = sourceExtension.isEmpty
                ? "\(sanitizedStem)-\(suffix)"
                : "\(sanitizedStem)-\(suffix).\(sourceExtension)"
            let candidateURL = directoryURL.appendingPathComponent(candidateName)
            if try candidate(candidateURL, matchesSource: sourceURL) {
                return candidateURL.standardizedFileURL
            }
            suffix += 1
        }
    }

    private static func candidate(_ candidateURL: URL, matchesSource sourceURL: URL) throws -> Bool {
        guard FileManager.default.fileExists(atPath: candidateURL.path) else {
            return true
        }
        return try ProvenanceFileHasher.sha256(of: candidateURL) == ProvenanceFileHasher.sha256(of: sourceURL)
    }

    private static func barcodeDefinitionFileFormat(for url: URL) -> FileFormat {
        switch url.pathExtension.lowercased() {
        case "csv", "tsv", "txt":
            return .text
        default:
            return .unknown
        }
    }

    private static func isURL(_ url: URL, inside projectURL: URL) -> Bool {
        let targetPath = url.standardizedFileURL.path
        let projectPath = projectURL.standardizedFileURL.path
        if targetPath == projectPath { return true }
        let normalizedProjectPath = projectPath.hasSuffix("/") ? projectPath : projectPath + "/"
        return targetPath.hasPrefix(normalizedProjectPath)
    }

    nonisolated static func displayPath(for url: URL, relativeTo projectURL: URL?) -> String {
        let targetPath = url.standardizedFileURL.path
        guard let projectURL else { return targetPath }
        let projectPath = projectURL.standardizedFileURL.path
        let normalizedProjectPath = projectPath.hasSuffix("/") ? projectPath : projectPath + "/"
        guard targetPath.hasPrefix(normalizedProjectPath) else { return targetPath }
        return String(targetPath.dropFirst(normalizedProjectPath.count))
    }

    private static func deduplicated(_ urls: [URL]) -> [URL] {
        var seen = Set<String>()
        return urls.filter { url in
            seen.insert(url.standardizedFileURL.path).inserted
        }
    }

    private static func defaultONTGenotypingOutputName(for selectedReadURLs: [URL]) -> String {
        "amplicon-genotyping"
    }

    private static func defaultFullLengthONTMHCOutputName(for selectedReadURLs: [URL]) -> String {
        guard selectedReadURLs.count == 1,
              let stem = selectedReadURLs.first?.deletingPathExtension().lastPathComponent,
              !stem.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return "full-length-ont-mhc-genotyping"
        }
        return "\(sanitizeFilenameStem(stem))-full-length-ont-mhc"
    }

    private static func defaultTwelveSOutputName(for selectedReadURLs: [URL]) -> String {
        guard let stem = selectedReadURLs.first?.deletingPathExtension().lastPathComponent,
              !stem.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return "12s-amplicons"
        }
        return "\(sanitizeFilenameStem(stem))-12s"
    }

    private static func defaultGenotypingReadType(for selectedReadURLs: [URL]) -> AmpliconGenotypingReadType {
        let readTypes = Set(selectedReadURLs.compactMap(genotypingReadTypeFromFASTQMetadata))
        if readTypes.count == 1, let readType = readTypes.first {
            return readType
        }
        return .auto
    }

    private static func genotypingReadTypeFromFASTQMetadata(_ url: URL) -> AmpliconGenotypingReadType? {
        let bundleURL: URL
        if FASTQBundle.isBundleURL(url) {
            bundleURL = url.standardizedFileURL
        } else if let enclosingBundle = SequenceInputResolver.enclosingFASTQBundleURL(for: url) {
            bundleURL = enclosingBundle.standardizedFileURL
        } else {
            return nil
        }
        guard let fastqURL = FASTQBundle.resolvePrimaryFASTQURL(for: bundleURL),
              let metadata = FASTQMetadataStore.load(for: fastqURL) else {
            return nil
        }
        if let assemblyReadType = metadata.assemblyReadType {
            switch assemblyReadType {
            case .ontReads:
                return .ont
            case .illuminaShortReads:
                return .illumina
            case .pacBioHiFi:
                return nil
            }
        }
        guard let assemblyReadType = metadata.sequencingPlatform.flatMap(FASTQAssemblyReadType.init(sequencingPlatform:)) else {
            return nil
        }
        switch assemblyReadType {
        case .ontReads:
            return .ont
        case .illuminaShortReads:
            return .illumina
        case .pacBioHiFi:
            return nil
        }
    }

    private static func sanitizeFilenameStem(_ value: String) -> String {
        let replaced = value.map { character -> Character in
            character.isLetter || character.isNumber || character == "-" || character == "_" ? character : "-"
        }
        let collapsed = String(replaced)
            .split(separator: "-", omittingEmptySubsequences: true)
            .joined(separator: "-")
        return collapsed.isEmpty ? "ont" : collapsed
    }

    nonisolated private static func defaultFullLengthPrimerReferenceURL(filename: String, projectURL: URL?) -> URL? {
        guard let projectURL else { return nil }
        guard let enumerator = FileManager.default.enumerator(
            at: projectURL,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else {
            return nil
        }
        for case let url as URL in enumerator {
            guard !Task.isCancelled else { return nil }
            guard url.lastPathComponent == filename,
                  (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else {
                continue
            }
            return url.standardizedFileURL
        }
        return nil
    }
}

enum WorkflowOperationError: Error, LocalizedError, Equatable {
    case incompleteConfiguration(String)
    case unsupportedPackage(String)
    case barcodeDefinitionImportFailed(String)

    var errorDescription: String? {
        switch self {
        case .incompleteConfiguration(let reason):
            return reason
        case .unsupportedPackage(let name):
            return "\(name) is not a runnable Nextflow or Snakemake lungfishref/lungfishfastq workflow."
        case .barcodeDefinitionImportFailed(let reason):
            return "Could not import the barcode definition into the project: \(reason)"
        }
    }
}
