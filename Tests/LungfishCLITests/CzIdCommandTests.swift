// CzIdCommandTests.swift - Tests for CZ-ID CLI command registration
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import ArgumentParser
import LungfishTestSupport
import XCTest
@testable import LungfishCLI
@testable import LungfishWorkflow

final class CzIdCommandTests: XCTestCase {
    func testCzIdCommandIsRegisteredAtTopLevel() {
        let isRegistered = LungfishCLI.configuration.subcommands.contains { command in
            command.configuration.commandName == CzIdCommand.configuration.commandName
        }

        XCTAssertTrue(isRegistered)
    }

    func testImportAcceptsExtractedFolderAndRecordsReplayableCommand() async throws {
        let tempDir = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let exportDir = tempDir.appendingPathComponent("czid-export", isDirectory: true)
        let reportsDir = exportDir.appendingPathComponent("reports", isDirectory: true)
        try FileManager.default.createDirectory(at: reportsDir, withIntermediateDirectories: true)
        try Self.czIdReportText.write(
            to: reportsDir.appendingPathComponent("taxon_report.tsv"),
            atomically: true,
            encoding: .utf8
        )
        let outputDir = tempDir.appendingPathComponent("imported", isDirectory: true)

        let command = try CzIdCommand.ImportSubcommand.parse([
            exportDir.path,
            "--output-dir", outputDir.path,
            "--quiet",
        ])
        try await command.run()

        XCTAssertTrue(FileManager.default.fileExists(
            atPath: outputDir.appendingPathComponent("classification.czid.tsv").path
        ))
        let recordedCommand = try firstProvenanceCommand(in: outputDir)
        XCTAssertEqual(recordedCommand, ["lungfish-cli", "cz-id", "import", exportDir.path, "--output-dir", outputDir.path])
    }

    func testImportAcceptsZipArchiveAndRecordsReplayableCommand() async throws {
        let tempDir = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let payloadDir = tempDir.appendingPathComponent("payload", isDirectory: true)
        let nestedDir = payloadDir.appendingPathComponent("czid/results", isDirectory: true)
        try FileManager.default.createDirectory(at: nestedDir, withIntermediateDirectories: true)
        try Self.czIdReportText.write(
            to: nestedDir.appendingPathComponent("taxon_report.tsv"),
            atomically: true,
            encoding: .utf8
        )
        let archiveURL = tempDir.appendingPathComponent("czid-export.zip")
        try makeZipArchive(from: payloadDir, to: archiveURL)
        let outputDir = tempDir.appendingPathComponent("imported-zip", isDirectory: true)

        let command = try CzIdCommand.ImportSubcommand.parse([
            archiveURL.path,
            "--output-dir", outputDir.path,
            "--quiet",
        ])
        try await command.run()

        XCTAssertTrue(FileManager.default.fileExists(
            atPath: outputDir.appendingPathComponent("classification.czid.tsv").path
        ))
        let recordedCommand = try firstProvenanceCommand(in: outputDir)
        XCTAssertEqual(recordedCommand, ["lungfish-cli", "cz-id", "import", archiveURL.path, "--output-dir", outputDir.path])
    }

    // MARK: - CZ-ID's own taxon reports (CZID-REAL-EXPORT-FORMAT, S1)

    /// `cz-id import` of czid-web's `report_csv` shape (comma CSV, numeric `tax_level`, `nt_count`, no root row)
    /// writes the genus clade from the genus row, the genus direct count as what its species leave, and the root
    /// from `nt_count` / `nt_rpm`.
    func testImportOfTheReportTableCSVWritesCladeCounts() async throws {
        let tempDir = try TestTempDirectory.make(prefix: "czid-command-report-csv")
        defer { TestTempDirectory.cleanup(tempDir) }
        let outputDir = tempDir.appendingPathComponent("imported", isDirectory: true)

        let command = try CzIdCommand.ImportSubcommand.parse([
            sharedFixtureURL("sample_report.csv").path,
            "--output-dir", outputDir.path,
            "--quiet",
        ])
        try await command.run()

        let kreport = try String(contentsOf: outputDir.appendingPathComponent("classification.kreport"), encoding: .utf8)
        XCTAssertEqual(kreport.components(separatedBy: "\n"), [
            "100.00\t2000000\t1997365\tR\t1\troot",
            "0.09\t1790\t60\tG\t1279\t  Staphylococcus",
            "0.08\t1520\t1520\tS\t1280\t    Staphylococcus aureus",
            "0.01\t210\t210\tS\t1282\t    Staphylococcus epidermidis",
            "0.04\t845\t5\tG\t694002\t  Betacoronavirus",
            "0.04\t840\t840\tS\t2697049\t    Severe acute respiratory syndrome coronavirus 2",
            "",
        ])
    }

