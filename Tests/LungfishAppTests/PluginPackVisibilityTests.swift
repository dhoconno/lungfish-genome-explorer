import XCTest
@testable import LungfishApp
@testable import LungfishCore
@testable import LungfishWorkflow
import LungfishKit

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

private struct TestPluginPackInstallError: LocalizedError, Sendable {
    let message: String

    var errorDescription: String? { message }
}

private actor OperationReportingPluginPackStatusProvider: PluginPackStatusProviding {
    let initialStatus: PluginPackStatus
    let installedStatus: PluginPackStatus
    let progressEvents: [PluginPackInstallProgress]
    let failure: TestPluginPackInstallError?
    private var didInstall = false

    init(
        initialStatus: PluginPackStatus,
        installedStatus: PluginPackStatus,
        progressEvents: [PluginPackInstallProgress],
        failure: TestPluginPackInstallError? = nil
    ) {
        self.initialStatus = initialStatus
        self.installedStatus = installedStatus
        self.progressEvents = progressEvents
        self.failure = failure
    }

    func visibleStatuses() async -> [PluginPackStatus] {
        [didInstall ? installedStatus : initialStatus]
    }

    func status(for pack: PluginPack) async -> PluginPackStatus {
        didInstall ? installedStatus : initialStatus
    }

    func invalidateVisibleStatusesCache() async {}

    func install(
        pack: PluginPack,
        reinstall: Bool,
        progress: (@Sendable (PluginPackInstallProgress) -> Void)?
    ) async throws {
        for event in progressEvents {
            progress?(event)
        }
        if let failure {
            throw failure
        }
        didInstall = true
    }
}

@MainActor
final class PluginPackVisibilityTests: XCTestCase {

    func testMetagenomicsPackHealthIsNotReadyWhenDatabaseBuildExecutableIsMissing() throws {
        let pack = try XCTUnwrap(PluginPack.builtInPack(id: "metagenomics"))
        let cases = [
            ("kraken2", "kraken2-build"),
            ("bracken", "bracken-build"),
        ]

        for (requirementID, missingExecutable) in cases {
            let requirement = try XCTUnwrap(
                pack.toolRequirements.first { $0.id == requirementID }
            )
            XCTAssertTrue(requirement.executables.contains(missingExecutable))

            let health = PackToolStatus(
                requirement: requirement,
                environmentExists: true,
                missingExecutables: [missingExecutable],
                smokeTestFailure: nil,
                storageUnavailablePath: nil
            )
            XCTAssertFalse(health.isReady)
            XCTAssertEqual(health.statusText, "Needs reinstall")
        }
    }

    func testPluginManagerCallbacksUseMainQueueBridgeInsteadOfMainActorTasks() throws {
        let source = try String(contentsOf: pluginManagerViewModelSourceURL(), encoding: .utf8)
        let storageObserver = try sourceSection(
            in: source,
            from: "private final class StorageLocationChangeObserver",
            to: "private struct RecommendedDatabaseSelection"
        )
        let installPack = try sourceSection(
            in: source,
            from: "func installPack(_ pack: PluginPack, reinstall: Bool = false)",
            to: "private func startPluginPackOperation"
        )

        XCTAssertFalse(storageObserver.contains("Task { @MainActor"))
        XCTAssertFalse(installPack.contains("Task { @MainActor"))
        XCTAssertTrue(storageObserver.contains("DispatchQueue.main.async"))
        XCTAssertTrue(installPack.contains("DispatchQueue.main.async"))
        XCTAssertTrue(storageObserver.contains("MainActor.assumeIsolated"))
        XCTAssertTrue(installPack.contains("MainActor.assumeIsolated"))
    }

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

    func testPackStatusesExcludeExperimentalPacksWhenExperimentalFeaturesAreOff() async throws {
        let previousExperimentalSetting = AppSettings.shared.experimentalFeaturesEnabled
        AppSettings.shared.experimentalFeaturesEnabled = false
        defer { AppSettings.shared.experimentalFeaturesEnabled = previousExperimentalSetting }

        let readMapping = try XCTUnwrap(PluginPack.builtInPack(id: "read-mapping"))
        let gatkCore = try XCTUnwrap(PluginPack.builtInPack(id: "gatk-core"))
        let viewModel = PluginManagerViewModel(
            packStatusProvider: StubPluginManagerPackStatusProvider(statuses: [
                PluginPackStatus(pack: readMapping, state: .ready, toolStatuses: [], failureMessage: nil),
                PluginPackStatus(pack: gatkCore, state: .ready, toolStatuses: [], failureMessage: nil),
            ]),
            automaticallyRefresh: false
        )

        await viewModel.loadPackStatuses()

        XCTAssertEqual(viewModel.optionalPackStatuses.map(\.pack.id), ["read-mapping"])
    }

