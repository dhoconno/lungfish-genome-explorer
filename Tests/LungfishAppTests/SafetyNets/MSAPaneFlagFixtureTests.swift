// MSAPaneFlagFixtureTests.swift - What the pane flag fixture puts back and what the app displays on
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// The routing table and the view-switch matrix write the machine's saved MSA
// pane flag closed and put it back (MSAPaneFlagFixture), and they hand the
// alignments their viewer builds a defaults suite through
// `ViewerViewController.multipleSequenceAlignmentDefaults`. These tests pin the
// two facts that make that safe. The fixture puts the machine's flag back as it
// found it, down to an absent key, and the app itself keeps the standard
// defaults for every alignment it displays.
//
// Each test runs the fixture on a suite it owns, never on the machine's key. The
// unit tier's parallel workers share that key, and one test read nil after its
// restore when another worker removed the key (unit tier at 327052394).

import AppKit
import XCTest
import LungfishIO
import LungfishTestSupport
@testable import LungfishApp

@MainActor
final class MSAPaneFlagFixtureTests: XCTestCase {
    private let key = MSABottomPaneView.DefaultsKey.isOpen

    private func makeSuite() -> UserDefaults {
        makeTestDefaultsSuite(prefix: "MSAPaneFlagFixtureTests").defaults
    }

    func testRestoreLeavesNoKeyWhenTheMachineHeldNone() {
        let defaults = makeSuite()
        let fixture = MSAPaneFlagFixture(machineFlag: false, defaults: defaults)
        XCTAssertEqual(defaults.object(forKey: key) as? Bool, false, "the fixture writes the flag closed")
        fixture.restore()
        XCTAssertNil(
            defaults.object(forKey: key),
            "a machine that held no flag must hold none after the restore"
        )
    }

    func testRestorePutsBackTrue() {
        let defaults = makeSuite()
        defaults.set(true, forKey: key)
        let fixture = MSAPaneFlagFixture(machineFlag: false, defaults: defaults)
        XCTAssertEqual(defaults.object(forKey: key) as? Bool, false, "the fixture writes the flag closed")
        fixture.restore()
        XCTAssertEqual(defaults.object(forKey: key) as? Bool, true)
    }

    func testRestorePutsBackFalse() {
        let defaults = makeSuite()
        defaults.set(false, forKey: key)
        let fixture = MSAPaneFlagFixture(machineFlag: true, defaults: defaults)
        XCTAssertEqual(defaults.object(forKey: key) as? Bool, true, "the fixture writes the flag it is given")
        fixture.restore()
        XCTAssertEqual(defaults.object(forKey: key) as? Bool, false)
    }

    /// The hook the nets use must leave the app on the standard defaults. A
    /// plain display persists nothing, so this test leaves no key behind.
    func testAnAlignmentTheAppDisplaysKeepsTheStandardDefaults() async throws {
        XCTAssertTrue(
            ViewerViewController.multipleSequenceAlignmentDefaults === UserDefaults.standard,
            "the app never sets the alignment defaults, so they stay the standard defaults"
        )

        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("standard.fa")
        try ">a\nACGTAC\n>b\nACGAAC\n>c\nTCGAAC\n".write(to: source, atomically: true, encoding: .utf8)
        let bundleURL = directory.appendingPathComponent("standard.lungfishmsa")
        _ = try MultipleSequenceAlignmentBundle.importAlignment(from: source, to: bundleURL)

        let viewer = ViewerViewController()
        viewer.loadViewIfNeeded()
        try await viewer.displayMultipleSequenceAlignmentBundle(at: bundleURL)
        let msa = try XCTUnwrap(viewer.multipleSequenceAlignmentViewController)
        XCTAssertTrue(
            msa.gutterWidthDefaults === UserDefaults.standard,
            "an alignment the app displays keeps its pane state in the standard defaults"
        )
    }
}
