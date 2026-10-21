// BlastSubmitCommandTests.swift - The record facts `blast submit` writes for each viewer site
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import ArgumentParser
import CryptoKit
import Foundation
import LungfishWorkflow
import XCTest
@testable import LungfishCLI
@testable import LungfishCore

/// Phase 2.11 lane A65 M1 (plan decision C1, BIO conditions 1 to 3 and check 6). For the lineage
/// each of the seven viewer sites will pass in M2 and M3, the leaf copies the query into its own
/// result folder, names the copy's SHA-256, and records the lineage in `blast-result.json` and in
/// the provenance options. No test here reaches the network: the result comes from a canned answer.
final class BlastSubmitCommandTests: XCTestCase {
    static let reads: [(id: String, sequence: String)] = [
        (id: "read_1", sequence: "ACGTACGTAC"), (id: "read_2", sequence: "GGCCTTAAGG"),
    ]

    /// The lineage options of each site, by its gap id.
    static let siteLineage: [(gapID: String, options: [String])] = [
        ("blast-nao-mgs", ["--source-result", "/p/naomgs-1", "--sample", "S1", "--taxid", "11320",
                           "--subsample-count", "20", "--entrez-query", "txid11320[Organism:exp]"]),
        ("blast-nvd", ["--source-result", "/p/nvd-1", "--sample", "S1", "--contig", "NODE_1_length_900", "--taxid", "11320"]),
        ("blast-esviritu", ["--source-result", "/p/esviritu-1", "--sample", "S1", "--taxid", "11320",
                            "--subsample-count", "20", "--subsample-seed", "7", "--accepted-taxid", "11320"]),
        ("blast-taxtriage", ["--source-result", "/p/taxtriage-1", "--sample", "S1", "--taxid", "11320",
                             "--subsample-count", "20", "--accepted-name", "Influenza A virus"]),
        ("blast-12s-unresolved", ["--source-result", "/p/12s-1", "--sample", "S1"]),
        ("blast-assembly", ["--source-result", "/p/assembly-1", "--contig", "contig_7"]),
        ("blast-fasta-selection", ["--source-result", "/p/genome.lungfishref"]),
    ]

    private var scratch: URL!

