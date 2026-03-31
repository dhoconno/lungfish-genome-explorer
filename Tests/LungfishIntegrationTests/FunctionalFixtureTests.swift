// FunctionalFixtureTests.swift — Functional tests using SARS-CoV-2 fixture data
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// These tests exercise parsing, indexing, and round-tripping of real genomic
// files using the nf-core SARS-CoV-2 test dataset (~85 KB total).
//
// Every format the app supports should have at least one test here to catch
// regressions in I/O, rendering, and CLI operations.

import Compression
import XCTest
@testable import LungfishCore
@testable import LungfishIO

/// Functional tests that parse, index, and round-trip real genomic files.
///
/// These use the shared SARS-CoV-2 fixtures from `Tests/Fixtures/sarscov2/`.
/// Each test verifies that a specific file format can be read end-to-end
/// without network access or external tools.
@MainActor
final class FunctionalFixtureTests: XCTestCase {

    var tempDirectory: URL!

    override func setUp() async throws {
        try await super.setUp()
        tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("LungfishFixtureTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: tempDirectory,
            withIntermediateDirectories: true
        )
    }

    override func tearDown() async throws {
        if let tempDir = tempDirectory {
            try? FileManager.default.removeItem(at: tempDir)
        }
        try await super.tearDown()
    }

    // MARK: - FASTA

    func testFASTAParsing() throws {
        let url = TestFixtures.sarscov2.reference
        let data = try String(contentsOf: url, encoding: .utf8)

        // Should have a single sequence header
        let headers = data.components(separatedBy: "\n").filter { $0.hasPrefix(">") }
        XCTAssertEqual(headers.count, 1, "SARS-CoV-2 reference should have exactly 1 sequence")
        XCTAssertTrue(headers[0].contains("MT192765.1"), "Should be MT192765.1 accession")

        // Genome should be ~29-30 kb
        let sequence = data.components(separatedBy: "\n")
            .filter { !$0.hasPrefix(">") && !$0.isEmpty }
            .joined()
        XCTAssertGreaterThan(sequence.count, 29000, "SARS-CoV-2 genome should be ~30 kb")
        XCTAssertLessThan(sequence.count, 31000, "SARS-CoV-2 genome should be ~30 kb")
    }

    func testFASTAIndex() throws {
        let url = TestFixtures.sarscov2.referenceIndex
        let content = try String(contentsOf: url, encoding: .utf8)
        let fields = content.trimmingCharacters(in: .whitespacesAndNewlines)
            .components(separatedBy: "\t")

        // FAI format: name, length, offset, linebases, linewidth
        XCTAssertGreaterThanOrEqual(fields.count, 5, "FAI should have at least 5 tab-separated fields")
        XCTAssertEqual(fields[0], "MT192765.1", "Should index MT192765.1")
    }

    // MARK: - FASTQ

    func testFASTQGzipReading() throws {
        let r1 = TestFixtures.sarscov2.fastqR1
        let r2 = TestFixtures.sarscov2.fastqR2

        // Verify both files exist and are non-empty gzip
        let r1Data = try Data(contentsOf: r1)
        let r2Data = try Data(contentsOf: r2)

        // Gzip magic bytes: 1f 8b
        XCTAssertEqual(r1Data[0], 0x1f, "R1 should be gzipped")
        XCTAssertEqual(r1Data[1], 0x8b, "R1 should be gzipped")
        XCTAssertEqual(r2Data[0], 0x1f, "R2 should be gzipped")
        XCTAssertEqual(r2Data[1], 0x8b, "R2 should be gzipped")

        XCTAssertGreaterThan(r1Data.count, 1000, "R1 should have substantial content")
        XCTAssertGreaterThan(r2Data.count, 1000, "R2 should have substantial content")
    }

    // MARK: - VCF

