// RNASeqPseudobulkTests.swift - The pseudobulk pass on the pbmc_1k_v3 cuts and its refusals (Phase 5.2 lane RS-PSEUDOBULK)
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// The pins are the tables `scripts/repro/rnaseq/gse183579/pseudobulk_check.py` wrote from the matrix text of each cut
// with the fixture's label table (`Tests/Fixtures/rnaseq/README.md`, row pseudobulk-pbmc_1k_v3), and the cut's own UMI
// totals, 212,629 for STARsolo and 212,733 for Cell Ranger. One label holds 9 cells and one 10.

import CryptoKit
import XCTest
import LungfishIO
import LungfishTestSupport
@testable import LungfishWorkflow

final class RNASeqPseudobulkTests: XCTestCase {
    var root: URL!

    override func setUpWithError() throws { root = try TestTempDirectory.make(prefix: "rnaseq-pseudobulk") }
    override func tearDownWithError() throws { TestTempDirectory.cleanup(root) }

    static let fixture = RNASeqFixtures.root.appendingPathComponent("pseudobulk-pbmc_1k_v3", isDirectory: true)
    static let starsolo = RNASeqFixtures.root.appendingPathComponent("starsolo-pbmc_1k_v3", isDirectory: true)
    static let cellRanger = RNASeqFixtures.root.appendingPathComponent("cellranger-pbmc_1k_v3/outs", isDirectory: true)

    /// A single-cell result of `folders` written by the one writer, each sample of animal `A<n>`.
    static func singleCellResult(_ folders: [URL], name: String = "cells", in root: URL) throws -> URL {
        let read = try folders.map { try SingleCellFolderReader.read(folder: $0) }
        let samples = read.enumerated().map { RNASeqSampleRecord(id: $1.sample, animal: "A\($0 + 1)", species: "Homo sapiens", origin: "blood", runs: [$1.sample]) }
        let request = try SingleCellFolderReader.request(read, name: name, samples: samples, genomes: [])
        let url = root.appendingPathComponent("\(name).lungfishrnaseq", isDirectory: true)
        let envelope = ProvenanceEnvelope(workflowName: "RNA-seq import", toolName: "lungfish-cli", toolVersion: "test")
        return try RNASeqResultWriter(provenanceWriter: ProvenanceWriter(signingProvider: nil)).write(request, to: url, envelope: envelope)
    }

    /// A copy of the STARsolo cut under `name`, so a result can hold two samples.
    static func starsoloCopy(_ name: String, in root: URL) throws -> URL {
        let copy = root.appendingPathComponent("runs/\(name)", isDirectory: true)
        try FileManager.default.createDirectory(at: copy.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: starsolo, to: copy)
        return copy
    }

    func table(_ text: String, _ name: String = "labels.tsv") throws -> URL {
        let url = root.appendingPathComponent(name)
        try text.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    func sum(_ result: URL, _ labels: URL) throws -> RNASeqPseudobulk.Outcome {
        try RNASeqPseudobulk.sum(result: result, labels: labels, name: "pb")
    }

    func write(_ outcome: RNASeqPseudobulk.Outcome) throws -> URL {
        let url = root.appendingPathComponent("pb.lungfishrnaseq", isDirectory: true)
        let envelope = ProvenanceEnvelope(workflowName: "RNA-seq pseudobulk", toolName: "lungfish-cli", toolVersion: "test")
        return try RNASeqResultWriter(provenanceWriter: ProvenanceWriter(signingProvider: nil)).write(outcome.request, to: url, envelope: envelope)
    }

    func sha256(_ url: URL) throws -> String {
        SHA256.hash(data: try Data(contentsOf: url)).map { String(format: "%02x", $0) }.joined()
    }

    func refusal(_ result: URL, _ labels: URL, file: StaticString = #filePath, line: UInt = #line) -> String? {
        do {
            _ = try sum(result, labels)
            XCTFail("the table was summed", file: file, line: line)
            return nil
        } catch {
            XCTAssertTrue(error is RNASeqPseudobulkRefusal, "\(error)", file: file, line: line)
            return (error as? LocalizedError)?.errorDescription
        }
    }
}

extension RNASeqPseudobulkTests {
    /// Each cut, its sample, the expected table's sha256 and the cut's UMIs.
    private static let cuts: [(folder: URL, sample: String, labels: String, expected: String, sha256: String, umis: UInt64)] = [
        (starsolo, "starsolo-pbmc_1k_v3", "labels-starsolo.tsv", "expected-starsolo.tsv",
         "b221b9e088aa9df571de9a3e76d3c6164b4cd67ffaf2029f0e8fde533d0a48ff", 212_629),
        (cellRanger, "cellranger-pbmc_1k_v3", "labels-cellranger.tsv", "expected-cellranger.tsv",
         "40e1a77ad01eca2a4594c14dec51828542c8acee9d22136090249066055ae6c7", 212_733),
    ]

