// CzIdCommandTests.swift - Tests for CZ-ID CLI command registration
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

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
        XCTAssertEqual(recordedCommand, ["lungfish", "cz-id", "import", exportDir.path, "--output-dir", outputDir.path])
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
        XCTAssertEqual(recordedCommand, ["lungfish", "cz-id", "import", archiveURL.path, "--output-dir", outputDir.path])
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
        let provenanceURL = outputDir.appendingPathComponent(ProvenanceRecorder.provenanceFilename)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(
            with: try Data(contentsOf: provenanceURL)
        ) as? [String: Any])
        let steps = try XCTUnwrap(object["steps"] as? [[String: Any]])
        let firstStep = try XCTUnwrap(steps.first)
        return try XCTUnwrap(firstStep["command"] as? [String])
    }
}
