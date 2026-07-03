// StrainComparisonColumnWindowingTests.swift - Display-only column windowing
// Copyright (c) 2025 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
@testable import LungfishTaxTriageUI
import LungfishKit

@MainActor
final class StrainComparisonColumnWindowingTests: XCTestCase {

    private func sampleIds(_ count: Int) -> [String] {
        (0..<count).map { "S\($0)" }
    }

    private func entries(count: Int, sampleIds: [String]) -> [StrainComparisonEntry] {
        (0..<count).map { pos in
            var bases: [String: Character] = [:]
            for sample in sampleIds { bases[sample] = "A" }
            return StrainComparisonEntry(
                accession: "NC_000001.1",
                position: pos,
                referenceBase: "G",
                sampleBases: bases
            )
        }
    }

    func testCapsSampleColumnsAtSixtyByDefault() {
        let view = StrainComparisonView()
        let ids = sampleIds(150)
        view.configure(entries: entries(count: 5, sampleIds: ids), sampleIds: ids, organismName: "E. coli")

        XCTAssertLessThanOrEqual(view.testingSampleColumnCount, SampleColumnWindow.defaultLimit)
        XCTAssertEqual(view.testingSampleColumnCount, 60)
        XCTAssertTrue(view.isColumnWindowActive)
    }

    func testShowAllInstantiatesEveryColumn() {
        let view = StrainComparisonView()
        let ids = sampleIds(150)
        view.configure(entries: entries(count: 5, sampleIds: ids), sampleIds: ids, organismName: "E. coli")
        view.showAllSampleColumns()

        XCTAssertEqual(view.testingSampleColumnCount, 150)
        XCTAssertFalse(view.isColumnWindowActive)
    }

    func testSmallCohortInstantiatesAllColumns() {
        let view = StrainComparisonView()
        let ids = sampleIds(40)
        view.configure(entries: entries(count: 5, sampleIds: ids), sampleIds: ids, organismName: "E. coli")

        XCTAssertEqual(view.testingSampleColumnCount, 40)
        XCTAssertFalse(view.isColumnWindowActive)
    }

    /// Anti-leak: the full logical sample set must remain 150 while the window
    /// shows 60.
    func testFullSampleSetSurvivesWindow() {
        let view = StrainComparisonView()
        let ids = sampleIds(150)
        view.configure(entries: entries(count: 5, sampleIds: ids), sampleIds: ids, organismName: "E. coli")

        XCTAssertEqual(view.testingSampleColumnCount, 60)
        XCTAssertEqual(view.testingFullSampleIds.count, 150)
    }
}
