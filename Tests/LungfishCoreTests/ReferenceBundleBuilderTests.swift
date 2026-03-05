// ReferenceBundleBuilderTests.swift - Tests for bundle builder
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
@testable import LungfishCore

final class ReferenceBundleBuilderTests: XCTestCase {

    // MARK: - Test Fixtures

    var tempDirectory: URL!

    override func setUp() async throws {
        tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("LungfishBuilderTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        if let tempDir = tempDirectory {
            try? FileManager.default.removeItem(at: tempDir)
        }
    }

    // MARK: - BuildStep Tests

    func testBuildStepProgressWeights() {
        // Ensure all progress weights sum to approximately 1.0
        let totalWeight = BuildStep.allCases.reduce(0.0) { $0 + $1.progressWeight }
        XCTAssertEqual(totalWeight, 1.0, accuracy: 0.01)
    }

    func testBuildStepRawValues() {
        XCTAssertEqual(BuildStep.validating.rawValue, "Validating input files")
        XCTAssertEqual(BuildStep.creatingStructure.rawValue, "Creating bundle structure")
        XCTAssertEqual(BuildStep.compressingFASTA.rawValue, "Compressing FASTA with bgzip")
        XCTAssertEqual(BuildStep.complete.rawValue, "Complete")
    }

    // MARK: - BuildConfiguration Tests

    func testBuildConfigurationCreation() {
        let fastaURL = tempDirectory.appendingPathComponent("test.fa")
        let outputDir = tempDirectory.appendingPathComponent("output")

        let config = BuildConfiguration(
            name: "Test Genome",
            identifier: "test.genome",
            fastaURL: fastaURL,
            outputDirectory: outputDir,
            source: SourceInfo(organism: "Test", assembly: "v1")
        )

        XCTAssertEqual(config.name, "Test Genome")
        XCTAssertEqual(config.identifier, "test.genome")
        XCTAssertEqual(config.fastaURL, fastaURL)
        XCTAssertEqual(config.outputDirectory, outputDir)
        XCTAssertTrue(config.compressFASTA)
        XCTAssertTrue(config.annotationFiles.isEmpty)
        XCTAssertTrue(config.variantFiles.isEmpty)
        XCTAssertTrue(config.signalFiles.isEmpty)
    }

    func testBuildConfigurationWithAllInputs() {
        let fastaURL = tempDirectory.appendingPathComponent("test.fa")
        let gffURL = tempDirectory.appendingPathComponent("test.gff3")
        let vcfURL = tempDirectory.appendingPathComponent("test.vcf")
        let bwURL = tempDirectory.appendingPathComponent("test.bw")
        let outputDir = tempDirectory.appendingPathComponent("output")

        let config = BuildConfiguration(
            name: "Full Genome",
            identifier: "full.genome",
            fastaURL: fastaURL,
            annotationFiles: [
                AnnotationInput(url: gffURL, name: "Genes", annotationType: .gene)
            ],
            variantFiles: [
                VariantInput(url: vcfURL, name: "Variants")
            ],
            signalFiles: [
                SignalInput(url: bwURL, name: "Coverage", signalType: .coverage)
            ],
            outputDirectory: outputDir,
            source: SourceInfo(organism: "Test", assembly: "v1"),
            compressFASTA: false
        )

        XCTAssertEqual(config.annotationFiles.count, 1)
        XCTAssertEqual(config.variantFiles.count, 1)
        XCTAssertEqual(config.signalFiles.count, 1)
        XCTAssertFalse(config.compressFASTA)
    }

    // MARK: - AnnotationInput Tests

    func testAnnotationInputCreation() {
        let url = tempDirectory.appendingPathComponent("genes.gff3")

        let input = AnnotationInput(
            url: url,
            name: "Gene Annotations",
            description: "Test genes",
            annotationType: .gene
        )

        XCTAssertEqual(input.url, url)
        XCTAssertEqual(input.name, "Gene Annotations")
        XCTAssertEqual(input.description, "Test genes")
        XCTAssertEqual(input.annotationType, .gene)
        XCTAssertEqual(input.id, "genes")  // Auto-generated from filename
    }

    func testAnnotationInputWithCustomId() {
        let url = tempDirectory.appendingPathComponent("test.gff3")

        let input = AnnotationInput(
            url: url,
            name: "Test",
            id: "custom_id"
        )

        XCTAssertEqual(input.id, "custom_id")
    }

    // MARK: - VariantInput Tests

