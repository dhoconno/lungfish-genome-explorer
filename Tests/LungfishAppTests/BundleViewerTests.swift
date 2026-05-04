// BundleViewerTests.swift - Tests for bundle viewer components
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
@testable import LungfishApp
@testable import LungfishCore
@testable import LungfishIO

// Disambiguate DocumentType: LungfishApp.DocumentType (file format type used by DocumentManager)
// vs LungfishCore.DocumentType (genomic document classification). We test the LungfishApp one.
private typealias AppDocumentType = LungfishApp.DocumentType

// MARK: - DocumentType Reference Bundle Tests

/// Tests for the `.lungfishReferenceBundle` case of `DocumentType` and related
/// directory-format detection logic.
@MainActor
final class DocumentTypeReferenceBundleTests: XCTestCase {

    // MARK: - Extension Tests

    func testLungfishReferenceBundleExtensions() {
        let extensions = AppDocumentType.lungfishReferenceBundle.extensions
        XCTAssertEqual(extensions, ["lungfishref"],
                       "lungfishReferenceBundle should have exactly one extension: 'lungfishref'")
    }

    func testLungfishReferenceBundleExtensionCount() {
        let extensions = AppDocumentType.lungfishReferenceBundle.extensions
        XCTAssertEqual(extensions.count, 1,
                       "lungfishReferenceBundle should have exactly 1 extension")
    }

    func testAlignmentAndTreeBundleExtensions() {
        XCTAssertEqual(AppDocumentType.lungfishMultipleSequenceAlignmentBundle.extensions, ["lungfishmsa"])
        XCTAssertEqual(AppDocumentType.lungfishPhylogeneticTreeBundle.extensions, ["lungfishtree"])
    }

    // MARK: - Detection Tests

    func testDetectLungfishRefFromURL() {
        let url = URL(fileURLWithPath: "/tmp/human_genome.lungfishref")
        let detected = AppDocumentType.detect(from: url)
        XCTAssertEqual(detected, .lungfishReferenceBundle,
                       "Should detect .lungfishReferenceBundle from .lungfishref extension")
    }

    func testDetectLungfishRefCaseInsensitive() {
        let url = URL(fileURLWithPath: "/tmp/genome.LUNGFISHREF")
        let detected = AppDocumentType.detect(from: url)
        XCTAssertEqual(detected, .lungfishReferenceBundle,
                       "Detection should be case-insensitive for .lungfishref")
    }

    func testDetectLungfishRefMixedCase() {
        let url = URL(fileURLWithPath: "/tmp/genome.LungfishRef")
        let detected = AppDocumentType.detect(from: url)
        XCTAssertEqual(detected, .lungfishReferenceBundle,
                       "Detection should be case-insensitive for mixed-case .LungfishRef")
    }

    func testDetectLungfishRefWithNestedPath() {
        let url = URL(fileURLWithPath: "/Users/lab/references/hg38/GRCh38.lungfishref")
        let detected = AppDocumentType.detect(from: url)
        XCTAssertEqual(detected, .lungfishReferenceBundle,
                       "Should detect .lungfishReferenceBundle regardless of directory depth")
    }

    func testDetectLungfishRefWithSpacesInPath() {
        let url = URL(fileURLWithPath: "/Users/lab/My Genomes/Human Genome.lungfishref")
        let detected = AppDocumentType.detect(from: url)
        XCTAssertEqual(detected, .lungfishReferenceBundle,
                       "Should detect .lungfishReferenceBundle even with spaces in path")
    }

    func testDetectAlignmentAndTreeBundles() {
        XCTAssertEqual(
            AppDocumentType.detect(from: URL(fileURLWithPath: "/Users/lab/My Alignments/MHC.lungfishmsa")),
            .lungfishMultipleSequenceAlignmentBundle
        )
        XCTAssertEqual(
            AppDocumentType.detect(from: URL(fileURLWithPath: "/Users/lab/My Trees/MHC.lungfishtree")),
            .lungfishPhylogeneticTreeBundle
        )
    }

    func testDetectLungfishRefGzippedReturnsNil() {
        // .lungfishref.gz does not make sense (it is a directory format), so gzip
        // stripping should reveal "lungfishref" but the detection should still work
        let url = URL(fileURLWithPath: "/tmp/genome.lungfishref.gz")
        let detected = AppDocumentType.detect(from: url)
        // After stripping .gz, the extension becomes "lungfishref" which maps to the bundle type
        XCTAssertEqual(detected, .lungfishReferenceBundle,
                       "Stripping .gz from .lungfishref.gz should still detect the bundle type")
    }

    // MARK: - isDirectoryFormat Tests

    func testLungfishReferenceBundleIsDirectoryFormat() {
        XCTAssertTrue(AppDocumentType.lungfishReferenceBundle.isDirectoryFormat,
                      ".lungfishReferenceBundle should be a directory format")
    }

    func testLungfishProjectIsDirectoryFormat() {
        XCTAssertTrue(AppDocumentType.lungfishProject.isDirectoryFormat,
                      ".lungfishProject should be a directory format")
    }

    func testAlignmentAndTreeBundlesAreDirectoryFormats() {
        XCTAssertTrue(AppDocumentType.lungfishMultipleSequenceAlignmentBundle.isDirectoryFormat)
        XCTAssertTrue(AppDocumentType.lungfishPhylogeneticTreeBundle.isDirectoryFormat)
    }

    func testFastaIsNotDirectoryFormat() {
        XCTAssertFalse(AppDocumentType.fasta.isDirectoryFormat,
                       ".fasta should NOT be a directory format")
    }

    func testFastqIsNotDirectoryFormat() {
        XCTAssertFalse(AppDocumentType.fastq.isDirectoryFormat,
                       ".fastq should NOT be a directory format")
    }

    func testGenbankIsNotDirectoryFormat() {
        XCTAssertFalse(AppDocumentType.genbank.isDirectoryFormat,
                       ".genbank should NOT be a directory format")
    }

    func testGff3IsNotDirectoryFormat() {
        XCTAssertFalse(AppDocumentType.gff3.isDirectoryFormat,
                       ".gff3 should NOT be a directory format")
    }

    func testBedIsNotDirectoryFormat() {
        XCTAssertFalse(AppDocumentType.bed.isDirectoryFormat,
                       ".bed should NOT be a directory format")
    }

    func testVcfIsNotDirectoryFormat() {
        XCTAssertFalse(AppDocumentType.vcf.isDirectoryFormat,
                       ".vcf should NOT be a directory format")
    }

    func testBamIsNotDirectoryFormat() {
        XCTAssertFalse(AppDocumentType.bam.isDirectoryFormat,
                       ".bam should NOT be a directory format")
    }

    func testOnlyNativeBundlesAreDirectoryFormats() {
        let directoryTypes = AppDocumentType.allCases.filter { $0.isDirectoryFormat }
        XCTAssertEqual(directoryTypes.count, 4,
                       "Exactly four types should be directory formats: project, reference, MSA, and tree bundles")
        XCTAssertTrue(directoryTypes.contains(.lungfishProject))
        XCTAssertTrue(directoryTypes.contains(.lungfishReferenceBundle))
        XCTAssertTrue(directoryTypes.contains(.lungfishMultipleSequenceAlignmentBundle))
        XCTAssertTrue(directoryTypes.contains(.lungfishPhylogeneticTreeBundle))
    }

    // MARK: - Raw Value Tests

    func testLungfishReferenceBundleRawValue() {
        XCTAssertEqual(AppDocumentType.lungfishReferenceBundle.rawValue, "lungfishReferenceBundle",
                       "Raw value should match the Swift enum case name")
    }

    func testLungfishReferenceBundleFromRawValue() {
        let type = AppDocumentType(rawValue: "lungfishReferenceBundle")
        XCTAssertEqual(type, .lungfishReferenceBundle,
                       "Should reconstruct .lungfishReferenceBundle from its raw value")
    }

    // MARK: - Supported Extensions Inclusion

    func testSupportedExtensionsIncludesLungfishref() {
        let supported = DocumentManager.supportedExtensions
        XCTAssertTrue(supported.contains("lungfishref"),
                      "supportedExtensions should include 'lungfishref'")
        XCTAssertTrue(supported.contains("lungfishmsa"),
                      "supportedExtensions should include 'lungfishmsa'")
        XCTAssertTrue(supported.contains("lungfishtree"),
                      "supportedExtensions should include 'lungfishtree'")
    }

    // MARK: - Extension Uniqueness

    func testLungfishrefExtensionIsUnique() {
        // Verify "lungfishref" is not shared with any other DocumentType
        let typesWithLungfishref = AppDocumentType.allCases.filter { $0.extensions.contains("lungfishref") }
        XCTAssertEqual(typesWithLungfishref.count, 1,
                       "'lungfishref' extension should belong to exactly one DocumentType")
        XCTAssertEqual(typesWithLungfishref.first, .lungfishReferenceBundle)
    }
}

// MARK: - ChromosomeInfo Tests

/// Tests for the `ChromosomeInfo` model from `LungfishCore`.
///
/// Verifies struct initialization, `Identifiable` conformance, `Equatable` conformance,
/// `Codable` round-trip, and default parameter behavior.
final class ChromosomeInfoTests: XCTestCase {

    // MARK: - Test Helpers

    /// Creates a standard chromosome info for testing.
    private func makeChromosome(
        name: String = "chr1",
        length: Int64 = 248_956_422,
        offset: Int64 = 0,
        lineBases: Int = 80,
        lineWidth: Int = 81,
        aliases: [String] = ["1"],
        isPrimary: Bool = true,
        isMitochondrial: Bool = false
    ) -> ChromosomeInfo {
        ChromosomeInfo(
            name: name,
            length: length,
            offset: offset,
            lineBases: lineBases,
            lineWidth: lineWidth,
            aliases: aliases,
            isPrimary: isPrimary,
            isMitochondrial: isMitochondrial
        )
    }

    // MARK: - Initialization Tests

    func testChromosomeInfoProperties() {
        let chrom = makeChromosome()
        XCTAssertEqual(chrom.name, "chr1")
        XCTAssertEqual(chrom.length, 248_956_422)
        XCTAssertEqual(chrom.offset, 0)
        XCTAssertEqual(chrom.lineBases, 80)
        XCTAssertEqual(chrom.lineWidth, 81)
        XCTAssertEqual(chrom.aliases, ["1"])
        XCTAssertTrue(chrom.isPrimary)
        XCTAssertFalse(chrom.isMitochondrial)
    }

