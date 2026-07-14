// ReferenceBundleTests.swift - Tests for reference bundle reader
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
import os
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

    func testRecordStoreDatabaseReturnsNilWhenManifestDoesNotDeclareStore() async throws {
        let bundleURL = try createValidTestBundle()
        let bundle = try await ReferenceBundle(url: bundleURL)

        XCTAssertNil(try bundle.recordStoreDatabase())
    }

    func testRecordStoreDatabaseOpensDeclaredGenBankDatabase() async throws {
        let bundleURL = tempDirectory.appendingPathComponent("record-store.lungfishref", isDirectory: true)
        let metadataURL = bundleURL.appendingPathComponent("metadata", isDirectory: true)
        try FileManager.default.createDirectory(at: metadataURL, withIntermediateDirectories: true)
        let databaseURL = metadataURL.appendingPathComponent("genbank_records.sqlite")
        let record = GenBankRecord(
            sequence: try Sequence(name: "NHP00353", alphabet: .dna, bases: "ATGC"),
            annotations: [],
            locus: LocusInfo(name: "NHP00353", length: 4, moleculeType: .dna, topology: .linear),
            accession: "NHP00353"
        )
        try GenBankRecordDatabase.create(records: [record], at: databaseURL)
        let manifest = BundleManifest(
            name: "MHC Reference",
            identifier: "test.record-store",
            source: SourceInfo(organism: "Macaca fascicularis", assembly: "IPD-MHC"),
            recordStore: ReferenceRecordStoreInfo(
                schemaVersion: 1,
                format: "genbank",
                databasePath: "metadata/genbank_records.sqlite",
                recordCount: 1
            )
        )
        try manifest.save(to: bundleURL)

        let bundle = try await ReferenceBundle(url: bundleURL)
        let database = try XCTUnwrap(bundle.recordStoreDatabase())

        XCTAssertEqual(try database.records().map(\.sequenceName), ["NHP00353"])
    }

    func testRecordStoreDatabaseThrowsForMissingDeclaredDatabase() async throws {
        let bundleURL = tempDirectory.appendingPathComponent("missing-record-store.lungfishref", isDirectory: true)
        try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)
        let manifest = BundleManifest(
            name: "Missing Record Store",
            identifier: "test.missing-record-store",
            source: SourceInfo(organism: "Test", assembly: "Test"),
            recordStore: ReferenceRecordStoreInfo(
                schemaVersion: 1,
                format: "genbank",
                databasePath: "metadata/genbank_records.sqlite",
                recordCount: 1
            )
        )
        try manifest.save(to: bundleURL)
        let bundle = try await ReferenceBundle(url: bundleURL)

        XCTAssertThrowsError(try bundle.recordStoreDatabase())
    }

    func testRecordStoreDatabaseThrowsForCorruptDeclaredDatabase() async throws {
        let bundleURL = tempDirectory.appendingPathComponent("corrupt-record-store.lungfishref", isDirectory: true)
        let metadataURL = bundleURL.appendingPathComponent("metadata", isDirectory: true)
        try FileManager.default.createDirectory(at: metadataURL, withIntermediateDirectories: true)
        try Data("not sqlite".utf8).write(to: metadataURL.appendingPathComponent("genbank_records.sqlite"))
        let manifest = BundleManifest(
            name: "Corrupt Record Store",
            identifier: "test.corrupt-record-store",
            source: SourceInfo(organism: "Test", assembly: "Test"),
            recordStore: ReferenceRecordStoreInfo(
                schemaVersion: 1,
                format: "genbank",
                databasePath: "metadata/genbank_records.sqlite",
                recordCount: 1
            )
        )
        try manifest.save(to: bundleURL)
        let bundle = try await ReferenceBundle(url: bundleURL)

        XCTAssertThrowsError(try bundle.recordStoreDatabase())
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

    func testOpenRejectsGenomeSymlinkEscapingBundle() async throws {
        let bundleURL = tempDirectory.appendingPathComponent("symlink-escape.lungfishref", isDirectory: true)
        let genomeDirectory = bundleURL.appendingPathComponent("genome", isDirectory: true)
        try FileManager.default.createDirectory(at: genomeDirectory, withIntermediateDirectories: true)

        let outsideFASTA = tempDirectory.appendingPathComponent("outside.fa")
        try ">chr1\nACGT\n".write(to: outsideFASTA, atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(
            at: genomeDirectory.appendingPathComponent("sequence.fa"),
            withDestinationURL: outsideFASTA
        )
        try "chr1\t4\t6\t4\t5\n".write(
            to: genomeDirectory.appendingPathComponent("sequence.fa.fai"),
            atomically: true,
            encoding: .utf8
        )

        let manifest = BundleManifest(
            formatVersion: "1.0",
            name: "Symlink Escape",
            identifier: "test.symlink-escape",
            source: SourceInfo(organism: "Test organism", assembly: "TestAssembly"),
            genome: GenomeInfo(
                path: "genome/sequence.fa",
                indexPath: "genome/sequence.fa.fai",
                totalLength: 4,
                chromosomes: [
                    ChromosomeInfo(name: "chr1", length: 4, offset: 6, lineBases: 4, lineWidth: 5)
                ]
            )
        )
        try manifest.save(to: bundleURL)

        do {
            _ = try await ReferenceBundle(url: bundleURL)
            XCTFail("Expected symlink-escaping genome path to be rejected")
        } catch let error as ReferenceBundleError {
            guard case .validationFailed(let errors) = error else {
                return XCTFail("Expected validationFailed error, got \(error)")
            }
            XCTAssertTrue(errors.contains { validationError in
                guard case .invalidPath(let field, let path) = validationError else { return false }
                return field == "genome.path" && path == "genome/sequence.fa"
            })
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

    func testChromosomeLookupByVersionedAccessionFallsBackToUnversionedName() async throws {
        let bundleURL = try createSingleSequenceBundle(sequenceName: "MN908947")
        let bundle = try await ReferenceBundle(url: bundleURL)

        let chromosome = bundle.chromosome(named: "MN908947.3")

        XCTAssertNotNil(chromosome)
        XCTAssertEqual(chromosome?.name, "MN908947")
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

    func testGetVariantsThrowsUnsupportedFormatForBCFOnlyTrack() async throws {
        let bundleURL = try createBCFOnlyVariantBundle()
        let bundle = try await ReferenceBundle(url: bundleURL)
        let region = GenomicRegion(chromosome: "chr1", start: 0, end: 100)

        XCTAssertThrowsError(try bundle.getVariants(trackId: "variants", region: region)) { error in
            guard case ReferenceBundleError.unsupportedTrackFormat(let trackId, let format, let reason) = error else {
                XCTFail("Expected unsupportedTrackFormat, got \(error)")
                return
            }
            XCTAssertEqual(trackId, "variants")
            XCTAssertEqual(format, "BCF")
            XCTAssertTrue(reason.contains("SQLite"))
        }
    }

    func testGetVariantAnnotationsThrowsUnsupportedFormatForBCFOnlyTrack() async throws {
        let bundleURL = try createBCFOnlyVariantBundle()
        let bundle = try await ReferenceBundle(url: bundleURL)
        let region = GenomicRegion(chromosome: "chr1", start: 0, end: 100)

        XCTAssertThrowsError(try bundle.getVariantAnnotations(trackId: "variants", region: region)) { error in
            guard case ReferenceBundleError.unsupportedTrackFormat(let trackId, let format, _) = error else {
                XCTFail("Expected unsupportedTrackFormat, got \(error)")
                return
            }
            XCTAssertEqual(trackId, "variants")
            XCTAssertEqual(format, "BCF")
        }
    }

    func testGetVariantsUsesReadableSQLiteSidecar() async throws {
        let bundleURL = try createSQLiteVariantBundle()
        let bundle = try await ReferenceBundle(url: bundleURL)
        let region = GenomicRegion(chromosome: "chr1", start: 0, end: 100)

        let variants = try bundle.getVariants(trackId: "variants", region: region)

        XCTAssertEqual(variants.count, 1)
        XCTAssertEqual(variants.first?.variantId, "rs1")
        XCTAssertEqual(variants.first?.ref, "A")
        XCTAssertEqual(variants.first?.alt, ["G"])
    }

    func testGetVariantAnnotationsUsesReadableSQLiteSidecar() async throws {
        let bundleURL = try createSQLiteVariantBundle()
        let bundle = try await ReferenceBundle(url: bundleURL)
        let region = GenomicRegion(chromosome: "chr1", start: 0, end: 100)

        let annotations = try bundle.getVariantAnnotations(trackId: "variants", region: region)

        XCTAssertEqual(annotations.count, 1)
        XCTAssertEqual(annotations.first?.name, "rs1")
        XCTAssertEqual(annotations.first?.qualifiers["variant_track_id"]?.firstValue, "variants")
    }

    func testGetVariantsThrowsVariantReadFailedForInvalidSQLiteSidecar() async throws {
        let bundleURL = try createInvalidSQLiteVariantBundle()
        let bundle = try await ReferenceBundle(url: bundleURL)
        let region = GenomicRegion(chromosome: "chr1", start: 0, end: 100)

        XCTAssertThrowsError(try bundle.getVariants(trackId: "variants", region: region)) { error in
            guard case ReferenceBundleError.variantReadFailed(let reason) = error else {
                XCTFail("Expected variantReadFailed, got \(error)")
                return
            }
            XCTAssertTrue(reason.contains("SQLite sidecar"))
            XCTAssertTrue(reason.contains("variants.db"))
        }
    }

    func testGetVariantAnnotationsThrowsVariantReadFailedForInvalidSQLiteSidecar() async throws {
        let bundleURL = try createInvalidSQLiteVariantBundle()
        let bundle = try await ReferenceBundle(url: bundleURL)
        let region = GenomicRegion(chromosome: "chr1", start: 0, end: 100)

        XCTAssertThrowsError(try bundle.getVariantAnnotations(trackId: "variants", region: region)) { error in
            guard case ReferenceBundleError.variantReadFailed(let reason) = error else {
                XCTFail("Expected variantReadFailed, got \(error)")
                return
            }
            XCTAssertTrue(reason.contains("SQLite sidecar"))
            XCTAssertTrue(reason.contains("variants.db"))
        }
    }

    func testGetVariantsThrowsVariantReadFailedForMissingSQLiteSidecar() async throws {
        let bundleURL = try createSQLiteVariantBundle(writeDatabase: false)
        let bundle = try await ReferenceBundle(url: bundleURL)
        let region = GenomicRegion(chromosome: "chr1", start: 0, end: 100)

        XCTAssertThrowsError(try bundle.getVariants(trackId: "variants", region: region)) { error in
            guard case ReferenceBundleError.variantReadFailed(let reason) = error else {
                XCTFail("Expected variantReadFailed, got \(error)")
                return
            }
            XCTAssertTrue(reason.contains("is missing"))
            XCTAssertTrue(reason.contains("variants.db"))
        }
    }

    func testGetVariantAnnotationsThrowsVariantReadFailedForMissingSQLiteSidecar() async throws {
        let bundleURL = try createSQLiteVariantBundle(writeDatabase: false)
        let bundle = try await ReferenceBundle(url: bundleURL)
        let region = GenomicRegion(chromosome: "chr1", start: 0, end: 100)

        XCTAssertThrowsError(try bundle.getVariantAnnotations(trackId: "variants", region: region)) { error in
            guard case ReferenceBundleError.variantReadFailed(let reason) = error else {
                XCTFail("Expected variantReadFailed, got \(error)")
                return
            }
            XCTAssertTrue(reason.contains("is missing"))
            XCTAssertTrue(reason.contains("variants.db"))
        }
    }

    func testGetVariantsThrowsMissingFileWhenBCFPayloadIsAbsent() async throws {
        let bundleURL = try createBCFOnlyVariantBundle(writePayload: false)
        let bundle = try await ReferenceBundle(url: bundleURL)
        let region = GenomicRegion(chromosome: "chr1", start: 0, end: 100)

        XCTAssertThrowsError(try bundle.getVariants(trackId: "variants", region: region)) { error in
            guard case ReferenceBundleError.missingFile(let path) = error else {
                XCTFail("Expected missingFile, got \(error)")
                return
            }
            XCTAssertEqual(path, "variants/test.bcf")
        }
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

    func testBookmarkedAlignmentPathsKeepSecurityScopedAccessAlive() async throws {
        let bundleURL = try createValidTestBundle()
        let manifest = try BundleManifest.load(from: bundleURL)
        let externalDir = tempDirectory.appendingPathComponent("external-alignments", isDirectory: true)
        try FileManager.default.createDirectory(at: externalDir, withIntermediateDirectories: true)

        let alignmentURL = externalDir.appendingPathComponent("sample.sorted.bam")
        let indexURL = externalDir.appendingPathComponent("sample.sorted.bam.bai")
        try Data([0x42, 0x41, 0x4D]).write(to: alignmentURL)
        try Data([0x42, 0x41, 0x49]).write(to: indexURL)

        let sourceBookmark = Data([0x01, 0x02, 0x03])
        let indexBookmark = Data([0x04, 0x05, 0x06])
        let probe = ReferenceBundleBookmarkAccessProbe(
            resolutions: [
                sourceBookmark: alignmentURL,
                indexBookmark: indexURL,
            ]
        )
        var bundle: ReferenceBundle? = ReferenceBundle(
            url: bundleURL,
            manifest: manifest,
            bookmarkAccess: ReferenceBundleBookmarkAccess(
                resolve: probe.resolve,
                startAccessing: probe.startAccessing,
                stopAccessing: probe.stopAccessing
            )
        )
        let track = AlignmentTrackInfo(
            id: "external",
            name: "sample.sorted.bam",
            format: .bam,
            sourcePath: "/missing/sample.sorted.bam",
            sourceBookmark: sourceBookmark.base64EncodedString(),
            indexPath: "/missing/sample.sorted.bam.bai",
            indexBookmark: indexBookmark.base64EncodedString()
        )

        XCTAssertEqual(try bundle?.resolveAlignmentPath(track), alignmentURL.standardizedFileURL.path)
        XCTAssertEqual(try bundle?.resolveAlignmentIndexPath(track), indexURL.standardizedFileURL.path)
        XCTAssertEqual(probe.startedURLs(), [alignmentURL.standardizedFileURL, indexURL.standardizedFileURL])
        XCTAssertTrue(probe.stoppedURLs().isEmpty)

        bundle = nil

        XCTAssertEqual(Set(probe.stoppedURLs()), Set([alignmentURL.standardizedFileURL, indexURL.standardizedFileURL]))
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

        let unsupportedTrackError = ReferenceBundleError.unsupportedTrackFormat(
            trackId: "variants",
            format: "BCF",
            reason: "SQLite sidecar required"
        )
        XCTAssertTrue(unsupportedTrackError.localizedDescription.contains("variants"))
        XCTAssertTrue(unsupportedTrackError.localizedDescription.contains("BCF"))
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

    func testFetchSequenceSyncUsesCanonicalFASTANameForVersionedAccession() async throws {
        let bundleURL = try createSingleSequenceBundle(sequenceName: "MN908947")
        let bundle = try await ReferenceBundle(url: bundleURL)
        let region = GenomicRegion(chromosome: "MN908947.3", start: 2, end: 6)

        let sequence = try bundle.fetchSequenceSync(region: region)

        XCTAssertEqual(sequence, "GTAC")
    }

    func testGetAnnotationsSyncUsesVersionedDatabaseChromosomeForUnversionedReference() async throws {
        let bundleURL = try createSingleSequenceBundle(
            sequenceName: "MN908947",
            annotationChromosome: "MN908947.3"
        )
        let bundle = try await ReferenceBundle(url: bundleURL)
        let region = GenomicRegion(chromosome: "MN908947", start: 0, end: 8)

        let annotations = try bundle.getAnnotationsSync(trackId: "genes", region: region)

        XCTAssertEqual(annotations.map(\.name), ["geneA"])
        XCTAssertEqual(annotations.first?.chromosome, "MN908947.3")
    }

    // MARK: - Helper Methods

    private func createSingleSequenceBundle(
        sequenceName: String,
        annotationChromosome: String? = nil
    ) throws -> URL {
        let bundleURL = tempDirectory.appendingPathComponent("\(sequenceName).lungfishref")
        try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)

        let genomeDir = bundleURL.appendingPathComponent("genome")
        try FileManager.default.createDirectory(at: genomeDir, withIntermediateDirectories: true)
        let annotationsDir = bundleURL.appendingPathComponent("annotations")
        try FileManager.default.createDirectory(at: annotationsDir, withIntermediateDirectories: true)

        let fastaContent = """
        >\(sequenceName)
        ACGTACGT
        """
        let fastaURL = genomeDir.appendingPathComponent("sequence.fa")
        try fastaContent.write(to: fastaURL, atomically: true, encoding: .utf8)

        let headerByteCount = sequenceName.utf8.count + 2
        let indexContent = "\(sequenceName)\t8\t\(headerByteCount)\t8\t9\n"
        let indexURL = genomeDir.appendingPathComponent("sequence.fa.fai")
        try indexContent.write(to: indexURL, atomically: true, encoding: .utf8)

        var annotationTracks: [AnnotationTrackInfo] = []
        if let annotationChromosome {
            let bedURL = tempDirectory.appendingPathComponent("\(sequenceName)-annotations.bed")
            let bedLine = [
                annotationChromosome,
                "2",
                "6",
                "geneA",
                "0",
                "+",
                "2",
                "6",
                "0,0,0",
                "1",
                "4,",
                "0,",
                "gene",
                "gene=geneA",
            ].joined(separator: "\t")
            try bedLine.write(to: bedURL, atomically: true, encoding: .utf8)

            let dbURL = annotationsDir.appendingPathComponent("genes.db")
            _ = try AnnotationDatabase.createFromBED(bedURL: bedURL, outputURL: dbURL)
            annotationTracks = [
                AnnotationTrackInfo(
                    id: "genes",
                    name: "Genes",
                    path: "annotations/genes.bb",
                    databasePath: "annotations/genes.db",
                    featureCount: 1
                ),
            ]
        }

        let manifest = BundleManifest(
            formatVersion: "1.0",
            name: "Single Sequence",
            identifier: "test.single",
            source: SourceInfo(
                organism: "Test organism",
                assembly: sequenceName,
                database: "Test"
            ),
            genome: GenomeInfo(
                path: "genome/sequence.fa",
                indexPath: "genome/sequence.fa.fai",
                totalLength: 8,
                chromosomes: [
                    ChromosomeInfo(
                        name: sequenceName,
                        length: 8,
                        offset: Int64(headerByteCount),
                        lineBases: 8,
                        lineWidth: 9
                    )
                ]
            ),
            annotations: annotationTracks
        )

        try manifest.save(to: bundleURL)

        return bundleURL
    }

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

    private func createBCFOnlyVariantBundle(writePayload: Bool = true) throws -> URL {
        let bundleURL = tempDirectory.appendingPathComponent("bcf-only.lungfishref")
        try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)

        let variantsDir = bundleURL.appendingPathComponent("variants")
        try FileManager.default.createDirectory(at: variantsDir, withIntermediateDirectories: true)
        if writePayload {
            try Data([0x42, 0x43, 0x46]).write(to: variantsDir.appendingPathComponent("test.bcf"))
            try Data([0x43, 0x53, 0x49]).write(to: variantsDir.appendingPathComponent("test.bcf.csi"))
        }

        let manifest = BundleManifest(
            formatVersion: "1.0",
            name: "BCF Only",
            identifier: "test.bcf-only",
            source: SourceInfo(
                organism: "Test organism",
                assembly: "TestAssembly",
                database: "Test"
            ),
            variants: [
                VariantTrackInfo(
                    id: "variants",
                    name: "BCF Variants",
                    path: "variants/test.bcf",
                    indexPath: "variants/test.bcf.csi",
                    variantCount: 1
                )
            ]
        )

        try manifest.save(to: bundleURL)
        return bundleURL
    }

    private func createSQLiteVariantBundle(writeDatabase: Bool = true) throws -> URL {
        let bundleURL = tempDirectory.appendingPathComponent("sqlite-variants-\(UUID().uuidString).lungfishref")
        try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)

        let variantsDir = bundleURL.appendingPathComponent("variants")
        try FileManager.default.createDirectory(at: variantsDir, withIntermediateDirectories: true)
        try Data([0x42, 0x43, 0x46]).write(to: variantsDir.appendingPathComponent("test.bcf"))
        try Data([0x43, 0x53, 0x49]).write(to: variantsDir.appendingPathComponent("test.bcf.csi"))

        if writeDatabase {
            let vcfURL = tempDirectory.appendingPathComponent("sqlite-variants-\(UUID().uuidString).vcf")
            let vcf = """
            ##fileformat=VCFv4.3
            #CHROM\tPOS\tID\tREF\tALT\tQUAL\tFILTER\tINFO
            chr1\t10\trs1\tA\tG\t50\tPASS\t.
            """
            try vcf.write(to: vcfURL, atomically: true, encoding: .utf8)
            let dbURL = variantsDir.appendingPathComponent("variants.db")
            try VariantDatabase.createFromVCF(vcfURL: vcfURL, outputURL: dbURL)
        }

        let manifest = BundleManifest(
            formatVersion: "1.0",
            name: "SQLite Variants",
            identifier: "test.sqlite-variants",
            source: SourceInfo(
                organism: "Test organism",
                assembly: "TestAssembly",
                database: "Test"
            ),
            variants: [
                VariantTrackInfo(
                    id: "variants",
                    name: "SQLite Variants",
                    path: "variants/test.bcf",
                    indexPath: "variants/test.bcf.csi",
                    databasePath: "variants/variants.db",
                    variantCount: 1
                )
            ]
        )

        try manifest.save(to: bundleURL)
        return bundleURL
    }

    private func createInvalidSQLiteVariantBundle() throws -> URL {
        let bundleURL = tempDirectory.appendingPathComponent("invalid-sqlite-variants.lungfishref")
        try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)

        let variantsDir = bundleURL.appendingPathComponent("variants")
        try FileManager.default.createDirectory(at: variantsDir, withIntermediateDirectories: true)
        try Data([0x42, 0x43, 0x46]).write(to: variantsDir.appendingPathComponent("test.bcf"))
        try Data([0x43, 0x53, 0x49]).write(to: variantsDir.appendingPathComponent("test.bcf.csi"))
        try Data("not a sqlite database".utf8).write(to: variantsDir.appendingPathComponent("variants.db"))

        let manifest = BundleManifest(
            formatVersion: "1.0",
            name: "Invalid SQLite Variants",
            identifier: "test.invalid-sqlite-variants",
            source: SourceInfo(
                organism: "Test organism",
                assembly: "TestAssembly",
                database: "Test"
            ),
            variants: [
                VariantTrackInfo(
                    id: "variants",
                    name: "Invalid SQLite Variants",
                    path: "variants/test.bcf",
                    indexPath: "variants/test.bcf.csi",
                    databasePath: "variants/variants.db",
                    variantCount: 1
                )
            ]
        )

        try manifest.save(to: bundleURL)
        return bundleURL
    }
}

private final class ReferenceBundleBookmarkAccessProbe: @unchecked Sendable {
    private struct State {
        var startedURLs: [URL] = []
        var stoppedURLs: [URL] = []
    }

    private let resolutions: [Data: URL]
    private let state = OSAllocatedUnfairLock(initialState: State())

    init(resolutions: [Data: URL]) {
        self.resolutions = resolutions
    }

    func resolve(_ data: Data) throws -> ReferenceBundleBookmarkResolution {
        guard let url = resolutions[data] else {
            throw CocoaError(.fileReadNoSuchFile)
        }
        return ReferenceBundleBookmarkResolution(url: url, isStale: false)
    }

    func startAccessing(_ url: URL) -> Bool {
        state.withLock { $0.startedURLs.append(url) }
        return true
    }

    func stopAccessing(_ url: URL) {
        state.withLock { $0.stoppedURLs.append(url) }
    }

    func startedURLs() -> [URL] {
        state.withLock { $0.startedURLs }
    }

    func stoppedURLs() -> [URL] {
        state.withLock { $0.stoppedURLs }
    }
}
