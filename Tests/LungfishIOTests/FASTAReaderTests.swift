// FASTAReaderTests.swift - Comprehensive tests for FASTA file reading
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
@testable import LungfishIO
@testable import LungfishCore

final class FASTAReaderTests: XCTestCase {

    // MARK: - Test Fixtures

    var tempDirectory: URL!

    override func setUp() async throws {
        // Create a temporary directory for test files
        tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("LungfishTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        // Clean up temporary files
        if let tempDir = tempDirectory {
            try? FileManager.default.removeItem(at: tempDir)
        }
    }

    /// Creates a temporary FASTA file with the given content
    private func createTempFASTA(_ content: String, filename: String = "test.fasta") throws -> URL {
        let fileURL = tempDirectory.appendingPathComponent(filename)
        try content.write(to: fileURL, atomically: true, encoding: .utf8)
        return fileURL
    }

    // MARK: - Basic Reading Tests

    func testReadSingleSequence() async throws {
        let content = """
        >seq1 Test sequence
        ATCGATCGATCG
        """

        let fileURL = try createTempFASTA(content)
        let reader = try FASTAReader(url: fileURL)
        let sequences = try await reader.readAll()

        XCTAssertEqual(sequences.count, 1)
        XCTAssertEqual(sequences[0].name, "seq1")
        XCTAssertEqual(sequences[0].description, "Test sequence")
        XCTAssertEqual(sequences[0].asString(), "ATCGATCGATCG")
        XCTAssertEqual(sequences[0].length, 12)
    }

    func testReadMultipleSequences() async throws {
        let content = """
        >seq1 First sequence
        ATCGATCG
        >seq2 Second sequence
        GGGGCCCC
        >seq3 Third sequence
        AAAATTTT
        """

        let fileURL = try createTempFASTA(content)
        let reader = try FASTAReader(url: fileURL)
        let sequences = try await reader.readAll()

        XCTAssertEqual(sequences.count, 3)
        XCTAssertEqual(sequences[0].name, "seq1")
        XCTAssertEqual(sequences[1].name, "seq2")
        XCTAssertEqual(sequences[2].name, "seq3")
        XCTAssertEqual(sequences[0].asString(), "ATCGATCG")
        XCTAssertEqual(sequences[1].asString(), "GGGGCCCC")
        XCTAssertEqual(sequences[2].asString(), "AAAATTTT")
    }

    func testReadMultiLineSequence() async throws {
        let content = """
        >seq1 Multi-line sequence
        ATCGATCG
        ATCGATCG
        ATCGATCG
        ATCGATCG
        """

        let fileURL = try createTempFASTA(content)
        let reader = try FASTAReader(url: fileURL)
        let sequences = try await reader.readAll()

        XCTAssertEqual(sequences.count, 1)
        XCTAssertEqual(sequences[0].asString(), "ATCGATCGATCGATCGATCGATCGATCGATCG")
        XCTAssertEqual(sequences[0].length, 32)
    }

    func testReadVaryingLineLengths() async throws {
        let content = """
        >seq1
        ATCG
        ATCGATCGATCGATCGATCG
        AT
        ATCGATCGATCGATCGATCGATCGATCGATCG
        """

        let fileURL = try createTempFASTA(content)
        let reader = try FASTAReader(url: fileURL)
        let sequences = try await reader.readAll()

        XCTAssertEqual(sequences.count, 1)
        XCTAssertEqual(sequences[0].length, 58)  // 4 + 20 + 2 + 32
    }

    // MARK: - Header Parsing Tests

    func testParseHeaderNameOnly() async throws {
        let content = """
        >sequence_name
        ATCG
        """

        let fileURL = try createTempFASTA(content)
        let reader = try FASTAReader(url: fileURL)
        let sequences = try await reader.readAll()

        XCTAssertEqual(sequences[0].name, "sequence_name")
        XCTAssertNil(sequences[0].description)
    }

    func testParseHeaderWithDescription() async throws {
        let content = """
        >seq1 This is a description with spaces
        ATCG
        """

        let fileURL = try createTempFASTA(content)
        let reader = try FASTAReader(url: fileURL)
        let sequences = try await reader.readAll()

        XCTAssertEqual(sequences[0].name, "seq1")
        XCTAssertEqual(sequences[0].description, "This is a description with spaces")
    }

    func testParseHeaderSplitsOnTabWhitespace() async throws {
        let content = """
        >seq1\tThis is a tab separated description
        ATCG
        """

        let fileURL = try createTempFASTA(content)
        let reader = try FASTAReader(url: fileURL)
        let sequences = try await reader.readAll()

        XCTAssertEqual(sequences[0].name, "seq1")
        XCTAssertEqual(sequences[0].description, "This is a tab separated description")
    }

    func testParseHeaderWithSpecialCharacters() async throws {
        let content = """
        >chr1:100-200|gene=BRCA1|organism=Homo_sapiens
        ATCGATCG
        """

        let fileURL = try createTempFASTA(content)
        let reader = try FASTAReader(url: fileURL)
        let sequences = try await reader.readAll()

        XCTAssertEqual(sequences[0].name, "chr1:100-200|gene=BRCA1|organism=Homo_sapiens")
    }

    func testReadHeaders() async throws {
        let content = """
        >seq1 First description
        ATCGATCG
        >seq2 Second description
        GGGGCCCC
        >seq3
        AAAATTTT
        """

        let fileURL = try createTempFASTA(content)
        let reader = try FASTAReader(url: fileURL)
        let headers = try await reader.readHeaders()

        XCTAssertEqual(headers.count, 3)
        XCTAssertEqual(headers[0].name, "seq1")
        XCTAssertEqual(headers[0].description, "First description")
        XCTAssertEqual(headers[1].name, "seq2")
        XCTAssertEqual(headers[2].name, "seq3")
        XCTAssertNil(headers[2].description)
    }

    func testReadAllSupportsGzippedFASTA() async throws {
        let content = """
        >seq1 gzip description
        ATCGATCG
        >seq2
        GGGGCCCC
        """
        let fileURL = tempDirectory.appendingPathComponent("test.fa.gz")
        try GzipTestHelper.writeGzip(content, to: fileURL)

        let reader = try FASTAReader(url: fileURL)
        let sequences = try await reader.readAll()

        XCTAssertTrue(reader.isCompressed)
        XCTAssertEqual(sequences.count, 2)
        XCTAssertEqual(sequences[0].name, "seq1")
        XCTAssertEqual(sequences[0].description, "gzip description")
        XCTAssertEqual(sequences[0].asString(), "ATCGATCG")
        XCTAssertEqual(sequences[1].name, "seq2")
        XCTAssertEqual(sequences[1].asString(), "GGGGCCCC")
    }

    func testSequencesSupportsGzippedFASTA() async throws {
        let content = """
        >seq1
        ATCG
        >seq2
        GCTA
        """
        let fileURL = tempDirectory.appendingPathComponent("stream.fasta.gz")
        try GzipTestHelper.writeGzip(content, to: fileURL)

        let reader = try FASTAReader(url: fileURL)
        var names: [String] = []
        for try await sequence in reader.sequences() {
            names.append(sequence.name)
        }

        XCTAssertEqual(names, ["seq1", "seq2"])
    }

    func testReadHeadersSupportsGzippedFASTA() async throws {
        let content = """
        >seq1 first compressed header
        ATCG
        >seq2
        GCTA
        """
        let fileURL = tempDirectory.appendingPathComponent("headers.fa.gz")
        try GzipTestHelper.writeGzip(content, to: fileURL)

        let reader = try FASTAReader(url: fileURL)
        let headers = try await reader.readHeaders()

        XCTAssertEqual(headers.count, 2)
        XCTAssertEqual(headers[0].name, "seq1")
        XCTAssertEqual(headers[0].description, "first compressed header")
        XCTAssertEqual(headers[1].name, "seq2")
        XCTAssertNil(headers[1].description)
    }

    // MARK: - Alphabet Detection Tests

    func testAutoDetectDNA() async throws {
        let content = """
        >dna_seq
        ATCGATCGATCGATCG
        """

        let fileURL = try createTempFASTA(content)
        let reader = try FASTAReader(url: fileURL)
        let sequences = try await reader.readAll()

        XCTAssertEqual(sequences[0].alphabet, .dna)
    }

    func testAutoDetectRNA() async throws {
        let content = """
        >rna_seq
        AUCGAUCGAUCGAUCG
        """

        let fileURL = try createTempFASTA(content)
        let reader = try FASTAReader(url: fileURL)
        let sequences = try await reader.readAll()

        XCTAssertEqual(sequences[0].alphabet, .rna)
    }

    func testAutoDetectProtein() async throws {
        let content = """
        >protein_seq
        MKTAYIAKQRQISFVKSHFSRQLEERLGLI
        """

        let fileURL = try createTempFASTA(content)
        let reader = try FASTAReader(url: fileURL)
        let sequences = try await reader.readAll()

        XCTAssertEqual(sequences[0].alphabet, .protein)
    }

    func testExplicitAlphabet() async throws {
        let content = """
        >seq1
        ATCGATCG
        """

        let fileURL = try createTempFASTA(content)
        let reader = try FASTAReader(url: fileURL)
        let sequences = try await reader.readAll(alphabet: .dna)

        XCTAssertEqual(sequences[0].alphabet, .dna)
    }

    // MARK: - Edge Cases

    func testEmptyFile() async throws {
        let content = ""

        let fileURL = try createTempFASTA(content)
        let reader = try FASTAReader(url: fileURL)
        let sequences = try await reader.readAll()

        XCTAssertTrue(sequences.isEmpty)
    }

    func testFileWithOnlyHeader() async throws {
        let content = ">header_only"

        let fileURL = try createTempFASTA(content)
        let reader = try FASTAReader(url: fileURL)
        let sequences = try await reader.readAll()

        // Empty sequence (no bases after header) should be skipped
        XCTAssertTrue(sequences.isEmpty)
    }

    func testFileWithEmptyLines() async throws {
        let content = """
        >seq1 Test

        ATCG

        ATCG

        >seq2

        GGGG
        """

        let fileURL = try createTempFASTA(content)
        let reader = try FASTAReader(url: fileURL)
        let sequences = try await reader.readAll()

        XCTAssertEqual(sequences.count, 2)
        XCTAssertEqual(sequences[0].asString(), "ATCGATCG")
        XCTAssertEqual(sequences[1].asString(), "GGGG")
    }

    func testFileWithLeadingWhitespace() async throws {
        let content = """
        >seq1
           ATCG
           ATCG
        """

        let fileURL = try createTempFASTA(content)
        let reader = try FASTAReader(url: fileURL)
        let sequences = try await reader.readAll()

        XCTAssertEqual(sequences[0].asString(), "ATCGATCG")
    }

    func testFileWithTrailingWhitespace() async throws {
        let content = ">seq1\nATCG   \nATCG   \n"

        let fileURL = try createTempFASTA(content)
        let reader = try FASTAReader(url: fileURL)
        let sequences = try await reader.readAll()

        XCTAssertEqual(sequences[0].asString(), "ATCGATCG")
    }

    func testLowercaseBases() async throws {
        let content = """
        >seq1
        atcgatcg
        """

        let fileURL = try createTempFASTA(content)
        let reader = try FASTAReader(url: fileURL)
        let sequences = try await reader.readAll()

        XCTAssertEqual(sequences.count, 1)
        XCTAssertEqual(sequences[0].length, 8)
    }

    func testMixedCaseBases() async throws {
        let content = """
        >seq1
        AtCgAtCg
        """

        let fileURL = try createTempFASTA(content)
        let reader = try FASTAReader(url: fileURL)
        let sequences = try await reader.readAll()

        XCTAssertEqual(sequences.count, 1)
    }

    func testAmbiguousBases() async throws {
        let content = """
        >seq1
        ATCGNNNNATCG
        RYSWKMBDHVN
        """

        let fileURL = try createTempFASTA(content)
        let reader = try FASTAReader(url: fileURL)
        let sequences = try await reader.readAll()

        XCTAssertEqual(sequences.count, 1)
        XCTAssertTrue(sequences[0].asString().contains("N"))
    }

    // MARK: - Error Handling Tests

    func testFileNotFound() async {
        let fileURL = URL(fileURLWithPath: "/nonexistent/path/file.fasta")

        do {
            _ = try FASTAReader(url: fileURL)
            XCTFail("Should throw error for non-existent file")
        } catch let error as FASTAError {
            if case .fileNotFound(_) = error {
                // Expected
            } else {
                XCTFail("Wrong error type: \(error)")
            }
        } catch {
            XCTFail("Unexpected error type: \(error)")
        }
    }

    func testSequenceBeforeHeader() async throws {
        let content = """
        ATCGATCG
        >seq1
        GGGG
        """

        let fileURL = try createTempFASTA(content)
        let reader = try FASTAReader(url: fileURL)

        do {
            _ = try await reader.readAll()
            XCTFail("Should throw error for sequence before header")
        } catch let error as FASTAError {
            if case .sequenceBeforeHeader(let line) = error {
                XCTAssertEqual(line, 1)
            } else {
                XCTFail("Wrong error type: \(error)")
            }
        } catch {
            XCTFail("Unexpected error type: \(error)")
        }
    }

    func testInvalidCharacter() async throws {
        let content = """
        >seq1
        ATCG123XYZ
        """

        let fileURL = try createTempFASTA(content)
        let reader = try FASTAReader(url: fileURL)

        do {
            _ = try await reader.readAll(alphabet: .dna)
            XCTFail("Should throw error for invalid characters")
        } catch let error as FASTAError {
            if case .invalidSequence(let name, _) = error {
                XCTAssertEqual(name, "seq1")
            } else {
                XCTFail("Wrong error type: \(error)")
            }
        } catch {
            XCTFail("Unexpected error type: \(error)")
        }
    }

    // MARK: - Streaming Tests

    func testSequenceStream() async throws {
        let content = """
        >seq1
        ATCG
        >seq2
        GGGG
        >seq3
        CCCC
        """

        let fileURL = try createTempFASTA(content)
        let reader = try FASTAReader(url: fileURL)

        var count = 0
        for try await sequence in reader.sequences() {
            count += 1
            XCTAssertEqual(sequence.length, 4)
        }

        XCTAssertEqual(count, 3)
    }

    func testStreamStopsOnError() async throws {
        let content = """
        >seq1
        ATCG
        >seq2
        INVALID123
        >seq3
        GGGG
        """

        let fileURL = try createTempFASTA(content)
        let reader = try FASTAReader(url: fileURL)

        var sequences: [Sequence] = []
        var errorThrown = false

        do {
            for try await sequence in reader.sequences(alphabet: .dna) {
                sequences.append(sequence)
            }
        } catch {
            errorThrown = true
        }

        XCTAssertTrue(errorThrown)
        XCTAssertEqual(sequences.count, 1)  // First valid sequence before error
    }

    // MARK: - Large File Tests

    func testLargeFile() async throws {
        var content = ""
        for i in 0..<100 {
            content += ">seq\(i)\n"
            content += String(repeating: "ATCGATCGATCGATCGATCG", count: 50) + "\n"  // 1000 bp each
        }

        let fileURL = try createTempFASTA(content)
        let reader = try FASTAReader(url: fileURL)
        let sequences = try await reader.readAll()

        XCTAssertEqual(sequences.count, 100)
        for seq in sequences {
            XCTAssertEqual(seq.length, 1000)
        }
    }

    func testVeryLongSequence() async throws {
        var content = ">long_sequence\n"
        // Create a 100,000 bp sequence
        content += String(repeating: "ATCGATCGATCGATCGATCGATCGATCGATCGATCGATCGATCGATCGATCGATCGATCG\n", count: 1667)

        let fileURL = try createTempFASTA(content)
        let reader = try FASTAReader(url: fileURL)
        let sequences = try await reader.readAll()

        XCTAssertEqual(sequences.count, 1)
        XCTAssertGreaterThan(sequences[0].length, 90000)
    }

    // MARK: - File Extension Tests

    func testSupportedExtensions() {
        let supported = FASTAReader.supportedExtensions
        XCTAssertTrue(supported.contains("fa"))
        XCTAssertTrue(supported.contains("fasta"))
        XCTAssertTrue(supported.contains("fna"))
        XCTAssertTrue(supported.contains("faa"))
        XCTAssertTrue(supported.contains("ffn"))
    }

    func testVariousFileExtensions() async throws {
        let content = """
        >seq1
        ATCG
        """

        for ext in ["fa", "fasta", "fna", "faa"] {
            let fileURL = try createTempFASTA(content, filename: "test.\(ext)")
            let reader = try FASTAReader(url: fileURL)
            let sequences = try await reader.readAll()
            XCTAssertEqual(sequences.count, 1, "Failed for extension: \(ext)")
        }
    }

    // MARK: - Performance Tests

    func testReadPerformance() async throws {
        // Create a file with 1000 sequences of 1000 bp each
        var content = ""
        for i in 0..<1000 {
            content += ">seq\(i)\n"
            content += String(repeating: "ATCG", count: 250) + "\n"
        }

        let fileURL = try createTempFASTA(content, filename: "performance_test.fasta")
        let reader = try FASTAReader(url: fileURL)

        measure {
            let expectation = self.expectation(description: "Read completes")
            Task {
                _ = try? await reader.readAll()
                expectation.fulfill()
            }
            wait(for: [expectation], timeout: 10.0)
        }
    }
}

// MARK: - FASTAWriter Tests

final class FASTAWriterTests: XCTestCase {

