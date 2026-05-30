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
        XCTAssertEqual(ont.title, "Amplicon Genotyping")

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

    func testBuiltInSectionsGroupCoreWorkflowsBeforeSpecializedWorkflows() throws {
        let sections = WorkflowLibraryCatalog.builtInSections

        XCTAssertEqual(sections.first?.kind, .core)
        XCTAssertEqual(sections.first?.title, "Core Tools")
        XCTAssertTrue(sections.first?.items.allSatisfy { $0.maturity == .core } == true)

        let specialized = try XCTUnwrap(sections.first { $0.kind == .specialized })
        XCTAssertEqual(specialized.title, "Specialized Workflows")
        XCTAssertTrue(specialized.items.contains { $0.toolID == .ontGenotyping })
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

    func testFreshInstallEnablesBundledSpecializedWorkflowsAndPersistsExplicitChanges() throws {
        let defaults = try makeDefaults()
        let store = WorkflowLibraryEnablementStore(userDefaults: defaults)
        let twelveS = try XCTUnwrap(WorkflowLibraryCatalog.item(id: WorkflowLibraryCatalog.twelveSAmpliconMatchingID))

        XCTAssertTrue(store.isWorkflowEnabled(.minimap2))
        XCTAssertTrue(store.isWorkflowEnabled(.ontGenotyping))
        XCTAssertTrue(store.isWorkflowEnabled(twelveS))

        store.setWorkflow(.ontGenotyping, enabled: false)
        store.setWorkflow(twelveS, enabled: false)
        XCTAssertFalse(store.isWorkflowEnabled(.ontGenotyping))
        XCTAssertFalse(store.isWorkflowEnabled(twelveS))

        let reloaded = WorkflowLibraryEnablementStore(userDefaults: defaults)
        XCTAssertFalse(reloaded.isWorkflowEnabled(.ontGenotyping))
        XCTAssertFalse(reloaded.isWorkflowEnabled(twelveS))

        reloaded.setWorkflow(.ontGenotyping, enabled: true)
        reloaded.setWorkflow(twelveS, enabled: true)
        XCTAssertTrue(reloaded.isWorkflowEnabled(.ontGenotyping))
        XCTAssertTrue(reloaded.isWorkflowEnabled(twelveS))
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