    func testVariantInputCreation() {
        let url = tempDirectory.appendingPathComponent("snps.vcf")

        let input = VariantInput(
            url: url,
            name: "SNP Variants",
            description: "Test SNPs",
            variantType: .snp
        )

        XCTAssertEqual(input.url, url)
        XCTAssertEqual(input.name, "SNP Variants")
        XCTAssertEqual(input.description, "Test SNPs")
        XCTAssertEqual(input.variantType, .snp)
        XCTAssertEqual(input.id, "snps")
    }

    func testVariantInputDefaultType() {
        let url = tempDirectory.appendingPathComponent("test.vcf")

        let input = VariantInput(url: url, name: "Test")

        XCTAssertEqual(input.variantType, .mixed)
    }

    // MARK: - SignalInput Tests

    func testSignalInputCreation() {
        let url = tempDirectory.appendingPathComponent("coverage.bw")

        let input = SignalInput(
            url: url,
            name: "Coverage Track",
            signalType: .coverage
        )

        XCTAssertEqual(input.url, url)
        XCTAssertEqual(input.name, "Coverage Track")
        XCTAssertEqual(input.signalType, .coverage)
        XCTAssertEqual(input.id, "coverage")
    }

    func testSignalInputDefaultType() {
        let url = tempDirectory.appendingPathComponent("test.bw")

        let input = SignalInput(url: url, name: "Test")

        XCTAssertEqual(input.signalType, .custom)
    }

    // MARK: - BundleBuildError Tests

    func testBundleBuildErrorDescriptions() {
        let url = URL(fileURLWithPath: "/test/file.fa")

        let notFound = BundleBuildError.inputFileNotFound(url)
        XCTAssertTrue(notFound.localizedDescription.contains("not found"))

        let notReadable = BundleBuildError.inputFileNotReadable(url)
        XCTAssertTrue(notReadable.localizedDescription.contains("Cannot read"))

        let invalidFASTA = BundleBuildError.invalidFASTAFormat("bad header")
        XCTAssertTrue(invalidFASTA.localizedDescription.contains("Invalid FASTA"))

        let cancelled = BundleBuildError.cancelled
        XCTAssertTrue(cancelled.localizedDescription.contains("cancelled"))

        let validationFailed = BundleBuildError.validationFailed(["error1", "error2"])
        XCTAssertTrue(validationFailed.localizedDescription.contains("error1"))
        XCTAssertTrue(validationFailed.localizedDescription.contains("error2"))
    }

    func testBundleBuildErrorRecoverySuggestions() {
        let url = URL(fileURLWithPath: "/test")

        XCTAssertNotNil(BundleBuildError.inputFileNotFound(url).recoverySuggestion)
        XCTAssertNotNil(BundleBuildError.invalidFASTAFormat("test").recoverySuggestion)
        XCTAssertNotNil(BundleBuildError.cancelled.recoverySuggestion)
        XCTAssertNotNil(BundleBuildError.containerRuntimeNotAvailable.recoverySuggestion)
    }

    // MARK: - ReferenceBundleBuilder Tests

    @MainActor
    func testBuilderInitialState() {
        let builder = ReferenceBundleBuilder()

        XCTAssertEqual(builder.progress, 0.0)
        XCTAssertFalse(builder.isBuilding)
        XCTAssertTrue(builder.errors.isEmpty)
    }

    @MainActor
    func testBuildWithMissingFASTA() async {
        let builder = ReferenceBundleBuilder()

        let config = BuildConfiguration(
            name: "Test",
            identifier: "test",
            fastaURL: tempDirectory.appendingPathComponent("nonexistent.fa"),
            outputDirectory: tempDirectory,
            source: SourceInfo(organism: "Test", assembly: "v1")
        )

        do {
            _ = try await builder.build(configuration: config)
            XCTFail("Expected error for missing FASTA")
        } catch let error as BundleBuildError {
            if case .inputFileNotFound = error {
                // Expected
            } else {
                XCTFail("Expected inputFileNotFound error, got \(error)")
            }
        } catch {
            XCTFail("Unexpected error type: \(error)")
        }
    }

    @MainActor
    func testBuildWithValidFASTA() async throws {
        let builder = ReferenceBundleBuilder()

        // Create a test FASTA file
        let fastaURL = tempDirectory.appendingPathComponent("test.fa")
        let fastaContent = """
        >chr1
        ATCGATCGATCGATCGATCGATCGATCGATCGATCGATCGATCGATCGATCG
        ATCGATCGATCGATCGATCGATCGATCGATCGATCGATCGATCGATCGATCG
        >chr2
        GGGGCCCCGGGGCCCCGGGGCCCCGGGGCCCCGGGGCCCC
        """
        try fastaContent.write(to: fastaURL, atomically: true, encoding: .utf8)

        let outputDir = tempDirectory.appendingPathComponent("output")
        try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)

