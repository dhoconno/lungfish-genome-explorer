// DatabaseBrowserGenomeRowParityReplayTests.swift - The NCBI browser's genome row, in process against lungfish-cli
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.10 lane A44, ruling Q2b, panel decisions C4 and G5, on lane Q30's harness. One genome row
// of the NCBI browser's batch download, an assembly with a project, runs on two sides that start
// as copies of one empty project. Lane A60 of 2.11 deleted the in-process route with its
// hidden key, and side A with it.
//
// - Side C is the CLI route, `fetch genome <accession> --output-dir <project>/Downloads --format
//   json` launched through `CLISubprocessTransport`, writing straight into the folder its row's
//   command names. The import keeps a bundle there in place.
// - Side C' is the harness's replay of the row's command.
//
// Both sides read the loopback NCBI stand-in, which the process environment names, as the CLI
// pins do. The record each CLI side writes must name every output it lists with that file's
// digest (B-5), and a signed run passes `provenance verify` on sides C and C'.
//
// It launches the built lungfish-cli and the managed bgzip and samtools, so its name ends in
// ReplayTests, which sends it to the integration tier.

import Foundation
import XCTest
@testable import LungfishApp
@testable import LungfishCore
@testable import LungfishWorkflow
import LungfishIO
import LungfishKit
import LungfishKitTestSupport
import LungfishTestSupport

@MainActor
final class DatabaseBrowserGenomeRowParityReplayTests: XCTestCase {
    enum Case: String, Sendable {
        case oneAssemblyInAProject
        /// Two rows of one batch, whose row records one `fetch genome` command with both
        /// accessions (review fix F7).
        case twoAssembliesInAProject
    }

    /// The digest gap of the contract (lane Q30 M2 finding 1), pinned and never declared, which
    /// the contract's fix empties. No difference of this case is a folder digest or a manifest
    /// map entry.
    static let digestGap: [String] = []

    /// The genome row of the stand-in's first assembly.
    static let record = SearchResultRecord(
        id: "9900001", accession: NCBIGenomeStandIn.assemblyAccession, title: "StandInAsm1", source: .ncbi)
    /// The genome row of the stand-in's second assembly.
    static let secondRecord = SearchResultRecord(
        id: NCBIGenomeStandIn.secondAssemblyUID, accession: NCBIGenomeStandIn.secondAssemblyAccession,
        title: "StandInAsm2", source: .ncbi)

    /// The genome rows of one batch of `parityCase`.
    static func records(of parityCase: Case) -> [SearchResultRecord] {
        switch parityCase {
        case .oneAssemblyInAProject: [record]
        case .twoAssembliesInAProject: [record, secondRecord]
        }
    }

    /// One genome row with a project. C against C' lists nothing, and each CLI side's record names each output with its digest. Findings P1 and P2
    /// of lane A44 M2c, the digest a record states for `manifest.json` and the numbering of its
    /// ids across the tree, no longer show since lane Q30's mask and the FXP fix.
    func testTheGenomeRowBuildsTheSameBundleOnBothRoutes() async throws {
        try await assertParity(.oneAssemblyInAProject)
    }

    /// Review fix F7. A batch row of two genome rows runs one single-accession child for each
    /// row and records one `fetch genome <A> <B>` command, which side C' replays. Each bundle's
    /// record names its own accession, so the replay builds the same two bundles.
    func testTwoGenomeRowsReplayAsTheBatchRowsOneCommand() async throws {
        try await assertParity(.twoAssembliesInAProject)
    }

