// BlastSubmitKraken2ParityReplayTests.swift - The Kraken2 taxon BLAST in the app against blast submit
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.12 lane 12.10 (A65-P50) and 2.13 lane 13.02, the sides of BlastSubmitParity.swift. The Kraken2 row looks up
// the taxon's reads in every source file of the result (`kraken2BlastVerificationRequest`, review ruling 6) and judges
// hits on the clade and its genus relatives. The lookup runs once, on a copy of the fixture outside the side roots, and
// the oracle and both sides search its request. The oracle is that request searched in this process, as the row
// searched it before the route moved (the hidden key that kept that route left in 2.13). Side C is the site's plan, and
// C against C' declares nothing. The class launches the built lungfish-cli against a loopback stand-in, so its name
// ends in ReplayTests, which sends it to the integration tier.

import Foundation
import XCTest
@testable import LungfishApp
import LungfishCore
import LungfishIO
import LungfishKitTestSupport
import LungfishTestSupport
import LungfishWorkflow

@MainActor
final class BlastSubmitKraken2ParityReplayTests: XCTestCase {
    private var scratch: URL!
    private var server: LoopbackHTTPStandIn!
    private var saved: ProcessEnvironmentOverride?
    private var harness: RouteParityHarness!

    override func setUpWithError() throws {
        scratch = try TestTempDirectory.make(prefix: "blast-kraken2-parity")
        server = try BlastSubmitParity.standIn()
        saved = ProcessEnvironmentOverride(
            set: [BlastSubmitParity.standInVariable: server.baseURL.absoluteString], unset: ["NCBI_API_KEY"]
        )
        harness = BlastSubmitParity.harness(cli: try BlastSubmitParity.cli(for: Self.self), server: server)
    }

    override func tearDownWithError() throws {
        saved?.restore()
        server?.stop()
        TestTempDirectory.cleanup(scratch)
    }

    func testTheTaxonSearchSendsWhatTheInProcessSearchSentAndKeepsItsResult() async throws {
        let request = try await lookedUpRequest()
        try await BlastSubmitParity.assertParity(
            harness: harness, server: server,
            in: scratch.appendingPathComponent("parity", isDirectory: true),
            resultsParent: { $0.appendingPathComponent(Self.resultPath, isDirectory: true) },
            fixture: Self.makeProject,
            oracle: { await BlastSubmitParity.inProcessSearch(request, server: self.server) },
            sideC: { root in
                let outcome = await BlastSubmitParity.sideC(
                    root, cli: self.harness.cliBinary, plan: { try Self.plan(request, $0) }, begin: Self.begin
                )
                Self.assertRecordFacts(under: root)
                return outcome
            }
        )
    }

    func testTheTaxonSearchRecordIsSignedAndVerifies() async throws {
        let request = try await lookedUpRequest()
        try await BlastSubmitParity.assertSignedRecordVerifies(
            harness: harness, in: scratch.appendingPathComponent("signed", isDirectory: true),
            resultsParent: { $0.appendingPathComponent(Self.resultPath, isDirectory: true) },
            fixture: Self.makeProject,
            sideC: { root in
                await BlastSubmitParity.sideC(root, cli: self.harness.cliBinary, plan: { try Self.plan(request, $0) }, begin: Self.begin)
            }
        )
    }

    func testSIGTERMCancelsTheTaxonSearchInsideTheGrace() async throws {
        let request = try await lookedUpRequest()
        let root = scratch.appendingPathComponent("cancel", isDirectory: true)
        try Self.makeProject(root)
        try await BlastSubmitParity.assertSIGTERMCancels(try Self.plan(request, root), server: server, testClass: Self.self)
    }

    // MARK: - The site

    private static let taxonName = "Escherichia coli"
    /// The Kraken2 result, relative to a side root.
    private nonisolated static let resultPath = "Project.lungfish/Analyses/kraken2-run"
    private static let readsPath = "Project.lungfish/Imports/reads.fastq"

