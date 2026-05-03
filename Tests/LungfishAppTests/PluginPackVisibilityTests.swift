import XCTest
@testable import LungfishApp
@testable import LungfishWorkflow

private actor StubPluginManagerPackStatusProvider: PluginPackStatusProviding {
    let statuses: [PluginPackStatus]

    init(statuses: [PluginPackStatus]) {
        self.statuses = statuses
    }

    func visibleStatuses() async -> [PluginPackStatus] {
        statuses
    }

    func status(for pack: PluginPack) async -> PluginPackStatus {
        statuses.first(where: { $0.pack.id == pack.id })!
    }

    func invalidateVisibleStatusesCache() async {}

    func install(
        pack: PluginPack,
        reinstall: Bool,
        progress: (@Sendable (PluginPackInstallProgress) -> Void)?
    ) async throws {
        progress?(PluginPackInstallProgress(
            requirementID: nil,
            requirementDisplayName: nil,
            overallFraction: 1.0,
            itemFraction: 1.0,
            message: "Installed"
        ))
    }
}

private final class DelayedPluginManagerPackStatusProvider: @unchecked Sendable, PluginPackStatusProviding {
    let statuses: [PluginPackStatus]
    private let lock = NSLock()
    private var continuations: [CheckedContinuation<Void, Never>] = []

    init(statuses: [PluginPackStatus]) {
        self.statuses = statuses
    }

    func visibleStatuses() async -> [PluginPackStatus] {
        await withCheckedContinuation { continuation in
            lock.withLock {
                continuations.append(continuation)
            }
        }
        return statuses
    }

    func status(for pack: PluginPack) async -> PluginPackStatus {
        statuses.first(where: { $0.pack.id == pack.id })!
    }

    func invalidateVisibleStatusesCache() async {}

    func install(
        pack: PluginPack,
        reinstall: Bool,
        progress: (@Sendable (PluginPackInstallProgress) -> Void)?
    ) async throws {}

    func release() {
        let pending = lock.withLock {
            let pending = continuations
            continuations.removeAll()
            return pending
        }
        for continuation in pending {
            continuation.resume()
        }
    }
}

private actor CacheAwarePluginManagerPackStatusProvider: PluginPackStatusProviding {
    let pack: PluginPack
    private let installedStatuses: [PluginPackStatus]
    private let removedStatuses: [PluginPackStatus]
    private var currentStatuses: [PluginPackStatus]
    private var invalidationCount = 0

    init(pack: PluginPack, installedStatuses: [PluginPackStatus], removedStatuses: [PluginPackStatus]) {
        self.pack = pack
        self.installedStatuses = installedStatuses
        self.removedStatuses = removedStatuses
        self.currentStatuses = installedStatuses
    }

    func visibleStatuses() async -> [PluginPackStatus] {
        currentStatuses
    }

    func status(for pack: PluginPack) async -> PluginPackStatus {
        currentStatuses.first(where: { $0.pack.id == pack.id })!
    }

    func invalidateVisibleStatusesCache() async {
        invalidationCount += 1
        currentStatuses = removedStatuses
    }

    func install(
        pack: PluginPack,
        reinstall: Bool,
        progress: (@Sendable (PluginPackInstallProgress) -> Void)?
    ) async throws {}

    func recordedInvalidationCount() -> Int {
        invalidationCount
    }
}

@MainActor
final class PluginPackVisibilityTests: XCTestCase {

    func testViewModelExposesRequiredSetupSeparatelyFromOptionalPacks() async {
        guard let readMapping = PluginPack.activeOptionalPacks.first(where: { $0.id == "read-mapping" }) else {
            XCTFail("Expected active read-mapping pack")
            return
        }
        guard let variantCalling = PluginPack.activeOptionalPacks.first(where: { $0.id == "variant-calling" }) else {
            XCTFail("Expected active variant-calling pack")
            return
        }
        guard let assembly = PluginPack.activeOptionalPacks.first(where: { $0.id == "assembly" }) else {
            XCTFail("Expected active assembly pack")
            return
        }
        guard let msa = PluginPack.activeOptionalPacks.first(where: { $0.id == "multiple-sequence-alignment" }) else {
            XCTFail("Expected active multiple sequence alignment pack")
            return
        }
        guard let phylogenetics = PluginPack.activeOptionalPacks.first(where: { $0.id == "phylogenetics" }) else {
            XCTFail("Expected active phylogenetics pack")
            return
        }
        guard let metagenomics = PluginPack.activeOptionalPacks.first(where: { $0.id == "metagenomics" }) else {
            XCTFail("Expected active metagenomics pack")
            return
        }
        let required = PluginPackStatus(
            pack: .requiredSetupPack,
            state: .needsInstall,
            toolStatuses: [],
            failureMessage: nil
        )
        let readMappingStatus = PluginPackStatus(
            pack: readMapping,
            state: .needsInstall,
            toolStatuses: [],
            failureMessage: nil
        )
        let variantCallingStatus = PluginPackStatus(
            pack: variantCalling,
            state: .needsInstall,
            toolStatuses: [],
            failureMessage: nil
        )
        let assemblyStatus = PluginPackStatus(
            pack: assembly,
            state: .needsInstall,
            toolStatuses: [],
            failureMessage: nil
        )
        let msaStatus = PluginPackStatus(
            pack: msa,
            state: .needsInstall,
            toolStatuses: [],
            failureMessage: nil
        )
        let phylogeneticsStatus = PluginPackStatus(
            pack: phylogenetics,
            state: .needsInstall,
            toolStatuses: [],
            failureMessage: nil
        )
        let metagenomicsStatus = PluginPackStatus(
            pack: metagenomics,
            state: .needsInstall,
            toolStatuses: [],
            failureMessage: nil
        )
        let viewModel = PluginManagerViewModel(
            packStatusProvider: StubPluginManagerPackStatusProvider(statuses: [
                required,
                readMappingStatus,
                variantCallingStatus,
                assemblyStatus,
                msaStatus,
                phylogeneticsStatus,
                metagenomicsStatus,
            ])
        )

        await viewModel.loadPackStatuses()

        XCTAssertEqual(viewModel.requiredSetupPack?.pack.id, "lungfish-tools")
        XCTAssertEqual(viewModel.optionalPackStatuses.map(\.pack.id), [
            "read-mapping",
            "variant-calling",
            "assembly",
            "multiple-sequence-alignment",
            "phylogenetics",
            "metagenomics",
        ])
    }

