// ViewerEsVirituOperationTests.swift - begin() site in ViewerViewController+EsViritu
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// The EsViritu viewer registers one row, the BLAST verification of a
// detection (R4). It locks no bundle. No lungfish-cli command BLASTs the reads
// of a detection, so the recorded command is a CLI parity gap and the test
// pins it.

import XCTest
@testable import LungfishApp
@testable import LungfishCLI
import LungfishKit
import LungfishKitTestSupport

@MainActor
final class ViewerEsVirituOperationTests: XCTestCase {
    func testDetectionBlastRowRecordsItsTitleTypeAndNoLock() throws {
        let reporter = RecordingOperationReporter()
        var launchedID: UUID?

        ViewerViewController.beginEsVirituBlastVerificationOperation(
            taxonName: "Hepatitis B virus",
            reporter: reporter
        ) { launchedID = $0 }

        let item = try XCTUnwrap(reporter.items.first)
        XCTAssertEqual(reporter.items.count, 1)
        XCTAssertEqual(launchedID, item.id)
        XCTAssertEqual(item.title, "BLAST Hepatitis B virus")
        XCTAssertEqual(item.initialDetail, "Preparing BLAST verification\u{2026}")
        XCTAssertEqual(item.operationType, .blastVerification)
        XCTAssertNil(item.targetBundleURL)
        XCTAssertEqual(item.additionalLockedBundleURLs, [])
        XCTAssertNil(item.routeContext)
    }

    func testDetectionBlastRowPinsTodaysCommandAsAParityGap() throws {
        let reporter = RecordingOperationReporter()

        ViewerViewController.beginEsVirituBlastVerificationOperation(
            taxonName: "Hepatitis B virus",
            reporter: reporter
        ) { _ in }

        let item = try XCTUnwrap(reporter.items.first)
        // CLI parity gap. No lungfish-cli command BLASTs the reads of an
        // EsViritu detection. The closest is `blast verify`, which covers a
        // Kraken2 classification only. It needs --kreport, --kraken-output,
        // --source and --taxid, and it has no --virus option. When a command
        // covers EsViritu detections, record it and replace this pin with a
        // parse test.
        XCTAssertEqual(item.cliCommand, "lungfish-cli blast verify --virus 'Hepatitis B virus'")
        XCTAssertEqual(
            try RecordedCLICommand.arguments(of: item.cliCommand),
            ["blast", "verify", "--virus", "Hepatitis B virus"]
        )
        XCTAssertThrowsError(try RecordedCLICommand.parse(item.cliCommand))
    }

    func testDetectionBlastLaunchesNothingWhenTheBeginIsRefused() {
        // No real center refuses this row, because it requests no lock. A
        // reporter that refuses every begin proves the launch closure sits
        // behind the `.started` case.
        let reporter = RecordingOperationReporter(lockHeldBy: "Importing BAM")
        var launched = false

        let result = ViewerViewController.beginEsVirituBlastVerificationOperation(
            taxonName: "Hepatitis B virus",
            reporter: reporter
        ) { _ in launched = true }

        guard case .refused = result else { return XCTFail("the helper must report the refusal") }
        XCTAssertFalse(launched, "a refused row must launch nothing")
        XCTAssertEqual(reporter.items.count, 1)
        XCTAssertEqual(reporter.items.first?.state, .refused)
    }
}
