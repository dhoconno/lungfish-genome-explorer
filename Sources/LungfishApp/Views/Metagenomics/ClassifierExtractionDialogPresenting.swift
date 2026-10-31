// ClassifierExtractionDialogPresenting.swift - Shared helper for presenting the unified classifier extraction dialog
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Each classifier view controller owns tool-specific selector-building and
// result-path resolution. This helper centralizes the final window lookup,
// route-context construction, and dialog presentation step.
//
// Phase 3.1 lane 3E. A viewer that adopts `ClassifierResultActions` hands the App one
// `ClassifierExtractionRequest` through `onExtractionRequested`, which the App wires to
// `presentClassifierExtractionDialog(_:)`, so the viewer names no App type (layering rule 1)
// and the App reads nothing back from the viewer. The argument form serves the viewers that
// have not adopted the component yet and builds the same request.

import AppKit
import Foundation
import LungfishWorkflow
import LungfishKit

extension NSViewController {

    /// Presents the unified classifier extraction dialog for a viewer's request.
    ///
    /// Silently returns without presenting a dialog when:
    /// - The view controller has no attached window (called before the VC
    ///   has been added to a window — avoids presenting an orphan sheet).
    /// - The request has no selectors (nothing to extract — a no-op is correct).
    ///
    /// The request names the classifier (which drives the resolver dispatch path and the title), the result path,
    /// the per-sample row selectors, the bundle name the save panel offers, the table rows the selection stands for
    /// when there are fewer selectors than rows, and a line the dialog shows under its selection label.
    @MainActor
    func presentClassifierExtractionDialog(_ request: ClassifierExtractionRequest) {
        guard let window = view.window, !request.selectors.isEmpty else { return }
        let mainController = window.windowController as? MainWindowController
        let routeContext = OperationRouteContext(
            projectURL: mainController?.projectSession.projectURL
                ?? mainController?.mainSplitViewController?.sidebarController.currentProjectURL,
            windowStateScope: mainController?.projectSession.windowStateScope
        )
        var ctx = TaxonomyReadExtractionAction.Context(
            tool: request.tool,
            resultPath: request.resultPath,
            selections: request.selectors,
            suggestedName: request.suggestedName,
            routeContext: routeContext
        )
        ctx.selectedRowCount = request.selectedRowCount
        ctx.leftOutNotice = request.leftOutNotice
        TaxonomyReadExtractionAction.shared.present(context: ctx, hostWindow: window)
    }

    /// Presents the unified classifier extraction dialog for the given tool and selection state, as
    /// ``presentClassifierExtractionDialog(_:)`` does for the same request.
    ///
    /// - Parameters:
    ///   - tool: The classifier the dialog is scoped to.
    ///   - resultPath: Path to the classifier's result file or directory.
    ///   - selectors: Per-sample row selectors built from the current table
    ///     selection. Must be non-empty for the dialog to appear.
    ///   - suggestedName: Default bundle name offered to the user in the save
    ///     panel, short, sanitized and tool-prefixed (e.g. "esviritu_NC_001803").
    ///   - selectedRowCount: Table rows the selection stands for. Nil counts the selectors.
    ///   - leftOutNotice: A line the dialog shows under its selection label. Nil shows no line.
    @MainActor
    func presentClassifierExtractionDialog(
        tool: ClassifierTool,
        resultPath: URL,
        selectors: [ClassifierRowSelector],
        suggestedName: String,
        selectedRowCount: Int? = nil,
        leftOutNotice: String? = nil
    ) {
        presentClassifierExtractionDialog(ClassifierExtractionRequest(
            tool: tool,
            resultPath: resultPath,
            selectors: selectors,
            suggestedName: suggestedName,
            selectedRowCount: selectedRowCount,
            leftOutNotice: leftOutNotice
        ))
    }
}
