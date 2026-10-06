import XCTest
@testable import LungfishApp
@testable import LungfishWorkflow

private actor StubPackStatusProvider: PluginPackStatusProviding {
    let states: [String: PluginPackState]

    init(states: [String: PluginPackState]) {
        self.states = states
    }

    func visibleStatuses() async -> [PluginPackStatus] {
        []
    }

    func status(for pack: PluginPack) async -> PluginPackStatus {
        PluginPackStatus(
            pack: pack,
            state: states[pack.id] ?? .needsInstall,
            toolStatuses: [],
            failureMessage: nil
        )
    }

    func invalidateVisibleStatusesCache() async {}

    func install(
        pack: PluginPack,
        reinstall: Bool,
        progress: (@Sendable (PluginPackInstallProgress) -> Void)?
    ) async throws {}


}

@MainActor
final class FASTQOperationsCatalogTests: XCTestCase {
    func testCategoryTitlesMatchApprovedTaxonomy() {
        XCTAssertEqual(
            FASTQOperationCategoryID.allCases.map(\.title),
            [
                "QC & REPORTING",
                "DEMULTIPLEXING",
                "TRIMMING & FILTERING",
                "DECONTAMINATION",
                "READ PROCESSING",
                "SEARCH & SUBSETTING",
                "MAPPING",
                "VARIANT CALLING",
                "ASSEMBLY",
                "CLUSTERING",
                "CLASSIFICATION",
                "GENOTYPING",
                "ALIGNMENT & PHYLOGENETICS",
            ]
        )
    }

    /// Raw values are strings, so reordering the cases to the Tools menu order
    /// changes nothing that is stored. The order itself is the menu's.
    func testCategoryCasesFollowTheToolsMenuOrder() {
        XCTAssertEqual(
            FASTQOperationCategoryID.allCases.map(\.rawValue),
            [
                "qcReporting",
                "demultiplexing",
                "trimmingFiltering",
                "decontamination",
                "readProcessing",
                "searchSubsetting",
                "mapping",
                "variantCalling",
                "assembly",
                "clustering",
                "classification",
                "genotyping",
                "alignment",
            ]
        )
    }

    /// One name per category, shared by the Tools menu, the dialog header, the
    /// dataset launchers and the Workflow Library. The dialog's uppercase
    /// header is derived from it.
    func testEveryCategoryHasOneDisplayNameAndTheDialogTitleDerivesFromIt() {
        XCTAssertEqual(
            FASTQOperationCategoryID.allCases.map(\.displayName),
            [
                "QC & Reporting",
                "Demultiplexing",
                "Trimming & Filtering",
                "Decontamination",
                "Read Processing",
                "Search & Subsetting",
                "Mapping",
                "Variant Calling",
                "Assembly",
                "Clustering",
                "Classification",
                "Genotyping",
                "Alignment & Phylogenetics",
            ]
        )
        for category in FASTQOperationCategoryID.allCases {
            XCTAssertEqual(category.title, category.displayName.uppercased(), "\(category.rawValue)")
        }
    }

    func testEveryToolIsListedByExactlyTheCategoryItDeclares() {
        var listed: [FASTQOperationToolID] = []
        for category in FASTQOperationCategoryID.allCases {
            for toolID in FASTQOperationDialogState.toolIDs(for: category) {
                XCTAssertEqual(toolID.categoryID, category, "\(toolID.rawValue) is listed by \(category.rawValue)")
                listed.append(toolID)
            }
        }
        XCTAssertEqual(listed.count, Set(listed).count, "no tool is listed by two categories")
        XCTAssertEqual(Set(listed), Set(FASTQOperationToolID.allCases), "every tool belongs to a category")
    }

    /// D1. The two filters that drop reads by their content sit with the other
    /// trim and filter tools, so the menu, the dialog and the library agree.
    func testTrimmingAndFilteringHoldsTheLowComplexityAndDuplicateFilters() {
        XCTAssertEqual(
            FASTQOperationDialogState.toolIDs(for: .trimmingFiltering),
            [
                .fastpTrim, .qualityTrim, .adapterRemoval, .primerTrimming, .trimFixedBases,
                .filterByReadLength, .removeLowComplexityReads, .removeDuplicates,
            ]
        )
        XCTAssertEqual(
            FASTQOperationDialogState.toolIDs(for: .decontamination),
            [.removeHumanReads, .removeRibosomalRNA, .removeContaminants]
        )
        XCTAssertEqual(FASTQOperationToolID.removeLowComplexityReads.categoryID, .trimmingFiltering)
        XCTAssertEqual(FASTQOperationToolID.removeDuplicates.categoryID, .trimmingFiltering)
    }

