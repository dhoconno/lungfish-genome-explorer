// FASTQOperationDialogTriggerTests.swift - The dialog runs when a classifier pane captures its configs
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Lane A41 M3b of Phase 2.10 (review fix 4, ruling Q3). The Kraken2, EsViritu and TaxTriage panes
// set `FASTQOperationDialogState.embeddedClassifierCapture` once their wizard captures its configs,
// and no launch request follows. The glue between that capture and the dialog's `onRun` is the
// `.onChange(of: state.embeddedClassifierCapture)` of `FASTQOperationDialog`. The decision it asks
// is pinned apart in FASTQOperationDialogRoutingTests. This suite fires the modifier itself on the
// built view with ViewInspector, so a dialog that lost the modifier runs nothing, and a modifier
// that ignores the selected pane would run a tool that is not a classifier.

import SwiftUI
import ViewInspector
import XCTest
@testable import LungfishApp

@MainActor
final class FASTQOperationDialogTriggerTests: XCTestCase {
    /// A capture runs the dialog once on each classifier pane and never on another pane. Clearing
    /// the capture runs it on none, since the clear in `prepareForRun()` must not start a run.
    func testAClassifierCaptureRunsTheDialogOnlyOnAClassifierPane() throws {
        let panes: [(tool: FASTQOperationToolID, runs: Int)] = [
            (.kraken2, 1), (.esViritu, 1), (.taxTriage, 1),
            (.minimap2, 0), (.spades, 0),
        ]
        for (toolID, expectedRuns) in panes {
            let state = FASTQOperationDialogState(
                initialCategory: toolID.categoryID,
                selectedInputURLs: [URL(fileURLWithPath: "/tmp/sample.fastq")]
            )
            state.selectTool(toolID)
            XCTAssertEqual(state.selectedToolID, toolID, "\(toolID.title) is the selected pane")

            var runs = 0
            let dialog = FASTQOperationDialog(state: state, onCancel: {}, onRun: { runs += 1 })
            let root = try dialog.inspect().find(ViewType.View<DatasetOperationsDialog<FASTQOperationToolPanes>>.self)

            try root.callOnChange(oldValue: UUID?.none, newValue: UUID?.some(UUID()))
            XCTAssertEqual(runs, expectedRuns, "a capture on the \(toolID.title) pane")

            try root.callOnChange(oldValue: UUID?.some(UUID()), newValue: UUID?.none)
            XCTAssertEqual(runs, expectedRuns, "a cleared capture on the \(toolID.title) pane runs nothing")
        }
    }
}
