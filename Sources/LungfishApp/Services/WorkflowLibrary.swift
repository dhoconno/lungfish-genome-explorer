import Foundation
import CryptoKit
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
        enablementStore: WorkflowLibraryEnablementStore = .shared,
        packageStore: WorkflowLibraryImportedPackageStore = .shared
    ) -> WorkflowFeatureAvailability {
        let enabledBuiltInCapabilities = Set(
            WorkflowLibraryCatalog.builtIn
                .filter { $0.maturity != .core && enablementStore.isWorkflowEnabled($0) }
                .flatMap(\.capabilities)
        )
        let hasBuiltInWorkflowOperations = enabledBuiltInCapabilities.contains(.workflowOperations)
        let enabledUserWorkflowIDs = enablementStore.enabledUserWorkflowIDSnapshot
        let hasRunnableUserWorkflows = hasBuiltInWorkflowOperations || enabledUserWorkflowIDs.isEmpty
            ? false
            : packageStore.validatedPackages().contains { package in
                package.supportsWorkflowLibraryExecution && enabledUserWorkflowIDs.contains(package.manifest.id)
            }
        return WorkflowFeatureAvailability(
            hasWorkflowOperations: hasBuiltInWorkflowOperations
                || hasRunnableUserWorkflows,
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
    static let fullLengthONTMHCGenotypingID = "builtin.full-length-ont-mhc-genotyping"

    static let twelveSAmpliconMatchingItem = WorkflowLibraryItem(
        id: twelveSAmpliconMatchingID,
        title: "12S Amplicon Matching",
        subtitle: "Match merged 12S amplicon reads exactly to a deduplicated FASTA and review unresolved sequences.",
        categoryID: .genotyping,
        maturity: .specialized,
        requiredPluginPackIDs: ["lungfish-tools"],
        capabilities: [.workflowOperations]
    )

    static let fullLengthONTMHCGenotypingItem = WorkflowLibraryItem(
        id: fullLengthONTMHCGenotypingID,
        title: "Full-length ONT MHC genotyping",
        subtitle: "Cluster full-length ONT MHC amplicons with Savont and genotype cluster consensus sequences against an MHC allele library.",
        categoryID: .genotyping,
        maturity: .specialized,
        requiredPluginPackIDs: [
            "lungfish-tools",
            "read-mapping",
            "full-length-mhc-genotyping",
        ],
        capabilities: [.workflowOperations, .haplotypeDefinitions]
    )

    static let builtIn: [WorkflowLibraryItem] = FASTQOperationToolID.allCases.map { toolID in
        if toolID == .savont {
            return WorkflowLibraryItem(
                toolID: toolID,
                maturity: .core,
                requiredPluginPackIDs: ["full-length-mhc-genotyping"]
            )
        }
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
    } + [fullLengthONTMHCGenotypingItem, twelveSAmpliconMatchingItem]

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
        case .genotyping: return "Genotyping"
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
    case superseded
    case blocked(missingPackIDs: [String])
    case unsupportedRunner(kind: WorkflowPackageRunnerKind)
}

extension WorkflowPackageRunnerKind {
    var supportsWorkflowLibraryExecution: Bool {
        switch self {
        case .nextflow, .snakemake:
            return true
        case .command:
            return false
        }
    }

    var workflowLibraryUnsupportedReason: String? {
        switch self {
        case .nextflow, .snakemake:
            return nil
        case .command:
            return "Command-runner packages can be imported and reviewed, but beta builds do not execute them."
        }
    }
}

extension WorkflowPackageValidationResult {
    var supportsWorkflowLibraryExecution: Bool {
        workflowLibraryExecutionUnavailableReason == nil
    }

    var workflowLibraryExecutionUnavailableReason: String? {
        if let runnerReason = manifest.runner.kind.workflowLibraryUnsupportedReason {
            return runnerReason
        }
        let hasReferenceInput = manifest.inputs.contains {
            $0.required && $0.bundleTypes.contains(.lungfishref)
        }
        let hasFASTQInput = manifest.inputs.contains {
            $0.required && $0.bundleTypes.contains(.lungfishfastq)
        }
        guard hasReferenceInput, hasFASTQInput, !manifest.outputs.isEmpty else {
            return "Beta1 Workflow Operations require a required .lungfishref input, a required .lungfishfastq input, and at least one declared output."
        }
        return nil
    }
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
        guard !enabled || package.supportsWorkflowLibraryExecution else { return }
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
        using provider: any PluginPackStatusProviding,
        shouldCommit: () -> Bool = { true }
    ) async -> WorkflowLibraryEnablementResult {
        guard package.supportsWorkflowLibraryExecution else {
            return .unsupportedRunner(kind: package.manifest.runner.kind)
        }
        let missingPackIDs = await missingRequiredPluginPackIDs(for: package, using: provider)
        guard shouldCommit() else { return .superseded }
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

enum WorkflowRegistrationStatus: String, Codable, Sendable {
    case unchecked, available, missing, invalid
}

/// A linked package remains visible and removable even when its source disappears.
struct WorkflowPackageRegistration: Identifiable, Codable, Equatable, Sendable {
    let id: UUID
    var sourceURL: URL
    var lastKnownManifest: WorkflowPackageManifest?
    var status: WorkflowRegistrationStatus
    var diagnostic: String?

    var title: String { lastKnownManifest?.name ?? sourceURL.deletingPathExtension().lastPathComponent }
}

@MainActor
final class WorkflowLibraryImportedPackageStore {
    static let shared = WorkflowLibraryImportedPackageStore()
    private static let importedPackagePathsKey = "WorkflowLibrary.importedWorkflowPackagePaths"
    private static let registrationsKey = "WorkflowLibrary.packageRegistrations.v1"

    private struct PackageValidationFingerprint: Equatable, Sendable {
        let manifestSHA256: String?
    }
    private struct CachedPackageValidation: Sendable {
        let fingerprint: PackageValidationFingerprint
        let result: WorkflowPackageValidationResult
    }
    private struct ValidationOutcome: Sendable {
        var registration: WorkflowPackageRegistration
        let result: WorkflowPackageValidationResult?
        let fingerprint: PackageValidationFingerprint
    }

    private let userDefaults: UserDefaults
    private var validationCache: [URL: CachedPackageValidation] = [:]
    private var revision: UInt64 = 0
    private var registrations: [WorkflowPackageRegistration] {
        didSet {
            guard registrations != oldValue else { return }
            revision &+= 1
            // One encoded value replaces the registry; no intermediate duplicate identity.
            do { userDefaults.set(try JSONEncoder().encode(registrations), forKey: Self.registrationsKey) }
            catch { preconditionFailure("Unable to encode workflow registrations: \(error)") }
        }
    }

    init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
        if let data = userDefaults.data(forKey: Self.registrationsKey),
           let decoded = try? JSONDecoder().decode([WorkflowPackageRegistration].self, from: data) {
            self.registrations = decoded.map { value in
                var value = value
                if value.status == .available { value.status = .unchecked }
                return value
            }
        } else {
            var seen = Set<String>()
            self.registrations = (userDefaults.stringArray(forKey: Self.importedPackagePathsKey) ?? []).compactMap { path in
                let url = URL(fileURLWithPath: path).standardizedFileURL
                guard seen.insert(url.path).inserted else { return nil }
                return WorkflowPackageRegistration(id: UUID(), sourceURL: url, status: .unchecked)
            }
            // Persist IDs before validation so disconnected legacy paths also remain stable.
            if let encoded = try? JSONEncoder().encode(registrations) {
                userDefaults.set(encoded, forKey: Self.registrationsKey)
            }
        }
    }

    var registrationSnapshot: [WorkflowPackageRegistration] { registrations }
    var registrationRevision: UInt64 { revision }
    var packageURLSnapshot: [URL] { registrations.map(\.sourceURL) }

    func cachedValidatedPackages() -> [WorkflowPackageValidationResult] {
        registrations.compactMap { registration in
            guard registration.status == .available,
                  let cached = validationCache[registration.sourceURL],
                  cached.fingerprint == Self.packageFingerprint(for: registration.sourceURL),
                  cachedValidationStillHasRequiredFiles(cached.result) else { return nil }
            return cached.result
        }
    }

    func validatedPackages() -> [WorkflowPackageValidationResult] {
        applyValidation(registrations.map(Self.validate))
    }

    func validatedPackagesInBackground() async -> [WorkflowPackageValidationResult] {
        let snapshot = registrations
        let expectedRevision = revision
        let workerTask = Task.detached(priority: .userInitiated) {
            snapshot.map(Self.validate)
        }
        let outcomes = await withTaskCancellationHandler {
            await workerTask.value
        } onCancel: { workerTask.cancel() }
        guard !Task.isCancelled, expectedRevision == revision else { return cachedValidatedPackages() }
        return applyValidation(outcomes)
    }

    /// Registration means linking to this location, never copying the package.
    func addPackage(at packageURL: URL) {
        let url = packageURL.standardizedFileURL
        guard !registrations.contains(where: { $0.sourceURL == url }) else { return }
        registrations.append(WorkflowPackageRegistration(id: UUID(), sourceURL: url, status: .unchecked))
    }

    /// One active source/version per manifest ID; replacement preserves its local ID and enablement.
    func addValidatedPackage(_ result: WorkflowPackageValidationResult) {
        let url = result.packageURL.standardizedFileURL
        let existing = registrations.first { $0.lastKnownManifest?.id == result.manifest.id }
            ?? registrations.first { $0.sourceURL == url }
        var updated = registrations.filter { $0.lastKnownManifest?.id != result.manifest.id && $0.sourceURL != url }
        updated.append(WorkflowPackageRegistration(id: existing?.id ?? UUID(), sourceURL: url,
            lastKnownManifest: result.manifest, status: .available))
        registrations = updated
        cache(result)
    }

    func removeRegistration(id: UUID) {
        registrations.removeAll { $0.id == id }
    }

    func removePackage(withManifestID manifestID: String) {
        registrations.removeAll { $0.lastKnownManifest?.id == manifestID }
    }

    func relocateRegistration(id: UUID, to result: WorkflowPackageValidationResult) throws {
        guard let index = registrations.firstIndex(where: { $0.id == id }) else { return }
        if let expected = registrations[index].lastKnownManifest?.id, expected != result.manifest.id {
            throw NSError(domain: "WorkflowLibrary", code: 1, userInfo: [NSLocalizedDescriptionKey:
                "This package has identity \(result.manifest.id), but the selected registration expects \(expected). Add it separately instead."])
        }
        guard !registrations.contains(where: { $0.id != id && $0.lastKnownManifest?.id == result.manifest.id }) else {
            throw NSError(domain: "WorkflowLibrary", code: 2, userInfo: [NSLocalizedDescriptionKey:
                "This workflow identity is already registered. Remove its other registration first."])
        }
        registrations[index] = WorkflowPackageRegistration(id: id, sourceURL: result.packageURL.standardizedFileURL,
            lastKnownManifest: result.manifest, status: .available)
        cache(result)
    }

    private nonisolated static func validate(_ source: WorkflowPackageRegistration) -> ValidationOutcome {
        var registration = source
        let fingerprint = packageFingerprint(for: source.sourceURL)
        do {
            try Task.checkCancellation()
            let result = try WorkflowPackageValidator.validatePackage(at: source.sourceURL)
            if let expected = source.lastKnownManifest?.id, expected != result.manifest.id {
                throw NSError(domain: "WorkflowLibrary", code: 3, userInfo: [NSLocalizedDescriptionKey:
                    "Package identity changed from \(expected) to \(result.manifest.id). Remove and add the new package explicitly."])
            }
            registration.lastKnownManifest = result.manifest
            registration.status = .available
            registration.diagnostic = nil
            return ValidationOutcome(registration: registration, result: result, fingerprint: fingerprint)
        } catch {
            registration.status = FileManager.default.fileExists(atPath: source.sourceURL.path) ? .invalid : .missing
            registration.diagnostic = error.localizedDescription
            return ValidationOutcome(registration: registration, result: nil, fingerprint: fingerprint)
        }
    }

    private func applyValidation(_ outcomes: [ValidationOutcome]) -> [WorkflowPackageValidationResult] {
        // Legacy path lists may contain the same identity more than once. Latest link wins,
        // matching Add's replacement rule; invalid/missing registrations remain diagnosable.
        var seen = Set<String>()
        let retained = outcomes.reversed().filter { outcome in
            guard let id = outcome.registration.lastKnownManifest?.id else { return true }
            return seen.insert(id).inserted
        }.reversed()
        registrations = retained.map(\.registration)
        validationCache.removeAll()
        for outcome in retained {
            if let result = outcome.result { cache(result, fingerprint: outcome.fingerprint) }
        }
        return retained.compactMap(\.result)
    }

    private func cache(_ result: WorkflowPackageValidationResult, fingerprint: PackageValidationFingerprint? = nil) {
        validationCache[result.packageURL.standardizedFileURL] = CachedPackageValidation(
            fingerprint: fingerprint ?? Self.packageFingerprint(for: result.packageURL), result: result)
    }

    private nonisolated static func packageFingerprint(for packageURL: URL) -> PackageValidationFingerprint {
        let manifestURL = packageURL
            .standardizedFileURL
            .appendingPathComponent(WorkflowPackageValidator.manifestFilename)
        let data = try? Data(contentsOf: manifestURL)
        return PackageValidationFingerprint(
            manifestSHA256: data.map {
                SHA256.hash(data: $0).map { String(format: "%02x", $0) }.joined()
            }
        )
    }

    private func cachedValidationStillHasRequiredFiles(_ result: WorkflowPackageValidationResult) -> Bool {
        let packageURL = result.packageURL.standardizedFileURL
        guard FileManager.default.fileExists(atPath: result.manifestURL.path),
              FileManager.default.fileExists(
                atPath: packageURL.appendingPathComponent(result.manifest.runner.entrypoint).path
              ) else {
            return false
        }
        if result.manifest.runtime.kind == .conda,
           let environmentFile = result.manifest.runtime.environmentFile {
            return FileManager.default.fileExists(atPath: packageURL.appendingPathComponent(environmentFile).path)
        }
        return true
    }
}
