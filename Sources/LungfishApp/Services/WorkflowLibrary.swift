import Foundation
import LungfishWorkflow

enum WorkflowLibraryMaturity: String, Codable, CaseIterable, Sendable {
    case core
    case specialized
    case experimental

    var displayName: String {
        switch self {
        case .core: return "Core"
        case .specialized: return "Specialized"
        case .experimental: return "Experimental"
        }
    }
}

struct WorkflowLibraryItem: Identifiable, Equatable, Sendable {
    let id: String
    let toolID: FASTQOperationToolID
    let title: String
    let subtitle: String
    let categoryID: FASTQOperationCategoryID
    let maturity: WorkflowLibraryMaturity
    let requiredPluginPackIDs: [String]

    init(
        toolID: FASTQOperationToolID,
        title: String? = nil,
        subtitle: String? = nil,
        maturity: WorkflowLibraryMaturity,
        requiredPluginPackIDs: [String] = []
    ) {
        self.id = toolID.rawValue
        self.toolID = toolID
        self.title = title ?? toolID.title
        self.subtitle = subtitle ?? toolID.subtitle
        self.categoryID = toolID.categoryID
        self.maturity = maturity
        self.requiredPluginPackIDs = requiredPluginPackIDs
    }
}

enum WorkflowLibrarySectionKind: String, Sendable, Codable, Equatable {
    case core
    case specialized
    case user
}

struct WorkflowLibraryGroup: Identifiable, Equatable, Sendable {
    let id: String
    let title: String
    let items: [WorkflowLibraryItem]

    init(title: String, items: [WorkflowLibraryItem]) {
        self.id = title.lowercased().replacingOccurrences(of: " ", with: "-")
        self.title = title
        self.items = items
    }
}

struct WorkflowLibrarySection: Identifiable, Equatable, Sendable {
    let kind: WorkflowLibrarySectionKind
    let title: String
    let groups: [WorkflowLibraryGroup]

    var id: String { kind.rawValue }
    var items: [WorkflowLibraryItem] { groups.flatMap(\.items) }
}

enum WorkflowLibraryCatalog {
    static let builtIn: [WorkflowLibraryItem] = FASTQOperationToolID.allCases.map { toolID in
        if toolID == .ontGenotyping {
            return WorkflowLibraryItem(
                toolID: toolID,
                maturity: .specialized,
                requiredPluginPackIDs: ["lungfish-tools", "read-mapping"]
            )
        }
        return WorkflowLibraryItem(
            toolID: toolID,
            maturity: .core,
            requiredPluginPackIDs: toolID.categoryID.requiredPackIDs
        )
    }

    static func item(for toolID: FASTQOperationToolID) -> WorkflowLibraryItem? {
        builtIn.first { $0.toolID == toolID }
    }

    static var builtInSections: [WorkflowLibrarySection] {
        let coreItems = builtIn.filter { $0.maturity == .core }
        let specializedItems = builtIn.filter { $0.maturity == .specialized }
        return [
            WorkflowLibrarySection(
                kind: .core,
                title: "Core Tools",
                groups: groupedByCategory(coreItems)
            ),
            WorkflowLibrarySection(
                kind: .specialized,
                title: "Specialized Workflows",
                groups: groupedByCategory(specializedItems)
            ),
        ].filter { !$0.items.isEmpty }
    }

    static func userSections(for packages: [WorkflowPackageValidationResult]) -> [WorkflowLibraryUserSection] {
        let groups = Dictionary(grouping: packages) { result in
            result.manifest.category
        }
        .map { category, packages in
            WorkflowLibraryUserGroup(
                title: category,
                packages: packages.sorted {
                    $0.manifest.name.localizedStandardCompare($1.manifest.name) == .orderedAscending
                }
            )
        }
        .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }

        guard !groups.isEmpty else { return [] }
        return [WorkflowLibraryUserSection(title: "User Workflows", groups: groups)]
    }

    private static func groupedByCategory(_ items: [WorkflowLibraryItem]) -> [WorkflowLibraryGroup] {
        Dictionary(grouping: items) { displayTitle(for: $0.categoryID) }
            .map { category, items in
                WorkflowLibraryGroup(
                    title: category,
                    items: items.sorted {
                        $0.title.localizedStandardCompare($1.title) == .orderedAscending
                    }
                )
            }
            .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }

    private static func displayTitle(for categoryID: FASTQOperationCategoryID) -> String {
        switch categoryID {
        case .qcReporting: return "QC & Reporting"
        case .demultiplexing: return "Demultiplexing"
        case .trimmingFiltering: return "Trimming & Filtering"
        case .decontamination: return "Decontamination"
        case .readProcessing: return "Read Processing"
        case .searchSubsetting: return "Search & Subsetting"
        case .alignment: return "Alignment"
        case .mapping: return "Mapping"
        case .assembly: return "Assembly"
        case .clustering: return "Clustering"
        case .classification: return "Classification"
        }
    }
}

struct WorkflowLibraryUserGroup: Identifiable, Equatable, Sendable {
    let id: String
    let title: String
    let packages: [WorkflowPackageValidationResult]

    init(title: String, packages: [WorkflowPackageValidationResult]) {
        self.id = title.lowercased().replacingOccurrences(of: " ", with: "-")
        self.title = title
        self.packages = packages
    }
}

struct WorkflowLibraryUserSection: Identifiable, Equatable, Sendable {
    let title: String
    let groups: [WorkflowLibraryUserGroup]

    var id: String { title.lowercased().replacingOccurrences(of: " ", with: "-") }
}

@MainActor
protocol WorkflowLibraryEnabling: AnyObject {
    func isWorkflowEnabled(_ toolID: FASTQOperationToolID) -> Bool
}

enum WorkflowLibraryEnablementResult: Equatable, Sendable {
    case enabled
    case blocked(missingPackIDs: [String])
}

@MainActor
final class WorkflowLibraryEnablementStore: WorkflowLibraryEnabling {
    static let shared = WorkflowLibraryEnablementStore()

    private static let enabledWorkflowIDsKey = "WorkflowLibrary.enabledWorkflowIDs"
    private static let enabledUserWorkflowIDsKey = "WorkflowLibrary.enabledUserWorkflowIDs"

    private let userDefaults: UserDefaults
    private var enabledWorkflowIDs: Set<String> {
        didSet {
            userDefaults.set(Array(enabledWorkflowIDs).sorted(), forKey: Self.enabledWorkflowIDsKey)
        }
    }
    private var enabledUserWorkflowIDs: Set<String> {
        didSet {
            userDefaults.set(Array(enabledUserWorkflowIDs).sorted(), forKey: Self.enabledUserWorkflowIDsKey)
        }
    }

