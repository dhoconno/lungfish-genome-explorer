// GenomeDownloadViewModelTests.swift - Unit tests for GenomeDownloadViewModel
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
@testable import LungfishApp
@testable import LungfishCore
@testable import LungfishWorkflow

/// Unit tests for ``GenomeDownloadViewModel``.
///
/// Tests cover:
/// - Initialization with default and custom dependencies
/// - Tool pre-flight validation
/// - Sendable conformance
/// - BundleBuildError cases
final class GenomeDownloadViewModelTests: XCTestCase {

    // MARK: - Initialization

    func testInitializationCreatesViewModel() {
        let viewModel = GenomeDownloadViewModel()
        XCTAssertNotNil(viewModel)
    }

    func testInitializationWithCustomNCBIService() {
        let customService = NCBIService(apiKey: "test-key-123")
        let viewModel = GenomeDownloadViewModel(ncbiService: customService)
        XCTAssertNotNil(viewModel)
    }

    func testInitializationWithCustomToolRunner() {
        let builder = GenomeDownloadBundleBuilder(toolRunner: NativeToolRunner.shared)
        let viewModel = GenomeDownloadViewModel(builder: builder)
        XCTAssertNotNil(viewModel)
    }

    func testInitializationWithAllCustomDependencies() {
        let builder = GenomeDownloadBundleBuilder(ncbiService: NCBIService(), toolRunner: NativeToolRunner.shared)
        let viewModel = GenomeDownloadViewModel(builder: builder)
        XCTAssertNotNil(viewModel)
    }

    // MARK: - Sendable Conformance

    func testViewModelCanBeSentAcrossIsolationBoundaries() async {
        let viewModel = GenomeDownloadViewModel()

        // If GenomeDownloadViewModel were not Sendable, this would produce a
        // compiler diagnostic under strict concurrency checking.
        let returned = await Task.detached {
            return viewModel
        }.value

        XCTAssertNotNil(returned)
    }

    // MARK: - Tool Pre-flight Validation

    func testValidateToolsDoesNotThrowWhenToolsAvailable() async throws {
        // If tools are present in the build, validation should succeed.
        // This test may fail on machines without tools, which is expected.
        let viewModel = GenomeDownloadViewModel()
        do {
            try await viewModel.validateTools()
        } catch let error as BundleBuildError {
            // Only missingTools is acceptable here
            switch error {
            case .missingTools(let names):
                // Expected on machines missing required native tools
                XCTAssertFalse(names.isEmpty, "Missing tools list should not be empty")
            default:
                XCTFail("Unexpected BundleBuildError: \(error)")
            }
        }
    }

    // MARK: - BundleBuildError Cases

    func testMissingToolsErrorDescription() {
        let error = BundleBuildError.missingTools(["bgzip", "samtools"])
        XCTAssertTrue(error.errorDescription?.contains("bgzip") ?? false)
        XCTAssertTrue(error.errorDescription?.contains("samtools") ?? false)
    }

    func testMissingToolsRecoverySuggestion() {
        let error = BundleBuildError.missingTools(["bgzip"])
        XCTAssertNotNil(error.recoverySuggestion)
        XCTAssertTrue(error.recoverySuggestion?.contains("reinstall") ?? false)
    }

    func testMissingToolsSingleTool() {
        let error = BundleBuildError.missingTools(["samtools"])
        XCTAssertEqual(error.errorDescription, "Required tools are missing: samtools")
    }

    func testCompressionFailedError() {
        let error = BundleBuildError.compressionFailed("bgzip exited with code 1")
        XCTAssertTrue(error.errorDescription?.contains("compression") ?? false)
    }

    func testIndexingFailedError() {
        let error = BundleBuildError.indexingFailed("samtools faidx failed")
        XCTAssertTrue(error.errorDescription?.contains("indexing") ?? false)
    }

    func testValidationFailedError() {
        let error = BundleBuildError.validationFailed(["Missing genome", "No chromosomes"])
        XCTAssertTrue(error.errorDescription?.contains("Missing genome") ?? false)
        XCTAssertTrue(error.errorDescription?.contains("No chromosomes") ?? false)
    }

    func testCancelledError() {
        let error = BundleBuildError.cancelled
        XCTAssertEqual(error.errorDescription, "Build was cancelled")
    }

    // MARK: - Assembly Report Parsing

