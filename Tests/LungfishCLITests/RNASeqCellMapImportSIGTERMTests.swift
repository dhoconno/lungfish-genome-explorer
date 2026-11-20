// RNASeqCellMapImportSIGTERMTests.swift - A SIGTERM cancels rnaseq cell-map import before it publishes (Phase 5.5 lane CM-IMPORT)
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// The family's cancel case (`docs/contracts/SCOPE-AND-DELIVERY.md`, Tests per family), as `RNASeqPseudobulkSIGTERMTests` has it.
// The leaf writes through the one writer, whose stage `.<name>.lungfishrnaseq.creating-<UUID>` holds the tables once they
// are written, and holds there on `LUNGFISH_VIEWER_EXPORT_HOLD_FILE` (a debug build only), so the signal reaches it with
// the stage on disk. It then removes the stage, publishes nothing, exits 125 and leaves no process behind. The built
// lungfish-cli imports 10x's two files onto the Cell Ranger cut, so no real tool and no network are needed.

import Foundation
import XCTest
import LungfishTestSupport
@testable import LungfishCLI

final class RNASeqCellMapImportSIGTERMTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = try TestTempDirectory.make(prefix: "rnaseq-cell-map-sigterm").resolvingSymlinksInPath()
    }

    override func tearDownWithError() throws {
        TestTempDirectory.cleanup(root)
    }

    private func stages(in folder: URL) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: folder.path).filter { $0.hasPrefix(".map.lungfishrnaseq.creating-") }
    }

    func testTheImportTurnsSIGTERMIntoACancelAndLeavesNeitherCellMapNorStage() async throws {
        let result = try CellMapImportFixture.result(CellMapImportFixture.cellRanger, in: root)
        let analyses = result.deletingLastPathComponent()
        let output = analyses.appendingPathComponent("map.lungfishrnaseq", isDirectory: true)
        let hold = root.appendingPathComponent("held")
        let run = try CLISIGTERMHarness.launchCLI(
            ["rnaseq", "cell-map", "import", result.path, "--coordinates", CellMapImportFixture.projection.path,
             "--clusters", CellMapImportFixture.clusters.path, "--output", output.path, "--format", "json"],
            environment: [ViewerExportLeaf.holdFileVariable: hold.path], workingDirectory: root, testClass: Self.self)
        defer { run.stop() }
        let held = await CLISIGTERMHarness.waitForFile(hold)
        XCTAssertTrue(held, "the leaf wrote its tables into the stage and reached the checkpoint")
        XCTAssertEqual(try stages(in: analyses).count, 1, "the stage is on disk while the leaf holds")
        let stop = await CLISIGTERMHarness.cancel(run)
        CLISIGTERMHarness.assertCancelledExit(stop)
        CLISIGTERMHarness.assertNoProcessLeft(stop)
        XCTAssertTrue(
            (stop.standardOutput + stop.standardError).contains(RNASeqCellMapImportSubcommand.cancelledMessage),
            "the words of a cancel. Standard output: \(stop.standardOutput)")
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path), "a cancel publishes no cell map")
        XCTAssertEqual(try stages(in: analyses), [], "a cancel leaves no hidden stage")
    }
}
