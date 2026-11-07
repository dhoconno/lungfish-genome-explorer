// FASTQMeanQualityPoolingTests.swift - The collector's Mean Q is the Phred value of the pooled error probability
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
@testable import LungfishIO

/// A pin of scientific output (BIO-MEANQ item 4, owner row 36). Ten bases at Q40 and ten at Q2 pool to 5.01, the figure
/// seqkit reports as `AvgQual` for the same bases, and not to the 21.0 that an arithmetic mean of the Phred values gives.
/// This holds before and after the label work of lane MEANQ, so it passes at its base.
final class FASTQMeanQualityPoolingTests: XCTestCase {

    private func record(_ id: String, quality: String) -> FASTQRecord {
        FASTQRecord(identifier: id, sequence: String(repeating: "A", count: quality.count), qualityString: quality, encoding: .phred33)
    }

    func testCollectorMeanQualityIsPooledErrorProbabilityMean() {
        // Two reads, `IIIIIIIIII` (Q40) and `##########` (Q2).
        let twoReads = FASTQStatisticsCollector()
        twoReads.process(record("high", quality: "IIIIIIIIII"))
        twoReads.process(record("low", quality: "##########"))
        let pooled = twoReads.finalize().meanQuality
        XCTAssertEqual(pooled, 5.01, accuracy: 0.01)
        XCTAssertNotEqual(pooled, 21.0, accuracy: 1.0)

        // The same twenty bases in one read give the same figure, so the pool is over bases and not over reads.
        let oneRead = FASTQStatisticsCollector()
        oneRead.process(record("both", quality: "IIIIIIIIII##########"))
        XCTAssertEqual(oneRead.finalize().meanQuality, pooled, accuracy: 1e-9)
    }
}