    func testChromosomeInfoDefaultParameters() {
        // Only required params
        let chrom = ChromosomeInfo(
            name: "scaffold_42",
            length: 5000,
            offset: 1024,
            lineBases: 60,
            lineWidth: 61
        )
        XCTAssertEqual(chrom.aliases, [],
                       "Default aliases should be an empty array")
        XCTAssertTrue(chrom.isPrimary,
                      "Default isPrimary should be true")
        XCTAssertFalse(chrom.isMitochondrial,
                       "Default isMitochondrial should be false")
    }

    func testMitochondrialChromosome() {
        let mt = makeChromosome(
            name: "chrM",
            length: 16_569,
            offset: 3_088_286_401,
            aliases: ["MT"],
            isPrimary: false,
            isMitochondrial: true
        )
        XCTAssertTrue(mt.isMitochondrial)
        XCTAssertFalse(mt.isPrimary)
        XCTAssertEqual(mt.aliases, ["MT"])
    }

    // MARK: - Identifiable Conformance

    func testIdentifiableIdIsName() {
        let chrom = makeChromosome(name: "chr17")
        XCTAssertEqual(chrom.id, "chr17",
                       "ChromosomeInfo.id should equal its name")
    }

    func testIdentifiableDistinctIds() {
        let chr1 = makeChromosome(name: "chr1")
        let chr2 = makeChromosome(name: "chr2")
        XCTAssertNotEqual(chr1.id, chr2.id,
                          "Different chromosomes should have different IDs")
    }

    // MARK: - Equatable Conformance

    func testChromosomeInfoEquality() {
        let a = makeChromosome(name: "chr1", length: 1000, offset: 0, lineBases: 80, lineWidth: 81)
        let b = makeChromosome(name: "chr1", length: 1000, offset: 0, lineBases: 80, lineWidth: 81)
        XCTAssertEqual(a, b, "Chromosomes with identical properties should be equal")
    }

    func testChromosomeInfoInequalityByName() {
        let a = makeChromosome(name: "chr1")
        let b = makeChromosome(name: "chr2")
        XCTAssertNotEqual(a, b, "Chromosomes with different names should not be equal")
    }

    func testChromosomeInfoInequalityByLength() {
        let a = makeChromosome(name: "chr1", length: 1000)
        let b = makeChromosome(name: "chr1", length: 2000)
        XCTAssertNotEqual(a, b, "Chromosomes with different lengths should not be equal")
    }

    func testChromosomeInfoInequalityByOffset() {
        let a = makeChromosome(name: "chr1", offset: 0)
        let b = makeChromosome(name: "chr1", offset: 100)
        XCTAssertNotEqual(a, b, "Chromosomes with different offsets should not be equal")
    }

    func testChromosomeInfoInequalityByIsPrimary() {
        let a = makeChromosome(name: "chr1", isPrimary: true)
        let b = makeChromosome(name: "chr1", isPrimary: false)
        XCTAssertNotEqual(a, b, "Chromosomes with different isPrimary should not be equal")
    }

    // MARK: - Codable Round-Trip

    func testChromosomeInfoCodableRoundTrip() throws {
        let original = makeChromosome(
            name: "chrX",
            length: 156_040_895,
            offset: 2_881_033_287,
            lineBases: 80,
            lineWidth: 81,
            aliases: ["X", "23"],
            isPrimary: true,
            isMitochondrial: false
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let data = try encoder.encode(original)

        let decoder = JSONDecoder()
        let decoded = try decoder.decode(ChromosomeInfo.self, from: data)

        XCTAssertEqual(decoded, original,
                       "ChromosomeInfo should survive a JSON encode/decode round-trip")
    }

    func testChromosomeInfoCodingKeys() throws {
        let chrom = ChromosomeInfo(
            name: "chr1",
            length: 1000,
            offset: 0,
            lineBases: 80,
            lineWidth: 81,
            aliases: ["1"],
            isPrimary: true,
            isMitochondrial: false
        )

        let encoder = JSONEncoder()
        let data = try encoder.encode(chrom)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])

        // Verify snake_case coding keys
        XCTAssertNotNil(json["line_bases"], "Should encode lineBases as 'line_bases'")
        XCTAssertNotNil(json["line_width"], "Should encode lineWidth as 'line_width'")
        XCTAssertNotNil(json["is_primary"], "Should encode isPrimary as 'is_primary'")
        XCTAssertNotNil(json["is_mitochondrial"], "Should encode isMitochondrial as 'is_mitochondrial'")

        // Verify camelCase keys are NOT present
        XCTAssertNil(json["lineBases"], "Should not use camelCase 'lineBases' in JSON")
        XCTAssertNil(json["lineWidth"], "Should not use camelCase 'lineWidth' in JSON")
        XCTAssertNil(json["isPrimary"], "Should not use camelCase 'isPrimary' in JSON")
        XCTAssertNil(json["isMitochondrial"], "Should not use camelCase 'isMitochondrial' in JSON")
    }

    func testChromosomeInfoDecodingFromJSON() throws {
        let json = """
        {
            "name": "chrY",
            "length": 57227415,
            "offset": 3044246822,
            "line_bases": 80,
            "line_width": 81,
            "aliases": ["Y"],
            "is_primary": true,
            "is_mitochondrial": false
        }
        """
        let data = Data(json.utf8)
        let chrom = try JSONDecoder().decode(ChromosomeInfo.self, from: data)

        XCTAssertEqual(chrom.name, "chrY")
        XCTAssertEqual(chrom.length, 57_227_415)
        XCTAssertEqual(chrom.offset, 3_044_246_822)
        XCTAssertEqual(chrom.lineBases, 80)
        XCTAssertEqual(chrom.lineWidth, 81)
        XCTAssertEqual(chrom.aliases, ["Y"])
        XCTAssertTrue(chrom.isPrimary)
        XCTAssertFalse(chrom.isMitochondrial)
    }

    // MARK: - Edge Cases

    func testChromosomeInfoZeroLength() {
        let chrom = makeChromosome(name: "empty", length: 0)
        XCTAssertEqual(chrom.length, 0)
    }

    func testChromosomeInfoVeryLargeLength() {
        // Lungfish (Neoceratodus forsteri) has the largest known genome at ~43 Gb
        let length: Int64 = 43_000_000_000
        let chrom = makeChromosome(name: "chr1", length: length)
        XCTAssertEqual(chrom.length, length,
                       "Int64 should accommodate very large genome sizes")
    }

    func testChromosomeInfoEmptyAliases() {
        let chrom = makeChromosome(aliases: [])
        XCTAssertTrue(chrom.aliases.isEmpty)
    }

    func testChromosomeInfoMultipleAliases() {
        let chrom = makeChromosome(name: "chr1", aliases: ["1", "NC_000001.11", "CM000663.2"])
        XCTAssertEqual(chrom.aliases.count, 3)
        XCTAssertTrue(chrom.aliases.contains("1"))
        XCTAssertTrue(chrom.aliases.contains("NC_000001.11"))
        XCTAssertTrue(chrom.aliases.contains("CM000663.2"))
    }
}

// MARK: - BundleManifest Tests

/// Tests for `BundleManifest` construction, validation, and I/O.
final class BundleManifestTests: XCTestCase {

    // MARK: - Test Helpers

    private var tempDir: URL!

    override func setUp() async throws {
        try await super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("BundleManifestTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        if let tempDir = tempDir {
            try? FileManager.default.removeItem(at: tempDir)
        }
        tempDir = nil
        try await super.tearDown()
    }

    /// Creates a minimal valid manifest for testing.
    private func makeManifest(
        name: String = "Test Genome",
        identifier: String = "org.lungfish.test",
        chromosomes: [ChromosomeInfo]? = nil,
        annotations: [AnnotationTrackInfo] = []
    ) -> BundleManifest {
        let chroms = chromosomes ?? [
            ChromosomeInfo(name: "chr1", length: 248_956_422, offset: 0, lineBases: 80, lineWidth: 81),
            ChromosomeInfo(name: "chr2", length: 242_193_529, offset: 248_960_000, lineBases: 80, lineWidth: 81),
        ]
        return BundleManifest(
            name: name,
            identifier: identifier,
            source: SourceInfo(organism: "Homo sapiens", assembly: "GRCh38"),
            genome: GenomeInfo(
                path: "genome/sequence.fa.gz",
                indexPath: "genome/sequence.fa.gz.fai",
                totalLength: chroms.reduce(0) { $0 + $1.length },
                chromosomes: chroms
            ),
            annotations: annotations
        )
    }

    // MARK: - Construction Tests

    func testManifestConstruction() {
        let manifest = makeManifest()
        XCTAssertEqual(manifest.name, "Test Genome")
        XCTAssertEqual(manifest.identifier, "org.lungfish.test")
        XCTAssertEqual(manifest.formatVersion, "1.0")
        XCTAssertEqual(manifest.source.organism, "Homo sapiens")
        XCTAssertEqual(manifest.source.assembly, "GRCh38")
        XCTAssertEqual(manifest.genome!.chromosomes.count, 2)
        XCTAssertEqual(manifest.genome!.path, "genome/sequence.fa.gz")
        XCTAssertEqual(manifest.genome!.indexPath, "genome/sequence.fa.gz.fai")
    }

    func testManifestDefaultAnnotationsEmpty() {
        let manifest = makeManifest()
        XCTAssertTrue(manifest.annotations.isEmpty,
                      "Default annotations should be empty")
        XCTAssertTrue(manifest.variants.isEmpty,
                      "Default variants should be empty")
        XCTAssertTrue(manifest.tracks.isEmpty,
                      "Default tracks should be empty")
    }

    func testManifestWithAnnotations() {
        let annotations = [
            AnnotationTrackInfo(
                id: "genes",
                name: "Gene Annotations",
                path: "annotations/genes.bb"
            ),
            AnnotationTrackInfo(
                id: "transcripts",
                name: "Transcript Annotations",
                path: "annotations/transcripts.bb",
                annotationType: .transcript
            ),
        ]
        let manifest = makeManifest(annotations: annotations)
        XCTAssertEqual(manifest.annotations.count, 2)
        XCTAssertEqual(manifest.annotations[0].id, "genes")
        XCTAssertEqual(manifest.annotations[1].annotationType, .transcript)
    }

    // MARK: - Validation Tests

    func testValidManifestPassesValidation() {
        let manifest = makeManifest()
        let errors = manifest.validate()
        XCTAssertTrue(errors.isEmpty,
                      "A valid manifest should produce no validation errors, got: \(errors)")
    }

    func testManifestValidationFailsOnEmptyName() {
        let manifest = makeManifest(name: "")
        let errors = manifest.validate()
        let hasNameError = errors.contains { error in
            if case .missingField(let field) = error {
                return field == "name"
            }
            return false
        }
        XCTAssertTrue(hasNameError, "Should report missing 'name' field")
    }

