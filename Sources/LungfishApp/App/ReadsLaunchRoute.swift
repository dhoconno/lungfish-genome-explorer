// ReadsLaunchRoute.swift - The hidden key that picks the route of a Map Reads launch
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation

/// The route a Map Reads launch takes (Phase 2.10, decision C4). The in-process route and its key
/// stay for one release now that the key defaults to `cli` (2.7 E14). The Reassemble and ONT import
/// keys went in Phase 2.11 (K3).
enum ReadsLaunchRoute: String, Sendable, Equatable, CaseIterable {
    /// The route of the releases before the flip. The app runs the launch in process. A
    /// key set to `legacy` keeps it for one release.
    case legacy
    /// The default since lane A46 M3's last commit. The app runs `lungfish-cli map` on
    /// `CLIReadsRunner` and records the argv it runs.
    case cli
}

/// The launch of the L6 family that keeps a key.
enum ReadsLaunchPath: String, Sendable, Equatable, CaseIterable {
    /// Map Reads (census row p19).
    case mapping

    /// The hidden `UserDefaults` key of the launch, such as `ReadsLaunchRoute.mapping`. It holds
    /// `cli` or `legacy`, or a Boolean that is true for the CLI route, for example
    /// `defaults write <app id> ReadsLaunchRoute.mapping legacy`.
    var defaultsKey: String {
        "ReadsLaunchRoute.\(rawValue)"
    }
}

/// Reads the route of each launch from the defaults it is given, so a test passes its own suite and
/// never touches the user's defaults.
struct ReadsLaunchRouteSettings {
    /// The route of a launch whose key is unset or holds a value this reader does not know. It is
    /// the CLI route since lane A46's last commit, which came once both parity classes passed.
    static let defaultRoute: ReadsLaunchRoute = .cli

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
