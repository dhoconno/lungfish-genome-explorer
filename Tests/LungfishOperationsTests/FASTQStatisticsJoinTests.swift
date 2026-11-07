// FASTQStatisticsJoinTests.swift - A bundle's FASTQ files join into one Mean Q by their pooled error probability
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
@testable import LungfishOperations

/// `FASTQStatisticsService.compute(for:)` runs seqkit on every file of a bundle and joins the rows. The Mean Q of one
/// file is the Phred value of the mean error probability over its bases (seqkit `AvgQual`), so the joined figure is the
/// Phred value of the error probabilities pooled over all bases, which is what seqkit gives for the same bases in one
/// file. Joining the Phred values with a base-weighted average showed 22.5 for a paired run whose reads pool to 13.0
/// (BIO-MEANQ item 7, row MEANQ-JOIN, S1).
final class FASTQStatisticsJoinTests: XCTestCase {

    private func summary(sumLen: Int64, averageQuality: Double) -> FASTQStatisticsService.SeqkitSummary {
        FASTQStatisticsService.SeqkitSummary(
            numSeqs: 1, sumLen: sumLen, minLen: Int(sumLen), avgLen: Double(sumLen), maxLen: Int(sumLen),
            q20Percentage: 100, q30Percentage: 100, averageQuality: averageQuality, gcPercentage: 50
        )
    }

    func testJoinedSeqkitAverageQualityIsPooledErrorProbabilityMean() {
        // Ten bases at Q40 beside ten at Q2. seqkit gives 5.01 for the same twenty bases in one file, and the
        // arithmetic way of joining gave 21.0.
        let joined = FASTQStatisticsService.aggregateSeqkitSummaries([
            summary(sumLen: 10, averageQuality: 40),
            summary(sumLen: 10, averageQuality: 2),
        ])
        XCTAssertEqual(joined.averageQuality, 5.01, accuracy: 0.01)
        XCTAssertNotEqual(joined.averageQuality, 21.0, accuracy: 1.0)

        // A paired run with R1 at Q35 and a failed R2 at Q10 pools to 13.0, where the base-weighted average of the
        // two Phred values showed 22.5.
        let pair = FASTQStatisticsService.aggregateSeqkitSummaries([
            summary(sumLen: 1_000_000, averageQuality: 35),
            summary(sumLen: 1_000_000, averageQuality: 10),
        ])
        XCTAssertEqual(pair.averageQuality, 13.0, accuracy: 0.01)
        XCTAssertNotEqual(pair.averageQuality, 22.5, accuracy: 1.0)
    }

    func testJoinedAverageQualityWeighsEachFileByItsBases() {
        // Files of unequal size, one of them empty, against a direct evaluation of the definition.
        let files: [(bases: Int64, quality: Double)] = [(3_000, 36.5), (10_000, 21.25), (0, 0), (250, 3.5)]
        let joined = FASTQStatisticsService.aggregateSeqkitSummaries(
            files.map { summary(sumLen: $0.bases, averageQuality: $0.quality) }
        )
        let errorSum = files.reduce(0.0) { $0 + Double($1.bases) * pow(10.0, -$1.quality / 10.0) }
        let bases = files.reduce(Int64(0)) { $0 + $1.bases }
        XCTAssertEqual(joined.averageQuality, -10.0 * log10(errorSum / Double(bases)), accuracy: 1e-9)
        XCTAssertEqual(joined.sumLen, bases)
    }
}
