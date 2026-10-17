// BlastSubmitFastaSelectionParityReplayTests.swift - The FASTA selection BLAST in the app against blast submit
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.11 lane A65 M2, the sides of BlastSubmitParity.swift. The FASTA viewer searches the selected
// sequences of a file, and side C keeps the search under the project's `blast-verifications/`, never in
// the file's folder or a bundle, with the file named as its source. The class launches the built
// lungfish-cli against a loopback stand-in, so its name ends in ReplayTests, which sends it to the
// integration tier.

import Foundation
import XCTest
@testable import LungfishApp
import LungfishCore
import LungfishKitTestSupport
import LungfishTestSupport

@MainActor
final class BlastSubmitFastaSelectionParityReplayTests: XCTestCase {
    /// The files only side C writes, the search under the project.
    static let declared = BlastSubmitParity.declared(stageFiles: 2, resultFiles: 3, resultsParent: "Project.lungfish")

    private var scratch: URL!
    private var server: LoopbackHTTPStandIn!
    private var saved: ProcessEnvironmentOverride?
    private var harness: RouteParityHarness!

    override func setUpWithError() throws {
        scratch = try TestTempDirectory.make(prefix: "blast-fasta-parity")
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

    func testTheSelectionSearchSendsWhatTheInProcessSearchSentAndKeepsItsResult() async throws {
        try await BlastSubmitParity.assertParity(
            harness: harness, server: server, declared: Self.declared,
            in: scratch.appendingPathComponent("parity", isDirectory: true),
            fixture: Self.makeProject,
            sideA: { _ in await BlastSubmitParity.sideA(Self.inProcessRequest(), server: self.server) },
            sideC: { root in await BlastSubmitParity.sideC(root, cli: self.harness.cliBinary, plan: Self.plan, begin: Self.begin) }
        )
    }

    func testTheSelectionSearchRecordIsSignedAndVerifies() async throws {
        try await BlastSubmitParity.assertSignedRecordVerifies(
            harness: harness, in: scratch.appendingPathComponent("signed", isDirectory: true),
            resultsParent: { BlastSubmitParity.project(in: $0) },
            fixture: Self.makeProject,
            sideA: { _ in await BlastSubmitParity.sideA(Self.inProcessRequest(), server: self.server) },
            sideC: { root in await BlastSubmitParity.sideC(root, cli: self.harness.cliBinary, plan: Self.plan, begin: Self.begin) }
        )
    }

    // MARK: - The site

    /// The FASTA file, relative to a side root.
    private static let sourcePath = "Project.lungfish/Imports/savont clusters.fasta"
    private static let sourceLabel = "2 FASTA sequences"
    /// The selected sequences, as the viewer parsed them from its records.
    private static let sequences = [(id: "cluster-1", sequence: "ACGTACGTACGTACGTACGT"), (id: "cluster-2", sequence: "GGCCTTAAGGCCTTAAGGCC")]

    private static func makeProject(_ root: URL) throws {
        let source = root.appendingPathComponent(sourcePath)
        try FileManager.default.createDirectory(at: source.deletingLastPathComponent(), withIntermediateDirectories: true)
        let records = sequences.map { ">\($0.id)\n\($0.sequence)\n" }.joined()
        try Data((records + ">cluster-3\nTTTTGGGGCCCCAAAATTTT\n").utf8).write(to: source)
    }

    /// The request of the in-process route, as the viewer built it before the route moved.
    private static func inProcessRequest() -> BlastVerificationRequest {
        BlastVerificationRequest(
            taxonName: sourceLabel, taxId: 0, sequences: sequences, database: BlastDatabaseID.coreNT.rawValue, entrezQuery: nil
        )
    }

    private static func plan(_ root: URL) throws -> BlastSubmitPlan {
        try ViewerViewController.fastaSelectionBlastSubmitPlan(
            sourceLabel: sourceLabel, sequences: sequences, sourceURL: root.appendingPathComponent(sourcePath),
            projectURL: BlastSubmitParity.project(in: root)
        )
    }

    private static func begin(_ command: String, _ reporter: RecordingOperationReporter) {
        ViewerViewController.beginGenericBlastVerificationOperation(
            sourceLabel: sourceLabel, cliCommand: command, reporter: reporter
        ) { _ in }
    }
}
