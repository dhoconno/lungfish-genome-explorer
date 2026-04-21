import Foundation
import Observation
import LungfishIO
import LungfishWorkflow

@MainActor
@Observable
final class FASTQOperationDialogState {
    private static let mixedDetectedAndUnclassifiedAssemblyInputsMessage =
        "Selected FASTQ inputs mix detected and unclassified read classes. Select one read class per run."

    var selectedCategory: FASTQOperationCategoryID {
        didSet {
            if selectedToolID.categoryID != selectedCategory {
                selectedToolID = selectedCategory.defaultToolID
                return
            }

            normalizeSelectionState()
        }
    }

    var selectedToolID: FASTQOperationToolID {
        didSet {
            if selectedCategory != selectedToolID.categoryID {
                selectedCategory = selectedToolID.categoryID
                return
            }

            normalizeSelectionState()
        }
    }

    var selectedInputURLs: [URL]
    var auxiliaryInputs: [FASTQOperationInputKind: URL]
    var outputMode: FASTQOperationOutputMode {
        didSet {
            normalizeOutputMode()
        }
    }
    var embeddedRunTrigger: Int
    var projectURL: URL?
    var outputDirectoryURL: URL?
    var pendingLaunchRequest: FASTQOperationLaunchRequest?
    var pendingMinimap2Config: Minimap2Config?
    var pendingMappingRequest: MappingRunRequest?
    var pendingAssemblyRequest: AssemblyRunRequest?
    var pendingClassificationConfigs: [ClassificationConfig]
    var pendingEsVirituConfigs: [EsVirituConfig]
    var pendingTaxTriageConfig: TaxTriageConfig?

    // Honest derivative-tool state surfaced by the modal.
    var qualityTrimThreshold: Int
    var qualityTrimWindowSize: Int
    var qualityTrimMode: FASTQQualityTrimMode

    var adapterRemovalMode: FASTQAdapterMode
    var adapterRemovalSequence: String

    var primerTrimmingSource: FASTQPrimerSource
    var primerTrimmingLiteralSequence: String
    var primerTrimmingReferencePath: String
    var primerTrimmingKmerSize: Int
    var primerTrimmingMinKmer: Int
    var primerTrimmingHammingDistance: Int

    var trimFixedBasesFrom5Prime: Int
    var trimFixedBasesFrom3Prime: Int

    var filterByReadLengthMin: Int?
    var filterByReadLengthMax: Int?

    var removeContaminantsMode: FASTQContaminantFilterMode
    var removeContaminantsKmerSize: Int
    var removeContaminantsHammingDistance: Int

    var removeDuplicatesPreset: FASTQDeduplicatePreset
    var removeDuplicatesSubstitutions: Int
    var removeDuplicatesOptical: Bool
    var removeDuplicatesOpticalDistance: Int

    var mergeOverlappingPairsStrictness: FASTQMergeStrictness
    var mergeOverlappingPairsMinOverlap: Int

    var correctSequencingErrorsKmerSize: Int

    var orientWordLength: Int
    var orientDbMask: String

    var subsampleByProportionValue: Double?
    var subsampleByCountValue: Int?

    var extractReadsByIDQuery: String
    var extractReadsByIDField: FASTQSearchField
    var extractReadsByIDRegex: Bool

    var extractReadsByMotifPattern: String
    var extractReadsByMotifRegex: Bool

    var selectReadsBySequenceValue: String
    var selectReadsBySequenceSearchEnd: FASTQAdapterSearchEnd
    var selectReadsBySequenceMinOverlap: Int
    var selectReadsBySequenceErrorRate: Double
    var selectReadsBySequenceKeepMatched: Bool
    var selectReadsBySequenceSearchReverseComplement: Bool

    var demultiplexBarcodeSource: FASTQDemultiplexBarcodeSource
    var demultiplexKitID: String
    var demultiplexCustomCSVPath: String
    var demultiplexLocation: String
    var demultiplexMaxDistanceFrom5Prime: Int
    var demultiplexMaxDistanceFrom3Prime: Int
    var demultiplexErrorRate: Double
    var demultiplexTrimBarcodes: Bool

    private var embeddedToolReady: Bool

    init(
        initialCategory: FASTQOperationCategoryID,
        selectedInputURLs: [URL],
        projectURL: URL? = DocumentManager.shared.activeProject?.url
    ) {
        let defaultToolID = initialCategory.defaultToolID
        self.selectedCategory = initialCategory
        self.selectedToolID = defaultToolID
        self.selectedInputURLs = selectedInputURLs
        self.auxiliaryInputs = [:]
        self.outputMode = defaultToolID.defaultOutputMode
        self.embeddedRunTrigger = 0
        self.projectURL = projectURL
        self.outputDirectoryURL = Self.defaultOutputDirectory(
            projectURL: projectURL,
            selectedInputURLs: selectedInputURLs
        )
        self.pendingLaunchRequest = nil
        self.pendingMinimap2Config = nil
        self.pendingMappingRequest = nil
        self.pendingAssemblyRequest = nil
        self.pendingClassificationConfigs = []
        self.pendingEsVirituConfigs = []
        self.pendingTaxTriageConfig = nil
        self.qualityTrimThreshold = 20
        self.qualityTrimWindowSize = 4
        self.qualityTrimMode = .cutRight
        self.adapterRemovalMode = .autoDetect
        self.adapterRemovalSequence = ""
        self.primerTrimmingSource = .literal
        self.primerTrimmingLiteralSequence = ""
        self.primerTrimmingReferencePath = ""
        self.primerTrimmingKmerSize = 15
        self.primerTrimmingMinKmer = 11
        self.primerTrimmingHammingDistance = 1
        self.trimFixedBasesFrom5Prime = 0
        self.trimFixedBasesFrom3Prime = 0
        self.filterByReadLengthMin = nil
        self.filterByReadLengthMax = nil
        self.removeContaminantsMode = .phix
        self.removeContaminantsKmerSize = 31
        self.removeContaminantsHammingDistance = 1
        self.removeDuplicatesPreset = .exactPCR
        self.removeDuplicatesSubstitutions = 0
        self.removeDuplicatesOptical = false
        self.removeDuplicatesOpticalDistance = 40
        self.mergeOverlappingPairsStrictness = .normal
        self.mergeOverlappingPairsMinOverlap = 12
        self.correctSequencingErrorsKmerSize = 50
        self.orientWordLength = 12
        self.orientDbMask = "dust"
        self.subsampleByProportionValue = nil
        self.subsampleByCountValue = nil
        self.extractReadsByIDQuery = ""
        self.extractReadsByIDField = .id
        self.extractReadsByIDRegex = false
        self.extractReadsByMotifPattern = ""
        self.extractReadsByMotifRegex = false
        self.selectReadsBySequenceValue = ""
        self.selectReadsBySequenceSearchEnd = .fivePrime
        self.selectReadsBySequenceMinOverlap = 16
        self.selectReadsBySequenceErrorRate = 0.15
        self.selectReadsBySequenceKeepMatched = true
        self.selectReadsBySequenceSearchReverseComplement = false
        self.demultiplexBarcodeSource = .builtinKit
        self.demultiplexKitID = BarcodeKitRegistry.builtinKits().first?.id ?? ""
        self.demultiplexCustomCSVPath = ""
        self.demultiplexLocation = "bothends"
        self.demultiplexMaxDistanceFrom5Prime = 0
        self.demultiplexMaxDistanceFrom3Prime = 0
        self.demultiplexErrorRate = 0.15
        self.demultiplexTrimBarcodes = true
        self.embeddedToolReady = defaultToolID.defaultEmbeddedReadiness

        if initialCategory == .assembly {
            self.selectedToolID = Self.defaultAssemblyTool(for: self.detectedAssemblyReadType)
        }
    }

