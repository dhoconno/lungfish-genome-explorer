import XCTest
import ViewInspector
@testable import LungfishApp
@testable import LungfishCore
@testable import LungfishIO
@testable import LungfishKit
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

    @MainActor
    func testVariantCallingDialogUsesExtraArgumentsLabel() throws {
        let state = BAMVariantCallingDialogState(bundle: try makeBundleFixture())
        let view = BAMVariantCallingToolPanes(state: state)

        // Converted from source-text grep (see git history) to a ViewInspector
        // assertion on the actual rendered section: the "Extra arguments" heading
        // renders, and no legacy "Advanced Options" heading is present alongside it.
        let headings = try view.inspect().findAll(ViewType.Text.self).compactMap { try? $0.string() }
        XCTAssertTrue(headings.contains("Extra arguments"))
        XCTAssertFalse(headings.contains("Advanced Options"))
    }

    @MainActor
    func testVariantCallingDialogUsesSharedScientificHelpCatalog() throws {
        let state = BAMVariantCallingDialogState(bundle: try makeBundleFixture())
        let view = BAMVariantCallingToolPanes(state: state)
        let inspected = try view.inspect()

        // Converted from source-text grep to behavioral assertions: each control's
        // rendered `.help()` text is the *same string instance* as the named
        // LungfishHelpContent catalog entry's summary, proving the modifier is
        // actually wired to that catalog item at runtime (not just present in source).
        let alignmentTrackPicker = try inspected.find(ViewType.Picker.self)
        XCTAssertEqual(try alignmentTrackPicker.help().string(), LungfishHelpContent.bamVariantAlignmentTrack.summary)

        let outputTrackField = try inspected.find(ViewType.TextField.self, where: { tf in
            (try? tf.labelView().text().string()) == "Output Variant Track Name"
        })
        XCTAssertEqual(try outputTrackField.help().string(), LungfishHelpContent.bamVariantOutputTrack.summary)

        let mafField = try inspected.find(ViewType.TextField.self, where: { tf in
            (try? tf.labelView().text().string()) == "0.05"
        })
        XCTAssertEqual(try mafField.help().string(), LungfishHelpContent.bamVariantThresholds.summary)

        let advancedField = try inspected.find(ViewType.TextField.self, where: { tf in
            (try? tf.labelView().text().string()) == "--call-indels"
        })
        XCTAssertEqual(try advancedField.help().string(), LungfishHelpContent.fastqAdvancedArguments.summary)

        let readinessText = try inspected.find(text: state.readinessText)
        XCTAssertEqual(try readinessText.help().string(), LungfishHelpContent.operationReadiness.summary)

        // iVar-specific controls (primer-trim toggle, consensus AF/merge-AF/bad-quality
        // fields) only render once iVar is the selected caller.
        state.selectCaller(.ivar)
        let ivarInspected = try BAMVariantCallingToolPanes(state: state).inspect()

        let primerTrimToggle = try ivarInspected.find(ViewType.Toggle.self)
        XCTAssertEqual(try primerTrimToggle.help().string(), LungfishHelpContent.bamVariantIvarPrimerTrim.summary)

        let consensusAFField = try ivarInspected.find(ViewType.TextField.self, where: { tf in
            (try? tf.labelView().text().string()) == "0.75"
        })
        XCTAssertEqual(try consensusAFField.help().string(), LungfishHelpContent.bamVariantIvarConsensusAF.summary)

        let mergeAFField = try ivarInspected.find(ViewType.TextField.self, where: { tf in
            (try? tf.labelView().text().string()) == "0.25"
        })
        XCTAssertEqual(try mergeAFField.help().string(), LungfishHelpContent.bamVariantIvarMergeAF.summary)

        let badQualityField = try ivarInspected.find(ViewType.TextField.self, where: { tf in
            (try? tf.labelView().text().string()) == "20"
        })
        XCTAssertEqual(try badQualityField.help().string(), LungfishHelpContent.bamVariantIvarBadQuality.summary)

        // ONT model field (medaka) only renders once medaka is the selected caller.
        state.selectCaller(.medaka)
        let medakaInspected = try BAMVariantCallingToolPanes(state: state).inspect()
        let modelField = try medakaInspected.find(ViewType.TextField.self, where: { tf in
            (try? tf.labelView().text().string()) == "r1041_e82_400bps_sup_v5.0.0"
        })
        XCTAssertEqual(try modelField.help().string(), LungfishHelpContent.bamVariantOntModel.summary)
    }

    @MainActor
    func testPrimerTrimDialogUsesSharedScientificHelpCatalog() throws {
        let state = BAMPrimerTrimDialogState(
            bundle: try makeBundleFixture(),
            availability: .available,
            builtInSchemes: [],
            projectSchemes: []
        )
        let view = BAMPrimerTrimToolPanes(state: state, onBrowseScheme: {})
        let inspected = try view.inspect()

        // source-text: no runtime seam — see docs/reports/2026-08-21-test-suite-review.md §3
        // PrimerSchemePickerView (Sources/LungfishApp/Views/BAM/PrimerSchemePickerView.swift:10)
        // is a plain custom View with no inspection conformance, so ViewInspector's tree
        // walk can't reach the `.lungfishHelp(LungfishHelpContent.bamPrimerScheme)`
        // modifier applied to it in overviewSection. Revisit if an inspection seam
        // (e.g. Inspectable conformance) is added to that view.
        let source = try String(
            contentsOf: repositoryRoot()
                .appendingPathComponent("Sources/LungfishApp/Views/BAM/BAMPrimerTrimToolPanes.swift"),
            encoding: .utf8
        )
        XCTAssertTrue(source.contains(".lungfishHelp(LungfishHelpContent.bamPrimerScheme)"))

        // Converted from source-text grep to behavioral assertions on the actual
        // rendered controls and their bound LungfishHelpContent catalog entries.
        let alignmentTrackPicker = try inspected.find(ViewType.Picker.self, where: { picker in
            (try? picker.labelView().text().string()) == "Alignment Track"
        })
        XCTAssertEqual(try alignmentTrackPicker.help().string(), LungfishHelpContent.bamPrimerTrimAlignmentTrack.summary)

        let outputTrackField = try inspected.find(ViewType.TextField.self, where: { tf in
            (try? tf.labelView().text().string()) == "Output Track Name"
        })
        XCTAssertEqual(try outputTrackField.help().string(), LungfishHelpContent.bamPrimerTrimOutputTrack.summary)

        let retainedReadsText = try inspected.find(ViewType.Text.self, where: { text in
            (try? text.string())?.contains("Reads without matching primers are retained") == true
        })
        XCTAssertEqual(
            try retainedReadsText.help().string(),
            LungfishHelpContent.bamPrimerTrimRetainsUnmatchedReads.summary
        )

        // The advanced-options fields are wrapped by `labeledField(...)` (a
        // Text label + TextField VStack); `.lungfishHelp(...)` is applied to
        // that wrapping VStack, not the TextField itself, so the help lookup
        // targets the VStack containing the matching TextField.
        XCTAssertEqual(
            try InspectableView.lungfishSoleTextFieldGroup(in: inspected, placeholderOrLabel: "30").help().string(),
            LungfishHelpContent.bamPrimerTrimMinReadLength.summary
        )
        XCTAssertEqual(
            try InspectableView.lungfishSoleTextFieldGroup(in: inspected, placeholderOrLabel: "20").help().string(),
            LungfishHelpContent.bamPrimerTrimMinQuality.summary
        )
        XCTAssertEqual(
            try InspectableView.lungfishSoleTextFieldGroup(in: inspected, placeholderOrLabel: "4").help().string(),
            LungfishHelpContent.bamPrimerTrimSlidingWindow.summary
        )
        XCTAssertEqual(
            try InspectableView.lungfishSoleTextFieldGroup(in: inspected, placeholderOrLabel: "0").help().string(),
            LungfishHelpContent.bamPrimerTrimOffset.summary
        )

        let readinessText = try inspected.find(text: state.readinessText)
        XCTAssertEqual(try readinessText.help().string(), LungfishHelpContent.operationReadiness.summary)
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
    func testDialogStateCarriesIvarOptionsIntoPendingRequest() throws {
        let state = BAMVariantCallingDialogState(bundle: try makeBundleFixture())

        state.selectCaller(.ivar)
        state.ivarPrimerTrimConfirmed = true
        state.ivarConsensusAF = 0.8
        state.ivarMergeAFThreshold = 0.2
        state.ivarBadQualityThreshold = 25
        state.ivarIgnoreStrandBias = false
        state.prepareForRun()

        let request = try XCTUnwrap(state.pendingRequest)
        XCTAssertEqual(request.caller, .ivar)
        XCTAssertEqual(request.ivarConsensusAF, 0.8)
        XCTAssertEqual(request.ivarMergeAFThreshold, 0.2)
        XCTAssertEqual(request.ivarBadQualityThreshold, 25)
        XCTAssertFalse(request.ivarIgnoreStrandBias)
    }

    @MainActor
    func testDialogStateBlocksInvalidIvarThresholdRanges() throws {
        let state = BAMVariantCallingDialogState(bundle: try makeBundleFixture())

        state.selectCaller(.ivar)
        state.ivarPrimerTrimConfirmed = true

        state.ivarConsensusAF = 1.1
        XCTAssertFalse(state.isRunEnabled)
        XCTAssertEqual(state.readinessText, "iVar consensus allele frequency must be between 0 and 1.")

        state.ivarConsensusAF = 0.8
        state.ivarMergeAFThreshold = -0.1
        XCTAssertFalse(state.isRunEnabled)
        XCTAssertEqual(state.readinessText, "iVar merge allele-frequency threshold must be between 0 and 1.")

        state.ivarMergeAFThreshold = 0.2
        state.ivarBadQualityThreshold = -1
        XCTAssertFalse(state.isRunEnabled)
        XCTAssertEqual(state.readinessText, "iVar bad-quality threshold must be zero or greater.")
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

        // source-text: no runtime seam — see docs/reports/2026-08-21-test-suite-review.md §3
        // F3 (ViewInspector adoption) evaluated this one and left it tagged: the
        // "Call Variants…" button lives in `AnalysisSection.variantCallingSection`,
        // reached only by first driving `AnalysisSubsectionGrid`'s private
        // `@State private var selectedSubsection` to `.variantCalling` (default is
        // `.filtering`). ViewInspector can only observe/drive `@State` after the
        // view adds an `onAppear`/`Inspection<Self>` seam (see ViewInspector's
        // "Views using @State" guide) — a production-source change out of scope for
        // a source-text -> ViewInspector *test* conversion. `.disabled()` itself IS
        // genuinely reachable by ViewInspector once a view is instantiated (proven in
        // this file's converted `BAMVariantCallingToolPanes`/`BAMPrimerTrimToolPanes`
        // tests above); the blocker here is exclusively the private `@State`
        // subsection router, not the `.disabled()` modifier.
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

        // source-text: no runtime seam — see docs/reports/2026-08-21-test-suite-review.md §3
        // F3 (ViewInspector adoption): same blocker as
        // testReadStyleSectionSourceDisablesCallVariantsUsingEligibilityFlag above —
        // the "Call Variants…" button only renders once `AnalysisSection`'s private
        // `@State private var selectedSubsection` is driven to `.variantCalling`,
        // which ViewInspector cannot do without a production-source
        // onAppear/Inspection<Self> seam (out of scope for this conversion).
        XCTAssertTrue(source.contains("onCallVariantsRequested"))
        XCTAssertTrue(source.contains("Call Variants"))
    }

    func testInspectorControllerSourceWiresCallVariantsWorkflow() throws {
        let source = combinedInspectorViewControllerSource()

        // source-text: no runtime seam — see docs/reports/2026-08-21-test-suite-review.md §3
        // onCallVariantsRequested is a real closure property on ReadStyleSectionViewModel
        // (a genuine injected-closure seam), wired up inside
        // InspectorViewController.updateAlignmentSection(from:). Exercising it end-to-end
        // means constructing a full ReferenceBundle fixture, calling
        // updateAlignmentSection, invoking the closure, and observing that
        // runCallVariantsWorkflow() presents a real NSWindow-backed dialog
        // (presentVariantCallingDialog reads view.window/NSApp.keyWindow and can spawn an
        // NSAlert) -- exercising that safely and deterministically in a unit test is out
        // of scope for this task; no test in this file currently sets up that wiring.
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
