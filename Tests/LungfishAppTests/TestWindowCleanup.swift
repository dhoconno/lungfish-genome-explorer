// TestWindowCleanup.swift - Orders out the windows a test opened and left on screen
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import XCTest

extension XCTestCase {
    /// Orders out, when the test ends, each window that appeared during the test and is still on screen. Use it where
    /// the test cannot reach the window to close it, such as the host window under a sheet that a helper presents or
    /// the window AppKit keeps for a save panel's accessory view after the panel is gone. Call it in `setUp`, so the
    /// windows already open stay as they are, and the test leaves no visible window (Phase 3.1 ruling
    /// QA-RELEASE-LOOP, section 5).
    @MainActor
    func orderOutWindowsOpenedDuringTest() {
        let before = Set(NSApplication.shared.windows.map(ObjectIdentifier.init))
        addTeardownBlock { @MainActor in
            for window in NSApplication.shared.windows where window.isVisible && !before.contains(ObjectIdentifier(window)) {
                if let sheet = window.attachedSheet { window.endSheet(sheet) }
                window.orderOut(nil)
            }
        }
    }
}
