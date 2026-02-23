// AlignmentDataProviderTests.swift - Tests for alignment data provider
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
@testable import LungfishIO
@testable import LungfishCore

final class AlignmentDataProviderTests: XCTestCase {

    // MARK: - Initialization

    func testProviderInitialization() {
        let provider = AlignmentDataProvider(
            alignmentPath: "/data/sample.bam",
            indexPath: "/data/sample.bam.bai",
            format: .bam,
            referenceFastaPath: nil
        )

        XCTAssertEqual(provider.alignmentPath, "/data/sample.bam")
        XCTAssertEqual(provider.indexPath, "/data/sample.bam.bai")
        XCTAssertEqual(provider.format, .bam)
        XCTAssertNil(provider.referenceFastaPath)
    }

    func testProviderInitializationCRAM() {
        let provider = AlignmentDataProvider(
            alignmentPath: "/data/sample.cram",
            indexPath: "/data/sample.cram.crai",
            format: .cram,
            referenceFastaPath: "/data/reference.fa"
        )

        XCTAssertEqual(provider.format, .cram)
        XCTAssertEqual(provider.referenceFastaPath, "/data/reference.fa")
    }

    func testProviderDefaultFormat() {
        let provider = AlignmentDataProvider(
            alignmentPath: "/data/test.bam",
            indexPath: "/data/test.bam.bai"
        )

        XCTAssertEqual(provider.format, .bam)
        XCTAssertNil(provider.referenceFastaPath)
    }

    // MARK: - Sendable Conformance

    func testProviderIsSendable() {
        let provider = AlignmentDataProvider(
            alignmentPath: "/data/sample.bam",
            indexPath: "/data/sample.bam.bai"
        )

        // Verify Sendable by capturing in a Sendable closure
        let sendableCheck: @Sendable () -> String = {
            provider.alignmentPath
        }
        XCTAssertEqual(sendableCheck(), "/data/sample.bam")
    }

    // MARK: - Invalid Region Handling

    func testFetchReadsInvalidEmptyChromosome() async {
        let provider = AlignmentDataProvider(
            alignmentPath: "/nonexistent.bam",
            indexPath: "/nonexistent.bam.bai"
        )

        do {
            _ = try await provider.fetchReads(chromosome: "", start: 0, end: 100)
            XCTFail("Expected error for empty chromosome")
        } catch let error as AlignmentFetchError {
            if case .invalidRegion(let region) = error {
                XCTAssertTrue(region.contains(":0-100"))
            } else {
                XCTFail("Expected .invalidRegion but got \(error)")
            }
        } catch {
            XCTFail("Expected AlignmentFetchError but got \(type(of: error))")
        }
    }

    func testFetchReadsInvalidNegativeStart() async {
        let provider = AlignmentDataProvider(
            alignmentPath: "/nonexistent.bam",
            indexPath: "/nonexistent.bam.bai"
        )

        do {
            _ = try await provider.fetchReads(chromosome: "chr1", start: -1, end: 100)
            XCTFail("Expected error for negative start")
        } catch let error as AlignmentFetchError {
            if case .invalidRegion = error {
                // Expected
            } else {
                XCTFail("Expected .invalidRegion but got \(error)")
            }
        } catch {
            XCTFail("Expected AlignmentFetchError but got \(type(of: error))")
        }
    }

    func testFetchReadsInvalidStartGreaterThanEnd() async {
        let provider = AlignmentDataProvider(
            alignmentPath: "/nonexistent.bam",
            indexPath: "/nonexistent.bam.bai"
        )

        do {
            _ = try await provider.fetchReads(chromosome: "chr1", start: 200, end: 100)
            XCTFail("Expected error for start > end")
        } catch let error as AlignmentFetchError {
            if case .invalidRegion = error {
                // Expected
            } else {
                XCTFail("Expected .invalidRegion but got \(error)")
            }
        } catch {
            XCTFail("Expected AlignmentFetchError but got \(type(of: error))")
        }
    }

    func testFetchReadsZeroMaxReadsReturnsEmpty() async throws {
        let provider = AlignmentDataProvider(
            alignmentPath: "/nonexistent.bam",
            indexPath: "/nonexistent.bam.bai"
        )

        // maxReads = 0 should return empty without running samtools
        let reads = try await provider.fetchReads(
            chromosome: "chr1", start: 0, end: 100, maxReads: 0
        )
        XCTAssertTrue(reads.isEmpty)
    }

    // MARK: - AlignmentFetchError

    func testAlignmentFetchErrorSamtoolsNotFoundDescription() {
        let error = AlignmentFetchError.samtoolsNotFound
        XCTAssertNotNil(error.errorDescription)
        XCTAssertTrue(error.errorDescription!.contains("samtools"))
    }

