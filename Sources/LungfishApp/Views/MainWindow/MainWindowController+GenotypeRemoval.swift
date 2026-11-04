// MainWindowController+GenotypeRemoval.swift - A genotype result viewer leaves with its window
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit

extension MainWindowController {
    /// The window is closing, and `windowShouldClose` has settled any manual haplotype draft. No route clears the
    /// viewer on this way out, so a genotype viewer runs its removal here while the window still answers for Undo,
    /// and a matrix edit still waiting on the workbook goes on to be saved after the window has gone.
    @objc public func windowWillClose(_ notification: Notification) {
        mainSplitViewController?.viewerController?.hideGenotypeResultView()
    }
}