    var tempDirectory: URL!

    override func setUp() async throws {
        tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("LungfishWriterTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        if let tempDir = tempDirectory {
            try? FileManager.default.removeItem(at: tempDir)
        }
    }

    func testWriteSingleSequence() async throws {
        let fileURL = tempDirectory.appendingPathComponent("output.fasta")
        let writer = FASTAWriter(url: fileURL)

        let sequence = try Sequence(name: "test", description: "Test sequence", alphabet: .dna, bases: "ATCGATCG")
        try writer.write([sequence])

        // Read back and verify
        let reader = try FASTAReader(url: fileURL)
        let sequences = try await reader.readAll()

        XCTAssertEqual(sequences.count, 1)
        XCTAssertEqual(sequences[0].name, "test")
        XCTAssertEqual(sequences[0].description, "Test sequence")
        XCTAssertEqual(sequences[0].asString(), "ATCGATCG")
    }

    func testWriteMultipleSequences() async throws {
        let fileURL = tempDirectory.appendingPathComponent("multi.fasta")
        let writer = FASTAWriter(url: fileURL)

        let sequences = [
            try Sequence(name: "seq1", alphabet: .dna, bases: "ATCG"),
            try Sequence(name: "seq2", alphabet: .dna, bases: "GGGG"),
            try Sequence(name: "seq3", alphabet: .dna, bases: "CCCC")
        ]
        try writer.write(sequences)

        // Read back and verify
        let reader = try FASTAReader(url: fileURL)
        let readSequences = try await reader.readAll()

        XCTAssertEqual(readSequences.count, 3)
    }

