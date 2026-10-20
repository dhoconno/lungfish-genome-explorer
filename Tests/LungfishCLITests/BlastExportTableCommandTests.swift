// BlastExportTableCommandTests.swift - lungfish-cli blast export table
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.12 lane 12.33, ARCH ruling T5 and BIO 6. The leaf reads the file the BLAST drawer's result came from, a
// `blast submit` record or an archive file, in that order. It writes the builder's bytes, names only that file with
// its digest, says which form it was, refuses before any write, and parses the arguments the app's begin helper
// builds.

import ArgumentParser
import XCTest
@testable import LungfishCLI
@testable import LungfishCore
@testable import LungfishWorkflow

final class BlastExportTableCommandTests: XCTestCase {
    private var folder: URL!
    private var archiveFile: URL!
    private var submitRecord: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("BlastExportTable-\(UUID().uuidString)", isDirectory: true)
        let resultFolder = folder.appendingPathComponent("kraken2-run", isDirectory: true)
        try FileManager.default.createDirectory(at: resultFolder, withIntermediateDirectories: true)
        archiveFile = try BlastVerificationArchive.save(Self.verification, request: nil, in: resultFolder, toolName: "lungfish-cli", toolKind: "cli")
        let submitFolder = BlastVerificationArchive.directoryURL(for: resultFolder)
            .appendingPathComponent("Escherichia-coli-a", isDirectory: true)
        try FileManager.default.createDirectory(at: submitFolder, withIntermediateDirectories: true)
        submitRecord = submitFolder.appendingPathComponent(BlastSubmissionRecord.recordFileName)
        let request = BlastVerificationRequest(
            taxonName: "Escherichia coli", taxId: 562, sequences: [(id: "read,1", sequence: "ACGTACGTAC")],
            database: BlastDatabaseID.coreNT.rawValue
        )
        let record = BlastSubmissionRecord(
            savedAt: Date(timeIntervalSince1970: 1_790_000_060),
            query: .init(fileName: BlastSubmissionRecord.queryFileName, sha256: String(repeating: "0", count: 64), sequenceCount: 3),
            lineage: .init(sourceResult: "@/Analyses/kraken2-run", taxId: 562, subsampleCount: 3, subsampleSeed: 0),
            search: .init(request),
            result: Self.verification
        )
        try BlastSubmissionRecord.encoder.encode(record).write(to: submitRecord)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    /// A result with hits, a read with no hit and a quoted field, as the drawer's pin uses.
    private static var verification: BlastVerificationResult {
        let hits = [
            BlastHitSummary(
                rank: 1, accession: "NC_000001.1", organism: "Escherichia coli, strain \"K-12\"", taxId: 562,
                percentIdentity: 99.5, queryCoverage: 98.25, eValue: 1e-50, bitScore: 250.46, alignmentLength: 150
            ),
            BlastHitSummary(
                rank: 2, accession: "NC_000002.1", organism: nil, taxId: nil,
                percentIdentity: 90, queryCoverage: 80.126, eValue: 0.0, bitScore: 100.04, alignmentLength: 120
            ),
        ]
        return BlastVerificationResult(
            taxonName: "Escherichia coli",
            taxId: 562,
            readResults: [
                BlastReadResult(
                    id: "read,1", verdict: .verified, topHitOrganism: "Escherichia coli", topHitAccession: "NC_000001.1",
                    percentIdentity: 99.5, queryCoverage: 98.25, eValue: 1e-50, alignmentLength: 150, bitScore: 250.46,
                    topHits: hits, hasLCADisagreement: true, matchesQueriedTaxon: true
                ),
                BlastReadResult(id: "read_2", verdict: .unverified),
                BlastReadResult(
                    id: "read_3", verdict: .ambiguous, topHitOrganism: "Shigella", topHitAccession: "NC_000003.1",
                    percentIdentity: 88.126, queryCoverage: 70.5, eValue: 0.002, alignmentLength: 99, bitScore: 55.5
                ),
            ],
            submittedAt: Date(timeIntervalSince1970: 1_790_000_000),
            completedAt: Date(timeIntervalSince1970: 1_790_000_060),
            rid: "PIN-RID",
            blastProgram: "megablast",
            database: "core_nt"
        )
    }

