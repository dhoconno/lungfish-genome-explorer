// ExtractSequenceBundleConformanceTests.swift - extract sequence --bundle keeps the tracks and names its tools
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import ArgumentParser
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
            XCTAssertEqual(
                step.toolVersionEvidence?.recordedString, step.toolVersion, "\(step.toolName) names where its version comes from"
            )
            XCTAssertNotNil(step.managedToolID, "\(step.toolName) names its tool by the lock entry")
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

    /// With `--next-free-name` the bundle that holds the name `-o` gives stays as it was, and the run
    /// publishes under the next free name, which its manifest identifier and record name
    /// (2.11 A48 M1 review Fix 6, SC5). Without it a typed `-o` replaces, as before.
    func testNextFreeNameKeepsTheBundleThatHoldsTheName() async throws {
        try await requireTools()
        let source = try await Self.makeSourceBundle(in: root)
        let output = root.appendingPathComponent("Extractions/Region_1.lungfishref", isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        try "rival".write(to: output.appendingPathComponent("rival.txt"), atomically: true, encoding: .utf8)

        let command = try ExtractSequenceSubcommand.parse([
            source.path, "chr1:11-40", "--bundle", "--name=Region 1", "--no-samples",
            "--output", output.path, "--next-free-name", "--quiet",
        ])
        try await command.run()

        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: output.path), ["rival.txt"])
        let published = root.appendingPathComponent("Extractions/Region_1_1.lungfishref", isDirectory: true)
        let manifest = try BundleManifest.load(from: published)
        XCTAssertEqual(manifest.name, "Region 1", "the track path keeps the name given")
        XCTAssertEqual(manifest.identifier, "org.lungfish.extracted.region_1_1")
        let envelope = try ProvenanceJSON.decoder.decode(
            ProvenanceEnvelope.self,
            from: Data(contentsOf: published.appendingPathComponent(ProvenanceWriter.provenanceFilename))
        )
        XCTAssertTrue(envelope.argv.contains("--next-free-name"), "the record names the command that ran")
        guard case .file(let recorded)? = envelope.options.resolvedDefaults["output_bundle"] else {
            return XCTFail("the record names no output bundle")
        }
        XCTAssertEqual(recorded.standardizedFileURL.path, published.standardizedFileURL.path)
    }

    /// Review A48-M2 Fix 7. Each refusal exits 3, ends standard output with one `failed` line whose
    /// error names the fix (docs/formats/cli-events.md), and writes nothing.
    func testEachRefusalExitsThreeNamesItsFixAndWritesNothing() async throws {
        try await requireTools()
        let source = try await Self.makeSourceBundle(in: root)
        let plain = root.appendingPathComponent("plain", isDirectory: true)
        try FileManager.default.createDirectory(at: plain, withIntermediateDirectories: true)
        let output = root.appendingPathComponent("Extractions/x.lungfishref").path
        let addOutput = "--bundle writes a reference bundle. Add -o <name>.lungfishref."
        let rows: [(arguments: [String], words: String)] = [
            ([source.path, "chr1:1-10", "--bundle"], addOutput),
            ([source.path, "chr1:1-10", "--bundle", "-o", root.appendingPathComponent("x.fa").path], addOutput),
            (
                [plain.path, "chr1:1-10", "--bundle", "-o", output],
                "No reference bundle at \(plain.standardizedFileURL.path). --bundle reads a .lungfishref folder."
            ),
            (
                [source.path, "chr1:1-10", "--bundle", "--no-samples", "--samples=S3", "-o", output],
                "--no-samples keeps no sample, so it cannot go with --samples. Give one of them."
            ),
            (
                [source.path, "chr1:1-10", "--bundle", "--strand=+", "-o", output],
                "--feature-type, --strand and --concatenate-exons describe a feature. Add --feature-name."
            ),
            ([source.path, "chr1", "--bundle", "-o", output], "--bundle needs a region with its sequence name, such as chr1:1000-2000."),
            ([source.path, "chr1:1-5,10-20", "--bundle", "-o", output], "A region of several parts is a feature's. Add --feature-name."),
            ([source.path, "chrZ:1-5", "--bundle", "-o", output], "Sequence 'chrZ' is not in the bundle. Available: chr1"),
        ]
        let before = try listing()
        for (index, row) in rows.enumerated() {
            let refusal = try await refusal(row.arguments)
            XCTAssertEqual(refusal.exitCode, 3, "row \(index + 1)")
            XCTAssertEqual(refusal.event, "failed", "row \(index + 1)")
            XCTAssertEqual(refusal.error, row.words, "row \(index + 1)")
            XCTAssertEqual(try listing(), before, "row \(index + 1) writes nothing")
        }
    }

    /// Review A48-M2 Fix 4. An output that is the source bundle, or a folder inside it, would replace
    /// the input with its own region, so the leaf refuses it before it reads anything.
    func testAnOutputThatIsTheSourceIsRefusedAndTheSourceStaysWhole() async throws {
        try await requireTools()
        let source = try await Self.makeSourceBundle(in: root)
        let manifest = try Data(contentsOf: source.appendingPathComponent("manifest.json"))
        let before = try listing()
        for output in [source.path, source.appendingPathComponent("inner.lungfishref").path] {
            let refusal = try await refusal([source.path, "chr1:11-40", "--bundle", "--no-samples", "--output", output])
            XCTAssertEqual(refusal.exitCode, 3, output)
            XCTAssertEqual(refusal.event, "failed", output)
            XCTAssertTrue(refusal.error.contains("never replaces its input"), "\(output): \(refusal.error)")
            XCTAssertEqual(try Data(contentsOf: source.appendingPathComponent("manifest.json")), manifest, output)
            XCTAssertEqual(try listing(), before, "\(output) leaves every file as it was")
        }
    }

    /// Review A48-M3b Fix 2. An output that holds the source bundle would replace the input with its own
    /// region just as the source itself would, so the leaf refuses the third arm of the guard too.
    func testAnOutputThatHoldsTheSourceIsRefusedAndTheSourceStaysWhole() async throws {
        try await requireTools()
        let holder = root.appendingPathComponent("Holder.lungfishref", isDirectory: true)
        try FileManager.default.createDirectory(at: holder, withIntermediateDirectories: true)
        let nested = try await Self.makeSourceBundle(in: holder)
        let manifest = try Data(contentsOf: nested.appendingPathComponent("manifest.json"))
        let before = try listing()
        let refusal = try await refusal([nested.path, "chr1:11-40", "--bundle", "--no-samples", "--output", holder.path])
        XCTAssertEqual(refusal.exitCode, 3)
        XCTAssertEqual(refusal.event, "failed")
        XCTAssertTrue(refusal.error.contains("never replaces its input"), refusal.error)
        XCTAssertEqual(try Data(contentsOf: nested.appendingPathComponent("manifest.json")), manifest)
        XCTAssertEqual(try listing(), before)
    }

    /// Review A48-M3b Fix 2. On the default macOS volume `SOURCE REF.lungfishref` is the same folder as
    /// `Source Ref.lungfishref`, so the guard has to compare the case the folder is stored in. The test
    /// skips on a volume that tells the two names apart.
    func testAnOutputThatDiffersFromTheSourceOnlyInCaseIsRefused() async throws {
        try await requireTools()
        let source = try await Self.makeSourceBundle(in: root)
        let variant = source.deletingLastPathComponent().appendingPathComponent("SOURCE REF.lungfishref", isDirectory: true)
        try XCTSkipUnless(FileManager.default.fileExists(atPath: variant.path), "needs a case-insensitive volume")
        let before = try listing()
        let refusal = try await refusal([source.path, "chr1:11-40", "--bundle", "--no-samples", "--output", variant.path])
        XCTAssertEqual(refusal.exitCode, 3)
        XCTAssertTrue(refusal.error.contains("never replaces its input"), refusal.error)
        XCTAssertEqual(try listing(), before)
    }

    /// Runs the leaf on `arguments` with `--format json --quiet` and returns the exit code it threw and
    /// the event and error of its last standard output line.
    private func refusal(_ arguments: [String]) async throws -> (exitCode: Int32?, event: String?, error: String) {
        let capture = FileManager.default.temporaryDirectory
            .appendingPathComponent("extract-refusal-capture-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: capture, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: capture) }
        let command = try ExtractSequenceSubcommand.parse(arguments + ["--format", "json", "--quiet"])
        var thrown: Error?
        let streams = try await StandardStreamCapture.capture(in: capture) {
            do { try await command.run() } catch { thrown = error }
        }
        let last = String(decoding: streams.standardOutput, as: UTF8.self).split(separator: "\n").last.map(String.init) ?? ""
        let event = (try? JSONSerialization.jsonObject(with: Data(last.utf8))) as? [String: Any]
        return ((thrown as? ExitCode)?.rawValue, event?["event"] as? String, event?["error"] as? String ?? "")
    }

    /// Every file and folder under the test's root, by relative path.
    private func listing() throws -> [String] {
        (FileManager.default.enumerator(atPath: root.path)?.allObjects as? [String] ?? []).sorted()
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
