// RNASeqExportCommandTests.swift - `lungfish-cli rnaseq export` (Phase 5.1 lane RS-HANDOFF)
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// The family's cases (`docs/contracts/SCOPE-AND-DELIVERY.md`, Tests per family). The recorded argv parses to equal options,
// a replay of the recorded command gives files of equal sha256 but the record, and a refusal writes nothing. The cancel
// case with a real SIGTERM is `RNASeqExportSIGTERMTests` of the continuation, and `RNASeqExportFolderTests` covers the
// cancel of the folder writer itself.

import ArgumentParser
import CryptoKit
import Foundation
import XCTest
import LungfishIO
import LungfishTestSupport
@testable import LungfishCLI
@testable import LungfishWorkflow

final class RNASeqExportCommandTests: XCTestCase {
    private var root: URL!
    private var analyses: URL!

    override func setUpWithError() throws {
        root = try TestTempDirectory.make(prefix: "rnaseq-export-cli")
        analyses = root.appendingPathComponent("Analyses", isDirectory: true)
        try FileManager.default.createDirectory(at: analyses, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { TestTempDirectory.cleanup(root) }

    private static let salmonRoute = RNASeqResultManifest.Route(id: "salmon-reads", tool: "salmon", toolVersion: "2.11.0", settings: ["input": "reads"])
    private let salmon = RNASeqExportCommandTests.salmonRoute

    private func result(_ name: String, route: RNASeqResultManifest.Route, samples: [String], groups: [String: String] = [:]) throws -> URL {
        try Self.makeResult(name, route: route, samples: samples, groups: groups, in: root)
    }

    /// A result of three host genes made by RS-KIND's writer under `root/Analyses`, which the transcript capture and
    /// the SIGTERM test share.
    static func makeResult(
        _ name: String, route: RNASeqResultManifest.Route = salmonRoute, samples: [String], groups: [String: String] = [:], in root: URL
    ) throws -> URL {
        let set = RNASeqResultManifest.ReferenceSet(id: "human-lge-1", layout: .lge)
        let analyses = root.appendingPathComponent("Analyses", isDirectory: true)
        try FileManager.default.createDirectory(at: analyses, withIntermediateDirectories: true)
        let genes = ["G1", "G2", "G3"]
        let scratch = root.appendingPathComponent("inputs-\(name)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        let geneFile = scratch.appendingPathComponent("genes.tsv")
        let text = "gene_id\tname\tbiotype\tcontig\tlength\tnot_host\tmask\tunreliable\n" + genes.map { "\($0)\t\($0)\tprotein_coding\tchr1\t900\tfalse\t\t\n" }.joined()
        try text.write(to: geneFile, atomically: true, encoding: .utf8)
        let rows = genes.enumerated().map { gene, id in RNASeqCountTable.Row(id: id, counts: samples.indices.map { Double(20 * (gene + 1) + $0) }) }
        let request = RNASeqResultWriter.Request(
            name: name, modality: .bulk, origin: .init(kind: .quantified), route: route, referenceSet: set,
            samples: samples.map { RNASeqSampleRecord(id: $0, group: groups[$0], runs: [$0]) },
            genes: .referenceSetTable(url: geneFile, keeping: genes),
            counts: [.init(rows: .gene, column: .default, unit: .estimated, table: RNASeqCountTable(sampleIDs: samples, rows: rows))],
            sourceFiles: [], notHost: [])
        let url = analyses.appendingPathComponent("\(name).lungfishrnaseq", isDirectory: true)
        let envelope = ProvenanceEnvelope(workflowName: "RNA-seq quantification", toolName: "lungfish-cli", toolVersion: "test")
        try RNASeqResultWriter(provenanceWriter: ProvenanceWriter(signingProvider: nil)).write(request, to: url, envelope: envelope)
        return url
    }

    private func arguments(_ results: [URL], output: URL, extra: [String] = []) -> [String] {
        results.map(\.path) + ["--output", output.path] + extra + ["--quiet"]
    }

    private func hashes(_ folder: URL) throws -> [String: String] {
        var all: [String: String] = [:]
        for name in try FileManager.default.contentsOfDirectory(atPath: folder.path) where name != ".lungfish-provenance.json" {
            all[name] = SHA256.hash(data: try Data(contentsOf: folder.appendingPathComponent(name))).map { String(format: "%02x", $0) }.joined()
        }
        return all
    }

    private func twoResults() throws -> [URL] {
        [try result("a", route: salmon, samples: ["S1", "S2"], groups: ["S1": "TB", "S2": "HIV"]),
         try result("b", route: salmon, samples: ["S3", "S4"], groups: ["S3": "TB", "S4": "HIV"])]
    }

    private let extra = ["--design", "group", "--contrast", "group:TB:HIV", "--padj-cutoff", "0.05", "--lfc-bar", "1.4"]

    func testTheRecordedArgvParsesToEqualOptions() async throws {
        let out = root.appendingPathComponent("export1", isDirectory: true)
        let command = try RNASeqExportSubcommand.parse(arguments(try twoResults(), output: out, extra: extra))
        try await command.run()
        let record = try XCTUnwrap(try ProvenanceEnvelopeReader.loadCanonical(from: out))
        XCTAssertEqual(Array(record.argv.prefix(3)), ["lungfish-cli", "rnaseq", "export"])
        let reparsed = try RNASeqExportSubcommand.parse(Array(record.argv.dropFirst(3)))
        XCTAssertEqual(reparsed.canonicalArgv(), record.argv)
        XCTAssertEqual(reparsed.settings(), command.settings())
    }

    func testAReplayOfTheRecordedCommandGivesFilesOfEqualSha256ButTheRecord() async throws {
        let first = root.appendingPathComponent("export1", isDirectory: true)
        let second = root.appendingPathComponent("export2", isDirectory: true)
        try await RNASeqExportSubcommand.parse(arguments(try twoResults(), output: first, extra: extra)).run()
        var argv = Array(try XCTUnwrap(try ProvenanceEnvelopeReader.loadCanonical(from: first)).argv.dropFirst(3))
        argv[try XCTUnwrap(argv.firstIndex(of: "--output")) + 1] = second.path
        try await RNASeqExportSubcommand.parse(argv + ["--quiet"]).run()
        XCTAssertEqual(try hashes(second), try hashes(first))
        XCTAssertFalse(try hashes(first).isEmpty)
    }

    func testAMixOfRoutesExitsWithTheInputCodeAndWritesNothing() async throws {
        let other = RNASeqResultManifest.Route(id: "star-salmon", tool: "salmon", toolVersion: "2.11.0", settings: ["flag": "-a"])
        let a = try result("a", route: salmon, samples: ["S1", "S2"])
        let c = try result("c", route: other, samples: ["U1", "U2", "U3"])
        let out = root.appendingPathComponent("export1", isDirectory: true)
        do {
            try await RNASeqExportSubcommand.parse(arguments([a, c], output: out)).run()
            XCTFail("a table of two routes was exported")
        } catch let code as ExitCode {
            XCTAssertEqual(code, CLIExitCode.inputError.exitCode)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: out.path))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path).filter { $0.hasPrefix(".") }, [])
    }

    /// The same call parses with no flag, so each throw below is the unknown flag, never the missing result path (SWIFT S-1).
    func testNoFlagOverridesTheRefusal() throws {
        let a = try result("a", route: salmon, samples: ["S1", "S2"])
        let out = root.appendingPathComponent("export1", isDirectory: true)
        XCTAssertNoThrow(try RNASeqExportSubcommand.parse(arguments([a], output: out)), "the same call parses with no flag")
        for flag in ["--allow-mixed-routes", "--force", "--ignore-route"] {
            XCTAssertThrowsError(try RNASeqExportSubcommand.parse(arguments([a], output: out, extra: [flag])), flag)
        }
    }
}
