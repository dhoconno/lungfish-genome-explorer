// GenotypeSummaryRowUnitsTests.swift - The Inspector names the unit its genotype totals count
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishIO
import XCTest
@testable import LungfishApp

@MainActor
final class GenotypeSummaryRowUnitsTests: XCTestCase {
    private func result(stats: ONTGenotypeRunStats) -> ONTGenotypeResultBundleData {
        let bundleURL = URL(fileURLWithPath: "/tmp/units-\(UUID().uuidString).lungfishgenotype")
        return ONTGenotypeResultBundleData(
            bundleURL: bundleURL,
            manifest: ONTGenotypeResultBundleManifest(
                outputName: "units", analysisName: "units",
                primaryWorkbookPath: "units.xlsx", longSummaryCSVPath: "calls.csv",
                sampleSummaryCSVPath: "samples.csv", statsJSONPath: "stats.json",
                provenancePath: "provenance.json", createdAt: "2026-09-27T00:00:00Z"
            ),
            artifacts: ONTGenotypeResultArtifacts(
                workbookURL: bundleURL.appendingPathComponent("units.xlsx"),
                longSummaryCSVURL: bundleURL.appendingPathComponent("calls.csv"),
                sampleSummaryCSVURL: bundleURL.appendingPathComponent("samples.csv"),
                statsJSONURL: bundleURL.appendingPathComponent("stats.json"),
                provenanceURL: bundleURL.appendingPathComponent("provenance.json")
            ),
            stats: stats,
            calls: [],
            samples: []
        )
    }

    func testFragmentDenominatedRunsAreLabelledAsFragments() {
        let rows = InspectorViewController.genotypeSummaryRows(result(stats: ONTGenotypeRunStats(
            totalInputReads: 376,
            totalInputReadsUnit: "fragments",
            retainedUniqueReads: 376,
            retainedUniquePercentOfTotalReads: 100
        )))
        XCTAssertTrue(rows.contains { $0 == ("Total Fragments", "376") }, "\(rows)")
        XCTAssertTrue(rows.contains { $0 == ("Retained % of Fragments", "100.00%") }, "\(rows)")
        XCTAssertFalse(rows.contains { $0.0 == "Total Reads" })
    }

    func testReadDenominatedAndLegacyStatsKeepTheReadLabels() {
        for stats in [
            ONTGenotypeRunStats(totalInputReads: 752, totalInputReadsUnit: "reads", retainedUniquePercentOfTotalReads: 50),
            ONTGenotypeRunStats(totalInputReads: 752, retainedUniquePercentOfTotalReads: 50),
        ] {
            let rows = InspectorViewController.genotypeSummaryRows(result(stats: stats))
            XCTAssertTrue(rows.contains { $0 == ("Total Reads", "752") }, "\(rows)")
            XCTAssertTrue(rows.contains { $0 == ("Retained %", "50.00%") }, "\(rows)")
        }
    }
}
