// ImportFastaAnnotatedLeafTests.swift - import fasta with annotations, provenance inputs and events
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import ArgumentParser
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
            throw XCTSkip("Native reference bundle tools are unavailable: \(missing.description)")
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

    private func captureStandardOutput(_ operation: () async throws -> Void) async throws -> String {
        let pipe = Pipe()
        let originalStdout = dup(STDOUT_FILENO)
        fflush(stdout)
        dup2(pipe.fileHandleForWriting.fileDescriptor, STDOUT_FILENO)
        do {
            try await operation()
            fflush(stdout)
        } catch {
            fflush(stdout)
            dup2(originalStdout, STDOUT_FILENO)
            close(originalStdout)
            pipe.fileHandleForWriting.closeFile()
            throw error
        }
        dup2(originalStdout, STDOUT_FILENO)
        close(originalStdout)
        pipe.fileHandleForWriting.closeFile()
        return String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    }
}
