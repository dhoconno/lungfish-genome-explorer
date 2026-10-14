// ManagedToolsRoute.swift - The route the managed tools and packs rows take, and its hidden key
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import Synchronization

/// The route of the three managed tools and packs launches (Phase 2.10 lane A52, family L10,
/// panel decision C4): the Update Tools sheet's run, the Plugin Manager's pack install and
/// reinstall, and its database update.
enum ManagedToolsRoute: String, Sendable, Equatable, CaseIterable {
    /// The route before lane A52, kept for one release as the escape the hidden key names (C4).
    /// The app runs the reconciler, the pack status service and the database registry in this
    /// process. It opens one Operations row for the whole run and one for every item of an Update
    /// Tools run, the declared difference that keeps the key, and it goes in 2.11.
    case legacy
    /// `lungfish-cli tools update --apply --only`, `conda install --pack [--reinstall]` and
    /// `conda db update`, run through the app's transport. One row, whose command is the argv.
    case cli
}

/// Reads the route from the defaults it is given, so a test passes its own suite and never
/// touches the user's defaults.
struct ManagedToolsRouteSettings {
    /// The hidden key. It holds `cli` or `legacy`, or a Boolean that is true for the CLI route,
    /// for example `defaults write <app id> ManagedToolsRoute legacy`.
    static let defaultsKey = "ManagedToolsRoute"
    /// The route of a key that is unset or holds a value this reader does not know. Lane A52's
    /// last commit set it to `.cli`, once side A against side C held only declared differences
    /// (ManagedToolsCLIGUIParityReplayTests). `defaults write <app id> ManagedToolsRoute legacy`
    /// keeps the in-process route for one release.
    static let defaultRoute: ManagedToolsRoute = .cli

    let defaults: UserDefaults

    var route: ManagedToolsRoute {
        switch defaults.object(forKey: Self.defaultsKey) {
        case let name as String:
            return ManagedToolsRoute(rawValue: name.lowercased()) ?? Self.defaultRoute
        case let usesCLI as Bool:
            return usesCLI ? .cli : .legacy
        default:
            return Self.defaultRoute
        }
    }

    private static let overrideStorage = Mutex<ManagedToolsRoute?>(nil)

    /// A route a test forces. The three launches read ``currentRoute``, so a unit test that drives
    /// the in-process path never starts the built CLI.
    static var testOverride: ManagedToolsRoute? {
        get { overrideStorage.withLock { $0 } }
        set { overrideStorage.withLock { $0 = newValue } }
    }

    /// The route the three launches take now.
    static var currentRoute: ManagedToolsRoute {
        testOverride ?? ManagedToolsRouteSettings(defaults: .standard).route
    }
}
