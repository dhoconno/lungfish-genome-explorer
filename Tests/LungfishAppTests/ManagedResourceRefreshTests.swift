import XCTest
@testable import LungfishApp
@testable import LungfishWorkflow
@testable import LungfishCore

private actor StubManagedResourcePackStatusProvider: PluginPackStatusProviding {
    let statuses: [PluginPackStatus]

    init(statuses: [PluginPackStatus]) {
        self.statuses = statuses
    }

    func visibleStatuses() async -> [PluginPackStatus] { statuses }

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

@MainActor
final class ManagedResourceRefreshTests: XCTestCase {
    override func setUpWithError() throws {
        // The test injects a pack status provider, the in-process route. The default route runs
        // `lungfish-cli conda install --pack` (lane A52), which an injected provider never reaches.
        ManagedToolsRouteSettings.testOverride = .legacy
    }

    override func tearDownWithError() throws {
        ManagedToolsRouteSettings.testOverride = nil
    }

    func testInstallPackPostsManagedResourcesDidChange() async {
        let center = NotificationCenter()
        let required = PluginPackStatus(
            pack: .requiredSetupPack,
            state: .needsInstall,
            toolStatuses: [],
            failureMessage: nil
        )
        let provider = StubManagedResourcePackStatusProvider(statuses: [required])
        let viewModel = PluginManagerViewModel(
            packStatusProvider: provider,
            notificationCenter: center
        )

        let exp = expectation(description: "managed resources change posted")
        let token = center.addObserver(
            forName: .managedResourcesDidChange,
            object: nil,
            queue: nil
        ) { _ in
            exp.fulfill()
        }
        defer { center.removeObserver(token) }

        viewModel.installPack(PluginPack.requiredSetupPack)
        await fulfillment(of: [exp], timeout: 10.0)
    }
}
