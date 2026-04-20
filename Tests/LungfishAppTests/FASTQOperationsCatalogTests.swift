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

    func testAssemblyCategoryUsesBuiltInPackNameForDisabledReason() async throws {
        let provider = StubPackStatusProvider(states: ["assembly": .needsInstall])
        let catalog = FASTQOperationsCatalog(statusProvider: provider)

        let resolvedCategory = await catalog.category(id: .assembly)
        let category = try XCTUnwrap(resolvedCategory)
        XCTAssertFalse(category.isEnabled)
        XCTAssertEqual(category.disabledReason, "Requires Genome Assembly Pack")
    }

    func testAllRequiredPackIDsResolveToBuiltInPacks() {
        let requiredPackIDs = FASTQOperationCategoryID.allCases
            .flatMap(\.requiredPackIDs)

        XCTAssertFalse(requiredPackIDs.isEmpty)

        for packID in requiredPackIDs {
            XCTAssertNotNil(PluginPack.builtInPack(id: packID), "Missing built-in pack for \(packID)")
        }
    }

    func testPackLookupReturnsNilForUnknownPackID() async {
        let provider: any PluginPackStatusProviding = StubPackStatusProvider(states: [:])

        let status = await provider.status(forPackID: "unknown-pack")

        XCTAssertNil(status)
    }
}
