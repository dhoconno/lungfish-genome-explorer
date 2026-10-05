// MainSplitViewController+MSAInspector.swift - Connect the MSA viewport to the Inspector
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit

extension MainSplitViewController {
    /// Routes the MSA viewport's selection and focused distance pair to the
    /// Inspector while `isCurrent` holds, then publishes the first selection.
    /// A selection the Distances pane drives updates Selected Item but keeps
    /// the Inspector's tab, so the Bundle tab's Pairwise Distance breakdown
    /// stays in view while the user walks the matrix (review S1). The focused
    /// pair is a programmatic sync and never switches tabs either.
    func wireMultipleSequenceAlignmentInspector(
        _ controller: MultipleSequenceAlignmentViewController,
        isCurrent: @escaping @MainActor () -> Bool
    ) {
        controller.onSelectionStateChanged = { [weak self, weak controller] state in
            guard let self, isCurrent() else { return }
            if controller?.isDistancePaneDrivingSelection == true {
                self.inspectorController.holdsTabOnNextMSASelection = true
            }
            self.inspectorController.updateMultipleSequenceAlignmentSelection(state)
        }
        controller.onFocusedDistancePairChanged = { [weak self] pair in
            guard let self, isCurrent() else { return }
            self.inspectorController.updateMSAFocusedDistancePair(pair)
        }
        inspectorController.viewModel.documentSectionViewModel.msaPairwiseDistance?.onShowDistanceMatrix = {
            [weak controller] in controller?.showDistanceMatrix()
        }
        controller.notifySelectionStateIfAvailable()
    }
}
