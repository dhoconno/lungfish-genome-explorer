// FASTQReaderTests.swift - Tests for FASTQ file parser
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
@testable import LungfishIO

final class FASTQReaderTests: XCTestCase {

    // MARK: - Test File Paths

    /// Path to the regular FASTQ test file
    let regularFastqPath = "/Users/dho/Desktop/test2/My Genome Project.lungfish/test_reads.fastq"

    /// Path to the gzip-compressed FASTQ test file
    let gzipFastqPath = "/Users/dho/Desktop/test2/My Genome Project.lungfish/test_reads.fastq.gz"

    // MARK: - Basic Parsing Tests

    func testReadRegularFastqFile() async throws {
        let url = URL(fileURLWithPath: regularFastqPath)
        let reader = FASTQReader()

        let records = try await reader.readAll(from: url)

        // The test file has 20 records
        XCTAssertEqual(records.count, 20, "Expected 20 records in test file")

        // Verify first record
        let first = records[0]
        XCTAssertEqual(first.identifier, "SEQ_001")
        XCTAssertTrue(first.description?.contains("Lungfish test read 1") ?? false)
        XCTAssertEqual(first.length, 100)
    }

    func testReadGzipCompressedFastqFile() async throws {
        let url = URL(fileURLWithPath: gzipFastqPath)
        let reader = FASTQReader()

        let records = try await reader.readAll(from: url)

        // Should have same number of records as uncompressed
        XCTAssertEqual(records.count, 20, "Expected 20 records in gzip file")

        // Verify first record matches uncompressed
        let first = records[0]
        XCTAssertEqual(first.identifier, "SEQ_001")
        XCTAssertEqual(first.length, 100)
    }

    func testGzipAndRegularFileMatchExactly() async throws {
        let regularURL = URL(fileURLWithPath: regularFastqPath)
        let gzipURL = URL(fileURLWithPath: gzipFastqPath)
        let reader = FASTQReader()

        let regularRecords = try await reader.readAll(from: regularURL)
        let gzipRecords = try await reader.readAll(from: gzipURL)

        XCTAssertEqual(regularRecords.count, gzipRecords.count)

        for (regular, gzip) in zip(regularRecords, gzipRecords) {
            XCTAssertEqual(regular.identifier, gzip.identifier)
            XCTAssertEqual(regular.description, gzip.description)
            XCTAssertEqual(regular.sequence, gzip.sequence)
            XCTAssertEqual(regular.quality.count, gzip.quality.count)
        }
    }

    // MARK: - Read Name Parsing Tests

    func testReadNamesParsedCorrectly() async throws {
        let url = URL(fileURLWithPath: regularFastqPath)
        let reader = FASTQReader()

        let records = try await reader.readAll(from: url)

        // Check specific read names from the test file
        XCTAssertEqual(records[0].identifier, "SEQ_001")
        XCTAssertEqual(records[1].identifier, "SEQ_002")
        XCTAssertEqual(records[10].identifier, "SEQ_011")
        XCTAssertEqual(records[19].identifier, "SEQ_020")
    }

    func testReadNameWithoutDescription() async throws {
        // Create a minimal FASTQ in memory
        let tempDir = FileManager.default.temporaryDirectory
        let tempFile = tempDir.appendingPathComponent("test_minimal.fastq")

        let content = """
            @SIMPLE_READ
            ATCGATCG
            +
            IIIIIIII
            """

        try content.write(to: tempFile, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: tempFile) }

