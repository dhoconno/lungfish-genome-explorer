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

@MainActor
final class PluginPackVisibilityTests: XCTestCase {

    func testViewModelExposesRequiredSetupSeparatelyFromOptionalPacks() async {
        let required = PluginPackStatus(
            pack: .requiredSetupPack,
            state: .needsInstall,
            toolStatuses: [],
            failureMessage: nil
        )
        let optional = PluginPackStatus(
            pack: PluginPack.activeOptionalPacks[0],
            state: .needsInstall,
            toolStatuses: [],
            failureMessage: nil
        )
        let viewModel = PluginManagerViewModel(
            packStatusProvider: StubPluginManagerPackStatusProvider(statuses: [required, optional])
        )

        await viewModel.loadPackStatuses()

        XCTAssertEqual(viewModel.requiredSetupPack?.pack.id, "lungfish-tools")
        XCTAssertEqual(viewModel.optionalPackStatuses.map(\.pack.id), ["metagenomics"])
    }

    func testFocusPackSelectsPacksTabAndStoresPackID() {
        let viewModel = PluginManagerViewModel(
            packStatusProvider: StubPluginManagerPackStatusProvider(statuses: [])
        )

        viewModel.focusPack("metagenomics")

        XCTAssertEqual(viewModel.selectedTab, .packs)
        XCTAssertEqual(viewModel.focusedPackID, "metagenomics")
    }
}