    func testVCFParsing() throws {
        let url = TestFixtures.sarscov2.vcf
        let content = try String(contentsOf: url, encoding: .utf8)
        let lines = content.components(separatedBy: "\n")

        // Should have header lines
        let headerLines = lines.filter { $0.hasPrefix("#") }
        XCTAssertGreaterThan(headerLines.count, 0, "VCF should have header lines")

        // Should have a ##fileformat line
        XCTAssertTrue(
            headerLines.contains(where: { $0.hasPrefix("##fileformat=VCF") }),
            "VCF should declare format version"
        )

        // Should have #CHROM header
        XCTAssertTrue(
            headerLines.contains(where: { $0.hasPrefix("#CHROM") }),
            "VCF should have column header"
        )

        // Should have variant records
        let dataLines = lines.filter { !$0.hasPrefix("#") && !$0.isEmpty }
        XCTAssertGreaterThan(dataLines.count, 0, "VCF should have variant records")

        // All variants should be on MT192765.1
        for line in dataLines {
            XCTAssertTrue(line.hasPrefix("MT192765.1\t"), "Variants should reference MT192765.1")
        }
    }

    func testVCFGzipAndTabix() throws {
        let vcfGz = TestFixtures.sarscov2.vcfGz
        let tbi = TestFixtures.sarscov2.vcfTbi

        let vcfData = try Data(contentsOf: vcfGz)
        let tbiData = try Data(contentsOf: tbi)

        // VCF.gz should be bgzipped (also starts with gzip magic)
        XCTAssertEqual(vcfData[0], 0x1f, "VCF.gz should be bgzipped")
        XCTAssertEqual(vcfData[1], 0x8b, "VCF.gz should be bgzipped")

        // TBI should exist and be non-empty
        XCTAssertGreaterThan(tbiData.count, 0, "Tabix index should be non-empty")
    }

    // MARK: - BAM

    func testBAMFileStructure() throws {
        let bam = TestFixtures.sarscov2.sortedBam
        let bai = TestFixtures.sarscov2.bamIndex

        let bamData = try Data(contentsOf: bam)
        let baiData = try Data(contentsOf: bai)

        // BAM files are BGZF — same gzip magic
        XCTAssertEqual(bamData[0], 0x1f, "BAM should start with gzip magic byte 1")
        XCTAssertEqual(bamData[1], 0x8b, "BAM should start with gzip magic byte 2")
        XCTAssertGreaterThan(bamData.count, 1000, "BAM should have substantial content")

        // BAI should exist
        XCTAssertGreaterThan(baiData.count, 0, "BAI index should be non-empty")
    }

    // MARK: - BED

    func testBEDParsing() throws {
        let url = TestFixtures.sarscov2.bed
        let content = try String(contentsOf: url, encoding: .utf8)
        let lines = content.components(separatedBy: "\n").filter { !$0.isEmpty }

        XCTAssertGreaterThan(lines.count, 0, "BED should have records")

        for line in lines {
            let fields = line.components(separatedBy: "\t")
            XCTAssertGreaterThanOrEqual(fields.count, 3, "BED records need at least 3 fields")
            XCTAssertEqual(fields[0], "MT192765.1", "BED records should reference MT192765.1")

            // chromStart and chromEnd should be valid integers
            XCTAssertNotNil(Int(fields[1]), "chromStart should be an integer")
            XCTAssertNotNil(Int(fields[2]), "chromEnd should be an integer")

            // chromEnd > chromStart
            if let start = Int(fields[1]), let end = Int(fields[2]) {
                XCTAssertGreaterThan(end, start, "chromEnd should be > chromStart")
            }
        }
    }

    // MARK: - GFF3

    func testGFF3Parsing() throws {
        let url = TestFixtures.sarscov2.gff3
        let content = try String(contentsOf: url, encoding: .utf8)
        let lines = content.components(separatedBy: "\n")

        let dataLines = lines.filter { !$0.hasPrefix("#") && !$0.isEmpty }
        XCTAssertGreaterThan(dataLines.count, 0, "GFF3 should have feature records")

        // Should contain known SARS-CoV-2 genes
        let geneNames = dataLines.joined(separator: "\n")
        XCTAssertTrue(
            geneNames.contains("orf1ab") || geneNames.contains("ORF1ab"),
            "GFF3 should contain orf1ab gene"
        )
    }

