// ProjectUniversalSearchUnmeasuredStatisticsTests.swift - Search leaves out statistics nobody measured
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
import LungfishCore
import LungfishTestSupport
@testable import LungfishIO

/// Before Phase 3.0 an ONT import stored statistics that counted reads and gave every length and score 0, and some
/// bundles still carry them. The search index took a sidecar's statistics as they were, so a search on read count,
/// length or GC matched those false numbers (ONT-BIO Backlog 5, lane DEMUX-STATS). It indexes only statistics that
/// were measured.
final class ProjectUniversalSearchUnmeasuredStatisticsTests: XCTestCase {

    private var projectURL: URL!

    override func setUpWithError() throws {
        projectURL = try TestTempDirectory.make(prefix: "search-unmeasured-statistics")
    }

    override func tearDown() {
        TestTempDirectory.cleanup(projectURL)
    }

    func testSearchIndexesMeasuredStatisticsAndLeavesOutStatisticsNobodyMeasured() throws {
        let measured = FASTQDatasetStatistics(
            readCount: 50, baseCount: 5_000,
            meanReadLength: 100, minReadLength: 90, maxReadLength: 110,
            medianReadLength: 100, n50ReadLength: 100,
            meanQuality: 31.5, q20Percentage: 97, q30Percentage: 88, gcContent: 0.45,
            readLengthHistogram: [90: 10, 100: 30, 110: 10], qualityScoreHistogram: [30: 2_500, 40: 2_500],
            perPositionQuality: []
        )
        try makeFASTQBundle(name: "Measured", statistics: measured)
        try makeFASTQBundle(
            name: "CountsOnly",
            statistics: .countsOnlyFixture(readCount: 383_349, baseCount: 575_023_500)
        )

        let index = try ProjectUniversalSearchIndex(projectURL: projectURL)
        try index.rebuild()

        let results = try index.search(rawQuery: "type:fastq_dataset read_count>=1", limit: 50)
        XCTAssertEqual(
            results.map { $0.url.deletingPathExtension().lastPathComponent }, ["Measured"],
            "a read count nobody measured is not indexed"
        )
    }

    private func makeFASTQBundle(name: String, statistics: FASTQDatasetStatistics) throws {
        let bundleURL = projectURL.appendingPathComponent("\(name).lungfishfastq", isDirectory: true)
        try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)
        let fastqURL = bundleURL.appendingPathComponent("reads.fastq")
        try "@read1\nACGTACGT\n+\nIIIIIIII\n".write(to: fastqURL, atomically: true, encoding: .utf8)
        var metadata = PersistedFASTQMetadata()
        metadata.computedStatistics = statistics
        FASTQMetadataStore.save(metadata, for: fastqURL)
    }
}
