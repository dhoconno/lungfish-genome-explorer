// TaxTriageFailedControlTests.swift - A control that never ran does not read as a clean control
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Lane TTBUILDDB, row TAXTRIAGE-FAILED-CONTROL-READS-CLEAN. A batch records a failed sample in its sidecar
// (`sampleFailures`) and keeps the mark of a control that failed, but a failed control has no report, so no row
// of the database names it. The matrix read No and the report read `No organisms detected in negative
// controls.` for it, which is false since the control never ran (lane report, measured at the base). The tests
// run the real importer, `build-db` and the CLI exports on a run folder whose sidecar lists the failure.

import XCTest
@testable import LungfishCLI
@testable import LungfishIO
@testable import LungfishWorkflow

final class TaxTriageFailedControlTests: XCTestCase {
    private static let shared = "Bradyrhizobium sp. WCU1"

    private var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("TaxTriageFailedControl-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    // MARK: - Tests

    /// The control failed, so no organism can read No.
    func testMatrixDoesNotReadNoForAControlThatNeverRan() async throws {
        let result = try await importedRun(
            samples: [("patient", false), ("NTC1", true)],
            failed: ["NTC1"],
            reports: ["patient"]
        )

        let shared = try XCTUnwrap(try matrixLines(of: result).first { $0.hasPrefix("\(Self.shared),") })
        XCTAssertTrue(shared.contains(",Not checked,"), "the matrix did not say the control was not checked: \(shared)")
        XCTAssertFalse(shared.contains(",No,"), "the matrix read No for a control that never ran: \(shared)")
    }

    func testReportSaysTheControlFailedAndWhatToDo() async throws {
        let result = try await importedRun(
            samples: [("patient", false), ("NTC1", true)],
            failed: ["NTC1"],
            reports: ["patient"]
        )

        let report = try reportText(of: result)
        XCTAssertFalse(report.contains("No organisms detected in negative controls."), report)
        XCTAssertTrue(report.contains("Negative Controls: NTC1 (failed, no result)"), report)
        XCTAssertTrue(report.contains("Contamination risk is not checked."), report)
        XCTAssertTrue(report.contains("The negative control NTC1 failed, so Lungfish has no result for it."), report)
        XCTAssertTrue(report.contains("Run it again, or check it another way, before you rely on these results."), report)
    }

    func testResultsExportShowsNotCheckedInTheBlankCell() async throws {
        let result = try await importedRun(
            samples: [("patient", false), ("NTC1", true)],
            failed: ["NTC1"],
            reports: ["patient"]
        )

        let rows = try resultsLines(of: result).filter { $0.contains(",\(Self.shared),") }
        XCTAssertEqual(rows.count, 1, "\(rows)")
        XCTAssertTrue(rows.allSatisfy { $0.hasSuffix(",Not checked") }, "the cell stayed blank: \(rows)")
    }

    /// A control that ran and found nothing is clean, and the words stay as they were.
    func testControlThatRanAndFoundNothingStillReadsNo() async throws {
        let result = try await importedRun(
            samples: [("patient", false), ("NTC1", true)],
            failed: [],
            reports: ["patient"]
        )

        let shared = try XCTUnwrap(try matrixLines(of: result).first { $0.hasPrefix("\(Self.shared),") })
        XCTAssertTrue(shared.contains(",No,"), shared)
        let report = try reportText(of: result)
        XCTAssertTrue(report.contains("No organisms detected in negative controls."), report)
        XCTAssertFalse(report.contains("not checked"), report)
    }

    /// BIO ruling 2 of TTIMPORT, "it needs words where a control still has no rows".
    func testReportSaysWhenAControlThatRanHasNoOrganismsListed() async throws {
        let result = try await importedRun(
            samples: [("patient", false), ("NTC1", true)],
            failed: [],
            reports: ["patient"]
        )

        let report = try reportText(of: result)
        XCTAssertTrue(report.contains("Negative Controls: NTC1 (no organisms listed)"), report)
    }

    /// Two controls, one that ran and holds the shared organism and one that failed. Yes stays Yes, and what the
    /// failed control could have held is not called No.
    func testAnotherControlThatRanKeepsYesWhileTheFailedOneIsNotChecked() async throws {
        let result = try await importedRun(
            samples: [("patient", false), ("NTC1", true), ("NTC2", true)],
            failed: ["NTC2"],
            reports: ["patient", "NTC1"]
        )

        let lines = try matrixLines(of: result)
        let shared = try XCTUnwrap(lines.first { $0.hasPrefix("\(Self.shared),") })
        XCTAssertTrue(shared.contains(",2/2,Yes,"), shared)
        let others = lines.dropFirst().filter { !$0.hasPrefix("\(Self.shared),") }
        XCTAssertFalse(others.isEmpty)
        XCTAssertTrue(others.allSatisfy { $0.contains(",Not checked,") }, "\(others)")
        let report = try reportText(of: result)
        XCTAssertTrue(report.contains("Contamination risk is only partly checked."), report)
        XCTAssertTrue(report.contains("The negative control NTC2 failed, so Lungfish has no result for it."), report)
    }

    /// A control with no rows beside samples the run does not list may have its organisms under one of them.
    /// Its absence is not a clean control.
    func testControlWithNoRowsBesideUnlistedSamplesIsNotCalledClean() async throws {
        let result = try await importedRun(
            samples: [("patient", false), ("NTC 9", true)],
            failed: [],
            reports: ["patient", "elsewhere"]
        )

        let shared = try XCTUnwrap(try matrixLines(of: result).first { $0.hasPrefix("\(Self.shared),") })
        XCTAssertTrue(shared.contains(",Not checked,"), "the matrix read a verdict it cannot know: \(shared)")
        let report = try reportText(of: result)
        XCTAssertFalse(report.contains("No organisms detected in negative controls."), report)
        XCTAssertTrue(report.contains("Negative Controls: NTC 9 (named NTC_9 in the results, not found in the results)"), report)
        XCTAssertTrue(report.contains("(elsewhere)"), "the report does not name the unlisted sample: \(report)")
    }

    // MARK: - Helpers

    /// Imports a run folder of flat reports, the first of which holds 3 rows and each other 1, and builds the
    /// database. The sidecar lists `samples` as typed and the failure of each name in `failed`.
    private func importedRun(samples: [(String, Bool)], failed: [String], reports: [String]) async throws -> URL {
        let source = folder.appendingPathComponent("run", isDirectory: true)
        for (index, id) in reports.enumerated() {
            try writeReport(for: id, rows: index == 0 ? 3 : 1, to: source.appendingPathComponent("report/\(id).odr.txt"))
        }
        let config = TaxTriageConfig(
            samples: samples.map {
                TaxTriageSample(
                    sampleId: $0.0,
                    fastq1: URL(fileURLWithPath: "/nonexistent/sample.fastq.gz"),
                    isNegativeControl: $0.1
                )
            },
            platform: .illumina,
            outputDirectory: source
        )
        let failures = failed.map {
            TaxTriageSampleFailure(
                sampleID: $0,
                outputDirectory: source.appendingPathComponent($0),
                errorDescription: "TaxTriage pipeline failed with exit code 1"
            )
        }
        try TaxTriageResult(
            config: config, runtime: 10, exitCode: 0, outputDirectory: source, sampleFailures: failures
        ).save()
        let imported = try MetagenomicsImportService.importTaxTriage(
            inputURL: source,
            outputDirectory: folder.appendingPathComponent("imports", isDirectory: true)
        )
        let build = try BuildDbCommand.TaxTriageSubcommand.parse([imported.resultDirectory.path, "--no-cleanup", "-q"])
        try await build.run()
        return imported.resultDirectory
    }

    /// A report table of the fixture's header and its first `rows` data lines, with the sample named in each line.
    private func writeReport(for sample: String, rows: Int, to url: URL) throws {
        let lines = try String(contentsOf: try fixtureReport(), encoding: .utf8)
            .components(separatedBy: "\n").filter { !$0.isEmpty }
        let kept = lines.prefix(1 + rows).enumerated().map { index, line -> String in
            guard index > 0 else { return line }
            var fields = line.components(separatedBy: "\t")
            fields[3] = sample
            return fields.joined(separator: "\t")
        }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try (kept.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
    }

    private func fixtureReport() throws -> URL {
        var url = URL(fileURLWithPath: #filePath)
        while url.path != "/" {
            url = url.deletingLastPathComponent()
            let candidate = url.appendingPathComponent(
                "Tests/Fixtures/taxtriage-odr-3.3.8/SRR12486983/report/SRR12486983.odr.txt"
            )
            if FileManager.default.fileExists(atPath: candidate.path) { return candidate }
        }
        throw XCTSkip("taxtriage-odr-3.3.8 fixture not found")
    }

    private func matrixLines(of result: URL) throws -> [String] {
        let output = folder.appendingPathComponent("matrix-\(UUID().uuidString).csv")
        _ = try TaxTriageCommand.ExportOrganismMatrixSubcommand.parse([result.path, "--output", output.path]).export()
        return try String(contentsOf: output, encoding: .utf8).split(separator: "\n").map(String.init)
    }

    private func resultsLines(of result: URL) throws -> [String] {
        let output = folder.appendingPathComponent("results-\(UUID().uuidString).csv")
        _ = try TaxTriageCommand.ExportResultsSubcommand.parse(
            [result.path, "--output-format", "csv", "--output", output.path]
        ).export()
        return try String(contentsOf: output, encoding: .utf8).split(separator: "\n").map(String.init)
    }

    private func reportText(of result: URL) throws -> String {
        let output = folder.appendingPathComponent("report-\(UUID().uuidString).txt")
        _ = try TaxTriageCommand.ExportBatchReportSubcommand.parse([result.path, "--output", output.path]).export()
        return try String(contentsOf: output, encoding: .utf8)
    }
}
