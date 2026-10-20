// BlastSubmitNvdParityReplayTests.swift - The NVD contig BLAST in the app against blast submit
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.12 lane 12.08 (A65-M3a) and 2.13 lane 13.02, the sides of BlastSubmitParity.swift. The NVD viewer sends one
// contig and judges hits on the request `NvdBlastHit.blastVerificationRequest` builds. The oracle is that request
// searched in this process, as the viewer searched it before the route moved (the hidden key that kept that route left
// in 2.13), and C against C' declares nothing. The class launches the built lungfish-cli against a loopback stand-in,
// so its name ends in ReplayTests, which sends it to the integration tier.

import Foundation
import XCTest
@testable import LungfishApp
import LungfishCore
import LungfishIO
import LungfishKitTestSupport
import LungfishTestSupport

@MainActor
final class BlastSubmitNvdParityReplayTests: XCTestCase {
    private var scratch: URL!
    private var server: LoopbackHTTPStandIn!
    private var saved: ProcessEnvironmentOverride?
    private var harness: RouteParityHarness!

    override func setUpWithError() throws {
        scratch = try TestTempDirectory.make(prefix: "blast-nvd-parity")
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
            resultsParent: { BlastSubmitParity.project(in: $0) },
            fixture: Self.makeProject,
            oracle: { await BlastSubmitParity.inProcessSearch(Self.inProcessRequest(), server: self.server) },
            sideC: { root in await BlastSubmitParity.sideC(root, cli: self.harness.cliBinary, plan: Self.plan, begin: Self.begin) }
        )
    }

    func testTheContigSearchRecordIsSignedAndVerifies() async throws {
        try await BlastSubmitParity.assertSignedRecordVerifies(
            harness: harness, in: scratch.appendingPathComponent("signed", isDirectory: true),
            resultsParent: { BlastSubmitParity.project(in: $0) },
            fixture: Self.makeProject,
            sideC: { root in await BlastSubmitParity.sideC(root, cli: self.harness.cliBinary, plan: Self.plan, begin: Self.begin) }
        )
    }

    func testSIGTERMCancelsTheContigSearchInsideTheGrace() async throws {
        let root = scratch.appendingPathComponent("cancel", isDirectory: true)
        try Self.makeProject(root)
        try await BlastSubmitParity.assertSIGTERMCancels(try Self.plan(root), server: server, testClass: Self.self)
    }

    // MARK: - The site

    private static let classificationName = "Influenza A virus"
    /// The contig is named `read_1`, the query the stand-in's JSON2 answer names.
    private static let hit = BlastSubmitParity.nvdHit(
        qseqid: "read_1", taxId: 11320, name: classificationName, scientificName: classificationName
    )
    private static let contig = "ACGTACGTACGTACGTACGT"

    /// The NVD result the contig came from, relative to a side root.
    private static let sourcePath = "Project.lungfish/Analyses/nvd-flu-run"

    private static func makeProject(_ root: URL) throws {
        let source = root.appendingPathComponent(sourcePath, isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try Data("{}\n".utf8).write(to: source.appendingPathComponent("manifest.json"))
    }

    /// The request of the in-process route, built by the LungfishIO builder the viewer calls (review ruling 6).
    private static func inProcessRequest() -> BlastVerificationRequest {
        hit.blastVerificationRequest(taxonName: classificationName, sequence: contig)
    }

    private static func plan(_ root: URL) throws -> BlastSubmitPlan {
        try ViewerViewController.nvdBlastSubmitPlan(
            hit: hit, sequence: contig, classificationName: classificationName,
            projectURL: BlastSubmitParity.project(in: root), sourceResultURL: root.appendingPathComponent(sourcePath, isDirectory: true)
        )
    }

    private static func begin(_ command: String, _ reporter: RecordingOperationReporter) {
        ViewerViewController.beginNvdBlastVerificationOperation(
            contigName: "read_1 (20 bp)", classificationName: classificationName, taxId: 11320, cliCommand: command, reporter: reporter
        ) { _ in }
    }
}
