// ReadTimeWriteTests+TwelveS.swift - A person's change in the 12S viewer writes nothing into the project (UX 6)
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
@testable import LungfishApp
@testable import LungfishKit
import LungfishTestSupport

extension ReadTimeWriteTests {
    /// With a person's change in 12S, a switch away and back and the quit's capture and flush, every file of the
    /// project keeps its bytes and its date, and the view sits in the store outside the project (VS A4, UX 6).
    @MainActor
    func testATwelveSViewChangeASwitchAndAQuitWriteNothingIntoTheProject() async throws {
        let root = try TestTempDirectory.make(prefix: "ReadTimeWriteTwelveS")
        defer { TestTempDirectory.cleanup(root) }
        let project = try SafetyNetFiles.makeDirectory(root.appendingPathComponent("Views.lungfish", isDirectory: true))
        let twelveS = try await ViewSwitchFixtures.build(try ViewSwitchFixtures.kind(named: "12S"), in: project)
        let other = try await ViewSwitchFixtures.build(try ViewSwitchFixtures.kind(named: "Status only"), in: project)
        let storeRoot = root.appendingPathComponent("view-memory", isDirectory: true)
        let store = ViewMemoryStore(root: storeRoot)
        store.loadProject(at: project)
        let before = try ProjectDigest(of: project)

        let driver = TwelveSViewStateDriver()
        let harness = try ViewSwitchWindowHarness()
        harness.keepViews(in: store)
        harness.select(twelveS.item)
        let shown = await waitUntil(budget: .lookup, pollInterval: .milliseconds(25)) { driver.isShown(in: harness) }
        XCTAssertTrue(shown, "12S did not show")
        try driver.change(in: harness)
        harness.select(other.item)
        let left = await waitUntil(budget: .lookup, pollInterval: .milliseconds(25)) { !driver.isShown(in: harness) }
        XCTAssertTrue(left, "12S stayed after the switch")
        harness.select(twelveS.item)
        let back = await waitUntil(budget: .lookup, pollInterval: .milliseconds(25)) { driver.isShown(in: harness) }
        XCTAssertTrue(back, "12S did not show again")
        harness.split.viewerController.surfaceHost.captureActive()
        store.flushSynchronously()
        harness.close()

        let after = try ProjectDigest(of: project)
        XCTAssertEqual(after.entries, before.entries, "viewing and switching write nothing into the project (UX 6)")
        let kept = try FileManager.default.subpathsOfDirectory(atPath: storeRoot.path)
        XCTAssertTrue(kept.contains { $0.hasSuffix(".json") || !$0.contains(".") }, "the view sits in the store: \(kept)")
    }
}
