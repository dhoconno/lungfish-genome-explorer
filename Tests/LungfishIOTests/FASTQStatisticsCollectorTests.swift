// FASTQStatisticsCollectorTests.swift - Tests for streaming FASTQ statistics
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
@testable import LungfishIO

final class FASTQStatisticsCollectorTests: XCTestCase {

    // MARK: - Helpers

    /// Creates a FASTQRecord with given length and uniform quality.
    private func makeRecord(
        id: String = "read1",
        sequence: String,
        quality: UInt8 = 30
    ) -> FASTQRecord {
        let qualityString = String(repeating: Character(UnicodeScalar(quality + 33)), count: sequence.count)
        return FASTQRecord(
            identifier: id,
            sequence: sequence,
            qualityString: qualityString,
            encoding: .phred33
        )
    }

    // MARK: - Empty Dataset

    func testEmptyDatasetReturnsZeros() {
        let collector = FASTQStatisticsCollector()
        let stats = collector.finalize()

        XCTAssertEqual(stats.readCount, 0)
        XCTAssertEqual(stats.baseCount, 0)
        XCTAssertEqual(stats.meanReadLength, 0)
        XCTAssertEqual(stats.minReadLength, 0)
        XCTAssertEqual(stats.maxReadLength, 0)
        XCTAssertEqual(stats.medianReadLength, 0)
        XCTAssertEqual(stats.n50ReadLength, 0)
        XCTAssertEqual(stats.meanQuality, 0)
        XCTAssertEqual(stats.q20Percentage, 0)
        XCTAssertEqual(stats.q30Percentage, 0)
        XCTAssertEqual(stats.gcContent, 0)
        XCTAssertTrue(stats.readLengthHistogram.isEmpty)
        XCTAssertTrue(stats.qualityScoreHistogram.isEmpty)
        XCTAssertTrue(stats.perPositionQuality.isEmpty)
    }

    // MARK: - Single Record

    func testSingleRecord() {
        let collector = FASTQStatisticsCollector()
        let record = makeRecord(sequence: "ACGT", quality: 35)
        collector.process(record)
        let stats = collector.finalize()

        XCTAssertEqual(stats.readCount, 1)
        XCTAssertEqual(stats.baseCount, 4)
        XCTAssertEqual(stats.meanReadLength, 4.0)
        XCTAssertEqual(stats.minReadLength, 4)
        XCTAssertEqual(stats.maxReadLength, 4)
        XCTAssertEqual(stats.medianReadLength, 4)
        XCTAssertEqual(stats.meanQuality, 35.0, accuracy: 0.01)
    }

    // MARK: - Read Count and Base Count

    func testMultipleRecordCounts() {
        let collector = FASTQStatisticsCollector()
        collector.process(makeRecord(id: "r1", sequence: "ACGT"))     // 4 bases
        collector.process(makeRecord(id: "r2", sequence: "ACGTACGT")) // 8 bases
        collector.process(makeRecord(id: "r3", sequence: "AC"))       // 2 bases
        let stats = collector.finalize()

        XCTAssertEqual(stats.readCount, 3)
        XCTAssertEqual(stats.baseCount, 14)
    }

    // MARK: - Length Statistics

    func testMinMaxMeanLength() {
        let collector = FASTQStatisticsCollector()
        collector.process(makeRecord(id: "r1", sequence: "AC"))       // 2
        collector.process(makeRecord(id: "r2", sequence: "ACGT"))     // 4
        collector.process(makeRecord(id: "r3", sequence: "ACGTAC"))   // 6
        let stats = collector.finalize()

        XCTAssertEqual(stats.minReadLength, 2)
        XCTAssertEqual(stats.maxReadLength, 6)
        XCTAssertEqual(stats.meanReadLength, 4.0, accuracy: 0.01)
    }

    func testMedianLengthOddCount() {
        let collector = FASTQStatisticsCollector()
        collector.process(makeRecord(id: "r1", sequence: "AC"))       // 2
        collector.process(makeRecord(id: "r2", sequence: "ACGT"))     // 4
        collector.process(makeRecord(id: "r3", sequence: "ACGTAC"))   // 6
        let stats = collector.finalize()

        // Median of [2, 4, 6] = 4
        XCTAssertEqual(stats.medianReadLength, 4)
    }

    func testMedianLengthEvenCount() {
        let collector = FASTQStatisticsCollector()
        collector.process(makeRecord(id: "r1", sequence: "AC"))       // 2
        collector.process(makeRecord(id: "r2", sequence: "ACGT"))     // 4
        collector.process(makeRecord(id: "r3", sequence: "ACGTAC"))   // 6
        collector.process(makeRecord(id: "r4", sequence: "ACGTACGT")) // 8
        let stats = collector.finalize()

        // Median of [2, 4, 6, 8] — our histogram median picks the (n+1)/2 = 2.5th element
        // which lands on 4 (cumulative reaches target at 4)
        XCTAssertTrue(stats.medianReadLength == 4 || stats.medianReadLength == 6)
    }

