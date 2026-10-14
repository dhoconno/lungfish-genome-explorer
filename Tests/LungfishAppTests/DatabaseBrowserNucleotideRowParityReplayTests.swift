// DatabaseBrowserNucleotideRowParityReplayTests.swift - The NCBI browser's nucleotide row, in process against lungfish-cli
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.10 lane A45, panel decisions C4 and G5, on lane Q30's harness. One nucleotide row of the
// NCBI browser's batch download, with a project, runs on three sides that start as copies of one
// empty project, as the genome row's class (lane A44) runs its sides.
//
// - Side A is the in-process route the hidden key keeps for one release. It builds the bundle in a
//   batch folder under the project's `.tmp` folder, and the import then copies the bundle into the
//   project's Downloads folder and removes the built one.
// - Side C is the CLI route, `fetch ncbi <accession> --bundle --output-dir <project>/Downloads
//   --format json` launched through `CLISubprocessTransport`.
// - Side C' is the harness's replay of the row's recorded command.
//
// Both routes read the loopback NCBI stand-in, which the process environment names. It launches the
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

    static let closer = "2.11, which deletes the in-process nucleotide row with its key (C4)"

    /// Each way side C differs from side A with BIO's reason, as measured (the counts are exact).
    /// The batch folder's name holds a UUID, numbered by its place in the tree.
    static let declared: [RouteParityDeclaredDifference<Case>] = {
        let naming = "The CLI route names the one sequence by the accession with its version, the CHROM of a VCF, with the "
            + "bare accession and the LOCUS name as aliases (A44 ruling M3-2 term 4, BIO test T4). The in-process route "
            + "names it by the LOCUS name, so the FASTA header, the index, the manifest's names and offset and, with no "
            + "GFF3, the FEATURES track's chromosome differ."
        let record = "Both routes write the builder's record, rewritten in the CLI's case to the final place. The run's "
            + "argument vector is the CLI's own, so each argv, each replay command and each step id differs, and the "
            + "digests of the three files the renamed sequence changes follow from the naming. The bundle's root record "
            + "and its copy in provenance/ hold every step of the run, so they carry about half of the values. The "
            + "harness explains a provenance envelope up to 1,000 values, each with an exact count (A45 M1 ruling, section 3)."
        let bundle = "<ANY>/Downloads/<ANY>.lungfishref/"
        return [
            RouteParityDeclaredDifference(
                [.recordWithGFF3: 1, .recordWithoutGFF3: 1],
                "only in A: Project.lungfish/.tmp/batch-<UUID-<ANY>>/.lungfish-owned-work-directory.json",
                reason: "The in-process route builds the bundle in a batch folder under the project's .tmp folder, and the "
                    + "import copies the bundle out and leaves the folder with its owner marker. The CLI route stages in "
                    + "a folder of its own under .tmp and removes it.",
                closedBy: closer),
            RouteParityDeclaredDifference(
                [.recordWithGFF3: 6, .recordWithoutGFF3: 6], "differs: <ANY>/genome/sequence.fa<ANY>: only in <ANY>",
                reason: naming, closedBy: closer),
            RouteParityDeclaredDifference(
                [.recordWithoutGFF3: 10], "differs: <ANY>/annotations/ncbi_genbank_annotations.db: only in <ANY>",
                reason: naming, closedBy: closer),
            RouteParityDeclaredDifference(
                [.recordWithGFF3: 2, .recordWithoutGFF3: 2], "differs: <ANY>/manifest.json at browser_summary.sequences[0].<ANY>",
                reason: naming, closedBy: closer),
            RouteParityDeclaredDifference(
                [.recordWithGFF3: 3, .recordWithoutGFF3: 3], "differs: <ANY>/manifest.json at genome.chromosomes[0].<ANY>",
                reason: naming, closedBy: closer),
            RouteParityDeclaredDifference(
                [.recordWithGFF3: 12, .recordWithoutGFF3: 12], "differs: <ANY>/manifest.json at metadata[<ANY>].id",
                reason: "The manifest's metadata groups carry fresh UUIDs on every build, masked and numbered by their place "
                    + "in the tree. The records ahead of the manifest hold other ids, so the numbers differ.",
                closedBy: closer),
            RouteParityDeclaredDifference(
                [.recordWithGFF3: 90, .recordWithoutGFF3: 81], "differs: \(bundle)<ANY>lungfish-provenance.json at argv[<ANY>",
                reason: record, closedBy: closer),
            RouteParityDeclaredDifference(
                [.recordWithGFF3: 61, .recordWithoutGFF3: 61], "differs: \(bundle)<ANY>lungfish-provenance.json at steps[<ANY>].argv[<ANY>",
                reason: record, closedBy: closer),
            RouteParityDeclaredDifference(
                [.recordWithGFF3: 10, .recordWithoutGFF3: 9], "differs: \(bundle)<ANY>lungfish-provenance.json at reproducibleCommand",
                reason: record, closedBy: closer),
            RouteParityDeclaredDifference(
                [.recordWithGFF3: 19, .recordWithoutGFF3: 16],
                "differs: \(bundle)<ANY>lungfish-provenance.json at steps[<ANY>].reproducibleCommand",
                reason: record, closedBy: closer),
            RouteParityDeclaredDifference(
                [.recordWithGFF3: 16, .recordWithoutGFF3: 13], "differs: \(bundle)<ANY>lungfish-provenance.json at steps[<ANY>].id",
                reason: record, closedBy: closer),
            RouteParityDeclaredDifference(
                [.recordWithGFF3: 27, .recordWithoutGFF3: 27], "differs: \(bundle)<ANY>lungfish-provenance.json at <ANY>checksumSHA256",
                reason: record, closedBy: closer),
            RouteParityDeclaredDifference(
                [.recordWithGFF3: 27, .recordWithoutGFF3: 27], "differs: \(bundle)<ANY>lungfish-provenance.json at <ANY>fileSize",
                reason: record, closedBy: closer),
            RouteParityDeclaredDifference(
                [.recordWithGFF3: 3, .recordWithoutGFF3: 6],
                "differs: \(bundle)<ANY>lungfish-provenance.json at steps[<ANY>].resolvedOptions.<ANY>",
                reason: naming, closedBy: closer),
        ]
    }()

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

    /// One nucleotide row with a project. C against C' lists nothing, and A against C exactly the
    /// declared entries. The class prints what it measured when they differ.
    func testTheRecordWithGFF3BuildsTheBrowsersBundleOnBothRoutes() async throws {
        try await assertParity(.recordWithGFF3)
    }

    /// NCBI serves no GFF3 for the record, so both routes take the track from its FEATURES.
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
        let runs = try await harness.run(
            in: root.appendingPathComponent("case", isDirectory: true),
            fixture: Self.makeProject,
            sideA: { try await Self.sideA($0, record: record) },
            sideC: { try await Self.sideC($0, cli: cli, record: record) }
        )
        let result = try harness.evaluate(parityCase, declared: Self.declared, runs: runs)
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

    /// Side A. The in-process route of the row into one batch folder, then the import's copy of the
    /// bundle into Downloads.
    static func sideA(_ root: URL, record: SearchResultRecord) async throws -> RouteParitySideOutcome {
        let project = project(in: root)
        let service = NCBIService()
        let built = try await DatabaseBrowserViewModel.downloadNucleotideRow(
            record, index: 0, totalCount: 1, operationID: UUID(), route: .legacy, ncbi: service,
            genBankVM: GenBankBundleDownloadViewModel(ncbiService: service), includeGFF3Annotations: true,
            batchFolder: BatchDownloadFolder(projectURL: project), projectURL: project)
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
        let project = project(in: root)
        let service = NCBIService()
        let command = DatabaseBrowserViewModel.batchDownloadCLICommand(
            source: .ncbi, searchType: .nucleotide, accessions: [record.accession], projectURL: project)
        do {
            _ = try await DatabaseBrowserViewModel.downloadNucleotideRow(
                record, index: 0, totalCount: 1, operationID: UUID(), route: .cli, ncbi: service,
                genBankVM: GenBankBundleDownloadViewModel(ncbiService: service), includeGFF3Annotations: true,
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
