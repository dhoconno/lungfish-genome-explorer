// PortableProvenanceTests.swift - Provenance written into a project carries no private paths
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import SQLite3
import XCTest
import LungfishTestSupport
@testable import LungfishIO
@testable import LungfishWorkflow

/// Records LGE writes into a project or bundle must not name the account's
/// home, the managed tool root, scratch directories or the project's own
/// absolute location, and must still load, replay and export with real paths.
final class PortableProvenanceTests: XCTestCase {
    private var root: URL!
    private var project: URL!
    private var analysis: URL!
    private var input: URL!
    private var output: URL!

    private var toolRoot: URL { PortablePath.defaultManagedRoots.toolRoot }
    private var samtools: String { toolRoot.appendingPathComponent("envs/samtools/bin/samtools").path }
    private var externalInput: String {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Downloads/external-reads.fastq.gz").path
    }

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("portable-provenance-\(UUID().uuidString)", isDirectory: true)
        project = root.appendingPathComponent("Shared Project (demo).lungfish", isDirectory: true)
        analysis = project.appendingPathComponent("Analyses/minimap2-1", isDirectory: true)
        try FileManager.default.createDirectory(at: analysis, withIntermediateDirectories: true)
        let imports = project.appendingPathComponent("Imports/reads.lungfishfastq", isDirectory: true)
        try FileManager.default.createDirectory(at: imports, withIntermediateDirectories: true)
        input = imports.appendingPathComponent("reads.fastq.gz")
        try Data("@r\nACGT\n+\nIIII\n".utf8).write(to: input)
        output = analysis.appendingPathComponent("sample.sorted.bam")
        try Data("bam".utf8).write(to: output)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func makeRun() -> WorkflowRun {
        let step = StepExecution(
            toolName: "samtools",
            toolVersion: "1.24",
            command: [samtools, "sort", "-o", output.path, input.path, externalInput],
            inputs: [ProvenanceRecorder.fileRecord(url: input, role: .input)],
            outputs: [ProvenanceRecorder.fileRecord(url: output, format: .bam, role: .output)],
            exitCode: 0,
            wallTime: 1,
            stderr: "[bam_sort] writing to \(root.path)/scratch/sort.tmp.0000.bam",
            endTime: Date()
        )
        return WorkflowRun(name: "portable test", endTime: Date(), status: .completed, steps: [step])
    }

    private func assertNoPrivatePaths(_ text: String, file: StaticString = #filePath, line: UInt = #line) {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        XCTAssertFalse(text.contains(home), "names the home directory", file: file, line: line)
        XCTAssertFalse(text.contains(home.replacingOccurrences(of: "/", with: "\\/")), "names the home directory", file: file, line: line)
        XCTAssertFalse(text.contains(project.path), "names the project's absolute path", file: file, line: line)
        XCTAssertFalse(text.contains(project.path.replacingOccurrences(of: "/", with: "\\/")), "names the project's absolute path", file: file, line: line)
        for temporary in ["/var/folders", "/private/var/folders", "/private/tmp", "\\/var\\/folders", "\\/private\\/tmp"] {
            XCTAssertFalse(text.contains(temporary), "names a temporary directory", file: file, line: line)
        }
        let user = NSUserName()
        if !user.isEmpty {
            XCTAssertFalse(text.contains("\"user\" : \"\(user)\""), "names the account", file: file, line: line)
        }
    }

    // MARK: - Provenance envelopes

    func testEnvelopeInsideProjectIsPortableAndLoadsWithRealPaths() throws {
        let envelope = makeRun().canonicalEnvelope()
        let sidecar = try ProvenanceWriter(signingProvider: nil).write(envelope, to: analysis)

        let text = try String(contentsOf: sidecar, encoding: .utf8)
        assertNoPrivatePaths(text)
        XCTAssertTrue(text.contains("@\\/Imports\\/reads.lungfishfastq\\/reads.fastq.gz"), text)
        XCTAssertTrue(text.contains("<tool-root>\\/envs\\/samtools\\/bin\\/samtools"), text)
        XCTAssertTrue(text.contains("<external>\\/external-reads.fastq.gz"), text)

        let loaded = try XCTUnwrap(ProvenanceEnvelopeReader.load(fromSidecar: sidecar))
        let argv = try XCTUnwrap(loaded.steps.first?.argv)
        XCTAssertEqual(argv[0], samtools)
        XCTAssertEqual(argv[3], output.standardizedFileURL.path)
        XCTAssertEqual(argv[4], input.standardizedFileURL.path)
        XCTAssertEqual(argv[5], "<external>/external-reads.fastq.gz")
        XCTAssertEqual(loaded.steps.first?.inputs.first?.path, input.standardizedFileURL.path)
    }