    /// Runs `parityCase` on sides C and C' and checks C against C'.
    func assertParity(_ parityCase: Case) async throws {
        let (cli, root) = try await prepare()
        defer { TestTempDirectory.cleanup(root) }
        let server = try await NCBIGenomeStandIn.start(servingIn: root.appendingPathComponent("served", isDirectory: true))
        defer { server.stop() }
        let saved = ProcessEnvironmentOverride(
            set: [NCBIServiceEndpoints.standInOriginVariable: server.baseURL.absoluteString], unset: ["NCBI_API_KEY"])
        defer { saved.restore() }

        let records = Self.records(of: parityCase)
        let harness = RouteParityHarness(cliBinary: cli, kind: .bundle, replayTimeout: .seconds(120))
        let runs = try await ReadsRouteParity.runCAndCPrime(
            harness,
            in: root.appendingPathComponent("case", isDirectory: true),
            fixture: Self.makeProject,
            sideC: { try await Self.sideC($0, cli: cli, records: records) }
        )
        let result = try harness.evaluate(parityCase, declared: [], runs: runs)
        // digest gap, Q30 finding 1
        let gap = result.failures.filter { Self.digestGap.contains($0) }
        XCTAssertEqual(gap, Self.digestGap, "the digest gap moved")
        RouteParityHarness.assertNoFailures(result.failures.filter { !Self.digestGap.contains($0) }, in: "\(parityCase)")

        for run in runs.all {
            XCTAssertEqual(run.outcome.end, .completed, "side \(run.side): \(run.outcome.detail)")
        }
        XCTAssertEqual(
            runs.cPrime.replayedArguments.map { Array($0.prefix(2 + records.count)) },
            [["fetch", "genome"] + records.map(\.accession)])
        for run in [runs.c, runs.cPrime] {
            let bundles = try Self.bundles(in: run.root, count: records.count)
            for (bundle, record) in zip(bundles, records) {
                try Self.assertRecordNamesEachOutputWithItsDigest(bundle, side: run.side)
                let envelope = try XCTUnwrap(ProvenanceRecorder.loadEnvelope(from: bundle))
                XCTAssertEqual(
                    envelope.argv.filter { records.map(\.accession).contains($0) }, [record.accession],
                    "side \(run.side): \(bundle.lastPathComponent) names \(envelope.argv)")
            }
        }
    }

    /// B-5 with a signing key in the environment. Each CLI side signs its record, and `provenance
    /// verify` passes on side C's bundle and on the replay's.
    func testEachCLISidesSignedRecordPassesProvenanceVerify() async throws {
        let (cli, root) = try await prepare()
        defer { TestTempDirectory.cleanup(root) }
        let server = try await NCBIGenomeStandIn.start(servingIn: root.appendingPathComponent("served", isDirectory: true))
        defer { server.stop() }
        let saved = ProcessEnvironmentOverride(
            set: [
                NCBIServiceEndpoints.standInOriginVariable: server.baseURL.absoluteString,
                ProvenanceSigningConfiguration.signingKeyEnvironmentKey: "lane-a44-parity-signing-key",
            ],
            unset: ["NCBI_API_KEY", ProvenanceSigningConfiguration.signingKeyFileEnvironmentKey])
        defer { saved.restore() }

        let harness = RouteParityHarness(cliBinary: cli, kind: .bundle, replayTimeout: .seconds(120))
        let rootC = RouteParityHarness.root(of: .c, in: root)
        let rootCPrime = RouteParityHarness.root(of: .cPrime, in: root)
        try Self.makeProject(rootC)
        try Self.makeProject(rootCPrime)
        let c = RouteParitySideRun(side: .c, root: rootC, outcome: try await Self.sideC(rootC, cli: cli, records: [Self.record]))
        let cPrime = await harness.replay(of: c, in: rootCPrime)
        for run in [c, cPrime] {
            XCTAssertEqual(run.outcome.end, .completed, "side \(run.side): \(run.outcome.detail)")
            let bundle = try Self.onlyBundle(in: run.root)
            let verify = await RouteParityHarness.runCLI(
                cli, arguments: ["provenance", "verify", bundle.path], timeout: .seconds(60))
            XCTAssertEqual(verify.status, 0, "side \(run.side): \(verify.detail)")
            XCTAssertTrue(verify.stdout.contains("Signature valid"), "side \(run.side): \(verify.stdout)")
        }
    }

