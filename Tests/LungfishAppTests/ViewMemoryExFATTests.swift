// ViewMemoryExFATTests.swift - A project on ExFAT keeps a reference view across a relaunch and gains no byte
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// View-state lane VS-PROOF, item 2 (exit check X2). Most external SSDs ship formatted ExFAT
// (docs/contracts/EXTERNAL-VOLUMES.md), where an extended attribute lands in a `._name` sidecar and a modification time
// is rounded to 10 ms. A project on such a volume keeps its reference view in the store on this Mac across a relaunch
// of the window on the same store, and the project gains no byte and no `._` file. The store stays under the test's
// own folder on the internal disk (QA 6). `scripts/testing/exfat-tests.sh ViewMemoryExFAT` runs it on a fresh ExFAT
// image, and with no image root it skips as every ExFAT test does.

import AppKit
import Darwin
import XCTest
@testable import LungfishApp
@testable import LungfishKit
import LungfishTestSupport

@MainActor
final class ViewMemoryExFATTests: XCTestCase {
    /// The test's folder on the ExFAT volume.
    private var volumeFolder: URL!
    /// The test's folder on the internal disk, which holds the store.
    private var scratch: URL!

    override func setUp() async throws {
        try await super.setUp()
        guard let volume = ProcessInfo.processInfo.environment["LUNGFISH_EXFAT_TEST_ROOT"], !volume.isEmpty else {
            throw XCTSkip("Set LUNGFISH_EXFAT_TEST_ROOT to an ExFAT volume root to run this test.")
        }
        var information = statfs()
        guard statfs(volume, &information) == 0 else {
            throw XCTSkip("LUNGFISH_EXFAT_TEST_ROOT does not name a mounted volume.")
        }
        let typeName = withUnsafeBytes(of: information.f_fstypename) { bytes in
            String(decoding: bytes.prefix { $0 != 0 }, as: UTF8.self)
        }
        guard typeName == "exfat" else {
            throw XCTSkip("LUNGFISH_EXFAT_TEST_ROOT is \(typeName), not exfat.")
        }
        let folder = URL(fileURLWithPath: volume, isDirectory: true)
            .appendingPathComponent(".lge-view-memory-exfat-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        volumeFolder = folder
        scratch = try TestTempDirectory.make(prefix: "ViewMemoryExFAT")
    }

    override func tearDown() async throws {
        if let volumeFolder { try? FileManager.default.removeItem(at: volumeFolder) }
        if let scratch { TestTempDirectory.cleanup(scratch) }
        volumeFolder = nil
        scratch = nil
        try await super.tearDown()
    }

    /// The reference's place, look and Focus mode, changed as a person does, come back after the window closes and a
    /// new window opens on a new store over the same folder, as after a quit and a relaunch (VS S1). Every file of the
    /// project on ExFAT keeps its bytes and its date, and no `._` sidecar appears.
    func testAProjectOnExFATKeepsAReferenceViewThroughARelaunchAndGainsNoByteAndNoAppleDoubleFile() async throws {
        let project = try SafetyNetFiles.makeDirectory(volumeFolder.appendingPathComponent("Views.lungfish", isDirectory: true))
        let driver = ReferenceViewportViewStateDriver(route: .reference)
        let fixture = try await ViewSwitchFixtures.build(try ViewSwitchFixtures.kind(named: driver.kind), in: project)
        try driver.prepare(fixture)
        let storeRoot = scratch.appendingPathComponent("view-memory", isDirectory: true)
        // The digest comes before the store reads the project, so a write by that read shows too.
        let before = try ProjectDigest(of: project)
        let sidecarsBefore = Self.appleDoubleFiles(in: project)

        let changed: [String]
        do {
            let store = ViewMemoryStore(root: storeRoot)
            store.loadProject(at: project)
            let harness = try ViewSwitchWindowHarness()
            harness.keepViews(in: store)
            try await show(fixture, in: harness, driver: driver)
            let start = try driver.read(in: harness)
            try await driver.change(in: harness)
            await driver.settle(in: harness)
            changed = try driver.read(in: harness)
            XCTAssertNotEqual(changed, start, "the change shows in the view's controls")
            // The quit keeps the installed view with no switch and writes the store (VS S1).
            harness.split.viewerController.surfaceHost.captureActive()
            store.flushSynchronously()
            harness.close()
        }

        let relaunched = ViewMemoryStore(root: storeRoot)
        relaunched.loadProject(at: project)
        let harness = try ViewSwitchWindowHarness()
        harness.keepViews(in: relaunched)
        try await show(fixture, in: harness, driver: driver)
        XCTAssertEqual(try driver.read(in: harness), changed, "the view as left before the relaunch")
        XCTAssertNil(driver.resetLineWords(in: harness), "nothing was lost, so no line shows")
        harness.split.viewerController.surfaceHost.captureActive()
        relaunched.flushSynchronously()
        harness.close()

        XCTAssertEqual(
            try ProjectDigest(of: project).differences(from: before).map(\.summary), [],
            "viewing, the relaunch and the store's flush write nothing into a project on ExFAT"
        )
        XCTAssertEqual(Self.appleDoubleFiles(in: project), sidecarsBefore, "the project gained a `._` sidecar on ExFAT")
        let kept = try FileManager.default.subpathsOfDirectory(atPath: storeRoot.path).filter {
            $0.hasSuffix(".json") && !URL(fileURLWithPath: $0).lastPathComponent.hasPrefix(".")
        }
        XCTAssertFalse(kept.isEmpty, "the view sits in the store on the internal disk: \(kept)")
    }

    private func show(_ fixture: ViewSwitchFixture, in harness: ViewSwitchWindowHarness, driver: any ViewStateDriver) async throws {
        harness.select(fixture.item)
        let shown = await waitUntil(budget: .lookup, pollInterval: .milliseconds(25)) { driver.isShown(in: harness) }
        XCTAssertTrue(shown, "\(driver.kind) did not show")
        await driver.settle(in: harness)
    }

    /// The `._` sidecars under `root`, relative to it, in path order.
    private static func appleDoubleFiles(in root: URL) -> [String] {
        let paths = FileManager.default.enumerator(atPath: root.path)?.compactMap { $0 as? String } ?? []
        return paths.filter { URL(fileURLWithPath: $0).lastPathComponent.hasPrefix("._") }.sorted()
    }
}