    func testFocusPackSelectsPacksTabAndStoresPackID() {
        let viewModel = PluginManagerViewModel(
            packStatusProvider: StubPluginManagerPackStatusProvider(statuses: [])
        )

        viewModel.focusPack("metagenomics")

        XCTAssertEqual(viewModel.selectedTab, .packs)
        XCTAssertEqual(viewModel.focusedPackID, "metagenomics")
    }

    func testRefreshPackStatusesExposesLoadingStateWhileStatusesArePending() async {
        let required = PluginPackStatus(
            pack: .requiredSetupPack,
            state: .needsInstall,
            toolStatuses: [],
            failureMessage: nil
        )
        let provider = DelayedPluginManagerPackStatusProvider(statuses: [required])
        let viewModel = PluginManagerViewModel(packStatusProvider: provider)

        try? await Task.sleep(for: .milliseconds(20))

        XCTAssertTrue(viewModel.isLoadingPackStatuses)
        XCTAssertNil(viewModel.requiredSetupPack)

        provider.release()
        try? await Task.sleep(for: .milliseconds(50))

        XCTAssertFalse(viewModel.isLoadingPackStatuses)
        XCTAssertEqual(viewModel.requiredSetupPack?.pack.id, "lungfish-tools")
    }

    func testRemovePackInvalidatesCachedPackStatuses() async {
        let pack = PluginPack(
            id: "cache-test-pack",
            name: "Cache Test Pack",
            description: "Test pack for cache invalidation",
            sfSymbol: "shippingbox",
            packages: [],
            category: "Testing"
        )

        let installed = PluginPackStatus(
            pack: pack,
            state: .ready,
            toolStatuses: [],
            failureMessage: nil
        )
        let removed = PluginPackStatus(
            pack: pack,
            state: .needsInstall,
            toolStatuses: [],
            failureMessage: nil
        )
        let provider = CacheAwarePluginManagerPackStatusProvider(
            pack: pack,
            installedStatuses: [installed],
            removedStatuses: [removed]
        )
        let viewModel = PluginManagerViewModel(packStatusProvider: provider)

        await viewModel.loadPackStatuses()
        XCTAssertEqual(viewModel.optionalPackStatuses.first?.state, .ready)

        viewModel.removePack(pack)
        try? await Task.sleep(for: .milliseconds(50))

        let invalidationCount = await provider.recordedInvalidationCount()
        XCTAssertEqual(invalidationCount, 1)
        XCTAssertEqual(viewModel.optionalPackStatuses.first?.state, .needsInstall)
    }

    func testRemovePackPostsManagedResourcesDidChange() async {
        let center = NotificationCenter()
        let pack = PluginPack(
            id: "notify-pack",
            name: "Notify Pack",
            description: "Test pack for notification coverage",
            sfSymbol: "shippingbox",
            packages: [],
            category: "Testing"
        )
        let installed = PluginPackStatus(
            pack: pack,
            state: .ready,
            toolStatuses: [],
            failureMessage: nil
        )
        let removed = PluginPackStatus(
            pack: pack,
            state: .needsInstall,
            toolStatuses: [],
            failureMessage: nil
        )
        let provider = CacheAwarePluginManagerPackStatusProvider(
            pack: pack,
            installedStatuses: [installed],
            removedStatuses: [removed]
        )
        let viewModel = PluginManagerViewModel(
            packStatusProvider: provider,
            notificationCenter: center
        )

        await viewModel.loadPackStatuses()

        let exp = expectation(description: "managed resources change posted")
        let token = center.addObserver(
            forName: .managedResourcesDidChange,
            object: nil,
            queue: nil
        ) { _ in
            exp.fulfill()
        }
        defer { center.removeObserver(token) }

        viewModel.removePack(pack)
        await fulfillment(of: [exp], timeout: 1.0)
    }
}
