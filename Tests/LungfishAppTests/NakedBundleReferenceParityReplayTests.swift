// NakedBundleReferenceParityReplayTests.swift - The variant-only reference download and its recorded command
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.10 lane A44 M3, review A44-M2d rulings M3-1 to M3-3, panel decisions C4 and G5, on lane
// Q30's harness. A VCF imported with no reference leaves a variant-only bundle in the project, and
// the app then downloads the reference and merges it into that bundle. Phase 2.11 (K3) deleted the
// in-process route and its hidden key, so the download runs on the CLI route only. Each case runs
// on the two sides that are left, which start as copies of one project holding such a bundle.
//
// - Side C is the CLI route. The app finds the assembly the same way, or falls back to the VCF's
//   accession, records the command and launches `fetch genome <accession> --into-bundle <bundle>
//   --format json` through `CLISubprocessTransport`.
// - Side C' is the harness's replay of the command side C recorded.
//
// The loopback NCBI stand-in, which the process environment names, answers both sides. The record
// side C writes in the bundle's `genome/` folder must name each output it lists with that file's
// digest (B-5), and no other record may reach the bundle. C against C' declares nothing.
//
// It launches the built lungfish-cli and the managed bgzip and samtools, so its name ends in
// ReplayTests, which sends it to the integration tier.

import Foundation
import Synchronization
import XCTest
@testable import LungfishApp
@testable import LungfishCore
@testable import LungfishIO
@testable import LungfishWorkflow
import LungfishKit
import LungfishKitTestSupport
import LungfishTestSupport

@MainActor
final class NakedBundleReferenceParityReplayTests: XCTestCase {
    enum Case: String, Sendable {
        /// The VCF's header names the assembly by its accession.
        case assemblyByAccession
        /// The VCF names an assembly the app finds by organism and assembly name (ruling M3-1).
        case assemblyByName
        /// No assembly. The fallback fetches the GenBank record of the VCF's versioned accession
        /// (ruling M3-2, BIO's T1).
        case genBankFallback
    }

    /// What the import found in the VCF, the input of a case.
    struct Input: Sendable {
        let inferredRef: ReferenceInference.Result
        let ncbiAccessions: [String]
        /// The VCF's one chromosome.
        let chromosome: String
        /// The accession the app finds, which side C's command names.
        let fetched: String
    }

    static func input(of parityCase: Case) -> Input {
        let genBank = NCBIDownloadPinFixtures.genBankAccession
        switch parityCase {
        case .assemblyByAccession:
            return Input(
                inferredRef: reference(assembly: "StandInAsm1", accession: NCBIGenomeStandIn.assemblyAccession),
                ncbiAccessions: ["NC_000001.1"], chromosome: "NC_000001.1", fetched: NCBIGenomeStandIn.assemblyAccession)
        case .assemblyByName:
            return Input(
                inferredRef: reference(assembly: "StandInAsm1", accession: nil),
                ncbiAccessions: ["NC_000001.1"], chromosome: "NC_000001.1", fetched: NCBIGenomeStandIn.assemblyAccession)
        case .genBankFallback:
            // The stand-in's accession fails the RefSeq pattern of the import, so it is passed in.
            return Input(
                inferredRef: reference(assembly: nil, accession: nil),
                ncbiAccessions: [genBank], chromosome: genBank, fetched: genBank)
        }
    }

    static func reference(assembly: String?, accession: String?) -> ReferenceInference.Result {
        ReferenceInference.Result(
            assembly: assembly,
            organism: assembly == nil ? nil : "Lungfish stand-in organism",
            accession: accession,
            namingConvention: "RefSeq",
            confidence: assembly == nil ? .none : .high,
            sequenceCount: 1,
            totalLength: 150
        )
    }

    // MARK: - Cases

