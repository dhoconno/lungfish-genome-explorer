// AccessibilityCellActions.swift - Custom AX actions for table rows
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit

/// Publishes a table row's commands as accessibility custom actions.
///
/// Context menus are invisible to VoiceOver and to background automation that
/// drives the app through the accessibility API. AppKit exposes each table row
/// as a private proxy element whose children are cell proxies, and only the
/// cell proxies forward `AXCustomActions`, to the `NSTableCellView` they stand
/// for. Actions set on an `NSTableRowView` are never read. So the actions are
/// installed on every cell view of the row from the delegate's cell callback,
/// which the table runs again whenever the row is reused or reloaded.
///
/// Handlers resolve the row from the cell at the moment they run, with
/// `NSTableView.row(for:)`, never from an index captured when the cell was
/// built, because cell views are recycled as the table scrolls.
@MainActor
enum AccessibilityCellActions {
    /// Installs `actions` on `cellView`, or clears them when the list is empty.
    static func install(_ actions: [NSAccessibilityCustomAction], on cellView: NSView) {
        cellView.setAccessibilityCustomActions(actions.isEmpty ? nil : actions)
    }

    /// The row a cell view currently shows, or nil when it is not in a table.
    static func currentRow(of cellView: NSView) -> Int? {
        guard let tableView = enclosingTableView(of: cellView) else { return nil }
        let row = tableView.row(for: cellView)
        return row >= 0 ? row : nil
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

    private static func enclosingTableView(of view: NSView) -> NSTableView? {
        var current = view.superview
        while let candidate = current {
            if let table = candidate as? NSTableView { return table }
            current = candidate.superview
        }
        return nil
    }
}
