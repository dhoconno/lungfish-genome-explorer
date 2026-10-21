// ImportFastaAnnotatedLeafTests.swift - import fasta with annotations, provenance inputs and events
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import ArgumentParser
import LungfishTestSupport
import XCTest
@testable import LungfishCLI
@testable import LungfishCore
@testable import LungfishIO
@testable import LungfishWorkflow

/// The options the app's annotated reference import and Import Center need (ruling A48 F2, L1 and L5).
final class ImportFastaAnnotatedLeafTests: XCTestCase {
    private var root: URL!
    private var project: URL!

    override func setUp() async throws {
        if let missing = await NativeBundleBuilder().checkRequiredTools() {
            try ToolAvailability.skipOrFail("Native reference bundle tools are unavailable: \(missing.description)")
        }
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ImportFastaAnnotatedLeafTests-\(UUID().uuidString)", isDirectory: true)
            .resolvingSymlinksInPath()
        project = root.appendingPathComponent("Project.lungfish", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        if let root { try? FileManager.default.removeItem(at: root) }
    }

    func testAnnotationsAttachTheTrackAndWriteTheExtractionRecord() async throws {
        let staged = try stageSelection()
        let alignment = root.appendingPathComponent("Aligned.lungfishmsa", isDirectory: true)
        try FileManager.default.createDirectory(at: alignment, withIntermediateDirectories: true)
        // The viewer names the bundles the selection came from, which are folders.
        let export = root.appendingPathComponent("Source.lungfishref", isDirectory: true)
        try FileManager.default.createDirectory(at: export, withIntermediateDirectories: true)
        try #"{"schemaVersion":1}"#.write(
            to: export.appendingPathComponent("manifest.json"), atomically: true, encoding: .utf8
        )

        try await ImportCommand.FASTASubcommand.parse([
            staged.fasta.path, "--output-dir", project.path, "--name", "Annotated Selection",
            "--provenance-input", alignment.path, "--provenance-input", export.path,
            "--annotations", staged.bed.path, "--annotation-selection", staged.selectionJSON.path,
            "--source-alignment-bundle", alignment.path, "--quiet",
        ]).run()

        let bundle = project.appendingPathComponent("Reference Sequences/Annotated_Selection.lungfishref", isDirectory: true)
        let manifest = try BundleManifest.load(from: bundle)
        XCTAssertEqual(manifest.annotations.count, 1)
        XCTAssertEqual(manifest.annotations.first?.featureCount, 2)

        // The attach writes the bundle's root record after the build, as it did on the helper route.
        let root = try XCTUnwrap(ProvenanceEnvelopeReader.load(from: bundle))
        XCTAssertEqual(root.workflowName, "lungfish annotation track import")
        XCTAssertTrue(root.steps.flatMap(\.inputs).contains { $0.path == staged.bed.path })

        let sidecar = bundle.appendingPathComponent("annotations/msa-extraction-annotations-provenance.json")
        let explicit = try XCTUnwrap(ProvenanceEnvelopeReader.load(fromSidecar: sidecar)).options.explicit
        XCTAssertEqual(explicit["selected_annotations_by_record"], staged.selection)
        XCTAssertEqual(explicit["selected_sequence_ids"], .array([.string("seqA"), .string("seqB")]))
        XCTAssertEqual(explicit["source_alignment_bundle"], .file(alignment))
        XCTAssertEqual(explicit["durable_source_files"], .array([.file(alignment), .file(export)]))
        XCTAssertEqual(
            explicit["selected_annotation_bed_sha256"],
            ProvenanceRecorder.sha256(of: staged.bed).map(ParameterValue.string)
        )
        XCTAssertEqual(explicit["feature_count"], .integer(2))
    }

