// PluginManagerViewModel+OperationBegin.swift - Operations panel registration for Plugin Manager launches
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishKit
import LungfishWorkflow

/// The begin helpers for the pack install and database update launches in the
/// baselined PluginManagerViewModel.swift (finding R4). They live here, not
/// beside their launch sites, so the baselined file does not grow
/// (scripts/ratchets/file-size.sh). Each helper registers its row through
/// `OperationReporting` and calls `launch` only when the row started, so a test
/// can check the row and its command without touching `OperationCenter.shared`.
/// Neither row locks a bundle, so a real `OperationCenter` never refuses them.
extension PluginManagerViewModel {
    /// Registers the plugin pack row for an install or a reinstall and, only when
    /// it starts, calls `launch` with the operation ID. The row locks no bundle.
    ///
    /// The row records `lungfish-cli conda install --pack <pack ID>`. That
    /// command installs the pack through the same
    /// `PluginPackStatusProviding.install` call as the run, with `reinstall`
    /// false.
    ///
    /// cli-parity-gap: plugin-reinstall. `conda install` has no option that
    /// reinstalls a pack, because its `--overwrite` flag applies only to an
    /// offline pack bundle. A reinstall run passes `reinstall` true, which
    /// recreates the pack's environments instead of installing only what is
    /// missing. The reinstall row records no command. The plain install
    /// command is the closest, and it does not reproduce a reinstall.
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
            cliCommand: reinstall ? nil : OperationCenter.buildCLICommand(
                subcommand: "conda install",
                args: ["--pack", pack.id]
            )
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
    /// The row records `lungfish-cli conda db update <catalog ID> --yes`, which
    /// exists under the `conda` command group. `catalogID` is the resolved
    /// catalog identifier the run hands to
    /// `MetagenomicsDatabaseRegistry.updateDatabase`, and the command calls the
    /// same registry method with the same identifier.
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
            cliCommand: OperationCenter.buildCLICommand(
                subcommand: "conda db update",
                args: [catalogID, "--yes"]
            )
        )
        switch result {
        case .started(let operationID):
            launch(operationID)
        case .refused:
            break // The panel already shows the refused row. Nothing was launched.
        }
        return result
    }
}
