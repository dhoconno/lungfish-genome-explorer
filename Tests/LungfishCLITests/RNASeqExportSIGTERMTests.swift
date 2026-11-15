// RNASeqExportSIGTERMTests.swift - A SIGTERM cancels rnaseq export before it publishes (Phase 5.1 lane RS-HANDOFF)
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// The family's cancel case (`docs/contracts/SCOPE-AND-DELIVERY.md`, Tests per family). The app's Cancel sends SIGTERM to the
// leaf and gives it `operationGrace`. The leaf stages its folder and record beside the output, in a hidden
// `.<name>.<UUID>.export.tmp` folder, and holds there on `LUNGFISH_VIEWER_EXPORT_HOLD_FILE` (a debug build only), so the
// signal reaches it with the stage on disk. It then removes the stage, publishes nothing, exits 125 and leaves no process
// behind. The built lungfish-cli runs on a result the test writes with RS-KIND's writer, so no real tool and no network are
// needed.

import Foundation
import XCTest
import LungfishTestSupport
@testable import LungfishCLI

final class RNASeqExportSIGTERMTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = try TestTempDirectory.make(prefix: "rnaseq-export-sigterm").resolvingSymlinksInPath()
    }

    override func tearDownWithError() throws {
        TestTempDirectory.cleanup(root)
    }

    private func stages() throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: root.path).filter { $0.hasPrefix(".") && $0.hasSuffix(".export.tmp") }
    }

    func testTheExportTurnsSIGTERMIntoACancelAndLeavesNeitherFolderNorStage() async throws {
        let result = try RNASeqExportCommandTests.makeResult(
            "a", samples: ["S1", "S2"], groups: ["S1": "TB", "S2": "HIV"], in: root)
        let output = root.appendingPathComponent("export", isDirectory: true)
        let hold = root.appendingPathComponent("held")
        let run = try CLISIGTERMHarness.launchCLI(
            ["rnaseq", "export", result.path, "--output", output.path, "--design", "group", "--contrast", "group:TB:HIV",
             "--format", "json"],
            environment: [ViewerExportLeaf.holdFileVariable: hold.path], workingDirectory: root, testClass: Self.self)
        defer { run.stop() }
        let held = await CLISIGTERMHarness.waitForFile(hold)
        XCTAssertTrue(held, "the leaf staged its folder and reached the checkpoint")
        let staged = try stages()
        XCTAssertEqual(staged.count, 1, "the stage is on disk while the leaf holds. \(staged)")
        let stop = await CLISIGTERMHarness.cancel(run)
        CLISIGTERMHarness.assertCancelledExit(stop)
        CLISIGTERMHarness.assertNoProcessLeft(stop)
        XCTAssertTrue(
            (stop.standardOutput + stop.standardError).contains(ViewerExportLeaf.cancelledMessage),
            "the words of a cancel. Standard output: \(stop.standardOutput)")
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path), "a cancel publishes no folder")
        XCTAssertEqual(try stages(), [], "a cancel leaves no hidden stage")
    }

    /// A single-cell result takes the other branch of the leaf. It copies each sample's matrix into the stage and then reaches
    /// the same checkpoint, so it holds with its stage on disk too. It takes no `--design` and no `--contrast`, which a
    /// single-cell export refuses (RS-SC-HANDOFF-SWIFT, should-fix 1).
    func testTheSingleCellExportTurnsSIGTERMIntoACancelAndLeavesNeitherFolderNorStage() async throws {
        let result = try RNASeqPseudobulkCommandTests.makeSingleCellResult(in: root)
        let output = root.appendingPathComponent("export", isDirectory: true)
        let hold = root.appendingPathComponent("held")
        let run = try CLISIGTERMHarness.launchCLI(
            ["rnaseq", "export", result.path, "--output", output.path, "--format", "json"],
            environment: [ViewerExportLeaf.holdFileVariable: hold.path], workingDirectory: root, testClass: Self.self)
        defer { run.stop() }
        let held = await CLISIGTERMHarness.waitForFile(hold)
        XCTAssertTrue(held, "the leaf copied the matrices into its stage and reached the checkpoint")
        let staged = try stages()
        XCTAssertEqual(staged.count, 1, "the stage is on disk while the leaf holds. \(staged)")
        let stop = await CLISIGTERMHarness.cancel(run)
        CLISIGTERMHarness.assertCancelledExit(stop)
        CLISIGTERMHarness.assertNoProcessLeft(stop)
        XCTAssertTrue(
            (stop.standardOutput + stop.standardError).contains(ViewerExportLeaf.cancelledMessage),
            "the words of a cancel. Standard output: \(stop.standardOutput)")
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path), "a cancel publishes no folder")
        XCTAssertEqual(try stages(), [], "a cancel leaves no hidden stage")
    }
}
