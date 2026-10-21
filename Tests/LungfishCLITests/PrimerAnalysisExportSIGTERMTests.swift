// PrimerAnalysisExportSIGTERMTests.swift - A SIGTERM cancels the two primer export leaves before they publish
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.13 lane 13.43 M3 (SWIFT 3 and 4, X14). The app's Cancel sends SIGTERM to the leaf and gives it
// `operationGrace`. Each leaf stages its folder, payload and record together, beside the output, in a hidden folder. The
// leaf holds there on `LUNGFISH_VIEWER_EXPORT_HOLD_FILE` (a debug build only), so the signal reaches it with the staging
// folder on disk. It then removes the staging folder, publishes nothing, exits 125 and leaves no process behind. The built
// lungfish-cli runs on a saved analysis, so no real tool and no network are needed.

import Foundation
import XCTest
import LungfishTestSupport
@testable import LungfishCLI
@testable import LungfishWorkflow

final class PrimerAnalysisExportSIGTERMTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = try PrimerAnalysisExportFixtures.physical(TestTempDirectory.make(prefix: "primer-export-sigterm"))
    }

    override func tearDownWithError() throws {
        TestTempDirectory.cleanup(root)
    }

    func testAnOrderExportTurnsSIGTERMIntoACancelAndLeavesNeitherFolderNorStaging() async throws {
        let bundle = try PrimerAnalysisExportFixtures.primer3(in: root, pairCount: 2)
        let output = root.appendingPathComponent("order", isDirectory: true)
        try await assertCancelled(
            ["primers", "analysis", "export-order", bundle.path, "--output", output.path, "--format", "json"],
            output: output, staging: ".primer-order-")
    }

    func testASelectionExportTurnsSIGTERMIntoACancelAndLeavesNeitherFolderNorStaging() async throws {
        let bundle = try PrimerAnalysisExportFixtures.primalScheme(in: root)
        let snapshot = try PrimerAnalysisViewerSnapshot.load(from: bundle)
        let target = try XCTUnwrap(snapshot.designReview.first)
        let output = root.appendingPathComponent("pool.lungfishref", isDirectory: true)
        try await assertCancelled(
            ["primers", "analysis", "export-selection", bundle.path, "--kind", "primer-fasta",
             "--source-result-id", target.sourceResultID, "--pool", "1", "--output", output.path, "--format", "json"],
            output: output, staging: ".primer-selection-")
    }

    /// Runs the leaf until it holds, sends SIGTERM, and checks the exit, the words, the tree, the output and the root.
    private func assertCancelled(_ arguments: [String], output: URL, staging: String) async throws {
        let hold = root.appendingPathComponent("held")
        let run = try CLISIGTERMHarness.launchCLI(
            arguments, environment: [ViewerExportLeaf.holdFileVariable: hold.path], workingDirectory: root,
            testClass: Self.self)
        defer { run.stop() }
        let held = await CLISIGTERMHarness.waitForFile(hold)
        XCTAssertTrue(held, "the leaf staged its folder and reached the checkpoint")
        let stop = await CLISIGTERMHarness.cancel(run)
        CLISIGTERMHarness.assertCancelledExit(stop)
        CLISIGTERMHarness.assertNoProcessLeft(stop)
        XCTAssertTrue(
            (stop.standardOutput + stop.standardError).contains(ViewerExportLeaf.cancelledMessage),
            "the words of a cancel. Standard output: \(stop.standardOutput)")
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path), "a cancel publishes no folder")
        let entries = try FileManager.default.contentsOfDirectory(atPath: root.path)
        XCTAssertEqual(entries.filter { $0.hasPrefix(staging) }, [], "a cancel leaves no hidden staging folder. \(entries)")
    }
}
