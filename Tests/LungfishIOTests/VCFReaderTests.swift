// VCFReaderTests.swift - Tests for VCF reader
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
@testable import LungfishIO
@testable import LungfishCore

final class VCFReaderTests: XCTestCase {

    // MARK: - Test Data

    private func createTempVCF(content: String) throws -> URL {
        let tempDir = FileManager.default.temporaryDirectory
        let tempFile = tempDir.appendingPathComponent("test_\(UUID().uuidString).vcf")
        try content.write(to: tempFile, atomically: true, encoding: .utf8)
        return tempFile
    }

    // MARK: - Header Parsing

    func testReadHeader() async throws {
        let vcf = """
        ##fileformat=VCFv4.3
        ##INFO=<ID=DP,Number=1,Type=Integer,Description="Total Depth">
        ##FORMAT=<ID=GT,Number=1,Type=String,Description="Genotype">
        ##FILTER=<ID=q10,Description="Quality below 10">
        ##contig=<ID=chr1,length=248956422>
        #CHROM\tPOS\tID\tREF\tALT\tQUAL\tFILTER\tINFO
        chr1\t100\t.\tA\tG\t30\tPASS\tDP=10
        """

        let url = try createTempVCF(content: vcf)
        defer { try? FileManager.default.removeItem(at: url) }

        let reader = VCFReader()
        let header = try await reader.readHeader(from: url)

        XCTAssertEqual(header.fileFormat, "VCFv4.3")
        XCTAssertEqual(header.infoFields.count, 1)
        XCTAssertEqual(header.infoFields["DP"]?.type, "Integer")
        XCTAssertEqual(header.formatFields.count, 1)
        XCTAssertEqual(header.filters.count, 1)
        XCTAssertEqual(header.contigs["chr1"], 248956422)
    }

    // MARK: - Variant Parsing

    func testReadSNP() async throws {
        let vcf = """
        ##fileformat=VCFv4.3
        #CHROM\tPOS\tID\tREF\tALT\tQUAL\tFILTER\tINFO
        chr1\t100\trs123\tA\tG\t30\tPASS\tDP=10
        """

        let url = try createTempVCF(content: vcf)
        defer { try? FileManager.default.removeItem(at: url) }

        let reader = VCFReader()
        let variants = try await reader.readAll(from: url)

        XCTAssertEqual(variants.count, 1)
        let v = variants[0]
        XCTAssertEqual(v.chromosome, "chr1")
        XCTAssertEqual(v.position, 100)
        XCTAssertEqual(v.id, "rs123")
        XCTAssertEqual(v.ref, "A")
        XCTAssertEqual(v.alt, ["G"])
        XCTAssertEqual(v.quality, 30)
        XCTAssertEqual(v.filter, "PASS")
        XCTAssertEqual(v.info["DP"], "10")
        XCTAssertTrue(v.isSNP)
        XCTAssertTrue(v.isPassing)
    }

    func testReadIndel() async throws {
        let vcf = """
        ##fileformat=VCFv4.3
        #CHROM\tPOS\tID\tREF\tALT\tQUAL\tFILTER\tINFO
        chr1\t100\t.\tATCG\tA\t50\tPASS\t.
        """

        let url = try createTempVCF(content: vcf)
        defer { try? FileManager.default.removeItem(at: url) }

        let reader = VCFReader()
        let variants = try await reader.readAll(from: url)

        XCTAssertEqual(variants.count, 1)
        let v = variants[0]
        XCTAssertEqual(v.ref, "ATCG")
        XCTAssertEqual(v.alt, ["A"])
        XCTAssertTrue(v.isIndel)
        XCTAssertFalse(v.isSNP)
    }

    func testReadMultiAllelic() async throws {
        let vcf = """
        ##fileformat=VCFv4.3
        #CHROM\tPOS\tID\tREF\tALT\tQUAL\tFILTER\tINFO
        chr1\t100\t.\tA\tG,T,C\t30\tPASS\t.
        """

        let url = try createTempVCF(content: vcf)
        defer { try? FileManager.default.removeItem(at: url) }

        let reader = VCFReader()
        let variants = try await reader.readAll(from: url)

        XCTAssertEqual(variants.count, 1)
        let v = variants[0]
        XCTAssertEqual(v.alt, ["G", "T", "C"])
        XCTAssertTrue(v.isMultiAllelic)
    }

    func testReadMultipleVariants() async throws {
        let vcf = """
        ##fileformat=VCFv4.3
        #CHROM\tPOS\tID\tREF\tALT\tQUAL\tFILTER\tINFO
        chr1\t100\t.\tA\tG\t30\tPASS\t.
        chr1\t200\t.\tC\tT\t40\tPASS\t.
        chr2\t300\t.\tG\tA\t50\tPASS\t.
        """

        let url = try createTempVCF(content: vcf)
        defer { try? FileManager.default.removeItem(at: url) }

        let reader = VCFReader()
        let variants = try await reader.readAll(from: url)

        XCTAssertEqual(variants.count, 3)
        XCTAssertEqual(variants[0].position, 100)
        XCTAssertEqual(variants[1].position, 200)
        XCTAssertEqual(variants[2].chromosome, "chr2")
    }

    // MARK: - INFO Field Parsing