    func testEachCutSumsToTheIndependentTableByteForByte() throws {
        for cut in Self.cuts {
            let result = try Self.singleCellResult([cut.folder], name: cut.sample, in: root)
            let outcome = try sum(result, Self.fixture.appendingPathComponent(cut.labels))
            let written = try write(outcome)
            let expected = Self.fixture.appendingPathComponent(cut.expected)
            XCTAssertEqual(try sha256(expected), cut.sha256, "the committed table is the script's")
            XCTAssertEqual(try Data(contentsOf: written.appendingPathComponent("counts/genes.counts.tsv")), try Data(contentsOf: expected), cut.sample)
            try FileManager.default.removeItem(at: written)
        }
    }

    /// Swift reads "\r\n" as one Character, so a label table that a Windows tool or Excel saved with CRLF was read as one line
    /// and refused with "no label column". The sums of the CRLF copy have to equal the sums of the LF table (CM-IMPORT BIO, backlog 1).
    func testACrLfLabelTableSumsLikeItsLfCopy() throws {
        let result = try Self.singleCellResult([Self.starsolo], name: "solo", in: root)
        let labels = Self.fixture.appendingPathComponent("labels-starsolo.tsv")
        let text = try String(contentsOf: labels, encoding: .utf8)
        XCTAssertFalse(text.contains("\r"), "the committed label table ends its lines with LF")
        let crlf = try table(text.replacingOccurrences(of: "\n", with: "\r\n"), "labels-crlf.tsv")
        var sums: [Data] = []
        for given in [labels, crlf] {
            let written = try write(try sum(result, given))
            sums.append(try Data(contentsOf: written.appendingPathComponent("counts/genes.counts.tsv")))
            try FileManager.default.removeItem(at: written)
        }
        XCTAssertEqual(sums[1], sums[0], "a label table with CRLF line ends sums like its LF copy")
    }

    func testTheNineCellGroupIsLeftOutWithItsWordsAndTheTenCellGroupIsKept() throws {
        for cut in Self.cuts {
            let result = try Self.singleCellResult([cut.folder], name: cut.sample, in: root)
            let outcome = try sum(result, Self.fixture.appendingPathComponent(cut.labels))
            XCTAssertEqual(outcome.kept.map(\.label), ["B", "T", "ten"], "code-point order of the labels")
            XCTAssertEqual(outcome.kept.map(\.cells), [51, 100, 10])
            XCTAssertEqual(outcome.kept.map(\.column), ["B", "T", "ten"].map { "\(cut.sample)_\($0)" })
            XCTAssertEqual(outcome.dropped.map(\.label), ["nine"])
            XCTAssertEqual(outcome.dropped.map(\.cells), [9])
            XCTAssertEqual(outcome.unlabelled.map(\.cells), [30])
            XCTAssertEqual(outcome.notes, [
                "Group \(cut.sample) nine holds 9 cells, under 10, and is left out.",
                "30 cells of sample \(cut.sample) have no label and are left out.",
            ])
            let total = outcome.kept.reduce(0) { $0 + $1.umis } + outcome.dropped.reduce(0) { $0 + $1.umis }
                + outcome.unlabelled.reduce(0) { $0 + $1.umis }
            XCTAssertEqual(total, cut.umis, "kept, dropped and unlabelled add up to the cut's UMIs")
            try FileManager.default.removeItem(at: result)
        }
    }

    func testTheResultCarriesTheAnimalTheLabelAsGroupTheRouteSettingAndTheRecordFacts() throws {
        let result = try Self.singleCellResult([Self.starsolo], name: "solo", in: root)
        let outcome = try sum(result, Self.fixture.appendingPathComponent("labels-starsolo.tsv"))
        let loaded = try RNASeqResultBundle.load(from: try write(outcome))
        let source = try RNASeqResultBundle.loadManifest(from: result)
        XCTAssertEqual(loaded.manifest.modality, .bulk)
        XCTAssertEqual(loaded.manifest.origin, .init(kind: .pseudobulk, tool: source.origin.tool, toolVersion: source.origin.toolVersion))
        var route = source.route
        route.settings[RNASeqPseudobulk.routeSetting] = RNASeqPseudobulk.routeSettingValue
        XCTAssertEqual(loaded.manifest.route, route)
        XCTAssertEqual(loaded.manifest.referenceSet, source.referenceSet)
        XCTAssertEqual(loaded.manifest.counts.map(\.unit), [.umis])
        XCTAssertEqual(loaded.manifest.sourceFiles, [])
        XCTAssertEqual(loaded.samples.map(\.group), ["B", "T", "ten"])
        XCTAssertEqual(Set(loaded.samples.compactMap(\.animal)), ["A1"])
        XCTAssertEqual(Set(loaded.samples.compactMap(\.species)), ["Homo sapiens"])
        XCTAssertEqual(loaded.genes.count, 1_353)
        XCTAssertEqual(outcome.facts["singleCellManifestSHA256"], .string(try sha256(RNASeqResultBundle.manifestURL(in: result))))
        XCTAssertEqual(outcome.facts["labelTableSHA256"], .string("b3f8a4c3dbf48b7f6acc155ba717491343652b1374c065feb8a7f55afcfcaa6f"))
        XCTAssertEqual(outcome.facts["minimumCells"], .integer(10))
        XCTAssertEqual(outcome.facts["featureTypesLeftOut"], .dictionary([:]))
    }
}