        let reader = FASTQReader()
        let records = try await reader.readAll(from: tempFile)

        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records[0].identifier, "SIMPLE_READ")
        XCTAssertNil(records[0].description)
    }

    // MARK: - Quality Score Tests

    func testQualityScoresDecodedCorrectly() async throws {
        let url = URL(fileURLWithPath: regularFastqPath)
        let reader = FASTQReader()

        let records = try await reader.readAll(from: url)

        // SEQ_001 has all 'I' quality scores (ASCII 73, Phred+33 = Q40)
        let first = records[0]
        XCTAssertEqual(first.quality.count, first.sequence.count)

        // 'I' = ASCII 73, Phred+33 offset = 33, so quality = 73 - 33 = 40
        XCTAssertEqual(first.quality.qualityAt(0), 40)
        XCTAssertEqual(first.quality.qualityAt(50), 40)
        XCTAssertEqual(first.quality.meanQuality, 40.0, accuracy: 0.01)
    }

    func testVariableQualityScores() async throws {
        let url = URL(fileURLWithPath: regularFastqPath)
        let reader = FASTQReader()

        let records = try await reader.readAll(from: url)

        // SEQ_005 has variable quality
        let record = records[4]  // SEQ_005

        // Check that there's variation in quality
        let minQ = record.quality.minQuality
        let maxQ = record.quality.maxQuality
        XCTAssertLessThan(minQ, maxQ, "Expected variable quality scores")
    }

    func testQualityToErrorProbability() async throws {
        let url = URL(fileURLWithPath: regularFastqPath)
        let reader = FASTQReader()

        let records = try await reader.readAll(from: url)
        let first = records[0]

        // Q40 should give error probability of 10^(-40/10) = 0.0001
        let errorProb = first.quality.errorProbabilityAt(0)
        XCTAssertEqual(errorProb, 0.0001, accuracy: 0.00001)

        // Q30 gives error probability of 0.001
        let q30Record = FASTQRecord(
            identifier: "test",
            sequence: "A",
            qualityString: "?",  // ASCII 63 = Q30
            encoding: .phred33
        )
        XCTAssertEqual(q30Record.quality.errorProbabilityAt(0), 0.001, accuracy: 0.0001)
    }

    // MARK: - Sequence/Quality Length Matching Tests

    func testSequenceQualityLengthsMatch() async throws {
        let url = URL(fileURLWithPath: regularFastqPath)
        let reader = FASTQReader()

        let records = try await reader.readAll(from: url)

        for record in records {
            XCTAssertEqual(
                record.sequence.count,
                record.quality.count,
                "Sequence and quality lengths must match for \(record.identifier)"
            )
        }
    }

    func testVariableLengthReads() async throws {
        let url = URL(fileURLWithPath: regularFastqPath)
        let reader = FASTQReader()

        let records = try await reader.readAll(from: url)

        // Check that we have reads of different lengths
        let lengths = Set(records.map { $0.length })
        XCTAssertTrue(lengths.count > 1, "Expected reads of different lengths")

        // SEQ_011 and SEQ_012 should be 150bp
        XCTAssertEqual(records[10].length, 150)
        XCTAssertEqual(records[11].length, 150)

        // SEQ_013 and SEQ_014 should be 75bp
        XCTAssertEqual(records[12].length, 75)
        XCTAssertEqual(records[13].length, 75)
    }

    // MARK: - Quality Statistics Tests

    func testQualityStatistics() async throws {
        let url = URL(fileURLWithPath: regularFastqPath)
        let reader = FASTQReader()

        let records = try await reader.readAll(from: url)
        let stats = FASTQStatistics(records: records)

        XCTAssertEqual(stats.readCount, 20)
        XCTAssertGreaterThan(stats.baseCount, 0)
        XCTAssertGreaterThan(stats.meanReadLength, 0)
        XCTAssertGreaterThan(stats.minReadLength, 0)
        XCTAssertGreaterThanOrEqual(stats.maxReadLength, stats.minReadLength)
        XCTAssertGreaterThan(stats.meanQuality, 0)
    }

    func testQ20Q30Percentages() async throws {
        let url = URL(fileURLWithPath: regularFastqPath)
        let reader = FASTQReader()

        let records = try await reader.readAll(from: url)

        // First record has all Q40, so 100% should be >= Q20 and >= Q30
        let first = records[0]
        XCTAssertEqual(first.quality.q20Percentage, 100.0, accuracy: 0.01)
        XCTAssertEqual(first.quality.q30Percentage, 100.0, accuracy: 0.01)

        // Overall stats
        let stats = FASTQStatistics(records: records)
        XCTAssertGreaterThan(stats.q20Percentage, 0)
        XCTAssertLessThanOrEqual(stats.q30Percentage, stats.q20Percentage)
    }

    // MARK: - Encoding Detection Tests

    func testPhred33EncodingDetection() async throws {
        // Create a file with low quality scores that only make sense in Phred+33
        let tempDir = FileManager.default.temporaryDirectory
        let tempFile = tempDir.appendingPathComponent("test_phred33.fastq")

        // '!' is ASCII 33 = Q0 in Phred+33
        let content = """
            @TEST
            ATCG
            +
            !!!!
            """

        try content.write(to: tempFile, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: tempFile) }

        let reader = FASTQReader()
        let records = try await reader.readAll(from: tempFile)

        XCTAssertEqual(records[0].quality.encoding, .phred33)
        XCTAssertEqual(records[0].quality.qualityAt(0), 0)
    }

    // MARK: - Record Count Tests

    func testCountRecords() async throws {
        let url = URL(fileURLWithPath: regularFastqPath)
        let reader = FASTQReader()

        let count = try await reader.countRecords(in: url)
        XCTAssertEqual(count, 20)
    }

    func testCountRecordsGzip() async throws {
        let url = URL(fileURLWithPath: gzipFastqPath)
        let reader = FASTQReader()

        let count = try await reader.countRecords(in: url)
        XCTAssertEqual(count, 20)
    }

    // MARK: - Streaming Tests

    func testStreamingRecords() async throws {
        let url = URL(fileURLWithPath: regularFastqPath)
        let reader = FASTQReader()

        var count = 0
        for try await record in reader.records(from: url) {
            count += 1
            XCTAssertFalse(record.identifier.isEmpty)
            XCTAssertFalse(record.sequence.isEmpty)
        }

        XCTAssertEqual(count, 20)
    }

    // MARK: - Error Handling Tests

    func testInvalidHeaderError() async throws {
        let tempDir = FileManager.default.temporaryDirectory
        let tempFile = tempDir.appendingPathComponent("test_invalid_header.fastq")

        // Missing @ prefix
        let content = """
            SEQ_001
            ATCG
            +
            IIII
            """

        try content.write(to: tempFile, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: tempFile) }

        let reader = FASTQReader()

        do {
            _ = try await reader.readAll(from: tempFile)
            XCTFail("Expected FASTQError.invalidHeader")
        } catch let error as FASTQError {
            if case .invalidHeader = error {
                // Expected
            } else {
                XCTFail("Expected invalidHeader error, got \(error)")
            }
        }
    }

    func testQualityLengthMismatchError() async throws {
        let tempDir = FileManager.default.temporaryDirectory
        let tempFile = tempDir.appendingPathComponent("test_length_mismatch.fastq")

        // Quality shorter than sequence
        let content = """
            @SEQ_001
            ATCGATCG
            +
            III
            """

        try content.write(to: tempFile, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: tempFile) }

        let reader = FASTQReader()

        do {
            _ = try await reader.readAll(from: tempFile)
            XCTFail("Expected FASTQError.qualityLengthMismatch")
        } catch let error as FASTQError {
            if case .qualityLengthMismatch = error {
                // Expected
            } else {
                XCTFail("Expected qualityLengthMismatch error, got \(error)")
            }
        }
    }

    func testInvalidSeparatorError() async throws {
        let tempDir = FileManager.default.temporaryDirectory
        let tempFile = tempDir.appendingPathComponent("test_invalid_separator.fastq")

        // Wrong separator (- instead of +)
        let content = """
            @SEQ_001
            ATCG
            -
            IIII
            """

        try content.write(to: tempFile, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: tempFile) }

        let reader = FASTQReader()

        do {
            _ = try await reader.readAll(from: tempFile)
            XCTFail("Expected FASTQError.invalidSeparator")
        } catch let error as FASTQError {
            if case .invalidSeparator = error {
                // Expected
            } else {
                XCTFail("Expected invalidSeparator error, got \(error)")
            }
        }
    }

    // MARK: - GC Content Tests

    func testGCContentCalculation() async throws {
        let url = URL(fileURLWithPath: regularFastqPath)
        let reader = FASTQReader()

        let records = try await reader.readAll(from: url)
        let stats = FASTQStatistics(records: records)

        // GC content should be between 0 and 100
        XCTAssertGreaterThanOrEqual(stats.gcContent, 0)
        XCTAssertLessThanOrEqual(stats.gcContent, 100)
    }

    // MARK: - Gzip Specific Tests

    func testGzipMagicBytesDetection() async throws {
        let url = URL(fileURLWithPath: gzipFastqPath)
        XCTAssertTrue(url.isGzipCompressed)

        let regularURL = URL(fileURLWithPath: regularFastqPath)
        XCTAssertFalse(regularURL.isGzipCompressed)
    }

    func testGzipDecompressionPreservesContent() async throws {
        let gzipURL = URL(fileURLWithPath: gzipFastqPath)
        let regularURL = URL(fileURLWithPath: regularFastqPath)

        // Read regular file content
        let regularContent = try String(contentsOf: regularURL, encoding: .utf8)
        let regularLines = regularContent.split(separator: "\n", omittingEmptySubsequences: false)

        // Read gzip file via our decompression
        let gzipStream = try GzipInputStream(url: gzipURL)
        var gzipLines: [String] = []
        for try await line in gzipStream.lines() {
            gzipLines.append(line)
        }

        // Compare line counts (allowing for trailing newline differences)
        let regularNonEmpty = regularLines.filter { !$0.isEmpty }
        let gzipNonEmpty = gzipLines.filter { !$0.isEmpty }
        XCTAssertEqual(regularNonEmpty.count, gzipNonEmpty.count)
    }

    // MARK: - Quality Trimming Tests

    func testQualityTrimming() async throws {
        let record = FASTQRecord(
            identifier: "TEST",
            description: nil,
            sequence: "ATCGATCGATCG",
            qualityString: "IIIIII!!!!!!",  // High quality then low quality
            encoding: .phred33
        )

        let trimmed = record.qualityTrimmed(threshold: 20, windowSize: 3)

        // Should trim off the low quality bases
        XCTAssertLessThan(trimmed.length, record.length)
    }

    // MARK: - Reverse Complement Tests

    func testReverseComplement() async throws {
        let record = FASTQRecord(
            identifier: "TEST",
            description: nil,
            sequence: "ATCG",
            qualityString: "ABCD",
            encoding: .phred33
        )

        let rc = record.reverseComplement()

        XCTAssertEqual(rc.sequence, "CGAT")  // Reverse complement of ATCG
        XCTAssertEqual(rc.quality.toAscii(), "DCBA")  // Reversed quality
    }

    // MARK: - Paired-End Tests

    func testPairedEndReadParsing() async throws {
        // Test /1 /2 format
        let read1 = FASTQRecord(
            identifier: "READ_001/1",
            sequence: "ATCG",
            qualityString: "IIII",
            encoding: .phred33
        )

        XCTAssertNotNil(read1.readPair)
        XCTAssertEqual(read1.readPair?.readNumber, 1)
        XCTAssertEqual(read1.readPair?.pairId, "READ_001")

        let read2 = FASTQRecord(
            identifier: "READ_001/2",
            sequence: "GCTA",
            qualityString: "HHHH",
            encoding: .phred33
        )

        XCTAssertNotNil(read2.readPair)
        XCTAssertEqual(read2.readPair?.readNumber, 2)
        XCTAssertEqual(read2.readPair?.pairId, "READ_001")
    }
}

