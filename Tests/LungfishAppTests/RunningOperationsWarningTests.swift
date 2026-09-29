// RunningOperationsWarningTests.swift - Quit/close warnings with running operations
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import XCTest
@testable import LungfishApp
@testable import LungfishKit

@MainActor
final class RunningOperationsWarningTests: XCTestCase {

    func testWarningPointsAtTheOperationsPanelInterruptedRow() {
        let center = OperationCenter()
        let id = center.start(title: "EsViritu SRR12486983", detail: "Running")
        let items = center.activeItems
        XCTAssertEqual(items.map(\.id), [id])
        for kind in [RunningOperationsWarning.Kind.quit, .closeWindow] {
            let text = RunningOperationsWarning.informativeText(kind: kind, operations: items)
            XCTAssertTrue(text.contains("Operations Panel"), text)
            XCTAssertTrue(text.contains("Interrupted"), text)
            XCTAssertFalse(text.contains("Manage Project Storage"), text)
            XCTAssertTrue(text.contains("• EsViritu SRR12486983"), text)
        }
        XCTAssertEqual(RunningOperationsWarning.messageText(kind: .quit, count: 1), "Quit with 1 Operation Running?")
        XCTAssertEqual(
            RunningOperationsWarning.messageText(kind: .closeWindow, count: 2),
            "Close Window with 2 Operations Running?"
        )
    }
}
