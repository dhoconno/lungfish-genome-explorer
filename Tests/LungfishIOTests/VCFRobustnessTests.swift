// VCFRobustnessTests.swift - Real-world VCF parsing edge cases and robustness
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
@testable import LungfishIO
@testable import LungfishCore

final class VCFRobustnessTests: XCTestCase {

    // MARK: - Helpers

    private func createTempVCF(content: String) throws -> URL {
        let tempDir = FileManager.default.temporaryDirectory
        let tempFile = tempDir.appendingPathComponent("test_\(UUID().uuidString).vcf")
        try content.write(to: tempFile, atomically: true, encoding: .utf8)
        return tempFile
    }

    private func resourceURL(_ name: String, ext: String) -> URL? {
        Bundle.module.url(forResource: name, withExtension: ext, subdirectory: "Resources")
    }

    // MARK: - Empty VCF Parsing

    func testEmptyVCFParsesWithZeroVariants() async throws {
        let vcf = """
        ##fileformat=VCFv4.0
        ##INFO=<ID=DP,Number=1,Type=Integer,Description="Raw Depth">
        ##FILTER=<ID=min_dp_10,Description="Minimum Coverage 10">
        #CHROM\tPOS\tID\tREF\tALT\tQUAL\tFILTER\tINFO
        """
        let url = try createTempVCF(content: vcf)
        defer { try? FileManager.default.removeItem(at: url) }

        let reader = VCFReader()
        let variants = try await reader.readAll(from: url)
        XCTAssertEqual(variants.count, 0)
    }

    func testEmptyVCFHeader() async throws {
        let vcf = """
        ##fileformat=VCFv4.0
        ##INFO=<ID=DP,Number=1,Type=Integer,Description="Raw Depth">
        #CHROM\tPOS\tID\tREF\tALT\tQUAL\tFILTER\tINFO
        """
        let url = try createTempVCF(content: vcf)
        defer { try? FileManager.default.removeItem(at: url) }

        let reader = VCFReader()
        let header = try await reader.readHeader(from: url)
        XCTAssertEqual(header.fileFormat, "VCFv4.0")
        XCTAssertTrue(header.sampleNames.isEmpty)
        XCTAssertEqual(header.infoFields.count, 1)
    }

    func testEmptyVCFSummary() async throws {
        let vcf = """
        ##fileformat=VCFv4.0
        ##FILTER=<ID=min_dp_10,Description="Minimum Coverage 10">
        #CHROM\tPOS\tID\tREF\tALT\tQUAL\tFILTER\tINFO
        """
        let url = try createTempVCF(content: vcf)
        defer { try? FileManager.default.removeItem(at: url) }

        let reader = VCFReader()
        let summary = try await reader.summarize(from: url)
        XCTAssertEqual(summary.variantCount, 0)
        XCTAssertTrue(summary.chromosomes.isEmpty)
        XCTAssertTrue(summary.maxPositionPerChromosome.isEmpty)
        XCTAssertTrue(summary.variantTypes.isEmpty)
        XCTAssertFalse(summary.hasSampleColumns)
        XCTAssertNil(summary.qualityStats.min)
        XCTAssertNil(summary.qualityStats.max)
        XCTAssertNil(summary.qualityStats.mean)
        XCTAssertEqual(summary.qualityStats.count, 0)
    }

    func testEmptyVCFDatabaseCreation() async throws {
        let vcf = """
        ##fileformat=VCFv4.0
        #CHROM\tPOS\tID\tREF\tALT\tQUAL\tFILTER\tINFO
        """
        let url = try createTempVCF(content: vcf)
        defer { try? FileManager.default.removeItem(at: url) }

        let dbURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("test_empty_\(UUID().uuidString).db")
        defer { try? FileManager.default.removeItem(at: dbURL) }

        let count = try VariantDatabase.createFromVCF(
            vcfURL: url, outputURL: dbURL, sourceFile: "test.vcf"
        )
        XCTAssertEqual(count, 0)

        // Database should still be valid and queryable
        let db = try VariantDatabase(url: dbURL)
        let results = try db.query(chromosome: "any", start: 0, end: 1000)
        XCTAssertEqual(results.count, 0)
    }

