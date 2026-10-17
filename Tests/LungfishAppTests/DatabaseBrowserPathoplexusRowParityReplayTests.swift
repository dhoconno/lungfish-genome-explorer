// DatabaseBrowserPathoplexusRowParityReplayTests.swift - The Pathoplexus browser's row, in process against lungfish-cli
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.10 lane A45 M2, panel decisions C4 and G5, on lane Q30's harness. One Pathoplexus row of the
// browser's batch download, with a project, runs on two sides that start as copies of one empty
// project, as the nucleotide row's class runs its sides. Lane A60 of 2.11 deleted the in-process
// route with its hidden key, and side A with it.
//
// - Side C is the CLI route, `fetch pathoplexus <accession> --organism <id> --output-dir
//   <project>/Downloads --format json` launched through `CLISubprocessTransport`.
// - Side C' is the harness's replay of the row's recorded command.
//
// Both sides read the loopback Pathoplexus and NCBI stand-ins, which the process environment names.
// The cases are the row's ways: a record with an INSDC accession GenBank serves, one with none, and one
// whose INSDC accession GenBank cannot serve. A restricted record is refused with the row's words and
// builds nothing. The class launches the built lungfish-cli and the managed bgzip and samtools, so its
// name ends in ReplayTests, which sends it to the integration tier.

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
final class DatabaseBrowserPathoplexusRowParityReplayTests: XCTestCase {
    enum Case: String, Sendable {
        case recordWithINSDC
        case recordWithoutINSDC
        case recordWithUnavailableINSDC
    }

    static func accession(of parityCase: Case) -> String {
        switch parityCase {
        case .recordWithINSDC: return PathoplexusLAPISStandIn.openWithINSDC
        case .recordWithoutINSDC: return PathoplexusLAPISStandIn.openNoINSDC
        case .recordWithUnavailableINSDC: return PathoplexusLAPISStandIn.openINSDCUnavailable
        }
    }

    static func record(of parityCase: Case) -> SearchResultRecord {
        let accession = accession(of: parityCase)
        return SearchResultRecord(id: accession, accession: accession, title: "Stand-in Pathoplexus record", source: .pathoplexus)
    }

    func testARecordWithAnINSDCAccessionBuildsTheBrowsersBundleOnBothRoutes() async throws {
        try await assertParity(.recordWithINSDC)
    }

    func testARecordWithNoINSDCAccessionBuildsTheBrowsersBundleOnBothRoutes() async throws {
        try await assertParity(.recordWithoutINSDC)
    }

    func testAnINSDCAccessionGenBankCannotServeBuildsTheBrowsersBundleOnBothRoutes() async throws {
        try await assertParity(.recordWithUnavailableINSDC)
    }

