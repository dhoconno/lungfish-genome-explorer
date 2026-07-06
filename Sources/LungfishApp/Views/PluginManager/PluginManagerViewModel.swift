// PluginManagerViewModel.swift - View model for the Plugin Manager
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import AppKit
import LungfishWorkflow
import os.log
import LungfishCore
import LungfishKit

/// Logger for the Plugin Manager view model.
private let logger = Logger(subsystem: LogSubsystem.app, category: "PluginManagerVM")

private final class StorageLocationChangeObserver {
    private let notificationCenter: NotificationCenter
    private var token: NSObjectProtocol?

    init(
        notificationCenter: NotificationCenter = .default,
        onChange: @escaping @MainActor () -> Void
    ) {
        self.notificationCenter = notificationCenter
        self.token = notificationCenter.addObserver(
            forName: .databaseStorageLocationChanged,
            object: nil,
            queue: nil
        ) { _ in
            if Thread.isMainThread {
                MainActor.assumeIsolated {
                    onChange()
                }
            } else {
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        onChange()
                    }
                }
            }
        }
    }

    deinit {
        if let token {
            notificationCenter.removeObserver(token)
        }
    }
}

private struct RecommendedDatabaseSelection: Equatable {
    let name: String
    let tool: String
    let collection: DatabaseCollection?
    let recommendedRAM: Int64

    init(_ database: MetagenomicsDatabaseInfo) {
        self.name = database.name
        self.tool = database.tool
        self.collection = database.collection
        self.recommendedRAM = database.recommendedRAM
    }

    func matches(_ database: MetagenomicsDatabaseInfo) -> Bool {
        hasSameCatalogIdentity(as: database)
            && database.recommendedRAM == recommendedRAM
    }

    func hasSameCatalogIdentity(as database: MetagenomicsDatabaseInfo) -> Bool {
        database.name == name
            && database.tool == tool
            && database.collection == collection
    }
}

struct OfflinePackCommandGuidance: Equatable {
    let exportCommand: String
    let installCommand: String
    let copyText: String
}

private final class PluginPackInstallProgressLog: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [PluginPackInstallProgress] = []

    func append(_ event: PluginPackInstallProgress) {
        lock.lock()
        events.append(event)
        lock.unlock()
    }

    func snapshot() -> [PluginPackInstallProgress] {
        lock.lock()
        let copy = events
        lock.unlock()
        return copy
    }
}

/// View model for the Plugin Manager window.
///
/// Bridges between the ``CondaManager`` actor and the SwiftUI view layer.
/// All state is ``@MainActor``-isolated and uses ``@Observable`` for
/// automatic SwiftUI invalidation.
///
/// ## Tabs
///
/// - **Installed**: Lists conda environments and their packages.
/// - **Packs**: Shows curated ``PluginPack`` bundles.
/// - **Databases**: Kraken2 database download and management.
@MainActor
@Observable
final class PluginManagerViewModel {

    // MARK: - Tab

    /// The sections of the Plugin Manager.
    enum Tab: Hashable, Sendable {
        case installed
        case packs
        case databases

        /// Maps to the segmented control index.
        var segmentIndex: Int {
            switch self {
            case .installed:  return 0
            case .packs:      return 1
            case .databases:  return 2
            }
        }

        /// Creates a tab from a segmented control index.
        static func from(segmentIndex: Int) -> Tab {
            switch segmentIndex {
            case 0: return .installed
            case 1: return .packs
            case 2: return .databases
            default: return .installed
            }
        }
    }

    // MARK: - State

    /// Currently selected tab.
    var selectedTab: Tab = .packs {
        didSet {
            if selectedTab == .installed {
                refreshInstalled()
            } else if selectedTab == .packs {
                refreshPackStatuses()
            } else if selectedTab == .databases {
                refreshDatabases()
            }
        }
    }

    /// Whether a loading operation is in progress.
    var isLoading: Bool = false

    /// Whether pack status checks are running.
    var isLoadingPackStatuses: Bool = false

    /// Current error message to display, if any.
    var errorMessage: String?

    /// Whether the error alert is showing.
    var showingError: Bool = false

    // MARK: - Installed Tab State

    /// Installed conda environments.
    var environments: [CondaEnvironment] = []

    /// Hash-named conda environments that do not map to curated Lungfish packs.
    var orphanedEnvironments: [CondaEnvironment] = []

