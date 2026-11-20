// RNASeqCellMapImportTests.swift - `lungfish-cli rnaseq cell-map import` on the 200-cell cuts (Phase 5.5 lane CM-IMPORT)
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// X1 of the plan. P1, the Cell Ranger cut with 10x's t-SNE and graph clusters, reads back exactly with no flag. P2, the
// STARsolo cut, needs `--barcode-suffix drop` and `--other-counts`, and then matches all 200. The counts of each label in
// total and for each sample, the record's facts, a replay of its command, the label table read by `rnaseq pseudobulk
// --labels`, and `provenance verify` on the record and on a copy with one digit edited.

import ArgumentParser
import CryptoKit
import Foundation
import SQLite3
import XCTest
import LungfishIO
import LungfishTestSupport
@testable import LungfishCLI
@testable import LungfishWorkflow

enum CellMapImportFixture {
    static let analysis = RNASeqFixtures.root.appendingPathComponent("tenx-analysis-pbmc_1k_v3/analysis", isDirectory: true)
    static let projection = analysis.appendingPathComponent("tsne/2_components/projection.csv")
    static let clusters = analysis.appendingPathComponent("clustering/graphclust/clusters.csv")
    static let starsolo = "starsolo-pbmc_1k_v3"
    static let cellRanger = "cellranger-pbmc_1k_v3/outs"
    /// The cells of each graph cluster of the cut, counted from `clusters.csv` by hand (CM-TRUTH `p1/cut200/graphclust-sizes.tsv`).
    static let clusterSizes = [32, 37, 36, 25, 28, 23, 19]

    /// A single-cell result named `name` of the cut `folder`, in `root/Analyses`, written by the one writer.
    static func result(_ folder: String, name: String = "cells", in root: URL) throws -> URL {
        let analyses = root.appendingPathComponent("Analyses", isDirectory: true)
        try FileManager.default.createDirectory(at: analyses, withIntermediateDirectories: true)
        let read = try SingleCellFolderReader.read(folder: RNASeqFixtures.root.appendingPathComponent(folder, isDirectory: true))
        let samples = [RNASeqSampleRecord(id: read.sample, animal: "A1", species: "Homo sapiens", runs: [read.sample])]
        let request = try SingleCellFolderReader.request([read], name: name, samples: samples, genomes: [])
        let url = analyses.appendingPathComponent("\(name).lungfishrnaseq", isDirectory: true)
        let envelope = ProvenanceEnvelope(workflowName: "RNA-seq import", toolName: "lungfish-cli", toolVersion: "test")
        return try RNASeqResultWriter(provenanceWriter: ProvenanceWriter(signingProvider: nil)).write(request, to: url, envelope: envelope)
    }

    /// The fields of each line of a 10x CSV after its first line.
    static func rows(_ url: URL) throws -> [[String]] {
        try String(contentsOf: url, encoding: .utf8).split(separator: "\n").dropFirst().map { $0.split(separator: ",").map(String.init) }
    }

    /// Each stored coordinate of embedding 1 as SQLite holds it, by dimension and the cell's barcode.
    static func coordinates(_ map: URL) throws -> [Int: [String: Double]] {
        var handle: OpaquePointer?
        guard sqlite3_open_v2(map.appendingPathComponent("cellmap.sqlite").path, &handle, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            throw XCTSkip("cellmap.sqlite does not open")
        }
        defer { sqlite3_close(handle) }
        var statement: OpaquePointer?
        let sql = "SELECT c.dimension, k.barcode, c.value FROM coordinates c JOIN cells k ON k.cell = c.cell WHERE c.embedding = 1"
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else { return [:] }
        defer { sqlite3_finalize(statement) }
        var values: [Int: [String: Double]] = [:]
        while sqlite3_step(statement) == SQLITE_ROW {
            let barcode = String(cString: sqlite3_column_text(statement, 1))
            values[Int(sqlite3_column_int(statement, 0)), default: [:]][barcode] = sqlite3_column_double(statement, 2)
        }
        return values
    }