    /// A restricted record is refused with the row's words and builds no bundle.
    func testARestrictedRecordIsRefusedOnBothRoutes() async throws {
        let (cli, root) = try await prepare()
        defer { TestTempDirectory.cleanup(root) }
        let stand = try await StandIns.start(in: root)
        defer { stand.stop() }
        let record = SearchResultRecord(
            id: PathoplexusLAPISStandIn.restricted, accession: PathoplexusLAPISStandIn.restricted,
            title: "Stand-in restricted record", source: .pathoplexus)
        let project = root.appendingPathComponent("cli/Project.lungfish", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        do {
            _ = try await Self.row(record, project: project, cli: cli)
            XCTFail("A restricted record downloads")
        } catch {
            XCTAssertTrue("\(error)".contains("Record PP_000003 is restricted and cannot be downloaded"), "\(error)")
        }
        let walker = FileManager.default.enumerator(atPath: project.path)
        var bundles: [String] = []
        while let path = walker?.nextObject() as? String {
            if path.hasSuffix(".lungfishref") { bundles.append(path) }
        }
        XCTAssertEqual(bundles, [], "a refused record builds no bundle")
    }

    func assertParity(_ parityCase: Case) async throws {
        let (cli, root) = try await prepare()
        defer { TestTempDirectory.cleanup(root) }
        let stand = try await StandIns.start(in: root)
        defer { stand.stop() }

        let record = Self.record(of: parityCase)
        let harness = RouteParityHarness(cliBinary: cli, kind: .bundle, replayTimeout: .seconds(120))
        let runs = try await ReadsRouteParity.runCAndCPrime(
            harness,
            in: root.appendingPathComponent("case", isDirectory: true),
            fixture: DatabaseBrowserNucleotideRowParityReplayTests.makeProject,
            sideC: { try await Self.sideC($0, cli: cli, record: record) }
        )
        let result = try harness.evaluate(parityCase, declared: [], runs: runs)
        RouteParityHarness.assertNoFailures(result.failures, in: "\(parityCase)")

        for run in runs.all {
            XCTAssertEqual(run.outcome.end, .completed, "side \(run.side): \(run.outcome.detail)")
        }
        XCTAssertEqual(
            runs.cPrime.replayedArguments.map { Array($0.prefix(3)) }, [["fetch", "pathoplexus", record.accession]])
        for run in [runs.c, runs.cPrime] {
            let bundle = try DatabaseBrowserNucleotideRowParityReplayTests.onlyBundle(in: run.root)
            try DatabaseBrowserNucleotideRowParityReplayTests.assertRecordNamesEachOutputWithItsDigest(bundle, side: run.side)
            let manifest = try BundleManifest.load(from: bundle)
            let chromosomes = try XCTUnwrap(manifest.genome).chromosomes
            // The INSDC way names the one sequence by the INSDC accession with its version (A44 M3-2 term 4,
            // BIO T4). A way built from the Pathoplexus FASTA names it by the Pathoplexus accession.
            let expected = parityCase == .recordWithINSDC ? NCBIDownloadPinFixtures.genBankAccession : record.accession
            XCTAssertEqual(chromosomes.map(\.name), [expected], "side \(run.side)")
            XCTAssertNotNil(manifest.metadata?.first { $0.name == "Pathoplexus Record" }, "side \(run.side)")
        }
    }

    // MARK: - Sides

    /// One row of the browser's batch download into `project`.
    static func row(_ record: SearchResultRecord, project: URL, cli: URL?) async throws -> URL {
        try await DatabaseBrowserViewModel.downloadPathoplexusRow(
            record, index: 0, totalCount: 1, operationID: UUID(), organism: PathoplexusLAPISStandIn.organism,
            ncbi: NCBIService(), includeGFF3Annotations: true, projectURL: project, cliURLOverride: cli)
    }

    /// Side C. The CLI route of the row, and the command the batch row records.
    static func sideC(_ root: URL, cli: URL, record: SearchResultRecord) async throws -> RouteParitySideOutcome {
        let project = DatabaseBrowserNucleotideRowParityReplayTests.project(in: root)
        let command = DatabaseBrowserViewModel.batchDownloadCLICommand(
            source: .pathoplexus, searchType: .nucleotide, accessions: [record.accession], projectURL: project,
            pathoplexusOrganism: PathoplexusLAPISStandIn.organism)
        do {
            _ = try await row(record, project: project, cli: cli)
        } catch {
            return RouteParitySideOutcome(end: .failed, detail: "\(error)", recordedCommand: command)
        }
        return RouteParitySideOutcome(end: .completed, detail: "exit 0", recordedCommand: command)
    }

    // MARK: - Helpers

    /// The loopback Pathoplexus and NCBI stand-ins, named in the process environment the child
    /// inherits, and no NCBI key.
    struct StandIns {
        let ncbi: LoopbackHTTPStandIn
        let lapis: LoopbackHTTPStandIn
        let saved: ProcessEnvironmentOverride

        static func start(in root: URL) async throws -> StandIns {
            let ncbi = try await NCBIGenomeStandIn.start(servingIn: root.appendingPathComponent("served", isDirectory: true))
            let lapis = try PathoplexusLAPISStandIn.start()
            let saved = ProcessEnvironmentOverride(
                set: [
                    NCBIServiceEndpoints.standInOriginVariable: ncbi.baseURL.absoluteString,
                    PathoplexusServiceEndpoints.standInOriginVariable: lapis.baseURL.absoluteString,
                ],
                unset: ["NCBI_API_KEY"])
            return StandIns(ncbi: ncbi, lapis: lapis, saved: saved)
        }

        func stop() {
            saved.restore()
            ncbi.stop()
            lapis.stop()
        }
    }

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
        return (cli, try TestTempDirectory.make(prefix: "pathoplexus-row-parity"))
    }
}
