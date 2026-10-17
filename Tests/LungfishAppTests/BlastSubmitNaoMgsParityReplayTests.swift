// BlastSubmitNaoMgsParityReplayTests.swift - The NAO-MGS taxon BLAST in the app against blast submit
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.11 lane A65 M2, the sides of BlastSubmitParity.swift. The NAO-MGS viewer searches a subsample of
// a taxon's reads, drawn with the seed 0 the in-process route used, with the taxon's Entrez filter. The
// class launches the built lungfish-cli against a loopback stand-in, so its name ends in ReplayTests, which
// sends it to the integration tier.

import Foundation
import XCTest
@testable import LungfishApp
import LungfishCore
import LungfishIO
import LungfishKitTestSupport
import LungfishTestSupport

@MainActor
final class BlastSubmitNaoMgsParityReplayTests: XCTestCase {
    /// The files only side C writes, under the project and never in the NAO-MGS result folder the search names.
    static let declared = BlastSubmitParity.declared(stageFiles: 2, resultFiles: 3, resultsParent: "Project.lungfish")

    private var scratch: URL!
    private var server: LoopbackHTTPStandIn!
    private var saved: ProcessEnvironmentOverride?
    private var harness: RouteParityHarness!

    override func setUpWithError() throws {
        scratch = try TestTempDirectory.make(prefix: "blast-nao-mgs-parity")
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
        try await BlastSubmitParity.assertParity(
            harness: harness, server: server, declared: Self.declared,
            in: scratch.appendingPathComponent("parity", isDirectory: true),
            fixture: Self.makeProject,
            sideA: { _ in await BlastSubmitParity.sideA(Self.inProcessRequest(), server: self.server) },
            sideC: { root in await BlastSubmitParity.sideC(root, cli: self.harness.cliBinary, plan: Self.plan, begin: Self.begin) }
        )
    }

    func testTheTaxonSearchRecordIsSignedAndVerifies() async throws {
        try await BlastSubmitParity.assertSignedRecordVerifies(
            harness: harness, in: scratch.appendingPathComponent("signed", isDirectory: true),
            resultsParent: { BlastSubmitParity.project(in: $0) },
            fixture: Self.makeProject,
            sideA: { _ in await BlastSubmitParity.sideA(Self.inProcessRequest(), server: self.server) },
            sideC: { root in await BlastSubmitParity.sideC(root, cli: self.harness.cliBinary, plan: Self.plan, begin: Self.begin) }
        )
    }

    // MARK: - The site

    private static let taxonName = "Influenza A virus"
    private static let taxId = 11320
    /// The count the viewer asks for, below the three reads, so the subsample draws.
    private static let readCount = 2

    /// Three reads of the taxon from two samples.
    private static let reads = [
        ("read_1", "S1", "ACGTACGTACGTACGTACGT"), ("read_2", "S2", "GGCCTTAAGGCCTTAAGGCC"), ("read_3", "S1", "TTTTGGGGCCCCAAAATTTT"),
    ].map { id, sample, bases in
        NaoMgsVirusHit(
            sample: sample, seqId: id, taxId: taxId, bestAlignmentScore: 40,
            cigar: "20M", queryStart: 0, queryEnd: 20, refStart: 0, refEnd: 20,
            readSequence: bases, readQuality: String(repeating: "I", count: 20),
            subjectSeqId: "NC_026438.1", subjectTitle: taxonName, bitScore: 40, eValue: 1e-5,
            percentIdentity: 100, editDistance: 0, fragmentLength: 20, isReverseComplement: false,
            pairStatus: "CP", queryLength: 20
        )
    }

    /// The NAO-MGS result folder the reads came from, relative to a side root. The viewer names it as the
    /// search's source result (review fix F2), and the search's folder still lands under the project.
    private static let sourcePath = "Project.lungfish/Analyses/naomgs-flu-run"

    private static func makeProject(_ root: URL) throws {
        let source = root.appendingPathComponent(sourcePath, isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try Data("{}\n".utf8).write(to: source.appendingPathComponent("manifest.json"))
    }

    /// The draw and the request of the in-process route, as the viewer built them before the route moved.
    private static func inProcessRequest() -> BlastVerificationRequest {
        let allReads = reads.map { (id: $0.seqId, sequence: $0.readSequence) }
        let longest = min(5, readCount / 4)
        let subsampled = BlastService(environment: [:]).subsampleReads(
            from: allReads, strategy: .mixed(longest: longest, random: readCount - longest)
        )
        return BlastVerificationRequest(
            taxonName: taxonName, taxId: taxId, sequences: subsampled, database: BlastDatabaseID.coreNT.rawValue,
            entrezQuery: "txid\(taxId)[Organism:exp]"
        )
    }

    private static func plan(_ root: URL) throws -> BlastSubmitPlan {
        try ViewerViewController.naoMgsBlastSubmitPlan(
            taxonName: taxonName, taxId: taxId, readCount: readCount, reads: reads, projectURL: BlastSubmitParity.project(in: root),
            sourceResultURL: root.appendingPathComponent(sourcePath, isDirectory: true)
        )
    }

    private static func begin(_ command: String, _ reporter: RecordingOperationReporter) {
        ViewerViewController.beginNaoMgsBlastVerificationOperation(
            taxonName: taxonName, taxId: taxId, cliCommand: command, reporter: reporter
        ) { _ in }
    }
}
