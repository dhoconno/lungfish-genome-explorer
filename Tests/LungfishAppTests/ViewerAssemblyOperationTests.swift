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

    func testContigBlastRowRecordsNoCommandAsAParityGap() throws {
        let reporter = RecordingOperationReporter()

        ViewerViewController.beginAssemblyContigBlastVerificationOperation(
            sourceLabel: "contig contig_7",
            reporter: reporter
        ) { _ in }

        let item = try XCTUnwrap(reporter.items.first)
        // No lungfish-cli command BLASTs assembled contigs, so the row records
        // no command.
        XCTAssertNil(item.cliCommand)
        assertCLIParityGap(item.cliCommand, id: "blast-assembly")
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
