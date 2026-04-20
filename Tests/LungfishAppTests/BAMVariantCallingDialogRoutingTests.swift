import XCTest
@testable import LungfishApp
@testable import LungfishCore
@testable import LungfishIO
@testable import LungfishWorkflow

private actor StubVariantCallingPackStatusProvider: PluginPackStatusProviding {
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
    func testDialogStateBlocksIVarUntilPrimerTrimAcknowledged() {
        let state = BAMVariantCallingDialogState(bundle: makeBundleFixture())

        state.selectCaller(.ivar)

        XCTAssertFalse(state.isRunEnabled)

        state.ivarPrimerTrimConfirmed = true

        XCTAssertTrue(state.isRunEnabled)
    }

    @MainActor
    func testDialogStateBlocksMedakaUntilModelIsProvided() {
        let state = BAMVariantCallingDialogState(bundle: makeBundleFixture())

        state.selectCaller(.medaka)

        XCTAssertFalse(state.isRunEnabled)

        state.medakaModel = "r1041_e82_400bps_sup_v5.0.0"

        XCTAssertTrue(state.isRunEnabled)
    }

    func testCatalogDisablesAllToolsWhenVariantCallingPackIsMissing() async {
        let catalog = BAMVariantCallingCatalog(
            statusProvider: StubVariantCallingPackStatusProvider(states: ["variant-calling": .needsInstall])
        )

        let items = await catalog.sidebarItems()

        XCTAssertEqual(items.count, ViralVariantCaller.allCases.count)
        XCTAssertTrue(items.allSatisfy { $0.availability != .available })
    }

    @MainActor
    func testDialogStateBlocksRunWhenSelectedCallerIsUnavailable() async {
        let sidebarItems = await BAMVariantCallingCatalog(
            statusProvider: StubVariantCallingPackStatusProvider(states: ["variant-calling": .needsInstall])
        ).sidebarItems()
        let state = BAMVariantCallingDialogState(
            bundle: makeBundleFixture(),
            sidebarItems: sidebarItems
        )

        XCTAssertFalse(state.isRunEnabled)
        XCTAssertTrue(state.readinessText.contains("Requires Variant Calling Pack"))
    }

    @MainActor
    func testDialogStateAutoSuffixesDefaultTrackNameWhenCollisionExists() {
        let state = BAMVariantCallingDialogState(
            bundle: makeBundleFixture(existingVariantTrackNames: ["Sample 1 • LoFreq"])
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

    private func makeBundleFixture(existingVariantTrackNames: [String] = []) -> ReferenceBundle {
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
            alignments: [
                AlignmentTrackInfo(
                    id: "aln-1",
                    name: "Sample 1",
                    format: .bam,
                    sourcePath: "alignments/sample.sorted.bam",
                    indexPath: "alignments/sample.sorted.bam.bai",
                    checksumSHA256: "bam-sha"
                )
            ]
        )

        return ReferenceBundle(
            url: tempDir.appendingPathComponent("Bundle.lungfishref", isDirectory: true),
            manifest: manifest
        )
    }

    private func repositoryRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }
}