    func selectCategory(_ category: FASTQOperationCategoryID) {
        selectedCategory = category
        if category == .assembly {
            selectedToolID = Self.defaultAssemblyTool(for: detectedAssemblyReadType)
        } else {
            selectedToolID = category.defaultToolID
        }
        normalizeSelectionState()
    }

    func selectTool(_ toolID: FASTQOperationToolID) {
        guard selectedToolID != toolID else { return }
        selectedCategory = toolID.categoryID
        selectedToolID = toolID
        normalizeSelectionState()
    }

    func setAuxiliaryInput(_ url: URL, for kind: FASTQOperationInputKind) {
        auxiliaryInputs[kind] = url.standardizedFileURL
    }

    func removeAuxiliaryInput(for kind: FASTQOperationInputKind) {
        auxiliaryInputs.removeValue(forKey: kind)
    }

    func auxiliaryInputURL(for kind: FASTQOperationInputKind) -> URL? {
        auxiliaryInputs[kind]
    }

    func isAuxiliaryInputValid(for kind: FASTQOperationInputKind) -> Bool {
        guard let url = auxiliaryInputs[kind] else { return false }
        return kind.accepts(url: url)
    }

    func updateEmbeddedReadiness(_ ready: Bool) {
        embeddedToolReady = ready
    }

    func prepareForRun() {
        if selectedToolID.usesEmbeddedConfiguration {
            pendingLaunchRequest = nil
            embeddedRunTrigger += 1
            return
        }

        pendingMinimap2Config = nil
        pendingMappingRequest = nil
        pendingAssemblyRequest = nil
        pendingClassificationConfigs = []
        pendingEsVirituConfigs = []
        pendingTaxTriageConfig = nil
        pendingLaunchRequest = launchRequestForSelectedTool()
    }

