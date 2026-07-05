import Foundation
import LungfishWorkflow
import Observation

struct WorkflowLibraryPackageStatusRow: Equatable, Identifiable, Sendable {
    let id: String
    let label: String
    let value: String
    let isReady: Bool
}

@MainActor
@Observable
final class WorkflowLibraryViewModel {
    let items: [WorkflowLibraryItem]

    private let store: WorkflowLibraryEnablementStore
    private let packageStore: WorkflowLibraryImportedPackageStore
    private let statusProvider: any PluginPackStatusProviding
    @ObservationIgnored private var userWorkflowPackageRefreshTask: Task<Void, Never>?
    @ObservationIgnored private var userWorkflowPackageRefreshGeneration: UInt64 = 0

    var pluginStatusesByPackID: [String: PluginPackStatus] = [:]
    var isRefreshing: Bool = false
    var isLoadingUserWorkflowPackages: Bool = false
    var installingWorkflowIDs: Set<String> = []
    var errorMessage: String?
    var showingError: Bool = false
    var userWorkflowPackages: [WorkflowPackageValidationResult] = []
    var enabledWorkflowIDs: Set<String>
    var enabledUserWorkflowIDs: Set<String>

    var builtInSections: [WorkflowLibrarySection] {
        WorkflowLibraryCatalog.builtInSections
    }

    var userWorkflowSections: [WorkflowLibraryUserSection] {
        WorkflowLibraryCatalog.userSections(for: userWorkflowPackages)
    }

    init(
        items: [WorkflowLibraryItem] = WorkflowLibraryCatalog.builtIn,
        store: WorkflowLibraryEnablementStore = .shared,
        packageStore: WorkflowLibraryImportedPackageStore = .shared,
        statusProvider: any PluginPackStatusProviding = PluginPackStatusService.shared,
        automaticallyRefreshUserWorkflowPackages: Bool = true
    ) {
        self.items = items
        self.store = store
        self.packageStore = packageStore
        self.statusProvider = statusProvider
        self.enabledWorkflowIDs = store.enabledWorkflowIDSnapshot
        self.enabledUserWorkflowIDs = store.enabledUserWorkflowIDSnapshot
        self.userWorkflowPackages = packageStore.cachedValidatedPackages()
        if automaticallyRefreshUserWorkflowPackages {
            startUserWorkflowPackageRefresh()
        }
    }

    deinit {
        userWorkflowPackageRefreshTask?.cancel()
    }

    func isEnabled(_ item: WorkflowLibraryItem) -> Bool {
        item.maturity == .core || enabledWorkflowIDs.contains(item.id)
    }

    func isEnabled(_ package: WorkflowPackageValidationResult) -> Bool {
        package.supportsWorkflowLibraryExecution && enabledUserWorkflowIDs.contains(package.manifest.id)
    }

    func canDisable(_ item: WorkflowLibraryItem) -> Bool {
        item.maturity != .core
    }

    func missingRequiredPluginPackIDs(for item: WorkflowLibraryItem) -> [String] {
        item.requiredPluginPackIDs.filter { packID in
            pluginStatusesByPackID[packID]?.state != .ready
        }
    }

    func missingRequiredPluginPackIDs(for package: WorkflowPackageValidationResult) -> [String] {
        package.manifest.requiredPluginPackIDs.filter { packID in
            pluginStatusesByPackID[packID]?.state != .ready
        }
    }

    func pluginPackName(for packID: String) -> String {
        PluginPack.builtInPack(id: packID)?.name ?? packID
    }

    func dependencySummary(for item: WorkflowLibraryItem) -> String {
        guard !item.requiredPluginPackIDs.isEmpty else {
            return "No managed plug-ins required"
        }
        return item.requiredPluginPackIDs.map(pluginPackName(for:)).joined(separator: ", ")
    }