    /// Map of environment name to its installed packages.
    var installedPackages: [String: [CondaPackageInfo]] = [:]

    /// Set of environment names currently being removed.
    var removingEnvironments: Set<String> = []

    var orphanedEnvironmentDiagnosticText: String {
        guard !orphanedEnvironments.isEmpty else { return "" }
        let count = orphanedEnvironments.count
        let noun = count == 1 ? "orphaned hash-named conda environment" : "orphaned hash-named conda environments"
        let examples = orphanedEnvironments.prefix(2).map(\.name).joined(separator: ", ")
        return "\(count) \(noun) hidden from installed tools: \(examples). Remove them if they are leftover runtime/plugin installs."
    }

    // MARK: - Packs Tab State

    private let packStatusProvider: any PluginPackStatusProviding
    private let notificationCenter: NotificationCenter
    private let operationCenter: OperationCenter

    /// Current status for the required setup pack.
    var requiredSetupPack: PluginPackStatus?

    /// Current statuses for active optional packs.
    var optionalPackStatuses: [PluginPackStatus] = []

    /// Pack identifier to focus in the Packs tab.
    var focusedPackID: String?

    /// Set of pack IDs currently being installed.
    var installingPacks: Set<String> = []

    /// Map of pack ID to installation progress message.
    var packProgressMessage: [String: String] = [:]

    /// Set of installed environment names, for status indicators.
    var installedEnvironmentNames: Set<String> {
        Set(environments.map(\.name))
    }

    // MARK: - Databases Tab State

    /// Available Kraken2 databases from the registry catalog.
    var databases: [MetagenomicsDatabaseInfo] = []

    /// Set of database names currently being downloaded.
    var downloadingDatabases: Set<String> = []

    /// Map of database name to download progress (0.0 to 1.0).
    var downloadProgress: [String: Double] = [:]

    /// Map of database name to progress status message.
    var downloadMessage: [String: String] = [:]

    /// Map of database name to error message from a failed download.
    var downloadError: [String: String] = [:]

    /// Map of database name to the Task handle for cancellation.
    private var downloadTasks: [String: Task<Void, Never>] = [:]

    /// Set of database names currently being removed.
    var removingDatabases: Set<String> = []

    /// Database name pending removal confirmation, drives the confirmation alert.
    var databasePendingRemoval: String?

    /// Name of the recommended database based on system RAM.
    var recommendedDatabaseName: String = ""

    /// Registry-selected recommendation source used by the header and row badge.
    private var recommendedDatabaseSelection: RecommendedDatabaseSelection?

    /// System RAM in bytes, for display and recommendation logic.
    let systemRAMBytes: UInt64 = ProcessInfo.processInfo.physicalMemory

    /// Total storage used by all installed databases, in bytes.
    var totalDatabaseStorageBytes: Int64 {
        databases
            .filter { $0.status == .ready }
            .compactMap(\.sizeOnDisk)
            .reduce(0, +)
    }

    /// Returns whether a database should carry the same recommendation badge
    /// named in the Databases tab header.
    func isRecommendedDatabase(_ database: MetagenomicsDatabaseInfo) -> Bool {
        recommendedDatabaseSelection?.matches(database) ?? false
    }

    /// The shared managed storage root shown in the Databases footer.
    var storageLocationPath: String = ""

    /// Current shared storage display state surfaced to the footer.
    var storageLocationDisplayState: ManagedStorageDisplayState = .defaultRoot

    /// Describes the current shared storage state for footer copy.
    var storageLocationStatusText: String = ""

    @ObservationIgnored private var storageLocationChangeObserver: StorageLocationChangeObserver?

    /// Opens the Storage tab in Settings.
    func openStorageSettings() {
        SettingsNavigationState.shared.open(.storage)
        if selectedTab == .databases {
            refreshDatabases()
        }
    }

    // MARK: - Lifecycle

    init(
        packStatusProvider: any PluginPackStatusProviding = PluginPackStatusService.shared,
        notificationCenter: NotificationCenter = .default,
        automaticallyRefresh: Bool = true,
        operationCenter: OperationCenter = .shared
    ) {
        self.packStatusProvider = packStatusProvider
        self.notificationCenter = notificationCenter
        self.operationCenter = operationCenter
        refreshStorageLocationState()
        self.storageLocationChangeObserver = StorageLocationChangeObserver(
            notificationCenter: notificationCenter
        ) { [weak self] in
            self?.refreshStorageLocationState()
        }

        if automaticallyRefresh {
            refreshInstalled()
            refreshPackStatuses()
        }
    }

