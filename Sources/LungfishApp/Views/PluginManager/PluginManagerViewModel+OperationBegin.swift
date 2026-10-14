// PluginManagerViewModel+OperationBegin.swift - Operations panel registration and routes for Plugin Manager launches
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishKit
import LungfishWorkflow

/// The begin helpers for the pack install and database update launches in the
/// baselined PluginManagerViewModel.swift (finding R4), and the route each launch takes
/// (Phase 2.10 lane A52). They live here, not beside their launch sites, so the baselined
/// file does not grow (scripts/ratchets/file-size.sh). Each helper registers its row through
/// `OperationReporting` and calls `launch` only when the row started, so a test
/// can check the row and its command without touching `OperationCenter.shared`.
/// Neither row locks a bundle, so a real `OperationCenter` never refuses them.
extension PluginManagerViewModel {
    /// Registers the plugin pack row for an install or a reinstall and, only when
    /// it starts, calls `launch` with the operation ID. The row locks no bundle.
    ///
    /// The row records `lungfish-cli conda install --pack <pack ID> [--reinstall] --format json`,
    /// the argv the CLI route runs (`CLIManagedToolsRunner.installPack`). A reinstall recreates
    /// the pack's environments instead of installing only what is missing, as the in-process
    /// call with `reinstall` true does, so the row now reproduces it.
    @discardableResult
    static func beginPluginPackOperation(
        pack: PluginPack,
        reinstall: Bool,
        reporter: any OperationReporting = OperationCenter.shared,
        launch: (UUID) -> Void
    ) -> OperationStartResult {
        let result = reporter.begin(
            title: "Plugin Pack: \(pack.name)",
            detail: "\(reinstall ? "Preparing to reinstall" : "Preparing to install") \(pack.name)",
            operationType: .condaPluginPack,
            cliCommand: CLIManagedToolsRunner.installPack(packID: pack.id, reinstall: reinstall).recordedCommand
        )
        switch result {
        case .started(let operationID):
            launch(operationID)
        case .refused:
            break // The panel already shows the refused row. Nothing was launched.
        }
        return result
    }

    /// Registers the database update row and, only when it starts, calls
    /// `launch` with the operation ID. The row locks no bundle and is a
    /// download row.
    ///
    /// The row records `lungfish-cli conda db update <catalog ID> --yes --format json`, the argv the
    /// CLI route runs (`CLIManagedToolsRunner.updateDatabase`). `catalogID` is the resolved
    /// catalog identifier the run hands to `MetagenomicsDatabaseRegistry.updateDatabase`, and the
    /// command calls the same registry method with the same identifier.
    @discardableResult
    static func beginDatabaseUpdateOperation(
        name: String,
        catalogID: String,
        targetVersion: String,
        reporter: any OperationReporting = OperationCenter.shared,
        launch: (UUID) -> Void
    ) -> OperationStartResult {
        let result = reporter.begin(
            title: "Update Database: \(name)",
            detail: "Updating \(name) to \(targetVersion)",
            operationType: .download,
            cliCommand: CLIManagedToolsRunner.updateDatabase(catalogID: catalogID).recordedCommand
        )
        switch result {
        case .started(let operationID):
            launch(operationID)
        case .refused:
            break // The panel already shows the refused row. Nothing was launched.
        }
        return result
    }

    // MARK: - Routes

    /// Installs or reinstalls `pack` on the route the hidden key names (panel decision C4).
    ///
    /// The legacy route is `provider.install` in this process. The CLI route runs
    /// `conda install --pack` on the row `operationID`, whose events the row shows, and the
    /// caller reads the pack's status afterwards as it did. A cancel the row acknowledged ends
    /// this call without a throw, because the command put back what it moved aside and the row
    /// says Cancelled, where a throw would raise the failure alert.
    func installPackThroughRoute(
        pack: PluginPack,
        reinstall: Bool,
        operationID: UUID,
        provider: any PluginPackStatusProviding,
        cliURLOverride: URL? = nil,
        progress: @escaping @Sendable (PluginPackInstallProgress) -> Void
    ) async throws {
        switch ManagedToolsRouteSettings.currentRoute {
        case .legacy:
            try await provider.install(pack: pack, reinstall: reinstall, progress: progress)
        case .cli:
            let packID = pack.id
            // The command changed the environments in another process, whatever way it ended, so
            // the status service forgets what it cached before the caller reads the status.
            do {
                _ = try await CLIManagedToolsRunner.launch(
                    CLIManagedToolsRunner.installPack(packID: packID, reinstall: reinstall),
                    operationID: operationID,
                    overlay: { [weak self] message in self?.packProgressMessage[packID] = message },
                    cliURLOverride: cliURLOverride
                )
            } catch is CancellationError {
                await provider.invalidateVisibleStatusesCache()
                return
            } catch {
                await provider.invalidateVisibleStatusesCache()
                throw error
            }
            await provider.invalidateVisibleStatusesCache()
        }
    }

    /// Updates the database `catalogID` on the route the hidden key names (panel decision C10).
    ///
    /// The legacy route is `legacy`, the registry call in this process. The CLI route runs
    /// `conda db update` on the row `operationID` and reloads the registry from disk afterwards,
    /// because the command saved the manifest in another process. A cancel throws
    /// `CancellationError`, which the caller does not report as a failure.
    func updateDatabaseThroughRoute(
        catalogID: String,
        operationID: UUID,
        legacy: @Sendable (String, @escaping @Sendable (Double, String) -> Void) async throws -> Void,
        registry: MetagenomicsDatabaseRegistry = .shared,
        cliURLOverride: URL? = nil,
        progress: @escaping @Sendable (Double, String) -> Void
    ) async throws {
        switch ManagedToolsRouteSettings.currentRoute {
        case .legacy:
            try await legacy(catalogID, progress)
        case .cli:
            _ = try await CLIManagedToolsRunner.launch(
                CLIManagedToolsRunner.updateDatabase(catalogID: catalogID),
                operationID: operationID,
                progress: progress,
                cliURLOverride: cliURLOverride
            )
            try await registry.reloadFromDisk()
        }
    }
}
