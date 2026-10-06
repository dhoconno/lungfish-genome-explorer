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