    func testWriteLineWidth() async throws {
        let fileURL = tempDirectory.appendingPathComponent("linewidth.fasta")
        let writer = FASTAWriter(url: fileURL, lineWidth: 10)

        // Create a 25 bp sequence
        let sequence = try Sequence(name: "test", alphabet: .dna, bases: "ATCGATCGATCGATCGATCGATCGA")
        try writer.write([sequence])

        // Read the raw file and check line lengths
        let content = try String(contentsOf: fileURL, encoding: .utf8)
        let lines = content.split(separator: "\n", omittingEmptySubsequences: false)

        // Should have: header, 10bp, 10bp, 5bp
        XCTAssertEqual(lines[1].count, 10)
        XCTAssertEqual(lines[2].count, 10)
        XCTAssertEqual(lines[3].count, 5)
    }

    func testAppendSequence() async throws {
        let fileURL = tempDirectory.appendingPathComponent("append.fasta")
        let writer = FASTAWriter(url: fileURL)

        // Write first sequence
        let seq1 = try Sequence(name: "seq1", alphabet: .dna, bases: "ATCG")
        try writer.write([seq1])

        // Append second sequence
        let seq2 = try Sequence(name: "seq2", alphabet: .dna, bases: "GGGG")
        try writer.append(seq2)

        // Read back and verify
        let reader = try FASTAReader(url: fileURL)
        let sequences = try await reader.readAll()

        XCTAssertEqual(sequences.count, 2)
        XCTAssertEqual(sequences[0].name, "seq1")
        XCTAssertEqual(sequences[1].name, "seq2")
    }