    /// Sample NCBI assembly report content for testing.
    private static let sampleAssemblyReport = """
    # Assembly name:  Callithrix_jacchus_cj1700_1.1
    # Organism name:  Callithrix jacchus (white-tufted-ear marmoset)
    # Taxid:          9483
    # Assembly method: FALCON v. 1.7.5
    # Genome coverage: 40.0x
    # Sequencing technology: PacBio; Illumina
    #
    # Sequence-Name\tSequence-Role\tAssigned-Molecule\tAssigned-Molecule-Location/Type\tGenBank-Accn\tRelationship\tRefSeq-Accn\tAssembly-Unit\tSequence-Length\tUCSC-style-name
    chr1\tassembled-molecule\t1\tChromosome\tCM018917.1\t=\tNC_048383.1\tPrimary Assembly\t217961735\tna
    chr10\tassembled-molecule\t10\tChromosome\tCM018926.1\t=\tNC_048392.1\tPrimary Assembly\t137671225\tna
    chrX\tassembled-molecule\tX\tChromosome\tCM018939.1\t=\tNC_048405.1\tPrimary Assembly\t148168104\tna
    chrMT\tassembled-molecule\tMT\tMitochondrion\tAY612638.1\t=\tNC_005358.1\tnon-nuclear\t16499\tna
    random_chr1_000743F_qpd_obj\tunlocalized-scaffold\t1\tChromosome\tWJHW01000571.1\t=\tNW_023264044.1\tPrimary Assembly\t52620\tna
    Super-Scaffold_100045\tunplaced-scaffold\tna\tna\tML767168.1\t=\tNW_023264967.1\tPrimary Assembly\t1542166\tna
    """

    func testParseAssemblyReportEntries() throws {
        let tempFile = FileManager.default.temporaryDirectory.appendingPathComponent("test_report.txt")
        try Self.sampleAssemblyReport.write(to: tempFile, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: tempFile) }

        let entries = try BundleBuildHelpers.parseAssemblyReport(at: tempFile)
        XCTAssertEqual(entries.count, 6)

        // Check chr1 entry
        let chr1 = entries[0]
        XCTAssertEqual(chr1.sequenceName, "chr1")
        XCTAssertEqual(chr1.sequenceRole, "assembled-molecule")
        XCTAssertEqual(chr1.assignedMolecule, "1")
        XCTAssertEqual(chr1.moleculeType, "Chromosome")
        XCTAssertEqual(chr1.genBankAccession, "CM018917.1")
        XCTAssertEqual(chr1.refSeqAccession, "NC_048383.1")
        XCTAssertEqual(chr1.sequenceLength, 217961735)
        XCTAssertNil(chr1.ucscName) // "na" should become nil

        // Check MT entry
        let mt = entries[3]
        XCTAssertEqual(mt.assignedMolecule, "MT")
        XCTAssertEqual(mt.moleculeType, "Mitochondrion")