    /// The reads are named `read_1` and `read_2`, the queries the stand-in's JSON2 answer names.
    private static func makeProject(_ root: URL) throws {
        let result = root.appendingPathComponent(resultPath, isDirectory: true)
        let reads = root.appendingPathComponent(readsPath)
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: result, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: reads.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("""
        100.00\t2\t0\tR\t1\troot
        100.00\t2\t0\tG\t561\t  Escherichia
        100.00\t2\t2\tS\t562\t    Escherichia coli

        """.utf8).write(to: result.appendingPathComponent("classification.kreport"))
        try Data("C\tread_1\t562\t20\t562:20\nC\tread_2\t562\t20\t562:20\n".utf8)
            .write(to: result.appendingPathComponent("classification.kraken"))
        try Data("@read_1\nACGTACGTACGTACGTACGT\n+\nIIIIIIIIIIIIIIIIIIII\n@read_2\nGGCCTTAAGGCCTTAAGGCC\n+\nIIIIIIIIIIIIIIIIIIII\n".utf8)
            .write(to: reads)
    }

    /// The request the row's read lookup builds, run once on a fixture outside the side roots.
    private func lookedUpRequest() async throws -> BlastVerificationRequest {
        let root = scratch.appendingPathComponent("lookup", isDirectory: true)
        try Self.makeProject(root)
        let result = root.appendingPathComponent(Self.resultPath, isDirectory: true)
        let request = try await ViewerViewController.kraken2BlastLookup(
            taxonName: Self.taxonName, taxId: 562,
            tree: try KreportParser.parse(url: result.appendingPathComponent("classification.kreport")),
            classificationOutput: result.appendingPathComponent("classification.kraken"),
            sourceInputs: [root.appendingPathComponent(Self.readsPath)], readCount: 2
        )
        XCTAssertEqual(request.sequences.map(\.id).sorted(), ["read_1", "read_2"])
        XCTAssertTrue(request.acceptedTaxIds.contains(562))
        return request
    }

    private static func plan(_ request: BlastVerificationRequest, _ root: URL) throws -> BlastSubmitPlan {
        try ViewerViewController.kraken2BlastSubmitPlan(
            request: request, projectURL: BlastSubmitParity.project(in: root),
            resultDirectory: root.appendingPathComponent(resultPath, isDirectory: true)
        )
    }

    /// What the leaf recorded for the taxon search (BIO 3, 4 and 6).
    private static func assertRecordFacts(under root: URL) {
        let sidecar = BlastSubmitParity.record(under: root.appendingPathComponent(resultPath, isDirectory: true))
        let recordURL = sidecar.deletingLastPathComponent().appendingPathComponent(BlastSubmissionRecord.recordFileName)
        guard let record = try? BlastSubmissionRecord.load(recordURL) else {
            return XCTFail("side C left no readable \(recordURL.lastPathComponent)")
        }
        XCTAssertEqual(record.search.database, "nt", "the search keeps the in-process row's database")
        XCTAssertEqual(record.lineage.taxId, 562)
        XCTAssertEqual(record.lineage.sourceResult, "@/Analyses/kraken2-run")
        XCTAssertEqual(record.lineage.subsampleCount, 2)
        XCTAssertEqual(record.lineage.subsampleSeed, 0)
        XCTAssertEqual(record.query.sequenceCount, 2)
        let argv = (try? ProvenanceEnvelopeReader.load(fromSidecar: sidecar))?.argv ?? []
        let flag = argv.firstIndex(of: "--database")
        XCTAssertEqual(flag.flatMap { argv.indices.contains($0 + 1) ? argv[$0 + 1] : nil }, "nt", "the recorded argv names the database")
    }

    private static func begin(_ command: String, _ reporter: RecordingOperationReporter) {
        ViewerViewController.beginKraken2BlastVerificationOperation(taxonName: taxonName, cliCommand: command, reporter: reporter) { _ in }
    }
}
