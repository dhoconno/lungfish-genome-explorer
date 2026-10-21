// SequenceExtractionRegionBundlePinConformanceTests.swift - Pins the region bundle the viewer's extraction builds
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import XCTest
@testable import LungfishApp
@testable import LungfishWorkflow
import LungfishCore
import LungfishIO
import LungfishTestSupport

/// Phase 2.11 lane A48 M1. Pins the `.lungfishref` bundle that `SequenceExtractionPipeline` builds
/// for a region of a source bundle, recorded at the base before the track and sample path folds into
/// `SequenceExtractionBundleBuilder`. The region bundle keeps the source's annotation and variant
/// tracks and a sample filter whose names hold dots and spaces (BIO 5), and the pins cover its files,
/// manifest, both tracks, the samples kept and its record. A plain region (no track, no filter) and
/// the names each path gives an empty name are pinned beside it. Each case runs the managed bgzip
/// and samtools faidx, so the class sits in the conformance tier and skips without them unless
/// `LUNGFISH_REQUIRE_TOOLS=1`.
final class SequenceExtractionRegionBundlePinConformanceTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = try TestTempDirectory.make(prefix: "region-bundle-pin")
    }

    override func tearDownWithError() throws {
        TestTempDirectory.cleanup(root)
    }

    /// The region bundle with both tracks and a sample filter of two of three samples.
    func testTheRegionBundleKeepsTracksSamplesAndRecord() async throws {
        try await requireTools()
        let source = try makeSourceBundle()
        let output = try folder("extractions")

        let bundleURL = try await SequenceExtractionPipeline().buildBundle(
            from: regionResult(sourceName: "chr1:11-40"),
            outputDirectory: output,
            sourceBundleURL: source.bundle,
            sourceBundleName: "Source Ref",
            desiredBundleName: "Region 1: HA/1",
            sourceBundleChromosomes: [Self.sourceChromosome],
            sourceAnnotationTracks: [
                .init(id: "genes", name: "Genes", databaseURL: source.annotations, annotationType: .gene),
            ],
            sourceVariantTracks: [
                .init(id: "calls 1", name: "Calls", databaseURL: source.variants, variantType: .snp),
            ],
            sampleFilter: ["sample 2.b", "S.1 a"]
        )

        try assertSnapshot(bundleSnapshot(bundleURL), Self.regionBundle, "region bundle")
        try assertSnapshot(recordSnapshot(bundleURL), Self.regionRecord, "region record")
    }

    /// The plain region, which today goes through the builder's own path.
    func testThePlainRegionBundleAndRecord() async throws {
        try await requireTools()
        let source = try makeSourceBundle()
        let output = try folder("extractions")

        let bundleURL = try await SequenceExtractionPipeline().buildBundle(
            from: regionResult(sourceName: "chr1:11-40"),
            outputDirectory: output,
            sourceBundleURL: source.bundle,
            sourceBundleName: "Source Ref",
            desiredBundleName: "Plain region"
        )

        try assertSnapshot(bundleSnapshot(bundleURL), Self.plainBundle, "plain bundle")
        try assertSnapshot(recordSnapshot(bundleURL), Self.plainRecord, "plain record")
    }

    /// The folder each path gives a blank desired name, an empty source name and an empty desired
    /// name. An empty sample filter sends a run down the track path with no track to copy.
    func testEachPathNamesAnEmptyName() async throws {
        try await requireTools()
        var names: [String] = []
        for trackPath in [false, true] {
            names.append(try await folderName(desired: "  ", sourceName: "chr1", trackPath: trackPath))
            names.append(try await folderName(desired: nil, sourceName: "  ", trackPath: trackPath))
            names.append(try await folderName(desired: "", sourceName: "Seg 4: HA/1", trackPath: trackPath))
        }
        try assertSnapshot(names.joined(separator: "\n"), Self.emptyNames, "empty names")
    }

    /// Two extractions with one name that overlap keep both bundles, on each path. The run that
    /// publishes second finds the name taken, takes the next free one and replaces nothing, and each
    /// bundle holds its own record and identifier (2.11 A48 M1 review Fix 6, SC5). Before, both runs
    /// published under the name picked at their start, and the later one replaced the earlier. The
    /// rival form publishes the other bundle while the run builds, so the overlap never depends on
    /// timing. The pair form runs two extractions at once, which need not overlap. Each path is its
    /// own call, so a failure names the path's line.
    func testOverlappingRegionExtractionsWithOneNameKeepBothBundles() async throws {
        try await requireTools()
        let source = try makeSourceBundle()
        try await assertOverlappingRunsKeepBothBundles(source: source.bundle, trackPath: false)
        try await assertOverlappingRunsKeepBothBundles(source: source.bundle, trackPath: true)
    }

    private func assertOverlappingRunsKeepBothBundles(
        source: URL, trackPath: Bool, file: StaticString = #filePath, line: UInt = #line
    ) async throws {
        let path = trackPath ? "track" : "plain"
        let filter: Set<String>? = trackPath ? [] : nil
        let result = regionResult(sourceName: "chr1:11-40")

        let output = try folder("rival-\(path)")
        let rival = output.appendingPathComponent("Name.lungfishref", isDirectory: true)
        let published = try await SequenceExtractionPipeline().buildBundle(
            from: result, outputDirectory: output, sourceBundleURL: source,
            sourceBundleName: "Source Ref", desiredBundleName: "Name", sampleFilter: filter
        ) { fraction, _ in
            // The first progress comes after the run picked its name and before it publishes.
            guard fraction <= 0.10 else { return }
            try? FileManager.default.createDirectory(at: rival, withIntermediateDirectories: true)
            try? "rival".write(to: rival.appendingPathComponent("rival.txt"), atomically: true, encoding: .utf8)
        }
        XCTAssertEqual(published.lastPathComponent, "Name_1.lungfishref", "\(path) path", file: file, line: line)
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(atPath: rival.path), ["rival.txt"],
            "\(path) path left the rival bundle as it was", file: file, line: line
        )
        try assertOwnBundle(published, trackPath: trackPath, file: file, line: line)

        let pair = try folder("pair-\(path)")
        async let first = SequenceExtractionPipeline().buildBundle(
            from: result, outputDirectory: pair, sourceBundleURL: source,
            sourceBundleName: "Source Ref", desiredBundleName: "Name", sampleFilter: filter)
        async let second = SequenceExtractionPipeline().buildBundle(
            from: result, outputDirectory: pair, sourceBundleURL: source,
            sourceBundleName: "Source Ref", desiredBundleName: "Name", sampleFilter: filter)
        let bundles = try await [first, second]
        let names = try FileManager.default.contentsOfDirectory(atPath: pair.path)
            .filter { $0.hasSuffix(".lungfishref") }.sorted()
        XCTAssertEqual(names, ["Name.lungfishref", "Name_1.lungfishref"], "\(path) pair", file: file, line: line)
        XCTAssertEqual(bundles.map(\.lastPathComponent).sorted(), names, "\(path) pair", file: file, line: line)
        for bundleURL in bundles {
            try assertOwnBundle(bundleURL, trackPath: trackPath, file: file, line: line)
        }
    }

    /// The bundle's identifier follows its folder, its manifest name does on the plain path, and its
    /// record names it as the output and lists only its files.
    private func assertOwnBundle(
        _ bundleURL: URL, trackPath: Bool, file: StaticString = #filePath, line: UInt = #line
    ) throws {
        let label = "\(trackPath ? "track" : "plain") \(bundleURL.lastPathComponent)"
        let folderName = bundleURL.deletingPathExtension().lastPathComponent
        let manifest = try BundleManifest.load(from: bundleURL)
        XCTAssertEqual(manifest.identifier, "org.lungfish.extracted.\(folderName.lowercased())", label, file: file, line: line)
        XCTAssertEqual(manifest.name, trackPath ? "Name" : folderName, label, file: file, line: line)
        let envelope = try record(of: bundleURL)
        guard case .file(let recorded)? = envelope.options.resolvedDefaults["output_bundle"] else {
            return XCTFail("\(label) records no output bundle", file: file, line: line)
        }
        XCTAssertEqual(recorded.lastPathComponent, bundleURL.lastPathComponent, label, file: file, line: line)
        let outputs = try XCTUnwrap(envelope.steps.first, file: file, line: line).outputs.map(\.path)
        XCTAssertFalse(outputs.isEmpty, label, file: file, line: line)
        XCTAssertTrue(
            outputs.allSatisfy { $0.contains("/\(bundleURL.lastPathComponent)/") },
            "\(label) lists only its own files: \(outputs)", file: file, line: line
        )
    }

    /// A viewer style source, a bundle in a project whose `genome` folder links to the reference it
    /// came from, gives a plain record whose inputs name that genome and its index outside the source
    /// (2.11 A48 M1 review Fixes 3 and 5, BIO 6). Before the fold the plain path's lookup refused the
    /// link, and the record named neither.
    func testThePlainRecordNamesGenomeMembersOutsideTheSource() async throws {
        try await requireTools()
        let project = try folder("Test.lungfish")
        let reference = project.appendingPathComponent("Reference Sequences/src.lungfishref", isDirectory: true)
        let genome = reference.appendingPathComponent("genome", isDirectory: true)
        try FileManager.default.createDirectory(at: genome, withIntermediateDirectories: true)
        try ">chr1\nACGT\n".write(to: genome.appendingPathComponent("sequence.fa"), atomically: true, encoding: .utf8)
        try "chr1\t4\t6\t4\t5\n".write(
            to: genome.appendingPathComponent("sequence.fa.fai"), atomically: true, encoding: .utf8)
        let identifier = "org.lungfish.test.outside-genome"
        let genomeInfo = GenomeInfo(
            path: "genome/sequence.fa", indexPath: "genome/sequence.fa.fai", totalLength: 4,
            chromosomes: [ChromosomeInfo(name: "chr1", length: 4, offset: 6, lineBases: 4, lineWidth: 5)])
        try BundleManifest(
            formatVersion: "1.0", name: "Reference", identifier: identifier,
            source: SourceInfo(organism: "Test", assembly: "Test"), genome: genomeInfo
        ).save(to: reference)
        let viewer = project.appendingPathComponent("Analyses/run/viewer.lungfishref", isDirectory: true)
        try FileManager.default.createDirectory(at: viewer, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: viewer.appendingPathComponent("genome"), withDestinationURL: genome)
        try BundleManifest(
            formatVersion: "1.0", name: "Viewer", identifier: identifier,
            originBundlePath: "@/Reference Sequences/src.lungfishref",
            source: SourceInfo(organism: "Test", assembly: "Test"), genome: genomeInfo
        ).save(to: viewer)

        let bundleURL = try await SequenceExtractionPipeline().buildBundle(
            from: regionResult(sourceName: "chr1:11-40"),
            outputDirectory: try folder("extractions"),
            sourceBundleURL: viewer,
            sourceBundleName: "Viewer",
            desiredBundleName: "Outside"
        )

        let inputs = try XCTUnwrap(try record(of: bundleURL).steps.first).inputs.map {
            "\($0.role) \(URL(fileURLWithPath: $0.path).resolvingSymlinksInPath().path)"
        }
        let outside = genome.resolvingSymlinksInPath().path
        XCTAssertTrue(inputs.contains("input \(outside)/sequence.fa"), "the genome file is an input: \(inputs)")
        XCTAssertTrue(inputs.contains("index \(outside)/sequence.fa.fai"), "its index is an index: \(inputs)")
    }

    // MARK: - Pinned values

    /// Recorded at lane A48's base b35342d54. The region annotation that spans the
    /// chromosome and every feature and call outside the region are left out, coordinates move to
    /// the region, the third sample `S3` is filtered out, and a hom-ref call is not stored.
    private static let regionBundle = """
    folder Region_1-_HA-1.lungfishref
    file .lungfish-provenance.json
    file annotations/annotations_0_genes.db
    file genome/sequence.fa.gz
    file genome/sequence.fa.gz.fai
    file genome/sequence.fa.gz.gzi
    file manifest.json
    file provenance/annotations/annotations_0_genes.db.lungfish-provenance.json
    file provenance/bundle.lungfish-provenance.json
    file provenance/genome/sequence.fa.gz.fai.lungfish-provenance.json
    file provenance/genome/sequence.fa.gz.gzi.lungfish-provenance.json
    file provenance/genome/sequence.fa.gz.lungfish-provenance.json
    file provenance/manifest.json.lungfish-provenance.json
    file provenance/variants/variants_0_calls_1.db.lungfish-provenance.json
    file variants/variants_0_calls_1.db
    name Region 1: HA/1
    identifier org.lungfish.extracted.region_1-_ha-1
    description Optional("Extracted from Source Ref at chr1:10-40")
    source Source Ref Extracted nil Optional("Extracted from Source Ref at chr1:10-40")
    genome genome/sequence.fa.gz genome/sequence.fa.gz.fai Optional("genome/sequence.fa.gz.gzi") 30 md5=nil
    chromosome chr1:11-40 30 aliases=[] description=nil
    annotation genes Genes annotations/annotations_0_genes.db Optional("annotations/annotations_0_genes.db") gene count=Optional(2) Optional("Coordinate-transformed annotations from source bundle track \\'Genes\\'")
      geneA gene chr1:11-40 2-20 + blocks=Optional("18,")/Optional("0,")
      cdsA CDS chr1:11-40 5-11 - blocks=Optional("6,")/Optional("0,")
    variant calls 1 Calls variants/variants_0_calls_1.db Optional("variants/variants_0_calls_1.db") snp count=Optional(2) Optional("Variants extracted from chr1:10-40")
      samples S.1 a,sample 2.b
      v1 chr1:11-40 5-6 S.1 a=0/1
      v2 chr1:11-40 20-21 S.1 a=1/1 sample 2.b=0/1
    """

    private static let regionRecord = """
    workflow lungfish gui sequence extraction
    tool lungfish gui sequence extraction
    argv Lungfish Genome Explorer | sequence | extract-bundle | --source-bundle | <root>/source.lungfishref | --source-name | Source Ref | --chromosome | chr1 | --start | 10 | --end | 40 | --name | Region 1: HA/1 | --samples | S.1 a,sample 2.b | --output | <root>/extractions/Region_1-_HA-1.lungfishref
    steps lungfish gui sequence extraction, bgzip, samtools faidx
    explicit bundle_name=string("Region 1: HA/1")
    explicit concatenate_exons=boolean(false)
    explicit operation=string("sequence-extraction")
    explicit reverse_complement=boolean(false)
    explicit sample_filter=array([LungfishWorkflow.ParameterValue.string("S.1 a"), LungfishWorkflow.ParameterValue.string("sample 2.b")])
    explicit source_bundle=file(file://<root>/source.lungfishref/)
    explicit source_bundle_name=string("Source Ref")
    explicit source_name=string("chr1:11-40")
    default concatenate_exons=boolean(false)
    default reverse_complement=boolean(false)
    default sample_filter=array([])
    resolved bundle_name=string("Region 1: HA/1")
    resolved chromosome=string("chr1")
    resolved concatenate_exons=boolean(false)
    resolved coordinate_system=string("0-based half-open")
    resolved end=integer(40)
    resolved operation=string("sequence-extraction")
    resolved output_bundle=file(file://<root>/extractions/Region_1-_HA-1.lungfishref/)
    resolved reverse_complement=boolean(false)
    resolved sample_filter=array([LungfishWorkflow.ParameterValue.string("S.1 a"), LungfishWorkflow.ParameterValue.string("sample 2.b")])
    resolved source_bundle=file(file://<root>/source.lungfishref/)
    resolved source_bundle_name=string("Source Ref")
    resolved source_name=string("chr1:11-40")
    resolved start=integer(10)
    step lungfish gui sequence extraction | Lungfish Genome Explorer | sequence | extract-bundle | --source-bundle | <root>/source.lungfishref | --source-name | Source Ref | --chromosome | chr1 | --start | 10 | --end | 40 | --name | Region 1: HA/1 | --samples | S.1 a,sample 2.b | --output | <root>/extractions/Region_1-_HA-1.lungfishref
      input input <root>/source.lungfishref/annotations/genes.db digest=true
      input input <root>/source.lungfishref/genome/sequence.fa.gz digest=true
      input index <root>/source.lungfishref/genome/sequence.fa.gz.fai digest=true
      input input <root>/source.lungfishref/manifest.json digest=true
      input input <root>/source.lungfishref/variants/calls.db digest=true
      output output <root>/extractions/Region_1-_HA-1.lungfishref/annotations/annotations_0_genes.db digest=true
      output output <root>/extractions/Region_1-_HA-1.lungfishref/genome/sequence.fa.gz digest=true
      output index <root>/extractions/Region_1-_HA-1.lungfishref/genome/sequence.fa.gz.fai digest=true
      output index <root>/extractions/Region_1-_HA-1.lungfishref/genome/sequence.fa.gz.gzi digest=true
      output output <root>/extractions/Region_1-_HA-1.lungfishref/manifest.json digest=true
      output output <root>/extractions/Region_1-_HA-1.lungfishref/variants/variants_0_calls_1.db digest=true
    step bgzip | bgzip | -f | -@ | <threads> | sequence.fa
      output output <root>/extractions/Region_1-_HA-1.lungfishref/genome/sequence.fa.gz digest=true
    step samtools faidx | samtools | faidx | sequence.fa.gz
      input output <root>/extractions/Region_1-_HA-1.lungfishref/genome/sequence.fa.gz digest=true
      output index <root>/extractions/Region_1-_HA-1.lungfishref/genome/sequence.fa.gz.fai digest=true
      output index <root>/extractions/Region_1-_HA-1.lungfishref/genome/sequence.fa.gz.gzi digest=true
    file output <root>/extractions/Region_1-_HA-1.lungfishref/annotations/annotations_0_genes.db digest=true
    file output <root>/extractions/Region_1-_HA-1.lungfishref/genome/sequence.fa.gz digest=true
    file index <root>/extractions/Region_1-_HA-1.lungfishref/genome/sequence.fa.gz.fai digest=true
    file index <root>/extractions/Region_1-_HA-1.lungfishref/genome/sequence.fa.gz.gzi digest=true
    file output <root>/extractions/Region_1-_HA-1.lungfishref/manifest.json digest=true
    file output <root>/extractions/Region_1-_HA-1.lungfishref/variants/variants_0_calls_1.db digest=true
    file input <root>/source.lungfishref/annotations/genes.db digest=true
    file input <root>/source.lungfishref/genome/sequence.fa.gz digest=true
    file index <root>/source.lungfishref/genome/sequence.fa.gz.fai digest=true
    file input <root>/source.lungfishref/manifest.json digest=true
    file input <root>/source.lungfishref/variants/calls.db digest=true
    """

    private static let plainBundle = """
    folder Plain_region.lungfishref
    file .lungfish-provenance.json
    file genome/sequence.fa.gz
    file genome/sequence.fa.gz.fai
    file genome/sequence.fa.gz.gzi
    file manifest.json
    file provenance/bundle.lungfish-provenance.json
    file provenance/genome/sequence.fa.gz.fai.lungfish-provenance.json
    file provenance/genome/sequence.fa.gz.gzi.lungfish-provenance.json
    file provenance/genome/sequence.fa.gz.lungfish-provenance.json
    file provenance/manifest.json.lungfish-provenance.json
    name Plain_region
    identifier org.lungfish.extracted.plain_region
    description nil
    source Source Ref Extracted source.lungfishref Optional("Extracted from Source Ref at chr1:11-40 (1-based)")
    genome genome/sequence.fa.gz genome/sequence.fa.gz.fai Optional("genome/sequence.fa.gz.gzi") 30 md5=nil
    chromosome chr1:11-40 30 aliases=[] description=nil
    """

    /// Changed by the fold in two lines of the record. The source index is an `index` input, as on
    /// the track path, where the base said `input`. At the base the builder's record also listed,
    /// in a folder reached through a link such as the temporary folder, the six record files the
    /// bundle builder wrote before it as outputs, with digests of files it then rewrote. The one
    /// record writer compares paths with links resolved and lists none of them.
    private static let plainRecord = """
    workflow lungfish gui sequence extraction
    tool lungfish gui sequence extraction
    argv Lungfish Genome Explorer | sequence | extract-bundle | --source-bundle | <root>/source.lungfishref | --source-name | Source Ref | --chromosome | chr1 | --start | 10 | --end | 40 | --name | Plain region | --output | <root>/extractions/Plain_region.lungfishref
    steps lungfish gui sequence extraction, bgzip, samtools faidx
    explicit bundle_name=string("Plain region")
    explicit concatenate_exons=boolean(false)
    explicit operation=string("sequence-extraction")
    explicit reverse_complement=boolean(false)
    explicit sample_filter=array([])
    explicit source_bundle=file(file://<root>/source.lungfishref/)
    explicit source_bundle_name=string("Source Ref")
    explicit source_name=string("chr1:11-40")
    default concatenate_exons=boolean(false)
    default reverse_complement=boolean(false)
    default sample_filter=array([])
    resolved bundle_name=string("Plain region")
    resolved chromosome=string("chr1")
    resolved concatenate_exons=boolean(false)
    resolved coordinate_system=string("0-based half-open")
    resolved end=integer(40)
    resolved operation=string("sequence-extraction")
    resolved output_bundle=file(file://<root>/extractions/Plain_region.lungfishref/)
    resolved reverse_complement=boolean(false)
    resolved sample_filter=array([])
    resolved source_bundle=file(file://<root>/source.lungfishref/)
    resolved source_bundle_name=string("Source Ref")
    resolved source_name=string("chr1:11-40")
    resolved start=integer(10)
    step lungfish gui sequence extraction | Lungfish Genome Explorer | sequence | extract-bundle | --source-bundle | <root>/source.lungfishref | --source-name | Source Ref | --chromosome | chr1 | --start | 10 | --end | 40 | --name | Plain region | --output | <root>/extractions/Plain_region.lungfishref
      input input <root>/source.lungfishref/genome/sequence.fa.gz digest=true
      input index <root>/source.lungfishref/genome/sequence.fa.gz.fai digest=true
      input input <root>/source.lungfishref/manifest.json digest=true
      output output <root>/extractions/Plain_region.lungfishref/genome/sequence.fa.gz digest=true
      output index <root>/extractions/Plain_region.lungfishref/genome/sequence.fa.gz.fai digest=true
      output index <root>/extractions/Plain_region.lungfishref/genome/sequence.fa.gz.gzi digest=true
      output output <root>/extractions/Plain_region.lungfishref/manifest.json digest=true
    step bgzip | bgzip | -f | -@ | <threads> | sequence.fa
      output output <root>/extractions/Plain_region.lungfishref/genome/sequence.fa.gz digest=true
    step samtools faidx | samtools | faidx | sequence.fa.gz
      input output <root>/extractions/Plain_region.lungfishref/genome/sequence.fa.gz digest=true
      output index <root>/extractions/Plain_region.lungfishref/genome/sequence.fa.gz.fai digest=true
      output index <root>/extractions/Plain_region.lungfishref/genome/sequence.fa.gz.gzi digest=true
    file output <root>/extractions/Plain_region.lungfishref/genome/sequence.fa.gz digest=true
    file index <root>/extractions/Plain_region.lungfishref/genome/sequence.fa.gz.fai digest=true
    file index <root>/extractions/Plain_region.lungfishref/genome/sequence.fa.gz.gzi digest=true
    file output <root>/extractions/Plain_region.lungfishref/manifest.json digest=true
    file input <root>/source.lungfishref/genome/sequence.fa.gz digest=true
    file index <root>/source.lungfishref/genome/sequence.fa.gz.fai digest=true
    file input <root>/source.lungfishref/manifest.json digest=true
    """

    /// Changed by the fold for a blank desired name on both paths. At the base it gave
    /// `.lungfishref`, a folder Finder hides, with the manifest name `.lungfishref` and the
    /// identifier `org.lungfish.extracted..lungfishref` on the plain path and the identifier
    /// `org.lungfish.extracted.` on the track path. The one uniquer gives `extracted_sequence` (BR8).
    /// The track path still keeps the raw name in the manifest, an empty one included.
    private static let emptyNames = """
    plain Optional("  ") "chr1" -> extracted_sequence.lungfishref name="extracted_sequence" id=org.lungfish.extracted.extracted_sequence
    plain nil "  " -> extracted_sequence.lungfishref name="extracted_sequence" id=org.lungfish.extracted.extracted_sequence
    plain Optional("") "Seg 4: HA/1" -> Seg_4-_HA-1.lungfishref name="Seg_4-_HA-1" id=org.lungfish.extracted.seg_4-_ha-1
    track Optional("  ") "chr1" -> extracted_sequence.lungfishref name="  " id=org.lungfish.extracted.extracted_sequence
    track nil "  " -> extracted_sequence.lungfishref name="  " id=org.lungfish.extracted.extracted_sequence
    track Optional("") "Seg 4: HA/1" -> Seg_4-_HA-1.lungfishref name="" id=org.lungfish.extracted.seg_4-_ha-1
    """

    // MARK: - Fixture

    private static let sourceChromosome = ChromosomeInfo(
        name: "chr1", length: 60, offset: 6, lineBases: 60, lineWidth: 61)

    private func requireTools(file: StaticString = #filePath, line: UInt = #line) async throws {
        do {
            try await BundleBuildHelpers.validateTools(using: .shared)
        } catch {
            try ToolAvailability.skipOrFail("Managed bgzip and samtools are required: \(error)", file: file, line: line)
        }
    }

    private func folder(_ name: String) throws -> URL {
        let url = root.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// A 30 base region, `chr1` from 10 to 40 in 0-based half-open coordinates.
    private func regionResult(sourceName: String) -> LungfishCore.ExtractionResult {
        LungfishCore.ExtractionResult(
            fastaHeader: "chr1:11-40", nucleotideSequence: "ACGTACGTACGTACGTACGTACGTACGTAC", proteinSequence: nil,
            sourceName: sourceName, chromosome: "chr1", effectiveStart: 10, effectiveEnd: 40,
            isReverseComplement: false)
    }

    /// A source bundle of one 60 base chromosome with an annotation database of four features (one
    /// spans the chromosome, one lies outside the region) and a variant database of four calls over
    /// three samples, two of them outside the region.
    private func makeSourceBundle() throws -> (bundle: URL, annotations: URL, variants: URL) {
        let bundle = root.appendingPathComponent("source.lungfishref", isDirectory: true)
        let genome = bundle.appendingPathComponent("genome", isDirectory: true)
        let annotations = bundle.appendingPathComponent("annotations", isDirectory: true)
        let variants = bundle.appendingPathComponent("variants", isDirectory: true)
        for directory in [genome, annotations, variants] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        try "source genome\n".write(
            to: genome.appendingPathComponent("sequence.fa.gz"), atomically: true, encoding: .utf8)
        try "chr1\t60\t6\t60\t61\n".write(
            to: genome.appendingPathComponent("sequence.fa.gz.fai"), atomically: true, encoding: .utf8)
        try BundleManifest(
            name: "Source Ref",
            identifier: "org.lungfish.test.region-source",
            description: "source",
            source: SourceInfo(organism: "source", assembly: "fixture"),
            genome: GenomeInfo(
                path: "genome/sequence.fa.gz", indexPath: "genome/sequence.fa.gz.fai", gzipIndexPath: nil,
                totalLength: 60, chromosomes: [Self.sourceChromosome])
        ).save(to: bundle)

        let bedURL = root.appendingPathComponent("genes.bed")
        try [
            "chr1\t0\t60\tchr1-region\t0\t+\t0\t60\t0\t1\t60,\t0,\tregion",
            "chr1\t12\t30\tgeneA\t0\t+\t12\t30\t0\t1\t18,\t0,\tgene",
            "chr1\t15\t21\tcdsA\t0\t-\t15\t21\t0\t1\t6,\t0,\tCDS",
            "chr1\t45\t55\tgeneB\t0\t+\t45\t55\t0\t1\t10,\t0,\tgene",
        ].joined(separator: "\n").write(to: bedURL, atomically: true, encoding: .utf8)
        let annotationDB = annotations.appendingPathComponent("genes.db")
        _ = try AnnotationDatabase.createFromBED(bedURL: bedURL, outputURL: annotationDB)

        let vcfURL = root.appendingPathComponent("calls.vcf")
        try [
            "##fileformat=VCFv4.2",
            "##contig=<ID=chr1,length=60>",
            "##FORMAT=<ID=GT,Number=1,Type=String,Description=\"Genotype\">",
            "#CHROM\tPOS\tID\tREF\tALT\tQUAL\tFILTER\tINFO\tFORMAT\tS.1 a\tsample 2.b\tS3",
            "chr1\t5\tv0\tA\tG\t50\tPASS\t.\tGT\t0/1\t1/1\t0/0",
            "chr1\t16\tv1\tC\tT\t60\tPASS\t.\tGT\t0/1\t0/0\t1/1",
            "chr1\t31\tv2\tG\tA\t70\tPASS\t.\tGT\t1/1\t0/1\t0/1",
            "chr1\t50\tv3\tT\tC\t80\tPASS\t.\tGT\t0/0\t0/1\t1/1",
        ].joined(separator: "\n").appending("\n").write(to: vcfURL, atomically: true, encoding: .utf8)
        let variantDB = variants.appendingPathComponent("calls.db")
        _ = try VariantDatabase.createFromVCF(vcfURL: vcfURL, outputURL: variantDB)
        return (bundle, annotationDB, variantDB)
    }

    /// Builds one bundle in a folder of its own and returns the folder name it got, or the error.
    private func folderName(desired: String?, sourceName: String, trackPath: Bool) async throws -> String {
        let output = try folder("names-\(UUID().uuidString)")
        do {
            let bundleURL = try await SequenceExtractionPipeline().buildBundle(
                from: regionResult(sourceName: sourceName),
                outputDirectory: output,
                desiredBundleName: desired,
                sampleFilter: trackPath ? [] : nil
            )
            let manifest = try BundleManifest.load(from: bundleURL)
            return "\(trackPath ? "track" : "plain") \(String(describing: desired)) \(sourceName.debugDescription) -> "
                + "\(bundleURL.lastPathComponent) name=\(manifest.name.debugDescription) id=\(manifest.identifier)"
        } catch {
            return "\(trackPath ? "track" : "plain") \(String(describing: desired)) error \(error)"
        }
    }

    // MARK: - Snapshots

    private func assertSnapshot(
        _ actual: String, _ expected: String, _ name: String, file: StaticString = #filePath, line: UInt = #line
    ) throws {
        if actual != expected {
            print("SNAPSHOT-BEGIN \(name)\n\(actual)\nSNAPSHOT-END \(name)")
        }
        XCTAssertEqual(actual, expected, name, file: file, line: line)
    }

    /// The root's path, and the thread count the runner gives bgzip, which follows this Mac's cores.
    private func scrub(_ text: String) -> String {
        text
            .replacingOccurrences(of: root.resolvingSymlinksInPath().path, with: "<root>")
            .replacingOccurrences(of: root.path, with: "<root>")
            .replacingOccurrences(of: #"\| -@ \| \d+ \|"#, with: "| -@ | <threads> |", options: .regularExpression)
    }

    /// Every file of the bundle, its manifest, both tracks read back from their databases and the
    /// samples each variant database keeps.
    private func bundleSnapshot(_ bundleURL: URL) throws -> String {
        var lines = ["folder \(bundleURL.lastPathComponent)"]
        let enumerator = FileManager.default.enumerator(at: bundleURL, includingPropertiesForKeys: [.isRegularFileKey])
        var files: [String] = []
        while let fileURL = enumerator?.nextObject() as? URL {
            if try fileURL.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true {
                files.append(String(fileURL.standardizedFileURL.path.dropFirst(bundleURL.standardizedFileURL.path.count + 1)))
            }
        }
        lines += files.sorted().map { "file \($0)" }

        let manifest = try BundleManifest.load(from: bundleURL)
        lines.append("name \(manifest.name)")
        lines.append("identifier \(manifest.identifier)")
        lines.append("description \(String(describing: manifest.description))")
        lines.append("source \(manifest.source.organism) \(String(describing: manifest.source.assembly)) "
            + "\(manifest.source.sourceURL?.lastPathComponent ?? "nil") \(String(describing: manifest.source.notes))")
        if let genome = manifest.genome {
            lines.append("genome \(genome.path) \(genome.indexPath) \(String(describing: genome.gzipIndexPath)) "
                + "\(genome.totalLength) md5=\(String(describing: genome.md5Checksum))")
            for chromosome in genome.chromosomes {
                lines.append("chromosome \(chromosome.name) \(chromosome.length) aliases=\(chromosome.aliases) "
                    + "description=\(String(describing: chromosome.fastaDescription))")
            }
        }
        for track in manifest.annotations {
            lines.append("annotation \(track.id) \(track.name) \(track.path) \(String(describing: track.databasePath)) "
                + "\(track.annotationType) count=\(String(describing: track.featureCount)) \(String(describing: track.description))")
            let database = try AnnotationDatabase(url: bundleURL.appendingPathComponent(track.path))
            for chromosome in database.allChromosomes().sorted() {
                let records = database.queryByRegion(chromosome: chromosome, start: 0, end: 1_000, limit: 100)
                    .sorted { ($0.start, $0.name) < ($1.start, $1.name) }
                for record in records {
                    lines.append("  \(record.name) \(record.type) \(record.chromosome) \(record.start)-\(record.end) "
                        + "\(record.strand) blocks=\(String(describing: record.blockSizes))/\(String(describing: record.blockStarts))")
                }
            }
        }
        for track in manifest.variants {
            lines.append("variant \(track.id) \(track.name) \(track.path) \(String(describing: track.databasePath)) "
                + "\(track.variantType) count=\(String(describing: track.variantCount)) \(String(describing: track.description))")
            let database = try VariantDatabase(url: bundleURL.appendingPathComponent(track.path))
            lines.append("  samples \(database.sampleNames().sorted().joined(separator: ","))")
            for chromosome in database.allChromosomes().sorted() {
                for row in database.genotypesInRegion(chromosome: chromosome, start: 0, end: 1_000, limit: 100) {
                    let calls = row.genotypes.sorted { $0.sampleName < $1.sampleName }
                        .map { "\($0.sampleName)=\($0.genotype ?? "nil")" }
                        .joined(separator: " ")
                    lines.append("  \(row.variant.variantID) \(row.variant.chromosome) "
                        + "\(row.variant.position)-\(row.variant.end) \(calls)")
                }
            }
        }
        return scrub(lines.joined(separator: "\n"))
    }

    private func record(of bundleURL: URL) throws -> ProvenanceEnvelope {
        try ProvenanceJSON.decoder.decode(
            ProvenanceEnvelope.self,
            from: Data(contentsOf: bundleURL.appendingPathComponent(ProvenanceWriter.provenanceFilename))
        )
    }

    /// The bundle's record, without its times and digests, which only need to be present.
    private func recordSnapshot(_ bundleURL: URL) throws -> String {
        let envelope = try ProvenanceJSON.decoder.decode(
            ProvenanceEnvelope.self,
            from: Data(contentsOf: bundleURL.appendingPathComponent(ProvenanceWriter.provenanceFilename))
        )
        var lines = [
            "workflow \(envelope.workflowName)",
            "tool \(envelope.toolName)",
            "argv \(envelope.argv.joined(separator: " | "))",
            "steps \(envelope.steps.map(\.toolName).joined(separator: ", "))",
        ]
        let describe: ([String: ParameterValue]) -> [String] = { options in
            options.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }
        }
        lines += describe(envelope.options.explicit).map { "explicit \($0)" }
        lines += describe(envelope.options.defaults).map { "default \($0)" }
        lines += describe(envelope.options.resolvedDefaults).map { "resolved \($0)" }
        for step in envelope.steps {
            lines.append("step \(step.toolName) | \(step.argv.joined(separator: " | "))")
            lines += step.inputs.sorted { $0.path < $1.path }
                .map { "  input \($0.role) \($0.path) digest=\($0.checksumSHA256 != nil)" }
            lines += step.outputs.sorted { $0.path < $1.path }
                .map { "  output \($0.role) \($0.path) digest=\($0.checksumSHA256 != nil)" }
        }
        lines += envelope.files.sorted { $0.path < $1.path }
            .map { "file \($0.role) \($0.path) digest=\($0.checksumSHA256 != nil)" }
        return scrub(lines.joined(separator: "\n"))
    }
}