    // MARK: - No Sample Columns (Lofreq-style)

    func testNoSampleColumnsParseCorrectly() async throws {
        let vcf = """
        ##fileformat=VCFv4.0
        #CHROM\tPOS\tID\tREF\tALT\tQUAL\tFILTER\tINFO
        NC_045512.2\t241\t.\tC\tT\t49314\tPASS\tDP=9264;AF=0.999784;SB=0;DP4=1,1,4909,4353
        NC_045512.2\t3037\t.\tC\tT\t49314\tPASS\tDP=2727;AF=0.993399;SB=0;DP4=0,1,851,1858
        """
        let url = try createTempVCF(content: vcf)
        defer { try? FileManager.default.removeItem(at: url) }

        let reader = VCFReader()
        let variants = try await reader.readAll(from: url)
        XCTAssertEqual(variants.count, 2)
        XCTAssertTrue(variants[0].genotypes.isEmpty)
        XCTAssertTrue(variants[1].genotypes.isEmpty)
        XCTAssertEqual(variants[0].chromosome, "NC_045512.2")
        XCTAssertEqual(variants[0].position, 241)
        XCTAssertEqual(variants[0].ref, "C")
        XCTAssertEqual(variants[0].alt, ["T"])
        XCTAssertEqual(variants[0].quality, 49314)
        XCTAssertEqual(variants[0].filter, "PASS")
    }

    func testNoSampleColumnsSummary() async throws {
        let vcf = """
        ##fileformat=VCFv4.0
        #CHROM\tPOS\tID\tREF\tALT\tQUAL\tFILTER\tINFO
        NC_045512.2\t241\t.\tC\tT\t100\tPASS\tDP=50
        NC_045512.2\t3037\t.\tC\tT\t200\tPASS\tDP=100
        """
        let url = try createTempVCF(content: vcf)
        defer { try? FileManager.default.removeItem(at: url) }

        let reader = VCFReader()
        let summary = try await reader.summarize(from: url)
        XCTAssertFalse(summary.hasSampleColumns)
        XCTAssertEqual(summary.variantCount, 2)
        XCTAssertEqual(summary.chromosomes.count, 1)
        XCTAssertTrue(summary.chromosomes.contains("NC_045512.2"))
    }

    // MARK: - Lofreq INFO Field Parsing

    func testLofreqInfoFieldParsing() async throws {
        let vcf = """
        ##fileformat=VCFv4.0
        ##INFO=<ID=DP,Number=1,Type=Integer,Description="Raw Depth">
        ##INFO=<ID=AF,Number=1,Type=Float,Description="Allele Frequency">
        ##INFO=<ID=SB,Number=1,Type=Integer,Description="Phred-scaled strand bias">
        ##INFO=<ID=DP4,Number=4,Type=Integer,Description="Ref-forward, ref-reverse, alt-forward, alt-reverse">
        ##INFO=<ID=INDEL,Number=0,Type=Flag,Description="Indicates INDEL">
        ##INFO=<ID=CONSVAR,Number=0,Type=Flag,Description="Consensus variant">
        ##INFO=<ID=HRUN,Number=1,Type=Integer,Description="Homopolymer run">
        #CHROM\tPOS\tID\tREF\tALT\tQUAL\tFILTER\tINFO
        NC_045512.2\t241\t.\tC\tT\t49314\tPASS\tDP=9264;AF=0.999784;SB=0;DP4=1,1,4909,4353
        NC_045512.2\t500\t.\tAT\tA\t1000\tPASS\tDP=500;AF=0.1;INDEL;HRUN=3
        """
        let url = try createTempVCF(content: vcf)
        defer { try? FileManager.default.removeItem(at: url) }

        let reader = VCFReader()
        let variants = try await reader.readAll(from: url)

        // First variant — SNP with rich INFO
        let v1 = variants[0]
        XCTAssertEqual(v1.info["DP"], "9264")
        XCTAssertEqual(v1.info["AF"], "0.999784")
        XCTAssertEqual(v1.info["SB"], "0")
        XCTAssertEqual(v1.info["DP4"], "1,1,4909,4353")
        XCTAssertTrue(v1.isSNP)

        // Second variant — INDEL with flag fields
        let v2 = variants[1]
        XCTAssertEqual(v2.info["INDEL"], "true") // Flag fields stored as "true"
        XCTAssertEqual(v2.info["HRUN"], "3")
        XCTAssertEqual(v2.info["DP"], "500")
        XCTAssertTrue(v2.isIndel)
    }

