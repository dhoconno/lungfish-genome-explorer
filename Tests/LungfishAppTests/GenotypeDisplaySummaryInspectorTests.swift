// GenotypeDisplaySummaryInspectorTests.swift - Genotype Display row counts in the Inspector
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import XCTest
import LungfishIO
import LungfishWorkflow
@testable import LungfishApp
@testable import LungfishGenotypeUI

/// The View tab's Genotype Display section read "Rows 0 of 0 / Hidden Cells 0"
/// on a matrix with many rows (2026.9.40): the matrix published its first
/// summary while the viewport was built, before the host wired the callback.
@MainActor
final class GenotypeDisplaySummaryInspectorTests: XCTestCase {
    func testOpeningAGenotypeResultPublishesTheMatrixRowCountsToTheInspector() async throws {
        let split = MainSplitViewController()
        _ = split.view
        let bundleURL = URL(fileURLWithPath: "/tmp/summary-\(UUID().uuidString).lungfishgenotype")
        let result = makeGenotypeResult(bundleURL: bundleURL)
        split.genotypeResultLoader = { _ in result }

        split.displayGenotypeResultBundleFromSidebar(at: bundleURL)
        await split.genotypeResultLoadTask?.value

        let controller = try XCTUnwrap(split.viewerController.genotypeResultViewController)
        let display = split.inspectorController.viewModel.genotypeResultDisplaySectionViewModel
        XCTAssertGreaterThan(display.totalRowCount, 0, "Rows must count the matrix, not read 0 of 0")
        XCTAssertEqual(display.visibleRowCount, controller.testingMatrixVisibleRowCount)
        XCTAssertEqual(display.totalRowCount, controller.testingMatrixTotalRowCount)
        XCTAssertEqual(display.hiddenCellCount, controller.testingMatrixHiddenCellCount)
    }

    private func makeGenotypeResult(bundleURL: URL) -> ONTGenotypeResultBundleData {
        func call(_ sample: String, _ genotype: String, _ reads: Int) -> ONTGenotypeCall {
            ONTGenotypeCall(
                sample: sample, genotype: genotype,
                passedAlignments: reads, passedUniqueReads: reads,
                sampleTotalReads: 40, sampleUniqueRetainedReads: 40, sampleUniqueRetainedPercent: 100,
                overallInputReads: 80, overallUniqueRetainedReads: 80, overallUniqueRetainedPercent: 100
            )
        }
        let calls = [
            call("AnimalA", "allele-1", 20), call("AnimalA", "allele-2", 20),
            call("AnimalB", "allele-1", 25), call("AnimalB", "allele-3", 15),
        ]
        return ONTGenotypeResultBundleData(
            bundleURL: bundleURL,
            manifest: ONTGenotypeResultBundleManifest(
                kind: GenotypeResultWorkflowKind.miSeqAmpliconMHCGenotype.rawValue,
                outputName: "summary", analysisName: "summary",
                primaryWorkbookPath: "summary.xlsx", longSummaryCSVPath: "calls.csv",
                sampleSummaryCSVPath: "samples.csv", statsJSONPath: "stats.json",
                provenancePath: "provenance.json"
            ),
            artifacts: ONTGenotypeResultArtifacts(
                workbookURL: bundleURL.appendingPathComponent("summary.xlsx"),
                longSummaryCSVURL: bundleURL.appendingPathComponent("calls.csv"),
                sampleSummaryCSVURL: bundleURL.appendingPathComponent("samples.csv"),
                statsJSONURL: bundleURL.appendingPathComponent("stats.json"),
                provenanceURL: bundleURL.appendingPathComponent("provenance.json")
            ),
            stats: ONTGenotypeRunStats(),
            calls: calls,
            samples: []
        )
    }
}
