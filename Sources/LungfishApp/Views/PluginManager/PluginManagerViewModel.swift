// PluginManagerViewModel.swift - View model for the Plugin Manager
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
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
@MainActor
@Observable
final class PluginManagerViewModel {

    // MARK: - Tab

    /// The three sections of the Plugin Manager.
    enum Tab: Hashable, Sendable {
        case installed
        case available
        case packs

        /// Maps to the segmented control index.
        var segmentIndex: Int {
            switch self {
            case .installed: return 0
            case .available: return 1
            case .packs: return 2
            }
        }

        /// Creates a tab from a segmented control index.
        static func from(segmentIndex: Int) -> Tab {
            switch segmentIndex {
            case 0: return .installed
            case 1: return .available
            case 2: return .packs
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

    /// All built-in plugin packs.
    let packs: [PluginPack] = PluginPack.builtIn

    /// Set of pack IDs currently being installed.
    var installingPacks: Set<String> = []

    /// Map of pack ID to installation progress message.
    var packProgressMessage: [String: String] = [:]

    /// Set of installed environment names, for status indicators.
    var installedEnvironmentNames: Set<String> {
        Set(environments.map(\.name))
    }

    // MARK: - Lifecycle

    init() {
        refreshInstalled()
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

    /// Installs all packages in a plugin pack, then runs post-install hooks.
    func installPack(_ pack: PluginPack) {
        installingPacks.insert(pack.id)
        packProgressMessage[pack.id] = "Preparing..."

        Task {
            defer {
                installingPacks.remove(pack.id)
                packProgressMessage.removeValue(forKey: pack.id)
            }

            var allSucceeded = true

            for (index, packageName) in pack.packages.enumerated() {
                let progressMessage = "Installing \(packageName) (\(index + 1)/\(pack.packages.count))"
                packProgressMessage[pack.id] = progressMessage

                do {
                    try await CondaManager.shared.install(
                        packages: [packageName],
                        environment: packageName,
                        progress: { [weak self] progress, message in
                            DispatchQueue.main.async {
                                MainActor.assumeIsolated {
                                    self?.packProgressMessage[pack.id] = progressMessage
                                }
                            }
                        }
                    )
                    logger.info("Pack '\(pack.id, privacy: .public)': installed \(packageName, privacy: .public)")
                } catch {
                    allSucceeded = false
                    logger.error("Pack '\(pack.id, privacy: .public)': failed to install \(packageName, privacy: .public): \(error.localizedDescription, privacy: .public)")
                    // Continue installing remaining packages
                }
            }

            // Run post-install hooks if all packages installed (or at least the
            // environments referenced by the hooks exist).
            if !pack.postInstallHooks.isEmpty {
                await runPostInstallHooks(for: pack, force: allSucceeded)
            }

            refreshInstalled()
        }
    }

    /// Runs post-install hooks for a pack.
    ///
    /// Each hook runs a command inside its target conda environment (e.g.
    /// `freyja update` to download lineage barcodes). Failures are logged
    /// but do not prevent subsequent hooks from running.
    ///
    /// - Parameters:
    ///   - pack: The plugin pack whose hooks to run.
    ///   - force: If `true`, run all hooks regardless of refresh interval.
    private func runPostInstallHooks(for pack: PluginPack, force: Bool) async {
        for hook in pack.postInstallHooks {
            // Verify the target environment exists before running the hook
            guard installedEnvironmentNames.contains(hook.environment) else {
                logger.warning("Skipping hook '\(hook.description, privacy: .public)': environment '\(hook.environment, privacy: .public)' not installed")
                continue
            }

            guard hook.command.count >= 1 else { continue }
            let toolName = hook.command[0]
            let arguments = Array(hook.command.dropFirst())

            packProgressMessage[pack.id] = hook.description

            do {
                let result = try await CondaManager.shared.runTool(
                    name: toolName,
                    arguments: arguments,
                    environment: hook.environment,
                    timeout: 600 // 10 minutes for database downloads
                )

                if result.exitCode == 0 {
                    logger.info(
                        "Hook '\(hook.description, privacy: .public)' completed successfully"
                    )
                } else {
                    logger.warning("Hook '\(hook.description, privacy: .public)' exited with code \(result.exitCode): \(result.stderr, privacy: .public)")
                }
            } catch {
                // Non-fatal: log and continue to next hook
                logger.error("Hook '\(hook.description, privacy: .public)' failed: \(error.localizedDescription, privacy: .public)")
            }
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