    func testPackStatusesIncludeExperimentalPacksWhenExperimentalFeaturesAreOn() async throws {
        let previousExperimentalSetting = AppSettings.shared.experimentalFeaturesEnabled
        AppSettings.shared.experimentalFeaturesEnabled = true
        defer { AppSettings.shared.experimentalFeaturesEnabled = previousExperimentalSetting }

        let readMapping = try XCTUnwrap(PluginPack.builtInPack(id: "read-mapping"))
        let gatkCore = try XCTUnwrap(PluginPack.builtInPack(id: "gatk-core"))
        let viewModel = PluginManagerViewModel(
            packStatusProvider: StubPluginManagerPackStatusProvider(statuses: [
                PluginPackStatus(pack: readMapping, state: .ready, toolStatuses: [], failureMessage: nil),
                PluginPackStatus(pack: gatkCore, state: .ready, toolStatuses: [], failureMessage: nil),
            ]),
            automaticallyRefresh: false
        )

        await viewModel.loadPackStatuses()

        XCTAssertEqual(viewModel.optionalPackStatuses.map(\.pack.id), ["read-mapping", "gatk-core"])
    }

    func testPBAAIsNotShownAsPluginPack() {
        XCTAssertNil(PluginPack.builtInPack(id: "amplicon-genotyping"))
        XCTAssertFalse(
            PluginPack.visibleForApp(experimentalFeaturesEnabled: true)
                .map(\.id)
                .contains("amplicon-genotyping")
        )
    }

    func testReadyRequiredSetupPackDoesNotExposePrimaryInstallAction() {
        let status = PluginPackStatus(
            pack: .requiredSetupPack,
            state: .ready,
            toolStatuses: [],
            failureMessage: nil
        )

        let presentation = PackCardPresentation(
            status: status,
            isInstalling: false,
            canRemove: false
        )

        XCTAssertEqual(presentation.primaryAction, .none)
    }

    func testRequiredSetupPackNeedingInstallExposesInstallAction() {
        let status = PluginPackStatus(
            pack: .requiredSetupPack,
            state: .needsInstall,
            toolStatuses: [],
            failureMessage: nil
        )

        let presentation = PackCardPresentation(
            status: status,
            isInstalling: false,
            canRemove: false
        )

        XCTAssertEqual(presentation.primaryAction, .install(title: "Install"))
    }

    func testReadyOptionalPackExposesRemoveActionWhenAvailable() {
        let pack = PluginPack(
            id: "optional-ready-pack",
            name: "Optional Ready Pack",
            description: "Ready optional pack",
            sfSymbol: "shippingbox",
            packages: [],
            category: "Testing"
        )
        let status = PluginPackStatus(
            pack: pack,
            state: .ready,
            toolStatuses: [],
            failureMessage: nil
        )

        let presentation = PackCardPresentation(
            status: status,
            isInstalling: false,
            canRemove: true
        )

        XCTAssertEqual(presentation.primaryAction, .removeAll)
    }

    func testInstalledTabSeparatesHashNamedOrphanEnvironments() {
        let viewModel = PluginManagerViewModel(
            packStatusProvider: StubPluginManagerPackStatusProvider(statuses: []),
            automaticallyRefresh: false
        )
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("plugin-manager-orphan-envs-\(UUID().uuidString)", isDirectory: true)
        let orphanName = "5b301f1ad57c22a15e98c9f27d9f4a41"

        viewModel.applyInstalledEnvironments([
            CondaEnvironment(name: "bbmap", path: root.appendingPathComponent("bbmap"), packageCount: 12),
            CondaEnvironment(name: orphanName, path: root.appendingPathComponent(orphanName), packageCount: 3),
            CondaEnvironment(name: "minimap2", path: root.appendingPathComponent("minimap2"), packageCount: 5),
        ])

        XCTAssertEqual(viewModel.environments.map(\.name), ["bbmap", "minimap2"])
        XCTAssertEqual(viewModel.orphanedEnvironments.map(\.name), [orphanName])
        XCTAssertTrue(viewModel.orphanedEnvironmentDiagnosticText.contains("1 orphaned"))
    }

    func testInstalledTabSeparatesEnvPrefixedHashNamedOrphanEnvironments() {
        let viewModel = PluginManagerViewModel(
            packStatusProvider: StubPluginManagerPackStatusProvider(statuses: []),
            automaticallyRefresh: false
        )
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("plugin-manager-env-orphan-envs-\(UUID().uuidString)", isDirectory: true)
        let orphanName = "env-5b301f1ad57c22a15e98c9f27d9f4a41"

        viewModel.applyInstalledEnvironments([
            CondaEnvironment(name: "bbmap", path: root.appendingPathComponent("bbmap"), packageCount: 12),
            CondaEnvironment(name: orphanName, path: root.appendingPathComponent(orphanName), packageCount: 3),
            CondaEnvironment(name: "minimap2", path: root.appendingPathComponent("minimap2"), packageCount: 5),
        ])

        XCTAssertEqual(viewModel.environments.map(\.name), ["bbmap", "minimap2"])
        XCTAssertEqual(viewModel.orphanedEnvironments.map(\.name), [orphanName])
        XCTAssertTrue(viewModel.orphanedEnvironmentDiagnosticText.contains(orphanName))
    }