        // Check unplaced scaffold
        let unplaced = entries[5]
        XCTAssertEqual(unplaced.sequenceRole, "unplaced-scaffold")
        XCTAssertEqual(unplaced.assignedMolecule, "na")
    }

    func testParseAssemblyReportHeader() throws {
        let tempFile = FileManager.default.temporaryDirectory.appendingPathComponent("test_report_hdr.txt")
        try Self.sampleAssemblyReport.write(to: tempFile, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: tempFile) }

        let items = try BundleBuildHelpers.parseAssemblyReportHeader(at: tempFile)

        // Should extract key metadata from # header lines
        let labels = items.map(\.label)
        XCTAssertTrue(labels.contains("Assembly name"))
        XCTAssertTrue(labels.contains("Organism name"))
        XCTAssertTrue(labels.contains("Assembly method"))
        XCTAssertTrue(labels.contains("Genome coverage"))
        XCTAssertTrue(labels.contains("Sequencing technology"))

        // Check specific values
        let assemblyName = items.first(where: { $0.label == "Assembly name" })
        XCTAssertEqual(assemblyName?.value, "Callithrix_jacchus_cj1700_1.1")
    }

    func testAugmentChromosomesWithAssemblyReport() throws {
        let tempFile = FileManager.default.temporaryDirectory.appendingPathComponent("test_report_aug.txt")
        try Self.sampleAssemblyReport.write(to: tempFile, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: tempFile) }

        let entries = try BundleBuildHelpers.parseAssemblyReport(at: tempFile)

        // Create chromosomes as they'd come from parseFai (RefSeq names, no aliases)
        let chromosomes = [
            ChromosomeInfo(name: "NC_048383.1", length: 217961735, offset: 0, lineBases: 80, lineWidth: 81),
            ChromosomeInfo(name: "NC_048392.1", length: 137671225, offset: 100, lineBases: 80, lineWidth: 81),
            ChromosomeInfo(name: "NC_048405.1", length: 148168104, offset: 200, lineBases: 80, lineWidth: 81),
            ChromosomeInfo(name: "NC_005358.1", length: 16499, offset: 300, lineBases: 80, lineWidth: 81),
            ChromosomeInfo(name: "NW_023264044.1", length: 52620, offset: 400, lineBases: 80, lineWidth: 81),
            ChromosomeInfo(name: "UNMATCHED_SCAFFOLD", length: 1000, offset: 500, lineBases: 80, lineWidth: 81),
        ]

        let augmented = BundleBuildHelpers.augmentChromosomesWithAssemblyReport(chromosomes, report: entries)
        XCTAssertEqual(augmented.count, 6)

        // NC_048383.1 should get aliases "1", "chr1", "CM018917.1"
        let chr1 = augmented[0]
        XCTAssertEqual(chr1.name, "NC_048383.1") // Name unchanged
        XCTAssertTrue(chr1.aliases.contains("1"), "Should have simple number alias")
        XCTAssertTrue(chr1.aliases.contains("chr1"), "Should have chr-prefixed alias")
        XCTAssertTrue(chr1.aliases.contains("CM018917.1"), "Should have GenBank alias")
        XCTAssertTrue(chr1.isPrimary)
        XCTAssertFalse(chr1.isMitochondrial)

        // NC_048392.1 should get aliases "10", "chr10", "CM018926.1"
        let chr10 = augmented[1]
        XCTAssertTrue(chr10.aliases.contains("10"))
        XCTAssertTrue(chr10.aliases.contains("chr10"))
        XCTAssertTrue(chr10.aliases.contains("CM018926.1"))

        // NC_048405.1 should get aliases "X", "chrX", "CM018939.1"
        let chrX = augmented[2]
        XCTAssertTrue(chrX.aliases.contains("X"))
        XCTAssertTrue(chrX.aliases.contains("chrX"))

        // MT should be flagged as mitochondrial
        let mt = augmented[3]
        XCTAssertTrue(mt.isMitochondrial)
        XCTAssertTrue(mt.aliases.contains("MT"))
        XCTAssertTrue(mt.aliases.contains("chrMT"))

        // Unlocalized scaffold should NOT be primary and should NOT get molecule-number aliases
        let unlocalized = augmented[4]
        XCTAssertFalse(unlocalized.isPrimary)
        XCTAssertFalse(unlocalized.aliases.contains("1"), "Scaffold should not get parent chromosome number as alias")
        XCTAssertFalse(unlocalized.aliases.contains("chr1"), "Scaffold should not get parent chr-prefixed alias")
        // But it should still get its own accession aliases
        XCTAssertTrue(unlocalized.aliases.contains("WJHW01000571.1"), "Scaffold should have GenBank alias")
        XCTAssertTrue(unlocalized.aliases.contains("random_chr1_000743F_qpd_obj"), "Scaffold should have sequence name alias")

        // Unmatched scaffold should pass through unchanged
        let unmatched = augmented[5]
        XCTAssertEqual(unmatched.name, "UNMATCHED_SCAFFOLD")
        XCTAssertTrue(unmatched.aliases.isEmpty)
    }

    func testAugmentedAliasesExcludeOwnName() throws {
        let tempFile = FileManager.default.temporaryDirectory.appendingPathComponent("test_report_self.txt")
        try Self.sampleAssemblyReport.write(to: tempFile, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: tempFile) }

        let entries = try BundleBuildHelpers.parseAssemblyReport(at: tempFile)
        let chromosomes = [
            ChromosomeInfo(name: "NC_048383.1", length: 217961735, offset: 0, lineBases: 80, lineWidth: 81),
        ]

        let augmented = BundleBuildHelpers.augmentChromosomesWithAssemblyReport(chromosomes, report: entries)
        // The chromosome's own name should NOT appear in its aliases
        XCTAssertFalse(augmented[0].aliases.contains("NC_048383.1"))
    }
}
