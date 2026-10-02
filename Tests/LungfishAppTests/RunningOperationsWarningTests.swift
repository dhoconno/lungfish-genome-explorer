// RunningOperationsWarningTests.swift - Quit/close warnings with running operations
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import XCTest
@testable import LungfishApp
@testable import LungfishKit
import LungfishKitTestSupport

@MainActor
final class RunningOperationsWarningTests: XCTestCase {

    func testWarningPointsAtTheOperationsPanelInterruptedRow() {
        let center = OperationCenter()
        let id = center.begin(
            title: "EsViritu SRR12486983",
            detail: "Running",
            operationType: .download,
            cliCommand: nil
        ).rowID
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

    func testOpenWarningDropsRunsThatFinishAndSaysWhenNothingIsLeft() {
        let center = OperationCenter()
        let kraken = center.begin(
            title: "Kraken2 SRR12486989",
            detail: "Running",
            operationType: .download,
            cliCommand: nil
        ).rowID
        let esviritu = center.begin(
            title: "EsViritu SRR12486983",
            detail: "Running",
            operationType: .download,
            cliCommand: nil
        ).rowID
        let alert = NSAlert()
        alert.addButton(withTitle: "Cancel Operations and Quit").hasDestructiveAction = true
        alert.addButton(withTitle: "Don't Quit")
        let live = LiveRunningOperationsAlert(alert: alert, kind: .quit, center: center) {
            center.activeItems
        }
        defer { live.stop() }
        XCTAssertEqual(alert.messageText, "Quit with 2 Operations Running?")
        XCTAssertTrue(alert.informativeText.contains("Kraken2 SRR12486989"))

        XCTAssertTrue(center.complete(id: kraken, detail: "Done"))
        XCTAssertEqual(alert.messageText, "Quit with 1 Operation Running?")
        XCTAssertFalse(alert.informativeText.contains("Kraken2"), alert.informativeText)
        XCTAssertEqual(live.operations.map(\.id), [esviritu])

        XCTAssertTrue(center.complete(id: esviritu, detail: "Done"))
        XCTAssertTrue(live.operations.isEmpty)
        XCTAssertEqual(alert.messageText, "All Operations Have Finished")
        XCTAssertEqual(alert.buttons.first?.title, "Quit")
        XCTAssertEqual(alert.buttons.first?.hasDestructiveAction, false)
    }
}
