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

    func hasPendingVisibleStatusesRequest() -> Bool {
        lock.withLock { !continuations.isEmpty }
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

    func hasPendingVisibleStatusesRequest() -> Bool {
        lock.withLock { continuation != nil }
    }
}

private final class OverlappingWelcomePackStatusProvider: @unchecked Sendable, PluginPackStatusProviding {
    private let firstStatuses: [PluginPackStatus]
    private let secondStatuses: [PluginPackStatus]
    private let lock = NSLock()
    private var callCount = 0
    private var firstContinuation: CheckedContinuation<Void, Never>?
    private var secondContinuation: CheckedContinuation<Void, Never>?

    init(firstStatuses: [PluginPackStatus], secondStatuses: [PluginPackStatus]) {
        self.firstStatuses = firstStatuses
        self.secondStatuses = secondStatuses
    }

    func visibleStatuses() async -> [PluginPackStatus] {
        let statuses: [PluginPackStatus]
        let callIndex = lock.withLock {
            callCount += 1
            return callCount
        }

        switch callIndex {
        case 1:
            statuses = firstStatuses
            await withCheckedContinuation { continuation in
                lock.withLock {
                    firstContinuation = continuation
                }
            }
        case 2:
            statuses = secondStatuses
            await withCheckedContinuation { continuation in
                lock.withLock {
                    secondContinuation = continuation
                }
            }
        default:
            statuses = secondStatuses
        }

        return statuses
    }

    func status(for pack: PluginPack) async -> PluginPackStatus {
        secondStatuses.first(where: { $0.pack.id == pack.id })
            ?? firstStatuses.first(where: { $0.pack.id == pack.id })!
    }

    func invalidateVisibleStatusesCache() async {}

    func install(
        pack: PluginPack,
        reinstall: Bool,
        progress: (@Sendable (PluginPackInstallProgress) -> Void)?
    ) async throws {}

    func releaseFirst() {
        let continuation = lock.withLock {
            let continuation = firstContinuation
            firstContinuation = nil
            return continuation
        }
        continuation?.resume()
    }

    func releaseSecond() {
        let continuation = lock.withLock {
            let continuation = secondContinuation
            secondContinuation = nil
            return continuation
        }
        continuation?.resume()
    }

    func recordedCallCount() -> Int {
        lock.withLock { callCount }
    }

    func hasPendingFirstRequest() -> Bool {
        lock.withLock { firstContinuation != nil }
    }

