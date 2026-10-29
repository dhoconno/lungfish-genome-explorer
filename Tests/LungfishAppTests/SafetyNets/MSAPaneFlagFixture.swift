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
// is the worst state a machine can hold, and puts back what it found. It also
// gives every alignment the viewer builds a defaults suite of its own
// (`ViewerViewController.multipleSequenceAlignmentDefaults`), so the net passes
// whatever the machine holds and writes nothing the next run could read.

import Foundation
import XCTest
@testable import LungfishApp
import LungfishTestSupport

@MainActor
final class MSAPaneFlagFixture {
    private static let key = MSABottomPaneView.DefaultsKey.isOpen

    private let saved: Any?
    private let displayDefaults = TestDefaultsSuite(prefix: "MSAPaneFlagFixture")

    /// Writes the machine's saved pane flag as `open`, remembers what was there
    /// and gives the alignments the viewer builds a suite of their own.
    init(machineFlag open: Bool) {
        saved = UserDefaults.standard.object(forKey: Self.key)
        UserDefaults.standard.set(open, forKey: Self.key)
        ViewerViewController.multipleSequenceAlignmentDefaults = displayDefaults.defaults
    }

    /// Ends the suite and puts the machine's saved pane flag back as the fixture found it.
    func restore() {
        ViewerViewController.multipleSequenceAlignmentDefaults = .standard
        displayDefaults.tearDown()
        if let saved {
            UserDefaults.standard.set(saved, forKey: Self.key)
        } else {
            UserDefaults.standard.removeObject(forKey: Self.key)
        }
    }
}

extension XCTestCase {
    /// For a test that opens or closes the pane of an alignment it displays
    /// through a viewer. The pane's open flag then goes to a suite that the
    /// test owns and removes, never to the machine's standard defaults.
    @MainActor
    func isolateAlignmentPaneDefaults() {
        let suite = makeTestDefaultsSuite(prefix: "AlignmentPaneDefaults")
        ViewerViewController.multipleSequenceAlignmentDefaults = suite.defaults
        addTeardownBlock {
            await MainActor.run { ViewerViewController.multipleSequenceAlignmentDefaults = .standard }
        }
    }
}
