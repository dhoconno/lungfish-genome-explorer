import Foundation
import LungfishWorkflow
import Observation

@MainActor
@Observable
final class WorkflowLibraryViewModel {
    enum Tab: Hashable, Sendable {
        case library
        case installed
        case runs

        var segmentIndex: Int {
            switch self {
            case .library: return 0
            case .installed: return 1
            case .runs: return 2
            }
        }

        static func from(segmentIndex: Int) -> Tab {
            switch segmentIndex {
            case 0: return .library
            case 1: return .installed
            case 2: return .runs
            default: return .library
            }
        }
    }

    let items: [WorkflowLibraryItem]

    private let store: WorkflowLibraryEnablementStore
    private let packageStore: WorkflowLibraryImportedPackageStore
    private let statusProvider: any PluginPackStatusProviding

    var selectedTab: Tab = .library
    var pluginStatusesByPackID: [String: PluginPackStatus] = [:]
    var isRefreshing: Bool = false
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
        statusProvider: any PluginPackStatusProviding = PluginPackStatusService.shared
    ) {
        self.items = items
        self.store = store
        self.packageStore = packageStore
        self.statusProvider = statusProvider
        self.enabledWorkflowIDs = store.enabledWorkflowIDSnapshot
        self.enabledUserWorkflowIDs = store.enabledUserWorkflowIDSnapshot
        self.userWorkflowPackages = packageStore.validatedPackages()
    }

    func isEnabled(_ item: WorkflowLibraryItem) -> Bool {
        item.maturity == .core || enabledWorkflowIDs.contains(item.id)
    }

    func isEnabled(_ package: WorkflowPackageValidationResult) -> Bool {
        enabledUserWorkflowIDs.contains(package.manifest.id)
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

    func importWorkflowPackage(at packageURL: URL) async throws {
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
        if result == .enabled {
            syncEnablementState()
        }
        if case .blocked(let missingPackIDs) = result {
            errorMessage = "Install required plug-ins before enabling \(package.manifest.name): \(missingPackIDs.map(pluginPackName(for:)).joined(separator: ", "))."
            showingError = true
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
            if result == .enabled {
                syncEnablementState()
            }
            if case .blocked(let missingPackIDs) = result {
                errorMessage = "Could not enable \(package.manifest.name). Still missing: \(missingPackIDs.map(pluginPackName(for:)).joined(separator: ", "))."
                showingError = true
            }
        } catch {
            errorMessage = "Could not install plug-ins for \(package.manifest.name): \(error.localizedDescription)"
            showingError = true
        }
    }

    private func syncEnablementState() {
        enabledWorkflowIDs = store.enabledWorkflowIDSnapshot
        enabledUserWorkflowIDs = store.enabledUserWorkflowIDSnapshot
    }
}
