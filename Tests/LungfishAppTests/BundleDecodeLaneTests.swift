// BundleDecodeLaneTests.swift - Quick opens of large bundles decode one at a time
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import XCTest
@testable import LungfishApp
@testable import LungfishCore
import LungfishTestSupport

/// `JSONDecoder` cannot be cancelled, so the decode of a bundle the user has
/// left runs to its end. Quick clicks through large references ran their
/// decodes side by side, each above 2 GB at its peak. Large decodes now wait
/// for one lane, and a waiting decode whose open was cancelled never starts.
@MainActor
final class BundleDecodeLaneTests: XCTestCase {
    override func tearDown() async throws {
        BundleLoadProbe.install(nil)
        BundleDecodeLane.overrideLargeFileBytes(nil)
        try await super.tearDown()
    }

    func testQuickOpensOfLargeBundlesDecodeOneAtATime() async throws {
        let root = try TestTempDirectory.make(prefix: "BundleDecodeLane")
        defer { TestTempDirectory.cleanup(root) }
        let bundles = try ["A", "B", "C"].map {
            try MappingRoutingFixture.makeReferenceBundle(
                name: "Bundle \($0)", chromosomes: [.init(name: "chr\($0)1", length: 100)], in: root
            )
        }
        // Every manifest counts as large, so each open waits for the lane.
        BundleDecodeLane.overrideLargeFileBytes(0)
        let gate = BundleDecodeGate()
        defer { gate.release() }
        let decodes = BundleDecodeLog()
        decodes.install(offMainOnly: true, holding: bundles[0], on: gate)

        let split = MainSplitViewController()
        split.loadViewIfNeeded()
        split.displayReferenceBundleViewportFromSidebar(at: bundles[0])
        await waitUntil(timeout: .seconds(30)) { decodes.count(.bundleManifest) == 1 }
        split.displayReferenceBundleViewportFromSidebar(at: bundles[1])
        await waitUntil(timeout: .seconds(30)) { BundleDecodeLane.waitingCount == 1 }
        split.displayReferenceBundleViewportFromSidebar(at: bundles[2])
        let bothWait = await waitUntil(timeout: .seconds(30)) { BundleDecodeLane.waitingCount == 2 }
        XCTAssertTrue(bothWait, "the later opens did not wait for the running decode")
        XCTAssertEqual(decodes.count(.bundleManifest), 1, "a decode ran beside the held one")

        gate.release()
        let opened = await waitUntil(timeout: .seconds(30)) {
            split.viewerController.referenceBundleViewportController?
                .testEmbeddedViewerController.currentReferenceBundle?.url.standardizedFileURL
                == bundles[2].standardizedFileURL
        }
        XCTAssertTrue(opened, "the last selection never opened")
        XCTAssertEqual(
            split.viewerController.referenceBundleViewportController?.testDisplayedSequenceNames, ["chrC1"]
        )
        // The held decode of A ran to its end and its open dropped the result.
        // The open of B was cancelled while it waited, so B never decoded.
        XCTAssertEqual(
            decodes.paths(.bundleManifest),
            [bundles[0], bundles[2]].map(\.standardizedFileURL.path)
        )
        let drained = await waitUntil(timeout: .seconds(30)) { BundleDecodeLane.waitingCount == 0 }
        XCTAssertTrue(drained, "a decode still waits for the lane")
    }

    func testSmallBundleOpensWhileALargeDecodeIsHeld() async throws {
        let root = try TestTempDirectory.make(prefix: "BundleDecodeLaneSmall")
        defer { TestTempDirectory.cleanup(root) }
        let large = try MappingRoutingFixture.makeReferenceBundle(
            name: "Large",
            chromosomes: (1...40).map { MappingRoutingFixture.Chromosome(name: "chr\($0)", length: 100) },
            in: root
        )
        let small = try MappingRoutingFixture.makeReferenceBundle(
            name: "Small", chromosomes: [.init(name: "chrS1", length: 100)], in: root
        )
        let smallManifestBytes = try XCTUnwrap(
            small.appendingPathComponent(BundleManifest.filename)
                .resourceValues(forKeys: [.fileSizeKey]).fileSize
        )
        // The large manifest is over the line and the small one is not.
        BundleDecodeLane.overrideLargeFileBytes(Int64(smallManifestBytes))
        let gate = BundleDecodeGate()
        defer { gate.release() }
        let decodes = BundleDecodeLog()
        decodes.install(offMainOnly: true, holding: large, on: gate)

        let split = MainSplitViewController()
        split.loadViewIfNeeded()
        split.displayReferenceBundleViewportFromSidebar(at: large)
        let largeOpen = split.bundleOpenTask
        await waitUntil(timeout: .seconds(30)) { decodes.count(.bundleManifest) == 1 }
        split.displayReferenceBundleViewportFromSidebar(at: small)

        let showsSmall = await waitUntil(timeout: .seconds(30)) {
            split.viewerController.referenceBundleViewportController?.testDisplayedSequenceNames == ["chrS1"]
        }
        XCTAssertTrue(showsSmall, "the small bundle waited behind the held large decode")
        XCTAssertEqual(BundleDecodeLane.waitingCount, 0)
        gate.release()
        await largeOpen?.value
    }
}
