// DemultiplexSummaryWordsTests.swift - The words `fastq demultiplex` prints for barcodes that could be chance matches
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 3.3 review DEMUXFLOOR-UX SF1. The summary named each barcode within chance as `D703 12`, printed one read as
// "1 reads" and never said the files were kept or what to check. Phase 3.3 lane DEMUXNULL item 9 adds what the chance
// count was measured on. UX set the words in review DEMUXNULL-UX.

import XCTest
import LungfishWorkflow
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

    /// DEMUX-EXACT-BARE-NO-FLOOR (ruling UX-EXACT-BARE-WORDS): the words, byte for byte, and when they print.
    func testExactBareSummarySaysItDoesNotCheckForChanceMatchesOnlyWhenItMadeASampleFile() {
        XCTAssertEqual(
            DemultiplexEngine.exactBareChanceWords,
            "Exact Bare Barcode does not check for chance matches. On reads that do not carry the chosen barcodes in "
                + "their sequence, such as reads whose index is only in the read names, it can make sample files from "
                + "chance matches. Check the sample files against the samples you expect."
        )
        XCTAssertEqual(
            FastqDemultiplexSubcommand.exactBareChanceSummary(.exactBareBarcode, barcodesWithReads: 2),
            DemultiplexEngine.exactBareChanceWords
        )
        XCTAssertNil(FastqDemultiplexSubcommand.exactBareChanceSummary(.exactBareBarcode, barcodesWithReads: 0))
        XCTAssertNil(FastqDemultiplexSubcommand.exactBareChanceSummary(.cutadapt, barcodesWithReads: 2))
        XCTAssertNil(FastqDemultiplexSubcommand.exactBareChanceSummary(.headerIndex, barcodesWithReads: 2))
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
