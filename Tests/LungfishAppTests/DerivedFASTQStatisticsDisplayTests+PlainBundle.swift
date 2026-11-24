// DerivedFASTQStatisticsDisplayTests+PlainBundle.swift - A plain bundle of counted reads opens with no quality scores
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import LungfishTestSupport
import XCTest
@testable import LungfishApp
@testable import LungfishIO

extension DerivedFASTQStatisticsDisplayTests {
    /// A plain bundle made by Merge into New Bundle or by extraction holds no manifest, and its reads were measured on
    /// open as Mean Q 40.0 (lane FLUIDIGM-UNLINKED, ruling BIO-FLUIDIGM-UNLINKED). The dashboard now asks the reader,
    /// so reads that carry the counted-read signature read "No quality scores", on the first open (the measure) and on
    /// the next (the figures kept for the session). A bundle of measured reads keeps its Mean Q, Q20 and Q30.
    @MainActor
    func testAPlainBundleOfCountedReadsOpensWithNoQualityScores() async throws {
        isolateAlignmentPaneDefaults()
        let root = try TestTempDirectory.make(prefix: "plain-counted-dashboard")
        let hostDefaults = HostDefaultsRestorer(keysContaining: root.lastPathComponent)
        defer {
            hostDefaults.restore()
            TestTempDirectory.cleanup(root)
        }

        func plainBundle(named name: String, record: (Int) -> String) throws -> URL {
            let bundle = root.appendingPathComponent("\(name).\(FASTQBundle.directoryExtension)", isDirectory: true)
            try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
            try (1...4).map(record).joined()
                .write(to: bundle.appendingPathComponent("reads.fastq"), atomically: true, encoding: .utf8)
            return bundle
        }
        func shownStatistics(of bundle: URL) async throws -> FASTQDatasetStatistics {
            let harness = try ViewSwitchWindowHarness()
            defer { harness.close() }
            harness.split.loadFASTQDatasetInBackground(sourceURL: bundle)
            let shown = await waitUntil(budget: .lookup) {
                harness.split.inspectorController.viewModel.documentSectionViewModel.fastqStatistics != nil
            }
            XCTAssertTrue(shown, "the dashboard never showed numbers for \(bundle.lastPathComponent)")
            return try XCTUnwrap(harness.split.inspectorController.viewModel.documentSectionViewModel.fastqStatistics)
        }

        let counted = try plainBundle(named: "merged-counted") {
            "@u\(String(format: "%06d", $0));size=\(9 - $0)\nACGTACGTAC\n+\nIIIIIIIIII\n"
        }
        for pass in ["measured", "kept for the session"] {
            let statistics = try await shownStatistics(of: counted)
            XCTAssertEqual(statistics.readCount, 4, "reads of the counted bundle, \(pass)")
            XCTAssertEqual(
                FASTQStatisticsDisplayRules.meanQualityText(statistics), "No quality scores",
                "Mean Q of a plain bundle of counted reads, \(pass)"
            )
            XCTAssertEqual(FASTQStatisticsDisplayRules.q20Text(statistics), "No quality scores", "Q20, \(pass)")
            XCTAssertEqual(FASTQStatisticsDisplayRules.q30Text(statistics), "No quality scores", "Q30, \(pass)")
            XCTAssertFalse(
                FASTQStatisticsDisplayRules.hasQualityReport(statistics), "a written Q40 draws no quality charts, \(pass)"
            )
        }

        let measured = try plainBundle(named: "merged-measured") { "@read\($0)\nACGTACGTAC\n+\n5555555555\n" }
        let statistics = try await shownStatistics(of: measured)
        XCTAssertEqual(FASTQStatisticsDisplayRules.meanQualityText(statistics), "20.0", "Mean Q of measured reads")
        XCTAssertEqual(FASTQStatisticsDisplayRules.q20Text(statistics), "100.0%", "Q20 of measured reads")
        XCTAssertEqual(FASTQStatisticsDisplayRules.q30Text(statistics), "0.0%", "Q30 of measured reads")
    }
}
