import XCTest
import LungfishWorkflow
@testable import LungfishApp

@MainActor
final class WorkflowLibraryTests: XCTestCase {
    func testBuiltInCatalogRegistersEveryFASTQOperationAndKeepsONTGenotypingSpecialized() throws {
        let catalogToolIDs = Set(WorkflowLibraryCatalog.builtIn.compactMap(\.toolID))
        XCTAssertEqual(catalogToolIDs, Set(FASTQOperationToolID.allCases))

        let ont = try XCTUnwrap(WorkflowLibraryCatalog.item(for: .ontGenotyping))
        XCTAssertEqual(ont.maturity, .specialized)
        XCTAssertEqual(ont.requiredPluginPackIDs, ["lungfish-tools", "read-mapping"])
        XCTAssertEqual(ont.title, "miSeq amplicon ONT MHC genotyping")

        XCTAssertEqual(WorkflowLibraryCatalog.item(for: .minimap2)?.requiredPluginPackIDs, ["read-mapping"])
        XCTAssertEqual(WorkflowLibraryCatalog.item(for: .mafft)?.requiredPluginPackIDs, ["multiple-sequence-alignment"])

        let coreItems = WorkflowLibraryCatalog.builtIn.filter { $0.maturity == .core }
        XCTAssertFalse(coreItems.isEmpty)
        XCTAssertTrue(coreItems.allSatisfy { $0.maturity == .core })
    }

    func testBuiltInCatalogIncludesTwelveSAmpliconMatchingAsSpecializedWorkflow() throws {
        let twelveS = try XCTUnwrap(WorkflowLibraryCatalog.item(id: WorkflowLibraryCatalog.twelveSAmpliconMatchingID))

        XCTAssertNil(twelveS.toolID)
        XCTAssertEqual(twelveS.title, "12S Amplicon Matching")
        XCTAssertEqual(twelveS.maturity, .specialized)
        XCTAssertEqual(twelveS.categoryID, .classification)
        XCTAssertEqual(twelveS.requiredPluginPackIDs, ["lungfish-tools"])
    }

    func testBuiltInCatalogIncludesFullLengthONTMHCGenotypingAsSpecializedWorkflow() throws {
        let workflow = try XCTUnwrap(
            WorkflowLibraryCatalog.item(id: WorkflowLibraryCatalog.fullLengthONTMHCGenotypingID)
        )

        XCTAssertNil(workflow.toolID)
        XCTAssertEqual(workflow.title, "Full-length ONT MHC genotyping")
        XCTAssertEqual(workflow.maturity, .specialized)
        XCTAssertEqual(workflow.categoryID, .classification)
        XCTAssertEqual(workflow.requiredPluginPackIDs, [
            "lungfish-tools",
            "read-mapping",
            "full-length-mhc-genotyping",
        ])
        XCTAssertTrue(workflow.capabilities.contains(.workflowOperations))
        XCTAssertTrue(workflow.capabilities.contains(.haplotypeDefinitions))
    }

    func testBuiltInSectionsGroupCoreWorkflowsBeforeSpecializedWorkflows() throws {
        let sections = WorkflowLibraryCatalog.builtInSections

        XCTAssertEqual(sections.first?.kind, .core)
        XCTAssertEqual(sections.first?.title, "Core Tools")
        XCTAssertTrue(sections.first?.items.allSatisfy { $0.maturity == .core } == true)

        let specialized = try XCTUnwrap(sections.first { $0.kind == .specialized })
        XCTAssertEqual(specialized.title, "Specialized Workflows")
        XCTAssertTrue(specialized.items.contains { $0.toolID == .ontGenotyping })
        XCTAssertTrue(specialized.items.contains { $0.id == WorkflowLibraryCatalog.fullLengthONTMHCGenotypingID })
        XCTAssertTrue(specialized.items.contains { $0.id == WorkflowLibraryCatalog.twelveSAmpliconMatchingID })
        XCTAssertTrue(sections.firstIndex { $0.kind == .core }! < sections.firstIndex { $0.kind == .specialized }!)
    }

    func testCoreSectionGroupsBuiltInToolsByLogicalCategory() throws {
        let core = try XCTUnwrap(WorkflowLibraryCatalog.builtInSections.first { $0.kind == .core })

        XCTAssertTrue(core.groups.contains { $0.title == "Mapping" && $0.items.contains { $0.toolID == .minimap2 } })
        XCTAssertTrue(core.groups.contains { $0.title == "Alignment" && $0.items.contains { $0.toolID == .mafft } })
        XCTAssertFalse(core.groups.flatMap(\.items).contains { $0.toolID == .ontGenotyping })
        XCTAssertFalse(core.groups.flatMap(\.items).contains { $0.id == WorkflowLibraryCatalog.twelveSAmpliconMatchingID })
    }