    /// U13, D2, D9, D11 and D12. The titles the Tools menu session renamed. The
    /// menu, the dialog header and sidebar, the dataset launchers and the Workflow
    /// Library all read them from here, so one pin covers every generated copy.
    func testRenamedToolsAndWorkflowsCarryTheirNewTitles() throws {
        let renamed: [(toolID: FASTQOperationToolID, title: String)] = [
            (.fastpTrim, "fastp Adapter & Quality Trim"),
            (.removeRibosomalRNA, "Remove Ribosomal RNA Reads"),
            (.removeLowComplexityReads, "Remove Low-Complexity Reads"),
            (.removeDuplicates, "Remove Duplicate Reads"),
            (.reverseComplement, "Reverse Complement All Sequences"),
            (.translate, "Translate All Sequences"),
            (.ontGenotyping, "MiSeq Amplicon MHC Genotyping"),
            (.hifiasm, "hifiasm"),
            (.viralRecon, "Viral Recon (SARS-CoV-2)"),
        ]
        for (toolID, title) in renamed {
            XCTAssertEqual(toolID.title, title, "\(toolID.rawValue)")
            XCTAssertEqual(WorkflowLibraryCatalog.item(for: toolID)?.title, title, "the library card of \(toolID.rawValue)")
            XCTAssertEqual(toolID.sidebarItem(availability: .available).title, title, "the dialog row of \(toolID.rawValue)")
        }
        XCTAssertEqual(WorkflowLibraryCatalog.fullLengthONTMHCGenotypingItem.title, "Full-Length ONT MHC Genotyping")

        // D2. Removing duplicates is advice for shotgun libraries, and the subtitle says why amplicon reads stay.
        XCTAssertEqual(
            FASTQOperationToolID.removeDuplicates.subtitle,
            "Collapse PCR and optical duplicate reads in shotgun libraries. Amplicon reads are identical by design, so keep them."
        )
        // D12. The subtitle spells the assay the way its title does.
        XCTAssertTrue(FASTQOperationToolID.ontGenotyping.subtitle.contains("MiSeq amplicon MHC genotyping"))
        XCTAssertFalse(FASTQOperationToolID.ontGenotyping.subtitle.contains("miSeq"))
        // Raw values are what the enablement defaults and the Tools menu identifiers store, and they never follow a title.
        XCTAssertEqual(renamed.map(\.toolID.rawValue), [
            "fastpTrim", "removeRibosomalRNA", "removeLowComplexityReads", "removeDuplicates",
            "reverseComplement", "translate", "ontGenotyping", "hifiasm", "viralRecon",
        ])
        XCTAssertEqual(
            WorkflowLibraryCatalog.fullLengthONTMHCGenotypingItem.id,
            "builtin.full-length-ont-mhc-genotyping",
            "the catalog id is stored in the enablement defaults"
        )
    }

