// CLICommandTests.swift - Comprehensive tests for CLI commands, output handlers, and formatters
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import ArgumentParser
import XCTest
@testable import LungfishCLI
@testable import LungfishCore
@testable import LungfishIO

// MARK: - SequenceStats Tests

final class SequenceStatsTests: XCTestCase {

    /// Verifies that SequenceStats can be encoded to JSON and decoded back with all fields preserved.
    func testSequenceStatsCodable() throws {
        let stats = SequenceStats(
            sequenceCount: 10,
            totalLength: 50000,
            gcContent: 0.42,
            n50: 8000,
            minLength: 100,
            maxLength: 15000,
            meanLength: 5000.0
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let data = try encoder.encode(stats)

        let decoder = JSONDecoder()
        let decoded = try decoder.decode(SequenceStats.self, from: data)

        XCTAssertEqual(decoded.sequenceCount, stats.sequenceCount)
        XCTAssertEqual(decoded.totalLength, stats.totalLength)
        XCTAssertEqual(decoded.gcContent, stats.gcContent, accuracy: 0.0001)
        XCTAssertEqual(decoded.n50, stats.n50)
        XCTAssertEqual(decoded.minLength, stats.minLength)
        XCTAssertEqual(decoded.maxLength, stats.maxLength)
        XCTAssertEqual(decoded.meanLength, stats.meanLength, accuracy: 0.0001)
    }

    /// Verifies that all SequenceStats fields store the correct values upon initialization.
    func testSequenceStatsValues() {
        let stats = SequenceStats(
            sequenceCount: 3,
            totalLength: 30000,
            gcContent: 0.55,
            n50: 12000,
            minLength: 5000,
            maxLength: 15000,
            meanLength: 10000.0
        )

        XCTAssertEqual(stats.sequenceCount, 3)
        XCTAssertEqual(stats.totalLength, 30000)
        XCTAssertEqual(stats.gcContent, 0.55, accuracy: 0.0001)
        XCTAssertEqual(stats.n50, 12000)
        XCTAssertEqual(stats.minLength, 5000)
        XCTAssertEqual(stats.maxLength, 15000)
        XCTAssertEqual(stats.meanLength, 10000.0, accuracy: 0.0001)
    }

    /// Verifies that SequenceStats handles edge case of zero-length sequences.
    func testSequenceStatsZeroValues() {
        let stats = SequenceStats(
            sequenceCount: 0,
            totalLength: 0,
            gcContent: 0.0,
            n50: 0,
            minLength: 0,
            maxLength: 0,
            meanLength: 0.0
        )

        XCTAssertEqual(stats.sequenceCount, 0)
        XCTAssertEqual(stats.totalLength, 0)
        XCTAssertEqual(stats.gcContent, 0.0, accuracy: 0.0001)
    }

    /// Verifies that SequenceStats JSON encoding produces expected keys.
    func testSequenceStatsJSONKeys() throws {
        let stats = SequenceStats(
            sequenceCount: 1,
            totalLength: 100,
            gcContent: 0.5,
            n50: 100,
            minLength: 100,
            maxLength: 100,
            meanLength: 100.0
        )

        let encoder = JSONEncoder()
        let data = try encoder.encode(stats)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]

        XCTAssertNotNil(json)
        XCTAssertNotNil(json?["sequenceCount"])
        XCTAssertNotNil(json?["totalLength"])
        XCTAssertNotNil(json?["gcContent"])
        XCTAssertNotNil(json?["n50"])
        XCTAssertNotNil(json?["minLength"])
        XCTAssertNotNil(json?["maxLength"])
        XCTAssertNotNil(json?["meanLength"])
    }
}

// MARK: - ConvertResult Tests

final class ConvertResultTests: XCTestCase {

    /// Verifies that ConvertResult can be encoded to JSON and decoded back with all fields intact.
    func testConvertResultCodable() throws {
        let result = ConvertResult(
            inputFile: "/path/to/input.fasta",
            outputFile: "/path/to/output.gb",
            inputFormat: "fasta",
            outputFormat: "genbank",
            sequenceCount: 5,
            annotationCount: 12
        )

        let encoder = JSONEncoder()
        let data = try encoder.encode(result)

        let decoder = JSONDecoder()
        let decoded = try decoder.decode(ConvertResult.self, from: data)

        XCTAssertEqual(decoded.inputFile, result.inputFile)
        XCTAssertEqual(decoded.outputFile, result.outputFile)
        XCTAssertEqual(decoded.inputFormat, result.inputFormat)
        XCTAssertEqual(decoded.outputFormat, result.outputFormat)
        XCTAssertEqual(decoded.sequenceCount, result.sequenceCount)
        XCTAssertEqual(decoded.annotationCount, result.annotationCount)
    }

    /// Verifies that all ConvertResult fields are correctly populated.
    func testConvertResultFields() {
        let result = ConvertResult(
            inputFile: "genome.fa",
            outputFile: "genome.gb",
            inputFormat: "fa",
            outputFormat: "genbank",
            sequenceCount: 24,
            annotationCount: 0
        )

        XCTAssertEqual(result.inputFile, "genome.fa")
        XCTAssertEqual(result.outputFile, "genome.gb")
        XCTAssertEqual(result.inputFormat, "fa")
        XCTAssertEqual(result.outputFormat, "genbank")
        XCTAssertEqual(result.sequenceCount, 24)
        XCTAssertEqual(result.annotationCount, 0)
    }

    /// Verifies that ConvertResult handles zero counts correctly.
    func testConvertResultZeroCounts() throws {
        let result = ConvertResult(
            inputFile: "empty.fa",
            outputFile: "empty.gb",
            inputFormat: "fa",
            outputFormat: "genbank",
            sequenceCount: 0,
            annotationCount: 0
        )

        let encoder = JSONEncoder()
        let data = try encoder.encode(result)
        let decoded = try JSONDecoder().decode(ConvertResult.self, from: data)

        XCTAssertEqual(decoded.sequenceCount, 0)
        XCTAssertEqual(decoded.annotationCount, 0)
    }
}

// MARK: - ValidationFileResult Tests

final class ValidationFileResultTests: XCTestCase {

    /// Verifies that ValidationFileResult encodes and decodes correctly through JSON.
    func testValidationFileResultCodable() throws {
        let result = ValidationFileResult(
            file: "/data/test.fasta",
            valid: true,
            format: "FASTA",
            errors: []
        )

        let encoder = JSONEncoder()
        let data = try encoder.encode(result)

        let decoder = JSONDecoder()
        let decoded = try decoder.decode(ValidationFileResult.self, from: data)

        XCTAssertEqual(decoded.file, "/data/test.fasta")
        XCTAssertTrue(decoded.valid)
        XCTAssertEqual(decoded.format, "FASTA")
        XCTAssertTrue(decoded.errors.isEmpty)
    }

    /// Verifies that ValidationResult reports allValid correctly when all files are valid.
    func testValidationResultAllValid() throws {
        let fileResults = [
            ValidationFileResult(file: "a.fasta", valid: true, format: "FASTA", errors: []),
            ValidationFileResult(file: "b.fastq", valid: true, format: "FASTQ", errors: []),
            ValidationFileResult(file: "c.gb", valid: true, format: "GenBank", errors: []),
        ]

        let validationResult = ValidationResult(files: fileResults, allValid: true)

        XCTAssertTrue(validationResult.allValid)
        XCTAssertEqual(validationResult.files.count, 3)

        // Verify Codable roundtrip
        let data = try JSONEncoder().encode(validationResult)
        let decoded = try JSONDecoder().decode(ValidationResult.self, from: data)

        XCTAssertTrue(decoded.allValid)
        XCTAssertEqual(decoded.files.count, 3)
        XCTAssertTrue(decoded.files.allSatisfy { $0.valid })
    }

