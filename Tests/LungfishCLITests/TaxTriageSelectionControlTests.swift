// TaxTriageSelectionControlTests.swift - A selection that leaves out a control still sees what the control holds
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Lane TTCONTROLS, row TAXTRIAGE-SELECTION-LEAVES-OUT-CONTROL (BIO backlog 3 of the TTBUILDDB review). The organism
// matrix and the batch report took the rows of a control from the samples the export was asked for, so
// `--sample patient` on a run whose control NTC1 held the organism read `No`, and the report read `No organisms
// detected in negative controls.` The results export read the controls across all samples. The viewer's Export menu
// runs these same leaves with the ticked samples, so unticking a control reached the same false result. The tests run
// the real importer, `build-db` and the CLI exports.

import XCTest
@testable import LungfishCLI
@testable import LungfishIO
@testable import LungfishWorkflow

final class TaxTriageSelectionControlTests: XCTestCase {
    private static let shared = "Bradyrhizobium sp. WCU1"
    private static let other = "Human alphaherpesvirus 1"

    private var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("TaxTriageSelectionControl-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    // MARK: - Tests

    /// The control NTC1 holds the organism the patient holds, and the selection is the patient alone.
    func testMatrixOfASelectionThatLeavesOutTheControlStillFlagsWhatTheControlHolds() async throws {
        let result = try await importedRun(reports: [("patient", [0, 1, 2]), ("NTC1", [0])])

        let shared = try XCTUnwrap(try matrixLines(of: result, samples: ["patient"]).first { $0.hasPrefix("\(Self.shared),") })
        XCTAssertTrue(shared.contains(",Yes,"), "the control holds it, but the matrix of the selection said: \(shared)")
        XCTAssertFalse(shared.contains(",No,"), "the matrix read No for an organism the control holds: \(shared)")
    }

    /// What the control does not hold still reads No, since the control ran.
    func testMatrixOfThatSelectionReadsNoForWhatTheControlDoesNotHold() async throws {
        let result = try await importedRun(reports: [("patient", [0, 1, 2]), ("NTC1", [0])])

        let other = try XCTUnwrap(try matrixLines(of: result, samples: ["patient"]).first { $0.hasPrefix("\(Self.other),") })
        XCTAssertTrue(other.contains(",No,"), other)
    }

    func testReportOfASelectionThatLeavesOutTheControlListsWhatTheControlHolds() async throws {
        let result = try await importedRun(reports: [("patient", [0, 1, 2]), ("NTC1", [0])])

        let report = try reportText(of: result, samples: ["patient"])
        XCTAssertFalse(report.contains("No organisms detected in negative controls."), report)
        XCTAssertTrue(report.contains("\(Self.shared) (detected in: NTC1, patient)"), report)
        // The per-sample line counts the control from its own rows, not from the ticked samples (BIO review, blocker 1).
        XCTAssertTrue(report.contains("NTC1 [NTC]: 1 organisms ("), report)
        XCTAssertFalse(report.contains("NTC1 [NTC]: 0 organisms"), report)
    }

    /// The control holds an organism that no ticked sample holds. The report is about the controls, so it lists it.
    func testReportNamesAnOrganismTheControlHoldsAndTheSelectionDoesNot() async throws {
        let result = try await importedRun(reports: [("patient", [0]), ("NTC1", [1])])

        let report = try reportText(of: result, samples: ["patient"])
        XCTAssertFalse(report.contains("No organisms detected in negative controls."), report)
        XCTAssertTrue(report.contains("\(Self.other) (detected in: NTC1)"), report)
        let shared = try XCTUnwrap(try matrixLines(of: result, samples: ["patient"]).first { $0.hasPrefix("\(Self.shared),") })
        XCTAssertTrue(shared.contains(",No,"), "the control does not hold \(Self.shared): \(shared)")
    }

    /// The results export reads the controls across all samples, and the matrix and the report now agree with it.
    func testResultsExportOfTheSameSelectionFlagsWhatTheControlHolds() async throws {
        let result = try await importedRun(reports: [("patient", [0, 1, 2]), ("NTC1", [0])])

        let rows = try resultsLines(of: result, samples: ["patient"]).filter { $0.contains(",\(Self.shared),") }
        XCTAssertEqual(rows.count, 1, "\(rows)")
        XCTAssertTrue(rows.allSatisfy { $0.hasSuffix(",yes") }, "\(rows)")
    }

    // MARK: - Helpers

    /// Imports a run folder of flat reports and builds the database. `reports` lists each sample with the rows of the
    /// fixture report it holds, counted from 0 (0 is Bradyrhizobium sp. WCU1, 1 is Human alphaherpesvirus 1). The
    /// sidecar lists the patient and the control NTC1.
    private func importedRun(reports: [(String, [Int])]) async throws -> URL {
        let source = folder.appendingPathComponent("run", isDirectory: true)
        for (id, rows) in reports {
            try writeReport(for: id, rows: rows, to: source.appendingPathComponent("report/\(id).odr.txt"))
        }
        let config = TaxTriageConfig(
            samples: [("patient", false), ("NTC1", true)].map {
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
            outputDirectory: folder.appendingPathComponent("imports", isDirectory: true)
        )
        let build = try BuildDbCommand.TaxTriageSubcommand.parse([imported.resultDirectory.path, "--no-cleanup", "-q"])
        try await build.run()
        return imported.resultDirectory
    }

    /// A report table of the fixture's header and the data lines at `rows`, with the sample named in each line.
    private func writeReport(for sample: String, rows: [Int], to url: URL) throws {
        let lines = try String(contentsOf: try fixtureReport(), encoding: .utf8)
            .components(separatedBy: "\n").filter { !$0.isEmpty }
        var kept = [lines[0]]
        for index in rows {
            var fields = lines[1 + index].components(separatedBy: "\t")
            fields[3] = sample
            kept.append(fields.joined(separator: "\t"))
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

    private func selection(_ samples: [String]) -> [String] {
        samples.flatMap { ["--sample", $0] }
    }

    private func matrixLines(of result: URL, samples: [String]) throws -> [String] {
        let output = folder.appendingPathComponent("matrix-\(UUID().uuidString).csv")
        _ = try TaxTriageCommand.ExportOrganismMatrixSubcommand.parse(
            [result.path] + selection(samples) + ["--output", output.path]
        ).export()
        return try String(contentsOf: output, encoding: .utf8).split(separator: "\n").map(String.init)
    }

    private func resultsLines(of result: URL, samples: [String]) throws -> [String] {
        let output = folder.appendingPathComponent("results-\(UUID().uuidString).csv")
        _ = try TaxTriageCommand.ExportResultsSubcommand.parse(
            [result.path] + selection(samples) + ["--output-format", "csv", "--output", output.path]
        ).export()
        return try String(contentsOf: output, encoding: .utf8).split(separator: "\n").map(String.init)
    }

    private func reportText(of result: URL, samples: [String]) throws -> String {
        let output = folder.appendingPathComponent("report-\(UUID().uuidString).txt")
        _ = try TaxTriageCommand.ExportBatchReportSubcommand.parse(
            [result.path] + selection(samples) + ["--output", output.path]
        ).export()
        return try String(contentsOf: output, encoding: .utf8)
    }
}
