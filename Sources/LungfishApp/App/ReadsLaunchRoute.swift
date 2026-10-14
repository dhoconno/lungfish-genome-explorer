// ReadsLaunchRoute.swift - The hidden keys that pick the route of a Map Reads and a Reassemble launch
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation

/// The route a Map Reads or Reassemble launch takes (Phase 2.10, decision C4). The in-process
/// route and its key stay for one release once the key turns to `cli` (2.7 E14).
enum ReadsLaunchRoute: String, Sendable, Equatable, CaseIterable {
    /// Today's route. The app runs the managed pipeline in process.
    case legacy
    /// The app runs `lungfish-cli map` or `lungfish-cli assemble` on `CLIReadsRunner` and records
    /// the argv it runs.
    case cli
}

/// The two launches of the L6 family that keep a key. Each has its own key, so one can move to
/// the CLI route, or back, without the other.
enum ReadsLaunchPath: String, Sendable, Equatable, CaseIterable {
    /// Map Reads (census row p19).
    case mapping
    /// Reassemble from the sidebar (census row p32).
    case assembly

    /// The hidden `UserDefaults` key of the launch, such as `ReadsLaunchRoute.mapping`. It holds
    /// `cli` or `legacy`, or a Boolean that is true for the CLI route, for example
    /// `defaults write <app id> ReadsLaunchRoute.mapping cli`.
    var defaultsKey: String {
        "ReadsLaunchRoute.\(rawValue)"
    }
}

/// Reads the route of each launch from the defaults it is given, so a test passes its own suite and
/// never touches the user's defaults.
struct ReadsLaunchRouteSettings {
    /// The route of a launch whose key is unset or holds a value this reader does not know. It stays
    /// on today's route until both parity classes pass, and lane A46's last commit turns it to `cli`.
    static let defaultRoute: ReadsLaunchRoute = .legacy

    let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// The route the key of `path` asks for, or ``defaultRoute``.
    func route(for path: ReadsLaunchPath) -> ReadsLaunchRoute {
        switch defaults.object(forKey: path.defaultsKey) {
        case let name as String:
            return ReadsLaunchRoute(rawValue: name.lowercased()) ?? Self.defaultRoute
        case let usesCLI as Bool:
            return usesCLI ? .cli : .legacy
        default:
            return Self.defaultRoute
        }
    }
}
