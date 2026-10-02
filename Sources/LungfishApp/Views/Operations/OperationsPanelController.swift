// OperationsPanelController.swift - Operations window for operation progress
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import Combine
import LungfishCore
import LungfishKit

/// A normal app window that displays all running, completed, and failed
/// operations tracked by ``OperationCenter``.
///
/// Accessed via the Operations menu (Shift-Option-Cmd-O) or programmatically.
@MainActor
final class OperationsPanelController: NSWindowController {

    init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 650),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: true
        )
        window.title = "Operations"
        window.level = .normal
        window.isReleasedWhenClosed = false
        window.isRestorable = false
        window.minSize = NSSize(width: 700, height: 530)
        window.center()

        super.init(window: window)

        let viewController = OperationsPanelViewController()
        window.contentViewController = viewController
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

// MARK: - Elapsed Time Formatting

/// Formats a time interval into a compact human-readable elapsed time string.
///
/// Formatting tiers:
/// - Less than 1 second: `"<1s"`
/// - 1--59 seconds: `"42s"`
/// - 1--59 minutes: `"3m 12s"`
/// - 1 hour or more: `"1h 23m"`
///
/// Negative intervals are clamped to zero and displayed as `"<1s"`.
///
/// Delegates to ``LungfishFormatters/formatDuration(_:)-`` (F46), the
/// canonical duration formatter shared across the app.
func formatElapsedTime(_ interval: TimeInterval) -> String {
    LungfishFormatters.formatDuration(interval)
}