    func testRoundTrip() async throws {
        let fileURL = tempDirectory.appendingPathComponent("roundtrip.fasta")
        let writer = FASTAWriter(url: fileURL)

        let originalSequences = [
            try Sequence(name: "seq1", description: "First", alphabet: .dna, bases: "ATCGATCGATCGATCGATCGATCGATCG"),
            try Sequence(name: "seq2", description: "Second with longer description", alphabet: .dna, bases: "GGGGCCCCAAAATTTT"),
            try Sequence(name: "seq3", alphabet: .dna, bases: "NNNNNNNN")
        ]

        try writer.write(originalSequences)

        let reader = try FASTAReader(url: fileURL)
        let readSequences = try await reader.readAll()

        XCTAssertEqual(readSequences.count, originalSequences.count)

        for (original, read) in zip(originalSequences, readSequences) {
            XCTAssertEqual(read.name, original.name)
            XCTAssertEqual(read.description, original.description)
            XCTAssertEqual(read.asString(), original.asString())
        }
    }

    func testWriteProteinSequence() async throws {
        let fileURL = tempDirectory.appendingPathComponent("protein.fasta")
        let writer = FASTAWriter(url: fileURL)

        let sequence = try Sequence(
            name: "protein1",
            description: "Test protein",
            alphabet: .protein,
            bases: "MKTAYIAKQRQISFVKSHFSRQLEERLGLI"
        )
        try writer.write([sequence])

        // Read back
        let reader = try FASTAReader(url: fileURL)
        let sequences = try await reader.readAll()

        XCTAssertEqual(sequences[0].asString(), "MKTAYIAKQRQISFVKSHFSRQLEERLGLI")
    }
}

// MARK: - FASTAError Tests

final class FASTAErrorTests: XCTestCase {

