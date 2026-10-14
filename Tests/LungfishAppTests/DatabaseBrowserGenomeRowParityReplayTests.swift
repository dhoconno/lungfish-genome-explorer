// DatabaseBrowserGenomeRowParityReplayTests.swift - The NCBI browser's genome row, in process against lungfish-cli
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.10 lane A44, ruling Q2b, panel decisions C4 and G5, on lane Q30's harness. One genome row
// of the NCBI browser's batch download, an assembly with a project, runs on three sides that start
// as copies of one empty project.
//
// - Side A is the in-process route the hidden key keeps for one release. It gets the assembly
//   summary and builds the bundle in a batch folder under the project's `.tmp` folder, and the
//   import then copies the bundle into the project's Downloads folder and removes the built one
//   (`handleMultipleDownloadsSync`).
// - Side C is the CLI route, `fetch genome <accession> --output-dir <project>/Downloads --format
//   json` launched through `CLISubprocessTransport`, writing straight into the folder its row's
//   command names. The import keeps a bundle there in place.
// - Side C' is the harness's replay of the row's command.
//
// Both routes read the loopback NCBI stand-in, which the process environment names, as the CLI
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
    }

    static let closer = "2.11, which deletes the in-process genome row with its key (C4)"

    /// What side C writes that side A does not, and the reverse, with BIO's reason.
    static let declared: [RouteParityDeclaredDifference<Case>] = [
        RouteParityDeclaredDifference(
            [.oneAssemblyInAProject: 1],
            "only in A: Project.lungfish/.tmp/batch-<UUID>/.lungfish-owned-work-directory.json",
            reason: "The in-process route builds the bundle in a batch folder under the project's .tmp folder, and the "
                + "import copies the bundle out and leaves the folder with its owner marker. The CLI route stages in a "
                + "folder of its own under .tmp and removes it.",
            closedBy: closer
        ),
        RouteParityDeclaredDifference(
            [.oneAssemblyInAProject: 14],
            "only in C: Project.lungfish/Downloads/<ANY>.lungfishref/<ANY>lungfish-provenance.json",
            reason: "fetch genome writes the bundle's provenance record, which names each fetched file with its source "
                + "URL, digest and size (B-3), a sidecar beside each output and a copy of each in provenance/. The "
                + "in-process route writes no record, the declared difference that keeps its key (C4).",
            closedBy: closer
        ),
    ]

    /// The digest gap of the contract (lane Q30 M2 finding 1), pinned and never declared, which
    /// the contract's fix empties. No difference of this case is a folder digest or a manifest
    /// map entry.
    static let digestGap: [String] = []

    /// The genome row of the stand-in's one assembly.
    static let record = SearchResultRecord(
        id: "9900001", accession: NCBIGenomeStandIn.assemblyAccession, title: "StandInAsm1", source: .ncbi)

    /// Stopped under the coordinator rule on two differences that are neither declared nor a digest
    /// gap, which await a ruling (lane A44 M2c report, findings P1 and P2). C against C': each
    /// record states the SHA-256 of `manifest.json`, whose bytes differ between runs only in the
    /// random ids of its metadata groups and items, which the compare masks in the file but not in
    /// the digest a record states for it (14 values). A against C: the manifest's ids are numbered
    /// across the tree, so the files only one side holds shift them (one value).
    /// `LUNGFISH_A44_PARITY_FINDINGS=1` runs the case as it stands.
    func testTheGenomeRowBuildsTheSameBundleOnBothRoutes() async throws {
        guard ProcessInfo.processInfo.environment["LUNGFISH_A44_PARITY_FINDINGS"] == "1" else {
            throw XCTSkip("Stopped on findings P1 and P2 of lane A44 M2c, which await a ruling")
        }
        let (cli, root) = try await prepare()
        defer { TestTempDirectory.cleanup(root) }
        let server = try await NCBIGenomeStandIn.start(servingIn: root.appendingPathComponent("served", isDirectory: true))
        defer { server.stop() }
        let saved = ProcessEnvironmentOverride(
            set: [NCBIServiceEndpoints.standInOriginVariable: server.baseURL.absoluteString], unset: ["NCBI_API_KEY"])
        defer { saved.restore() }

        let harness = RouteParityHarness(cliBinary: cli, kind: .bundle, replayTimeout: .seconds(120))
        let runs = try await harness.run(
            in: root.appendingPathComponent("case", isDirectory: true),
            fixture: Self.makeProject,
            sideA: { try await Self.sideA($0) },
            sideC: { try await Self.sideC($0, cli: cli) }
        )
        let result = try harness.evaluate(Case.oneAssemblyInAProject, declared: Self.declared, runs: runs)
        // digest gap, Q30 finding 1
        let gap = result.failures.filter { Self.digestGap.contains($0) }
        XCTAssertEqual(gap, Self.digestGap, "the digest gap moved")
        RouteParityHarness.assertNoFailures(
            result.failures.filter { !Self.digestGap.contains($0) }, in: "\(Case.oneAssemblyInAProject)")

        for run in runs.all {
            XCTAssertEqual(run.outcome.end, .completed, "side \(run.side): \(run.outcome.detail)")
        }
        XCTAssertNil(ProvenanceRecorder.loadEnvelope(from: try Self.onlyBundle(in: runs.a.root)), "side A writes no record")
        for run in [runs.c, runs.cPrime] {
            try Self.assertRecordNamesEachOutputWithItsDigest(try Self.onlyBundle(in: run.root), side: run.side)
        }
    }

    /// B-5 with a signing key in the environment. Each CLI side signs its record, and `provenance
    /// verify` passes on side C's bundle and on the replay's. Side A writes no record to verify.
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
        let c = RouteParitySideRun(side: .c, root: rootC, outcome: try await Self.sideC(rootC, cli: cli))
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

    /// Side A. The in-process route into a batch folder, then the import's copy into Downloads.
    static func sideA(_ root: URL) async throws -> RouteParitySideOutcome {
        let project = project(in: root)
        let service = NCBIService()
        let built = try await DatabaseBrowserViewModel.downloadGenomeRow(
            record, index: 0, totalCount: 1, operationID: UUID(), route: .legacy,
            ncbi: service, genomeVM: GenomeDownloadViewModel(ncbiService: service),
            batchFolder: BatchDownloadFolder(projectURL: project), projectURL: project)
        let downloads = project.appendingPathComponent("Downloads", isDirectory: true)
        try FileManager.default.createDirectory(at: downloads, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: built, to: downloads.appendingPathComponent(built.lastPathComponent))
        try FileManager.default.removeItem(at: built)
        return RouteParitySideOutcome(end: .completed, detail: "in process")
    }

    /// Side C. The CLI route of the row, which records the command its row shows.
    static func sideC(_ root: URL, cli: URL) async throws -> RouteParitySideOutcome {
        let project = project(in: root)
        let service = NCBIService()
        let command = DatabaseBrowserViewModel.batchDownloadCLICommand(
            source: .ncbi, searchType: .genome, accessions: [record.accession], projectURL: project)
        do {
            _ = try await DatabaseBrowserViewModel.downloadGenomeRow(
                record, index: 0, totalCount: 1, operationID: UUID(), route: .cli,
                ncbi: service, genomeVM: GenomeDownloadViewModel(ncbiService: service),
                batchFolder: BatchDownloadFolder(projectURL: project), projectURL: project, cliURLOverride: cli)
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
        let downloads = project(in: root).appendingPathComponent("Downloads", isDirectory: true)
        let names = try FileManager.default.contentsOfDirectory(atPath: downloads.path).filter { $0.hasSuffix(".lungfishref") }
        XCTAssertEqual(names.count, 1, "\(names)")
        return downloads.appendingPathComponent(try XCTUnwrap(names.first), isDirectory: true)
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