    func testMovedProjectResolvesToItsNewLocation() throws {
        _ = try ProvenanceWriter(signingProvider: nil).write(makeRun().canonicalEnvelope(), to: analysis)
        let moved = root.appendingPathComponent("Elsewhere/Copied.lungfish", isDirectory: true)
        try FileManager.default.createDirectory(at: moved.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: project, to: moved)

        let sidecar = moved.appendingPathComponent("Analyses/minimap2-1/.lungfish-provenance.json")
        let loaded = try XCTUnwrap(ProvenanceEnvelopeReader.load(fromSidecar: sidecar))
        XCTAssertEqual(
            loaded.steps.first?.argv[4],
            moved.standardizedFileURL.appendingPathComponent("Imports/reads.lungfishfastq/reads.fastq.gz").path
        )
    }

    func testLegacySidecarWithAbsolutePathsStillLoads() throws {
        // Written outside any project (kept verbatim), then moved in.
        let staging = root.appendingPathComponent("staging", isDirectory: true)
        let sidecar = try ProvenanceWriter(signingProvider: nil).write(makeRun().canonicalEnvelope(), to: staging)
        XCTAssertTrue(try String(contentsOf: sidecar, encoding: .utf8).contains(input.path.replacingOccurrences(of: "/", with: "\\/")))
        let legacy = analysis.appendingPathComponent("legacy.lungfish-provenance.json")
        try FileManager.default.copyItem(at: sidecar, to: legacy)

        let loaded = try XCTUnwrap(ProvenanceEnvelopeReader.load(fromSidecar: legacy))
        XCTAssertEqual(loaded.steps.first?.argv[4], input.path)
    }

    func testWorkflowRunSidecarInsideBundleIsPortable() throws {
        let bundle = project.appendingPathComponent("Reference Sequences/ref.lungfishref", isDirectory: true)
        try FileManager.default.createDirectory(at: bundle.appendingPathComponent("variants"), withIntermediateDirectories: true)
        let sidecar = bundle.appendingPathComponent("variants/vc-1.lungfish-provenance.json")
        try makeRun().writeSidecar(to: sidecar)
        assertNoPrivatePaths(try String(contentsOf: sidecar, encoding: .utf8))
        let loaded = try XCTUnwrap(ProvenanceEnvelopeReader.load(fromSidecar: sidecar))
        XCTAssertEqual(loaded.steps.first?.argv[4], input.standardizedFileURL.path)
        XCTAssertNil(loaded.runtimeIdentity.user)
    }

    // MARK: - Export

    func testShellExportResolvesProjectPathsAndFlagsExternalOnes() throws {
        let sidecar = try ProvenanceWriter(signingProvider: nil).write(makeRun().canonicalEnvelope(), to: analysis)
        let envelope = try XCTUnwrap(ProvenanceEnvelopeReader.load(fromSidecar: sidecar))
        let exportDirectory = root.appendingPathComponent("export", isDirectory: true)
        let bundle = try ProvenanceExporter(signingProvider: nil).exportBundle(
            envelope,
            format: .shell,
            to: exportDirectory,
            sourceSidecarURL: sidecar
        )
        let script = try String(contentsOf: bundle.primaryArtifactURL, encoding: .utf8)
        XCTAssertTrue(script.contains("$PROJECT/Imports/reads.lungfishfastq/reads.fastq.gz"), script)
        XCTAssertTrue(script.contains("\nsamtools sort "), script)
        XCTAssertFalse(script.contains(samtools), script)
        XCTAssertFalse(script.contains(project.path), script)
        XCTAssertFalse(script.contains("@/Imports"), script)
        XCTAssertTrue(script.contains("<external>/external-reads.fastq.gz"), script)
        XCTAssertTrue(script.contains("Replace each <external>"), script)
    }

    // MARK: - Run Again history