    // MARK: - Read Length Histogram

    func testReadLengthHistogram() {
        let collector = FASTQStatisticsCollector()
        collector.process(makeRecord(id: "r1", sequence: "ACGT"))     // 4
        collector.process(makeRecord(id: "r2", sequence: "ACGT"))     // 4
        collector.process(makeRecord(id: "r3", sequence: "ACGTAC"))   // 6
        let stats = collector.finalize()

        XCTAssertEqual(stats.readLengthHistogram[4], 2)
        XCTAssertEqual(stats.readLengthHistogram[6], 1)
        XCTAssertNil(stats.readLengthHistogram[5])
    }

    // MARK: - N50

    func testN50Calculation() {
        let collector = FASTQStatisticsCollector()
        // 3 reads: lengths 100, 200, 300 → total bases = 600
        // N50: sort desc [300, 200, 100], cumulative: 300 >= 300 (half of 600) → N50 = 300
        collector.process(makeRecord(id: "r1", sequence: String(repeating: "A", count: 100), quality: 30))
        collector.process(makeRecord(id: "r2", sequence: String(repeating: "A", count: 200), quality: 30))
        collector.process(makeRecord(id: "r3", sequence: String(repeating: "A", count: 300), quality: 30))
        let stats = collector.finalize()

        XCTAssertEqual(stats.n50ReadLength, 300)
    }

    func testN50RequiresAtLeastHalfOfOddTotalBases() {
        let collector = FASTQStatisticsCollector()
        for (index, sequence) in ["AAA", "CC", "GG"].enumerated() {
            collector.process(makeRecord(id: "r\(index)", sequence: sequence))
        }
        XCTAssertEqual(collector.finalize().n50ReadLength, 2)
    }

    func testN50WithUniformLengths() {
        let collector = FASTQStatisticsCollector()
        for i in 0..<5 {
            collector.process(makeRecord(id: "r\(i)", sequence: "ACGTACGT", quality: 30))
        }
        let stats = collector.finalize()
        // All same length → N50 = 8
        XCTAssertEqual(stats.n50ReadLength, 8)
    }

    // MARK: - GC Content

    func testGCContent() {
        let collector = FASTQStatisticsCollector()
        // "GCGC" → 4/4 = 100% GC
        collector.process(makeRecord(sequence: "GCGC"))
        let stats = collector.finalize()
        XCTAssertEqual(stats.gcContent, 1.0, accuracy: 0.001)
    }

    func testGCContentMixed() {
        let collector = FASTQStatisticsCollector()
        // "ACGT" → 2 GC out of 4 = 50%
        collector.process(makeRecord(sequence: "ACGT"))
        let stats = collector.finalize()
        XCTAssertEqual(stats.gcContent, 0.5, accuracy: 0.001)
    }

    func testGCContentAllAT() {
        let collector = FASTQStatisticsCollector()
        collector.process(makeRecord(sequence: "AATT"))
        let stats = collector.finalize()
        XCTAssertEqual(stats.gcContent, 0.0, accuracy: 0.001)
    }

    func testGCContentCaseInsensitive() {
        let collector = FASTQStatisticsCollector()
        // Lowercase should also be counted
        collector.process(makeRecord(sequence: "gcGC"))
        let stats = collector.finalize()
        XCTAssertEqual(stats.gcContent, 1.0, accuracy: 0.001)
    }

    // MARK: - Quality Statistics

    func testQualityMean() {
        let collector = FASTQStatisticsCollector()
        // Quality 30 for all 4 bases
        collector.process(makeRecord(sequence: "ACGT", quality: 30))
        let stats = collector.finalize()
        XCTAssertEqual(stats.meanQuality, 30.0, accuracy: 0.01)
    }

    func testQ20Percentage() {
        let collector = FASTQStatisticsCollector()
        // All bases Q30 → all are >= Q20
        collector.process(makeRecord(sequence: "ACGT", quality: 30))
        let stats = collector.finalize()
        XCTAssertEqual(stats.q20Percentage, 100.0, accuracy: 0.01)
    }

    func testQ30Percentage() {
        let collector = FASTQStatisticsCollector()
        // All bases Q30 → all are >= Q30
        collector.process(makeRecord(sequence: "ACGT", quality: 30))
        let stats = collector.finalize()
        XCTAssertEqual(stats.q30Percentage, 100.0, accuracy: 0.01)
    }

    func testLowQualityRecordQ30() {
        let collector = FASTQStatisticsCollector()
        // Quality 10 → none are Q20 or Q30
        collector.process(makeRecord(sequence: "ACGT", quality: 10))
        let stats = collector.finalize()
        XCTAssertEqual(stats.q20Percentage, 0.0, accuracy: 0.01)
        XCTAssertEqual(stats.q30Percentage, 0.0, accuracy: 0.01)
    }

    // MARK: - Quality Score Histogram

