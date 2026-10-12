// AppDelegate+ClassifierLaunchRouting.swift - The FASTQ operations dialog's Kraken2 and EsViritu launches
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import Foundation
import LungfishKit
import LungfishWorkflow

/// The Tools menu's Kraken2 and EsViritu launches go through here (AppDelegate+ToolsMenu.swift).
/// Every launch runs `lungfish-cli` through the CLI route (AppDelegate+ClassificationCLIRoute.swift),
/// since the in-process route and the hidden keys that chose between them went in Phase 2.9 (E14).
/// A launch with no project open is refused, because the command writes its result into the project
/// (decision L1).
extension AppDelegate {
    /// Runs the Kraken2 configs the dialog hands over through `lungfish-cli kraken2 classify`.
    func launchClassification(
        configs: [ClassificationConfig],
        viewerController: ViewerViewController,
        routeContext: OperationRouteContext? = nil
    ) {
        runClassificationThroughCLI(configs: configs, viewerController: viewerController, routeContext: routeContext)
    }

    /// Runs the EsViritu configs the dialog hands over through `lungfish-cli esviritu detect`.
    func launchEsViritu(
        configs: [EsVirituConfig],
        viewerController: ViewerViewController,
        routeContext: OperationRouteContext? = nil
    ) {
        runEsVirituThroughCLI(configs: configs, viewerController: viewerController, routeContext: routeContext)
    }

    /// Refuses a classifier launch that has no project to write into with the `No Project Open`
    /// sheet, the house refusal of imports and primer design (decision L1, UX U14). The launch
    /// starts nothing, so no row, no folder and no byte appears. The sheet sits on the window the
    /// launch came from and names the tool the way the Tools menu does.
    func refuseClassifierLaunchWithoutProject(
        tool: String,
        viewerController: ViewerViewController,
        routeContext: OperationRouteContext?
    ) {
        showAlert(
            title: "No Project Open",
            message: "Open or create a project before running \(tool). LGE saves its results in the project's Analyses folder.",
            presentingWindow: viewerController.view.window ?? targetMainWindowController(routeContext: routeContext)?.window
        )
    }
}