    func testFreshInstallKeepsNicheWorkflowsOptInAndPersistsExplicitChanges() throws {
        let defaults = try makeDefaults()
        let store = WorkflowLibraryEnablementStore(userDefaults: defaults)
        let twelveS = try XCTUnwrap(WorkflowLibraryCatalog.item(id: WorkflowLibraryCatalog.twelveSAmpliconMatchingID))

        // A fresh install enables ONT genotyping (an enhancement to an existing
        // workflow) but leaves 12S amplicon matching opt-in/disabled.
        XCTAssertTrue(store.isWorkflowEnabled(.minimap2))
        XCTAssertTrue(store.isWorkflowEnabled(.ontGenotyping))
        XCTAssertFalse(
            store.isWorkflowEnabled(twelveS),
            "12S is a niche opt-in workflow; it must be DISABLED on fresh install"
        )

        // Explicitly enabling the niche workflow persists across reloads.
        store.setWorkflow(twelveS, enabled: true)
        XCTAssertTrue(store.isWorkflowEnabled(twelveS))

        let enabledReload = WorkflowLibraryEnablementStore(userDefaults: defaults)
        XCTAssertTrue(enabledReload.isWorkflowEnabled(twelveS))
        XCTAssertTrue(enabledReload.isWorkflowEnabled(.ontGenotyping))

        // Disabling ONT genotyping and the niche workflow also persists.
        enabledReload.setWorkflow(.ontGenotyping, enabled: false)
        enabledReload.setWorkflow(twelveS, enabled: false)
        XCTAssertFalse(enabledReload.isWorkflowEnabled(.ontGenotyping))
        XCTAssertFalse(enabledReload.isWorkflowEnabled(twelveS))

        let disabledReload = WorkflowLibraryEnablementStore(userDefaults: defaults)
        XCTAssertFalse(disabledReload.isWorkflowEnabled(.ontGenotyping))
        XCTAssertFalse(disabledReload.isWorkflowEnabled(twelveS))
    }

    func testEnablementStorePostsChangeNotificationWhenWorkflowAvailabilityChanges() throws {
        let defaults = try makeDefaults()
        let store = WorkflowLibraryEnablementStore(userDefaults: defaults)
        let expectation = expectation(description: "workflow enablement changed")
        let observer = NotificationCenter.default.addObserver(
            forName: .workflowLibraryEnablementDidChange,
            object: nil,
            queue: nil
        ) { notification in
            XCTAssertEqual(notification.userInfo?["workflowID"] as? String, FASTQOperationToolID.ontGenotyping.rawValue)
            expectation.fulfill()
        }
        defer { NotificationCenter.default.removeObserver(observer) }

        store.setWorkflow(.ontGenotyping, enabled: false)

        wait(for: [expectation], timeout: 1)
    }

    func testWorkflowFeatureAvailabilityFollowsEnabledSpecializedAndUserWorkflows() throws {
        let defaults = try makeDefaults()
        let store = WorkflowLibraryEnablementStore(userDefaults: defaults)

        var availability = WorkflowFeatureAvailability.current(enablementStore: store)
        XCTAssertTrue(availability.hasWorkflowOperations)
        XCTAssertTrue(availability.hasHaplotypeDefinitions)

        store.setWorkflow(.ontGenotyping, enabled: false)
        availability = WorkflowFeatureAvailability.current(enablementStore: store)
        XCTAssertFalse(availability.hasWorkflowOperations)
        XCTAssertFalse(availability.hasHaplotypeDefinitions)

        store.setUserWorkflow("org.example.custom", enabled: true)
        availability = WorkflowFeatureAvailability.current(enablementStore: store)
        XCTAssertTrue(availability.hasWorkflowOperations)
        XCTAssertFalse(availability.hasHaplotypeDefinitions)
    }