    func hasPendingSecondRequest() -> Bool {
        lock.withLock { secondContinuation != nil }
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
        let metagenomicsStatus = PluginPackStatus(
            pack: metagenomics,
            state: .needsInstall,
            toolStatuses: [],
            failureMessage: nil
        )

        let viewModel = WelcomeViewModel(
            statusProvider: StubWelcomePackStatusProvider(statuses: [
                required,
                readMappingStatus,
                variantCallingStatus,
                assemblyStatus,
                metagenomicsStatus,
            ])
        )
        await viewModel.refreshSetup()

        XCTAssertFalse(viewModel.canLaunch)
        XCTAssertEqual(viewModel.optionalPackStatuses.map(\.pack.id), ["read-mapping", "variant-calling", "assembly", "metagenomics"])
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

    func testDebugBypassAllowsLaunchWhenRequiredSetupNeedsInstall() async {
        let required = PluginPackStatus(
            pack: .requiredSetupPack,
            state: .needsInstall,
            toolStatuses: [],
            failureMessage: nil
        )

        let viewModel = WelcomeViewModel(
            statusProvider: StubWelcomePackStatusProvider(statuses: [required]),
            debugLaunchConfiguration: AppDebugLaunchConfiguration(
                environment: ["LUNGFISH_DEBUG_BYPASS_REQUIRED_SETUP": "1"]
            )
        )
        await viewModel.refreshSetup()

        #if DEBUG
        XCTAssertTrue(viewModel.canLaunch)
        #else
        XCTAssertFalse(viewModel.canLaunch)
        #endif
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
        for _ in 0..<20 where !provider.hasPendingVisibleStatusesRequest() {
            try? await Task.sleep(for: .milliseconds(10))
        }

        XCTAssertTrue(provider.hasPendingVisibleStatusesRequest())
        XCTAssertTrue(viewModel.isRefreshingSetup)
        XCTAssertNil(viewModel.requiredSetupStatus)

        provider.release()
        await refreshTask.value

        XCTAssertFalse(viewModel.isRefreshingSetup)
        XCTAssertEqual(viewModel.requiredSetupStatus?.state, .ready)
    }

    func testRefreshSetupClearsLoadedStatusesWhileReloading() async {
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
        guard let metagenomics = PluginPack.activeOptionalPacks.first(where: { $0.id == "metagenomics" }) else {
            XCTFail("Expected active metagenomics pack")
            return
        }
        let required = PluginPackStatus(
            pack: .requiredSetupPack,
            state: .ready,
            toolStatuses: [],
            failureMessage: nil
        )
        let readMappingStatus = PluginPackStatus(
            pack: readMapping,
            state: .ready,
            toolStatuses: [],
            failureMessage: nil
        )
        let variantCallingStatus = PluginPackStatus(
            pack: variantCalling,
            state: .ready,
            toolStatuses: [],
            failureMessage: nil
        )
        let assemblyStatus = PluginPackStatus(
            pack: assembly,
            state: .ready,
            toolStatuses: [],
            failureMessage: nil
        )
        let metagenomicsStatus = PluginPackStatus(
            pack: metagenomics,
            state: .ready,
            toolStatuses: [],
            failureMessage: nil
        )

        let provider = StatefulWelcomePackStatusProvider(
            initialStatuses: [required, readMappingStatus, variantCallingStatus, assemblyStatus, metagenomicsStatus],
            loadingStatuses: [required, readMappingStatus, variantCallingStatus, assemblyStatus, metagenomicsStatus]
        )
        let viewModel = WelcomeViewModel(statusProvider: provider)

        await viewModel.refreshSetup()
        XCTAssertEqual(viewModel.requiredSetupStatus?.state, .ready)
        XCTAssertEqual(viewModel.optionalPackStatuses.map(\.pack.id), ["read-mapping", "variant-calling", "assembly", "metagenomics"])

        let refreshTask = Task { await viewModel.refreshSetup() }
        for _ in 0..<20 where !provider.hasPendingVisibleStatusesRequest() {
            try? await Task.sleep(for: .milliseconds(10))
        }

        XCTAssertTrue(provider.hasPendingVisibleStatusesRequest())
        XCTAssertTrue(viewModel.isRefreshingSetup)
        XCTAssertNil(viewModel.requiredSetupStatus)
        XCTAssertTrue(viewModel.optionalPackStatuses.isEmpty)

        provider.release()
        await refreshTask.value

        XCTAssertEqual(viewModel.requiredSetupStatus?.state, .ready)
        XCTAssertEqual(viewModel.optionalPackStatuses.map(\.pack.id), ["read-mapping", "variant-calling", "assembly", "metagenomics"])
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
        for _ in 0..<20 where !provider.hasPendingVisibleStatusesRequest() {
            try? await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(provider.hasPendingVisibleStatusesRequest())
        XCTAssertTrue(viewModel.isRefreshingSetup)
        provider.release()
        try? await Task.sleep(for: .milliseconds(50))

        XCTAssertEqual(viewModel.requiredSetupStatus?.state, .ready)
    }

    func testRefreshSetupIgnoresStaleOverlappingResults() async {
        let stale = PluginPackStatus(
            pack: .requiredSetupPack,
            state: .needsInstall,
            toolStatuses: [],
            failureMessage: nil
        )
        let fresh = PluginPackStatus(
            pack: .requiredSetupPack,
            state: .ready,
            toolStatuses: [],
            failureMessage: nil
        )

        let provider = OverlappingWelcomePackStatusProvider(
            firstStatuses: [stale],
            secondStatuses: [fresh]
        )
        let viewModel = WelcomeViewModel(statusProvider: provider)

        let firstRefresh = Task { await viewModel.refreshSetup() }
        for _ in 0..<20 where !provider.hasPendingFirstRequest() {
            try? await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(provider.hasPendingFirstRequest())

        let secondRefresh = Task { await viewModel.refreshSetup() }
        for _ in 0..<20 where !provider.hasPendingSecondRequest() {
            try? await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(provider.recordedCallCount(), 2)
        XCTAssertTrue(provider.hasPendingSecondRequest())

        provider.releaseSecond()
        await secondRefresh.value

        XCTAssertEqual(viewModel.requiredSetupStatus?.state, .ready)

        provider.releaseFirst()
        await firstRefresh.value

        XCTAssertEqual(viewModel.requiredSetupStatus?.state, .ready)
    }

    private func repositoryRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }
}