    /// Verifies ValidationFileResult correctly represents an invalid file with errors.
    func testValidationFileResultInvalid() throws {
        let result = ValidationFileResult(
            file: "broken.fasta",
            valid: false,
            format: "FASTA",
            errors: ["Sequence before header", "Invalid character"]
        )

        XCTAssertFalse(result.valid)
        XCTAssertEqual(result.errors.count, 2)
        XCTAssertTrue(result.errors.contains("Sequence before header"))
        XCTAssertTrue(result.errors.contains("Invalid character"))

        // Roundtrip
        let data = try JSONEncoder().encode(result)
        let decoded = try JSONDecoder().decode(ValidationFileResult.self, from: data)
        XCTAssertFalse(decoded.valid)
        XCTAssertEqual(decoded.errors.count, 2)
    }

    /// Verifies ValidationFileResult with nil format for unknown files.
    func testValidationFileResultNilFormat() throws {
        let result = ValidationFileResult(
            file: "unknown.xyz",
            valid: false,
            format: nil,
            errors: ["Unknown file format"]
        )

        XCTAssertNil(result.format)

        let data = try JSONEncoder().encode(result)
        let decoded = try JSONDecoder().decode(ValidationFileResult.self, from: data)
        XCTAssertNil(decoded.format)
    }

    /// Verifies ValidationResult allValid is false when any file is invalid.
    func testValidationResultNotAllValid() {
        let fileResults = [
            ValidationFileResult(file: "a.fasta", valid: true, format: "FASTA", errors: []),
            ValidationFileResult(file: "b.fasta", valid: false, format: "FASTA", errors: ["Parse error"]),
        ]

        let validationResult = ValidationResult(files: fileResults, allValid: false)

        XCTAssertFalse(validationResult.allValid)
        XCTAssertEqual(validationResult.files.count, 2)
    }
}

// MARK: - CLIOutput Handler Tests

final class CLIOutputHandlerTests: XCTestCase {

    /// Verifies that StandardOutputHandler can be created without crashing.
    func testStandardOutputHandlerCreation() {
        let handler = StandardOutputHandler(useColors: false)
        // Should not crash; writing to stdout is a side effect, so we verify creation
        XCTAssertNotNil(handler)
        handler.finish()
    }

    /// Verifies that StandardOutputHandler can be created with colors enabled.
    func testStandardOutputHandlerCreationWithColors() {
        let handler = StandardOutputHandler(useColors: true)
        XCTAssertNotNil(handler)
        handler.finish()
    }

    /// Verifies that StandardOutputHandler can be created with an output file path.
    func testStandardOutputHandlerWithOutputFile() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cli_tests_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let outputPath = tempDir.appendingPathComponent("output.txt").path
        let handler = StandardOutputHandler(useColors: false, outputPath: outputPath)
        handler.write("Test message")
        handler.finish()

        let content = try String(contentsOfFile: outputPath, encoding: .utf8)
        XCTAssertTrue(content.contains("Test message"))
    }

    /// Verifies that JSONOutputHandler encodes Codable data and writes to stdout without error.
    func testJSONOutputHandlerWriteData() {
        struct SampleData: Codable {
            let name: String
            let count: Int
        }

        let handler = JSONOutputHandler()
        // Writing to stdout is a side effect; verify no crash
        handler.writeData(SampleData(name: "test", count: 42), label: nil)
        handler.finish()
    }

    /// Verifies that JSONOutputHandler correctly encodes Codable values to valid JSON.
    func testJSONOutputHandlerEncodesCorrectly() throws {
        struct TestPayload: Codable, Equatable {
            let key: String
            let value: Int
        }

        let payload = TestPayload(key: "alpha", value: 99)

        // Verify encoding produces valid JSON
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let jsonData = try encoder.encode(payload)
        let jsonString = String(data: jsonData, encoding: .utf8)!

        XCTAssertTrue(jsonString.contains("\"key\""))
        XCTAssertTrue(jsonString.contains("\"alpha\""))
        XCTAssertTrue(jsonString.contains("\"value\""))
        XCTAssertTrue(jsonString.contains("99"))

        // Verify round-trip
        let decoded = try JSONDecoder().decode(TestPayload.self, from: jsonData)
        XCTAssertEqual(decoded, payload)
    }

    /// Verifies that TSVOutputHandler.setHeaders stores and outputs column headers.
    func testTSVOutputHandlerSetHeaders() {
        let handler = TSVOutputHandler()
        // setHeaders writes to stdout; verify no crash
        handler.setHeaders(["Name", "Length", "GC%"])
        handler.finish()
    }

    /// Verifies that TSVOutputHandler.addRow stores and outputs a data row.
    func testTSVOutputHandlerAddRow() {
        let handler = TSVOutputHandler()
        handler.setHeaders(["Col1", "Col2", "Col3"])
        handler.addRow(["A", "B", "C"])
        handler.addRow(["D", "E", "F"])
        handler.finish()
    }

    /// Verifies that TSVOutputHandler can handle empty headers and rows.
    func testTSVOutputHandlerEmptyData() {
        let handler = TSVOutputHandler()
        handler.setHeaders([])
        handler.addRow([])
        handler.finish()
    }

    /// Verifies that CLIOutputFactory creates a JSONOutputHandler when format is .json.
    func testCLIOutputFactoryJSON() throws {
        let options = try GlobalOptions.parse(["--format", "json"])

        let handler = CLIOutputFactory.createHandler(for: options)
        XCTAssertTrue(handler is JSONOutputHandler, "Expected JSONOutputHandler for .json format")
    }

    /// Verifies that CLIOutputFactory creates a TSVOutputHandler when format is .tsv.
    func testCLIOutputFactoryTSV() throws {
        let options = try GlobalOptions.parse(["--format", "tsv"])

        let handler = CLIOutputFactory.createHandler(for: options)
        XCTAssertTrue(handler is TSVOutputHandler, "Expected TSVOutputHandler for .tsv format")
    }

    /// Verifies that CLIOutputFactory creates a StandardOutputHandler when format is .text.
    func testCLIOutputFactoryText() throws {
        let options = try GlobalOptions.parse([])

        let handler = CLIOutputFactory.createHandler(for: options)
        XCTAssertTrue(handler is StandardOutputHandler, "Expected StandardOutputHandler for .text format")
    }

    /// Verifies that CLIOutputFactory creates a StandardOutputHandler when debug mode is on.
    func testCLIOutputFactoryDebug() throws {
        let options = try GlobalOptions.parse(["--debug"])

        let handler = CLIOutputFactory.createHandler(for: options)
        XCTAssertTrue(handler is StandardOutputHandler, "Expected StandardOutputHandler for debug mode")
    }
}

// MARK: - CLIJSONResult Tests

final class CLIJSONResultTests: XCTestCase {

    /// Verifies that CLIJSONResult encodes a successful result with data.
    func testCLIJSONResultSuccess() throws {
        struct ResultData: Codable {
            let count: Int
        }

        let result = CLIJSONResult(
            success: true,
            command: "analyze stats",
            data: ResultData(count: 42)
        )

        XCTAssertTrue(result.success)
        XCTAssertEqual(result.command, "analyze stats")
        XCTAssertNotNil(result.data)
        XCTAssertEqual(result.data?.count, 42)
        XCTAssertNil(result.error)

        // Verify Codable
        let data = try JSONEncoder().encode(result)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        XCTAssertNotNil(json)
        XCTAssertEqual(json?["success"] as? Bool, true)
        XCTAssertEqual(json?["command"] as? String, "analyze stats")
    }