    // MARK: - GTF

    func testGTFParsing() throws {
        let url = TestFixtures.sarscov2.gtf
        let content = try String(contentsOf: url, encoding: .utf8)
        let lines = content.components(separatedBy: "\n")

        let dataLines = lines.filter { !$0.hasPrefix("#") && !$0.isEmpty }
        XCTAssertGreaterThan(dataLines.count, 0, "GTF should have feature records")

        // GTF has 9 tab-delimited fields
        for line in dataLines.prefix(5) {
            let fields = line.components(separatedBy: "\t")
            XCTAssertEqual(fields.count, 9, "GTF records should have exactly 9 fields")
        }
    }

    // MARK: - Cross-Format Consistency

    func testFixturesAreInternallyConsistent() throws {
        // The reference name used across all files should match
        let fai = try String(contentsOf: TestFixtures.sarscov2.referenceIndex, encoding: .utf8)
        let refName = fai.components(separatedBy: "\t").first ?? ""
        XCTAssertEqual(refName, "MT192765.1")

        // VCF variants should reference the same chromosome
        let vcf = try String(contentsOf: TestFixtures.sarscov2.vcf, encoding: .utf8)
        let vcfChroms = vcf.components(separatedBy: "\n")
            .filter { !$0.hasPrefix("#") && !$0.isEmpty }
            .compactMap { $0.components(separatedBy: "\t").first }
        let uniqueChroms = Set(vcfChroms)
        XCTAssertEqual(uniqueChroms, ["MT192765.1"], "VCF should only reference MT192765.1")

        // BED should reference the same chromosome
        let bed = try String(contentsOf: TestFixtures.sarscov2.bed, encoding: .utf8)
        let bedChroms = bed.components(separatedBy: "\n")
            .filter { !$0.isEmpty }
            .compactMap { $0.components(separatedBy: "\t").first }
        let uniqueBedChroms = Set(bedChroms)
        XCTAssertEqual(uniqueBedChroms, ["MT192765.1"], "BED should only reference MT192765.1")
    }

    // MARK: - Paired-End FASTQ Consistency

    /// Verifies that R1 and R2 FASTQ files have the same number of reads.
    ///
    /// Paired-end data requires one-to-one correspondence between forward
    /// and reverse reads. A mismatch indicates truncation or corruption.
    func testFASTQPairedEndConsistency() async throws {
        let reader = FASTQReader(validateSequence: false)

        var r1Count = 0
        for try await _ in reader.records(from: TestFixtures.sarscov2.fastqR1) {
            r1Count += 1
        }

        var r2Count = 0
        for try await _ in reader.records(from: TestFixtures.sarscov2.fastqR2) {
            r2Count += 1
        }

        XCTAssertGreaterThan(r1Count, 0, "R1 should have at least one read")
        XCTAssertEqual(r1Count, r2Count,
                       "Paired-end R1 (\(r1Count) reads) and R2 (\(r2Count) reads) must have the same count")
    }

    // MARK: - VCF Variant Positions Within Genome

