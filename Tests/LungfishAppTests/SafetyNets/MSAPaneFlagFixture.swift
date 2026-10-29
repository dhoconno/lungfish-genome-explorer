// MSAPaneFlagFixture.swift - The machine's saved MSA pane flag, written closed for one test of a net
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// The MSA bottom pane opens or stays closed by the key `msaBottomPane.isOpen`
// of the defaults its viewer was given (`MSABottomPaneView.restorePersistedState`).
// The viewer gave it `UserDefaults.standard`, which in a test process is the
// domain `com.apple.dt.xctest.tool`. That domain stays on disk between runs, and
// a test that closed a pane through a viewer left 0 in it (architecture review
// NAOMGS-ARCH, finding R6). With 0 the alignment row of the routing table
// waited its full 311 seconds for a pane that never opened, and every switch to
// an alignment in the view-switch matrix read "alignment bottom pane closed".
//
// A net that opens an alignment writes the flag closed before each test, which
// is the worst state a machine can hold, and puts back what it found. The net
// must pass whatever the machine holds.

import Foundation
@testable import LungfishApp

@MainActor
final class MSAPaneFlagFixture {
    private static let key = MSABottomPaneView.DefaultsKey.isOpen

    private let saved: Any?

    /// Writes the machine's saved pane flag as `open` and remembers what was there.
    init(machineFlag open: Bool) {
        saved = UserDefaults.standard.object(forKey: Self.key)
        UserDefaults.standard.set(open, forKey: Self.key)
    }

    /// Puts the machine's saved pane flag back as the fixture found it.
    func restore() {
        if let saved {
            UserDefaults.standard.set(saved, forKey: Self.key)
        } else {
            UserDefaults.standard.removeObject(forKey: Self.key)
        }
    }
}
