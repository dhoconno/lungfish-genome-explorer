// TaxTriageLaunchRoute.swift - The route the Tools menu's TaxTriage launch takes, and its hidden key
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation

/// The route of the TaxTriage launch of the FASTQ operations dialog (Phase 2.11 lane U30, panel
/// decision K1). Kraken2 and EsViritu run through `lungfish-cli` since 2.9. TaxTriage runs there by
/// default since the flip (U30 M4), this key keeps the in-process route for one Preview, and its
/// deletion goes to 2.12.
enum TaxTriageLaunchRoute: String, Sendable, Equatable, CaseIterable {
    /// The route before lane U30, kept for one Preview behind the key's `legacy` value. The app runs
    /// `runTaxTriage` in this process, which writes the cross-reference sidecars, the run history and
    /// a manifest entry itself, and records no command for a run of several samples (cli-parity-gap
    /// `taxtriage-multi-sample`).
    case legacy
    /// The default since U30 M4. `lungfish-cli taxtriage run --project`, run through the app's
    /// transport. One row, whose command is the argv, and nothing written by the app after the
    /// command returns.
    case cli
}

/// Reads the route from the defaults it is given, so a test passes its own suite and never touches
/// the user's defaults.
struct TaxTriageLaunchRouteSettings {
    /// The hidden key. It holds `cli` or `legacy`, or a Boolean that is true for the CLI route, for
    /// example `defaults write <app id> TaxTriageLaunchRoute cli`.
    static let defaultsKey = "TaxTriageLaunchRoute"
    /// The route of a key that is unset or holds a value this reader does not know. It is `.cli`
    /// since the flip (U30 M4), after Q32 M3 showed each sample's payload hashes equal with declared
    /// differences only and BIO read it (K1). An explicit `legacy` keeps the in-process route for one
    /// Preview.
    static let defaultRoute: TaxTriageLaunchRoute = .cli

    let defaults: UserDefaults

    var route: TaxTriageLaunchRoute {
        switch defaults.object(forKey: Self.defaultsKey) {
        case let name as String:
            return TaxTriageLaunchRoute(rawValue: name.lowercased()) ?? Self.defaultRoute
        case let usesCLI as Bool:
            return usesCLI ? .cli : .legacy
        default:
            return Self.defaultRoute
        }
    }

    /// The route the TaxTriage launch takes now, read from the user's defaults. A test passes the
    /// route to `AppDelegate.launchTaxTriage(config:viewerController:routeContext:route:)` instead,
    /// so no test shares a global override with another.
    static var currentRoute: TaxTriageLaunchRoute {
        TaxTriageLaunchRouteSettings(defaults: .standard).route
    }
}
