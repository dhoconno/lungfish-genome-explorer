// DatabaseBrowserPathoplexusRowParityReplayTests.swift - The Pathoplexus browser's row, in process against lungfish-cli
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.10 lane A45 M2, panel decisions C4 and G5, on lane Q30's harness. One Pathoplexus row of the
// browser's batch download, with a project, runs on three sides that start as copies of one empty
// project, as the nucleotide row's class runs its sides.
//
// - Side A is the in-process route the hidden key keeps for one release. It builds the bundle in a
//   batch folder under the project's `.tmp` folder, and the import then copies the bundle into the
//   project's Downloads folder and removes the built one.
// - Side C is the CLI route, `fetch pathoplexus <accession> --organism <id> --output-dir
//   <project>/Downloads --format json` launched through `CLISubprocessTransport`.
// - Side C' is the harness's replay of the row's recorded command.
//
// Both routes read the loopback Pathoplexus and NCBI stand-ins, which the process environment names.
// The cases are the row's ways: a record with an INSDC accession GenBank serves, one with none, and one
// whose INSDC accession GenBank cannot serve. A restricted record is refused on both routes with the
// same words and builds nothing. The class launches the built lungfish-cli and the managed bgzip and
// samtools, so its name ends in ReplayTests, which sends it to the integration tier.

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

    static let closer = "2.11, which deletes the in-process Pathoplexus row with its key (C4)"

    /// Each way side C differs from side A with BIO's reason, as measured (the counts are exact).
    /// The batch folder's name holds a UUID, numbered by its place in the tree.
    static let declared: [RouteParityDeclaredDifference<Case>] = {
        let naming = "The INSDC way of the CLI route names the one sequence by the INSDC accession with its version, the CHROM "
            + "of a VCF, with the bare accession and the LOCUS name as aliases (A44 ruling M3-2 term 4, BIO test T4). The "
            + "in-process route names it by the LOCUS name, so the FASTA header, the index, the manifest's names and offset "
            + "differ."
        let record = "Both routes write the GenBank builder's record on the INSDC way, rewritten in the CLI's case to the "
            + "final place. The run's argument vector is the CLI's own, so each argv, each replay command and each step id "
            + "differs, and the digests of the files the renamed sequence changes follow from the naming. The CLI route "
            + "states the digest of the manifest as it stands once Pathoplexus's metadata is appended, where the "
            + "in-process route states the one the builder saw before the append. The bundle's root record, its copy in "
            + "provenance/ and each file's sidecar hold every step of the run, so they carry most of the values. The "
            + "harness explains a provenance envelope up to 1,000 values, each with an exact count (A45 M1 ruling, section 3)."
        let bundle = "<ANY>/Downloads/<ANY>.lungfishref/"
        let record2 = "differs: \(bundle)<ANY>lungfish-provenance.json at "
        return [
            RouteParityDeclaredDifference(
                [.recordWithINSDC: 1, .recordWithoutINSDC: 1, .recordWithUnavailableINSDC: 1],
                "only in A: Project.lungfish/.tmp/batch-<UUID-<ANY>>/.lungfish-owned-work-directory.json",
                reason: "The in-process route builds the bundle in a batch folder under the project's .tmp folder, and the "
                    + "import copies the bundle out and leaves the folder with its owner marker. The CLI route stages in "
                    + "a folder of its own under .tmp and removes it.",
                closedBy: closer),
            RouteParityDeclaredDifference(
                [.recordWithINSDC: 6], "differs: <ANY>/genome/sequence.fa<ANY>: only in <ANY>", reason: naming, closedBy: closer),
            RouteParityDeclaredDifference(
                [.recordWithINSDC: 2], "differs: <ANY>/manifest.json at browser_summary.sequences[0].<ANY>",
                reason: naming, closedBy: closer),
            RouteParityDeclaredDifference(
                [.recordWithINSDC: 3], "differs: <ANY>/manifest.json at genome.chromosomes[0].<ANY>",
                reason: naming, closedBy: closer),
            RouteParityDeclaredDifference(
                [.recordWithINSDC: 30], "differs: <ANY>/manifest.json at metadata[<ANY>].id",
                reason: "The manifest's metadata groups, 7 of the 30, and their items, 23, including the Pathoplexus groups "
                    + "appended to the manifest, carry fresh UUIDs on every build, masked and numbered by their place in the "
                    + "tree. The records ahead of the manifest hold other ids, so the numbers differ.",
                closedBy: closer),
            RouteParityDeclaredDifference(
                [.recordWithINSDC: 100], "\(record2)argv[<ANY>", reason: record, closedBy: closer),
            RouteParityDeclaredDifference(
                [.recordWithINSDC: 67], "\(record2)steps[<ANY>].argv[<ANY>", reason: record, closedBy: closer),
            RouteParityDeclaredDifference(
                [.recordWithINSDC: 10], "\(record2)reproducibleCommand", reason: record, closedBy: closer),
            RouteParityDeclaredDifference(
                [.recordWithINSDC: 19], "\(record2)steps[<ANY>].reproducibleCommand", reason: record, closedBy: closer),
            RouteParityDeclaredDifference(
                [.recordWithINSDC: 16], "\(record2)steps[<ANY>].id", reason: record, closedBy: closer),
            RouteParityDeclaredDifference(
                [.recordWithINSDC: 27], "\(record2)<ANY>checksumSHA256", reason: record, closedBy: closer),
            RouteParityDeclaredDifference(
                [.recordWithINSDC: 27], "\(record2)<ANY>fileSize", reason: record, closedBy: closer),
            RouteParityDeclaredDifference(
                [.recordWithINSDC: 3], "\(record2)steps[<ANY>].resolvedOptions.<ANY>", reason: naming, closedBy: closer),
            RouteParityDeclaredDifference(
                [.recordWithINSDC: 80], "\(record2)options.resolvedDefaults.fetchedRecord<ANY>",
                reason: "A record fetched from NCBI on the day of the run is a live snapshot (2.9 R3). The CLI route names it "
                    + "in each record file as a fetchedRecord entry in the shape of a Nextflow database entry, with the status, "
                    + "the date of the fetch and the kept sources/record.gb (A45 ruling K7). The in-process route keeps the "
                    + "record it wrote before 2.10, so side A holds none of the eight values in any of its record files.",
                closedBy: closer),
            RouteParityDeclaredDifference(
                [.recordWithINSDC: 110], "\(record2)options.resolvedDefaults.pathoplexusRecord<ANY>",
                reason: "The CLI route names the Pathoplexus record the bundle was built for in each record file: the organism, "
                    + "the accession as Pathoplexus resolved it, its version, the INSDC accession and the data use terms "
                    + "(BIO brief for M2, the record names each accession with its version). The in-process route records "
                    + "none of it, so side A holds none of the ten values in any of its record files.",
                closedBy: closer),
            RouteParityDeclaredDifference(
                [.recordWithoutINSDC: 12, .recordWithUnavailableINSDC: 12], "only in C: \(bundle)<ANY>lungfish-provenance.json",
                reason: "A bundle built from the Pathoplexus FASTA gets no provenance record from the in-process route, because "
                    + "the builder writes none. The CLI route writes the record the builder does not write (the fetch date, "
                    + "the status liveSnapshot, the digest of the FASTA the server sent, the Pathoplexus accession with its "
                    + "version), so the root record, its copy in provenance/ and each file's sidecar exist only on side C "
                    + "(BIO's declared difference, A45 ruling K7).",
                closedBy: closer),
            RouteParityDeclaredDifference(
                [.recordWithoutINSDC: 1, .recordWithUnavailableINSDC: 1], "only in C: \(bundle)sources/record.fasta",
                reason: "The CLI route keeps the FASTA the server sent as sources/record.fasta, because the record's "
                    + "fetchedRecord entry lists it and states its digest. The in-process route keeps nothing of it.",
                closedBy: closer),
        ]
    }()

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

    /// A restricted record is refused on both routes with the row's words, and neither route builds a bundle.
    func testARestrictedRecordIsRefusedOnBothRoutes() async throws {
        let (cli, root) = try await prepare()
        defer { TestTempDirectory.cleanup(root) }
        let stand = try await StandIns.start(in: root)
        defer { stand.stop() }
        let record = SearchResultRecord(
            id: PathoplexusLAPISStandIn.restricted, accession: PathoplexusLAPISStandIn.restricted,
            title: "Stand-in restricted record", source: .pathoplexus)
        for route in [PathoplexusRowDownloadRoute.legacy, .cli] {
            let project = root.appendingPathComponent("\(route.rawValue)/Project.lungfish", isDirectory: true)
            try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
            do {
                _ = try await Self.row(record, route: route, project: project, cli: cli)
                XCTFail("A restricted record downloads on the \(route.rawValue) route")
            } catch {
                XCTAssertTrue(
                    "\(error)".contains("Record PP_000003 is restricted and cannot be downloaded"), "\(route.rawValue): \(error)")
            }
            let walker = FileManager.default.enumerator(atPath: project.path)
            var bundles: [String] = []
            while let path = walker?.nextObject() as? String {
                if path.hasSuffix(".lungfishref") { bundles.append(path) }
            }
            XCTAssertEqual(bundles, [], "a refused record builds no bundle on the \(route.rawValue) route")
        }
    }

    func assertParity(_ parityCase: Case) async throws {
        let (cli, root) = try await prepare()
        defer { TestTempDirectory.cleanup(root) }
        let stand = try await StandIns.start(in: root)
        defer { stand.stop() }

        let record = Self.record(of: parityCase)
        let harness = RouteParityHarness(cliBinary: cli, kind: .bundle, replayTimeout: .seconds(120))
        let runs = try await harness.run(
            in: root.appendingPathComponent("case", isDirectory: true),
            fixture: DatabaseBrowserNucleotideRowParityReplayTests.makeProject,
            sideA: { try await Self.sideA($0, record: record) },
            sideC: { try await Self.sideC($0, cli: cli, record: record) }
        )
        let result = try harness.evaluate(parityCase, declared: Self.declared, runs: runs)
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

    /// One row of the browser's batch download by `route`, into `project`.
    static func row(_ record: SearchResultRecord, route: PathoplexusRowDownloadRoute, project: URL, cli: URL?) async throws -> URL {
        let service = NCBIService()
        return try await DatabaseBrowserViewModel.downloadPathoplexusRow(
            record, index: 0, totalCount: 1, operationID: UUID(), route: route, organism: PathoplexusLAPISStandIn.organism,
            ncbi: service, genBankVM: GenBankBundleDownloadViewModel(ncbiService: service), includeGFF3Annotations: true,
            batchFolder: BatchDownloadFolder(projectURL: project), projectURL: project, cliURLOverride: cli)
    }

    /// Side A. The in-process route of the row into one batch folder, then the import's copy of the
    /// bundle into Downloads.
    static func sideA(_ root: URL, record: SearchResultRecord) async throws -> RouteParitySideOutcome {
        let project = DatabaseBrowserNucleotideRowParityReplayTests.project(in: root)
        let built = try await row(record, route: .legacy, project: project, cli: nil)
        let downloads = project.appendingPathComponent("Downloads", isDirectory: true)
        try FileManager.default.createDirectory(at: downloads, withIntermediateDirectories: true)
        let imported = downloads.appendingPathComponent(built.lastPathComponent)
        try FileManager.default.copyItem(at: built, to: imported)
        // The sidebar's import rewrites the record's paths from the batch folder to the copy.
        ProvenancePathRehydrator.rehydrate(from: built, to: imported)
        try FileManager.default.removeItem(at: built)
        return RouteParitySideOutcome(end: .completed, detail: "in process")
    }

    /// Side C. The CLI route of the row, and the command the batch row records.
    static func sideC(_ root: URL, cli: URL, record: SearchResultRecord) async throws -> RouteParitySideOutcome {
        let project = DatabaseBrowserNucleotideRowParityReplayTests.project(in: root)
        let command = DatabaseBrowserViewModel.batchDownloadCLICommand(
            source: .pathoplexus, searchType: .nucleotide, accessions: [record.accession], projectURL: project,
            pathoplexusOrganism: PathoplexusLAPISStandIn.organism)
        do {
            _ = try await row(record, route: .cli, project: project, cli: cli)
        } catch {
            return RouteParitySideOutcome(end: .failed, detail: "\(error)", recordedCommand: command)
        }
        return RouteParitySideOutcome(end: .completed, detail: "exit 0", recordedCommand: command)
    }

    // MARK: - Helpers

    /// The loopback Pathoplexus and NCBI stand-ins, named in the process environment the in-process
    /// route reads and the child inherits, and no NCBI key.
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
