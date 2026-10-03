// AppDelegateMenuActionsOperationTests.swift - begin() site in AppDelegate+MenuActions
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// The `operations-failed-operation` UI test scenario seeds one failed row
// through a static begin helper (R4). The row is a fixture, not an operation.
// MainWindowNavigationXCUITests opens the Operations panel, presses the report
// button on the failed row and checks that the GitHub issue URL names the row's
// title. These tests keep that row as the XCUI test expects it, and pin the
// fixture command, which no lungfish-cli command reproduces.

import XCTest
@testable import LungfishApp
import LungfishKit
import LungfishKitTestSupport

@MainActor
final class AppDelegateMenuActionsOperationTests: XCTestCase {
    func testFailureSeedRecordsItsRowWithNoLockAndNoCommandAsAnExemptFixture() throws {
        let reporter = RecordingOperationReporter()
        var launchedID: UUID?

        AppDelegate.beginOperationsPanelFailureSeedOperation(reporter: reporter) { launchedID = $0 }

        let item = try XCTUnwrap(reporter.items.first)
        XCTAssertEqual(launchedID, item.id)
        XCTAssertEqual(item.title, "UI test failed operation")
        XCTAssertEqual(item.initialDetail, "Preparing deterministic failure")
        XCTAssertEqual(item.operationType, .classification)
        XCTAssertNil(item.targetBundleURL)
        XCTAssertEqual(item.additionalLockedBundleURLs, [])
        XCTAssertNil(item.routeContext)
        // cli-parity-exempt: not-an-operation. No run stands behind this
        // fixture row, so it records no command.
        XCTAssertNil(item.cliCommand)
        XCTAssertThrowsError(try RecordedCLICommand.parseScript(item.cliCommand))
    }

    func testFailureSeedLeavesTheFailedRowTheXCUITestExpects() throws {
        let reporter = RecordingOperationReporter()

        AppDelegate.seedOperationsPanelFailure(on: reporter)

        XCTAssertEqual(reporter.items.count, 1)
        let item = try XCTUnwrap(reporter.items.first)
        // The XCUI test needs a failed row whose title the issue URL carries.
        XCTAssertEqual(item.state, .failed)
        XCTAssertEqual(item.title, "UI test failed operation")
        XCTAssertEqual(item.detail, "Deterministic failure used by XCUI")
        XCTAssertEqual(item.failure?.detail, "Deterministic failure used by XCUI")
        XCTAssertEqual(item.failure?.errorMessage, "UI test failure")
        XCTAssertEqual(
            item.failure?.errorDetail,
            "This fixture exercises the Operations panel GitHub issue action."
        )
        XCTAssertEqual(item.logs.map(\.message), ["UI test seeded operation"])
        XCTAssertEqual(item.logs.map(\.level), [.info])
    }

    func testFailureSeedRefusedBeginLaunchesNothing() throws {
        // The row requests no lock, so no real center refuses it. A reporter
        // that refuses every begin proves the launch sits behind `.started`.
        let reporter = RecordingOperationReporter(lockHeldBy: "Importing BAM")
        var launched = false

        let result = AppDelegate.beginOperationsPanelFailureSeedOperation(reporter: reporter) { _ in
            launched = true
        }

        guard case .refused = result else {
            return XCTFail("a refused begin must not seed the failed row")
        }
        XCTAssertFalse(launched)
        XCTAssertEqual(reporter.items.map(\.state), [.refused])

        AppDelegate.seedOperationsPanelFailure(on: reporter)

        XCTAssertEqual(reporter.items.map(\.state), [.refused, .refused], "a refused seed logs and fails nothing")
        XCTAssertTrue(reporter.items.allSatisfy { $0.logs.isEmpty && $0.failure == nil })
    }
}
