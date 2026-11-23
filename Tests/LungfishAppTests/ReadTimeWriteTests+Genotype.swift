// ReadTimeWriteTests+Genotype.swift - A person's change in the genotype viewer writes nothing into the project (UX 6)
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import XCTest
@testable import LungfishApp
@testable import LungfishKit
import LungfishTestSupport

extension ReadTimeWriteTests {
    /// With a person's change in a genotype result, a switch away and back and the quit's flush, every file of a
    /// writable project keeps its bytes and its date, and the view sits in the store outside the project (VS U9, UX 6).
    @MainActor
    func testAGenotypeViewChangeASwitchAndAQuitWriteNothingIntoAWritableProject() async throws {
        try await assertGenotypeViewingWritesNothing(readOnlyBundle: false)
    }

    /// The same on a bundle the person cannot write, which the base's write past `isWritableFile` alone reached.
    @MainActor
    func testAGenotypeViewChangeASwitchAndAQuitWriteNothingIntoAReadOnlyBundle() async throws {
        try XCTSkipIf(getuid() == 0, "a read-only folder is writable to root")
        try await assertGenotypeViewingWritesNothing(readOnlyBundle: true)
    }

    @MainActor
    private func assertGenotypeViewingWritesNothing(readOnlyBundle: Bool) async throws {
        let root = try TestTempDirectory.make(prefix: "ReadTimeWriteGenotype")
        let project = try SafetyNetFiles.makeDirectory(root.appendingPathComponent("Views.lungfish", isDirectory: true))
        let genotype = try await ViewSwitchFixtures.build(try ViewSwitchFixtures.kind(named: "Genotype"), in: project)
        let other = try await ViewSwitchFixtures.build(try ViewSwitchFixtures.kind(named: "Status only"), in: project)
        let bundle = try XCTUnwrap(genotype.item.url)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: NSNumber(value: 0o755)], ofItemAtPath: bundle.path)
            TestTempDirectory.cleanup(root)
        }
        if readOnlyBundle {
            try FileManager.default.setAttributes([.posixPermissions: NSNumber(value: 0o555)], ofItemAtPath: bundle.path)
        }
        let storeRoot = root.appendingPathComponent("view-memory", isDirectory: true)
        // The digest comes before the store reads the project, so a write by that read shows too.
        let before = try ProjectDigest(of: project)
        let store = ViewMemoryStore(root: storeRoot)
        store.loadProject(at: project)

        let driver = GenotypeViewStateDriver()
        let harness = try ViewSwitchWindowHarness()
        harness.keepViews(in: store)
        harness.select(genotype.item)
        let shown = await waitUntil(budget: .lookup, pollInterval: .milliseconds(25)) { driver.isShown(in: harness) }
        XCTAssertTrue(shown, "the genotype result did not show")
        try driver.change(in: harness)
        let changed = try driver.read(in: harness)
        harness.select(other.item)
        let left = await waitUntil(budget: .lookup, pollInterval: .milliseconds(25)) { !driver.isShown(in: harness) }
        XCTAssertTrue(left, "the genotype result stayed after the switch")
        harness.select(genotype.item)
        let back = await waitUntil(budget: .lookup, pollInterval: .milliseconds(25)) { driver.isShown(in: harness) }
        XCTAssertTrue(back, "the genotype result did not show again")
        XCTAssertEqual(try driver.read(in: harness), changed, "the view came back from the store")
        store.flushSynchronously()
        harness.close()

        let after = try ProjectDigest(of: project)
        XCTAssertEqual(
            after.differences(from: before).map(\.summary), [], "viewing and switching write nothing into the project")
        XCTAssertEqual(after.entries, before.entries)
        let kept = try FileManager.default.subpathsOfDirectory(atPath: storeRoot.path)
        XCTAssertTrue(kept.contains { $0.hasSuffix(".json") }, "the view sits in the store: \(kept)")
    }
}