    func testAlignmentFetchErrorSamtoolsFailedDescription() {
        let error = AlignmentFetchError.samtoolsFailed("file not found")
        XCTAssertNotNil(error.errorDescription)
        XCTAssertTrue(error.errorDescription!.contains("file not found"))
    }

    func testAlignmentFetchErrorInvalidRegionDescription() {
        let error = AlignmentFetchError.invalidRegion("chr1:-5-100")
        XCTAssertNotNil(error.errorDescription)
        XCTAssertTrue(error.errorDescription!.contains("chr1:-5-100"))
    }

    func testAlignmentFetchErrorTimeoutDescription() {
        let error = AlignmentFetchError.timeout
        XCTAssertNotNil(error.errorDescription)
        XCTAssertTrue(error.errorDescription!.contains("timed out"))
    }

    func testAllAlignmentFetchErrorCasesHaveDescriptions() {
        let errors: [AlignmentFetchError] = [
            .samtoolsNotFound,
            .samtoolsFailed("test"),
            .invalidRegion("test"),
            .timeout
        ]
        for error in errors {
            XCTAssertNotNil(error.errorDescription, "Error case should have a description")
            XCTAssertFalse(error.errorDescription!.isEmpty)
        }
    }

    // MARK: - SAMParser Integration (inline data, no samtools needed)

    func testSAMParserParsesAlignedReads() {
        let samLine = "read1\t99\tchr1\t100\t60\t75M\t=\t300\t275\tACGTACGTACGTACGTACGTACGTACGTACGTACGTACGTACGTACGTACGTACGTACGTACGTACGTACGTACG\t*\tRG:Z:sample1"
        let reads = SAMParser.parse(samLine)
        XCTAssertEqual(reads.count, 1)

        let read = reads[0]
        XCTAssertEqual(read.name, "read1")
        XCTAssertEqual(read.chromosome, "chr1")
        XCTAssertEqual(read.position, 99) // 0-based (100 - 1)
        XCTAssertEqual(read.mapq, 60)
    }

    func testSAMParserParsesReadGroups() {
        let headerText = """
        @HD\tVN:1.6\tSO:coordinate
        @SQ\tSN:chr1\tLN:248956422
        @RG\tID:lane1\tSM:NA12878\tPL:ILLUMINA\tLB:lib1
        @RG\tID:lane2\tSM:NA12878\tPL:ILLUMINA\tLB:lib2
        @RG\tID:lane3\tSM:HG002\tPL:ILLUMINA\tLB:lib3
        """
        let readGroups = SAMParser.parseReadGroups(from: headerText)
        XCTAssertEqual(readGroups.count, 3)

        let samples = Set(readGroups.compactMap { $0.sample })
        XCTAssertTrue(samples.contains("NA12878"))
        XCTAssertTrue(samples.contains("HG002"))
    }

    func testSAMParserHandlesEmptyInput() {
        let reads = SAMParser.parse("")
        XCTAssertTrue(reads.isEmpty)
    }

    func testSAMParserReadGroupsEmptyHeader() {
        let readGroups = SAMParser.parseReadGroups(from: "")
        XCTAssertTrue(readGroups.isEmpty)
    }

    func testSAMParserReadGroupsNoRGLines() {
        let header = "@HD\tVN:1.6\n@SQ\tSN:chr1\tLN:248956422\n"
        let readGroups = SAMParser.parseReadGroups(from: header)
        XCTAssertTrue(readGroups.isEmpty)
    }

    // MARK: - Depth Parsing

    func testParseDepthOutputBasic() {
        let depthOutput = """
        chr1\t101\t20
        chr1\t102\t0
        chr1\t150\t7
        """
        let points = AlignmentDataProvider.parseDepthOutput(depthOutput)
        XCTAssertEqual(points.count, 3)
        XCTAssertEqual(points[0], DepthPoint(chromosome: "chr1", position: 100, depth: 20))
        XCTAssertEqual(points[1], DepthPoint(chromosome: "chr1", position: 101, depth: 0))
        XCTAssertEqual(points[2], DepthPoint(chromosome: "chr1", position: 149, depth: 7))
    }

    func testParseDepthOutputSkipsInvalidLines() {
        let depthOutput = """
        chr1\t100\t10
        bad-line
        chr1\tX\t4
        chr1\t120\tY
        chr2\t1\t9
        """
        let points = AlignmentDataProvider.parseDepthOutput(depthOutput)
        XCTAssertEqual(points.count, 2)
        XCTAssertEqual(points[0], DepthPoint(chromosome: "chr1", position: 99, depth: 10))
        XCTAssertEqual(points[1], DepthPoint(chromosome: "chr2", position: 0, depth: 9))
    }

    func testParseDepthOutputEmpty() {
        XCTAssertTrue(AlignmentDataProvider.parseDepthOutput("").isEmpty)
        XCTAssertTrue(AlignmentDataProvider.parseDepthOutput("\n\n").isEmpty)
    }