    func testManifestValidationFailsOnEmptyIdentifier() {
        let manifest = makeManifest(identifier: "")
        let errors = manifest.validate()
        let hasIdentifierError = errors.contains { error in
            if case .missingField(let field) = error {
                return field == "identifier"
            }
            return false
        }
        XCTAssertTrue(hasIdentifierError, "Should report missing 'identifier' field")
    }

    func testManifestValidationFailsOnNoChromosomes() {
        let manifest = makeManifest(chromosomes: [])
        let errors = manifest.validate()
        let hasChromError = errors.contains { error in
            if case .missingField(let field) = error {
                return field == "genome.chromosomes"
            }
            return false
        }
        XCTAssertTrue(hasChromError, "Should report missing 'genome.chromosomes' field")
    }

    func testManifestValidationDetectsDuplicateTrackIds() {
        let annotations = [
            AnnotationTrackInfo(id: "genes", name: "Genes", path: "annotations/genes.bb"),
            AnnotationTrackInfo(id: "genes", name: "Genes Duplicate", path: "annotations/genes2.bb"),
        ]
        let manifest = makeManifest(annotations: annotations)
        let errors = manifest.validate()
        let hasDuplicateError = errors.contains { error in
            if case .duplicateTrackId(let id) = error {
                return id == "genes"
            }
            return false
        }
        XCTAssertTrue(hasDuplicateError, "Should detect duplicate track ID 'genes'")
    }

    func testManifestValidationMultipleErrors() {
        let manifest = makeManifest(name: "", identifier: "", chromosomes: [])
        let errors = manifest.validate()
        XCTAssertGreaterThanOrEqual(errors.count, 3,
                                    "Should report at least 3 errors: name, identifier, chromosomes")
    }

    // MARK: - I/O Round-Trip Tests

    func testManifestSaveAndLoad() throws {
        let original = makeManifest()

        // Save
        try original.save(to: tempDir)

        // Load
        let loaded = try BundleManifest.load(from: tempDir)

        XCTAssertEqual(loaded.name, original.name)
        XCTAssertEqual(loaded.identifier, original.identifier)
        XCTAssertEqual(loaded.formatVersion, original.formatVersion)
        XCTAssertEqual(loaded.genome!.chromosomes.count, original.genome!.chromosomes.count)
        XCTAssertEqual(loaded.genome!.path, original.genome!.path)
        XCTAssertEqual(loaded.source.organism, original.source.organism)
    }

    func testManifestFilename() {
        XCTAssertEqual(BundleManifest.filename, "manifest.json",
                       "Manifest filename should be 'manifest.json'")
    }

    func testManifestLoadFromMissingDirectoryThrows() {
        let missingDir = tempDir.appendingPathComponent("does_not_exist")
        XCTAssertThrowsError(try BundleManifest.load(from: missingDir),
                             "Loading from a missing directory should throw")
    }

    func testManifestLoadFromEmptyDirectoryThrows() throws {
        let emptyDir = tempDir.appendingPathComponent("empty_bundle")
        try FileManager.default.createDirectory(at: emptyDir, withIntermediateDirectories: true)

        XCTAssertThrowsError(try BundleManifest.load(from: emptyDir),
                             "Loading from a directory without manifest.json should throw")
    }

    func testManifestLoadFromInvalidJSONThrows() throws {
        let manifestURL = tempDir.appendingPathComponent("manifest.json")
        try "{ invalid json }".write(to: manifestURL, atomically: true, encoding: .utf8)

        XCTAssertThrowsError(try BundleManifest.load(from: tempDir),
                             "Loading a malformed manifest.json should throw")
    }

    // MARK: - Equatable Tests

    func testManifestEquality() {
        let a = makeManifest(name: "Genome A", identifier: "org.test.a")
        let b = makeManifest(name: "Genome A", identifier: "org.test.a")
        // Note: createdDate/modifiedDate use Date() which differs between calls,
        // so these two manifests will NOT be equal. This is expected behavior.
        // Equatable compares all fields including dates.
        XCTAssertNotEqual(a, b,
                          "Manifests with different creation dates should not be equal")
    }

    func testManifestEqualityWithSameDates() {
        let fixedDate = Date(timeIntervalSince1970: 1_700_000_000)
        let chroms = [ChromosomeInfo(name: "chr1", length: 1000, offset: 0, lineBases: 80, lineWidth: 81)]
        let a = BundleManifest(
            name: "Test",
            identifier: "org.test",
            createdDate: fixedDate,
            modifiedDate: fixedDate,
            source: SourceInfo(organism: "Test", assembly: "v1"),
            genome: GenomeInfo(path: "g.fa", indexPath: "g.fa.fai", totalLength: 1000, chromosomes: chroms)
        )
        let b = BundleManifest(
            name: "Test",
            identifier: "org.test",
            createdDate: fixedDate,
            modifiedDate: fixedDate,
            source: SourceInfo(organism: "Test", assembly: "v1"),
            genome: GenomeInfo(path: "g.fa", indexPath: "g.fa.fai", totalLength: 1000, chromosomes: chroms)
        )
        XCTAssertEqual(a, b,
                       "Manifests with identical fields (including dates) should be equal")
    }
}

// MARK: - BundleValidationError Tests

/// Tests for `BundleValidationError` descriptions and conformance.
final class BundleValidationErrorTests: XCTestCase {

    func testMissingFieldErrorDescription() {
        let error = BundleValidationError.missingField("genome.path")
        let description = error.errorDescription
        XCTAssertNotNil(description)
        XCTAssertTrue(description!.contains("genome.path"),
                      "Error should mention the missing field name. Got: \(description!)")
    }

    func testDuplicateTrackIdErrorDescription() {
        let error = BundleValidationError.duplicateTrackId("genes")
        let description = error.errorDescription
        XCTAssertNotNil(description)
        XCTAssertTrue(description!.contains("genes"),
                      "Error should mention the duplicate track ID. Got: \(description!)")
    }

    func testFileNotFoundErrorDescription() {
        let error = BundleValidationError.fileNotFound("annotations/genes.bb")
        let description = error.errorDescription
        XCTAssertNotNil(description)
        XCTAssertTrue(description!.contains("annotations/genes.bb"),
                      "Error should mention the missing file path. Got: \(description!)")
    }

    func testInvalidFileFormatErrorDescription() {
        let error = BundleValidationError.invalidFileFormat("genes.txt", "BigBed")
        let description = error.errorDescription
        XCTAssertNotNil(description)
        XCTAssertTrue(description!.contains("genes.txt"),
                      "Error should mention the file path. Got: \(description!)")
        XCTAssertTrue(description!.contains("BigBed"),
                      "Error should mention the expected format. Got: \(description!)")
    }

    func testAllValidationErrorsConformToLocalizedError() {
        let errors: [BundleValidationError] = [
            .missingField("name"),
            .duplicateTrackId("track1"),
            .fileNotFound("missing.bb"),
            .invalidFileFormat("bad.txt", "BigBed"),
        ]
        for error in errors {
            let localized = error.localizedDescription
            XCTAssertFalse(localized.isEmpty,
                           "localizedDescription should not be empty for \(error)")
        }
    }
}

// MARK: - BundleDataProvider Tests

/// Tests for `BundleDataProvider` computed properties and chromosome lookup logic.
///
/// These tests exercise the provider's non-I/O API (properties that delegate to
/// the manifest) without requiring actual genome files on disk.
@MainActor
final class BundleDataProviderTests: XCTestCase {

    // MARK: - Test Helpers

    private func makeManifest(
        name: String = "Test Genome",
        organism: String = "Homo sapiens",
        assembly: String = "GRCh38",
        chromosomes: [ChromosomeInfo]? = nil,
        annotations: [AnnotationTrackInfo] = []
    ) -> BundleManifest {
        let chroms = chromosomes ?? [
            ChromosomeInfo(name: "chr1", length: 248_956_422, offset: 0, lineBases: 80, lineWidth: 81, aliases: ["1"]),
            ChromosomeInfo(name: "chr2", length: 242_193_529, offset: 248_960_000, lineBases: 80, lineWidth: 81, aliases: ["2"]),
            ChromosomeInfo(name: "chrX", length: 156_040_895, offset: 491_160_000, lineBases: 80, lineWidth: 81, aliases: ["X", "23"]),
            ChromosomeInfo(name: "chrM", length: 16_569, offset: 647_200_000, lineBases: 80, lineWidth: 81, aliases: ["MT"], isPrimary: false, isMitochondrial: true),
        ]
        return BundleManifest(
            name: name,
            identifier: "org.lungfish.test",
            source: SourceInfo(organism: organism, assembly: assembly),
            genome: GenomeInfo(
                path: "genome/sequence.fa.gz",
                indexPath: "genome/sequence.fa.gz.fai",
                totalLength: chroms.reduce(0) { $0 + $1.length },
                chromosomes: chroms
            ),
            annotations: annotations
        )
    }

    private func makeProvider(
        manifest: BundleManifest? = nil
    ) -> BundleDataProvider {
        let m = manifest ?? makeManifest()
        let dummyURL = URL(fileURLWithPath: "/tmp/test.lungfishref")
        return BundleDataProvider(bundleURL: dummyURL, manifest: m)
    }

    // MARK: - Property Tests

    func testProviderName() {
        let provider = makeProvider(manifest: makeManifest(name: "Human Reference"))
        XCTAssertEqual(provider.name, "Human Reference")
    }

    func testProviderOrganism() {
        let provider = makeProvider(manifest: makeManifest(organism: "Mus musculus"))
        XCTAssertEqual(provider.organism, "Mus musculus")
    }

    func testProviderAssembly() {
        let provider = makeProvider(manifest: makeManifest(assembly: "GRCm39"))
        XCTAssertEqual(provider.assembly, "GRCm39")
    }

    func testProviderChromosomes() {
        let provider = makeProvider()
        XCTAssertEqual(provider.chromosomes.count, 4)
        XCTAssertEqual(provider.chromosomes[0].name, "chr1")
        XCTAssertEqual(provider.chromosomes[1].name, "chr2")
        XCTAssertEqual(provider.chromosomes[2].name, "chrX")
        XCTAssertEqual(provider.chromosomes[3].name, "chrM")
    }

    func testProviderAnnotationTrackIds() {
        let annotations = [
            AnnotationTrackInfo(id: "genes", name: "Genes", path: "annotations/genes.bb"),
            AnnotationTrackInfo(id: "transcripts", name: "Transcripts", path: "annotations/transcripts.bb"),
        ]
        let provider = makeProvider(manifest: makeManifest(annotations: annotations))
        XCTAssertEqual(provider.annotationTrackIds, ["genes", "transcripts"])
    }