    /// A report the converter cannot count is refused with Sol's words (FIX-CZID Z1, Z2 and Z9) and the input exit
    /// code, and nothing is written.
    func testImportRefusesReportsItCannotCountWithTheInputExitCode() async throws {
        let scratch = try ImportStreamCapture.Scratch()
        defer { scratch.remove() }
        let cases: [(name: String, text: String, words: String)] = [
            (
                "no-counts.csv",
                "tax_id,tax_level,genus_tax_id,name,nt_rpm\n1279,2,1279,Staphylococcus,895.0\n",
                "no-counts.csv has no read count column (nt_count or nr_count), so counts cannot be assigned to taxa. Nothing was imported."
            ),
            (
                "no-tax-id.csv",
                "tax_level,genus_tax_id,name,nt_rpm,nt_count\n2,1279,Staphylococcus,895.0,1790\n",
                "no-tax-id.csv is missing the tax_id column required for CZ-ID taxon reports. Nothing was imported."
            ),
            (
                "no-name.csv",
                "tax_id,tax_level,genus_tax_id,nt_rpm,nt_count\n1279,2,1279,895.0,1790\n",
                "no-name.csv is missing the name column required for CZ-ID taxon reports. Nothing was imported."
            ),
            (
                "empty-name.csv",
                "tax_id,tax_level,genus_tax_id,name,nt_rpm,nt_count\n1279,2,1279,Staphylococcus,895.0,1790\n1280,1,1279,,760.0,1520\n",
                "Row 3 of empty-name.csv has no name value. Nothing was imported."
            ),
        ]
        for testCase in cases {
            let source = try scratch.write("inputs/\(testCase.name)", testCase.text)
            let outputDir = scratch.root.appendingPathComponent("out-\(testCase.name)", isDirectory: true)
            let command = try CzIdCommand.ImportSubcommand.parse([source.path, "--output-dir", outputDir.path])
            let output = try await ImportStreamCapture.capture(in: scratch) { try await command.run() }

            XCTAssertEqual((output.thrown as? ExitCode)?.rawValue, CLIExitCode.inputError.rawValue, testCase.name)
            XCTAssertEqual(output.standardOutput, ["✗ \(testCase.words)"], testCase.name)
            XCTAssertEqual(FileManager.default.fileExists(atPath: outputDir.path), false, testCase.name)
        }

        let source = try scratch.write("inputs/summary-no-counts.csv", cases[0].text)
        let summary = try CzIdCommand.SummarySubcommand.parse([source.path])
        let output = try await ImportStreamCapture.capture(in: scratch) { try await summary.run() }
        XCTAssertEqual((output.thrown as? ExitCode)?.rawValue, CLIExitCode.inputError.rawValue)
        XCTAssertEqual(output.standardOutput, [
            "✗ summary-no-counts.csv has no read count column (nt_count or nr_count), so counts cannot be assigned to taxa. Nothing was imported.",
        ])
    }

    /// `Tests/Fixtures/czid`.
    private func sharedFixtureURL(_ name: String) -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/czid", isDirectory: true)
            .appendingPathComponent(name)
    }

    private static let czIdReportText = """
    sample_name\tproject_id\tpipeline_version\tnt_db_version\tnr_db_version\ttax_id\ttaxon_name\trank\tnt_read_count\tnt_rpm\tnr_read_count\tnr_rpm
    Sample-CZ-001\tProject-42\t8.4\tnt_2025_12_01\tnr_2025_12_01\t1\troot\troot\t1200\t1000000\t1200\t1000000
    Sample-CZ-001\tProject-42\t8.4\tnt_2025_12_01\tnr_2025_12_01\t10239\tViruses\tsuperkingdom\t88\t73333\t12\t10000
    Sample-CZ-001\tProject-42\t8.4\tnt_2025_12_01\tnr_2025_12_01\t2697049\tSevere acute respiratory syndrome coronavirus 2\tspecies\t42\t35000\t5\t4166.7
    """

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("czid-command-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func makeZipArchive(from directory: URL, to archiveURL: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        process.currentDirectoryURL = directory
        process.arguments = ["-qry", archiveURL.path, "."]
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
    }

    private func firstProvenanceCommand(in outputDir: URL) throws -> [String] {
        let provenance = try XCTUnwrap(ProvenanceEnvelopeReader.loadCanonical(from: outputDir))
        return try XCTUnwrap(provenance.steps.first?.argv)
    }
}
