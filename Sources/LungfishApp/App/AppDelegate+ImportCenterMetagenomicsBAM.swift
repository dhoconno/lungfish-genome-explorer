// AppDelegate+ImportCenterMetagenomicsBAM.swift - The Import Center's classifier result imports and BAM import, moved out of AppDelegate+ImportCenter.swift
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import LungfishCore
import LungfishIO
import LungfishKit
import LungfishOperations
import LungfishWorkflow
import os

/// The Import Center's Kraken2, EsViritu, TaxTriage and NAO-MGS result imports and its
/// BAM import live here, moved out of AppDelegate+ImportCenter.swift, which is at its
/// size baseline.
extension AppDelegate {

    /// Import a Kraken2 result file (.kreport) from a known URL (called from Import Center).
    func importKraken2ResultFromURL(_ url: URL) {
        importClassifierResultFromURL(
            url,
            kind: .kraken2,
            operationTitle: "Kraken2 Import",
            missingProjectMessage: "Please open a project before importing classification results."
        )
    }

    /// Import an EsViritu result from a known URL (called from Import Center).
    func importEsVirituResultFromURL(_ url: URL) {
        importClassifierResultFromURL(
            url,
            kind: .esviritu,
            operationTitle: "EsViritu Import",
            missingProjectMessage: "Please open a project before importing EsViritu results."
        )
    }

    /// Import a TaxTriage result from a known URL (called from Import Center).
    func importTaxTriageResultFromURL(_ url: URL) {
        importClassifierResultFromURL(
            url,
            kind: .taxtriage,
            operationTitle: "TaxTriage Import",
            missingProjectMessage: "Please open a project before importing TaxTriage results."
        )
    }

    internal func importNaoMgsResultFromURL(_ url: URL, routeContext: OperationRouteContext? = nil, onDispatch: (@MainActor @Sendable (ImportDispatchOutcome) -> Void)? = nil) {
        importClassifierResultFromURL(
            url,
            kind: .naomgs,
            operationTitle: "NAO-MGS Import",
            missingProjectMessage: "Please open a project before importing NAO-MGS results.",
            routeContext: routeContext,
            naoMgsOptions: .init(fetchReferences: true),
            onDispatch: onDispatch
        )
    }

    private func importClassifierResultFromURL(
        _ url: URL,
        kind: MetagenomicsImportKind,
        operationTitle: String,
        missingProjectMessage: String,
        preferredName: String? = nil,
        routeContext explicitRouteContext: OperationRouteContext? = nil,
        naoMgsOptions: ClassifierResultImportCLIRoute.NaoMgsOptions? = nil,
        onDispatch: (@MainActor @Sendable (ImportDispatchOutcome) -> Void)? = nil
    ) {
        let routeContext = explicitRouteContext ?? currentOperationRouteContext()
        let targetController = targetMainWindowController(routeContext: routeContext)
        guard let sidebarController = targetController?.mainSplitViewController?.sidebarController,
              let projectURL = sidebarController.currentProjectURL else {
            onDispatch?(.rejected(missingProjectMessage))
            showAlert(title: "No Project Open", message: missingProjectMessage, presentingWindow: targetController?.window)
            return
        }
        guard canWriteProjectOutputs(
            projectURL: projectURL,
            windowStateScope: routeContext?.windowStateScopeID.map(WindowStateScope.init(id:)),
            workflowName: operationTitle,
            presentingWindow: targetController?.window
        ) else {
            onDispatch?(.rejected("This project is not writable."))
            return
        }

        let outputDir: URL
        do {
            outputDir = try ClassifierResultImportCLIRoute.destination(for: kind, projectURL: projectURL)
        } catch {
            onDispatch?(.rejected("Could not prepare the import destination: \(error.localizedDescription)"))
            showAlert(title: "Import Failed", message: "Could not prepare Analyses folder: \(error.localizedDescription)", presentingWindow: targetController?.window)
            return
        }

        // Every kind runs `lungfish-cli import <kind>` (Phase 2.12 lanes 12.04 and 12.05).
        let runner = CLIBundleBuildRunner()
        let arguments = ClassifierResultImportCLIRoute.arguments(
            kind: kind, inputURL: url, outputDirectory: outputDir, preferredName: preferredName,
            fetchReferences: naoMgsOptions?.fetchReferences ?? true
        )
        Self.beginClassifierResultImportOperation(
            kind: kind,
            operationTitle: operationTitle,
            inputURL: url,
            outputDirectory: outputDir,
            preferredName: preferredName,
            naoMgsOptions: naoMgsOptions,
            routeContext: routeContext,
            onCancel: { runner.cancel() }
        ) { opID in
            onDispatch?(.started)
            Task { [weak self] in
                let outcome = await ClassifierResultImportCLIRoute.run(
                    runner, arguments: arguments, operationID: opID, operationTitle: operationTitle
                )
                guard case .failed(let detail, alert: true) = outcome else { return }
                self?.showAlert(
                    title: "\(operationTitle) Failed",
                    message: detail,
                    presentingWindow: self?.targetMainWindowController(routeContext: routeContext)?.window
                )
            }
        }
    }

