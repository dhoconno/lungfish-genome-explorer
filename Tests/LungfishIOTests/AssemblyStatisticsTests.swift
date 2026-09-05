// AssemblyStatisticsTests.swift - Tests for assembly statistics computation
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
import LungfishCore
@testable import LungfishIO

final class AssemblyStatisticsTests: XCTestCase {

    func testHistogramNxKeepsPrecisionBeyondDoubleIntegerRange() {
        let half = 9_007_199_254_740_992
        XCTAssertEqual(SequenceLengthStatistics.nx(
            histogram: [half: 1, half - 1: 1, 2: 1],
            totalBases: 18_014_398_509_481_985
        ), half - 1)
        XCTAssertEqual(SequenceLengthStatistics.nx(histogram: [3: 2], totalBases: 6), 3)
        XCTAssertEqual(SequenceLengthStatistics.nx(histogram: [:], totalBases: 0), 0)
    }

    // MARK: - Basic Computation

    func testSingleContig() {
        let stats = AssemblyStatisticsCalculator.computeFromLengths([1000])
        XCTAssertEqual(stats.contigCount, 1)
        XCTAssertEqual(stats.totalLengthBP, 1000)
        XCTAssertEqual(stats.largestContigBP, 1000)
        XCTAssertEqual(stats.smallestContigBP, 1000)
        XCTAssertEqual(stats.n50, 1000)
        XCTAssertEqual(stats.l50, 1)
    }

    func testMultipleContigs() {
        // Contigs: 500, 400, 300, 200, 100 = total 1500
        // N50: 50% of 1500 = 750. Cumulative: 500 (33%), 500+400=900 (60%) -> N50 = 400
        // L50: 2 contigs needed (500+400=900 >= 750)
        let stats = AssemblyStatisticsCalculator.computeFromLengths([500, 400, 300, 200, 100])
        XCTAssertEqual(stats.contigCount, 5)
        XCTAssertEqual(stats.totalLengthBP, 1500)
        XCTAssertEqual(stats.largestContigBP, 500)
        XCTAssertEqual(stats.smallestContigBP, 100)
        XCTAssertEqual(stats.n50, 400)
        XCTAssertEqual(stats.l50, 2)
        XCTAssertEqual(stats.meanLengthBP, 300, accuracy: 0.01)
    }

    func testN90() {
        // Total = 1500, 90% = 1350
        // Cumulative: 500, 900, 1200, 1400 >= 1350 -> N90 = 200
        let stats = AssemblyStatisticsCalculator.computeFromLengths([500, 400, 300, 200, 100])
        XCTAssertEqual(stats.n90, 200)
    }

    func testEmptyInput() {
        let stats = AssemblyStatisticsCalculator.computeFromLengths([])
        XCTAssertEqual(stats.contigCount, 0)
        XCTAssertEqual(stats.totalLengthBP, 0)
        XCTAssertEqual(stats.n50, 0)
        XCTAssertEqual(stats.l50, 0)
    }

    func testUnsortedInput() {
        // Should sort internally
        let stats = AssemblyStatisticsCalculator.computeFromLengths([100, 500, 300, 200, 400])
        XCTAssertEqual(stats.largestContigBP, 500)
        XCTAssertEqual(stats.smallestContigBP, 100)
        XCTAssertEqual(stats.n50, 400)
    }

    func testNxRequiresCeilingOfFractionalBaseThreshold() {
        let stats = AssemblyStatisticsCalculator.computeFromLengths([3, 2, 2])
        XCTAssertEqual(stats.n50, 2)
        XCTAssertEqual(stats.l50, 2)
        let n90 = AssemblyStatisticsCalculator.computeFromLengths([9, 1, 1])
        XCTAssertEqual(n90.n90, 1)
    }