    // MARK: - Sides

    /// An empty project, which each side's root starts as.
    static func makeProject(_ root: URL) throws {
        try FileManager.default.createDirectory(at: project(in: root), withIntermediateDirectories: true)
    }

    static func project(in root: URL) -> URL {
        root.appendingPathComponent("Project.lungfish", isDirectory: true)
    }

    /// Side C. The CLI route of each row, as the batch loop runs them, and the one command the
    /// batch row records.
    static func sideC(_ root: URL, cli: URL, records: [SearchResultRecord]) async throws -> RouteParitySideOutcome {
        let project = project(in: root)
        let service = NCBIService()
        let operationID = UUID()
        let command = DatabaseBrowserViewModel.batchDownloadCLICommand(
            source: .ncbi, searchType: .genome, accessions: records.map(\.accession), projectURL: project)
        do {
            for (index, record) in records.enumerated() {
                _ = try await DatabaseBrowserViewModel.downloadGenomeRow(
                    record, index: index, totalCount: records.count, operationID: operationID,
                    ncbi: service, projectURL: project, cliURLOverride: cli)
            }
        } catch {
            return RouteParitySideOutcome(end: .failed, detail: "\(error)", recordedCommand: command)
        }
        return RouteParitySideOutcome(end: .completed, detail: "exit 0", recordedCommand: command)
    }

    // MARK: - Helpers

    /// The built CLI and a scratch root, or a skip without the managed tools.
    func prepare() async throws -> (cli: URL, root: URL) {
        do {
            try await GenomeDownloadBundleBuilder(ncbiService: NCBIService(apiKey: nil, environment: [:])).validateTools()
        } catch {
            try ToolAvailability.skipOrFail("Managed bgzip and samtools are required: \(error)")
        }
        let products = Bundle(for: Self.self).bundleURL.deletingLastPathComponent()
        let cli = try XCTUnwrap(
            CLITestBinaryResolver.cliBinaryURL(buildProductsDirectory: products),
            "No lungfish-cli beside \(products.path) and none named by LUNGFISH_CLI_PATH")
        return (cli, try TestTempDirectory.make(prefix: "genome-row-parity"))
    }

    /// The one bundle in the project's Downloads folder of a side root.
    static func onlyBundle(in root: URL) throws -> URL {
        try XCTUnwrap(try bundles(in: root, count: 1).first)
    }

    /// The `count` bundles in the project's Downloads folder of a side root, by name.
    static func bundles(in root: URL, count: Int) throws -> [URL] {
        let downloads = project(in: root).appendingPathComponent("Downloads", isDirectory: true)
        let names = try FileManager.default.contentsOfDirectory(atPath: downloads.path).filter { $0.hasSuffix(".lungfishref") }
        XCTAssertEqual(names.count, count, "\(names)")
        return names.sorted().map { downloads.appendingPathComponent($0, isDirectory: true) }
    }

    /// B-5. The bundle's record lists outputs, each of which exists with the digest it states.
    static func assertRecordNamesEachOutputWithItsDigest(_ bundle: URL, side: RouteParitySide) throws {
        let envelope = try XCTUnwrap(ProvenanceRecorder.loadEnvelope(from: bundle), "side \(side) wrote no record")
        XCTAssertFalse(envelope.outputs.isEmpty, "side \(side)")
        for output in envelope.outputs {
            let url = URL(fileURLWithPath: output.path)
            XCTAssertTrue(FileManager.default.fileExists(atPath: url.path), "side \(side): \(output.path)")
            let stated = try XCTUnwrap(output.checksumSHA256, "side \(side): \(output.path)")
            XCTAssertEqual(try ProvenanceFileHasher.sha256(of: url), stated, "side \(side): \(output.path)")
        }
    }
}