    func testFileNotFoundErrorDescription() {
        let url = URL(fileURLWithPath: "/path/to/file.fasta")
        let error = FASTAError.fileNotFound(url)
        XCTAssertTrue(error.errorDescription?.contains("/path/to/file.fasta") ?? false)
    }

    func testInvalidEncodingErrorDescription() {
        let error = FASTAError.invalidEncoding
        XCTAssertNotNil(error.errorDescription)
        XCTAssertTrue(error.errorDescription?.contains("encoding") ?? false)
    }

    func testSequenceBeforeHeaderErrorDescription() {
        let error = FASTAError.sequenceBeforeHeader(line: 5)
        XCTAssertTrue(error.errorDescription?.contains("5") ?? false)
    }

    func testInvalidSequenceErrorDescription() {
        let underlying = SequenceError.invalidCharacter("X", position: 10)
        let error = FASTAError.invalidSequence(name: "seq1", underlying: underlying)
        XCTAssertTrue(error.errorDescription?.contains("seq1") ?? false)
    }

    func testRegionOutOfBoundsErrorDescription() {
        let region = GenomicRegion(chromosome: "chr1", start: 1000, end: 2000)
        let error = FASTAError.regionOutOfBounds(region, sequenceLength: 500)
        XCTAssertTrue(error.errorDescription?.contains("500") ?? false)
    }
}

// MARK: - Real File Tests

/// Tests that load actual FASTA files from the test data directory.
/// These tests verify the parser works with real-world FASTA files.
final class FASTARealFileTests: XCTestCase {

