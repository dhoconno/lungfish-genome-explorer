// MeanQualityParityTests.swift - Import and Refresh QC Summary agree on Mean Q
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import XCTest
@testable import LungfishIO

/// The FASTQ import path stores seqkit's `AvgQual` (`seqkit stats -a`), and
/// Refresh QC Summary (`fastq qc-summary`) stores what
/// `FASTQStatisticsCollector` computes. Both must be the error-probability
/// mean, so the Mean Q card does not change value after a refresh.
final class MeanQualityParityTests: XCTestCase {
    /// `seqkit stats -a -T Tests/Fixtures/sarscov2/test_1.fastq.gz` reports
    /// `AvgQual 24.91` (seqkit prints two decimals). The arithmetic Phred
    /// mean of the same file is 33.33, which is what the refresh path used
    /// to report.
    private static let seqkitAvgQualForSarscov2R1 = 24.91
    private static let arithmeticPhredMeanForSarscov2R1 = 33.33

    func testCollectorMatchesSeqkitAvgQualOnFixture() async throws {
        let reader = FASTQReader(validateSequence: false)
        let collector = FASTQStatisticsCollector()
        var errorSum = 0.0
        var phredSum = 0
        var bases = 0
        for try await record in reader.records(from: TestFixtures.sarscov2.fastqR1) {
            collector.process(record)
            for index in 0..<record.quality.count {
                let q = record.quality.qualityAt(index)
                errorSum += pow(10.0, -Double(q) / 10.0)
                phredSum += Int(q)
                bases += 1
            }
        }
        let stats = collector.finalize()

        XCTAssertEqual(stats.readCount, 100)
        XCTAssertEqual(stats.baseCount, 13_897)
        XCTAssertEqual(stats.meanQuality, Self.seqkitAvgQualForSarscov2R1, accuracy: 0.01)
        XCTAssertEqual(stats.meanQuality, -10.0 * log10(errorSum / Double(bases)), accuracy: 1e-9)

        let arithmetic = Double(phredSum) / Double(bases)
        XCTAssertEqual(arithmetic, Self.arithmeticPhredMeanForSarscov2R1, accuracy: 0.01)
        XCTAssertGreaterThan(arithmetic, stats.meanQuality + 5,
                             "the arithmetic mean overstates quality; the card must not switch between the two")
    }

    func testReaderComputeStatisticsUsesTheSameDefinitionAsSeqkit() async throws {
        // `fastq qc-summary` calls this entry point with sampleLimit 0.
        let reader = FASTQReader(validateSequence: false)
        let result = try await reader.computeStatistics(from: TestFixtures.sarscov2.fastqR1, sampleLimit: 0)
        XCTAssertEqual(result.statistics.meanQuality, Self.seqkitAvgQualForSarscov2R1, accuracy: 0.01)
    }
}