    /// MD62. The attach is a step of `import fasta`, so its record names the command that ran and never
    /// `lungfish-cli annotation-import`, which no leaf has. Under the test runner the words are the ones the
    /// command would run, as the bundle's own import record holds them.
    func testTheAnnotationRecordNamesTheImportFastaCommandThatRan() async throws {
        let staged = try stageSelection()
        try await ImportCommand.FASTASubcommand.parse([
            staged.fasta.path, "--output-dir", project.path, "--name", "Annotated Selection",
            "--annotations", staged.bed.path, "--annotation-selection", staged.selectionJSON.path, "--quiet",
        ]).run()

        let bundle = project.appendingPathComponent("Reference Sequences/Annotated_Selection.lungfishref", isDirectory: true)
        let annotations = bundle.appendingPathComponent("annotations", isDirectory: true)
        let logName = try XCTUnwrap(
            try FileManager.default.contentsOfDirectory(atPath: annotations.path).first { $0.hasSuffix("-import-provenance.json") }
        )
        let log = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data(contentsOf: annotations.appendingPathComponent(logName))) as? [String: Any]
        )
        let entry = try XCTUnwrap((log["entries"] as? [[String: Any]])?.first)
        let argv = try XCTUnwrap(entry["argv"] as? [String])
        XCTAssertEqual(Array(argv.prefix(3)), ["lungfish-cli", "import", "fasta"], "\(argv)")
        XCTAssertTrue(argv.contains(staged.fasta.path), "\(argv)")
        XCTAssertTrue(argv.contains("--annotations"), "\(argv)")
        XCTAssertFalse(argv.contains("annotation-import"), "\(argv)")
        // The bundle's root record is the annotation import's, and its step holds the same command.
        let record = try XCTUnwrap(ProvenanceEnvelopeReader.load(from: bundle))
        XCTAssertEqual(record.steps.first?.argv, argv)
    }

    func testJSONEventsAreOneStartProgressAndOneComplete() async throws {
        let source = root.appendingPathComponent("plain.fa")
        try ">chr1\nACGTACGT\n".write(to: source, atomically: true, encoding: .utf8)

        let output = try await captureStandardOutput {
            try await ImportCommand.FASTASubcommand.parse([
                source.path, "--output-dir", self.project.path, "--format", "json",
            ]).run()
        }
        let events = try output.split(separator: "\n").map { line in
            try XCTUnwrap(JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any], String(line))
        }
        XCTAssertEqual(events.first?["event"] as? String, "start")
        XCTAssertEqual(events.first?["message"] as? String, "Importing plain.fa")
        XCTAssertEqual(events.dropFirst().dropLast().compactMap { $0["event"] as? String }.filter { $0 != "progress" }, [])
        XCTAssertTrue(events.contains { $0["message"] as? String == "Preparing reference input..." })
        XCTAssertEqual(events.last?["event"] as? String, "complete")
        let bundle = project.appendingPathComponent("Reference Sequences/plain.lungfishref").path
        XCTAssertEqual(events.last?["outputs"] as? [String], [bundle])
    }

    func testASelectionWithoutAnnotationsIsRefusedAndWritesNothing() async throws {
        let staged = try stageSelection()
        do {
            try await ImportCommand.FASTASubcommand.parse([
                staged.fasta.path, "--output-dir", project.path, "--annotation-selection", staged.selectionJSON.path,
            ]).run()
            XCTFail("Expected a refusal")
        } catch let exit as ExitCode {
            XCTAssertEqual(exit.rawValue, 3)
        }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: project.path), [])
    }

    /// The leaf reads the input to name the selected records, which a compressed input cannot give
    /// after the build (A48 M3 review, Fix 2). It refuses first, with the input error code.
    func testAnnotationsWithACompressedInputAreRefusedBeforeAnythingIsWritten() async throws {
        let staged = try stageSelection()
        let compressed = root.appendingPathComponent("selection.fasta.gz")
        try gzip(staged.fasta, to: compressed)
        do {
            try await ImportCommand.FASTASubcommand.parse([
                compressed.path, "--output-dir", project.path, "--annotations", staged.bed.path, "--quiet",
            ]).run()
            XCTFail("Expected a refusal")
        } catch let exit as ExitCode {
            XCTAssertEqual(exit.rawValue, 3)
        }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: project.path), [])
    }

    /// A step after the build that throws takes the published bundle away and ends the run with a failed
    /// event (A48 M3 review, Fix 6, L5). The BED holds a comment and no feature line, so the attach has
    /// nothing to import and throws after the service published the bundle.
    func testAFailingAnnotationStepRemovesThePublishedBundleAndEndsWithAFailedEvent() async throws {
        let staged = try stageSelection()
        let empty = staged.bed.deletingLastPathComponent().appendingPathComponent("no-features.bed")
        try "# a header and no feature line\n".write(to: empty, atomically: true, encoding: .utf8)

        let captured = await captureStandardOutputAndError {
            try await ImportCommand.FASTASubcommand.parse([
                staged.fasta.path, "--output-dir", self.project.path, "--annotations", empty.path, "--format", "json",
            ]).run()
        }

        guard let failure = captured.error as? ReferenceBundleAnnotationImportError,
              case .noImportableAnnotations = failure
        else {
            return XCTFail("the attach step refuses a BED with no feature line, got \(String(describing: captured.error))")
        }
        XCTAssertEqual(try ImportFastaSIGTERMTests.leftovers(in: project), [], "the failed run removed the published bundle")
        let lines = captured.output.split(separator: "\n").map(String.init)
        let last = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data((lines.last ?? "").utf8)) as? [String: Any], "\(lines)"
        )
        XCTAssertEqual(last["event"] as? String, "failed", "the last line is the failed event. \(lines)")
    }

    // MARK: - Fixtures

    private func gzip(_ source: URL, to destination: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/gzip")
        process.arguments = ["-c", source.path]
        let output = Pipe()
        process.standardOutput = output
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
        try data.write(to: destination, options: .atomic)
    }

    private func stageSelection() throws -> (fasta: URL, bed: URL, selectionJSON: URL, selection: ParameterValue) {
        let staging = root.appendingPathComponent("staging", isDirectory: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        let fasta = staging.appendingPathComponent("selection.fasta")
        try ">seqA first\nACGTACGTAC\n>seqB\nGGCCAATTGGCC\n".write(to: fasta, atomically: true, encoding: .utf8)
        let bed = staging.appendingPathComponent("selected-annotations.bed")
        try ("seqA\t1\t6\tgeneA\t0\t+\t1\t6\t0,0,0\t1\t5,\t0,\tgene\tproduct=a%3Bb%3Dc,d\n"
            + "seqB\t0\t12\tcdsB\t0\t-\t0\t12\t0,0,0\t2\t3,2,\t0,10,\tCDS\t\n")
            .write(to: bed, atomically: true, encoding: .utf8)
        let selection = MSAExtractionAnnotationProvenance.annotationSelectionValue([
            "seqA": [SequenceAnnotation(
                type: .gene, name: "geneA", chromosome: "seqA", intervals: [AnnotationInterval(start: 1, end: 6)],
                strand: .forward, qualifiers: ["product": AnnotationQualifier("a;b=c,d")], note: "kept note"
            )],
            "seqB": [SequenceAnnotation(
                type: .cds, name: "cdsB", chromosome: "seqB",
                intervals: [AnnotationInterval(start: 10, end: 12), AnnotationInterval(start: 0, end: 3)],
                strand: .reverse
            )],
        ])
        let selectionJSON = staging.appendingPathComponent("selected-annotations.json")
        try JSONEncoder().encode(selection).write(to: selectionJSON)
        return (fasta, bed, selectionJSON, selection)
    }

    // MARK: - The folder as given (2.11 A48 M4, the FASTQ operation wrapper)

    func testBundleDirBuildsInTheFolderAsGivenAndRecordsTheOption() async throws {
        let source = root.appendingPathComponent("plain.fa")
        try ">chr1\nACGTACGT\n".write(to: source, atomically: true, encoding: .utf8)
        let folder = project.appendingPathComponent("Analyses", isDirectory: true)

        let output = try await captureStandardOutput {
            try await ImportCommand.FASTASubcommand.parse([
                source.path, "--bundle-dir", folder.path, "--name", "Wrapped", "--format", "json",
            ]).run()
        }

        let bundle = folder.appendingPathComponent("Wrapped.lungfishref", isDirectory: true)
        let last = try XCTUnwrap(output.split(separator: "\n").last)
        let complete = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(last.utf8)) as? [String: Any])
        XCTAssertEqual(complete["outputs"] as? [String], [bundle.path])
        for parent in [project!, folder] {
            XCTAssertFalse(
                FileManager.default.fileExists(atPath: parent.appendingPathComponent("Reference Sequences").path),
                "--bundle-dir makes no Reference Sequences folder"
            )
        }
        let record = try XCTUnwrap(ProvenanceEnvelopeReader.load(from: bundle))
        XCTAssertEqual(
            Array(try XCTUnwrap(record.steps.first?.argv).dropFirst()),
            ["import", "fasta", source.path, "--bundle-dir", folder.path, "--name=Wrapped"],
            "the record names the folder the way the run was given it, with no --output-dir"
        )
    }

    func testBundleDirWithOutputDirIsRefusedAtParse() {
        XCTAssertThrowsError(try ImportCommand.FASTASubcommand.parse([
            "plain.fa", "--output-dir", project.path, "--bundle-dir", project.path,
        ])) { error in
            XCTAssertEqual(
                ImportCommand.FASTASubcommand.message(for: error),
                "Give --output-dir or --bundle-dir, not both."
            )
        }
        XCTAssertEqual(
            ReferenceBundleImportService.importFASTAArguments(
                sourceURL: URL(fileURLWithPath: "/in/a.fa"), projectURL: nil,
                bundleFolderURL: URL(fileURLWithPath: "/out/Analyses", isDirectory: true), preferredBundleName: nil,
                rehydrateSourceProvenance: true
            ),
            ["import", "fasta", "/in/a.fa", "--bundle-dir", "/out/Analyses", "--rehydrate-source-provenance"]
        )
    }

    private func captureStandardOutput(_ operation: () async throws -> Void) async throws -> String {
        let captured = await captureStandardOutputAndError(operation)
        if let error = captured.error { throw error }
        return captured.output
    }

    /// What the operation printed to standard output together with the error it ended with, since a
    /// run that fails still ends its events with a failed line that a test has to read.
    private func captureStandardOutputAndError(
        _ operation: () async throws -> Void
    ) async -> (output: String, error: (any Error)?) {
        let pipe = Pipe()
        let originalStdout = dup(STDOUT_FILENO)
        fflush(stdout)
        dup2(pipe.fileHandleForWriting.fileDescriptor, STDOUT_FILENO)
        var thrown: (any Error)?
        do {
            try await operation()
        } catch {
            thrown = error
        }
        fflush(stdout)
        dup2(originalStdout, STDOUT_FILENO)
        close(originalStdout)
        pipe.fileHandleForWriting.closeFile()
        let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        return (output, thrown)
    }
}
