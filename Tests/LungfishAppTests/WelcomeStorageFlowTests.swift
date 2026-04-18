import XCTest
@testable import LungfishApp
@testable import LungfishCore
@testable import LungfishWorkflow

private actor SequencedWelcomeStorageStatusProvider: PluginPackStatusProviding {
    private let sequences: [[PluginPackStatus]]
    private var index = 0

    init(sequences: [[PluginPackStatus]]) {
        self.sequences = sequences
    }

    func visibleStatuses() async -> [PluginPackStatus] {
        let current = sequences[min(index, sequences.count - 1)]
        index += 1
        return current
    }

    func status(for pack: PluginPack) async -> PluginPackStatus {
        sequences.flatMap { $0 }.first(where: { $0.pack.id == pack.id })!
    }

    func invalidateVisibleStatusesCache() async {}

    func install(
        pack: PluginPack,
        reinstall: Bool,
        progress: (@Sendable (PluginPackInstallProgress) -> Void)?
    ) async throws {}
}

private final class DelayedInstallWelcomeStatusProvider: @unchecked Sendable, PluginPackStatusProviding {
    let statuses: [PluginPackStatus]
    private let lock = NSLock()
    private var installContinuation: CheckedContinuation<Void, Never>?

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
            overallFraction: 0.1,
            itemFraction: 0.1,
            message: "Installing"
        ))

        await withCheckedContinuation { continuation in
            lock.withLock {
                installContinuation = continuation
            }
        }
    }

    func releaseInstall() {
        let continuation = lock.withLock {
            let continuation = installContinuation
            installContinuation = nil
            return continuation
        }
        continuation?.resume()
    }
}

private final class DelayedRefreshWelcomeStatusProvider: @unchecked Sendable, PluginPackStatusProviding {
    let statuses: [PluginPackStatus]
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Never>?

    init(statuses: [PluginPackStatus]) {
        self.statuses = statuses
    }

