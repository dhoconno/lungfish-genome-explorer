// BundleManifestTests.swift - Tests for bundle manifest data model
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
@testable import LungfishCore
import LungfishTestSupport

final class BundleManifestTests: XCTestCase {

    // MARK: - Test Fixtures

    var tempDirectory: URL!

    override func setUp() async throws {
        tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("LungfishTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        if let tempDir = tempDirectory {
            try? FileManager.default.removeItem(at: tempDir)
        }
    }

    // MARK: - BundleManifest Creation Tests

    func testBundleManifestCreation() {
        let manifest = BundleManifest(
            formatVersion: "1.0",
            name: "Human Reference Genome",
            identifier: "com.example.grch38",
            originBundlePath: "@/Downloads/Human Reference Genome.lungfishref",
            source: SourceInfo(
                organism: "Homo sapiens",
                assembly: "GRCh38",
                database: "NCBI",
                sourceURL: URL(string: "https://www.ncbi.nlm.nih.gov/genome/guide/human/")
            ),
            genome: GenomeInfo(
                path: "genome/sequence.fa.gz",
                indexPath: "genome/sequence.fa.gz.fai",
                gzipIndexPath: "genome/sequence.fa.gz.gzi",
                totalLength: 3_100_000_000,
                chromosomes: [
                    ChromosomeInfo(name: "chr1", length: 248_956_422, offset: 6, lineBases: 50, lineWidth: 51, aliases: ["1"]),
                    ChromosomeInfo(name: "chr2", length: 242_193_529, offset: 5000000, lineBases: 50, lineWidth: 51, aliases: ["2"])
                ]
            ),
            annotations: [],
            variants: [],
            tracks: []
        )

        XCTAssertEqual(manifest.formatVersion, "1.0")
        XCTAssertEqual(manifest.name, "Human Reference Genome")
        XCTAssertEqual(manifest.identifier, "com.example.grch38")
        XCTAssertEqual(manifest.originBundlePath, "@/Downloads/Human Reference Genome.lungfishref")
        XCTAssertEqual(manifest.source.organism, "Homo sapiens")
        XCTAssertEqual(manifest.source.assembly, "GRCh38")
        XCTAssertEqual(manifest.genome!.chromosomes.count, 2)
        XCTAssertEqual(manifest.genome!.totalLength, 3_100_000_000)
    }

    func testBundleManifestSaveLoadRoundTripsOriginBundlePath() throws {
        let bundleURL = tempDirectory.appendingPathComponent("TestGenome.lungfishref", isDirectory: true)
        try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)

        let manifest = BundleManifest(
            name: "Test Genome",
            identifier: "com.example.test-genome",
            originBundlePath: "@/Downloads/TestGenome.lungfishref",
            source: SourceInfo(
                organism: "Test organism",
                assembly: "TG1"
            ),
            genome: GenomeInfo(
                path: "genome/sequence.fa.gz",
                indexPath: "genome/sequence.fa.gz.fai",
                gzipIndexPath: "genome/sequence.fa.gz.gzi",
                totalLength: 10,
                chromosomes: [
                    ChromosomeInfo(
                        name: "chr1",
                        length: 10,
                        offset: 0,
                        lineBases: 10,
                        lineWidth: 11,
                        aliases: []
                    )
                ]
            )
        )

        try manifest.save(to: bundleURL)
        let loaded = try BundleManifest.load(from: bundleURL)