    func testNxRetainsIntegerPrecisionForLargeTotals() {
        let half = Int64.max / 2
        let stats = AssemblyStatisticsCalculator.computeFromLengths([half, half - 1, 2])
        XCTAssertEqual(stats.totalLengthBP, Int64.max)
        XCTAssertEqual(stats.n50, half - 1)
        XCTAssertEqual(stats.l50, 2)
    }

    // MARK: - GC Content

    func testGCContent() {
        let stats = AssemblyStatisticsCalculator.computeFromLengths([100], gcCount: 50, totalBases: 100)
        XCTAssertEqual(stats.gcFraction, 0.5, accuracy: 0.001)
        XCTAssertEqual(stats.gcPercent, 50.0, accuracy: 0.1)
    }

    func testGCContentZero() {
        let stats = AssemblyStatisticsCalculator.computeFromLengths([100], gcCount: 0, totalBases: 100)
        XCTAssertEqual(stats.gcFraction, 0.0)
    }

    // MARK: - FASTA Parsing

    func testParseFASTAString() {
        let fasta = """
        >contig1
        ATCGATCGATCG
        ATCGATCGATCG
        >contig2
        GCGCGCGC
        """
        let stats = AssemblyStatisticsCalculator.compute(fromFASTAString: fasta)
        XCTAssertEqual(stats.contigCount, 2)
        XCTAssertEqual(stats.totalLengthBP, 32)  // 24 + 8
        XCTAssertEqual(stats.largestContigBP, 24)
        XCTAssertEqual(stats.smallestContigBP, 8)
    }

    func testGCFromFASTA() {
        let fasta = """
        >test
        GGCCAATT
        """
        let stats = AssemblyStatisticsCalculator.compute(fromFASTAString: fasta)
        XCTAssertEqual(stats.gcFraction, 0.5, accuracy: 0.001)
    }

    func testFASTAWithNBases() {
        let fasta = """
        >test
        ATCGNNNN
        """
        let stats = AssemblyStatisticsCalculator.compute(fromFASTAString: fasta)
        XCTAssertEqual(stats.totalLengthBP, 8)  // N bases count toward length
        XCTAssertEqual(stats.gcFraction, 0.25, accuracy: 0.001)  // 2 GC out of 8
    }

    func testEmptyFASTA() {
        let stats = AssemblyStatisticsCalculator.compute(fromFASTAString: "")
        XCTAssertEqual(stats.contigCount, 0)
    }

    func testFASTAWithLowercaseBases() {
        let fasta = """
        >test
        atcgatcg
        """
        let stats = AssemblyStatisticsCalculator.compute(fromFASTAString: fasta)
        XCTAssertEqual(stats.totalLengthBP, 8)
        XCTAssertEqual(stats.gcFraction, 0.5, accuracy: 0.001)
    }

    // MARK: - Summary

    func testSummaryContainsKey() {
        let stats = AssemblyStatisticsCalculator.computeFromLengths([1000, 500, 200])
        let summary = stats.summary
        XCTAssertTrue(summary.contains("N50"))
        XCTAssertTrue(summary.contains("Contigs"))
        XCTAssertTrue(summary.contains("GC"))
    }

    // MARK: - Realistic Assembly

    func testRealisticBacterialAssembly() {
        // Simulate a ~3 Mbp bacterial genome in ~50 contigs
        var lengths: [Int64] = []
        lengths.append(500_000)
        lengths.append(400_000)
        lengths.append(350_000)
        lengths.append(300_000)
        lengths.append(250_000)
        for _ in 0..<10 { lengths.append(100_000) }
        for _ in 0..<15 { lengths.append(50_000) }
        for _ in 0..<20 { lengths.append(10_000) }

        let stats = AssemblyStatisticsCalculator.computeFromLengths(lengths)
        XCTAssertEqual(stats.contigCount, 50)
        XCTAssertGreaterThan(stats.n50, 50_000)
        XCTAssertGreaterThan(stats.totalLengthBP, 3_000_000)
    }
}
