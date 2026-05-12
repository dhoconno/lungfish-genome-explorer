// ProvenanceExportCommandTests.swift - CLI tests for provenance export
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import XCTest
@testable import LungfishCLI
@testable import LungfishWorkflow

final class ProvenanceExportCommandTests: XCTestCase {
    func testProvenanceTopLevelSubcommandsContainsExport() {
        let subcommands = ProvenanceCommand.configuration.subcommands.map { $0.configuration.commandName }

        XCTAssertTrue(subcommands.contains("export"))
    }

    func testProvenanceExportParsesInputFormatAndOutput() throws {
        let command = try ProvenanceCommand.ExportSubcommand.parse([
            "/tmp/.lungfish-provenance.json",
            "--format", "shell",
            "--output", "/tmp/provenance-export"
        ])

        XCTAssertEqual(command.input, "/tmp/.lungfish-provenance.json")
        XCTAssertEqual(command.format, "shell")
        XCTAssertEqual(command.output, "/tmp/provenance-export")
    }

    func testShellExportWritesRunScriptAndCopiesCanonicalSourceSidecar() async throws {
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let sidecarURL = directory.appendingPathComponent(ProvenanceRecorder.provenanceFilename)
        let outputDirectory = directory.appendingPathComponent("export", isDirectory: true)
        let envelope = ProvenanceEnvelope.fixture(
            workflowName: "fastq.trim.fastp",
            toolName: "fastp",
            toolVersion: "0.24.1",
            argv: ["fastp", "-i", "reads 1.fastq", "-o", "trimmed.fastq"],
            inputPath: "reads 1.fastq",
            outputPath: "trimmed.fastq"
        )
        try ProvenanceJSON.encoder.encode(envelope).write(to: sidecarURL, options: .atomic)

        let command = try ProvenanceCommand.ExportSubcommand.parse([
            sidecarURL.path,
            "--format", "shell",
            "--output", outputDirectory.path
        ])

        try await command.run()

        let runScriptURL = outputDirectory.appendingPathComponent("run.sh")
        let copiedSidecarURL = outputDirectory
            .appendingPathComponent("provenance", isDirectory: true)
            .appendingPathComponent(ProvenanceRecorder.provenanceFilename)
        XCTAssertTrue(FileManager.default.fileExists(atPath: runScriptURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: copiedSidecarURL.path))

        let script = try String(contentsOf: runScriptURL, encoding: .utf8)
        XCTAssertTrue(script.contains("fastp"), script)
        XCTAssertTrue(script.contains("'reads 1.fastq'") || script.contains("\"reads 1.fastq\""), script)
        XCTAssertTrue(script.contains("trimmed.fastq"), script)

        XCTAssertEqual(try Data(contentsOf: copiedSidecarURL), try Data(contentsOf: sidecarURL))
    }

    func testFormatParserAcceptsCliValuesAndRejectsUnsupportedValues() throws {
        XCTAssertEqual(try ProvenanceExportFormat.cliValue("shell"), .shell)
        XCTAssertEqual(try ProvenanceExportFormat.cliValue("nextflow"), .nextflow)
        XCTAssertEqual(try ProvenanceExportFormat.cliValue("snakemake"), .snakemake)
        XCTAssertEqual(try ProvenanceExportFormat.cliValue("methods"), .methods)
        XCTAssertEqual(try ProvenanceExportFormat.cliValue("json"), .json)
        XCTAssertEqual(try ProvenanceExportFormat.cliValue("Shell Script"), .shell)

        XCTAssertThrowsError(try ProvenanceExportFormat.cliValue("python")) { error in
            XCTAssertTrue(error.localizedDescription.contains("Unsupported provenance export format"), error.localizedDescription)
        }
    }

    private func makeTempDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("lungfish-provenance-export-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