    // MARK: - BAM/CRAM Import

    /// Starts a BAM import as an `OperationCenter` operation and returns its id, or `nil`
    /// if it was refused (no bundle open, a write-lock conflict, or the bundle already
    /// busy). Callers that need to wait for this import before starting another on the
    /// same bundle -- see `ImportCenterViewModel`'s multi-file BAM/VCF dispatch
    /// -- await the returned id with `awaitOperationTerminal(id:)`.
    @discardableResult
    internal func performBAMImport(bamURL: URL, bundleURL: URL, routeContext explicitRouteContext: OperationRouteContext? = nil) -> UUID? {
        let routeContext = explicitRouteContext ?? currentOperationRouteContext()
        guard canWriteProjectOutputs(
            projectURL: ProjectTempDirectory.findProjectRoot(bundleURL),
            windowStateScope: routeContext?.windowStateScopeID.map(WindowStateScope.init(id:)),
            workflowName: "BAM import",
            presentingWindow: targetMainWindowController(routeContext: routeContext)?.window
        ) else { return nil }
        guard OperationCenter.shared.canStartOperation(on: bundleURL) else {
            if let holder = OperationCenter.shared.activeLockHolder(for: bundleURL) {
                showAlert(title: "Operation in Progress",
                          message: "\"\(holder.title)\" is currently running on this bundle. Please wait for it to finish.")
            }
            return nil
        }

        let result = Self.beginBAMImportOperation(
            bamURL: bamURL,
            bundleURL: bundleURL,
            routeContext: routeContext,
            onCancel: {} // CLIBundleBuildRunner.launch wires the row's Cancel to the command once it starts
        ) { opID in
            // The import is `lungfish-cli import bam`, and the row shows its events (Phase 2.11 lane A63).
            Task { [weak self] in
                do {
                    let run = try await CLIBundleBuildRunner.launch(
                        arguments: BAMImportCLICommand.arguments(bamURL: bamURL, bundleURL: bundleURL),
                        operationID: opID
                    )
                    guard OperationCenter.shared.complete(id: opID, detail: run.message ?? "Alignments imported") else { return }

                    guard let viewerController = self?.targetMainWindowController(routeContext: routeContext)?
                        .mainSplitViewController?.viewerController else {
                        debugLog("performBAMImport: No viewer controller")
                        return
                    }
                    do {
                        try viewerController.displayBundle(at: bundleURL)
                        debugLog("performBAMImport: Bundle reloaded with alignment track (\(run.message ?? ""))")
                    } catch {
                        debugLog("performBAMImport: Bundle reload failed: \(error)")
                        self?.showAlert(title: "Import Error", message: "Alignments imported but bundle reload failed: \(error.localizedDescription)")
                    }
                } catch is CancellationError {
                    // The runner acknowledged the cancel on the row.
                    debugLog("performBAMImport: Cancelled by user")
                } catch {
                    guard OperationCenter.shared.fail(id: opID, detail: error.localizedDescription) else { return }
                    debugLog("performBAMImport: Failed: \(error)")
                    self?.showAlert(title: "BAM Import Failed", message: error.localizedDescription)
                }
            }
        }
        return result.startedID
    }
}