        let config = BuildConfiguration(
            name: "Test Genome",
            identifier: "test.genome",
            fastaURL: fastaURL,
            outputDirectory: outputDir,
            source: SourceInfo(organism: "Test organism", assembly: "TestAssembly"),
            compressFASTA: true
        )

        let progressCollector = BuildProgressCollector()

        let bundleURL = try await builder.build(configuration: config) { step, progress, message in
            progressCollector.append(step: step, progress: progress, message: message)
        }

        // Verify bundle was created
        XCTAssertTrue(FileManager.default.fileExists(atPath: bundleURL.path))

        // Verify manifest exists
        let manifestURL = bundleURL.appendingPathComponent("manifest.json")
        XCTAssertTrue(FileManager.default.fileExists(atPath: manifestURL.path))

        // Verify genome files exist
        let genomeDir = bundleURL.appendingPathComponent("genome")
        XCTAssertTrue(FileManager.default.fileExists(atPath: genomeDir.path))

        // Verify progress was reported
        let progressUpdates = progressCollector.values
        XCTAssertFalse(progressUpdates.isEmpty)

        // Verify final progress is complete
        if let lastUpdate = progressUpdates.last {
            XCTAssertEqual(lastUpdate.0, .complete)
            XCTAssertEqual(lastUpdate.1, 1.0, accuracy: 0.01)
        } else {
            XCTFail("No progress updates received")
        }
    }

    @MainActor
    func testBuildCancellation() async throws {
        let builder = ReferenceBundleBuilder()

        // Create a test FASTA file
        let fastaURL = tempDirectory.appendingPathComponent("test.fa")
        let fastaContent = """
        >chr1
        ATCGATCGATCGATCGATCGATCGATCGATCGATCGATCGATCGATCGATCG
        """
        try fastaContent.write(to: fastaURL, atomically: true, encoding: .utf8)

        let outputDir = tempDirectory.appendingPathComponent("output")

        let config = BuildConfiguration(
            name: "Test",
            identifier: "test",
            fastaURL: fastaURL,
            outputDirectory: outputDir,
            source: SourceInfo(organism: "Test", assembly: "v1")
        )

        // Cancel immediately
        builder.cancel()

        do {
            _ = try await builder.build(configuration: config)
            // Build might complete before cancellation takes effect
        } catch let error as BundleBuildError {
            if case .cancelled = error {
                // Expected
            }
        }
    }

    @MainActor
    func testBuildWithAnnotations() async throws {
        let builder = ReferenceBundleBuilder()

        // Create test files
        let fastaURL = tempDirectory.appendingPathComponent("test.fa")
        try ">chr1\nATCG".write(to: fastaURL, atomically: true, encoding: .utf8)

        let gffURL = tempDirectory.appendingPathComponent("genes.gff3")
        let gffContent = """
        ##gff-version 3
        chr1\t.\tgene\t1\t100\t.\t+\t.\tID=gene1;Name=TestGene
        """
        try gffContent.write(to: gffURL, atomically: true, encoding: .utf8)

        let outputDir = tempDirectory.appendingPathComponent("output")

        let config = BuildConfiguration(
            name: "Test",
            identifier: "test",
            fastaURL: fastaURL,
            annotationFiles: [
                AnnotationInput(url: gffURL, name: "Genes", annotationType: .gene)
            ],
            outputDirectory: outputDir,
            source: SourceInfo(organism: "Test", assembly: "v1"),
            compressFASTA: false
        )

        let bundleURL = try await builder.build(configuration: config)

        // Verify annotations directory was created
        let annotationsDir = bundleURL.appendingPathComponent("annotations")
        XCTAssertTrue(FileManager.default.fileExists(atPath: annotationsDir.path))

        // Verify annotation file exists (as .bb placeholder)
        let annotationFile = annotationsDir.appendingPathComponent("genes.bb")
        XCTAssertTrue(FileManager.default.fileExists(atPath: annotationFile.path))
    }

    @MainActor
    func testBuildWithVariants() async throws {
        let builder = ReferenceBundleBuilder()

        // Create test files
        let fastaURL = tempDirectory.appendingPathComponent("test.fa")
        try ">chr1\nATCG".write(to: fastaURL, atomically: true, encoding: .utf8)

        let vcfURL = tempDirectory.appendingPathComponent("variants.vcf")
        let vcfContent = """
        ##fileformat=VCFv4.2
        #CHROM\tPOS\tID\tREF\tALT\tQUAL\tFILTER\tINFO
        chr1\t10\t.\tA\tG\t100\tPASS\t.
        """
        try vcfContent.write(to: vcfURL, atomically: true, encoding: .utf8)

        let outputDir = tempDirectory.appendingPathComponent("output")

        let config = BuildConfiguration(
            name: "Test",
            identifier: "test",
            fastaURL: fastaURL,
            variantFiles: [
                VariantInput(url: vcfURL, name: "SNPs", variantType: .snp)
            ],
            outputDirectory: outputDir,
            source: SourceInfo(organism: "Test", assembly: "v1"),
            compressFASTA: false
        )

        let bundleURL = try await builder.build(configuration: config)

        // Verify variants directory was created
        let variantsDir = bundleURL.appendingPathComponent("variants")
        XCTAssertTrue(FileManager.default.fileExists(atPath: variantsDir.path))

        // Verify BCF file exists
        let bcfFile = variantsDir.appendingPathComponent("variants.bcf")
        XCTAssertTrue(FileManager.default.fileExists(atPath: bcfFile.path))

        // Verify index exists
        let indexFile = variantsDir.appendingPathComponent("variants.bcf.csi")
        XCTAssertTrue(FileManager.default.fileExists(atPath: indexFile.path))
    }

    // MARK: - Bundle Structure Tests

    @MainActor
    func testBundleDirectoryStructure() async throws {
        let builder = ReferenceBundleBuilder()

        let fastaURL = tempDirectory.appendingPathComponent("test.fa")
        try ">chr1\nATCG".write(to: fastaURL, atomically: true, encoding: .utf8)

        let outputDir = tempDirectory.appendingPathComponent("output")

        let config = BuildConfiguration(
            name: "Structure Test",
            identifier: "test",
            fastaURL: fastaURL,
            outputDirectory: outputDir,
            source: SourceInfo(organism: "Test", assembly: "v1"),
            compressFASTA: false
        )

        let bundleURL = try await builder.build(configuration: config)

        // Verify all required directories exist
        XCTAssertTrue(FileManager.default.fileExists(atPath: bundleURL.appendingPathComponent("genome").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: bundleURL.appendingPathComponent("annotations").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: bundleURL.appendingPathComponent("variants").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: bundleURL.appendingPathComponent("tracks").path))
    }

    @MainActor
    func testManifestContent() async throws {
        let builder = ReferenceBundleBuilder()

        let fastaURL = tempDirectory.appendingPathComponent("test.fa")
        try ">chr1\nATCGATCG\n>chr2\nGGGG".write(to: fastaURL, atomically: true, encoding: .utf8)

        let outputDir = tempDirectory.appendingPathComponent("output")

        let config = BuildConfiguration(
            name: "Manifest Test",
            identifier: "org.test.manifest",
            fastaURL: fastaURL,
            outputDirectory: outputDir,
            source: SourceInfo(
                organism: "Test Organism",
                assembly: "TestAssembly",
                database: "TestDB"
            ),
            compressFASTA: false
        )

        let bundleURL = try await builder.build(configuration: config)

        // Load and verify manifest
        let manifest = try BundleManifest.load(from: bundleURL)

        XCTAssertEqual(manifest.name, "Manifest Test")
        XCTAssertEqual(manifest.identifier, "org.test.manifest")
        XCTAssertEqual(manifest.source.organism, "Test Organism")
        XCTAssertEqual(manifest.source.assembly, "TestAssembly")
        XCTAssertEqual(manifest.genome!.chromosomes.count, 2)
        XCTAssertEqual(manifest.genome!.chromosomes[0].name, "chr1")
        XCTAssertEqual(manifest.genome!.chromosomes[1].name, "chr2")
    }
}

/// Thread-safe collector for build progress callback values
private final class BuildProgressCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var _values: [(BuildStep, Double, String)] = []

    var values: [(BuildStep, Double, String)] {
        lock.lock()
        defer { lock.unlock() }
        return _values
    }

    func append(step: BuildStep, progress: Double, message: String) {
        lock.lock()
        defer { lock.unlock() }
        _values.append((step, progress, message))
    }
}
