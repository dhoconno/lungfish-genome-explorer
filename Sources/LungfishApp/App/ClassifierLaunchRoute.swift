// ClassifierLaunchRoute.swift - The hidden switch that picks the route of each classifier launch
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation

/// The route a Kraken2 or EsViritu launch from the FASTQ operations dialog takes (Phase 2.7,
/// panel decision E10).
enum ClassifierLaunchRoute: String, Sendable, Equatable, CaseIterable {
    /// The route before Phase 2.7. The app runs the pipeline in process
    /// (AppDelegate+Classification.swift). A key that names it keeps a launch there until the
    /// route goes in 2.9 (E14).
    case legacy
    /// The default since lane F3 (E10). The app runs `lungfish-cli kraken2 classify` or
    /// `esviritu detect` with `--project` and shows the command's events in the row
    /// (AppDelegate+ClassificationCLIRoute.swift).
    case cli
}

/// One of the four classifier launches. Each has its own hidden key, so one tool or one path can
/// move to the CLI route, or back, without the others (E10).
enum ClassifierLaunchPath: String, Sendable, Equatable, CaseIterable {
    case kraken2Single = "kraken2.single"
    case kraken2Batch = "kraken2.batch"
    case esVirituSingle = "esviritu.single"
    case esVirituBatch = "esviritu.batch"

    /// The hidden `UserDefaults` key of the path, such as `ClassifierLaunchRoute.kraken2.batch`.
    /// It holds `cli` or `legacy`, or a Boolean that is true for the CLI route, for example
    /// `defaults write <app id> ClassifierLaunchRoute.kraken2.batch cli`.
    var defaultsKey: String {
        "ClassifierLaunchRoute.\(rawValue)"
    }

    /// The Kraken2 path of a launch of `sampleCount` samples. More than one sample is a batch, as
    /// `runClassification(configs:viewerController:routeContext:)` decides today.
    static func kraken2(sampleCount: Int) -> ClassifierLaunchPath {
        sampleCount > 1 ? .kraken2Batch : .kraken2Single
    }

    /// The EsViritu path of a launch of `sampleCount` samples, decided as for Kraken2.
    static func esViritu(sampleCount: Int) -> ClassifierLaunchPath {
        sampleCount > 1 ? .esVirituBatch : .esVirituSingle
    }
}

/// Reads the route of each classifier launch from the defaults it is given, so a test passes its
/// own suite and never touches the user's defaults.
struct ClassifierLaunchRouteSettings {
    /// The route of a launch whose key is unset or holds a value this reader does not know. Lane
    /// F3 moved it to the CLI route once parity side C was green, C against C' listed nothing and
    /// every case passed with real tools (E10, ClassifierCLIGUIParityReplayTests).
    static let defaultRoute: ClassifierLaunchRoute = .cli

    let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// The route the key of `path` asks for, or ``defaultRoute``.
    func route(for path: ClassifierLaunchPath) -> ClassifierLaunchRoute {
        switch defaults.object(forKey: path.defaultsKey) {
        case let name as String:
            return ClassifierLaunchRoute(rawValue: name.lowercased()) ?? Self.defaultRoute
        case let usesCLI as Bool:
            return usesCLI ? .cli : .legacy
        default:
            return Self.defaultRoute
        }
    }
}
