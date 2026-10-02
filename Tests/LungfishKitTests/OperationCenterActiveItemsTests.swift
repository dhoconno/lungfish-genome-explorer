// OperationCenterActiveItemsTests.swift - Quit/close warning query helpers
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
@testable import LungfishKit
import LungfishKitTestSupport

/// Tests for the query helpers added so `applicationShouldTerminate`
/// and `windowShouldClose` can check for running operations before quitting
/// or closing a project window. `AppDelegate`/`MainWindowController`
/// themselves are AppKit lifecycle types with no seam for direct unit
/// testing here, so these tests cover the OperationCenter-side contract
/// those call sites depend on.
@MainActor
final class OperationCenterActiveItemsTests: XCTestCase {
    private var center: OperationCenter!

    override func setUp() {
        super.setUp()
        center = OperationCenter()
        center.failureReportStore = .temporaryForTesting()
    }

    override func tearDown() {
        center = nil
        super.tearDown()
    }

    func testActiveItemsIsEmptyWithNoOperations() {
        XCTAssertTrue(center.activeItems.isEmpty)
    }

    func testActiveItemsIncludesRunningButNotCompletedOrFailed() {
        let running = center.begin(
            title: "Running Op",
            detail: "in progress",
            operationType: .download,
            cliCommand: nil
        ).rowID
        let completed = center.begin(
            title: "Completed Op",
            detail: "done",
            operationType: .download,
            cliCommand: nil
        ).rowID
        _ = center.complete(id: completed, detail: "done")
        let failed = center.begin(title: "Failed Op", detail: "oops", operationType: .download, cliCommand: nil).rowID
        _ = center.fail(id: failed, detail: "oops")

        let activeIDs = Set(center.activeItems.map(\.id))
        XCTAssertEqual(activeIDs, [running])
    }

    func testActiveItemsIncludesCancellingState() {
        let id = center.begin(
            title: "Cancellable Op",
            detail: "in progress",
            operationType: .download,
            cliCommand: nil,
            onCancel: {}
        ).rowID
        center.cancel(id: id)

        XCTAssertEqual(center.items.first(where: { $0.id == id })?.state, .cancelling)
        XCTAssertTrue(center.activeItems.contains { $0.id == id })
    }

    func testActiveItemsForProjectURLFiltersByRouteContext() {
        let projectA = URL(fileURLWithPath: "/tmp/ProjectA.lungfish")
        let projectB = URL(fileURLWithPath: "/tmp/ProjectB.lungfish")

        let aOp = center.begin(
            title: "Project A Import",
            detail: "in progress",
            operationType: .download,
            cliCommand: nil,
            routeContext: OperationRouteContext(projectURL: projectA, windowStateScopeID: nil)
        ).rowID
        let bOp = center.begin(
            title: "Project B Import",
            detail: "in progress",
            operationType: .download,
            cliCommand: nil,
            routeContext: OperationRouteContext(projectURL: projectB, windowStateScopeID: nil)
        ).rowID

        let scopedToA = Set(center.activeItems(forProjectURL: projectA).map(\.id))
        XCTAssertEqual(scopedToA, [aOp])
        XCTAssertFalse(scopedToA.contains(bOp))

        let scopedToB = Set(center.activeItems(forProjectURL: projectB).map(\.id))
        XCTAssertEqual(scopedToB, [bOp])
    }

    /// An operation with no route context cannot be proven to belong to a
    /// different project, so a window-scoped close check must still warn
    /// about it rather than silently letting it be interrupted.
    func testActiveItemsForProjectURLIncludesOperationsWithNoRouteContext() {
        let projectA = URL(fileURLWithPath: "/tmp/ProjectA.lungfish")
        let unrouted = center.begin(
            title: "Unrouted Op",
            detail: "in progress",
            operationType: .download,
            cliCommand: nil
        ).rowID

        let scopedToA = center.activeItems(forProjectURL: projectA)
        XCTAssertTrue(scopedToA.contains { $0.id == unrouted })
    }

    func testActiveItemsForNilProjectURLReturnsAllActiveItems() {
        let op1 = center.begin(title: "Op 1", detail: "in progress", operationType: .download, cliCommand: nil).rowID
        let op2 = center.begin(title: "Op 2", detail: "in progress", operationType: .download, cliCommand: nil).rowID

        let all = Set(center.activeItems(forProjectURL: nil).map(\.id))
        XCTAssertEqual(all, [op1, op2])
    }
}