    // MARK: - Installed Tab Actions

    /// Refreshes the list of installed environments.
    func refreshInstalled() {
        Task {
            isLoading = true
            defer { isLoading = false }

            do {
                let envs = try await CondaManager.shared.listEnvironments()
                applyInstalledEnvironments(envs)
                logger.info("Found \(envs.count, privacy: .public) conda environments")
            } catch {
                handleError(error, context: "listing environments")
            }
        }
    }

    func applyInstalledEnvironments(_ envs: [CondaEnvironment]) {
        let sorted = envs.sorted { $0.name < $1.name }
        orphanedEnvironments = sorted.filter { Self.isHashNamedOrphanEnvironmentName($0.name) }
        environments = sorted.filter { !Self.isHashNamedOrphanEnvironmentName($0.name) }
    }

    /// Loads the package list for a specific environment.
    func loadPackages(for environment: String) {
        Task {
            do {
                let packages = try await CondaManager.shared.listInstalled(in: environment)
                installedPackages[environment] = packages.sorted { $0.name < $1.name }
            } catch {
                handleError(error, context: "listing packages in '\(environment)'")
            }
        }
    }

    /// Removes a conda environment.
    func removeEnvironment(name: String) {
        removingEnvironments.insert(name)
        Task {
            defer { removingEnvironments.remove(name) }

            do {
                try await CondaManager.shared.removeEnvironment(name: name)
                logger.info("Removed environment '\(name, privacy: .public)'")
                refreshInstalled()
            } catch {
                handleError(error, context: "removing '\(name)'")
            }
        }
    }

    func removeOrphanedEnvironments() {
        let names = orphanedEnvironments.map(\.name)
        guard !names.isEmpty else { return }

        removingEnvironments.formUnion(names)
        Task {
            defer { removingEnvironments.subtract(names) }

            var failedNames: [String] = []
            for name in names {
                do {
                    try await CondaManager.shared.removeEnvironment(name: name)
                    logger.info("Removed orphaned environment '\(name, privacy: .public)'")
                } catch {
                    failedNames.append(name)
                    logger.error("Failed to remove orphaned environment '\(name, privacy: .public)': \(error.localizedDescription, privacy: .public)")
                }
            }

            refreshInstalled()
            if failedNames.isEmpty {
                postManagedResourcesDidChange()
            } else {
                handleError(
                    PluginManagerOrphanCleanupError(environmentNames: failedNames),
                    context: "removing orphaned environments"
                )
            }
        }
    }

    // MARK: - Packs Tab Actions

    func loadPackStatuses() async {
        isLoadingPackStatuses = true
        defer { isLoadingPackStatuses = false }
        let statuses = await packStatusProvider.visibleStatuses(
            includeExperimental: AppSettings.shared.experimentalFeaturesEnabled
        )
        requiredSetupPack = statuses.first(where: { $0.pack.isRequiredBeforeLaunch })
        optionalPackStatuses = statuses.filter { !$0.pack.isRequiredBeforeLaunch }
    }

    func refreshPackStatuses() {
        Task {
            await loadPackStatuses()
        }
    }

    func focusPack(_ packID: String) {
        selectedTab = .packs
        focusedPackID = packID
    }

    func offlinePackCommandGuidance(for pack: PluginPack) -> OfflinePackCommandGuidance {
        let archivePath = "./\(pack.id)-conda-offline-pack.tgz"
        let exportCommand = shellCommand([
            CLICommandIdentity.executableName,
            "conda",
            "export-pack",
            "--pack",
            pack.id,
            "--output",
            archivePath,
        ])
        let installCommand = shellCommand([
            CLICommandIdentity.executableName,
            "conda",
            "install",
            "--offline",
            "--from-bundle",
            archivePath,
        ])
        return OfflinePackCommandGuidance(
            exportCommand: exportCommand,
            installCommand: installCommand,
            copyText: [exportCommand, installCommand].joined(separator: "\n")
        )
    }

    func copyOfflinePackCommandGuidance(for pack: PluginPack) {
        let guidance = offlinePackCommandGuidance(for: pack)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(guidance.copyText, forType: .string)
    }