    func dependencyStatusRows(for package: WorkflowPackageValidationResult) -> [WorkflowLibraryPackageStatusRow] {
        guard !package.manifest.requiredPluginPackIDs.isEmpty else {
            return [
                WorkflowLibraryPackageStatusRow(
                    id: "dependencies.none",
                    label: "Dependencies",
                    value: "No managed plug-ins required",
                    isReady: true
                ),
            ]
        }
        let missingPackIDs = Set(missingRequiredPluginPackIDs(for: package))
        return package.manifest.requiredPluginPackIDs.map { packID in
            let ready = !missingPackIDs.contains(packID)
            return WorkflowLibraryPackageStatusRow(
                id: "dependency.\(packID)",
                label: "Dependency",
                value: "\(pluginPackName(for: packID)) - \(ready ? "Ready" : "Needs install")",
                isReady: ready
            )
        }
    }

    func refreshDependencyStatuses() async {
        isRefreshing = true
        defer { isRefreshing = false }
        var statuses: [String: PluginPackStatus] = [:]
        let packagePackIDs = userWorkflowPackages.flatMap(\.manifest.requiredPluginPackIDs)
        let packIDs = Set(items.flatMap(\.requiredPluginPackIDs) + packagePackIDs)
        for packID in packIDs {
            if let status = await statusProvider.status(forPackID: packID) {
                statuses[packID] = status
            }
        }
        pluginStatusesByPackID = statuses
    }

    func refreshUserWorkflowPackages() async {
        userWorkflowPackageRefreshTask?.cancel()
        userWorkflowPackageRefreshGeneration &+= 1
        let generation = userWorkflowPackageRefreshGeneration
        isLoadingUserWorkflowPackages = true
        let packages = await packageStore.validatedPackagesInBackground()
        if generation == userWorkflowPackageRefreshGeneration {
            isLoadingUserWorkflowPackages = false
        }
        guard !Task.isCancelled,
              generation == userWorkflowPackageRefreshGeneration else {
            return
        }
        userWorkflowPackages = packages
        await refreshDependencyStatuses()
    }

    func importWorkflowPackage(at packageURL: URL) async throws {
        userWorkflowPackageRefreshTask?.cancel()
        userWorkflowPackageRefreshGeneration &+= 1
        isLoadingUserWorkflowPackages = false
        let result = try await Task.detached(priority: .userInitiated) {
            try WorkflowPackageValidator.validatePackage(at: packageURL)
        }.value
        packageStore.addValidatedPackage(result)
        if let index = userWorkflowPackages.firstIndex(where: { $0.manifest.id == result.manifest.id }) {
            userWorkflowPackages[index] = result
        } else {
            userWorkflowPackages.append(result)
            userWorkflowPackages.sort {
                $0.manifest.name.localizedStandardCompare($1.manifest.name) == .orderedAscending
            }
        }
        await refreshDependencyStatuses()
    }

    func setWorkflow(_ item: WorkflowLibraryItem, enabled: Bool) async {
        guard enabled else {
            store.setWorkflow(item, enabled: false)
            syncEnablementState()
            return
        }

        let result = await store.enableWorkflow(item, using: statusProvider)
        if result == .enabled {
            syncEnablementState()
        }
        if case .blocked(let missingPackIDs) = result {
            errorMessage = "Install required plug-ins before enabling \(item.title): \(missingPackIDs.map(pluginPackName(for:)).joined(separator: ", "))."
            showingError = true
        }
        await refreshDependencyStatuses()
    }

    func setWorkflow(_ package: WorkflowPackageValidationResult, enabled: Bool) async {
        guard enabled else {
            store.setUserWorkflow(package, enabled: false)
            syncEnablementState()
            return
        }

        let result = await store.enableUserWorkflow(package, using: statusProvider)
        switch result {
        case .enabled:
            syncEnablementState()
        case .blocked(let missingPackIDs):
            errorMessage = "Install required plug-ins before enabling \(package.manifest.name): \(missingPackIDs.map(pluginPackName(for:)).joined(separator: ", "))."
            showingError = true
        case .unsupportedRunner:
            showUnsupportedRunnerError(for: package)
        }
        await refreshDependencyStatuses()
    }