    func testQualityScoreHistogram() {
        let collector = FASTQStatisticsCollector()
        collector.process(makeRecord(sequence: "ACGT", quality: 35))
        let stats = collector.finalize()

        XCTAssertEqual(stats.qualityScoreHistogram[35], 4)
        XCTAssertNil(stats.qualityScoreHistogram[30])
    }

    // MARK: - Per-Position Quality

    func testPerPositionQuality() {
        let collector = FASTQStatisticsCollector()
        // Two reads, both length 4, quality 30
        collector.process(makeRecord(id: "r1", sequence: "ACGT", quality: 30))
        collector.process(makeRecord(id: "r2", sequence: "ACGT", quality: 30))
        let stats = collector.finalize()

        XCTAssertEqual(stats.perPositionQuality.count, 4)
        for pos in stats.perPositionQuality {
            XCTAssertEqual(pos.mean, 30.0, accuracy: 0.01)
            XCTAssertEqual(pos.median, 30.0, accuracy: 0.01)
        }
    }

    func testPerPositionQualityVariableLength() {
        let collector = FASTQStatisticsCollector()
        collector.process(makeRecord(id: "r1", sequence: "AC", quality: 30))   // 2 bases
        collector.process(makeRecord(id: "r2", sequence: "ACGT", quality: 30)) // 4 bases
        let stats = collector.finalize()

        // Position 0 and 1: 2 reads contribute
        // Position 2 and 3: only 1 read contributes
        XCTAssertEqual(stats.perPositionQuality.count, 4)
        XCTAssertEqual(stats.perPositionQuality[0].position, 0)
        XCTAssertEqual(stats.perPositionQuality[3].position, 3)
    }

    // MARK: - Codable

    func testDatasetStatisticsCodable() throws {
        let collector = FASTQStatisticsCollector()
        collector.process(makeRecord(sequence: "ACGT", quality: 30))
        let stats = collector.finalize()

        let encoder = JSONEncoder()
        let data = try encoder.encode(stats)

        let decoder = JSONDecoder()
        let decoded = try decoder.decode(FASTQDatasetStatistics.self, from: data)

        XCTAssertEqual(decoded.readCount, stats.readCount)
        XCTAssertEqual(decoded.baseCount, stats.baseCount)
        XCTAssertEqual(decoded.meanQuality, stats.meanQuality, accuracy: 0.001)
        XCTAssertEqual(decoded.gcContent, stats.gcContent, accuracy: 0.001)
        XCTAssertEqual(decoded.perPositionQuality.count, stats.perPositionQuality.count)
    }

    // MARK: - Histogram Helpers

    func testComputeMedianFromHistogram() {
        // Histogram: {10: 3, 20: 2, 30: 1} → sorted values: 10,10,10,20,20,30
        // Total 6, target = 3, median = 10
        let histogram: [Int: Int] = [10: 3, 20: 2, 30: 1]
        let median = FASTQStatisticsCollector.computeMedianFromHistogram(histogram, totalCount: 6)
        XCTAssertEqual(median, 10)
    }

    func testComputeMedianSingleEntry() {
        let histogram: [Int: Int] = [150: 1]
        let median = FASTQStatisticsCollector.computeMedianFromHistogram(histogram, totalCount: 1)
        XCTAssertEqual(median, 150)
    }

    func testComputeN50FromHistogram() {
        // Reads: 100bp x 1, 200bp x 1, 300bp x 1
        // Total bases: 600, half = 300
        // Sorted desc: 300 (cumulative: 300 >= 300) → N50 = 300
        let histogram: [Int: Int] = [100: 1, 200: 1, 300: 1]
        let n50 = FASTQStatisticsCollector.computeN50FromHistogram(histogram, totalBases: 600)
        XCTAssertEqual(n50, 300)
    }

    func testComputeN50EqualLengths() {
        // 10 reads of length 150 → total 1500, half = 750
        // Only key=150 → cumulative 150*10=1500 >= 750 → N50 = 150
        let histogram: [Int: Int] = [150: 10]
        let n50 = FASTQStatisticsCollector.computeN50FromHistogram(histogram, totalBases: 1500)
        XCTAssertEqual(n50, 150)
    }

    // MARK: - Large Dataset Simulation

    func testLargeDatasetPerformance() {
        let collector = FASTQStatisticsCollector()
        let sequence = String(repeating: "ACGT", count: 37) + "ACG" // 151 bases (typical Illumina)
        let quality = UInt8(35)

        // Simulate 100K reads — should be fast in streaming mode
        for i in 0..<100_000 {
            collector.process(makeRecord(id: "read\(i)", sequence: sequence, quality: quality))
        }
        let stats = collector.finalize()

        XCTAssertEqual(stats.readCount, 100_000)
        XCTAssertEqual(stats.baseCount, 15_100_000)
        XCTAssertEqual(stats.minReadLength, 151)
        XCTAssertEqual(stats.maxReadLength, 151)
        XCTAssertEqual(stats.meanQuality, 35.0, accuracy: 0.01)
        XCTAssertEqual(stats.q30Percentage, 100.0, accuracy: 0.01)
    }
}
