// OperationsMenuCancelTests.swift - The Operations menu's Cancel item reaches its sheet (WALKFIX, W-13)
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import XCTest
@testable import LungfishApp
@testable import LungfishWorkflow
import LungfishKit
import LungfishKitTestSupport
import LungfishTestSupport

/// W-13 of the 2026-11-05 walk. The Operations menu's "Cancel ... (Running)" item did nothing, with no sheet and no
/// cancel. Its action was `cancelOperation:`, which is also `NSResponder`'s own method, so the first responder (a table,
/// a text view, the window) took the action and the app delegate never saw it. The action has its own name now, and no
/// responder implements it.
@MainActor
final class OperationsMenuCancelTests: XCTestCase {
    func testCancelItemReachesTheAppDelegateWithATableAsFirstResponder() throws {
        _ = NSApplication.shared
        OperationCenter.shared.cancelAll()
        OperationCenter.shared.clearCompleted()
        let operationID = OperationCenter.shared.begin(
            title: "Reference download",
            detail: "Downloading",
            operationType: .download,
            cliCommand: nil,
            onCancel: {}
        ).rowID
        defer {
            _ = OperationCenter.shared.fail(id: operationID, detail: "cleanup")
            OperationCenter.shared.clearCompleted()
        }

        let mainMenu = MainMenu.createMainMenu()
        let operationsMenu = try XCTUnwrap(mainMenu.items.first { $0.title == "Operations" }?.submenu)
        OperationsMenuDelegate.shared.menuNeedsUpdate(operationsMenu)
        let cancelItem = try XCTUnwrap(operationsMenu.items.first)
        XCTAssertTrue(cancelItem.isEnabled, "a running operation that can be cancelled has an enabled item")
        let action = try XCTUnwrap(cancelItem.action, "the item has an action")
        XCTAssertNil(cancelItem.target, "the item keeps no target, so the responder chain decides")

        // A window whose first responder is a table, as the main window's sidebar or a results table is.
        let table = NSTableView(frame: NSRect(x: 0, y: 0, width: 300, height: 200))
        table.addTableColumn(NSTableColumn(identifier: NSUserInterfaceItemIdentifier("name")))
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 300, height: 200))
        scroll.documentView = table
        let window = NSWindow(contentRect: scroll.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = scroll
        window.setFrameOrigin(NSPoint(x: -30_000, y: -30_000))
        window.makeKeyAndOrderFront(nil)
        XCTAssertTrue(window.makeFirstResponder(table), "the table takes the first responder")

        let appDelegate = AppDelegate()
        let previousDelegate = NSApp.delegate
        NSApp.delegate = appDelegate
        defer {
            NSApp.delegate = previousDelegate
            window.contentView = nil
            window.close()
        }

        XCTAssertFalse(
            NSResponder.instancesRespond(to: action),
            "\(NSStringFromSelector(action)) is a method of NSResponder, so the first responder takes it"
        )
        XCTAssertFalse(table.responds(to: action), "the table does not answer the Cancel item")
        let target = NSApp.target(forAction: action, to: cancelItem.target, from: cancelItem)
        XCTAssertTrue(
            target as AnyObject === appDelegate,
            "the Cancel item reaches \(String(describing: target)) and not the app delegate"
        )
    }
}
