// ProvenanceStepParentWriterTests.swift - The writers record the step each sub-step ran under
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.6 lane P8, plan decision S6. The FASTQ importer and the native bundle builder record the
// tools an import ran as steps beside the import's own step, and each now names that step as its
// parent. The tests run the real writers and read the canonical record each publishes at the bundle
// root. The rollup and the per-file sidecars under `provenance/` are narrowed copies of it, and
// whether they keep the field is a matter for the site that narrows them.

import XCTest
import LungfishCore
import LungfishIO
@testable import LungfishWorkflow

final class ProvenanceStepParentWriterTests: XCTestCase {

    // MARK: - The writers record the parent in the canonical record

    /// The steps of the record the writer publishes at the bundle root, which every reader and
    /// the export read first. The per-file sidecars and the rollup under `provenance/` are
    /// narrowed copies of it.
    private func canonicalSteps(of bundleURL: URL) throws -> [ProvenanceStep] {
        try XCTUnwrap(ProvenanceEnvelopeReader.load(from: bundleURL)).steps
    }

    func testTheFASTQImporterRecordsEveryOtherStepUnderTheImportStep() async throws {
        let root = try makeStepParentDirectory()
        let source = root.appendingPathComponent("source", isDirectory: true)
        let projectURL = root.appendingPathComponent("Project.lungfish", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: projectURL, withIntermediateDirectories: true)
        let r1 = source.appendingPathComponent("Sample_R1.fastq.gz")
        let r2 = source.appendingPathComponent("Sample_R2.fastq.gz")
        try "@read1/1\nACGT\n+\nIIII\n".write(to: r1, atomically: true, encoding: .utf8)
        try "@read1/2\nTGCA\n+\nIIII\n".write(to: r2, atomically: true, encoding: .utf8)
        let config = FASTQBatchImporter.ImportConfig(
            projectDirectory: projectURL, platform: .illumina, recipe: nil,
            qualityBinning: QualityBinningScheme.none, optimizeStorage: false, threads: 1
        )
        let result = await FASTQBatchImporter.runBatchImport(
            pairs: [SamplePair(sampleName: "Sample", r1: r1, r2: r2)], config: config, log: nil
        )
        XCTAssertEqual(result.completed, 1, "Import should succeed. Errors: \(result.errors)")

        let bundle = projectURL.appendingPathComponent("Imports/Sample.lungfishfastq", isDirectory: true)
        let steps = try canonicalSteps(of: bundle)
        let importStep = try XCTUnwrap(steps.first { $0.toolName == "lungfish import fastq" })
        XCTAssertNil(importStep.parentStepID, "the import step ran on its own")
        let others = steps.filter { $0.id != importStep.id }
        XCTAssertFalse(others.isEmpty, "the record holds the steps the import ran")
        XCTAssertEqual(others.map(\.parentStepID), others.map { _ -> UUID? in importStep.id }, "\(others.map(\.toolName))")
    }

    func testTheNativeBundleBuilderRecordsEachToolStepUnderTheImportStepOfACLICommand() async throws {
        let root = try makeStepParentDirectory()
        let fasta = root.appendingPathComponent("source.fa")
        try ">chr1\nACGT\n>chr2\nTGCA\n".write(to: fasta, atomically: true, encoding: .utf8)
        let home = root.appendingPathComponent("home", isDirectory: true)
        try writeFakeManagedTool(home: home, environment: "samtools", executable: "samtools", script: """
        #!/bin/sh
        if [ "$1" = "--version" ]; then echo "samtools 1.23"; exit 0; fi
        if [ "$1" = "faidx" ]; then printf "chr1\\t4\\t6\\t4\\t5\\nchr2\\t4\\t17\\t4\\t5\\n" > "$2.fai"; exit 0; fi
        exit 2
        """)
        let builder = NativeBundleBuilder(
            toolRunner: NativeToolRunner(toolsDirectory: nil, homeDirectory: home, appIdentity: .preview)
        )
        let importCommand = ["lungfish-cli", "import", "fasta", fasta.path, "--output-dir", root.path, "--name", "CLI"]
        let withCLI = try await builder.build(configuration: BuildConfiguration(
            name: "CLI", identifier: "org.lungfish.test.parent-cli", fastaURL: fasta, outputDirectory: root,
            source: SourceInfo(organism: "Test", assembly: "Test"), compressFASTA: false,
            provenanceWorkflowName: "lungfish import fasta", provenanceCommand: importCommand
        ))
        let cliSteps = try canonicalSteps(of: withCLI)
        let importStep = try XCTUnwrap(cliSteps.first { $0.toolName == "lungfish import fasta" })
        let tools = cliSteps.filter { $0.id != importStep.id }
        XCTAssertFalse(tools.isEmpty, "the record holds the tool steps the import ran")
        XCTAssertEqual(tools.map(\.parentStepID), tools.map { _ -> UUID? in importStep.id })
        XCTAssertNil(importStep.parentStepID)

        // The shell script of that record runs the import once and names its tools in comments.
        let script = ProvenanceExporter(signingProvider: nil)
            .exportShell(try XCTUnwrap(ProvenanceEnvelopeReader.load(from: withCLI)).legacyWorkflowRun(preferCanonicalSteps: true))
        XCTAssertEqual(StepParentSupport.commandLines(of: script).count, 1, script)
        XCTAssertTrue(script.contains("samtools"), "the skipped tool stays in a comment")

        // Without a CLI command the builder's own name heads the record, no script can run it, and a
        // command that takes the tool steps over (`bundle create`) would find a parent that is gone,
        // so the tool steps record none.
        let withoutCLI = try await builder.build(configuration: BuildConfiguration(
            name: "Plain", identifier: "org.lungfish.test.parent-plain", fastaURL: fasta, outputDirectory: root,
            source: SourceInfo(organism: "Test", assembly: "Test"), compressFASTA: false
        ))
        let plainSteps = try canonicalSteps(of: withoutCLI)
        XCTAssertGreaterThan(plainSteps.count, 1)
        XCTAssertEqual(plainSteps.map(\.parentStepID), plainSteps.map { _ -> UUID? in nil })
    }