    func visibleStatuses() async -> [PluginPackStatus] {
        await withCheckedContinuation { continuation in
            lock.withLock {
                self.continuation = continuation
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
        let continuation = lock.withLock {
            let continuation = self.continuation
            self.continuation = nil
            return continuation
        }
        continuation?.resume()
    }
}

final class WelcomeStorageFlowTests: XCTestCase {
    private var tempHome: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempHome = FileManager.default.temporaryDirectory
            .appendingPathComponent("welcome-storage-flow-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempHome, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let tempHome {
            try? FileManager.default.removeItem(at: tempHome)
        }
        tempHome = nil
        try super.tearDownWithError()
    }

    @MainActor
    func testChooseAlternateStorageLocationShowsChooser() {
        let store = ManagedStorageConfigStore(homeDirectory: tempHome)
        let viewModel = WelcomeViewModel(
            statusProvider: SequencedWelcomeStorageStatusProvider(sequences: [[requiredStatus(state: .needsInstall)]]),
            storageConfigStore: store
        )

        XCTAssertFalse(viewModel.showingStorageChooser)
        XCTAssertNil(viewModel.pendingStorageSelection)
        XCTAssertFalse(viewModel.canConfirmStorageSelection)

        viewModel.chooseAlternateStorageLocation()

        XCTAssertTrue(viewModel.showingStorageChooser)
    }

    @MainActor
    func testCannotConfirmSelectionWhenResolvedPathContainsSpaces() async throws {
        let store = ManagedStorageConfigStore(homeDirectory: tempHome)
        let defaultRoot = store.defaultLocation.rootURL
        let invalidSelection = URL(fileURLWithPath: "/Volumes/My SSD/Lungfish", isDirectory: true)
        let coordinator = ManagedStorageCoordinator(
            configStore: store,
            databaseMigrator: { _, _ in },
            toolInstaller: { _ in },
            verifier: { _ in }
        )
        let viewModel = WelcomeViewModel(
            statusProvider: SequencedWelcomeStorageStatusProvider(sequences: [[requiredStatus(state: .needsInstall)]]),
            storageCoordinator: coordinator,
            storageConfigStore: store
        )

        let result = viewModel.validateStorageSelection(invalidSelection)

        XCTAssertEqual(result, .invalid(.containsSpaces))

        viewModel.chooseAlternateStorageLocation()
        viewModel.updatePendingStorageSelection(invalidSelection)
        try await viewModel.confirmAlternateStorageLocation()

        XCTAssertEqual(store.currentLocation().rootURL, defaultRoot)
        XCTAssertFalse(viewModel.canConfirmStorageSelection)
        XCTAssertEqual(viewModel.storageValidationResult, .invalid(.containsSpaces))
    }

    @MainActor
    func testResolvedSelectionMatchingCurrentRootIsRejected() async throws {
        let store = ManagedStorageConfigStore(homeDirectory: tempHome)
        let currentRoot = store.defaultLocation.rootURL
        try FileManager.default.createDirectory(at: currentRoot, withIntermediateDirectories: true)

        let symlinkRoot = tempHome.appendingPathComponent("current-root-link", isDirectory: false)
        try FileManager.default.createSymbolicLink(
            at: symlinkRoot,
            withDestinationURL: currentRoot
        )

        let coordinator = ManagedStorageCoordinator(
            configStore: store,
            databaseMigrator: { _, _ in
                XCTFail("Migration should not run when the resolved selection matches the current root")
            },
            toolInstaller: { _ in
                XCTFail("Tool install should not run when the resolved selection matches the current root")
            },
            verifier: { _ in
                XCTFail("Verification should not run when the resolved selection matches the current root")
            }
        )
        let viewModel = WelcomeViewModel(
            statusProvider: SequencedWelcomeStorageStatusProvider(sequences: [[requiredStatus(state: .needsInstall)]]),
            storageCoordinator: coordinator,
            storageConfigStore: store
        )

        viewModel.chooseAlternateStorageLocation()
        viewModel.updatePendingStorageSelection(symlinkRoot)
        try await viewModel.confirmAlternateStorageLocation()

        XCTAssertEqual(viewModel.pendingStorageSelection, currentRoot.resolvingSymlinksInPath().standardizedFileURL)
        XCTAssertEqual(viewModel.storageValidationResult, .valid)
        XCTAssertFalse(viewModel.canConfirmStorageSelection)
        XCTAssertEqual(store.currentLocation().rootURL, currentRoot)
    }

    @MainActor
    func testConfirmAlternateStorageLocationChangesStorageAndRefreshesSetup() async throws {
        let store = ManagedStorageConfigStore(homeDirectory: tempHome)
        let newRoot = tempHome.appendingPathComponent("ExternalManagedStorage", isDirectory: true)
        let provider = SequencedWelcomeStorageStatusProvider(sequences: [
            [requiredStatus(state: .needsInstall)],
            [requiredStatus(state: .ready)]
        ])
        let coordinator = ManagedStorageCoordinator(
            configStore: store,
            databaseMigrator: { _, _ in },
            toolInstaller: { _ in },
            verifier: { _ in }
        )
        let viewModel = WelcomeViewModel(
            statusProvider: provider,
            storageCoordinator: coordinator,
            storageConfigStore: store
        )

        await viewModel.refreshSetup()
        XCTAssertEqual(viewModel.requiredSetupStatus?.state, .needsInstall)

        viewModel.chooseAlternateStorageLocation()
        viewModel.updatePendingStorageSelection(newRoot)
        try await viewModel.confirmAlternateStorageLocation()

        XCTAssertEqual(store.currentLocation().rootURL, newRoot.standardizedFileURL)
        XCTAssertEqual(viewModel.requiredSetupStatus?.state, .ready)
        XCTAssertFalse(viewModel.showingStorageChooser)
    }

    @MainActor
    func testChooseAlternateStorageLocationIsRejectedWhileInstallIsActive() async throws {
        let provider = DelayedInstallWelcomeStatusProvider(statuses: [requiredStatus(state: .needsInstall)])
        let viewModel = WelcomeViewModel(statusProvider: provider)
        let alternateRoot = tempHome.appendingPathComponent("AlternateManagedRoot", isDirectory: true)

        await viewModel.refreshSetup()
        viewModel.updatePendingStorageSelection(alternateRoot)
        XCTAssertTrue(viewModel.canConfirmStorageSelection)

        viewModel.installRequiredSetup()
        await Task.yield()

        XCTAssertTrue(viewModel.isInstallingRequiredSetup)

        viewModel.chooseAlternateStorageLocation()

        XCTAssertFalse(viewModel.showingStorageChooser)
        XCTAssertFalse(viewModel.canConfirmStorageSelection)

        provider.releaseInstall()
    }

    @MainActor
    func testChooseAlternateStorageLocationIsRejectedWhileRefreshIsActive() async {
        let provider = DelayedRefreshWelcomeStatusProvider(statuses: [requiredStatus(state: .needsInstall)])
        let viewModel = WelcomeViewModel(statusProvider: provider)

        let refreshTask = Task { await viewModel.refreshSetup() }
        await Task.yield()

        XCTAssertTrue(viewModel.isRefreshingSetup)

        viewModel.chooseAlternateStorageLocation()

        XCTAssertFalse(viewModel.showingStorageChooser)
        XCTAssertFalse(viewModel.canConfirmStorageSelection)

        provider.release()
        await refreshTask.value
    }

    private func requiredStatus(state: PluginPackState) -> PluginPackStatus {
        PluginPackStatus(
            pack: .requiredSetupPack,
            state: state,
            toolStatuses: [],
            failureMessage: nil
        )
    }
}
