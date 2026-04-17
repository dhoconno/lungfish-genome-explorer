// PluginManagerViewModel.swift - View model for the Plugin Manager
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import AppKit
import LungfishWorkflow
import os.log
import LungfishCore

/// Logger for the Plugin Manager view model.
private let logger = Logger(subsystem: LogSubsystem.app, category: "PluginManagerVM")

/// View model for the Plugin Manager window.
///
/// Bridges between the ``CondaManager`` actor and the SwiftUI view layer.
/// All state is ``@MainActor``-isolated and uses ``@Observable`` for
/// automatic SwiftUI invalidation.
///
/// ## Tabs
///
/// - **Installed**: Lists conda environments and their packages.
/// - **Available**: Searches bioconda for packages to install.
/// - **Packs**: Shows curated ``PluginPack`` bundles.
/// - **Databases**: Kraken2 database download and management.
@MainActor
@Observable
final class PluginManagerViewModel {

    // MARK: - Tab

    /// The four sections of the Plugin Manager.
    enum Tab: Hashable, Sendable {
        case installed
        case available
        case packs
        case databases

        /// Maps to the segmented control index.
        var segmentIndex: Int {
            switch self {
            case .installed:  return 0
            case .available:  return 1
            case .packs:      return 2
            case .databases:  return 3
            }
        }

        /// Creates a tab from a segmented control index.
        static func from(segmentIndex: Int) -> Tab {
            switch segmentIndex {
            case 0: return .installed
            case 1: return .available
            case 2: return .packs
            case 3: return .databases
            default: return .installed
            }
        }
    }

    // MARK: - State

