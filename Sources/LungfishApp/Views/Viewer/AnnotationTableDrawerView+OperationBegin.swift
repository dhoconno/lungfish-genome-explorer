// AnnotationTableDrawerView+OperationBegin.swift - Operations panel registration and launch for stored variant edits
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import LungfishIO
import LungfishKit
import LungfishWorkflow

/// The begin helper for the drawer's stored variant edits (finding R4), kept
/// out of the baselined AnnotationTableDrawerView.swift so that file does not
/// grow (scripts/ratchets/file-size.sh). It registers the row through
/// `OperationReporting` and calls `launch` only when the row started, so a
/// test can check the row, its lock and its command without touching
/// `OperationCenter.shared`.
extension AnnotationTableDrawerView {
    /// Registers the stored variant edit row and, only when it starts, calls
    /// `launch` with the operation ID. The row locks `bundleURL` and records
    /// the `lungfish-cli` command that reproduces the edit (plan decision C3),
    /// made from `command`, the argv from the `variants delete` or
    /// `variants import-sample-metadata` words on. `title` names the edit, for
    /// example "Variant deletion".
    @discardableResult
    static func beginVariantStorageMutationOperation(
        title: String,
        bundleURL: URL,
        command: [String],
        routeContext: OperationRouteContext?,
        reporter: any OperationReporting = OperationCenter.shared,
        launch: (UUID) -> Void
    ) -> OperationStartResult {
        let result = reporter.begin(
            title: title,
            detail: "Updating stored data and provenance",
            operationType: .workflow,
            targetBundleURL: bundleURL,
            cliCommand: OperationCenter.buildCLICommand(
                subcommand: command.prefix(2).joined(separator: " "), args: Array(command.dropFirst(2))
            ),
            routeContext: routeContext
        )
        switch result {
        case .started(let operationID):
            launch(operationID)
        case .refused:
            break // The panel already shows the refused row. Nothing was launched.
        }
        return result
    }

    /// Imports the sample metadata of `fileURL` into the bundle's variant databases by launching
    /// `lungfish-cli variants import-sample-metadata` (plan decision C3). The import parses a file
    /// from outside the bundle, so the command reads it and the app reads nothing. The row records
    /// and launches the same argv (with `--format json`) through `CLIBundleEditRunner`, whose
    /// Cancel sends the command SIGTERM, and it completes once the drawer has reloaded the samples
    /// the command stored, so the bundle lock covers both. A row the bundle lock refuses launches
    /// nothing, and the drawer shows its refusal as it does for the other stored edits.
    ///
    /// - Parameters:
    ///   - center: The center that holds the row. A test passes its own.
    ///   - cliURLOverride: The `lungfish-cli` to run, for a test that runs the built one.
    /// - Returns: The task that runs the edit, or nil when the drawer has no search index or the row
    ///   was refused.
    @discardableResult
    func importSampleMetadata(
        fileURL: URL,
        format: MetadataFormat,
        bundleURL: URL,
        center: OperationCenter = .shared,
        cliURLOverride: URL? = nil
    ) -> Task<Void, Never>? {
        guard let source = searchIndex else { return nil }
        let owner = window?.windowController as? MainWindowController
        let session = owner?.projectSession
        let generation = session?.documentGeneration
        let sourceWindow = window
        let scope = windowStateScope
        let route = OperationRouteContext(
            projectURL: session?.projectURL ?? owner?.mainSplitViewController?.sidebarController?.currentProjectURL
                ?? ProjectTempDirectory.findProjectRoot(bundleURL),
            windowStateScope: scope)
        let arguments = VariantSampleMetadataImportService.importMetadataArguments(
            metadataURL: fileURL, format: format, bundleURL: bundleURL
        ) + ["--format", "json"]
        var task: Task<Void, Never>?
        Self.beginVariantStorageMutationOperation(
            title: "Sample metadata import", bundleURL: bundleURL, command: arguments, routeContext: route, reporter: center
        ) { operationID in
            variantStorageOperationID = operationID
            task = Task { @MainActor [weak self] in
                defer {
                    if self?.variantStorageOperationID == operationID {
                        self?.variantStorageOperationID = nil
                        self?.variantStorageMutationTask = nil
                    }
                }
                do {
                    _ = try await CLIBundleEditRunner.launch(
                        arguments: arguments, operationID: operationID, cliURLOverride: cliURLOverride
                    )
                    if let self, self.searchIndex === source, self.window === sourceWindow,
                       self.windowStateScope == scope, session?.documentGeneration == generation {
                        annotationDrawerLogger.info("importSampleMetadata: Imported \(fileURL.lastPathComponent)")
                        self.populateSampleData(from: source)
                        self.configureColumnsForTab(.samples)
                        self.updateDisplayedSamples()
                    }
                    center.complete(id: operationID, detail: "Data and provenance updated")
                } catch {
                    center.fail(id: operationID, detail: "Stored data update failed", errorMessage: error.localizedDescription)
                    annotationDrawerLogger.error("Stored data update failed: \(error.localizedDescription)")
                }
            }
            variantStorageMutationTask = task
        }
        return task
    }
}