    func testEnablingSpecializedWorkflowIsBlockedUntilRequiredPluginPacksAreReady() async throws {
        let defaults = try makeDefaults()
        let store = WorkflowLibraryEnablementStore(userDefaults: defaults)
        let ont = try XCTUnwrap(WorkflowLibraryCatalog.item(for: .ontGenotyping))
        store.setWorkflow(.ontGenotyping, enabled: false)

        let blockedProvider = StubWorkflowLibraryPluginStatusProvider(states: [
            "lungfish-tools": .ready,
            "read-mapping": .needsInstall,
        ])
        let blocked = await store.enableWorkflow(ont, using: blockedProvider)
        XCTAssertEqual(blocked, .blocked(missingPackIDs: ["read-mapping"]))
        XCTAssertFalse(store.isWorkflowEnabled(.ontGenotyping))

        let readyProvider = StubWorkflowLibraryPluginStatusProvider(states: [
            "lungfish-tools": .ready,
            "read-mapping": .ready,
        ])
        let enabled = await store.enableWorkflow(ont, using: readyProvider)
        XCTAssertEqual(enabled, .enabled)
        XCTAssertTrue(store.isWorkflowEnabled(.ontGenotyping))
    }

    func testEnablingFullLengthMHCWorkflowRequiresSpecializedSavontBlastPack() async throws {
        let defaults = try makeDefaults()
        let store = WorkflowLibraryEnablementStore(userDefaults: defaults)
        let workflow = try XCTUnwrap(
            WorkflowLibraryCatalog.item(id: WorkflowLibraryCatalog.fullLengthONTMHCGenotypingID)
        )
        store.setWorkflow(workflow, enabled: false)

        let blockedProvider = StubWorkflowLibraryPluginStatusProvider(states: [
            "lungfish-tools": .ready,
            "read-mapping": .ready,
            "full-length-mhc-genotyping": .needsInstall,
        ])
        let blocked = await store.enableWorkflow(workflow, using: blockedProvider)
        XCTAssertEqual(blocked, .blocked(missingPackIDs: ["full-length-mhc-genotyping"]))
        XCTAssertFalse(store.isWorkflowEnabled(workflow))

        let readyProvider = StubWorkflowLibraryPluginStatusProvider(states: [
            "lungfish-tools": .ready,
            "read-mapping": .ready,
            "full-length-mhc-genotyping": .ready,
        ])
        let enabled = await store.enableWorkflow(workflow, using: readyProvider)
        XCTAssertEqual(enabled, .enabled)
        XCTAssertTrue(store.isWorkflowEnabled(workflow))
    }

    func testViewModelInstallsMissingDependenciesBeforeEnablingSpecializedWorkflow() async throws {
        let defaults = try makeDefaults()
        let store = WorkflowLibraryEnablementStore(userDefaults: defaults)
        let statusProvider = InstallingWorkflowLibraryPluginStatusProvider(states: [
            "lungfish-tools": .ready,
            "read-mapping": .needsInstall,
        ])
        let packageStore = WorkflowLibraryImportedPackageStore(userDefaults: defaults)
        let viewModel = WorkflowLibraryViewModel(
            store: store,
            packageStore: packageStore,
            statusProvider: statusProvider
        )
        let ont = try XCTUnwrap(WorkflowLibraryCatalog.item(for: .ontGenotyping))

        await viewModel.refreshDependencyStatuses()
        XCTAssertEqual(viewModel.missingRequiredPluginPackIDs(for: ont), ["read-mapping"])

        await viewModel.installDependenciesAndEnable(ont)

        XCTAssertEqual(statusProvider.installedPackIDs, ["read-mapping"])
        XCTAssertTrue(store.isWorkflowEnabled(.ontGenotyping))
        XCTAssertTrue(viewModel.missingRequiredPluginPackIDs(for: ont).isEmpty)
    }

    func testViewModelInstallsFullLengthMHCPluginPackBeforeEnablingWorkflow() async throws {
        let defaults = try makeDefaults()
        let store = WorkflowLibraryEnablementStore(userDefaults: defaults)
        let workflow = try XCTUnwrap(
            WorkflowLibraryCatalog.item(id: WorkflowLibraryCatalog.fullLengthONTMHCGenotypingID)
        )
        store.setWorkflow(workflow, enabled: false)
        let statusProvider = InstallingWorkflowLibraryPluginStatusProvider(states: [
            "lungfish-tools": .ready,
            "read-mapping": .ready,
            "full-length-mhc-genotyping": .needsInstall,
        ])
        let packageStore = WorkflowLibraryImportedPackageStore(userDefaults: defaults)
        let viewModel = WorkflowLibraryViewModel(
            store: store,
            packageStore: packageStore,
            statusProvider: statusProvider
        )

        await viewModel.refreshDependencyStatuses()
        XCTAssertEqual(viewModel.missingRequiredPluginPackIDs(for: workflow), ["full-length-mhc-genotyping"])

        await viewModel.installDependenciesAndEnable(workflow)

        XCTAssertEqual(statusProvider.installedPackIDs, ["full-length-mhc-genotyping"])
        XCTAssertTrue(store.isWorkflowEnabled(workflow))
        XCTAssertTrue(viewModel.missingRequiredPluginPackIDs(for: workflow).isEmpty)
    }