    private func command(_ arguments: [String]) throws -> BlastCommand.ExportTableSubcommand {
        let parsed = try LungfishCLI.parseAsRoot(arguments)
        return try XCTUnwrap(parsed as? BlastCommand.ExportTableSubcommand)
    }

    private func leafArguments(_ input: URL, output: URL, format: String = "tsv", extra: [String] = []) -> [String] {
        ["blast", "export", "table", input.path] + extra + ["--output-format", format, "--output", output.path]
    }

    private static func envelope(of outputURL: URL) throws -> ProvenanceEnvelope {
        try XCTUnwrap(ProvenanceEnvelopeReader.load(fromSidecar: ProvenanceRecorder.fileSidecarURL(for: outputURL)))
    }

    private static func inputNames(_ envelope: ProvenanceEnvelope) -> [String] {
        envelope.files.filter { $0.role == .input }.map { URL(fileURLWithPath: $0.path).lastPathComponent }.sorted()
    }

    /// An archive file gives the builder's bytes, and the record names that file with its digest, the taxon and the
    /// search, and says the file is an archive.
    func testTheArchiveFormWritesTheBuilderBytesAndNamesTheFileItRead() throws {
        let output = folder.appendingPathComponent("archive.tsv")
        _ = try command(leafArguments(archiveFile, output: output)).export()
        XCTAssertEqual(
            try String(contentsOf: output, encoding: .utf8),
            BlastVerificationTableExport.tableContent(result: Self.verification, separator: "\t")
        )
        let envelope = try Self.envelope(of: output)
        XCTAssertEqual(Self.inputNames(envelope), [archiveFile.lastPathComponent])
        XCTAssertTrue(envelope.files.filter { $0.role == .input }.allSatisfy { $0.checksumSHA256 != nil })
        let resolved = envelope.options.resolvedDefaults
        XCTAssertEqual(
            Set(resolved.keys),
            ["database", "inputKind", "outputByteCount", "program", "rid", "taxId", "taxonName", "totalReads"]
        )
        XCTAssertEqual(resolved["inputKind"]?.stringValue, "blast-verification-archive")
        XCTAssertEqual(resolved["rid"]?.stringValue, "PIN-RID")
        XCTAssertEqual(resolved["taxonName"]?.stringValue, "Escherichia coli")
        XCTAssertEqual(Set(envelope.options.explicit.keys), ["outputFormat", "outputPath"])
    }

    /// An archive record needs only a version, a date and a result, so it would also decode a `blast-result.json`.
    /// The leaf decodes the submit record first and says so.
    func testABlastSubmitRecordIsNeverReadAsAnArchive() throws {
        let output = folder.appendingPathComponent("submit.tsv")
        _ = try command(leafArguments(submitRecord, output: output)).export()
        let envelope = try Self.envelope(of: output)
        XCTAssertEqual(envelope.options.resolvedDefaults["inputKind"]?.stringValue, "blast-submit-record")
        XCTAssertEqual(Self.inputNames(envelope), [BlastSubmissionRecord.recordFileName])
        XCTAssertEqual(
            try String(contentsOf: output, encoding: .utf8),
            BlastVerificationTableExport.tableContent(result: Self.verification, separator: "\t")
        )
    }

    /// CSV quotes the fields that hold a comma or a quote, and force is an explicit option only when given.
    func testCSVQuotesTheFieldsThatNeedIt() throws {
        let output = folder.appendingPathComponent("hits.csv")
        try Data("old".utf8).write(to: output)
        _ = try command(leafArguments(submitRecord, output: output, format: "csv", extra: ["--force"])).export()
        let text = try String(contentsOf: output, encoding: .utf8)
        XCTAssertEqual(text, BlastVerificationTableExport.tableContent(result: Self.verification, separator: ","))
        XCTAssertTrue(text.contains("\"read,1\""))
        XCTAssertTrue(text.contains("\"Escherichia coli, strain \"\"K-12\"\"\""))
        let envelope = try Self.envelope(of: output)
        XCTAssertEqual(Set(envelope.options.explicit.keys), ["force", "outputFormat", "outputPath"])
    }

