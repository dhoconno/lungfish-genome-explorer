// LungfishPhylogeneticsUISmokeTests.swift - leaf module presence smoke test
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
@testable import LungfishPhylogeneticsUI

@MainActor
final class LungfishPhylogeneticsUISmokeTests: XCTestCase {
    func testTreeViewControllerLoadsViewStandalone() {
        let controller = PhylogeneticTreeViewController()
        XCTAssertEqual(controller.view.accessibilityIdentifier(), "phylogenetic-tree-bundle-view")
    }

    func testSelectionStateEquatable() {
        let lhs = PhylogeneticTreeSelectionState(title: "A", subtitle: "tip", detailRows: [("Type", "Tip")])
        let rhs = PhylogeneticTreeSelectionState(title: "A", subtitle: "tip", detailRows: [("Type", "Tip")])
        XCTAssertEqual(lhs, rhs)
    }
}