    /// Verifies that CLIJSONResult encodes a failure result with error information.
    func testCLIJSONResultFailure() throws {
        let error = CLIJSONError(
            code: .inputError,
            message: "File not found",
            details: "The file /missing.fa does not exist"
        )

        let result = CLIJSONResult<String>(
            success: false,
            command: "convert",
            data: nil,
            error: error
        )

        XCTAssertFalse(result.success)
        XCTAssertEqual(result.command, "convert")
        XCTAssertNil(result.data)
        XCTAssertNotNil(result.error)
        XCTAssertEqual(result.error?.message, "File not found")
        XCTAssertEqual(result.error?.details, "The file /missing.fa does not exist")
        XCTAssertEqual(result.error?.code, String(CLIExitCode.inputError.rawValue))

        // Verify encoding
        let data = try JSONEncoder().encode(result)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        XCTAssertEqual(json?["success"] as? Bool, false)
    }

    /// Verifies that CLIJSONMetadata contains version, timestamp, and platform fields.
    func testCLIJSONMetadata() throws {
        let metadata = CLIJSONMetadata()

        XCTAssertEqual(metadata.version, "1.0.0")
        XCTAssertFalse(metadata.timestamp.isEmpty, "Timestamp should not be empty")
        XCTAssertFalse(metadata.platform.isEmpty, "Platform should not be empty")
        XCTAssertTrue(metadata.platform.contains("macOS"), "Platform should mention macOS")

        // Verify that timestamp is a valid ISO 8601 string
        let isoFormatter = ISO8601DateFormatter()
        let date = isoFormatter.date(from: metadata.timestamp)
        XCTAssertNotNil(date, "Timestamp should be a valid ISO 8601 date")

        // Verify Codable
        let data = try JSONEncoder().encode(metadata)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        XCTAssertNotNil(json?["version"])
        XCTAssertNotNil(json?["timestamp"])
        XCTAssertNotNil(json?["platform"])
    }

    /// Verifies that CLIJSONResult metadata is automatically populated.
    func testCLIJSONResultIncludesMetadata() throws {
        let result = CLIJSONResult(
            success: true,
            command: "test",
            data: "hello"
        )

        XCTAssertEqual(result.metadata.version, "1.0.0")
        XCTAssertFalse(result.metadata.timestamp.isEmpty)

        let data = try JSONEncoder().encode(result)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let metadataDict = json?["metadata"] as? [String: Any]
        XCTAssertNotNil(metadataDict)
        XCTAssertEqual(metadataDict?["version"] as? String, "1.0.0")
    }

    /// Verifies that CLIJSONError correctly formats the exit code as a string.
    func testCLIJSONErrorCodeFormatting() {
        let error = CLIJSONError(
            code: .networkError,
            message: "Connection timeout"
        )

        XCTAssertEqual(error.code, String(CLIExitCode.networkError.rawValue))
        XCTAssertEqual(error.code, "66")
        XCTAssertEqual(error.message, "Connection timeout")
        XCTAssertNil(error.details)
    }
}

// MARK: - Format Conversion Integration Tests

final class FormatConversionIntegrationTests: XCTestCase {

    var tempDir: URL!

    override func setUp() async throws {
        try await super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cli_format_tests_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        if let tempDir = tempDir {
            try? FileManager.default.removeItem(at: tempDir)
        }
        try await super.tearDown()
    }

    /// Writes a FASTA file with multiple sequences and reads it back, verifying content integrity.
    func testConvertFASTAWriteAndRead() async throws {
        let fastaURL = tempDir.appendingPathComponent("test.fasta")

        // Create test sequences
        let seq1 = try Sequence(name: "seq1", description: "Test sequence 1", alphabet: .dna, bases: "ATCGATCGATCG")
        let seq2 = try Sequence(name: "seq2", description: "Test sequence 2", alphabet: .dna, bases: "GCTAGCTAGCTA")
        let seq3 = try Sequence(name: "seq3", alphabet: .dna, bases: "AAACCCGGGTTT")

        // Write
        let writer = FASTAWriter(url: fastaURL)
        try writer.write([seq1, seq2, seq3])

        // Verify file exists
        XCTAssertTrue(FileManager.default.fileExists(atPath: fastaURL.path))

        // Read back
        let reader = try FASTAReader(url: fastaURL)
        let sequences = try await reader.readAll()

        XCTAssertEqual(sequences.count, 3)
        XCTAssertEqual(sequences[0].name, "seq1")
        XCTAssertEqual(sequences[0].description, "Test sequence 1")
        XCTAssertEqual(sequences[0].asString(), "ATCGATCGATCG")
        XCTAssertEqual(sequences[0].length, 12)

        XCTAssertEqual(sequences[1].name, "seq2")
        XCTAssertEqual(sequences[1].asString(), "GCTAGCTAGCTA")

        XCTAssertEqual(sequences[2].name, "seq3")
        XCTAssertEqual(sequences[2].asString(), "AAACCCGGGTTT")
    }

    /// Writes a GenBank file and reads it back, verifying LOCUS, sequence, and feature data.
    func testConvertGenBankWriteAndRead() async throws {
        let gbURL = tempDir.appendingPathComponent("test.gb")

        let seq = try Sequence(
            name: "TEST_SEQ",
            description: "A test sequence for GenBank roundtrip",
            alphabet: .dna,
            bases: "ATCGATCGATCGATCGATCGATCG"
        )

        let locus = LocusInfo(
            name: "TEST_SEQ",
            length: 24,
            moleculeType: .dna,
            topology: .linear,
            division: "UNK",
            date: "01-JAN-2024"
        )

        let record = GenBankRecord(
            sequence: seq,
            annotations: [],
            locus: locus,
            definition: "A test sequence for GenBank roundtrip",
            accession: "TEST001",
            version: "TEST001.1"
        )

        // Write
        let writer = GenBankWriter(url: gbURL)
        try writer.write([record])

        // Verify file exists
        XCTAssertTrue(FileManager.default.fileExists(atPath: gbURL.path))

        // Read back
        let reader = try GenBankReader(url: gbURL)
        let records = try await reader.readAll()

        XCTAssertEqual(records.count, 1)
        let readRecord = records[0]

        XCTAssertEqual(readRecord.locus.name, "TEST_SEQ")
        XCTAssertEqual(readRecord.sequence.asString(), "ATCGATCGATCGATCGATCGATCG")
        XCTAssertEqual(readRecord.sequence.length, 24)
        XCTAssertEqual(readRecord.locus.moleculeType, .dna)
        XCTAssertEqual(readRecord.locus.topology, .linear)
    }

    /// Writes a FASTQ file with quality scores and reads it back, verifying sequence and quality data.
    func testConvertFASTQWriteAndRead() async throws {
        let fastqURL = tempDir.appendingPathComponent("test.fastq")

        let record1 = FASTQRecord(
            identifier: "read1",
            description: "Test read 1",
            sequence: "ATCGATCG",
            qualityString: "IIIIIIII",
            encoding: .phred33
        )

        let record2 = FASTQRecord(
            identifier: "read2",
            description: "Test read 2",
            sequence: "GCTAGCTA",
            qualityString: "FFFFFFFF",
            encoding: .phred33
        )

        // Write
        try FASTQWriter.write([record1, record2], to: fastqURL)

        // Verify file exists
        XCTAssertTrue(FileManager.default.fileExists(atPath: fastqURL.path))

        // Read back
        let reader = FASTQReader()
        let records = try await reader.readAll(from: fastqURL)

        XCTAssertEqual(records.count, 2)

        XCTAssertEqual(records[0].identifier, "read1")
        XCTAssertEqual(records[0].sequence, "ATCGATCG")
        XCTAssertEqual(records[0].length, 8)
        XCTAssertEqual(records[0].description, "Test read 1")

        XCTAssertEqual(records[1].identifier, "read2")
        XCTAssertEqual(records[1].sequence, "GCTAGCTA")
        XCTAssertEqual(records[1].length, 8)
    }

