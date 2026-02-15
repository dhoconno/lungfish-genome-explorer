// GeneTabBarViewTests.swift - Tests for gene tab bar behavior
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
@testable import LungfishApp

@MainActor
final class GeneTabBarViewTests: XCTestCase {

    private func makeRegions(_ count: Int) -> [GeneRegion] {
        (0..<count).map { idx in
            GeneRegion(
                name: "GENE\(idx + 1)",
                chromosome: "chr1",
                start: 1000 + (idx * 100),
                end: 1050 + (idx * 100)
            )
        }
    }

    func testSelectionPreservedAcrossSetGeneRegions() {
        let view = GeneTabBarView(frame: NSRect(x: 0, y: 0, width: 900, height: 28))
        let initial = makeRegions(12)
        view.setGeneRegions(initial)
        view.selectGeneTab(at: 10)
        XCTAssertEqual(view.selectedGeneRegion?.name, "GENE11")

        let refreshed = initial + [GeneRegion(name: "GENE13", chromosome: "chr1", start: 2400, end: 2450)]
        view.setGeneRegions(refreshed)
        XCTAssertEqual(view.selectedGeneRegion?.name, "GENE11")
    }

    func testPreferredGeneNameOverridesSelection() {
        let view = GeneTabBarView(frame: NSRect(x: 0, y: 0, width: 900, height: 28))
        let regions = makeRegions(10)
        view.setGeneRegions(regions)
        view.selectGeneTab(at: 2)
        XCTAssertEqual(view.selectedGeneRegion?.name, "GENE3")

        view.setGeneRegions(regions, preferredGeneName: "GENE8")
        XCTAssertEqual(view.selectedGeneRegion?.name, "GENE8")
    }
}