    func testProviderAnnotationTrackIdsEmpty() {
        let provider = makeProvider(manifest: makeManifest(annotations: []))
        XCTAssertTrue(provider.annotationTrackIds.isEmpty,
                      "Provider with no annotation tracks should have empty track IDs")
    }

    // MARK: - Chromosome Lookup Tests

    func testChromosomeInfoByName() {
        let provider = makeProvider()
        let info = provider.chromosomeInfo(named: "chr1")
        XCTAssertNotNil(info)
        XCTAssertEqual(info?.name, "chr1")
        XCTAssertEqual(info?.length, 248_956_422)
    }

    func testChromosomeInfoByAlias() {
        let provider = makeProvider()
        let info = provider.chromosomeInfo(named: "1")
        XCTAssertNotNil(info, "Should find chromosome by alias '1'")
        XCTAssertEqual(info?.name, "chr1")
    }

    func testChromosomeInfoBySecondAlias() {
        let provider = makeProvider()
        let info = provider.chromosomeInfo(named: "23")
        XCTAssertNotNil(info, "Should find chrX by alias '23'")
        XCTAssertEqual(info?.name, "chrX")
    }

    func testChromosomeInfoByMitochondrialAlias() {
        let provider = makeProvider()
        let info = provider.chromosomeInfo(named: "MT")
        XCTAssertNotNil(info, "Should find chrM by alias 'MT'")
        XCTAssertEqual(info?.name, "chrM")
        XCTAssertTrue(info?.isMitochondrial ?? false)
    }

    func testChromosomeInfoNotFound() {
        let provider = makeProvider()
        let info = provider.chromosomeInfo(named: "chrZ")
        XCTAssertNil(info, "Should return nil for unknown chromosome name")
    }

    func testChromosomeInfoCaseSensitive() {
        let provider = makeProvider()
        // ChromosomeInfo lookup is case-sensitive by default
        let info = provider.chromosomeInfo(named: "CHR1")
        XCTAssertNil(info, "Chromosome lookup should be case-sensitive")
    }
}

// MARK: - LoadedDocument Bundle Tests

/// Tests for `LoadedDocument` when used with the `.lungfishReferenceBundle` type.
@MainActor
final class LoadedDocumentBundleTests: XCTestCase {

    func testLoadedDocumentBundleTypeProperties() {
        let url = URL(fileURLWithPath: "/tmp/genome.lungfishref")
        let document = LoadedDocument(url: url, type: .lungfishReferenceBundle)

        XCTAssertEqual(document.type, .lungfishReferenceBundle)
        XCTAssertEqual(document.name, "genome.lungfishref")
        XCTAssertEqual(document.url, url)
        XCTAssertTrue(document.sequences.isEmpty)
        XCTAssertTrue(document.annotations.isEmpty)
        XCTAssertNil(document.bundleManifest,
                     "Bundle manifest should be nil until explicitly set")
    }

    func testLoadedDocumentBundleManifestAssignment() {
        let url = URL(fileURLWithPath: "/tmp/genome.lungfishref")
        let document = LoadedDocument(url: url, type: .lungfishReferenceBundle)

        let manifest = BundleManifest(
            name: "Test",
            identifier: "org.test",
            source: SourceInfo(organism: "Test", assembly: "v1"),
            genome: GenomeInfo(
                path: "genome/seq.fa.gz",
                indexPath: "genome/seq.fa.gz.fai",
                totalLength: 1000,
                chromosomes: [
                    ChromosomeInfo(name: "chr1", length: 1000, offset: 0, lineBases: 80, lineWidth: 81)
                ]
            )
        )

        document.bundleManifest = manifest
        XCTAssertNotNil(document.bundleManifest)
        XCTAssertEqual(document.bundleManifest?.name, "Test")
        XCTAssertEqual(document.bundleManifest?.genome!.chromosomes.count, 1)
    }

    func testLoadedDocumentBundleManifestCanBeCleared() {
        let url = URL(fileURLWithPath: "/tmp/genome.lungfishref")
        let document = LoadedDocument(url: url, type: .lungfishReferenceBundle)

        let manifest = BundleManifest(
            name: "Temporary",
            identifier: "org.test",
            source: SourceInfo(organism: "Test", assembly: "v1"),
            genome: GenomeInfo(
                path: "g.fa.gz",
                indexPath: "g.fa.gz.fai",
                totalLength: 500,
                chromosomes: [
                    ChromosomeInfo(name: "chr1", length: 500, offset: 0, lineBases: 80, lineWidth: 81)
                ]
            )
        )

        document.bundleManifest = manifest
        XCTAssertNotNil(document.bundleManifest)

        document.bundleManifest = nil
        XCTAssertNil(document.bundleManifest,
                     "Bundle manifest should be clearable by setting to nil")
    }

    func testLoadedDocumentBundleTypeIsDirectoryFormat() {
        XCTAssertTrue(AppDocumentType.lungfishReferenceBundle.isDirectoryFormat,
                      "The document type for a bundle document should be a directory format")
    }
}

// MARK: - Viewer Bundle Routing Tests

