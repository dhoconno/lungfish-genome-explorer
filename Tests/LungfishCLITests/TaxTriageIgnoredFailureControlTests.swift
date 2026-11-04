// TaxTriageIgnoredFailureControlTests.swift - A control whose task Nextflow ignored is not a clean control
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Lane TTCONTROLS, row TAXTRIAGE-IGNORED-FAILURES-UNREAD (BIO backlog 2 of the TTBUILDDB review). The pipeline gives
// most processes an ignore error strategy, so a control whose alignment task died ends the run with exit 0 and no
// rows. The sidecar's `ignoredFailures` names the sample of each such task (`MINIMAP2_ALIGN (NTC1)`), and nothing read
// it, so that control read as a clean control and the exports said No. The tests run the real importer, `build-db`
// and the CLI exports. The three guards pass at the base and keep the rule narrow.

import XCTest
@testable import LungfishCLI
@testable import LungfishIO
@testable import LungfishWorkflow

final class TaxTriageIgnoredFailureControlTests: XCTestCase {
    private static let shared = "Bradyrhizobium sp. WCU1"
    private static let other = "Human alphaherpesvirus 1"

    private var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("TaxTriageIgnoredFailure-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    // MARK: - A control with no rows whose task was ignored

    func testMatrixReadsNotCheckedForAControlWithNoRowsWhoseTaskNextflowIgnored() async throws {
        let result = try await importedRun(reports: [("patient", [0, 1])], ignored: [Self.ignored("MINIMAP2_ALIGN", "NTC1")])

        let shared = try XCTUnwrap(try matrixLines(of: result).first { $0.hasPrefix("\(Self.shared),") })
        XCTAssertTrue(shared.contains(",Not checked,"), "the control has no result, but the matrix said: \(shared)")
        XCTAssertFalse(shared.contains(",No,"), "the matrix read No for a control that has no result: \(shared)")
    }

    /// The task label carries the name the pipeline gave the sample, `NTC_1` for the control typed `NTC 1`.
    func testMatrixFindsTheControlByTheNameTheTaskLabelCarries() async throws {
        let result = try await importedRun(
            reports: [("patient", [0, 1])], control: "NTC 1", ignored: [Self.ignored("MINIMAP2_ALIGN", "NTC_1")]
        )

        let shared = try XCTUnwrap(try matrixLines(of: result).first { $0.hasPrefix("\(Self.shared),") })
        XCTAssertTrue(shared.contains(",Not checked,"), shared)
    }

    func testReportSaysTheControlFailedWhenItsTaskNextflowIgnored() async throws {
        let result = try await importedRun(reports: [("patient", [0, 1])], ignored: [Self.ignored("MINIMAP2_ALIGN", "NTC1")])

        let report = try reportText(of: result)
        XCTAssertTrue(report.contains("NTC1 (failed, no result)"), report)
        XCTAssertTrue(report.contains("The negative control NTC1 failed, so Lungfish has no result for it."), report)
        XCTAssertFalse(report.contains("No organisms detected in negative controls."), report)
    }

    func testResultsExportReadsNotCheckedInTheCellWhenAControlsTaskWasIgnored() async throws {
        let result = try await importedRun(reports: [("patient", [0, 1])], ignored: [Self.ignored("MINIMAP2_ALIGN", "NTC1")])

        let rows = try resultsLines(of: result).filter { $0.contains(",\(Self.shared),") }
        XCTAssertEqual(rows.count, 1, "\(rows)")
        XCTAssertTrue(rows.allSatisfy { $0.hasSuffix(",Not checked") }, "\(rows)")
    }

    // MARK: - The entry the parser writes from the pipeline's own log note (BIO review, should-fix 1)

    /// The pipeline's note, read by the real parser, names the control as the hand-made entries above do.
    func testMatrixReadsNotCheckedForAControlNamedByARealNextflowNote() async throws {
        let result = try await importedRun(
            reports: [("patient", [0, 1])], ignored: [Self.parsedEntry(process: "MINIMAP2_ALIGN", tag: "NTC1")]
        )

        let shared = try XCTUnwrap(try matrixLines(of: result).first { $0.hasPrefix("\(Self.shared),") })
        XCTAssertTrue(shared.contains(",Not checked,"), shared)
    }

    /// The parser cuts a task's tag at its first dot and the pipeline keeps dots in a sample name, so a control typed
    /// `NTC.1` is `NTC` by the entry's sample and `NTC.1` by the whole tag.
    func testMatrixReadsNotCheckedForAControlWhoseNameHasADot() async throws {
        let result = try await importedRun(
            reports: [("patient", [0, 1])],
            control: "NTC.1",
            ignored: [Self.parsedEntry(process: "MINIMAP2_ALIGN", tag: "NTC.1")]
        )

        let shared = try XCTUnwrap(try matrixLines(of: result).first { $0.hasPrefix("\(Self.shared),") })
        XCTAssertTrue(shared.contains(",Not checked,"), "the dotted control has no result, but the matrix said: \(shared)")
    }

    // MARK: - Guards, true at the base and after

    /// An entry that names the patient says nothing about the control.
    func testAnEntryNamingThePatientLeavesTheCleanControlClean() async throws {
        let result = try await importedRun(reports: [("patient", [0, 1])], ignored: [Self.ignored("MINIMAP2_ALIGN", "patient")])

        let shared = try XCTUnwrap(try matrixLines(of: result).first { $0.hasPrefix("\(Self.shared),") })
        XCTAssertTrue(shared.contains(",No,"), shared)
    }

    /// A control that has rows keeps reading from them, and an organism it does not hold still reads No, since a cell
    /// cannot say more (BIO ruling 3, the Known limit). The report says in words that a step of the control was skipped
    /// and its results may be incomplete (BIO review, should-fix 2).
    func testAnEntryNamingAControlThatHasRowsKeepsReadingItsRows() async throws {
        let result = try await importedRun(
            reports: [("patient", [0, 1]), ("NTC1", [0])], ignored: [Self.ignored("MINIMAP2_ALIGN", "NTC1")]
        )

        let lines = try matrixLines(of: result)
        let shared = try XCTUnwrap(lines.first { $0.hasPrefix("\(Self.shared),") })
        let other = try XCTUnwrap(lines.first { $0.hasPrefix("\(Self.other),") })
        XCTAssertTrue(shared.contains(",Yes,"), shared)
        XCTAssertTrue(other.contains(",No,"), other)
        let report = try reportText(of: result)
        XCTAssertTrue(report.contains("may be incomplete"), "a step of the control was skipped, but the report said: \(report)")
        XCTAssertTrue(report.contains("(MINIMAP2_ALIGN)"), report)
        XCTAssertFalse(report.contains("(failed, no result)"), "the control has rows, so it did not fail: \(report)")
    }

    /// FASTQC, NANOPLOT and MULTIQC only draw quality plots (`onlyAffectsQualityPlots`), so a control whose plot failed
    /// and that found nothing is still a clean control.
    func testAnEntryThatOnlyAffectsQualityPlotsLeavesTheControlClean() async throws {
        let result = try await importedRun(reports: [("patient", [0, 1])], ignored: [Self.ignored("FASTQC", "NTC1")])

        let shared = try XCTUnwrap(try matrixLines(of: result).first { $0.hasPrefix("\(Self.shared),") })
        XCTAssertTrue(shared.contains(",No,"), shared)
    }

    /// A clean control with a dot in its name makes the pipeline's routine empty-reference entry, and the step that saves
    /// the run drops it. The helper that drops it looked the files up by the name cut at the first dot, kept the entry,
    /// and the control then read as failed with words that were false (lane TTCONTROLS, BIO closing read, fix B).
    func testACleanControlWhoseNameHasADotStaysCleanWhenOnlyTheRoutineEntryNamesIt() async throws {
        let source = folder.appendingPathComponent("run", isDirectory: true)
        for directory in ["map", "combine", "download"] {
            try FileManager.default.createDirectory(
                at: source.appendingPathComponent(directory, isDirectory: true), withIntermediateDirectories: true
            )
        }
        try "Acc\tAssembly\tOrganism_Name\tDescription\tMapped_Value\n".write(
            to: source.appendingPathComponent("map/NTC.1.merged.taxid.tsv"), atomically: true, encoding: .utf8
        )
        try Data().write(to: source.appendingPathComponent("combine/NTC.1.combined.gcfmap.tsv"))
        try Data().write(to: source.appendingPathComponent("download/NTC.1.dwnld.references.fasta"))
        let routine = try Self.parsedEntry(process: "ALIGNMENT_PER_SAMPLE", tag: "NTC.1")

        let kept = TaxTriageResult.sanitizeIgnoredFailures([routine], outputDirectory: source)
        let result = try await importedRun(reports: [("patient", [0, 1])], control: "NTC.1", ignored: kept)

        let shared = try XCTUnwrap(try matrixLines(of: result).first { $0.hasPrefix("\(Self.shared),") })
        XCTAssertTrue(shared.contains(",No,"), "the control is clean, but the matrix said: \(shared)")
        let report = try reportText(of: result)
        XCTAssertFalse(report.contains("failed, no result"), "the control is clean, but the report said: \(report)")
    }

    // MARK: - Helpers

    private static func ignored(_ process: String, _ sample: String) -> TaxTriageIgnoredFailure {
        TaxTriageIgnoredFailure(
            processPath: "NFCORE_TAXTRIAGE:TAXTRIAGE:\(process)",
            processName: process,
            taskLabel: "\(process) (\(sample))",
            sampleID: sample,
            exitCode: 137
        )
    }

    /// The entry that the parser writes for the pipeline's note about a task of `tag`, which holds the whole tag as the
    /// task label and the sample cut at its first dot.
    private static func parsedEntry(process: String, tag: String) throws -> TaxTriageIgnoredFailure {
        let note = "NOTE: Process `NFCORE_TAXTRIAGE:TAXTRIAGE:\(process) (\(tag))` terminated with an error exit status (255) -- Error is ignored"
        return try XCTUnwrap(TaxTriageResult.parseIgnoredFailures(fromNextflowLogText: note).first, note)
    }

    /// Imports a run folder of flat reports and builds the database. `reports` lists each sample with the rows of the
    /// fixture report it holds, counted from 0 (0 is Bradyrhizobium sp. WCU1, 1 is Human alphaherpesvirus 1). The
    /// sidecar lists the patient and the control, and carries `ignored` as the run's ignored task failures. A control
    /// without a report is a control with no rows.
    private func importedRun(
        reports: [(String, [Int])],
        control: String = "NTC1",
        ignored: [TaxTriageIgnoredFailure]
    ) async throws -> URL {
        let source = folder.appendingPathComponent("run", isDirectory: true)
        for (id, rows) in reports {
            try writeReport(for: id, rows: rows, to: source.appendingPathComponent("report/\(id).odr.txt"))
        }
        let config = TaxTriageConfig(
            samples: [("patient", false), (control, true)].map {
                TaxTriageSample(
                    sampleId: $0.0,
                    fastq1: URL(fileURLWithPath: "/nonexistent/sample.fastq.gz"),
                    isNegativeControl: $0.1
                )
            },
            platform: .illumina,
            outputDirectory: source
        )
        try TaxTriageResult(
            config: config, runtime: 10, exitCode: 0, outputDirectory: source, ignoredFailures: ignored
        ).save()
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