    func testRecordNamesTheLeafAndItsCanonicalArgv() throws {
        let output = folder.appendingPathComponent("record.csv")
        let arguments = ["blast", "export", "table", submitRecord.path, "--output-format", "csv", "--output", output.path]
        _ = try command(arguments).export()
        let envelope = try Self.envelope(of: output)
        XCTAssertEqual(envelope.tool.name, "lungfish-cli")
        XCTAssertEqual(envelope.tool.kind, "cli")
        XCTAssertEqual(envelope.workflowName, "lungfish blast export table")
        XCTAssertEqual(envelope.argv, ["lungfish-cli"] + arguments)
        XCTAssertEqual(envelope.durableReplayArgv, envelope.argv)
    }

    /// Each refusal comes before any write (exit 3), a file of neither form is named for both, and `--force` never
    /// lets the output replace its input.
    func testRefusalsComeBeforeAnyWrite() throws {
        let exists = folder.appendingPathComponent("exists.tsv")
        try Data("keep".utf8).write(to: exists)
        XCTAssertThrowsError(try command(leafArguments(submitRecord, output: exists)).export()) { error in
            XCTAssertTrue(error is ViewerExportRefusal, "\(error)")
        }
        XCTAssertEqual(try String(contentsOf: exists, encoding: .utf8), "keep")
        _ = try command(leafArguments(submitRecord, output: exists, extra: ["--force"])).export()
        XCTAssertNotEqual(try String(contentsOf: exists, encoding: .utf8), "keep")

        try assertRefused(folder.appendingPathComponent("missing.json"))
        try assertRefused(folder)
        let neither = folder.appendingPathComponent("neither.json")
        try Data("{\"schemaVersion\": 1}".utf8).write(to: neither)
        let output = folder.appendingPathComponent("neither.tsv")
        XCTAssertThrowsError(try command(leafArguments(neither, output: output)).export()) { error in
            XCTAssertTrue(error is ViewerExportRefusal, "\(error)")
            let words = "\(error) \(error.localizedDescription)"
            XCTAssertTrue(words.contains("blast-result.json"), words)
            XCTAssertTrue(words.contains("verification archive"), words)
        }

        let before = try Data(contentsOf: submitRecord)
        XCTAssertThrowsError(try command(leafArguments(submitRecord, output: submitRecord, extra: ["--force"])).export()) { error in
            XCTAssertTrue(error is ViewerExportRefusal, "\(error)")
        }
        XCTAssertEqual(try Data(contentsOf: submitRecord), before)
    }

    private func assertRefused(_ input: URL, line: UInt = #line) throws {
        let output = folder.appendingPathComponent("refused-\(UUID().uuidString).tsv")
        XCTAssertThrowsError(try command(leafArguments(input, output: output)).export(), line: line) { error in
            XCTAssertTrue(error is ViewerExportRefusal, "\(error)", line: line)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path), line: line)
        XCTAssertFalse(FileManager.default.fileExists(atPath: ProvenanceRecorder.fileSidecarURL(for: output).path), line: line)
    }

    /// ARCH ruling G2 section 5. The arguments the begin helper builds parse through the root into the leaf, whose
    /// canonical argv is the executable name and the same array.
    func testBlastTableLeafParsesTheGUIArguments() throws {
        let invocation = BlastVerificationTableExport.invocation(
            recordURL: submitRecord,
            format: .csv,
            outputURL: folder.appendingPathComponent("gui.csv"),
            force: true
        )
        let arguments = invocation.arguments()
        let leaf = try command(arguments)
        XCTAssertEqual(leaf.invocation(), invocation)
        XCTAssertEqual(leaf.invocation().canonicalArgv(), [CLICommandIdentity.executableName] + arguments)
        XCTAssertEqual(Array(arguments.prefix(3)), BlastVerificationTableExport.commandPath)
        XCTAssertEqual(BlastCommand.ExportTableSubcommand.configuration.commandName, BlastVerificationTableExport.commandPath.last)
    }

    func testBlastTableLeafRefusesAnOptionItDoesNotTake() {
        let output = folder.appendingPathComponent("refuse.tsv")
        XCTAssertThrowsError(try command(leafArguments(submitRecord, output: output, extra: ["--separator", "tsv"])))
        XCTAssertThrowsError(try command(leafArguments(submitRecord, output: output, extra: ["--sample", "sample-A"])))
    }
}