@MainActor
final class ViewerBundleRoutingTests: XCTestCase {
    nonisolated(unsafe) private var tempDir: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("bundle_viewer_routing_tests_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let tempDir {
            try? FileManager.default.removeItem(at: tempDir)
        }
        tempDir = nil
        try super.tearDownWithError()
    }

    func testDisplayBundleDefaultOverloadUsesReferenceViewport() throws {
        let vc = ViewerViewController()
        _ = vc.view
        let bundleURL = try makeReferenceBundle(chromosomes: ["chr1", "chr2"])

        try vc.displayBundle(at: bundleURL)

        let controller = try XCTUnwrap(vc.referenceBundleViewportController)
        XCTAssertEqual(controller.currentInput?.kind, .directBundle)
        XCTAssertEqual(controller.currentInput?.renderedBundleURL, bundleURL.standardizedFileURL)
        XCTAssertNil(vc.chromosomeNavigatorView)
        XCTAssertNil(vc.referenceFrame)
    }

    func testDisplayBundleBrowseModeUsesReferenceViewportWithoutChromosomeNavigatorOrReferenceFrame() throws {
        let vc = ViewerViewController()
        _ = vc.view
        let bundleURL = try makeReferenceBundle(chromosomes: ["chr1", "chr2"])

        try vc.displayBundle(at: bundleURL, mode: .browse)

        XCTAssertNil(vc.chromosomeNavigatorView)
        XCTAssertNil(vc.referenceFrame)
        XCTAssertNotNil(vc.referenceBundleViewportController)
    }

    func testSingleSequenceBundleStillOpensInReferenceViewportMode() throws {
        let vc = ViewerViewController()
        _ = vc.view
        let bundleURL = try makeReferenceBundle(chromosomes: ["chr1"])

        try vc.displayBundle(at: bundleURL, mode: .browse)

        XCTAssertNil(vc.chromosomeNavigatorView)
        XCTAssertNil(vc.referenceFrame)
        XCTAssertEqual(vc.referenceBundleViewportController?.testSelectedSequenceName, "chr1")
    }

    func testBrowseModeEmbedsSequenceDetailViewerForSelectedRow() throws {
        let vc = ViewerViewController()
        _ = vc.view
        let bundleURL = try makeReferenceBundle(chromosomes: ["chr1", "chr2"])

        try vc.displayBundle(at: bundleURL, mode: .browse)

        let viewport = try XCTUnwrap(vc.referenceBundleViewportController)
        let embeddedViewer = try XCTUnwrap(viewport.children.compactMap { $0 as? ViewerViewController }.first)

        XCTAssertEqual(viewport.testSelectedSequenceName, "chr1")
        XCTAssertEqual(embeddedViewer.referenceFrame?.chromosome, "chr1")
        XCTAssertNil(embeddedViewer.chromosomeNavigatorView)
        XCTAssertNil(embeddedViewer.referenceBundleViewportController)
    }

    func testBrowseModeSelectionUpdatesEmbeddedSequenceDetailViewer() throws {
        let vc = ViewerViewController()
        _ = vc.view
        let bundleURL = try makeReferenceBundle(chromosomes: ["chr1", "chr2"])

        try vc.displayBundle(at: bundleURL, mode: .browse)
        let viewport = try XCTUnwrap(vc.referenceBundleViewportController)
        let embeddedViewer = try XCTUnwrap(viewport.children.compactMap { $0 as? ViewerViewController }.first)

        viewport.testSelectSequence(named: "chr2")

        XCTAssertEqual(viewport.testSelectedSequenceName, "chr2")
        XCTAssertEqual(embeddedViewer.referenceFrame?.chromosome, "chr2")
    }

    func testReferenceBundleViewportExposesEmbeddedUserSelectionForAnnotationAuthoring() throws {
        let vc = ViewerViewController()
        _ = vc.view
        let bundleURL = try makeReferenceBundle(chromosomes: ["chr1", "chr2"])

        try vc.displayBundle(at: bundleURL, mode: .browse)
        let viewport = try XCTUnwrap(vc.referenceBundleViewportController)
        let embeddedViewer = try XCTUnwrap(viewport.children.compactMap { $0 as? ViewerViewController }.first)

        embeddedViewer.viewerView.testSetUserSelectionRange(10..<25)

        XCTAssertNil(vc.viewerView.selectionRange)
        let selection = try XCTUnwrap(vc.currentSequenceAnnotationDraftContext())
        XCTAssertEqual(selection.bundleURL, bundleURL.standardizedFileURL)
        XCTAssertEqual(selection.chromosome, "chr1")
        XCTAssertEqual(selection.range, 10..<25)
        XCTAssertEqual(selection.sequenceLength, 100)
    }

    func testReferenceViewportFocusedDetailAndBackRestoresListDetailState() throws {
        let vc = ViewerViewController()
        _ = vc.view
        let bundleURL = try makeReferenceBundle(chromosomes: ["chr1", "chr2"])

        try vc.displayBundle(at: bundleURL, mode: .browse)
        let viewport = try XCTUnwrap(vc.referenceBundleViewportController)
        viewport.testSelectSequence(named: "chr2")

        viewport.testEnterFocusedDetailMode()

        XCTAssertTrue(viewport.testIsFocusedDetailMode)
        XCTAssertEqual(viewport.testFocusedBackButtonAccessibilityIdentifier, "reference-viewport-back-button")

        viewport.testReturnToListDetailMode()

        XCTAssertFalse(viewport.testIsFocusedDetailMode)
        XCTAssertEqual(viewport.testSelectedSequenceName, "chr2")
    }

    func testFailedBrowseOpenPreservesExistingReferenceViewportState() throws {
        let vc = ViewerViewController()
        _ = vc.view
        let validBundleURL = try makeReferenceBundle(chromosomes: ["chr1", "chr2"])
        let invalidBundleURL = tempDir.appendingPathComponent("invalid-bundle.lungfishref", isDirectory: true)
        try FileManager.default.createDirectory(at: invalidBundleURL, withIntermediateDirectories: true)

        try vc.displayBundle(at: validBundleURL, mode: .browse)
        let viewport = try XCTUnwrap(vc.referenceBundleViewportController)
        viewport.testSelectSequence(named: "chr2")

        XCTAssertThrowsError(try vc.displayBundle(at: invalidBundleURL, mode: .browse))

        XCTAssertNotNil(vc.referenceBundleViewportController)
        XCTAssertEqual(vc.referenceBundleViewportController?.testSelectedSequenceName, "chr2")
        XCTAssertNil(vc.referenceFrame)
    }

    func testDisplayMultipleSequenceAlignmentBundleInstallsNativeViewport() throws {
        let vc = ViewerViewController()
        _ = vc.view
        let bundleURL = try makeMultipleSequenceAlignmentBundle()

        try vc.displayMultipleSequenceAlignmentBundle(at: bundleURL)

        XCTAssertNotNil(vc.multipleSequenceAlignmentViewController)
        XCTAssertNil(vc.phylogeneticTreeViewController)
        XCTAssertNil(vc.referenceBundleViewportController)
        XCTAssertNil(vc.currentBundleURL)
        XCTAssertEqual(vc.contentMode, .genomics)
    }

    func testMultipleSequenceAlignmentViewportRendersAlignmentMatrix() throws {
        let controller = MultipleSequenceAlignmentViewController()
        _ = controller.view
        let bundleURL = try makeMultipleSequenceAlignmentBundle()

        try controller.displayBundle(at: bundleURL)

        XCTAssertEqual(controller.testingRenderedRowNames, ["seq1", "seq2", "seq3"])
        XCTAssertEqual(
            controller.testingAlignmentMatrixPreview(rowCount: 3, columnCount: 6),
            [
                "seq1 ACGT-A",
                "seq2 ACCTTA",
                "seq3 ACGTTA",
            ]
        )
        XCTAssertEqual(controller.testingDisplayedAlignmentColumnCount, 6)
        XCTAssertEqual(controller.testingConsensusPreview, "ACGTTA")
    }

    func testMultipleSequenceAlignmentViewportCanFocusVariableSitesAndSelections() throws {
        let controller = MultipleSequenceAlignmentViewController()
        _ = controller.view
        let bundleURL = try makeMultipleSequenceAlignmentBundle()

        try controller.displayBundle(at: bundleURL)
        controller.testingSetVariableSitesOnly(true)
        controller.testingSelect(row: 1, displayedColumn: 0)

        XCTAssertEqual(controller.testingDisplayedAlignmentColumnCount, 1)
        XCTAssertEqual(controller.testingSelectedRowName, "seq2")
        XCTAssertEqual(controller.testingSelectedAlignmentColumn, 3)
        XCTAssertEqual(controller.testingSelectedResidue, "C")

        controller.testingSetSearchText("seq3")
        controller.testingPerformSearch()

        XCTAssertEqual(controller.testingSelectedRowName, "seq3")
    }

    func testMultipleSequenceAlignmentMatrixSupportsKeyboardNavigationAndRangeExtension() throws {
        let controller = MultipleSequenceAlignmentViewController()
        _ = controller.view
        let bundleURL = try makeMultipleSequenceAlignmentBundle()

        try controller.displayBundle(at: bundleURL)

        let matrixView = try XCTUnwrap(
            controller.view.testingDescendant(accessibilityIdentifier: "multiple-sequence-alignment-matrix-view")
        )
        XCTAssertTrue(matrixView.acceptsFirstResponder)

        matrixView.keyDown(with: .testingMSAKey(.right))
        XCTAssertEqual(controller.testingSelectedRowName, "seq1")
        XCTAssertEqual(controller.testingSelectedAlignmentColumn, 2)
        XCTAssertEqual(controller.testingSelectedAlignmentColumnRange, 2...2)

        matrixView.keyDown(with: .testingMSAKey(.down))
        XCTAssertEqual(controller.testingSelectedRowName, "seq2")
        XCTAssertEqual(controller.testingSelectedAlignmentColumn, 2)

        matrixView.keyDown(with: .testingMSAKey(.right, modifiers: [.shift]))
        XCTAssertEqual(controller.testingSelectedRowName, "seq2")
        XCTAssertEqual(controller.testingSelectedAlignmentColumn, 3)
        XCTAssertEqual(controller.testingSelectedAlignmentColumnRange, 2...3)

        matrixView.keyDown(with: .testingMSAKey(.end))
        XCTAssertEqual(controller.testingSelectedAlignmentColumn, 6)
        XCTAssertEqual(controller.testingSelectedAlignmentColumnRange, 6...6)

        matrixView.keyDown(with: .testingMSAKey(.home))
        XCTAssertEqual(controller.testingSelectedAlignmentColumn, 1)

        matrixView.keyDown(with: .testingMSAKey(.pageDown))
        XCTAssertEqual(controller.testingSelectedRowName, "seq3")

        matrixView.keyDown(with: .testingMSAKey(.pageUp))
        XCTAssertEqual(controller.testingSelectedRowName, "seq1")
    }

    func testMultipleSequenceAlignmentMatrixExposesKeyboardTestHook() throws {
        let controller = MultipleSequenceAlignmentViewController()
        _ = controller.view
        let bundleURL = try makeMultipleSequenceAlignmentBundle()

        try controller.displayBundle(at: bundleURL)

        controller.testingMoveActiveCell(.right)
        controller.testingMoveActiveCell(.down)
        controller.testingMoveActiveCell(.right, extendingSelection: true)

        XCTAssertEqual(controller.testingSelectedRowName, "seq2")
        XCTAssertEqual(controller.testingSelectedAlignmentColumn, 3)
        XCTAssertEqual(controller.testingSelectedAlignmentColumnRange, 2...3)
    }

    func testMultipleSequenceAlignmentViewportShowsOverviewAndColorSchemeSelector() throws {
        let controller = MultipleSequenceAlignmentViewController()
        _ = controller.view
        let bundleURL = try makeMultipleSequenceAlignmentBundle()

        try controller.displayBundle(at: bundleURL)

        let overview = try XCTUnwrap(
            controller.view.testingDescendant(accessibilityIdentifier: "multiple-sequence-alignment-overview-signal")
        )
        XCTAssertEqual(overview.accessibilityLabel(), "Alignment conservation overview")
        XCTAssertEqual(controller.testingOverviewSignalSummary, "6 columns, 1 variable, 1 gap-bearing")

        let colorScheme = try XCTUnwrap(
            controller.view.testingDescendant(accessibilityIdentifier: "multiple-sequence-alignment-color-scheme")
        ) as? NSSegmentedControl
        XCTAssertEqual(colorScheme?.label(forSegment: colorScheme?.selectedSegment ?? -1), "Nucleotide")

        controller.testingSetColorScheme(.conservation)

        XCTAssertEqual(colorScheme?.label(forSegment: colorScheme?.selectedSegment ?? -1), "Conservation")
        XCTAssertEqual(controller.testingColorSchemeName, "Conservation")
    }

    func testMultipleSequenceAlignmentViewportUsesFullCanvasAndAnnotationDrawer() throws {
        let controller = MultipleSequenceAlignmentViewController()
        controller.view.frame = NSRect(x: 0, y: 0, width: 1_200, height: 720)
        let bundleURL = try makeMultipleSequenceAlignmentBundle()

        try controller.displayBundle(at: bundleURL)
        controller.view.layoutSubtreeIfNeeded()

        let matrixView = try XCTUnwrap(
            controller.view.testingDescendant(accessibilityIdentifier: "multiple-sequence-alignment-matrix-view")
        )
        let rowGutter = try XCTUnwrap(
            controller.view.testingDescendant(accessibilityIdentifier: "multiple-sequence-alignment-row-gutter")
        )
        let columnHeader = try XCTUnwrap(
            controller.view.testingDescendant(accessibilityIdentifier: "multiple-sequence-alignment-column-header")
        )
        let annotationDrawer = try XCTUnwrap(
            controller.view.testingDescendant(accessibilityIdentifier: "annotation-table-drawer")
        )

        XCTAssertNil(controller.view.testingDescendant(accessibilityIdentifier: "multiple-sequence-alignment-list-pane"))
        XCTAssertNil(controller.view.testingDescendant(accessibilityIdentifier: "multiple-sequence-alignment-detail-visualization-pane"))
        XCTAssertNil(controller.view.testingDescendant(accessibilityIdentifier: "multiple-sequence-alignment-detail"))
        XCTAssertGreaterThan(matrixView.frame.width, 900)
        XCTAssertGreaterThan(matrixView.frame.height, 400)
        XCTAssertGreaterThanOrEqual(rowGutter.frame.width, 150)
        XCTAssertGreaterThanOrEqual(columnHeader.frame.height, 42)
        XCTAssertGreaterThanOrEqual(annotationDrawer.frame.height, 110)
    }

    func testMultipleSequenceAlignmentSelectionContextMenuUsesFASTAExtractionActions() throws {
        let controller = MultipleSequenceAlignmentViewController()
        _ = controller.view
        let bundleURL = try makeMultipleSequenceAlignmentBundle()

        try controller.displayBundle(at: bundleURL)
        controller.testingSelect(row: 1, displayedColumn: 0)

        XCTAssertEqual(
            controller.testingSelectionContextMenuTitles,
            [
                "Extract Sequence…",
                "Copy FASTA",
                "Export FASTA…",
                "Create Bundle…",
                "Run Operation…",
                "Build Tree with IQ-TREE…",
                "Add Annotation from Selection…",
                "Apply Annotation to Selected Rows",
            ]
        )
        XCTAssertEqual(controller.testingSelectedFASTARecords, [">seq2\nACCTTA\n"])
    }

    func testMultipleSequenceAlignmentBlockSelectionExportsSelectedColumnsAndShowsAnnotations() throws {
        let controller = MultipleSequenceAlignmentViewController()
        _ = controller.view
        let bundleURL = try makeMultipleSequenceAlignmentBundleWithAnnotations()

        try controller.displayBundle(at: bundleURL)
        controller.testingSelectBlock(rowRange: 0...1, displayedColumnRange: 1...4)

        XCTAssertEqual(controller.testingSelectedRowName, "2 rows")
        XCTAssertEqual(controller.testingSelectedAlignmentColumn, 2)
        XCTAssertEqual(
            controller.testingSelectedFASTARecords,
            [
                ">seq1_columns_2-5\nCGT\n",
                ">seq2_columns_2-5\nCCTT\n",
            ]
        )
        XCTAssertEqual(controller.testingAnnotationDrawerSummary, "1 annotation")
        XCTAssertEqual(controller.testingAnnotationDrawerRows, ["seq1\tgene-alpha\tgene\t2-4"])
    }

    func testMultipleSequenceAlignmentCreateBundleUsesCLIReferenceExtractionRequest() throws {
        let controller = MultipleSequenceAlignmentViewController()
        _ = controller.view
        let bundleURL = try makeMultipleSequenceAlignmentBundleWithAnnotations()
        var capturedRequest: MultipleSequenceAlignmentSelectionExportRequest?
        controller.onExportMSASelectionRequested = { request in
            capturedRequest = request
        }

        try controller.displayBundle(at: bundleURL)
        controller.testingSelectBlock(rowRange: 0...1, displayedColumnRange: 1...4)
        controller.testingCreateBundleFromSelectedSequences()

        let request = try XCTUnwrap(capturedRequest)
        XCTAssertEqual(request.bundleURL, bundleURL)
        XCTAssertEqual(request.outputKind, "reference")
        XCTAssertEqual(request.columns, "2-5")
        XCTAssertEqual(request.suggestedName, "seq1.lungfishref")
        XCTAssertTrue(request.rows?.isEmpty == false)
    }

    func testMultipleSequenceAlignmentContextMenuRequestsIQTreeInference() throws {
        let controller = MultipleSequenceAlignmentViewController()
        _ = controller.view
        let bundleURL = try makeMultipleSequenceAlignmentBundle()
        var capturedRequest: MultipleSequenceAlignmentTreeInferenceRequest?
        controller.onInferTreeRequested = { request in
            capturedRequest = request
        }

        try controller.displayBundle(at: bundleURL)
        controller.testingSelectBlock(rowRange: 0...1, displayedColumnRange: 1...4)
        controller.testingInferTreeFromAlignment()

        let request = try XCTUnwrap(capturedRequest)
        XCTAssertEqual(request.bundleURL, bundleURL)
        XCTAssertTrue(request.rows?.isEmpty == false)
        XCTAssertEqual(request.columns, "2-5")
        XCTAssertEqual(request.suggestedName, "alignment.lungfishtree")
        XCTAssertEqual(request.displayName, "alignment")
    }

    func testMultipleSequenceAlignmentDrawerShowsRetainedAnnotationsOutsideSelection() throws {
        let controller = MultipleSequenceAlignmentViewController()
        _ = controller.view
        let bundleURL = try makeMultipleSequenceAlignmentBundleWithAnnotations()

        try controller.displayBundle(at: bundleURL)

        XCTAssertEqual(controller.testingSelectedAlignmentColumn, 1)
        XCTAssertEqual(controller.testingAnnotationDrawerSummary, "1 annotation")
        XCTAssertEqual(controller.testingAnnotationDrawerRows, ["seq1\tgene-alpha\tgene\t2-4"])
    }

    func testMultipleSequenceAlignmentUsesReferenceAnnotationDrawerWithAlignmentMetadata() throws {
        let controller = MultipleSequenceAlignmentViewController()
        _ = controller.view
        let bundleURL = try makeMultipleSequenceAlignmentBundleWithAnnotations()

        try controller.displayBundle(at: bundleURL)

        let drawer = try XCTUnwrap(
            controller.view.testingDescendant(accessibilityIdentifier: "annotation-table-drawer") as? AnnotationTableDrawerView
        )
        XCTAssertNil(
            controller.view.testingDescendant(accessibilityIdentifier: "multiple-sequence-alignment-annotation-drawer")
        )
        XCTAssertEqual(drawer.displayedAnnotations.count, 1)
        XCTAssertEqual(drawer.displayedAnnotations.first?.name, "gene-alpha")
        XCTAssertEqual(drawer.displayedAnnotations.first?.attributes?["source_coordinates"], "seq1:2-4")
        XCTAssertEqual(drawer.displayedAnnotations.first?.attributes?["alignment_columns"], "2-4")
        XCTAssertEqual(drawer.displayedAnnotations.first?.attributes?["consensus_columns"], "2-4")
        XCTAssertTrue(drawer.tableView.tableColumns.map(\.title).contains("Source Coordinates"))
        XCTAssertTrue(drawer.tableView.tableColumns.map(\.title).contains("Alignment Columns"))
        XCTAssertTrue(drawer.tableView.tableColumns.map(\.title).contains("Consensus Columns"))
    }

    func testMultipleSequenceAlignmentViewportExposesVisibleAnnotationTracks() throws {
        let controller = MultipleSequenceAlignmentViewController()
        _ = controller.view
        let bundleURL = try makeMultipleSequenceAlignmentBundleWithAnnotations()

        try controller.displayBundle(at: bundleURL)

        XCTAssertEqual(controller.testingAnnotationTrackRows, ["seq1\tGenes\tgene-alpha\t2-4"])
        XCTAssertEqual(
            controller.testingAnnotationContextMenuTitles(named: "gene-alpha"),
            ["Select Annotation", "Center on Annotation", "Zoom to Annotation"]
        )
    }

    func testMultipleSequenceAlignmentAnnotationTracksExposeAccessibilityElements() throws {
        let controller = MultipleSequenceAlignmentViewController()
        _ = controller.view
        let bundleURL = try makeMultipleSequenceAlignmentBundleWithAnnotations()

        try controller.displayBundle(at: bundleURL)
        let matrixView = try XCTUnwrap(
            controller.view.testingDescendant(accessibilityIdentifier: "multiple-sequence-alignment-matrix-view")
        )
        let elements = matrixView.accessibilityChildren() ?? []
        let annotationElement = try XCTUnwrap(elements.compactMap { $0 as? NSView }.first {
            $0.accessibilityIdentifier() == "multiple-sequence-alignment-annotation-track-seq1-gene-alpha"
        })

        XCTAssertEqual(
            annotationElement.accessibilityLabel(),
            "Annotation gene-alpha, type gene, row seq1, alignment columns 2-4, source coordinates 2-4"
        )
    }

    func testMultipleSequenceAlignmentSelectedCellExposesAccessibilityElement() throws {
        let controller = MultipleSequenceAlignmentViewController()
        _ = controller.view
        let bundleURL = try makeMultipleSequenceAlignmentBundle()

        try controller.displayBundle(at: bundleURL)
        controller.testingSelect(row: 1, displayedColumn: 2)

        let matrixView = try XCTUnwrap(
            controller.view.testingDescendant(accessibilityIdentifier: "multiple-sequence-alignment-matrix-view")
        )
        let elements = matrixView.accessibilityChildren() ?? []
        let selectedCell = try XCTUnwrap(elements.compactMap { $0 as? NSView }.first {
            $0.accessibilityIdentifier() == "multiple-sequence-alignment-cell-seq2-column-3"
        })

        XCTAssertEqual(selectedCell.accessibilityLabel(), "seq2, alignment column 3, residue C")
        XCTAssertEqual(selectedCell.accessibilityHelp(), "Selected alignment cell. Use arrow keys or drag to adjust the selection.")
        XCTAssertNotNil(
            controller.view.testingDescendant(accessibilityIdentifier: "multiple-sequence-alignment-cell-seq2-column-3"),
            "Selected alignment cell should also be a concrete accessibility subview for XCUI."
        )
    }

    func testMultipleSequenceAlignmentAnnotationDrawerSelectionNavigatesAlignmentColumns() throws {
        let controller = MultipleSequenceAlignmentViewController()
        _ = controller.view
        let bundleURL = try makeMultipleSequenceAlignmentBundleWithAnnotations()

        try controller.displayBundle(at: bundleURL)
        let drawer = try XCTUnwrap(
            controller.view.testingDescendant(accessibilityIdentifier: "annotation-table-drawer") as? AnnotationTableDrawerView
        )
        let annotation = try XCTUnwrap(drawer.displayedAnnotations.first)

        controller.annotationDrawer(drawer, didSelectAnnotation: annotation)

        XCTAssertEqual(controller.testingSelectedRowName, "seq1")
        XCTAssertEqual(controller.testingSelectedAlignmentColumn, 2)
        XCTAssertEqual(controller.testingAnnotationDrawerRows, ["seq1\tgene-alpha\tgene\t2-4"])
    }

    func testMultipleSequenceAlignmentAnnotationTrackSelectionCentersAndZoomsToAnnotation() throws {
        let controller = MultipleSequenceAlignmentViewController()
        _ = controller.view
        let bundleURL = try makeMultipleSequenceAlignmentBundleWithAnnotations()

        try controller.displayBundle(at: bundleURL)
        let initialColumnWidth = controller.testingAlignmentColumnWidth

        controller.testingSelectAnnotationTrack(named: "gene-alpha")

        XCTAssertEqual(controller.testingSelectedRowName, "seq1")
        XCTAssertEqual(controller.testingSelectedAlignmentColumn, 2)
        XCTAssertEqual(controller.testingSelectedAlignmentColumnRange, 2...4)

        controller.testingZoomToAnnotationTrack(named: "gene-alpha")

        XCTAssertGreaterThan(controller.testingAlignmentColumnWidth, initialColumnWidth)
        XCTAssertEqual(controller.testingSelectedAlignmentColumnRange, 2...4)
    }

    func testMultipleSequenceAlignmentCanAuthorAndProjectAnnotationFromSelectedColumns() throws {
        let controller = MultipleSequenceAlignmentViewController()
        _ = controller.view
        let bundleURL = try makeMultipleSequenceAlignmentBundle()

        try controller.displayBundle(at: bundleURL)
        controller.testingSelectBlock(rowRange: 0...0, displayedColumnRange: 1...4)
        try controller.testingAddAnnotationFromSelection(name: "selection-feature", type: "gene")

        XCTAssertEqual(controller.testingAnnotationDrawerSummary, "1 annotation")
        XCTAssertEqual(controller.testingAnnotationDrawerRows, ["seq1\tselection-feature\tgene\t2-4"])

        controller.testingSelectBlock(rowRange: 0...1, displayedColumnRange: 1...4)
        try controller.testingApplySelectedAnnotationsToSelectedRows()

        XCTAssertEqual(controller.testingAnnotationDrawerSummary, "2 annotations")
        XCTAssertEqual(
            controller.testingAnnotationDrawerRows,
            [
                "seq1\tselection-feature\tgene\t2-4",
                "seq2\tselection-feature\tgene\t2-4",
            ]
        )

        let persisted = try MultipleSequenceAlignmentBundle.load(from: bundleURL).loadAnnotationStore()
        XCTAssertEqual(persisted.sourceAnnotations.count, 1)
        XCTAssertEqual(persisted.projectedAnnotations.count, 1)
        XCTAssertEqual(persisted.projectedAnnotations.first?.rowName, "seq2")
    }

    func testMultipleSequenceAlignmentAnnotationAuthoringRequestsCLIWhenCallbackInstalled() throws {
        let controller = MultipleSequenceAlignmentViewController()
        _ = controller.view
        let bundleURL = try makeMultipleSequenceAlignmentBundle()
        var capturedRequest: MultipleSequenceAlignmentAnnotationAddRequest?
        controller.onAddAnnotationRequested = { request in
            capturedRequest = request
        }

        try controller.displayBundle(at: bundleURL)
        controller.testingSelectBlock(rowRange: 0...0, displayedColumnRange: 1...4)
        try controller.testingAddAnnotationFromSelection(name: "selection-feature", type: "gene")

        let request = try XCTUnwrap(capturedRequest)
        XCTAssertEqual(request.bundleURL, bundleURL)
        XCTAssertEqual(request.columns, "2-5")
        XCTAssertEqual(request.name, "selection-feature")
        XCTAssertEqual(request.type, "gene")
        XCTAssertEqual(request.strand, ".")
        XCTAssertEqual(request.qualifiers, ["created_by=lungfish-gui"])
        XCTAssertFalse(request.row.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        XCTAssertEqual(controller.testingAnnotationDrawerSummary, "0 annotations")
    }

    func testMultipleSequenceAlignmentAnnotationProjectionRequestsCLIWhenCallbackInstalled() throws {
        let controller = MultipleSequenceAlignmentViewController()
        _ = controller.view
        let bundleURL = try makeMultipleSequenceAlignmentBundleWithAnnotations()
        var capturedRequests: [MultipleSequenceAlignmentAnnotationProjectionRequest] = []
        controller.onProjectAnnotationRequested = { request in
            capturedRequests.append(request)
        }

        try controller.displayBundle(at: bundleURL)
        controller.testingSelectBlock(rowRange: 0...1, displayedColumnRange: 1...4)
        try controller.testingApplySelectedAnnotationsToSelectedRows()

        let request = try XCTUnwrap(capturedRequests.first)
        XCTAssertEqual(capturedRequests.count, 1)
        XCTAssertEqual(request.bundleURL, bundleURL)
        XCTAssertFalse(request.sourceAnnotationID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        XCTAssertFalse(request.targetRows.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        XCTAssertEqual(request.conflictPolicy, "append")
        XCTAssertEqual(request.displayName, "gene-alpha")
        XCTAssertEqual(controller.testingAnnotationDrawerSummary, "1 annotation")
    }

    func testMultipleSequenceAlignmentExtractionCarriesProjectedAnnotations() throws {
        let controller = MultipleSequenceAlignmentViewController()
        _ = controller.view
        let bundleURL = try makeMultipleSequenceAlignmentBundle()

        try controller.displayBundle(at: bundleURL)
        controller.testingSelectBlock(rowRange: 0...0, displayedColumnRange: 1...4)
        try controller.testingAddAnnotationFromSelection(name: "selection-feature", type: "gene")
        controller.testingSelectBlock(rowRange: 0...1, displayedColumnRange: 1...4)
        try controller.testingApplySelectedAnnotationsToSelectedRows()

        XCTAssertEqual(
            controller.testingSelectedFASTARecords,
            [
                ">seq1_columns_2-5\nCGT\n",
                ">seq2_columns_2-5\nCCTT\n",
            ]
        )
        let annotations = controller.testingSelectedExtractionAnnotationsByRecord
        XCTAssertEqual(Set(annotations.keys), ["seq1_columns_2-5", "seq2_columns_2-5"])
        XCTAssertEqual(annotations["seq1_columns_2-5"]?.first?.intervals, [AnnotationInterval(start: 0, end: 3)])
        XCTAssertEqual(annotations["seq2_columns_2-5"]?.first?.intervals, [AnnotationInterval(start: 0, end: 3)])
        XCTAssertEqual(annotations["seq1_columns_2-5"]?.first?.chromosome, "seq1_columns_2-5")
        XCTAssertEqual(annotations["seq2_columns_2-5"]?.first?.chromosome, "seq2_columns_2-5")
    }

    func testDisplayPhylogeneticTreeBundleInstallsNativeViewport() throws {
        let vc = ViewerViewController()
        _ = vc.view
        let bundleURL = try makePhylogeneticTreeBundle()

        try vc.displayPhylogeneticTreeBundle(at: bundleURL)

        XCTAssertNotNil(vc.phylogeneticTreeViewController)
        XCTAssertNil(vc.multipleSequenceAlignmentViewController)
        XCTAssertNil(vc.referenceBundleViewportController)
        XCTAssertNil(vc.currentBundleURL)
        XCTAssertEqual(vc.contentMode, .genomics)
    }

    func testPhylogeneticTreeViewportRendersInteractiveRectangularCanvas() throws {
        let controller = PhylogeneticTreeViewController()
        controller.view.frame = NSRect(x: 0, y: 0, width: 1_200, height: 720)
        let bundleURL = try makePhylogeneticTreeBundle()

        try controller.displayBundle(at: bundleURL)
        controller.view.layoutSubtreeIfNeeded()

        XCTAssertNotNil(controller.view.testingDescendant(accessibilityIdentifier: "phylogenetic-tree-canvas-view"))
        XCTAssertNotNil(controller.view.testingDescendant(accessibilityIdentifier: "phylogenetic-tree-search-field"))
        XCTAssertNotNil(controller.view.testingDescendant(accessibilityIdentifier: "phylogenetic-tree-fit-button"))
        XCTAssertNotNil(controller.view.testingDescendant(accessibilityIdentifier: "phylogenetic-tree-reset-button"))
        XCTAssertGreaterThanOrEqual(controller.testingCanvasNodeCount, 5)
        XCTAssertEqual(controller.testingRenderedTipLabels, ["A", "B", "C"])
        XCTAssertTrue(controller.testingCanvasCommandAccessibilityLabels.contains("Fit tree"))
        XCTAssertTrue(controller.testingCanvasCommandAccessibilityLabels.contains("Reset tree"))
        XCTAssertGreaterThan(
            controller.testingCanvasViewportFrame.width,
            300,
            "frames: \(controller.testingTreeLayoutFrames)"
        )

        controller.testingSelectNode(label: "B")

        XCTAssertEqual(controller.testingSelectedNodeLabel, "B")
        XCTAssertTrue(controller.testingDetailText.contains("B"))
        XCTAssertTrue(controller.testingDetailText.contains("branch"))
    }

    func testPhylogeneticTreeViewportKeepsControlsInsideNarrowVisualizationArea() throws {
        let controller = PhylogeneticTreeViewController()
        controller.view.frame = NSRect(x: 0, y: 0, width: 760, height: 520)
        let bundleURL = try makePhylogeneticTreeBundle()

        try controller.displayBundle(at: bundleURL)
        controller.view.layoutSubtreeIfNeeded()

        let layoutFrames = controller.testingTreeLayoutFrames
        let rootFrame = try XCTUnwrap(layoutFrames["rootView"])
        let canvasFrame = try XCTUnwrap(layoutFrames["treeScrollView"])
        XCTAssertGreaterThan(canvasFrame.width, 560, "frames: \(layoutFrames)")
        XCTAssertGreaterThan(canvasFrame.height, 300, "frames: \(layoutFrames)")

        for frame in controller.testingToolbarControlFrames.values {
            XCTAssertGreaterThanOrEqual(frame.minX, rootFrame.minX, "toolbar frame \(frame) escaped root \(rootFrame)")
            XCTAssertLessThanOrEqual(frame.maxX, rootFrame.maxX, "toolbar frame \(frame) escaped root \(rootFrame)")
            XCTAssertGreaterThanOrEqual(frame.minY, rootFrame.minY, "toolbar frame \(frame) escaped root \(rootFrame)")
            XCTAssertLessThanOrEqual(frame.maxY, rootFrame.maxY, "toolbar frame \(frame) escaped root \(rootFrame)")
        }

        XCTAssertTrue(controller.testingCanvasCommandAccessibilityLabels.contains("Fit tree"))
        XCTAssertTrue(controller.testingCanvasCommandAccessibilityLabels.contains("Zoom in"))
        XCTAssertTrue(controller.testingCanvasCommandAccessibilityLabels.contains("Zoom out"))
    }

    private func makeReferenceBundle(chromosomes: [String]) throws -> URL {
        let bundleURL = tempDir.appendingPathComponent("\(UUID().uuidString).lungfishref", isDirectory: true)
        let genomeURL = bundleURL.appendingPathComponent("genome", isDirectory: true)
        try FileManager.default.createDirectory(at: genomeURL, withIntermediateDirectories: true)
        try Data().write(to: genomeURL.appendingPathComponent("sequence.fa.gz"))
        try Data().write(to: genomeURL.appendingPathComponent("sequence.fa.gz.fai"))

        let manifest = BundleManifest(
            name: "Fixture",
            identifier: "org.test.viewer.fixture",
            source: SourceInfo(organism: "Fixture", assembly: "fixture"),
            genome: GenomeInfo(
                path: "genome/sequence.fa.gz",
                indexPath: "genome/sequence.fa.gz.fai",
                totalLength: Int64(chromosomes.count * 100),
                chromosomes: chromosomes.enumerated().map { index, name in
                    ChromosomeInfo(
                        name: name,
                        length: 100,
                        offset: Int64(index * 101),
                        lineBases: 80,
                        lineWidth: 81
                    )
                }
            )
        )

        try manifest.save(to: bundleURL)
        return bundleURL
    }

    private func makeMultipleSequenceAlignmentBundle() throws -> URL {
        let sourceURL = tempDir.appendingPathComponent("alignment.fa")
        try """
        >seq1
        ACGT-A
        >seq2
        ACCTTA
        >seq3
        ACGTTA
        """.write(to: sourceURL, atomically: true, encoding: .utf8)
        let bundleURL = tempDir.appendingPathComponent("alignment.lungfishmsa", isDirectory: true)
        _ = try MultipleSequenceAlignmentBundle.importAlignment(from: sourceURL, to: bundleURL)
        return bundleURL
    }

    private func makeMultipleSequenceAlignmentBundleWithAnnotations() throws -> URL {
        let sourceURL = tempDir.appendingPathComponent("annotated-alignment.fa")
        try """
        >seq1
        ACGT-A
        >seq2
        ACCTTA
        >seq3
        ACGTTA
        """.write(to: sourceURL, atomically: true, encoding: .utf8)
        let bundleURL = tempDir.appendingPathComponent("annotated-alignment.lungfishmsa", isDirectory: true)
        _ = try MultipleSequenceAlignmentBundle.importAlignment(
            from: sourceURL,
            to: bundleURL,
            options: .init(
                sourceAnnotations: [
                    MultipleSequenceAlignmentBundle.SourceAnnotationInput(
                        rowName: "seq1",
                        sourceSequenceName: "seq1",
                        sourceFilePath: sourceURL.path,
                        sourceTrackID: "genes",
                        sourceTrackName: "Genes",
                        sourceAnnotationID: "gene-alpha",
                        name: "gene-alpha",
                        type: "gene",
                        strand: "+",
                        intervals: [AnnotationInterval(start: 1, end: 4)]
                    ),
                ]
            )
        )
        return bundleURL
    }

    private func makePhylogeneticTreeBundle() throws -> URL {
        let sourceURL = tempDir.appendingPathComponent("tree.nwk")
        try "((A:0.1,B:0.2)90:0.3,C:0.4);\n".write(to: sourceURL, atomically: true, encoding: .utf8)
        let bundleURL = tempDir.appendingPathComponent("tree.lungfishtree", isDirectory: true)
        _ = try PhylogeneticTreeBundleImporter.importTree(from: sourceURL, to: bundleURL)
        return bundleURL
    }
}

private extension NSView {
    func testingDescendant(accessibilityIdentifier target: String) -> NSView? {
        if accessibilityIdentifier() == target {
            return self
        }
        for subview in subviews {
            if let found = subview.testingDescendant(accessibilityIdentifier: target) {
                return found
            }
        }
        return nil
    }
}

private enum MSATestingKey {
    case up
    case down
    case left
    case right
    case home
    case end
    case pageUp
    case pageDown
}

private extension NSEvent {
    static func testingMSAKey(
        _ key: MSATestingKey,
        modifiers: NSEvent.ModifierFlags = []
    ) -> NSEvent {
        let specialKey: Int
        let keyCode: UInt16
        switch key {
        case .up:
            specialKey = NSUpArrowFunctionKey
            keyCode = 126
        case .down:
            specialKey = NSDownArrowFunctionKey
            keyCode = 125
        case .left:
            specialKey = NSLeftArrowFunctionKey
            keyCode = 123
        case .right:
            specialKey = NSRightArrowFunctionKey
            keyCode = 124
        case .home:
            specialKey = NSHomeFunctionKey
            keyCode = 115
        case .end:
            specialKey = NSEndFunctionKey
            keyCode = 119
        case .pageUp:
            specialKey = NSPageUpFunctionKey
            keyCode = 116
        case .pageDown:
            specialKey = NSPageDownFunctionKey
            keyCode = 121
        }
        let characters = String(Character(UnicodeScalar(specialKey)!))
        return NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: modifiers,
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: characters,
            charactersIgnoringModifiers: characters,
            isARepeat: false,
            keyCode: keyCode
        )!
    }
}

// MARK: - AnnotationTrackInfo Tests

/// Tests for `AnnotationTrackInfo` construction and type values.
final class AnnotationTrackInfoTests: XCTestCase {

    func testAnnotationTrackInfoConstruction() {
        let track = AnnotationTrackInfo(
            id: "genes",
            name: "Gene Annotations",
            description: "NCBI RefSeq genes",
            path: "annotations/genes.bb",
            annotationType: .gene,
            featureCount: 42_000,
            source: "NCBI",
            version: "110"
        )

        XCTAssertEqual(track.id, "genes")
        XCTAssertEqual(track.name, "Gene Annotations")
        XCTAssertEqual(track.description, "NCBI RefSeq genes")
        XCTAssertEqual(track.path, "annotations/genes.bb")
        XCTAssertEqual(track.annotationType, .gene)
        XCTAssertEqual(track.featureCount, 42_000)
        XCTAssertEqual(track.source, "NCBI")
        XCTAssertEqual(track.version, "110")
    }

    func testAnnotationTrackInfoDefaults() {
        let track = AnnotationTrackInfo(
            id: "track1",
            name: "Track",
            path: "annotations/track.bb"
        )
        XCTAssertNil(track.description)
        XCTAssertEqual(track.annotationType, .gene, "Default annotation type should be .gene")
        XCTAssertNil(track.featureCount)
        XCTAssertNil(track.source)
        XCTAssertNil(track.version)
    }

    func testAnnotationTrackTypes() {
        // Verify all annotation track types are valid
        let types: [AnnotationTrackType] = [
            .gene, .transcript, .exon, .cds, .regulatory, .repeats, .conservation, .custom
        ]
        for type in types {
            let track = AnnotationTrackInfo(
                id: "test_\(type.rawValue)",
                name: "Test",
                path: "test.bb",
                annotationType: type
            )
            XCTAssertEqual(track.annotationType, type)
        }
    }

    func testAnnotationTrackInfoCodableRoundTrip() throws {
        let original = AnnotationTrackInfo(
            id: "genes",
            name: "Genes",
            description: "Test genes",
            path: "annotations/genes.bb",
            annotationType: .transcript,
            featureCount: 1000,
            source: "Ensembl",
            version: "109"
        )

        let encoder = JSONEncoder()
        let data = try encoder.encode(original)
        let decoded = try JSONDecoder().decode(AnnotationTrackInfo.self, from: data)

        XCTAssertEqual(decoded, original)
    }

    func testAnnotationTrackInfoIdentifiable() {
        let track = AnnotationTrackInfo(id: "my_track", name: "My Track", path: "t.bb")
        XCTAssertEqual(track.id, "my_track",
                       "AnnotationTrackInfo.id should be the track ID string")
    }
}

// MARK: - GenomeInfo Tests

/// Tests for the `GenomeInfo` model.
final class GenomeInfoTests: XCTestCase {

    func testGenomeInfoConstruction() {
        let chroms = [
            ChromosomeInfo(name: "chr1", length: 1000, offset: 0, lineBases: 80, lineWidth: 81),
            ChromosomeInfo(name: "chr2", length: 2000, offset: 1000, lineBases: 80, lineWidth: 81),
        ]
        let genome = GenomeInfo(
            path: "genome/seq.fa.gz",
            indexPath: "genome/seq.fa.gz.fai",
            gzipIndexPath: "genome/seq.fa.gz.gzi",
            totalLength: 3000,
            chromosomes: chroms,
            md5Checksum: "abc123def456"
        )

        XCTAssertEqual(genome.path, "genome/seq.fa.gz")
        XCTAssertEqual(genome.indexPath, "genome/seq.fa.gz.fai")
        XCTAssertEqual(genome.gzipIndexPath, "genome/seq.fa.gz.gzi")
        XCTAssertEqual(genome.totalLength, 3000)
        XCTAssertEqual(genome.chromosomes.count, 2)
        XCTAssertEqual(genome.md5Checksum, "abc123def456")
    }

    func testGenomeInfoDefaults() {
        let genome = GenomeInfo(
            path: "g.fa.gz",
            indexPath: "g.fa.gz.fai",
            totalLength: 0,
            chromosomes: []
        )
        XCTAssertNil(genome.gzipIndexPath)
        XCTAssertNil(genome.md5Checksum)
    }

    func testGenomeInfoCodableRoundTrip() throws {
        let original = GenomeInfo(
            path: "genome/seq.fa.gz",
            indexPath: "genome/seq.fa.gz.fai",
            gzipIndexPath: "genome/seq.fa.gz.gzi",
            totalLength: 3_088_286_401,
            chromosomes: [
                ChromosomeInfo(name: "chr1", length: 248_956_422, offset: 0, lineBases: 80, lineWidth: 81),
            ],
            md5Checksum: "d73e3497c7d07f11a24a00e5ad33a77b"
        )

        let encoder = JSONEncoder()
        let data = try encoder.encode(original)
        let decoded = try JSONDecoder().decode(GenomeInfo.self, from: data)

        XCTAssertEqual(decoded, original)
    }

    func testGenomeInfoCodingKeys() throws {
        let genome = GenomeInfo(
            path: "g.fa.gz",
            indexPath: "g.fai",
            gzipIndexPath: "g.gzi",
            totalLength: 100,
            chromosomes: [],
            md5Checksum: "abc"
        )

        let data = try JSONEncoder().encode(genome)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])

        XCTAssertNotNil(json["index_path"], "Should encode indexPath as 'index_path'")
        XCTAssertNotNil(json["gzip_index_path"], "Should encode gzipIndexPath as 'gzip_index_path'")
        XCTAssertNotNil(json["total_length"], "Should encode totalLength as 'total_length'")
        XCTAssertNotNil(json["md5_checksum"], "Should encode md5Checksum as 'md5_checksum'")
    }
}

