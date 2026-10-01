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
/// activates only when exactly one row is selected. With none or several
/// selected the table beeps, so a stale or arbitrary row is never activated.
@MainActor
open class RowActivatingTableView: NSTableView {
    /// Called when Return or Enter is pressed with a row selected.
    public var onActivateSelectedRow: (() -> Void)?

    /// Called instead of activating when Return is pressed without exactly
    /// one selected row. Beeps by default.
    public var rejectActivation: () -> Void = { NSSound.beep() }

    /// Whether the key event should activate the selected row: Return or
    /// Enter with no modifier other than the keypad or function flags.
    public static func activatesSelectedRow(keyCode: UInt16, modifierFlags: NSEvent.ModifierFlags) -> Bool {
        let isReturnOrEnter = keyCode == 36 || keyCode == 76
        let modifiers = modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting([.numericPad, .function])
        return isReturnOrEnter && modifiers.isEmpty
    }

    open override func keyDown(with event: NSEvent) {
        if Self.activatesSelectedRow(keyCode: event.keyCode, modifierFlags: event.modifierFlags),
           let onActivateSelectedRow {
            if numberOfSelectedRows == 1 {
                onActivateSelectedRow()
            } else {
                rejectActivation()
            }
            return
        }
        super.keyDown(with: event)
    }
}
