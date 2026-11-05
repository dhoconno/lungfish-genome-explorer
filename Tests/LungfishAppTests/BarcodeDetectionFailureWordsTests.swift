// BarcodeDetectionFailureWordsTests.swift - Detect barcodes says that no search ran when the kit gave it nothing to search for
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 3.2 lane ALERTS (W-18, ruling WALK-UX item 11). Detect on the default kit, TruSeq Single Index Set A, raised
// "The barcode search stopped before it finished" and told the person to check that the FASTQ file is complete, while
// the details said that no barcode sequence could be built and that nothing ran. The file was sound. The scout raises
// those two errors from its adapter check before any search tool starts, so the body now says no search ran and gives
// the kit's cause and what to try. A search tool that did start and failed keeps the older words
// (RemainingSiteFailureReportsTests).

import XCTest
import LungfishIO
import LungfishKit
import LungfishWorkflow
@testable import LungfishApp

final class BarcodeDetectionFailureWordsTests: XCTestCase {
    private func defaultKitName() throws -> String {
        try XCTUnwrap(BarcodeKitRegistry.kit(byID: "truseq-single-a")).displayName
    }

    func testAKitWithNoSearchSequencesSaysNoSearchRanAndNamesTheKit() throws {
        let kit = try defaultKitName()
        let report = ViewerFailureReports.detectBarcodes(DemultiplexError.emptyAdapterSequences(kitName: kit))

        XCTAssertFalse(report.whatHappened.contains("stopped"), "nothing ran, so nothing stopped: \(report.whatHappened)")
        XCTAssertTrue(report.whatHappened.contains(kit), "the body names the kit: \(report.whatHappened)")
        XCTAssertTrue(report.whatHappened.contains("No search was run"), "the body says nothing ran: \(report.whatHappened)")
        XCTAssertFalse(report.nextStep.contains("FASTQ file is complete"), "the file is not the cause: \(report.nextStep)")
        XCTAssertTrue(report.nextStep.contains("different kit"), "the next step offers another kit: \(report.nextStep)")
        XCTAssertTrue(report.nextStep.contains("Custom Definition"), "the next step offers the way out: \(report.nextStep)")
        XCTAssertTrue(
            report.details?.contains("No barcode sequences could be built") ?? false,
            "the tool's own text stays in the details: \(String(describing: report.details))"
        )
    }

    func testAKitWhoseBarcodesShareASearchSequenceSaysNoSearchRanToo() throws {
        let kit = try defaultKitName()
        let report = ViewerFailureReports.detectBarcodes(DemultiplexError.ambiguousAdapterSequences(kitName: kit))

        XCTAssertFalse(report.whatHappened.contains("stopped"), "nothing ran, so nothing stopped: \(report.whatHappened)")
        XCTAssertTrue(report.whatHappened.contains(kit), "the body names the kit: \(report.whatHappened)")
        XCTAssertTrue(report.whatHappened.contains("No search was run"), "the body says nothing ran: \(report.whatHappened)")
        XCTAssertTrue(report.whatHappened.contains("same search sequence"), "the body gives the cause: \(report.whatHappened)")
        XCTAssertFalse(report.nextStep.contains("FASTQ file is complete"), "the file is not the cause: \(report.nextStep)")
        XCTAssertTrue(report.nextStep.contains("Custom Definition"), "the next step offers the way out: \(report.nextStep)")
    }

    func testASearchToolThatStartedAndFailedStillSaysTheSearchStopped() {
        let error = DemultiplexError.cutadaptFailed(exitCode: 1, stderr: "cutadapt: error: bad adapter")
        let report = ViewerFailureReports.detectBarcodes(error)

        XCTAssertTrue(report.whatHappened.contains("stopped before it finished"), "a search that ran can stop: \(report.whatHappened)")
        XCTAssertTrue(report.nextStep.contains("FASTQ file is complete"), "the file is a fair thing to check then: \(report.nextStep)")
    }
}
