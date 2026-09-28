// DemoProjectsSheetHostTests.swift - Which window Help > Demo Projects… attaches to
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import XCTest
@testable import LungfishApp

/// With the app in the background, Help > Demo Projects… hung its sheet on
/// whichever project window came first in `NSApp.windows`. The sheet now
/// attaches to the key or main window only, else opens on its own.
@MainActor
final class DemoProjectsSheetHostTests: XCTestCase {
    private var windows: [NSWindow] = []

    override func tearDown() async throws {
        windows.forEach { $0.orderOut(nil) }
        windows = []
    }

    private func visibleWindow() -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: -4000, y: -4000, width: 200, height: 120),
            styleMask: [.titled], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        window.orderFront(nil)
        windows.append(window)
        return window
    }

    func testNoKeyOrMainWindowOpensStandaloneEvenWithOtherWindowsVisible() {
        _ = NSApplication.shared
        let other = visibleWindow()
        XCTAssertTrue(other.isVisible)
        XCTAssertNil(DemoProjectsSheetController.hostWindow(keyWindow: nil, mainWindow: nil))
    }

    func testKeyWindowWinsThenMainWindow() {
        _ = NSApplication.shared
        let key = visibleWindow()
        let main = visibleWindow()
        XCTAssertTrue(DemoProjectsSheetController.hostWindow(keyWindow: key, mainWindow: main) === key)
        XCTAssertTrue(DemoProjectsSheetController.hostWindow(keyWindow: nil, mainWindow: main) === main)

        let hidden = NSWindow(contentRect: .zero, styleMask: [.titled], backing: .buffered, defer: true)
        hidden.isReleasedWhenClosed = false
        XCTAssertTrue(DemoProjectsSheetController.hostWindow(keyWindow: hidden, mainWindow: main) === main,
                      "a window that is not on screen cannot host the sheet")
    }
}