    func testRunBundleHistoryInsideProjectIsPortableAndReplaysAfterMove() throws {
        let package = root.appendingPathComponent("Library/Fixture.lungfishflowpkg", isDirectory: true)
        try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
        let workflow = package.appendingPathComponent("main.nf")
        try "// never executed".write(to: workflow, atomically: true, encoding: .utf8)
        let manifest = WorkflowPackageManifest(
            id: "invented-portable", name: "Fixture", version: "1", category: "Local Test",
            runner: WorkflowPackageRunner(kind: .nextflow, entrypoint: "main.nf"),
            inputs: [WorkflowPackageInput(id: "source", name: "Source", bundleTypes: [.lungfishref])],
            outputs: [WorkflowPackageOutput(id: "result", name: "Result", bundleType: .lungfishref, pathTemplate: "result.txt")]
        )
        try JSONEncoder().encode(manifest).write(to: package.appendingPathComponent("manifest.json"))
        let results = project.appendingPathComponent("Workflow Results/run-1", isDirectory: true)
        try FileManager.default.createDirectory(at: results, withIntermediateDirectories: true)
        let request = LocalWorkflowRunRequest(
            workflowURL: workflow, engine: .nextflow, inputURLs: [input], outputDirectory: results,
            expectedOutputURLs: [results.appendingPathComponent("result.txt")],
            params: ["label": "literal", "outdir": results.path], cpus: 2
        )
        let identity = try LocalWorkflowReplayIdentity.capture(for: request)
        let history = request.manifest(replayIdentity: identity, executionStatus: .completed, exitCode: 0)
        let runBundle = project.appendingPathComponent("Workflow Runs/run-1.lungfishrun", isDirectory: true)
        try LocalWorkflowRunBundleStore.write(history, to: runBundle)
        let step = StepExecution(
            toolName: "lungfish-cli workflow run", toolVersion: "test",
            command: ["lungfish-cli"] + request.cliArguments(bundlePath: runBundle), inputs: [],
            outputs: [ProvenanceRecorder.fileRecord(url: runBundle.appendingPathComponent("manifest.json"), role: .output)],
            exitCode: 0, wallTime: 1, endTime: Date()
        )
        let run = WorkflowRun(name: "Invented local attempt", endTime: Date(), status: .completed, steps: [step])
        try ProvenanceWriter(signingProvider: nil).write(run.canonicalEnvelope(), to: runBundle)

        let manifestText = try String(contentsOf: runBundle.appendingPathComponent("manifest.json"), encoding: .utf8)
        assertNoPrivatePaths(manifestText)

        // Same location: the reopened configuration is the original one.
        let loaded = try LocalWorkflowReplayPreflight.load(from: runBundle)
        XCTAssertEqual(loaded.request.inputURLs.map(\.standardizedFileURL.path), [input.standardizedFileURL.path])
        XCTAssertEqual(loaded.request.workflowURL.standardizedFileURL.path, workflow.standardizedFileURL.path)

        // A moved project reopens with its inputs at the new location.
        let moved = root.appendingPathComponent("Moved/Portable.lungfish", isDirectory: true)
        try FileManager.default.createDirectory(at: moved.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: project, to: moved)
        let movedBundle = moved.appendingPathComponent("Workflow Runs/run-1.lungfishrun", isDirectory: true)
        let reopened = try LocalWorkflowReplayPreflight.load(from: movedBundle)
        XCTAssertEqual(
            reopened.request.inputURLs.first?.standardizedFileURL.path,
            moved.standardizedFileURL.appendingPathComponent("Imports/reads.lungfishfastq/reads.fastq.gz").path
        )
        XCTAssertEqual(
            reopened.request.outputDirectory.standardizedFileURL.path,
            moved.standardizedFileURL.appendingPathComponent("Workflow Results/run-1").path
        )
    }

    // MARK: - Mapping provenance and SQLite

