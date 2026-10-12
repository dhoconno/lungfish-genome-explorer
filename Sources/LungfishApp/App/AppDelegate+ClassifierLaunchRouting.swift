// AppDelegate+ClassifierLaunchRouting.swift - Picks the CLI route or the in-process route for a classifier launch
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import Foundation
import LungfishKit
import LungfishWorkflow

/// The Tools menu's Kraken2 and EsViritu launches go through here (AppDelegate+ToolsMenu.swift),
/// which picks the route of each launch from its hidden key (ClassifierLaunchRoute.swift, panel
/// decision E10). The in-process route stays in AppDelegate+Classification.swift, unchanged, until it
/// goes in 2.9 (E14). A launch with no project open takes neither route, since both write their result
/// into the project (decision L1).
extension AppDelegate {
    /// Runs the Kraken2 configs the dialog hands over, on the route their path's key names.
    func launchClassification(
        configs: [ClassificationConfig],
        viewerController: ViewerViewController,
        routeContext: OperationRouteContext? = nil,
        routes: ClassifierLaunchRouteSettings = ClassifierLaunchRouteSettings()
    ) {
        guard !configs.isEmpty else { return }
        let path = ClassifierLaunchPath.kraken2(sampleCount: configs.count)
        guard let route = classifierLaunchRoute(for: path, routeContext: routeContext, routes: routes) else {
            refuseClassifierLaunchWithoutProject(
                tool: FASTQOperationToolID.kraken2.title,
                viewerController: viewerController,
                routeContext: routeContext
            )
            return
        }
        switch route {
        case .legacy:
            runClassification(configs: configs, viewerController: viewerController, routeContext: routeContext)
        case .cli:
            runClassificationThroughCLI(configs: configs, viewerController: viewerController, routeContext: routeContext)
        }
    }

    /// Runs the EsViritu configs the dialog hands over, on the route their path's key names.
    func launchEsViritu(
        configs: [EsVirituConfig],
        viewerController: ViewerViewController,
        routeContext: OperationRouteContext? = nil,
        routes: ClassifierLaunchRouteSettings = ClassifierLaunchRouteSettings()
    ) {
        guard !configs.isEmpty else { return }
        let path = ClassifierLaunchPath.esViritu(sampleCount: configs.count)
        guard let route = classifierLaunchRoute(for: path, routeContext: routeContext, routes: routes) else {
            refuseClassifierLaunchWithoutProject(
                tool: FASTQOperationToolID.esViritu.title,
                viewerController: viewerController,
                routeContext: routeContext
            )
            return
        }
        switch route {
        case .legacy:
            runEsViritu(configs: configs, viewerController: viewerController, routeContext: routeContext)
        case .cli:
            runEsVirituThroughCLI(configs: configs, viewerController: viewerController, routeContext: routeContext)
        }
    }

    /// The route a launch of `path` takes, or nil for a launch with no project open. Both routes
    /// write their result into the open project's `Analyses/` folder (the CLI route with `--project`,
    /// E1), so such a launch takes neither, whatever the key says, and is refused (decision L1).
    func classifierLaunchRoute(
        for path: ClassifierLaunchPath,
        routeContext: OperationRouteContext?,
        routes: ClassifierLaunchRouteSettings
    ) -> ClassifierLaunchRoute? {
        guard (routeContext ?? currentOperationRouteContext())?.projectURL != nil else {
            return nil
        }
        return routes.route(for: path)
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