// MARK: - SourceInfo Tests

/// Tests for the `SourceInfo` model.
final class SourceInfoTests: XCTestCase {

    func testSourceInfoConstruction() {
        let source = SourceInfo(
            organism: "Homo sapiens",
            commonName: "Human",
            taxonomyId: 9606,
            assembly: "GRCh38",
            assemblyAccession: "GCF_000001405.40",
            database: "NCBI",
            notes: "Primary assembly"
        )

        XCTAssertEqual(source.organism, "Homo sapiens")
        XCTAssertEqual(source.commonName, "Human")
        XCTAssertEqual(source.taxonomyId, 9606)
        XCTAssertEqual(source.assembly, "GRCh38")
        XCTAssertEqual(source.assemblyAccession, "GCF_000001405.40")
        XCTAssertEqual(source.database, "NCBI")
        XCTAssertEqual(source.notes, "Primary assembly")
    }

    func testSourceInfoDefaults() {
        let source = SourceInfo(organism: "Mus musculus", assembly: "GRCm39")
        XCTAssertNil(source.commonName)
        XCTAssertNil(source.taxonomyId)
        XCTAssertNil(source.assemblyAccession)
        XCTAssertNil(source.database)
        XCTAssertNil(source.sourceURL)
        XCTAssertNil(source.downloadDate)
        XCTAssertNil(source.notes)
    }

    func testSourceInfoCodableRoundTrip() throws {
        let original = SourceInfo(
            organism: "Danio rerio",
            commonName: "Zebrafish",
            taxonomyId: 7955,
            assembly: "GRCz11"
        )

        let encoder = JSONEncoder()
        let data = try encoder.encode(original)
        let decoded = try JSONDecoder().decode(SourceInfo.self, from: data)

        XCTAssertEqual(decoded, original)
    }
}