    // MARK: - Real SARS-CoV-2 VCF Files from Test Resources

    func testRealEmptyVCFFile() async throws {
        guard let url = resourceURL("empty_sarscov2", ext: "vcf") else {
            throw XCTSkip("empty_sarscov2.vcf not in test resources")
        }

        let reader = VCFReader()
        let variants = try await reader.readAll(from: url)
        XCTAssertEqual(variants.count, 0, "NTC VCF should have 0 variants")

        let header = try await reader.readHeader(from: url)
        XCTAssertEqual(header.fileFormat, "VCFv4.0")
        XCTAssertTrue(header.sampleNames.isEmpty, "Lofreq VCF has no sample columns")
    }

    func testRealEmptyVCFSummary() async throws {
        guard let url = resourceURL("empty_sarscov2", ext: "vcf") else {
            throw XCTSkip("empty_sarscov2.vcf not in test resources")
        }

        let reader = VCFReader()
        let summary = try await reader.summarize(from: url)
        XCTAssertEqual(summary.variantCount, 0)
        XCTAssertTrue(summary.chromosomes.isEmpty)
        XCTAssertFalse(summary.hasSampleColumns)
        // Reference inference won't work with no chromosomes and no contig headers
        // (the empty VCF has no contig lines)
    }

    func testReal208VariantVCF() async throws {
        guard let url = resourceURL("sarscov2_208variants", ext: "vcf") else {
            throw XCTSkip("sarscov2_208variants.vcf not in test resources")
        }

        let reader = VCFReader()
        let variants = try await reader.readAll(from: url)
        XCTAssertEqual(variants.count, 208)

        // All variants should be on NC_045512.2
        let chroms = Set(variants.map(\.chromosome))
        XCTAssertEqual(chroms, ["NC_045512.2"])

        // Should have both SNPs and indels
        let snpCount = variants.filter(\.isSNP).count
        let indelCount = variants.filter(\.isIndel).count
        XCTAssertGreaterThan(snpCount, 0, "Should have some SNPs")
        XCTAssertGreaterThanOrEqual(indelCount, 0) // May not have indels

        // Quality should be present for all variants
        let withQuality = variants.filter { $0.quality != nil }
        XCTAssertEqual(withQuality.count, variants.count, "All lofreq variants have quality scores")

        // All should have PASS or a filter name
        let passingCount = variants.filter(\.isPassing).count
        XCTAssertGreaterThan(passingCount, 0)

        // No genotypes (lofreq)
        XCTAssertTrue(variants.allSatisfy { $0.genotypes.isEmpty })
    }

    func testReal208VariantVCFSummary() async throws {
        guard let url = resourceURL("sarscov2_208variants", ext: "vcf") else {
            throw XCTSkip("sarscov2_208variants.vcf not in test resources")
        }

        let reader = VCFReader()
        let summary = try await reader.summarize(from: url)

        XCTAssertEqual(summary.variantCount, 208)
        XCTAssertEqual(summary.chromosomes, ["NC_045512.2"])
        XCTAssertFalse(summary.hasSampleColumns)
        XCTAssertGreaterThan(summary.variantTypes["SNP"] ?? 0, 0)

        // Quality stats
        XCTAssertNotNil(summary.qualityStats.min)
        XCTAssertNotNil(summary.qualityStats.max)
        XCTAssertNotNil(summary.qualityStats.mean)
        XCTAssertEqual(summary.qualityStats.count, 208)
        XCTAssertGreaterThan(summary.qualityStats.max ?? 0, 0)

        // Max position should be near end of SARS-CoV-2 genome (29903 bp)
        let maxPos = summary.maxPositionPerChromosome["NC_045512.2"]
        XCTAssertNotNil(maxPos)
        XCTAssertGreaterThan(maxPos ?? 0, 1000)
        XCTAssertLessThanOrEqual(maxPos ?? 0, 29903)

        // Filter counts should include PASS
        XCTAssertGreaterThan(summary.filterCounts["PASS"] ?? 0, 0)
    }

