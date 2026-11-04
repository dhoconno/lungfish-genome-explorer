// ReferenceBundleNumbersConformanceTests.swift - What a mapping result on a real BAM shows, measured by samtools (Phase 3.2 lane REFMAP)
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// The viewport measures a track that names no source of its own with the managed samtools, so these tests need the real
// tool. The name keeps them out of the unit tier. They skip without samtools and fail there under `LUNGFISH_REQUIRE_TOOLS=1`.
// The literals were read at the base, before the viewport moved onto the surface host.

import AppKit
import LungfishTestSupport
import XCTest
@testable import LungfishApp
@testable import LungfishCore
@testable import LungfishIO
@testable import LungfishWorkflow

@MainActor
final class ReferenceBundleNumbersConformanceTests: XCTestCase {
    private var root: URL!
    private var hostDefaults: HostDefaultsRestorer!

    override func setUpWithError() throws {
        isolateAlignmentPaneDefaults()
    }

    override func setUp() async throws {
        try await super.setUp()
        _ = try await ToolAvailability.require("samtools", environment: "samtools")
        root = try TestTempDirectory.make(prefix: "ReferenceNumbers")
        hostDefaults = HostDefaultsRestorer(keysContaining: root.lastPathComponent)
    }

    override func tearDown() async throws {
        hostDefaults?.restore()
        if let root { TestTempDirectory.cleanup(root) }
        try await super.tearDown()
    }

    func testTheMeasuredRowOfARealBAMIsWhatTheViewportShows() async throws {
        let harness = try ViewSwitchWindowHarness()
        defer { harness.close() }
        let viewer = harness.split.viewerController!
        let (result, _, _) = try RoutingSafetyNetFixtures.mappingAnalysis(in: root.appendingPathComponent("Analyses", isDirectory: true))

        harness.split.displayMappingAnalysisFromSidebar(at: result)
        await harness.split.bundleOpenTask?.value
        let settled = await waitUntil(budget: .lookup) {
            guard let viewport = viewer.referenceBundleViewportController else { return false }
            return viewport.mappingRowsRefreshTask == nil && !viewport.testContigTableView.displayedRows.isEmpty
        }
        let viewport = try XCTUnwrap(viewer.referenceBundleViewportController)
        XCTAssertTrue(settled, "the viewport never measured its row")
        XCTAssertEqual(viewport.testSummaryText, "minimap2 Mapping — 200 / 200 reads mapped (100.0%)")
        XCTAssertEqual(viewport.testContigTableView.displayedRows.count, 1)
        let row = try XCTUnwrap(viewport.testContigTableView.displayedRows.first)
        XCTAssertEqual(row.sampleID, "sample")
        XCTAssertEqual(row.alignmentTrackID, "sample-alignment")
        XCTAssertEqual(row.contigName, "MT192765.1")
        XCTAssertEqual(row.contigLength, 29_829)
        XCTAssertEqual(row.mappedReads, 197)
        XCTAssertEqual(row.mappedReadPercent, 98.5, accuracy: 0.0001)
        XCTAssertEqual(row.meanDepth, 0.918603, accuracy: 0.000001)
        XCTAssertEqual(row.coverageBreadth, 0.430822, accuracy: 0.000001)
        XCTAssertEqual(row.medianMAPQ, 60, accuracy: 0.0001)
        XCTAssertEqual(row.meanIdentity, 0.9948906974198022, accuracy: 0.000000001)
    }

    /// What the viewport shows when the BAM its record names is gone. A valid legacy result has no viewer bundle, so `load`
    /// refuses nothing, and these literals are what BIO rules on.
    func testAMappingResultWhoseBAMIsGoneOpensAsAtTheBase() async throws {
        let harness = try ViewSwitchWindowHarness()
        defer { harness.close() }
        let viewer = harness.split.viewerController!
        let (result, _, bam) = try RoutingSafetyNetFixtures.mappingAnalysis(in: root.appendingPathComponent("Analyses", isDirectory: true))
        try FileManager.default.removeItem(at: bam)
        try FileManager.default.removeItem(at: bam.appendingPathExtension("bai"))

        harness.split.displayMappingAnalysisFromSidebar(at: result)
        await harness.split.bundleOpenTask?.value
        let settled = await waitUntil(budget: .lookup) {
            viewer.referenceBundleViewportController?.mappingRowsRefreshTask == nil
        }
        let viewport = try XCTUnwrap(viewer.referenceBundleViewportController)
        XCTAssertTrue(settled, "the refresh of a gone BAM never ended")
        XCTAssertEqual(viewer.contentMode, .mapping)
        XCTAssertEqual(viewport.testContigTableView.displayedRows, [], "a gone BAM showed rows")
        XCTAssertTrue(
            viewport.testSummaryText.hasPrefix("minimap2 Mapping — 200 / 200 reads mapped (100.0%) — Warning: Could not measure the alignment statistics for sample alignment. Open the mapping again to try once more, or run the mapping again if it keeps failing."),
            viewport.testSummaryText
        )
        XCTAssertEqual(viewport.testDetailPlaceholderMessage, "Select a mapped contig to inspect mapped reads.")
    }
}
