// ClassifierExtractionDialogPresenting.swift - Shared helper for presenting the unified classifier extraction dialog
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 5 simplification-pass addition. Factors out the ~10-line preamble
// that each classifier VC's `presentUnifiedExtractionDialog()` needs to run
// before calling `TaxonomyReadExtractionAction.shared.present(...)`.
//
// Each classifier VC still owns the tool-specific selector-building and
// result-path resolution — this helper only consolidates the final "I have
// all the inputs, now show the dialog" step so the per-VC method stays tiny.

import AppKit
import Foundation
import LungfishWorkflow

extension NSViewController {

    /// Presents the unified classifier extraction dialog for the given tool
    /// and selection state.
    ///
    /// Silently returns without presenting a dialog when:
    /// - The view controller has no attached window (called before the VC
    ///   has been added to a window — avoids presenting an orphan sheet).
    /// - `selectors` is empty (nothing to extract — a no-op is correct).
    ///
    /// This wrapper collapses the boilerplate each classifier VC would
    /// otherwise repeat: the window guard, the empty-selectors guard, the
    /// `TaxonomyReadExtractionAction.Context` construction, and the
    /// `TaxonomyReadExtractionAction.shared.present(...)` call.
    ///
    /// - Parameters:
    ///   - tool: The classifier the dialog is scoped to. Drives the resolver
    ///     dispatch path (BAM vs. taxonomy) and the displayed title.
    ///   - resultPath: Path to the classifier's result file or directory.
    ///   - selectors: Per-sample row selectors built from the current table
    ///     selection. Must be non-empty for the dialog to appear.
    ///   - suggestedName: Default bundle name offered to the user in the save
    ///     panel. Callers should produce a short, sanitized, tool-prefixed
    ///     name (e.g. "esviritu_NC_001803").
    @MainActor
    func presentClassifierExtractionDialog(
        tool: ClassifierTool,
        resultPath: URL,
        selectors: [ClassifierRowSelector],
        suggestedName: String
    ) {
        guard let window = view.window, !selectors.isEmpty else { return }
        let ctx = TaxonomyReadExtractionAction.Context(
            tool: tool,
            resultPath: resultPath,
            selections: selectors,
            suggestedName: suggestedName
        )
        TaxonomyReadExtractionAction.shared.present(context: ctx, hostWindow: window)
    }
}
