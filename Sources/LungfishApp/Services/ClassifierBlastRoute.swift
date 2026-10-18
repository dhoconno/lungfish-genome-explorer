// ClassifierBlastRoute.swift - The hidden key of the classifier BLAST Verify actions moved onto `blast submit`
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation

/// The route of a classifier viewer's BLAST Verify action that Phase 2.12 moves onto `blast submit`: NVD and
/// EsViritu (lane 12.08), TaxTriage and 12S (lane 12.09) and Kraken2 (lane 12.10). Each site's parity class
/// declares, side A against side C, the query copy under the project's `.tmp` and the search's folder under
/// `blast-verifications/`, which the in-process search never wrote, so the move keeps that search behind this
/// hidden key for one release (decision C4 of 2.10, R-A1 and U-R1 of 2.12). The name is new, because a person
/// who set `BlastReadActionRoute` to `legacy` in 2026.10.20 must not run these sites in process unknowingly.
/// Phase 2.13 deletes the key with the `legacy` code.
enum ClassifierBlastRoute: String, Sendable, Equatable, CaseIterable {
    /// `BlastService.verify` in this process, the route before Phase 2.12. Its row records no command.
    case legacy
    /// `lungfish-cli blast submit` on `CLIBlastSubmitRunner`, the default.
    case cli
}

/// Reads the route from the defaults it is given, so a test passes its own suite and never touches the
/// user's defaults.
struct ClassifierBlastRouteSettings {
    /// The hidden key. It holds `cli` or `legacy`, or a Boolean that is true for the CLI route, for
    /// example `defaults write com.lungfish.browser.preview ClassifierBlastRoute legacy`.
    static let defaultsKey = "ClassifierBlastRoute"
    /// The route of a key that is unset or holds a value this reader does not know. Lane 12.08 set it to
    /// `.cli` once side A against side C of the NVD and EsViritu classes held only the declared differences.
    static let defaultRoute: ClassifierBlastRoute = .cli

    let defaults: UserDefaults

    var route: ClassifierBlastRoute {
        switch defaults.object(forKey: Self.defaultsKey) {
        case let name as String:
            return ClassifierBlastRoute(rawValue: name.lowercased()) ?? Self.defaultRoute
        case let usesCLI as Bool:
            return usesCLI ? .cli : .legacy
        default:
            return Self.defaultRoute
        }
    }

    /// The route a classifier viewer's BLAST Verify action takes now, read from the app's defaults.
    static var currentRoute: ClassifierBlastRoute {
        ClassifierBlastRouteSettings(defaults: .standard).route
    }
}