    func testAlignmentStatsDatabaseStoresPortableValues() throws {
        let bundle = project.appendingPathComponent("Analyses/minimap2-1/ref.lungfishref", isDirectory: true)
        try FileManager.default.createDirectory(at: bundle.appendingPathComponent("alignments/mapped"), withIntermediateDirectories: true)
        let database = try AlignmentMetadataDatabase.create(at: bundle.appendingPathComponent("alignments/mapped/aln_1.stats.db"))
        database.setFileInfo("source_path", value: bundle.appendingPathComponent("alignments/mapped/aln_1.bam").path)
        database.addProgramRecord(
            id: "samtools", name: "samtools", version: "1.24",
            commandLine: "\(samtools) sort -o \(output.path) \(root.path)/scratch/filtered.bam"
        )
        database.addProvenanceRecord(
            tool: "lungfish-cli", command: "lungfish-cli bam adopt-mapping --bundle '\(bundle.path)'",
            inputFile: analysis.path, outputFile: bundle.appendingPathComponent("alignments/mapped/aln_1.bam").path
        )

        let stored = try rawValues(in: database.databaseURL, sql: """
            SELECT value FROM file_info UNION ALL SELECT command_line FROM program_records
            UNION ALL SELECT command || ' ' || input_file || ' ' || output_file FROM provenance
            """)
        for value in stored { assertNoPrivatePaths(value) }
        XCTAssertTrue(stored.contains("<tool-root>/envs/samtools/bin/samtools sort -o @/Analyses/minimap2-1/sample.sorted.bam <workspace>/\(root.lastPathComponent)/scratch/filtered.bam"), "\(stored)")

        let reader = try AlignmentMetadataDatabase(url: database.databaseURL)
        XCTAssertEqual(reader.getFileInfo("source_path"), bundle.standardizedFileURL.appendingPathComponent("alignments/mapped/aln_1.bam").path)
        XCTAssertEqual(reader.provenanceHistory().first?.inputFile, analysis.standardizedFileURL.path)
    }

    private func rawValues(in url: URL, sql: String) throws -> [String] {
        var db: OpaquePointer?
        guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            throw XCTSkip("cannot open \(url.path)")
        }
        defer { sqlite3_close(db) }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            XCTFail(String(cString: sqlite3_errmsg(db)))
            return []
        }
        defer { sqlite3_finalize(statement) }
        var values: [String] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            if let text = sqlite3_column_text(statement, 0) {
                values.append(String(cString: text))
            }
        }
        return values
    }

    // MARK: - BAM and VCF headers

    func testBAMHeaderProgramLinesBecomePortable() {
        let context = PortablePath.Context.forFile(at: output)
        let header = [
            "@HD\tVN:1.6\tSO:coordinate",
            "@SQ\tSN:chr20\tLN:500001",
            "@PG\tID:minimap2\tPN:minimap2\tVN:2.31\tCL:minimap2 -a -o \(analysis.path)/raw.sam \(input.path)",
            "@PG\tID:samtools\tPN:samtools\tPP:minimap2\tVN:1.24\tCL:\(samtools) sort -o \(output.path) \(analysis.path)/filtered.bam",
            "",
        ].joined(separator: "\n")
        let sanitized = BAMHeaderPathSanitizer.sanitizedHeader(header, context: context)
        XCTAssertEqual(sanitized, [
            "@HD\tVN:1.6\tSO:coordinate",
            "@SQ\tSN:chr20\tLN:500001",
            "@PG\tID:minimap2\tPN:minimap2\tVN:2.31\tCL:minimap2 -a -o @/Analyses/minimap2-1/raw.sam @/Imports/reads.lungfishfastq/reads.fastq.gz",
            "@PG\tID:samtools\tPN:samtools\tPP:minimap2\tVN:1.24\tCL:<tool-root>/envs/samtools/bin/samtools sort -o @/Analyses/minimap2-1/sample.sorted.bam @/Analyses/minimap2-1/filtered.bam",
            "",
        ].joined(separator: "\n"))
        XCTAssertNil(BAMHeaderPathSanitizer.sanitizedHeader("@HD\tVN:1.6\n@SQ\tSN:chr1\tLN:10\n", context: context))
    }

    func testGATKCommandLineInKeptVCFBecomesPortable() {
        let portable = PortablePath.Context.forFile(at: output)
        let context = VCFHeaderPathSanitizer.Context(workspaceURLs: [], portable: portable)
        let line = "##GATKCommandLine=<ID=HaplotypeCaller,CommandLine=\"HaplotypeCaller --input \(output.path) --reference \(FileManager.default.homeDirectoryForCurrentUser.path)/refs/GRCh38.fa --output \(analysis.path)/calls.vcf.gz\",Version=\"4.6\">"
        XCTAssertEqual(
            VCFHeaderPathSanitizer.sanitize(headerLine: line, context: context),
            "##GATKCommandLine=<ID=HaplotypeCaller,CommandLine=\"HaplotypeCaller --input @/Analyses/minimap2-1/sample.sorted.bam --reference <external>/GRCh38.fa --output @/Analyses/minimap2-1/calls.vcf.gz\",Version=\"4.6\">"
        )
    }
}
