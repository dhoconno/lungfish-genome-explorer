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

    func testObservableBuilderDispatchesBundleWorkOffMainActor() throws {
        let sourceURL = try repoRoot()
            .appendingPathComponent("Sources/LungfishCore/Bundles/ReferenceBundleBuilder.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)

        XCTAssertTrue(
            source.contains("Task.detached"),
            "ReferenceBundleBuilder must keep UI-observable state on MainActor while dispatching file parsing/copy/index work off-main."
        )
        XCTAssertTrue(
            source.contains("ReferenceBundleBuildExecutor"),
            "Bundle file operations should live in a non-MainActor executor instead of private MainActor methods."
        )
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
        XCTAssertNotNil(BundleBuildError.outputBundleAlreadyExists(url).recoverySuggestion)
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
    func testBuildRejectsExistingOutputBundleWithoutDeletingIt() async throws {
        let builder = ReferenceBundleBuilder()

        let fastaURL = tempDirectory.appendingPathComponent("test.fa")
        try ">chr1\nATCG\n".write(to: fastaURL, atomically: true, encoding: .utf8)

        let outputDir = tempDirectory.appendingPathComponent("output")
        let existingBundleURL = outputDir.appendingPathComponent("Test.lungfishref")
        let sentinelURL = existingBundleURL.appendingPathComponent("do-not-delete.txt")
        try FileManager.default.createDirectory(at: existingBundleURL, withIntermediateDirectories: true)
        try "existing user data".write(to: sentinelURL, atomically: true, encoding: .utf8)

        let config = BuildConfiguration(
            name: "Test",
            identifier: "test",
            fastaURL: fastaURL,
            outputDirectory: outputDir,
            source: SourceInfo(organism: "Test", assembly: "v1"),
            compressFASTA: false
        )

        do {
            _ = try await builder.build(configuration: config)
            XCTFail("Expected existing output bundle to be rejected")
        } catch let error as BundleBuildError {
            guard case .outputBundleAlreadyExists(let url) = error else {
                XCTFail("Expected outputBundleAlreadyExists, got \(error)")
                return
            }
            let actualPath = url.path.hasSuffix("/") ? String(url.path.dropLast()) : url.path
            let expectedPath = existingBundleURL.path.hasSuffix("/") ? String(existingBundleURL.path.dropLast()) : existingBundleURL.path
            XCTAssertEqual(actualPath, expectedPath)
        }

        XCTAssertTrue(
            FileManager.default.fileExists(atPath: sentinelURL.path),
            "Rejecting an existing output bundle must not delete user data"
        )
        XCTAssertEqual(try String(contentsOf: sentinelURL, encoding: .utf8), "existing user data")
    }

    @MainActor
    func testBuildWithValidUncompressedFASTA() async throws {
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
            compressFASTA: false
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
    func testCoreBuilderRejectsCompressedFASTAWithoutNativeBgzip() async throws {
        let builder = ReferenceBundleBuilder()

        let fastaURL = tempDirectory.appendingPathComponent("test.fa")
        try ">chr1\nATCG\n".write(to: fastaURL, atomically: true, encoding: .utf8)

        let outputDir = tempDirectory.appendingPathComponent("output")
        let config = BuildConfiguration(
            name: "Compressed Test",
            identifier: "compressed.test",
            fastaURL: fastaURL,
            outputDirectory: outputDir,
            source: SourceInfo(organism: "Test", assembly: "v1"),
            compressFASTA: true
        )

        do {
            _ = try await builder.build(configuration: config)
            XCTFail("Expected Core builder to reject bgzip compression without native tools")
        } catch let error as BundleBuildError {
            guard case .compressionFailed(let reason) = error else {
                XCTFail("Expected compressionFailed, got \(error)")
                return
            }
            XCTAssertTrue(reason.contains("NativeBundleBuilder"))
            XCTAssertTrue(reason.contains("bgzip"))
        }
    }

    @MainActor
    func testCoreBuilderRejectsProvenanceConfigurationWithoutCreatingBundle() async throws {
        let builder = ReferenceBundleBuilder()

        let fastaURL = tempDirectory.appendingPathComponent("test.fa")
        try ">chr1\nATCG\n".write(to: fastaURL, atomically: true, encoding: .utf8)

        let outputDir = tempDirectory.appendingPathComponent("output")
        let expectedBundleURL = outputDir.appendingPathComponent("Provenance_Test.lungfishref")
        let config = BuildConfiguration(
            name: "Provenance Test",
            identifier: "provenance.test",
            fastaURL: fastaURL,
            outputDirectory: outputDir,
            source: SourceInfo(organism: "Test", assembly: "v1"),
            compressFASTA: false,
            provenanceWorkflowName: "test provenance"
        )

        do {
            _ = try await builder.build(configuration: config)
            XCTFail("Expected Core builder to reject provenance-bearing configurations")
        } catch let error as BundleBuildError {
            guard case .unsupportedProvenanceConfiguration(let reason) = error else {
                XCTFail("Expected unsupportedProvenanceConfiguration, got \(error)")
                return
            }
            XCTAssertTrue(reason.contains("cannot write provenance"))
        }

        XCTAssertFalse(FileManager.default.fileExists(atPath: expectedBundleURL.path))
    }

    @MainActor
    func testCancellingParentTaskCancelsDetachedBuildWork() async throws {
        let builder = ReferenceBundleBuilder()

        let fastaURL = tempDirectory.appendingPathComponent("large.fa")
        let fastaContent = ">chr1\n" + String(
            repeating: "ATCGATCGATCGATCGATCGATCGATCGATCGATCGATCGATCGATCG\n",
            count: 50_000
        )
        try fastaContent.write(to: fastaURL, atomically: true, encoding: .utf8)

        let outputDir = tempDirectory.appendingPathComponent("output")
        let expectedBundleURL = outputDir.appendingPathComponent("Cancellation_Test.lungfishref")
        let config = BuildConfiguration(
            name: "Cancellation Test",
            identifier: "cancellation.test",
            fastaURL: fastaURL,
            outputDirectory: outputDir,
            source: SourceInfo(organism: "Test", assembly: "v1"),
            compressFASTA: false
        )

        let buildStarted = expectation(description: "build started")
        buildStarted.assertForOverFulfill = false

        let task = Task { @MainActor in
            try await builder.build(configuration: config) { step, _, _ in
                if step == .creatingStructure {
                    buildStarted.fulfill()
                }
            }
        }

        await fulfillment(of: [buildStarted], timeout: 2.0)
        task.cancel()

        do {
            _ = try await task.value
            XCTFail("Expected parent cancellation to cancel detached bundle work")
        } catch let error as BundleBuildError {
            guard case .cancelled = error else {
                XCTFail("Expected cancelled error, got \(error)")
                return
            }
        }

        XCTAssertFalse(FileManager.default.fileExists(atPath: expectedBundleURL.path))
    }

    @MainActor
    func testFASTAIndexUsesExactCRLFByteOffsets() async throws {
        let builder = ReferenceBundleBuilder()

        let fastaURL = tempDirectory.appendingPathComponent("crlf.fa")
        let fastaBytes = Data(">chr1\r\nACGT\r\nACGT\r\n>chr2\r\nNN\r\n".utf8)
        try fastaBytes.write(to: fastaURL)

        let outputDir = tempDirectory.appendingPathComponent("output")
        let config = BuildConfiguration(
            name: "CRLF Test",
            identifier: "crlf.test",
            fastaURL: fastaURL,
            outputDirectory: outputDir,
            source: SourceInfo(organism: "Test", assembly: "v1"),
            compressFASTA: false
        )

        let bundleURL = try await builder.build(configuration: config)
        let indexURL = bundleURL.appendingPathComponent("genome/sequence.fa.fai")
        let index = try String(contentsOf: indexURL, encoding: .utf8)

        XCTAssertEqual(index, "chr1\t8\t7\t4\t6\nchr2\t2\t26\t2\t4\n")
    }

    @MainActor
    func testFASTAIndexUsesSamtoolsWidthForSingleLineWithoutTrailingNewline() async throws {
        let builder = ReferenceBundleBuilder()

        let fastaURL = tempDirectory.appendingPathComponent("single-line.fa")
        try Data(">chr1\nACGT".utf8).write(to: fastaURL)

        let outputDir = tempDirectory.appendingPathComponent("output")
        let config = BuildConfiguration(
            name: "Single Line Test",
            identifier: "single-line.test",
            fastaURL: fastaURL,
            outputDirectory: outputDir,
            source: SourceInfo(organism: "Test", assembly: "v1"),
            compressFASTA: false
        )

        let bundleURL = try await builder.build(configuration: config)
        let indexURL = bundleURL.appendingPathComponent("genome/sequence.fa.fai")
        let index = try String(contentsOf: indexURL, encoding: .utf8)

        XCTAssertEqual(index, "chr1\t4\t6\t4\t5\n")
    }

    @MainActor
    func testFASTAIndexRejectsInconsistentInternalLineWidths() async throws {
        let builder = ReferenceBundleBuilder()

        let fastaURL = tempDirectory.appendingPathComponent("ragged.fa")
        try Data(">chr1\nACGT\nAC\nACGT\n".utf8).write(to: fastaURL)

        let outputDir = tempDirectory.appendingPathComponent("output")
        let expectedBundleURL = outputDir.appendingPathComponent("Ragged_Test.lungfishref")
        let config = BuildConfiguration(
            name: "Ragged Test",
            identifier: "ragged.test",
            fastaURL: fastaURL,
            outputDirectory: outputDir,
            source: SourceInfo(organism: "Test", assembly: "v1"),
            compressFASTA: false
        )

        do {
            _ = try await builder.build(configuration: config)
            XCTFail("Expected ragged internal FASTA line to be rejected")
        } catch let error as BundleBuildError {
            guard case .invalidFASTAFormat(let message) = error else {
                XCTFail("Expected invalidFASTAFormat, got \(error)")
                return
            }
            XCTAssertTrue(message.contains("Inconsistent sequence line"))
        }

        XCTAssertFalse(FileManager.default.fileExists(atPath: expectedBundleURL.path))
    }

    @MainActor
    func testFASTAIndexRejectsMixedInternalNewlineWidths() async throws {
        let builder = ReferenceBundleBuilder()

        let fastaURL = tempDirectory.appendingPathComponent("mixed-newlines.fa")
        try Data(">chr1\r\nACGT\r\nACGT\nACGT\r\n".utf8).write(to: fastaURL)

        let outputDir = tempDirectory.appendingPathComponent("output")
        let expectedBundleURL = outputDir.appendingPathComponent("Mixed_Newlines_Test.lungfishref")
        let config = BuildConfiguration(
            name: "Mixed Newlines Test",
            identifier: "mixed-newlines.test",
            fastaURL: fastaURL,
            outputDirectory: outputDir,
            source: SourceInfo(organism: "Test", assembly: "v1"),
            compressFASTA: false
        )

        do {
            _ = try await builder.build(configuration: config)
            XCTFail("Expected mixed internal newline widths to be rejected")
        } catch let error as BundleBuildError {
            guard case .invalidFASTAFormat(let message) = error else {
                XCTFail("Expected invalidFASTAFormat, got \(error)")
                return
            }
            XCTAssertTrue(message.contains("Inconsistent sequence line"))
        }

        XCTAssertFalse(FileManager.default.fileExists(atPath: expectedBundleURL.path))
    }

    @MainActor
    func testFASTAIndexRejectsBlankLineBeforeMoreSequence() async throws {
        let builder = ReferenceBundleBuilder()

        let fastaURL = tempDirectory.appendingPathComponent("blank-before-sequence.fa")
        try Data(">chr1\nACGT\n\nACGT\n".utf8).write(to: fastaURL)

        let outputDir = tempDirectory.appendingPathComponent("output")
        let expectedBundleURL = outputDir.appendingPathComponent("Blank_Sequence_Test.lungfishref")
        let config = BuildConfiguration(
            name: "Blank Sequence Test",
            identifier: "blank-sequence.test",
            fastaURL: fastaURL,
            outputDirectory: outputDir,
            source: SourceInfo(organism: "Test", assembly: "v1"),
            compressFASTA: false
        )

        do {
            _ = try await builder.build(configuration: config)
            XCTFail("Expected blank line before more sequence to be rejected")
        } catch let error as BundleBuildError {
            guard case .invalidFASTAFormat(let message) = error else {
                XCTFail("Expected invalidFASTAFormat, got \(error)")
                return
            }
            XCTAssertTrue(message.contains("Blank FASTA line"))
        }

        XCTAssertFalse(FileManager.default.fileExists(atPath: expectedBundleURL.path))
    }

    @MainActor
    func testFASTAIndexRejectsWhitespaceOnlyLineBeforeMoreSequence() async throws {
        let builder = ReferenceBundleBuilder()

        let fastaURL = tempDirectory.appendingPathComponent("whitespace-before-sequence.fa")
        try Data(">chr1\nACGT\n \t \nACGT\n".utf8).write(to: fastaURL)

        let outputDir = tempDirectory.appendingPathComponent("output")
        let expectedBundleURL = outputDir.appendingPathComponent("Whitespace_Sequence_Test.lungfishref")
        let config = BuildConfiguration(
            name: "Whitespace Sequence Test",
            identifier: "whitespace-sequence.test",
            fastaURL: fastaURL,
            outputDirectory: outputDir,
            source: SourceInfo(organism: "Test", assembly: "v1"),
            compressFASTA: false
        )

        do {
            _ = try await builder.build(configuration: config)
            XCTFail("Expected whitespace-only line before more sequence to be rejected")
        } catch let error as BundleBuildError {
            guard case .invalidFASTAFormat(let message) = error else {
                XCTFail("Expected invalidFASTAFormat, got \(error)")
                return
            }
            XCTAssertTrue(message.contains("Blank FASTA line"))
        }

        XCTAssertFalse(FileManager.default.fileExists(atPath: expectedBundleURL.path))
    }

    @MainActor
    func testFASTAIndexAllowsBlankLinesAtRecordBoundaries() async throws {
        let builder = ReferenceBundleBuilder()

        let fastaURL = tempDirectory.appendingPathComponent("boundary-blanks.fa")
        try Data("\n>chr1\nACGT\n\n>chr2\nNN\n\n".utf8).write(to: fastaURL)

        let outputDir = tempDirectory.appendingPathComponent("output")
        let config = BuildConfiguration(
            name: "Boundary Blanks Test",
            identifier: "boundary-blanks.test",
            fastaURL: fastaURL,
            outputDirectory: outputDir,
            source: SourceInfo(organism: "Test", assembly: "v1"),
            compressFASTA: false
        )

        let bundleURL = try await builder.build(configuration: config)
        let indexURL = bundleURL.appendingPathComponent("genome/sequence.fa.fai")
        let index = try String(contentsOf: indexURL, encoding: .utf8)

        XCTAssertEqual(index, "chr1\t4\t7\t4\t5\nchr2\t2\t19\t2\t3\n")
    }

    @MainActor
    func testFASTAIndexRejectsFinalLineWiderThanIndexedLineWidth() async throws {
        let builder = ReferenceBundleBuilder()

        let fastaURL = tempDirectory.appendingPathComponent("wide-final.fa")
        try Data(">chr1\nACGT\nACGT\r\n".utf8).write(to: fastaURL)

        let outputDir = tempDirectory.appendingPathComponent("output")
        let expectedBundleURL = outputDir.appendingPathComponent("Wide_Final_Test.lungfishref")
        let config = BuildConfiguration(
            name: "Wide Final Test",
            identifier: "wide-final.test",
            fastaURL: fastaURL,
            outputDirectory: outputDir,
            source: SourceInfo(organism: "Test", assembly: "v1"),
            compressFASTA: false
        )

        do {
            _ = try await builder.build(configuration: config)
            XCTFail("Expected final line wider than indexed width to be rejected")
        } catch let error as BundleBuildError {
            guard case .invalidFASTAFormat(let message) = error else {
                XCTFail("Expected invalidFASTAFormat, got \(error)")
                return
            }
            XCTAssertTrue(message.contains("Final sequence line"))
        }

        XCTAssertFalse(FileManager.default.fileExists(atPath: expectedBundleURL.path))
    }

    @MainActor
    func testFASTAIndexRejectsHeaderOnlyRecords() async throws {
        let builder = ReferenceBundleBuilder()

        let fastaURL = tempDirectory.appendingPathComponent("empty-record.fa")
        try Data(">chr1\n>chr2\nNN\n".utf8).write(to: fastaURL)

        let outputDir = tempDirectory.appendingPathComponent("output")
        let expectedBundleURL = outputDir.appendingPathComponent("Empty_Record_Test.lungfishref")
        let config = BuildConfiguration(
            name: "Empty Record Test",
            identifier: "empty-record.test",
            fastaURL: fastaURL,
            outputDirectory: outputDir,
            source: SourceInfo(organism: "Test", assembly: "v1"),
            compressFASTA: false
        )

        do {
            _ = try await builder.build(configuration: config)
            XCTFail("Expected header-only FASTA record to be rejected")
        } catch let error as BundleBuildError {
            guard case .invalidFASTAFormat(let message) = error else {
                XCTFail("Expected invalidFASTAFormat, got \(error)")
                return
            }
            XCTAssertTrue(message.contains("no sequence"))
        }

        XCTAssertFalse(FileManager.default.fileExists(atPath: expectedBundleURL.path))
    }

    @MainActor
    func testFASTAIndexRejectsCROnlyLineEndings() async throws {
        let builder = ReferenceBundleBuilder()

        let fastaURL = tempDirectory.appendingPathComponent("cr-only.fa")
        try Data(">chr1\rACGT\r".utf8).write(to: fastaURL)

        let outputDir = tempDirectory.appendingPathComponent("output")
        let expectedBundleURL = outputDir.appendingPathComponent("CR_Only_Test.lungfishref")
        let config = BuildConfiguration(
            name: "CR Only Test",
            identifier: "cr-only.test",
            fastaURL: fastaURL,
            outputDirectory: outputDir,
            source: SourceInfo(organism: "Test", assembly: "v1"),
            compressFASTA: false
        )

        do {
            _ = try await builder.build(configuration: config)
            XCTFail("Expected CR-only FASTA line endings to be rejected")
        } catch let error as BundleBuildError {
            guard case .invalidFASTAFormat(let message) = error else {
                XCTFail("Expected invalidFASTAFormat, got \(error)")
                return
            }
            XCTAssertTrue(message.contains("CR-only"))
        }

        XCTAssertFalse(FileManager.default.fileExists(atPath: expectedBundleURL.path))
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

        // Verify annotation file keeps its source format instead of pretending to be BigBed.
        let annotationFile = annotationsDir.appendingPathComponent("genes.gff3")
        XCTAssertTrue(FileManager.default.fileExists(atPath: annotationFile.path))
    }

    @MainActor
    func testBuildWithHeaderOnlyGFF3KeepsManifestEntryAndNotesNoAnnotations() async throws {
        let builder = ReferenceBundleBuilder()

        let fastaURL = tempDirectory.appendingPathComponent("test.fa")
        try ">chr1\nATCG\n".write(to: fastaURL, atomically: true, encoding: .utf8)

        let gffURL = tempDirectory.appendingPathComponent("empty.gff3")
        try "##gff-version 3\n".write(to: gffURL, atomically: true, encoding: .utf8)

        let outputDir = tempDirectory.appendingPathComponent("output")
        let config = BuildConfiguration(
            name: "Empty Annotation Test",
            identifier: "empty.annotation.test",
            fastaURL: fastaURL,
            annotationFiles: [
                AnnotationInput(url: gffURL, name: "Empty annotations", annotationType: .gene)
            ],
            outputDirectory: outputDir,
            source: SourceInfo(organism: "Test", assembly: "v1"),
            compressFASTA: false
        )

        let bundleURL = try await builder.build(configuration: config)
        let manifest = try BundleManifest.load(from: bundleURL)
        let track = try XCTUnwrap(manifest.annotations.first)

        XCTAssertEqual(track.featureCount, 0)
        XCTAssertEqual(track.description, "No annotations found in source GFF3")
        XCTAssertTrue(FileManager.default.fileExists(atPath: bundleURL.appendingPathComponent(track.path).path))
    }

    @MainActor
    func testBuildWithGzippedAnnotationDoesNotFabricateFeatureCountOrDescription() async throws {
        let builder = ReferenceBundleBuilder()

        let fastaURL = tempDirectory.appendingPathComponent("test.fa")
        try ">chr1\nATCG\n".write(to: fastaURL, atomically: true, encoding: .utf8)

        let gffURL = tempDirectory.appendingPathComponent("genes.gff3.gz")
        try Data([0x1f, 0x8b, 0x08, 0x00, 0x00, 0x00, 0x00, 0x00]).write(to: gffURL)

        let outputDir = tempDirectory.appendingPathComponent("output")
        let config = BuildConfiguration(
            name: "Compressed Annotation Test",
            identifier: "compressed.annotation.test",
            fastaURL: fastaURL,
            annotationFiles: [
                AnnotationInput(url: gffURL, name: "Compressed annotations", annotationType: .gene)
            ],
            outputDirectory: outputDir,
            source: SourceInfo(organism: "Test", assembly: "v1"),
            compressFASTA: false
        )

        let bundleURL = try await builder.build(configuration: config)
        let manifest = try BundleManifest.load(from: bundleURL)
        let track = try XCTUnwrap(manifest.annotations.first)

        XCTAssertNil(track.featureCount)
        XCTAssertNil(track.description)
        XCTAssertTrue(FileManager.default.fileExists(atPath: bundleURL.appendingPathComponent(track.path).path))
    }

    @MainActor
    func testBuildWithVariantsRequiresIndexedBCF() async throws {
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

        do {
            _ = try await builder.build(configuration: config)
            XCTFail("Expected Core builder to reject VCF-to-BCF conversion without native tools")
        } catch let error as BundleBuildError {
            guard case .variantConversionFailed(let file, let reason) = error else {
                XCTFail("Expected variantConversionFailed, got \(error)")
                return
            }
            XCTAssertEqual(file, "SNPs")
            XCTAssertTrue(reason.contains("cannot convert VCF to BCF"))
            XCTAssertTrue(reason.contains("NativeBundleBuilder"))
        }
    }

    @MainActor
    func testBuildWithIndexedBCFCopiesBCFAndCSI() async throws {
        let builder = ReferenceBundleBuilder()

        let fastaURL = tempDirectory.appendingPathComponent("test.fa")
        try ">chr1\nATCG".write(to: fastaURL, atomically: true, encoding: .utf8)

        let bcfURL = tempDirectory.appendingPathComponent("variants.bcf")
        try Data([0x42, 0x43, 0x46, 0x02, 0x02]).write(to: bcfURL)
        let csiURL = URL(fileURLWithPath: bcfURL.path + ".csi")
        try Data([0x43, 0x53, 0x49, 0x01]).write(to: csiURL)

        let outputDir = tempDirectory.appendingPathComponent("output")
        let config = BuildConfiguration(
            name: "Test",
            identifier: "test",
            fastaURL: fastaURL,
            variantFiles: [
                VariantInput(url: bcfURL, name: "SNPs", variantType: .snp)
            ],
            outputDirectory: outputDir,
            source: SourceInfo(organism: "Test", assembly: "v1"),
            compressFASTA: false
        )

        let bundleURL = try await builder.build(configuration: config)

        let bcfFile = bundleURL.appendingPathComponent("variants/variants.bcf")
        let indexFile = bundleURL.appendingPathComponent("variants/variants.bcf.csi")
        XCTAssertTrue(FileManager.default.fileExists(atPath: bcfFile.path))
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

private func repoRoot() throws -> URL {
    var directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    let fileManager = FileManager.default
    for _ in 0..<10 {
        if fileManager.fileExists(atPath: directory.appendingPathComponent("Package.swift").path) {
            return directory
        }
        directory = directory.deletingLastPathComponent()
    }
    throw XCTSkip("Could not locate Package.swift above \(#filePath)")
}
