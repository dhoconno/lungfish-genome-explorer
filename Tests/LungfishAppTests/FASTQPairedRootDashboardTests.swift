// FASTQPairedRootDashboardTests.swift - The dashboard of a root of R1 and R2 files counts both mates (Phase 3.3 lane PAIREDROOT)
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import LungfishTestSupport
import XCTest
@testable import LungfishApp
@testable import LungfishIO

/// A `.lungfishfastq` root that holds an `_R1` and an `_R2` file with no `source-files.json` showed the card, the
/// Inspector and the stored record of R1 alone, while tools read both files as one mate pair (BIO-PAIRED-ROOT-PRIMARY,
/// S1). R2 of an Illumina run is usually the poorer mate, so the card overstated Mean Q, Q20 and Q30. The reads below
/// are the ruling's fixture. R1 holds four reads at Q40 with GC 50%, and R2 four reads at Q10 with GC 100%.
@MainActor
final class FASTQPairedRootDashboardTests: XCTestCase {
    private var root: URL!
    private var hostDefaults: HostDefaultsRestorer!

    override func setUpWithError() throws {
        isolateAlignmentPaneDefaults()
    }

    override func setUp() async throws {
        try await super.setUp()
        root = try TestTempDirectory.make(prefix: "PairedRootDashboard")
        hostDefaults = HostDefaultsRestorer(keysContaining: root.lastPathComponent)
    }

    override func tearDown() async throws {
        hostDefaults.restore()
        TestTempDirectory.cleanup(root)
        try await super.tearDown()
    }

    private static func reads(_ prefix: String, sequence: String, quality: Character) -> String {
        (1...4).map { "@\(prefix)\($0)\n\(sequence)\n+\n\(String(repeating: quality, count: sequence.count))\n" }.joined()
    }

    private func makePairedRoot() throws -> URL {
        let bundle = root.appendingPathComponent("pair-extract.\(FASTQBundle.directoryExtension)", isDirectory: true)
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
        try Self.reads("r1_", sequence: "ACGT", quality: "I")
            .write(to: bundle.appendingPathComponent("s_R1.fastq"), atomically: true, encoding: .utf8)
        try Self.reads("r2_", sequence: "GGCC", quality: "+")
            .write(to: bundle.appendingPathComponent("s_R2.fastq"), atomically: true, encoding: .utf8)
        return bundle
    }

    func testDashboardStatisticsOfPairedRootCountBothMates() async throws {
        let bundle = try makePairedRoot()
        let harness = try ViewSwitchWindowHarness()
        defer { harness.close() }
        let split = harness.split

        split.loadFASTQDatasetInBackground(sourceURL: bundle)

        let shown = await waitUntil(budget: .lookup) {
            split.inspectorController.viewModel.documentSectionViewModel.fastqStatistics != nil
        }
        XCTAssertTrue(shown, "the dashboard never showed numbers for the root of R1 and R2")
        let statistics = try XCTUnwrap(split.inspectorController.viewModel.documentSectionViewModel.fastqStatistics)
        XCTAssertEqual(statistics.readCount, 8, "the reads of both mates, where R1 alone is 4")
        XCTAssertEqual(statistics.baseCount, 32)
        XCTAssertEqual(statistics.meanQuality, 13.0, accuracy: 0.05, "the pooled error mean, where R1 alone is Q40")
        XCTAssertEqual(statistics.gcContent, 0.75, accuracy: 0.005, "GC of both mates, where R1 alone is 50%")

        let dashboard = try XCTUnwrap(split.viewerController.fastqDatasetController)
        func cardLines() -> [String] {
            dashboard.testingSummaryAccessibilityChildren.map {
                "\($0.accessibilityLabel() ?? ""): \(($0.accessibilityValue() as? String) ?? "")"
            }
        }
        // The card fills after the Inspector model does, so wait on the card's own text and not on a delay.
        let measured = await waitUntil(budget: .lookup) { cardLines().contains("Reads: 8") }
        let cards = cardLines()
        XCTAssertTrue(measured, "the cards never showed 8 reads: \(cards)")
        XCTAssertTrue(cards.contains("Reads: 8"), "the cards are \(cards)")
        XCTAssertTrue(cards.contains("\(FASTQStatisticsDisplayRules.meanQualityLabel): 13.0"), "the cards are \(cards)")
        XCTAssertTrue(
            cards.contains("Q20: 50.0%"),
            "R1 is all Q40 and R2 all Q10 with equal bases, so half the bases reach Q20, where R1 alone reads 100.0%; the cards are \(cards)"
        )
        XCTAssertTrue(
            cards.contains("Q30: 50.0%"),
            "half the bases reach Q30, where R1 alone reads 100.0%; the cards are \(cards)"
        )
        XCTAssertTrue(cards.contains("GC: 75.0%"), "the cards are \(cards)")
    }
}
