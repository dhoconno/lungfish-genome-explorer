// InspectorViewController+RNASeq.swift - The Inspector of an open RNA-seq result
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation

extension InspectorViewController {
    /// Updates the Inspector for an RNA-seq result. The Document tab has no block for the kind, so the Inspector shows
    /// the item and its provenance.
    func updateRNASeqResultDocument(name: String, bundleURL: URL) {
        viewModel.readStyleSectionViewModel.clear()
        updateProvenanceTarget(url: bundleURL, sidebarType: .registeredBundle, displayName: name)
        viewModel.selectedTab = .bundle
    }
}
