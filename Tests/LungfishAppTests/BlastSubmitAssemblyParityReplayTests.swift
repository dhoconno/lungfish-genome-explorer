// BlastSubmitAssemblyParityReplayTests.swift - The assembly contig BLAST in the app against blast submit
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.11 lane A65 M2, the sides of BlastSubmitParity.swift. The assembly viewer searches the selected
// contigs, and side C keeps the search under `blast-verifications/` of the assembly's folder, as
// `blast verify --result-dir` keeps its output. The class launches the built lungfish-cli against a
// loopback stand-in, so its name ends in ReplayTests, which sends it to the integration tier.

import Foundation
import XCTest
@testable import LungfishApp
import LungfishCore
import LungfishKitTestSupport
import LungfishTestSupport

@MainActor
final class BlastSubmitAssemblyParityReplayTests: XCTestCase {
    private var scratch: URL!
    private var server: LoopbackHTTPStandIn!
    private var saved: ProcessEnvironmentOverride?
    private var harness: RouteParityHarness!

    override func setUpWithError() throws {
        scratch = try TestTempDirectory.make(prefix: "blast-assembly-parity")
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

    func testTheContigSearchSendsWhatTheInProcessSearchSentAndKeepsItsResult() async throws {
        try await BlastSubmitParity.assertParity(
            harness: harness, server: server,
            in: scratch.appendingPathComponent("parity", isDirectory: true),
            resultsParent: { $0.appendingPathComponent(Self.assemblyPath, isDirectory: true) },
            fixture: Self.makeProject,
            oracle: { await BlastSubmitParity.inProcessSearch(Self.inProcessRequest(), server: self.server) },
            sideC: { root in await BlastSubmitParity.sideC(root, cli: self.harness.cliBinary, plan: Self.plan, begin: Self.begin) }
        )
    }

    func testTheContigSearchRecordIsSignedAndVerifies() async throws {
        try await BlastSubmitParity.assertSignedRecordVerifies(
            harness: harness, in: scratch.appendingPathComponent("signed", isDirectory: true),
            resultsParent: { $0.appendingPathComponent(Self.assemblyPath, isDirectory: true) },
            fixture: Self.makeProject,
            sideC: { root in await BlastSubmitParity.sideC(root, cli: self.harness.cliBinary, plan: Self.plan, begin: Self.begin) }
        )
    }

    // MARK: - The site

    /// The assembly's folder, relative to a side root.
    nonisolated static let assemblyPath = "Project.lungfish/Analyses/spades-2026-10-17"
    private static let sourceLabel = "2 contigs"
    private static let taxId = 11320
    /// The contigs the viewer hands its BLAST action, one FASTA record each.
    private static let contigs = [">contig_1 length=20 cov=12.5\nACGTACGTAC\nGTACGTACGT", ">contig_2\nGGCCTTAAGGCCTTAAGGCC"]

    private static func makeProject(_ root: URL) throws {
        let assembly = root.appendingPathComponent(assemblyPath, isDirectory: true)
        try FileManager.default.createDirectory(at: assembly, withIntermediateDirectories: true)
        try Data((contigs.joined(separator: "\n") + "\n").utf8).write(to: assembly.appendingPathComponent("contigs.fasta"))
    }

    /// The request of the in-process route, as the viewer built it before the route moved.
    private static func inProcessRequest() -> BlastVerificationRequest {
        BlastVerificationRequest(
            taxonName: sourceLabel, taxId: taxId, sequences: ViewerViewController.blastSequences(from: contigs),
            database: BlastDatabaseID.coreNT.rawValue, entrezQuery: nil
        )
    }

    private static func plan(_ root: URL) throws -> BlastSubmitPlan {
        try ViewerViewController.assemblyBlastSubmitPlan(
            sourceLabel: sourceLabel, taxId: taxId, fastaRecords: contigs,
            resultURL: root.appendingPathComponent(assemblyPath, isDirectory: true)
        )
    }

    private static func begin(_ command: String, _ reporter: RecordingOperationReporter) {
        ViewerViewController.beginAssemblyContigBlastVerificationOperation(
            sourceLabel: sourceLabel, cliCommand: command, reporter: reporter
        ) { _ in }
    }
}
