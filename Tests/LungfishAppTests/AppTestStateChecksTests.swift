// AppTestStateChecksTests.swift - The App checks of the test-state observer find a row and a window and restore them
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import XCTest
import LungfishKit
import LungfishTestSupport
@testable import LungfishApp

/// Phase 3.1 ruling QA-RELEASE-LOOP, section 4, item 5. Each test restores what it made through the check itself, so
/// the observer finds nothing at its end.
@MainActor
final class AppTestStateChecksTests: XCTestCase {
    func testTheBootstrapRegistersTheAppChecksInThisBundle() {
        XCTAssertEqual(Array(TestStateObserver.checkNames.suffix(3)), AppTestStateChecks.names)
    }

    func testTheRowCheckNamesARowBegunInTheTestAndTheRestoreEndsIt() {
        let check = AppTestStateChecks.operationRowsCheck()
        let before = check.snapshot()
        let id = OperationCenter.shared.begin(
            title: "Observer probe", detail: "running", operationType: .download, cliCommand: nil
        ).rowID
        let after = check.snapshot()
        let keys = TestStateObserver.leakedKeys(before: before, after: after, comparison: check.comparison)
        check.restore(keys, before)
        XCTAssertEqual(keys, [id.uuidString])
        XCTAssertEqual(after[id.uuidString], "\"Observer probe\" (\(OperationType.download), running)")
        XCTAssertFalse(OperationCenter.shared.activeItems.contains { $0.id == id }, "the restore ended the row")
        XCTAssertFalse(OperationCenter.shared.items.contains { $0.id == id }, "and cleared it")
    }

    func testTheWindowCheckNamesAVisibleKeyWindowAndTheRestoreOrdersItOut() {
        _ = NSApplication.shared
        let check = AppTestStateChecks.visibleWindowsCheck()
        let before = check.snapshot()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 120, height: 80), styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.title = "Observer probe"
        window.orderFront(nil)
        let after = check.snapshot()
        let keys = TestStateObserver.leakedKeys(before: before, after: after, comparison: check.comparison)
        check.restore(keys, before)
        XCTAssertEqual(keys, [String(window.windowNumber)])
        XCTAssertFalse(window.isVisible, "the restore ordered the window out")
    }
}