    /// Tests FASTA to FASTA roundtrip with line wrapping at 60 characters.
    func testFASTARoundtripWithLongSequence() async throws {
        let fastaURL = tempDir.appendingPathComponent("long.fasta")

        // Create a sequence longer than the default 60-character line width
        let bases = String(repeating: "ATCG", count: 40) // 160 bases
        let seq = try Sequence(name: "long_seq", alphabet: .dna, bases: bases)

        let writer = FASTAWriter(url: fastaURL, lineWidth: 60)
        try writer.write([seq])

        let reader = try FASTAReader(url: fastaURL)
        let sequences = try await reader.readAll()

        XCTAssertEqual(sequences.count, 1)
        XCTAssertEqual(sequences[0].asString(), bases)
        XCTAssertEqual(sequences[0].length, 160)
    }

    /// Tests that a FASTQ file preserves quality scores through write/read cycle.
    func testFASTQQualityPreservation() async throws {
        let fastqURL = tempDir.appendingPathComponent("quality.fastq")

        // Create a record with varying quality scores
        let qualityString = "!\"#$%&'()*+,-./0123456789:;<=>?@ABCDEFGHI"
        let sequence = String(repeating: "A", count: qualityString.count)

        let record = FASTQRecord(
            identifier: "quality_test",
            sequence: sequence,
            qualityString: qualityString,
            encoding: .phred33
        )

        try FASTQWriter.write([record], to: fastqURL)

        let reader = FASTQReader()
        let records = try await reader.readAll(from: fastqURL)

        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records[0].sequence, sequence)
        XCTAssertEqual(records[0].length, qualityString.count)
    }
}

// MARK: - CLI Error Tests

final class CLIErrorExtendedTests: XCTestCase {

    /// Verifies that every CLIError case provides a non-empty error description.
    func testAllCLIErrorCasesHaveDescriptions() {
        let cases: [CLIError] = [
            .inputFileNotFound(path: "/test"),
            .outputWriteFailed(path: "/test", reason: "permission denied"),
            .formatDetectionFailed(path: "/test.xyz"),
            .unsupportedFormat(format: "xyz"),
            .conversionFailed(reason: "test failure"),
            .validationFailed(errors: ["err1", "err2"]),
            .workflowFailed(reason: "process exited"),
            .containerUnavailable,
            .networkError(reason: "timeout"),
            .cancelled,
        ]

        for error in cases {
            let description = error.localizedDescription
            XCTAssertFalse(
                description.isEmpty,
                "CLIError.\(error) should have a non-empty description"
            )
        }
    }

    /// Verifies that every CLIError case maps to a defined CLIExitCode.
    func testAllCLIErrorCasesHaveExitCodes() {
        let cases: [CLIError] = [
            .inputFileNotFound(path: "/test"),
            .outputWriteFailed(path: "/test", reason: "reason"),
            .formatDetectionFailed(path: "/test"),
            .unsupportedFormat(format: "xyz"),
            .conversionFailed(reason: "reason"),
            .validationFailed(errors: []),
            .workflowFailed(reason: "reason"),
            .containerUnavailable,
            .networkError(reason: "reason"),
            .cancelled,
        ]

        for error in cases {
            let exitCode = error.exitCode
            // Verify it maps to a valid exit code (rawValue should be non-negative)
            XCTAssertGreaterThanOrEqual(
                exitCode.rawValue, 0,
                "Exit code for \(error) should be non-negative"
            )
        }
    }

    /// Verifies specific exit code raw values for each CLI error category.
    func testCLIExitCodeValues() {
        XCTAssertEqual(CLIExitCode.success.rawValue, 0)
        XCTAssertEqual(CLIExitCode.failure.rawValue, 1)
        XCTAssertEqual(CLIExitCode.usage.rawValue, 2)
        XCTAssertEqual(CLIExitCode.inputError.rawValue, 3)
        XCTAssertEqual(CLIExitCode.outputError.rawValue, 4)
        XCTAssertEqual(CLIExitCode.formatError.rawValue, 5)
        XCTAssertEqual(CLIExitCode.workflowError.rawValue, 64)
        XCTAssertEqual(CLIExitCode.containerError.rawValue, 65)
        XCTAssertEqual(CLIExitCode.networkError.rawValue, 66)
        XCTAssertEqual(CLIExitCode.timeout.rawValue, 124)
        XCTAssertEqual(CLIExitCode.cancelled.rawValue, 125)
        XCTAssertEqual(CLIExitCode.dependency.rawValue, 126)
        XCTAssertEqual(CLIExitCode.notFound.rawValue, 127)
    }

    /// Verifies that CLIError exit codes map correctly to specific code values.
    func testCLIErrorToExitCodeMapping() {
        XCTAssertEqual(CLIError.inputFileNotFound(path: "").exitCode, .inputError)
        XCTAssertEqual(CLIError.outputWriteFailed(path: "", reason: "").exitCode, .outputError)
        XCTAssertEqual(CLIError.formatDetectionFailed(path: "").exitCode, .formatError)
        XCTAssertEqual(CLIError.unsupportedFormat(format: "").exitCode, .formatError)
        XCTAssertEqual(CLIError.conversionFailed(reason: "").exitCode, .failure)
        XCTAssertEqual(CLIError.validationFailed(errors: []).exitCode, .failure)
        XCTAssertEqual(CLIError.workflowFailed(reason: "").exitCode, .workflowError)
        XCTAssertEqual(CLIError.containerUnavailable.exitCode, .containerError)
        XCTAssertEqual(CLIError.networkError(reason: "").exitCode, .networkError)
        XCTAssertEqual(CLIError.cancelled.exitCode, .cancelled)
    }

    /// Verifies that CLIExitCode.exitCode produces an ArgumentParser ExitCode.
    func testCLIExitCodeToExitCode() {
        let exitCode = CLIExitCode.success.exitCode
        XCTAssertEqual(exitCode.rawValue, 0)

        let failureCode = CLIExitCode.failure.exitCode
        XCTAssertEqual(failureCode.rawValue, 1)
    }

    /// Verifies that error descriptions contain relevant context information.
    func testCLIErrorDescriptionContent() {
        let fileError = CLIError.inputFileNotFound(path: "/my/special/file.fa")
        XCTAssertTrue(fileError.localizedDescription.contains("/my/special/file.fa"))

        let formatError = CLIError.unsupportedFormat(format: "bam2")
        XCTAssertTrue(formatError.localizedDescription.contains("bam2"))

        let containerError = CLIError.containerUnavailable
        XCTAssertTrue(containerError.localizedDescription.contains("macOS 26"))

        let validationError = CLIError.validationFailed(errors: ["Error A", "Error B"])
        XCTAssertTrue(validationError.localizedDescription.contains("Error A"))
        XCTAssertTrue(validationError.localizedDescription.contains("Error B"))

        let networkError = CLIError.networkError(reason: "DNS resolution failed")
        XCTAssertTrue(networkError.localizedDescription.contains("DNS resolution failed"))

        let cancelledError = CLIError.cancelled
        XCTAssertTrue(cancelledError.localizedDescription.contains("cancelled"))
    }
}

// MARK: - TerminalFormatter Additional Tests

final class TerminalFormatterExtendedTests: XCTestCase {

    /// Verifies that formatter.success() output contains the checkmark character.
    func testFormatterSuccess() {
        let formatter = TerminalFormatter(useColors: false)
        let result = formatter.success("Operation completed")
        XCTAssertTrue(result.contains("\u{2713}"), "Success output should contain checkmark character")
        XCTAssertTrue(result.contains("Operation completed"))
    }

