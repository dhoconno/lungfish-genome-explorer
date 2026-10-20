// BlastSubmitTaxTriageParityReplayTests.swift - The TaxTriage organism BLAST in the app against blast submit
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.12 lane 12.09 (A65-M3b) and 2.13 lane 13.02, the sides of BlastSubmitParity.swift. The TaxTriage viewer
// draws a subsample of the reads of the selected accessions, with the mixed strategy and seed 0, and judges hits on the
// request `TaxTriageOrganism.blastVerificationRequest` builds. The oracle is that request searched in this process, as
// the viewer searched it before the route moved (the hidden key that kept that route left in 2.13), and C against C'
// declares nothing. The reads stand in for the BAM extraction the site runs before it plans. The class launches the
// built lungfish-cli against a loopback stand-in, so its name ends in ReplayTests, which sends it to the integration
// tier.

import Foundation
import XCTest
@testable import LungfishApp
import LungfishCore
import LungfishIO
import LungfishKitTestSupport
import LungfishTestSupport

@MainActor
final class BlastSubmitTaxTriageParityReplayTests: XCTestCase {
    private var scratch: URL!
    private var server: LoopbackHTTPStandIn!
    private var saved: ProcessEnvironmentOverride?
    private var harness: RouteParityHarness!

    override func setUpWithError() throws {
        scratch = try TestTempDirectory.make(prefix: "blast-taxtriage-parity")
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

    func testTheOrganismSearchSendsWhatTheInProcessSearchSentAndKeepsItsResult() async throws {
        try await BlastSubmitParity.assertParity(
            harness: harness, server: server,
            in: scratch.appendingPathComponent("parity", isDirectory: true),
            resultsParent: { BlastSubmitParity.project(in: $0) },
            fixture: Self.makeProject,
            oracle: { await BlastSubmitParity.inProcessSearch(Self.inProcessRequest(), server: self.server) },
            sideC: { root in await BlastSubmitParity.sideC(root, cli: self.harness.cliBinary, plan: Self.plan, begin: Self.begin) }
        )
    }

    func testTheOrganismSearchRecordIsSignedAndVerifies() async throws {
        try await BlastSubmitParity.assertSignedRecordVerifies(
            harness: harness, in: scratch.appendingPathComponent("signed", isDirectory: true),
            resultsParent: { BlastSubmitParity.project(in: $0) },
            fixture: Self.makeProject,
            sideC: { root in await BlastSubmitParity.sideC(root, cli: self.harness.cliBinary, plan: Self.plan, begin: Self.begin) }
        )
    }

    func testSIGTERMCancelsTheOrganismSearchInsideTheGrace() async throws {
        let root = scratch.appendingPathComponent("cancel", isDirectory: true)
        try Self.makeProject(root)
        try await BlastSubmitParity.assertSIGTERMCancels(try Self.plan(root), server: server, testClass: Self.self)
    }

    // MARK: - The site

    private static let organism = TaxTriageOrganism(
        name: "Influenza A virus", score: 0.9, reads: 100, coverage: 50, taxId: 11320, rank: "species", sample: "S1"
    )
    /// The count the viewer asks for, below the three reads, so the subsample draws.
    private static let readCount = 2
    /// Three reads of the selected accession, as the BAM extraction gives them.
    private static let reads: [(id: String, sequence: String)] = [
        (id: "read_1", sequence: "ACGTACGTACGTACGTACGT"), (id: "read_2", sequence: "GGCCTTAAGGCCTTAAGGCC"),
        (id: "read_3", sequence: "TTTTGGGGCCCCAAAATTTT"),
    ]

    /// The TaxTriage result the reads came from, relative to a side root.
    private static let sourcePath = "Project.lungfish/Analyses/taxtriage-flu-run"

    private static func makeProject(_ root: URL) throws {
        let source = root.appendingPathComponent(sourcePath, isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try Data("{}\n".utf8).write(to: source.appendingPathComponent("manifest.json"))
    }

    /// The draw and the request of the in-process route, the request built by the LungfishIO builder the viewer
    /// calls.
    private static func inProcessRequest() -> BlastVerificationRequest {
        let longest = min(5, readCount / 4)
        let subsampled = BlastService(environment: [:]).subsampleReads(
            from: reads, strategy: .mixed(longest: longest, random: readCount - longest)
        )
        return organism.blastVerificationRequest(sequences: subsampled)
    }

    private static func plan(_ root: URL) throws -> BlastSubmitPlan {
        try ViewerViewController.taxTriageBlastSubmitPlan(
            organism: organism, reads: reads, readCount: readCount, accessions: ["NC_026438.1"],
            projectURL: BlastSubmitParity.project(in: root), sourceResultURL: root.appendingPathComponent(sourcePath, isDirectory: true)
        )
    }

    private static func begin(_ command: String, _ reporter: RecordingOperationReporter) {
        ViewerViewController.beginTaxTriageBlastVerificationOperation(
            taxonName: organism.name, cliCommand: command, reporter: reporter
        ) { _ in }
    }
}
