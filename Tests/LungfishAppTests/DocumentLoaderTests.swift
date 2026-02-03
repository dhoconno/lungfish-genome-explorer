// DocumentLoaderTests.swift - Tests for background document loading
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
@testable import LungfishCore
@testable import LungfishIO
@testable import LungfishApp

/// Tests for DocumentLoader three-phase loading architecture.
///
/// Tests verify:
/// 1. Phase 1: Fast folder scanning without file content parsing
/// 2. Phase 2: Placeholder document creation
/// 3. Phase 3: Background file loading with DocumentLoader
final class DocumentLoaderTests: XCTestCase {

    // MARK: - Test Fixtures

    private var tempDir: URL!

    override func setUpWithError() throws {
        // Create temp directory for test files
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("DocumentLoaderTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        // Clean up temp directory
        if let tempDir = tempDir {
            try? FileManager.default.removeItem(at: tempDir)
        }
    }

    // MARK: - FileScanResult Tests

    func testFileScanResultIsSendable() throws {
        // FileScanResult must be Sendable for safe cross-actor transfer
        let url = tempDir.appendingPathComponent("test.fa")
        let result = FileScanResult(url: url, type: .fasta)

        // Transfer across actor boundary to verify Sendable conformance
        Task.detached {
            let _ = result.url
            let _ = result.type
        }

        XCTAssertEqual(result.url, url)
        XCTAssertEqual(result.type, .fasta)
    }

    func testFileLoadResultIsSendable() throws {
        // FileLoadResult must be Sendable for safe cross-actor transfer
        let url = tempDir.appendingPathComponent("test.fa")
        let seq = try Sequence(name: "Test", alphabet: .dna, bases: "ATCG")
        let result = FileLoadResult(url: url, type: .fasta, sequences: [seq])

        // Transfer across actor boundary to verify Sendable conformance
        Task.detached {
            let _ = result.url
            let _ = result.type
            let _ = result.sequences
        }

        XCTAssertEqual(result.url, url)
        XCTAssertEqual(result.sequences.count, 1)
        XCTAssertNil(result.error)
    }

    // MARK: - Folder Scan Tests

    func testScanFolderFindsFASTAFiles() throws {
        // Create test FASTA file
        let fastaURL = tempDir.appendingPathComponent("test.fa")
        try ">seq1\nATCG\n".write(to: fastaURL, atomically: true, encoding: .utf8)

        let results = try DocumentLoader.scanFolder(at: tempDir)

        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results.first?.type, .fasta)
        // Compare paths to handle symlink differences (/var vs /private/var)
        XCTAssertEqual(results.first?.url.lastPathComponent, fastaURL.lastPathComponent)
    }