    private func launchRequestForSelectedTool() -> FASTQOperationLaunchRequest? {
        switch selectedToolID {
        case .refreshQCSummary:
            return .refreshQCSummary(inputURLs: selectedInputURLs)

        case .demultiplexBarcodes:
            let customCSVPath = selectedBarcodeDefinitionPath
            let kitID = demultiplexBarcodeSource == .customDefinition
                ? customCSVPath.map { URL(fileURLWithPath: $0).deletingPathExtension().lastPathComponent }
                : trimmedNonEmpty(demultiplexKitID)
            guard let kitID else { return nil }
            return .derivative(
                request: .demultiplex(
                    kitID: kitID,
                    customCSVPath: demultiplexBarcodeSource == .customDefinition ? customCSVPath : nil,
                    location: demultiplexLocation,
                    symmetryMode: nil,
                    maxDistanceFrom5Prime: demultiplexMaxDistanceFrom5Prime,
                    maxDistanceFrom3Prime: demultiplexMaxDistanceFrom3Prime,
                    errorRate: demultiplexErrorRate,
                    trimBarcodes: demultiplexTrimBarcodes,
                    sampleAssignments: nil,
                    kitOverride: nil
                ),
                inputURLs: selectedInputURLs,
                outputMode: outputMode
            )

        case .qualityTrim:
            guard qualityTrimThreshold > 0, qualityTrimWindowSize > 0 else { return nil }
            return .derivative(
                request: .qualityTrim(
                    threshold: qualityTrimThreshold,
                    windowSize: qualityTrimWindowSize,
                    mode: qualityTrimMode
                ),
                inputURLs: selectedInputURLs,
                outputMode: outputMode
            )

        case .adapterRemoval:
            let sequence = trimmedNonEmpty(adapterRemovalSequence)
            if adapterRemovalMode == .specified, sequence == nil {
                return nil
            }
            return .derivative(
                request: .adapterTrim(
                    mode: adapterRemovalMode,
                    sequence: adapterRemovalMode == .specified ? sequence : nil,
                    sequenceR2: nil,
                    fastaFilename: nil
                ),
                inputURLs: selectedInputURLs,
                outputMode: outputMode
            )

        case .primerTrimming:
            let literalSequence = trimmedNonEmpty(primerTrimmingLiteralSequence)
            let referencePath = selectedPrimerReferencePath
            switch primerTrimmingSource {
            case .literal where literalSequence == nil:
                return nil
            case .reference where referencePath == nil:
                return nil
            default:
                break
            }
            return .derivative(
                request: .primerRemoval(configuration: FASTQPrimerTrimConfiguration(
                    source: primerTrimmingSource,
                    forwardSequence: primerTrimmingSource == .literal ? literalSequence : nil,
                    referenceFasta: primerTrimmingSource == .reference ? referencePath : nil,
                    tool: .bbduk,
                    kmerSize: primerTrimmingKmerSize,
                    minKmer: primerTrimmingMinKmer,
                    hammingDistance: primerTrimmingHammingDistance
                )),
                inputURLs: selectedInputURLs,
                outputMode: outputMode
            )

        case .trimFixedBases:
            guard trimFixedBasesFrom5Prime > 0 || trimFixedBasesFrom3Prime > 0 else { return nil }
            return .derivative(
                request: .fixedTrim(
                    from5Prime: trimFixedBasesFrom5Prime,
                    from3Prime: trimFixedBasesFrom3Prime
                ),
                inputURLs: selectedInputURLs,
                outputMode: outputMode
            )

        case .filterByReadLength:
            guard filterByReadLengthMin != nil || filterByReadLengthMax != nil else { return nil }
            if let min = filterByReadLengthMin, let max = filterByReadLengthMax, min > max {
                return nil
            }
            return .derivative(
                request: .lengthFilter(min: filterByReadLengthMin, max: filterByReadLengthMax),
                inputURLs: selectedInputURLs,
                outputMode: outputMode
            )

        case .removeHumanReads:
            return .derivative(
                request: .humanReadScrub(
                    databaseID: auxiliaryInputURL(for: .database)?.deletingPathExtension().lastPathComponent
                        ?? DeaconPanhumanDatabaseInstaller.databaseID,
                    removeReads: true
                ),
                inputURLs: selectedInputURLs,
                outputMode: outputMode
            )

        case .removeContaminants:
            return .derivative(
                request: .contaminantFilter(
                    mode: removeContaminantsMode,
                    referenceFasta: removeContaminantsMode == .custom ? auxiliaryInputURL(for: .contaminantReference)?.path : nil,
                    kmerSize: removeContaminantsKmerSize,
                    hammingDistance: removeContaminantsHammingDistance
                ),
                inputURLs: selectedInputURLs,
                outputMode: outputMode
            )

        case .removeDuplicates:
            let deduplicateParameters = resolvedDeduplicateParameters()
            return .derivative(
                request: .deduplicate(
                    preset: removeDuplicatesPreset,
                    substitutions: deduplicateParameters.substitutions,
                    optical: deduplicateParameters.optical,
                    opticalDistance: deduplicateParameters.opticalDistance
                ),
                inputURLs: selectedInputURLs,
                outputMode: outputMode
            )

        case .mergeOverlappingPairs:
            return .derivative(
                request: .pairedEndMerge(
                    strictness: mergeOverlappingPairsStrictness,
                    minOverlap: mergeOverlappingPairsMinOverlap
                ),
                inputURLs: selectedInputURLs,
                outputMode: outputMode
            )

        case .repairPairedEndFiles:
            return .derivative(
                request: .pairedEndRepair,
                inputURLs: selectedInputURLs,
                outputMode: outputMode
            )

        case .orientReads:
            guard let referenceURL = auxiliaryInputURL(for: .referenceSequence) else { return nil }
            return .derivative(
                request: .orient(
                    referenceURL: referenceURL,
                    wordLength: orientWordLength,
                    dbMask: orientDbMask,
                    saveUnoriented: false
                ),
                inputURLs: selectedInputURLs,
                outputMode: outputMode
            )

        case .correctSequencingErrors:
            return .derivative(
                request: .errorCorrection(kmerSize: correctSequencingErrorsKmerSize),
                inputURLs: selectedInputURLs,
                outputMode: outputMode
            )

        case .subsampleByProportion:
            guard let subsampleByProportionValue, subsampleByProportionValue > 0, subsampleByProportionValue <= 1 else {
                return nil
            }
            return .derivative(
                request: .subsampleProportion(subsampleByProportionValue),
                inputURLs: selectedInputURLs,
                outputMode: outputMode
            )

        case .subsampleByCount:
            guard let subsampleByCountValue, subsampleByCountValue > 0 else {
                return nil
            }
            return .derivative(
                request: .subsampleCount(subsampleByCountValue),
                inputURLs: selectedInputURLs,
                outputMode: outputMode
            )

        case .extractReadsByID:
            let query = trimmedNonEmpty(extractReadsByIDQuery)
            guard let query else { return nil }
            return .derivative(
                request: .searchText(query: query, field: extractReadsByIDField, regex: extractReadsByIDRegex),
                inputURLs: selectedInputURLs,
                outputMode: outputMode
            )

        case .extractReadsByMotif:
            let pattern = trimmedNonEmpty(extractReadsByMotifPattern)
            guard let pattern else { return nil }
            return .derivative(
                request: .searchMotif(pattern: pattern, regex: extractReadsByMotifRegex),
                inputURLs: selectedInputURLs,
                outputMode: outputMode
            )

        case .selectReadsBySequence:
            let sequence = trimmedNonEmpty(selectReadsBySequenceValue)
            guard let sequence else { return nil }
            let fastaPath = isPathLikeSequenceFilterValue(sequence) ? sequence : nil
            return .derivative(
                request: .sequencePresenceFilter(
                    sequence: fastaPath == nil ? sequence : nil,
                    fastaPath: fastaPath,
                    searchEnd: selectReadsBySequenceSearchEnd,
                    minOverlap: selectReadsBySequenceMinOverlap,
                    errorRate: selectReadsBySequenceErrorRate,
                    keepMatched: selectReadsBySequenceKeepMatched,
                    searchReverseComplement: selectReadsBySequenceSearchReverseComplement
                ),
                inputURLs: selectedInputURLs,
                outputMode: outputMode
            )

        case .minimap2, .bwaMem2, .bowtie2, .bbmap, .spades, .megahit, .skesa, .flye, .hifiasm, .kraken2, .esViritu, .taxTriage:
            return nil
        }
    }

    func captureMinimap2Config(_ config: Minimap2Config) {
        setAuxiliaryInput(config.referenceURL, for: .referenceSequence)
        pendingMinimap2Config = config
        pendingMappingRequest = nil
        pendingAssemblyRequest = nil
        pendingClassificationConfigs = []
        pendingEsVirituConfigs = []
        pendingTaxTriageConfig = nil
        pendingLaunchRequest = .map(
            inputURLs: config.inputFiles,
            referenceURL: config.referenceURL,
            outputMode: outputMode
        )
        embeddedToolReady = true
    }

    func captureMappingRequest(_ request: MappingRunRequest) {
        setAuxiliaryInput(request.referenceFASTAURL, for: .referenceSequence)
        pendingMinimap2Config = nil
        pendingMappingRequest = request
        pendingAssemblyRequest = nil
        pendingClassificationConfigs = []
        pendingEsVirituConfigs = []
        pendingTaxTriageConfig = nil
        pendingLaunchRequest = .map(
            inputURLs: request.inputFASTQURLs,
            referenceURL: request.referenceFASTAURL,
            outputMode: outputMode
        )
        embeddedToolReady = true
    }

    func captureAssemblyRequest(_ request: AssemblyRunRequest) {
        outputDirectoryURL = request.outputDirectory
        pendingMinimap2Config = nil
        pendingMappingRequest = nil
        pendingAssemblyRequest = request
        pendingClassificationConfigs = []
        pendingEsVirituConfigs = []
        pendingTaxTriageConfig = nil
        pendingLaunchRequest = .assemble(
            request: request,
            outputMode: outputMode
        )
        embeddedToolReady = true
    }

    func captureAssemblyWizardConfig(_ config: SPAdesAssemblyConfig) {
        guard let request = assemblyRequest(from: config) else { return }
        captureAssemblyRequest(request)
    }