// MARK: - GzipInputStream Tests

final class GzipInputStreamTests: XCTestCase {

    let gzipPath = "/Users/dho/Desktop/test2/My Genome Project.lungfish/test_reads.fastq.gz"

    func testGzipStreamLines() async throws {
        let url = URL(fileURLWithPath: gzipPath)
        let stream = try GzipInputStream(url: url)

        var lineCount = 0
        for try await line in stream.lines() {
            lineCount += 1
            if lineCount == 1 {
                // First line should be the header
                XCTAssertTrue(line.hasPrefix("@SEQ_001"))
            }
        }

        // Should have 80+ lines (20 records x 4 lines each)
        XCTAssertGreaterThanOrEqual(lineCount, 80)
    }

    func testGzipReadAll() async throws {
        let url = URL(fileURLWithPath: gzipPath)
        let stream = try GzipInputStream(url: url)

        let content = try await stream.readAll()

        XCTAssertTrue(content.contains("@SEQ_001"))
    }

    func testInvalidGzipFile() async throws {
        let tempDir = FileManager.default.temporaryDirectory
        let tempFile = tempDir.appendingPathComponent("not_gzip.gz")

        // Write non-gzip content
        try "This is not gzip".write(to: tempFile, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: tempFile) }

        let stream = try GzipInputStream(url: tempFile)