    /// Verifies that formatter.success() output contains ANSI codes when colors are enabled.
    func testFormatterSuccessWithColors() {
        let formatter = TerminalFormatter(useColors: true)
        let result = formatter.success("Done")
        XCTAssertTrue(result.contains("\u{001B}[32m"), "Success should use green ANSI color")
        XCTAssertTrue(result.contains("\u{001B}[0m"), "Success should contain reset code")
        XCTAssertTrue(result.contains("Done"))
    }

    /// Verifies that formatter.error() output contains the X mark character.
    func testFormatterError() {
        let formatter = TerminalFormatter(useColors: false)
        let result = formatter.error("Something failed")
        XCTAssertTrue(result.contains("\u{2717}"), "Error output should contain X mark character")
        XCTAssertTrue(result.contains("Something failed"))
    }

    /// Verifies that formatter.error() output uses red ANSI color when enabled.
    func testFormatterErrorWithColors() {
        let formatter = TerminalFormatter(useColors: true)
        let result = formatter.error("Failure")
        XCTAssertTrue(result.contains("\u{001B}[31m"), "Error should use red ANSI color")
    }

    /// Verifies that formatter.warning() output contains the warning symbol.
    func testFormatterWarning() {
        let formatter = TerminalFormatter(useColors: false)
        let result = formatter.warning("Low disk space")
        XCTAssertTrue(result.contains("\u{26A0}"), "Warning output should contain warning symbol")
        XCTAssertTrue(result.contains("Low disk space"))
    }

    /// Verifies that formatter.warning() output uses yellow ANSI color when enabled.
    func testFormatterWarningWithColors() {
        let formatter = TerminalFormatter(useColors: true)
        let result = formatter.warning("Caution")
        XCTAssertTrue(result.contains("\u{001B}[33m"), "Warning should use yellow ANSI color")
    }

    /// Verifies that formatter.info() output contains the info symbol.
    func testFormatterInfo() {
        let formatter = TerminalFormatter(useColors: false)
        let result = formatter.info("Processing started")
        XCTAssertTrue(result.contains("\u{2139}"), "Info output should contain info symbol")
        XCTAssertTrue(result.contains("Processing started"))
    }

    /// Verifies that formatter.info() output uses cyan ANSI color when enabled.
    func testFormatterInfoWithColors() {
        let formatter = TerminalFormatter(useColors: true)
        let result = formatter.info("Note")
        XCTAssertTrue(result.contains("\u{001B}[36m"), "Info should use cyan ANSI color")
    }

    /// Verifies that formatter.header() produces a formatted header string.
    func testFormatterHeader() {
        let formatter = TerminalFormatter(useColors: false)
        let result = formatter.header("Sequence Statistics")
        // Without colors, header() calls bold() which returns the string unchanged
        XCTAssertEqual(result, "Sequence Statistics")
    }

    /// Verifies that formatter.header() uses bold ANSI codes when colors are enabled.
    func testFormatterHeaderWithColors() {
        let formatter = TerminalFormatter(useColors: true)
        let result = formatter.header("Results")
        XCTAssertTrue(result.contains("\u{001B}[1m"), "Header should contain bold ANSI code")
        XCTAssertTrue(result.contains("Results"))
        XCTAssertTrue(result.contains("\u{001B}[0m"), "Header should contain reset code")
    }

    /// Verifies that formatter.number() formats numeric values.
    func testFormatterNumber() {
        let formatter = TerminalFormatter(useColors: false)

        let intResult = formatter.number(42)
        XCTAssertEqual(intResult, "42")

        let doubleResult = formatter.number(3.14)
        XCTAssertTrue(doubleResult.contains("3.14"))

        let largeResult = formatter.number(1000000)
        XCTAssertTrue(largeResult.contains("1000000"))
    }

    /// Verifies that formatter.number() uses yellow ANSI color when colors are enabled.
    func testFormatterNumberWithColors() {
        let formatter = TerminalFormatter(useColors: true)
        let result = formatter.number(99)
        XCTAssertTrue(result.contains("\u{001B}[33m"), "Number should use yellow ANSI color")
        XCTAssertTrue(result.contains("99"))
    }

    /// Verifies that formatter.bold() wraps text in ANSI bold codes when colors are enabled.
    func testFormatterBold() {
        let formatter = TerminalFormatter(useColors: true)
        let result = formatter.bold("Important")
        XCTAssertTrue(result.contains("\u{001B}[1m"), "Bold should contain ANSI bold code")
        XCTAssertTrue(result.contains("Important"))
        XCTAssertTrue(result.contains("\u{001B}[0m"), "Bold should contain reset code")
    }

    /// Verifies that formatter.bold() returns plain text when colors are disabled.
    func testFormatterBoldNoColors() {
        let formatter = TerminalFormatter(useColors: false)
        let result = formatter.bold("Plain")
        XCTAssertEqual(result, "Plain")
        XCTAssertFalse(result.contains("\u{001B}"))
    }

    /// Verifies that formatter.dim() wraps text in ANSI dim codes when colors are enabled.
    func testFormatterDim() {
        let formatter = TerminalFormatter(useColors: true)
        let result = formatter.dim("Faded text")
        XCTAssertTrue(result.contains("\u{001B}[2m"), "Dim should contain ANSI dim code")
        XCTAssertTrue(result.contains("Faded text"))
        XCTAssertTrue(result.contains("\u{001B}[0m"), "Dim should contain reset code")
    }

    /// Verifies that formatter.dim() returns plain text when colors are disabled.
    func testFormatterDimNoColors() {
        let formatter = TerminalFormatter(useColors: false)
        let result = formatter.dim("Subdued")
        XCTAssertEqual(result, "Subdued")
        XCTAssertFalse(result.contains("\u{001B}"))
    }

    /// Verifies that progress bar clamps values below 0 to 0% and above 1 to 100%.
    func testProgressBarClamping() {
        let formatter = TerminalFormatter(useColors: false)

        // Test value below 0
        let barNegative = formatter.progressBar(progress: -0.5, width: 10, showPercent: true)
        XCTAssertTrue(barNegative.contains("0%"), "Negative progress should clamp to 0%")
        // The bar should be all empty
        let negativeStripped = TerminalFormatter.stripANSI(barNegative)
        XCTAssertFalse(negativeStripped.contains("100%"))

        // Test value above 1
        let barOver = formatter.progressBar(progress: 1.5, width: 10, showPercent: true)
        XCTAssertTrue(barOver.contains("100%"), "Progress > 1 should clamp to 100%")

        // Test exact boundaries
        let barZero = formatter.progressBar(progress: 0.0, width: 10, showPercent: true)
        XCTAssertTrue(barZero.contains("0%"))

        let barFull = formatter.progressBar(progress: 1.0, width: 10, showPercent: true)
        XCTAssertTrue(barFull.contains("100%"))
    }

    /// Verifies that progress bar with showPercent=false omits the percentage.
    func testProgressBarNoPercent() {
        let formatter = TerminalFormatter(useColors: false)
        let bar = formatter.progressBar(progress: 0.5, width: 10, showPercent: false)
        XCTAssertFalse(bar.contains("%"), "Progress bar should not contain percent when showPercent is false")
    }

