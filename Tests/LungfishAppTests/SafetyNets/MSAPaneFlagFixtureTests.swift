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
// Each test writes the machine's flag, because that is what the fixture does.
// The class saves the key before every test and puts it back after it, so a
// test that fails halfway leaves the machine as it found it.

import AppKit
import XCTest
import LungfishIO
@testable import LungfishApp

@MainActor
final class MSAPaneFlagFixtureTests: XCTestCase {
    private let key = MSABottomPaneView.DefaultsKey.isOpen
    private var machineFlagBeforeTheTest: Any?

    override func setUpWithError() throws {
        try super.setUpWithError()
        machineFlagBeforeTheTest = UserDefaults.standard.object(forKey: key)
    }

    override func tearDownWithError() throws {
        if let machineFlagBeforeTheTest {
            UserDefaults.standard.set(machineFlagBeforeTheTest, forKey: key)
        } else {
            UserDefaults.standard.removeObject(forKey: key)
        }
        machineFlagBeforeTheTest = nil
        try super.tearDownWithError()
    }

    func testRestoreLeavesNoKeyWhenTheMachineHeldNone() {
        UserDefaults.standard.removeObject(forKey: key)
        let fixture = MSAPaneFlagFixture(machineFlag: false)
        XCTAssertEqual(UserDefaults.standard.object(forKey: key) as? Bool, false, "the fixture writes the flag closed")
        fixture.restore()
        XCTAssertNil(
            UserDefaults.standard.object(forKey: key),
            "a machine that held no flag must hold none after the restore"
        )
    }

    func testRestorePutsBackTrue() {
        UserDefaults.standard.set(true, forKey: key)
        let fixture = MSAPaneFlagFixture(machineFlag: false)
        XCTAssertEqual(UserDefaults.standard.object(forKey: key) as? Bool, false, "the fixture writes the flag closed")
        fixture.restore()
        XCTAssertEqual(UserDefaults.standard.object(forKey: key) as? Bool, true)
    }

    func testRestorePutsBackFalse() {
        UserDefaults.standard.set(false, forKey: key)
        let fixture = MSAPaneFlagFixture(machineFlag: true)
        XCTAssertEqual(UserDefaults.standard.object(forKey: key) as? Bool, true, "the fixture writes the flag it is given")
        fixture.restore()
        XCTAssertEqual(UserDefaults.standard.object(forKey: key) as? Bool, false)
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