    /// Installs or reinstalls a plugin pack through the shared status service.
    func installPack(_ pack: PluginPack, reinstall: Bool = false) {
        installingPacks.insert(pack.id)
        packProgressMessage[pack.id] = reinstall ? "Reinstalling..." : "Installing..."
        let operationID = startPluginPackOperation(pack: pack, reinstall: reinstall)
        let progressLog = PluginPackInstallProgressLog()
        let packID = pack.id

        Task {
            var didSucceed = false
            defer {
                installingPacks.remove(pack.id)
                packProgressMessage.removeValue(forKey: pack.id)
            }

            do {
                try await packStatusProvider.install(pack: pack, reinstall: reinstall) { [weak self, progressLog] event in
                    progressLog.append(event)
                    DispatchQueue.main.async { [weak self] in
                        MainActor.assumeIsolated {
                            guard let self else { return }
                            self.packProgressMessage[packID] = event.message
                            self.updatePluginPackOperationProgress(operationID: operationID, event: event)
                        }
                    }
                }
                recordPluginPackProgressEvents(progressLog.snapshot(), operationID: operationID)
                let finalStatus = await packStatusProvider.status(for: pack)
                recordPluginPackStatus(finalStatus, operationID: operationID)
                completePluginPackOperation(pack: pack, status: finalStatus, operationID: operationID)
                didSucceed = true
            } catch {
                recordPluginPackProgressEvents(progressLog.snapshot(), operationID: operationID)
                operationCenter.log(
                    id: operationID,
                    level: .error,
                    message: "Install failed: \(error.localizedDescription)"
                )
                operationCenter.fail(
                    id: operationID,
                    detail: "Failed to \(reinstall ? "reinstall" : "install") \(pack.name)",
                    errorMessage: error.localizedDescription,
                    errorDetail: pluginPackDiagnosticText(pack: pack)
                )
                handleError(error, context: "\(reinstall ? "reinstalling" : "installing") '\(pack.name)'")
            }
            refreshInstalled()
            await loadPackStatuses()
            if didSucceed {
                postManagedResourcesDidChange()
            }
        }
    }

    private func startPluginPackOperation(pack: PluginPack, reinstall: Bool) -> UUID {
        let operationID = operationCenter.start(
            title: "Plugin Pack: \(pack.name)",
            detail: "\(reinstall ? "Preparing to reinstall" : "Preparing to install") \(pack.name)",
            operationType: .condaPluginPack,
            cliCommand: OperationCenter.buildCLICommand(
                subcommand: "conda install",
                args: ["--pack", pack.id]
            )
        )
        operationCenter.log(
            id: operationID,
            level: .info,
            message: "Action: \(reinstall ? "Reinstall" : "Install") requested from Plugin Manager"
        )
        for line in pluginPackDiagnosticLines(pack: pack) {
            operationCenter.log(id: operationID, level: .info, message: line)
        }
        return operationID
    }

    private func updatePluginPackOperationProgress(
        operationID: UUID,
        event: PluginPackInstallProgress
    ) {
        guard operationCenter.items.first(where: { $0.id == operationID })?.state == .running else {
            return
        }
        operationCenter.update(
            id: operationID,
            progress: event.overallFraction,
            detail: event.message
        )
    }

    private func recordPluginPackProgressEvents(
        _ events: [PluginPackInstallProgress],
        operationID: UUID
    ) {
        for event in events {
            operationCenter.updateWithLog(
                id: operationID,
                progress: event.overallFraction,
                detail: event.message
            )
        }
    }

    private func recordPluginPackStatus(
        _ status: PluginPackStatus,
        operationID: UUID
    ) {
        for line in pluginPackStatusDiagnosticLines(status) {
            let level: OperationLogLevel = status.state == .ready || line.contains(" - Ready") ? .info : .warning
            operationCenter.log(id: operationID, level: level, message: line)
        }
    }

    private func completePluginPackOperation(
        pack: PluginPack,
        status: PluginPackStatus,
        operationID: UUID
    ) {
        if let warningDetail = pluginPackWarningDetail(pack: pack, status: status) {
            operationCenter.completeWithWarning(id: operationID, detail: warningDetail)
        } else {
            operationCenter.complete(id: operationID, detail: "\(pack.name) ready")
        }
    }

