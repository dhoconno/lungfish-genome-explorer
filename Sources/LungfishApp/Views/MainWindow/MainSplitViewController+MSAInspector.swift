// MainSplitViewController+MSAInspector.swift - Connect the MSA viewport to the Inspector
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit

extension MainSplitViewController {
    /// Routes the MSA viewport's selection and focused distance pair to the
    /// Inspector while `isCurrent` holds, then publishes the first selection.
    /// A selection the Distances pane drives goes through the same
    /// `updateMultipleSequenceAlignmentSelection` path as any other alignment
    /// selection. The focused pair is a programmatic sync and never switches tabs.
    func wireMultipleSequenceAlignmentInspector(
        _ controller: MultipleSequenceAlignmentViewController,
        isCurrent: @escaping @MainActor () -> Bool
    ) {
        controller.onSelectionStateChanged = { [weak self] state in
            guard let self, isCurrent() else { return }
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