    /// The Geneious and application-export imports build a reference bundle with the native builder and
    /// then rehydrate its record, which gives every step the collection's import command. A script of that
    /// record used to run the import once for each step. The later steps now name the first as their parent,
    /// so the nested rule leaves the script one command.
    func testARehydratedBuilderRecordExportsTheCollectionImportOnce() async throws {
        let root = try makeStepParentDirectory()
        let fasta = root.appendingPathComponent("source.fa")
        try ">chr1\nACGT\n>chr2\nTGCA\n".write(to: fasta, atomically: true, encoding: .utf8)
        let home = root.appendingPathComponent("home", isDirectory: true)
        try writeFakeManagedTool(home: home, environment: "samtools", executable: "samtools", script: """
        #!/bin/sh
        if [ "$1" = "--version" ]; then echo "samtools 1.23"; exit 0; fi
        if [ "$1" = "faidx" ]; then printf "chr1\\t4\\t6\\t4\\t5\\nchr2\\t4\\t17\\t4\\t5\\n" > "$2.fai"; exit 0; fi
        exit 2
        """)
        let bundleURL = try await NativeBundleBuilder(
            toolRunner: NativeToolRunner(toolsDirectory: nil, homeDirectory: home, appIdentity: .preview)
        ).build(configuration: BuildConfiguration(
            name: "Collection", identifier: "org.lungfish.test.collection", fastaURL: fasta, outputDirectory: root,
            source: SourceInfo(organism: "Test", assembly: "Test"), compressFASTA: false
        ))
        let durable = root.appendingPathComponent("collection/original.gb")
        try FileManager.default.createDirectory(at: durable.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "LOCUS\n".write(to: durable, atomically: true, encoding: .utf8)
        let replay = ["lungfish-cli", "import", "geneious", durable.path, "--output-dir", root.path]

        try ReferenceBundleImportProvenanceRehydrator.rehydrateSidecar(
            bundleURL: bundleURL,
            durableSourceURL: durable,
            sourceRelativePath: "original.gb",
            context: ReferenceBundleImportProvenanceContext(
                workflowName: "reference.import", replayCommand: replay,
                options: ProvenanceOptions(explicit: ["format": .string("fasta")])
            )
        )

        let record = try XCTUnwrap(ProvenanceEnvelopeReader.load(from: bundleURL))
        XCTAssertGreaterThan(record.steps.count, 1, "the builder ran a tool")
        let first = try XCTUnwrap(record.steps.first)
        XCTAssertEqual(record.steps.map(\.argv).filter { $0 == replay }.count, record.steps.count, "every step carries the collection command")
        XCTAssertNil(first.parentStepID)
        let later = Array(record.steps.dropFirst())
        XCTAssertEqual(later.map(\.parentStepID), later.map { _ -> UUID? in first.id })

        let script = ProvenanceExporter(signingProvider: nil).exportShell(record.legacyWorkflowRun(preferCanonicalSteps: true))
        let commands = StepParentSupport.commandLines(of: script)
        XCTAssertEqual(commands.count, 1, "\(commands)")
        XCTAssertTrue(commands.first?.hasPrefix("lungfish-cli import geneious") == true, "\(commands)")
    }

    private func writeFakeManagedTool(home: URL, environment: String, executable: String, script: String) throws {
        let binDir = home.appendingPathComponent(".lungfish/conda/envs", isDirectory: true)
            .appendingPathComponent(environment, isDirectory: true).appendingPathComponent("bin", isDirectory: true)
        try FileManager.default.createDirectory(at: binDir, withIntermediateDirectories: true)
        let toolURL = binDir.appendingPathComponent(executable)
        try script.write(to: toolURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: toolURL.path)
    }
}