    static func facts(_ map: URL) throws -> [String: ParameterValue] {
        try XCTUnwrap(try ProvenanceEnvelopeReader.loadCanonical(from: map)).options.resolvedDefaults
    }
}

final class RNASeqCellMapImportTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws { root = try TestTempDirectory.make(prefix: "rnaseq-cell-map-import") }
    override func tearDownWithError() throws { TestTempDirectory.cleanup(root) }

    private func output(_ name: String) -> URL { root.appendingPathComponent("Analyses/\(name).lungfishrnaseq", isDirectory: true) }

    private func arguments(_ result: URL, output: URL, _ more: [String] = []) -> [String] {
        [result.path, "--coordinates", CellMapImportFixture.projection.path, "--clusters", CellMapImportFixture.clusters.path] + more
            + ["--output", output.path, "--quiet"]
    }

    /// P1. On the Cell Ranger cut every one of the 200 cells holds the cut's t-SNE text as its Double and its cluster.
    func testP1TheCellRangerCutReadsBackExactlyWithNoFlag() async throws {
        let result = try CellMapImportFixture.result(CellMapImportFixture.cellRanger, in: root)
        let map = output("tsne")
        try await RNASeqCellMapImportSubcommand.parse(arguments(result, output: map)).run()
        let stored = try CellMapImportFixture.coordinates(map)
        let rows = try CellMapImportFixture.rows(CellMapImportFixture.projection)
        XCTAssertEqual(rows.count, 200)
        XCTAssertEqual(stored[1]?.count, 200)
        XCTAssertEqual(stored[2]?.count, 200)
        for row in rows {
            XCTAssertEqual(stored[1]?[row[0]], Double(row[1]), row[0])
            XCTAssertEqual(stored[2]?[row[0]], Double(row[2]), row[0])
        }
        let database = try RNASeqCellMapDatabase(url: map.appendingPathComponent("cellmap.sqlite"))
        let embedding = try XCTUnwrap(try database.embeddings().first)
        XCTAssertEqual([embedding.name, embedding.method, embedding.sourceFile], ["TSNE", "t-SNE", "source/1/projection.csv"])
        XCTAssertFalse(embedding.otherCounts)
        let set = try XCTUnwrap(try database.labelSets().first)
        XCTAssertEqual(set.name, "graphclust")
        let labelOf = Dictionary(try CellMapImportFixture.rows(CellMapImportFixture.clusters).map { ($0[0], $0[1]) }, uniquingKeysWith: { a, _ in a })
        let ids = try database.cellLabels(labelSet: set.labelSet)
        for cell in 1...200 {
            let barcode = try XCTUnwrap(try database.cell(id: cell)).barcode
            XCTAssertEqual(set.labels[Int(ids[cell - 1]) - 1].name, labelOf[barcode], barcode)
        }
        let facts = try CellMapImportFixture.facts(map)
        XCTAssertEqual(facts["choices"], .dictionary(["barcodeSuffix": .string("as given"), "barcodesNotHeld": .string("refused"),
                                                      "counts": .string("the parent's")]))
        XCTAssertEqual(facts["tool"], .string("Cell Ranger"))
        XCTAssertEqual(try RNASeqResultBundle.loadManifest(from: map).origin.tool, "Cell Ranger")
    }

    /// P2. The STARsolo cut refuses without the suffix flag in 5.5 I2's words with the count, and with `--barcode-suffix
    /// drop` and `--other-counts` matches all 200, and the record says computed on other counts.
    func testP2TheStarsoloCutNeedsTheSuffixFlagAndOtherCountsThenMatchesAll200() async throws {
        let result = try CellMapImportFixture.result(CellMapImportFixture.starsolo, in: root)
        let map = output("tsne")
        do {
            try await RNASeqCellMapImportSubcommand.parse(arguments(result, output: map)).run()
            XCTFail("bare barcodes matched barcodes that end in -1")
        } catch let code as ExitCode {
            XCTAssertEqual(code, CLIExitCode.inputError.exitCode)
        }
        let options = RNASeqCellMapImport.Options(parent: result, coordinates: [CellMapImportFixture.projection], clusters: [CellMapImportFixture.clusters])
        XCTAssertThrowsError(try RNASeqCellMapImport.check(options, output: map)) { error in
            XCTAssertEqual((error as? LocalizedError)?.errorDescription,
                           "No barcode of projection.csv matches sample starsolo-pbmc_1k_v3 as given, and 200 of its 200 barcodes would match with -1 dropped. "
                           + "LGE changes no barcode unless asked. To drop -1 from every given barcode, run again with --barcode-suffix drop.")
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: map.path))
        try await RNASeqCellMapImportSubcommand.parse(arguments(result, output: map, ["--barcode-suffix", "drop", "--other-counts"])).run()
        let stored = try CellMapImportFixture.coordinates(map)
        for row in try CellMapImportFixture.rows(CellMapImportFixture.projection) {
            XCTAssertEqual(stored[1]?[String(row[0].dropLast(2))], Double(row[1]), row[0])
            XCTAssertEqual(stored[2]?[String(row[0].dropLast(2))], Double(row[2]), row[0])
        }
        let database = try RNASeqCellMapDatabase(url: map.appendingPathComponent("cellmap.sqlite"))
        XCTAssertEqual(try database.embeddingCells().map { [$0.drawn, $0.leftOut] }, [[200, 0]])
        XCTAssertTrue(try XCTUnwrap(try database.embeddings().first).otherCounts)
        let facts = try CellMapImportFixture.facts(map)
        XCTAssertEqual(facts["choices"], .dictionary(["barcodeSuffix": .string("-1 dropped"), "barcodesNotHeld": .string("refused"),
                                                      "counts": .string("computed on other counts")]))
    }

    /// Each label's cells in total and for each sample, as written, and the label table that pseudobulk reads gives the
    /// same sums as a table of the same cells written by hand from 10x's clusters.csv.
    func testTheLabelCountsAndTheLabelTableThatPseudobulkReads() async throws {
        let result = try CellMapImportFixture.result(CellMapImportFixture.cellRanger, in: root)
        let map = output("tsne")
        try await RNASeqCellMapImportSubcommand.parse(arguments(result, output: map)).run()
        let set = try XCTUnwrap(try RNASeqCellMapDatabase(url: map.appendingPathComponent("cellmap.sqlite")).labelSets().first)
        XCTAssertEqual(set.labels.map(\.name), ["1", "2", "3", "4", "5", "6", "7"])
        XCTAssertEqual(set.labels.map(\.cells), CellMapImportFixture.clusterSizes)
        XCTAssertEqual(set.counts.map(\.cells), CellMapImportFixture.clusterSizes)
        XCTAssertEqual(set.samples.map { [$0.labelled, $0.unlabelled] }, [[200, 0]])

        let sample = try RNASeqCellsDatabase(url: result.appendingPathComponent(RNASeqCellsDatabase.filename)).samples()[0].name
        let byHand = root.appendingPathComponent("by-hand.tsv")
        let lines = try CellMapImportFixture.rows(CellMapImportFixture.clusters).map { "\(sample)\t\($0[0])\t\($0[1])\n" }
        try ("sample\tbarcode\tlabel\n" + lines.joined()).write(to: byHand, atomically: true, encoding: .utf8)
        XCTAssertEqual(try Data(contentsOf: map.appendingPathComponent("labels/graphclust.tsv")), try Data(contentsOf: byHand))
        let summed = output("clusters")
        try await RNASeqPseudobulkSubcommand.parse([result.path, "--labels", map.appendingPathComponent("labels/graphclust.tsv").path,
                                                    "--output", summed.path, "--quiet"]).run()
        let table = try RNASeqCountTable(tsv: Data(contentsOf: summed.appendingPathComponent("counts/genes.counts.tsv")), path: "genes.counts.tsv")
        XCTAssertEqual(table.sampleIDs, (1...7).map { "\(sample)_\($0)" })
    }

    func testTheRecordedArgvParsesToEqualOptionsAndAReplayGivesEqualFiles() async throws {
        let result = try CellMapImportFixture.result(CellMapImportFixture.starsolo, in: root)
        let first = output("tsne1")
        let command = try RNASeqCellMapImportSubcommand.parse(arguments(result, output: first, ["--barcode-suffix", "drop", "--other-counts",
                                                                                                 "--method", "TSNE=t-SNE", "--tool-version", "3.0.0"]))
        try await command.run()
        let record = try XCTUnwrap(try ProvenanceEnvelopeReader.loadCanonical(from: first))
        XCTAssertEqual(Array(record.argv.prefix(4)), ["lungfish-cli", "rnaseq", "cell-map", "import"])
        let reparsed = try RNASeqCellMapImportSubcommand.parse(Array(record.argv.dropFirst(4)))
        XCTAssertEqual(reparsed.canonicalArgv(), record.argv)
        XCTAssertEqual(reparsed.canonicalArgv(), command.canonicalArgv())
        let second = output("tsne2")
        var argv = Array(record.argv.dropFirst(4))
        argv[try XCTUnwrap(argv.firstIndex(of: "--output")) + 1] = second.path
        try await RNASeqCellMapImportSubcommand.parse(argv + ["--quiet"]).run()
        for file in ["samples.tsv", "genes.tsv", "labels/graphclust.tsv", "source/1/projection.csv", "source/2/clusters.csv"] {
            XCTAssertEqual(try Data(contentsOf: second.appendingPathComponent(file)), try Data(contentsOf: first.appendingPathComponent(file)), file)
        }
        let manifest = try RNASeqResultBundle.loadManifest(from: first)
        XCTAssertEqual(manifest.sourceFiles.map(\.path), ["source/1/projection.csv", "source/2/clusters.csv"])
        XCTAssertEqual(manifest.sourceFiles.map(\.sha256), try [CellMapImportFixture.projection, CellMapImportFixture.clusters].map {
            SHA256.hash(data: try Data(contentsOf: $0)).map { String(format: "%02x", $0) }.joined()
        })
        XCTAssertEqual(manifest.origin, .init(kind: .imported, tool: "Cell Ranger", toolVersion: "3.0.0"))
    }

    /// Runs `body` with a throwaway signing key, as `RNASeqPseudobulkCommandTests` does.
    private func withThrowawayKey<T>(_ body: () async throws -> T) async throws -> T {
        let keyFile = root.appendingPathComponent("signing-key.txt")
        try "cell-map-pin-throwaway-\(UUID().uuidString)\n".write(to: keyFile, atomically: true, encoding: .utf8)
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

    /// `provenance verify` passes on the cell map's record and fails on a copy with one digit edited, as
    /// `RNASeqPseudobulkCommandTests.testTheRecordSignsAndVerifiesWhenAKeyIsSet` does.
    func testTheRecordVerifiesAndACopyWithOneDigitEditedDoesNot() async throws {
        let result = try CellMapImportFixture.result(CellMapImportFixture.cellRanger, in: root)
        let map = output("tsne")
        try await withThrowawayKey { try await RNASeqCellMapImportSubcommand.parse(arguments(result, output: map)).run() }
        let record = map.appendingPathComponent(ProvenanceWriter.provenanceFilename)
        let signature = ProvenanceSigningConfiguration.signatureURL(for: record)
        let publicKey = ProvenanceSigningConfiguration.publicKeyURL(for: record)
        try await ProvenanceCommand.VerifySubcommand.parse([map.path]).run()
        let text = try String(contentsOf: record, encoding: .utf8)
        let digit = try XCTUnwrap(text.firstIndex { $0.isASCII && $0.isNumber })
        var edited = text
        edited.replaceSubrange(digit...digit, with: String(((text[digit].wholeNumberValue ?? 0) + 1) % 10))
        let tampered = root.appendingPathComponent("tampered", isDirectory: true).appendingPathComponent(record.lastPathComponent)
        let control = root.appendingPathComponent("control", isDirectory: true).appendingPathComponent(record.lastPathComponent)
        for copy in [tampered, control] { try FileManager.default.createDirectory(at: copy.deletingLastPathComponent(), withIntermediateDirectories: true) }
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
