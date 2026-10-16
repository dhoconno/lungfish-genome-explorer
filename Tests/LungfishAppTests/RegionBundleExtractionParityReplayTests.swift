// RegionBundleExtractionParityReplayTests.swift - The region extraction in process against extract sequence --bundle
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.11 lane A48 M2, plan decisions C4 and C5 of 2.10 and G1, on lane Q30's harness. The viewer
// builds a reference bundle of a region or a feature, with the source bundle's annotation and variant
// tracks and the samples it shows. Each case runs on three sides that start as copies of one project
// with one source bundle.
//
// - Side A is the in-process route at the base, `SequenceExtractionPipeline().buildBundle`, with the
//   tracks and the sample filter the site collected.
// - Side C is the CLI route, the begin helper the site calls and `CLIBundleBuildRunner`, which launches
//   the built `lungfish-cli extract sequence --bundle` on the argv of
//   `SequenceExtractionPipeline.cliArguments`. Its row records the command.
// - Side C' is the harness's replay of that command.
//
// A against C declares each difference, every one in the run's record, since the CLI's record names
// its own command (docs/contracts/CLI-EQUIVALENCE.md). C against C' declares nothing.
//
// It runs the managed bgzip and samtools faidx and launches the built lungfish-cli, so its name ends in
// ReplayTests, which sends it to the integration tier, and it skips without the tools unless
// `LUNGFISH_REQUIRE_TOOLS=1`.

import Foundation
import XCTest
@testable import LungfishApp
import LungfishCore
import LungfishIO
import LungfishKit
import LungfishKitTestSupport
import LungfishTestSupport
@testable import LungfishWorkflow

@MainActor
final class RegionBundleExtractionParityReplayTests: XCTestCase {
    enum Case: String, Sendable {
        /// A region with both tracks and two of three samples, whose names hold dots and spaces (BIO 5).
        case regionWithSamples
        /// A reverse-strand feature of two parts, joined and reverse complemented (review N2).
        case reverseFeature
    }

    /// Every difference is the record's statement of the command, in the bundle's root record and in
    /// each per-file record under `provenance/`. The bundles, their manifests, genomes, tracks and
    /// sample filters, and every other line of each record are the same.
    static let declared: [RouteParityDeclaredDifference<Case>] = {
        let record = "differs: Project.lungfish/Extractions/<ANY>.json at "
        let closedBy = "Never. The recorded command changes by design (docs/contracts/CLI-EQUIVALENCE.md)"
        let argv = ["argv[<ANY>]", "steps[<ANY>].argv[<ANY>]"].map { key in
            RouteParityDeclaredDifference<Case>(
                [.regionWithSamples: 152, .reverseFeature: 120],
                record + key,
                reason: "The pipeline records `lungfish-gui sequence extract-bundle` with its own options, and the "
                    + "CLI route records the `lungfish-cli extract sequence --bundle` argv its row recorded, so each "
                    + "word of the argv differs in the root record and in each per-file record (review N1 of A48 M1).",
                closedBy: closedBy
            )
        }
        let identity = [
            "reproducibleCommand", "steps[<ANY>].reproducibleCommand", "steps[<ANY>].toolName", "steps[<ANY>].toolVersion",
            "tool.name", "tool.version", "toolName", "toolVersion", "workflowName",
        ].map { key in
            RouteParityDeclaredDifference<Case>(
                [.regionWithSamples: 8, .reverseFeature: 6],
                record + key,
                reason: "The pipeline names its run `lungfish gui sequence extraction` at the app's version, and the "
                    + "leaf names `lungfish extract sequence` at the CLI's version, once in the root record and once "
                    + "in each per-file record.",
                closedBy: closedBy
            )
        }
        return argv + identity
    }()

    private static let genome = "ACGTTGCAACGGATCCATGCAAGCTTGACCTAGGTACCGAATTCGGCCATGGCATGCAAT"
    private static let sourcePath = "Project.lungfish/Source Ref.lungfishref"
    private static let extractionsPath = "Project.lungfish/Extractions"

    private var scratch: URL!
    private var harness: RouteParityHarness!

    override func setUpWithError() throws {
        scratch = try TestTempDirectory.make(prefix: "region-extraction-parity")
        let products = Bundle(for: Self.self).bundleURL.deletingLastPathComponent()
        let cli = try XCTUnwrap(
            CLITestBinaryResolver.cliBinaryURL(buildProductsDirectory: products),
            "No lungfish-cli beside \(products.path) and none named by LUNGFISH_CLI_PATH, so no side can run"
        )
        harness = RouteParityHarness(cliBinary: cli, kind: .bundle, replayTimeout: .seconds(120))
    }

    override func tearDownWithError() throws {
        TestTempDirectory.cleanup(scratch)
    }

    func testTheRegionRowBuildsWhatTheInProcessPipelineBuilt() async throws {
        try await requireTools()
        try await assertCase(.regionWithSamples)
    }

    func testAReverseFeatureBuildsWhatTheInProcessPipelineBuilt() async throws {
        try await requireTools()
        try await assertCase(.reverseFeature)
    }

