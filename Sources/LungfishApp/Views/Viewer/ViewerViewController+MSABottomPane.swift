// ViewerViewController+MSABottomPane.swift - Drawer state and distance matrix export for the MSA viewport
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import LungfishIO

extension ViewerViewController {
    /// The reference viewport that covers this viewer, when it is a child on screen. The viewport draws its bundle
    /// in an embedded viewer that owns the drawer a person sees, and this viewer holds no bundle or index while the
    /// viewport covers it, so the drawer actions below go to the viewport instead of making an empty drawer here
    /// (lane DRAWER-ROUTE, WF-6).
    var drawerOwningReferenceViewport: ReferenceBundleViewportController? {
        guard let viewport = referenceBundleViewportController, viewport.parent === self else { return nil }
        return viewport
    }

    /// Open state of the drawer that View > Show Drawer and the window toolbar
    /// drawer button toggle for what is shown. The window controller reads it
    /// for the menu title and the button state.
    var isActiveDrawerOpen: Bool {
        if let taxTriageVC = taxTriageViewController { return taxTriageVC.isBlastDrawerOpen }
        if let taxVC = taxonomyViewController { return taxVC.isTaxaCollectionsDrawerOpen }
        if isDisplayingFASTQDataset { return isFASTQMetadataDrawerOpen }
        if let msa = multipleSequenceAlignmentViewController { return msa.isBottomPaneOpen }
        if let viewport = drawerOwningReferenceViewport { return viewport.isEmbeddedAnnotationDrawerOpen }
        return isAnnotationDrawerOpen
    }

    /// Keeps the window toolbar drawer button in step when the MSA toolbar,
    /// the Inspector or a menu route opens or closes the pane (review N5).
    func syncWindowDrawerToolbarButton() {
        (view.window?.windowController as? MainWindowController)?.syncDrawerToolbarButton()
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