    func testViewModelImportsValidatedUserWorkflowPackages() async throws {
        let defaults = try makeDefaults()
        let store = WorkflowLibraryEnablementStore(userDefaults: defaults)
        let packageStore = WorkflowLibraryImportedPackageStore(userDefaults: defaults)
        let viewModel = WorkflowLibraryViewModel(
            store: store,
            packageStore: packageStore,
            statusProvider: StubWorkflowLibraryPluginStatusProvider(states: [:])
        )
        let packageURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Examples/WorkflowPackages/hello-world-nextflow.lungfishflowpkg", isDirectory: true)

        try await viewModel.importWorkflowPackage(at: packageURL)

        XCTAssertEqual(viewModel.userWorkflowPackages.map(\.manifest.id), ["org.lungfish.templates.hello-world-nextflow"])
        XCTAssertEqual(viewModel.userWorkflowSections.map(\.title), ["User Workflows"])
        XCTAssertEqual(viewModel.userWorkflowSections.first?.groups.first?.title, "Templates")
    }

    func testWorkflowPackageImportValidatesOffMainAndCachesResult() throws {
        let root = repositoryRoot()
        let viewModelSource = try String(
            contentsOf: root.appendingPathComponent(
                "Sources/LungfishApp/Views/WorkflowLibrary/WorkflowLibraryViewModel.swift"
            ),
            encoding: .utf8
        )
        let storeSource = try String(
            contentsOf: root.appendingPathComponent("Sources/LungfishApp/Services/WorkflowLibrary.swift"),
            encoding: .utf8
        )

        XCTAssertTrue(viewModelSource.contains("Task.detached(priority: .userInitiated)"))
        XCTAssertTrue(viewModelSource.contains("packageStore.addValidatedPackage(result)"))
        XCTAssertTrue(viewModelSource.contains("packageStore.cachedValidatedPackages()"))
        XCTAssertTrue(viewModelSource.contains("packageStore.validatedPackagesInBackground()"))
        XCTAssertTrue(storeSource.contains("private var validationCache"))
        XCTAssertTrue(storeSource.contains("func addValidatedPackage(_ result: WorkflowPackageValidationResult)"))
        XCTAssertTrue(storeSource.contains("func cachedValidatedPackages()"))
        XCTAssertTrue(storeSource.contains("func validatedPackagesInBackground() async"))
        XCTAssertTrue(storeSource.contains("let fingerprint = Self.packageFingerprint(for: url)"))
        XCTAssertTrue(storeSource.contains("cache(result, fingerprint: fingerprint)"))
        XCTAssertTrue(storeSource.contains("withTaskCancellationHandler"))
        XCTAssertTrue(storeSource.contains("manifestSHA256"))
    }

    func testViewModelLoadsColdImportedWorkflowPackagesAsynchronously() async throws {
        let defaults = try makeDefaults()
        let store = WorkflowLibraryEnablementStore(userDefaults: defaults)
        let packageStore = WorkflowLibraryImportedPackageStore(userDefaults: defaults)
        packageStore.addPackage(at: helloWorldNextflowPackageURL())
        let viewModel = WorkflowLibraryViewModel(
            store: store,
            packageStore: packageStore,
            statusProvider: StubWorkflowLibraryPluginStatusProvider(states: [:]),
            automaticallyRefreshUserWorkflowPackages: false
        )

        XCTAssertTrue(viewModel.userWorkflowPackages.isEmpty)

        await viewModel.refreshUserWorkflowPackages()

        XCTAssertEqual(
            viewModel.userWorkflowPackages.map(\.manifest.id),
            ["org.lungfish.templates.hello-world-nextflow"]
        )
    }