    private func assertCase(_ parityCase: Case) async throws {
        let result = try await harness.assertParity(
            parityCase,
            declared: Self.declared,
            in: scratch.appendingPathComponent(parityCase.rawValue, isDirectory: true),
            fixture: { root in try Self.writeFixture(root) },
            sideA: { root in await self.sideA(root, parityCase) },
            sideC: { root in await self.sideC(root, parityCase) }
        )
        for run in [result.runs.a, result.runs.c, result.runs.cPrime] {
            XCTAssertEqual(run.outcome.end, .completed, "\(run.side): \(run.outcome.detail)")
        }
        XCTAssertEqual(result.runs.a.outcome.detail, "Bundle ready", "the row's complete words")
        XCTAssertEqual(result.runs.c.outcome.detail, "Bundle ready", "the row's complete words")
    }

    // MARK: - The sides

    /// What the site hands both routes for `parityCase` in `root`.
    private struct Extraction {
        let source: ReferenceBundle
        let request: ExtractionRequest
        let result: LungfishCore.ExtractionResult
        let bundleName: String
        let sampleFilter: Set<String>?
        let extractions: URL
    }

    private func extraction(_ root: URL, _ parityCase: Case) async throws -> Extraction {
        let source = try await ReferenceBundle(url: root.appendingPathComponent(Self.sourcePath, isDirectory: true))
        let request: ExtractionRequest
        let bundleName: String
        let sampleFilter: Set<String>?
        switch parityCase {
        case .regionWithSamples:
            request = ExtractionRequest(source: .region(chromosome: "chr1", start: 10, end: 40))
            bundleName = "Region 1: HA/1"
            sampleFilter = ["S.1 a", "sample 2.b"]
        case .reverseFeature:
            let annotation = SequenceAnnotation(
                type: .cds, name: "cdsA", chromosome: "chr1",
                intervals: [AnnotationInterval(start: 2, end: 6), AnnotationInterval(start: 10, end: 14)], strand: .reverse
            )
            request = ExtractionRequest(
                source: .annotation(annotation), flank5Prime: 2, reverseComplement: true, concatenateExons: true
            )
            bundleName = "cdsA"
            sampleFilter = nil
        }
        let result = try SequenceExtractor.extract(
            request: request,
            sequenceProvider: { name, start, end in
                let clampedStart = max(0, start)
                let clampedEnd = min(Self.genome.count, end)
                guard clampedStart < clampedEnd else { return nil }
                return try? source.fetchSequenceSync(region: GenomicRegion(chromosome: name, start: clampedStart, end: clampedEnd))
            },
            chromosomeLength: Self.genome.count
        )
        return Extraction(
            source: source, request: request, result: result, bundleName: bundleName, sampleFilter: sampleFilter,
            extractions: root.appendingPathComponent(Self.extractionsPath, isDirectory: true)
        )
    }

    /// Side A. The pipeline the site ran at the base, with the tracks it collected.
    private func sideA(_ root: URL, _ parityCase: Case) async -> RouteParitySideOutcome {
        do {
            let run = try await extraction(root, parityCase)
            let bundle = run.source
            try FileManager.default.createDirectory(at: run.extractions, withIntermediateDirectories: true)
            _ = try await SequenceExtractionPipeline().buildBundle(
                from: run.result,
                outputDirectory: run.extractions,
                sourceBundleURL: bundle.url,
                sourceBundleName: bundle.manifest.name,
                desiredBundleName: run.bundleName,
                sourceBundleChromosomes: bundle.manifest.genome?.chromosomes ?? [],
                sourceAnnotationTracks: bundle.annotationTrackIds.compactMap { id -> SequenceExtractionSourceAnnotationTrack? in
                    guard let track = bundle.annotationTrack(id: id), let path = track.databasePath,
                          let url = try? bundle.memberURL(for: path, field: "annotations") else { return nil }
                    return .init(id: track.id, name: track.name, databaseURL: url, annotationType: track.annotationType)
                },
                sourceVariantTracks: bundle.variantTrackIds.compactMap { id -> SequenceExtractionSourceVariantTrack? in
                    guard let track = bundle.variantTrack(id: id), let path = track.databasePath,
                          let url = try? bundle.memberURL(for: path, field: "variants") else { return nil }
                    return .init(id: track.id, name: track.name, databaseURL: url, variantType: track.variantType)
                },
                sampleFilter: run.sampleFilter,
                isConcatenated: run.request.concatenateExons
            )
            return RouteParitySideOutcome(end: .completed, detail: "Bundle ready")
        } catch {
            return RouteParitySideOutcome(end: .failed, detail: "\(error)")
        }
    }

