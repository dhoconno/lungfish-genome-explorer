import XCTest
@testable import LungfishApp
@testable import LungfishCore
@testable import LungfishIO
@testable import LungfishWorkflow

private actor StubVariantCallingPackStatusProvider: PluginPackStatusProviding {
    let states: [String: PluginPackState]
    let toolStatusesByPackID: [String: [PackToolStatus]]

    init(
        states: [String: PluginPackState],
        toolStatusesByPackID: [String: [PackToolStatus]] = [:]
    ) {
        self.states = states
        self.toolStatusesByPackID = toolStatusesByPackID
    }

    func visibleStatuses() async -> [PluginPackStatus] {
        []
    }

    func status(for pack: PluginPack) async -> PluginPackStatus {
        PluginPackStatus(
            pack: pack,
            state: states[pack.id] ?? .needsInstall,
            toolStatuses: toolStatusesByPackID[pack.id] ?? [],
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

final class BAMVariantCallingDialogRoutingTests: XCTestCase {
    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("BAMVariantCallingDialogRoutingTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    func testVariantCallingDialogUsesExtraArgumentsLabel() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: root.appendingPathComponent("Sources/LungfishApp/Views/BAM/BAMVariantCallingToolPanes.swift"),
            encoding: .utf8
        )

        XCTAssertTrue(source.contains(#"Text("Extra arguments")"#))
        XCTAssertFalse(source.contains(#"Text("Advanced Options")"#))
    }

    @MainActor
    func testDialogStateBlocksIVarUntilPrimerTrimAcknowledged() throws {
        let state = BAMVariantCallingDialogState(bundle: try makeBundleFixture())

        state.selectCaller(.ivar)

        XCTAssertFalse(state.isRunEnabled)

        state.ivarPrimerTrimConfirmed = true

        XCTAssertTrue(state.isRunEnabled)
    }

    @MainActor
    func testDialogStateBlocksMedakaUntilModelIsProvided() throws {
        let state = BAMVariantCallingDialogState(bundle: try makeBundleFixture())

        state.selectCaller(.medaka)

        XCTAssertFalse(state.isRunEnabled)

        state.medakaModel = "r1041_e82_400bps_sup_v5.0.0"

        XCTAssertTrue(state.isRunEnabled)
    }

    @MainActor
    func testDialogStateAllowsBcftoolsWithoutCallerSpecificPrerequisites() throws {
        let state = BAMVariantCallingDialogState(bundle: try makeBundleFixture())

        state.selectCaller(.bcftools)

        XCTAssertTrue(state.isRunEnabled)
        XCTAssertEqual(state.selectedToolID, "bcftools")
        XCTAssertTrue(state.readinessText.contains("bcftools"))
    }

    func testCatalogIncludesBcftoolsFromRequiredSetupPack() {
        let item = BAMVariantCallingCatalog.availableSidebarItems().first { $0.id == "bcftools" }

        XCTAssertEqual(item?.title, "bcftools")
        XCTAssertEqual(item?.subtitle, "Orthogonal mpileup/call cross-check for BAM alignments.")
        XCTAssertEqual(item?.availability, .available)
    }

    func testCatalogIncludesClair3AndPhasedGATKWhatsHapLane() {
        let items = BAMVariantCallingCatalog.availableSidebarItems()
        let clair3 = items.first { $0.id == "clair3" }
        let phased = items.first { $0.id == "gatk-whatshap-phased" }

        XCTAssertEqual(clair3?.title, "Clair3")
        XCTAssertEqual(clair3?.subtitle, "ONT-focused neural-network variant calling with Clair3.")
        XCTAssertEqual(clair3?.availability, .available)
        XCTAssertEqual(phased?.title, "GATK + WhatsHap Phased")
        XCTAssertEqual(phased?.subtitle, "Phase-aware HaplotypeCaller plus WhatsHap command plan.")
        XCTAssertEqual(phased?.availability, .available)
    }

    @MainActor
    func testDialogStateParsesAdvancedOptionsIntoPendingRequest() throws {
        let state = BAMVariantCallingDialogState(bundle: try makeBundleFixture())

        state.advancedOptionsText = #"--call-indels --tag "sample 1""#
        state.prepareForRun()

        XCTAssertEqual(state.pendingRequest?.advancedArguments, ["--call-indels", "--tag", "sample 1"])
    }

    @MainActor
    func testDialogStateFiltersToEligibleBamTracksOnly() throws {
        let bundle = try makeBundleFixture(
            alignments: [
                AlignmentTrackInfo(
                    id: "aln-bam",
                    name: "Eligible BAM",
                    format: .bam,
                    sourcePath: "alignments/eligible.sorted.bam",
                    indexPath: "alignments/eligible.sorted.bam.bai"
                ),
                AlignmentTrackInfo(
                    id: "aln-sam",
                    name: "SAM Only",
                    format: .sam,
                    sourcePath: "alignments/raw.sam",
                    indexPath: "alignments/raw.sam.bai"
                ),
                AlignmentTrackInfo(
                    id: "aln-missing-index",
                    name: "Missing Index",
                    format: .bam,
                    sourcePath: "alignments/missing.sorted.bam",
                    indexPath: "alignments/missing.sorted.bam.bai"
                ),
            ],
            existingFiles: [
                "alignments/eligible.sorted.bam",
                "alignments/eligible.sorted.bam.bai",
                "alignments/raw.sam",
                "alignments/missing.sorted.bam",
            ]
        )

        let state = BAMVariantCallingDialogState(bundle: bundle)

        XCTAssertEqual(state.alignmentTrackOptions.map(\.id), ["aln-bam"])
        XCTAssertEqual(state.selectedAlignmentTrackID, "aln-bam")
    }

    @MainActor
    func testDialogStateUsesPreferredEligibleTrackWhenProvided() throws {
        let bundle = try makeBundleFixture(
            alignments: [
                AlignmentTrackInfo(
                    id: "aln-1",
                    name: "First BAM",
                    format: .bam,
                    sourcePath: "alignments/first.sorted.bam",
                    indexPath: "alignments/first.sorted.bam.bai"
                ),
                AlignmentTrackInfo(
                    id: "aln-2",
                    name: "Second BAM",
                    format: .bam,
                    sourcePath: "alignments/second.sorted.bam",
                    indexPath: "alignments/second.sorted.bam.bai"
                ),
            ],
            existingFiles: [
                "alignments/first.sorted.bam",
                "alignments/first.sorted.bam.bai",
                "alignments/second.sorted.bam",
                "alignments/second.sorted.bam.bai",
            ]
        )

        let state = BAMVariantCallingDialogState(
            bundle: bundle,
            preferredAlignmentTrackID: "aln-2"
        )

        XCTAssertEqual(state.selectedAlignmentTrackID, "aln-2")
        XCTAssertEqual(state.selectedAlignmentTrack?.name, "Second BAM")
    }

    @MainActor
    func testDialogStateReportsMissingAnalysisReadyBams() throws {
        let bundle = try makeBundleFixture(
            alignments: [
                AlignmentTrackInfo(
                    id: "aln-sam",
                    name: "Raw SAM",
                    format: .sam,
                    sourcePath: "alignments/raw.sam",
                    indexPath: "alignments/raw.sam.bai"
                ),
            ],
            existingFiles: ["alignments/raw.sam"]
        )

        let state = BAMVariantCallingDialogState(bundle: bundle)

        XCTAssertEqual(state.alignmentTrackOptions, [])
        XCTAssertFalse(state.isRunEnabled)
        XCTAssertEqual(
            state.readinessText,
            "This bundle has no analysis-ready BAM alignment tracks to call variants from."
        )
    }

    @MainActor
    func testDialogStateDisablesRunForInvalidSelectedTrackID() throws {
        let state = BAMVariantCallingDialogState(bundle: try makeBundleFixture())

        state.selectedAlignmentTrackID = "missing-track"

        XCTAssertFalse(state.isRunEnabled)
    }

    @MainActor
    func testReadStyleSectionTracksVariantCallingEligibility() throws {
        let viewModel = ReadStyleSectionViewModel()

        let eligibleBundle = try makeBundleFixture(
            alignments: [
                AlignmentTrackInfo(
                    id: "aln-bam",
                    name: "Eligible BAM",
                    format: .bam,
                    sourcePath: "alignments/eligible.sorted.bam",
                    indexPath: "alignments/eligible.sorted.bam.bai"
                ),
            ],
            existingFiles: [
                "alignments/eligible.sorted.bam",
                "alignments/eligible.sorted.bam.bai",
            ]
        )
        viewModel.loadStatistics(from: eligibleBundle)
        XCTAssertTrue(viewModel.hasVariantCallableAlignmentTracks)

        let ineligibleBundle = try makeBundleFixture(
            alignments: [
                AlignmentTrackInfo(
                    id: "aln-sam",
                    name: "SAM Only",
                    format: .sam,
                    sourcePath: "alignments/raw.sam",
                    indexPath: "alignments/raw.sam.bai"
                ),
            ],
            existingFiles: ["alignments/raw.sam"]
        )
        viewModel.loadStatistics(from: ineligibleBundle)
        XCTAssertFalse(viewModel.hasVariantCallableAlignmentTracks)
    }

    func testReadStyleSectionSourceDisablesCallVariantsUsingEligibilityFlag() throws {
        let source = try String(
            contentsOf: repositoryRoot()
                .appendingPathComponent("Sources/LungfishApp/Views/Inspector/Sections/ReadStyleSection.swift"),
            encoding: .utf8
        )

        XCTAssertTrue(source.contains(".disabled(!viewModel.hasVariantCallableAlignmentTracks)"))
    }

    func testCatalogDisablesAllToolsWhenVariantCallingPackIsMissing() async {
        let catalog = BAMVariantCallingCatalog(
            statusProvider: StubVariantCallingPackStatusProvider(states: [
                "variant-calling": .needsInstall,
                "gatk-core": .needsInstall,
            ])
        )

        let items = await catalog.sidebarItems()

        XCTAssertGreaterThanOrEqual(items.count, ViralVariantCaller.allCases.count)
        XCTAssertTrue(items.allSatisfy { $0.availability != .available })
    }

    func testCatalogAllowsReadyVariantCallersWhenOnlyClair3IsMissing() async throws {
        let variantPack = try XCTUnwrap(PluginPack.builtInPack(id: "variant-calling"))
        let statuses = variantPack.toolRequirements.map { requirement in
            PackToolStatus(
                requirement: requirement,
                environmentExists: requirement.id != "clair3",
                missingExecutables: requirement.id == "clair3" ? requirement.executables : [],
                smokeTestFailure: nil,
                storageUnavailablePath: nil
            )
        }
        let catalog = BAMVariantCallingCatalog(
            statusProvider: StubVariantCallingPackStatusProvider(
                states: [
                    "variant-calling": .needsInstall,
                    "lungfish-tools": .ready,
                    "gatk-core": .needsInstall,
                    "phasing": .needsInstall,
                ],
                toolStatusesByPackID: [
                    "variant-calling": statuses,
                ]
            )
        )

        let items = await catalog.sidebarItems()

        XCTAssertEqual(items.first(where: { $0.id == "lofreq" })?.availability, .available)
        XCTAssertEqual(items.first(where: { $0.id == "ivar" })?.availability, .available)
        XCTAssertEqual(items.first(where: { $0.id == "medaka" })?.availability, .available)
        XCTAssertEqual(
            items.first(where: { $0.id == "clair3" })?.availability,
            .disabled(reason: "Requires Clair3")
        )
    }

    func testCatalogGatesGATKHaplotypeCallerOnGATKCorePack() async throws {
        let catalog = BAMVariantCallingCatalog(
            statusProvider: StubVariantCallingPackStatusProvider(states: [
                "variant-calling": .needsInstall,
                "lungfish-tools": .needsInstall,
                "gatk-core": .ready,
            ])
        )

        let items = await catalog.sidebarItems()

        let gatk = try XCTUnwrap(items.first(where: { $0.id == "gatk-haplotype-caller" }))
        XCTAssertEqual(gatk.availability, .available)
        for viral in ViralVariantCaller.allCases where viral != .bcftools {
            XCTAssertEqual(
                items.first(where: { $0.id == viral.rawValue })?.availability,
                .disabled(reason: "Requires Variant Calling Pack")
            )
        }
        XCTAssertEqual(
            items.first(where: { $0.id == ViralVariantCaller.bcftools.rawValue })?.availability,
            .disabled(reason: "Requires Third-Party Tools Pack")
        )
    }

    func testCatalogGatesPhasedLaneOnBothGATKAndPhasingPacks() async throws {
        let catalog = BAMVariantCallingCatalog(
            statusProvider: StubVariantCallingPackStatusProvider(states: [
                "variant-calling": .ready,
                "lungfish-tools": .ready,
                "gatk-core": .ready,
                "phasing": .needsInstall,
            ])
        )

        let items = await catalog.sidebarItems()
        let phased = try XCTUnwrap(items.first(where: { $0.id == "gatk-whatshap-phased" }))

        XCTAssertEqual(phased.availability, .disabled(reason: "Requires Variant Phasing Pack"))
    }

    @MainActor
    func testDialogStateBlocksRunWhenSelectedCallerIsUnavailable() async throws {
        let sidebarItems = await BAMVariantCallingCatalog(
            statusProvider: StubVariantCallingPackStatusProvider(states: [
                "variant-calling": .needsInstall,
                "gatk-core": .needsInstall,
            ])
        ).sidebarItems()
        let state = BAMVariantCallingDialogState(
            bundle: try makeBundleFixture(),
            sidebarItems: sidebarItems
        )

        XCTAssertFalse(state.isRunEnabled)
        XCTAssertTrue(state.readinessText.contains("Requires Variant Calling Pack"))
    }

    @MainActor
    func testDialogStateBuildsRunnableGATKHaplotypeCallerRequestWithStandardVCFOutput() async throws {
        let sidebarItems = await BAMVariantCallingCatalog(
            statusProvider: StubVariantCallingPackStatusProvider(states: [
                "variant-calling": .needsInstall,
                "gatk-core": .ready,
            ])
        ).sidebarItems()
        let bundle = try makeBundleFixture()
        let state = BAMVariantCallingDialogState(
            bundle: bundle,
            sidebarItems: sidebarItems
        )

        state.selectTool(named: "gatk-haplotype-caller")

        XCTAssertTrue(state.isRunEnabled)
        XCTAssertEqual(
            state.readinessText,
            "Ready to run GATK HaplotypeCaller on Sample 1."
        )

        state.prepareForRun()

        let request = try XCTUnwrap(state.pendingGATKRequest)
        XCTAssertEqual(request.workflowName, "GATK HaplotypeCaller")
        XCTAssertEqual(request.packID, "gatk-core")
        XCTAssertEqual(request.command.arguments.first, "HaplotypeCaller")
        XCTAssertArgumentPair(
            request.command.arguments,
            "-R",
            bundle.url.appendingPathComponent("genome/reference.fa.gz").path
        )
        XCTAssertArgumentPair(
            request.command.arguments,
            "-I",
            bundle.url.appendingPathComponent("alignments/sample.sorted.bam").path
        )
        XCTAssertFalse(request.command.arguments.contains("-ERC"))
        XCTAssertEqual(request.outputs.first?.format, .vcf)
    }

    @MainActor
    func testDialogStateAutoSuffixesDefaultTrackNameWhenCollisionExists() throws {
        let state = BAMVariantCallingDialogState(
            bundle: try makeBundleFixture(existingVariantTrackNames: ["Sample 1 • LoFreq"])
        )

        state.selectCaller(.lofreq)

        XCTAssertEqual(state.outputTrackName, "Sample 1 • LoFreq (2)")
    }

    func testReadStyleSectionSourceIncludesCallVariantsAction() throws {
        let source = try String(
            contentsOf: repositoryRoot()
                .appendingPathComponent("Sources/LungfishApp/Views/Inspector/Sections/ReadStyleSection.swift"),
            encoding: .utf8
        )

        XCTAssertTrue(source.contains("onCallVariantsRequested"))
        XCTAssertTrue(source.contains("Call Variants"))
    }

    func testInspectorControllerSourceWiresCallVariantsWorkflow() throws {
        let source = try String(
            contentsOf: repositoryRoot()
                .appendingPathComponent("Sources/LungfishApp/Views/Inspector/InspectorViewController.swift"),
            encoding: .utf8
        )

        XCTAssertTrue(source.contains("onCallVariantsRequested"))
        XCTAssertTrue(source.contains("runCallVariantsWorkflow()"))
        XCTAssertTrue(source.contains("operationType: .variantCalling"))
    }

    private func makeBundleFixture(
        alignments: [AlignmentTrackInfo]? = nil,
        existingFiles: [String]? = nil,
        existingVariantTrackNames: [String] = []
    ) throws -> ReferenceBundle {
        let resolvedAlignments = alignments ?? [
            AlignmentTrackInfo(
                id: "aln-1",
                name: "Sample 1",
                format: .bam,
                sourcePath: "alignments/sample.sorted.bam",
                indexPath: "alignments/sample.sorted.bam.bai",
                checksumSHA256: "bam-sha"
            )
        ]
        let resolvedExistingFiles = existingFiles
            ?? resolvedAlignments.flatMap { [$0.sourcePath, $0.indexPath] }
        let bundleURL = tempDir.appendingPathComponent("Bundle-\(UUID().uuidString).lungfishref", isDirectory: true)

        try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)
        for relativePath in resolvedExistingFiles {
            let fileURL = bundleURL.appendingPathComponent(relativePath)
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            XCTAssertTrue(FileManager.default.createFile(atPath: fileURL.path, contents: Data("fixture".utf8)))
        }

        let manifest = BundleManifest(
            name: "Bundle",
            identifier: "bundle.test",
            source: SourceInfo(organism: "Virus", assembly: "TestAssembly", database: "Test"),
            genome: GenomeInfo(
                path: "genome/reference.fa.gz",
                indexPath: "genome/reference.fa.gz.fai",
                totalLength: 29_903,
                chromosomes: [
                    ChromosomeInfo(
                        name: "chr1",
                        length: 29_903,
                        offset: 0,
                        lineBases: 60,
                        lineWidth: 61
                    )
                ]
            ),
            variants: existingVariantTrackNames.enumerated().map { index, name in
                VariantTrackInfo(
                    id: "vc-\(index + 1)",
                    name: name,
                    path: "variants/\(index + 1).vcf.gz",
                    indexPath: "variants/\(index + 1).vcf.gz.tbi",
                    databasePath: "variants/\(index + 1).db"
                )
            },
            alignments: resolvedAlignments
        )

        return ReferenceBundle(url: bundleURL, manifest: manifest)
    }

    private func repositoryRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }
}

private func XCTAssertArgumentPair(
    _ arguments: [String],
    _ flag: String,
    _ value: String,
    file: StaticString = #filePath,
    line: UInt = #line
) {
    for index in arguments.indices where arguments[index] == flag && index + 1 < arguments.endIndex {
        if arguments[index + 1] == value {
            return
        }
    }
    XCTFail("Expected argument pair \(flag) \(value) in \(arguments)", file: file, line: line)
}
