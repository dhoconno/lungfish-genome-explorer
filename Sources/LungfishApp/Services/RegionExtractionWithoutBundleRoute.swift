// RegionExtractionWithoutBundleRoute.swift - The route of a viewer's region bundle with no reference bundle, and its hidden key
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation

/// The route a viewer with no reference bundle builds its region bundle on (Phase 2.12 lane 12.12,
/// A48-GAP, plan R-A1 and U-R1, C4 of 2.10).
enum RegionExtractionWithoutBundleRoute: String, Sendable, Equatable, CaseIterable {
    /// The route before lane 12.12, `SequenceExtractionPipeline` in this process, kept for one release
    /// as the escape the hidden key names, since the CLI route also keeps the staged FASTA and its
    /// record names it and the document. Lane 13.03 (DEL-REST) deletes it with its key.
    case legacy
    /// `lungfish-cli extract sequence <staged FASTA> <region> -o <name>.lungfishref` on `CLIBundleBuildRunner`.
    case cli
}

/// Reads the route from the defaults it is given, so a test passes its own suite and never touches the
/// user's defaults.
struct RegionExtractionWithoutBundleRouteSettings {
    /// The hidden key, a name no earlier key used (U-R1). It holds `cli` or `legacy`, or a Boolean that is
    /// true for the CLI route, for example `defaults write <app id> RegionExtractionWithoutBundleRoute legacy`.
    static let defaultsKey = "RegionExtractionWithoutBundleRoute"
    /// The route of a key that is unset or holds a value this reader does not know.
    static let defaultRoute: RegionExtractionWithoutBundleRoute = .cli

    let defaults: UserDefaults

    var route: RegionExtractionWithoutBundleRoute {
        switch defaults.object(forKey: Self.defaultsKey) {
        case let name as String:
            return RegionExtractionWithoutBundleRoute(rawValue: name.lowercased()) ?? Self.defaultRoute
        case let usesCLI as Bool:
            return usesCLI ? .cli : .legacy
        default:
            return Self.defaultRoute
        }
    }

    /// The route the viewer takes now, read from the app's defaults.
    static var currentRoute: RegionExtractionWithoutBundleRoute {
        RegionExtractionWithoutBundleRouteSettings(defaults: .standard).route
    }
}
