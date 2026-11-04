// TaxTriageControlNameTests.swift - A negative control keeps its flag whatever the pipeline did to its name
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Lane TTBUILDDB, row TAXTRIAGE-CONTROL-NAME-PIPELINE-RENAMED. The pipeline's samplesheet check
// (`bin/check_samplesheet.py`, `_validate_sample`) turns a space into `_`, strips 27 more characters and
// numbers two samples whose names then meet `_T1` and `_T2`. LGE keeps the name the person typed in the
// sidecar, so a control named `NTC 1` has rows under `NTC_1`. The tests run the real importer, `build-db`
// and the CLI exports on a run folder whose sidecar holds the typed name and whose reports hold the name
// the script writes. The names below are what the script wrote when it ran on them (lane report).

import XCTest
@testable import LungfishCLI
@testable import LungfishIO
@testable import LungfishWorkflow

final class TaxTriageControlNameTests: XCTestCase {
    private static let shared = "Bradyrhizobium sp. WCU1"

    /// The name given and the name `check_samplesheet.py` wrote for it, one sample to a samplesheet.
    private static let pipelineNames: [(given: String, written: String)] = [
        ("NTC.1", "NTC.1"),
        ("NTC 1", "NTC_1"),
        ("Water (blank)", "Water_blank"),
        ("Blank [A]", "Blank_A"),
        ("Neg#1 100%", "Neg1_100"),
        ("A&B+C", "ABC"),
        ("Ctrl!@$^`~;", "Ctrl"),
        ("a,b", "ab"),
        ("q\"x*y?z<w>v|u", "qxyzwvu"),
        ("back\\slash", "backslash"),
        ("col:on", "colon"),
        ("sl/ash", "slash"),
        ("brace{a}", "bracea"),
        (" lead", "_lead"),
        ("trail ", "trail_"),
    ]

    private var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("TaxTriageControlName-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    // MARK: - Tests

    /// BIO ruling 2 of TTIMPORT: config `NTC 1` marked, report `NTC_1.odr.txt` with Specimen ID `NTC_1`, the
    /// matrix reads Yes for the organism the control holds, and the report and results flag the control.
    func testControlWithASpaceInItsNameKeepsItsMark() async throws {
        let result = try await importedRun(
            samples: [("S1", false), ("NTC 1", true)],
            reports: ["S1", "NTC_1"]
        )

        let shared = try XCTUnwrap(try matrixLines(of: result).first { $0.hasPrefix("\(Self.shared),") })
        XCTAssertTrue(shared.contains(",2/2,Yes,"), "the matrix did not flag the organism the control holds: \(shared)")
        let report = try reportText(of: result)
        XCTAssertTrue(report.contains("NTC_1 [NTC]"), "the report did not tag the control: \(report)")
        XCTAssertFalse(report.contains("No organisms detected in negative controls."), report)
        let rows = try resultsLines(of: result).filter { $0.contains(",\(Self.shared),") }
        XCTAssertEqual(rows.count, 2, "\(rows)")
        XCTAssertTrue(rows.allSatisfy { $0.hasSuffix(",yes") }, "the results cell did not flag both samples: \(rows)")
    }

    /// Each character class the script strips, and the leading and trailing space it turns into `_`.
    func testControlKeepsItsMarkWhateverCharacterThePipelineStrips() async throws {
        for (given, written) in Self.pipelineNames {
            let result = try await importedRun(
                samples: [("S1", false), (given, true)],
                reports: ["S1", written],
                name: "run-\(UUID().uuidString)"
            )
            let shared = try XCTUnwrap(try matrixLines(of: result).first { $0.hasPrefix("\(Self.shared),") })
            XCTAssertTrue(
                shared.contains(",2/2,Yes,"),
                "the control [\(given)] written as [\(written)] was not flagged: \(shared)"
            )
        }
    }

    /// Two samples that meet after the rule share one name in the results. The flag stays on, and the report
    /// names both samples so a person knows why.
    func testTwoSamplesThatMeetAfterRenamingKeepTheFlagAndSayWhy() async throws {
        let result = try await importedRun(
            samples: [("S1", false), ("NTC 1", true), ("NTC_1", false)],
            reports: ["S1", "NTC_1"]
        )

        let shared = try XCTUnwrap(try matrixLines(of: result).first { $0.hasPrefix("\(Self.shared),") })
        XCTAssertTrue(shared.contains(",2/2,Yes,"), "the flag was lost: \(shared)")
        let report = try reportText(of: result)
        let explaining = report.components(separatedBy: "\n")
            .filter { $0.contains("NTC 1") && $0.contains("NTC_1") && !$0.hasPrefix("Negative Controls:") }
        XCTAssertFalse(explaining.isEmpty, "the report does not say that NTC 1 and NTC_1 meet: \(report)")
    }

    /// In one samplesheet the script numbers two samples whose names meet `_T1` and `_T2`.
    func testPipelineNumberingOfTwoMeetingNamesKeepsTheFlag() async throws {
        let result = try await importedRun(
            samples: [("S1", false), ("NTC 1", true), ("NTC_1", false)],
            reports: ["S1", "NTC_1_T1", "NTC_1_T2"]
        )

        let shared = try XCTUnwrap(try matrixLines(of: result).first { $0.hasPrefix("\(Self.shared),") })
        XCTAssertTrue(shared.contains(",3/3,Yes,"), "the flag was lost after the pipeline numbered the samples: \(shared)")
    }

    // MARK: - Helpers

    /// Imports a run folder of flat reports, the first of which holds 3 rows and each other 1, and builds the
    /// database. The sidecar names `samples` as typed. The reports and the database name `reports`.
    private func importedRun(
        samples: [(String, Bool)],
        reports: [String],
        name: String = "run"
    ) async throws -> URL {
        let source = folder.appendingPathComponent(name, isDirectory: true)
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
        try TaxTriageResult(config: config, runtime: 10, exitCode: 0, outputDirectory: source).save()
        let imported = try MetagenomicsImportService.importTaxTriage(
            inputURL: source,
            outputDirectory: folder.appendingPathComponent("imports-\(name)", isDirectory: true)
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