    func testImportCancelsStartupPackageRefreshAndClearsLoadingState() async throws {
        let defaults = try makeDefaults()
        let store = WorkflowLibraryEnablementStore(userDefaults: defaults)
        let packageStore = WorkflowLibraryImportedPackageStore(userDefaults: defaults)
        packageStore.addPackage(at: helloWorldNextflowPackageURL())
        let viewModel = WorkflowLibraryViewModel(
            store: store,
            packageStore: packageStore,
            statusProvider: StubWorkflowLibraryPluginStatusProvider(states: [:])
        )

        try await viewModel.importWorkflowPackage(at: helloWorldNextflowPackageURL())

        XCTAssertFalse(viewModel.isLoadingUserWorkflowPackages)
        XCTAssertEqual(
            viewModel.userWorkflowPackages.map(\.manifest.id),
            ["org.lungfish.templates.hello-world-nextflow"]
        )
    }

    func testWorkflowPackageValidationCacheInvalidatesManifestContentChanges() throws {
        let defaults = try makeDefaults()
        let packageStore = WorkflowLibraryImportedPackageStore(userDefaults: defaults)
        let temp = try temporaryDirectory()
        let packageURL = temp.appendingPathComponent("cached.lungfishflowpkg", isDirectory: true)
        try FileManager.default.copyItem(at: helloWorldNextflowPackageURL(), to: packageURL)
        packageStore.addPackage(at: packageURL)

        XCTAssertEqual(
            packageStore.validatedPackages().map(\.manifest.id),
            ["org.lungfish.templates.hello-world-nextflow"]
        )

        let manifestURL = packageURL.appendingPathComponent(WorkflowPackageValidator.manifestFilename)
        let originalManifest = try String(contentsOf: manifestURL, encoding: .utf8)
        let updatedManifest = originalManifest.replacingOccurrences(
            of: "org.lungfish.templates.hello-world-nextflow",
            with: "org.lungfish.templates.hello-world-nextflaw"
        )
        XCTAssertEqual(originalManifest.utf8.count, updatedManifest.utf8.count)
        try updatedManifest.write(to: manifestURL, atomically: true, encoding: .utf8)

        XCTAssertEqual(
            packageStore.validatedPackages().map(\.manifest.id),
            ["org.lungfish.templates.hello-world-nextflaw"]
        )
    }

    func testImportedWorkflowPackagesPersistAcrossViewModels() async throws {
        let defaults = try makeDefaults()
        let store = WorkflowLibraryEnablementStore(userDefaults: defaults)
        let packageStore = WorkflowLibraryImportedPackageStore(userDefaults: defaults)
        let firstViewModel = WorkflowLibraryViewModel(
            store: store,
            packageStore: packageStore,
            statusProvider: StubWorkflowLibraryPluginStatusProvider(states: [:])
        )

        try await firstViewModel.importWorkflowPackage(at: helloWorldNextflowPackageURL())

        let reloadedPackageStore = WorkflowLibraryImportedPackageStore(userDefaults: defaults)
        let reloadedViewModel = WorkflowLibraryViewModel(
            store: WorkflowLibraryEnablementStore(userDefaults: defaults),
            packageStore: reloadedPackageStore,
            statusProvider: StubWorkflowLibraryPluginStatusProvider(states: [:])
        )
        await reloadedViewModel.refreshUserWorkflowPackages()

        XCTAssertEqual(
            reloadedViewModel.userWorkflowPackages.map(\.manifest.id),
            ["org.lungfish.templates.hello-world-nextflow"]
        )
    }

    func testViewModelEnablesImportedUserWorkflowPackageWhenDependenciesAreReady() async throws {
        let defaults = try makeDefaults()
        let store = WorkflowLibraryEnablementStore(userDefaults: defaults)
        let packageStore = WorkflowLibraryImportedPackageStore(userDefaults: defaults)
        let viewModel = WorkflowLibraryViewModel(
            store: store,
            packageStore: packageStore,
            statusProvider: StubWorkflowLibraryPluginStatusProvider(states: [
                "lungfish-tools": .ready,
            ])
        )

        try await viewModel.importWorkflowPackage(at: helloWorldNextflowPackageURL())
        let package = try XCTUnwrap(viewModel.userWorkflowPackages.first)

        XCTAssertFalse(viewModel.enabledUserWorkflowIDs.contains(package.manifest.id))
        XCTAssertFalse(viewModel.isEnabled(package))

        await viewModel.setWorkflow(package, enabled: true)

        XCTAssertTrue(viewModel.enabledUserWorkflowIDs.contains(package.manifest.id))
        XCTAssertTrue(viewModel.isEnabled(package))

        let reloadedStore = WorkflowLibraryEnablementStore(userDefaults: defaults)
        XCTAssertTrue(reloadedStore.isUserWorkflowEnabled(package.manifest.id))
    }