    init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
        let storedIDs = userDefaults.stringArray(forKey: Self.enabledWorkflowIDsKey) ?? []
        self.enabledWorkflowIDs = Set(storedIDs)
        let storedUserWorkflowIDs = userDefaults.stringArray(forKey: Self.enabledUserWorkflowIDsKey) ?? []
        self.enabledUserWorkflowIDs = Set(storedUserWorkflowIDs)
    }

    var enabledWorkflowIDSnapshot: Set<String> {
        enabledWorkflowIDs
    }

    var enabledUserWorkflowIDSnapshot: Set<String> {
        enabledUserWorkflowIDs
    }

    func isWorkflowEnabled(_ toolID: FASTQOperationToolID) -> Bool {
        guard let item = WorkflowLibraryCatalog.item(for: toolID) else {
            return true
        }
        return isWorkflowEnabled(item)
    }

    func isWorkflowEnabled(_ item: WorkflowLibraryItem) -> Bool {
        item.maturity == .core || enabledWorkflowIDs.contains(item.id)
    }

    func setWorkflow(_ toolID: FASTQOperationToolID, enabled: Bool) {
        guard let item = WorkflowLibraryCatalog.item(for: toolID) else { return }
        setWorkflow(item, enabled: enabled)
    }

    func setWorkflow(_ item: WorkflowLibraryItem, enabled: Bool) {
        guard item.maturity != .core else { return }
        if enabled {
            enabledWorkflowIDs.insert(item.id)
        } else {
            enabledWorkflowIDs.remove(item.id)
        }
    }

    func isUserWorkflowEnabled(_ manifestID: String) -> Bool {
        enabledUserWorkflowIDs.contains(manifestID)
    }

    func isUserWorkflowEnabled(_ package: WorkflowPackageValidationResult) -> Bool {
        isUserWorkflowEnabled(package.manifest.id)
    }

    func setUserWorkflow(_ manifestID: String, enabled: Bool) {
        if enabled {
            enabledUserWorkflowIDs.insert(manifestID)
        } else {
            enabledUserWorkflowIDs.remove(manifestID)
        }
    }

    func setUserWorkflow(_ package: WorkflowPackageValidationResult, enabled: Bool) {
        setUserWorkflow(package.manifest.id, enabled: enabled)
    }

    func enableWorkflow(
        _ item: WorkflowLibraryItem,
        using provider: any PluginPackStatusProviding
    ) async -> WorkflowLibraryEnablementResult {
        let missingPackIDs = await missingRequiredPluginPackIDs(for: item, using: provider)
        guard missingPackIDs.isEmpty else {
            return .blocked(missingPackIDs: missingPackIDs)
        }
        setWorkflow(item, enabled: true)
        return .enabled
    }

    func enableUserWorkflow(
        _ package: WorkflowPackageValidationResult,
        using provider: any PluginPackStatusProviding
    ) async -> WorkflowLibraryEnablementResult {
        let missingPackIDs = await missingRequiredPluginPackIDs(for: package, using: provider)
        guard missingPackIDs.isEmpty else {
            return .blocked(missingPackIDs: missingPackIDs)
        }
        setUserWorkflow(package, enabled: true)
        return .enabled
    }

    func missingRequiredPluginPackIDs(
        for item: WorkflowLibraryItem,
        using provider: any PluginPackStatusProviding
    ) async -> [String] {
        await missingRequiredPluginPackIDs(item.requiredPluginPackIDs, using: provider)
    }

    func missingRequiredPluginPackIDs(
        for package: WorkflowPackageValidationResult,
        using provider: any PluginPackStatusProviding
    ) async -> [String] {
        await missingRequiredPluginPackIDs(package.manifest.requiredPluginPackIDs, using: provider)
    }

    private func missingRequiredPluginPackIDs(
        _ requiredPluginPackIDs: [String],
        using provider: any PluginPackStatusProviding
    ) async -> [String] {
        var missing: [String] = []
        for packID in requiredPluginPackIDs {
            guard let status = await provider.status(forPackID: packID),
                  status.state == .ready else {
                missing.append(packID)
                continue
            }
        }
        return missing
    }
}

@MainActor
final class WorkflowLibraryImportedPackageStore {
    static let shared = WorkflowLibraryImportedPackageStore()

    private static let importedPackagePathsKey = "WorkflowLibrary.importedWorkflowPackagePaths"

    private let userDefaults: UserDefaults
    private var packagePaths: [String] {
        didSet {
            userDefaults.set(packagePaths, forKey: Self.importedPackagePathsKey)
        }
    }

    init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
        self.packagePaths = userDefaults.stringArray(forKey: Self.importedPackagePathsKey) ?? []
    }

    var packageURLSnapshot: [URL] {
        packagePaths.map { URL(fileURLWithPath: $0).standardizedFileURL }
    }

    func validatedPackages() -> [WorkflowPackageValidationResult] {
        packageURLSnapshot.compactMap { try? WorkflowPackageValidator.validatePackage(at: $0) }
    }

    func addPackage(at packageURL: URL) {
        let path = packageURL.standardizedFileURL.path
        packagePaths.removeAll { $0 == path }
        packagePaths.append(path)
    }

    func removePackage(withManifestID manifestID: String) {
        packagePaths.removeAll { path in
            let url = URL(fileURLWithPath: path).standardizedFileURL
            guard let result = try? WorkflowPackageValidator.validatePackage(at: url) else { return false }
            return result.manifest.id == manifestID
        }
    }
}
