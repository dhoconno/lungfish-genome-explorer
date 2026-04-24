import XCTest
@testable import LungfishApp
@testable import LungfishWorkflow

private actor FakePackStatusProvider: PluginPackStatusProviding {
    let state: PluginPackState

    init(state: PluginPackState) {
        self.state = state
    }

    func visibleStatuses() async -> [PluginPackStatus] { [] }

    func status(for pack: PluginPack) async -> PluginPackStatus {
        PluginPackStatus(pack: pack, state: state, toolStatuses: [], failureMessage: nil)
    }

    func status(forPackID packID: String) async -> PluginPackStatus? {
        guard let pack = PluginPack.builtInPack(id: packID) else { return nil }
        return PluginPackStatus(pack: pack, state: state, toolStatuses: [], failureMessage: nil)
    }

    func invalidateVisibleStatusesCache() async {}

    func install(
        pack: PluginPack,
        reinstall: Bool,
        progress: (@Sendable (PluginPackInstallProgress) -> Void)?
    ) async throws {}
}

final class BAMPrimerTrimCatalogTests: XCTestCase {
    func testAvailabilityReadyWhenPackReady() async {
        let catalog = BAMPrimerTrimCatalog(
            statusProvider: FakePackStatusProvider(state: .ready)
        )
        let availability = await catalog.availability()
        XCTAssertEqual(availability, .available)
    }

    func testAvailabilityDisabledWhenPackNotReady() async {
        let catalog = BAMPrimerTrimCatalog(
            statusProvider: FakePackStatusProvider(state: .needsInstall)
        )
        let availability = await catalog.availability()
        if case .disabled(let reason) = availability {
            XCTAssertTrue(reason.contains("Variant Calling"))
        } else {
            XCTFail("expected disabled, got \(availability)")
        }
    }

    func testAvailabilityDisabledForAllNonReadyStates() async {
        for state: PluginPackState in [.needsInstall, .installing, .failed] {
            let catalog = BAMPrimerTrimCatalog(
                statusProvider: FakePackStatusProvider(state: state)
            )
            let availability = await catalog.availability()
            guard case .disabled = availability else {
                XCTFail("expected disabled for state \(state), got \(availability)")
                continue
            }
        }
    }
}
