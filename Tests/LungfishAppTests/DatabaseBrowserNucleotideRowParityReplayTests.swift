// DatabaseBrowserNucleotideRowParityReplayTests.swift - The NCBI browser's nucleotide row and its replay
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.10 lane A45, panel decisions C4 and G5, on lane Q30's harness. One nucleotide row of the
// NCBI browser's batch download, with a project, runs on two sides that start as copies of one
// empty project, as the genome row's class (lane A44) runs its sides. Lane A60 of 2.11 deleted the
// in-process route with its hidden key, and side A with it.
//
// - Side C is the CLI route, `fetch ncbi <accession> --bundle --output-dir <project>/Downloads
//   --format json` launched through `CLISubprocessTransport`.
// - Side C' is the harness's replay of the row's recorded command.
//
// Both sides read the loopback NCBI stand-in, which the process environment names. It launches the
// built lungfish-cli and the managed bgzip and samtools, so its name ends in ReplayTests, which
// sends it to the integration tier.

import Foundation
import XCTest
@testable import LungfishApp
@testable import LungfishCore
@testable import LungfishWorkflow
import LungfishIO
import LungfishKit
import LungfishKitTestSupport
import LungfishOperations
import LungfishTestSupport

@MainActor
final class DatabaseBrowserNucleotideRowParityReplayTests: XCTestCase {
    enum Case: String, Sendable {
        case recordWithGFF3
        case recordWithoutGFF3
    }

    /// The digest gap of the contract (lane Q30 M2 finding 1), pinned and never declared.
    static let digestGap: [String] = []

    /// The row of the stand-in's GenBank record, which it serves with a GFF3.
    static let record = SearchResultRecord(
        id: "9910001", accession: NCBIDownloadPinFixtures.genBankAccession, title: "Stand-in record", source: .ncbi)
    /// The row of the stand-in's second record, for which it serves no GFF3.
    static let recordWithoutGFF3 = SearchResultRecord(
        id: "9910002", accession: NCBIGenomeStandIn.recordWithoutGFF3Accession, title: "Stand-in record 2", source: .ncbi)

    static func record(of parityCase: Case) -> SearchResultRecord {
        parityCase == .recordWithGFF3 ? record : recordWithoutGFF3
    }

    /// One nucleotide row with a project. C against C' lists nothing.
    func testTheRecordWithGFF3BuildsTheBrowsersBundleOnBothRoutes() async throws {
        try await assertParity(.recordWithGFF3)
    }

    /// NCBI serves no GFF3 for the record, so the row takes the track from its FEATURES.
    func testTheRecordWithoutGFF3BuildsTheBrowsersBundleOnBothRoutes() async throws {
        try await assertParity(.recordWithoutGFF3)
    }

    func assertParity(_ parityCase: Case) async throws {
        let (cli, root) = try await prepare()
        defer { TestTempDirectory.cleanup(root) }
        let server = try await NCBIGenomeStandIn.start(servingIn: root.appendingPathComponent("served", isDirectory: true))
        defer { server.stop() }
        let saved = ProcessEnvironmentOverride(
            set: [NCBIServiceEndpoints.standInOriginVariable: server.baseURL.absoluteString], unset: ["NCBI_API_KEY"])
        defer { saved.restore() }

        let record = Self.record(of: parityCase)
        let harness = RouteParityHarness(cliBinary: cli, kind: .bundle, replayTimeout: .seconds(120))
        let runs = try await ReadsRouteParity.runCAndCPrime(
            harness,
            in: root.appendingPathComponent("case", isDirectory: true),
            fixture: Self.makeProject,
            sideC: { try await Self.sideC($0, cli: cli, record: record) }
        )
        let result = try harness.evaluate(parityCase, declared: [], runs: runs)
        let gap = result.failures.filter { Self.digestGap.contains($0) }
        XCTAssertEqual(gap, Self.digestGap, "the digest gap moved")
        RouteParityHarness.assertNoFailures(result.failures.filter { !Self.digestGap.contains($0) }, in: "\(parityCase)")

        for run in runs.all {
            XCTAssertEqual(run.outcome.end, .completed, "side \(run.side): \(run.outcome.detail)")
        }
        XCTAssertEqual(
            runs.cPrime.replayedArguments.map { Array($0.prefix(3)) }, [["fetch", "ncbi", record.accession]])
        for run in [runs.c, runs.cPrime] {
            let bundle = try Self.onlyBundle(in: run.root)
            try Self.assertRecordNamesEachOutputWithItsDigest(bundle, side: run.side)
            let manifest = try BundleManifest.load(from: bundle)
            let chromosomes = try XCTUnwrap(manifest.genome).chromosomes
            XCTAssertEqual(chromosomes.map(\.name), [record.accession], "side \(run.side)")
            // BIO T4: the bare accession, the name of an older bundle of this record, still maps.
            let bare = String(record.accession.split(separator: ".")[0])
            XCTAssertEqual(
                mapVCFChromosomes([bare], toBundleChromosomes: chromosomes), [bare: record.accession], "side \(run.side)")
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

    /// Side C. The CLI route of the row, and the command the batch row records.
    static func sideC(_ root: URL, cli: URL, record: SearchResultRecord) async throws -> RouteParitySideOutcome {
        let project = project(in: root)
        let service = NCBIService()
        let command = DatabaseBrowserViewModel.batchDownloadCLICommand(
            source: .ncbi, searchType: .nucleotide, accessions: [record.accession], projectURL: project)
        do {
            _ = try await DatabaseBrowserViewModel.downloadNucleotideRow(
                record, index: 0, totalCount: 1, operationID: UUID(), ncbi: service,
                includeGFF3Annotations: true, projectURL: project, cliURLOverride: cli)
        } catch {
            return RouteParitySideOutcome(end: .failed, detail: "\(error)", recordedCommand: command)
        }
        return RouteParitySideOutcome(end: .completed, detail: "exit 0", recordedCommand: command)
    }

    // MARK: - Helpers

    /// The built CLI and a scratch root, or a skip without the managed tools.
    func prepare() async throws -> (cli: URL, root: URL) {
        do {
            try await GenBankDownloadBundleBuilder(ncbiService: NCBIService(apiKey: nil, environment: [:])).validateTools()
        } catch {
            try ToolAvailability.skipOrFail("Managed bgzip and samtools are required: \(error)")
        }
        let products = Bundle(for: Self.self).bundleURL.deletingLastPathComponent()
        let cli = try XCTUnwrap(
            CLITestBinaryResolver.cliBinaryURL(buildProductsDirectory: products),
            "No lungfish-cli beside \(products.path) and none named by LUNGFISH_CLI_PATH")
        return (cli, try TestTempDirectory.make(prefix: "nucleotide-row-parity"))
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
