// InspectorDuplicateWorkflowRoute.swift - The hidden switch that picks the route of the duplicate workflows
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation

/// The route the Inspector's two duplicate workflows take, Mark Duplicates in Bundle Tracks and Create
/// Deduplicated Bundle (Phase 2.10 lane A54, decision C4 and the ruling on deviation 6).
enum InspectorDuplicateWorkflowRoute: String, Sendable, Equatable, CaseIterable {
    /// The route of the releases before the flip. The app runs `AlignmentDuplicateService` in process on a task
    /// the row's Cancel cancels. It stays behind this value for one release.
    case legacy
    /// The app runs `lungfish-cli bundle mark-duplicates` or `bundle deduplicate-alignments` with
    /// `--format json` on the L3 runner (`CLIAlignmentActionRunner`) and shows the command's events in the row.
    case cli
}

/// Reads the route from the defaults it is given, so a test passes its own suite and never touches the
/// user's defaults. One key serves both workflows, because the two leaves share their service, their
/// events and their cancel.
struct InspectorDuplicateWorkflowRouteSettings {
    /// The hidden `UserDefaults` key. It holds `cli` or `legacy`, or a Boolean that is true for the CLI
    /// route, for example `defaults write <app id> InspectorDuplicateWorkflowRoute cli`.
    static let defaultsKey = "InspectorDuplicateWorkflowRoute"

    /// The route when the key is unset or holds a value this reader does not know. The parity class
    /// `AlignmentWorkflowCLIGUIParityReplayTests` was green, so the lane's last commit flipped it to `.cli`.
    /// The in-process route stays behind `legacy` for one release, and the key goes with it in Phase 2.11.
    static let defaultRoute: InspectorDuplicateWorkflowRoute = .cli

    let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// The route the key asks for, or ``defaultRoute``.
    func route() -> InspectorDuplicateWorkflowRoute {
        switch defaults.object(forKey: Self.defaultsKey) {
        case let name as String:
            return InspectorDuplicateWorkflowRoute(rawValue: name.lowercased()) ?? Self.defaultRoute
        case let usesCLI as Bool:
            return usesCLI ? .cli : .legacy
        default:
            return Self.defaultRoute
        }
    }
}