    func testParseInfoFields() async throws {
        let vcf = """
        ##fileformat=VCFv4.3
        #CHROM\tPOS\tID\tREF\tALT\tQUAL\tFILTER\tINFO
        chr1\t100\t.\tA\tG\t30\tPASS\tDP=10;AF=0.5;DB
        """

        let url = try createTempVCF(content: vcf)
        defer { try? FileManager.default.removeItem(at: url) }

        let reader = VCFReader()
        let variants = try await reader.readAll(from: url)

        let v = variants[0]
        XCTAssertEqual(v.info["DP"], "10")
        XCTAssertEqual(v.info["AF"], "0.5")
        XCTAssertEqual(v.info["DB"], "true")  // Flag field
    }

    // MARK: - Genotype Parsing

    func testReadGenotypes() async throws {
        let vcf = """
        ##fileformat=VCFv4.3
        #CHROM\tPOS\tID\tREF\tALT\tQUAL\tFILTER\tINFO\tFORMAT\tSAMPLE1\tSAMPLE2
        chr1\t100\t.\tA\tG\t30\tPASS\t.\tGT:DP:GQ\t0/1:20:30\t1/1:15:25
        """

        let url = try createTempVCF(content: vcf)
        defer { try? FileManager.default.removeItem(at: url) }

        let reader = VCFReader()
        let variants = try await reader.readAll(from: url)

        let v = variants[0]
        XCTAssertEqual(v.genotypes.count, 2)

        let gt1 = v.genotypes["SAMPLE1"]!
        XCTAssertEqual(gt1.rawGenotype, "0/1")
        XCTAssertTrue(gt1.isHet)
        XCTAssertEqual(gt1.depth, 20)
        XCTAssertEqual(gt1.genotypeQuality, 30)

        let gt2 = v.genotypes["SAMPLE2"]!
        XCTAssertEqual(gt2.rawGenotype, "1/1")
        XCTAssertTrue(gt2.isHomAlt)
    }

    func testPhasedGenotype() async throws {
        let vcf = """
        ##fileformat=VCFv4.3
        #CHROM\tPOS\tID\tREF\tALT\tQUAL\tFILTER\tINFO\tFORMAT\tSAMPLE1
        chr1\t100\t.\tA\tG\t30\tPASS\t.\tGT\t0|1
        """

        let url = try createTempVCF(content: vcf)
        defer { try? FileManager.default.removeItem(at: url) }

        let reader = VCFReader()
        let variants = try await reader.readAll(from: url)

        let gt = variants[0].genotypes["SAMPLE1"]!
        XCTAssertTrue(gt.isPhased)
        XCTAssertEqual(gt.alleleIndices, [0, 1])
    }

    // MARK: - Filter Status

    func testFilterStatus() async throws {
        let vcf = """
        ##fileformat=VCFv4.3
        #CHROM\tPOS\tID\tREF\tALT\tQUAL\tFILTER\tINFO
        chr1\t100\t.\tA\tG\t30\tPASS\t.
        chr1\t200\t.\tC\tT\t5\tLowQual\t.
        chr1\t300\t.\tG\tA\t.\t.\t.
        """

        let url = try createTempVCF(content: vcf)
        defer { try? FileManager.default.removeItem(at: url) }

        let reader = VCFReader()
        let variants = try await reader.readAll(from: url)

        XCTAssertTrue(variants[0].isPassing)
        XCTAssertFalse(variants[1].isPassing)
        XCTAssertTrue(variants[2].isPassing)  // "." means passing
    }

    // MARK: - Conversion to Annotation

    func testToAnnotation() async throws {
        let vcf = """
        ##fileformat=VCFv4.3
        #CHROM\tPOS\tID\tREF\tALT\tQUAL\tFILTER\tINFO
        chr1\t100\trs123\tA\tG\t30\tPASS\tDP=10
        """

        let url = try createTempVCF(content: vcf)
        defer { try? FileManager.default.removeItem(at: url) }

        let reader = VCFReader()
        let annotations = try await reader.readAsAnnotations(from: url)

        XCTAssertEqual(annotations.count, 1)
        let ann = annotations[0]
        XCTAssertEqual(ann.type, .snp)
        XCTAssertEqual(ann.name, "rs123")
        XCTAssertEqual(ann.start, 99)  // 0-based
    }

    // MARK: - Error Handling

    func testMissingHeaderThrows() async throws {
        let vcf = """
        chr1\t100\t.\tA\tG\t30\tPASS\t.
        """

        let url = try createTempVCF(content: vcf)
        defer { try? FileManager.default.removeItem(at: url) }

        let reader = VCFReader()

        do {
            _ = try await reader.readAll(from: url)
            XCTFail("Expected error")
        } catch VCFError.missingHeader {
            // Expected
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testInvalidLineFormatThrows() async throws {
        let vcf = """
        ##fileformat=VCFv4.3
        #CHROM\tPOS\tID\tREF\tALT\tQUAL\tFILTER\tINFO
        chr1\t100\tA
        """

        let url = try createTempVCF(content: vcf)
        defer { try? FileManager.default.removeItem(at: url) }

        let reader = VCFReader()

        do {
            _ = try await reader.readAll(from: url)
            XCTFail("Expected error")
        } catch VCFError.invalidLineFormat {
            // Expected
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }
}
