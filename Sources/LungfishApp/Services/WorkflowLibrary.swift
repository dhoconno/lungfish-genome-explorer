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
    let toolID: FASTQOperationToolID?
    let title: String
    let subtitle: String
    let categoryID: FASTQOperationCategoryID
    let maturity: WorkflowLibraryMaturity
    let requiredPluginPackIDs: [String]
    let capabilities: Set<WorkflowLibraryCapability>

    init(
        toolID: FASTQOperationToolID,
        title: String? = nil,
        subtitle: String? = nil,
        maturity: WorkflowLibraryMaturity,
        requiredPluginPackIDs: [String] = [],
        capabilities: Set<WorkflowLibraryCapability> = []
    ) {
        self.id = toolID.rawValue
        self.toolID = toolID
        self.title = title ?? toolID.title
        self.subtitle = subtitle ?? toolID.subtitle
        self.categoryID = toolID.categoryID
        self.maturity = maturity
        self.requiredPluginPackIDs = requiredPluginPackIDs
        self.capabilities = capabilities
    }

    init(
        id: String,
        title: String,
        subtitle: String,
        categoryID: FASTQOperationCategoryID,
        maturity: WorkflowLibraryMaturity,
        requiredPluginPackIDs: [String] = [],
        capabilities: Set<WorkflowLibraryCapability> = []
    ) {
        self.id = id
        self.toolID = nil
        self.title = title
        self.subtitle = subtitle
        self.categoryID = categoryID
        self.maturity = maturity
        self.requiredPluginPackIDs = requiredPluginPackIDs
        self.capabilities = capabilities
    }
}

enum WorkflowLibraryCapability: String, Codable, CaseIterable, Sendable {
    case workflowOperations
    case haplotypeDefinitions
}

public struct WorkflowFeatureAvailability: Equatable, Sendable {
    public let hasWorkflowOperations: Bool
    public let hasHaplotypeDefinitions: Bool

    public init(hasWorkflowOperations: Bool, hasHaplotypeDefinitions: Bool) {
        self.hasWorkflowOperations = hasWorkflowOperations
        self.hasHaplotypeDefinitions = hasHaplotypeDefinitions
    }

    @MainActor
    static func current(
        enablementStore: WorkflowLibraryEnablementStore = .shared
    ) -> WorkflowFeatureAvailability {
        let enabledBuiltInCapabilities = Set(
            WorkflowLibraryCatalog.builtIn
                .filter { $0.maturity != .core && enablementStore.isWorkflowEnabled($0) }
                .flatMap(\.capabilities)
        )
        return WorkflowFeatureAvailability(
            hasWorkflowOperations: enabledBuiltInCapabilities.contains(.workflowOperations)
                || !enablementStore.enabledUserWorkflowIDSnapshot.isEmpty,
            hasHaplotypeDefinitions: enabledBuiltInCapabilities.contains(.haplotypeDefinitions)
        )
    }
}

extension Notification.Name {
    static let workflowLibraryEnablementChanged = Notification.Name("com.lungfish.workflowLibraryEnablementChanged")
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
    static let twelveSAmpliconMatchingID = "builtin.12s-amplicon-matching"

    static let twelveSAmpliconMatchingItem = WorkflowLibraryItem(
        id: twelveSAmpliconMatchingID,
        title: "12S Amplicon Matching",
        subtitle: "Match merged 12S amplicon reads exactly to a deduplicated FASTA and review unresolved sequences.",
        categoryID: .classification,
        maturity: .specialized,
        requiredPluginPackIDs: ["lungfish-tools"],
        capabilities: [.workflowOperations]
    )

    static let builtIn: [WorkflowLibraryItem] = FASTQOperationToolID.allCases.map { toolID in
        if toolID == .ontGenotyping {
            return WorkflowLibraryItem(
                toolID: toolID,
                maturity: .specialized,
                requiredPluginPackIDs: ["lungfish-tools", "read-mapping"],
                capabilities: [.workflowOperations, .haplotypeDefinitions]
            )
        }
        return WorkflowLibraryItem(
            toolID: toolID,
            maturity: .core,
            requiredPluginPackIDs: toolID.categoryID.requiredPackIDs
        )
    } + [twelveSAmpliconMatchingItem]

    static func item(for toolID: FASTQOperationToolID) -> WorkflowLibraryItem? {
        builtIn.first { $0.toolID == toolID }
    }