    /// Removes all environments for packages in a plugin pack.
    func removePack(_ pack: PluginPack) {
        installingPacks.insert(pack.id)
        packProgressMessage[pack.id] = "Removing..."

        Task {
            defer {
                installingPacks.remove(pack.id)
                packProgressMessage.removeValue(forKey: pack.id)
            }

            for packageName in pack.packages {
                guard installedEnvironmentNames.contains(packageName) else { continue }

                do {
                    try await CondaManager.shared.removeEnvironment(name: packageName)
                    logger.info("Pack '\(pack.id, privacy: .public)': removed \(packageName, privacy: .public)")
                } catch {
                    logger.error("Pack '\(pack.id, privacy: .public)': failed to remove \(packageName, privacy: .public): \(error.localizedDescription, privacy: .public)")
                }
            }

            await packStatusProvider.invalidateVisibleStatusesCache()
            refreshInstalled()
            refreshPackStatuses()
            postManagedResourcesDidChange()
        }
    }

    // MARK: - Databases Tab Actions

    /// Applies the registry-selected recommendation source to the displayed
    /// database list so the header and row badge compare against the same policy.
    func applyDatabaseRecommendation(
        databases allDatabases: [MetagenomicsDatabaseInfo],
        recommended: MetagenomicsDatabaseInfo?
    ) {
        guard let recommended else {
            databases = allDatabases
            recommendedDatabaseName = ""
            recommendedDatabaseSelection = nil
            return
        }

        let recommendation = RecommendedDatabaseSelection(recommended)
        recommendedDatabaseName = recommended.name
        recommendedDatabaseSelection = recommendation
        databases = allDatabases.map { database in
            guard recommendation.hasSameCatalogIdentity(as: database) else {
                return database
            }
            var normalized = database
            normalized.recommendedRAM = recommended.recommendedRAM
            return normalized
        }
    }

    /// Refreshes the database catalog from the registry.
    func refreshDatabases() {
        Task {
            do {
                let registry = MetagenomicsDatabaseRegistry.shared
                let allDBs = try await registry.availableDatabases()

                let recommended = try await registry.recommendedDatabase(ramBytes: systemRAMBytes)
                applyDatabaseRecommendation(databases: allDBs, recommended: recommended)

                logger.info(
                    "Loaded \(allDBs.count, privacy: .public) databases, recommended: \(self.recommendedDatabaseName, privacy: .public)"
                )
            } catch {
                handleError(error, context: "loading database catalog")
            }
        }
    }

    /// Downloads a Kraken2 database by name.
    ///
    /// Updates ``downloadingDatabases``, ``downloadProgress``, and
    /// ``downloadMessage`` as the download progresses. On completion, refreshes
    /// the database list. On error, stores the error message in ``downloadError``.
    ///
    /// - Parameter name: Name of the database to download (e.g., "Viral").
    func downloadDatabase(name: String) {
        guard !downloadingDatabases.contains(name) else { return }

        downloadingDatabases.insert(name)
        downloadProgress[name] = 0.0
        downloadMessage[name] = "Starting download\u{2026}"
        downloadError.removeValue(forKey: name)

        let task = Task {
            defer {
                downloadingDatabases.remove(name)
                downloadTasks.removeValue(forKey: name)
            }

            do {
                try Task.checkCancellation()
                _ = try await MetagenomicsDatabaseRegistry.shared.downloadDatabase(
                    name: name,
                    progress: { [weak self] fraction, message in
                        DispatchQueue.main.async {
                            MainActor.assumeIsolated {
                                self?.downloadProgress[name] = fraction
                                self?.downloadMessage[name] = message
                            }
                        }
                    }
                )
                downloadProgress.removeValue(forKey: name)
                downloadMessage.removeValue(forKey: name)
                logger.info("Database '\(name, privacy: .public)' downloaded successfully")
                refreshDatabases()
                postManagedResourcesDidChange()
            } catch is CancellationError {
                downloadProgress.removeValue(forKey: name)
                downloadMessage.removeValue(forKey: name)
                logger.info("Database '\(name, privacy: .public)' download cancelled by user")
                refreshDatabases()
            } catch {
                downloadProgress.removeValue(forKey: name)
                downloadMessage.removeValue(forKey: name)
                if !Task.isCancelled {
                    downloadError[name] = error.localizedDescription
                    logger.error("Database '\(name, privacy: .public)' download failed: \(error.localizedDescription, privacy: .public)")
                }
                refreshDatabases()
            }
        }
        downloadTasks[name] = task
    }

    /// Cancels an in-progress database download.
    ///
    /// - Parameter name: Name of the database whose download to cancel.
    func cancelDownload(name: String) {
        guard let task = downloadTasks[name] else { return }
        task.cancel()
        logger.info("Cancelling download of database '\(name, privacy: .public)'")
    }

