// TaxTriageImportedExportTests.swift - What the exports of an imported TaxTriage run say about its negative controls
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 3.2 lane TTIMPORT, row IMPORT-TAXTRIAGE-BATCH-HIDDEN, BIO-IMPORT-BATCH items 2, 3 and 11. The real importer
// reads a run folder, `build-db taxtriage` builds the database the viewer builds, and the three export leaves write
// what a person gets. An import that keeps the run's marks flags the organism a control holds. An import that does
// not say which samples were controls reads Not recorded and shows no default as the run's. A run with samples and
// no control still reads No.
//
// The tests sit in the CLI target because the leaves and `build-db` live there. `LungfishWorkflowTests` cannot reach them.

import XCTest
@testable import LungfishCLI
@testable import LungfishIO
@testable import LungfishWorkflow

final class TaxTriageImportedExportTests: XCTestCase {
    private static let shared = "Bradyrhizobium sp. WCU1"
    private static let controlsNotRecorded =
        "Negative Controls: Not recorded. This import does not say which samples were controls, so contamination risk is unknown."

    private var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("TaxTriageImportedExport-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    // MARK: - Tests

    /// A run with a marked control keeps the mark through the import, so every export flags the shared organism.
    func testImportedRunExportsItsNegativeControl() async throws {
        let result = try await importedRun(samples: [("S1", false), ("NTC1", true)])

        let shared = try XCTUnwrap(try matrixLines(of: result).first { $0.hasPrefix("\(Self.shared),") })
        XCTAssertTrue(shared.contains(",2/2,Yes,"), "the matrix did not flag the organism the control holds: \(shared)")

        let report = try reportText(of: result)
        XCTAssertTrue(report.contains("Negative Controls: NTC1"), report)
        XCTAssertTrue(report.contains("NTC1 [NTC]"), report)
        XCTAssertTrue(report.contains("Platform: Oxford Nanopore"), report)

        let rows = try resultsLines(of: result).filter { $0.contains(",\(Self.shared),") }
        XCTAssertEqual(rows.count, 2, "the shared organism has one row per sample: \(rows)")
        XCTAssertTrue(rows.allSatisfy { $0.hasSuffix(",yes") }, "the results cell did not flag both samples: \(rows)")
    }

    /// An import that cannot say which samples were controls reads Not recorded in every place a flag or a run
    /// setting would show, and shows no default as the run's.
    func testImportWithNoSamplesReadsNotRecorded() async throws {
        let result = try await importedRun(samples: nil)

        let matrix = try matrixLines(of: result)
        let matrixRows = Array(matrix.dropFirst())
        XCTAssertFalse(matrixRows.isEmpty, "the matrix holds no organism: \(matrix)")
        XCTAssertTrue(matrixRows.allSatisfy { $0.contains(",Not recorded,") }, "matrix cells: \(matrixRows)")

        let resultsRows = Array(try resultsLines(of: result).dropFirst())
        XCTAssertFalse(resultsRows.isEmpty, "the results table holds no row")
        XCTAssertTrue(resultsRows.allSatisfy { $0.hasSuffix(",Not recorded") }, "results cells: \(resultsRows)")

        let report = try reportText(of: result)
        for line in ["Platform: Not recorded", "Runtime: Not recorded", "Exit Code: Not recorded", Self.controlsNotRecorded] {
            XCTAssertTrue(report.contains(line), "the report lacks \(line): \(report)")
        }
        for text in [matrix.joined(separator: "\n"), report] {
            XCTAssertFalse(text.contains("Illumina"), "a default platform shows as the run's: \(text)")
            XCTAssertFalse(text.contains("0.0 seconds"), "a default runtime shows as the run's: \(text)")
        }
    }

    /// A run that lists its samples and marks none keeps No and a blank cell, since no control was used.
    func testRunWithSamplesAndNoControlStillReadsNo() async throws {
        let result = try await importedRun(samples: [("S1", false), ("S2", false)])

        let shared = try XCTUnwrap(try matrixLines(of: result).first { $0.hasPrefix("\(Self.shared),") })
        XCTAssertTrue(shared.contains(",2/2,No,"), "a run with no control must keep No: \(shared)")
        let rows = try resultsLines(of: result).filter { $0.contains(",\(Self.shared),") }
        XCTAssertTrue(rows.allSatisfy { $0.hasSuffix(",") }, "the results cell must stay blank: \(rows)")
        XCTAssertFalse(try reportText(of: result).contains("Not recorded"))
    }

    /// A two-sample batch with no root `report/` opens both samples, and the control's mark reaches the matrix.
    func testImportedTwoSampleBatchOpensBothSamples() async throws {
        let source = folder.appendingPathComponent("batch", isDirectory: true)
        try writeReport(for: "S1", rows: 3, to: source.appendingPathComponent("S1/report/S1.odr.txt"))
        try writeReport(for: "NTC1", rows: 1, to: source.appendingPathComponent("NTC1/report/NTC1.odr.txt"))
        let config = TaxTriageConfig(
            samples: [
                TaxTriageSample(sampleId: "S1", fastq1: URL(fileURLWithPath: "/nonexistent/S1.fastq.gz")),
                TaxTriageSample(sampleId: "NTC1", fastq1: URL(fileURLWithPath: "/nonexistent/NTC1.fastq.gz"), isNegativeControl: true),
            ],
            platform: .oxford,
            outputDirectory: source
        )
        try TaxTriageResult(config: config, runtime: 1234.5, exitCode: 0, outputDirectory: source).save()
        let imported = try MetagenomicsImportService.importTaxTriage(
            inputURL: source,
            outputDirectory: folder.appendingPathComponent("imports", isDirectory: true)
        )
        XCTAssertEqual(imported.reportEntryCount, 4)
        let build = try BuildDbCommand.TaxTriageSubcommand.parse([imported.resultDirectory.path, "--no-cleanup", "-q"])
        try await build.run()
        let database = try TaxTriageDatabase(at: imported.resultDirectory.appendingPathComponent("taxtriage.sqlite"))
        XCTAssertEqual(try database.fetchSamples().map(\.sample).sorted(), ["NTC1", "S1"])
        let shared = try XCTUnwrap(try matrixLines(of: imported.resultDirectory).first { $0.hasPrefix("\(Self.shared),") })
        XCTAssertTrue(shared.contains(",2/2,Yes,"), "the matrix did not flag the organism the control holds: \(shared)")
    }

    // MARK: - Helpers

    /// Imports a run folder of flat reports (`S1` holds 3 rows and each other sample 1) and builds the database.
    /// `samples` nil leaves out the run's sidecar, so the importer writes its own with no samples.
    private func importedRun(samples: [(String, Bool)]?) async throws -> URL {
        let source = folder.appendingPathComponent("run", isDirectory: true)
        let ids = samples?.map(\.0) ?? ["S1", "NTC1"]
        for (index, id) in ids.enumerated() {
            try writeReport(for: id, rows: index == 0 ? 3 : 1, to: source.appendingPathComponent("report/\(id).odr.txt"))
        }
        if let samples {
            let config = TaxTriageConfig(
                samples: samples.map {
                    TaxTriageSample(
                        sampleId: $0.0,
                        fastq1: URL(fileURLWithPath: "/nonexistent/\($0.0).fastq.gz"),
                        isNegativeControl: $0.1
                    )
                },
                platform: .oxford,
                outputDirectory: source
            )
            try TaxTriageResult(config: config, runtime: 1234.5, exitCode: 0, outputDirectory: source).save()
        }
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
        return try lines(of: output)
    }

    private func resultsLines(of result: URL) throws -> [String] {
        let output = folder.appendingPathComponent("results-\(UUID().uuidString).csv")
        _ = try TaxTriageCommand.ExportResultsSubcommand.parse(
            [result.path, "--output-format", "csv", "--output", output.path]
        ).export()
        return try lines(of: output)
    }

    private func reportText(of result: URL) throws -> String {
        let output = folder.appendingPathComponent("report-\(UUID().uuidString).txt")
        _ = try TaxTriageCommand.ExportBatchReportSubcommand.parse([result.path, "--output", output.path]).export()
        return try String(contentsOf: output, encoding: .utf8)
    }

    private func lines(of url: URL) throws -> [String] {
        try String(contentsOf: url, encoding: .utf8).split(separator: "\n").map(String.init)
    }
}