        do {
            _ = try await stream.readAll()
            XCTFail("Expected GzipError.invalidFormat")
        } catch let error as GzipError {
            if case .invalidFormat = error {
                // Expected
            } else {
                XCTFail("Expected invalidFormat error, got \(error)")
            }
        }
    }

    func testGzipFileNotFound() async throws {
        let url = URL(fileURLWithPath: "/nonexistent/file.fastq.gz")

        do {
            _ = try GzipInputStream(url: url)
            XCTFail("Expected GzipError.fileNotFound")
        } catch let error as GzipError {
            if case .fileNotFound = error {
                // Expected
            } else {
                XCTFail("Expected fileNotFound error, got \(error)")
            }
        }
    }
}

// MARK: - QualityScore Tests

final class QualityScoreTests: XCTestCase {

    func testPhred33Decoding() {
        // 'I' = ASCII 73, Q = 73 - 33 = 40
        let quality = QualityScore(ascii: "IIIII", encoding: .phred33)

        XCTAssertEqual(quality.count, 5)
        XCTAssertEqual(quality.qualityAt(0), 40)
        XCTAssertEqual(quality.meanQuality, 40.0)
    }

    func testPhred33LowQuality() {
        // '!' = ASCII 33, Q = 33 - 33 = 0
        let quality = QualityScore(ascii: "!!!!!", encoding: .phred33)

        XCTAssertEqual(quality.qualityAt(0), 0)
        XCTAssertEqual(quality.meanQuality, 0.0)
    }

