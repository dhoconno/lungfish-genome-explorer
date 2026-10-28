// PhylogeneticTreeViewController+SubtreeExport.swift - Save name and failure alert for Export Subtree
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import LungfishCore
import LungfishKit

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
        FailurePresenter.present(Self.subtreeExportFailure(error), in: window)
    }

    /// The words of the Export Subtree failure. The error's text goes only to
    /// the details area (ALERT-PRESENTER, Phase 3.1).
    static func subtreeExportFailure(_ error: any Error) -> FailureReport {
        FailureReport(
            failedStep: "Export the subtree",
            whatHappened: "The Newick file of the selected clade was not saved.",
            nextStep: "Check that the folder you chose can be written to and has free space, then export the subtree again.",
            underlying: error
        )
    }
}
