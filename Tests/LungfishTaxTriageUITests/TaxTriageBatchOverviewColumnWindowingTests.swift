// TaxTriageBatchOverviewColumnWindowingTests.swift - Display-only column windowing
// Copyright (c) 2025 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
@testable import LungfishTaxTriageUI
@testable import LungfishIO
import LungfishKit

@MainActor
final class TaxTriageBatchOverviewColumnWindowingTests: XCTestCase {

    private func sampleIds(_ count: Int) -> [String] {
        (0..<count).map { "S\($0)" }
    }

    private func metrics(organisms: Int, sampleIds: [String]) -> [TaxTriageMetric] {
        var out: [TaxTriageMetric] = []
        for o in 0..<organisms {
            for sample in sampleIds {
                out.append(TaxTriageMetric(
                    sample: sample,
                    organism: "Organism \(o)",
                    rank: "S",
                    reads: 100,
                    abundance: 0.1,
                    coverageBreadth: 50.0,
                    coverageDepth: 10.0,
                    tassScore: 0.9,
                    confidence: "High"
                ))
            }
        }
        return out
    }

    func testCapsSampleColumnsAtSixtyByDefault() {
        let view = TaxTriageBatchOverviewView()
        let ids = sampleIds(150)
        view.configure(metrics: metrics(organisms: 3, sampleIds: ids), sampleIds: ids)

        XCTAssertLessThanOrEqual(view.testingSampleColumnCount, SampleColumnWindow.defaultLimit)
        XCTAssertEqual(view.testingSampleColumnCount, 60)
        XCTAssertTrue(view.isColumnWindowActive)
    }

    func testShowAllInstantiatesEveryColumn() {
        let view = TaxTriageBatchOverviewView()
        let ids = sampleIds(150)
        view.configure(metrics: metrics(organisms: 3, sampleIds: ids), sampleIds: ids)
        view.showAllSampleColumns()

        XCTAssertEqual(view.testingSampleColumnCount, 150)
        XCTAssertFalse(view.isColumnWindowActive)
    }

    func testSmallCohortInstantiatesAllColumns() {
        let view = TaxTriageBatchOverviewView()
        let ids = sampleIds(40)
        view.configure(metrics: metrics(organisms: 3, sampleIds: ids), sampleIds: ids)

        XCTAssertEqual(view.testingSampleColumnCount, 40)
        XCTAssertFalse(view.isColumnWindowActive)
    }

    /// Anti-leak: the full logical sample set (used for the sample-count
    /// denominator) must remain 150 while the window shows 60.
    func testFullSampleSetSurvivesWindow() {
        let view = TaxTriageBatchOverviewView()
        let ids = sampleIds(150)
        view.configure(metrics: metrics(organisms: 3, sampleIds: ids), sampleIds: ids)

        XCTAssertEqual(view.testingSampleColumnCount, 60)
        XCTAssertEqual(view.testingFullSampleIds.count, 150)
        // Denominator reflects the full sample count, never the windowed 60.
        XCTAssertEqual(view.testingSampleCountLabel(row: 0), "150/150")
    }
}
