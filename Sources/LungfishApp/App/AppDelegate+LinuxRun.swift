// AppDelegate+LinuxRun.swift - The Import Center's plan sheet and adopt of a Linux run (CHTC C4 lane U)
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import Foundation
import LungfishWorkflow

extension AppDelegate {
    /// Opens the plan sheet for the chosen reads (Import Center, Plan for a Linux Machine). The plan needs no project,
    /// since nothing is imported.
    func writeFASTQPlanFromURLs(_ urls: [URL]) {
        guard let window = activeMainWindowController()?.window else { return }
        FASTQPlanSheet.present(on: window, inputs: urls) { request in
            FASTQIngestionService.beginLinuxPlanOperation(request: request, routeContext: nil) { operationID, arguments in
                FASTQIngestionService.runLinuxRunCommand(
                    arguments: arguments, operationID: operationID, projectDirectory: request.planFolder,
                    onBundleCreated: { _ in }
                )
            }
        }
    }

    /// Adopts a plan folder that a Linux run returned into the open project as one FASTQ bundle (Import Center, Linux
    /// Run Result), through `lungfish-cli import fastq <folder> --adopt`.
    func adoptLinuxRunFromURL(_ url: URL) {
        guard let originController = activeMainWindowController(),
              let mainSplit = originController.mainSplitViewController,
              let projectURL = mainSplit.sidebarController.currentProjectURL else {
            showAlert(title: "No Project Open", message: "Please open a project before importing a Linux run result.")
            return
        }
        guard canWriteProjectOutputs(
            projectURL: projectURL,
            windowStateScope: originController.projectSession.windowStateScope,
            workflowName: "Linux run result import",
            presentingWindow: originController.window
        ) else { return }
        FASTQIngestionService.beginLinuxRunAdoptOperation(
            resultFolder: url, projectDirectory: projectURL, routeContext: nil
        ) { operationID, arguments in
            FASTQIngestionService.runLinuxRunCommand(
                arguments: arguments, operationID: operationID, projectDirectory: projectURL
            ) { [weak mainSplit] _ in
                Task { @MainActor in mainSplit?.sidebarController.requestReloadFromFilesystem() }
            }
        }
    }
}
