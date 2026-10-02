// ViewerAssemblyOperationTests.swift - begin() site in ViewerViewController+Assembly
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// The assembly viewer registers one row, the BLAST verification of the
// selected contigs (R4). It locks no bundle. No lungfish-cli command BLASTs
// contigs, so the recorded command is a CLI parity gap and the test pins it.

import XCTest
@testable import LungfishApp
@testable import LungfishCLI
import LungfishKit
import LungfishKitTestSupport

@MainActor
final class ViewerAssemblyOperationTests: XCTestCase {
    func testContigBlastRowRecordsItsTitleTypeAndNoLock() throws {
        let reporter = RecordingOperationReporter()
        var launchedID: UUID?

        ViewerViewController.beginAssemblyContigBlastVerificationOperation(
            sourceLabel: "contig contig_7",
            reporter: reporter
        ) { launchedID = $0 }

        let item = try XCTUnwrap(reporter.items.first)
        XCTAssertEqual(reporter.items.count, 1)
        XCTAssertEqual(launchedID, item.id)
        XCTAssertEqual(item.title, "BLAST contig contig_7")
        XCTAssertEqual(item.initialDetail, "Preparing contig BLAST\u{2026}")
        XCTAssertEqual(item.operationType, .blastVerification)
        XCTAssertNil(item.targetBundleURL)
        XCTAssertEqual(item.additionalLockedBundleURLs, [])
        XCTAssertNil(item.routeContext)
    }

    func testContigBlastRowPinsTodaysCommandAsAParityGap() throws {
        let reporter = RecordingOperationReporter()

        ViewerViewController.beginAssemblyContigBlastVerificationOperation(
            sourceLabel: "contig contig_7",
            reporter: reporter
        ) { _ in }

        let item = try XCTUnwrap(reporter.items.first)
        // CLI parity gap. No lungfish-cli command BLASTs assembled contigs. The
        // closest is `blast verify`, which covers a Kraken2 classification
        // only and needs --kreport, --kraken-output, --source and --taxid. When
        // a command covers contigs, record it and replace this pin with a
        // parse test.
        XCTAssertEqual(item.cliCommand, "lungfish-cli blast verify")
        XCTAssertEqual(try RecordedCLICommand.arguments(of: item.cliCommand), ["blast", "verify"])
        XCTAssertThrowsError(try RecordedCLICommand.parse(item.cliCommand))
    }

    func testContigBlastLaunchesNothingWhenTheBeginIsRefused() {
        // No real center refuses this row, because it requests no lock. A
        // reporter that refuses every begin proves the launch closure sits
        // behind the `.started` case.
        let reporter = RecordingOperationReporter(lockHeldBy: "Importing BAM")
        var launched = false

        let result = ViewerViewController.beginAssemblyContigBlastVerificationOperation(
            sourceLabel: "contig contig_7",
            reporter: reporter
        ) { _ in launched = true }

        guard case .refused = result else { return XCTFail("the helper must report the refusal") }
        XCTAssertFalse(launched, "a refused row must launch nothing")
        XCTAssertEqual(reporter.items.count, 1)
        XCTAssertEqual(reporter.items.first?.state, .refused)
    }
}
