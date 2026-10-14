// NakedBundleReferenceParityReplayTests.swift - The variant-only reference download, in process against lungfish-cli
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.10 lane A44 M3, review A44-M2d rulings M3-1 to M3-3, panel decisions C4 and G5, on lane
// Q30's harness. A VCF imported with no reference leaves a variant-only bundle in the project, and
// the app then downloads the reference and merges it into that bundle. Each case runs on three
// sides that start as copies of one project holding such a bundle.
//
// - Side A is the in-process route the hidden key keeps for one release. The app finds the
//   assembly and builds its bundle in the project's `.tmp` folder, or with no assembly builds the
//   GenBank record of the VCF's accession, and merges the genome and annotations in.
// - Side C is the CLI route. The app finds the assembly the same way, or falls back to the VCF's
//   accession, records the command and launches `fetch genome <accession> --into-bundle <bundle>
//   --format json` through `CLISubprocessTransport`.
// - Side C' is the harness's replay of the command side C recorded.
//
// Both routes read the loopback NCBI stand-in, which the process environment names. The record
// side C writes in the bundle's `genome/` folder must name each output it lists with that file's
// digest (B-5), and no other record may reach the bundle. Both routes record the same command.
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

    static let closer = "2.11, which deletes the in-process reference download with its key (C4)"

    /// What side C writes that side A does not, and the reverse, with BIO's reason.
    static let declared: [RouteParityDeclaredDifference<Case>] = [
        RouteParityDeclaredDifference(
            [.assemblyByAccession: 1, .assemblyByName: 1, .genBankFallback: 1],
            "only in C: Project.lungfish/Cohort calls.lungfishref/genome/.lungfish-provenance.json",
            reason: "fetch genome --into-bundle writes the record of what it fetched, each file with its source URL, "
                + "digest and size (B-3), in the genome folder it merged. The in-process route writes no record, the "
                + "declared difference that keeps its key (C4).",
            closedBy: closer
        ),
    ] + genBankFallbackDeclared

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

    /// The VCF names the assembly's accession. Both routes find it by that accession, and the CLI
    /// merges the same genome and annotations and writes its record.
    func testTheAssemblyTheVCFNamesMergesTheSameGenomeOnBothRoutes() async throws {
        let (cli, root) = try await prepare()
        defer { TestTempDirectory.cleanup(root) }
        let runs = try await runParity(.assemblyByAccession, cli: cli, root: root)
        try Self.assertRecordedMerge(runs, of: .assemblyByAccession)
    }

    /// Ruling M3-1. The VCF names an assembly but no accession. The app still finds it by organism
    /// and assembly name on both routes, and the CLI fetches the accession it found.
    func testTheAssemblyFoundByNameMergesTheSameGenomeOnBothRoutes() async throws {
        let (cli, root) = try await prepare()
        defer { TestTempDirectory.cleanup(root) }
        let runs = try await runParity(.assemblyByName, cli: cli, root: root)
        try Self.assertRecordedMerge(runs, of: .assemblyByName)
    }

    /// Ruling M3-2 with BIO's T1 and T2, T1 as BIO corrected it (A44-M3-BIO-2, ruling 7). No
    /// assembly, so the fallback fetches the GenBank record of the VCF's versioned accession. On the
    /// CLI route the fai, the manifest's chromosome and every annotation row name the sequence
    /// exactly as the VCF's CHROM, which matches with no alias. The in-process route names the
    /// sequence by the record's LOCUS name and reaches it through its alias. Its annotation rows come
    /// from NCBI's GFF3, which it prefers to the record's FEATURES, so they keep the versioned name,
    /// and both tracks hold the same rows. Both sides read the same bases through their own fai,
    /// which the declared FASTA layout needs (BIO's second ruling, 1).
    func testGenBankFallbackVariantReachesTheSequenceOnBothRoutes() async throws {
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
        let bundleA = Self.bundle(in: runs.a.root)
        let bundleC = Self.bundle(in: runs.c.root)
        XCTAssertEqual(try Self.faiNames(of: bundleA), ["ZZ000001"], "side A names the sequence by the LOCUS name")
        let rowsA = try Self.annotationRows(of: bundleA).map(Self.describe).sorted()
        XCTAssertEqual(rowsA.count, 5)
        XCTAssertEqual(rowsA, try Self.annotationRows(of: bundleC).map(Self.describe).sorted(),
                       "side A's rows come from NCBI's GFF3 too, on the versioned name")
        let basesA = try await Self.bases(of: bundleA, chromosome: "ZZ000001")
        XCTAssertEqual(basesA.count, 150)
        let basesC = try await Self.bases(of: bundleC, chromosome: chrom)
        XCTAssertEqual(basesA, basesC, "both sides read the same bases through their own fai")

        let chromosomesC = try XCTUnwrap(BundleManifest.load(from: bundleC).genome?.chromosomes)
        XCTAssertEqual(mapVCFChromosomes([chrom], toBundleChromosomes: chromosomesC), [:])
        let chromosomesA = try XCTUnwrap(BundleManifest.load(from: bundleA).genome?.chromosomes)
        XCTAssertEqual(mapVCFChromosomes([chrom], toBundleChromosomes: chromosomesA), [chrom: "ZZ000001"])
    }

    /// BIO's second ruling on M3-2, outside its table, which `.legacy`'s doc states. For a record
    /// NCBI serves no GFF3 for, the in-process fallback converts the record's FEATURES into a track
    /// on the LOCUS name, where the CLI merges the genome with no annotation track. Not a parity
    /// case, because the fallback takes only a versioned RefSeq name, for which NCBI has a GFF3.
    func testWithoutAnNCBIGFF3OnlyTheInProcessFallbackAddsATrack() async throws {
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
        var bundles: [NakedBundleReferenceRoute: URL] = [:]
        for route in NakedBundleReferenceRoute.allCases {
            let sideRoot = root.appendingPathComponent(route.rawValue, isDirectory: true)
            try Self.makeProject(sideRoot, chromosome: accession)
            let outcome = try await Self.side(sideRoot, route: route, input: input, cli: route == .cli ? cli : nil)
            XCTAssertEqual(outcome.end, .completed, "\(route): \(outcome.detail)")
            bundles[route] = Self.bundle(in: sideRoot)
        }
        let cliManifest = try BundleManifest.load(from: try XCTUnwrap(bundles[.cli]))
        XCTAssertEqual(cliManifest.genome?.chromosomes.map(\.name), [accession], "the CLI merges the genome")
        XCTAssertEqual(cliManifest.annotations.map(\.id), [], "the CLI adds no track without an NCBI GFF3")
        let legacyRows = try Self.annotationRows(of: try XCTUnwrap(bundles[.legacy]))
        XCTAssertFalse(legacyRows.isEmpty, "the in-process build converts the record's FEATURES")
        XCTAssertEqual(Set(legacyRows.map(\.chromosome)), ["ZZ000002"], "FEATURES rows sit on the LOCUS name")
    }

    // MARK: - Running a case

    /// Runs `parityCase` on its three sides in `root` against the stand-in and checks that C
    /// against C' lists nothing, A against C exactly the declared entries, and every side merged.
    func runParity(_ parityCase: Case, cli: URL, root: URL) async throws -> RouteParityRuns {
        let server = try await NCBIGenomeStandIn.start(servingIn: root.appendingPathComponent("served", isDirectory: true))
        defer { server.stop() }
        let saved = ProcessEnvironmentOverride(
            set: [NCBIServiceEndpoints.standInOriginVariable: server.baseURL.absoluteString], unset: ["NCBI_API_KEY"])
        defer { saved.restore() }

        let input = Self.input(of: parityCase)
        let harness = RouteParityHarness(cliBinary: cli, kind: .bundle, replayTimeout: .seconds(120))
        let runs = try await harness.run(
            in: root.appendingPathComponent("case", isDirectory: true),
            fixture: { try Self.makeProject($0, chromosome: input.chromosome) },
            sideA: { try await Self.side($0, route: .legacy, input: input, cli: nil) },
            sideC: { try await Self.side($0, route: .cli, input: input, cli: cli) }
        )
        let result = try harness.evaluate(parityCase, declared: Self.declared, runs: runs)
        RouteParityHarness.assertNoFailures(result.failures, in: "\(parityCase)")
        for run in runs.all {
            XCTAssertEqual(run.outcome.end, .completed, "side \(run.side): \(run.outcome.detail)")
        }
        XCTAssertEqual(
            runs.cPrime.replayedArguments.map { Array($0.prefix(3)) }, [["fetch", "genome", input.fetched]],
            "side C' replays the one fetch genome command side C recorded")
        return runs
    }

    /// One side, the site's download on `route` into the side's variant-only bundle, and the
    /// command its row recorded.
    static func side(_ root: URL, route: NakedBundleReferenceRoute, input: Input, cli: URL?) async throws -> RouteParitySideOutcome {
        let recorded = RecordedCommandBox()
        do {
            let found = try await MainSplitViewController.downloadNakedBundleReference(
                inferredRef: input.inferredRef,
                ncbiAccessions: input.ncbiAccessions,
                bundleURL: bundle(in: root),
                operationID: UUID(),
                route: route,
                cliURLOverride: cli
            ) { recorded.set($0) }
            return RouteParitySideOutcome(
                end: found ? .completed : .failed, detail: found ? "merged" : "no reference found",
                recordedCommand: recorded.value)
        } catch {
            return RouteParitySideOutcome(end: .failed, detail: "\(error)", recordedCommand: recorded.value)
        }
    }

    /// B-5 and the merge's own record. On each CLI side the one record in the bundle is the run's,
    /// in `genome/`, which names the accession fetched and each output with the digest it has, so
    /// no record of the builder's staging reached the bundle. Side A writes none. The row of each
    /// route records the `fetch genome` command of the accession found, for its own bundle.
    static func assertRecordedMerge(_ runs: RouteParityRuns, of parityCase: Case) throws {
        let fetched = input(of: parityCase).fetched
        XCTAssertEqual(try recordPaths(in: bundle(in: runs.a.root)), [], "side A writes no record")
        for run in [runs.a, runs.c] {
            XCTAssertEqual(
                try RecordedCLICommand.arguments(of: run.outcome.recordedCommand),
                MainSplitViewController.nakedBundleReferenceFetchArguments(accession: fetched, bundleURL: bundle(in: run.root)),
                "side \(run.side) records the command of the accession found")
        }
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

// MARK: - The GenBank fallback's signed lines

extension NakedBundleReferenceParityReplayTests {
    /// BIO's reasons for the lines the GenBank fallback lists A against C. T1 to T3 are BIO's first
    /// ruling on M3-2 (A44-M3-BIO), T1 as the second corrects it, and rulings 1 to 6 are BIO's
    /// second ruling (A44-M3-BIO-2), which signed the rest of the table with no change on side C.
    enum FallbackReason {
        static let name = "T1 and T3. C names the sequence from the record's FASTA header, the VCF's CHROM with its "
            + "version, so a variant matches it with no alias. A names it by the LOCUS name, which drops the version, "
            + "and lists the CHROM as its alias. C lists the bare accession as its alias, so A's name still resolves."
        static let index = "T1 and ruling 1. The fai names the sequence as the manifest does, and its offset and line "
            + "fields follow each side's FASTA layout. Every reader takes the layout from the fai."
        static let layout = "Ruling 1. C keeps the FASTA lines NCBI serves, one 150-base line from the stand-in, where A "
            + "rewraps them at 60 bases. Every reader takes offset, line_bases and line_width from the fai, none "
            + "assumes 60, and both sides read the same bases."
        static let title = "T1 and ruling 2. The FASTA header names the sequence as the manifest does, and past the name "
            + "the title differs only by DEFINITION's final period. No reader parses the defline, the app reads "
            + "fasta_description."
        static let plainFASTA = "Ruling 3. The plain FASTA is the bgzip input the in-process GenBank builder keeps and "
            + "the merge copies in. The manifest names sequence.fa.gz on both sides, and no reader depends on it."
        static let description = "Ruling 4, a gain on C. The track header and navigator show the sequence with its "
            + "title, the record table's search finds it and exports write it into the defline. Name matching reads it "
            + "only after the exact and alias steps."
        static let source = "Ruling 5. organism is the record's title on both sides, A's with DEFINITION's period, "
            + "which ploidy's word match ignores. assembly is each side's sequence name. A's assembly_accession is a "
            + "nucleotide accession that lineage reads only without a source_url, which both sides hold the same. No "
            + "code reads notes, and C's provenance record says more."
        static let track = "T1 and ruling 6. Both tracks hold the same rows of NCBI's GFF3 for the revision fetched, "
            + "under the id, path, name, type, description and source each builder gives its track. No reader branches "
            + "on a track's type."
    }

    /// Every line the GenBank fallback lists A against C, each declared once with its measured
    /// count, so M3's key keeps the in-process fallback for one release (C4).
    static let genBankFallbackDeclared: [RouteParityDeclaredDifference<Case>] = {
        let bundle = "Project.lungfish/Cohort calls.lungfishref"
        let manifest = "differs: \(bundle)/manifest.json at "
        let fasta = "differs: \(bundle)/genome/sequence.fa.gz: only in "
        let fai = "differs: \(bundle)/genome/sequence.fa.gz.fai: only in "
        let linesA = [
            "ATGTCTACGAACCCAAAACCTCAAAGAAAAACCAAACGTAACACCAACCGTCGCCCACAG",
            "GACGTCAAGTTCCCGGGCGGTGGTCAGATCGTTGGTGGAGTTTACTTGTTGCCGCGCAGG",
            "GGCCCTAGATTGGGTGTGCGCGCGACGTAA",
        ]
        let title = " Lungfish stand-in virus isolate LGE-1 segment 1, complete sequence"
        var lines: [(id: String, reason: String)] = [
            (manifest + "genome.chromosomes[0].name", FallbackReason.name),
            (manifest + "genome.chromosomes[0].aliases[0]", FallbackReason.name),
            (manifest + "browser_summary.sequences[0].name", FallbackReason.name),
            (manifest + "browser_summary.sequences[0].aliases[0]", FallbackReason.name),
            (fai + "A: ZZ000001\t150\t78\t60\t61", FallbackReason.index),
            (fai + "C: ZZ000001.1\t150\t79\t150\t151", FallbackReason.index),
            (manifest + "genome.chromosomes[0].offset", FallbackReason.layout),
            (manifest + "genome.chromosomes[0].line_bases", FallbackReason.layout),
            (manifest + "genome.chromosomes[0].line_width", FallbackReason.layout),
        ]
        lines += linesA.map { (id: fasta + "A: " + $0, reason: FallbackReason.layout) }
        lines += [
            (fasta + "C: " + linesA.joined(), FallbackReason.layout),
            (fasta + "A: >ZZ000001" + title + ".", FallbackReason.title),
            (fasta + "C: >ZZ000001.1" + title, FallbackReason.title),
            ("only in A: \(bundle)/genome/sequence.fa", FallbackReason.plainFASTA),
            (manifest + "genome.chromosomes[0].fasta_description", FallbackReason.description),
            (manifest + "browser_summary.sequences[0].displayDescription", FallbackReason.description),
            (manifest + "source.organism", FallbackReason.source),
            (manifest + "source.assembly", FallbackReason.source),
            (manifest + "source.assembly_accession", FallbackReason.source),
            (manifest + "source.notes", FallbackReason.source),
            (manifest + "annotations[0].id", FallbackReason.track),
            (manifest + "annotations[0].path", FallbackReason.track),
            (manifest + "annotations[0].database_path", FallbackReason.track),
            (manifest + "annotations[0].name", FallbackReason.track),
            (manifest + "annotations[0].annotation_type", FallbackReason.track),
            (manifest + "annotations[0].description", FallbackReason.track),
            (manifest + "annotations[0].source", FallbackReason.track),
            ("only in A: \(bundle)/annotations/ncbi_gff3_annotations.db", FallbackReason.track),
            ("only in C: \(bundle)/annotations/annotations.db", FallbackReason.track),
        ]
        return lines.map { RouteParityDeclaredDifference([.genBankFallback: 1], $0.id, reason: $0.reason, closedBy: closer) }
    }()
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