    static func item(id: String) -> WorkflowLibraryItem? {
        builtIn.first { $0.id == id }
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

extension Notification.Name {
    static let workflowLibraryEnablementDidChange = Notification.Name("workflowLibraryEnablementDidChange")
}

@MainActor
final class WorkflowLibraryEnablementStore: WorkflowLibraryEnabling {
    static let shared = WorkflowLibraryEnablementStore()

    private static let enabledWorkflowIDsKey = "WorkflowLibrary.enabledWorkflowIDs"
    private static let enabledUserWorkflowIDsKey = "WorkflowLibrary.enabledUserWorkflowIDs"
    private static let defaultEnabledWorkflowIDs: Set<String> = [
        FASTQOperationToolID.ontGenotyping.rawValue,
    ]

    private let userDefaults: UserDefaults
    private var enabledWorkflowIDs: Set<String>
    private var enabledUserWorkflowIDs: Set<String>

    init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
        self.enabledWorkflowIDs = Self.loadEnabledWorkflowIDs(from: userDefaults)
        self.enabledUserWorkflowIDs = Self.loadSet(
            forKey: Self.enabledUserWorkflowIDsKey,
            from: userDefaults
        )
    }

    var enabledWorkflowIDSnapshot: Set<String> {
        reloadEnablementFromDefaults()
        return enabledWorkflowIDs
    }

    var enabledUserWorkflowIDSnapshot: Set<String> {
        reloadEnablementFromDefaults()
        return enabledUserWorkflowIDs
    }

    func isWorkflowEnabled(_ toolID: FASTQOperationToolID) -> Bool {
        guard let item = WorkflowLibraryCatalog.item(for: toolID) else {
            return true
        }
        return isWorkflowEnabled(item)
    }

    func isWorkflowEnabled(_ item: WorkflowLibraryItem) -> Bool {
        reloadEnablementFromDefaults()
        return item.maturity == .core || enabledWorkflowIDs.contains(item.id)
    }

    func setWorkflow(_ toolID: FASTQOperationToolID, enabled: Bool) {
        guard let item = WorkflowLibraryCatalog.item(for: toolID) else { return }
        setWorkflow(item, enabled: enabled)
    }

    func setWorkflow(_ item: WorkflowLibraryItem, enabled: Bool) {
        guard item.maturity != .core else { return }
        reloadEnablementFromDefaults()
        let wasEnabled = enabledWorkflowIDs.contains(item.id)
        if enabled {
            enabledWorkflowIDs.insert(item.id)
        } else {
            enabledWorkflowIDs.remove(item.id)
        }
        guard wasEnabled != enabled else { return }
        persistEnabledWorkflowIDs()
        postEnablementDidChangeIfNeeded(
            workflowID: item.id,
            enabled: enabled,
            wasEnabled: wasEnabled,
            isUserWorkflow: false
        )
        NotificationCenter.default.post(name: .workflowLibraryEnablementChanged, object: self)
    }

    func isUserWorkflowEnabled(_ manifestID: String) -> Bool {
        reloadEnablementFromDefaults()
        return enabledUserWorkflowIDs.contains(manifestID)
    }

    func isUserWorkflowEnabled(_ package: WorkflowPackageValidationResult) -> Bool {
        isUserWorkflowEnabled(package.manifest.id)
    }

    func setUserWorkflow(_ manifestID: String, enabled: Bool) {
        reloadEnablementFromDefaults()
        let wasEnabled = enabledUserWorkflowIDs.contains(manifestID)
        if enabled {
            enabledUserWorkflowIDs.insert(manifestID)
        } else {
            enabledUserWorkflowIDs.remove(manifestID)
        }
        guard wasEnabled != enabled else { return }
        persistEnabledUserWorkflowIDs()
        postEnablementDidChangeIfNeeded(
            workflowID: manifestID,
            enabled: enabled,
            wasEnabled: wasEnabled,
            isUserWorkflow: true
        )
        NotificationCenter.default.post(name: .workflowLibraryEnablementChanged, object: self)
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

    private static func loadSet(forKey key: String, from userDefaults: UserDefaults) -> Set<String> {
        Set(userDefaults.stringArray(forKey: key) ?? [])
    }

    private static func loadEnabledWorkflowIDs(from userDefaults: UserDefaults) -> Set<String> {
        guard userDefaults.object(forKey: enabledWorkflowIDsKey) != nil else {
            return defaultEnabledWorkflowIDs
        }
        return loadSet(forKey: enabledWorkflowIDsKey, from: userDefaults)
    }

    private func reloadEnablementFromDefaults() {
        enabledWorkflowIDs = Self.loadEnabledWorkflowIDs(from: userDefaults)
        enabledUserWorkflowIDs = Self.loadSet(forKey: Self.enabledUserWorkflowIDsKey, from: userDefaults)
    }

    private func persistEnabledWorkflowIDs() {
        userDefaults.set(Array(enabledWorkflowIDs).sorted(), forKey: Self.enabledWorkflowIDsKey)
    }

    private func persistEnabledUserWorkflowIDs() {
        userDefaults.set(Array(enabledUserWorkflowIDs).sorted(), forKey: Self.enabledUserWorkflowIDsKey)
    }

    private func postEnablementDidChangeIfNeeded(
        workflowID: String,
        enabled: Bool,
        wasEnabled: Bool,
        isUserWorkflow: Bool
    ) {
        guard wasEnabled != enabled else { return }
        NotificationCenter.default.post(
            name: .workflowLibraryEnablementDidChange,
            object: self,
            userInfo: [
                "workflowID": workflowID,
                "enabled": enabled,
                "isUserWorkflow": isUserWorkflow,
            ]
        )
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
