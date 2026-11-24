// InspectorViewController+RNASeq.swift - The Inspector of an open RNA-seq result
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation

extension InspectorViewController {
    /// Updates the Inspector for an RNA-seq result. The Bundle tab shows the result's facts, and the Provenance tab
    /// its record.
    func updateRNASeqResultDocument(name: String, facts: [(label: String, value: String)], bundleURL: URL) {
        viewModel.readStyleSectionViewModel.clear()
        updateProvenanceTarget(url: bundleURL, sidebarType: .registeredBundle, displayName: name)
        viewModel.documentSectionViewModel.updateRNASeqResultHeader(
            RNASeqResultDocumentState.rows(facts, prefix: "inspector-rnaseq-result"), bundleURL: bundleURL)
        viewModel.setContentTab(.bundle)
    }

    /// The registered bundle the Provenance tab names, which is the RNA-seq result the Inspector shows. The route
    /// sets it before the surface loads, so a cell map's first lines, which can come before the loaded hook, find it.
    var rnaseqResultTarget: URL? {
        guard let item = viewModel.provenanceSectionViewModel.currentItem, item.sidebarType == .registeredBundle else {
            return nil
        }
        return item.url
    }

    /// Shows a cell map's fact lines, or empties them. Lines of a result that is not the Inspector's target are
    /// dropped, so a view left behind cannot change what replaced it.
    func updateRNASeqCellMapFacts(_ lines: [(label: String, value: String)], bundleURL: URL) {
        guard rnaseqResultTarget?.standardizedFileURL == bundleURL.standardizedFileURL else { return }
        viewModel.documentSectionViewModel.updateRNASeqResultCellMap(
            RNASeqResultDocumentState.rows(lines, prefix: "inspector-rnaseq-cell-map"), bundleURL: bundleURL)
    }
}
