// ExtractSequenceBundleConformanceTests.swift - extract sequence --bundle keeps the tracks and names its tools
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import XCTest
@testable import LungfishCLI
@testable import LungfishWorkflow
import LungfishCore
import LungfishIO
import LungfishTestSupport

/// Phase 2.11 lane A48 M2. `extract sequence --bundle` builds the region bundle the viewer builds,
/// from a source bundle with a real bgzip genome, an annotation track and a variant track over three
/// samples whose names hold dots and spaces (BIO 5). It runs the managed bgzip and samtools faidx, so
/// the class sits in the conformance tier and skips without them unless `LUNGFISH_REQUIRE_TOOLS=1`.
final class ExtractSequenceBundleConformanceTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = try TestTempDirectory.make(prefix: "extract-sequence-bundle")
    }

    override func tearDownWithError() throws {
        TestTempDirectory.cleanup(root)
    }

    func testTheBundleKeepsTracksAndSamplesAndItsRecordNamesEachTool() async throws {
        try await requireTools()
        let source = try await Self.makeSourceBundle(in: root)
        let output = root.appendingPathComponent("Extractions/Region_1.lungfishref", isDirectory: true)

        let command = try ExtractSequenceSubcommand.parse([
            source.path, "chr1:11-40", "--bundle", "--name=Region 1", "--samples=sample 2.b", "--samples=S.1 a",
            "--output", output.path, "--quiet",
        ])
        try await command.run()

        let manifest = try BundleManifest.load(from: output)
        XCTAssertEqual(manifest.name, "Region 1")
        XCTAssertEqual(manifest.annotations.map(\.id), ["genes"], "the annotation track is kept")
        XCTAssertEqual(manifest.variants.map(\.id), ["calls 1"], "the variant track is kept")
        let variantDB = try VariantDatabase(url: output.appendingPathComponent(try XCTUnwrap(manifest.variants.first?.databasePath)))
        XCTAssertEqual(Set(variantDB.sampleNames()), ["S.1 a", "sample 2.b"], "only the samples named are kept")

        let envelope = try ProvenanceJSON.decoder.decode(
            ProvenanceEnvelope.self,
            from: Data(contentsOf: output.appendingPathComponent(ProvenanceWriter.provenanceFilename))
        )
        XCTAssertEqual(envelope.workflowName, "lungfish extract sequence")
        XCTAssertEqual(Array(envelope.argv.prefix(6)), ["lungfish-cli", "extract", "sequence", source.path, "chr1:11-40", "--bundle"])
        XCTAssertEqual(envelope.argv.filter { $0.hasPrefix("--samples=") }, ["--samples=S.1 a", "--samples=sample 2.b"])
        XCTAssertEqual(envelope.steps.map(\.toolName), ["lungfish extract sequence", "bgzip", "samtools faidx"])
        for step in envelope.steps.dropFirst() {
            XCTAssertNotEqual(step.toolVersion, "unknown", "\(step.toolName) names the version that ran")
            XCTAssertFalse(step.outputs.isEmpty, "\(step.toolName) names what it wrote")
        }
        XCTAssertEqual(
            envelope.options.resolvedDefaults["sample_filter"], .array([.string("S.1 a"), .string("sample 2.b")])
        )
        XCTAssertEqual(envelope.options.resolvedDefaults["output_bundle"], .file(output))
        let staged = try FileManager.default.contentsOfDirectory(atPath: output.deletingLastPathComponent().path)
        XCTAssertEqual(staged, ["Region_1.lungfishref"], "the run leaves nothing but the bundle beside it")
    }

    func testAFeatureOfTwoPartsJoinsThemAsTheViewerDoes() async throws {
        try await requireTools()
        let source = try await Self.makeSourceBundle(in: root)
        let output = root.appendingPathComponent("Extractions/cds.lungfishref", isDirectory: true)

        let command = try ExtractSequenceSubcommand.parse([
            source.path, "chr1:3-6,11-14", "--bundle", "--feature-name=cdsA", "--feature-type", "CDS", "--strand", "-",
            "--concatenate-exons", "--reverse-complement", "--output", output.path, "--quiet",
        ])
        try await command.run()

        let annotation = SequenceAnnotation(
            type: .cds, name: "cdsA", chromosome: "chr1",
            intervals: [AnnotationInterval(start: 2, end: 6), AnnotationInterval(start: 10, end: 14)], strand: .reverse
        )
        let expected = try SequenceExtractor.extract(
            request: ExtractionRequest(
                source: .annotation(annotation), reverseComplement: true, concatenateExons: true
            ),
            sequenceProvider: { _, start, end in String(Self.genome.dropFirst(start).prefix(end - start)) },
            chromosomeLength: Self.genome.count
        )
        let bundle = try await ReferenceBundle(url: output)
        let chromosome = try XCTUnwrap(bundle.chromosomeNames.first)
        let bases = try bundle.fetchSequenceSync(
            region: GenomicRegion(chromosome: chromosome, start: 0, end: expected.nucleotideSequence.count)
        )
        XCTAssertEqual(bases, expected.nucleotideSequence, "the bundle holds the bases the viewer's request extracts")
    }

    func testARefusalNamesTheFixAndWritesNothing() async throws {
        let command = try ExtractSequenceSubcommand.parse([
            root.path, "chr1:1-10", "--bundle", "--no-samples", "--samples=S3", "--output", root.appendingPathComponent("x.lungfishref").path,
        ])
        do {
            try await command.run()
            XCTFail("a refusal must throw")
        } catch {
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), [])
        }
    }

    // MARK: - Fixture

    /// 60 bases of `chr1`.
    static let genome = "ACGTTGCAACGGATCCATGCAAGCTTGACCTAGGTACCGAATTCGGCCATGGCATGCAAT"

    private func requireTools(file: StaticString = #filePath, line: UInt = #line) async throws {
        do {
            try await BundleBuildHelpers.validateTools(using: .shared)
        } catch {
            try ToolAvailability.skipOrFail("Managed bgzip and samtools are required: \(error)", file: file, line: line)
        }
    }

    /// A source bundle whose genome the builder compressed and indexed, with an annotation track of
    /// two genes and a variant track of four calls over three samples.
    static func makeSourceBundle(in root: URL) async throws -> URL {
        let bundle = root.appendingPathComponent("source/Source Ref.lungfishref", isDirectory: true)
        let context = SequenceExtractionBundleCommandContext(
            workflowName: "fixture", toolName: "fixture", argv: ["fixture"],
            explicitOptions: [:], defaultOptions: [:], resolvedOptions: [:], inputURLs: []
        )
        _ = try await SequenceExtractionBundleBuilder().buildBundle(
            request: SequenceExtractionBundleBuildRequest(
                result: LungfishCore.ExtractionResult(
                    fastaHeader: "chr1", nucleotideSequence: genome, proteinSequence: nil, sourceName: "chr1",
                    chromosome: "chr1", effectiveStart: 0, effectiveEnd: genome.count, isReverseComplement: false
                ),
                outputDirectory: bundle.deletingLastPathComponent(),
                outputBundleURL: bundle,
                commandContext: context
            )
        )
        let annotations = bundle.appendingPathComponent("annotations", isDirectory: true)
        let variants = bundle.appendingPathComponent("variants", isDirectory: true)
        for folder in [annotations, variants] {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        let bedURL = root.appendingPathComponent("genes.bed")
        try [
            "chr1\t12\t30\tgeneA\t0\t+\t12\t30\t0\t1\t18,\t0,\tgene",
            "chr1\t45\t55\tgeneB\t0\t+\t45\t55\t0\t1\t10,\t0,\tgene",
        ].joined(separator: "\n").write(to: bedURL, atomically: true, encoding: .utf8)
        let genesCount = try AnnotationDatabase.createFromBED(bedURL: bedURL, outputURL: annotations.appendingPathComponent("genes.db"))
        let vcfURL = root.appendingPathComponent("calls.vcf")
        try [
            "##fileformat=VCFv4.2",
            "##contig=<ID=chr1,length=60>",
            "##FORMAT=<ID=GT,Number=1,Type=String,Description=\"Genotype\">",
            "#CHROM\tPOS\tID\tREF\tALT\tQUAL\tFILTER\tINFO\tFORMAT\tS.1 a\tsample 2.b\tS3",
            "chr1\t5\tv0\tT\tG\t50\tPASS\t.\tGT\t0/1\t1/1\t0/0",
            "chr1\t16\tv1\tA\tT\t60\tPASS\t.\tGT\t0/1\t0/1\t1/1",
            "chr1\t31\tv2\tC\tA\t70\tPASS\t.\tGT\t1/1\t0/1\t0/1",
            "chr1\t50\tv3\tC\tT\t80\tPASS\t.\tGT\t0/0\t0/1\t1/1",
        ].joined(separator: "\n").appending("\n").write(to: vcfURL, atomically: true, encoding: .utf8)
        let callsCount = try VariantDatabase.createFromVCF(vcfURL: vcfURL, outputURL: variants.appendingPathComponent("calls.db"))
        let built = try BundleManifest.load(from: bundle)
        try BundleManifest(
            name: "Source Ref",
            identifier: built.identifier,
            description: built.description,
            source: built.source,
            genome: built.genome,
            annotations: [AnnotationTrackInfo(
                id: "genes", name: "Genes", path: "annotations/genes.db", databasePath: "annotations/genes.db",
                annotationType: .gene, featureCount: genesCount
            )],
            variants: [VariantTrackInfo(
                id: "calls 1", name: "Calls", path: "variants/calls.db", indexPath: "variants/calls.db",
                databasePath: "variants/calls.db", variantType: .snp, variantCount: callsCount
            )]
        ).save(to: bundle)
        return bundle
    }
}
