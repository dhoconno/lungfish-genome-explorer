// OperationReportingTests.swift - OperationCenter behind the OperationReporting protocol
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
@testable import LungfishKit

/// Operation code holds `any OperationReporting` (R4). These tests drive a
/// fresh `OperationCenter()` through the protocol, so the short forms in the
/// protocol extension must reach the same rows, locks and terminal states as
/// the class's own methods.
@MainActor
final class OperationReportingTests: XCTestCase {
    private let bundleURL = URL(fileURLWithPath: "/tmp/operation-reporting-fixture.lungfishref", isDirectory: true)

    func testBeginThroughTheProtocolRegistersTheRowWithTypeCommandAndLock() throws {
        let center = OperationCenter()
        let reporter: any OperationReporting = center
        let routeContext = OperationRouteContext(
            projectURL: URL(fileURLWithPath: "/tmp/Project.lungfish"),
            windowStateScopeID: UUID()
        )

        let result = reporter.begin(
            title: "Primer-trimming",
            detail: "Preparing primer trim...",
            operationType: .bamPrimerTrim,
            targetBundleURL: bundleURL,
            cliCommand: "lungfish-cli bam primer-trim --bundle /tmp/x.lungfishref",
            routeContext: routeContext
        )

        let id = try XCTUnwrap(result.startedID, "a free bundle must start")
        let row = try XCTUnwrap(center.items.first { $0.id == id })
        XCTAssertEqual(row.title, "Primer-trimming")
        XCTAssertEqual(row.detail, "Preparing primer trim...")
        XCTAssertEqual(row.operationType, .bamPrimerTrim)
        XCTAssertEqual(row.cliCommand, "lungfish-cli bam primer-trim --bundle /tmp/x.lungfishref")
        XCTAssertEqual(row.targetBundleURL, bundleURL)
        XCTAssertEqual(row.routeContext, routeContext)
        XCTAssertEqual(row.state, .running)
        XCTAssertEqual(center.activeLockHolder(for: bundleURL)?.id, id)
    }

    func testRefusalThroughTheProtocolKeepsTheHolderAndShowsTheBusyRow() throws {
        let center = OperationCenter()
        let holder = try XCTUnwrap(center.begin(
            title: "Calling variants with LoFreq",
            detail: "Running",
            operationType: .variantCalling,
            targetBundleURL: bundleURL,
            cliCommand: "lungfish-cli variants call"
        ).startedID)
        let reporter: any OperationReporting = center

        let result = reporter.begin(
            title: "Create Filtered Alignment Track",
            detail: "Preparing Exact Matches...",
            operationType: .bamImport,
            targetBundleURL: bundleURL,
            cliCommand: "lungfish-cli bam filter"
        )

        guard case .refused(let refusal) = result else {
            return XCTFail("a held bundle lock must refuse through the protocol too")
        }
        XCTAssertEqual(refusal.blockingOperationTitle, "Calling variants with LoFreq")
        XCTAssertEqual(
            refusal.message,
            "\"Calling variants with LoFreq\" is currently running on this bundle. Please wait for it to finish."
        )
        let busyRow = try XCTUnwrap(center.items.first { $0.id == refusal.id })
        XCTAssertEqual(busyRow.state, .failed)
        XCTAssertEqual(busyRow.errorMessage, "Bundle is busy")
        XCTAssertEqual(center.activeLockHolder(for: bundleURL)?.id, holder, "the refusal leaves the holder in place")
    }

    func testShortFormsReachTheSameRowAsTheClassMethods() throws {
        let center = OperationCenter()
        let reporter: any OperationReporting = center
        let id = try XCTUnwrap(reporter.begin(
            title: "Merge Reference Bundles",
            detail: "Preparing",
            operationType: .bundleBuild,
            cliCommand: nil
        ).startedID)

        XCTAssertTrue(reporter.updateWithLog(id: id, progress: 0.4, detail: "Concatenating sequences"))
        reporter.log(id: id, level: .warning, message: "One source had no annotations")
        reporter.setCommand(id: id, command: "lungfish-cli bundle create")

        let row = try XCTUnwrap(center.items.first { $0.id == id })
        XCTAssertEqual(row.detail, "Concatenating sequences")
        XCTAssertEqual(row.progress, 0.4, accuracy: 0.0001)
        XCTAssertEqual(row.cliCommand, "lungfish-cli bundle create")
        XCTAssertEqual(row.logEntries.map(\.message), ["Concatenating sequences", "One source had no annotations"])

        XCTAssertTrue(reporter.fail(id: id, detail: "Merge failed", errorMessage: "No FASTA"))
        XCTAssertFalse(reporter.complete(id: id, detail: "too late"), "a finished row takes no second terminal call")
        let failed = try XCTUnwrap(center.items.first { $0.id == id })
        XCTAssertEqual(failed.state, .failed)
        XCTAssertEqual(failed.errorMessage, "No FASTA")
    }

    func testCancelThroughTheProtocolReachesTheWorkerAndAcknowledgementReleasesTheLock() throws {
        let center = OperationCenter()
        let reporter: any OperationReporting = center
        let cancelReachedWorker = expectation(description: "onCancel reaches the worker")
        let id = try XCTUnwrap(reporter.begin(
            title: "Primer-trimming",
            detail: "Running",
            operationType: .bamPrimerTrim,
            targetBundleURL: bundleURL,
            cliCommand: "lungfish-cli bam primer-trim",
            onCancel: { cancelReachedWorker.fulfill() }
        ).startedID)

        reporter.cancel(id: id)
        // OperationCenter hands onCancel to a global queue, so wait for it.
        wait(for: [cancelReachedWorker], timeout: 5)
        XCTAssertTrue(reporter.acknowledgeCancellation(id: id))
        XCTAssertEqual(center.items.first { $0.id == id }?.state, .cancelled)
        XCTAssertEqual(center.items.first { $0.id == id }?.detail, "Cancelled by user")
        XCTAssertTrue(center.canStartOperation(on: bundleURL))
    }

    func testRequireStartedReturnsTheIDOrThrowsTheRefusal() throws {
        let id = UUID()
        XCTAssertEqual(try OperationStartResult.started(id).requireStarted(), id)

        let refusal = OperationStartRefusal(id: UUID(), blockedBy: "Importing BAM", message: "Bundle is busy")
        XCTAssertThrowsError(try OperationStartResult.refused(refusal).requireStarted()) { error in
            XCTAssertEqual((error as? OperationRefusedError)?.refusal.blockingOperationTitle, "Importing BAM")
        }
    }

    func testRefusedErrorCarriesTheRefusalMessage() {
        let refusal = OperationStartRefusal(
            id: UUID(),
            blockedBy: "Importing BAM",
            message: "\"Importing BAM\" is currently running on this bundle. Please wait for it to finish."
        )
        let error = OperationRefusedError(refusal)
        XCTAssertEqual(error.refusal.blockingOperationTitle, "Importing BAM")
        XCTAssertEqual(error.localizedDescription, refusal.message)
    }
}
