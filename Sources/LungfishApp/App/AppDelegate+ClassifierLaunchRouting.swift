// AppDelegate+ClassifierLaunchRouting.swift - The FASTQ operations dialog's Kraken2 and EsViritu launches
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import Foundation
import LungfishKit
import LungfishWorkflow

/// The Tools menu's Kraken2, EsViritu and TaxTriage launches go through here (AppDelegate+ToolsMenu.swift).
/// Every Kraken2 and EsViritu launch runs `lungfish-cli` through the CLI route (AppDelegate+ClassificationCLIRoute.swift),
/// since the in-process route and the hidden keys that chose between them went in Phase 2.9 (E14).
/// TaxTriage runs `lungfish-cli taxtriage run --project` the same way since Phase 2.12 (K1).
/// A launch with no project open is refused, because the command writes its result into the project
/// (decision L1). A classifier item chosen with no main window to open the dialog on takes the same
/// refusal, app-modal (decision A4).
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

    /// Runs the TaxTriage config the dialog hands over through `lungfish-cli taxtriage run --project`
    /// (AppDelegate+TaxTriageCLIRoute.swift), the route the default of 2.11's hidden key took since
    /// U30 M4. The key and the in-process route went in Phase 2.12 (K1). A launch with no project
    /// open is refused.
    func launchTaxTriage(
        config: TaxTriageConfig,
        viewerController: ViewerViewController,
        routeContext: OperationRouteContext? = nil,
        cliURLOverride: URL? = nil
    ) {
        runTaxTriageThroughCLI(config: config, viewerController: viewerController, routeContext: routeContext, cliURLOverride: cliURLOverride)
    }

    /// The one refusal of a classifier launch that has no project to write into, the `No Project
    /// Open` alert that imports and primer design show too (decisions L1 and A4, UX U14). The
    /// launch starts nothing, so no row, no folder and no byte appears. The alert names the tool
    /// the way the Tools menu does. It sits as a sheet on `window` when the launch has one and is
    /// app-modal when it has none, through ``NoProjectPresenterSeam``.
    func refuseClassifierLaunchWithoutProject(tool: String, window: NSWindow?) {
        NoProjectPresenterSeam.presenter.present(
            title: "No Project Open",
            message: "Open or create a project before running \(tool). LGE saves its results in the project's Analyses folder.",
            on: window
        )
    }

    /// The refusal for a launch the FASTQ operations dialog handed over, on the window of the
    /// viewer it came from, or the window the route context names, or none.
    func refuseClassifierLaunchWithoutProject(
        tool: String,
        viewerController: ViewerViewController,
        routeContext: OperationRouteContext?
    ) {
        refuseClassifierLaunchWithoutProject(
            tool: tool,
            window: viewerController.view.window ?? targetMainWindowController(routeContext: routeContext)?.window
        )
    }

    /// What `showFASTQOperationsDialog` does when it finds no main window to open the dialog on,
    /// as with no project window open (decision A4). A classifier item has a reason to give,
    /// since its launch needs a project, so it shows the refusal app-modal and names the tool, or
    /// says "a classifier" when the item is the generic one, which has no tool. Any other item only beeps.
    func answerToolsMenuItemWithNoMainWindow(category: FASTQOperationCategoryID, toolID: FASTQOperationToolID?) {
        debugLog("showFASTQOperationsDialog: No main window available")
        guard category == .classification else {
            NSSound.beep()
            return
        }
        refuseClassifierLaunchWithoutProject(tool: toolID?.title ?? "a classifier", window: nil)
    }
}
