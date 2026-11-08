// DemultiplexSummaryWordsTests.swift - The words `fastq demultiplex` prints for barcodes that could be chance matches
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 3.3 review DEMUXFLOOR-UX SF1. The summary named each barcode within chance as `D703 12`, printed one read as
// "1 reads" and never said the files were kept or what to check. Phase 3.3 lane DEMUXNULL item 9 adds what the chance
// count was measured on. UX set the words in review DEMUXNULL-UX.

import XCTest
@testable import LungfishWorkflow
@testable import LungfishCLI

final class DemultiplexSummaryWordsTests: XCTestCase {
    /// The limit of the floor, byte for byte (DEMUX-FLOOR-DECOY-MAX, rulings BIO-DECOY-MAX-STABLE and STB-R2-UX section D).
    private let notInPoolLine = "A barcode that is not in your pool can still pass as a sample. For each such barcode this "
        + "happens in about one run in 1,000, and more often in amplicon files. Check samples with few reads against "
        + "your sample sheet."

    /// BIO's measured false sample (ruling BIO-DECOY-MAX-STABLE section 1): 317 reads of one barcode over a ceiling of 45
    /// in 84,882 unassigned reads, the chance measured on the start composition. `withinChance` adds a second barcode with
    /// 3 reads under its ceiling.
    private func outcome(withinChance: Bool) -> DemultiplexChanceFloor.Outcome {
        var barcodes = [DemultiplexChanceFloor.BarcodeCount(barcodeID: "CAACTGCAACAT", readCount: 317, chanceCeiling: 45)]
        if withinChance {
            barcodes.append(DemultiplexChanceFloor.BarcodeCount(barcodeID: "D703", readCount: 3, chanceCeiling: 5))
        }
        return DemultiplexChanceFloor.Outcome(
            readsSearched: 85_199, chanceTrials: 84_882, barcodes: barcodes, null: .startComposition, margin: 86.92,
            compositionReads: 84_882
        )
    }

    /// A floor run that published a sample and names no barcode within chance prints the limit line alone.
    func testAFloorRunThatPublishesSaysABarcodeNotInThePoolCanStillPass() {
        XCTAssertEqual(
            FastqDemultiplexSubcommand.chanceSummaryLines(
                engine: .cutadapt, readCounts: [317, 0], chanceFloor: outcome(withinChance: false)
            ),
            [notInPoolLine]
        )
    }

    /// With a barcode within chance too, the within line prints first and the limit line follows it.
    func testAFloorRunWithABarcodeWithinChanceSaysTheWithinLineThenTheLimit() {
        let within = "Could be chance matches: D703 (3 reads). Reads that carry no barcode match a barcode by chance at this "
            + "error rate, and each of these holds no more reads than chance gives. The chance is measured on the first "
            + "bases of the Unassigned reads. Their files were kept, so check them against the samples you expect."
        XCTAssertEqual(
            FastqDemultiplexSubcommand.chanceSummaryLines(
                engine: .cutadapt, readCounts: [317, 3], chanceFloor: outcome(withinChance: true)
            ),
            [within, notInPoolLine]
        )
    }

    /// A run with no floor outcome, a Read Names run or one that searched nothing, says nothing about the pool.
    func testARunWithNoFloorOutcomeSaysNothingOfThePool() {
        XCTAssertEqual(
            FastqDemultiplexSubcommand.chanceSummaryLines(engine: .cutadapt, readCounts: [317, 0], chanceFloor: nil), []
        )
        XCTAssertEqual(
            FastqDemultiplexSubcommand.chanceSummaryLines(engine: .headerIndex, readCounts: [317, 0], chanceFloor: nil), []
        )
    }

    /// Exact Bare Barcode has no floor, so its words print alone and the limit of the floor never prints.
    func testExactBareRunsPrintOnlyTheirOwnWords() {
        XCTAssertEqual(
            FastqDemultiplexSubcommand.chanceSummaryLines(engine: .exactBareBarcode, readCounts: [317, 0], chanceFloor: nil),
            [DemultiplexEngine.exactBareChanceWords]
        )
    }

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