    /// A display rename never reaches disk. The Operations row, its log and the
    /// preview follow the new titles. The label a batch manifest records and the
    /// folder a grouped result is written to keep the wording these operations had
    /// before, so a project written today reads like one written earlier.
    func testDisplayRenamesLeaveWhatIsWrittenToDiskAlone() throws {
        let input = URL(fileURLWithPath: "/tmp/sample.lungfishfastq")
        let derivatives: [(request: FASTQDerivativeRequest, display: String, onDisk: String, folder: String)] = [
            (
                .fastpTrim(threshold: 20, windowSize: 4, mode: .cutRight, adapterMode: .autoDetect, adapterSequence: nil),
                "fastp Adapter & Quality Trim", "fastp Adapter + Quality Trim", "fastp-adapter-quality-trim"
            ),
            (
                .lowComplexityFilter(entropy: 0.6, window: 50, kmer: 5),
                "Remove Low-Complexity Reads", "Low-Complexity Filter", "low-complexity-filter"
            ),
            (
                .ribosomalRNAFilter(retention: .nonRRNA, ensure: .none),
                "Remove Ribosomal RNA Reads", "Remove ribosomal RNA sequences", "remove-ribosomal-rna-sequences"
            ),
            (.reverseComplement, "Reverse Complement All Sequences", "Reverse Complement", "reverse-complement"),
            (.translate(frameOffset: 0), "Translate All Sequences", "Translate", "translate"),
        ]
        let parent = FileManager.default.temporaryDirectory
            .appendingPathComponent("display-rename-folders-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: parent) }

        let controller = MainSplitViewController()
        for (request, display, onDisk, folder) in derivatives {
            XCTAssertEqual(request.operationLabel, display, "the Operations label")
            XCTAssertEqual(request.batchLabel, onDisk, "the label a batch manifest records for \(display)")
            let launch = FASTQOperationLaunchRequest.derivative(request: request, inputURLs: [input], outputMode: .groupedResult)
            XCTAssertEqual(launch.operationDisplayTitle, display, "the Operations row title")
            let outputFolder = controller.uniqueFASTQOperationOutputDirectory(in: parent, request: launch)
            XCTAssertEqual(outputFolder.lastPathComponent, folder, "the folder a grouped \(display) result is written to")
        }

        // Labels that carry run parameters, and operations nobody renamed, keep their own wording.
        XCTAssertEqual(FASTQDerivativeRequest.lengthFilter(min: 50, max: 100).batchLabel, "Filter by Length (50-100 bp)")
        XCTAssertEqual(
            FASTQDerivativeRequest.deduplicate(preset: .exactPCR, substitutions: 0, optical: false, opticalDistance: 40).batchLabel,
            "Deduplicate"
        )

        let genotyping = FASTQOperationLaunchRequest.ontGenotyping(request: ONTBarcodeDemuxGenotypingRunRequest(
            inputFASTQURLs: [input],
            referenceSourceURL: input,
            outputDirectory: parent.appendingPathComponent("genotype", isDirectory: true),
            outputName: "genotype",
            analysisName: "genotype",
            threads: 1,
            minSupport: 1,
            mode: .ontSampleBundles,
            readType: .ont
        ))
        XCTAssertEqual(genotyping.operationDisplayTitle, "MiSeq Amplicon MHC Genotyping")
    }

    /// U7. Viral Recon is variant calling, not mapping.
    func testMappingKeepsTheFourMappersAndVariantCallingHoldsViralRecon() {
        XCTAssertEqual(
            FASTQOperationDialogState.toolIDs(for: .mapping),
            [.minimap2, .bwaMem2, .bowtie2, .bbmap]
        )
        XCTAssertEqual(FASTQOperationDialogState.toolIDs(for: .variantCalling), [.viralRecon])
        XCTAssertEqual(FASTQOperationToolID.viralRecon.categoryID, .variantCalling)
        XCTAssertEqual(FASTQOperationCategoryID.variantCalling.defaultToolID, .viralRecon)
    }

    /// U7. Moving Viral Recon into its own category must not change what gates
    /// it, so the new category copies the mapping category's requirement.
    func testVariantCallingRequiresTheSamePacksAsMapping() {
        XCTAssertEqual(
            FASTQOperationCategoryID.variantCalling.requiredPackIDs,
            FASTQOperationCategoryID.mapping.requiredPackIDs
        )
        XCTAssertEqual(FASTQOperationCategoryID.variantCalling.requiredPackIDs, ["read-mapping"])
        XCTAssertEqual(WorkflowLibraryCatalog.item(for: .viralRecon)?.requiredPluginPackIDs, ["read-mapping"])
    }

    func testCatalogIncludesClusteringCategory() {
        XCTAssertTrue(FASTQOperationCategoryID.allCases.contains(.clustering))
        XCTAssertEqual(FASTQOperationCategoryID.clustering.title, "CLUSTERING")
        XCTAssertEqual(FASTQOperationCategoryID.clustering.requiredPackIDs, [])
    }

    func testClusteringCatalogIncludesSavontBesidePBAAForFASTQOnly() {
        XCTAssertEqual(
            FASTQOperationDialogState.toolIDs(for: .clustering),
            [.savont, .pbaa]
        )
        XCTAssertEqual(FASTQOperationToolID.savont.title, "Savont Clustering")
        XCTAssertEqual(FASTQOperationToolID.savont.categoryID, .clustering)
        XCTAssertEqual(FASTQOperationToolID.savont.requiredInputKinds, [.fastqDataset])
        XCTAssertEqual(FASTQOperationToolID.savont.defaultOutputMode, .perInput)
        XCTAssertFalse(FASTQOperationToolID.savont.supportsConfigurableOutput)
        XCTAssertFalse(FASTQOperationToolID.savont.supportsFASTA)
        XCTAssertTrue(FASTQOperationToolID.savont.requiresProvenance)
    }

    func testClassificationCategoryRequiresMetagenomicsPack() async throws {
        let provider = StubPackStatusProvider(states: ["metagenomics": .needsInstall])
        let catalog = FASTQOperationsCatalog(statusProvider: provider)

        let resolvedCategory = await catalog.category(id: .classification)
        let category = try XCTUnwrap(resolvedCategory)
        XCTAssertFalse(category.isEnabled)
        XCTAssertEqual(category.disabledReason, "Requires Metagenomics Pack")
    }

    func testMappingCategoryUsesReadMappingPackID() async throws {
        let provider = StubPackStatusProvider(states: ["read-mapping": .ready])
        let catalog = FASTQOperationsCatalog(statusProvider: provider)

        let resolvedCategory = await catalog.category(id: .mapping)
        let category = try XCTUnwrap(resolvedCategory)
        XCTAssertTrue(category.isEnabled)
        XCTAssertEqual(category.requiredPackIDs, ["read-mapping"])
    }

    func testVariantCallingCategoryIncludesViralReconBehindReadMappingPack() async throws {
        let provider = StubPackStatusProvider(states: ["read-mapping": .ready])
        let catalog = FASTQOperationsCatalog(statusProvider: provider)

        let resolvedCategory = await catalog.category(id: .variantCalling)
        let category = try XCTUnwrap(resolvedCategory)

        XCTAssertTrue(category.isEnabled)
        XCTAssertEqual(category.requiredPackIDs, ["read-mapping"])
        XCTAssertTrue(FASTQOperationDialogState.toolIDs(for: .variantCalling).contains(.viralRecon))
        XCTAssertFalse(FASTQOperationDialogState.toolIDs(for: .mapping).contains(.viralRecon))

        // Without the read-mapping pack the new category is gated exactly as mapping is.
        let missing = StubPackStatusProvider(states: ["read-mapping": .needsInstall])
        let missingCatalog = FASTQOperationsCatalog(statusProvider: missing)
        let resolvedGated = await missingCatalog.category(id: .variantCalling)
        let resolvedMappingGated = await missingCatalog.category(id: .mapping)
        let gated = try XCTUnwrap(resolvedGated)
        let mappingGated = try XCTUnwrap(resolvedMappingGated)
        XCTAssertFalse(gated.isEnabled)
        XCTAssertEqual(gated.disabledReason, mappingGated.disabledReason)
    }

    func testAssemblyCategoryUsesBuiltInPackNameForDisabledReason() async throws {
        let provider = StubPackStatusProvider(states: ["assembly": .needsInstall])
        let catalog = FASTQOperationsCatalog(statusProvider: provider)

        let resolvedCategory = await catalog.category(id: .assembly)
        let category = try XCTUnwrap(resolvedCategory)
        XCTAssertFalse(category.isEnabled)
        XCTAssertEqual(category.disabledReason, "Requires Genome Assembly Pack")
    }

    func testAlignmentCategoryRequiresMSAPackAndContainsMAFFT() async throws {
        let provider = StubPackStatusProvider(states: ["multiple-sequence-alignment": .ready])
        let catalog = FASTQOperationsCatalog(statusProvider: provider)

        let resolvedCategory = await catalog.category(id: .alignment)
        let category = try XCTUnwrap(resolvedCategory)

        XCTAssertTrue(category.isEnabled)
        XCTAssertEqual(category.requiredPackIDs, ["multiple-sequence-alignment"])
        XCTAssertEqual(FASTQOperationCategoryID.alignment.defaultToolID, .mafft)
        XCTAssertTrue(FASTQOperationDialogState.toolIDs(for: .alignment).contains(.mafft))
    }

    func testMAFFTToolBuildsPendingMSARequest() throws {
        let project = repositoryRoot()
            .appendingPathComponent(".build", isDirectory: true)
            .appendingPathComponent("Project.lungfish", isDirectory: true)
        let input = project.appendingPathComponent("input.fasta")
        let state = FASTQOperationDialogState(
            initialCategory: .alignment,
            selectedInputURLs: [input],
            projectURL: project
        )

        state.prepareForRun()

        let request = try XCTUnwrap(state.pendingMSAAlignmentRequest)
        XCTAssertEqual(request.tool, .mafft)
        XCTAssertEqual(request.inputSequenceURLs, [input])
        XCTAssertEqual(request.projectURL, project)
        XCTAssertEqual(request.strategy, .auto)
        XCTAssertEqual(request.outputOrder, .input)
        XCTAssertEqual(request.extraArguments, [])
        XCTAssertNil(request.threads)
        XCTAssertNil(state.pendingLaunchRequest)
    }

    // MARK: - MB-3: multi-input output naming

    func testMAFFTDefaultSourceNameForSingleInputUsesPlainStem() {
        let input = URL(fileURLWithPath: "/tmp/SampleA.fasta")

        XCTAssertEqual(
            FASTQOperationDialogState.mafftDefaultSourceName(for: [input]),
            "SampleA"
        )
    }

    func testMAFFTDefaultSourceNameForTwoInputsReflectsBothInputs() {
        let inputs = [
            URL(fileURLWithPath: "/tmp/SampleA.fasta"),
            URL(fileURLWithPath: "/tmp/SampleB.fasta"),
        ]

        XCTAssertEqual(
            FASTQOperationDialogState.mafftDefaultSourceName(for: inputs),
            "SampleA+1 more aligned"
        )
    }

    func testMAFFTDefaultSourceNameForThreeInputsReflectsAllInputs() {
        let inputs = [
            URL(fileURLWithPath: "/tmp/SampleA.fasta"),
            URL(fileURLWithPath: "/tmp/SampleB.fasta"),
            URL(fileURLWithPath: "/tmp/SampleC.fasta"),
        ]

        XCTAssertEqual(
            FASTQOperationDialogState.mafftDefaultSourceName(for: inputs),
            "SampleA+2 more aligned"
        )
    }

    func testMAFFTToolBuildsPendingMSARequestNamedForAllSelectedInputs() throws {
        let project = repositoryRoot()
            .appendingPathComponent(".build", isDirectory: true)
            .appendingPathComponent("Project.lungfish", isDirectory: true)
        let inputs = [
            project.appendingPathComponent("SampleA.fasta"),
            project.appendingPathComponent("SampleB.fasta"),
            project.appendingPathComponent("SampleC.fasta"),
        ]
        let state = FASTQOperationDialogState(
            initialCategory: .alignment,
            selectedInputURLs: inputs,
            projectURL: project
        )

        state.prepareForRun()

        let request = try XCTUnwrap(state.pendingMSAAlignmentRequest)
        XCTAssertEqual(request.inputSequenceURLs, inputs)
        // The bundle stem is filesystem-sanitized ("+" -> "-"), but must
        // still trace back to all 3 inputs, not just the first.
        XCTAssertTrue(request.name.hasPrefix("SampleA-2-more-aligned"), request.name)
    }

    func testMAFFTToolPassesCuratedOptionsIntoPendingMSARequest() throws {
        let project = repositoryRoot()
            .appendingPathComponent(".build", isDirectory: true)
            .appendingPathComponent("Project.lungfish", isDirectory: true)
        let input = project.appendingPathComponent("input.fasta")
        let state = FASTQOperationDialogState(
            initialCategory: .alignment,
            selectedInputURLs: [input],
            projectURL: project
        )
        state.mafftStrategy = .linsi
        state.mafftOutputOrder = .aligned
        state.mafftSequenceType = .nucleotide
        state.mafftDirectionAdjustment = .accurate
        state.mafftSymbolPolicy = .any
        state.mafftDeterministicThreads = false
        state.mafftThreads = 4

        state.prepareForRun()

        let request = try XCTUnwrap(state.pendingMSAAlignmentRequest)
        XCTAssertEqual(request.strategy, .linsi)
        XCTAssertEqual(request.outputOrder, .aligned)
        XCTAssertEqual(request.sequenceType, .nucleotide)
        XCTAssertEqual(request.directionAdjustment, .accurate)
        XCTAssertEqual(request.symbolPolicy, .any)
        XCTAssertFalse(request.deterministicThreads)
        XCTAssertEqual(request.threads, 4)
    }

    func testMAFFTToolParsesAdvancedOptionsIntoPendingRequest() throws {
        let project = repositoryRoot()
            .appendingPathComponent(".build", isDirectory: true)
            .appendingPathComponent("Project.lungfish", isDirectory: true)
        let input = project.appendingPathComponent("input.fasta")
        let state = FASTQOperationDialogState(
            initialCategory: .alignment,
            selectedInputURLs: [input],
            projectURL: project
        )
        state.mafftExtraOptionsText = #"--op 1.53 --treeout --retree "2""#

        state.prepareForRun()

        let request = try XCTUnwrap(state.pendingMSAAlignmentRequest)
        XCTAssertEqual(request.extraArguments, ["--op", "1.53", "--treeout", "--retree", "2"])
        XCTAssertTrue(state.isRunEnabled)
    }

    func testMAFFTToolBlocksInvalidAdvancedOptions() {
        let project = repositoryRoot()
            .appendingPathComponent(".build", isDirectory: true)
            .appendingPathComponent("Project.lungfish", isDirectory: true)
        let input = project.appendingPathComponent("input.fasta")
        let state = FASTQOperationDialogState(
            initialCategory: .alignment,
            selectedInputURLs: [input],
            projectURL: project
        )
        state.mafftExtraOptionsText = #"--op "1.53" --label "unfinished"#

        state.prepareForRun()

        XCTAssertNil(state.pendingMSAAlignmentRequest)
        XCTAssertFalse(state.isRunEnabled)
        XCTAssertTrue(state.readinessText.contains("Advanced options"))
    }

    func testMAFFTToolRequiresExplicitFASTQAssemblyConfirmationForFASTQInput() {
        let project = repositoryRoot()
            .appendingPathComponent(".build", isDirectory: true)
            .appendingPathComponent("Project.lungfish", isDirectory: true)
        let input = project.appendingPathComponent("assembled-contigs.fastq")
        let state = FASTQOperationDialogState(
            initialCategory: .alignment,
            selectedInputURLs: [input],
            projectURL: project
        )

        state.prepareForRun()

        XCTAssertNil(state.pendingMSAAlignmentRequest)
        XCTAssertFalse(state.isRunEnabled)
        XCTAssertTrue(state.readinessText.contains("assembled or consensus sequences"))

        state.mafftAllowFASTQAssemblyInputs = true
        state.prepareForRun()

        XCTAssertEqual(state.pendingMSAAlignmentRequest?.allowFASTQAssemblyInputs, true)
        XCTAssertTrue(state.isRunEnabled)
    }

    func testAllRequiredPackIDsResolveToBuiltInPacks() {
        let requiredPackIDs = FASTQOperationCategoryID.allCases
            .flatMap(\.requiredPackIDs)

        XCTAssertFalse(requiredPackIDs.isEmpty)

        for packID in requiredPackIDs {
            XCTAssertNotNil(PluginPack.builtInPack(id: packID), "Missing built-in pack for \(packID)")
        }
    }

    func testReadProcessingIncludesSequenceTransformsForFASTAAndFASTQ() {
        let readProcessingTools = FASTQOperationDialogState.toolIDs(for: .readProcessing)

        XCTAssertTrue(readProcessingTools.contains(.reverseComplement))
        XCTAssertTrue(readProcessingTools.contains(.translate))
        XCTAssertTrue(FASTQOperationToolID.reverseComplement.supportsFASTA)
        XCTAssertTrue(FASTQOperationToolID.translate.supportsFASTA)
    }

    private func repositoryRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    func testPackLookupReturnsNilForUnknownPackID() async {
        let provider: any PluginPackStatusProviding = StubPackStatusProvider(states: [:])

        let status = await provider.status(forPackID: "unknown-pack")

        XCTAssertNil(status)
    }

    func testMAFFTRequestCarriesSelectedNamesOnlyWhenScopeIsSelected() throws {
        let project = repositoryRoot()
            .appendingPathComponent(".build", isDirectory: true)
            .appendingPathComponent("Project.lungfish", isDirectory: true)
        let input = project.appendingPathComponent("input.fasta")
        let state = FASTQOperationDialogState(
            initialCategory: .alignment,
            selectedInputURLs: [input],
            projectURL: project
        )
        state.mafftAllSequenceCount = 12
        state.mafftSelectedSequenceNames = ["seqA", "seqB"]

        state.mafftSequenceScope = .all
        state.prepareForRun()
        XCTAssertNil(try XCTUnwrap(state.pendingMSAAlignmentRequest).includedSequenceNames)

        state.mafftSequenceScope = .selected
        state.prepareForRun()
        XCTAssertEqual(
            try XCTUnwrap(state.pendingMSAAlignmentRequest).includedSequenceNames,
            ["seqA", "seqB"]
        )
    }
}
