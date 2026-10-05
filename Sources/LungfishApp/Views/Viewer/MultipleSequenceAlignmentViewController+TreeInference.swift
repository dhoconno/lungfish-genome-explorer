// MultipleSequenceAlignmentViewController+TreeInference.swift - Build Tree request and accessibility twin
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit

extension MultipleSequenceAlignmentViewController {
    /// K5: the accessibility twin of the context-menu "Build Tree with IQ-TREE…" item, present
    /// on the matrix and the row gutter whenever a bundle is loaded.
    func treeAccessibilityActions() -> [NSAccessibilityCustomAction] {
        guard bundleURL != nil else { return [] }
        return [
            NSAccessibilityCustomAction(name: "Build Tree with IQ-TREE…") { [weak self] in
                MainActor.assumeIsolated { self?.inferTreeFromAlignment() }
                return true
            }
        ]
    }

    /// The tree-inference request for the loaded alignment, carrying the current row and
    /// column selection. The IQ-TREE dialog validates the scope, so no selection size is
    /// required here. `nil` only when no bundle is loaded.
    func treeInferenceRequest() -> MultipleSequenceAlignmentTreeInferenceRequest? {
        guard let bundleURL else { return nil }
        let displayName = bundle?.manifest.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            ? bundle?.manifest.name ?? bundleURL.deletingPathExtension().lastPathComponent
            : bundleURL.deletingPathExtension().lastPathComponent
        let selectedRows: String?
        if !selectedRowIndices.isEmpty {
            let rowIDs = selectedRowIndices.compactMap { rowIDsByIndex[safe: $0] }
            selectedRows = rowIDs.isEmpty ? nil : rowIDs.joined(separator: ",")
        } else {
            selectedRows = nil
        }
        let selectedColumns = selectedExportColumns
        return MultipleSequenceAlignmentTreeInferenceRequest(
            bundleURL: bundleURL,
            rows: selectedRows,
            columns: selectedColumns,
            suggestedName: "\(displayName).lungfishtree",
            displayName: displayName
        )
    }

    var testingTreeAccessibilityActionNames: (matrix: [String], gutter: [String]) {
        (testingTreeAccessibilityActions.matrix.map(\.name), testingTreeAccessibilityActions.gutter.map(\.name))
    }

    func testingPerformMatrixTreeAccessibilityAction() -> Bool {
        testingTreeAccessibilityActions.matrix.first?.handler?() ?? false
    }

    var testingBuildTreeContextItemEnabled: Bool {
        selectionContextMenu().items.first { $0.title == "Build Tree with IQ-TREE\u{2026}" }?.isEnabled ?? false
    }
}