    func captureClassificationConfigs(_ configs: [ClassificationConfig]) {
        guard let first = configs.first else { return }
        setAuxiliaryInput(first.databasePath, for: .database)
        pendingMinimap2Config = nil
        pendingMappingRequest = nil
        pendingAssemblyRequest = nil
        pendingClassificationConfigs = configs
        pendingEsVirituConfigs = []
        pendingTaxTriageConfig = nil
        pendingLaunchRequest = .classify(
            tool: .kraken2,
            inputURLs: configs.flatMap(\.inputFiles),
            databaseName: first.databaseName
        )
        embeddedToolReady = true
    }

    func captureEsVirituConfigs(_ configs: [EsVirituConfig]) {
        guard let first = configs.first else { return }
        setAuxiliaryInput(first.databasePath, for: .database)
        pendingMinimap2Config = nil
        pendingMappingRequest = nil
        pendingAssemblyRequest = nil
        pendingClassificationConfigs = []
        pendingEsVirituConfigs = configs
        pendingTaxTriageConfig = nil
        pendingLaunchRequest = .classify(
            tool: .esViritu,
            inputURLs: configs.flatMap(\.inputFiles),
            databaseName: first.databasePath.lastPathComponent
        )
        embeddedToolReady = true
    }

    func captureTaxTriageConfig(_ config: TaxTriageConfig) {
        if let databasePath = config.kraken2DatabasePath {
            setAuxiliaryInput(databasePath, for: .database)
        }
        pendingMinimap2Config = nil
        pendingMappingRequest = nil
        pendingAssemblyRequest = nil
        pendingClassificationConfigs = []
        pendingEsVirituConfigs = []
        pendingTaxTriageConfig = config
        pendingLaunchRequest = .classify(
            tool: .taxTriage,
            inputURLs: config.samples.flatMap { sample in
                [sample.fastq1] + (sample.fastq2.map { [$0] } ?? [])
            },
            databaseName: config.kraken2DatabasePath?.lastPathComponent ?? ""
        )
        embeddedToolReady = true
    }

    var visibleSections: [DatasetOperationSection] {
        var sections: [DatasetOperationSection] = [.inputs, .primarySettings, .advancedSettings]
        if showsOutputStrategyPicker {
            sections.append(.output)
        }
        sections.append(.readiness)
        return sections
    }

    var inputSectionTitle: String {
        DatasetOperationSection.inputs.title
    }

    var outputSectionTitle: String {
        DatasetOperationSection.output.title
    }

    var readinessText: String {
        if selectedInputURLs.isEmpty {
            return "Select at least one \(inputDatasetDisplayName) dataset."
        }

        if let missingKind = missingRequiredAuxiliaryInputKinds.first {
            return missingKind.missingSelectionText
        }

        if let configurationMessage = selectedToolConfigurationReadinessText {
            return configurationMessage
        }

        if !embeddedToolReady {
            return selectedToolID.embeddedReadinessText
        }

        if showsOutputStrategyPicker {
            return "Ready to configure output."
        }

        return "Batch output is fixed for this tool."
    }

    var outputStrategyOptions: [FASTQOperationOutputMode] {
        showsOutputStrategyPicker ? [.perInput, .groupedResult] : [.fixedBatch]
    }

    var showsOutputStrategyPicker: Bool {
        selectedToolID.categoryID != .classification
    }

    var requiredInputKinds: [FASTQOperationInputKind] {
        switch selectedToolID {
        case .primerTrimming:
            return primerTrimmingSource == .reference
                ? [.fastqDataset, .primerSource]
                : [.fastqDataset]
        case .removeContaminants:
            return removeContaminantsMode == .custom
                ? [.fastqDataset, .contaminantReference]
                : [.fastqDataset]
        case .demultiplexBarcodes:
            return demultiplexBarcodeSource == .customDefinition
                ? [.fastqDataset, .barcodeDefinition]
                : [.fastqDataset]
        default:
            return selectedToolID.requiredInputKinds
        }
    }

    var detectedAssemblyReadType: AssemblyReadType? {
        assemblyCompatibilityEvaluation.resolvedReadType
    }

    var assemblyReadClassMismatchMessage: String? {
        assemblyCompatibilityEvaluation.blockingMessage
    }

    var isRunEnabled: Bool {
        !selectedInputURLs.isEmpty
        && missingRequiredAuxiliaryInputKinds.isEmpty
        && selectedToolConfigurationIsReady
        && embeddedToolReady
    }

    var datasetLabel: String {
        let datasetLabel = inputDatasetDisplayName.uppercased()
        switch selectedInputURLs.count {
        case 0:
            return "No \(datasetLabel) selected"
        case 1:
            return selectedInputURLs[0].lastPathComponent
        default:
            return "\(selectedInputURLs.count) \(datasetLabel) datasets"
        }
    }

    var sidebarItems: [DatasetOperationToolSidebarItem] {
        visibleToolIDs(for: selectedCategory).map { toolID in
            toolID.sidebarItem(availability: availability(for: toolID))
        }
    }

    var selectedToolSummary: String {
        switch selectedToolID {
        case .refreshQCSummary:
            return "Recompute the QC summary for the selected FASTQ datasets."
        case .demultiplexBarcodes:
            return "Split pooled reads into sample-specific outputs using a barcode definition."
        case .qualityTrim:
            return "Trim low-quality bases from read ends."
        case .adapterRemoval:
            return "Remove adapter sequence from reads."
        case .primerTrimming:
            return "Trim PCR primer sequences using a literal or reference-backed source."
        case .trimFixedBases:
            return "Remove a fixed number of bases from either end of each read."
        case .filterByReadLength:
            return "Keep reads in the requested length range."
        case .removeHumanReads:
            return "Filter reads that match the configured human database."
        case .removeContaminants:
            return "Filter reads that match a contaminant reference."
        case .removeDuplicates:
            return "Collapse duplicate reads from the selected datasets."
        case .mergeOverlappingPairs:
            return "Merge overlapping paired-end reads."
        case .repairPairedEndFiles:
            return "Repair synchronization issues between paired-end mates."
        case .orientReads:
            return "Orient reads against a required reference sequence."
        case .correctSequencingErrors:
            return "Correct likely sequencing errors before downstream analysis."
        case .subsampleByProportion:
            return "Keep a user-defined fraction of reads."
        case .subsampleByCount:
            return "Keep a fixed number of reads."
        case .extractReadsByID:
            return "Extract reads whose identifiers match the requested values."
        case .extractReadsByMotif:
            return "Extract reads containing the requested motif."
        case .selectReadsBySequence:
            return "Keep reads matching a target sequence."
        case .minimap2:
            return "Configure minimap2 mapping against a reference sequence."
        case .bwaMem2:
            return "Configure BWA-MEM2 short-read mapping against a reference sequence."
        case .bowtie2:
            return "Configure Bowtie2 short-read mapping against a reference sequence."
        case .bbmap:
            return "Configure BBMap reference-guided mapping against a reference sequence."
        case .spades:
            return "Configure a SPAdes assembly run."
        case .megahit:
            return "Configure a MEGAHIT assembly run."
        case .skesa:
            return "Configure a SKESA assembly run."
        case .flye:
            return "Configure a Flye assembly run."
        case .hifiasm:
            return "Configure a Hifiasm assembly run."
        case .kraken2:
            return "Configure Kraken2 classification."
        case .esViritu:
            return "Configure EsViritu viral detection."
        case .taxTriage:
            return "Configure TaxTriage pathogen triage."
        }
    }

