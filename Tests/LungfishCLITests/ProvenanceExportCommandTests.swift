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

    func testShellExportWritesRunScriptAndCanonicalizesSourceSidecar() async throws {
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

        let copiedEnvelope = try ProvenanceJSON.decoder.decode(
            ProvenanceEnvelope.self,
            from: try Data(contentsOf: copiedSidecarURL)
        )
        XCTAssertEqual(copiedEnvelope.schemaVersion, 1)
        XCTAssertEqual(copiedEnvelope.workflowName, "fastq.trim.fastp")
        XCTAssertEqual(copiedEnvelope.argv, ["fastp", "-i", "reads 1.fastq", "-o", "trimmed.fastq"])

        let preservedSourceURL = outputDirectory
            .appendingPathComponent("provenance", isDirectory: true)
            .appendingPathComponent("source-\(sidecarURL.lastPathComponent)")
        XCTAssertEqual(try Data(contentsOf: preservedSourceURL), try Data(contentsOf: sidecarURL))
    }

    func testNextflowExportEscapesPortableCommands() async throws {
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let sidecarURL = directory.appendingPathComponent(ProvenanceRecorder.provenanceFilename)
        let outputDirectory = directory.appendingPathComponent("nextflow-export", isDirectory: true)
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
            "--format", "nextflow",
            "--output", outputDirectory.path
        ])

        try await command.run()

        let main = try String(
            contentsOf: outputDirectory.appendingPathComponent("main.nf"),
            encoding: .utf8
        )
        XCTAssertTrue(main.contains("fastp -i 'reads 1.fastq' -o trimmed.fastq"), main)
    }

    func testExportCanonicalizesLegacyWorkflowRunSidecar() async throws {
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let sidecarURL = directory.appendingPathComponent(ProvenanceRecorder.provenanceFilename)
        let outputDirectory = directory.appendingPathComponent("legacy-export", isDirectory: true)
        let legacy = WorkflowRun(
            name: "Legacy Export",
            startTime: Date(timeIntervalSince1970: 100),
            endTime: Date(timeIntervalSince1970: 104),
            status: .completed,
            appVersion: "Lungfish legacy",
            hostOS: "macOS test",
            runtime: WorkflowRuntime(appVersion: "Lungfish legacy", hostOS: "macOS test", user: "tester"),
            steps: [
                StepExecution(
                    toolName: "legacy-tool",
                    toolVersion: "1.0",
                    command: ["legacy-tool", "--input", "reads 1.fastq", "--output", "result.tsv"],
                    inputs: [FileRecord(path: "reads 1.fastq", sha256: "abc123", sizeBytes: 12, format: .fastq)],
                    outputs: [FileRecord(path: "result.tsv", sha256: "def456", sizeBytes: 34, role: .output)],
                    exitCode: 0,
                    wallTime: 4.0
                )
            ],
            parameters: ["threads": .integer(2)]
        )
        try ProvenanceJSON.encoder.encode(legacy).write(to: sidecarURL, options: .atomic)

        let command = try ProvenanceCommand.ExportSubcommand.parse([
            sidecarURL.path,
            "--format", "json",
            "--output", outputDirectory.path
        ])

        try await command.run()

        let copiedSidecarURL = outputDirectory
            .appendingPathComponent("provenance", isDirectory: true)
            .appendingPathComponent(ProvenanceRecorder.provenanceFilename)
        let canonical = try ProvenanceJSON.decoder.decode(
            ProvenanceEnvelope.self,
            from: try Data(contentsOf: copiedSidecarURL)
        )
        XCTAssertEqual(canonical.schemaVersion, 1)
        XCTAssertEqual(canonical.id, legacy.id)
        XCTAssertEqual(canonical.workflowName, "Legacy Export")
        XCTAssertEqual(canonical.toolName, "legacy-tool")
        XCTAssertEqual(canonical.toolVersion, "1.0")

        let object = try JSONSerialization.jsonObject(with: try Data(contentsOf: copiedSidecarURL)) as? [String: Any]
        XCTAssertNotNil(object?["schemaVersion"])
        XCTAssertNil(object?["name"])
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