    func testMixedQuality() {
        // Mix of qualities
        let quality = QualityScore(ascii: "!5@I", encoding: .phred33)

        XCTAssertEqual(quality.qualityAt(0), 0)   // '!'
        XCTAssertEqual(quality.qualityAt(1), 20)  // '5' = 53 - 33 = 20
        XCTAssertEqual(quality.qualityAt(2), 31)  // '@' = 64 - 33 = 31
        XCTAssertEqual(quality.qualityAt(3), 40)  // 'I' = 73 - 33 = 40
    }

    func testQualityHistogram() {
        let quality = QualityScore(ascii: "IIIII55555", encoding: .phred33)
        let histogram = quality.qualityHistogram()

        XCTAssertEqual(histogram[40], 5)  // 5 'I's
        XCTAssertEqual(histogram[20], 5)  // 5 '5's
    }

    func testPercentAboveThreshold() {
        let quality = QualityScore(ascii: "IIIII!!!!!", encoding: .phred33)

        XCTAssertEqual(quality.percentAbove(threshold: 30), 50.0)
        XCTAssertEqual(quality.q30Percentage, 50.0)
    }

    func testMedianQuality() {
        let quality = QualityScore(ascii: "!5@I", encoding: .phred33)
        // Sorted: 0, 20, 31, 40 -> median = (20 + 31) / 2 = 25.5
        XCTAssertEqual(quality.medianQuality, 25.5, accuracy: 0.01)
    }

    func testQualityToAscii() {
        let quality = QualityScore(values: [0, 20, 31, 40], encoding: .phred33)
        let ascii = quality.toAscii()

        XCTAssertEqual(ascii, "!5@I")
    }

    func testTrimPosition() {
        // High quality followed by low quality
        let quality = QualityScore(ascii: "IIIII!!!!!", encoding: .phred33)
        let trimPos = quality.trimPosition(threshold: 20, windowSize: 3)

        // Should find trim position around where quality drops
        XCTAssertLessThanOrEqual(trimPos, 7)
        XCTAssertGreaterThan(trimPos, 0)
    }
}

// MARK: - QualityEncoding Detection Tests

final class QualityEncodingTests: XCTestCase {

    func testDetectPhred33FromLowChars() {
        // Characters below ASCII 59 can only be Phred+33
        let encoding = QualityEncoding.detect(from: "!#$%")
        XCTAssertEqual(encoding, .phred33)
    }

    func testDetectPhred33AsDefault() {
        // Modern standard, should default to Phred+33
        let encoding = QualityEncoding.detect(from: "IIIII")
        XCTAssertEqual(encoding, .phred33)
    }

    func testEncodingDisplayNames() {
        XCTAssertEqual(QualityEncoding.phred33.displayName, "Phred+33 (Sanger/Illumina 1.8+)")
        XCTAssertEqual(QualityEncoding.phred64.displayName, "Phred+64 (Illumina 1.3-1.7)")
    }

    func testEncodingOffsets() {
        XCTAssertEqual(QualityEncoding.phred33.asciiOffset, 33)
        XCTAssertEqual(QualityEncoding.phred64.asciiOffset, 64)
    }
}
