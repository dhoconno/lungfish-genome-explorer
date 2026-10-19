// ImportCzIdSIGTERMTests.swift - A SIGTERM to import cz-id, the command the CZ-ID row runs
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.12 lane 12.06 (A63-M3, QA 1). The app's Cancel sends the command it runs SIGTERM. At the lane base
// `import cz-id` had no cancel, so the signal ended it before it wrote any record of the run (the pin of
// commit 22e540b79). The leaf now turns SIGTERM into a cancel. It exits 125 inside the grace, records the run
// as cancelled in the project, tells the row with a `failed` event and publishes no bundle.
//
// The command reads a large taxon report for seconds in a debug build, so a SIGTERM that follows the
// command's `Classifications` folder by a poll interval meets it at work. The two cases on a plain report meet
// that pre-read. The two on an export folder, which has no pre-read, meet the conversion while it writes the
// bundle (review 12.06-M1 fix 6). No tool and no network are needed.

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

    func testImportCzIdTurnsSIGTERMIntoACancelAndPublishesNothing() async throws {
        let held = try await startOnALargeReport(arguments: ["--format", "json"])
        defer { held.run.stop() }
        let stop = await CLISIGTERMHarness.assertSIGTERMCancels(
            held.run,
            record: { ImportCommandsSIGTERMTests.recordStatus(in: held.project) }
        )
        try ImportCommandsSIGTERMTests.assertCancelledEvents(stop.standardOutput)
        XCTAssertEqual(
            ImportCommandsSIGTERMTests.bundles(in: held.project, folder: "Classifications"), [],
            "a cancelled import publishes no bundle"
        )
    }

    /// The same cancel with every core busy, which the grace must still cover.
    func testImportCzIdTurnsSIGTERMIntoACancelWithEveryCoreBusy() async throws {
        let held = try await startOnALargeReport(arguments: ["--format", "json"])
        defer { held.run.stop() }
        let burners = try CLISIGTERMHarness.launchBurners(count: ProcessInfo.processInfo.activeProcessorCount)
        defer { burners.forEach { $0.stop() } }
        let stop = await CLISIGTERMHarness.assertSIGTERMCancels(
            held.run,
            record: { ImportCommandsSIGTERMTests.recordStatus(in: held.project) }
        )
        try ImportCommandsSIGTERMTests.assertCancelledEvents(stop.standardOutput)
        XCTAssertEqual(ImportCommandsSIGTERMTests.bundles(in: held.project, folder: "Classifications"), [])
    }

    /// Review 12.06-M1 fix 6. A cancel while the conversion writes the bundle, which the two cases above never meet,
    /// since they cancel during the pre-read of a plain report. An export folder has no pre-read. The converter makes
    /// `Classifications/Held-Sample.lungfishtax` after its parse and goes on writing into it, on the leaf's task, and
    /// the leaf checks the cancel once the conversion returned, removes the bundle and exits 125.
    func testImportCzIdCancelsDuringTheConversionOfAnExportFolderAndRemovesTheBundle() async throws {
        let held = try await startOnAnExportFolder()
        defer { held.run.stop() }
        let stop = await CLISIGTERMHarness.assertSIGTERMCancels(
            held.run,
            record: { ImportCommandsSIGTERMTests.recordStatus(in: held.project) }
        )
        try ImportCommandsSIGTERMTests.assertCancelledEvents(stop.standardOutput)
        XCTAssertEqual(
            ImportCommandsSIGTERMTests.bundles(in: held.project, folder: "Classifications"), [],
            "the cancel removed the bundle the conversion was writing"
        )
    }

    /// The same cancel in the write phase with every core busy, which the grace must still cover.
    func testImportCzIdCancelsDuringTheConversionWithEveryCoreBusy() async throws {
        let held = try await startOnAnExportFolder()
        defer { held.run.stop() }
        let burners = try CLISIGTERMHarness.launchBurners(count: ProcessInfo.processInfo.activeProcessorCount)
        defer { burners.forEach { $0.stop() } }
        let stop = await CLISIGTERMHarness.assertSIGTERMCancels(
            held.run,
            record: { ImportCommandsSIGTERMTests.recordStatus(in: held.project) }
        )
        try ImportCommandsSIGTERMTests.assertCancelledEvents(stop.standardOutput)
        XCTAssertEqual(ImportCommandsSIGTERMTests.bundles(in: held.project, folder: "Classifications"), [])
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

    /// Starts `import cz-id` on an export folder that holds a large report and waits until the converter has made
    /// the bundle folder, which it does after its parse and before it writes the bundle's files.
    ///
    /// The row count comes from timing the debug lungfish-cli on this Mac Studio with other lanes building
    /// (`czid_timing.py` in the lane's records). Three runs each, the bundle's first appearance after the launch and
    /// the exit after that appearance: 20,000 rows 4.8 to 9.7 s and 0.4 to 1.0 s, 50,000 rows 9.6 to 24.9 s and 0.6
    /// to 1.5 s, 100,000 rows 25.9, 28.2 and 35.9 s and 1.7, 1.9 and 2.7 s, 200,000 rows 39.7 to 48.7 s and 2.0 to
    /// 3.1 s. So 100,000 rows keep the write going 1 to 3 s after the bundle appears, and the wait for the bundle,
    /// which follows two full parses of the report (the folder search and the conversion), gets 60 s.
    func startOnAnExportFolder() async throws -> Held {
        let project = root.appendingPathComponent("Project.lungfish", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let export = root.appendingPathComponent("export", isDirectory: true)
        try FileManager.default.createDirectory(at: export, withIntermediateDirectories: true)
        try Self.writeLargeReport(to: export.appendingPathComponent("taxon_report.tsv"), rows: 100_000)
        let run = try CLISIGTERMHarness.launchCLI(
            ["import", "cz-id", export.path, "--project", project.path, "--sample-name", "Held Sample", "--format", "json"],
            workingDirectory: root,
            testClass: Self.self
        )
        let bundle = project.appendingPathComponent("Classifications/Held-Sample.lungfishtax", isDirectory: true)
        let reached = await CLISIGTERMHarness.waitForFile(bundle, timeout: .seconds(60))
        if !reached {
            run.stop()
            XCTFail("the converter never made the bundle folder")
        }
        return Held(run: run, project: project)
    }
}