    var isFASTAInputMode: Bool {
        guard !selectedInputURLs.isEmpty else { return false }
        return selectedInputURLs.allSatisfy {
            FASTAOperationCatalog.inputSequenceFormat(for: $0) == .fasta
        }
    }

    var dialogTitle: String {
        isFASTAInputMode ? "FASTA Operations" : selectedCategory.title
    }

    var dialogSubtitle: String {
        "Configure \(selectedToolID.title) for the selected \(inputDatasetDisplayName.uppercased()) data."
    }

    var inputDatasetDisplayName: String {
        isFASTAInputMode ? "FASTA" : "FASTQ"
    }

    static func toolIDs(for category: FASTQOperationCategoryID) -> [FASTQOperationToolID] {
        switch category {
        case .qcReporting:
            return [.refreshQCSummary]
        case .demultiplexing:
            return [.demultiplexBarcodes]
        case .trimmingFiltering:
            return [.qualityTrim, .adapterRemoval, .primerTrimming, .trimFixedBases, .filterByReadLength]
        case .decontamination:
            return [.removeHumanReads, .removeContaminants, .removeDuplicates]
        case .readProcessing:
            return [.mergeOverlappingPairs, .repairPairedEndFiles, .orientReads, .correctSequencingErrors]
        case .searchSubsetting:
            return [.subsampleByProportion, .subsampleByCount, .extractReadsByID, .extractReadsByMotif, .selectReadsBySequence]
        case .mapping:
            return [.minimap2, .bwaMem2, .bowtie2, .bbmap]
        case .assembly:
            return [.spades, .megahit, .skesa, .flye, .hifiasm]
        case .classification:
            return [.kraken2, .esViritu, .taxTriage]
        }
    }

    private var missingRequiredAuxiliaryInputKinds: [FASTQOperationInputKind] {
        guard !selectedToolID.usesEmbeddedConfiguration else {
            return []
        }

        return requiredInputKinds.filter { kind in
            kind != .fastqDataset && !isAuxiliaryInputValid(for: kind)
        }
    }

    private var selectedToolConfigurationIsReady: Bool {
        selectedToolConfigurationReadinessText == nil
    }

    private var selectedToolConfigurationReadinessText: String? {
        switch selectedToolID {
        case .qualityTrim:
            guard qualityTrimThreshold > 0, qualityTrimWindowSize > 0 else {
                return "Enter a positive quality threshold and window size."
            }
            return nil

        case .adapterRemoval:
            if adapterRemovalMode == .specified, trimmedNonEmpty(adapterRemovalSequence) == nil {
                return "Enter an adapter sequence for manual adapter removal."
            }
            return nil

        case .primerTrimming:
            switch primerTrimmingSource {
            case .literal:
                return trimmedNonEmpty(primerTrimmingLiteralSequence) == nil
                    ? "Enter a literal primer sequence or switch to reference mode."
                    : nil
            case .reference:
                return nil
            }

        case .trimFixedBases:
            return (trimFixedBasesFrom5Prime > 0 || trimFixedBasesFrom3Prime > 0)
                ? nil
                : "Enter at least one fixed trim amount."

        case .filterByReadLength:
            if filterByReadLengthMin == nil, filterByReadLengthMax == nil {
                return "Enter a minimum, a maximum, or both."
            }
            if let min = filterByReadLengthMin, let max = filterByReadLengthMax, min > max {
                return "Minimum read length cannot exceed maximum read length."
            }
            return nil

        case .removeContaminants:
            return nil

        case .removeDuplicates:
            return nil

        case .mergeOverlappingPairs:
            return mergeOverlappingPairsMinOverlap > 0
                ? nil
                : "Enter a positive minimum overlap."

        case .repairPairedEndFiles:
            return nil

        case .orientReads:
            return auxiliaryInputURL(for: .referenceSequence) == nil
                ? "Select a reference sequence to continue."
                : nil

        case .correctSequencingErrors:
            return correctSequencingErrorsKmerSize > 0
                ? nil
                : "Enter a positive k-mer size."

        case .subsampleByProportion:
            guard let value = subsampleByProportionValue else {
                return "Enter a proportion between 0 and 1."
            }
            return (value > 0 && value <= 1) ? nil : "Enter a proportion between 0 and 1."

        case .subsampleByCount:
            guard let value = subsampleByCountValue else {
                return "Enter a positive read count."
            }
            return value > 0 ? nil : "Enter a positive read count."

        case .extractReadsByID:
            return trimmedNonEmpty(extractReadsByIDQuery) == nil
                ? "Enter a read ID or search pattern."
                : nil

        case .extractReadsByMotif:
            return trimmedNonEmpty(extractReadsByMotifPattern) == nil
                ? "Enter a motif or search pattern."
                : nil

        case .selectReadsBySequence:
            return trimmedNonEmpty(selectReadsBySequenceValue) == nil
                ? "Enter a literal sequence or FASTA path."
                : nil

        case .demultiplexBarcodes:
            if demultiplexBarcodeSource == .builtinKit, trimmedNonEmpty(demultiplexKitID) == nil {
                return "Select a built-in barcode kit or switch to a custom definition."
            }
            return nil

        case .spades, .megahit, .skesa, .flye, .hifiasm:
            if let mismatchMessage = assemblyReadClassMismatchMessage {
                return mismatchMessage
            }
            if let assemblyTool = selectedToolID.assemblyTool,
               let detectedAssemblyReadType,
               !AssemblyCompatibility.isSupported(tool: assemblyTool, for: detectedAssemblyReadType) {
                return "\(assemblyTool.displayName) is not available for \(detectedAssemblyReadType.displayName) in v1."
            }
            return nil

        case .refreshQCSummary, .minimap2, .bwaMem2, .bowtie2, .bbmap, .kraken2, .esViritu, .taxTriage, .removeHumanReads:
            return nil
        }
    }

