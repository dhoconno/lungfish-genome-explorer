// DemultiplexSummaryWordsTests.swift - The words `fastq demultiplex` prints for barcodes that could be chance matches
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 3.3 review DEMUXFLOOR-UX SF1. The summary named each barcode within chance as `D703 12`, printed one read as
// "1 reads" and never said the files were kept or what to check. Phase 3.3 lane DEMUXNULL item 9 adds what the chance
// count was measured on. UX set the words in review DEMUXNULL-UX.

import XCTest
@testable import LungfishCLI

final class DemultiplexSummaryWordsTests: XCTestCase {
    func testWithinChanceSummaryNamesEachBarcodeWithItsReadsAndSaysTheChanceIsMeasuredOnThisFilesReads() {
        XCTAssertEqual(
            FastqDemultiplexSubcommand.withinChanceSummary(
                [(barcodeID: "D703", readCount: 12), (barcodeID: "D704", readCount: 1)], null: .startComposition
            ),
            "Could be chance matches: D703 (12 reads), D704 (1 read). Reads that carry no barcode match a barcode by "
                + "chance at this error rate, and each of these holds no more reads than chance gives. The chance is "
                + "measured on the first bases of the Unassigned reads. Their files were kept, so check them against "
                + "the samples you expect."
        )
        XCTAssertNil(FastqDemultiplexSubcommand.withinChanceSummary([], null: .startComposition))
        XCTAssertNil(FastqDemultiplexSubcommand.withinChanceSummary([], null: .randomBases))
    }

    func testWithinChanceSummarySaysWhyTheChanceIsMeasuredOnRandomBases() {
        XCTAssertEqual(
            FastqDemultiplexSubcommand.withinChanceSummary([(barcodeID: "D703", readCount: 3)], null: .randomBases),
            "Could be chance matches: D703 (3 reads). Reads that carry no barcode match a barcode by chance at this "
                + "error rate, and each of these holds no more reads than chance gives. The chance is worked out as if "
                + "A, C, G and T were equally likely, because the Unassigned reads could not measure it. Their files "
                + "were kept, so check them against the samples you expect."
        )
    }
}
