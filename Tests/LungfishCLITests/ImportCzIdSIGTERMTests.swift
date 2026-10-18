// ImportCzIdSIGTERMTests.swift - A SIGTERM to import cz-id, the command the CZ-ID row runs
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.12 lane 12.06 (A63-M3, QA 1). The app's Cancel sends the command it runs SIGTERM. At the lane base
// `import cz-id` had no cancel, so the signal ended it before it wrote any record of the run. This pin holds
// that until the leaf turns SIGTERM into a cancel, which flips it.
//
// The command reads a large taxon report for seconds in a debug build, so a SIGTERM that follows the
// command's `Classifications` folder by a poll interval meets it at work. No tool and no network are needed.

import Darwin
import Foundation
import XCTest
import LungfishTestSupport

final class ImportCzIdSIGTERMTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = try TestTempDirectory.make(prefix: "import-cz-id-sigterm")
    }

    override func tearDownWithError() throws {
        TestTempDirectory.cleanup(root)
    }

    func testImportCzIdEndsBySIGTERMWithNoRecordOfTheRunToday() async throws {
        let held = try await startOnALargeReport()
        defer { held.run.stop() }
        let stop = await CLISIGTERMHarness.cancel(held.run)
        XCTAssertNotEqual(stop.exitStatus, 125, "the leaf has no cancel at the base." + stop.diagnostics)
        XCTAssertNil(
            ImportCommandsSIGTERMTests.recordStatus(in: held.project),
            "and writes no record of the run in the project"
        )
    }

    // MARK: - Holding the command at work

    struct Held {
        let run: CLISIGTERMHarness.Run
        let project: URL
    }

    /// A taxon report with a root row and `rows` species rows, which a debug build reads for seconds.
    static func writeLargeReport(to url: URL, rows: Int = 200_000) throws {
        var text = "sample_name\tproject_id\tpipeline_version\tnt_db_version\tnr_db_version\ttax_id\ttaxon_name\trank"
            + "\tnt_read_count\tnt_rpm\tnr_read_count\tnr_rpm\n"
        text.reserveCapacity(rows * 110)
        text += "Held-Sample\tProject-42\t8.4\tnt_2025_12_01\tnr_2025_12_01\t1\troot\troot\t1200\t1000000\t1200\t1000000\n"
        for row in 0..<rows {
            text += "Held-Sample\tProject-42\t8.4\tnt_2025_12_01\tnr_2025_12_01\t\(100_000 + row)\tTaxon \(row)\tspecies"
                + "\t\(row % 97 + 1)\t\(row % 89 + 1)\t1\t1\n"
        }
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    /// Starts `import cz-id` on a large report and waits until the command has made the project's
    /// `Classifications` folder, which it does before it reads the report.
    func startOnALargeReport(arguments extra: [String] = []) async throws -> Held {
        let project = root.appendingPathComponent("Project.lungfish", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let report = root.appendingPathComponent("taxon_report.tsv")
        try Self.writeLargeReport(to: report)
        let run = try CLISIGTERMHarness.launchCLI(
            ["import", "cz-id", report.path, "--project", project.path, "--sample-name", "Held Sample"] + extra,
            workingDirectory: root,
            testClass: Self.self
        )
        let reached = await CLISIGTERMHarness.waitForFile(project.appendingPathComponent("Classifications", isDirectory: true))
        if !reached {
            run.stop()
            XCTFail("the command never made the Classifications folder")
        }
        return Held(run: run, project: project)
    }
}
