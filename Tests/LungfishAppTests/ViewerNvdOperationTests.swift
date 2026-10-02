// ViewerNvdOperationTests.swift - begin() site in ViewerViewController+Nvd
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// The NVD viewer registers one row, the BLAST verification of a contig (R4).
// It locks no bundle. No lungfish-cli command BLASTs an NVD contig, so the
// recorded command is a CLI parity gap and the test pins it.

import XCTest
@testable import LungfishApp
@testable import LungfishCLI
import LungfishKit
import LungfishKitTestSupport

@MainActor
final class ViewerNvdOperationTests: XCTestCase {
    private let contigName = "NODE_12 (1,205 bp)"
    private let classificationName = "Severe acute respiratory syndrome coronavirus 2"

    func testContigBlastRowRecordsItsTitleTypeAndNoLock() throws {
        let reporter = RecordingOperationReporter()
        var launchedID: UUID?

        ViewerViewController.beginNvdBlastVerificationOperation(
            contigName: contigName,
            classificationName: classificationName,
            taxId: 2_697_049,
            reporter: reporter
        ) { launchedID = $0 }

        let item = try XCTUnwrap(reporter.items.first)
        XCTAssertEqual(reporter.items.count, 1)
        XCTAssertEqual(launchedID, item.id)
        XCTAssertEqual(
            item.title,
            "BLAST NODE_12 (1,205 bp) \u{2014} Severe acute respiratory syndrome coronavirus 2"
        )
        XCTAssertEqual(item.initialDetail, "Preparing BLAST verification\u{2026}")
        XCTAssertEqual(item.operationType, .blastVerification)
        XCTAssertNil(item.targetBundleURL)
        XCTAssertEqual(item.additionalLockedBundleURLs, [])
        XCTAssertNil(item.routeContext)
    }

    func testContigBlastRowPinsTodaysCommandAsAParityGap() throws {
        let reporter = RecordingOperationReporter()

        ViewerViewController.beginNvdBlastVerificationOperation(
            contigName: contigName,
            classificationName: classificationName,
            taxId: 2_697_049,
            reporter: reporter
        ) { _ in }

        let item = try XCTUnwrap(reporter.items.first)
        // CLI parity gap. No lungfish-cli command BLASTs an NVD contig. The
        // closest is `blast verify`, which covers a Kraken2 classification
        // only and also needs --kreport, --kraken-output and --source. When a
        // command covers NVD contigs, record it and replace this pin with a
        // parse test.
        XCTAssertEqual(item.cliCommand, "lungfish-cli blast verify --taxid 2697049")
        XCTAssertEqual(try RecordedCLICommand.arguments(of: item.cliCommand), ["blast", "verify", "--taxid", "2697049"])
        XCTAssertThrowsError(try RecordedCLICommand.parse(item.cliCommand))
    }

    func testContigBlastLaunchesNothingWhenTheBeginIsRefused() {
        // No real center refuses this row, because it requests no lock. A
        // reporter that refuses every begin proves the launch closure sits
        // behind the `.started` case.
        let reporter = RecordingOperationReporter(lockHeldBy: "Importing BAM")
        var launched = false

        let result = ViewerViewController.beginNvdBlastVerificationOperation(
            contigName: contigName,
            classificationName: classificationName,
            taxId: 2_697_049,
            reporter: reporter
        ) { _ in launched = true }

        guard case .refused = result else { return XCTFail("the helper must report the refusal") }
        XCTAssertFalse(launched, "a refused row must launch nothing")
        XCTAssertEqual(reporter.items.count, 1)
        XCTAssertEqual(reporter.items.first?.state, .refused)
    }
}
