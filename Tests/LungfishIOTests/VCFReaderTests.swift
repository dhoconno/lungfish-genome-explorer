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

    // MARK: - Real-World VCF v4.2 File Test

    func testRealWorldVCFv42File() async throws {
        // Comprehensive VCF 4.2 test with multiple chromosomes, samples, and variant types
        let vcf = """
        ##fileformat=VCFv4.2
        ##fileDate=20260202
        ##source=LungfishGenomeBrowserTest
        ##reference=TestSequence1
        ##contig=<ID=TestSequence1,length=1000>
        ##contig=<ID=Chromosome1,length=500>
        ##contig=<ID=Chromosome2,length=400>
        ##contig=<ID=LargeChromosome1,length=10000>
        ##INFO=<ID=DP,Number=1,Type=Integer,Description="Total Depth">
        ##INFO=<ID=AF,Number=A,Type=Float,Description="Allele Frequency">
        ##INFO=<ID=NS,Number=1,Type=Integer,Description="Number of Samples With Data">
        ##INFO=<ID=DB,Number=0,Type=Flag,Description="dbSNP membership">
        ##INFO=<ID=TYPE,Number=A,Type=String,Description="Variant type: SNP, INS, DEL, MNP">
        ##INFO=<ID=GENE,Number=1,Type=String,Description="Gene name">
        ##INFO=<ID=EFFECT,Number=1,Type=String,Description="Predicted effect">
        ##FILTER=<ID=q10,Description="Quality below 10">
        ##FILTER=<ID=s50,Description="Less than 50% of samples have data">
        ##FILTER=<ID=LowCov,Description="Low coverage (DP<10)">
        ##FORMAT=<ID=GT,Number=1,Type=String,Description="Genotype">
        ##FORMAT=<ID=GQ,Number=1,Type=Integer,Description="Genotype Quality">
        ##FORMAT=<ID=DP,Number=1,Type=Integer,Description="Read Depth">
        ##FORMAT=<ID=AD,Number=R,Type=Integer,Description="Allelic depths">
        ##FORMAT=<ID=PL,Number=G,Type=Integer,Description="Phred-scaled likelihoods">
        #CHROM\tPOS\tID\tREF\tALT\tQUAL\tFILTER\tINFO\tFORMAT\tSample1\tSample2\tSample3
        TestSequence1\t50\trs001\tA\tG\t99\tPASS\tDP=150;AF=0.35;NS=3;TYPE=SNP;GENE=testGeneA;EFFECT=synonymous\tGT:GQ:DP:AD:PL\t0/1:99:52:30,22:255,0,255\t0/0:99:48:48,0:0,144,255\t0/1:99:50:28,22:255,0,255
        TestSequence1\t125\trs002\tC\tT\t85\tPASS\tDP=120;AF=0.25;NS=3;TYPE=SNP;GENE=testGeneA;EFFECT=missense\tGT:GQ:DP:AD:PL\t0/1:85:42:32,10:120,0,255\t0/0:99:38:38,0:0,114,255\t0/1:80:40:30,10:110,0,255
        TestSequence1\t350\trs004\tAT\tA\t60\tPASS\tDP=90;AF=0.2;NS=3;TYPE=DEL;GENE=testGeneA;EFFECT=frameshift\tGT:GQ:DP:AD:PL\t0/0:99:30:30,0:0,90,255\t0/1:60:28:22,6:100,0,200\t0/0:99:32:32,0:0,96,255
        TestSequence1\t450\trs005\tG\tGT\t55\tPASS\tDP=85;AF=0.15;NS=3;TYPE=INS;GENE=testGeneA;EFFECT=frameshift\tGT:GQ:DP:AD:PL\t0/0:99:28:28,0:0,84,255\t0/0:99:27:27,0:0,81,255\t0/1:55:30:25,5:90,0,200
        TestSequence1\t750\trs007\tC\tG\t45\tq10\tDP=50;AF=0.1;NS=3;TYPE=SNP;GENE=testGeneB;EFFECT=intergenic\tGT:GQ:DP:AD:PL\t0/0:45:18:18,0:0,54,200\t0/0:40:15:15,0:0,45,180\t0/1:35:17:15,2:50,0,170
        TestSequence1\t900\trs008\tA\tT\t30\tLowCov\tDP=8;AF=0.5;NS=2;TYPE=SNP;EFFECT=intergenic\tGT:GQ:DP:AD:PL\t0/1:30:4:2,2:50,0,50\t./.:.:0:0,0:0,0,0\t0/1:25:4:2,2:45,0,45
        Chromosome1\t100\trs009\tG\tA\t95\tPASS\tDP=130;AF=0.3;NS=3;TYPE=SNP;GENE=chr1Gene1;EFFECT=missense\tGT:GQ:DP:AD:PL\t0/1:95:45:32,13:180,0,255\t0/0:99:42:42,0:0,126,255\t0/1:90:43:30,13:175,0,255
        Chromosome2\t75\trs012\tA\tG\t92\tPASS\tDP=135;AF=0.45;NS=3;TYPE=SNP;GENE=chr2Gene1;EFFECT=missense\tGT:GQ:DP:AD:PL\t0/1:92:46:25,21:200,0,230\t0/1:90:44:24,20:195,0,225\t0/1:88:45:25,20:190,0,220
        """

        let url = try createTempVCF(content: vcf)
        defer { try? FileManager.default.removeItem(at: url) }

        let reader = VCFReader()

        // Test header parsing
        let header = try await reader.readHeader(from: url)
        XCTAssertEqual(header.fileFormat, "VCFv4.2")
        XCTAssertEqual(header.infoFields.count, 7)
        XCTAssertEqual(header.formatFields.count, 5)
        XCTAssertEqual(header.filters.count, 3)
        XCTAssertEqual(header.contigs.count, 4)
        XCTAssertEqual(header.sampleNames, ["Sample1", "Sample2", "Sample3"])
        XCTAssertEqual(header.contigs["TestSequence1"], 1000)
        XCTAssertEqual(header.contigs["LargeChromosome1"], 10000)

        // Verify INFO field definitions
        XCTAssertEqual(header.infoFields["DP"]?.type, "Integer")
        XCTAssertEqual(header.infoFields["AF"]?.type, "Float")
        XCTAssertEqual(header.infoFields["DB"]?.type, "Flag")

        // Test variant parsing
        let variants = try await reader.readAll(from: url)
        XCTAssertEqual(variants.count, 8)

        // Test first SNP (rs001)
        let rs001 = variants[0]
        XCTAssertEqual(rs001.id, "rs001")
        XCTAssertEqual(rs001.chromosome, "TestSequence1")
        XCTAssertEqual(rs001.position, 50)
        XCTAssertEqual(rs001.ref, "A")
        XCTAssertEqual(rs001.alt, ["G"])
        XCTAssertEqual(rs001.quality, 99)
        XCTAssertEqual(rs001.filter, "PASS")
        XCTAssertTrue(rs001.isSNP)
        XCTAssertTrue(rs001.isPassing)

        // Test INFO fields
        XCTAssertEqual(rs001.info["DP"], "150")
        XCTAssertEqual(rs001.info["AF"], "0.35")
        XCTAssertEqual(rs001.info["GENE"], "testGeneA")
        XCTAssertEqual(rs001.info["EFFECT"], "synonymous")
        XCTAssertEqual(rs001.info["TYPE"], "SNP")

        // Test genotypes
        XCTAssertEqual(rs001.genotypes.count, 3)
        let sample1GT = rs001.genotypes["Sample1"]!
        XCTAssertEqual(sample1GT.rawGenotype, "0/1")
        XCTAssertTrue(sample1GT.isHet)
        XCTAssertEqual(sample1GT.depth, 52)
        XCTAssertEqual(sample1GT.genotypeQuality, 99)

        let sample2GT = rs001.genotypes["Sample2"]!
        XCTAssertEqual(sample2GT.rawGenotype, "0/0")
        XCTAssertTrue(sample2GT.isHomRef)
        XCTAssertEqual(sample2GT.depth, 48)

        // Test deletion (rs004 - AT -> A)
        let deletion = variants[2]
        XCTAssertEqual(deletion.id, "rs004")
        XCTAssertEqual(deletion.ref, "AT")
        XCTAssertEqual(deletion.alt, ["A"])
        XCTAssertTrue(deletion.isIndel)
        XCTAssertEqual(deletion.info["TYPE"], "DEL")

        // Test insertion (rs005 - G -> GT)
        let insertion = variants[3]
        XCTAssertEqual(insertion.id, "rs005")
        XCTAssertEqual(insertion.ref, "G")
        XCTAssertEqual(insertion.alt, ["GT"])
        XCTAssertTrue(insertion.isIndel)
        XCTAssertEqual(insertion.info["TYPE"], "INS")

        // Test filtered variant (rs007 with q10 filter)
        let filteredVariant = variants[4]
        XCTAssertEqual(filteredVariant.id, "rs007")
        XCTAssertEqual(filteredVariant.filter, "q10")
        XCTAssertFalse(filteredVariant.isPassing)

        // Test low coverage variant (rs008 with LowCov filter)
        let lowCovVariant = variants[5]
        XCTAssertEqual(lowCovVariant.id, "rs008")
        XCTAssertEqual(lowCovVariant.filter, "LowCov")
        XCTAssertFalse(lowCovVariant.isPassing)
        // Check missing genotype (Sample2 has ./.)
        let missingSample = lowCovVariant.genotypes["Sample2"]!
        XCTAssertEqual(missingSample.rawGenotype, "./.")

        // Test variants on different chromosomes
        let chr1Variant = variants[6]
        XCTAssertEqual(chr1Variant.chromosome, "Chromosome1")
        XCTAssertEqual(chr1Variant.position, 100)

        let chr2Variant = variants[7]
        XCTAssertEqual(chr2Variant.chromosome, "Chromosome2")
        XCTAssertEqual(chr2Variant.position, 75)

        // Test conversion to annotations
        let annotations = try await reader.readAsAnnotations(from: url)
        XCTAssertEqual(annotations.count, 8)

        // SNPs should have .snp type, indels should have .variation type
        let snpAnnotations = annotations.filter { $0.type == .snp }
        let variationAnnotations = annotations.filter { $0.type == .variation }
        XCTAssertEqual(snpAnnotations.count, 6)  // 6 SNPs
        XCTAssertEqual(variationAnnotations.count, 2)  // 2 indels

        // Verify annotation coordinates are 0-based
        let firstAnnotation = annotations[0]
        XCTAssertEqual(firstAnnotation.start, 49)  // VCF position 50 -> 0-based 49
        XCTAssertEqual(firstAnnotation.name, "rs001")
    }

    // MARK: - Async Stream Test

    func testAsyncStreamVariants() async throws {
        let vcf = """
        ##fileformat=VCFv4.2
        #CHROM\tPOS\tID\tREF\tALT\tQUAL\tFILTER\tINFO
        chr1\t100\trs001\tA\tG\t99\tPASS\tDP=100
        chr1\t200\trs002\tC\tT\t85\tPASS\tDP=90
        chr1\t300\trs003\tG\tA\t75\tPASS\tDP=80
        chr2\t150\trs004\tT\tC\t95\tPASS\tDP=95
        chr2\t250\trs005\tA\tG\t88\tPASS\tDP=85
        """

        let url = try createTempVCF(content: vcf)
        defer { try? FileManager.default.removeItem(at: url) }

        let reader = VCFReader()
        var count = 0
        var positions: [Int] = []

        for try await variant in reader.variants(from: url) {
            count += 1
            positions.append(variant.position)
        }

        XCTAssertEqual(count, 5)
        XCTAssertEqual(positions, [100, 200, 300, 150, 250])
    }
}
