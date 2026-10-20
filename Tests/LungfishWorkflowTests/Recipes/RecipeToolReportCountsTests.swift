// RecipeToolReportCountsTests.swift - read counts taken from fastp and deacon reports
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
@testable import LungfishWorkflow

/// The figures below are from fastp 1.3.6 and deacon 0.16.0 on 1,000,000 read
/// pairs of a VSP2 run (2026-10-20), each checked against a count of the files
/// the tool wrote.
final class RecipeToolReportCountsTests: XCTestCase {
    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("RecipeToolReportCountsTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    private func write(_ json: String, name: String) throws -> URL {
        let url = tempDir.appendingPathComponent(name)
        try Data(json.utf8).write(to: url)
        return url
    }

    func testFastpPairedReportGivesPairsInAndOut() throws {
        // Dedup + trim: 1,000,000 pairs in, 878,165 pairs in each output file.
        let report = try write("""
        {"summary": {"before_filtering": {"total_reads": 2000000}, "after_filtering": {"total_reads": 1756330}},
         "read1_before_filtering": {"total_reads": 1000000}, "read2_before_filtering": {"total_reads": 1000000},
         "read1_after_filtering": {"total_reads": 878165}, "read2_after_filtering": {"total_reads": 878165}}
        """, name: "fused.json")

        let counts = try XCTUnwrap(RecipeToolReportCounts.fastpPairs(reportAt: report))

        XCTAssertEqual(counts.input, 1_000_000)
        XCTAssertEqual(counts.output, 878_165)
    }

    func testFastpMergeReportGivesMergedReadsAndTheUnmergedPairsBesideThem() throws {
        // 859,213 pairs in: 721,593 merged reads and 137,620 unmerged pairs on disk.
        let report = try write("""
        {"summary": {"before_filtering": {"total_reads": 1718426}, "after_filtering": {"total_reads": 721593}},
         "filtering_result": {"passed_filter_reads": 1718426, "corrected_reads": 43780, "low_quality_reads": 0},
         "read1_before_filtering": {"total_reads": 859213}, "read2_before_filtering": {"total_reads": 859213},
         "merged_and_filtered": {"total_reads": 721593}}
        """, name: "merge.json")

        let counts = try XCTUnwrap(RecipeToolReportCounts.fastpMerge(reportAt: report))

        XCTAssertEqual(counts.inputPairs, 859_213)
        XCTAssertEqual(counts.mergedReads, 721_593)
        XCTAssertEqual(counts.unmergedPairs, 137_620)
    }

    func testDeaconPairedSummaryCountsBothMatesSoPairsAreHalf() throws {
        let summary = try write("""
        {"version": "deacon 0.16.0", "input": "f_R1.fq.gz", "input2": "f_R2.fq.gz",
         "seqs_in": 1756330, "seqs_out": 1718426, "seqs_removed": 37904}
        """, name: "deacon.json")

        let counts = try XCTUnwrap(RecipeToolReportCounts.deaconPairs(summaryAt: summary))

        XCTAssertEqual(counts.input, 878_165)
        XCTAssertEqual(counts.output, 859_213)
    }

    func testDeaconSummaryWithAnOddMateCountGivesNoPairCount() throws {
        let summary = try write("""
        {"input": "a_R1.fq.gz", "input2": "a_R2.fq.gz", "seqs_in": 11, "seqs_out": 10}
        """, name: "odd.json")

        XCTAssertNil(RecipeToolReportCounts.deaconPairs(summaryAt: summary))
    }

    func testReportsWithoutTheirCountsGiveNothing() throws {
        let empty = try write("{}", name: "empty.json")
        let missing = tempDir.appendingPathComponent("missing.json")

        XCTAssertNil(RecipeToolReportCounts.fastpPairs(reportAt: empty))
        XCTAssertNil(RecipeToolReportCounts.fastpMerge(reportAt: empty))
        XCTAssertNil(RecipeToolReportCounts.deaconPairs(summaryAt: empty))
        XCTAssertNil(RecipeToolReportCounts.fastpPairs(reportAt: missing))
        XCTAssertNil(RecipeToolReportCounts.fastpPairs(reportAt: URL(fileURLWithPath: "/dev/null")))
    }

    func testMergeReportWhoseFiguresDoNotAddUpGivesNothing() throws {
        // More merged reads than pairs that passed: the formula would go negative.
        let report = try write("""
        {"filtering_result": {"passed_filter_reads": 10}, "read1_before_filtering": {"total_reads": 5},
         "merged_and_filtered": {"total_reads": 6}}
        """, name: "bad-merge.json")

        XCTAssertNil(RecipeToolReportCounts.fastpMerge(reportAt: report))
    }
}
