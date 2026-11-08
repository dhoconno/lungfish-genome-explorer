// SidebarOutlineView.swift - The sidebar's outline, which marks the selections a person asked for
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import os

/// The sidebar's outline view.
///
/// It marks a selection a person asked for as explicit while the selection is made: a context-menu or Inspector
/// link select, the Operations panel's Results button, the select after an import or a run, an accessibility client's
/// select of the outline's rows (`AXSelectedRows`), and AppKit's own select of one row element (`AXSelected`) made
/// without the outline's focus, which is marked only for the first select of the row AppKit proposed, made in the
/// run-loop turn of that request and ending in a selection notice.
/// The shown result's focus rule (`MainSplitViewController.sidebarShouldAcceptSelection(_:explicit:)`) lets an
/// explicit selection through even when the outline is not the first responder. A click or a key in the outline needs
/// no mark, because the outline is then the first responder.
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

    // MARK: - AppKit's own select of one row element

    /// An AX client's `AXSelected` on one row element (AppKit's `NSOutlineRow`) never reaches the entries above.
    /// AppKit's user path asks the delegate's `outlineView(_:shouldSelectItem:)`, calls `selectRowIndexes`, then posts
    /// the selection notice, all inside the one request. This token carries the mark across those three calls only.
    /// The first select spends it. Only that first select, when it is not an extension, names exactly the proposed row
    /// and item and changes the rows, promotes it (the override cannot tell AppKit's call from the app's, so the notice
    /// and the turn bound it). The first notice of any kind takes it, and the end of the run-loop turn that armed it
    /// clears it. Each way fails closed.
    private struct ProposedSelect: Sendable {
        let row: Int
        let item: ObjectIdentifier
        let generation: UInt64
        var selecting = false
    }

    private struct ProposedSelectState: Sendable {
        var token: ProposedSelect?
        var generation: UInt64 = 0
    }

    private nonisolated let proposedSelect = OSAllocatedUnfairLock(initialState: ProposedSelectState())

    /// The proposed item itself, held weakly, so a freed item's address never matches a new one.
    private weak var proposedItem: AnyObject?

    /// True while a proposed select's token is held.
    var isHoldingProposedSelect: Bool { proposedSelect.withLock { $0.token != nil } }

    /// Arms the token for `item` at `row`. The delegate calls it only for a select that changes the rows.
    func noteSelectProposedWithoutFocus(row: Int, item: AnyObject) {
        proposedItem = item
        let identity = ObjectIdentifier(item)
        let generation = proposedSelect.withLock { state -> UInt64 in
            state.generation &+= 1
            state.token = ProposedSelect(row: row, item: identity, generation: state.generation)
            return state.generation
        }
        let held = proposedSelect
        RunLoop.main.perform(inModes: [.common]) {
            held.withLock { state in
                if state.token?.generation == generation { state.token = nil }
            }
        }
    }

    override func selectRowIndexes(_ indexes: IndexSet, byExtendingSelection extend: Bool) {
        if let proposed = spendProposedSelect(), !proposed.selecting, !extend,
           indexes == IndexSet(integer: proposed.row), indexes != selectedRowIndexes, rowHolds(proposed) {
            var selecting = proposed
            selecting.selecting = true
            let promoted = selecting
            proposedSelect.withLock { $0.token = promoted }
        }
        super.selectRowIndexes(indexes, byExtendingSelection: extend)
    }

    /// Takes the token. True only for the select AppKit proposed and made in this request.
    func takeProposedSelect() -> Bool {
        guard let proposed = spendProposedSelect(), proposed.selecting,
              selectedRowIndexes == IndexSet(integer: proposed.row) else { return false }
        return rowHolds(proposed)
    }

    private func spendProposedSelect() -> ProposedSelect? {
        proposedSelect.withLock { state -> ProposedSelect? in
            defer { state.token = nil }
            return state.token
        }
    }

    /// True when the proposed row still shows the proposed item, by identity.
    private func rowHolds(_ proposed: ProposedSelect) -> Bool {
        guard let shown = item(atRow: proposed.row) as AnyObject?, let proposedItem else { return false }
        return shown === proposedItem && ObjectIdentifier(shown) == proposed.item
    }
}
