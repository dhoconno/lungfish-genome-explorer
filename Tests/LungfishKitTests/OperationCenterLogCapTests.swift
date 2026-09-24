// OperationCenterLogCapTests.swift - PERF-15 bounded operation log history
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
@testable import LungfishKit

/// PERF-15: `OperationCenter.Item.logEntries` used to grow without a cap
/// through `log`/`updateWithLog`, and 132 production call sites append to it,
/// some carrying full tool stderr. These tests pin the retention cap added to
/// stop that unbounded growth.
@MainActor
final class OperationCenterLogCapTests: XCTestCase {
    private var center: OperationCenter!

    override func setUp() {
        super.setUp()
        center = OperationCenter()
    }

    override func tearDown() {
        center = nil
        super.tearDown()
    }

    func testTenThousandLogCallsLeaveAtMostTheRetentionCap() {
        let id = center.start(title: "Long Op", detail: "starting")

        for index in 0..<10_000 {
            center.log(id: id, level: .info, message: "step \(index)")
        }

        let item = try! XCTUnwrap(center.items.first(where: { $0.id == id }))
        XCTAssertLessThanOrEqual(item.logEntries.count, OperationCenter.Item.maxRetainedLogEntries)

        // The oldest entries are preserved...
        XCTAssertEqual(item.logEntries.first?.message, "step 0")
        // ...and the most recent entry is always present.
        XCTAssertEqual(item.logEntries.last?.message, "step 9999")
        // ...joined by exactly one elision marker.
        let markers = item.logEntries.filter(\.isElisionMarker)
        XCTAssertEqual(markers.count, 1)
    }

    func testHasWarningsStaysCorrectAfterEntriesAreElided() {
        let id = center.start(title: "Long Op With Warning", detail: "starting")

        // One warning near the very start of the log, buried well before the
        // point where elision would otherwise discard it if the cap dropped
        // arbitrary entries instead of always keeping the first N.
        center.log(id: id, level: .warning, message: "early warning")
        for index in 0..<10_000 {
            center.log(id: id, level: .info, message: "step \(index)")
        }

        let item = try! XCTUnwrap(center.items.first(where: { $0.id == id }))
        XCTAssertTrue(item.hasWarnings, "A warning within the retained first-N window must still be visible")
        XCTAssertLessThanOrEqual(item.logEntries.count, OperationCenter.Item.maxRetainedLogEntries)
    }

    func testHasWarningsSeesRecentWarningsAfterElision() {
        let id = center.start(title: "Long Op With Late Warning", detail: "starting")

        for index in 0..<10_000 {
            center.log(id: id, level: .info, message: "step \(index)")
        }
        center.log(id: id, level: .warning, message: "late warning")

        let item = try! XCTUnwrap(center.items.first(where: { $0.id == id }))
        XCTAssertTrue(item.hasWarnings, "A warning in the retained tail must still be visible")
    }

    func testLogCountBelowCapIsNeverElided() {
        let id = center.start(title: "Short Op", detail: "starting")

        for index in 0..<50 {
            center.log(id: id, level: .info, message: "step \(index)")
        }

        let item = try! XCTUnwrap(center.items.first(where: { $0.id == id }))
        XCTAssertEqual(item.logEntries.count, 50)
        XCTAssertFalse(item.logEntries.contains(where: \.isElisionMarker))
    }
}