    func testViewModelInstallsMissingDependenciesBeforeEnablingUserWorkflowPackage() async throws {
        let defaults = try makeDefaults()
        let store = WorkflowLibraryEnablementStore(userDefaults: defaults)
        let packageStore = WorkflowLibraryImportedPackageStore(userDefaults: defaults)
        let statusProvider = InstallingWorkflowLibraryPluginStatusProvider(states: [
            "lungfish-tools": .needsInstall,
        ])
        let viewModel = WorkflowLibraryViewModel(
            store: store,
            packageStore: packageStore,
            statusProvider: statusProvider
        )

        try await viewModel.importWorkflowPackage(at: helloWorldNextflowPackageURL())
        let package = try XCTUnwrap(viewModel.userWorkflowPackages.first)

        XCTAssertEqual(viewModel.missingRequiredPluginPackIDs(for: package), ["lungfish-tools"])

        await viewModel.installDependenciesAndEnable(package)

        XCTAssertEqual(statusProvider.installedPackIDs, ["lungfish-tools"])
        XCTAssertTrue(viewModel.isEnabled(package))
        XCTAssertTrue(viewModel.missingRequiredPluginPackIDs(for: package).isEmpty)
    }

    private func makeDefaults() throws -> UserDefaults {
        let suiteName = "WorkflowLibraryTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }

    private func helloWorldNextflowPackageURL() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Examples/WorkflowPackages/hello-world-nextflow.lungfishflowpkg", isDirectory: true)
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("WorkflowLibraryTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func repositoryRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }
}

private final class StubWorkflowLibraryPluginStatusProvider: PluginPackStatusProviding, @unchecked Sendable {
    let states: [String: PluginPackState]

    init(states: [String: PluginPackState]) {
        self.states = states
    }

    func visibleStatuses() async -> [PluginPackStatus] {
        await visibleStatuses(includeExperimental: true)
    }

    func visibleStatuses(includeExperimental: Bool) async -> [PluginPackStatus] {
        states.compactMap { packID, state in
            guard let pack = PluginPack.builtInPack(id: packID) else { return nil }
            return PluginPackStatus(pack: pack, state: state, toolStatuses: [], failureMessage: nil)
        }
    }

    func status(for pack: PluginPack) async -> PluginPackStatus {
        PluginPackStatus(pack: pack, state: states[pack.id] ?? .needsInstall, toolStatuses: [], failureMessage: nil)
    }

    func status(forPackID packID: String) async -> PluginPackStatus? {
        guard let pack = PluginPack.builtInPack(id: packID) else { return nil }
        return PluginPackStatus(pack: pack, state: states[packID] ?? .needsInstall, toolStatuses: [], failureMessage: nil)
    }

    func invalidateVisibleStatusesCache() async {}

    func install(
        pack: PluginPack,
        reinstall: Bool,
        progress: (@Sendable (PluginPackInstallProgress) -> Void)?
    ) async throws {}
}

@MainActor
private final class InstallingWorkflowLibraryPluginStatusProvider: PluginPackStatusProviding, @unchecked Sendable {
    private(set) var states: [String: PluginPackState]
    private(set) var installedPackIDs: [String] = []

    init(states: [String: PluginPackState]) {
        self.states = states
    }

    func visibleStatuses() async -> [PluginPackStatus] {
        await visibleStatuses(includeExperimental: true)
    }

    func visibleStatuses(includeExperimental: Bool) async -> [PluginPackStatus] {
        states.compactMap { packID, state in
            guard let pack = PluginPack.builtInPack(id: packID) else { return nil }
            return PluginPackStatus(pack: pack, state: state, toolStatuses: [], failureMessage: nil)
        }
    }

    func status(for pack: PluginPack) async -> PluginPackStatus {
        PluginPackStatus(pack: pack, state: states[pack.id] ?? .needsInstall, toolStatuses: [], failureMessage: nil)
    }

    func status(forPackID packID: String) async -> PluginPackStatus? {
        guard let pack = PluginPack.builtInPack(id: packID) else { return nil }
        return PluginPackStatus(pack: pack, state: states[packID] ?? .needsInstall, toolStatuses: [], failureMessage: nil)
    }

    func invalidateVisibleStatusesCache() async {}

    func install(
        pack: PluginPack,
        reinstall: Bool,
        progress: (@Sendable (PluginPackInstallProgress) -> Void)?
    ) async throws {
        installedPackIDs.append(pack.id)
        states[pack.id] = .ready
    }
}
