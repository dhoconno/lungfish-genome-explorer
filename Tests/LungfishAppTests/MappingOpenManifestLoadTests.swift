// MappingOpenManifestLoadTests.swift - A mapping opens with one decode of each large file, off the main thread
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import XCTest
@testable import LungfishApp
@testable import LungfishCore
@testable import LungfishWorkflow
import LungfishTestSupport

/// A mapping onto a large reference carries a copy of that reference, whose
/// manifest the open decoded five times on the main thread: for the route,
/// the Provenance sources, the embedded viewer, the row refresh and the BAM
/// metadata context. The mapping result, which lists every reference sequence,
/// was decoded on the main thread too.
@MainActor
final class MappingOpenManifestLoadTests: XCTestCase {
    override func tearDown() async throws {
        BundleLoadProbe.install(nil)
        try await super.tearDown()
    }

    func testMappingOpenDecodesViewerManifestOnceOffMain() async throws {
        let root = try TestTempDirectory.make(prefix: "MappingOpenManifestLoad")
        defer { TestTempDirectory.cleanup(root) }
        let bundleURL = try MappingRoutingFixture.makeReferenceBundle(
            name: "Mapped Once",
            chromosomes: [.init(name: "chr1", length: 100)],
            in: root
        )
        try MappingRoutingFixture.addSingleSampleAlignment(
            to: bundleURL, sampleID: "S1", includeReadGroup: false, includeChromosomeStats: true
        )
        let resultURL = root.appendingPathComponent("mapping-result", isDirectory: true)
        try FileManager.default.createDirectory(at: resultURL, withIntermediateDirectories: true)
        try MappingRoutingFixture.makeMappingResult(
            resultDirectory: resultURL, viewerBundleURL: bundleURL
        ).save(to: resultURL)
        let decodes = BundleDecodeLog()
        decodes.install(offMainOnly: true)

        let split = MainSplitViewController()
        split.loadViewIfNeeded()
        split.displayMappingAnalysisFromSidebar(at: resultURL)

        let opened = await waitUntil(timeout: .seconds(30)) {
            guard let viewport = split.viewerController.referenceBundleViewportController else { return false }
            return viewport.testContigTableView.displayedRows.contains { $0.sampleID == "S1" }
                && viewport.testEmbeddedViewerController.currentReferenceBundle != nil
        }
        XCTAssertTrue(opened, "the mapping viewport never showed its sample rows and its viewer")
        XCTAssertEqual(decodes.count(.mappingResult), 1)
        XCTAssertEqual(decodes.count(.bundleManifest), 1)
    }
}
