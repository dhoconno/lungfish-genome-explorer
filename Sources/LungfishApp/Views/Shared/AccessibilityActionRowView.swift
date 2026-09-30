// AccessibilityActionRowView.swift - Table row that exposes custom AX actions
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit

/// A table row view whose accessibility custom actions are computed on demand.
///
/// Context menus are invisible to VoiceOver and to background automation that
/// drives the app through the accessibility API. A row that adopts this view
/// publishes the same commands as `accessibilityCustomActions`, so an AX client
/// can list and perform them without a right-click. The provider runs each
/// time the actions are requested, so a row whose item changes state (running
/// to completed, for example) always reports the commands that currently
/// apply without the table having to rebuild its row views.
@MainActor
final class AccessibilityActionRowView: NSTableRowView {
    /// Returns the actions that currently apply to this row.
    var actionProvider: (() -> [NSAccessibilityCustomAction])?

    override func accessibilityCustomActions() -> [NSAccessibilityCustomAction]? {
        let actions = actionProvider?() ?? []
        return actions.isEmpty ? nil : actions
    }

    /// Builds one custom action whose handler runs on the main actor.
    static func makeAction(
        name: String,
        handler: @escaping @MainActor () -> Void
    ) -> NSAccessibilityCustomAction {
        NSAccessibilityCustomAction(name: name) {
            MainActor.assumeIsolated {
                handler()
            }
            return true
        }
    }
}