    private func normalizeSelectionState() {
        if isFASTAInputMode, !selectedToolID.supportsFASTA,
           let firstSupportedTool = FASTAOperationCatalog.availableToolIDs().first {
            selectedToolID = firstSupportedTool
            return
        }

        embeddedToolReady = selectedToolID.defaultEmbeddedReadiness
        embeddedRunTrigger = 0
        pendingLaunchRequest = nil
        pendingMinimap2Config = nil
        pendingMappingRequest = nil
        pendingAssemblyRequest = nil
        pendingClassificationConfigs = []
        pendingEsVirituConfigs = []
        pendingTaxTriageConfig = nil
        normalizeOutputMode()
    }

    private func normalizeOutputMode() {
        if outputMode != selectedToolID.defaultOutputMode && !selectedToolID.supportsConfigurableOutput {
            outputMode = selectedToolID.defaultOutputMode
            return
        }

        if !outputStrategyOptions.contains(outputMode) {
            outputMode = outputStrategyOptions.first ?? selectedToolID.defaultOutputMode
        }
    }

    private static func defaultOutputDirectory(projectURL: URL?, selectedInputURLs: [URL]) -> URL? {
        if let projectURL {
            return projectURL.appendingPathComponent("Analyses", isDirectory: true)
        }

        return selectedInputURLs.first?.deletingLastPathComponent()
    }

    private func trimmedNonEmpty(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private var selectedPrimerReferencePath: String? {
        auxiliaryInputURL(for: .primerSource)?.path
    }

    private var selectedBarcodeDefinitionPath: String? {
        auxiliaryInputURL(for: .barcodeDefinition)?.path
    }

    private var assemblyCompatibilityEvaluation: AssemblyCompatibilityEvaluation {
        let detectedReadTypes = selectedInputURLs.compactMap(AssemblyReadType.detect(fromInputURL:))
        let evaluation = AssemblyCompatibility.evaluate(detectedReadTypes: detectedReadTypes)

        let hasKnownAndUnknownMix =
            !detectedReadTypes.isEmpty && detectedReadTypes.count < selectedInputURLs.count
        guard !evaluation.isBlocked, hasKnownAndUnknownMix else {
            return evaluation
        }

        return AssemblyCompatibilityEvaluation(
            detectedReadTypes: evaluation.detectedReadTypes,
            resolvedReadType: nil,
            supportedTools: [],
            blockingMessage: Self.mixedDetectedAndUnclassifiedAssemblyInputsMessage
        )
    }

    private func availability(for toolID: FASTQOperationToolID) -> DatasetOperationAvailability {
        guard selectedCategory == .assembly,
              let assemblyTool = toolID.assemblyTool,
              let readType = detectedAssemblyReadType else {
            return .available
        }

        guard !AssemblyCompatibility.isSupported(tool: assemblyTool, for: readType) else {
            return .available
        }

        return .disabled(reason: Self.requiredReadTypeBadge(for: assemblyTool))
    }

    private func visibleToolIDs(for category: FASTQOperationCategoryID) -> [FASTQOperationToolID] {
        if isFASTAInputMode {
            return FASTAOperationCatalog.availableToolIDs()
        }

        let allToolIDs = Self.toolIDs(for: category)
        guard category == .assembly,
              assemblyReadClassMismatchMessage == nil,
              let readType = detectedAssemblyReadType else {
            return allToolIDs
        }

        let supportedAssemblyToolIDs = Set(
            AssemblyCompatibility.supportedTools(for: readType).map(Self.toolID(for:))
        )
        return allToolIDs.filter { supportedAssemblyToolIDs.contains($0) }
    }

    private static func defaultAssemblyTool(for readType: AssemblyReadType?) -> FASTQOperationToolID {
        guard let readType,
              let preferredTool = AssemblyCompatibility.supportedTools(for: readType).first else {
            return .spades
        }

        switch preferredTool {
        case .spades:
            return .spades
        case .megahit:
            return .megahit
        case .skesa:
            return .skesa
        case .flye:
            return .flye
        case .hifiasm:
            return .hifiasm
        }
    }

    private static func requiredReadTypeBadge(for tool: AssemblyTool) -> String {
        switch tool {
        case .spades, .megahit, .skesa:
            return "Requires Illumina"
        case .flye:
            return "Requires ONT"
        case .hifiasm:
            return "Requires ONT or HiFi/CCS"
        }
    }

    private static func toolID(for tool: AssemblyTool) -> FASTQOperationToolID {
        switch tool {
        case .spades:
            return .spades
        case .megahit:
            return .megahit
        case .skesa:
            return .skesa
        case .flye:
            return .flye
        case .hifiasm:
            return .hifiasm
        }
    }

    private func assemblyRequest(from config: SPAdesAssemblyConfig) -> AssemblyRunRequest? {
        guard let tool = selectedToolID.assemblyTool, tool == .spades else { return nil }
        guard let readType = detectedAssemblyReadType else { return nil }
        guard AssemblyCompatibility.isSupported(tool: tool, for: readType) else {
            return nil
        }

        return AssemblyRunRequest(
            tool: tool,
            readType: readType,
            inputURLs: config.allInputFiles,
            projectName: config.projectName,
            outputDirectory: config.outputDirectory,
            pairedEnd: !config.forwardReads.isEmpty
                && config.forwardReads.count == config.reverseReads.count
                && config.unpairedReads.isEmpty,
            threads: config.threads,
            memoryGB: config.memoryGB,
            minContigLength: config.minContigLength,
            selectedProfileID: config.mode.rawValue,
            extraArguments: config.customArgs
        )
    }

    private func resolvedDeduplicateParameters() -> (substitutions: Int, optical: Bool, opticalDistance: Int) {
        switch removeDuplicatesPreset {
        case .exactPCR:
            return (0, false, 40)
        case .nearDuplicate1:
            return (1, false, 40)
        case .nearDuplicate2:
            return (2, false, 40)
        case .opticalHiSeq:
            return (0, true, 40)
        case .opticalNovaSeq:
            return (0, true, 12000)
        case .custom:
            return (
                removeDuplicatesSubstitutions,
                removeDuplicatesOptical,
                removeDuplicatesOpticalDistance
            )
        }
    }

    private func isPathLikeSequenceFilterValue(_ value: String) -> Bool {
        let lowercased = value.lowercased()
        return value.contains("/")
            || lowercased.hasSuffix(".fa")
            || lowercased.hasSuffix(".fasta")
            || lowercased.hasSuffix(".fna")
            || lowercased.hasSuffix(".fas")
    }
}

enum FASTQOperationToolID: String, CaseIterable, Sendable {
    case refreshQCSummary
    case demultiplexBarcodes
    case qualityTrim
    case adapterRemoval
    case primerTrimming
    case trimFixedBases
    case filterByReadLength
    case removeHumanReads
    case removeContaminants
    case removeDuplicates
    case mergeOverlappingPairs
    case repairPairedEndFiles
    case orientReads
    case correctSequencingErrors
    case subsampleByProportion
    case subsampleByCount
    case extractReadsByID
    case extractReadsByMotif
    case selectReadsBySequence
    case minimap2
    case bwaMem2 = "bwa-mem2"
    case bowtie2
    case bbmap
    case spades
    case megahit
    case skesa
    case flye
    case hifiasm
    case kraken2
    case esViritu
    case taxTriage

