// AppDelegate+ClassifierLaunchRouting.swift - Picks the CLI route or the in-process route for a classifier launch
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishKit
import LungfishWorkflow

/// The Tools menu's Kraken2 and EsViritu launches go through here (AppDelegate+ToolsMenu.swift),
/// which picks the route of each launch from its hidden key (ClassifierLaunchRoute.swift, panel
/// decision E10). The in-process route stays in AppDelegate+Classification.swift, unchanged, until it
/// goes in 2.9 (E14).
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
        switch classifierLaunchRoute(for: path, routeContext: routeContext, routes: routes) {
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
        switch classifierLaunchRoute(for: path, routeContext: routeContext, routes: routes) {
        case .legacy:
            runEsViritu(configs: configs, viewerController: viewerController, routeContext: routeContext)
        case .cli:
            runEsVirituThroughCLI(configs: configs, viewerController: viewerController, routeContext: routeContext)
        }
    }

    /// The route a launch of `path` takes. The CLI route writes its result into the open project
    /// with `--project` (E1), so a launch with no project open takes the in-process route, whatever the
    /// key says.
    func classifierLaunchRoute(
        for path: ClassifierLaunchPath,
        routeContext: OperationRouteContext?,
        routes: ClassifierLaunchRouteSettings
    ) -> ClassifierLaunchRoute {
        guard routes.route(for: path) == .cli,
              (routeContext ?? currentOperationRouteContext())?.projectURL != nil else {
            return .legacy
        }
        return .cli
    }
}
