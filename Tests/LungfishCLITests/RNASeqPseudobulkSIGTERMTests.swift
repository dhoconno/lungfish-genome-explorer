// RNASeqPseudobulkSIGTERMTests.swift - A SIGTERM cancels rnaseq pseudobulk before it publishes (Phase 5.2 lane RS-PSEUDOBULK)
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// The family's cancel case (`docs/contracts/SCOPE-AND-DELIVERY.md`, Tests per family), as `RNASeqExportSIGTERMTests` has it.
// The leaf writes through the one writer, whose stage `.<name>.lungfishrnaseq.creating-<UUID>` holds the tables once they
// are written, and holds there on `LUNGFISH_VIEWER_EXPORT_HOLD_FILE` (a debug build only), so the signal reaches it with
// the stage on disk. It then removes the stage, publishes nothing, exits 125 and leaves no process behind. The built
// lungfish-cli runs on the STARsolo cut, so no real tool and no network are needed.

import Foundation
import XCTest
import LungfishTestSupport
@testable import LungfishCLI

final class RNASeqPseudobulkSIGTERMTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = try TestTempDirectory.make(prefix: "rnaseq-pseudobulk-sigterm").resolvingSymlinksInPath()
    }

    override func tearDownWithError() throws {
        TestTempDirectory.cleanup(root)
    }

    private func stages(in folder: URL) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: folder.path).filter { $0.hasPrefix(".pb.lungfishrnaseq.creating-") }
    }

    func testThePseudobulkTurnsSIGTERMIntoACancelAndLeavesNeitherResultNorStage() async throws {
        let result = try RNASeqPseudobulkCommandTests.makeSingleCellResult(in: root)
        let analyses = result.deletingLastPathComponent()
        let output = analyses.appendingPathComponent("pb.lungfishrnaseq", isDirectory: true)
        let hold = root.appendingPathComponent("held")
        let run = try CLISIGTERMHarness.launchCLI(
            ["rnaseq", "pseudobulk", result.path, "--labels", RNASeqPseudobulkCommandTests.labels.path, "--output", output.path,
             "--format", "json"],
            environment: [ViewerExportLeaf.holdFileVariable: hold.path], workingDirectory: root, testClass: Self.self)
        defer { run.stop() }
        let held = await CLISIGTERMHarness.waitForFile(hold)
        XCTAssertTrue(held, "the leaf wrote its tables into the stage and reached the checkpoint")
        XCTAssertEqual(try stages(in: analyses).count, 1, "the stage is on disk while the leaf holds")
        let stop = await CLISIGTERMHarness.cancel(run)
        CLISIGTERMHarness.assertCancelledExit(stop)
        CLISIGTERMHarness.assertNoProcessLeft(stop)
        XCTAssertTrue(
            (stop.standardOutput + stop.standardError).contains(RNASeqPseudobulkSubcommand.cancelledMessage),
            "the words of a cancel. Standard output: \(stop.standardOutput)")
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path), "a cancel publishes no result")
        XCTAssertEqual(try stages(in: analyses), [], "a cancel leaves no hidden stage")
    }
}
