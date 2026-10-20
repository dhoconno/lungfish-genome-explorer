// BlastSubmitTwelveSParityReplayTests.swift - The 12S unresolved-sequence BLAST in the app against blast submit
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.12 lane 12.09 (A65-M3b) and 2.13 lane 13.02, the sides of BlastSubmitParity.swift. The 12S viewer exports
// the unresolved sequences with `lungfish-cli fastq 12s-export-unresolved`, reads the FASTA and searches every sequence
// it holds as the request `12S unresolved sequences`, with no taxon and no subsample. The oracle is that request
// searched in this process, as the viewer searched it before the route moved (the hidden key that kept that route left
// in 2.13), and C against C' declares nothing. The sequences stand in for the export the site runs before it plans. The
// class launches the built lungfish-cli against a loopback stand-in, so its name ends in ReplayTests, which sends it to
// the integration tier.

import Foundation
import XCTest
@testable import LungfishApp
import LungfishCore
import LungfishKitTestSupport
import LungfishTestSupport

@MainActor
final class BlastSubmitTwelveSParityReplayTests: XCTestCase {
    private var scratch: URL!
    private var server: LoopbackHTTPStandIn!
    private var saved: ProcessEnvironmentOverride?
    private var harness: RouteParityHarness!

    override func setUpWithError() throws {
        scratch = try TestTempDirectory.make(prefix: "blast-twelves-parity")
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

    func testTheUnresolvedSearchSendsWhatTheInProcessSearchSentAndKeepsItsResult() async throws {
        try await BlastSubmitParity.assertParity(
            harness: harness, server: server,
            in: scratch.appendingPathComponent("parity", isDirectory: true),
            resultsParent: { BlastSubmitParity.project(in: $0) },
            fixture: Self.makeProject,
            oracle: { await BlastSubmitParity.inProcessSearch(Self.inProcessRequest(), server: self.server) },
            sideC: { root in await BlastSubmitParity.sideC(root, cli: self.harness.cliBinary, plan: Self.plan, begin: Self.begin) }
        )
    }

    func testTheUnresolvedSearchRecordIsSignedAndVerifies() async throws {
        try await BlastSubmitParity.assertSignedRecordVerifies(
            harness: harness, in: scratch.appendingPathComponent("signed", isDirectory: true),
            resultsParent: { BlastSubmitParity.project(in: $0) },
            fixture: Self.makeProject,
            sideC: { root in await BlastSubmitParity.sideC(root, cli: self.harness.cliBinary, plan: Self.plan, begin: Self.begin) }
        )
    }

    func testSIGTERMCancelsTheUnresolvedSearchInsideTheGrace() async throws {
        let root = scratch.appendingPathComponent("cancel", isDirectory: true)
        try Self.makeProject(root)
        try await BlastSubmitParity.assertSIGTERMCancels(try Self.plan(root), server: server, testClass: Self.self)
    }

    // MARK: - The site

    /// Two unresolved sequences, as the export gives them.
    private static let sequences: [(id: String, sequence: String)] = [
        (id: "read_1", sequence: "ACGTACGTACGTACGTACGT"), (id: "read_2", sequence: "GGCCTTAAGGCCTTAAGGCC"),
    ]

    /// The 12S result the sequences came from, relative to a side root.
    private static let bundlePath = "Project.lungfish/Analyses/12s-run/result.lungfish12s"

    private static func makeProject(_ root: URL) throws {
        let bundle = root.appendingPathComponent(bundlePath, isDirectory: true)
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
        try Data("{}\n".utf8).write(to: bundle.appendingPathComponent("manifest.json"))
    }

    /// The request of the in-process route, which the viewer built from the export with no taxon.
    private static func inProcessRequest() -> BlastVerificationRequest {
        BlastVerificationRequest(
            taxonName: "12S unresolved sequences", taxId: 0, sequences: sequences,
            database: BlastDatabaseID.coreNT.rawValue, entrezQuery: nil
        )
    }

    private static func plan(_ root: URL) throws -> BlastSubmitPlan {
        try ViewerViewController.twelveSUnresolvedBlastSubmitPlan(
            sequences: sequences, bundleURL: root.appendingPathComponent(bundlePath, isDirectory: true),
            projectURL: BlastSubmitParity.project(in: root)
        )
    }

    private static func begin(_ command: String, _ reporter: RecordingOperationReporter) {
        let arguments = ViewerViewController.twelveSUnresolvedExportArguments(
            bundleURL: URL(fileURLWithPath: "/tmp/twelves/result.lungfish12s"), minimumReads: 2,
            exportURL: URL(fileURLWithPath: "/tmp/twelves/unresolved-min2.fasta"), sequenceIDs: []
        )
        ViewerViewController.beginTwelveSUnresolvedBlastOperation(
            cliArguments: arguments, cliCommand: command, reporter: reporter
        ) { _ in }
    }
}
