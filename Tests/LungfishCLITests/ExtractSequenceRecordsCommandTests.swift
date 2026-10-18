// ExtractSequenceRecordsCommandTests.swift - lungfish-cli extract sequence with no region
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.12 lane 12.34 M3, ARCH ruling on the export shape 1.1 row A11 and 1.3, BIO 6. With no region the command
// writes the sequences a selection file or `--sequence` names, as stored, finds each by its header line or its first
// word, names only the FASTA file and the selection file as its inputs, refuses before it writes, and parses the
// arguments the viewer's begin helper builds. A run with a region is unchanged.

import ArgumentParser
import XCTest
@testable import LungfishCLI
@testable import LungfishCore
import LungfishIO
@testable import LungfishWorkflow

final class ExtractSequenceRecordsCommandTests: XCTestCase {
    private var folder: URL!
    private var source: URL!

    /// Four records. A wrapped one with a description, a single line, one with CRLF line ends, and a second `r2`
    /// that has no final line feed.
    private static let sourceText = ">r1 first record\nACGTACGT\nACGT\n>r2\nTTTTCCCCGGGGAAAA\n>r3 third\r\nAC\r\nGT\r\n>r2\nGGGG"

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("ExtractSequenceRecords-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        source = folder.appendingPathComponent("records.fa")
        try Data(Self.sourceText.utf8).write(to: source)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    private func command(_ arguments: [String]) throws -> ExtractSequenceSubcommand {
        let parsed = try LungfishCLI.parseAsRoot(arguments)
        return try XCTUnwrap(parsed as? ExtractSequenceSubcommand)
    }

    private func run(_ arguments: [String]) throws -> ViewerExportLeafOutcome {
        let leaf = try command(arguments)
        try leaf.validateRecordsRun()
        return try leaf.exportRecords()
    }

    private func writeSelection(_ names: [String], name: String = "selection.json") throws -> URL {
        let url = folder.appendingPathComponent(name)
        try FASTARecordsExport.selection(headers: names).encoded().write(to: url)
        return url
    }

    private func arguments(_ extra: [String], output: URL, input: URL? = nil) -> [String] {
        ["extract", "sequence", (input ?? source).path] + extra + ["--output", output.path]
    }

    private static func envelope(of outputURL: URL) throws -> ProvenanceEnvelope {
        try XCTUnwrap(ProvenanceEnvelopeReader.load(fromSidecar: ProvenanceRecorder.fileSidecarURL(for: outputURL)))
    }

    // MARK: - The records and the bytes

    /// The document keeps every byte, ends a header at the line feed and drops a carriage return from it, and finds
    /// text before the first header.
    func testTheDocumentSplitsIntoRecordsAndKeepsEveryByte() throws {
        let document = FASTARecordsExport.document(from: Data(Self.sourceText.utf8))
        XCTAssertEqual(document.preambleLength, 0)
        XCTAssertEqual(document.records.map(\.header), ["r1 first record", "r2", "r3 third", "r2"])
        XCTAssertEqual(document.records.map(\.firstWord), ["r1", "r2", "r3", "r2"])
        XCTAssertEqual(document.records.first?.range.lowerBound, 0)
        XCTAssertEqual(document.records.last?.range.upperBound, Self.sourceText.utf8.count)
        let joined = document.records.reduce(into: Data()) { $0.append(document.bytes(of: $1)) }
        XCTAssertEqual(joined, Data(Self.sourceText.utf8))

        XCTAssertEqual(FASTARecordsExport.document(from: Data("x\n>a\nA\n".utf8)).preambleLength, 2)
        XCTAssertEqual(FASTARecordsExport.document(from: Data("no header".utf8)).preambleLength, 9)
        XCTAssertEqual(FASTARecordsExport.document(from: Data()).records.count, 0)
    }

    func testTheNamedRecordsAreWrittenAsStoredInTheOrderAsked() throws {
        let output = folder.appendingPathComponent("two.fa")
        let outcome = try run(arguments(["--sequence=r3", "--sequence=r1"], output: output))
        XCTAssertEqual(
            try String(contentsOf: output, encoding: .utf8),
            ">r3 third\r\nAC\r\nGT\r\n>r1 first record\nACGTACGT\nACGT\n"
        )
        XCTAssertEqual(outcome.message, "Wrote 2 sequences to two.fa")
    }

    /// The viewer stages its records and names each by its whole header, so the selection of every header makes the
    /// staged file's bytes, a repeated header included.
    func testAllTheHeadersOfAFileMakeTheFilesOwnBytes() throws {
        let document = FASTARecordsExport.document(from: Data(Self.sourceText.utf8))
        let selection = try writeSelection(document.records.map(\.header))
        let output = folder.appendingPathComponent("all.fa")
        _ = try run(arguments(["--selection", selection.path], output: output))
        XCTAssertEqual(try Data(contentsOf: output), Data(Self.sourceText.utf8))
    }

    /// A whole header is matched before a first word, and a name asked twice takes the next record of that name.
    func testAWholeHeaderBeatsAFirstWordAndANameAskedTwiceTakesTheNextRecord() throws {
        let output = folder.appendingPathComponent("twice.fa")
        _ = try run(arguments(["--sequence=r2", "--sequence=r2"], output: output))
        XCTAssertEqual(try String(contentsOf: output, encoding: .utf8), ">r2\nTTTTCCCCGGGGAAAA\n>r2\nGGGG")

        let whole = folder.appendingPathComponent("whole.fa")
        _ = try run(arguments(["--sequence=r1 first record"], output: whole))
        XCTAssertEqual(try String(contentsOf: whole, encoding: .utf8), ">r1 first record\nACGTACGT\nACGT\n")

        let third = folder.appendingPathComponent("third.fa")
        XCTAssertThrowsError(try run(arguments(["--sequence=r2", "--sequence=r2", "--sequence=r2"], output: third))) { error in
            XCTAssertTrue(error is ViewerExportRefusal, "\(error)")
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: third.path))
    }