    func testReal208VariantVCFReferenceInference() async throws {
        guard let url = resourceURL("sarscov2_208variants", ext: "vcf") else {
            throw XCTSkip("sarscov2_208variants.vcf not in test resources")
        }

        let reader = VCFReader()
        let summary = try await reader.summarize(from: url)

        XCTAssertNotNil(summary.inferredReference, "Should infer reference from NC_045512.2")
        XCTAssertEqual(summary.inferredReference?.assembly, "SARS-CoV-2")
        XCTAssertEqual(summary.inferredReference?.organism, "Severe acute respiratory syndrome coronavirus 2")
        XCTAssertGreaterThanOrEqual(summary.inferredReference?.confidence ?? .none, .low)
    }

    func testReal79VariantVCF() async throws {
        guard let url = resourceURL("sarscov2_79variants", ext: "vcf") else {
            throw XCTSkip("sarscov2_79variants.vcf not in test resources")
        }

        let reader = VCFReader()
        let summary = try await reader.summarize(from: url)

        XCTAssertEqual(summary.variantCount, 79)
        XCTAssertEqual(summary.chromosomes, ["NC_045512.2"])
        XCTAssertFalse(summary.hasSampleColumns)
        XCTAssertNotNil(summary.inferredReference)
        XCTAssertEqual(summary.inferredReference?.assembly, "SARS-CoV-2")
    }

    // MARK: - Variant Type Classification

    func testSNPClassification() async throws {
        let vcf = """
        ##fileformat=VCFv4.0
        #CHROM\tPOS\tID\tREF\tALT\tQUAL\tFILTER\tINFO
        chr1\t100\t.\tA\tG\t30\tPASS\t.
        """
        let url = try createTempVCF(content: vcf)
        defer { try? FileManager.default.removeItem(at: url) }

        let reader = VCFReader()
        let summary = try await reader.summarize(from: url)
        XCTAssertEqual(summary.variantTypes["SNP"], 1)
    }

    func testInsertionClassification() async throws {
        let vcf = """
        ##fileformat=VCFv4.0
        #CHROM\tPOS\tID\tREF\tALT\tQUAL\tFILTER\tINFO
        chr1\t100\t.\tA\tATCG\t30\tPASS\t.
        """
        let url = try createTempVCF(content: vcf)
        defer { try? FileManager.default.removeItem(at: url) }

        let reader = VCFReader()
        let summary = try await reader.summarize(from: url)
        XCTAssertEqual(summary.variantTypes["INS"], 1)
    }

    func testDeletionClassification() async throws {
        let vcf = """
        ##fileformat=VCFv4.0
        #CHROM\tPOS\tID\tREF\tALT\tQUAL\tFILTER\tINFO
        chr1\t100\t.\tATCG\tA\t30\tPASS\t.
        """
        let url = try createTempVCF(content: vcf)
        defer { try? FileManager.default.removeItem(at: url) }

        let reader = VCFReader()
        let summary = try await reader.summarize(from: url)
        XCTAssertEqual(summary.variantTypes["DEL"], 1)
    }

    func testMNPClassification() async throws {
        let vcf = """
        ##fileformat=VCFv4.0
        #CHROM\tPOS\tID\tREF\tALT\tQUAL\tFILTER\tINFO
        chr1\t100\t.\tAT\tGC\t30\tPASS\t.
        """
        let url = try createTempVCF(content: vcf)
        defer { try? FileManager.default.removeItem(at: url) }

        let reader = VCFReader()
        let summary = try await reader.summarize(from: url)
        XCTAssertEqual(summary.variantTypes["MNP"], 1)
    }

    // MARK: - Quality Edge Cases