    func installDependenciesAndEnable(_ item: WorkflowLibraryItem) async {
        installingWorkflowIDs.insert(item.id)
        defer { installingWorkflowIDs.remove(item.id) }

        do {
            await refreshDependencyStatuses()
            let missingPackIDs = missingRequiredPluginPackIDs(for: item)
            for packID in missingPackIDs {
                guard let pack = PluginPack.builtInPack(id: packID) else {
                    continue
                }
                try await statusProvider.install(pack: pack, reinstall: false, progress: nil)
                await statusProvider.invalidateVisibleStatusesCache()
            }
            await refreshDependencyStatuses()
            let result = await store.enableWorkflow(item, using: statusProvider)
            if result == .enabled {
                syncEnablementState()
            }
            if case .blocked(let missingPackIDs) = result {
                errorMessage = "Could not enable \(item.title). Still missing: \(missingPackIDs.map(pluginPackName(for:)).joined(separator: ", "))."
                showingError = true
            }
        } catch {
            errorMessage = "Could not install plug-ins for \(item.title): \(error.localizedDescription)"
            showingError = true
        }
    }

    func installDependenciesAndEnable(_ package: WorkflowPackageValidationResult) async {
        guard package.supportsWorkflowLibraryExecution else {
            showUnsupportedRunnerError(for: package)
            return
        }

        installingWorkflowIDs.insert(package.manifest.id)
        defer { installingWorkflowIDs.remove(package.manifest.id) }

        do {
            await refreshDependencyStatuses()
            let missingPackIDs = missingRequiredPluginPackIDs(for: package)
            for packID in missingPackIDs {
                guard let pack = PluginPack.builtInPack(id: packID) else {
                    continue
                }
                try await statusProvider.install(pack: pack, reinstall: false, progress: nil)
                await statusProvider.invalidateVisibleStatusesCache()
            }
            await refreshDependencyStatuses()
            let result = await store.enableUserWorkflow(package, using: statusProvider)
            switch result {
            case .enabled:
                syncEnablementState()
            case .blocked(let missingPackIDs):
                errorMessage = "Could not enable \(package.manifest.name). Still missing: \(missingPackIDs.map(pluginPackName(for:)).joined(separator: ", "))."
                showingError = true
            case .unsupportedRunner:
                showUnsupportedRunnerError(for: package)
            }
        } catch {
            errorMessage = "Could not install plug-ins for \(package.manifest.name): \(error.localizedDescription)"
            showingError = true
        }
    }

    private func showUnsupportedRunnerError(for package: WorkflowPackageValidationResult) {
        let reason = package.workflowLibraryExecutionUnavailableReason
            ?? "This runner type is not executable from Workflow Operations."
        errorMessage = "\(package.manifest.name) is catalog-only. \(reason)"
        showingError = true
    }

    private func syncEnablementState() {
        enabledWorkflowIDs = store.enabledWorkflowIDSnapshot
        enabledUserWorkflowIDs = store.enabledUserWorkflowIDSnapshot
    }

    private func startUserWorkflowPackageRefresh() {
        userWorkflowPackageRefreshTask?.cancel()
        userWorkflowPackageRefreshGeneration &+= 1
        let generation = userWorkflowPackageRefreshGeneration
        let packageStore = packageStore
        userWorkflowPackageRefreshTask = Task { @MainActor [weak self, packageStore] in
            guard !Task.isCancelled else { return }
            self?.isLoadingUserWorkflowPackages = true
            let packages = await packageStore.validatedPackagesInBackground()
            guard let self else { return }
            if generation == self.userWorkflowPackageRefreshGeneration {
                self.isLoadingUserWorkflowPackages = false
            }
            guard !Task.isCancelled,
                  generation == self.userWorkflowPackageRefreshGeneration else {
                return
            }
            self.userWorkflowPackages = packages
            await self.refreshDependencyStatuses()
        }
    }

}
