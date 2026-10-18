// ExtractSequenceLineWidthCommandTests.swift - lungfish-cli extract sequence --line-width with no region
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.12 lane 12.34 M3, ARCH ruling on the export shape 1.1 row A12. With no region and `--line-width` the command
// wraps each named record's bases to that width and keeps its header line, which is how the sequence view's FASTA export
// writes its 80 columns. Without `--line-width` the records are written as stored (ExtractSequenceRecordsCommandTests),
// and a region run keeps its default width of 70.

import ArgumentParser
import XCTest
@testable import LungfishCLI
@testable import LungfishCore
import LungfishIO
@testable import LungfishWorkflow

final class ExtractSequenceLineWidthCommandTests: XCTestCase {
    private var folder: URL!
    private var source: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("ExtractSequenceWidth-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        source = folder.appendingPathComponent("sequence.fa")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    private func leaf(_ extra: [String], output: URL) throws -> ExtractSequenceSubcommand {
        let parsed = try LungfishCLI.parseAsRoot(["extract", "sequence", source.path] + extra + ["--output", output.path])
        return try XCTUnwrap(parsed as? ExtractSequenceSubcommand)
    }

    /// Runs the leaf on `text` and returns the file it wrote.
    private func run(_ text: String, _ extra: [String], output name: String = "out.fa") throws -> URL {
        try Data(text.utf8).write(to: source)
        let output = folder.appendingPathComponent(name)
        let command = try leaf(extra, output: output)
        try command.validateRecordsRun()
        _ = try command.exportRecords()
        return output
    }

    private func text(_ url: URL) throws -> String {
        try String(contentsOf: url, encoding: .utf8)
    }

    /// A 200 base sequence with a description wraps to 80, 80 and 40, the bytes the sequence view has always written.
    func testTheLineWidthWrapsTheBasesAndKeepsTheHeader() throws {
        let output = try run(
            ">chr1 visible track\n\(String(repeating: "ACGT", count: 50))\n", ["--sequence=chr1", "--line-width", "80"]
        )
        let eighty = String(repeating: "ACGT", count: 20)
        XCTAssertEqual(
            try text(output), ">chr1 visible track\n\(eighty)\n\(eighty)\n\(String(repeating: "ACGT", count: 10))\n"
        )
    }

    /// A sequence of exactly one line ends without a blank line, and a sequence with no bases is its header.
    func testAFullLineEndsWithoutABlankLineAndAnEmptySequenceIsItsHeader() throws {
        let full = String(repeating: "A", count: 80)
        let one = try run(">s\n\(full)\n", ["--sequence=s", "--line-width", "80"], output: "one.fa")
        XCTAssertEqual(try text(one), ">s\n\(full)\n")
        let empty = try run(">e\n>f\nAC\n", ["--sequence=e", "--line-width", "80"], output: "empty.fa")
        XCTAssertEqual(try text(empty), ">e\n")
    }

    /// Stored lines are joined and cut again, and a carriage return leaves with the line end it belonged to.
    func testAWrapJoinsStoredLinesAndDropsCarriageReturns() throws {
        let output = try run(
            ">a one\r\nACGT\r\nAC\r\nGTT\r\n>b\nTT\n", ["--sequence=a", "--sequence=b", "--line-width", "4"], output: "joined.fa"
        )
        XCTAssertEqual(try text(output), ">a one\nACGT\nACGT\nT\n>b\nTT\n")
    }

    /// With no `--line-width` the record is written as stored, and its record names no width.
    func testWithoutALineWidthTheRecordsAreStoredAsTheyWere() throws {
        let stored = ">a\nACGTACGT\nAC\n"
        let output = try run(stored, ["--sequence=a"], output: "stored.fa")
        XCTAssertEqual(try text(output), stored)
        let envelope = try XCTUnwrap(ProvenanceEnvelopeReader.load(fromSidecar: ProvenanceRecorder.fileSidecarURL(for: output)))
        XCTAssertNil(envelope.options.explicit["lineWidth"])
    }

    /// The record keeps the width as an explicit option, in its argv, and names the one FASTA file as its input.
    func testTheRecordNamesTheWidthAndTheFASTAFileOnly() throws {
        let output = try run(">a\nACGT\n", ["--sequence=a", "--line-width", "2"])
        let envelope = try XCTUnwrap(ProvenanceEnvelopeReader.load(fromSidecar: ProvenanceRecorder.fileSidecarURL(for: output)))
        XCTAssertEqual(envelope.options.explicit.keys.sorted(), ["lineWidth", "outputPath", "sequences"])
        XCTAssertEqual(envelope.options.explicit["lineWidth"], .integer(2))
        XCTAssertEqual(envelope.options.explicit["sequences"], .array([.string("a")]))
        XCTAssertTrue(envelope.options.defaults.isEmpty)
        let flag = try XCTUnwrap(envelope.argv.firstIndex(of: "--line-width"))
        XCTAssertEqual(envelope.argv[flag + 1], "2")
        let inputs = envelope.files.filter { $0.role == .input }
        XCTAssertEqual(inputs.map { URL(fileURLWithPath: $0.path).lastPathComponent }, ["sequence.fa"])
        XCTAssertEqual(envelope.workflowName, "lungfish extract sequence")
    }

    /// A width below 1 is refused before the start line and before a byte is written.
    func testALineWidthBelowOneIsRefusedBeforeAnythingIsWritten() throws {
        try Data(">a\nACGT\n".utf8).write(to: source)
        let output = folder.appendingPathComponent("zero.fa")
        let command = try leaf(["--sequence=a", "--line-width", "0"], output: output)
        XCTAssertThrowsError(try command.validateRecordsRun())
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
    }

    /// The default of 70 still belongs to the region runs, and the option still sets their width.
    func testTheDefaultWidthOfARegionRunIsStill70() throws {
        let plain = try XCTUnwrap(try LungfishCLI.parseAsRoot(["extract", "sequence", "g.fa", "chr1:1-10"]) as? ExtractSequenceSubcommand)
        XCTAssertNil(plain.lineWidthArgument)
        XCTAssertEqual(plain.lineWidth, 70)
        let wide = try XCTUnwrap(
            try LungfishCLI.parseAsRoot(["extract", "sequence", "g.fa", "chr1:1-10", "--line-width", "40"]) as? ExtractSequenceSubcommand
        )
        XCTAssertEqual(wide.lineWidth, 40)
    }

    /// The pure functions the app stages with and the leaf wraps with.
    func testTheStagedTextAndTheIdentityOfASequence() {
        XCTAssertEqual(FASTARecordsExport.sequenceText(name: "s", description: nil, bases: "ACGT"), ">s\nACGT\n")
        XCTAssertEqual(FASTARecordsExport.sequenceText(name: "s", description: "d e", bases: ""), ">s d e\n")
        XCTAssertEqual(FASTARecordsExport.sequenceText(name: "s", description: "", bases: "A"), ">s \nA\n", "an empty description keeps its space")
        XCTAssertEqual(FASTARecordsExport.sequenceIdentity(name: "chr1", description: "visible track"), "chr1")
        XCTAssertEqual(FASTARecordsExport.sequenceIdentity(name: "my seq", description: nil), "my seq")
        XCTAssertEqual(FASTARecordsExport.sequenceIdentity(name: "my seq", description: "circular"), "my seq circular")
        XCTAssertEqual(
            FASTARecordsExport.rewrapped(Data(">x\nACGTAC\n".utf8), lineWidth: 4), Data(">x\nACGT\nAC\n".utf8)
        )
    }
}