    /// Side C. The begin helper the site calls, and the runner on the argv the site hands it, which
    /// launches the built CLI. It returns the row's command, which side C' replays.
    private func sideC(_ root: URL, _ parityCase: Case) async -> RouteParitySideOutcome {
        let reporter = RecordingOperationReporter()
        let runner = CLIBundleBuildRunner(cliURLOverride: harness.cliBinary)
        do {
            let run = try await extraction(root, parityCase)
            let arguments = SequenceExtractionPipeline.cliArguments(
                source: run.request.source,
                flank5Prime: run.request.flank5Prime,
                flank3Prime: run.request.flank3Prime,
                reverseComplement: run.request.reverseComplement,
                concatenateExons: run.request.concatenateExons,
                sourceBundleURL: run.source.url,
                bundleName: run.bundleName,
                sampleFilter: run.sampleFilter,
                outputBundleURL: SequenceExtractionBundleBuilder.uniqueBundleURL(
                    for: run.result, desiredBundleName: run.bundleName, in: run.extractions
                )
            )
            var operationID: UUID?
            SequenceViewerView.beginExtractionBundleOperation(
                sourceName: run.result.sourceName, arguments: arguments, routeContext: nil, reporter: reporter
            ) { operationID = $0 }
            let id = try XCTUnwrap(operationID, "the row did not start")
            let result = try await runner.run(arguments: arguments, operationID: id)
            return RouteParitySideOutcome(
                end: .completed, detail: result.message ?? "", recordedCommand: reporter.items.first?.cliCommand
            )
        } catch {
            return RouteParitySideOutcome(end: .failed, detail: "\(error)", recordedCommand: reporter.items.first?.cliCommand)
        }
    }

    // MARK: - Fixture

    /// A project with one source bundle, a plain `chr1` of 60 bases with its index, an annotation track
    /// of two genes and a variant track of four calls over three samples.
    private static func writeFixture(_ root: URL) throws {
        let bundle = root.appendingPathComponent(sourcePath, isDirectory: true)
        let fileManager = FileManager.default
        for folder in ["genome", "annotations", "variants"] {
            try fileManager.createDirectory(at: bundle.appendingPathComponent(folder), withIntermediateDirectories: true)
        }
        try ">chr1\n\(genome)\n".write(to: bundle.appendingPathComponent("genome/sequence.fa"), atomically: true, encoding: .utf8)
        try "chr1\t60\t6\t60\t61\n".write(to: bundle.appendingPathComponent("genome/sequence.fa.fai"), atomically: true, encoding: .utf8)
        let inputs = root.appendingPathComponent("inputs", isDirectory: true)
        try fileManager.createDirectory(at: inputs, withIntermediateDirectories: true)
        let bed = inputs.appendingPathComponent("genes.bed")
        try "chr1\t12\t30\tgeneA\t0\t+\t12\t30\t0\t1\t18,\t0,\tgene\nchr1\t45\t55\tgeneB\t0\t-\t45\t55\t0\t1\t10,\t0,\tgene\n"
            .write(to: bed, atomically: true, encoding: .utf8)
        let genes = try AnnotationDatabase.createFromBED(bedURL: bed, outputURL: bundle.appendingPathComponent("annotations/genes.db"))
        let vcf = inputs.appendingPathComponent("calls.vcf")
        try [
            "##fileformat=VCFv4.2",
            "##contig=<ID=chr1,length=60>",
            "##FORMAT=<ID=GT,Number=1,Type=String,Description=\"Genotype\">",
            "#CHROM\tPOS\tID\tREF\tALT\tQUAL\tFILTER\tINFO\tFORMAT\tS.1 a\tsample 2.b\tS3",
            "chr1\t5\tv0\tT\tG\t50\tPASS\t.\tGT\t0/1\t1/1\t0/0",
            "chr1\t16\tv1\tA\tT\t60\tPASS\t.\tGT\t0/1\t0/1\t1/1",
            "chr1\t31\tv2\tC\tA\t70\tPASS\t.\tGT\t1/1\t0/1\t0/1",
            "chr1\t50\tv3\tC\tT\t80\tPASS\t.\tGT\t0/0\t0/1\t1/1",
        ].joined(separator: "\n").appending("\n").write(to: vcf, atomically: true, encoding: .utf8)
        let calls = try VariantDatabase.createFromVCF(vcfURL: vcf, outputURL: bundle.appendingPathComponent("variants/calls.db"))
        try BundleManifest(
            formatVersion: "1.0",
            name: "Source Ref",
            identifier: "org.lungfish.tests.region-parity",
            source: SourceInfo(organism: "Test organism", assembly: "test"),
            genome: GenomeInfo(
                path: "genome/sequence.fa",
                indexPath: "genome/sequence.fa.fai",
                totalLength: 60,
                chromosomes: [ChromosomeInfo(name: "chr1", length: 60, offset: 6, lineBases: 60, lineWidth: 61)]
            ),
            annotations: [AnnotationTrackInfo(
                id: "genes", name: "Genes", path: "annotations/genes.db", databasePath: "annotations/genes.db",
                annotationType: .gene, featureCount: genes
            )],
            variants: [VariantTrackInfo(
                id: "calls 1", name: "Calls", path: "variants/calls.db", indexPath: "variants/calls.db",
                databasePath: "variants/calls.db", variantType: .snp, variantCount: calls
            )]
        ).save(to: bundle)
    }

    private func requireTools(file: StaticString = #filePath, line: UInt = #line) async throws {
        do {
            try await BundleBuildHelpers.validateTools(using: .shared)
        } catch {
            try ToolAvailability.skipOrFail("Managed bgzip and samtools are required: \(error)", file: file, line: line)
        }
    }
}