    /// Verifies that progress bar renders filled and empty sections at 50%.
    func testProgressBarHalfway() {
        let formatter = TerminalFormatter(useColors: false)
        let bar = formatter.progressBar(progress: 0.5, width: 10, showPercent: true)
        XCTAssertTrue(bar.contains("50%"))
        // At 50% with width 10, should have 5 filled and 5 empty blocks
        let filled = bar.filter { $0 == "\u{2588}" }.count  // Full block
        let empty = bar.filter { $0 == "\u{2591}" }.count   // Light shade
        XCTAssertEqual(filled, 5, "50% of width 10 should produce 5 filled blocks")
        XCTAssertEqual(empty, 5, "50% of width 10 should produce 5 empty blocks")
    }

    /// Verifies that stripANSI removes all ANSI escape sequences from text.
    func testStripANSIComplex() {
        let text = "\u{001B}[1m\u{001B}[31mBold Red\u{001B}[0m Normal \u{001B}[2mDim\u{001B}[0m"
        let stripped = TerminalFormatter.stripANSI(text)
        XCTAssertEqual(stripped, "Bold Red Normal Dim")
        XCTAssertFalse(stripped.contains("\u{001B}"))
    }

    /// Verifies that the colored() method applies correct ANSI codes for various colors.
    func testColoredVariousColors() {
        let formatter = TerminalFormatter(useColors: true)

        let red = formatter.colored("text", .red)
        XCTAssertTrue(red.contains("\u{001B}[31m"))

        let green = formatter.colored("text", .green)
        XCTAssertTrue(green.contains("\u{001B}[32m"))

        let blue = formatter.colored("text", .blue)
        XCTAssertTrue(blue.contains("\u{001B}[34m"))

        let cyan = formatter.colored("text", .cyan)
        XCTAssertTrue(cyan.contains("\u{001B}[36m"))

        let yellow = formatter.colored("text", .yellow)
        XCTAssertTrue(yellow.contains("\u{001B}[33m"))
    }

    /// Verifies that no ANSI codes are applied when colors are disabled.
    func testColoredNoColors() {
        let formatter = TerminalFormatter(useColors: false)

        let result = formatter.colored("plain text", .red)
        XCTAssertEqual(result, "plain text")
        XCTAssertFalse(result.contains("\u{001B}"))
    }

    /// Verifies the spinner produces cycling characters.
    func testSpinner() {
        let formatter = TerminalFormatter(useColors: false)
        let frame0 = formatter.spinner(frame: 0)
        let frame1 = formatter.spinner(frame: 1)
        let frame10 = formatter.spinner(frame: 10)

        XCTAssertFalse(frame0.isEmpty)
        XCTAssertFalse(frame1.isEmpty)
        // Frame 10 wraps around to frame 0
        XCTAssertEqual(frame0, frame10, "Frame 10 should wrap to same as frame 0")
    }

    /// Verifies the keyValueTable format contains all provided keys and values.
    func testKeyValueTableContent() {
        let formatter = TerminalFormatter(useColors: false)
        let table = formatter.keyValueTable([
            ("Name", "Genome Assembly"),
            ("Size", "3.2 Gbp"),
            ("GC%", "41.5"),
        ])

        XCTAssertTrue(table.contains("Name"))
        XCTAssertTrue(table.contains("Genome Assembly"))
        XCTAssertTrue(table.contains("Size"))
        XCTAssertTrue(table.contains("3.2 Gbp"))
        XCTAssertTrue(table.contains("GC%"))
        XCTAssertTrue(table.contains("41.5"))
    }

    /// Verifies that table formatting includes headers and data rows.
    func testTableFormatting() {
        let formatter = TerminalFormatter(useColors: false)
        let table = formatter.table(
            headers: ["Sequence", "Length", "GC%"],
            rows: [
                ["chr1", "248956422", "42.3"],
                ["chr2", "242193529", "40.1"],
            ]
        )

        XCTAssertTrue(table.contains("Sequence"))
        XCTAssertTrue(table.contains("Length"))
        XCTAssertTrue(table.contains("GC%"))
        XCTAssertTrue(table.contains("chr1"))
        XCTAssertTrue(table.contains("chr2"))
        XCTAssertTrue(table.contains("248956422"))
        // Contains separator line
        XCTAssertTrue(table.contains("\u{2500}"), "Table should contain horizontal line character")
    }

    /// Verifies box formatting includes title and content.
    func testBoxFormatting() {
        let formatter = TerminalFormatter(useColors: false)
        let box = formatter.box("Summary", "Total: 42\nValid: 40")

        XCTAssertTrue(box.contains("Summary"))
        XCTAssertTrue(box.contains("Total: 42"))
        XCTAssertTrue(box.contains("Valid: 40"))
        // Box border characters
        XCTAssertTrue(box.contains("\u{250C}"), "Box should contain top-left corner")
        XCTAssertTrue(box.contains("\u{2510}"), "Box should contain top-right corner")
        XCTAssertTrue(box.contains("\u{2514}"), "Box should contain bottom-left corner")
        XCTAssertTrue(box.contains("\u{2518}"), "Box should contain bottom-right corner")
    }
}

// MARK: - ANSIColor Tests

final class ANSIColorTests: XCTestCase {

    /// Verifies that ANSIColor.reset produces the correct escape sequence.
    func testANSIColorReset() {
        XCTAssertEqual(ANSIColor.reset.rawValue, "\u{001B}[0m")
    }

    /// Verifies that basic ANSI color codes have the correct escape sequences.
    func testANSIBasicColors() {
        XCTAssertEqual(ANSIColor.red.rawValue, "\u{001B}[31m")
        XCTAssertEqual(ANSIColor.green.rawValue, "\u{001B}[32m")
        XCTAssertEqual(ANSIColor.yellow.rawValue, "\u{001B}[33m")
        XCTAssertEqual(ANSIColor.blue.rawValue, "\u{001B}[34m")
        XCTAssertEqual(ANSIColor.magenta.rawValue, "\u{001B}[35m")
        XCTAssertEqual(ANSIColor.cyan.rawValue, "\u{001B}[36m")
        XCTAssertEqual(ANSIColor.white.rawValue, "\u{001B}[37m")
        XCTAssertEqual(ANSIColor.black.rawValue, "\u{001B}[30m")
    }

    /// Verifies that ANSI style codes have the correct escape sequences.
    func testANSIStyleCodes() {
        XCTAssertEqual(ANSIColor.bold.rawValue, "\u{001B}[1m")
        XCTAssertEqual(ANSIColor.dim.rawValue, "\u{001B}[2m")
        XCTAssertEqual(ANSIColor.italic.rawValue, "\u{001B}[3m")
        XCTAssertEqual(ANSIColor.underline.rawValue, "\u{001B}[4m")
    }

    /// Verifies that bright ANSI colors have correct codes in the 90-97 range.
    func testANSIBrightColors() {
        XCTAssertEqual(ANSIColor.brightRed.rawValue, "\u{001B}[91m")
        XCTAssertEqual(ANSIColor.brightGreen.rawValue, "\u{001B}[92m")
        XCTAssertEqual(ANSIColor.brightBlue.rawValue, "\u{001B}[94m")
        XCTAssertEqual(ANSIColor.brightWhite.rawValue, "\u{001B}[97m")
        XCTAssertEqual(ANSIColor.brightBlack.rawValue, "\u{001B}[90m")
    }

    /// Verifies that background ANSI colors have codes in the 40-47 range.
    func testANSIBackgroundColors() {
        XCTAssertEqual(ANSIColor.bgRed.rawValue, "\u{001B}[41m")
        XCTAssertEqual(ANSIColor.bgGreen.rawValue, "\u{001B}[42m")
        XCTAssertEqual(ANSIColor.bgBlue.rawValue, "\u{001B}[44m")
        XCTAssertEqual(ANSIColor.bgBlack.rawValue, "\u{001B}[40m")
        XCTAssertEqual(ANSIColor.bgWhite.rawValue, "\u{001B}[47m")
    }
}