    var title: String {
        switch self {
        case .refreshQCSummary: return "Refresh QC Summary"
        case .demultiplexBarcodes: return "Demultiplex Barcodes"
        case .qualityTrim: return "Quality Trim"
        case .adapterRemoval: return "Adapter Removal"
        case .primerTrimming: return "Primer Trimming"
        case .trimFixedBases: return "Trim Fixed Bases"
        case .filterByReadLength: return "Filter by Read Length"
        case .removeHumanReads: return "Remove Human Reads"
        case .removeContaminants: return "Remove Contaminants"
        case .removeDuplicates: return "Remove Duplicates"
        case .mergeOverlappingPairs: return "Merge Overlapping Pairs"
        case .repairPairedEndFiles: return "Repair Paired-End Files"
        case .orientReads: return "Orient Reads"
        case .correctSequencingErrors: return "Correct Sequencing Errors"
        case .subsampleByProportion: return "Subsample by Proportion"
        case .subsampleByCount: return "Subsample by Count"
        case .extractReadsByID: return "Extract Reads by ID"
        case .extractReadsByMotif: return "Extract Reads by Motif"
        case .selectReadsBySequence: return "Select Reads by Sequence"
        case .minimap2: return "minimap2"
        case .bwaMem2: return "BWA-MEM2"
        case .bowtie2: return "Bowtie2"
        case .bbmap: return "BBMap"
        case .spades: return "SPAdes"
        case .megahit: return "MEGAHIT"
        case .skesa: return "SKESA"
        case .flye: return "Flye"
        case .hifiasm: return "Hifiasm"
        case .kraken2: return "Kraken2"
        case .esViritu: return "EsViritu"
        case .taxTriage: return "TaxTriage"
        }
    }

    var subtitle: String {
        switch self {
        case .refreshQCSummary: return "Rebuild the QC summary for the current FASTQ data."
        case .demultiplexBarcodes: return "Split pooled reads into barcode-defined samples."
        case .qualityTrim: return "Trim low-quality bases from read ends."
        case .adapterRemoval: return "Remove adapter sequence from reads."
        case .primerTrimming: return "Trim PCR primer sequence from reads."
        case .trimFixedBases: return "Remove a fixed number of bases from either end."
        case .filterByReadLength: return "Keep reads in a requested length range."
        case .removeHumanReads: return "Remove reads against a human database."
        case .removeContaminants: return "Remove spike-ins or other contaminant sequences."
        case .removeDuplicates: return "Collapse duplicate reads."
        case .mergeOverlappingPairs: return "Merge overlapping paired-end reads."
        case .repairPairedEndFiles: return "Restore proper pairing for FASTQ mates."
        case .orientReads: return "Orient reads to a reference strand."
        case .correctSequencingErrors: return "Correct random sequencing errors."
        case .subsampleByProportion: return "Keep a fraction of the input reads."
        case .subsampleByCount: return "Keep a fixed number of reads."
        case .extractReadsByID: return "Select reads matching identifiers."
        case .extractReadsByMotif: return "Select reads containing a motif."
        case .selectReadsBySequence: return "Select reads matching a sequence."
        case .minimap2: return "Map reads to a reference sequence with minimap2."
        case .bwaMem2: return "Map Illumina short reads with BWA-MEM2."
        case .bowtie2: return "Map Illumina short reads with Bowtie2."
        case .bbmap: return "Map reads to a reference sequence with BBMap."
        case .spades: return "Assemble reads into contigs."
        case .megahit: return "Assemble short reads with a compact de Bruijn graph."
        case .skesa: return "Assemble isolate-focused short reads conservatively."
        case .flye: return "Assemble ONT long reads into contigs."
        case .hifiasm: return "Assemble ONT or PacBio HiFi/CCS long reads into phased contigs."
        case .kraken2: return "Classify reads taxonomically."
        case .esViritu: return "Detect viruses and report coverage."
        case .taxTriage: return "Run the TaxTriage pathogen workflow."
        }
    }

    var categoryID: FASTQOperationCategoryID {
        switch self {
        case .refreshQCSummary:
            return .qcReporting
        case .demultiplexBarcodes:
            return .demultiplexing
        case .qualityTrim, .adapterRemoval, .primerTrimming, .trimFixedBases, .filterByReadLength:
            return .trimmingFiltering
        case .removeHumanReads, .removeContaminants, .removeDuplicates:
            return .decontamination
        case .mergeOverlappingPairs, .repairPairedEndFiles, .orientReads, .correctSequencingErrors:
            return .readProcessing
        case .subsampleByProportion, .subsampleByCount, .extractReadsByID, .extractReadsByMotif, .selectReadsBySequence:
            return .searchSubsetting
        case .minimap2, .bwaMem2, .bowtie2, .bbmap:
            return .mapping
        case .spades, .megahit, .skesa, .flye, .hifiasm:
            return .assembly
        case .kraken2, .esViritu, .taxTriage:
            return .classification
        }
    }

    var requiredInputKinds: [FASTQOperationInputKind] {
        switch self {
        case .refreshQCSummary:
            return [.fastqDataset]
        case .demultiplexBarcodes:
            return [.fastqDataset, .barcodeDefinition]
        case .qualityTrim, .adapterRemoval, .trimFixedBases, .filterByReadLength,
             .removeDuplicates, .mergeOverlappingPairs, .repairPairedEndFiles,
             .correctSequencingErrors, .subsampleByProportion, .subsampleByCount,
             .extractReadsByID, .extractReadsByMotif, .selectReadsBySequence,
             .spades, .megahit, .skesa, .flye, .hifiasm:
            return [.fastqDataset]
        case .primerTrimming:
            return [.fastqDataset, .primerSource]
        case .removeHumanReads, .kraken2, .esViritu, .taxTriage:
            return [.fastqDataset, .database]
        case .removeContaminants:
            return [.fastqDataset, .contaminantReference]
        case .orientReads, .minimap2, .bwaMem2, .bowtie2, .bbmap:
            return [.fastqDataset, .referenceSequence]
        }
    }

