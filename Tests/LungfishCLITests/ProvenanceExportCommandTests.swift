// ProvenanceExportCommandTests.swift - CLI tests for provenance export
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import ArgumentParser
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
            "--export-format", "shell",
            "--output", "/tmp/provenance-export"
        ])

        XCTAssertEqual(command.input, "/tmp/.lungfish-provenance.json")
        XCTAssertEqual(command.exportFormat, "shell")
        XCTAssertEqual(command.output, "/tmp/provenance-export")
    }

    func testProvenanceExportParsesThroughTopLevelCLIWithoutGlobalFormatCollision() throws {
        let command = try LungfishCLI.parseAsRoot([
            "provenance",
            "export",
            "/tmp/.lungfish-provenance.json",
            "--export-format", "shell",
            "--output", "/tmp/provenance-export"
        ])
        let export = try XCTUnwrap(command as? ProvenanceCommand.ExportSubcommand)

        XCTAssertEqual(export.exportFormat, "shell")
        XCTAssertEqual(export.output, "/tmp/provenance-export")
    }

    func testProvenanceExportParsesDocumentedFormatOption() throws {
        let command = try LungfishCLI.parseAsRoot(LungfishCLI.normalizedArgumentsForParsing([
            "provenance",
            "export",
            "/tmp/.lungfish-provenance.json",
            "--format", "shell",
            "--output", "/tmp/provenance-export"
        ]))
        let export = try XCTUnwrap(command as? ProvenanceCommand.ExportSubcommand)

        XCTAssertEqual(export.exportFormat, "shell")
        XCTAssertEqual(export.output, "/tmp/provenance-export")
    }

    func testExportArgvUsesObservedProcessInvocationWhenAvailable() {
        let observed = [
            "/usr/local/bin/lungfish-cli",
            "provenance",
            "export",
            "input.bundle",
            "-f",
            "methods",
            "--output",
            "report"
        ]
        let fallback = [
            "lungfish",
            "provenance",
            "export",
            "input.bundle",
            "--export-format",
            "methods",
            "--output",
            "report"
        ]

        let argv = ProvenanceCommand.ExportSubcommand.exportArgv(
            processArguments: observed,
            fallback: fallback
        )

        XCTAssertEqual(argv, observed)
    }

    func testShellExportWritesRunScriptAndRecordsExportProvenance() async throws {
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
            "--export-format", "shell",
            "--output", outputDirectory.path
        ])

        try await command.run()

        let runScriptURL = outputDirectory.appendingPathComponent("run.sh")
        let exportSidecarURL = outputDirectory
            .appendingPathComponent("provenance", isDirectory: true)
            .appendingPathComponent(ProvenanceRecorder.provenanceFilename)
        XCTAssertTrue(FileManager.default.fileExists(atPath: runScriptURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: exportSidecarURL.path))

        let script = try String(contentsOf: runScriptURL, encoding: .utf8)
        XCTAssertTrue(script.contains("fastp"), script)
        XCTAssertTrue(script.contains("'reads 1.fastq'") || script.contains("\"reads 1.fastq\""), script)
        XCTAssertTrue(script.contains("trimmed.fastq"), script)

        let exportEnvelope = try ProvenanceJSON.decoder.decode(
            ProvenanceEnvelope.self,
            from: try Data(contentsOf: exportSidecarURL)
        )
        XCTAssertEqual(exportEnvelope.schemaVersion, 1)
        XCTAssertEqual(exportEnvelope.workflowName, "provenance.export.shell")
        XCTAssertEqual(exportEnvelope.toolName, "lungfish provenance export")
        XCTAssertEqual(exportEnvelope.argv, [
            "lungfish", "provenance", "export",
            sidecarURL.path,
            "--export-format", "shell",
            "--output", outputDirectory.path
        ])
        XCTAssertTrue(exportEnvelope.files.contains { $0.role == .input && $0.path == sidecarURL.path })
        XCTAssertTrue(exportEnvelope.outputs.contains { $0.path == runScriptURL.path && $0.checksumSHA256 != nil })

        let preservedSourceURL = outputDirectory
            .appendingPathComponent("provenance", isDirectory: true)
            .appendingPathComponent("source", isDirectory: true)
            .appendingPathComponent(sidecarURL.lastPathComponent)
        XCTAssertEqual(try Data(contentsOf: preservedSourceURL), try Data(contentsOf: sidecarURL))
    }

    func testShellExportIncludesEveryStepFromLegacyWorkflowRun() async throws {
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let sidecarURL = directory.appendingPathComponent(ProvenanceRecorder.provenanceFilename)
        let outputDirectory = directory.appendingPathComponent("multi-step-export", isDirectory: true)
        let legacy = WorkflowRun(
            name: "Legacy Multi-Step",
            startTime: Date(timeIntervalSince1970: 100),
            endTime: Date(timeIntervalSince1970: 108),
            status: .completed,
            steps: [
                StepExecution(
                    toolName: "fastp",
                    toolVersion: "0.24.1",
                    command: ["fastp", "-i", "reads.fastq", "-o", "trimmed.fastq"],
                    inputs: [FileRecord(path: "reads.fastq", role: .input)],
                    outputs: [FileRecord(path: "trimmed.fastq", role: .output)],
                    exitCode: 0,
                    wallTime: 3
                ),
                StepExecution(
                    toolName: "minimap2",
                    toolVersion: "2.28",
                    command: ["minimap2", "reference.fasta", "trimmed.fastq", "-o", "aligned.sam"],
                    inputs: [
                        FileRecord(path: "reference.fasta", role: .reference),
                        FileRecord(path: "trimmed.fastq", role: .input)
                    ],
                    outputs: [FileRecord(path: "aligned.sam", role: .output)],
                    exitCode: 0,
                    wallTime: 5
                )
            ]
        )
        try ProvenanceJSON.encoder.encode(legacy).write(to: sidecarURL, options: .atomic)

        let command = try ProvenanceCommand.ExportSubcommand.parse([
            sidecarURL.path,
            "--export-format", "shell",
            "--output", outputDirectory.path
        ])

        try await command.run()

        let script = try String(
            contentsOf: outputDirectory.appendingPathComponent("run.sh"),
            encoding: .utf8
        )
        XCTAssertTrue(script.contains("# Step 1: fastp 0.24.1"), script)
        XCTAssertTrue(script.contains("# Step 2: minimap2 2.28"), script)
        XCTAssertTrue(script.contains("fastp \\"), script)
        XCTAssertTrue(script.contains("trimmed.fastq"), script)
        XCTAssertTrue(script.contains("minimap2 \\"), script)
        XCTAssertTrue(script.contains("aligned.sam"), script)
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
            "--export-format", "nextflow",
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
            "--export-format", "json",
            "--output", outputDirectory.path
        ])

        try await command.run()

        let exportSidecarURL = outputDirectory
            .appendingPathComponent("provenance", isDirectory: true)
            .appendingPathComponent(ProvenanceRecorder.provenanceFilename)
        let exportEnvelope = try ProvenanceJSON.decoder.decode(
            ProvenanceEnvelope.self,
            from: try Data(contentsOf: exportSidecarURL)
        )
        XCTAssertEqual(exportEnvelope.schemaVersion, 1)
        XCTAssertEqual(exportEnvelope.workflowName, "provenance.export.json")
        XCTAssertEqual(exportEnvelope.toolName, "lungfish provenance export")

        let exportedJSONURL = outputDirectory.appendingPathComponent("provenance.json")
        let canonicalSource = try ProvenanceJSON.decoder.decode(
            ProvenanceEnvelope.self,
            from: try Data(contentsOf: exportedJSONURL)
        )
        XCTAssertEqual(canonicalSource.id, legacy.id)
        XCTAssertEqual(canonicalSource.workflowName, "Legacy Export")
        XCTAssertEqual(canonicalSource.toolName, "legacy-tool")
        XCTAssertEqual(canonicalSource.toolVersion, "1.0")

        let preservedSourceURL = outputDirectory
            .appendingPathComponent("provenance", isDirectory: true)
            .appendingPathComponent("source", isDirectory: true)
            .appendingPathComponent(sidecarURL.lastPathComponent)
        XCTAssertEqual(try Data(contentsOf: preservedSourceURL), try Data(contentsOf: sidecarURL))

        let object = try JSONSerialization.jsonObject(with: try Data(contentsOf: exportSidecarURL)) as? [String: Any]
        XCTAssertNotNil(object?["schemaVersion"])
        XCTAssertNil(object?["name"])
    }

    func testExportReadsHistoricalAnalysisFixtureProvenance() async throws {
        let outputDirectory = try makeTempDirectory()
            .appendingPathComponent("fixture-export", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: outputDirectory.deletingLastPathComponent()) }

        let fixtureDirectory = try fixtureURL("analyses/kraken2-2026-01-15T11-00-00")
        let command = try ProvenanceCommand.ExportSubcommand.parse([
            fixtureDirectory.path,
            "--export-format", "json",
            "--output", outputDirectory.path
        ])

        try await command.run()

        let exportedJSONURL = outputDirectory.appendingPathComponent("provenance.json")
        let exportSidecarURL = outputDirectory
            .appendingPathComponent("provenance", isDirectory: true)
            .appendingPathComponent(ProvenanceRecorder.provenanceFilename)
        let preservedSourceURL = outputDirectory
            .appendingPathComponent("provenance/source/.lungfish-provenance.json")

        XCTAssertTrue(FileManager.default.fileExists(atPath: exportedJSONURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: exportSidecarURL.path))
        XCTAssertEqual(
            try Data(contentsOf: preservedSourceURL),
            try Data(contentsOf: fixtureDirectory.appendingPathComponent(ProvenanceRecorder.provenanceFilename))
        )

        let canonicalSource = try ProvenanceJSON.decoder.decode(
            ProvenanceEnvelope.self,
            from: try Data(contentsOf: exportedJSONURL)
        )
        XCTAssertEqual(canonicalSource.workflowName, "analysis-fixture-provenance-historical-backfill")
        XCTAssertEqual(canonicalSource.options.explicit["tool"]?.stringValue, "kraken2")
        XCTAssertEqual(canonicalSource.outputs.first?.role, .output)
    }

    func testExportPreservesSignedSourceProvenanceArtifacts() async throws {
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let outputDirectory = directory.appendingPathComponent("signed-export", isDirectory: true)
        let envelope = ProvenanceEnvelope.fixture(
            workflowName: "signed.source",
            toolName: "fastp",
            argv: ["fastp", "-i", "reads.fastq", "-o", "trimmed.fastq"]
        )
        let sourceSidecarURL = try ProvenanceWriter(
            signingProvider: LocalProvenanceSigningProvider(privateKey: "source-signing-key")
        ).write(envelope, to: directory)

        let command = try ProvenanceCommand.ExportSubcommand.parse([
            directory.path,
            "--export-format", "shell",
            "--output", outputDirectory.path
        ])

        try await command.run()

        let copiedSourceURL = outputDirectory
            .appendingPathComponent("provenance", isDirectory: true)
            .appendingPathComponent("source", isDirectory: true)
            .appendingPathComponent(ProvenanceRecorder.provenanceFilename)
        XCTAssertTrue(FileManager.default.fileExists(atPath: copiedSourceURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: ProvenanceSigningConfiguration.signatureURL(for: copiedSourceURL).path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: ProvenanceSigningConfiguration.publicKeyURL(for: copiedSourceURL).path))

        let verification = try ProvenanceSignatureVerifier.verify(provenanceURL: copiedSourceURL)
        XCTAssertTrue(verification.isValid)
        XCTAssertEqual(try Data(contentsOf: copiedSourceURL), try Data(contentsOf: sourceSidecarURL))
    }

    func testExporterCanSignExportOperationSidecar() throws {
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let sourceSidecarURL = directory.appendingPathComponent(ProvenanceRecorder.provenanceFilename)
        let outputDirectory = directory.appendingPathComponent("signed-report-export", isDirectory: true)
        let envelope = ProvenanceEnvelope.fixture(
            workflowName: "signed.report.source",
            toolName: "fastp",
            argv: ["fastp", "-i", "reads.fastq", "-o", "trimmed.fastq"]
        )
        try ProvenanceJSON.encoder.encode(envelope).write(to: sourceSidecarURL, options: .atomic)

        let bundle = try ProvenanceExporter(
            signingProvider: LocalProvenanceSigningProvider(privateKey: "export-report-key")
        ).exportBundle(
            envelope,
            format: .shell,
            to: outputDirectory,
            sourceSidecarURL: sourceSidecarURL,
            sourceRootURL: directory,
            exportArgv: [
                "lungfish", "provenance", "export",
                directory.path,
                "--export-format", "shell",
                "--output", outputDirectory.path
            ]
        )

        let exportSidecarURL = outputDirectory
            .appendingPathComponent("provenance", isDirectory: true)
            .appendingPathComponent(ProvenanceRecorder.provenanceFilename)
        XCTAssertTrue(bundle.copiedSidecarURLs.contains(exportSidecarURL))

        let verification = try ProvenanceSignatureVerifier.verify(provenanceURL: exportSidecarURL)
        XCTAssertTrue(verification.isValid)
    }

    func testExporterSignsPrimaryReportArtifact() throws {
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let sourceSidecarURL = directory.appendingPathComponent(ProvenanceRecorder.provenanceFilename)
        let outputDirectory = directory.appendingPathComponent("signed-methods-report", isDirectory: true)
        let envelope = ProvenanceEnvelope.fixture(
            workflowName: "signed.methods.source",
            toolName: "fastp",
            argv: ["fastp", "-i", "reads.fastq", "-o", "trimmed.fastq"]
        )
        try ProvenanceJSON.encoder.encode(envelope).write(to: sourceSidecarURL, options: .atomic)

        let bundle = try ProvenanceExporter(
            signingProvider: LocalProvenanceSigningProvider(privateKey: "export-report-key")
        ).exportBundle(
            envelope,
            format: .methods,
            to: outputDirectory,
            sourceSidecarURL: sourceSidecarURL,
            sourceRootURL: directory,
            exportArgv: [
                "lungfish", "provenance", "export",
                directory.path,
                "--export-format", "methods",
                "--output", outputDirectory.path
            ]
        )

        let reportURL = outputDirectory.appendingPathComponent("methods.md")
        XCTAssertEqual(bundle.primaryArtifactURL, reportURL)
        XCTAssertTrue(bundle.signedReportArtifactURLs.contains(ProvenanceSigningConfiguration.signatureURL(for: reportURL)))
        XCTAssertTrue(bundle.signedReportArtifactURLs.contains(ProvenanceSigningConfiguration.publicKeyURL(for: reportURL)))

        let verification = try ProvenanceSignatureVerifier.verify(provenanceURL: reportURL)
        XCTAssertTrue(verification.isValid)
    }

    func testDirectoryExportPreservesAllSourceProvenanceSidecarsAndManifests() async throws {
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let rootSidecarURL = directory.appendingPathComponent(ProvenanceRecorder.provenanceFilename)
        let provenanceDirectory = directory.appendingPathComponent("provenance", isDirectory: true)
        try FileManager.default.createDirectory(at: provenanceDirectory, withIntermediateDirectories: true)
        let bundleSidecarURL = provenanceDirectory.appendingPathComponent("bundle.lungfish-provenance.json")
        let outputSidecarURL = provenanceDirectory.appendingPathComponent("reads.lungfish-provenance.json")
        let manifestURL = directory.appendingPathComponent("manifest.json")
        let hyphenatedManifestURL = directory.appendingPathComponent("analyses-manifest.json")
        let nestedManifestDirectory = directory.appendingPathComponent("nested", isDirectory: true)
        try FileManager.default.createDirectory(at: nestedManifestDirectory, withIntermediateDirectories: true)
        let nestedHyphenatedManifestURL = nestedManifestDirectory.appendingPathComponent("esviritu-batch-manifest.json")
        let outputDirectory = directory.appendingPathComponent("directory-export", isDirectory: true)

        try ProvenanceJSON.encoder.encode(ProvenanceEnvelope.fixture(workflowName: "root"))
            .write(to: rootSidecarURL, options: .atomic)
        try ProvenanceJSON.encoder.encode(ProvenanceEnvelope.fixture(workflowName: "bundle"))
            .write(to: bundleSidecarURL, options: .atomic)
        try ProvenanceJSON.encoder.encode(ProvenanceEnvelope.fixture(workflowName: "reads"))
            .write(to: outputSidecarURL, options: .atomic)
        try Data(#"{"bundle":"manifest"}"#.utf8).write(to: manifestURL, options: .atomic)
        try Data(#"{"analyses":"manifest"}"#.utf8).write(to: hyphenatedManifestURL, options: .atomic)
        try Data(#"{"batch":"manifest"}"#.utf8).write(to: nestedHyphenatedManifestURL, options: .atomic)

        let command = try ProvenanceCommand.ExportSubcommand.parse([
            directory.path,
            "--export-format", "methods",
            "--output", outputDirectory.path
        ])

        try await command.run()

        let copiedRoot = outputDirectory
            .appendingPathComponent("provenance/source/.lungfish-provenance.json")
        let copiedBundle = outputDirectory
            .appendingPathComponent("provenance/source/provenance/bundle.lungfish-provenance.json")
        let copiedOutput = outputDirectory
            .appendingPathComponent("provenance/source/provenance/reads.lungfish-provenance.json")
        let copiedManifest = outputDirectory
            .appendingPathComponent("provenance/source/manifest.json")
        let copiedHyphenatedManifest = outputDirectory
            .appendingPathComponent("provenance/source/analyses-manifest.json")
        let copiedNestedHyphenatedManifest = outputDirectory
            .appendingPathComponent("provenance/source/nested/esviritu-batch-manifest.json")

        XCTAssertTrue(FileManager.default.fileExists(atPath: copiedRoot.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: copiedBundle.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: copiedOutput.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: copiedManifest.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: copiedHyphenatedManifest.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: copiedNestedHyphenatedManifest.path))
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

    private func fixtureURL(_ relativePath: String) throws -> URL {
        var dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        while dir.path != "/" {
            let candidate = dir.appendingPathComponent("Tests/Fixtures/\(relativePath)")
            if FileManager.default.fileExists(atPath: candidate.path) {
                return candidate
            }
            dir.deleteLastPathComponent()
        }
        throw XCTSkip("Missing fixture \(relativePath)")
    }
}
