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

    func testExportResolvesDataFileInputToAdjacentSidecar() async throws {
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let dataURL = directory.appendingPathComponent("reads.fastq")
        try Data("@read\nACGT\n+\n!!!!\n".utf8).write(to: dataURL, options: .atomic)
        let sidecarURL = ProvenanceRecorder.fileSidecarURL(for: dataURL)
        let outputDirectory = directory.appendingPathComponent("export-from-data-file", isDirectory: true)
        let envelope = ProvenanceEnvelope.fixture(
            workflowName: "fastq.filter.length",
            toolName: "seqkit",
            toolVersion: "2.9.0",
            argv: ["seqkit", "seq", dataURL.path],
            inputPath: "source.fastq",
            outputPath: dataURL.path
        )
        try ProvenanceJSON.encoder.encode(envelope).write(to: sidecarURL, options: .atomic)

        let command = try ProvenanceCommand.ExportSubcommand.parse([
            dataURL.path,
            "--export-format", "shell",
            "--output", outputDirectory.path
        ])

        try await command.run()

        let runScriptURL = outputDirectory.appendingPathComponent("run.sh")
        let exportSidecarURL = outputDirectory
            .appendingPathComponent("provenance", isDirectory: true)
            .appendingPathComponent(ProvenanceRecorder.provenanceFilename)
        let copiedSourceURL = outputDirectory
            .appendingPathComponent("provenance", isDirectory: true)
            .appendingPathComponent("source", isDirectory: true)
            .appendingPathComponent(sidecarURL.lastPathComponent)

        XCTAssertTrue(FileManager.default.fileExists(atPath: runScriptURL.path))
        XCTAssertEqual(try Data(contentsOf: copiedSourceURL), try Data(contentsOf: sidecarURL))

        let exportEnvelope = try ProvenanceJSON.decoder.decode(
            ProvenanceEnvelope.self,
            from: try Data(contentsOf: exportSidecarURL)
        )
        XCTAssertEqual(exportEnvelope.argv, [
            "lungfish", "provenance", "export",
            dataURL.path,
            "--export-format", "shell",
            "--output", outputDirectory.path
        ])
    }

    func testExportResolvesMappingProvenanceDirectory() async throws {
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let mappingSidecarURL = try writeMappingProvenance(to: directory)
        let outputDirectory = directory.appendingPathComponent("export-mapping", isDirectory: true)
        let command = try ProvenanceCommand.ExportSubcommand.parse([
            directory.path,
            "--export-format", "shell",
            "--output", outputDirectory.path
        ])

        try await command.run()

        let runScriptURL = outputDirectory.appendingPathComponent("run.sh")
        let copiedMappingSidecarURL = outputDirectory
            .appendingPathComponent("provenance/source/mapping-provenance.json")
        let exportSidecarURL = outputDirectory
            .appendingPathComponent("provenance", isDirectory: true)
            .appendingPathComponent(ProvenanceRecorder.provenanceFilename)

        XCTAssertTrue(FileManager.default.fileExists(atPath: runScriptURL.path))
        XCTAssertEqual(try Data(contentsOf: copiedMappingSidecarURL), try Data(contentsOf: mappingSidecarURL))

        let exportEnvelope = try ProvenanceJSON.decoder.decode(
            ProvenanceEnvelope.self,
            from: try Data(contentsOf: exportSidecarURL)
        )
        XCTAssertEqual(exportEnvelope.argv, [
            "lungfish", "provenance", "export",
            directory.path,
            "--export-format", "shell",
            "--output", outputDirectory.path
        ])
    }

    func testExportResolvesPrimitiveMSABundleSidecarWithKeyedFiles() async throws {
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let bundleURL = directory.appendingPathComponent("Aligned.lungfishmsa", isDirectory: true)
        try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)
        let sidecarURL = bundleURL.appendingPathComponent(ProvenanceRecorder.provenanceFilename)
        try Data("""
        {
          "schemaVersion": 1,
          "createdAt": "2026-05-12T18:41:18Z",
          "workflowName": "multiple-sequence-alignment-mafft",
          "toolName": "lungfish align mafft",
          "toolVersion": "0.4.0-alpha.16",
          "argv": ["lungfish", "align", "mafft", "input.fasta", "--output", "\(bundleURL.path)"],
          "reproducibleCommand": "lungfish align mafft input.fasta --output '\(bundleURL.path)'",
          "runtimeIdentity": {
            "executablePath": "/Applications/Lungfish.app/Contents/MacOS/lungfish-cli",
            "operatingSystemVersion": "macOS test",
            "processIdentifier": 42
          },
          "inputFiles": [
            {
              "path": "/project/input.fasta",
              "checksumSHA256": "\(String(repeating: "a", count: 64))",
              "fileSize": 10
            }
          ],
          "files": {
            "alignment/primary.aligned.fasta": {
              "path": "\(bundleURL.path)/alignment/primary.aligned.fasta",
              "checksumSHA256": "\(String(repeating: "b", count: 64))",
              "fileSize": 30
            }
          },
          "output": {
            "path": "\(bundleURL.path)",
            "checksumSHA256": "\(String(repeating: "c", count: 64))",
            "fileSize": 40
          },
          "externalToolInvocations": [
            {
              "name": "mafft",
              "version": "7.526",
              "argv": ["mafft", "--auto", "input.fasta"],
              "exitStatus": 0,
              "wallTimeSeconds": 1.5
            }
          ],
          "exitStatus": 0,
          "wallTimeSeconds": 2.0
        }
        """.utf8).write(to: sidecarURL, options: .atomic)
        let outputDirectory = directory.appendingPathComponent("msa-json-export", isDirectory: true)

        let command = try ProvenanceCommand.ExportSubcommand.parse([
            bundleURL.path,
            "--export-format", "json",
            "--output", outputDirectory.path
        ])

        try await command.run()

        let exportedJSONURL = outputDirectory.appendingPathComponent("provenance.json")
        let canonicalSource = try ProvenanceJSON.decoder.decode(
            ProvenanceEnvelope.self,
            from: try Data(contentsOf: exportedJSONURL)
        )
        XCTAssertEqual(canonicalSource.workflowName, "multiple-sequence-alignment-mafft")
        XCTAssertEqual(canonicalSource.output?.path, bundleURL.path)
        XCTAssertTrue(canonicalSource.files.contains { $0.path.hasSuffix("alignment/primary.aligned.fasta") })

        let preservedSourceURL = outputDirectory
            .appendingPathComponent("provenance/source/.lungfish-provenance.json")
        XCTAssertEqual(try Data(contentsOf: preservedSourceURL), try Data(contentsOf: sidecarURL))
    }

    func testExportResolvesPrimitiveTreeBundleSidecarWithoutCreatedAt() async throws {
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let bundleURL = directory.appendingPathComponent("Tree.lungfishtree", isDirectory: true)
        try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)
        let sidecarURL = bundleURL.appendingPathComponent(ProvenanceRecorder.provenanceFilename)
        try Data("""
        {
          "schemaVersion": 1,
          "workflowName": "phylogenetic-tree-infer-iqtree",
          "toolName": "lungfish tree infer iqtree",
          "toolVersion": "0.4.0-alpha.16",
          "argv": ["lungfish", "tree", "infer", "iqtree", "Aligned.lungfishmsa", "--output", "\(bundleURL.path)"],
          "command": "lungfish tree infer iqtree Aligned.lungfishmsa --output '\(bundleURL.path)'",
          "runtimeIdentity": {
            "executablePath": "/Applications/Lungfish.app/Contents/MacOS/lungfish-cli",
            "operatingSystemVersion": "macOS test"
          },
          "input": {
            "path": "/project/Aligned.lungfishmsa",
            "sha256": "\(String(repeating: "d", count: 64))",
            "fileSizeBytes": 100
          },
          "output": {
            "path": "\(bundleURL.path)",
            "sha256": "\(String(repeating: "e", count: 64))",
            "fileSizeBytes": 200
          },
          "checksums": {
            "tree/primary.nwk": "\(String(repeating: "f", count: 64))"
          },
          "fileSizes": {
            "tree/primary.nwk": 34
          },
          "externalTool": {
            "toolName": "iqtree2",
            "toolVersion": "2.3.6",
            "argv": ["iqtree2", "-s", "input.aligned.fasta"],
            "exitStatus": 0,
            "wallTimeSeconds": 3.0
          },
          "exitStatus": 0,
          "wallTimeSeconds": 4.0
        }
        """.utf8).write(to: sidecarURL, options: .atomic)
        let outputDirectory = directory.appendingPathComponent("tree-methods-export", isDirectory: true)

        let command = try ProvenanceCommand.ExportSubcommand.parse([
            bundleURL.path,
            "--export-format", "methods",
            "--output", outputDirectory.path
        ])

        try await command.run()

        let methods = try String(
            contentsOf: outputDirectory.appendingPathComponent("methods.md"),
            encoding: .utf8
        )
        XCTAssertTrue(methods.contains("iqtree2"), methods)
        XCTAssertTrue(methods.contains("Aligned.lungfishmsa"), methods)
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: outputDirectory
                    .appendingPathComponent("provenance/source/.lungfish-provenance.json")
                    .path
            )
        )
    }

    func testExportResolvesAssemblyProvenanceStoredUnderAssemblyDirectory() async throws {
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let bundleURL = directory.appendingPathComponent("Assembly.lungfishref", isDirectory: true)
        let assemblyURL = bundleURL.appendingPathComponent("assembly", isDirectory: true)
        try FileManager.default.createDirectory(at: assemblyURL, withIntermediateDirectories: true)
        let sidecarURL = assemblyURL.appendingPathComponent("provenance.json")
        try Data("""
        {
          "assembler": "SPAdes",
          "assembler_version": "4.0.0",
          "execution_backend": "micromamba",
          "managed_environment": "spades",
          "host_os": "macOS test",
          "host_architecture": "arm64",
          "lungfish_version": "Lungfish test",
          "assembly_date": "2026-05-12T18:41:18Z",
          "wall_time_seconds": 12.5,
          "command_line": "spades.py -1 reads_1.fastq -2 reads_2.fastq -o assembly",
          "parameters": {
            "mode": "isolate",
            "threads": 8,
            "skip_error_correction": false,
            "advanced_arguments": []
          },
          "inputs": [
            {
              "filename": "reads_1.fastq",
              "original_path": "/project/reads_1.fastq",
              "sha256": "\(String(repeating: "a", count: 64))",
              "size_bytes": 100
            }
          ]
        }
        """.utf8).write(to: sidecarURL, options: .atomic)
        let outputDirectory = directory.appendingPathComponent("assembly-shell-export", isDirectory: true)

        let command = try ProvenanceCommand.ExportSubcommand.parse([
            bundleURL.path,
            "--export-format", "shell",
            "--output", outputDirectory.path
        ])

        try await command.run()

        let script = try String(
            contentsOf: outputDirectory.appendingPathComponent("run.sh"),
            encoding: .utf8
        )
        XCTAssertTrue(script.contains("spades.py"), script)
        let copiedSidecarURL = outputDirectory
            .appendingPathComponent("provenance/source/assembly/provenance.json")
        XCTAssertEqual(try Data(contentsOf: copiedSidecarURL), try Data(contentsOf: sidecarURL))
    }

    func testExportResolvesVariantSiblingSidecarForVariantArtifactsAndBundleRoot() async throws {
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let bundleURL = directory.appendingPathComponent("Reference.lungfishref", isDirectory: true)
        let variantsURL = bundleURL.appendingPathComponent("variants", isDirectory: true)
        try FileManager.default.createDirectory(at: variantsURL, withIntermediateDirectories: true)
        let vcfURL = variantsURL.appendingPathComponent("covid.vcf.gz")
        let indexURL = variantsURL.appendingPathComponent("covid.vcf.gz.tbi")
        let databaseURL = variantsURL.appendingPathComponent("covid.db")
        try Data("##fileformat=VCFv4.2\n".utf8).write(to: vcfURL, options: .atomic)
        try Data("tabix-index".utf8).write(to: indexURL, options: .atomic)
        try Data("sqlite".utf8).write(to: databaseURL, options: .atomic)
        try ProvenanceJSON.encoder.encode(
            ProvenanceEnvelope.fixture(
                workflowName: "reference-bundle-import",
                outputPath: bundleURL.path
            )
        ).write(to: bundleURL.appendingPathComponent(ProvenanceRecorder.provenanceFilename), options: .atomic)

        let sidecarURL = variantsURL.appendingPathComponent("covid.lungfish-provenance.json")
        let run = WorkflowRun(
            name: "GATK HaplotypeCaller bundle attachment",
            startTime: Date(timeIntervalSince1970: 100),
            endTime: Date(timeIntervalSince1970: 104),
            status: .completed,
            steps: [
                StepExecution(
                    toolName: "lungfish gatk bundle attach",
                    toolVersion: "Lungfish test",
                    command: [
                        "lungfish-app",
                        "gatk-attach",
                        "--bundle", bundleURL.path,
                        "--vcf", vcfURL.path
                    ],
                    inputs: [
                        FileRecord(path: "/project/source.bam", role: .input)
                    ],
                    outputs: [
                        ProvenanceRecorder.fileRecord(url: vcfURL, format: .vcf, role: .output),
                        ProvenanceRecorder.fileRecord(url: indexURL, role: .index),
                        ProvenanceRecorder.fileRecord(url: databaseURL, format: .unknown, role: .output),
                    ],
                    exitCode: 0,
                    wallTime: 4
                )
            ]
        )
        try ProvenanceJSON.encoder.encode(run).write(to: sidecarURL, options: .atomic)

        for selectedURL in [vcfURL, indexURL, databaseURL, bundleURL] {
            let outputDirectory = directory.appendingPathComponent(
                "\(selectedURL.lastPathComponent)-variant-json-export",
                isDirectory: true
            )
            let command = try ProvenanceCommand.ExportSubcommand.parse([
                selectedURL.path,
                "--export-format", "json",
                "--output", outputDirectory.path
            ])

            try await command.run()

            let exportedJSONURL = outputDirectory.appendingPathComponent("provenance.json")
            let canonicalSource = try ProvenanceJSON.decoder.decode(
                ProvenanceEnvelope.self,
                from: try Data(contentsOf: exportedJSONURL)
            )
            XCTAssertEqual(canonicalSource.workflowName, "GATK HaplotypeCaller bundle attachment")
            XCTAssertTrue(canonicalSource.outputs.contains { $0.path == vcfURL.path })
            XCTAssertTrue(canonicalSource.outputs.contains { $0.path == databaseURL.path })
        }
    }

    func testPythonExportWritesScriptAndRecordsExportProvenance() async throws {
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let sidecarURL = directory.appendingPathComponent(ProvenanceRecorder.provenanceFilename)
        let outputDirectory = directory.appendingPathComponent("python-export", isDirectory: true)
        let envelope = ProvenanceEnvelope.fixture(
            workflowName: "fastq.trim.fastp",
            toolName: "fastp",
            toolVersion: "0.24.1",
            argv: ["fastp", "-i", "reads.fastq", "-o", "trimmed.fastq"],
            inputPath: "reads.fastq",
            outputPath: "trimmed.fastq"
        )
        try ProvenanceJSON.encoder.encode(envelope).write(to: sidecarURL, options: .atomic)

        let command = try ProvenanceCommand.ExportSubcommand.parse([
            sidecarURL.path,
            "--export-format", "python",
            "--output", outputDirectory.path
        ])

        try await command.run()

        let scriptURL = outputDirectory.appendingPathComponent("reproduce.py")
        let exportSidecarURL = outputDirectory
            .appendingPathComponent("provenance", isDirectory: true)
            .appendingPathComponent(ProvenanceRecorder.provenanceFilename)
        XCTAssertTrue(FileManager.default.fileExists(atPath: scriptURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: exportSidecarURL.path))

        let script = try String(contentsOf: scriptURL, encoding: .utf8)
        XCTAssertTrue(script.contains("#!/usr/bin/env python3"), script)
        XCTAssertTrue(script.contains("subprocess.run"), script)
        XCTAssertTrue(script.contains("\"fastp\""), script)

        let exportEnvelope = try ProvenanceJSON.decoder.decode(
            ProvenanceEnvelope.self,
            from: try Data(contentsOf: exportSidecarURL)
        )
        XCTAssertEqual(exportEnvelope.workflowName, "provenance.export.python")
        XCTAssertTrue(exportEnvelope.outputs.contains { $0.path == scriptURL.path && $0.checksumSHA256 != nil })
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

    func testNextflowExportRunsSmokePipelineWhenRuntimeAvailable() async throws {
        let nextflowURL = try requireExecutable(named: "nextflow")
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let sidecarURL = try makeSmokeProvenanceSidecar(in: directory, outputPath: "out.txt")
        let outputDirectory = directory.appendingPathComponent("nextflow-smoke", isDirectory: true)
        let command = try ProvenanceCommand.ExportSubcommand.parse([
            sidecarURL.path,
            "--export-format", "nextflow",
            "--output", outputDirectory.path
        ])

        try await command.run()

        let result = try runExternalCommand(
            nextflowURL,
            arguments: [
                "run",
                outputDirectory.appendingPathComponent("main.nf").path
            ],
            workingDirectory: outputDirectory
        )

        XCTAssertEqual(result.exitStatus, 0, result.diagnostics)
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: outputDirectory.appendingPathComponent("results/out.txt").path),
            result.diagnostics
        )
    }

    func testSnakemakeExportRunsSmokeWorkflowWhenRuntimeAvailable() async throws {
        let snakemakeURL = try requireExecutable(named: "snakemake")
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let sidecarURL = try makeSmokeProvenanceSidecar(in: directory, outputPath: "out.txt")
        let outputDirectory = directory.appendingPathComponent("snakemake-smoke", isDirectory: true)
        let command = try ProvenanceCommand.ExportSubcommand.parse([
            sidecarURL.path,
            "--export-format", "snakemake",
            "--output", outputDirectory.path
        ])

        try await command.run()

        let result = try runExternalCommand(
            snakemakeURL,
            arguments: [
                "--cores", "1",
                "--latency-wait", "1",
                "--snakefile", outputDirectory.appendingPathComponent("Snakefile").path,
                "--directory", outputDirectory.path
            ],
            workingDirectory: outputDirectory
        )

        XCTAssertEqual(result.exitStatus, 0, result.diagnostics)
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: outputDirectory.appendingPathComponent("out.txt").path),
            result.diagnostics
        )
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
        XCTAssertEqual(object?["name"] as? String, "provenance.export.json")
        XCTAssertEqual(object?["status"] as? String, "completed")
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

    func testExporterSignsWorkflowSecondaryArtifacts() throws {
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let sourceSidecarURL = directory.appendingPathComponent(ProvenanceRecorder.provenanceFilename)
        let envelope = ProvenanceEnvelope.fixture(
            workflowName: "signed.workflow.source",
            toolName: "minimap2",
            argv: ["minimap2", "reference.fasta", "reads.fastq"]
        )
        try ProvenanceJSON.encoder.encode(envelope).write(to: sourceSidecarURL, options: .atomic)

        let exporter = ProvenanceExporter(
            signingProvider: LocalProvenanceSigningProvider(privateKey: "workflow-report-key")
        )
        let nextflowOutputDirectory = directory.appendingPathComponent("signed-nextflow", isDirectory: true)
        let nextflowBundle = try exporter.exportBundle(
            envelope,
            format: .nextflow,
            to: nextflowOutputDirectory,
            sourceSidecarURL: sourceSidecarURL,
            sourceRootURL: directory
        )
        let nextflowConfigURL = nextflowOutputDirectory.appendingPathComponent("nextflow.config")
        let containerManifestURL = nextflowOutputDirectory.appendingPathComponent("containers/manifest.json")

        XCTAssertTrue(nextflowBundle.signedReportArtifactURLs.contains(ProvenanceSigningConfiguration.signatureURL(for: nextflowConfigURL)))
        XCTAssertTrue(nextflowBundle.signedReportArtifactURLs.contains(ProvenanceSigningConfiguration.publicKeyURL(for: nextflowConfigURL)))
        XCTAssertTrue(nextflowBundle.signedReportArtifactURLs.contains(ProvenanceSigningConfiguration.signatureURL(for: containerManifestURL)))
        XCTAssertTrue(nextflowBundle.signedReportArtifactURLs.contains(ProvenanceSigningConfiguration.publicKeyURL(for: containerManifestURL)))
        XCTAssertTrue(try ProvenanceSignatureVerifier.verify(provenanceURL: nextflowConfigURL).isValid)
        XCTAssertTrue(try ProvenanceSignatureVerifier.verify(provenanceURL: containerManifestURL).isValid)

        let snakemakeOutputDirectory = directory.appendingPathComponent("signed-snakemake", isDirectory: true)
        let snakemakeBundle = try exporter.exportBundle(
            envelope,
            format: .snakemake,
            to: snakemakeOutputDirectory,
            sourceSidecarURL: sourceSidecarURL,
            sourceRootURL: directory
        )
        let snakemakeConfigURL = snakemakeOutputDirectory.appendingPathComponent("config.yaml")

        XCTAssertTrue(snakemakeBundle.signedReportArtifactURLs.contains(ProvenanceSigningConfiguration.signatureURL(for: snakemakeConfigURL)))
        XCTAssertTrue(snakemakeBundle.signedReportArtifactURLs.contains(ProvenanceSigningConfiguration.publicKeyURL(for: snakemakeConfigURL)))
        XCTAssertTrue(try ProvenanceSignatureVerifier.verify(provenanceURL: snakemakeConfigURL).isValid)
    }

    func testDirectoryExportPreservesAllSourceProvenanceSidecarsAndManifests() async throws {
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let rootSidecarURL = directory.appendingPathComponent(ProvenanceRecorder.provenanceFilename)
        let provenanceDirectory = directory.appendingPathComponent("provenance", isDirectory: true)
        try FileManager.default.createDirectory(at: provenanceDirectory, withIntermediateDirectories: true)
        let bundleSidecarURL = provenanceDirectory.appendingPathComponent("bundle.lungfish-provenance.json")
        let outputSidecarURL = provenanceDirectory.appendingPathComponent("reads.lungfish-provenance.json")
        let annotationEditURL = directory
            .appendingPathComponent("metadata", isDirectory: true)
            .appendingPathComponent("annotation-edit-provenance.json")
        let annotationsDirectory = directory.appendingPathComponent("annotations", isDirectory: true)
        let manualAnnotationURL = annotationsDirectory.appendingPathComponent("manual-annotation-provenance.json")
        let annotationImportURL = annotationsDirectory.appendingPathComponent("genes-import-provenance.json")
        let alignmentDirectory = directory.appendingPathComponent("alignments/mapped", isDirectory: true)
        let primerTrimURL = alignmentDirectory.appendingPathComponent("sample.primer-trim-provenance.json")
        let adoptMappingURL = alignmentDirectory.appendingPathComponent("sample.adopt-mapping-provenance.json")
        let extractionMetadataURL = directory.appendingPathComponent("extraction-metadata.json")
        let manifestURL = directory.appendingPathComponent("manifest.json")
        let hyphenatedManifestURL = directory.appendingPathComponent("analyses-manifest.json")
        let nestedManifestDirectory = directory.appendingPathComponent("nested", isDirectory: true)
        try FileManager.default.createDirectory(at: nestedManifestDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: annotationEditURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(at: annotationsDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: alignmentDirectory, withIntermediateDirectories: true)
        let nestedHyphenatedManifestURL = nestedManifestDirectory.appendingPathComponent("esviritu-batch-manifest.json")
        let outputDirectory = directory.appendingPathComponent("directory-export", isDirectory: true)

        try ProvenanceJSON.encoder.encode(ProvenanceEnvelope.fixture(workflowName: "root"))
            .write(to: rootSidecarURL, options: .atomic)
        try ProvenanceJSON.encoder.encode(ProvenanceEnvelope.fixture(workflowName: "bundle"))
            .write(to: bundleSidecarURL, options: .atomic)
        try ProvenanceJSON.encoder.encode(ProvenanceEnvelope.fixture(workflowName: "reads"))
            .write(to: outputSidecarURL, options: .atomic)
        try Data(#"{"workflowName":"annotation-edit"}"#.utf8).write(to: annotationEditURL, options: .atomic)
        try Data(#"{"entries":[{"workflowName":"manual annotation","recordedAt":"2026-05-12T12:00:00Z"}]}"#.utf8)
            .write(to: manualAnnotationURL, options: .atomic)
        try Data(#"{"entries":[{"workflowName":"annotation import","recordedAt":"2026-05-12T12:30:00Z"}]}"#.utf8)
            .write(to: annotationImportURL, options: .atomic)
        try Data(#"{"workflowName":"primer trim"}"#.utf8).write(to: primerTrimURL, options: .atomic)
        try Data(#"{"workflowName":"adopt mapping"}"#.utf8).write(to: adoptMappingURL, options: .atomic)
        try Data(#"{"sourceDescription":"reads","toolName":"samtools","extractionDate":"2026-05-11T12:00:00Z"}"#.utf8)
            .write(to: extractionMetadataURL, options: .atomic)
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
        let copiedAnnotationEdit = outputDirectory
            .appendingPathComponent("provenance/source/metadata/annotation-edit-provenance.json")
        let copiedManualAnnotation = outputDirectory
            .appendingPathComponent("provenance/source/annotations/manual-annotation-provenance.json")
        let copiedAnnotationImport = outputDirectory
            .appendingPathComponent("provenance/source/annotations/genes-import-provenance.json")
        let copiedPrimerTrim = outputDirectory
            .appendingPathComponent("provenance/source/alignments/mapped/sample.primer-trim-provenance.json")
        let copiedAdoptMapping = outputDirectory
            .appendingPathComponent("provenance/source/alignments/mapped/sample.adopt-mapping-provenance.json")
        let copiedExtractionMetadata = outputDirectory
            .appendingPathComponent("provenance/source/extraction-metadata.json")
        let copiedManifest = outputDirectory
            .appendingPathComponent("provenance/source/manifest.json")
        let copiedHyphenatedManifest = outputDirectory
            .appendingPathComponent("provenance/source/analyses-manifest.json")
        let copiedNestedHyphenatedManifest = outputDirectory
            .appendingPathComponent("provenance/source/nested/esviritu-batch-manifest.json")

        XCTAssertTrue(FileManager.default.fileExists(atPath: copiedRoot.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: copiedBundle.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: copiedOutput.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: copiedAnnotationEdit.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: copiedManualAnnotation.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: copiedAnnotationImport.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: copiedPrimerTrim.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: copiedAdoptMapping.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: copiedExtractionMetadata.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: copiedManifest.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: copiedHyphenatedManifest.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: copiedNestedHyphenatedManifest.path))
    }

    func testFormatParserAcceptsCliValuesAndRejectsUnsupportedValues() throws {
        XCTAssertEqual(try ProvenanceExportFormat.cliValue("shell"), .shell)
        XCTAssertEqual(try ProvenanceExportFormat.cliValue("python"), .python)
        XCTAssertEqual(try ProvenanceExportFormat.cliValue("nextflow"), .nextflow)
        XCTAssertEqual(try ProvenanceExportFormat.cliValue("snakemake"), .snakemake)
        XCTAssertEqual(try ProvenanceExportFormat.cliValue("methods"), .methods)
        XCTAssertEqual(try ProvenanceExportFormat.cliValue("json"), .json)
        XCTAssertEqual(try ProvenanceExportFormat.cliValue("Shell Script"), .shell)
        XCTAssertEqual(try ProvenanceExportFormat.cliValue("Python Script"), .python)

        XCTAssertThrowsError(try ProvenanceExportFormat.cliValue("rmarkdown")) { error in
            XCTAssertTrue(error.localizedDescription.contains("Unsupported provenance export format"), error.localizedDescription)
        }
    }

    private func makeTempDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("lungfish-provenance-export-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func writeMappingProvenance(to directory: URL) throws -> URL {
        let inputFASTQ = directory.appendingPathComponent("reads.fastq")
        let referenceFASTA = directory.appendingPathComponent("reference.fa")
        let bamURL = directory.appendingPathComponent("sample.sorted.bam")
        let baiURL = directory.appendingPathComponent("sample.sorted.bam.bai")
        try Data("@read\nACGT\n+\n!!!!\n".utf8).write(to: inputFASTQ, options: .atomic)
        try Data(">chr1\nACGT\n".utf8).write(to: referenceFASTA, options: .atomic)
        try Data("bam".utf8).write(to: bamURL, options: .atomic)
        try Data("bai".utf8).write(to: baiURL, options: .atomic)

        let request = MappingRunRequest(
            tool: .minimap2,
            modeID: MappingMode.defaultShortRead.id,
            inputFASTQURLs: [inputFASTQ],
            referenceFASTAURL: referenceFASTA,
            outputDirectory: directory,
            sampleName: "sample",
            pairedEnd: false,
            threads: 4
        )
        let result = MappingResult(
            mapper: .minimap2,
            modeID: request.modeID,
            bamURL: bamURL,
            baiURL: baiURL,
            totalReads: 10,
            mappedReads: 9,
            unmappedReads: 1,
            wallClockSeconds: 1,
            contigs: []
        )
        let mapperInvocation = try MappingProvenance.mapperInvocation(for: request)
        let provenance = MappingProvenance.build(
            request: request,
            result: result,
            mapperInvocation: mapperInvocation,
            normalizationInvocations: MappingProvenance.normalizationInvocations(
                rawAlignmentURL: directory.appendingPathComponent("sample.raw.sam"),
                outputDirectory: directory,
                sampleName: "sample",
                threads: 4,
                minimumMappingQuality: 0,
                includeSecondary: true,
                includeSupplementary: true
            ),
            mapperVersion: "2.28",
            samtoolsVersion: "1.21",
            outputFiles: [
                ProvenanceRecorder.fileRecord(url: bamURL, format: .bam, role: .output),
                ProvenanceRecorder.fileRecord(url: baiURL, role: .index)
            ],
            exitStatus: 0
        )
        try provenance.save(to: directory)
        return directory.appendingPathComponent(MappingProvenance.filename)
    }

    private func makeSmokeProvenanceSidecar(in directory: URL, outputPath: String) throws -> URL {
        let run = WorkflowRun(
            name: "Smoke Export",
            startTime: Date(timeIntervalSince1970: 100),
            endTime: Date(timeIntervalSince1970: 101),
            status: .completed,
            appVersion: "Lungfish smoke",
            hostOS: "macOS smoke",
            runtime: WorkflowRuntime(appVersion: "Lungfish smoke", hostOS: "macOS smoke", user: "tester"),
            steps: [
                StepExecution(
                    toolName: "sh",
                    toolVersion: "system",
                    command: ["/bin/sh", "-c", "printf ok > \(outputPath)"],
                    inputs: [],
                    outputs: [FileRecord(path: outputPath, role: .output)],
                    exitCode: 0,
                    wallTime: 1.0
                )
            ]
        )
        let sidecarURL = directory.appendingPathComponent(ProvenanceRecorder.provenanceFilename)
        try ProvenanceJSON.encoder.encode(run.canonicalEnvelope()).write(to: sidecarURL, options: .atomic)
        return sidecarURL
    }

    private func requireExecutable(named name: String) throws -> URL {
        if let path = ProcessInfo.processInfo.environment["PATH"] {
            for directory in path.split(separator: ":") {
                let candidate = URL(fileURLWithPath: String(directory)).appendingPathComponent(name)
                if FileManager.default.isExecutableFile(atPath: candidate.path) {
                    return candidate
                }
            }
        }
        throw XCTSkip("\(name) is not available in this test environment")
    }

    private struct ExternalCommandResult {
        let exitStatus: Int32
        let stdout: String
        let stderr: String

        var diagnostics: String {
            """
            exitStatus: \(exitStatus)
            stdout:
            \(stdout)
            stderr:
            \(stderr)
            """
        }
    }

    private func runExternalCommand(
        _ executableURL: URL,
        arguments: [String],
        workingDirectory: URL
    ) throws -> ExternalCommandResult {
        let process = Process()
        process.executableURL = executableURL
        process.arguments = arguments
        process.currentDirectoryURL = workingDirectory

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        let semaphore = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in semaphore.signal() }
        try process.run()
        let timeout = DispatchTime.now() + .seconds(90)
        if semaphore.wait(timeout: timeout) == .timedOut {
            process.terminate()
            process.waitUntilExit()
        }

        let stdoutData = stdout.fileHandleForReading.readDataToEndOfFile()
        let stderrData = stderr.fileHandleForReading.readDataToEndOfFile()
        return ExternalCommandResult(
            exitStatus: process.terminationStatus,
            stdout: String(data: stdoutData, encoding: .utf8) ?? "",
            stderr: String(data: stderrData, encoding: .utf8) ?? ""
        )
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