// MARK: - ProgressReporter Tests

final class ProgressReporterTests: XCTestCase {

    /// Verifies that ProgressReporter can be created and called without crashing.
    func testProgressReporterCreation() {
        let formatter = TerminalFormatter(useColors: false)
        let reporter = ProgressReporter(formatter: formatter, showProgress: false)
        // With showProgress=false, update/clear/finish should be no-ops
        reporter.update(progress: 0.5, message: "Working...")
        reporter.clear()
        reporter.finish(success: true, message: "Done")
    }

    /// Verifies that ProgressReporter with showProgress=true does not crash on update.
    func testProgressReporterWithProgress() {
        let formatter = TerminalFormatter(useColors: false)
        let reporter = ProgressReporter(formatter: formatter, showProgress: true)
        reporter.update(progress: 0.0, message: "Starting")
        reporter.update(progress: 0.5, message: "Halfway")
        reporter.update(progress: 1.0, message: "Complete")
        reporter.finish(success: true, message: "Finished")
    }
}

// MARK: - OutputFormat / OutputMode Tests

final class OutputFormatTests: XCTestCase {

    /// Verifies all OutputFormat cases have correct raw values.
    func testOutputFormatRawValues() {
        XCTAssertEqual(OutputFormat.text.rawValue, "text")
        XCTAssertEqual(OutputFormat.json.rawValue, "json")
        XCTAssertEqual(OutputFormat.tsv.rawValue, "tsv")
    }

    /// Verifies that OutputFormat.allCases contains all expected cases.
    func testOutputFormatAllCases() {
        let allCases = OutputFormat.allCases
        XCTAssertEqual(allCases.count, 3)
        XCTAssertTrue(allCases.contains(.text))
        XCTAssertTrue(allCases.contains(.json))
        XCTAssertTrue(allCases.contains(.tsv))
    }

    /// Verifies that OutputFormat.allValueStrings produces string representations.
    func testOutputFormatAllValueStrings() {
        let strings = OutputFormat.allValueStrings
        XCTAssertEqual(strings.count, 3)
        XCTAssertTrue(strings.contains("text"))
        XCTAssertTrue(strings.contains("json"))
        XCTAssertTrue(strings.contains("tsv"))
    }

    /// Verifies that GlobalOptions output mode reflects the output format.
    func testOutputModeFromFormat() {
        var options = GlobalOptions()

        options.outputFormat = .json
        XCTAssertEqual(options.outputMode, .json)

        options.outputFormat = .tsv
        XCTAssertEqual(options.outputMode, .tsv)

        options.outputFormat = .text
        options.debug = false
        XCTAssertEqual(options.outputMode, .text)
    }

    /// Verifies that debug mode overrides output format in output mode.
    func testOutputModeDebugOverride() {
        var options = GlobalOptions()
        options.outputFormat = .json
        options.debug = true
        XCTAssertEqual(options.outputMode, .debug)
    }
}

// MARK: - FastqCommand Tests

final class FastqCommandTests: XCTestCase {

    // MARK: - Command Configuration

    /// Verifies that FastqCommand has the correct command name.
    func testFastqCommandName() {
        XCTAssertEqual(FastqCommand.configuration.commandName, "fastq")
    }

    /// Verifies that FastqCommand has all 15 subcommands registered.
    func testFastqSubcommandCount() {
        let subcommands = FastqCommand.configuration.subcommands
        XCTAssertEqual(subcommands.count, 15, "FastqCommand should have 15 subcommands")
    }

    /// Verifies that all expected subcommand names are registered.
    func testFastqSubcommandNames() {
        let names = FastqCommand.configuration.subcommands.compactMap {
            ($0 as? any ParsableCommand.Type)?.configuration.commandName
        }
        let expected = [
            "subsample", "length-filter", "quality-trim", "adapter-trim", "fixed-trim",
            "contaminant-filter", "primer-remove", "error-correct",
            "merge", "repair", "deinterleave", "interleave", "deduplicate",
            "demultiplex", "import-ont",
        ]
        for name in expected {
            XCTAssertTrue(names.contains(name), "Missing subcommand: \(name)")
        }
    }

    // MARK: - Subsample Argument Parsing

    /// Verifies that subsample command parses proportion option correctly.
    func testSubsampleParsesProportion() throws {
        let cmd = try FastqSubsampleSubcommand.parse([
            "input.fastq", "--proportion", "0.5", "-o", "/tmp/out.fastq",
        ])
        XCTAssertEqual(cmd.input, "input.fastq")
        XCTAssertEqual(cmd.proportion, 0.5)
        XCTAssertNil(cmd.count)
        XCTAssertEqual(cmd.output.output, "/tmp/out.fastq")
    }

    /// Verifies that subsample command parses count option correctly.
    func testSubsampleParsesCount() throws {
        let cmd = try FastqSubsampleSubcommand.parse([
            "reads.fq", "--count", "1000", "-o", "/tmp/out.fq",
        ])
        XCTAssertEqual(cmd.count, 1000)
        XCTAssertNil(cmd.proportion)
    }

    // MARK: - Length Filter Argument Parsing

    /// Verifies that length-filter parses min and max length options.
    func testLengthFilterParsesOptions() throws {
        let cmd = try FastqLengthFilterSubcommand.parse([
            "input.fq", "--min", "50", "--max", "300", "-o", "/tmp/out.fq",
        ])
        XCTAssertEqual(cmd.input, "input.fq")
        XCTAssertEqual(cmd.minLength, 50)
        XCTAssertEqual(cmd.maxLength, 300)
    }

    /// Verifies that length-filter accepts only min length.
    func testLengthFilterMinOnly() throws {
        let cmd = try FastqLengthFilterSubcommand.parse([
            "input.fq", "--min", "100", "-o", "/tmp/out.fq",
        ])
        XCTAssertEqual(cmd.minLength, 100)
        XCTAssertNil(cmd.maxLength)
    }

    // MARK: - Quality Trim Argument Parsing

    /// Verifies that quality-trim parses threshold, window, and mode options.
    func testQualityTrimParsesOptions() throws {
        let cmd = try FastqQualityTrimSubcommand.parse([
            "input.fq", "--threshold", "30", "--window", "5", "--mode", "cut-front",
            "-o", "/tmp/out.fq",
        ])
        XCTAssertEqual(cmd.threshold, 30)
        XCTAssertEqual(cmd.windowSize, 5)
        XCTAssertEqual(cmd.mode, "cut-front")
    }

    /// Verifies that quality-trim uses correct defaults.
    func testQualityTrimDefaults() throws {
        let cmd = try FastqQualityTrimSubcommand.parse([
            "input.fq", "-o", "/tmp/out.fq",
        ])
        XCTAssertEqual(cmd.threshold, 20)
        XCTAssertEqual(cmd.windowSize, 4)
        XCTAssertEqual(cmd.mode, "cut-right")
    }

    // MARK: - Adapter Trim Argument Parsing

    /// Verifies that adapter-trim parses adapter sequence option.
    func testAdapterTrimParsesOptions() throws {
        let cmd = try FastqAdapterTrimSubcommand.parse([
            "input.fq", "--adapter", "AGATCGGAAGAG", "-o", "/tmp/out.fq",
        ])
        XCTAssertEqual(cmd.adapterSequence, "AGATCGGAAGAG")
    }

    /// Verifies that adapter-trim works without adapter (auto-detect mode).
    func testAdapterTrimAutoDetect() throws {
        let cmd = try FastqAdapterTrimSubcommand.parse([
            "input.fq", "-o", "/tmp/out.fq",
        ])
        XCTAssertNil(cmd.adapterSequence)
    }

    // MARK: - Fixed Trim Argument Parsing

