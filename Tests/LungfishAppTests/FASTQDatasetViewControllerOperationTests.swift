// FASTQDatasetViewControllerOperationTests.swift - begin() site in FASTQDatasetViewController
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// The Quality Report launch registers its row through a static begin helper
// (R4). The row locks no bundle, so a reporter that refuses every begin stands
// in for a refusal and proves the launch closure sits behind the `.started`
// case. The run computes its statistics in process with seqkit, and no
// lungfish-cli command reproduces it. `fastq qc-summary` is the closest, and it
// computes its statistics another way and writes a JSON file. The row keeps
// recording the seqkit description it has always recorded, so the test pins
// that text as a CLI parity gap. A command added later fails the pin and
// prompts a parse test in its place.

import XCTest
@testable import LungfishApp
import LungfishKit
import LungfishKitTestSupport

@MainActor
final class FASTQDatasetViewControllerOperationTests: XCTestCase {
    private let fastqURL = URL(fileURLWithPath: "/tmp/lane 1a2g/Project.lungfish/Imports/Sample 1.lungfishfastq/reads.fastq.gz")

    func testQualityReportRecordsItsRowAndTodaysDescriptionAsAParityGap() throws {
        let reporter = RecordingOperationReporter()
        var launchedID: UUID?

        let result = FASTQDatasetViewController.beginQualityReportOperation(
            fastqURL: fastqURL,
            reporter: reporter
        ) { launchedID = $0 }

        let item = try XCTUnwrap(reporter.items.first)
        XCTAssertEqual(reporter.items.count, 1)
        XCTAssertEqual(result.startedID, item.id)
        XCTAssertEqual(launchedID, item.id)
        XCTAssertEqual(item.title, "Quality Report")
        XCTAssertEqual(item.initialDetail, "reads.fastq.gz")
        XCTAssertEqual(item.operationType, .qualityReport)
        XCTAssertNil(item.targetBundleURL)
        XCTAssertEqual(item.additionalLockedBundleURLs, [])
        XCTAssertNil(item.routeContext)
        // CLI parity gap. The run calls seqkit in process and stores the result
        // in the dataset's metadata sidecar. The closest command is
        // `fastq qc-summary`, which computes its statistics with FASTQReader and
        // writes a JSON file. When a command reproduces the run, record it and
        // replace this pin with a parse test.
        XCTAssertEqual(
            item.cliCommand,
            "seqkit stats -a -T \(fastqURL.path) && (count Q20/Q30 bases)"
                + " && seqkit head -n 100000 \(fastqURL.path) | (sampled quality analysis)"
        )
        XCTAssertThrowsError(try RecordedCLICommand.parse(item.cliCommand)) { error in
            guard case RecordedCLICommand.ParseError.notALungfishCLICommand = error else {
                return XCTFail("The pin must fail because the text is not a lungfish-cli command, got \(error)")
            }
        }
    }

    func testRefusedQualityReportLaunchesNothing() {
        // No real center refuses this row, because it requests no lock. A
        // reporter that refuses every begin proves the launch closure sits
        // behind the `.started` case.
        let reporter = RecordingOperationReporter(lockHeldBy: "Importing BAM")
        var launched = false

        let result = FASTQDatasetViewController.beginQualityReportOperation(
            fastqURL: fastqURL,
            reporter: reporter
        ) { _ in launched = true }

        XCTAssertNil(result.startedID)
        XCTAssertFalse(launched, "a refused row must launch nothing")
        XCTAssertEqual(reporter.items.map(\.state), [.refused])
    }
}
