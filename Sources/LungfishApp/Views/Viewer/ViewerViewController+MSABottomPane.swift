// ViewerViewController+MSABottomPane.swift - Drawer state and distance matrix export for the MSA viewport
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import LungfishIO

extension ViewerViewController {
    /// Open state of the drawer that View > Show Drawer and the window toolbar
    /// drawer button toggle for what is shown. The window controller reads it
    /// for the menu title and the button state.
    var isActiveDrawerOpen: Bool {
        if let taxTriageVC = taxTriageViewController { return taxTriageVC.isBlastDrawerOpen }
        if let taxVC = taxonomyViewController { return taxVC.isTaxaCollectionsDrawerOpen }
        if isDisplayingFASTQDataset { return isFASTQMetadataDrawerOpen }
        if let msa = multipleSequenceAlignmentViewController { return msa.isBottomPaneOpen }
        return isAnnotationDrawerOpen
    }

    /// Export Matrix as TSV… from the Distances pane or the menu bar (ruling U8).
    func exportMSADistanceMatrixViaCLI(bundleURL: URL, options: MSADistanceOptions) {
        MSADistanceMatrixExportCoordinator.export(
            bundleURL: bundleURL,
            options: options,
            window: view.window,
            windowStateScope: windowStateScope
        )
    }
}
