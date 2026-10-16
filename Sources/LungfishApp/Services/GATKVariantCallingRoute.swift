// GATKVariantCallingRoute.swift - The route the Call Variants dialog's GATK row takes, and its hidden key
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation

/// The route of the Call Variants dialog's GATK HaplotypeCaller row (Phase 2.11 lane A50 M3, decisions
/// C4 and C14 of Phase 2.10 and K3 of Phase 2.11).
enum GATKVariantCallingRoute: String, Sendable, Equatable, CaseIterable {
    /// The route before lane A50, kept for one release as the escape the hidden key names (C4). The app
    /// runs `GATKPipelineExecutor` and `GATKBundleVariantAttachmentService` in this process. It leaves in
    /// 2.12 with its key (K3).
    case legacy
    /// `lungfish-cli variants call --caller gatk`, run on `CLIVariantCallingRunner` through the app's
    /// transport, the way the dialog's other callers run.
    case cli
}

/// Reads the route from the defaults it is given, so a test passes its own suite and never touches the
/// user's defaults (ARCH memo N4).
struct GATKVariantCallingRouteSettings {
    /// The hidden key. It holds `cli` or `legacy`, or a Boolean that is true for the CLI route, for
    /// example `defaults write <app id> GATKVariantCallingRoute legacy`.
    static let defaultsKey = "GATKVariantCallingRoute"
    /// The route of a key that is unset or holds a value this reader does not know. Lane A50's last
    /// commit set it to `.cli` (ARCH check 7), once side A against side C held only declared differences
    /// (GATKVariantCallingCLIGUIParityReplayTests). `defaults write <app id> GATKVariantCallingRoute
    /// legacy` keeps the in-process route for one release (C4).
    static let defaultRoute: GATKVariantCallingRoute = .cli

    let defaults: UserDefaults

    var route: GATKVariantCallingRoute {
        switch defaults.object(forKey: Self.defaultsKey) {
        case let name as String:
            return GATKVariantCallingRoute(rawValue: name.lowercased()) ?? Self.defaultRoute
        case let usesCLI as Bool:
            return usesCLI ? .cli : .legacy
        default:
            return Self.defaultRoute
        }
    }

    /// The route the GATK row takes now, read from the app's defaults.
    static var currentRoute: GATKVariantCallingRoute {
        GATKVariantCallingRouteSettings(defaults: .standard).route
    }
}