    /// Requests removal of a database, showing a confirmation alert first.
    ///
    /// Sets ``databasePendingRemoval`` which drives the confirmation alert
    /// in the view. Call ``confirmRemoveDatabase()`` to proceed.
    ///
    /// - Parameter name: Name of the database to remove.
    func requestRemoveDatabase(name: String) {
        databasePendingRemoval = name
    }

    /// Confirms and executes the pending database removal.
    func confirmRemoveDatabase() {
        guard let name = databasePendingRemoval else { return }
        databasePendingRemoval = nil
        removeDatabase(name: name)
    }

    /// Removes a downloaded database, deleting its files from disk.
    ///
    /// Resets the registry entry to undownloaded state (for catalog entries)
    /// or removes it entirely (for user-imported databases).
    ///
    /// - Parameter name: Name of the database to remove.
    func removeDatabase(name: String) {
        guard !removingDatabases.contains(name) else { return }

        removingDatabases.insert(name)

        Task {
            defer { removingDatabases.remove(name) }

            do {
                let registry = MetagenomicsDatabaseRegistry.shared

                // Get the database path before removing the registry entry.
                if let db = try await registry.database(named: name), let path = db.path {
                    // Delete files from disk.
                    try? FileManager.default.removeItem(at: path)
                    logger.info("Deleted database files at \(path.path, privacy: .public)")
                }

                // Remove or reset the registry entry.
                try await registry.removeDatabase(name: name)
                logger.info("Removed database '\(name, privacy: .public)' from registry")

                refreshDatabases()
                postManagedResourcesDidChange()
            } catch {
                handleError(error, context: "removing database '\(name)'")
                refreshDatabases()
            }
        }
    }

    // MARK: - Helpers

    static func databaseTrackingSummary(for database: MetagenomicsDatabaseInfo) -> String {
        var parts: [String] = []
        if let installedAt = database.installedAt ?? database.lastUpdated {
            parts.append("Installed \(databaseTrackingDateFormatter.string(from: installedAt))")
        } else {
            parts.append("Not installed")
        }

        parts.append("Version \(database.version ?? "unknown")")

        if let availableUpdate = database.availableUpdateVersion {
            parts.append("Update available: \(availableUpdate)")
        } else if database.status == .ready {
            parts.append("Up to date")
        }

        return parts.joined(separator: " · ")
    }

    static func isHashNamedOrphanEnvironmentName(_ name: String) -> Bool {
        let candidate = name.hasPrefix("env-") ? String(name.dropFirst(4)) : name
        guard (32...64).contains(candidate.count) else { return false }
        return candidate.unicodeScalars.allSatisfy { scalar in
            CharacterSet(charactersIn: "0123456789abcdefABCDEF").contains(scalar)
        }
    }

    private static let databaseTrackingDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter
    }()

    private func refreshStorageLocationState() {
        storageLocationPath = AppSettings.shared.managedStorageRootURL.path
        storageLocationDisplayState = AppSettings.shared.managedStorageDisplayState
        storageLocationStatusText = switch storageLocationDisplayState {
        case .defaultRoot:
            "Default shared storage"
        case .customRoot:
            "Custom shared storage"
        case .malformedBootstrap:
            "Using default shared storage (config needs attention)"
        }
    }

    private func postManagedResourcesDidChange() {
        notificationCenter.post(name: .managedResourcesDidChange, object: nil)
    }

    private func handleError(_ error: Error, context: String) {
        let message = "Error \(context): \(error.localizedDescription)"
        logger.error("\(message, privacy: .public)")
        errorMessage = message
        showingError = true
    }
}

private func shellCommand(_ argv: [String]) -> String {
    argv.map(shellEscape).joined(separator: " ")
}

private func pluginPackDiagnosticText(pack: PluginPack, status: PluginPackStatus? = nil) -> String {
    var lines = pluginPackDiagnosticLines(pack: pack)
    if let status {
        lines.append(contentsOf: pluginPackStatusDiagnosticLines(status))
    }
    return lines.joined(separator: "\n")
}

