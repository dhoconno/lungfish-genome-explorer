// PhylogeneticTreeViewController+SubtreeExport.swift - Save name and failure alert for Export Subtree
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import LungfishCore

extension PhylogeneticTreeViewController {
    /// The save panel's suggested file name for an exported clade. Path
    /// separators become "_" and the stem is bounded so a long tip label
    /// cannot exceed the filesystem's name limit.
    static func subtreeExportSuggestedName(label: String) -> String {
        let cleaned = String(label.map { ($0 == "/" || $0 == ":") ? Character("_") : $0 })
        return "\(FileNameBudget.boundedStem(cleaned, pathExtension: "nwk")).nwk"
    }

    /// Tells the user why Export Subtree failed. Uses a sheet on the tree's
    /// window and never a modal run loop.
    func presentSubtreeExportFailure(_ error: Error) {
        guard let window = view.window else {
            NSSound.beep()
            return
        }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Export Subtree Failed"
        alert.informativeText = error.localizedDescription
        alert.addButton(withTitle: "OK")
        alert.beginSheetModal(for: window)
    }
}