    // MARK: - The record

    /// The record names the leaf, its canonical argv, and the two files it read with their digests, and nothing else.
    func testRecordNamesTheLeafTheFASTAAndTheSelectionOnly() throws {
        let selection = try writeSelection(["r3 third", "r1 first record"])
        let output = folder.appendingPathComponent("record.fa")
        let given = arguments(["--selection", selection.path], output: output)
        _ = try run(given)
        let envelope = try Self.envelope(of: output)
        XCTAssertEqual(envelope.tool.name, "lungfish-cli")
        XCTAssertEqual(envelope.tool.kind, "cli")
        XCTAssertEqual(envelope.workflowName, "lungfish extract sequence")
        XCTAssertEqual(envelope.argv, ["lungfish-cli"] + Array(given.dropFirst(0)))
        XCTAssertEqual(envelope.durableReplayArgv, envelope.argv)
        let inputs = envelope.files.filter { $0.role == .input }
        XCTAssertEqual(inputs.map { URL(fileURLWithPath: $0.path).lastPathComponent }.sorted(), ["records.fa", "selection.json"])
        XCTAssertTrue(inputs.allSatisfy { $0.checksumSHA256 != nil })
        XCTAssertEqual(envelope.options.explicit.keys.sorted(), ["outputPath", "selection"])
        XCTAssertTrue(envelope.options.defaults.isEmpty)
        XCTAssertEqual(envelope.options.resolvedDefaults.keys.sorted(), ["outputByteCount", "recordCount"])
        XCTAssertEqual(envelope.options.resolvedDefaults["recordCount"], .integer(2))
        XCTAssertEqual(envelope.options.resolvedDefaults["outputByteCount"], .integer(Int(try Data(contentsOf: output).count)))
        XCTAssertEqual(envelope.output?.format, .fasta)

        let named = folder.appendingPathComponent("named.fa")
        _ = try run(arguments(["--sequence=r1"], output: named))
        let byName = try Self.envelope(of: named)
        XCTAssertEqual(byName.options.explicit.keys.sorted(), ["outputPath", "sequences"])
        XCTAssertEqual(byName.options.explicit["sequences"], .array([.string("r1")]))
        XCTAssertEqual(byName.files.filter { $0.role == .input }.count, 1, "no selection file, so one input")
    }

    // MARK: - Refusals