    func testParseConsensusFASTA() {
        let fasta = """
        >chr1:1-10
        acgtNN
        tgca
        """
        let result = AlignmentDataProvider.parseConsensusFASTA(fasta)
        XCTAssertEqual(result.sequence, "ACGTNNTGCA")
        // Header ">chr1:1-10" → 1-based start 1 → 0-based start 0
        XCTAssertEqual(result.headerStart, 0)
    }

    func testParseConsensusFASTAHeaderWithLargeRegion() {
        let fasta = ">MN908947.3:5001-10000\nACGTACGT\n"
        let result = AlignmentDataProvider.parseConsensusFASTA(fasta)
        XCTAssertEqual(result.sequence, "ACGTACGT")
        // 1-based start 5001 → 0-based start 5000
        XCTAssertEqual(result.headerStart, 5000)
    }

    func testParseConsensusFASTANoRegionInHeader() {
        let fasta = ">chr1\nACGT\n"
        let result = AlignmentDataProvider.parseConsensusFASTA(fasta)
        XCTAssertEqual(result.sequence, "ACGT")
        XCTAssertNil(result.headerStart)
    }

    func testParseConsensusFASTAPreservesDeletionMarkers() {
        let fasta = """
        >chr1:11-20
        AC*GT**TAA
        """
        let result = AlignmentDataProvider.parseConsensusFASTA(fasta)
        XCTAssertEqual(result.sequence, "AC*GT**TAA")
        XCTAssertEqual(result.sequence.count, 10)
        XCTAssertEqual(result.headerStart, 10)
    }

    func testParseConsensusFASTAEmpty() {
        let result = AlignmentDataProvider.parseConsensusFASTA("")
        XCTAssertTrue(result.sequence.isEmpty)
        XCTAssertNil(result.headerStart)
    }

    // MARK: - AlignmentMetadataDatabase Parsing (inline data tests)

    func testIdxstatsParsingViaMetadataDatabase() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ADP-idxstats-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let dbURL = tempDir.appendingPathComponent("test.db")
        let db = try AlignmentMetadataDatabase.create(at: dbURL)

        let idxstatsOutput = """
        chr1\t248956422\t15000000\t50000
        chr2\t242193529\t12000000\t40000
        chrX\t156040895\t5000000\t20000
        *\t0\t0\t100000
        """
        db.populateFromIdxstats(idxstatsOutput)

        XCTAssertEqual(db.totalMappedReads(), 32_000_000)
        // populateFromIdxstats skips the '*' unmapped summary line — only per-chromosome unmapped
        XCTAssertEqual(db.totalUnmappedReads(), 110_000) // 50000 + 40000 + 20000
    }

    func testFlagstatParsingViaMetadataDatabase() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ADP-flagstat-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let dbURL = tempDir.appendingPathComponent("test.db")
        let db = try AlignmentMetadataDatabase.create(at: dbURL)

        let flagstatOutput = """
        50000000 + 0 in total (QC-passed reads + QC-failed reads)
        1000000 + 0 secondary
        500000 + 0 supplementary
        200000 + 0 duplicates
        48000000 + 0 mapped (96.00% : N/A)
        40000000 + 0 paired in sequencing
        20000000 + 0 read1
        20000000 + 0 read2
        38000000 + 0 properly paired (95.00% : N/A)
        39000000 + 0 with itself and mate mapped
        500000 + 0 singletons (1.25% : N/A)
        100000 + 0 with mate mapped to a different chr
        50000 + 0 with mate mapped to a different chr (mapQ>=5)
        """
        db.populateFromFlagstat(flagstatOutput)

        // Verify flagstat was parsed — populateFromFlagstat should not crash
        // The database stores these as flag_stat rows via addFlagStatEntry
    }

    // MARK: - Empty/Malformed Input Handling

    func testIdxstatsEmptyOutput() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ADP-empty-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let dbURL = tempDir.appendingPathComponent("test.db")
        let db = try AlignmentMetadataDatabase.create(at: dbURL)

        db.populateFromIdxstats("")
        XCTAssertEqual(db.totalMappedReads(), 0)
        XCTAssertEqual(db.totalUnmappedReads(), 0)
    }

    func testIdxstatsMalformedLines() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ADP-malformed-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let dbURL = tempDir.appendingPathComponent("test.db")
        let db = try AlignmentMetadataDatabase.create(at: dbURL)

        // Mix of valid and malformed lines
        let output = """
        chr1\t248956422\t1000\t50
        this_is_malformed
        chr2\t242193529\t2000\t100
        """
        db.populateFromIdxstats(output)

        // Should handle gracefully — only valid lines counted
        XCTAssertEqual(db.totalMappedReads(), 3000)
    }
}