    func testVCFWithMissingQuality() async throws {
        let vcf = """
        ##fileformat=VCFv4.0
        #CHROM\tPOS\tID\tREF\tALT\tQUAL\tFILTER\tINFO
        chr1\t100\t.\tA\tG\t.\tPASS\tDP=10
        """
        let url = try createTempVCF(content: vcf)
        defer { try? FileManager.default.removeItem(at: url) }

        let reader = VCFReader()
        let variants = try await reader.readAll(from: url)
        XCTAssertEqual(variants.count, 1)
        XCTAssertNil(variants[0].quality)

        let summary = try await reader.summarize(from: url)
        XCTAssertNil(summary.qualityStats.min)
        XCTAssertEqual(summary.qualityStats.count, 0)
    }

    // MARK: - Filter Edge Cases

    func testVCFWithMultipleFilterValues() async throws {
        let vcf = """
        ##fileformat=VCFv4.0
        ##FILTER=<ID=q10,Description="Quality below 10">
        ##FILTER=<ID=LowCov,Description="Low coverage">
        #CHROM\tPOS\tID\tREF\tALT\tQUAL\tFILTER\tINFO
        chr1\t100\t.\tA\tG\t5\tq10;LowCov\tDP=3
        chr1\t200\t.\tT\tC\t50\tPASS\tDP=100
        chr1\t300\t.\tG\tA\t8\tq10\tDP=5
        """
        let url = try createTempVCF(content: vcf)
        defer { try? FileManager.default.removeItem(at: url) }

        let reader = VCFReader()
        let variants = try await reader.readAll(from: url)
        XCTAssertEqual(variants.count, 3)

        // First variant has compound filter
        XCTAssertEqual(variants[0].filter, "q10;LowCov")
        XCTAssertFalse(variants[0].isPassing)

        // Second variant passes
        XCTAssertTrue(variants[1].isPassing)

        // Summary filter counts
        let summary = try await reader.summarize(from: url)
        XCTAssertEqual(summary.filterCounts["PASS"], 1)
        XCTAssertEqual(summary.filterCounts["q10;LowCov"], 1)
        XCTAssertEqual(summary.filterCounts["q10"], 1)
    }

    func testVCFWithDotFilter() async throws {
        let vcf = """
        ##fileformat=VCFv4.0
        #CHROM\tPOS\tID\tREF\tALT\tQUAL\tFILTER\tINFO
        chr1\t100\t.\tA\tG\t30\t.\tDP=10
        """
        let url = try createTempVCF(content: vcf)
        defer { try? FileManager.default.removeItem(at: url) }

        let reader = VCFReader()
        let variants = try await reader.readAll(from: url)
        XCTAssertNil(variants[0].filter) // "." → nil
        XCTAssertTrue(variants[0].isPassing) // nil filter counts as passing
    }

    // MARK: - Multi-Chromosome VCF

    func testSummaryWithMultipleChromosomes() async throws {
        let vcf = """
        ##fileformat=VCFv4.3
        #CHROM\tPOS\tID\tREF\tALT\tQUAL\tFILTER\tINFO
        chr1\t100\t.\tA\tG\t30\tPASS\t.
        chr1\t500\t.\tT\tC\t40\tPASS\t.
        chr2\t200\t.\tG\tA\t50\tPASS\t.
        chrX\t1000\t.\tC\tT\t60\tPASS\t.
        """
        let url = try createTempVCF(content: vcf)
        defer { try? FileManager.default.removeItem(at: url) }

        let reader = VCFReader()
        let summary = try await reader.summarize(from: url)

        XCTAssertEqual(summary.variantCount, 4)
        XCTAssertEqual(summary.chromosomes, ["chr1", "chr2", "chrX"])
        XCTAssertEqual(summary.maxPositionPerChromosome["chr1"], 500)
        XCTAssertEqual(summary.maxPositionPerChromosome["chr2"], 200)
        XCTAssertEqual(summary.maxPositionPerChromosome["chrX"], 1000)
    }

    // MARK: - VCF with Sample Columns

