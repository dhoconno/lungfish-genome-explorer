// SidebarOutlineView.swift - The sidebar's outline, which marks the selections a person asked for
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import os

/// The sidebar's outline view.
///
/// It marks a selection a person asked for as explicit while the selection is made: a context-menu or Inspector
/// link select, the Operations panel's Results button, the select after an import or a run, and an accessibility
/// select (VoiceOver, Voice Control, the Accessibility Inspector). The shown result's focus rule
/// (`MainSplitViewController.sidebarShouldAcceptSelection(_:explicit:)`) lets an explicit selection through even when
/// the outline is not the first responder. A click or a key in the outline needs no mark, because the outline is then
/// the first responder.
final class SidebarOutlineView: NSOutlineView {
    /// How many explicit scopes are open now. A lock holds it, because the accessibility attribute override below is
    /// not main-actor isolated and the concurrency-hatches ratchet allows no new `MainActor.assumeIsolated`.
    private nonisolated let explicitSelectionDepth = OSAllocatedUnfairLock(initialState: 0)

    /// True while a selection a person asked for is being made.
    var isMakingExplicitSelection: Bool { explicitSelectionDepth.withLock { $0 > 0 } }

    /// Runs `body`, whose selection change a person asked for, with the explicit mark set.
    func withExplicitSelection<T>(_ body: () throws -> T) rethrows -> T {
        explicitSelectionDepth.withLock { $0 += 1 }
        defer { explicitSelectionDepth.withLock { $0 -= 1 } }
        return try body()
    }

    /// Selects `indexes`, marked as a selection a person asked for when `explicit` is true.
    func selectRowIndexes(_ indexes: IndexSet, byExtendingSelection extend: Bool, explicit: Bool) {
        guard explicit else { return selectRowIndexes(indexes, byExtendingSelection: extend) }
        withExplicitSelection { selectRowIndexes(indexes, byExtendingSelection: extend) }
    }

    /// An accessibility client's select (AXSelectedRows) leaves the focus where it was, so it is marked explicit.
    /// Without the mark the focus rule would send a VoiceOver user's select back to the row before. The rows pass to
    /// super untouched: AppKit's own row elements need not conform to `NSAccessibilityRow`, and reading one as such
    /// traps.
    override func setAccessibilitySelectedRows(_ accessibilitySelectedRows: [any NSAccessibilityRow]) {
        withExplicitSelection { super.setAccessibilitySelectedRows(accessibilitySelectedRows) }
    }

    /// An AX client's attribute request (AXUIElementSetAttributeValue on AXSelectedRows) reaches the outline here, and
    /// NSTableView selects from it without calling `setAccessibilitySelectedRows`, so it is marked explicit here too.
    override func accessibilitySetValue(_ value: Any?, forAttribute attribute: NSAccessibility.Attribute) {
        guard attribute == .selectedRows else { return super.accessibilitySetValue(value, forAttribute: attribute) }
        // The attribute API is not main-actor isolated, so the depth sits behind a lock, not behind a main-actor hop.
        explicitSelectionDepth.withLock { $0 += 1 }
        defer { explicitSelectionDepth.withLock { $0 -= 1 } }
        super.accessibilitySetValue(value, forAttribute: attribute)
    }
}