    /// Verifies that all VCF variant positions fall within the genome length from the FAI index.
    func testVCFVariantPositionsWithinGenome() throws {
        // Parse genome length from FAI
        let faiContent = try String(contentsOf: TestFixtures.sarscov2.referenceIndex, encoding: .utf8)
        let faiFields = faiContent.trimmingCharacters(in: .whitespacesAndNewlines)
            .components(separatedBy: "\t")
        guard faiFields.count >= 2, let genomeLength = Int(faiFields[1]) else {
            XCTFail("Could not parse genome length from FAI index")
            return
        }
        XCTAssertGreaterThan(genomeLength, 0, "Genome length should be positive")

        // Parse variant positions from VCF
        let vcfContent = try String(contentsOf: TestFixtures.sarscov2.vcf, encoding: .utf8)
        let dataLines = vcfContent.components(separatedBy: "\n")
            .filter { !$0.hasPrefix("#") && !$0.isEmpty }

        XCTAssertGreaterThan(dataLines.count, 0, "VCF should have variant records")

        for line in dataLines {
            let fields = line.components(separatedBy: "\t")
            guard fields.count >= 2, let position = Int(fields[1]) else {
                XCTFail("Could not parse VCF position from line: \(line.prefix(80))")
                continue
            }
            // VCF positions are 1-based
            XCTAssertGreaterThanOrEqual(position, 1,
                                        "VCF position should be >= 1 (1-based)")
            XCTAssertLessThanOrEqual(position, genomeLength,
                                     "VCF position \(position) exceeds genome length \(genomeLength)")
        }
    }

    // MARK: - BAM Reference Matches FASTA

    /// Verifies that the BAM file references the same chromosome as the FASTA reference.
    ///
    /// BAM files are BGZF-compressed. This test decompresses the first BGZF block
    /// to access the BAM header, which contains reference sequence names as
    /// null-terminated strings in the binary header dictionary.
    func testBAMReferenceMatchesFASTA() throws {
        // Get the expected reference name from FAI
        let faiContent = try String(contentsOf: TestFixtures.sarscov2.referenceIndex, encoding: .utf8)
        let expectedRefName = faiContent.components(separatedBy: "\t").first ?? ""
        XCTAssertEqual(expectedRefName, "MT192765.1", "Precondition: FAI ref name")

        // Read the BAM file and decompress the first BGZF block.
        // BGZF format: gzip header (18 bytes with BGZF extra field), then DEFLATE data.
        let bamData = try Data(contentsOf: TestFixtures.sarscov2.sortedBam)

        // Parse the BGZF block: skip 18-byte gzip+extra header to get to DEFLATE data.
        // BGZF extra field at offset 10: SI1=66('B'), SI2=67('C'), SLEN=2, BSIZE=uint16
        guard bamData.count > 18 else {
            XCTFail("BAM file too small")
            return
        }

        // Read BSIZE from the extra field (uint16 LE at offset 16-17)
        let bsize = Int(bamData[16]) | (Int(bamData[17]) << 8)
        // Compressed data starts at offset 18, ends at bsize - 7 (before CRC32+ISIZE)
        let cDataEnd = bsize - 7  // -8 for CRC32+ISIZE, but bsize is 0-based so -7
        guard cDataEnd > 18, cDataEnd < bamData.count else {
            XCTFail("Invalid BGZF block size")
            return
        }
        let compressedBlock = bamData[18...cDataEnd]

        // Decompress using the Compression framework (ZLIB = raw DEFLATE with zlib header,
        // but BGZF uses raw DEFLATE without zlib header)
        let srcSize = compressedBlock.count
        let dstSize = 65536  // BAM header is typically small
        let dstBuffer = UnsafeMutablePointer<UInt8>.allocate(capacity: dstSize)
        defer { dstBuffer.deallocate() }

        let decompressed = compressedBlock.withUnsafeBytes { srcPtr -> Data? in
            guard let baseAddress = srcPtr.baseAddress?.assumingMemoryBound(to: UInt8.self) else {
                return nil
            }
            let written = compression_decode_buffer(
                dstBuffer, dstSize,
                baseAddress, srcSize,
                nil,
                COMPRESSION_ZLIB
            )
            guard written > 0 else { return nil }
            return Data(bytes: dstBuffer, count: written)
        }

        guard let headerData = decompressed else {
            XCTFail("Could not decompress first BGZF block")
            return
        }

        // Search for the reference name in the decompressed header
        let refNameData = expectedRefName.data(using: .utf8)!
        let containsRef = headerData.range(of: refNameData) != nil
        XCTAssertTrue(containsRef,
                      "Decompressed BAM header should contain reference sequence name MT192765.1")
    }
}
