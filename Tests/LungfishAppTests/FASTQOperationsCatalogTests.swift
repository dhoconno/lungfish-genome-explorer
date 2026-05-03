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
                "ALIGNMENT",
                "MAPPING",
                "ASSEMBLY",
                "CLASSIFICATION",
            ]
        )
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

    func testMappingCategoryIncludesViralReconBehindReadMappingPack() async throws {
        let provider = StubPackStatusProvider(states: ["read-mapping": .ready])
        let catalog = FASTQOperationsCatalog(statusProvider: provider)

        let resolvedCategory = await catalog.category(id: .mapping)
        let category = try XCTUnwrap(resolvedCategory)

        XCTAssertTrue(category.isEnabled)
        XCTAssertEqual(category.requiredPackIDs, ["read-mapping"])
        XCTAssertTrue(FASTQOperationDialogState.toolIDs(for: .mapping).contains(.viralRecon))
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
}