    /// Helper to get URL for a checked-in test resource.
    private func testFileURL(_ filename: String) throws -> URL {
        let resourceRoot = try XCTUnwrap(Bundle.module.resourceURL, "Missing test resource bundle")
        let candidates = [
            resourceRoot.appendingPathComponent(filename),
            resourceRoot
                .appendingPathComponent("Resources", isDirectory: true)
                .appendingPathComponent(filename),
        ]

        return try XCTUnwrap(
            candidates.first { FileManager.default.fileExists(atPath: $0.path) },
            "Missing FASTA test resource \(filename) in \(resourceRoot.path)"
        )
    }

    // MARK: - sample_multi.fasta Tests

    func testLoadTestDnaFasta() async throws {
        let fileURL = try testFileURL("sample_multi.fasta")
        let reader = try FASTAReader(url: fileURL)
        let sequences = try await reader.readAll()

        XCTAssertEqual(sequences.count, 5, "sample_multi.fasta should contain five sequences")

        let seq = sequences[0]

        XCTAssertEqual(seq.name, "seq1")

        XCTAssertEqual(seq.description, "First test sequence")

        XCTAssertEqual(seq.alphabet, .dna, "Should be detected as DNA")

        XCTAssertEqual(seq.length, 40, "First sample sequence should be 40 bp")

        let prefix = seq[0..<10]
        XCTAssertEqual(prefix, "ATCGATCGAT", "Sequence should start with checked-in fixture bases")

        let seqString = seq.asString()
        let validDNA = Set("ATCGatcg")
        for char in seqString {
            XCTAssertTrue(validDNA.contains(char), "Invalid DNA character found: \(char)")
        }
    }

