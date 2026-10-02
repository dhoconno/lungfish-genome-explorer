// FastqSubcommandBundleInputTests.swift - A fastq subcommand given a bundle reads the bundle's reads
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// The FASTQ operations dialog records `lungfish-cli fastq <subcommand>
// <bundle>` for every derivative it runs, and the subcommands refused a
// bundle path (they opened the directory as a file). Every single-input
// derivative subcommand now resolves a bundle the way the dialog and the
// dashboard do, through FASTQCLIMaterializer, so the recorded command
// replays: a single-file bundle is its file, a multi-file bundle is every
// file joined, a fullPaired bundle is R1 and R2 interleaved, and a virtual
// bundle is its materialized reads. A file inside a physical bundle is still
// that one file, and the preview of a virtual bundle is never processed as
// data (R3, R8, lane 1x).
//
// `reverse-complement` is pure Swift, so most cases need no tool. The
// length filter runs seqkit and the fullPaired case runs reformat.sh, so
// those skip when the managed tools are not installed.

import ArgumentParser
import Foundation
import XCTest
@testable import LungfishCLI
import LungfishIO
import LungfishTestSupport
import LungfishWorkflow

final class FastqSubcommandBundleInputTests: XCTestCase {
    private var root: URL!
    private var shapes: BundleShapeFixtures!

    override func setUpWithError() throws {
        root = try TestTempDirectory.make(prefix: "fastq-subcommand-bundle-input")
        shapes = try BundleShapeFixtures(in: root.appendingPathComponent("Project.lungfish/Imports", isDirectory: true))
    }

    override func tearDown() {
        TestTempDirectory.cleanup(root)
    }

    private func output(_ name: String) -> URL {
        root.appendingPathComponent(name)
    }

    private func reverseComplement(_ input: String, to outputURL: URL) async throws {
        try await FastqReverseComplementSubcommand.parse([input, "-o", outputURL.path]).run()
    }

    private func names(_ url: URL) throws -> [String] {
        try BundleShapeFixtures.readNames(in: url)
    }

    /// The output file's sidecar, focused on that output.
    private func envelope(for outputURL: URL) throws -> ProvenanceEnvelope {
        try XCTUnwrap(ProvenanceEnvelopeReader.load(fromSidecar: ProvenanceRecorder.fileSidecarURL(for: outputURL)))
    }

    /// The run's whole envelope, in the output folder. A focused sidecar keeps
    /// only the steps that wrote its output, so the step that wrote a bundle's
    /// reads for the run lives here.
    private func runEnvelope(for outputURL: URL) throws -> ProvenanceEnvelope {
        try XCTUnwrap(ProvenanceEnvelopeReader.load(
            fromSidecar: outputURL.deletingLastPathComponent().appendingPathComponent(ProvenanceRecorder.provenanceFilename)
        ))
    }

    private func requireTool(_ tool: NativeTool) async throws {
        guard await NativeToolRunner.shared.isToolAvailable(tool) else {
            try ToolAvailability.skipOrFail("managed \(tool.rawValue) is not installed")
        }
    }

    // MARK: - Each bundle shape

    func testEachBundleShapeIsReadAsItsReads() async throws {
        let cases: [(shape: String, bundle: URL, reads: [String])] = [
            ("root single", shapes.single, ["s1", "s2", "s3"]),
            ("root multi-file", shapes.multiFile, ["m1", "m2", "m3", "m4", "m5"]),
            ("virtual orientMap", shapes.oriented, ["s1", "s3"]),
            ("derived full", shapes.full, ["g1", "g2"]),
        ]
        for testCase in cases {
            let outputURL = output("\(testCase.shape.replacingOccurrences(of: " ", with: "-")).fastq")
            try await reverseComplement(testCase.bundle.path, to: outputURL)
            XCTAssertEqual(try names(outputURL), testCase.reads, testCase.shape)
        }
    }

    func testAFullPairedBundleIsReadAsItsMatesInterleaved() async throws {
        try await requireTool(.reformat)
        let outputURL = output("paired.fastq")
        try await reverseComplement(shapes.paired.path, to: outputURL)
        XCTAssertEqual(try names(outputURL), ["p1/1", "p1/2", "p2/1", "p2/2"])
    }

    func testAFileInsideAPhysicalBundleIsStillThatOneFile() async throws {
        let outputURL = output("chunk-1.fastq")
        try await reverseComplement(shapes.multiFileChunks[1].path, to: outputURL)
        XCTAssertEqual(try names(outputURL), ["m3", "m4", "m5"])
        let envelope = try envelope(for: outputURL)
        XCTAssertFalse(envelope.steps.contains { $0.toolName == SequenceInputConcatenation.toolName }, "nothing was joined")
    }

    /// The only FASTQ inside a virtual bundle is a preview of its first
    /// reads, which is not the data.
    func testThePreviewOfAVirtualBundleResolvesTheBundle() async throws {
        let preview = shapes.oriented.appendingPathComponent("preview.fastq")
        XCTAssertEqual(try names(preview), ["s1"], "the preview holds one read")
        let outputURL = output("from-preview.fastq")
        try await reverseComplement(preview.path, to: outputURL)
        XCTAssertEqual(try names(outputURL), ["s1", "s3"], "the bundle's reads, not the preview")
    }