    /// Currently selected tab.
    var selectedTab: Tab = .installed {
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

    /// Search text from the toolbar search field.
    var searchText: String = ""

    /// Whether a loading operation is in progress.
    var isLoading: Bool = false

    /// Current error message to display, if any.
    var errorMessage: String?

    /// Whether the error alert is showing.
    var showingError: Bool = false

    // MARK: - Installed Tab State

    /// Installed conda environments.
    var environments: [CondaEnvironment] = []

    /// Map of environment name to its installed packages.
    var installedPackages: [String: [CondaPackageInfo]] = [:]

    /// Set of environment names currently being removed.
    var removingEnvironments: Set<String> = []

    // MARK: - Available Tab State

    /// Search results from bioconda.
    var searchResults: [CondaPackageInfo] = []

    /// Deduplicated search results (latest version per package name).
    var deduplicatedResults: [CondaPackageInfo] {
        // Group by package name, keep only the latest version
        var seen: [String: CondaPackageInfo] = [:]
        for pkg in searchResults {
            if let existing = seen[pkg.name] {
                // Simple version comparison: prefer the one that sorts later
                if pkg.version.compare(existing.version, options: .numeric) == .orderedDescending {
                    seen[pkg.name] = pkg
                }
            } else {
                seen[pkg.name] = pkg
            }
        }
        return seen.values.sorted { $0.name < $1.name }
    }

    /// Whether a search has been performed.
    var hasSearched: Bool = false

    /// Set of package names currently being installed.
    var installingPackages: Set<String> = []

    /// Map of package name to installation progress (0.0 to 1.0).
    var installProgress: [String: Double] = [:]

    // MARK: - Packs Tab State

    private let packStatusProvider: any PluginPackStatusProviding

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

    /// System RAM in bytes, for display and recommendation logic.
    let systemRAMBytes: UInt64 = ProcessInfo.processInfo.physicalMemory

    /// Total storage used by all installed databases, in bytes.
    var totalDatabaseStorageBytes: Int64 {
        databases
            .filter { $0.status == .ready }
            .compactMap(\.sizeOnDisk)
            .reduce(0, +)
    }

    /// The base directory where databases are stored.
    ///
    /// Reads from AppSettings/databaseStorageURL so it reflects any
    /// custom storage location the user has configured.
    var databaseStoragePath: String {
        AppSettings.shared.databaseStorageURL.path
    }

    /// Presents an NSOpenPanel to choose a new database storage directory.
    ///
    /// On selection, updates AppSettings/databaseStorageURL and posts
    /// the databaseStorageLocationChanged notification so the registry
    /// and other observers update.
    func chooseDatabaseStorageLocation() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        panel.message = "Select a directory for database storage"

        panel.begin { [weak self] response in
            // panel.begin calls back on the main thread; use
            // MainActor.assumeIsolated to satisfy Swift 6 isolation.
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard response == .OK, let url = panel.url else { return }
                    AppSettings.shared.databaseStorageURL = url
                    self?.refreshDatabases()
                }
            }
        }
    }

    // MARK: - Lifecycle

    init(packStatusProvider: any PluginPackStatusProviding = PluginPackStatusService.shared) {
        self.packStatusProvider = packStatusProvider
        refreshInstalled()
        refreshPackStatuses()
    }

    // MARK: - Installed Tab Actions

    /// Refreshes the list of installed environments.
    func refreshInstalled() {
        Task {
            isLoading = true
            defer { isLoading = false }

            do {
                let envs = try await CondaManager.shared.listEnvironments()
                environments = envs.sorted { $0.name < $1.name }
                logger.info("Found \(envs.count, privacy: .public) conda environments")
            } catch {
                handleError(error, context: "listing environments")
            }
        }
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

    // MARK: - Available Tab Actions

    /// Triggers a bioconda search.
    func commitSearch() {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return }

        Task {
            isLoading = true
            hasSearched = true
            defer { isLoading = false }

            do {
                let results = try await CondaManager.shared.search(query: query)
                searchResults = results
                logger.info("Search for '\(query, privacy: .public)' returned \(results.count, privacy: .public) results")
            } catch {
                searchResults = []
                handleError(error, context: "searching for '\(query)'")
            }
        }
    }

    /// Installs a package into its own environment.
    func installPackage(_ package: CondaPackageInfo) {
        let name = package.name
        installingPackages.insert(name)
        installProgress[name] = 0.0

        Task {
            defer {
                installingPackages.remove(name)
                installProgress.removeValue(forKey: name)
            }

            do {
                try await CondaManager.shared.install(
                    packages: [name],
                    environment: name,
                    progress: { [weak self] progress, message in
                        Task { @MainActor [weak self] in
                            self?.installProgress[name] = progress
                        }
                    }
                )
                logger.info("Installed package '\(name, privacy: .public)'")
                refreshInstalled()
            } catch {
                handleError(error, context: "installing '\(name)'")
            }
        }
    }

    // MARK: - Packs Tab Actions

    func loadPackStatuses() async {
        let statuses = await packStatusProvider.visibleStatuses()
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

    /// Installs or reinstalls a plugin pack through the shared status service.
    func installPack(_ pack: PluginPack, reinstall: Bool = false) {
        installingPacks.insert(pack.id)
        packProgressMessage[pack.id] = reinstall ? "Reinstalling..." : "Installing..."

        Task {
            defer {
                installingPacks.remove(pack.id)
                packProgressMessage.removeValue(forKey: pack.id)
            }

            do {
                try await packStatusProvider.install(pack: pack, reinstall: reinstall) { [weak self] event in
                    DispatchQueue.main.async {
                        MainActor.assumeIsolated {
                            self?.packProgressMessage[pack.id] = event.message
                        }
                    }
                }
            } catch {
                handleError(error, context: "\(reinstall ? "reinstalling" : "installing") '\(pack.name)'")
            }
            refreshInstalled()
            refreshPackStatuses()
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

            refreshInstalled()
            refreshPackStatuses()
        }
    }

    // MARK: - Databases Tab Actions

    /// Refreshes the database catalog from the registry.
    func refreshDatabases() {
        Task {
            do {
                let registry = MetagenomicsDatabaseRegistry.shared
                let allDBs = try await registry.availableDatabases()
                databases = allDBs

                let recommended = try await registry.recommendedDatabase(ramBytes: systemRAMBytes)
                recommendedDatabaseName = recommended.name

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
            } catch {
                handleError(error, context: "removing database '\(name)'")
                refreshDatabases()
            }
        }
    }

    // MARK: - Helpers

    private func handleError(_ error: Error, context: String) {
        let message = "Error \(context): \(error.localizedDescription)"
        logger.error("\(message, privacy: .public)")
        errorMessage = message
        showingError = true
    }
}