    /// The VCF names the assembly's accession. The app finds it by that accession, and the CLI
    /// merges the assembly's genome and annotations and writes its record.
    func testTheAssemblyTheVCFNamesMergesItsGenomeAndTheRecordedCommandReproducesIt() async throws {
        let (cli, root) = try await prepare()
        defer { TestTempDirectory.cleanup(root) }
        let runs = try await runParity(.assemblyByAccession, cli: cli, root: root)
        try Self.assertRecordedMerge(runs, of: .assemblyByAccession)
    }

    /// Ruling M3-1. The VCF names an assembly but no accession. The app still finds it by organism
    /// and assembly name, and the CLI fetches the accession it found.
    func testTheAssemblyFoundByNameMergesItsGenomeAndTheRecordedCommandReproducesIt() async throws {
        let (cli, root) = try await prepare()
        defer { TestTempDirectory.cleanup(root) }
        let runs = try await runParity(.assemblyByName, cli: cli, root: root)
        try Self.assertRecordedMerge(runs, of: .assemblyByName)
    }

    /// Ruling M3-2 with BIO's T1 and T2, T1 as BIO corrected it (A44-M3-BIO-2, ruling 7). No
    /// assembly, so the fallback fetches the GenBank record of the VCF's versioned accession. The
    /// fai, the manifest's chromosome and every annotation row name the sequence exactly as the
    /// VCF's CHROM, which matches with no alias. The track holds the five rows of NCBI's GFF3 and
    /// the sequence reads back its 150 bases.
    func testGenBankFallbackVariantReachesTheSequence() async throws {
        let (cli, root) = try await prepare()
        defer { TestTempDirectory.cleanup(root) }
        let runs = try await runParity(.genBankFallback, cli: cli, root: root)
        try Self.assertRecordedMerge(runs, of: .genBankFallback)

        let chrom = Self.input(of: .genBankFallback).chromosome
        for run in [runs.c, runs.cPrime] {
            let bundle = Self.bundle(in: run.root)
            XCTAssertEqual(try Self.faiNames(of: bundle), [chrom], "side \(run.side)")
            XCTAssertEqual(try BundleManifest.load(from: bundle).genome?.chromosomes.map(\.name), [chrom], "side \(run.side)")
            XCTAssertEqual(Set(try Self.annotationRows(of: bundle).map(\.chromosome)), [chrom], "side \(run.side)")
        }
        let bundleC = Self.bundle(in: runs.c.root)
        XCTAssertEqual(try Self.annotationRows(of: bundleC).count, 5)
        let basesC = try await Self.bases(of: bundleC, chromosome: chrom)
        XCTAssertEqual(basesC.count, 150)

        let chromosomesC = try XCTUnwrap(BundleManifest.load(from: bundleC).genome?.chromosomes)
        XCTAssertEqual(mapVCFChromosomes([chrom], toBundleChromosomes: chromosomesC), [:])
    }

    /// BIO's second ruling on M3-2, outside its table. For a record NCBI serves no GFF3 for, the
    /// CLI merges the genome and adds no annotation track. Not a parity case, because the fallback
    /// takes only a versioned RefSeq name, for which NCBI has a GFF3.
    func testWithoutAnNCBIGFF3TheFallbackMergesTheGenomeAndAddsNoTrack() async throws {
        let (cli, root) = try await prepare()
        defer { TestTempDirectory.cleanup(root) }
        let server = try await NCBIGenomeStandIn.start(servingIn: root.appendingPathComponent("served", isDirectory: true))
        defer { server.stop() }
        let saved = ProcessEnvironmentOverride(
            set: [NCBIServiceEndpoints.standInOriginVariable: server.baseURL.absoluteString], unset: ["NCBI_API_KEY"])
        defer { saved.restore() }

        let accession = NCBIGenomeStandIn.recordWithoutGFF3Accession
        let input = Input(
            inferredRef: Self.reference(assembly: nil, accession: nil),
            ncbiAccessions: [accession], chromosome: accession, fetched: accession)
        let sideRoot = root.appendingPathComponent("cli", isDirectory: true)
        try Self.makeProject(sideRoot, chromosome: accession)
        let outcome = try await Self.side(sideRoot, input: input, cli: cli)
        XCTAssertEqual(outcome.end, .completed, outcome.detail)
        let manifest = try BundleManifest.load(from: Self.bundle(in: sideRoot))
        XCTAssertEqual(manifest.genome?.chromosomes.map(\.name), [accession], "the CLI merges the genome")
        XCTAssertEqual(manifest.annotations.map(\.id), [], "the CLI adds no track without an NCBI GFF3")
    }

