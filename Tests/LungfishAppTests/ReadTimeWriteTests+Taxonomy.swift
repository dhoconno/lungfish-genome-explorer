// ReadTimeWriteTests+Taxonomy.swift - A person's change in the Kraken2, EsViritu and CZ ID viewers writes nothing into the project (UX 6)
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
@testable import LungfishApp
@testable import LungfishKit
import LungfishTestSupport

extension ReadTimeWriteTests {
    /// With a person's change in each of Kraken2, EsViritu and CZ ID (a filter, a sort, a pick, and a zoom and the
    /// Collections drawer or a collapsed assembly), a switch away and back and the quit's capture and flush, every file
    /// of the project keeps its bytes and its date, and each view sits in the store outside the project (VS A4, UX 6).
    @MainActor
    func testATaxonomyViewChangeASwitchAndAQuitWriteNothingIntoTheProject() async throws {
        let root = try TestTempDirectory.make(prefix: "ReadTimeWriteTaxonomy")
        // The App's Kraken2 and EsViritu tables key their column layouts by the result's path in the runner's
        // defaults when the route sets their result (Phase 3.1 ruling QA-RELEASE-LOOP, section 5).
        let hostDefaults = HostDefaultsRestorer(keysContaining: root.lastPathComponent)
        defer {
            hostDefaults.restore()
            TestTempDirectory.cleanup(root)
        }
        let project = try SafetyNetFiles.makeDirectory(root.appendingPathComponent("Views.lungfish", isDirectory: true))
        let drivers: [any ViewStateDriver] = [Kraken2ViewStateDriver(), EsVirituViewStateDriver(), CzIdViewStateDriver()]
        var fixtures: [ViewSwitchFixture] = []
        for driver in drivers {
            let fixture = try await ViewSwitchFixtures.build(try ViewSwitchFixtures.kind(named: driver.kind), in: project)
            try driver.prepare(fixture)
            fixtures.append(fixture)
        }
        let other = try await ViewSwitchFixtures.build(try ViewSwitchFixtures.kind(named: "Status only"), in: project)
        let storeRoot = root.appendingPathComponent("view-memory", isDirectory: true)
        // The digest comes before the store reads the project, so a write by that read shows too.
        let before = try ProjectDigest(of: project)
        let store = ViewMemoryStore(root: storeRoot)
        store.loadProject(at: project)

        let harness = try ViewSwitchWindowHarness()
        harness.keepViews(in: store)
        for (driver, fixture) in zip(drivers, fixtures) {
            harness.select(fixture.item)
            let shown = await waitUntil(budget: .lookup, pollInterval: .milliseconds(25)) { driver.isShown(in: harness) }
            XCTAssertTrue(shown, "\(driver.kind) did not show")
            try driver.change(in: harness)
            harness.select(other.item)
            let left = await waitUntil(budget: .lookup, pollInterval: .milliseconds(25)) { !driver.isShown(in: harness) }
            XCTAssertTrue(left, "\(driver.kind) stayed after the switch")
            harness.select(fixture.item)
            let back = await waitUntil(budget: .lookup, pollInterval: .milliseconds(25)) { driver.isShown(in: harness) }
            XCTAssertTrue(back, "\(driver.kind) did not show again")
        }
        harness.split.viewerController.surfaceHost.captureActive()
        store.flushSynchronously()
        harness.close()

        let after = try ProjectDigest(of: project)
        XCTAssertEqual(after.entries, before.entries, "viewing and switching write nothing into the project (UX 6)")
        let kept = try FileManager.default.subpathsOfDirectory(atPath: storeRoot.path).filter { $0.hasSuffix(".json") }
        XCTAssertGreaterThanOrEqual(kept.count, drivers.count, "each view sits in the store: \(kept)")
    }
}
