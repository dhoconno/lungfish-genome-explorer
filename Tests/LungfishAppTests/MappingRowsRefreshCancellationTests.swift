// MappingRowsRefreshCancellationTests.swift - A superseded mapping row refresh stops its summary build
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import Synchronization
import XCTest
@testable import LungfishApp
@testable import LungfishCore
@testable import LungfishWorkflow
import LungfishTestSupport

/// The row refresh builds exact per-contig summaries with samtools. A newer
/// refresh only dropped the older one's output, so the older samtools run
/// went on to the end. The refresh task is now cancelled, and the summary
/// builder's cancellation handler stops its process tree.
@MainActor
final class MappingRowsRefreshCancellationTests: XCTestCase {
    private final class Counts: Sendable {
        let builds = Mutex(0)
        let cancelledBuilds = Mutex(0)
    }

    func testSupersededRefreshCancelsItsSummaryBuild() async throws {
        let root = try TestTempDirectory.make(prefix: "MappingRowsRefreshCancellation")
        defer { TestTempDirectory.cleanup(root) }
        let bundleURL = try MappingRoutingFixture.makeReferenceBundle(
            name: "Refresh Cancel", chromosomes: [.init(name: "chr1", length: 100)], in: root
        )
        try MappingRoutingFixture.addSingleSampleAlignment(
            to: bundleURL, sampleID: "S1", includeReadGroup: false, includeChromosomeStats: true
        )
        let resultURL = root.appendingPathComponent("mapping-result", isDirectory: true)
        let counts = Counts()
        let viewport = ReferenceBundleViewportController()
        _ = viewport.view
        viewport.setAlignmentTrackSummaryBuilderForTesting { _, _, _ in
            let build = counts.builds.withLock { value -> Int in
                value += 1
                return value
            }
            guard build == 1 else {
                return [MappingContigSummary(
                    contigName: "chr1", contigLength: 100, mappedReads: 1, mappedReadPercent: 100,
                    meanDepth: 2, coverageBreadth: 0.5, medianMAPQ: 60, meanIdentity: 1
                )]
            }
            do {
                try await Task.sleep(for: .seconds(60))
            } catch {
                counts.cancelledBuilds.withLock { $0 += 1 }
                throw error
            }
            return []
        }

        try viewport.configureForTesting(input: .mappingResult(
            result: MappingRoutingFixture.makeMappingResult(resultDirectory: resultURL, viewerBundleURL: bundleURL),
            resultDirectoryURL: resultURL,
            provenance: nil,
            viewerBundleManifest: try BundleManifest.load(from: bundleURL)
        ))
        let firstBuildStarted = await waitUntil(timeout: .seconds(30)) {
            counts.builds.withLock { $0 } == 1
        }
        XCTAssertTrue(firstBuildStarted, "the first refresh never started its summary build")

        viewport.applyEmbeddedReadDisplaySettings([
            NotificationUserInfoKey.visibleAlignmentTrackID: "reads-track",
        ])

        let cancelled = await waitUntil(timeout: .seconds(30)) {
            counts.cancelledBuilds.withLock { $0 } == 1
        }
        XCTAssertTrue(cancelled, "the superseded refresh's summary build was not cancelled")
        let rowsShown = await waitUntil(timeout: .seconds(30)) {
            viewport.testContigTableView.displayedRows.contains { $0.sampleID == "S1" }
        }
        XCTAssertTrue(rowsShown, "the newer refresh shows the rows its summary build measured")
        let shown = viewport.testContigTableView.displayedRows.first { $0.sampleID == "S1" }
        XCTAssertEqual(shown?.contigName, "chr1")
        XCTAssertEqual(shown?.mappedReads, 1)
        XCTAssertEqual(shown?.meanDepth, 2, "the builder's depth, not a zero that nobody measured")
    }
}
