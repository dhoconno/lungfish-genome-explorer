// ReferenceBundleTests.swift - Tests for reference bundle reader
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
@testable import LungfishIO
@testable import LungfishCore

final class ReferenceBundleTests: XCTestCase {

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

    // MARK: - Bundle Opening Tests

    func testOpenValidBundle() async throws {
        let bundleURL = try createValidTestBundle()

        let bundle = try await ReferenceBundle(url: bundleURL)

        XCTAssertEqual(bundle.name, "Test Genome")
        XCTAssertEqual(bundle.identifier, "test.genome")
        XCTAssertEqual(bundle.assembly, "TestAssembly")
        XCTAssertEqual(bundle.organism, "Test organism")
    }

    func testOpenNonexistentBundle() async {
        let nonexistentURL = tempDirectory.appendingPathComponent("nonexistent.lungfishref")

        do {
            _ = try await ReferenceBundle(url: nonexistentURL)
            XCTFail("Expected error for nonexistent bundle")
        } catch let error as ReferenceBundleError {
            if case .notADirectory = error {
                // Expected
            } else {
                XCTFail("Expected notADirectory error, got \(error)")
            }
        } catch {
            XCTFail("Unexpected error type: \(error)")
        }
    }

    func testOpenBundleWithWrongExtension() async throws {
        // Create a directory with wrong extension
        let wrongExtURL = tempDirectory.appendingPathComponent("test.wrongext")
        try FileManager.default.createDirectory(at: wrongExtURL, withIntermediateDirectories: true)

        do {
            _ = try await ReferenceBundle(url: wrongExtURL)
            XCTFail("Expected error for wrong extension")
        } catch let error as ReferenceBundleError {
            if case .invalidExtension(let ext) = error {
                XCTAssertEqual(ext, "wrongext")
            } else {
                XCTFail("Expected invalidExtension error, got \(error)")
            }
        } catch {
            XCTFail("Unexpected error type: \(error)")
        }
    }

    func testOpenBundleWithMissingManifest() async throws {
        let bundleURL = tempDirectory.appendingPathComponent("nomanifest.lungfishref")
        try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)

