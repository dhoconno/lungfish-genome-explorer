// MainSplitViewController+InspectorClear.swift - Clear the Inspector and keep the row it shows
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit

extension MainSplitViewController {
    /// Clears the Inspector for the row the window now shows, and gives the Inspector that row's content identity
    /// again, which `clearSelection()` sets to nil. With the identity kept, a late notification that names only the
    /// URL of the dataset just left is refused, so that dataset's block cannot refill beside the new row
    /// (INSPECTOR-CLEAR-IDENTITY-UNSET).
    func clearInspectorKeepingRowIdentity() {
        inspectorController.clearSelection()
        inspectorController.activeContentSelectionIdentity = activeContentSelectionIdentity
    }
}
