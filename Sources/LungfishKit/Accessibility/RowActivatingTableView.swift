// RowActivatingTableView.swift - Return and Enter activate the selected table row
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit

/// A table whose selected row is activated by Return or Enter, the way a
/// double-click activates it.
///
/// Keyboard users and AX-driven automation cannot double-click, so every
/// table whose double-click does something (recentre the viewport, open a
/// sequence, navigate to a chromosome) is one of these. Everything else is
/// standard `NSTableView` behaviour, including arrow-key selection. Return
/// with no selection does nothing, so a stale row is never activated.
@MainActor
open class RowActivatingTableView: NSTableView {
    /// Called when Return or Enter is pressed with a row selected.
    public var onActivateSelectedRow: (() -> Void)?

    /// Whether the key event should activate the selected row: Return or
    /// Enter with no modifier other than the keypad or function flags.
    public static func activatesSelectedRow(keyCode: UInt16, modifierFlags: NSEvent.ModifierFlags) -> Bool {
        let isReturnOrEnter = keyCode == 36 || keyCode == 76
        let modifiers = modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting([.numericPad, .function])
        return isReturnOrEnter && modifiers.isEmpty
    }

    open override func keyDown(with event: NSEvent) {
        if Self.activatesSelectedRow(keyCode: event.keyCode, modifierFlags: event.modifierFlags),
           selectedRow >= 0,
           let onActivateSelectedRow {
            onActivateSelectedRow()
            return
        }
        super.keyDown(with: event)
    }
}
