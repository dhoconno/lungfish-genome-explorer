// MainWindowController+DistanceMatrix.swift - Menu-bar routes for the MSA distance matrix
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit

/// The window controller sits at the end of the window's responder chain, so
/// it answers the nil-target distance matrix commands when focus is outside
/// the grid (the alignment, the sidebar or the Inspector) and forwards them
/// to the MSA viewport (rulings U2 and U8).
extension MainWindowController: DistanceMatrixMenuActions {
    var multipleSequenceAlignmentController: MultipleSequenceAlignmentViewController? {
        mainSplitViewController?.viewerController?.multipleSequenceAlignmentViewController
    }

    @objc func toggleDistanceMatrix(_ sender: Any?) {
        multipleSequenceAlignmentController?.toggleDistanceMatrix()
        syncDrawerToolbarButton()
    }

    @objc func showDistanceMatrix(_ sender: Any?) {
        multipleSequenceAlignmentController?.showDistanceMatrix()
        syncDrawerToolbarButton()
    }

    @objc func revealPairInAlignment(_ sender: Any?) {
        multipleSequenceAlignmentController?.distanceMatrixCommandTarget?.revealPairInAlignment(sender)
    }

    @objc func copyMatrix(_ sender: Any?) {
        multipleSequenceAlignmentController?.distanceMatrixCommandTarget?.copyMatrix(sender)
    }

    /// Export works whenever an MSA bundle is shown: it opens the Distances
    /// tab first when the matrix is hidden, so the exported options are the
    /// ones on screen.
    @objc func exportDistanceMatrix(_ sender: Any?) {
        guard let msa = multipleSequenceAlignmentController, msa.isDistanceMatrixAvailable else { return }
        if msa.distanceMatrixCommandTarget == nil { msa.showDistanceMatrix() }
        msa.bottomPane.distancePane.gridView.exportDistanceMatrix(sender)
        syncDrawerToolbarButton()
    }

    private func syncDrawerToolbarButton() {
        drawerToolbarButton?.state = mainSplitViewController?.viewerController?.isActiveDrawerOpen == true ? .on : .off
    }

    /// Validation for the distance matrix items; nil for any other item.
    func validateDistanceMatrixMenuItem(_ menuItem: NSMenuItem) -> Bool? {
        let msa = multipleSequenceAlignmentController
        switch menuItem.action {
        case #selector(toggleDistanceMatrix(_:)):
            menuItem.title = msa?.isDistanceMatrixShowing == true ? "Hide Distance Matrix" : "Show Distance Matrix"
            return msa?.isDistanceMatrixAvailable == true
        case #selector(showDistanceMatrix(_:)):
            return msa?.isDistanceMatrixAvailable == true
        case #selector(revealPairInAlignment(_:)), #selector(copyMatrix(_:)):
            guard let grid = msa?.distanceMatrixCommandTarget else { return false }
            return grid.validateMenuItem(menuItem)
        case #selector(exportDistanceMatrix(_:)):
            return msa?.isDistanceMatrixAvailable == true
        default:
            return nil
        }
    }
}
