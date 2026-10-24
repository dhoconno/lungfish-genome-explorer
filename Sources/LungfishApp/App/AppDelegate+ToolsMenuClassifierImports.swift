// AppDelegate+ToolsMenuClassifierImports.swift - The NVD and CZ-ID result imports of the Tools menu
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import SwiftUI
import LungfishCore
import LungfishIO
import LungfishOperations
import LungfishWorkflow
import os
import LungfishKit

/// The NVD and CZ-ID result imports of the Tools menu. They live apart from the baselined
/// AppDelegate+ToolsMenu.swift (scripts/ratchets/file-size.sh), so the Phase 2.12 lanes that route
/// them through lungfish-cli edit a small file.
extension AppDelegate {
    func importNvdResultFromURL(_ url: URL, routeContext explicitRouteContext: OperationRouteContext? = nil, onDispatch: (@MainActor @Sendable (ImportDispatchOutcome) -> Void)? = nil) {
        let routeContext = explicitRouteContext ?? currentOperationRouteContext()
        guard let controller = targetMainWindowController(routeContext: routeContext),
              let projectURL = routeContext?.projectURL
                ?? controller.projectSession.projectURL
                ?? controller.mainSplitViewController?.sidebarController?.currentProjectURL else {
            onDispatch?(.rejected("Open a project before importing results."))
            refuseImportWithoutProject("NVD results", window: targetMainWindowController(routeContext: explicitRouteContext)?.window)
            return
        }
        guard canWriteProjectOutputs(
            projectURL: projectURL,
            windowStateScope: routeContext?.windowStateScopeID.map(WindowStateScope.init(id:)),
            workflowName: "NVD Import",
            presentingWindow: controller.window
        ) else {
            onDispatch?(.rejected("This project is not writable."))
            return
        }

        let outputDir: URL
        do {
            outputDir = try ClassifierResultImportCLIRoute.destination(projectURL: projectURL)
        } catch {
            onDispatch?(.rejected("Could not prepare the import destination: \(error.localizedDescription)"))
            showAlert(title: "Import Failed", message: "Could not prepare Analyses folder: \(error.localizedDescription)", presentingWindow: controller.window)
            return
        }

        // The import is `lungfish-cli import nvd`, and the row shows its events (Phase 2.12 lane 12.05).
        let runner = CLIBundleBuildRunner()
        let arguments = ClassifierResultImportCLIRoute.arguments(
            kind: .nvd, inputURL: url, outputDirectory: outputDir, preferredName: nil
        )
        let began = Self.beginNvdImportOperation(
            sourceURL: url,
            importsDirectory: outputDir,
            routeContext: routeContext,
            onCancel: { runner.cancel() }
        ) { opID in
            onDispatch?(.started)
            Task { [weak self] in
                let outcome = await ClassifierResultImportCLIRoute.run(
                    runner, arguments: arguments, operationID: opID, operationTitle: "NVD Import"
                )
                switch outcome {
                case .completed(let folder, _):
                    OperationCenter.shared.log(id: opID, level: .info, message: "NVD import complete: \(folder.lastPathComponent)")
                    self?.targetMainWindowController(routeContext: routeContext)?
                        .mainSplitViewController?.sidebarController.requestReloadFromFilesystem()
                case .cancelled:
                    break
                case .failed(let detail, let alert):
                    guard alert else { return }
                    self?.showAlert(
                        title: "NVD Import Failed",
                        message: detail,
                        presentingWindow: self?.targetMainWindowController(routeContext: routeContext)?.window
                    )
                }
            }
        }
        if case .refused(let refusal) = began { onDispatch?(.rejected(refusal.message)) }
    }

    func importCzIdResultFromURL(_ url: URL, routeContext explicitRouteContext: OperationRouteContext? = nil, onDispatch: (@MainActor @Sendable (ImportDispatchOutcome) -> Void)? = nil) {
        let routeContext = explicitRouteContext ?? currentOperationRouteContext()
        guard let controller = targetMainWindowController(routeContext: routeContext),
              let projectURL = routeContext?.projectURL
                ?? controller.projectSession.projectURL
                ?? controller.mainSplitViewController?.sidebarController?.currentProjectURL else {
            onDispatch?(.rejected("Open a project before importing results."))
            refuseImportWithoutProject("CZ-ID results", window: targetMainWindowController(routeContext: explicitRouteContext)?.window)
            return
        }
        guard canWriteProjectOutputs(
            projectURL: projectURL,
            windowStateScope: routeContext?.windowStateScopeID.map(WindowStateScope.init(id:)),
            workflowName: "CZ-ID Import",
            presentingWindow: controller.window
        ) else {
            onDispatch?(.rejected("This project is not writable."))
            return
        }

        // The import is `lungfish-cli import cz-id` on `CLIBundleBuildRunner`, and the row shows its events
        // (Phase 2.12 lane 12.06). The app reads the report only for the sample name and the row's words.
        Task { @MainActor [weak self] in
            let sampleName: String
            let reportFileName: String
            do {
                (sampleName, reportFileName) = try await Task.detached {
                    let preview = try await CzIdImportPreview.scan(url)
                    return (preview.sampleName, preview.reportFileName)
                }.value
            } catch {
                onDispatch?(.rejected(error.localizedDescription))
                self?.showAlert(
                    title: "CZ-ID Import Failed",
                    message: error.localizedDescription,
                    presentingWindow: self?.targetMainWindowController(routeContext: routeContext)?.window
                )
                return
            }
            let began = AppDelegate.beginCzIdImportOperation(
                sourceURL: url,
                projectURL: projectURL,
                sampleName: sampleName,
                reportFileName: reportFileName,
                routeContext: routeContext
            ) { _ in onDispatch?(.started) }
            guard case .started(let opID) = began else {
                if case .refused(let refusal) = began { onDispatch?(.rejected(refusal.message)) }
                return
            }
            do {
                let run = try await CLIBundleBuildRunner.launch(
                    arguments: CzIdImportCLICommand.arguments(sourceURL: url, projectURL: projectURL, sampleName: sampleName),
                    operationID: opID
                )
                let bundleURL = run.outputs.first.map { URL(fileURLWithPath: $0, isDirectory: true) }
                    ?? projectURL.standardizedFileURL
                        .appendingPathComponent("Classifications", isDirectory: true)
                        .appendingPathComponent(
                            "\(CzIdProjectImportWorkflow.bundleFileName(for: sampleName)).lungfishtax",
                            isDirectory: true
                        )
                guard OperationCenter.shared.complete(
                    id: opID,
                    detail: "Imported \(sampleName)",
                    bundleURLs: [bundleURL]
                ) else { return }
                OperationCenter.shared.log(
                    id: opID,
                    level: .info,
                    message: "Imported CZ-ID result at \(bundleURL.lastPathComponent)"
                )
            } catch is CancellationError {
                // The runner acknowledged the cancel on the row.
            } catch {
                guard OperationCenter.shared.fail(id: opID, detail: error.localizedDescription) else { return }
                self?.showAlert(
                    title: "CZ-ID Import Failed",
                    message: error.localizedDescription,
                    presentingWindow: self?.targetMainWindowController(routeContext: routeContext)?.window
                )
            }
        }
    }
}
