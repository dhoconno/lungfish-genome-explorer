// ResultRowMenuValidation.swift - Shared focus rules for table-bound menu commands
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit

/// Focus rules every result table applies when it validates a menu item.
///
/// A command reaches a result table from two menus. The table's own context
/// menu follows the selection alone, because it only appears over the table.
/// The Selection > Table Row items and View > Expand All live in the menu
/// bar, where they reach the first responder's chain, so they are enabled
/// only while the table has keyboard focus and the selection supports the
/// command. Otherwise a stale table in another window would answer for a
/// shortcut aimed at a text field.
@MainActor
public enum ResultRowMenuValidation {
    /// True when `table`, or a view inside it such as a cell's field editor,
    /// is the key window's first responder.
    public static func tableHasKeyboardFocus(_ table: NSTableView) -> Bool {
        guard let responder = table.window?.firstResponder as? NSView else { return false }
        return responder === table || responder.isDescendant(of: table)
    }

    /// True when `item` belongs to one of `menus`, the context menus of the
    /// surface.
    public static func isContextMenuItem(_ item: NSMenuItem, in menus: [NSMenu?]) -> Bool {
        guard let owner = item.menu else { return false }
        return menus.contains { $0 === owner }
    }

    /// True when the item may act now: it is in a context menu of the
    /// surface, or the table has keyboard focus.
    public static func isReachable(
        _ item: NSMenuItem,
        table: NSTableView,
        contextMenus: [NSMenu?]? = nil
    ) -> Bool {
        isContextMenuItem(item, in: contextMenus ?? [table.menu]) || tableHasKeyboardFocus(table)
    }

    /// The accessibility custom actions for the commands `entries` that are
    /// available, each named by its title. `perform` receives the command
    /// when the action runs, after the caller has resolved the row.
    public static func cellActions(
        _ commands: [ResultRowCommand],
        on cellView: NSView,
        perform: @escaping @MainActor (_ command: ResultRowCommand, _ row: Int) -> Void
    ) -> [NSAccessibilityCustomAction] {
        commands.map { command in
            command.makeAccessibilityAction { [weak cellView] in
                guard let cellView, let row = AccessibilityCellActions.currentRow(of: cellView) else { return }
                perform(command, row)
            }
        }
    }
}
