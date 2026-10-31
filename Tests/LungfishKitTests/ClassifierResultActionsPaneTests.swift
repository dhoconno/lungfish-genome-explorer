// ClassifierResultActionsPaneTests.swift - A viewer hands the shared actions its resizable BLAST pane
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 3.1 lane ADOPT. NAO-MGS, EsViritu and NVD show their BLAST results in a `BlastResultsDrawerContainerView`
// that a person can drag taller. They hand that container's pane to `ClassifierResultActions`, which fills it and
// keeps its open state, so the pane a BLAST run fills is the one the viewer shows.

import AppKit
import XCTest
@testable import LungfishKit

@MainActor
final class ClassifierResultActionsPaneTests: XCTestCase {

    func testTheComponentFillsThePaneAViewerHandsIt() {
        let container = BlastResultsDrawerContainerView()
        let actions = ClassifierResultActions(blastDrawer: container.blastResultsTab)
        XCTAssertTrue(actions.blastDrawer === container.blastResultsTab)
        XCTAssertTrue(actions.blastResultsButton.isDescendant(of: actions.bar), "the bar holds BLAST Results")

        var opened: [Bool] = []
        actions.onBlastDrawerOpenChanged = { opened.append($0) }
        actions.showBlastFailure("NCBI BLAST did not return a result.")

        XCTAssertEqual(container.blastResultsTab.emptyStateDetailText, "NCBI BLAST did not return a result.")
        XCTAssertTrue(actions.isBlastDrawerOpen)
        actions.toggleBlastResults()
        XCTAssertEqual(opened, [true, false], "the viewer opens and closes the pane's space")
    }
}
