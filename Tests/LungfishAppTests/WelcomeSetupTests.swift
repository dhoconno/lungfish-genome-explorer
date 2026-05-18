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
    private var statusContinuation: CheckedContinuation<Void, Never>?
    private var visibleContinuation: CheckedContinuation<Void, Never>?
    private var statusCallCount = 0
    private var visibleCallCount = 0
    private let delayedStatusPackID: String?
    private let delaysVisibleStatuses: Bool

    init(
        statuses: [PluginPackStatus],
        delayedStatusPackID: String? = nil,
        delaysVisibleStatuses: Bool = true
    ) {
        self.statuses = statuses
        self.delayedStatusPackID = delayedStatusPackID
        self.delaysVisibleStatuses = delaysVisibleStatuses
    }

    func visibleStatuses() async -> [PluginPackStatus] {
        let shouldDelay = lock.withLock {
            visibleCallCount += 1
            return delaysVisibleStatuses
        }
        if shouldDelay {
            await withCheckedContinuation { continuation in
                lock.withLock {
                    visibleContinuation = continuation
                }
            }
        }
        return statuses
    }

    func status(for pack: PluginPack) async -> PluginPackStatus {
        let shouldDelay = lock.withLock {
            statusCallCount += 1
            return delayedStatusPackID == pack.id
        }
        if shouldDelay {
            await withCheckedContinuation { continuation in
                lock.withLock {
                    statusContinuation = continuation
                }
            }
        }
        return statuses.first(where: { $0.pack.id == pack.id })!
    }

    func invalidateVisibleStatusesCache() async {}

    func install(
        pack: PluginPack,
        reinstall: Bool,
        progress: (@Sendable (PluginPackInstallProgress) -> Void)?
    ) async throws {}

    func releaseStatus() {
        let continuation = lock.withLock {
            let continuation = statusContinuation
            statusContinuation = nil
            return continuation
        }
        continuation?.resume()
    }

    func releaseVisibleStatuses() {
        let continuation = lock.withLock {
            let continuation = visibleContinuation
            visibleContinuation = nil
            return continuation
        }
        continuation?.resume()
    }

    func hasPendingStatusRequest() -> Bool {
        lock.withLock { statusContinuation != nil }
    }

    func hasPendingVisibleStatusesRequest() -> Bool {
        lock.withLock { visibleContinuation != nil }
    }

    func recordedStatusCallCount() -> Int {
        lock.withLock { statusCallCount }
    }

    func recordedVisibleStatusesCallCount() -> Int {
        lock.withLock { visibleCallCount }
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
        let currentCallCount = lock.withLock { callCount }
        let statuses = currentCallCount == 0 ? initialStatuses : loadingStatuses
        return statuses.first(where: { $0.pack.id == pack.id })!
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

private final class InstallingWelcomePackStatusProvider: @unchecked Sendable, PluginPackStatusProviding {
    private let missingStatus: PluginPackStatus
    private let readyStatus: PluginPackStatus
    private let lock = NSLock()
    private var installed = false
    private let delaysVisibleStatuses: Bool
    private var visibleContinuation: CheckedContinuation<Void, Never>?
    private var visibleCallCount = 0

    init(
        missingStatus: PluginPackStatus,
        readyStatus: PluginPackStatus,
        delaysVisibleStatuses: Bool = false
    ) {
        self.missingStatus = missingStatus
        self.readyStatus = readyStatus
        self.delaysVisibleStatuses = delaysVisibleStatuses
    }

    func visibleStatuses() async -> [PluginPackStatus] {
        let shouldDelay = lock.withLock {
            visibleCallCount += 1
            return delaysVisibleStatuses
        }
        if shouldDelay {
            await withCheckedContinuation { continuation in
                lock.withLock {
                    visibleContinuation = continuation
                }
            }
        }
        return lock.withLock { installed } ? [readyStatus] : [missingStatus]
    }

    func status(for pack: PluginPack) async -> PluginPackStatus {
        lock.withLock { installed } ? readyStatus : missingStatus
    }

    func invalidateVisibleStatusesCache() async {}

    func install(
        pack: PluginPack,
        reinstall: Bool,
        progress: (@Sendable (PluginPackInstallProgress) -> Void)?
    ) async throws {
        lock.withLock {
            installed = true
        }
        progress?(PluginPackInstallProgress(
            requirementID: nil,
            requirementDisplayName: nil,
            overallFraction: 1.0,
            itemFraction: 1.0,
            message: "Installed"
        ))
    }

    func releaseVisibleStatuses() {
        let continuation = lock.withLock {
            let continuation = visibleContinuation
            visibleContinuation = nil
            return continuation
        }
        continuation?.resume()
    }

    func hasPendingVisibleStatusesRequest() -> Bool {
        lock.withLock { visibleContinuation != nil }
    }
}

private final class SequencedRequiredStatusProvider: @unchecked Sendable, PluginPackStatusProviding {
    private let initialStatus: PluginPackStatus
    private let refreshedStatus: PluginPackStatus
    private let lock = NSLock()
    private var statusCallCount = 0
    private var statusContinuation: CheckedContinuation<Void, Never>?

    init(initialStatus: PluginPackStatus, refreshedStatus: PluginPackStatus) {
        self.initialStatus = initialStatus
        self.refreshedStatus = refreshedStatus
    }

    func visibleStatuses() async -> [PluginPackStatus] {
        lock.withLock { statusCallCount <= 1 } ? [initialStatus] : [refreshedStatus]
    }

    func status(for pack: PluginPack) async -> PluginPackStatus {
        let callCount = lock.withLock {
            statusCallCount += 1
            return statusCallCount
        }
        if callCount > 1 {
            await withCheckedContinuation { continuation in
                lock.withLock {
                    statusContinuation = continuation
                }
            }
        }
        return callCount == 1 ? initialStatus : refreshedStatus
    }

    func invalidateVisibleStatusesCache() async {}

    func install(
        pack: PluginPack,
        reinstall: Bool,
        progress: (@Sendable (PluginPackInstallProgress) -> Void)?
    ) async throws {}

    func releaseStatus() {
        let continuation = lock.withLock {
            let continuation = statusContinuation
            statusContinuation = nil
            return continuation
        }
        continuation?.resume()
    }

    func hasPendingStatusRequest() -> Bool {
        lock.withLock { statusContinuation != nil }
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

    func testWelcomeNavigationSectionsExposeExpectedLabelsAndIdentifiers() {
        XCTAssertEqual(
            WelcomeSection.allCases.map(\.rawValue),
            ["Get Started", "Recent Projects", "Required Setup", "Optional Tools"]
        )
        XCTAssertEqual(
            WelcomeSection.allCases.map(\.accessibilityIdentifier),
            [
                "welcome-nav-get-started",
                "welcome-nav-recent-projects",
                "welcome-nav-required-setup",
                "welcome-nav-optional-tools",
            ]
        )
    }

    func testRequiredSetupPresentationHidesPrimaryInstallWhenReady() {
        let status = PluginPackStatus(
            pack: .requiredSetupPack,
            state: .ready,
            toolStatuses: [],
            failureMessage: nil
        )

        let presentation = RequiredSetupCardPresentation(status: status)

        XCTAssertTrue(presentation.isReady)
        XCTAssertEqual(presentation.statusTitle, "Ready")
        XCTAssertNil(presentation.primaryActionTitle)
        XCTAssertFalse(presentation.showsAlternateStorageAction)
    }

    func testRequiredSetupPresentationShowsInstallWhenSetupIsMissing() {
        let status = PluginPackStatus(
            pack: .requiredSetupPack,
            state: .needsInstall,
            toolStatuses: [],
            failureMessage: nil
        )

        let presentation = RequiredSetupCardPresentation(status: status)

        XCTAssertFalse(presentation.isReady)
        XCTAssertEqual(presentation.statusTitle, "Needs Attention")
        XCTAssertEqual(presentation.primaryActionTitle, "Install")
        XCTAssertTrue(presentation.showsAlternateStorageAction)
    }

    func testAvailableActionsExcludeOpenFiles() {
        XCTAssertEqual(WelcomeAction.allCases, [.createProject, .openProject])
        XCTAssertEqual(
            WelcomeAction.allCases.map(\.accessibilityIdentifier),
            ["welcome-create-project", "welcome-open-project"]
        )
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

    func testRefreshSetupExposesLoadingStateWhileRequiredStatusIsPending() async {
        let required = PluginPackStatus(
            pack: .requiredSetupPack,
            state: .ready,
            toolStatuses: [],
            failureMessage: nil
        )

        let provider = DelayedWelcomePackStatusProvider(
            statuses: [required],
            delayedStatusPackID: PluginPack.requiredSetupPack.id,
            delaysVisibleStatuses: false
        )
        let viewModel = WelcomeViewModel(statusProvider: provider)

        let refreshTask = Task { await viewModel.refreshSetup() }
        for _ in 0..<20 where !provider.hasPendingStatusRequest() {
            try? await Task.sleep(for: .milliseconds(10))
        }

        XCTAssertTrue(provider.hasPendingStatusRequest())
        XCTAssertTrue(viewModel.isRefreshingSetup)
        XCTAssertTrue(viewModel.isRefreshingRequiredSetup)
        XCTAssertFalse(viewModel.isRefreshingOptionalPacks)
        XCTAssertNil(viewModel.requiredSetupStatus)

        provider.releaseStatus()
        await refreshTask.value

        XCTAssertFalse(viewModel.isRefreshingSetup)
        XCTAssertFalse(viewModel.isRefreshingRequiredSetup)
        XCTAssertFalse(viewModel.isRefreshingOptionalPacks)
        XCTAssertEqual(viewModel.requiredSetupStatus?.state, .ready)
    }

    func testRequiredSetupEnablesLaunchWhileOptionalStatusesArePending() async {
        guard let readMapping = PluginPack.activeOptionalPacks.first(where: { $0.id == "read-mapping" }) else {
            XCTFail("Expected active read-mapping pack")
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
            state: .needsInstall,
            toolStatuses: [],
            failureMessage: nil
        )

        let provider = DelayedWelcomePackStatusProvider(statuses: [required, readMappingStatus])
        let viewModel = WelcomeViewModel(statusProvider: provider)

        let refreshTask = Task { await viewModel.refreshSetup() }
        for _ in 0..<20 where !provider.hasPendingVisibleStatusesRequest() {
            try? await Task.sleep(for: .milliseconds(10))
        }

        XCTAssertTrue(provider.hasPendingVisibleStatusesRequest())
        XCTAssertEqual(provider.recordedStatusCallCount(), 1)
        XCTAssertEqual(viewModel.requiredSetupStatus?.state, .ready)
        XCTAssertTrue(viewModel.canLaunch)
        XCTAssertFalse(viewModel.isRefreshingRequiredSetup)
        XCTAssertTrue(viewModel.isRefreshingOptionalPacks)
        XCTAssertTrue(viewModel.optionalPackStatuses.isEmpty)

        provider.releaseVisibleStatuses()
        await refreshTask.value

        XCTAssertFalse(viewModel.isRefreshingSetup)
        XCTAssertEqual(viewModel.optionalPackStatuses.map(\.pack.id), ["read-mapping"])
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
        XCTAssertTrue(viewModel.isRefreshingOptionalPacks)
        XCTAssertEqual(viewModel.requiredSetupStatus?.state, .ready)
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

    func testManagedResourceNotificationsCoalesceIntoOneFollowUpWhileRefreshIsInFlight() async {
        let center = NotificationCenter()
        let ready = PluginPackStatus(
            pack: .requiredSetupPack,
            state: .ready,
            toolStatuses: [],
            failureMessage: nil
        )
        let provider = DelayedWelcomePackStatusProvider(
            statuses: [ready],
            delayedStatusPackID: PluginPack.requiredSetupPack.id,
            delaysVisibleStatuses: false
        )
        let viewModel = WelcomeViewModel(
            statusProvider: provider,
            notificationCenter: center
        )

        center.post(name: .managedResourcesDidChange, object: nil)
        for _ in 0..<20 where !provider.hasPendingStatusRequest() {
            try? await Task.sleep(for: .milliseconds(10))
        }

        XCTAssertTrue(provider.hasPendingStatusRequest())
        XCTAssertEqual(provider.recordedStatusCallCount(), 1)

        center.post(name: .managedResourcesDidChange, object: nil)
        center.post(name: .managedResourcesDidChange, object: nil)
        provider.releaseStatus()
        for _ in 0..<20 where provider.recordedStatusCallCount() < 2 || !provider.hasPendingStatusRequest() {
            try? await Task.sleep(for: .milliseconds(10))
        }

        XCTAssertTrue(provider.hasPendingStatusRequest())
        XCTAssertEqual(provider.recordedStatusCallCount(), 2)

        provider.releaseStatus()
        for _ in 0..<20 where viewModel.isRefreshingSetup {
            try? await Task.sleep(for: .milliseconds(10))
        }

        XCTAssertEqual(provider.recordedStatusCallCount(), 2)
        XCTAssertEqual(provider.recordedVisibleStatusesCallCount(), 2)
        XCTAssertEqual(viewModel.requiredSetupStatus?.state, .ready)
    }

    func testRequiredRecheckDisablesLaunchUntilRequiredStatusReturns() async {
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
        let provider = SequencedRequiredStatusProvider(
            initialStatus: ready,
            refreshedStatus: missing
        )
        let viewModel = WelcomeViewModel(statusProvider: provider)

        await viewModel.refreshSetup()
        XCTAssertTrue(viewModel.canLaunch)

        let refreshTask = Task { await viewModel.refreshSetup() }
        for _ in 0..<20 where !provider.hasPendingStatusRequest() {
            try? await Task.sleep(for: .milliseconds(10))
        }

        XCTAssertTrue(provider.hasPendingStatusRequest())
        XCTAssertNil(viewModel.requiredSetupStatus)
        XCTAssertFalse(viewModel.canLaunch)
        XCTAssertTrue(viewModel.isRefreshingRequiredSetup)

        provider.releaseStatus()
        await refreshTask.value

        XCTAssertEqual(viewModel.requiredSetupStatus?.state, .needsInstall)
        XCTAssertFalse(viewModel.canLaunch)
    }

    func testInstallRequiredSetupPostsManagedResourcesDidChange() async {
        let center = NotificationCenter()
        let missing = PluginPackStatus(
            pack: .requiredSetupPack,
            state: .needsInstall,
            toolStatuses: [],
            failureMessage: nil
        )
        let ready = PluginPackStatus(
            pack: .requiredSetupPack,
            state: .ready,
            toolStatuses: [],
            failureMessage: nil
        )
        let provider = InstallingWelcomePackStatusProvider(
            missingStatus: missing,
            readyStatus: ready
        )
        let viewModel = WelcomeViewModel(
            statusProvider: provider,
            notificationCenter: center
        )
        let notification = expectation(description: "managed resources notification")
        let token = center.addObserver(
            forName: .managedResourcesDidChange,
            object: nil,
            queue: nil
        ) { _ in
            notification.fulfill()
        }
        defer { center.removeObserver(token) }

        await viewModel.refreshSetup()
        XCTAssertEqual(viewModel.requiredSetupStatus?.state, .needsInstall)

        viewModel.installRequiredSetup()
        await fulfillment(of: [notification], timeout: 2)
        for _ in 0..<20 where viewModel.isInstallingRequiredSetup || viewModel.isRefreshingSetup {
            try? await Task.sleep(for: .milliseconds(10))
        }

        XCTAssertEqual(viewModel.requiredSetupStatus?.state, .ready)
    }

    func testInstallRequiredSetupRefreshesRequiredStatusWhenOptionalRefreshIsInFlight() async {
        let missing = PluginPackStatus(
            pack: .requiredSetupPack,
            state: .needsInstall,
            toolStatuses: [],
            failureMessage: nil
        )
        let ready = PluginPackStatus(
            pack: .requiredSetupPack,
            state: .ready,
            toolStatuses: [],
            failureMessage: nil
        )
        let provider = InstallingWelcomePackStatusProvider(
            missingStatus: missing,
            readyStatus: ready,
            delaysVisibleStatuses: true
        )
        let viewModel = WelcomeViewModel(
            statusProvider: provider,
            notificationCenter: NotificationCenter()
        )

        let refreshTask = Task { await viewModel.refreshSetup() }
        for _ in 0..<20 where !provider.hasPendingVisibleStatusesRequest() {
            try? await Task.sleep(for: .milliseconds(10))
        }

        XCTAssertEqual(viewModel.requiredSetupStatus?.state, .needsInstall)
        XCTAssertTrue(viewModel.isRefreshingOptionalPacks)

        viewModel.installRequiredSetup()
        provider.releaseVisibleStatuses()
        await refreshTask.value
        for _ in 0..<20 where viewModel.isInstallingRequiredSetup || viewModel.isRefreshingSetup {
            try? await Task.sleep(for: .milliseconds(10))
        }

        XCTAssertEqual(viewModel.requiredSetupStatus?.state, .ready)
        XCTAssertTrue(viewModel.canLaunch)
    }

    func testRefreshSetupCoalescesOverlappingRequests() async {
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
        try? await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(provider.recordedCallCount(), 1)
        XCTAssertFalse(provider.hasPendingSecondRequest())

        provider.releaseFirst()
        await secondRefresh.value
        XCTAssertEqual(viewModel.requiredSetupStatus?.state, .ready)

        await firstRefresh.value

        XCTAssertEqual(viewModel.requiredSetupStatus?.state, .ready)
    }
}