    func testVCFWithSampleColumnsDetected() async throws {
        let vcf = """
        ##fileformat=VCFv4.3
        ##FORMAT=<ID=GT,Number=1,Type=String,Description="Genotype">
        #CHROM\tPOS\tID\tREF\tALT\tQUAL\tFILTER\tINFO\tFORMAT\tSample1\tSample2
        chr1\t100\t.\tA\tG\t30\tPASS\t.\tGT\t0/1\t1/1
        """
        let url = try createTempVCF(content: vcf)
        defer { try? FileManager.default.removeItem(at: url) }

        let reader = VCFReader()
        let summary = try await reader.summarize(from: url)
        XCTAssertTrue(summary.hasSampleColumns)
        XCTAssertEqual(summary.header.sampleNames, ["Sample1", "Sample2"])
    }

    // MARK: - Batch VCF Parsing (All 50 Files)

    func testAllRealVCFsFromDownloads() async throws {
        let vcfDir = URL(fileURLWithPath: "/Users/dho/Downloads/vcfs")
        guard FileManager.default.fileExists(atPath: vcfDir.path) else {
            throw XCTSkip("VCF test directory not available")
        }

        let files = try FileManager.default.contentsOfDirectory(at: vcfDir, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "vcf" }

        XCTAssertEqual(files.count, 50, "Expected 50 VCF files in test directory")

        let reader = VCFReader()
        var emptyCount = 0
        var totalVariants = 0

        for file in files {
            // Every file should parse without error
            let summary = try await reader.summarize(from: file)

            if summary.variantCount == 0 {
                emptyCount += 1
            } else {
                // Non-empty files should all be on NC_045512.2
                XCTAssertEqual(summary.chromosomes, ["NC_045512.2"],
                    "File \(file.lastPathComponent) should only have NC_045512.2")
                XCTAssertNotNil(summary.inferredReference,
                    "File \(file.lastPathComponent) should infer SARS-CoV-2 reference")
                XCTAssertEqual(summary.inferredReference?.assembly, "SARS-CoV-2",
                    "File \(file.lastPathComponent) should be SARS-CoV-2")
            }

            // None should have sample columns (lofreq output)
            XCTAssertFalse(summary.hasSampleColumns,
                "File \(file.lastPathComponent) should not have sample columns")

            totalVariants += summary.variantCount
        }

        XCTAssertEqual(emptyCount, 2, "Expected 2 empty VCFs (NTC and FCGAGM3WR5DS362E)")
        XCTAssertGreaterThan(totalVariants, 1000, "Should have >1000 variants across all files")
    }

    // MARK: - Annotation Conversion

    func testEmptyVCFAnnotationConversion() async throws {
        let vcf = """
        ##fileformat=VCFv4.0
        #CHROM\tPOS\tID\tREF\tALT\tQUAL\tFILTER\tINFO
        """
        let url = try createTempVCF(content: vcf)
        defer { try? FileManager.default.removeItem(at: url) }

        let reader = VCFReader()
        let annotations = try await reader.readAsAnnotations(from: url)
        XCTAssertEqual(annotations.count, 0)
    }

    func testLofreqVariantAnnotationConversion() async throws {
        let vcf = """
        ##fileformat=VCFv4.0
        #CHROM\tPOS\tID\tREF\tALT\tQUAL\tFILTER\tINFO
        NC_045512.2\t241\t.\tC\tT\t49314\tPASS\tDP=9264;AF=0.999784
        """
        let url = try createTempVCF(content: vcf)
        defer { try? FileManager.default.removeItem(at: url) }

        let reader = VCFReader()
        let annotations = try await reader.readAsAnnotations(from: url)
        XCTAssertEqual(annotations.count, 1)

        let ann = annotations[0]
        XCTAssertEqual(ann.start, 240) // 1-based → 0-based
        XCTAssertEqual(ann.type, .snp)
        XCTAssertEqual(ann.qualifiers["ref"]?.values.first, "C")
        XCTAssertEqual(ann.qualifiers["alt"]?.values.first, "T")
        XCTAssertEqual(ann.qualifiers["DP"]?.values.first, "9264")
        XCTAssertEqual(ann.qualifiers["AF"]?.values.first, "0.999784")
    }
}
