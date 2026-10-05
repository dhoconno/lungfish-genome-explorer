// InspectorViewController+MSAPairwiseDistance.swift - Feed the Pairwise Distance section from the matrix pane
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit

extension InspectorViewController {
    /// Shows the breakdown of the matrix cell that has keyboard focus. This is
    /// a programmatic sync from the Distances pane, so it never switches the
    /// Inspector's tab.
    func updateMSAFocusedDistancePair(_ pair: MSAFocusedDistancePair?) {
        viewModel.documentSectionViewModel.msaPairwiseDistance?.focusedPair = pair
    }
}