    // MARK: - Running a case

    /// Runs `parityCase` on its two sides in `root` against the stand-in and checks that C against
    /// C' lists nothing and both sides merged.
    func runParity(_ parityCase: Case, cli: URL, root: URL) async throws -> RouteParityRuns {
        let server = try await NCBIGenomeStandIn.start(servingIn: root.appendingPathComponent("served", isDirectory: true))
        defer { server.stop() }
        let saved = ProcessEnvironmentOverride(
            set: [NCBIServiceEndpoints.standInOriginVariable: server.baseURL.absoluteString], unset: ["NCBI_API_KEY"])
        defer { saved.restore() }

        let input = Self.input(of: parityCase)
        let harness = RouteParityHarness(cliBinary: cli, kind: .bundle, replayTimeout: .seconds(120))
        let runs = try await ReadsRouteParity.runCAndCPrime(
            harness,
            in: root.appendingPathComponent("case", isDirectory: true),
            fixture: { try Self.makeProject($0, chromosome: input.chromosome) },
            sideC: { try await Self.side($0, input: input, cli: cli) }
        )
        let found = try harness.differences(runs.c, runs.cPrime)
        RouteParityHarness.assertNoFailures(found.map { "\($0.id): \($0.detail)" }, in: "\(parityCase), C against C'")
        for run in [runs.c, runs.cPrime] {
            XCTAssertEqual(run.outcome.end, .completed, "side \(run.side): \(run.outcome.detail)")
        }
        XCTAssertEqual(
            runs.cPrime.replayedArguments.map { Array($0.prefix(3)) }, [["fetch", "genome", input.fetched]],
            "side C' replays the one fetch genome command side C recorded")
        return runs
    }

    /// One side, the site's download into the side's variant-only bundle, and the command its row
    /// recorded.
    static func side(_ root: URL, input: Input, cli: URL) async throws -> RouteParitySideOutcome {
        let recorded = RecordedCommandBox()
        do {
            let found = try await MainSplitViewController.downloadNakedBundleReference(
                inferredRef: input.inferredRef,
                ncbiAccessions: input.ncbiAccessions,
                bundleURL: bundle(in: root),
                operationID: UUID(),
                cliURLOverride: cli
            ) { recorded.set($0) }
            return RouteParitySideOutcome(
                end: found ? .completed : .failed, detail: found ? "merged" : "no reference found",
                recordedCommand: recorded.value)
        } catch {
            return RouteParitySideOutcome(end: .failed, detail: "\(error)", recordedCommand: recorded.value)
        }
    }

