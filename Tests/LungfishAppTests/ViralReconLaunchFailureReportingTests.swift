import LungfishKit
import XCTest
@testable import LungfishApp

/// A Viral Recon launch can fail before the run's own operation row exists:
/// executor validation, reference acquisition and input staging all run first.
/// Those failures used to go only to `debugLog`, so the user clicked Run and
/// saw absolutely nothing happen.
@MainActor
final class ViralReconLaunchFailureReportingTests: XCTestCase {
    func testLaunchFailureCreatesAFailedOperationRow() throws {
        let center = OperationCenter()

        AppDelegate.reportViralReconLaunchFailure(
            ViralReconWorkflowExecutionError.missingWorkflowDefinition,
            operationCenter: center,
            routeContext: nil
        )

        let item = try XCTUnwrap(center.items.first)
        XCTAssertEqual(item.state, .failed)
        XCTAssertEqual(item.title, "Viral Recon")
    }

    func testFailureRowCarriesTheUnderlyingReason() throws {
        let center = OperationCenter()

        AppDelegate.reportViralReconLaunchFailure(
            ViralReconWorkflowExecutionError.noProjectForResults,
            operationCenter: center,
            routeContext: nil
        )

        let item = try XCTUnwrap(center.items.first)
        let reason = ViralReconWorkflowExecutionError.noProjectForResults.localizedDescription
        XCTAssertEqual(item.detail, reason)
        XCTAssertEqual(item.errorDetail, reason)
    }

    func testFailureIsAlsoLoggedOnTheRow() throws {
        let center = OperationCenter()

        AppDelegate.reportViralReconLaunchFailure(
            ViralReconWorkflowExecutionError.missingWorkflowDefinition,
            operationCenter: center,
            routeContext: nil
        )

        let item = try XCTUnwrap(center.items.first)
        XCTAssertTrue(
            item.logEntries.contains { $0.level == .error },
            "the launch failure must appear in the row's history, not only in debugLog"
        )
    }

    // H-1: a non-zero exit is thrown only AFTER the run registered its own
    // operation row and failed that row with the stderr tail attached. Adding a
    // second row here showed the user two failed Viral Recon rows for one run,
    // the second one carrying strictly less information than the first.
    func testAFailureTheRunAlreadyReportedDoesNotCreateASecondRow() {
        let center = OperationCenter()

        let reported = AppDelegate.reportViralReconLaunchFailure(
            ViralReconWorkflowExecutionError.nonZeroExit(2),
            operationCenter: center,
            routeContext: nil
        )

        XCTAssertNil(reported)
        XCTAssertTrue(center.items.isEmpty)
    }

    // A cancelled launch is a user decision, not a defect, and must not leave a
    // failed row behind.
    func testCancellationIsNotReportedAsAFailure() {
        let center = OperationCenter()

        AppDelegate.reportViralReconLaunchFailure(
            CancellationError(),
            operationCenter: center,
            routeContext: nil
        )

        XCTAssertTrue(center.items.isEmpty)
    }
}
