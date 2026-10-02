// RecordingOperationReporterTests.swift - The OperationReporting test double behaves like OperationCenter
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
import LungfishKit
import LungfishKitTestSupport

/// Launch-site tests trust `RecordingOperationReporter` to record what a site
/// registered and to refuse like a held bundle lock (R4). These tests pin the
/// double to `OperationCenter`'s behaviour where the two must agree.
@MainActor
final class RecordingOperationReporterTests: XCTestCase {
    private let bundleURL = URL(fileURLWithPath: "/tmp/recording-reporter-fixture.lungfishref", isDirectory: true)

    func testBeginRecordsTitleTypeLockAndANonNilCommand() throws {
        let reporter = RecordingOperationReporter()
        let routeContext = OperationRouteContext(projectURL: nil, windowStateScopeID: UUID())

        let result = reporter.begin(
            title: "Calling variants with LoFreq",
            detail: "Preparing LoFreq...",
            operationType: .variantCalling,
            targetBundleURL: bundleURL,
            additionalLockedBundleURLs: [bundleURL.deletingLastPathComponent()],
            cliCommand: "lungfish-cli variants call --bundle /tmp/recording-reporter-fixture.lungfishref",
            routeContext: routeContext
        )

        let id = try XCTUnwrap(result.startedID)
        let item = try XCTUnwrap(reporter.items.first)
        XCTAssertEqual(reporter.items.count, 1)
        XCTAssertEqual(item.id, id)
        XCTAssertEqual(item.title, "Calling variants with LoFreq")
        XCTAssertEqual(item.initialDetail, "Preparing LoFreq...")
        XCTAssertEqual(item.operationType, .variantCalling)
        XCTAssertEqual(item.targetBundleURL, bundleURL)
        XCTAssertEqual(item.additionalLockedBundleURLs, [bundleURL.deletingLastPathComponent()])
        XCTAssertEqual(item.routeContext, routeContext)
        XCTAssertNotNil(item.cliCommand, "every operation records the command that reproduces it")
        XCTAssertEqual(item.state, .running)
        XCTAssertEqual(reporter.startedItems.map(\.id), [id])
    }

    func testLockHeldByRefusesWithOperationCentersMessageAndRecordsTheRequest() throws {
        let reporter = RecordingOperationReporter(lockHeldBy: "Importing BAM")

        let result = reporter.begin(
            title: "Create Filtered Alignment Track",
            detail: "Preparing Exact Matches...",
            operationType: .bamImport,
            targetBundleURL: bundleURL,
            cliCommand: "lungfish-cli bam filter"
        )

        guard case .refused(let refusal) = result else {
            return XCTFail("lockHeldBy must make begin refuse")
        }
        let center = OperationCenter()
        _ = center.begin(
            title: "Importing BAM",
            detail: "Running",
            operationType: .bamImport,
            targetBundleURL: bundleURL,
            cliCommand: nil
        )
        guard case .refused(let centerRefusal) = center.begin(
            title: "Create Filtered Alignment Track",
            detail: "Preparing Exact Matches...",
            operationType: .bamImport,
            targetBundleURL: bundleURL,
            cliCommand: "lungfish-cli bam filter"
        ) else {
            return XCTFail("a held lock must refuse in OperationCenter")
        }
        XCTAssertEqual(refusal.blockingOperationTitle, centerRefusal.blockingOperationTitle)
        XCTAssertEqual(refusal.message, centerRefusal.message)

        let item = try XCTUnwrap(reporter.item(refusal.id))
        XCTAssertEqual(item.state, .refused)
        XCTAssertEqual(item.targetBundleURL, bundleURL, "the refused request still shows the lock the site asked for")
        XCTAssertTrue(reporter.startedItems.isEmpty)
        XCTAssertFalse(reporter.update(id: refusal.id, progress: 0.5, detail: "must not run"))
        XCTAssertFalse(reporter.complete(id: refusal.id, detail: "must not complete"))
    }

    func testProgressLogsAndTerminalCallsAreRecordedOnce() throws {
        let reporter = RecordingOperationReporter()
        let id = try XCTUnwrap(reporter.begin(
            title: "Merge Reference Bundles",
            detail: "Preparing",
            operationType: .bundleBuild,
            cliCommand: nil
        ).startedID)

        XCTAssertTrue(reporter.update(id: id, progress: 0.1, detail: "Inspecting"))
        XCTAssertTrue(reporter.updateWithLog(id: id, progress: 0.3, detail: "Concatenating"))
        reporter.log(id: id, level: .warning, message: "No annotations in B")
        reporter.setCommand(id: id, command: "lungfish-cli bundle create")
        let outputURL = URL(fileURLWithPath: "/tmp/Merged.lungfishref")
        XCTAssertTrue(reporter.complete(id: id, detail: "Merged 2 reference bundles", bundleURLs: [outputURL]))
        XCTAssertFalse(reporter.fail(id: id, detail: "late failure"), "a finished item takes no second terminal call")
        XCTAssertFalse(reporter.update(id: id, progress: 0.9, detail: "late progress"))

        let item = try XCTUnwrap(reporter.item(id))
        XCTAssertEqual(item.progressUpdates.map(\.progress), [0.1, 0.3])
        XCTAssertEqual(item.logs.map(\.message), ["Concatenating", "No annotations in B"])
        XCTAssertEqual(item.cliCommand, "lungfish-cli bundle create")
        XCTAssertEqual(item.state, .completed)
        XCTAssertEqual(item.detail, "Merged 2 reference bundles")
        XCTAssertEqual(item.bundleURLs, [outputURL])
        XCTAssertNil(item.failure)
    }

    func testFailureRecordsMessageAndDetail() throws {
        let reporter = RecordingOperationReporter()
        let id = try XCTUnwrap(reporter.begin(
            title: "BLAST Influenza A",
            detail: "Preparing",
            operationType: .blastVerification,
            cliCommand: "lungfish-cli blast verify"
        ).startedID)

        XCTAssertTrue(reporter.fail(id: id, detail: "BLAST failed", errorMessage: "No sequences", errorDetail: "trace"))

        let item = try XCTUnwrap(reporter.item(id))
        XCTAssertEqual(item.state, .failed)
        XCTAssertEqual(item.failure?.detail, "BLAST failed")
        XCTAssertEqual(item.failure?.errorMessage, "No sequences")
        XCTAssertEqual(item.failure?.errorDetail, "trace")
    }

    func testCancelRunsTheCallbackAndWinsOverALaterCompletion() throws {
        let reporter = RecordingOperationReporter()
        let cancelled = XCTestExpectation(description: "the cancel callback runs")
        let id = try XCTUnwrap(reporter.begin(
            title: "Extract Respiratory Viruses",
            detail: "Preparing",
            operationType: .taxonomyExtraction,
            cliCommand: "# batch pipeline"
        ).startedID)
        reporter.setCancelCallback(for: id) { cancelled.fulfill() }

        reporter.cancel(id: id)

        // A zero timeout passes only when the callback already ran, which is
        // what the double promises: cancel(id:) calls it synchronously.
        XCTAssertEqual(XCTWaiter().wait(for: [cancelled], timeout: 0), .completed)
        XCTAssertEqual(reporter.item(id)?.state, .cancelling)
        XCTAssertFalse(reporter.complete(id: id, detail: "Extracted 3 taxa"), "cancellation wins over a late completion")
        let item = try XCTUnwrap(reporter.item(id))
        XCTAssertEqual(item.state, .cancelled)
        XCTAssertEqual(item.detail, "Cancelled by user")
        XCTAssertTrue(item.cancelRequested)
    }
}
