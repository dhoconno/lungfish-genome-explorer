// BundleManifestTests.swift - Tests for bundle manifest data model
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
@testable import LungfishCore

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
        XCTAssertEqual(manifest.source.organism, "Homo sapiens")
        XCTAssertEqual(manifest.source.assembly, "GRCh38")
        XCTAssertEqual(manifest.genome.chromosomes.count, 2)
        XCTAssertEqual(manifest.genome.totalLength, 3_100_000_000)
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
        XCTAssertEqual(manifest.genome.path, decoded.genome.path)
        XCTAssertEqual(manifest.genome.chromosomes.count, decoded.genome.chromosomes.count)
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
}