        do {
            _ = try await ReferenceBundle(url: bundleURL)
            XCTFail("Expected error for missing manifest")
        } catch let error as ReferenceBundleError {
            if case .manifestLoadFailed = error {
                // Expected
            } else {
                XCTFail("Expected manifestLoadFailed error, got \(error)")
            }
        } catch {
            XCTFail("Unexpected error type: \(error)")
        }
    }

    // MARK: - Chromosome Information Tests

    func testChromosomeNames() async throws {
        let bundleURL = try createValidTestBundle()
        let bundle = try await ReferenceBundle(url: bundleURL)

        let names = bundle.chromosomeNames
        XCTAssertEqual(names, ["chr1", "chr2"])
    }

    func testChromosomeLookupByName() async throws {
        let bundleURL = try createValidTestBundle()
        let bundle = try await ReferenceBundle(url: bundleURL)

        let chr1 = bundle.chromosome(named: "chr1")
        XCTAssertNotNil(chr1)
        XCTAssertEqual(chr1?.name, "chr1")
        XCTAssertEqual(chr1?.length, 1000)

        let chr2 = bundle.chromosome(named: "chr2")
        XCTAssertNotNil(chr2)
        XCTAssertEqual(chr2?.name, "chr2")
        XCTAssertEqual(chr2?.length, 500)
    }

    func testChromosomeLookupByAlias() async throws {
        let bundleURL = try createValidTestBundle()
        let bundle = try await ReferenceBundle(url: bundleURL)

        // Look up by alias "1" instead of "chr1"
        let chr1 = bundle.chromosome(named: "1")
        XCTAssertNotNil(chr1)
        XCTAssertEqual(chr1?.name, "chr1")
    }

    func testChromosomeLookupNotFound() async throws {
        let bundleURL = try createValidTestBundle()
        let bundle = try await ReferenceBundle(url: bundleURL)

        let notFound = bundle.chromosome(named: "chrZ")
        XCTAssertNil(notFound)
    }

    func testChromosomeLength() async throws {
        let bundleURL = try createValidTestBundle()
        let bundle = try await ReferenceBundle(url: bundleURL)

        XCTAssertEqual(bundle.chromosomeLength(named: "chr1"), 1000)
        XCTAssertEqual(bundle.chromosomeLength(named: "chr2"), 500)
        XCTAssertNil(bundle.chromosomeLength(named: "chrZ"))
    }

    // MARK: - Track Information Tests

    func testAnnotationTrackIds() async throws {
        let bundleURL = try createValidTestBundle()
        let bundle = try await ReferenceBundle(url: bundleURL)

        let trackIds = bundle.annotationTrackIds
        XCTAssertEqual(trackIds, ["genes"])
    }

    func testAnnotationTrackLookup() async throws {
        let bundleURL = try createValidTestBundle()
        let bundle = try await ReferenceBundle(url: bundleURL)

        let track = bundle.annotationTrack(id: "genes")
        XCTAssertNotNil(track)
        XCTAssertEqual(track?.name, "Gene Annotations")
        XCTAssertEqual(track?.path, "annotations/genes.bb")
    }

    func testVariantTrackIds() async throws {
        let bundleURL = try createValidTestBundle()
        let bundle = try await ReferenceBundle(url: bundleURL)

        let trackIds = bundle.variantTrackIds
        XCTAssertEqual(trackIds, ["variants"])
    }

    func testSignalTrackIds() async throws {
        let bundleURL = try createValidTestBundle()
        let bundle = try await ReferenceBundle(url: bundleURL)

        let trackIds = bundle.signalTrackIds
        XCTAssertEqual(trackIds, ["gc_content"])
    }

    func testResolveAlignmentPathsFromBundleRelativeTrackInfo() async throws {
        let bundleURL = try createValidTestBundle()
        let alignmentsDir = bundleURL.appendingPathComponent("alignments", isDirectory: true)
        try FileManager.default.createDirectory(at: alignmentsDir, withIntermediateDirectories: true)

        let alignmentURL = alignmentsDir.appendingPathComponent("sample.sorted.bam")
        let indexURL = alignmentsDir.appendingPathComponent("sample.sorted.bam.bai")
        try Data([0x42, 0x41, 0x4D]).write(to: alignmentURL)
        try Data([0x42, 0x41, 0x49]).write(to: indexURL)

        let bundle = try await ReferenceBundle(url: bundleURL)
        let track = AlignmentTrackInfo(
            id: "aln_test",
            name: "sample.sorted.bam",
            format: .bam,
            sourcePath: "alignments/sample.sorted.bam",
            indexPath: "alignments/sample.sorted.bam.bai"
        )

        XCTAssertEqual(try bundle.resolveAlignmentPath(track), alignmentURL.path)
        XCTAssertEqual(try bundle.resolveAlignmentIndexPath(track), indexURL.path)
    }

    // MARK: - Error Description Tests

    func testReferenceBundleErrorDescriptions() {
        let notADirError = ReferenceBundleError.notADirectory(URL(fileURLWithPath: "/test/path"))
        XCTAssertTrue(notADirError.localizedDescription.contains("not a directory"))

        let invalidExtError = ReferenceBundleError.invalidExtension("txt")
        XCTAssertTrue(invalidExtError.localizedDescription.contains("txt"))
        XCTAssertTrue(invalidExtError.localizedDescription.contains("lungfishref"))

        let chromNotFoundError = ReferenceBundleError.chromosomeNotFound("chrZ")
        XCTAssertTrue(chromNotFoundError.localizedDescription.contains("chrZ"))

        let trackNotFoundError = ReferenceBundleError.trackNotFound("missing_track")
        XCTAssertTrue(trackNotFoundError.localizedDescription.contains("missing_track"))
    }

    func testReferenceBundleErrorRecoverySuggestions() {
        let notADirError = ReferenceBundleError.notADirectory(URL(fileURLWithPath: "/test"))
        XCTAssertNotNil(notADirError.recoverySuggestion)

        let invalidExtError = ReferenceBundleError.invalidExtension("txt")
        XCTAssertNotNil(invalidExtError.recoverySuggestion)

        let chromNotFoundError = ReferenceBundleError.chromosomeNotFound("chrZ")
        XCTAssertNotNil(chromNotFoundError.recoverySuggestion)
    }

    // MARK: - BundleVariant Tests

    func testBundleVariantCreation() {
        let variant = BundleVariant(
            id: "var1",
            chromosome: "chr1",
            position: 12345,
            ref: "A",
            alt: ["G"],
            quality: 99.5,
            variantId: "rs12345",
            filter: "PASS"
        )

        XCTAssertEqual(variant.id, "var1")
        XCTAssertEqual(variant.chromosome, "chr1")
        XCTAssertEqual(variant.position, 12345)
        XCTAssertEqual(variant.ref, "A")
        XCTAssertEqual(variant.alt, ["G"])
        XCTAssertEqual(variant.quality, 99.5)
        XCTAssertEqual(variant.variantId, "rs12345")
        XCTAssertEqual(variant.filter, "PASS")
    }

    func testBundleVariantEquatable() {
        let variant1 = BundleVariant(
            id: "var1",
            chromosome: "chr1",
            position: 100,
            ref: "A",
            alt: ["G"]
        )

        let variant2 = BundleVariant(
            id: "var1",
            chromosome: "chr1",
            position: 100,
            ref: "A",
            alt: ["G"]
        )

        let variant3 = BundleVariant(
            id: "var2",
            chromosome: "chr1",
            position: 200,
            ref: "C",
            alt: ["T"]
        )

        XCTAssertEqual(variant1, variant2)
        XCTAssertNotEqual(variant1, variant3)
    }

    // MARK: - GenomicRegion Description Tests

    func testGenomicRegionDescription() {
        let region = GenomicRegion(chromosome: "chr1", start: 1000, end: 2000)
        XCTAssertEqual(region.description, "chr1:1000-2000")
    }

    // MARK: - Helper Methods

    private func createValidTestBundle() throws -> URL {
        let bundleURL = tempDirectory.appendingPathComponent("test.lungfishref")
        try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)

        // Create genome directory and files
        let genomeDir = bundleURL.appendingPathComponent("genome")
        try FileManager.default.createDirectory(at: genomeDir, withIntermediateDirectories: true)

        // Create a simple FASTA file
        let fastaContent = """
        >chr1
        ATCGATCGATCGATCGATCGATCGATCGATCGATCGATCGATCGATCGATCG
        ATCGATCGATCGATCGATCGATCGATCGATCGATCGATCGATCGATCGATCG
        >chr2
        GGGGCCCCGGGGCCCCGGGGCCCCGGGGCCCCGGGGCCCC
        """
        let fastaURL = genomeDir.appendingPathComponent("sequence.fa.gz")
        try fastaContent.write(to: fastaURL, atomically: true, encoding: .utf8)

        // Create index file
        let indexContent = """
        chr1\t1000\t6\t50\t51
        chr2\t500\t1100\t50\t51
        """
        let indexURL = genomeDir.appendingPathComponent("sequence.fa.gz.fai")
        try indexContent.write(to: indexURL, atomically: true, encoding: .utf8)

        // Create manifest
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
                path: "genome/sequence.fa.gz",
                indexPath: "genome/sequence.fa.gz.fai",
                totalLength: 1500,
                chromosomes: [
                    ChromosomeInfo(name: "chr1", length: 1000, offset: 6, lineBases: 50, lineWidth: 51, aliases: ["1"]),
                    ChromosomeInfo(name: "chr2", length: 500, offset: 1100, lineBases: 50, lineWidth: 51, aliases: ["2"])
                ]
            ),
            annotations: [
                AnnotationTrackInfo(
                    id: "genes",
                    name: "Gene Annotations",
                    description: "Test gene annotations",
                    path: "annotations/genes.bb",
                    featureCount: 100
                )
            ],
            variants: [
                VariantTrackInfo(
                    id: "variants",
                    name: "Test Variants",
                    description: "Test variants",
                    path: "variants/test.bcf",
                    indexPath: "variants/test.bcf.csi",
                    variantCount: 1000
                )
            ],
            tracks: [
                SignalTrackInfo(
                    id: "gc_content",
                    name: "GC Content",
                    description: "GC percentage",
                    path: "tracks/gc.bw",
                    signalType: .gcContent
                )
            ]
        )

        try manifest.save(to: bundleURL)

        return bundleURL
    }
}
