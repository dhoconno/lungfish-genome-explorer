// ReadTimeWriteTests+Datasets.swift - A person's change in the FASTQ, assembly and FASTA collection views writes nothing into the project (UX 6)
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
@testable import LungfishApp
@testable import LungfishKit
import LungfishTestSupport

extension ReadTimeWriteTests {
    /// With a person's change in each kind, a switch away and back and the quit's capture and flush, every file of the
    /// project keeps its bytes and its date, and each view sits in the store outside the project (VS A4, UX 6).
    @MainActor
    func testDatasetViewChangesASwitchAndAQuitWriteNothingIntoTheProject() async throws {
        let drivers: [any ViewStateDriver] = [
            FASTQViewStateDriver(), AssemblyViewStateDriver(), FASTACollectionViewStateDriver(),
        ]
        for driver in drivers {
            let root = try TestTempDirectory.make(prefix: "ReadTimeWriteDatasets")
            defer { TestTempDirectory.cleanup(root) }
            let project = try SafetyNetFiles.makeDirectory(root.appendingPathComponent("Views.lungfish", isDirectory: true))
            let fixture = try await ViewSwitchFixtures.build(try ViewSwitchFixtures.kind(named: driver.kind), in: project)
            let other = try await ViewSwitchFixtures.build(try ViewSwitchFixtures.kind(named: "Status only"), in: project)
            // The files a finished run leaves, such as the contigs index, which the catalog would otherwise write.
            try driver.prepare(fixture)
            let storeRoot = root.appendingPathComponent("view-memory", isDirectory: true)
            // The digest comes before the store reads the project, so a write by that read shows too.
            let before = try ProjectDigest(of: project)
            let store = ViewMemoryStore(root: storeRoot)
            store.loadProject(at: project)

            let harness = try ViewSwitchWindowHarness()
            harness.keepViews(in: store)
            harness.select(fixture.item)
            let shown = await waitUntil(budget: .lookup, pollInterval: .milliseconds(25)) { driver.isShown(in: harness) }
            XCTAssertTrue(shown, "\(driver.kind) did not show")
            await driver.settle(in: harness)
            try await driver.change(in: harness)
            await driver.settle(in: harness)
            harness.select(other.item)
            let left = await waitUntil(budget: .lookup, pollInterval: .milliseconds(25)) { !driver.isShown(in: harness) }
            XCTAssertTrue(left, "\(driver.kind) stayed after the switch")
            harness.select(fixture.item)
            let back = await waitUntil(budget: .lookup, pollInterval: .milliseconds(25)) { driver.isShown(in: harness) }
            XCTAssertTrue(back, "\(driver.kind) did not show again")
            await driver.settle(in: harness)
            harness.split.viewerController.surfaceHost.captureActive()
            store.flushSynchronously()
            harness.close()

            let after = try ProjectDigest(of: project)
            XCTAssertEqual(after.entries, before.entries, "\(driver.kind): viewing and switching write nothing into the project (UX 6)")
            let kept = try FileManager.default.subpathsOfDirectory(atPath: storeRoot.path)
            XCTAssertTrue(kept.contains { $0.hasSuffix(".json") }, "\(driver.kind): the view sits in the store: \(kept)")
        }
    }
}
