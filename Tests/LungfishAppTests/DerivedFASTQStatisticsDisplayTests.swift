// DerivedFASTQStatisticsDisplayTests.swift - The viewer shows only statistics that were counted
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
@testable import LungfishApp
import LungfishIO
import LungfishTestSupport

/// A derived bundle's manifest stores statistics that the FASTQ view, its charts and the Inspector show. Bundles
/// demultiplexed before Phase 3.0 lane DEMUX-STATS stored 0 for GC, mean Q, Q20 and Q30, and on the cutadapt route and
/// for unassigned reads 0 for median and N50 too, and those were shown as measured (walk WF-8b). The view now measures
/// the reads of such a bundle when it is shown, and words a record with reads and no scores as "No quality scores"
/// (ONT-BIO Backlog 3).
final class DerivedFASTQStatisticsDisplayTests: XCTestCase {

    private static let scored = FASTQDatasetStatistics(
        readCount: 4, baseCount: 400,
        meanReadLength: 100, minReadLength: 88, maxReadLength: 118,
        medianReadLength: 98, n50ReadLength: 108,
        meanQuality: 18.4, q20Percentage: 60, q30Percentage: 40, gcContent: 0.51,
        readLengthHistogram: [88: 1, 98: 1, 108: 1, 118: 1], qualityScoreHistogram: [2: 80, 10: 80, 20: 80, 30: 80, 40: 80],
        perPositionQuality: []
    )

    func testCountedStatisticsAreShownAsStored() {
        XCTAssertEqual(FASTQStatisticsDisplayRules.storedStatisticsToShow(Self.scored), Self.scored)
        XCTAssertEqual(
            FASTQStatisticsDisplayRules.storedStatisticsToShow(.empty), .empty, "no reads, nothing to measure"
        )
        let fasta = FASTQDatasetStatistics.measuringFASTA(text: ">a\nACGTGGCC\n>b\nGGCATT\n")
        XCTAssertEqual(
            FASTQStatisticsDisplayRules.storedStatisticsToShow(fasta), fasta,
            "a FASTA record counts lengths and GC and has no scores to count"
        )
    }

    func testStatisticsAnOlderDemultiplexStoredAreMeasuredAgain() {
        XCTAssertNil(
            FASTQStatisticsDisplayRules.storedStatisticsToShow(.countsOnlyFixture(readCount: 4, baseCount: 400)),
            "counts with no longest read"
        )
        let exactRoute = FASTQDatasetStatistics(
            readCount: 4, baseCount: 412,
            meanReadLength: 103, minReadLength: 88, maxReadLength: 118,
            medianReadLength: 108, n50ReadLength: 108,
            meanQuality: 0, q20Percentage: 0, q30Percentage: 0, gcContent: 0,
            readLengthHistogram: [88: 1, 98: 1, 108: 1, 118: 1], qualityScoreHistogram: [:],
            perPositionQuality: []
        )
        XCTAssertNil(
            FASTQStatisticsDisplayRules.storedStatisticsToShow(exactRoute),
            "the exact routes stored GC 0 and no scores for reads that have both"
        )
        let seqkitRow = FASTQDatasetStatistics(
            readCount: 4, baseCount: 412,
            meanReadLength: 103, minReadLength: 88, maxReadLength: 118,
            medianReadLength: 0, n50ReadLength: 0,
            meanQuality: 0, q20Percentage: 0, q30Percentage: 0, gcContent: 0,
            readLengthHistogram: [:], qualityScoreHistogram: [:],
            perPositionQuality: []
        )
        XCTAssertNil(
            FASTQStatisticsDisplayRules.storedStatisticsToShow(seqkitRow),
            "the cutadapt route stored a seqkit row with no length histogram, median 0 and N50 0"
        )
    }

    func testReadsWithNoScoresSayNoQualityScoresInPlaceOfMeanQQ20AndQ30() {
        let fasta = FASTQDatasetStatistics.measuringFASTA(text: ">a\nACGTGGCC\n>b\nGGCATT\n")
        XCTAssertEqual(FASTQStatisticsDisplayRules.meanQualityText(fasta), "No quality scores")
        XCTAssertEqual(FASTQStatisticsDisplayRules.q20Text(fasta), "No quality scores")
        XCTAssertEqual(FASTQStatisticsDisplayRules.q30Text(fasta), "No quality scores")

        XCTAssertEqual(FASTQStatisticsDisplayRules.meanQualityText(Self.scored), "18.4")
        XCTAssertEqual(FASTQStatisticsDisplayRules.q20Text(Self.scored), "60.0%")
        XCTAssertEqual(FASTQStatisticsDisplayRules.q30Text(Self.scored), "40.0%")
    }
}