    /// B-5 and the merge's own record. On each side the one record in the bundle is the run's, in
    /// `genome/`, which names the accession fetched and each output with the digest it has, so no
    /// record of the builder's staging reached the bundle. The row of side C records the `fetch
    /// genome` command of the accession found, for its bundle.
    static func assertRecordedMerge(_ runs: RouteParityRuns, of parityCase: Case) throws {
        let fetched = input(of: parityCase).fetched
        XCTAssertEqual(
            try RecordedCLICommand.arguments(of: runs.c.outcome.recordedCommand),
            MainSplitViewController.nakedBundleReferenceFetchArguments(accession: fetched, bundleURL: bundle(in: runs.c.root)),
            "side C records the command of the accession found")
        for run in [runs.c, runs.cPrime] {
            let target = bundle(in: run.root)
            XCTAssertEqual(try recordPaths(in: target), ["genome/.lungfish-provenance.json"], "side \(run.side)")
            let genome = target.appendingPathComponent("genome", isDirectory: true)
            let envelope = try XCTUnwrap(ProvenanceRecorder.loadEnvelope(from: genome), "side \(run.side) wrote no record")
            XCTAssertTrue(envelope.argv.contains(fetched), "side \(run.side): \(envelope.argv)")
            XCTAssertFalse(envelope.outputs.isEmpty, "side \(run.side)")
            for output in envelope.outputs {
                let url = URL(fileURLWithPath: output.path)
                XCTAssertTrue(output.path.contains("/Cohort calls.lungfishref/"), "side \(run.side): \(output.path)")
                XCTAssertTrue(FileManager.default.fileExists(atPath: url.path), "side \(run.side): \(output.path)")
                let stated = try XCTUnwrap(output.checksumSHA256, "side \(run.side): \(output.path)")
                XCTAssertEqual(try ProvenanceFileHasher.sha256(of: url), stated, "side \(run.side): \(output.path)")
            }
        }
    }

    // MARK: - Fixture and readers

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
        return (cli, try TestTempDirectory.make(prefix: "naked-reference-parity"))
    }

    /// A project holding the bundle a VCF import with no reference leaves, one variant on
    /// `chromosome`, a variant track and no genome.
    static func makeProject(_ root: URL, chromosome: String) throws {
        let project = root.appendingPathComponent("Project.lungfish", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        _ = try FetchGenomeCLIBundlePinConformanceTests.makeVariantOnlyBundle(in: project, chromosome: chromosome)
    }

    /// The variant-only bundle of a side root.
    static func bundle(in root: URL) -> URL {
        root.appendingPathComponent("Project.lungfish/Cohort calls.lungfishref", isDirectory: true)
    }

    /// Every provenance record in `bundle`, by its path in the bundle.
    static func recordPaths(in bundle: URL) throws -> [String] {
        let names = FileManager.default.enumerator(atPath: bundle.path)?.compactMap { $0 as? String } ?? []
        return names.filter { $0.hasSuffix(ProvenanceRecorder.provenanceFilename) }.sorted()
    }

    /// The sequence names of the bundle's FASTA index.
    static func faiNames(of bundle: URL) throws -> [String] {
        let manifest = try BundleManifest.load(from: bundle)
        let index = try XCTUnwrap(manifest.genome?.indexPath)
        let text = try String(contentsOf: bundle.appendingPathComponent(index), encoding: .utf8)
        return text.split(separator: "\n").compactMap { $0.split(separator: "\t").first.map(String.init) }
    }

    /// Every row of every annotation track of the bundle.
    static func annotationRows(of bundle: URL) throws -> [AnnotationDatabaseRecord] {
        let manifest = try BundleManifest.load(from: bundle)
        XCTAssertFalse(manifest.annotations.isEmpty, "\(bundle.lastPathComponent) has no annotation track")
        return try manifest.annotations.flatMap { track in
            let database = try AnnotationDatabase(url: bundle.appendingPathComponent(track.databasePath ?? track.path))
            return database.query(nameFilter: "", types: [], limit: 5000)
        }
    }

    /// A row as its place, strand, type and name, to compare the rows of two tracks.
    static func describe(_ row: AnnotationDatabaseRecord) -> String {
        "\(row.chromosome):\(row.start)-\(row.end) \(row.strand) \(row.type) \(row.name)"
    }

    /// The whole of the bundle's 150-base sequence `chromosome`, read through its fai.
    static func bases(of bundle: URL, chromosome: String) async throws -> String {
        let reference = try await ReferenceBundle(url: bundle)
        return try await reference.fetchSequence(region: GenomicRegion(chromosome: chromosome, start: 0, end: 150))
    }
}

/// The command a side's row recorded, set from the download's task.
private final class RecordedCommandBox: Sendable {
    private let command = Mutex<String?>(nil)

    func set(_ value: String) {
        command.withLock { $0 = value }
    }

    var value: String? {
        command.withLock { $0 }
    }
}