    func testScanFolderFindsGenBankFiles() throws {
        // Create test GenBank file
        let gbURL = tempDir.appendingPathComponent("test.gb")
        let gbContent = """
        LOCUS       Test                       4 bp    DNA     linear   UNK 01-JAN-2024
        DEFINITION  Test sequence
        ORIGIN
                1 atcg
        //
        """
        try gbContent.write(to: gbURL, atomically: true, encoding: .utf8)

        let results = try DocumentLoader.scanFolder(at: tempDir)

        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results.first?.type, .genbank)
    }

    func testScanFolderFindsMixedFormats() throws {
        // Create multiple file types
        let fastaURL = tempDir.appendingPathComponent("seq.fa")
        try ">seq1\nATCG\n".write(to: fastaURL, atomically: true, encoding: .utf8)

        let gffURL = tempDir.appendingPathComponent("annot.gff3")
        try "##gff-version 3\n".write(to: gffURL, atomically: true, encoding: .utf8)

        let bedURL = tempDir.appendingPathComponent("regions.bed")
        try "chr1\t100\t200\tgene1\n".write(to: bedURL, atomically: true, encoding: .utf8)

        let results = try DocumentLoader.scanFolder(at: tempDir)

        XCTAssertEqual(results.count, 3)

        let types = Set(results.map { $0.type })
        XCTAssertTrue(types.contains(.fasta))
        XCTAssertTrue(types.contains(.gff3))
        XCTAssertTrue(types.contains(.bed))
    }

    func testScanFolderIgnoresUnsupportedFiles() throws {
        // Create unsupported file types
        let txtURL = tempDir.appendingPathComponent("readme.txt")
        try "This is a readme".write(to: txtURL, atomically: true, encoding: .utf8)

        let jsonURL = tempDir.appendingPathComponent("config.json")
        try "{}".write(to: jsonURL, atomically: true, encoding: .utf8)

        // Create supported file
        let fastaURL = tempDir.appendingPathComponent("test.fa")
        try ">seq1\nATCG\n".write(to: fastaURL, atomically: true, encoding: .utf8)

        let results = try DocumentLoader.scanFolder(at: tempDir)

        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results.first?.type, .fasta)
    }

    func testScanFolderFindsFilesInSubfolders() throws {
        // Create subfolder with files
        let subfolder = tempDir.appendingPathComponent("sequences")
        try FileManager.default.createDirectory(at: subfolder, withIntermediateDirectories: true)

        let fastaURL = subfolder.appendingPathComponent("test.fa")
        try ">seq1\nATCG\n".write(to: fastaURL, atomically: true, encoding: .utf8)

        let results = try DocumentLoader.scanFolder(at: tempDir)

        XCTAssertEqual(results.count, 1)
        // Compare paths to handle symlink differences
        XCTAssertEqual(results.first?.url.lastPathComponent, fastaURL.lastPathComponent)
        XCTAssertTrue(results.first?.url.path.contains("sequences") ?? false)
    }

    func testScanFolderSkipsHiddenFiles() throws {
        // Create hidden file (should be skipped)
        let hiddenURL = tempDir.appendingPathComponent(".hidden.fa")
        try ">seq1\nATCG\n".write(to: hiddenURL, atomically: true, encoding: .utf8)

        // Create visible file
        let visibleURL = tempDir.appendingPathComponent("visible.fa")
        try ">seq2\nGCTA\n".write(to: visibleURL, atomically: true, encoding: .utf8)

        let results = try DocumentLoader.scanFolder(at: tempDir)

        XCTAssertEqual(results.count, 1)
        // Compare paths to handle symlink differences
        XCTAssertEqual(results.first?.url.lastPathComponent, visibleURL.lastPathComponent)
    }

    func testScanEmptyFolderReturnsEmpty() throws {
        let results = try DocumentLoader.scanFolder(at: tempDir)
        XCTAssertTrue(results.isEmpty)
    }

    func testScanNonexistentFolderThrows() {
        let badURL = tempDir.appendingPathComponent("nonexistent")

        XCTAssertThrowsError(try DocumentLoader.scanFolder(at: badURL)) { error in
            XCTAssertTrue(error is DocumentLoadError)
        }
    }

    // MARK: - File Loading Tests

    func testLoadFASTAFile() async throws {
        // Create test FASTA
        let fastaURL = tempDir.appendingPathComponent("test.fa")
        try ">seq1\nATCGATCG\n>seq2\nGCTAGCTA\n".write(to: fastaURL, atomically: true, encoding: .utf8)

        let result = try await DocumentLoader.loadFile(at: fastaURL, type: .fasta)

        XCTAssertEqual(result.sequences.count, 2)
        XCTAssertEqual(result.sequences[0].name, "seq1")
        XCTAssertEqual(result.sequences[1].name, "seq2")
        XCTAssertTrue(result.annotations.isEmpty)
        XCTAssertNil(result.error)
    }

    func testLoadGFF3File() async throws {
        // Create test GFF3
        let gffURL = tempDir.appendingPathComponent("test.gff3")
        let gffContent = """
        ##gff-version 3
        chr1\t.\tgene\t100\t500\t.\t+\t.\tID=gene1;Name=TestGene
        chr1\t.\tCDS\t100\t500\t.\t+\t0\tID=cds1;Parent=gene1
        """
        try gffContent.write(to: gffURL, atomically: true, encoding: .utf8)

        let result = try await DocumentLoader.loadFile(at: gffURL, type: .gff3)

        XCTAssertTrue(result.sequences.isEmpty)  // GFF3 only loads annotations
        XCTAssertEqual(result.annotations.count, 2)
        XCTAssertNil(result.error)
    }

    func testLoadBEDFile() async throws {
        // Create test BED
        let bedURL = tempDir.appendingPathComponent("test.bed")
        let bedContent = """
        chr1\t100\t500\tgene1\t100\t+
        chr1\t1000\t2000\tgene2\t200\t-
        """
        try bedContent.write(to: bedURL, atomically: true, encoding: .utf8)

        let result = try await DocumentLoader.loadFile(at: bedURL, type: .bed)

        XCTAssertTrue(result.sequences.isEmpty)
        XCTAssertEqual(result.annotations.count, 2)
        XCTAssertNil(result.error)
    }

    func testLoadVCFFile() async throws {
        // Create test VCF
        let vcfURL = tempDir.appendingPathComponent("test.vcf")
        let vcfContent = """
        ##fileformat=VCFv4.2
        #CHROM\tPOS\tID\tREF\tALT\tQUAL\tFILTER\tINFO
        chr1\t100\t.\tA\tG\t30\tPASS\t.
        """
        try vcfContent.write(to: vcfURL, atomically: true, encoding: .utf8)

        let result = try await DocumentLoader.loadFile(at: vcfURL, type: .vcf)

        XCTAssertTrue(result.sequences.isEmpty)
        XCTAssertEqual(result.annotations.count, 1)  // Variants become annotations
        XCTAssertNil(result.error)
    }

    // MARK: - Three-Phase Integration Test

    func testThreePhaseLoadingFlow() async throws {
        // Phase 1: Create mixed format folder
        let fastaURL = tempDir.appendingPathComponent("sequences.fa")
        try ">seq1\nATCGATCG\n".write(to: fastaURL, atomically: true, encoding: .utf8)

        let gffURL = tempDir.appendingPathComponent("annotations.gff3")
        try "##gff-version 3\nchr1\t.\tgene\t1\t8\t.\t+\t.\tID=gene1\n".write(to: gffURL, atomically: true, encoding: .utf8)

        // Phase 1: Fast scan (no parsing)
        let scanResults = try DocumentLoader.scanFolder(at: tempDir)
        XCTAssertEqual(scanResults.count, 2)

        // Phase 2: Would create placeholder documents (simulated)
        let placeholders = scanResults.map { scan in
            (url: scan.url, type: scan.type)
        }
        XCTAssertEqual(placeholders.count, 2)

        // Phase 3: Background loading
        var totalSequences = 0
        var totalAnnotations = 0

        for scan in scanResults {
            let result = try await DocumentLoader.loadFile(at: scan.url, type: scan.type)
            totalSequences += result.sequences.count
            totalAnnotations += result.annotations.count
        }

        XCTAssertEqual(totalSequences, 1)  // From FASTA
        XCTAssertEqual(totalAnnotations, 1)  // From GFF3
    }

    // MARK: - Performance Tests

    func testScanFolderPerformance() throws {
        // Create 100 test files
        for i in 0..<100 {
            let url = tempDir.appendingPathComponent("seq\(i).fa")
            try ">seq\(i)\nATCG\n".write(to: url, atomically: true, encoding: .utf8)
        }

        measure {
            let _ = try? DocumentLoader.scanFolder(at: tempDir)
        }
    }
}
