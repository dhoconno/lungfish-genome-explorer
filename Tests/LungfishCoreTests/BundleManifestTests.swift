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
