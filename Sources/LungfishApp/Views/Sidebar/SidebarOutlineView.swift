// SidebarOutlineView.swift - The sidebar's outline, which marks the selections a person asked for
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit

/// The sidebar's outline view.
///
/// It marks a selection a person asked for as explicit while the selection is made: a context-menu or Inspector
/// link select, the Operations panel's Results button, the select after an import or a run, and an accessibility
/// select (VoiceOver, Voice Control, the Accessibility Inspector). The shown result's focus rule
/// (`MainSplitViewController.sidebarShouldAcceptSelection(_:explicit:)`) lets an explicit selection through even when
/// the outline is not the first responder. A click or a key in the outline needs no mark, because the outline is then
/// the first responder.
final class SidebarOutlineView: NSOutlineView {
    private var explicitSelectionDepth = 0

    /// True while a selection a person asked for is being made.
    var isMakingExplicitSelection: Bool { explicitSelectionDepth > 0 }

    /// Runs `body`, whose selection change a person asked for, with the explicit mark set.
    func withExplicitSelection<T>(_ body: () throws -> T) rethrows -> T {
        explicitSelectionDepth += 1
        defer { explicitSelectionDepth -= 1 }
        return try body()
    }

    /// Selects `indexes`, marked as a selection a person asked for when `explicit` is true.
    func selectRowIndexes(_ indexes: IndexSet, byExtendingSelection extend: Bool, explicit: Bool) {
        guard explicit else { return selectRowIndexes(indexes, byExtendingSelection: extend) }
        withExplicitSelection { selectRowIndexes(indexes, byExtendingSelection: extend) }
    }
}
