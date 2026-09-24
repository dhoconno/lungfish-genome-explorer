// OperationCenterActiveItemsTests.swift - FEA-06 quit/close warning query helpers
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
@testable import LungfishKit

/// Tests for the query helpers FEA-06 added so `applicationShouldTerminate`
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
    }

    override func tearDown() {
        center = nil
        super.tearDown()
    }

    func testActiveItemsIsEmptyWithNoOperations() {
        XCTAssertTrue(center.activeItems.isEmpty)
    }

    func testActiveItemsIncludesRunningButNotCompletedOrFailed() {
        let running = center.start(title: "Running Op", detail: "in progress")
        let completed = center.start(title: "Completed Op", detail: "done")
        _ = center.complete(id: completed, detail: "done")
        let failed = center.start(title: "Failed Op", detail: "oops")
        _ = center.fail(id: failed, detail: "oops")

        let activeIDs = Set(center.activeItems.map(\.id))
        XCTAssertEqual(activeIDs, [running])
    }

    func testActiveItemsIncludesCancellingState() {
        let id = center.start(title: "Cancellable Op", detail: "in progress", onCancel: {})
        center.cancel(id: id)

        XCTAssertEqual(center.items.first(where: { $0.id == id })?.state, .cancelling)
        XCTAssertTrue(center.activeItems.contains { $0.id == id })
    }

    func testActiveItemsForProjectURLFiltersByRouteContext() {
        let projectA = URL(fileURLWithPath: "/tmp/ProjectA.lungfish")
        let projectB = URL(fileURLWithPath: "/tmp/ProjectB.lungfish")

        let aOp = center.start(
            title: "Project A Import",
            detail: "in progress",
            routeContext: OperationRouteContext(projectURL: projectA, windowStateScopeID: nil)
        )
        let bOp = center.start(
            title: "Project B Import",
            detail: "in progress",
            routeContext: OperationRouteContext(projectURL: projectB, windowStateScopeID: nil)
        )

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
        let unrouted = center.start(title: "Unrouted Op", detail: "in progress")

        let scopedToA = center.activeItems(forProjectURL: projectA)
        XCTAssertTrue(scopedToA.contains { $0.id == unrouted })
    }

    func testActiveItemsForNilProjectURLReturnsAllActiveItems() {
        let op1 = center.start(title: "Op 1", detail: "in progress")
        let op2 = center.start(title: "Op 2", detail: "in progress")

        let all = Set(center.activeItems(forProjectURL: nil).map(\.id))
        XCTAssertEqual(all, [op1, op2])
    }
}