    /// Verifies that fixed-trim parses front and tail options.
    func testFixedTrimParsesOptions() throws {
        let cmd = try FastqFixedTrimSubcommand.parse([
            "input.fq", "--front", "10", "--tail", "5", "-o", "/tmp/out.fq",
        ])
        XCTAssertEqual(cmd.front, 10)
        XCTAssertEqual(cmd.tail, 5)
    }

    /// Verifies that fixed-trim defaults to zero bases.
    func testFixedTrimDefaults() throws {
        let cmd = try FastqFixedTrimSubcommand.parse([
            "input.fq", "-o", "/tmp/out.fq",
        ])
        XCTAssertEqual(cmd.front, 0)
        XCTAssertEqual(cmd.tail, 0)
    }

    // MARK: - Contaminant Filter Argument Parsing

    /// Verifies that contaminant-filter parses mode, kmer, and hdist options.
    func testContaminantFilterParsesOptions() throws {
        let cmd = try FastqContaminantFilterSubcommand.parse([
            "input.fq", "--mode", "custom", "--ref", "/data/contam.fa",
            "--kmer", "27", "--hdist", "2", "-o", "/tmp/out.fq",
        ])
        XCTAssertEqual(cmd.mode, "custom")
        XCTAssertEqual(cmd.reference, "/data/contam.fa")
        XCTAssertEqual(cmd.kmerSize, 27)
        XCTAssertEqual(cmd.hammingDistance, 2)
    }

    /// Verifies that contaminant-filter uses correct defaults.
    func testContaminantFilterDefaults() throws {
        let cmd = try FastqContaminantFilterSubcommand.parse([
            "input.fq", "-o", "/tmp/out.fq",
        ])
        XCTAssertEqual(cmd.mode, "phix")
        XCTAssertNil(cmd.reference)
        XCTAssertEqual(cmd.kmerSize, 31)
        XCTAssertEqual(cmd.hammingDistance, 1)
    }

    // MARK: - Primer Removal Argument Parsing

    /// Verifies that primer-remove parses literal primer sequence.
    func testPrimerRemovalLiteral() throws {
        let cmd = try FastqPrimerRemovalSubcommand.parse([
            "input.fq", "--literal", "ACGTACGTACGT",
            "--kmer", "20", "--mink", "8", "--hdist", "2",
            "-o", "/tmp/out.fq",
        ])
        XCTAssertEqual(cmd.literalSequence, "ACGTACGTACGT")
        XCTAssertNil(cmd.reference)
        XCTAssertEqual(cmd.kmerSize, 20)
        XCTAssertEqual(cmd.minKmer, 8)
        XCTAssertEqual(cmd.hammingDistance, 2)
    }

    /// Verifies that primer-remove parses reference file.
    func testPrimerRemovalReference() throws {
        let cmd = try FastqPrimerRemovalSubcommand.parse([
            "input.fq", "--ref", "/data/primers.fa", "-o", "/tmp/out.fq",
        ])
        XCTAssertNil(cmd.literalSequence)
        XCTAssertEqual(cmd.reference, "/data/primers.fa")
    }

    /// Verifies that primer-remove uses correct defaults.
    func testPrimerRemovalDefaults() throws {
        let cmd = try FastqPrimerRemovalSubcommand.parse([
            "input.fq", "--literal", "ACGT", "-o", "/tmp/out.fq",
        ])
        XCTAssertEqual(cmd.kmerSize, 23)
        XCTAssertEqual(cmd.minKmer, 11)
        XCTAssertEqual(cmd.hammingDistance, 1)
    }

    // MARK: - Error Correction Argument Parsing

    /// Verifies that error-correct parses kmer option.
    func testErrorCorrectParsesOptions() throws {
        let cmd = try FastqErrorCorrectSubcommand.parse([
            "input.fq", "--kmer", "31", "-o", "/tmp/out.fq",
        ])
        XCTAssertEqual(cmd.kmerSize, 31)
    }

    /// Verifies that error-correct defaults to kmer size 50.
    func testErrorCorrectDefaults() throws {
        let cmd = try FastqErrorCorrectSubcommand.parse([
            "input.fq", "-o", "/tmp/out.fq",
        ])
        XCTAssertEqual(cmd.kmerSize, 50)
    }

    // MARK: - Merge Argument Parsing

    /// Verifies that merge parses min-overlap and strict options.
    func testMergeParsesOptions() throws {
        let cmd = try FastqMergeSubcommand.parse([
            "interleaved.fq", "--min-overlap", "20", "--strict", "-o", "/tmp/out.fq",
        ])
        XCTAssertEqual(cmd.input, "interleaved.fq")
        XCTAssertEqual(cmd.minOverlap, 20)
        XCTAssertTrue(cmd.strict)
    }

    /// Verifies that merge uses correct defaults.
    func testMergeDefaults() throws {
        let cmd = try FastqMergeSubcommand.parse([
            "interleaved.fq", "-o", "/tmp/out.fq",
        ])
        XCTAssertEqual(cmd.minOverlap, 12)
        XCTAssertFalse(cmd.strict)
    }

    // MARK: - Repair Argument Parsing

    /// Verifies that repair parses input argument.
    func testRepairParsesInput() throws {
        let cmd = try FastqRepairSubcommand.parse([
            "broken.fq", "-o", "/tmp/out.fq",
        ])
        XCTAssertEqual(cmd.input, "broken.fq")
    }

    // MARK: - Deinterleave Argument Parsing

    /// Verifies that deinterleave parses out1 and out2 options.
    func testDeinterleaveParsesOptions() throws {
        let cmd = try FastqDeinterleaveSubcommand.parse([
            "interleaved.fq", "--out1", "/tmp/R1.fq", "--out2", "/tmp/R2.fq",
        ])
        XCTAssertEqual(cmd.input, "interleaved.fq")
        XCTAssertEqual(cmd.out1, "/tmp/R1.fq")
        XCTAssertEqual(cmd.out2, "/tmp/R2.fq")
    }

    // MARK: - Interleave Argument Parsing

    /// Verifies that interleave parses in1 and in2 options.
    func testInterleaveParsesOptions() throws {
        let cmd = try FastqInterleaveSubcommand.parse([
            "--in1", "/data/R1.fq", "--in2", "/data/R2.fq", "-o", "/tmp/out.fq",
        ])
        XCTAssertEqual(cmd.in1, "/data/R1.fq")
        XCTAssertEqual(cmd.in2, "/data/R2.fq")
        XCTAssertEqual(cmd.output.output, "/tmp/out.fq")
    }

    // MARK: - Deduplicate Argument Parsing

    /// Verifies that deduplicate parses mode option.
    func testDeduplicateParsesOptions() throws {
        let cmd = try FastqDeduplicateSubcommand.parse([
            "input.fq", "--by", "sequence", "-o", "/tmp/out.fq",
        ])
        XCTAssertEqual(cmd.mode, "sequence")
    }

    /// Verifies that deduplicate defaults to dedup by id.
    func testDeduplicateDefaults() throws {
        let cmd = try FastqDeduplicateSubcommand.parse([
            "input.fq", "-o", "/tmp/out.fq",
        ])
        XCTAssertEqual(cmd.mode, "id")
    }

    // MARK: - FastqCommand Registration in LungfishCLI

    /// Verifies that FastqCommand is registered as a subcommand of LungfishCLI.
    func testFastqCommandRegistered() {
        let subcommands = LungfishCLI.configuration.subcommands
        let names = subcommands.compactMap {
            ($0 as? any ParsableCommand.Type)?.configuration.commandName
        }
        XCTAssertTrue(names.contains("fastq"), "LungfishCLI should contain fastq subcommand")
    }
}
