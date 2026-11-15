// RNASeqPseudobulkCommandTests.swift - `lungfish-cli rnaseq pseudobulk` (Phase 5.2 lane RS-PSEUDOBULK)
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// The family's cases (`docs/contracts/SCOPE-AND-DELIVERY.md`, Tests per family). The recorded argv parses to equal options,
// a replay of the recorded command gives files of equal sha256 but the record, a refusal writes nothing, and the export
// reads the new result. The manifest of a replay differs only in its name and date. The cancel case with a real SIGTERM
// is `RNASeqPseudobulkSIGTERMTests`.

import ArgumentParser
import CryptoKit
import Foundation
import XCTest
import LungfishIO
import LungfishTestSupport
@testable import LungfishCLI
@testable import LungfishWorkflow

final class RNASeqPseudobulkCommandTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws { root = try TestTempDirectory.make(prefix: "rnaseq-pseudobulk-cli") }
    override func tearDownWithError() throws { TestTempDirectory.cleanup(root) }

    static let labels = RNASeqFixtures.root.appendingPathComponent("pseudobulk-pbmc_1k_v3/labels-starsolo.tsv")

    /// The STARsolo cut as a single-cell result under `root/Analyses`, written by the one writer, which the SIGTERM test
    /// and the transcript capture share.
    static func makeSingleCellResult(in root: URL) throws -> URL {
        let analyses = root.appendingPathComponent("Analyses", isDirectory: true)
        try FileManager.default.createDirectory(at: analyses, withIntermediateDirectories: true)
        let folder = try SingleCellFolderReader.read(folder: RNASeqFixtures.root.appendingPathComponent("starsolo-pbmc_1k_v3", isDirectory: true))
        let samples = [RNASeqSampleRecord(id: folder.sample, animal: "A1", species: "Homo sapiens", runs: [folder.sample])]
        let request = try SingleCellFolderReader.request([folder], name: "cells", samples: samples, genomes: [])
        let url = analyses.appendingPathComponent("cells.lungfishrnaseq", isDirectory: true)
        let envelope = ProvenanceEnvelope(workflowName: "RNA-seq import", toolName: "lungfish-cli", toolVersion: "test")
        return try RNASeqResultWriter(provenanceWriter: ProvenanceWriter(signingProvider: nil)).write(request, to: url, envelope: envelope)
    }

    private func output(_ name: String) -> URL {
        root.appendingPathComponent("Analyses/\(name).lungfishrnaseq", isDirectory: true)
    }

    private func arguments(_ result: URL, labels: URL = labels, output: URL) -> [String] {
        [result.path, "--labels", labels.path, "--output", output.path, "--quiet"]
    }

    private func sha256(_ url: URL) throws -> String {
        SHA256.hash(data: try Data(contentsOf: url)).map { String(format: "%02x", $0) }.joined()
    }

    private static let tables = ["samples.tsv", "genes.tsv", "counts/genes.counts.tsv"]

    func testTheRecordedArgvParsesToEqualOptions() async throws {
        let out = output("pb1")
        let command = try RNASeqPseudobulkSubcommand.parse(arguments(try Self.makeSingleCellResult(in: root), output: out))
        try await command.run()
        let record = try XCTUnwrap(try ProvenanceEnvelopeReader.loadCanonical(from: out))
        XCTAssertEqual(Array(record.argv.prefix(3)), ["lungfish-cli", "rnaseq", "pseudobulk"])
        let reparsed = try RNASeqPseudobulkSubcommand.parse(Array(record.argv.dropFirst(3)))
        XCTAssertEqual(reparsed.canonicalArgv(), record.argv)
        XCTAssertEqual(reparsed.canonicalArgv(), command.canonicalArgv())
        XCTAssertEqual(record.options.resolvedDefaults["labelTableSHA256"], .string(try sha256(Self.labels)))
        XCTAssertEqual(record.options.resolvedDefaults["minimumCells"], .integer(10))
        guard case .array(let dropped)? = record.options.resolvedDefaults["groupsLeftOut"], case .dictionary(let group)? = dropped.first else {
            return XCTFail("the record lists no group left out")
        }
        XCTAssertEqual(group["words"], .string("Group starsolo-pbmc_1k_v3 nine holds 9 cells, under 10, and is left out."))
    }

    func testAReplayOfTheRecordedCommandGivesFilesOfEqualSha256ButTheRecord() async throws {
        let first = output("pb1")
        let second = output("pb2")
        try await RNASeqPseudobulkSubcommand.parse(arguments(try Self.makeSingleCellResult(in: root), output: first)).run()
        var argv = Array(try XCTUnwrap(try ProvenanceEnvelopeReader.loadCanonical(from: first)).argv.dropFirst(3))
        argv[try XCTUnwrap(argv.firstIndex(of: "--output")) + 1] = second.path
        try await RNASeqPseudobulkSubcommand.parse(argv + ["--quiet"]).run()
        for table in Self.tables {
            XCTAssertEqual(try sha256(second.appendingPathComponent(table)), try sha256(first.appendingPathComponent(table)), table)
        }
        var manifest = try RNASeqResultBundle.loadManifest(from: second)
        let original = try RNASeqResultBundle.loadManifest(from: first)
        manifest.name = original.name
        manifest.createdAt = original.createdAt
        XCTAssertEqual(manifest, original, "the manifest differs only in its name and date")
    }

    func testARefusalExitsWithTheInputCodeAndWritesNothing() async throws {
        let result = try Self.makeSingleCellResult(in: root)
        let labels = root.appendingPathComponent("stray.tsv")
        try "barcode\tlabel\nNOTACELL\tT\n".write(to: labels, atomically: true, encoding: .utf8)
        let out = output("pb1")
        for (table, what) in [(labels, "a barcode the result does not hold"), (Self.labels, "a bulk result")] {
            let input = what == "a bulk result" ? try RNASeqExportCommandTests.makeResult("bulk", samples: ["S1"], in: root) : result
            do {
                try await RNASeqPseudobulkSubcommand.parse(arguments(input, labels: table, output: out)).run()
                XCTFail("\(what) was summed")
            } catch let code as ExitCode {
                XCTAssertEqual(code, CLIExitCode.inputError.exitCode, what)
            }
            XCTAssertFalse(FileManager.default.fileExists(atPath: out.path), what)
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: out.deletingLastPathComponent().path).filter { $0.hasPrefix(".") }, [], what)
        }
    }

    func testAnExistingOutputIsRefusedAndKept() async throws {
        let result = try Self.makeSingleCellResult(in: root)
        do {
            try await RNASeqPseudobulkSubcommand.parse(arguments(result, output: result)).run()
            XCTFail("the result was written over")
        } catch let code as ExitCode {
            XCTAssertEqual(code, CLIExitCode.inputError.exitCode)
        }
        XCTAssertEqual(try RNASeqResultBundle.loadManifest(from: result).modality, .singleCell)
    }

    /// `rnaseq export` of the new result writes its table as `counts.tsv`, with no export file changed by this lane.
    func testTheExportOfThePseudobulkResultWritesItsTableAsCounts() async throws {
        let out = output("pb1")
        try await RNASeqPseudobulkSubcommand.parse(arguments(try Self.makeSingleCellResult(in: root), output: out)).run()
        let export = root.appendingPathComponent("export", isDirectory: true)
        try await RNASeqExportSubcommand.parse([out.path, "--output", export.path, "--quiet"]).run()
        let counts = try RNASeqCountTable(tsv: Data(contentsOf: export.appendingPathComponent("counts.tsv")), path: "counts.tsv")
        let table = try RNASeqCountTable(tsv: Data(contentsOf: out.appendingPathComponent("counts/genes.counts.tsv")), path: "genes.counts.tsv")
        XCTAssertEqual(counts, table)
        XCTAssertEqual(counts.sampleIDs, ["B", "T", "ten"].map { "starsolo-pbmc_1k_v3_\($0)" })
        let samples = try String(contentsOf: export.appendingPathComponent("samples.tsv"), encoding: .utf8)
        XCTAssertTrue(samples.contains("starsolo-pbmc_1k_v3_ten\tA1\tHomo sapiens\t\tten\t"), samples)
    }

    // MARK: - The record signs when a key is set

    /// Runs `body` with `LUNGFISH_PROVENANCE_SIGNING_KEY_FILE` naming a throwaway key under `root`, and puts the two signing
    /// variables back afterwards. It is the helper of `CancelledRunRecordsPinReplayTests`, made async for the leaf.
    private func withThrowawayKey<T>(_ body: () async throws -> T) async throws -> T {
        let keyFile = root.appendingPathComponent("signing-key.txt")
        try "pseudobulk-pin-throwaway-\(UUID().uuidString)\n".write(to: keyFile, atomically: true, encoding: .utf8)
        let keyName = ProvenanceSigningConfiguration.signingKeyEnvironmentKey
        let fileName = ProvenanceSigningConfiguration.signingKeyFileEnvironmentKey
        let saved = [keyName, fileName].map { ($0, ProcessInfo.processInfo.environment[$0]) }
        unsetenv(keyName)
        setenv(fileName, keyFile.path, 1)
        defer {
            for (name, value) in saved {
                if let value { setenv(name, value, 1) } else { unsetenv(name) }
            }
        }
        return try await body()
    }

    /// The leaf builds `ProvenanceWriter()`, which signs when a key is set, and the writer renames its stage whole, so the
    /// signature beside the record keeps verifying (docs/contracts/RECORDING-PROVENANCE.md, "A result's own record signs when
    /// a key is set"). The case follows `RNASeqQuantSigningReplayTests`: a throwaway key, a signature and a public key beside
    /// the record, `provenance verify` on it, then on a copy with one digit edited, which must not verify, and on an
    /// unedited copy checked the same way, which must. The leaf signs already, so this pin cannot fail first (review
    /// RS-PSEUDOBULK SWIFT, fix SF2).
    func testTheRecordSignsAndVerifiesWhenAKeyIsSet() async throws {
        let result = try Self.makeSingleCellResult(in: root)
        let out = output("pb1")
        try await withThrowawayKey {
            try await RNASeqPseudobulkSubcommand.parse(arguments(result, output: out)).run()
        }
        let record = out.appendingPathComponent(ProvenanceWriter.provenanceFilename)
        let signature = ProvenanceSigningConfiguration.signatureURL(for: record)
        let publicKey = ProvenanceSigningConfiguration.publicKeyURL(for: record)
        XCTAssertTrue(FileManager.default.fileExists(atPath: record.path), "no record at \(record.path)")
        XCTAssertTrue(FileManager.default.fileExists(atPath: signature.path), "the record has no signature though a key is set")
        XCTAssertTrue(FileManager.default.fileExists(atPath: publicKey.path), "the record has no public key though a key is set")
        try await ProvenanceCommand.VerifySubcommand.parse([out.path]).run()

        let text = try String(contentsOf: record, encoding: .utf8)
        let digit = try XCTUnwrap(text.firstIndex { $0.isASCII && $0.isNumber }, "the record holds no digit")
        var edited = text
        edited.replaceSubrange(digit...digit, with: String(((text[digit].wholeNumberValue ?? 0) + 1) % 10))
        let tampered = root.appendingPathComponent("tampered", isDirectory: true).appendingPathComponent(record.lastPathComponent)
        let control = root.appendingPathComponent("control", isDirectory: true).appendingPathComponent(record.lastPathComponent)
        for copy in [tampered, control] {
            try FileManager.default.createDirectory(at: copy.deletingLastPathComponent(), withIntermediateDirectories: true)
        }
        try edited.write(to: tampered, atomically: true, encoding: .utf8)
        try FileManager.default.copyItem(at: record, to: control)
        let against = ["--signature", signature.path, "--public-key", publicKey.path]
        try await ProvenanceCommand.VerifySubcommand.parse([control.path] + against).run()
        do {
            try await ProvenanceCommand.VerifySubcommand.parse([tampered.path] + against).run()
            XCTFail("a copy of the record with one digit edited still verifies")
        } catch {
            // The verifier refuses the edited copy, as it must.
        }
    }
}