private func pluginPackDiagnosticLines(pack: PluginPack) -> [String] {
    var lines: [String] = [
        "Pack ID: \(pack.id)",
        "Pack name: \(pack.name)",
        "Category: \(pack.category)",
        "Estimated size: \(pack.estimatedSizeMB) MB",
    ]

    for requirement in pack.toolRequirements {
        lines.append("Requirement: \(requirement.displayName) (\(requirement.id))")
        lines.append("Environment: \(requirement.environment)")
        lines.append("Package specs: \(requirement.installPackages.isEmpty ? "none" : requirement.installPackages.joined(separator: ", "))")
        if !requirement.executables.isEmpty {
            lines.append("Executables: \(requirement.executables.joined(separator: ", "))")
        }
        if let version = requirement.version {
            lines.append("Version: \(version)")
        }
        if let license = requirement.license {
            lines.append("License: \(license)")
        }
        if let sourceURL = requirement.sourceURL {
            lines.append("Source: \(sourceURL)")
        }
        if let smokeTest = requirement.smokeTest {
            lines.append(smokeTestDiagnosticLine(smokeTest, requirement: requirement))
        }
    }

    for hook in pack.postInstallHooks {
        lines.append("Post-install hook: \(hook.description)")
        lines.append("Hook environment: \(hook.environment)")
        lines.append("Hook command: \(shellCommand(hook.command))")
    }

    return lines
}

private func pluginPackStatusDiagnosticLines(_ status: PluginPackStatus) -> [String] {
    var lines: [String] = []

    if status.toolStatuses.isEmpty {
        lines.append("Verification: \(status.pack.name) - \(status.state.rawValue)")
    }

    for toolStatus in status.toolStatuses {
        lines.append("Verification: \(toolStatus.requirement.displayName) - \(toolStatus.statusText)")
        lines.append("Environment exists: \(toolStatus.environmentExists ? "yes" : "no")")
        if !toolStatus.missingExecutables.isEmpty {
            lines.append("Missing executables: \(toolStatus.missingExecutables.joined(separator: ", "))")
        }
        if let smokeTestFailure = toolStatus.smokeTestFailure, !smokeTestFailure.isEmpty {
            lines.append("Smoke test failure: \(smokeTestFailure)")
        }
        if let storageUnavailablePath = toolStatus.storageUnavailablePath {
            lines.append("Storage unavailable: \(storageUnavailablePath)")
        }
    }

    if let failureMessage = status.failureMessage, !failureMessage.isEmpty {
        lines.append("Verification failure: \(failureMessage)")
    }

    return lines
}

private func pluginPackWarningDetail(pack: PluginPack, status: PluginPackStatus) -> String? {
    guard status.state != .ready else { return nil }

    if let needsReinstall = status.toolStatuses.first(where: \.needsReinstall) {
        return "\(pack.name) installed but \(needsReinstall.requirement.displayName) reports \(needsReinstall.statusText)"
    }

    if let firstProblem = status.toolStatuses.first(where: { !$0.isReady }) {
        return "\(pack.name) installed but \(firstProblem.requirement.displayName) reports \(firstProblem.statusText)"
    }

    if let failureMessage = status.failureMessage, !failureMessage.isEmpty {
        return "\(pack.name) verification needs attention: \(failureMessage)"
    }

    return "\(pack.name) verification needs attention"
}

private func smokeTestDiagnosticLine(
    _ smokeTest: PackToolSmokeTest,
    requirement: PackToolRequirement
) -> String {
    let command: String
    switch smokeTest.kind {
    case .command:
        let executable = smokeTest.executable ?? requirement.executables.first ?? requirement.id
        command = shellCommand([executable] + smokeTest.arguments)
    case .bbtoolsReformat:
        command = shellCommand([smokeTest.executable ?? "reformat.sh"])
    }

    var parts = [
        "Smoke test: \(command)",
        "timeout \(formatSeconds(smokeTest.timeoutSeconds))s",
        "accepted exit codes \(smokeTest.acceptedExitCodes.map { String($0) }.joined(separator: ", "))",
    ]
    if let requiredOutputSubstring = smokeTest.requiredOutputSubstring {
        parts.append("requires output containing \(requiredOutputSubstring)")
    }
    return parts.joined(separator: "; ")
}

private func formatSeconds(_ seconds: Double) -> String {
    let rounded = seconds.rounded()
    if abs(seconds - rounded) < 0.001 {
        return String(Int(rounded))
    }
    return String(format: "%.1f", seconds)
}

private struct PluginManagerOrphanCleanupError: LocalizedError {
    let environmentNames: [String]

    var errorDescription: String? {
        "Could not remove \(environmentNames.joined(separator: ", "))"
    }
}