    func testTestDnaFastaHeaders() async throws {
        let fileURL = try testFileURL("sample_multi.fasta")
        let reader = try FASTAReader(url: fileURL)
        let headers = try await reader.readHeaders()

        XCTAssertEqual(headers.count, 5)
        XCTAssertEqual(headers[0].name, "seq1")
        XCTAssertEqual(headers[0].description, "First test sequence")
        XCTAssertEqual(headers[2].name, "seq3")
        XCTAssertNil(headers[2].description)
    }

    // MARK: - Multi-sequence Resource Tests

    func testLoadTestMultiFasta() async throws {
        let fileURL = try testFileURL("sample_multi.fasta")
        let reader = try FASTAReader(url: fileURL)
        let sequences = try await reader.readAll()

        XCTAssertEqual(sequences.count, 5, "sample_multi.fasta should contain exactly 5 sequences")

        let expectedNames = ["seq1", "seq2", "seq3", "protein_seq", "rna_seq"]
        let actualNames = sequences.map { $0.name }
        XCTAssertEqual(actualNames, expectedNames, "Sequence names should match expected")

        XCTAssertEqual(sequences[0].description, "First test sequence")
        XCTAssertEqual(sequences[1].description, "Second test sequence with longer description")
        XCTAssertNil(sequences[2].description)
        XCTAssertEqual(sequences[3].description, "This is a protein sequence")
        XCTAssertEqual(sequences[4].description, "RNA sequence with uracil")

        XCTAssertEqual(sequences[0].alphabet, .dna)
        XCTAssertEqual(sequences[1].alphabet, .dna)
        XCTAssertEqual(sequences[2].alphabet, .dna)
        XCTAssertEqual(sequences[3].alphabet, .protein)
        XCTAssertEqual(sequences[4].alphabet, .rna)

        XCTAssertEqual(sequences.map(\.length), [40, 20, 20, 20, 20])
    }

    func testMultiFastaStreaming() async throws {
        let fileURL = try testFileURL("sample_multi.fasta")
        let reader = try FASTAReader(url: fileURL)

        var count = 0
        var names: [String] = []

        for try await sequence in reader.sequences() {
            count += 1
            names.append(sequence.name)
            XCTAssertGreaterThan(sequence.length, 0, "Sequence \(sequence.name) should have non-zero length")
        }

        XCTAssertEqual(count, 5, "Should stream exactly 5 sequences")
        XCTAssertEqual(names, ["seq1", "seq2", "seq3", "protein_seq", "rna_seq"])
    }

    func testMultiFastaHeadersOnly() async throws {
        let fileURL = try testFileURL("sample_multi.fasta")
        let reader = try FASTAReader(url: fileURL)
        let headers = try await reader.readHeaders()

        XCTAssertEqual(headers.count, 5)

        XCTAssertEqual(headers[0].name, "seq1")
        XCTAssertEqual(headers[0].description, "First test sequence")

        XCTAssertEqual(headers[3].name, "protein_seq")
        XCTAssertEqual(headers[3].description, "This is a protein sequence")
    }

    // MARK: - large_test.fasta Tests

    func testLoadTestLargeFasta() async throws {
        let fileURL = try testFileURL("large_test.fasta")
        let reader = try FASTAReader(url: fileURL)

        // Measure performance
        let startTime = CFAbsoluteTimeGetCurrent()
        let sequences = try await reader.readAll()
        let elapsed = CFAbsoluteTimeGetCurrent() - startTime

        // Verify we got all large resource sequences
        XCTAssertEqual(sequences.count, 10, "large_test.fasta should contain exactly 10 sequences")

        let seq = sequences[0]

        // Verify name
        XCTAssertEqual(seq.name, "seq1")

        XCTAssertEqual(seq.description, "Test sequence 1 length=10000")

        XCTAssertEqual(seq.length, 10000, "Each large resource sequence should be 10000 bp")

        // Verify performance is acceptable (should parse in under 1 second)
        XCTAssertLessThan(elapsed, 1.0, "Parsing should complete in under 1 second")

        // Log the actual performance
        print("Large FASTA parsing took \(String(format: "%.3f", elapsed)) seconds for \(seq.length) bp")
    }