    var defaultOutputMode: FASTQOperationOutputMode {
        categoryID == .classification ? .fixedBatch : .perInput
    }

    func sidebarItem(
        availability: DatasetOperationAvailability = .available
    ) -> DatasetOperationToolSidebarItem {
        DatasetOperationToolSidebarItem(
            id: rawValue,
            title: title,
            subtitle: subtitle,
            availability: availability
        )
    }

    var usesEmbeddedConfiguration: Bool {
        switch self {
        case .minimap2, .bwaMem2, .bowtie2, .bbmap, .spades, .megahit, .skesa, .flye, .hifiasm, .kraken2, .esViritu, .taxTriage:
            return true
        default:
            return false
        }
    }

    var supportsConfigurableOutput: Bool {
        categoryID != .classification
    }

    var defaultEmbeddedReadiness: Bool {
        switch self {
        case .minimap2, .bwaMem2, .bowtie2, .bbmap, .spades, .megahit, .skesa, .flye, .hifiasm, .kraken2, .esViritu, .taxTriage:
            return false
        default:
            return true
        }
    }

    var embeddedReadinessText: String {
        switch self {
        case .minimap2:
            return "Select a reference sequence to continue."
        case .bwaMem2, .bowtie2, .bbmap:
            return "Complete the mapping settings to continue."
        case .kraken2, .esViritu, .taxTriage:
            return "Complete the classifier settings to continue."
        case .spades, .megahit, .skesa, .flye, .hifiasm:
            return "Complete the assembly settings to continue."
        default:
            return "Complete the required tool settings to continue."
        }
    }

    var assemblyTool: AssemblyTool? {
        switch self {
        case .spades: return .spades
        case .megahit: return .megahit
        case .skesa: return .skesa
        case .flye: return .flye
        case .hifiasm: return .hifiasm
        default: return nil
        }
    }

    var mappingTool: MappingTool? {
        switch self {
        case .minimap2: return .minimap2
        case .bwaMem2: return .bwaMem2
        case .bowtie2: return .bowtie2
        case .bbmap: return .bbmap
        default: return nil
        }
    }

    var supportsFASTA: Bool {
        switch self {
        case .trimFixedBases, .filterByReadLength, .removeContaminants,
             .removeDuplicates, .orientReads, .subsampleByProportion,
             .subsampleByCount, .extractReadsByID, .extractReadsByMotif,
             .selectReadsBySequence:
            return true
        case .refreshQCSummary, .demultiplexBarcodes, .qualityTrim,
             .adapterRemoval, .primerTrimming, .removeHumanReads,
             .mergeOverlappingPairs, .repairPairedEndFiles,
             .correctSequencingErrors, .minimap2, .bwaMem2, .bowtie2,
             .bbmap, .spades, .megahit, .skesa, .flye, .hifiasm,
             .kraken2, .esViritu, .taxTriage:
            return false
        }
    }
}

enum FASTQOperationInputKind: String, CaseIterable, Sendable {
    case fastqDataset
    case referenceSequence
    case database
    case barcodeDefinition
    case primerSource
    case contaminantReference

    var title: String {
        switch self {
        case .fastqDataset:
            return "FASTQ Datasets"
        case .referenceSequence:
            return "Reference Sequence"
        case .database:
            return "Database"
        case .barcodeDefinition:
            return "Barcode Definition"
        case .primerSource:
            return "Primer Reference"
        case .contaminantReference:
            return "Contaminant Reference"
        }
    }

    var missingSelectionText: String {
        switch self {
        case .referenceSequence:
            return "Select a reference sequence to continue."
        case .database:
            return "Select a database to continue."
        case .barcodeDefinition:
            return "Select a custom barcode definition to continue."
        case .primerSource:
            return "Select a primer reference FASTA to continue."
        case .contaminantReference:
            return "Select a contaminant reference to continue."
        case .fastqDataset:
            return "Select at least one FASTQ dataset."
        }
    }

    func accepts(url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        let fastaLike = ["fa", "fasta", "fna", "fas", "ffn", "frn", "faa", "gb", "gbk", "gbff", "embl", "lungfishref"]
        let textLike = ["txt", "csv", "tsv", "json", "fasta", "fa"]

        switch self {
        case .fastqDataset:
            return true
        case .referenceSequence, .contaminantReference:
            return fastaLike.contains(ext)
        case .database:
            return url.hasDirectoryPath || ext.isEmpty || ["db", "k2d", "sqlite", "json"].contains(ext)
        case .barcodeDefinition:
            return textLike.contains(ext)
        case .primerSource:
            return fastaLike.contains(ext)
        }
    }
}

enum FASTQDemultiplexBarcodeSource: String, CaseIterable, Sendable {
    case builtinKit
    case customDefinition
}

enum FASTQOperationOutputMode: String, CaseIterable, Sendable {
    case perInput
    case groupedResult
    case fixedBatch
}

enum FASTQOperationLaunchRequest: Sendable, Equatable {
    case refreshQCSummary(inputURLs: [URL])
    case derivative(request: FASTQDerivativeRequest, inputURLs: [URL], outputMode: FASTQOperationOutputMode)
    case map(inputURLs: [URL], referenceURL: URL, outputMode: FASTQOperationOutputMode)
    case assemble(request: AssemblyRunRequest, outputMode: FASTQOperationOutputMode)
    case classify(tool: FASTQOperationToolID, inputURLs: [URL], databaseName: String)
}

private extension AssemblyTool {
    var defaultReadType: AssemblyReadType {
        switch self {
        case .spades, .megahit, .skesa:
            return .illuminaShortReads
        case .flye:
            return .ontReads
        case .hifiasm:
            return .pacBioHiFi
        }
    }
}

extension FASTQOperationCategoryID {
    var defaultToolID: FASTQOperationToolID {
        switch self {
        case .qcReporting:
            return .refreshQCSummary
        case .demultiplexing:
            return .demultiplexBarcodes
        case .trimmingFiltering:
            return .qualityTrim
        case .decontamination:
            return .removeHumanReads
        case .readProcessing:
            return .mergeOverlappingPairs
        case .searchSubsetting:
            return .subsampleByProportion
        case .mapping:
            return .minimap2
        case .assembly:
            return .spades
        case .classification:
            return .kraken2
        }
    }
}