    override func setUpWithError() throws {
        scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("blast-submit-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: scratch)
    }

    func testAQueryTheSitesWriteParsesBackToTheSameBytes() throws {
        let request = BlastVerificationRequest(taxonName: "t", taxId: 0, sequences: Self.reads)
        let text = request.toMultiFASTA() + "\n"
        let parsed = BlastCommand.SubmitSubcommand.parseFASTA(Data(text.utf8))
        let again = BlastVerificationRequest(taxonName: "t", taxId: 0, sequences: parsed)
        XCTAssertEqual(again.toMultiFASTA(), request.toMultiFASTA())
        XCTAssertEqual(BlastCommand.SubmitSubcommand.parseFASTA(Data(">a b c\nAC GT\r\nTT\n>\n>empty\n".utf8)).map(\.id), ["a b c"])
    }

    func testEachSiteRecordsItsQueryDigestAndLineage() async throws {
        for site in Self.siteLineage {
            let folder = scratch.appendingPathComponent(site.gapID, isDirectory: true)
            let queryBytes = Data((BlastVerificationRequest(taxonName: "t", taxId: 0, sequences: Self.reads).toMultiFASTA() + "\n").utf8)
            let queryURL = scratch.appendingPathComponent("\(site.gapID).fasta")
            try queryBytes.write(to: queryURL)
            let output = folder.appendingPathComponent("result", isDirectory: true)
            let command = try XCTUnwrap(
                BlastCommand.parseAsRoot(["submit", "--query", queryURL.path, "--output", output.path, "--name", site.gapID] + site.options)
                    as? BlastCommand.SubmitSubcommand, site.gapID)
            let staged = try command.stageQuery(into: output)
            let request = command.makeRequest(sequences: staged.sequences)
            let result = try await Self.cannedResult(for: request)
            let recordURL = try command.writeRecord(result: result, request: request, query: staged, in: output, runClock: ProvenanceRunClock())

            let digest = SHA256.hash(data: queryBytes).map { String(format: "%02x", $0) }.joined()
            let copy = output.appendingPathComponent("query.fasta")
            XCTAssertEqual(try Data(contentsOf: copy), queryBytes, "\(site.gapID) keeps the query in its result folder")
            let record = try BlastSubmissionRecord.load(recordURL)
            XCTAssertEqual(record.query, .init(fileName: "query.fasta", sha256: digest, sequenceCount: 2), site.gapID)
            XCTAssertEqual(record.lineage, Self.expectedLineage(site.options), site.gapID)
            XCTAssertEqual(record.search.entrezQuery, Self.value(of: "--entrez-query", in: site.options), site.gapID)
            XCTAssertEqual(record.result.totalReads, 2, site.gapID)

            let sidecar = URL(fileURLWithPath: recordURL.path + ".lungfish-provenance.json")
            let envelope = try XCTUnwrap(try ProvenanceEnvelopeReader.load(fromSidecar: sidecar), site.gapID)
            XCTAssertEqual(envelope.status.rawValue, "completed", site.gapID)
            XCTAssertEqual(envelope.toolName, CLICommandIdentity.executableName, site.gapID)
            XCTAssertEqual(envelope.tool.name, CLICommandIdentity.executableName, site.gapID)
            XCTAssertEqual(envelope.tool.kind, CLICommandIdentity.recordedToolKind, site.gapID)
            let sidecarText = try String(contentsOf: sidecar, encoding: .utf8)
            XCTAssertTrue(sidecarText.contains(digest), "\(site.gapID) provenance names the query digest")
            XCTAssertTrue(sidecarText.contains("blast submit"), "\(site.gapID) provenance names the command")
        }
    }

    func testAFolderThatHoldsAResultIsRefusedAndNoTextReachesArgv() throws {
        let queryURL = scratch.appendingPathComponent("q.fasta")
        try Data(">r\nACGT\n".utf8).write(to: queryURL)
        let output = scratch.appendingPathComponent("out", isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: output.appendingPathComponent("blast-result.json"))
        let command = try XCTUnwrap(
            BlastCommand.parseAsRoot(["submit", "--query", queryURL.path, "--output", output.path]) as? BlastCommand.SubmitSubcommand)
        XCTAssertThrowsError(try command.stageQuery(into: output))
        XCTAssertFalse(command.recordedCommandLine().contains { $0.contains("ACGT") })
        XCTAssertThrowsError(try BlastCommand.parseAsRoot(["submit", "--query", "q", "--output", "o", "--subsample-count", "0"]))
    }

    // MARK: - Helpers

    static func value(of option: String, in options: [String]) -> String? {
        guard let index = options.firstIndex(of: option), options.indices.contains(index + 1) else { return nil }
        return options[index + 1]
    }

    static func expectedLineage(_ options: [String]) -> BlastSubmissionRecord.Lineage {
        BlastSubmissionRecord.Lineage(
            sourceResult: value(of: "--source-result", in: options),
            sample: value(of: "--sample", in: options),
            taxId: value(of: "--taxid", in: options).flatMap { Int($0) },
            contig: value(of: "--contig", in: options),
            subsampleCount: value(of: "--subsample-count", in: options).flatMap { Int($0) },
            subsampleSeed: value(of: "--subsample-seed", in: options).flatMap { UInt64($0) }
        )
    }

    /// A JSON2 answer with no hit for either read, the shape NCBI returns.
    static let json2NoHits = Data("""
    {"BlastOutput2": [\
    {"report": {"program": "blastn", "version": "BLASTN 2.16.0+", "results": {"search": {"query_title": "read_1", "query_len": 10, "hits": []}}}}, \
    {"report": {"program": "blastn", "version": "BLASTN 2.16.0+", "results": {"search": {"query_title": "read_2", "query_len": 10, "hits": []}}}}]}
    """.utf8)

    static func cannedResult(for request: BlastVerificationRequest) async throws -> BlastVerificationResult {
        let service = BlastService()
        let searchResults = try await service.parseJSON2Results(json2NoHits)
        return try service.buildVerificationResult(
            request: request, searchResults: searchResults, rid: "STANDIN1", submittedAt: Date(), completedAt: Date()
        )
    }
}