    func testLargeFastaStreamingPerformance() async throws {
        let fileURL = try testFileURL("large_test.fasta")
        let reader = try FASTAReader(url: fileURL)

        let startTime = CFAbsoluteTimeGetCurrent()
        var totalLength = 0

        for try await sequence in reader.sequences() {
            totalLength += sequence.length
        }

        let elapsed = CFAbsoluteTimeGetCurrent() - startTime

        XCTAssertEqual(totalLength, 100000, "Total length should be 100000 bp")
        XCTAssertLessThan(elapsed, 1.0, "Streaming should complete in under 1 second")

        print("Large FASTA streaming took \(String(format: "%.3f", elapsed)) seconds for \(totalLength) bp")
    }

    // MARK: - Sequence Data Integrity Tests

    func testSequenceDataIntegrity() async throws {
        let fileURL = try testFileURL("sample_multi.fasta")
        let reader = try FASTAReader(url: fileURL)
        let sequences = try await reader.readAll()

        guard let seq = sequences.first else {
            XCTFail("No sequence found")
            return
        }

        // Test subscript access at various positions
        XCTAssertEqual(seq[0], "A", "First base should be A")
        XCTAssertEqual(seq[1], "T", "Second base should be T")
        XCTAssertEqual(seq[2], "C", "Third base should be C")
        XCTAssertEqual(seq[3], "G", "Fourth base should be G")

        // Test range subscript
        let firstTen = seq[0..<10]
        XCTAssertEqual(firstTen.count, 10)
        XCTAssertEqual(firstTen, "ATCGATCGAT")

        // Test that asString() returns consistent results
        let str1 = seq.asString()
        let str2 = seq.asString()
        XCTAssertEqual(str1, str2, "asString() should return consistent results")
        XCTAssertEqual(str1.count, seq.length, "asString() length should match sequence length")
    }

    func testMultiSequenceDataIntegrity() async throws {
        let fileURL = try testFileURL("sample_multi.fasta")
        let reader = try FASTAReader(url: fileURL)
        let sequences = try await reader.readAll()

        // Verify first sequence starts correctly
        let seq1 = sequences[0]
        XCTAssertEqual(seq1[0..<4], "ATCG", "seq1 should start with ATCG")

        // Verify second sequence is different
        let seq2 = sequences[1]
        XCTAssertEqual(seq2[0..<4], "GGGG", "seq2 should start with GGGG")

        // Verify third sequence
        let seq3 = sequences[2]
        XCTAssertEqual(seq3[0..<4], "AAAA", "seq3 should start with AAAA")

        // Verify protein sequence
        let protein = sequences[3]
        XCTAssertEqual(protein[0..<3], "MKT", "protein_seq should start with MKT")
    }

    // MARK: - Round-trip Tests

    func testRoundTripWithRealFiles() async throws {
        // Read the multi-sequence file
        let sourceURL = try testFileURL("sample_multi.fasta")
        let reader = try FASTAReader(url: sourceURL)
        let originalSequences = try await reader.readAll()

        // Write to a temporary file
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("roundtrip_test_\(UUID().uuidString).fasta")
        defer { try? FileManager.default.removeItem(at: tempURL) }

        let writer = FASTAWriter(url: tempURL)
        try writer.write(originalSequences)

        // Read back
        let reader2 = try FASTAReader(url: tempURL)
        let readBackSequences = try await reader2.readAll()

        // Verify
        XCTAssertEqual(readBackSequences.count, originalSequences.count)

        for (original, readBack) in zip(originalSequences, readBackSequences) {
            XCTAssertEqual(readBack.name, original.name)
            XCTAssertEqual(readBack.description, original.description)
            XCTAssertEqual(readBack.length, original.length)
            XCTAssertEqual(readBack.asString(), original.asString())
        }
    }
}
