import XCTest
@testable import LungfishApp
@testable import LungfishWorkflow

private actor StubWelcomePackStatusProvider: PluginPackStatusProviding {
    var statuses: [PluginPackStatus]

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

private final class DelayedWelcomePackStatusProvider: @unchecked Sendable, PluginPackStatusProviding {
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

private final class StatefulWelcomePackStatusProvider: @unchecked Sendable, PluginPackStatusProviding {
    let initialStatuses: [PluginPackStatus]
    let loadingStatuses: [PluginPackStatus]
    private let lock = NSLock()
    private var callCount = 0
    private var continuation: CheckedContinuation<[PluginPackStatus], Never>?

    init(initialStatuses: [PluginPackStatus], loadingStatuses: [PluginPackStatus]) {
        self.initialStatuses = initialStatuses
        self.loadingStatuses = loadingStatuses
    }

    func visibleStatuses() async -> [PluginPackStatus] {
        lock.withLock {
            callCount += 1
        }

        if lock.withLock({ callCount }) == 1 {
            return initialStatuses
        }

        return await withCheckedContinuation { continuation in
            lock.withLock {
                self.continuation = continuation
            }
        }
    }

    func status(for pack: PluginPack) async -> PluginPackStatus {
        loadingStatuses.first(where: { $0.pack.id == pack.id }) ?? initialStatuses.first(where: { $0.pack.id == pack.id })!
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
        continuation?.resume(returning: loadingStatuses)
    }
}

@MainActor
final class WelcomeSetupTests: XCTestCase {

    func testWelcomeWindowUsesStandardTitlebarChrome() {
        let controller = WelcomeWindowController()
        guard let window = controller.window else {
            XCTFail("Expected welcome window")
            return
        }

        XCTAssertFalse(window.titlebarAppearsTransparent)
        XCTAssertFalse(window.isMovableByWindowBackground)
        XCTAssertGreaterThanOrEqual(window.contentMinSize.width, 980)
        XCTAssertGreaterThanOrEqual(window.contentMinSize.height, 640)
        XCTAssertLessThanOrEqual(window.contentMinSize.height, 700)
    }

    func testWelcomeViewSourceOmitsBrandingHeaderStack() throws {
        let source = try String(
            contentsOf: repositoryRoot()
                .appendingPathComponent("Sources/LungfishApp/Views/Welcome/WelcomeWindowController.swift"),
            encoding: .utf8
        )

        XCTAssertFalse(source.contains("Image(nsImage: Self.loadLogo())"))
        XCTAssertFalse(source.contains("Text(\"Lungfish Genome Explorer\")"))
        XCTAssertFalse(source.contains("Text(\"Seeing the invisible. Informing action.\")"))
    }

    func testWelcomeViewSourceIncludesSidebarNavigationSections() throws {
        let source = try String(
            contentsOf: repositoryRoot()
                .appendingPathComponent("Sources/LungfishApp/Views/Welcome/WelcomeWindowController.swift"),
            encoding: .utf8
        )

        XCTAssertTrue(source.contains("Get Started"))
        XCTAssertTrue(source.contains("Recent Projects"))
        XCTAssertTrue(source.contains("Required Setup"))
        XCTAssertTrue(source.contains("Optional Tools"))
    }

    func testWelcomeViewSourceUsesRequiredPackCopy() throws {
        let source = try String(
            contentsOf: repositoryRoot()
                .appendingPathComponent("Sources/LungfishApp/Views/Welcome/WelcomeWindowController.swift"),
            encoding: .utf8
        )

        XCTAssertFalse(source.contains("Lungfish Tools"))
        XCTAssertTrue(source.contains("Checking Required Setup"))
        XCTAssertTrue(source.contains("Preparing \\(pack.name)"))
        XCTAssertTrue(source.contains("Text(status.pack.name)"))
    }

    func testWelcomeViewSourceIncludesAlternateStorageAction() throws {
        let source = try String(
            contentsOf: repositoryRoot()
                .appendingPathComponent("Sources/LungfishApp/Views/Welcome/WelcomeWindowController.swift"),
            encoding: .utf8
        )

        XCTAssertTrue(source.contains("Need more space? Choose another storage location…"))
        XCTAssertTrue(source.contains("url.resolvingSymlinksInPath().standardizedFileURL"))
        XCTAssertTrue(source.contains("var isStorageChooserEnabled: Bool"))
        XCTAssertTrue(source.contains("Button(\"Use This Location\")"))
        XCTAssertTrue(source.contains(".disabled(!viewModel.isStorageChooserEnabled)"))
        XCTAssertTrue(source.contains(".disabled(!viewModel.canConfirmStorageSelection)"))
    }

    func testWelcomeViewSourceUsesWarmPaletteAndNoVerticalFixedSize() throws {
        let source = try String(
            contentsOf: repositoryRoot()
                .appendingPathComponent("Sources/LungfishApp/Views/Welcome/WelcomeWindowController.swift"),
            encoding: .utf8
        )

        XCTAssertTrue(source.contains("Color.lungfishWelcomeSidebarBackground"))
        XCTAssertTrue(source.contains("Color.lungfishWelcomeCardBackground"))
        XCTAssertTrue(source.contains("Color.lungfishCreamsicleFallback"))
        XCTAssertTrue(source.contains("Color.lungfishSageFallback"))
        XCTAssertFalse(source.contains("Color.accentColor"))
        XCTAssertFalse(source.contains("? .green"))
        XCTAssertFalse(source.contains("? .red"))
        XCTAssertFalse(source.contains(".fixedSize(horizontal: false, vertical: true)"))
    }

    func testAvailableActionsExcludeOpenFiles() {
        XCTAssertEqual(WelcomeAction.allCases, [.createProject, .openProject])
    }

    func testLaunchRemainsDisabledUntilRequiredSetupIsReady() async {
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

        let viewModel = WelcomeViewModel(
            statusProvider: StubWelcomePackStatusProvider(statuses: [required, optional])
        )
        await viewModel.refreshSetup()

        XCTAssertFalse(viewModel.canLaunch)
        XCTAssertEqual(viewModel.optionalPackStatuses.map(\.pack.id), ["metagenomics"])
    }

    func testLaunchEnablesWhenRequiredSetupIsReady() async {
        let required = PluginPackStatus(
            pack: .requiredSetupPack,
            state: .ready,
            toolStatuses: [],
            failureMessage: nil
        )

        let viewModel = WelcomeViewModel(
            statusProvider: StubWelcomePackStatusProvider(statuses: [required])
        )
        await viewModel.refreshSetup()

        XCTAssertTrue(viewModel.canLaunch)
    }

    func testRefreshSetupExposesLoadingStateWhileStatusesArePending() async {
        let required = PluginPackStatus(
            pack: .requiredSetupPack,
            state: .ready,
            toolStatuses: [],
            failureMessage: nil
        )

        let provider = DelayedWelcomePackStatusProvider(statuses: [required])
        let viewModel = WelcomeViewModel(statusProvider: provider)

        let refreshTask = Task { await viewModel.refreshSetup() }
        await Task.yield()

        XCTAssertTrue(viewModel.isRefreshingSetup)
        XCTAssertNil(viewModel.requiredSetupStatus)

        provider.release()
        await refreshTask.value

        XCTAssertFalse(viewModel.isRefreshingSetup)
        XCTAssertEqual(viewModel.requiredSetupStatus?.state, .ready)
    }

    func testRefreshSetupClearsLoadedStatusesWhileReloading() async {
        let required = PluginPackStatus(
            pack: .requiredSetupPack,
            state: .ready,
            toolStatuses: [],
            failureMessage: nil
        )
        let optional = PluginPackStatus(
            pack: PluginPack.activeOptionalPacks[0],
            state: .ready,
            toolStatuses: [],
            failureMessage: nil
        )

        let provider = StatefulWelcomePackStatusProvider(
            initialStatuses: [required, optional],
            loadingStatuses: [required, optional]
        )
        let viewModel = WelcomeViewModel(statusProvider: provider)

        await viewModel.refreshSetup()
        XCTAssertEqual(viewModel.requiredSetupStatus?.state, .ready)
        XCTAssertEqual(viewModel.optionalPackStatuses.map(\.pack.id), ["metagenomics"])

        let refreshTask = Task { await viewModel.refreshSetup() }
        await Task.yield()

        XCTAssertTrue(viewModel.isRefreshingSetup)
        XCTAssertNil(viewModel.requiredSetupStatus)
        XCTAssertTrue(viewModel.optionalPackStatuses.isEmpty)

        provider.release()
        await refreshTask.value

        XCTAssertEqual(viewModel.requiredSetupStatus?.state, .ready)
        XCTAssertEqual(viewModel.optionalPackStatuses.map(\.pack.id), ["metagenomics"])
    }

    func testManagedResourcesChangeRefreshesSetupInPlace() async {
        let center = NotificationCenter()
        let ready = PluginPackStatus(
            pack: .requiredSetupPack,
            state: .ready,
            toolStatuses: [],
            failureMessage: nil
        )
        let missing = PluginPackStatus(
            pack: .requiredSetupPack,
            state: .needsInstall,
            toolStatuses: [],
            failureMessage: nil
        )
        let provider = StatefulWelcomePackStatusProvider(
            initialStatuses: [missing],
            loadingStatuses: [ready]
        )
        let viewModel = WelcomeViewModel(
            statusProvider: provider,
            notificationCenter: center
        )

        await viewModel.refreshSetup()
        XCTAssertEqual(viewModel.requiredSetupStatus?.state, .needsInstall)

        center.post(name: .managedResourcesDidChange, object: nil)
        for _ in 0..<10 where !viewModel.isRefreshingSetup {
            try? await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(viewModel.isRefreshingSetup)
        provider.release()
        try? await Task.sleep(for: .milliseconds(50))

        XCTAssertEqual(viewModel.requiredSetupStatus?.state, .ready)
    }

    private func repositoryRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }
}