    func testAMissingPathIsRefusedBeforeAnythingRuns() async throws {
        let outputURL = output("missing.fastq")
        do {
            try await reverseComplement(root.appendingPathComponent("absent.lungfishfastq").path, to: outputURL)
            XCTFail("a missing input is refused")
        } catch let error as CLIError {
            guard case .inputFileNotFound = error else { return XCTFail("\(error)") }
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: outputURL.path))
    }

    // MARK: - The recorded command and the provenance

    func testTheProvenanceNamesTheBundleEveryMemberAndTheJoin() async throws {
        let outputURL = output("multi-provenance.fastq")
        try await reverseComplement(shapes.multiFile.path, to: outputURL)
        let envelope = try runEnvelope(for: outputURL)

        XCTAssertEqual(envelope.argv, [CLICommandIdentity.executableName, "fastq", "reverse-complement", shapes.multiFile.path, "-o", outputURL.path])
        let inputPaths = Set(envelope.files.filter { $0.role == .input }.map(\.path))
        for chunk in shapes.multiFileChunks {
            XCTAssertTrue(inputPaths.contains(chunk.standardizedFileURL.path), "\(chunk.lastPathComponent) is a recorded input")
        }
        let join = try XCTUnwrap(envelope.steps.first { $0.toolName == SequenceInputConcatenation.toolName }, "the join is a step")
        XCTAssertEqual(Set(join.inputs.map(\.path)), Set(shapes.multiFileChunks.map(\.standardizedFileURL.path)))
        XCTAssertEqual(join.outputs.count, 1)
        XCTAssertEqual(join.outputs.first?.originPath, shapes.multiFile.standardizedFileURL.path)
        XCTAssertFalse(FileManager.default.fileExists(atPath: join.outputs[0].path), "the joined copy is removed after the run")
    }

    func testTheProvenanceOfAVirtualBundleRecordsItsMaterialization() async throws {
        let outputURL = output("virtual-provenance.fastq")
        try await reverseComplement(shapes.oriented.path, to: outputURL)
        let envelope = try runEnvelope(for: outputURL)

        XCTAssertEqual(envelope.argv[3], shapes.oriented.path, "the command names the bundle")
        let materialize = try XCTUnwrap(
            envelope.steps.first { $0.toolName == CLISequenceInputMaterialization.materializationToolName },
            "the materialization is a step"
        )
        XCTAssertEqual(materialize.argv.prefix(4).map { $0 }, [CLICommandIdentity.executableName, "fastq", "materialize", shapes.oriented.standardizedFileURL.path])
        let inputPaths = Set(envelope.files.filter { $0.role == .input }.map(\.path))
        XCTAssertTrue(inputPaths.contains(shapes.oriented.standardizedFileURL.path), "the bundle aggregate")
        XCTAssertTrue(inputPaths.contains(shapes.single.appendingPathComponent("single.fastq").standardizedFileURL.path), "the root file")
        XCTAssertTrue(inputPaths.contains(shapes.oriented.appendingPathComponent("orient-map.tsv").standardizedFileURL.path), "the recipe")
    }

    func testTheRecordedCommandOfABundleRunReplaysToTheSameReads() async throws {
        let first = output("first.fastq")
        try await reverseComplement(shapes.multiFile.path, to: first)
        let recorded = try envelope(for: first).argv
        let replay = output("replay.fastq")
        var words = Array(recorded.dropFirst())
        words[words.count - 1] = replay.path
        let command = try LungfishCLI.parseAsRoot(LungfishCLI.normalizedArgumentsForParsing(words))
        guard var runnable = command as? AsyncParsableCommand else { return XCTFail("\(type(of: command))") }
        try await runnable.run()
        XCTAssertEqual(try Data(contentsOf: replay), try Data(contentsOf: first))
    }

    // MARK: - Pairing of a materialized copy

    /// A materialized copy carries no sidecar, so the pairing comes from the
    /// bundle's metadata, verified against the copy's records, as the
    /// dialog's `--pairing` argument is derived.
    func testAVirtualBundleOfPairsIsFilteredAsPairs() async throws {
        try await requireTool(.seqkit)
        let interleavedRoot = shapes.single.deletingLastPathComponent().appendingPathComponent("pairs.lungfishfastq", isDirectory: true)
        try FileManager.default.createDirectory(at: interleavedRoot, withIntermediateDirectories: true)
        let rootFile = interleavedRoot.appendingPathComponent("pairs.fastq")
        try (
            "@q1/1\nACGTACGTAC\n+\nIIIIIIIIII\n@q1/2\nAC\n+\nII\n"
            + "@q2/1\nACGTACGTAC\n+\nIIIIIIIIII\n@q2/2\nACGTACGTAC\n+\nIIIIIIIIII\n"
        ).write(to: rootFile, atomically: true, encoding: .utf8)
        let outputURL = output("pairs-length.fastq")
        try await FastqLengthFilterSubcommand.parse([interleavedRoot.path, "--min", "5", "--pairing", "interleaved", "-o", outputURL.path]).run()
        XCTAssertEqual(try names(outputURL), ["q2/1", "q2/2"], "the short mate's pair goes as a pair")
    }
}