    /// Every refusal comes before any write, and a refusal leaves neither the output nor its record.
    func testRefusesBeforeWriting() throws {
        let good = try writeSelection(["r1"])
        let garbage = folder.appendingPathComponent("garbage.json")
        try Data("not json".utf8).write(to: garbage)
        let empty = try writeSelection([], name: "empty.json")
        let gz = folder.appendingPathComponent("records.fa.gz")
        try Data(Self.sourceText.utf8).write(to: gz)
        let text = folder.appendingPathComponent("notes.txt")
        try Data(Self.sourceText.utf8).write(to: text)
        let preamble = folder.appendingPathComponent("preamble.fa")
        try Data("stray\n>a\nA\n".utf8).write(to: preamble)
        let cases: [(name: String, arguments: (URL) -> [String])] = [
            ("a source that is missing", { self.arguments(["--sequence=r1"], output: $0, input: self.folder.appendingPathComponent("gone.fa")) }),
            ("a gzip source", { self.arguments(["--sequence=r1"], output: $0, input: gz) }),
            ("a source that is not FASTA by name", { self.arguments(["--sequence=r1"], output: $0, input: text) }),
            ("text before the first header", { self.arguments(["--sequence=a"], output: $0, input: preamble) }),
            ("a selection file that is missing", { self.arguments(["--selection", self.folder.appendingPathComponent("none.json").path], output: $0) }),
            ("a selection file that is not JSON", { self.arguments(["--selection", garbage.path], output: $0) }),
            ("a selection that names no sequence", { self.arguments(["--selection", empty.path], output: $0) }),
            ("a sequence the file lacks", { self.arguments(["--sequence=r9"], output: $0) }),
            ("an output in a folder that is missing", { _ in
                self.arguments(["--selection", good.path], output: self.folder.appendingPathComponent("missing/out.fa"))
            }),
            ("an output that is the source", { _ in self.arguments(["--sequence=r1", "--force"], output: self.source) }),
            ("an output that is the selection file", { _ in self.arguments(["--selection", good.path, "--force"], output: good) }),
        ]
        for (index, refusal) in cases.enumerated() {
            let output = folder.appendingPathComponent("refused-\(index).fa")
            XCTAssertThrowsError(try run(refusal.arguments(output)), refusal.name) { error in
                XCTAssertTrue(error is ViewerExportRefusal, "\(refusal.name): \(error)")
            }
            XCTAssertFalse(FileManager.default.fileExists(atPath: output.path), refusal.name)
            XCTAssertFalse(FileManager.default.fileExists(atPath: ProvenanceRecorder.fileSidecarURL(for: output).path), refusal.name)
        }
        XCTAssertEqual(try Data(contentsOf: source), Data(Self.sourceText.utf8), "the source is untouched")
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.appendingPathComponent("missing").path))
    }

    func testRefusesAnExistingOutputUnlessForced() throws {
        let output = folder.appendingPathComponent("exists.fa")
        try Data("keep".utf8).write(to: output)
        XCTAssertThrowsError(try run(arguments(["--sequence=r1"], output: output))) { error in
            XCTAssertTrue(error is ViewerExportRefusal)
        }
        XCTAssertEqual(try String(contentsOf: output, encoding: .utf8), "keep")
        _ = try run(arguments(["--sequence=r1", "--force"], output: output))
        XCTAssertEqual(try String(contentsOf: output, encoding: .utf8), ">r1 first record\nACGTACGT\nACGT\n")
        XCTAssertEqual(try Self.envelope(of: output).options.explicit["force"], .boolean(true))
    }

    /// The options that would be dropped, or that say two things, are refused before the leaf starts.
    func testOptionConflictsAreRefusedBeforeTheLeafStarts() throws {
        let output = folder.appendingPathComponent("conflict.fa")
        let selection = try writeSelection(["r1"])
        let refused: [(name: String, arguments: [String])] = [
            ("a region with --sequence", ["extract", "sequence", source.path, "r1:1-4", "--sequence=r1", "-o", output.path]),
            ("neither a region nor a name", ["extract", "sequence", source.path, "-o", output.path]),
            ("--sequence with --selection", arguments(["--sequence=r1", "--selection", selection.path], output: output)),
            ("a bundle option", arguments(["--sequence=r1", "--no-samples"], output: output)),
            ("a bundle output", arguments(["--sequence=r1"], output: folder.appendingPathComponent("out.lungfishref"))),
            ("a flank", arguments(["--sequence=r1", "--flank", "5"], output: output)),
            ("no output file", ["extract", "sequence", source.path, "--sequence=r1"]),
        ]
        for item in refused {
            let leaf = try command(item.arguments)
            XCTAssertThrowsError(try leaf.validateRecordsRun(), item.name) { error in
                XCTAssertTrue(error is CLIError, "\(item.name): \(error)")
            }
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
    }

    // MARK: - The command line

    /// ARCH ruling G2 section 5. The arguments the begin helper builds parse through the root into the command,
    /// whose canonical argv is the executable name and the same array, for the selection form and the name form.
    func testTheLeafParsesTheGUIArguments() throws {
        let selection = try writeSelection(["r1"])
        let forSelection = FASTARecordsExport.invocation(
            sourceURL: source, selectionURL: selection, outputURL: folder.appendingPathComponent("gui one.fa"), force: true
        )
        let leaf = try command(forSelection.arguments())
        XCTAssertEqual(leaf.recordsInvocation(), forSelection)
        XCTAssertEqual(leaf.recordsInvocation().canonicalArgv(), [CLICommandIdentity.executableName] + forSelection.arguments())
        XCTAssertEqual(Array(forSelection.arguments().prefix(2)), FASTARecordsExport.commandPath)
        XCTAssertEqual(ExtractSequenceSubcommand.configuration.commandName, FASTARecordsExport.commandPath[1])
        XCTAssertNil(leaf.regionArgument)
        XCTAssertTrue(leaf.force)
        XCTAssertEqual(leaf.globalOptions.outputFormat, .json, "the runner reads the leaf's events")

        let forNames = FASTARecordsExport.invocation(
            sourceURL: source, sequences: ["-dash", "with space", "r1"],
            outputURL: folder.appendingPathComponent("gui two.fa"), force: false
        )
        let named = try command(forNames.arguments())
        XCTAssertEqual(named.sequenceNames, ["-dash", "with space", "r1"])
        XCTAssertEqual(named.recordsInvocation(), forNames)
    }

    /// A run with a region keeps its parse and its words.
    func testARegionRunKeepsItsArguments() throws {
        let leaf = try command(["extract", "sequence", source.path, "r1:1-4"])
        XCTAssertEqual(leaf.regionArgument, "r1:1-4")
        XCTAssertEqual(leaf.region, "r1:1-4")
        XCTAssertTrue(leaf.sequenceNames.isEmpty)
        XCTAssertNil(leaf.selection)
    }
}
