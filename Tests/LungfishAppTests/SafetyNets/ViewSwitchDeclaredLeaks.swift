// ViewSwitchDeclaredLeaks.swift - What the view switch leaves behind today
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// The view-switch tests compare what a window shows after a switch with what
// the kind shows when it is selected alone. A switch that differs today is
// declared here with the lines it differs by and a backlog id, so the tests
// pass at the base and fail when the leak changes. A fix that removes a leak
// removes its entry in the same change, because the test then fails on the
// pair until it does. A ViewportHost migration may change only the entries of
// its own kind.
//
// Each fault line is "+ line" for what the switch shows and the kind alone
// does not, or "- line" for what the kind alone shows and the switch does not.
// A path under another kind's folder reads `../<folder>/...`.

import Foundation

/// Switches from one kind that differ from their target kinds shown alone by
/// the same lines.
struct DeclaredViewSwitchLeak: Sendable {
    /// The kind shown before the switch, or ``freshWindow`` for a kind
    /// selected in a window that showed nothing yet.
    let from: String
    /// The kinds selected, each one switch of the walk.
    let to: [String]
    /// The backlog rows that hold the leak, `NET-` ids being the ones this
    /// lane proposes (lane report, declared-leak rows).
    let backlog: String
    /// The fault lines, in reading order.
    let faults: [String]

    static let freshWindow = "fresh window"
}


enum ViewSwitchDeclaredLeaks {
    /// Parts of the 3a acceptance row this net cannot hold at its base.
    ///
    /// The old-token refusal needs the ViewportHost token, which lane HOST
    /// adds and tests in Tests/LungfishKitTests against a stub viewport.
    static let gaps = [
        "A commit from an old display token is refused: no ViewportHost token exists at this base (lane HOST)",
    ]

    /// Every declared leak of the matrix and of the fresh-window pass, in the
    /// two table files named after the kinds the switches start from.
    ///
    /// The walk is one fixed circuit, so a leak that outlives one switch, as
    /// the MHC viewport does, is seen on the later switches of the circuit as
    /// well, and a fix to one route can change the entries of several pairs.
    static let all: [DeclaredViewSwitchLeak] = fromResultKinds + fromOtherKinds

    static func leak(_ from: String, to: [String], _ backlog: String, _ faults: [String]) -> DeclaredViewSwitchLeak {
        DeclaredViewSwitchLeak(from: from, to: to, backlog: backlog, faults: faults)
    }

    static func faults(from: String, to: String) -> [String] {
        all.first { $0.from == from && $0.to.contains(to) }?.faults ?? []
    }
}