    func testOfflinePackGuidanceIncludesDocsCompatibleCommandsForSelectedPack() throws {
        let pack = try XCTUnwrap(PluginPack.builtInPack(id: "metagenomics"))
        let viewModel = PluginManagerViewModel(
            packStatusProvider: StubPluginManagerPackStatusProvider(statuses: []),
            automaticallyRefresh: false
        )

        let guidance = viewModel.offlinePackCommandGuidance(for: pack)

        XCTAssertEqual(
            guidance.exportCommand,
            "lungfish-cli conda export-pack --pack metagenomics --output ./metagenomics-conda-offline-pack.tgz"
        )
        XCTAssertEqual(
            guidance.installCommand,
            "lungfish-cli conda install --offline --from-bundle ./metagenomics-conda-offline-pack.tgz"
        )
        XCTAssertTrue(guidance.copyText.contains(guidance.exportCommand))
        XCTAssertTrue(guidance.copyText.contains(guidance.installCommand))
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

    func testInstallPackReportsCondaPackCompletionToOperationCenter() async throws {
        let pack = try XCTUnwrap(PluginPack.builtInPack(id: "multiple-sequence-alignment"))
        let initialStatus = PluginPackStatus(
            pack: pack,
            state: .needsInstall,
            toolStatuses: [],
            failureMessage: nil
        )
        let installedStatus = PluginPackStatus(
            pack: pack,
            state: .ready,
            toolStatuses: readyToolStatuses(for: pack),
            failureMessage: nil
        )
        let provider = OperationReportingPluginPackStatusProvider(
            initialStatus: initialStatus,
            installedStatus: installedStatus,
            progressEvents: [
                PluginPackInstallProgress(
                    requirementID: "mafft",
                    requirementDisplayName: "MAFFT",
                    overallFraction: 0.25,
                    itemFraction: 0.25,
                    message: "Solving environment for MAFFT"
                ),
                PluginPackInstallProgress(
                    requirementID: "mafft",
                    requirementDisplayName: "MAFFT",
                    overallFraction: 1.0,
                    itemFraction: 1.0,
                    message: "MAFFT installed"
                ),
            ]
        )
        let operationCenter = OperationCenter()
        let viewModel = PluginManagerViewModel(
            packStatusProvider: provider,
            automaticallyRefresh: false,
            operationCenter: operationCenter
        )

        viewModel.installPack(pack, reinstall: true)

        let finishedItem = await finishedPluginPackOperation(in: operationCenter, packName: pack.name)
        let item = try XCTUnwrap(finishedItem)
        XCTAssertEqual(item.title, "Plugin Pack: Multiple Sequence Alignment")
        XCTAssertEqual(item.operationType, .condaPluginPack)
        XCTAssertEqual(item.state, .completed)
        XCTAssertEqual(item.displayStateLabel, "Completed")
        XCTAssertTrue(item.detail.contains("Multiple Sequence Alignment ready"))

        let logText = item.logEntries.map(\.message).joined(separator: "\n")
        XCTAssertTrue(logText.contains("Pack ID: multiple-sequence-alignment"))
        XCTAssertTrue(logText.contains("Requirement: MAFFT (mafft)"))
        XCTAssertTrue(logText.contains("Environment: mafft"))
        let mafftSpec = try XCTUnwrap(ManagedToolLock.bundled.packTool(packID: "multiple-sequence-alignment", id: "mafft")).packageSpec
        XCTAssertTrue(logText.contains("Package specs: \(mafftSpec)"))
        XCTAssertTrue(logText.contains("Solving environment for MAFFT"))
        XCTAssertTrue(logText.contains("Verification: MAFFT - Ready"))
    }

    func testInstallPackReportsNeedsReinstallVerificationWarningToOperationCenter() async throws {
        let pack = try XCTUnwrap(PluginPack.builtInPack(id: "multiple-sequence-alignment"))
        let brokenStatus = PluginPackStatus(
            pack: pack,
            state: .needsInstall,
            toolStatuses: [
                PackToolStatus(
                    requirement: try XCTUnwrap(pack.toolRequirements.first),
                    environmentExists: true,
                    missingExecutables: ["mafft"],
                    smokeTestFailure: "mafft --help exited 1",
                    storageUnavailablePath: nil
                ),
            ],
            failureMessage: "mafft --help exited 1"
        )
        let provider = OperationReportingPluginPackStatusProvider(
            initialStatus: brokenStatus,
            installedStatus: brokenStatus,
            progressEvents: [
                PluginPackInstallProgress(
                    requirementID: "mafft",
                    requirementDisplayName: "MAFFT",
                    overallFraction: 1.0,
                    itemFraction: 1.0,
                    message: "MAFFT installed"
                ),
            ]
        )
        let operationCenter = OperationCenter()
        let viewModel = PluginManagerViewModel(
            packStatusProvider: provider,
            automaticallyRefresh: false,
            operationCenter: operationCenter
        )

        viewModel.installPack(pack, reinstall: true)

        let finishedItem = await finishedPluginPackOperation(in: operationCenter, packName: pack.name)
        let item = try XCTUnwrap(finishedItem)
        XCTAssertEqual(item.operationType, .condaPluginPack)
        XCTAssertEqual(item.state, .completed)
        XCTAssertEqual(item.displayStateLabel, "Completed with Warnings")
        XCTAssertTrue(item.detail.contains("Needs reinstall"))

        let logText = item.logEntries.map(\.message).joined(separator: "\n")
        XCTAssertTrue(logText.contains("Verification: MAFFT - Needs reinstall"))
        XCTAssertTrue(logText.contains("Missing executables: mafft"))
        XCTAssertTrue(logText.contains("Smoke test failure: mafft --help exited 1"))
    }

    func testInstallPackReportsCondaPackFailureToOperationCenter() async throws {
        let pack = try XCTUnwrap(PluginPack.builtInPack(id: "multiple-sequence-alignment"))
        let initialStatus = PluginPackStatus(
            pack: pack,
            state: .needsInstall,
            toolStatuses: [],
            failureMessage: nil
        )
        let provider = OperationReportingPluginPackStatusProvider(
            initialStatus: initialStatus,
            installedStatus: initialStatus,
            progressEvents: [
                PluginPackInstallProgress(
                    requirementID: "mafft",
                    requirementDisplayName: "MAFFT",
                    overallFraction: 0.3,
                    itemFraction: 0.3,
                    message: "Solving environment for MAFFT"
                ),
            ],
            failure: TestPluginPackInstallError(message: "mafft solver failed")
        )
        let operationCenter = OperationCenter()
        let viewModel = PluginManagerViewModel(
            packStatusProvider: provider,
            automaticallyRefresh: false,
            operationCenter: operationCenter
        )

        viewModel.installPack(pack, reinstall: true)

        let finishedItem = await finishedPluginPackOperation(in: operationCenter, packName: pack.name)
        let item = try XCTUnwrap(finishedItem)
        XCTAssertEqual(item.operationType, .condaPluginPack)
        XCTAssertEqual(item.state, .failed)
        XCTAssertEqual(item.errorMessage, "mafft solver failed")
        XCTAssertEqual(item.detail, "Failed to reinstall Multiple Sequence Alignment")
        let mafftSpec = try XCTUnwrap(ManagedToolLock.bundled.packTool(packID: "multiple-sequence-alignment", id: "mafft")).packageSpec
        XCTAssertTrue(item.errorDetail?.contains("Package specs: \(mafftSpec)") == true)
        XCTAssertTrue(item.logEntries.map(\.message).joined(separator: "\n").contains("Solving environment for MAFFT"))
    }

    private func readyToolStatuses(for pack: PluginPack) -> [PackToolStatus] {
        pack.toolRequirements.map {
            PackToolStatus(
                requirement: $0,
                environmentExists: true,
                missingExecutables: [],
                smokeTestFailure: nil,
                storageUnavailablePath: nil
            )
        }
    }

    private func finishedPluginPackOperation(
        in operationCenter: OperationCenter,
        packName: String,
        timeout: TimeInterval = 1
    ) async -> OperationCenter.Item? {
        let title = "Plugin Pack: \(packName)"
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let item = operationCenter.items.first(where: { $0.title == title && $0.state != .running }) {
                return item
            }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return operationCenter.items.first(where: { $0.title == title && $0.state != .running })
    }

    private func pluginManagerViewModelSourceURL() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources")
            .appendingPathComponent("LungfishApp")
            .appendingPathComponent("Views")
            .appendingPathComponent("PluginManager")
            .appendingPathComponent("PluginManagerViewModel.swift")
    }

    private func sourceSection(in source: String, from start: String, to end: String) throws -> String {
        let startRange = try XCTUnwrap(source.range(of: start))
        let endRange = try XCTUnwrap(source.range(
            of: end,
            range: startRange.upperBound..<source.endIndex
        ))
        return String(source[startRange.lowerBound..<endRange.lowerBound])
    }
}