        XCTAssertEqual(loaded.originBundlePath, "@/Downloads/TestGenome.lungfishref")
    }

    func testBundleManifestRoundTripsReferenceRecordStore() throws {
        let recordStore = ReferenceRecordStoreInfo(
            schemaVersion: 1,
            format: "genbank",
            databasePath: "metadata/genbank_records.sqlite",
            recordCount: 2_321
        )
        let manifest = BundleManifest(
            name: "MHC Reference",
            identifier: "test.mhc-reference",
            createdDate: Date(timeIntervalSince1970: 1_700_000_000),
            modifiedDate: Date(timeIntervalSince1970: 1_700_000_000),
            source: SourceInfo(organism: "Macaca fascicularis", assembly: "IPD-MHC"),
            recordStore: recordStore
        )

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(manifest)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let encodedStore = try XCTUnwrap(object["record_store"] as? [String: Any])
        XCTAssertEqual(encodedStore["schema_version"] as? Int, 1)
        XCTAssertEqual(encodedStore["format"] as? String, "genbank")
        XCTAssertEqual(encodedStore["database_path"] as? String, "metadata/genbank_records.sqlite")
        XCTAssertEqual(encodedStore["record_count"] as? Int, 2_321)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(BundleManifest.self, from: data)
        XCTAssertEqual(decoded.recordStore, recordStore)
        XCTAssertEqual(decoded, manifest)
    }

    func testManifestMutationPreservesReferenceRecordStore() {
        let recordStore = ReferenceRecordStoreInfo(
            schemaVersion: 1,
            format: "genbank",
            databasePath: "metadata/genbank_records.sqlite",
            recordCount: 2_321
        )
        let manifest = BundleManifest(
            name: "MHC Reference",
            identifier: "test.mhc-reference",
            source: SourceInfo(organism: "Macaca fascicularis", assembly: "IPD-MHC"),
            recordStore: recordStore
        )

        let updated = manifest.addingAnnotationTrack(
            AnnotationTrackInfo(id: "genes", name: "Genes", path: "annotations/genes.sqlite")
        )

        XCTAssertEqual(updated.recordStore, recordStore)
    }

    func testBundleManifestSaveReplacesTheFileInsteadOfTruncatingItInPlace() throws {
        let bundleURL = tempDirectory.appendingPathComponent("InPlace.lungfishref", isDirectory: true)
        try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)
        let source = SourceInfo(organism: "Test organism", assembly: "TG1")
        try BundleManifest(name: "Old", identifier: "test.old", source: source).save(to: bundleURL)
        let manifestURL = bundleURL.appendingPathComponent(BundleManifest.filename)
        let oldBytes = try Data(contentsOf: manifestURL)

        // A reader that opened the old manifest keeps reading all of it while a save replaces it.
        let reader = try FileHandle(forReadingFrom: manifestURL)
        defer { try? reader.close() }
        try BundleManifest(name: "New", identifier: "test.new", source: source).save(to: bundleURL)

        XCTAssertEqual(try reader.readToEnd(), oldBytes)
        XCTAssertEqual(try BundleManifest.load(from: bundleURL).name, "New")
    }

    // MARK: - SourceInfo Tests

    func testSourceInfoCreation() {
        let source = SourceInfo(
            organism: "Mus musculus",
            commonName: "Mouse",
            assembly: "GRCm39",
            database: "Ensembl",
            sourceURL: URL(string: "https://ensembl.org/Mus_musculus/")
        )

        XCTAssertEqual(source.organism, "Mus musculus")
        XCTAssertEqual(source.commonName, "Mouse")
        XCTAssertEqual(source.assembly, "GRCm39")
        XCTAssertEqual(source.database, "Ensembl")
        XCTAssertNotNil(source.sourceURL)
    }

    // MARK: - GenomeInfo Tests

    func testGenomeInfoCreation() {
        let genome = GenomeInfo(
            path: "genome/sequence.fa.gz",
            indexPath: "genome/sequence.fa.gz.fai",
            gzipIndexPath: "genome/sequence.fa.gz.gzi",
            totalLength: 1_000_000_000,
            chromosomes: [
                ChromosomeInfo(name: "chr1", length: 500_000_000, offset: 6, lineBases: 50, lineWidth: 51, aliases: ["1", "CM000663.2"]),
                ChromosomeInfo(name: "chr2", length: 500_000_000, offset: 10000000, lineBases: 50, lineWidth: 51, aliases: ["2"])
            ]
        )

        XCTAssertEqual(genome.path, "genome/sequence.fa.gz")
        XCTAssertEqual(genome.indexPath, "genome/sequence.fa.gz.fai")
        XCTAssertEqual(genome.gzipIndexPath, "genome/sequence.fa.gz.gzi")
        XCTAssertEqual(genome.totalLength, 1_000_000_000)
        XCTAssertEqual(genome.chromosomes.count, 2)
    }

    // MARK: - ChromosomeInfo Tests

    func testChromosomeInfoCreation() {
        let chrom = ChromosomeInfo(
            name: "chrX",
            length: 156_040_895,
            offset: 5000000,
            lineBases: 50,
            lineWidth: 51,
            aliases: ["X", "CM000685.2"]
        )

        XCTAssertEqual(chrom.name, "chrX")
        XCTAssertEqual(chrom.length, 156_040_895)
        XCTAssertEqual(chrom.offset, 5000000)
        XCTAssertEqual(chrom.lineBases, 50)
        XCTAssertEqual(chrom.lineWidth, 51)
        XCTAssertEqual(chrom.aliases, ["X", "CM000685.2"])
    }

    func testChromosomeInfoWithoutAliases() {
        let chrom = ChromosomeInfo(
            name: "chrM",
            length: 16_569,
            offset: 0,
            lineBases: 50,
            lineWidth: 51,
            aliases: [],
            isMitochondrial: true
        )

        XCTAssertEqual(chrom.name, "chrM")
        XCTAssertEqual(chrom.length, 16_569)
        XCTAssertTrue(chrom.aliases.isEmpty)
        XCTAssertTrue(chrom.isMitochondrial)
    }

    // MARK: - AnnotationTrackInfo Tests

    func testAnnotationTrackInfoCreation() {
        let track = AnnotationTrackInfo(
            id: "genes",
            name: "Gene Annotations",
            description: "GENCODE gene annotations",
            path: "annotations/genes.bb",
            annotationType: .gene,
            featureCount: 60_000,
            source: "GENCODE",
            version: "v38"
        )

        XCTAssertEqual(track.id, "genes")
        XCTAssertEqual(track.name, "Gene Annotations")
        XCTAssertEqual(track.path, "annotations/genes.bb")
        XCTAssertEqual(track.featureCount, 60_000)
        XCTAssertEqual(track.annotationType, .gene)
    }

    // MARK: - VariantTrackInfo Tests

    func testVariantTrackInfoCreation() {
        let track = VariantTrackInfo(
            id: "dbsnp",
            name: "dbSNP Variants",
            description: "Common variants from dbSNP",
            path: "variants/dbsnp.bcf",
            indexPath: "variants/dbsnp.bcf.csi",
            variantType: .snp,
            variantCount: 700_000_000,
            source: "dbSNP"
        )

        XCTAssertEqual(track.id, "dbsnp")
        XCTAssertEqual(track.name, "dbSNP Variants")
        XCTAssertEqual(track.path, "variants/dbsnp.bcf")
        XCTAssertEqual(track.indexPath, "variants/dbsnp.bcf.csi")
        XCTAssertEqual(track.variantCount, 700_000_000)
        XCTAssertEqual(track.variantType, .snp)
    }

    // MARK: - SignalTrackInfo Tests

    func testSignalTrackInfoCreation() {
        let track = SignalTrackInfo(
            id: "gc_content",
            name: "GC Content",
            description: "GC percentage in sliding windows",
            path: "tracks/gc_content.bw",
            signalType: .gcContent,
            minValue: 0.0,
            maxValue: 100.0
        )

        XCTAssertEqual(track.id, "gc_content")
        XCTAssertEqual(track.name, "GC Content")
        XCTAssertEqual(track.path, "tracks/gc_content.bw")
        XCTAssertEqual(track.signalType, .gcContent)
        XCTAssertEqual(track.minValue, 0.0)
        XCTAssertEqual(track.maxValue, 100.0)
    }

    func testSignalTrackTypes() {
        XCTAssertEqual(SignalTrackType.coverage.rawValue, "coverage")
        XCTAssertEqual(SignalTrackType.gcContent.rawValue, "gcContent")
        XCTAssertEqual(SignalTrackType.conservation.rawValue, "conservation")
        XCTAssertEqual(SignalTrackType.chipSeq.rawValue, "chipSeq")
        XCTAssertEqual(SignalTrackType.atacSeq.rawValue, "atacSeq")
        XCTAssertEqual(SignalTrackType.methylation.rawValue, "methylation")
        XCTAssertEqual(SignalTrackType.custom.rawValue, "custom")
    }

    // MARK: - Codable Tests

    func testBundleManifestCodable() throws {
        let manifest = BundleManifest(
            formatVersion: "1.0",
            name: "Test Genome",
            identifier: "test.genome",
            source: SourceInfo(
                organism: "Test organism",
                assembly: "TestAssembly",
                database: "Test"
            ),
            genome: GenomeInfo(
                path: "genome/seq.fa.gz",
                indexPath: "genome/seq.fa.gz.fai",
                totalLength: 1000,
                chromosomes: [
                    ChromosomeInfo(name: "chr1", length: 1000, offset: 6, lineBases: 50, lineWidth: 51)
                ]
            ),
            annotations: [
                AnnotationTrackInfo(
                    id: "test",
                    name: "Test",
                    path: "annotations/test.bb"
                )
            ],
            variants: [],
            tracks: []
        )

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = .prettyPrinted

        let data = try encoder.encode(manifest)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let decoded = try decoder.decode(BundleManifest.self, from: data)

        XCTAssertEqual(manifest.formatVersion, decoded.formatVersion)
        XCTAssertEqual(manifest.name, decoded.name)
        XCTAssertEqual(manifest.identifier, decoded.identifier)
        XCTAssertEqual(manifest.source.organism, decoded.source.organism)
        XCTAssertEqual(manifest.genome!.path, decoded.genome!.path)
        XCTAssertEqual(manifest.genome!.chromosomes.count, decoded.genome!.chromosomes.count)
        XCTAssertEqual(manifest.annotations.count, decoded.annotations.count)
    }

    // MARK: - Load/Save Tests

    func testManifestSaveAndLoad() throws {
        let manifest = BundleManifest(
            formatVersion: "1.0",
            name: "Test Bundle",
            identifier: "test.bundle",
            source: SourceInfo(
                organism: "Test",
                assembly: "TestAsm",
                database: "Test"
            ),
            genome: GenomeInfo(
                path: "genome/seq.fa.gz",
                indexPath: "genome/seq.fa.gz.fai",
                totalLength: 1000,
                chromosomes: [
                    ChromosomeInfo(name: "chr1", length: 1000, offset: 6, lineBases: 50, lineWidth: 51)
                ]
            ),
            annotations: [],
            variants: [],
            tracks: []
        )

        // Create a mock bundle directory
        let bundleURL = tempDirectory.appendingPathComponent("test.lungfishref")
        try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)

        // Save manifest
        try manifest.save(to: bundleURL)

        // Verify manifest.json exists
        let manifestURL = bundleURL.appendingPathComponent("manifest.json")
        XCTAssertTrue(FileManager.default.fileExists(atPath: manifestURL.path))

        // Load manifest
        let loaded = try BundleManifest.load(from: bundleURL)

        XCTAssertEqual(loaded.name, manifest.name)
        XCTAssertEqual(loaded.identifier, manifest.identifier)
        XCTAssertEqual(loaded.source.organism, manifest.source.organism)
    }

    /// Since lane 12.37 `save` stores no derivable summary, and a reader builds it in memory from the loaded manifest.
    func testLoadedManifestSynthesizesBrowserSummaryFromGenomeChromosomes() throws {
        let bundleURL = tempDirectory.appendingPathComponent("browser-summary.lungfishref")
        try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)

        let manifest = BundleManifest(
            formatVersion: "1.0",
            name: "Browser Summary Bundle",
            identifier: "test.browser-summary",
            source: SourceInfo(
                organism: "Test",
                assembly: "TestAsm",
                database: "Test"
            ),
            genome: GenomeInfo(
                path: "genome/seq.fa.gz",
                indexPath: "genome/seq.fa.gz.fai",
                totalLength: 11_000,
                chromosomes: [
                    ChromosomeInfo(
                        name: "chr1",
                        length: 10_000,
                        offset: 0,
                        lineBases: 50,
                        lineWidth: 51,
                        aliases: ["1"],
                        isPrimary: true,
                        fastaDescription: "Test chromosome 1"
                    ),
                    ChromosomeInfo(
                        name: "chrM",
                        length: 1_000,
                        offset: 10_001,
                        lineBases: 50,
                        lineWidth: 51,
                        aliases: ["MT"],
                        isPrimary: false,
                        isMitochondrial: true,
                        fastaDescription: "Test mitochondrion"
                    )
                ]
            ),
            annotations: [
                AnnotationTrackInfo(id: "genes", name: "Genes", path: "annotations/genes.bb")
            ],
            variants: [
                VariantTrackInfo(id: "snps", name: "SNPs", path: "variants/snps.bcf", indexPath: "variants/snps.bcf.csi")
            ],
            tracks: [],
            alignments: [
                AlignmentTrackInfo(
                    id: "reads-a",
                    name: "reads-a.bam",
                    format: .bam,
                    sourcePath: "/data/reads-a.bam",
                    indexPath: "/data/reads-a.bam.bai",
                    mappedReadCount: 12
                ),
                AlignmentTrackInfo(
                    id: "reads-b",
                    name: "reads-b.bam",
                    format: .bam,
                    sourcePath: "/data/reads-b.bam",
                    indexPath: "/data/reads-b.bam.bai",
                    mappedReadCount: 30
                )
            ]
        )

        try manifest.save(to: bundleURL)
        XCTAssertNil(try BundleManifest.load(from: bundleURL).browserSummary)
        let loaded = try BundleManifest.load(from: bundleURL).withSynthesizedBrowserSummaryIfNeeded()

        XCTAssertEqual(loaded.browserSummary?.schemaVersion, 1)
        XCTAssertEqual(loaded.browserSummary?.aggregate.annotationTrackCount, 1)
        XCTAssertEqual(loaded.browserSummary?.aggregate.variantTrackCount, 1)
        XCTAssertEqual(loaded.browserSummary?.aggregate.alignmentTrackCount, 2)
        XCTAssertEqual(loaded.browserSummary?.aggregate.totalMappedReads, 42)
        XCTAssertEqual(loaded.browserSummary?.sequences.map(\.name), ["chr1", "chrM"])
        XCTAssertEqual(loaded.browserSummary?.sequences.first?.aliases, ["1"])
        XCTAssertEqual(loaded.browserSummary?.sequences.first?.displayDescription, "Test chromosome 1")
        XCTAssertEqual(loaded.browserSummary?.sequences.last?.aliases, ["MT"])
        XCTAssertEqual(loaded.browserSummary?.sequences.last?.displayDescription, "Test mitochondrion")
        XCTAssertEqual(loaded.browserSummary?.sequences.last?.isPrimary, false)
        XCTAssertEqual(loaded.browserSummary?.sequences.last?.isMitochondrial, true)
        XCTAssertNil(loaded.browserSummary?.sequences.last?.metrics)
    }

    func testSynthesizedBrowserSummaryFollowsManifestMutation() throws {
        let bundleURL = tempDirectory.appendingPathComponent("browser-summary-refresh.lungfishref")
        try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)

        let manifest = BundleManifest(
            formatVersion: "1.0",
            name: "Browser Summary Refresh Bundle",
            identifier: "test.browser-summary-refresh",
            source: SourceInfo(
                organism: "Test",
                assembly: "TestAsm",
                database: "Test"
            ),
            genome: GenomeInfo(
                path: "genome/seq.fa.gz",
                indexPath: "genome/seq.fa.gz.fai",
                totalLength: 10_000,
                chromosomes: [
                    ChromosomeInfo(
                        name: "chr1",
                        length: 10_000,
                        offset: 0,
                        lineBases: 50,
                        lineWidth: 51,
                        aliases: ["1"],
                        fastaDescription: "Test chromosome 1"
                    )
                ]
            )
        )

        try manifest.save(to: bundleURL)
        let loaded = try BundleManifest.load(from: bundleURL).withSynthesizedBrowserSummaryIfNeeded()
        XCTAssertEqual(loaded.browserSummary?.aggregate.variantTrackCount, 0)
        XCTAssertEqual(loaded.browserSummary?.aggregate.alignmentTrackCount, 0)

        let mutated = loaded
            .addingVariantTrack(
                VariantTrackInfo(
                    id: "snps",
                    name: "SNPs",
                    path: "variants/snps.bcf",
                    indexPath: "variants/snps.bcf.csi"
                )
            )
            .addingAlignmentTrack(
                AlignmentTrackInfo(
                    id: "reads",
                    name: "reads.bam",
                    format: .bam,
                    sourcePath: "/data/reads.bam",
                    indexPath: "/data/reads.bam.bai",
                    mappedReadCount: 25
                )
            )

        XCTAssertNil(mutated.browserSummary)

        try mutated.save(to: bundleURL)
        let reloaded = try BundleManifest.load(from: bundleURL).withSynthesizedBrowserSummaryIfNeeded()

        XCTAssertEqual(reloaded.browserSummary?.aggregate.variantTrackCount, 1)
        XCTAssertEqual(reloaded.browserSummary?.aggregate.alignmentTrackCount, 1)
        XCTAssertEqual(reloaded.browserSummary?.aggregate.totalMappedReads, 25)
        XCTAssertEqual(reloaded.browserSummary?.sequences.map(\.name), ["chr1"])
    }

    // MARK: - Stored form (lane 12.37, F5a)

    /// A genome manifest whose browser summary synthesis can give back from its chromosomes and tracks.
    func makeStoredFormManifest() -> BundleManifest {
        BundleManifest(
            name: "Stored Form",
            identifier: "test.stored-form",
            createdDate: Date(timeIntervalSince1970: 1_760_000_000),
            modifiedDate: Date(timeIntervalSince1970: 1_760_000_000),
            source: SourceInfo(organism: "Test", assembly: "TestAsm"),
            genome: GenomeInfo(
                path: "genome/sequence.fa",
                indexPath: "genome/sequence.fa.fai",
                totalLength: 150,
                chromosomes: [
                    ChromosomeInfo(
                        name: "chr1", length: 100, offset: 6, lineBases: 100, lineWidth: 101,
                        aliases: ["1"], fastaDescription: "first sequence"
                    ),
                    ChromosomeInfo(
                        name: "chrM", length: 50, offset: 113, lineBases: 50, lineWidth: 51,
                        aliases: ["MT"], isPrimary: false, isMitochondrial: true
                    ),
                ]
            ),
            annotations: [AnnotationTrackInfo(id: "genes", name: "Genes", path: "annotations/genes.db")],
            alignments: [
                AlignmentTrackInfo(
                    id: "reads", name: "reads.bam", format: .bam, sourcePath: "alignments/reads.bam",
                    indexPath: "alignments/reads.bam.bai",
                    // Whole seconds, since ISO 8601 dates round-trip without fractions.
                    addedDate: Date(timeIntervalSince1970: 1_760_000_000), mappedReadCount: 7
                )
            ]
        )
    }

    func storedFormBundle(_ name: String) throws -> URL {
        let bundleURL = tempDirectory.appendingPathComponent("\(name).lungfishref", isDirectory: true)
        try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)
        return bundleURL
    }

    func savedManifestJSON(in bundleURL: URL) throws -> [String: Any] {
        let data = try Data(contentsOf: bundleURL.appendingPathComponent(BundleManifest.filename))
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    /// BIO 4. A saved and loaded manifest equals the one saved, with the same summary in memory.
    func testSlimManifestDecodesToEqualManifest() throws {
        let manifest = makeStoredFormManifest()
        let bundleURL = try storedFormBundle("equal")
        try manifest.save(to: bundleURL)
        let loaded = try BundleManifest.load(from: bundleURL)

        XCTAssertEqual(loaded, manifest)
        XCTAssertEqual(loaded, manifest.withSynthesizedBrowserSummaryIfNeeded())
        XCTAssertEqual(
            loaded.withSynthesizedBrowserSummaryIfNeeded().browserSummary,
            manifest.withSynthesizedBrowserSummaryIfNeeded().browserSummary
        )
    }

    /// BIO 1. A stored summary that synthesis cannot give is written as it is: one with measured
    /// per-sequence metrics, and one whose aggregate differs from the manifest's tracks.
    func testSaveKeepsSummaryThatSynthesisCannotGive() throws {
        let manifest = makeStoredFormManifest()
        let derivable = try XCTUnwrap(manifest.withSynthesizedBrowserSummaryIfNeeded().browserSummary)
        let metrics = BundleBrowserSequenceMetrics(
            mappedReads: 7, mappedPercent: 50, meanDepth: 2.5, coverageBreadth: 0.9, medianMAPQ: 60, meanIdentity: 0.99
        )
        let measured = BundleBrowserSummary(
            schemaVersion: 1,
            aggregate: derivable.aggregate,
            sequences: derivable.sequences.map {
                BundleBrowserSequenceSummary(
                    name: $0.name, displayDescription: $0.displayDescription, length: $0.length, aliases: $0.aliases,
                    isPrimary: $0.isPrimary, isMitochondrial: $0.isMitochondrial, metrics: metrics
                )
            }
        )
        let stale = BundleBrowserSummary(
            schemaVersion: 1,
            aggregate: .init(annotationTrackCount: 0, variantTrackCount: 0, alignmentTrackCount: 0, totalMappedReads: nil),
            sequences: derivable.sequences
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]

        for (label, summary) in [("measured", measured), ("stale", stale)] {
            let stored = BundleManifest(
                name: manifest.name, identifier: manifest.identifier,
                createdDate: manifest.createdDate, modifiedDate: manifest.modifiedDate,
                source: manifest.source, genome: manifest.genome, annotations: manifest.annotations,
                alignments: manifest.alignments, browserSummary: summary
            )
            let bundleURL = try storedFormBundle(label)
            try stored.save(to: bundleURL)

            XCTAssertNotNil(try savedManifestJSON(in: bundleURL)["browser_summary"], label)
            XCTAssertEqual(try BundleManifest.load(from: bundleURL).browserSummary, summary, label)
            XCTAssertEqual(
                try Data(contentsOf: bundleURL.appendingPathComponent(BundleManifest.filename)),
                try encoder.encode(stored),
                label
            )
        }
    }

    /// BIO 2. An older bundle's manifest that stores the derivable summary keeps it, and reading it
    /// rewrites no byte.
    func testLoadKeepsAStoredSummaryAndItsBytes() throws {
        let stored = makeStoredFormManifest().withSynthesizedBrowserSummaryIfNeeded()
        let bundleURL = try storedFormBundle("older")
        let manifestURL = bundleURL.appendingPathComponent(BundleManifest.filename)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let bytes = try encoder.encode(stored)
        try bytes.write(to: manifestURL)

        let loaded = try BundleManifest.load(from: bundleURL)
        XCTAssertEqual(loaded.browserSummary, stored.browserSummary)
        XCTAssertEqual(loaded.withSynthesizedBrowserSummaryIfNeeded().browserSummary, stored.browserSummary)
        XCTAssertEqual(try Data(contentsOf: manifestURL), bytes)
    }

    /// F5a. `save` leaves out a summary that is nil or equals the synthesized one, so both write the same bytes.
    func testSaveOmitsDerivableBrowserSummary() throws {
        let manifest = makeStoredFormManifest()
        let withStored = manifest.withSynthesizedBrowserSummaryIfNeeded()
        XCTAssertNotNil(withStored.browserSummary)

        let noneURL = try storedFormBundle("none")
        let derivableURL = try storedFormBundle("derivable")
        try manifest.save(to: noneURL)
        try withStored.save(to: derivableURL)

        XCTAssertNil(try savedManifestJSON(in: noneURL)["browser_summary"])
        XCTAssertNil(try savedManifestJSON(in: derivableURL)["browser_summary"])
        XCTAssertEqual(
            try Data(contentsOf: noneURL.appendingPathComponent(BundleManifest.filename)),
            try Data(contentsOf: derivableURL.appendingPathComponent(BundleManifest.filename))
        )
        XCTAssertNil(try BundleManifest.load(from: derivableURL).browserSummary)
        XCTAssertNil(withStored.storedForm.browserSummary)
        XCTAssertEqual(withStored.storedForm, withStored)
    }

    // MARK: - Validation Tests

    func testValidManifest() {
        let manifest = createValidManifest()
        let errors = manifest.validate()
        XCTAssertTrue(errors.isEmpty, "Valid manifest should have no errors: \(errors)")
    }

    func testInvalidName() {
        let manifest = BundleManifest(
            formatVersion: "1.0",
            name: "",
            identifier: "test.genome",
            source: SourceInfo(organism: "Test", assembly: "Test"),
            genome: GenomeInfo(
                path: "genome/sequence.fa.gz",
                indexPath: "genome/sequence.fa.gz.fai",
                totalLength: 1_000_000,
                chromosomes: [
                    ChromosomeInfo(name: "chr1", length: 1_000_000, offset: 6, lineBases: 50, lineWidth: 51)
                ]
            )
        )

        let errors = manifest.validate()
        XCTAssertFalse(errors.isEmpty)
    }

    func testInvalidGenomePath() {
        let genome = GenomeInfo(
            path: "",
            indexPath: "genome/seq.fa.gz.fai",
            totalLength: 1000,
            chromosomes: [
                ChromosomeInfo(name: "chr1", length: 1000, offset: 6, lineBases: 50, lineWidth: 51)
            ]
        )

        let manifest = BundleManifest(
            formatVersion: "1.0",
            name: "Test",
            identifier: "test",
            source: SourceInfo(organism: "Test", assembly: "Test"),
            genome: genome,
            annotations: [],
            variants: [],
            tracks: []
        )

        let errors = manifest.validate()
        XCTAssertFalse(errors.isEmpty)
    }

    func testValidateRejectsUnsafeBundleMemberPaths() {
        let manifest = BundleManifest(
            formatVersion: "1.0",
            name: "Test",
            identifier: "test",
            source: SourceInfo(organism: "Test", assembly: "Test"),
            genome: GenomeInfo(
                path: "../outside.fa",
                indexPath: "/tmp/outside.fa.fai",
                gzipIndexPath: "provenance/outside.fa.gzi",
                totalLength: 1000,
                chromosomes: [
                    ChromosomeInfo(name: "chr1", length: 1000, offset: 6, lineBases: 50, lineWidth: 51)
                ]
            ),
            annotations: [
                AnnotationTrackInfo(
                    id: "genes",
                    name: "Genes",
                    path: "annotations/../genes.bb",
                    databasePath: "manifest.json"
                )
            ],
            variants: [
                VariantTrackInfo(
                    id: "variants",
                    name: "Variants",
                    path: "variants/test.bcf",
                    indexPath: "variants/test.bcf.csi",
                    databasePath: "~/variants.db"
                )
            ],
            tracks: [
                SignalTrackInfo(id: "signal", name: "Signal", path: "tracks/./signal.bw")
            ]
        )

        let invalidPaths = manifest.validate().compactMap { error -> String? in
            guard case .invalidPath(let field, let path) = error else { return nil }
            return "\(field)=\(path)"
        }

        XCTAssertTrue(invalidPaths.contains("genome.path=../outside.fa"))
        XCTAssertTrue(invalidPaths.contains("genome.indexPath=/tmp/outside.fa.fai"))
        XCTAssertTrue(invalidPaths.contains("genome.gzipIndexPath=provenance/outside.fa.gzi"))
        XCTAssertTrue(invalidPaths.contains("annotations[genes].path=annotations/../genes.bb"))
        XCTAssertTrue(invalidPaths.contains("annotations[genes].databasePath=manifest.json"))
        XCTAssertTrue(invalidPaths.contains("variants[variants].databasePath=~/variants.db"))
        XCTAssertTrue(invalidPaths.contains("tracks[signal].path=tracks/./signal.bw"))
    }

    func testValidateRejectsEscapingReferenceRecordStorePath() {
        let manifest = BundleManifest(
            name: "Unsafe Record Store",
            identifier: "test.unsafe-record-store",
            source: SourceInfo(organism: "Test", assembly: "Test"),
            recordStore: ReferenceRecordStoreInfo(
                schemaVersion: 1,
                format: "genbank",
                databasePath: "../escape.sqlite",
                recordCount: 1
            )
        )

        XCTAssertTrue(manifest.validate().contains { error in
            guard case .invalidPath(let field, let path) = error else { return false }
            return field == "record_store.database_path" && path == "../escape.sqlite"
        })
    }

    func testValidateRejectsUnsupportedReferenceRecordStoreFormat() {
        let manifest = manifestWithRecordStore(
            ReferenceRecordStoreInfo(
                schemaVersion: 1,
                format: "fasta",
                databasePath: "metadata/records.sqlite",
                recordCount: 1
            )
        )

        XCTAssertTrue(manifest.validate().contains { error in
            guard case .invalidValue(let field, let value, let expected) = error else { return false }
            return field == "record_store.format" && value == "fasta" && expected == "genbank"
        })
    }

    func testValidateRejectsUnsupportedReferenceRecordStoreSchemaVersion() {
        let manifest = manifestWithRecordStore(
            ReferenceRecordStoreInfo(
                schemaVersion: 2,
                format: "genbank",
                databasePath: "metadata/records.sqlite",
                recordCount: 1
            )
        )

        XCTAssertTrue(manifest.validate().contains { error in
            guard case .invalidValue(let field, let value, let expected) = error else { return false }
            return field == "record_store.schema_version" && value == "2" && expected == "1"
        })
    }

    func testValidateRejectsNegativeReferenceRecordCount() {
        let manifest = manifestWithRecordStore(
            ReferenceRecordStoreInfo(
                schemaVersion: 1,
                format: "genbank",
                databasePath: "metadata/records.sqlite",
                recordCount: -1
            )
        )

        XCTAssertTrue(manifest.validate().contains { error in
            guard case .invalidValue(let field, let value, let expected) = error else { return false }
            return field == "record_store.record_count" && value == "-1" && expected == "zero or greater"
        })
    }

    func testValidatedBundleMemberURLRejectsSymlinkEscapes() throws {
        let bundleURL = tempDirectory.appendingPathComponent("symlink-test.lungfishref", isDirectory: true)
        let genomeDirectory = bundleURL.appendingPathComponent("genome", isDirectory: true)
        try FileManager.default.createDirectory(at: genomeDirectory, withIntermediateDirectories: true)

        let outsideURL = tempDirectory.appendingPathComponent("outside.fa")
        try ">chr1\nACGT\n".write(to: outsideURL, atomically: true, encoding: .utf8)

        let symlinkURL = genomeDirectory.appendingPathComponent("sequence.fa")
        try FileManager.default.createSymbolicLink(at: symlinkURL, withDestinationURL: outsideURL)

        XCTAssertThrowsError(
            try BundleManifest.validatedBundleMemberURL(for: "genome/sequence.fa", in: bundleURL)
        )
    }

    func testDuplicateTrackIds() {
        let manifest = BundleManifest(
            formatVersion: "1.0",
            name: "Test",
            identifier: "test",
            source: SourceInfo(organism: "Test", assembly: "Test"),
            genome: GenomeInfo(
                path: "genome/seq.fa.gz",
                indexPath: "genome/seq.fa.gz.fai",
                totalLength: 1000,
                chromosomes: [
                    ChromosomeInfo(name: "chr1", length: 1000, offset: 6, lineBases: 50, lineWidth: 51)
                ]
            ),
            annotations: [
                AnnotationTrackInfo(id: "track1", name: "Track 1", path: "a.bb"),
                AnnotationTrackInfo(id: "track1", name: "Track 1 Dup", path: "b.bb")  // Duplicate ID
            ],
            variants: [],
            tracks: []
        )

        let errors = manifest.validate()
        XCTAssertFalse(errors.isEmpty)
    }

    // MARK: - Alignment Track Tests

    func testAlignmentTrackInfoCreation() {
        let track = AlignmentTrackInfo(
            id: "aln_test1",
            name: "sample.bam",
            format: .bam,
            sourcePath: "/data/sample.bam",
            indexPath: "/data/sample.bam.bai",
            fileSizeBytes: 5_000_000_000,
            addedDate: Date(),
            mappedReadCount: 50_000_000,
            unmappedReadCount: 1_000_000,
            sampleNames: ["SampleA", "SampleB"]
        )

        XCTAssertEqual(track.id, "aln_test1")
        XCTAssertEqual(track.name, "sample.bam")
        XCTAssertEqual(track.format, .bam)
        XCTAssertEqual(track.sourcePath, "/data/sample.bam")
        XCTAssertEqual(track.indexPath, "/data/sample.bam.bai")
        XCTAssertEqual(track.fileSizeBytes, 5_000_000_000)
        XCTAssertEqual(track.mappedReadCount, 50_000_000)
        XCTAssertEqual(track.sampleNames, ["SampleA", "SampleB"])
    }

    func testAlignmentFormatValues() {
        XCTAssertEqual(AlignmentFormat.bam.rawValue, "bam")
        XCTAssertEqual(AlignmentFormat.cram.rawValue, "cram")
        XCTAssertEqual(AlignmentFormat.sam.rawValue, "sam")
    }

    func testAddingAlignmentTrack() {
        let manifest = createValidManifest()
        XCTAssertTrue(manifest.alignments.isEmpty)

        let track = AlignmentTrackInfo(
            id: "aln_1",
            name: "test.bam",
            format: .bam,
            sourcePath: "/data/test.bam",
            indexPath: "/data/test.bam.bai",
            addedDate: Date(),
            sampleNames: ["Sample1"]
        )

        let updated = manifest.addingAlignmentTrack(track)
        XCTAssertEqual(updated.alignments.count, 1)
        XCTAssertEqual(updated.alignments[0].id, "aln_1")
        // Other fields should be preserved
        XCTAssertEqual(updated.name, manifest.name)
        XCTAssertEqual(updated.annotations.count, manifest.annotations.count)
    }

    func testRemovingAlignmentTrack() {
        let track1 = AlignmentTrackInfo(
            id: "aln_1", name: "first.bam", format: .bam,
            sourcePath: "/data/first.bam", indexPath: "/data/first.bam.bai",
            addedDate: Date(), sampleNames: []
        )
        let track2 = AlignmentTrackInfo(
            id: "aln_2", name: "second.bam", format: .cram,
            sourcePath: "/data/second.cram", indexPath: "/data/second.cram.crai",
            addedDate: Date(), sampleNames: []
        )

        let manifest = createValidManifest()
            .addingAlignmentTrack(track1)
            .addingAlignmentTrack(track2)
        XCTAssertEqual(manifest.alignments.count, 2)

        let removed = manifest.removingAlignmentTrack(id: "aln_1")
        XCTAssertEqual(removed.alignments.count, 1)
        XCTAssertEqual(removed.alignments[0].id, "aln_2")
    }

    /// Regression: removing variant tracks must round-trip every other
    /// field (alignments, warnings, browserSummary, originBundlePath,
    /// recordStore, metadata) unchanged.
    func testRemovingAllVariantTracksPreservesOtherFields() throws {
        let alignmentTrack = AlignmentTrackInfo(
            id: "aln_1", name: "sample.bam", format: .bam,
            sourcePath: "alignments/sample.bam", indexPath: "alignments/sample.bam.bai",
            addedDate: Date(), sampleNames: ["SampleA"]
        )
        let variantTrack = VariantTrackInfo(
            id: "var_1",
            name: "SNPs",
            path: "variants/snps.bcf",
            indexPath: "variants/snps.bcf.csi",
            variantType: .snp,
            variantCount: 42
        )
        let recordStore = ReferenceRecordStoreInfo(
            schemaVersion: 1,
            format: "genbank",
            databasePath: "records/records.sqlite",
            recordCount: 7
        )
        let warning = BundleWarning(category: "import", code: "W1", message: "test warning")

        let manifest = BundleManifest(
            formatVersion: "1.0",
            name: "Fixture Genome",
            identifier: "test.fixture",
            originBundlePath: "@/Downloads/Fixture.lungfishref",
            source: SourceInfo(organism: "Test organism", assembly: "TestAssembly", database: "Test"),
            genome: GenomeInfo(
                path: "genome/sequence.fa.gz",
                indexPath: "genome/sequence.fa.gz.fai",
                gzipIndexPath: "genome/sequence.fa.gz.gzi",
                totalLength: 1_000_000,
                chromosomes: [
                    ChromosomeInfo(name: "chr1", length: 1_000_000, offset: 6, lineBases: 50, lineWidth: 51)
                ]
            ),
            annotations: [],
            variants: [variantTrack],
            tracks: [],
            alignments: [alignmentTrack],
            warnings: [warning],
            recordStore: recordStore
        )

        XCTAssertFalse(manifest.variants.isEmpty, "Fixture must start with a variant track")
        XCTAssertFalse(manifest.alignments.isEmpty, "Fixture must start with an alignment track")

        let updated = manifest.removingAllVariantTracks()

        XCTAssertTrue(updated.variants.isEmpty)
        XCTAssertEqual(updated.alignments, manifest.alignments, "Alignment tracks must survive variant deletion")
        XCTAssertEqual(updated.warnings, manifest.warnings, "Warnings must survive variant deletion")
        XCTAssertEqual(updated.recordStore, manifest.recordStore, "Record store must survive variant deletion")
        XCTAssertEqual(updated.originBundlePath, manifest.originBundlePath)
        XCTAssertEqual(updated.formatVersion, manifest.formatVersion)
        XCTAssertEqual(updated.name, manifest.name)
        XCTAssertEqual(updated.identifier, manifest.identifier)
        XCTAssertEqual(updated.source, manifest.source)
        XCTAssertEqual(updated.genome, manifest.genome)
        XCTAssertEqual(updated.tracks, manifest.tracks)
        XCTAssertGreaterThanOrEqual(updated.modifiedDate, manifest.modifiedDate)
    }

    func testAlignmentTrackCodable() throws {
        let track = AlignmentTrackInfo(
            id: "aln_codable",
            name: "codable.bam",
            format: .bam,
            sourcePath: "/data/codable.bam",
            sourceBookmark: "base64bookmark==",
            indexPath: "/data/codable.bam.bai",
            metadataDBPath: "alignments/aln_codable.stats.db",
            fileSizeBytes: 1_000_000,
            addedDate: Date(),
            mappedReadCount: 5_000_000,
            unmappedReadCount: 100_000,
            sampleNames: ["SampleA"]
        )

        let manifest = createValidManifest().addingAlignmentTrack(track)

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(manifest)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(BundleManifest.self, from: data)

        XCTAssertEqual(decoded.alignments.count, 1)
        XCTAssertEqual(decoded.alignments[0].id, "aln_codable")
        XCTAssertEqual(decoded.alignments[0].format, .bam)
        XCTAssertEqual(decoded.alignments[0].sourcePath, "/data/codable.bam")
        XCTAssertEqual(decoded.alignments[0].sourceBookmark, "base64bookmark==")
        XCTAssertEqual(decoded.alignments[0].mappedReadCount, 5_000_000)
        XCTAssertEqual(decoded.alignments[0].sampleNames, ["SampleA"])
    }

    func testBackwardCompatibleDecodingWithoutAlignments() throws {
        // Create a valid manifest, encode it, strip the "alignments" key, then decode
        let original = createValidManifest()

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = .prettyPrinted
        let data = try encoder.encode(original)

        // Parse as dictionary, remove "alignments", re-encode
        var dict = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        dict.removeValue(forKey: "alignments")
        let strippedData = try JSONSerialization.data(withJSONObject: dict)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let manifest = try decoder.decode(BundleManifest.self, from: strippedData)
        XCTAssertTrue(manifest.alignments.isEmpty, "Missing alignments field should decode as empty array")
        XCTAssertEqual(manifest.name, original.name)
    }

    func testDecodeWithoutBrowserSummaryForLegacyBundleJSON() throws {
        let legacyJSON = """
        {
          "format_version" : "1.0",
          "name" : "Legacy Bundle",
          "identifier" : "test.legacy",
          "created_date" : "2026-04-22T12:00:00Z",
          "modified_date" : "2026-04-22T12:00:00Z",
          "source" : {
            "organism" : "Test organism",
            "assembly" : "LegacyAsm"
          },
          "genome" : {
            "path" : "genome/seq.fa.gz",
            "index_path" : "genome/seq.fa.gz.fai",
            "total_length" : 1000,
            "chromosomes" : [
              {
                "name" : "chr1",
                "length" : 1000,
                "offset" : 0,
                "line_bases" : 50,
                "line_width" : 51,
                "aliases" : [ "1" ],
                "is_primary" : true,
                "is_mitochondrial" : false
              }
            ]
          },
          "annotations" : [],
          "variants" : [],
          "tracks" : []
        }
        """.data(using: .utf8)!

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let manifest = try decoder.decode(BundleManifest.self, from: legacyJSON)

        XCTAssertEqual(manifest.name, "Legacy Bundle")
        XCTAssertEqual(manifest.genome?.chromosomes.map(\.name), ["chr1"])
        XCTAssertTrue(manifest.alignments.isEmpty)
        XCTAssertNil(manifest.browserSummary)
        XCTAssertNil(manifest.recordStore)
    }

    func testDuplicateAlignmentTrackIdsValidation() {
        let track = AlignmentTrackInfo(
            id: "dup_aln", name: "dup.bam", format: .bam,
            sourcePath: "/data/dup.bam", indexPath: "/data/dup.bam.bai",
            addedDate: Date(), sampleNames: []
        )

        let manifest = BundleManifest(
            formatVersion: "1.0",
            name: "Test",
            identifier: "test",
            source: SourceInfo(organism: "Test", assembly: "Test"),
            genome: GenomeInfo(
                path: "genome/seq.fa.gz",
                indexPath: "genome/seq.fa.gz.fai",
                totalLength: 1000,
                chromosomes: [
                    ChromosomeInfo(name: "chr1", length: 1000, offset: 6, lineBases: 50, lineWidth: 51)
                ]
            ),
            annotations: [],
            variants: [],
            tracks: [],
            alignments: [track, track]  // Duplicate IDs
        )

        let errors = manifest.validate()
        XCTAssertFalse(errors.isEmpty, "Duplicate alignment track IDs should be a validation error")
    }

    // MARK: - Extended Alignment Track Tests

    func testMultipleAlignmentTracksRoundTrip() throws {
        let bamTrack = AlignmentTrackInfo(
            id: "aln_bam", name: "sample.bam", format: .bam,
            sourcePath: "/data/sample.bam", indexPath: "/data/sample.bam.bai",
            mappedReadCount: 30_000_000, unmappedReadCount: 500_000,
            sampleNames: ["NA12878"]
        )
        let cramTrack = AlignmentTrackInfo(
            id: "aln_cram", name: "sample.cram", format: .cram,
            sourcePath: "/data/sample.cram", indexPath: "/data/sample.cram.crai",
            mappedReadCount: 25_000_000, unmappedReadCount: 300_000,
            sampleNames: ["HG002"]
        )
        let samTrack = AlignmentTrackInfo(
            id: "aln_sam", name: "sample.sam", format: .sam,
            sourcePath: "/data/sample.sam", indexPath: "",
            sampleNames: ["HG003"]
        )

        var manifest = createValidManifest()
        manifest = manifest.addingAlignmentTrack(bamTrack)
        manifest = manifest.addingAlignmentTrack(cramTrack)
        manifest = manifest.addingAlignmentTrack(samTrack)
        XCTAssertEqual(manifest.alignments.count, 3)

        // Round-trip through JSON
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(manifest)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(BundleManifest.self, from: data)

        XCTAssertEqual(decoded.alignments.count, 3)
        XCTAssertEqual(decoded.alignments[0].format, .bam)
        XCTAssertEqual(decoded.alignments[1].format, .cram)
        XCTAssertEqual(decoded.alignments[2].format, .sam)
        XCTAssertEqual(decoded.alignments[0].sampleNames, ["NA12878"])
        XCTAssertEqual(decoded.alignments[1].sampleNames, ["HG002"])
        XCTAssertEqual(decoded.alignments[2].sampleNames, ["HG003"])
        XCTAssertEqual(decoded.alignments[0].mappedReadCount, 30_000_000)
        XCTAssertEqual(decoded.alignments[1].unmappedReadCount, 300_000)
    }

    func testAlignmentTrackWithAllOptionalFields() throws {
        let track = AlignmentTrackInfo(
            id: "full_track",
            name: "complete.bam",
            description: "A fully-populated test track",
            format: .bam,
            sourcePath: "/data/complete.bam",
            sourceBookmark: "c291cmNlYm9va21hcms=",
            indexPath: "/data/complete.bam.bai",
            indexBookmark: "aW5kZXhib29rbWFyaw==",
            metadataDBPath: "alignments/full_track.stats.db",
            checksumSHA256: "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
            fileSizeBytes: 5_368_709_120,
            addedDate: Date(),
            mappedReadCount: 100_000_000,
            unmappedReadCount: 2_000_000,
            sampleNames: ["SAMPLE_A", "SAMPLE_B"]
        )

        XCTAssertNotNil(track.description)
        XCTAssertNotNil(track.sourceBookmark)
        XCTAssertNotNil(track.indexBookmark)
        XCTAssertNotNil(track.metadataDBPath)
        XCTAssertNotNil(track.checksumSHA256)
        XCTAssertEqual(track.fileSizeBytes, 5_368_709_120)
        XCTAssertEqual(track.sampleNames.count, 2)

        // Round-trip
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(track)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(AlignmentTrackInfo.self, from: data)

        XCTAssertEqual(decoded.id, track.id)
        XCTAssertEqual(decoded.description, track.description)
        XCTAssertEqual(decoded.sourceBookmark, track.sourceBookmark)
        XCTAssertEqual(decoded.indexBookmark, track.indexBookmark)
        XCTAssertEqual(decoded.metadataDBPath, track.metadataDBPath)
        XCTAssertEqual(decoded.checksumSHA256, track.checksumSHA256)
        XCTAssertEqual(decoded.fileSizeBytes, track.fileSizeBytes)
        XCTAssertEqual(decoded.sampleNames, track.sampleNames)
    }

    func testRemoveNonExistentAlignmentTrack() {
        let track = AlignmentTrackInfo(
            id: "existing", name: "existing.bam", format: .bam,
            sourcePath: "/data/existing.bam", indexPath: "/data/existing.bam.bai"
        )

        var manifest = createValidManifest()
        manifest = manifest.addingAlignmentTrack(track)
        XCTAssertEqual(manifest.alignments.count, 1)

        // Removing a non-existent ID should be a no-op
        let updated = manifest.removingAlignmentTrack(id: "does_not_exist")
        XCTAssertEqual(updated.alignments.count, 1)
        XCTAssertEqual(updated.alignments[0].id, "existing")
    }

    func testAddAndRemoveMultipleAlignmentTracks() {
        var manifest = createValidManifest()

        let track1 = AlignmentTrackInfo(
            id: "track1", name: "a.bam", format: .bam,
            sourcePath: "/data/a.bam", indexPath: "/data/a.bam.bai"
        )
        let track2 = AlignmentTrackInfo(
            id: "track2", name: "b.cram", format: .cram,
            sourcePath: "/data/b.cram", indexPath: "/data/b.cram.crai"
        )

        manifest = manifest.addingAlignmentTrack(track1)
        manifest = manifest.addingAlignmentTrack(track2)
        XCTAssertEqual(manifest.alignments.count, 2)

        // Remove first track
        manifest = manifest.removingAlignmentTrack(id: "track1")
        XCTAssertEqual(manifest.alignments.count, 1)
        XCTAssertEqual(manifest.alignments[0].id, "track2")

        // Remove second track
        manifest = manifest.removingAlignmentTrack(id: "track2")
        XCTAssertTrue(manifest.alignments.isEmpty)
    }

    /// `bundle info --format json` prints the manifest with the read counts the stats database holds. The copy must not
    /// claim the bundle changed now, which is what `replacingAlignmentTrack` does with the modified date.
    func testDisplayingAlignmentsKeepsTheModifiedDateAndSetsOnlyTheTracksGiven() {
        let stored = Date(timeIntervalSince1970: 1_700_000_000)
        let track = AlignmentTrackInfo(
            id: "aln_1",
            name: "Sample A reads",
            sourcePath: "alignments/aln_1.sorted.bam",
            indexPath: "alignments/aln_1.sorted.bam.bai",
            mappedReadCount: 12,
            unmappedReadCount: 1
        )
        let manifest = BundleManifest(
            name: "Fixture",
            identifier: "test.fixture",
            modifiedDate: stored,
            source: SourceInfo(organism: "Test", assembly: "TestAssembly", database: "Fixture"),
            alignments: [track]
        )

        let shown = manifest.displayingAlignments([track.withReadCounts(mapped: 10, unmapped: 1)])

        XCTAssertEqual(shown.modifiedDate, stored, "output must not claim the bundle changed now")
        XCTAssertEqual(shown.alignments.first?.mappedReadCount, 10)
        XCTAssertEqual(shown.alignments.first?.unmappedReadCount, 1)
        XCTAssertEqual(shown.alignments.first?.sourcePath, track.sourcePath)
        XCTAssertEqual(shown.name, manifest.name)
        XCTAssertEqual(manifest.alignments.first?.mappedReadCount, 12, "the manifest given is not changed")
    }

    // MARK: - MetadataGroup Save/Load Tests

    func testMetadataGroupSaveAndLoad() throws {
        let groups = [
            MetadataGroup(name: "Pathoplexus", items: [
                MetadataItem(label: "Accession", value: "PP_12345"),
                MetadataItem(label: "Organism", value: "Mpox virus"),
                MetadataItem(label: "Country", value: "Nigeria"),
                MetadataItem(label: "Collection Date", value: "2024-01-15"),
                MetadataItem(label: "Data Use Terms", value: "OPEN"),
            ]),
            MetadataGroup(name: "Record", items: [
                MetadataItem(label: "Length", value: "197209"),
            ])
        ]

        let manifest = BundleManifest(
            formatVersion: "1.0",
            name: "Test Metadata Groups",
            identifier: "test.metadata",
            source: SourceInfo(organism: "Test", assembly: "Test"),
            genome: GenomeInfo(
                path: "genome/seq.fa.gz",
                indexPath: "genome/seq.fa.gz.fai",
                totalLength: 1000,
                chromosomes: [
                    ChromosomeInfo(name: "chr1", length: 1000, offset: 6, lineBases: 50, lineWidth: 51)
                ]
            ),
            annotations: [],
            variants: [],
            tracks: [],
            metadata: groups
        )

        let bundleURL = tempDirectory.appendingPathComponent("metadata-test.lungfishref")
        try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)
        try manifest.save(to: bundleURL)

        let loaded = try BundleManifest.load(from: bundleURL)

        XCTAssertNotNil(loaded.metadata)
        XCTAssertEqual(loaded.metadata?.count, 2)
        XCTAssertEqual(loaded.metadata?[0].name, "Pathoplexus")
        XCTAssertEqual(loaded.metadata?[0].items.count, 5)
        XCTAssertEqual(loaded.metadata?[0].items[0].label, "Accession")
        XCTAssertEqual(loaded.metadata?[0].items[0].value, "PP_12345")
        XCTAssertEqual(loaded.metadata?[0].items[3].value, "2024-01-15")
        XCTAssertEqual(loaded.metadata?[1].name, "Record")
    }

    func testMetadataGroupAppendAfterSave() throws {
        let manifest = createValidManifest()

        let bundleURL = tempDirectory.appendingPathComponent("append-test.lungfishref")
        try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)
        try manifest.save(to: bundleURL)

        // Load, append metadata, save again (simulates appendPathoplexusMetadata)
        let loaded = try BundleManifest.load(from: bundleURL)
        XCTAssertNil(loaded.metadata)

        let ppGroup = MetadataGroup(name: "Pathoplexus", items: [
            MetadataItem(label: "Accession", value: "PP_001"),
        ])
        var groups = loaded.metadata ?? []
        groups.append(ppGroup)

        let updated = BundleManifest(
            formatVersion: loaded.formatVersion,
            name: loaded.name,
            identifier: loaded.identifier,
            description: loaded.description,
            createdDate: loaded.createdDate,
            modifiedDate: Date(),
            source: loaded.source,
            genome: loaded.genome,
            annotations: loaded.annotations,
            variants: loaded.variants,
            tracks: loaded.tracks,
            alignments: loaded.alignments,
            metadata: groups
        )
        try updated.save(to: bundleURL)

        let reloaded = try BundleManifest.load(from: bundleURL)
        XCTAssertNotNil(reloaded.metadata)
        XCTAssertEqual(reloaded.metadata?.count, 1)
        XCTAssertEqual(reloaded.metadata?[0].name, "Pathoplexus")
        XCTAssertEqual(reloaded.metadata?[0].items[0].value, "PP_001")
    }

    // MARK: - Helper Methods

    private func createValidManifest() -> BundleManifest {
        BundleManifest(
            formatVersion: "1.0",
            name: "Test Genome",
            identifier: "test.genome",
            source: SourceInfo(
                organism: "Test organism",
                assembly: "TestAssembly",
                database: "Test"
            ),
            genome: GenomeInfo(
                path: "genome/sequence.fa.gz",
                indexPath: "genome/sequence.fa.gz.fai",
                gzipIndexPath: "genome/sequence.fa.gz.gzi",
                totalLength: 1_000_000,
                chromosomes: [
                    ChromosomeInfo(name: "chr1", length: 1_000_000, offset: 6, lineBases: 50, lineWidth: 51)
                ]
            ),
            annotations: [],
            variants: [],
            tracks: []
        )
    }

    private func manifestWithRecordStore(_ recordStore: ReferenceRecordStoreInfo) -> BundleManifest {
        BundleManifest(
            name: "Record Store",
            identifier: "test.record-store",
            source: SourceInfo(organism: "Test", assembly: "Test"),
            recordStore: recordStore
        )
    }
}
