// ViewerViewController+RNASeq.swift - App wiring of the RNA-seq result surface
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import LungfishRNASeqUI

extension ViewerViewController {
    /// Wires what the App owns for the RNA-seq result surface. The registered-bundle route sets no content mode, so a
    /// shown result sets `.genomics`, whose Inspector tabs include Provenance, and gives the Inspector the result's name.
    func wireRNASeqResult(_ surface: RNASeqResultSurface) {
        surface.onLoaded = { [weak self] facts, bundleURL in
            guard let self else { return }
            self.contentMode = .genomics
            (self.parent as? MainSplitViewController)?.inspectorController.updateRNASeqResultDocument(
                name: facts.name,
                bundleURL: bundleURL
            )
        }
        // Save Selection as Labels Table… and Pseudobulk Selected Cells… of a cell map run `lungfish-cli rnaseq cell-map select`.
        surface.onSelectionAction = { [weak self] action in
            let projectURL = (self?.parent as? MainSplitViewController)?.sidebarController?.currentProjectURL
            RNASeqCellMapSelectRun.perform(action, projectURL: projectURL, routeContext: nil)
        }
    }
}
