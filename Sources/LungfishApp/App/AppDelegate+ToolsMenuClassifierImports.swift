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

        let importsDir = projectURL.appendingPathComponent("Imports", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: importsDir, withIntermediateDirectories: true)
        } catch {
            onDispatch?(.rejected("Could not prepare the import destination: \(error.localizedDescription)"))
            showAlert(title: "Import Failed", message: "Could not prepare Imports folder: \(error.localizedDescription)", presentingWindow: controller.window)
            return
        }

        let began = Self.beginNvdImportOperation(
            sourceURL: url,
            importsDirectory: importsDir,
            routeContext: routeContext
        ) { opID in
            onDispatch?(.started)
            let task = Task.detached { [weak self] in
                do {
                    let result = try await MetagenomicsImportHelperClient.importViaCLI(
                        kind: .nvd,
                        inputURL: url,
                        outputDirectory: importsDir
                    ) { progress, message in
                        DispatchQueue.main.async {
                            MainActor.assumeIsolated {
                                _ = OperationCenter.shared.update(
                                    id: opID,
                                    progress: progress,
                                    detail: message
                                )
                            }
                        }
                    }

                    DispatchQueue.main.async {
                        MainActor.assumeIsolated {
                            guard OperationCenter.shared.complete(
                                id: opID,
                                detail: result.detail,
                                bundleURLs: [result.resultDirectory]
                            ) else { return }
                            OperationCenter.shared.log(
                                id: opID,
                                level: .info,
                                message: "NVD import complete: \(result.resultDirectory.lastPathComponent)"
                            )
                            self?.targetMainWindowController(routeContext: routeContext)?
                                .mainSplitViewController?.sidebarController.requestReloadFromFilesystem()
                        }
                    }
                } catch is CancellationError {
                    DispatchQueue.main.async {
                        MainActor.assumeIsolated {
                            OperationCenter.shared.acknowledgeCancellation(id: opID)
                            OperationCenter.shared.log(
                                id: opID,
                                level: .info,
                                message: "NVD import cancelled"
                            )
                        }
                    }
                } catch {
                    DispatchQueue.main.async {
                        MainActor.assumeIsolated {
                            if let partialDir = (error as? MetagenomicsImportHelperClientError)?
                                .partialResultDirectory {
                                try? FileManager.default.removeItem(at: partialDir)
                                OperationCenter.shared.log(
                                    id: opID,
                                    level: .info,
                                    message: "Cleaned up partial NVD import directory"
                                )
                            }
                            OperationCenter.shared.log(
                                id: opID,
                                level: .error,
                                message: "NVD import failed: \(error.localizedDescription)"
                            )
                            guard OperationCenter.shared.fail(id: opID, detail: error.localizedDescription) else { return }
                            self?.showAlert(
                                title: "NVD Import Failed",
                                message: error.localizedDescription,
                                presentingWindow: self?.targetMainWindowController(routeContext: routeContext)?.window
                            )
                        }
                    }
                }
            }

            OperationCenter.shared.setCancelCallback(for: opID) { task.cancel() }
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

        // The task must be stored and the OperationCenter row given
        // a cancel callback, or the Operations panel shows no Cancel button
        // and a stalled import can only be ended by quitting the app (the
        // task itself already handles CancellationError correctly below —
        // it was only ever unreachable). `TaskBox` lets the task capture a
        // handle to itself for that callback, set immediately after
        // `Task.detached` returns, below.
        final class TaskBox: @unchecked Sendable {
            var task: Task<Void, Never>?
        }
        let taskBox = TaskBox()
        let task = Task.detached { [weak self] in
            var opID: UUID?
            var bundleURL: URL?
            do {
                try Task.checkCancellation()

                let preview = try await CzIdImportPreview.scan(url)
                let sampleName = preview.sampleName
                let finalBundleURL = projectURL
                    .standardizedFileURL
                    .appendingPathComponent("Classifications", isDirectory: true)
                    .appendingPathComponent(
                        "\(CzIdProjectImportWorkflow.bundleFileName(for: sampleName)).lungfishtax",
                        isDirectory: true
                    )
                bundleURL = finalBundleURL

                // The row, its Cancel button and its first progress line are
                // set up in one main-actor turn. Without the callback the
                // Operations panel shows no Cancel button, and a hung import
                // can only be ended by quitting the app. `taskBox.task` is set
                // to this very task right after `Task.detached` returns below,
                // and the callback only reads it when the user cancels.
                let began = await appPerformOnMainRunLoop {
                    AppDelegate.beginCzIdImportOperation(
                        sourceURL: url,
                        projectURL: projectURL,
                        sampleName: sampleName,
                        reportFileName: preview.reportFileName,
                        routeContext: routeContext
                    ) { startedID in
                        OperationCenter.shared.setCancelCallback(for: startedID) { taskBox.task?.cancel() }
                        onDispatch?(.started)
                        _ = OperationCenter.shared.updateWithLog(
                            id: startedID,
                            progress: 0.35,
                            detail: "Converting \(preview.reportFileName)..."
                        )
                    }
                }
                switch began {
                case .started(let startedID):
                    opID = startedID
                case .refused(let refusal):
                    await appPerformOnMainRunLoop { onDispatch?(.rejected(refusal.message)) }
                    return
                }

                let imported = try await CzIdProjectImportWorkflow.importFromURL(
                    url,
                    projectURL: projectURL,
                    sampleName: sampleName
                )

                let completedOpID = opID
                await appPerformOnMainRunLoop {
                    guard let opID = completedOpID else { return }
                    guard OperationCenter.shared.complete(
                        id: opID,
                        detail: "Imported \(imported.sampleName)",
                        bundleURLs: [imported.bundleURL]
                    ) else { return }
                    OperationCenter.shared.log(
                        id: opID,
                        level: .info,
                        message: "Imported CZ-ID result at \(imported.bundleURL.lastPathComponent)"
                    )
                }
            } catch is CancellationError {
                if let bundleURL {
                    try? FileManager.default.removeItem(at: bundleURL)
                }
                if let opID {
                    await appPerformOnMainRunLoop {
                        _ = OperationCenter.shared.fail(id: opID, detail: "Cancelled")
                    }
                } else {
                    await appPerformOnMainRunLoop { onDispatch?(.cancelled) }
                }
            } catch {
                if let bundleURL {
                    try? FileManager.default.removeItem(at: bundleURL)
                }
                let detail = error.localizedDescription
                let failedOpID = opID
                await appPerformOnMainRunLoop {
                    if let opID = failedOpID {
                        _ = OperationCenter.shared.fail(id: opID, detail: detail)
                    } else {
                        onDispatch?(.rejected(detail))
                    }
                    self?.showAlert(
                        title: "CZ-ID Import Failed",
                        message: detail,
                        presentingWindow: self?.targetMainWindowController(routeContext: routeContext)?.window
                    )
                }
            }
        }
        taskBox.task = task
    }
}
