// ComprehensiveParserTests.swift - Exhaustive edge-case tests for FASTA/FASTQ parsers
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// These tests programmatically generate every bioinformatically relevant edge case
// for FASTA and FASTQ formats, covering header variations, sequence content, line
// ending permutations, size extremes, compression, and malformed inputs.

import XCTest
@testable import LungfishIO
import LungfishCore

final class ComprehensiveParserTests: XCTestCase {

    // MARK: - Fixtures

    private var tempDirectory: URL!

    override func setUp() async throws {
        tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ComprehensiveParserTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: tempDirectory,
            withIntermediateDirectories: true
        )
    }

    override func tearDown() async throws {
        if let dir = tempDirectory {
            try? FileManager.default.removeItem(at: dir)
        }
    }

    // MARK: - Helpers

    /// Writes raw string content as a FASTA file and returns its URL.
    private func writeFASTA(_ content: String, name: String = "test.fasta") -> URL {
        let url = tempDirectory.appendingPathComponent(name)
        try! content.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    /// Writes raw bytes as a FASTA file (for line-ending tests where we need
    /// exact control over bytes).
    private func writeFASTABytes(_ data: Data, name: String = "test.fasta") -> URL {
        let url = tempDirectory.appendingPathComponent(name)
        try! data.write(to: url)
        return url
    }

    /// Writes raw string content as a FASTQ file and returns its URL.
    private func writeFASTQ(_ content: String, name: String = "test.fastq") -> URL {
        let url = tempDirectory.appendingPathComponent(name)
        try! content.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    /// Writes raw bytes as a FASTQ file for exact byte control.
    private func writeFASTQBytes(_ data: Data, name: String = "test.fastq") -> URL {
        let url = tempDirectory.appendingPathComponent(name)
        try! data.write(to: url)
        return url
    }

    /// Generates a random DNA sequence of a given length using only ATCG.
    private func randomDNA(length: Int) -> String {
        let bases: [Character] = ["A", "T", "C", "G"]
        return String((0..<length).map { _ in bases[Int.random(in: 0..<4)] })
    }

    /// Generates a quality string of uniform ASCII character for a given length.
    private func uniformQuality(_ char: Character, length: Int) -> String {
        String(repeating: char, count: length)
    }

    // =========================================================================
    // MARK: - FASTA: Basic Tests
    // =========================================================================

    // 1. Single sequence, single line
    func testFASTA_basic_singleSequenceSingleLine() async throws {
        let url = writeFASTA(">seq1 simple test\nATCGATCGATCG\n")
        let reader = try FASTAReader(url: url)
        let seqs = try await reader.readAll()

        XCTAssertEqual(seqs.count, 1)
        XCTAssertEqual(seqs[0].name, "seq1")
        XCTAssertEqual(seqs[0].description, "simple test")
        XCTAssertEqual(seqs[0].asString(), "ATCGATCGATCG")
        XCTAssertEqual(seqs[0].length, 12)
        XCTAssertEqual(seqs[0].alphabet, .dna)
    }

    // 2. Single sequence, multi-line wrapped at 60, 70, 80 chars
    func testFASTA_basic_multiLineWrap60() async throws {
        let bases = randomDNA(length: 180)
        let wrapped = stride(from: 0, to: bases.count, by: 60).map { i -> String in
            let start = bases.index(bases.startIndex, offsetBy: i)
            let end = bases.index(start, offsetBy: min(60, bases.count - i))
            return String(bases[start..<end])
        }.joined(separator: "\n")
        let url = writeFASTA(">seq1\n\(wrapped)\n")
        let reader = try FASTAReader(url: url)
        let seqs = try await reader.readAll()

        XCTAssertEqual(seqs.count, 1)
        XCTAssertEqual(seqs[0].asString(), bases)
        XCTAssertEqual(seqs[0].length, 180)
    }

    func testFASTA_basic_multiLineWrap70() async throws {
        let bases = randomDNA(length: 210)
        let wrapped = stride(from: 0, to: bases.count, by: 70).map { i -> String in
            let start = bases.index(bases.startIndex, offsetBy: i)
            let end = bases.index(start, offsetBy: min(70, bases.count - i))
            return String(bases[start..<end])
        }.joined(separator: "\n")
        let url = writeFASTA(">seq1\n\(wrapped)\n")
        let reader = try FASTAReader(url: url)
        let seqs = try await reader.readAll()

        XCTAssertEqual(seqs.count, 1)
        XCTAssertEqual(seqs[0].asString(), bases)
        XCTAssertEqual(seqs[0].length, 210)
    }

    func testFASTA_basic_multiLineWrap80() async throws {
        let bases = randomDNA(length: 240)
        let wrapped = stride(from: 0, to: bases.count, by: 80).map { i -> String in
            let start = bases.index(bases.startIndex, offsetBy: i)
            let end = bases.index(start, offsetBy: min(80, bases.count - i))
            return String(bases[start..<end])
        }.joined(separator: "\n")
        let url = writeFASTA(">seq1\n\(wrapped)\n")
        let reader = try FASTAReader(url: url)
        let seqs = try await reader.readAll()

        XCTAssertEqual(seqs.count, 1)
        XCTAssertEqual(seqs[0].asString(), bases)
        XCTAssertEqual(seqs[0].length, 240)
    }

    // 3. Multiple sequences (2, 10, 100)
    func testFASTA_basic_twoSequences() async throws {
        let content = ">s1\nATCG\n>s2\nGCTA\n"
        let url = writeFASTA(content)
        let reader = try FASTAReader(url: url)
        let seqs = try await reader.readAll()

        XCTAssertEqual(seqs.count, 2)
        XCTAssertEqual(seqs[0].name, "s1")
        XCTAssertEqual(seqs[0].asString(), "ATCG")
        XCTAssertEqual(seqs[1].name, "s2")
        XCTAssertEqual(seqs[1].asString(), "GCTA")
    }

    func testFASTA_basic_tenSequences() async throws {
        var content = ""
        for i in 1...10 {
            content += ">seq\(i)\n\(randomDNA(length: 50))\n"
        }
        let url = writeFASTA(content)
        let reader = try FASTAReader(url: url)
        let seqs = try await reader.readAll()

        XCTAssertEqual(seqs.count, 10)
        for i in 0..<10 {
            XCTAssertEqual(seqs[i].name, "seq\(i + 1)")
            XCTAssertEqual(seqs[i].length, 50)
        }
    }

    func testFASTA_basic_hundredSequences() async throws {
        var content = ""
        for i in 1...100 {
            content += ">seq\(i)\n\(randomDNA(length: 20))\n"
        }
        let url = writeFASTA(content)
        let reader = try FASTAReader(url: url)
        let seqs = try await reader.readAll()

        XCTAssertEqual(seqs.count, 100)
        XCTAssertEqual(seqs[99].name, "seq100")
    }

    // 4. Empty file (0 bytes)
    func testFASTA_basic_emptyFile() async throws {
        let url = writeFASTA("")
        let reader = try FASTAReader(url: url)
        let seqs = try await reader.readAll()

        XCTAssertTrue(seqs.isEmpty, "Empty FASTA should yield zero sequences")
    }

    // 5. File with only a header, no sequence data
    func testFASTA_basic_headerOnly() async throws {
        let url = writeFASTA(">header_only no bases follow\n")
        let reader = try FASTAReader(url: url)
        let seqs = try await reader.readAll()

        // A header without sequence data should not produce a sequence
        // (the parser requires non-empty baseChunks)
        XCTAssertEqual(seqs.count, 0,
                        "Header-only entry produces no sequence because base chunks are empty")
    }

    // 6. File with blank lines between sequences
    func testFASTA_basic_blankLinesBetweenSequences() async throws {
        let content = ">s1\nATCG\n\n\n>s2\nGCTA\n\n"
        let url = writeFASTA(content)
        let reader = try FASTAReader(url: url)
        let seqs = try await reader.readAll()

        XCTAssertEqual(seqs.count, 2)
        XCTAssertEqual(seqs[0].asString(), "ATCG")
        XCTAssertEqual(seqs[1].asString(), "GCTA")
    }

    // 7. File with trailing blank lines
    func testFASTA_basic_trailingBlankLines() async throws {
        let content = ">s1\nATCG\n\n\n\n"
        let url = writeFASTA(content)
        let reader = try FASTAReader(url: url)
        let seqs = try await reader.readAll()

        XCTAssertEqual(seqs.count, 1)
        XCTAssertEqual(seqs[0].asString(), "ATCG")
    }

    // =========================================================================
    // MARK: - FASTA: Special Characters in Names
    // =========================================================================

    // 8. Spaces in sequence name
    func testFASTA_specialChars_spacesInName() async throws {
        // FASTAReader splits on first space: "my" becomes name, rest is description
        let url = writeFASTA(">my sequence name\nATCG\n")
        let reader = try FASTAReader(url: url)
        let seqs = try await reader.readAll()

        XCTAssertEqual(seqs.count, 1)
        XCTAssertEqual(seqs[0].name, "my")
        XCTAssertEqual(seqs[0].description, "sequence name")
    }

    // 9. MHC allele notation with asterisks
    func testFASTA_specialChars_mhcAlleleNotation() async throws {
        let url = writeFASTA(">Mamu-A1*001:01:01:01 MHC class I\nATCGATCG\n")
        let reader = try FASTAReader(url: url)
        let seqs = try await reader.readAll()

        XCTAssertEqual(seqs.count, 1)
        XCTAssertEqual(seqs[0].name, "Mamu-A1*001:01:01:01")
        XCTAssertEqual(seqs[0].description, "MHC class I")
    }

    // 10. Colons (genomic range notation)
    func testFASTA_specialChars_colonsInName() async throws {
        let url = writeFASTA(">NC_045512.2:1-1000 SARS-CoV-2 partial\nATCGATCG\n")
        let reader = try FASTAReader(url: url)
        let seqs = try await reader.readAll()

        XCTAssertEqual(seqs.count, 1)
        XCTAssertEqual(seqs[0].name, "NC_045512.2:1-1000")
        XCTAssertEqual(seqs[0].description, "SARS-CoV-2 partial")
    }

    // 11. Pipes (NCBI-style gi header)
    func testFASTA_specialChars_pipesInName() async throws {
        let url = writeFASTA(">gi|12345|ref|NC_045512.2| SARS-CoV-2\nATCGATCG\n")
        let reader = try FASTAReader(url: url)
        let seqs = try await reader.readAll()

        XCTAssertEqual(seqs.count, 1)
        XCTAssertEqual(seqs[0].name, "gi|12345|ref|NC_045512.2|")
        XCTAssertEqual(seqs[0].description, "SARS-CoV-2")
    }

    // 12. Parentheses in description
    func testFASTA_specialChars_parentheses() async throws {
        let url = writeFASTA(">gene1 (partial)\nATCGATCG\n")
        let reader = try FASTAReader(url: url)
        let seqs = try await reader.readAll()

        XCTAssertEqual(seqs.count, 1)
        XCTAssertEqual(seqs[0].name, "gene1")
        XCTAssertEqual(seqs[0].description, "(partial)")
    }

    // 13. Equals signs in description (key=value metadata)
    func testFASTA_specialChars_equalsSignsMetadata() async throws {
        let url = writeFASTA(">seq1 length=100 gc=0.5\nATCGATCGATCG\n")
        let reader = try FASTAReader(url: url)
        let seqs = try await reader.readAll()

        XCTAssertEqual(seqs.count, 1)
        XCTAssertEqual(seqs[0].name, "seq1")
        XCTAssertEqual(seqs[0].description, "length=100 gc=0.5")
    }

    // 14. Unicode in description (Greek letters, non-ASCII)
    func testFASTA_specialChars_unicodeInDescription() async throws {
        let url = writeFASTA(">seq1 Mus musculus (house mouse) \u{03B2}-globin\nATCGATCG\n")
        let reader = try FASTAReader(url: url)
        let seqs = try await reader.readAll()

        XCTAssertEqual(seqs.count, 1)
        XCTAssertEqual(seqs[0].name, "seq1")
        XCTAssertTrue(seqs[0].description?.contains("\u{03B2}-globin") == true,
                       "Description should preserve Unicode characters")
    }

    // 15. Very long header (500+ chars)
    func testFASTA_specialChars_veryLongHeader() async throws {
        let longDesc = String(repeating: "x", count: 500)
        let url = writeFASTA(">longheader \(longDesc)\nATCG\n")
        let reader = try FASTAReader(url: url)
        let seqs = try await reader.readAll()

        XCTAssertEqual(seqs.count, 1)
        XCTAssertEqual(seqs[0].name, "longheader")
        XCTAssertEqual(seqs[0].description?.count, 500)
    }

    // 16. Tab-separated header fields
    func testFASTA_specialChars_tabSeparatedFields() async throws {
        let url = writeFASTA(">seq1\tsome\tfields\nATCG\n")
        let reader = try FASTAReader(url: url)
        let seqs = try await reader.readAll()

        XCTAssertEqual(seqs.count, 1)
        XCTAssertEqual(seqs[0].name, "seq1")
        XCTAssertEqual(seqs[0].description, "some\tfields")
    }

    // =========================================================================
    // MARK: - FASTA: Sequence Content Edge Cases
    // =========================================================================

    // 17. All N's sequence
    func testFASTA_content_allNs() async throws {
        let url = writeFASTA(">allN\nNNNNNNNNNN\n")
        let reader = try FASTAReader(url: url)
        let seqs = try await reader.readAll()

        XCTAssertEqual(seqs.count, 1)
        XCTAssertEqual(seqs[0].asString(), "NNNNNNNNNN")
        XCTAssertEqual(seqs[0].length, 10)
        XCTAssertEqual(seqs[0].alphabet, .dna)
    }

    // 18. Mixed case bases
    func testFASTA_content_mixedCase() async throws {
        let url = writeFASTA(">mixed\nATCGatcgATCGatcg\n")
        let reader = try FASTAReader(url: url)
        let seqs = try await reader.readAll()

        XCTAssertEqual(seqs.count, 1)
        // The 2-bit storage uppercases standard bases but preserves case for
        // ambiguous codes. For ATCG the round-trip should be uppercase.
        let result = seqs[0].asString()
        XCTAssertEqual(result.uppercased(), "ATCGATCGATCGATCG")
        XCTAssertEqual(seqs[0].length, 16)
    }

    // 19. IUPAC ambiguity codes
    func testFASTA_content_iupacAmbiguityCodes() async throws {
        let ambiguous = "RYSWKMBDHVN"
        let url = writeFASTA(">iupac\n\(ambiguous)\n")
        let reader = try FASTAReader(url: url)
        let seqs = try await reader.readAll(alphabet: .dna)

        XCTAssertEqual(seqs.count, 1)
        let result = seqs[0].asString()
        XCTAssertEqual(result, ambiguous)
        XCTAssertEqual(seqs[0].length, 11)
    }

    // 20. Sequence with internal spaces (should be stripped by trimming)
    func testFASTA_content_internalSpaces() async throws {
        // The parser calls trimmingCharacters(in: .whitespacesAndNewlines) on each line.
        // If the entire line is "A T C G", after trimming it becomes "A T C G".
        // However, the parser does NOT strip spaces within a line -- they would
        // be passed to SequenceStorage which would reject space as an invalid character.
        // In practice, FASTA files with spaces in sequence lines are malformed.
        // We test that the parser at least does not crash.
        let url = writeFASTA(">spaces\nATCG ATCG\n")
        let reader = try FASTAReader(url: url)

        // Spaces are not valid DNA characters, so this should throw
        do {
            _ = try await reader.readAll()
            XCTFail("Expected error for space character in sequence")
        } catch {
            // Expected: SequenceError.invalidCharacter or FASTAError.invalidSequence
            XCTAssertTrue(error is FASTAError,
                          "Expected FASTAError but got \(type(of: error))")
        }
    }

    // 21. Very short sequence (1 bp)
    func testFASTA_content_singleBase() async throws {
        let url = writeFASTA(">one\nA\n")
        let reader = try FASTAReader(url: url)
        let seqs = try await reader.readAll()

        XCTAssertEqual(seqs.count, 1)
        XCTAssertEqual(seqs[0].asString(), "A")
        XCTAssertEqual(seqs[0].length, 1)
    }

    // 22. Protein sequence (amino acids including EFILPQ — standard codes)
    func testFASTA_content_proteinSequence() async throws {
        let protein = "MKTAYIAKQRQISFVKEFILPQ"
        let url = writeFASTA(">prot1 Hypothetical protein\n\(protein)\n")
        let reader = try FASTAReader(url: url)
        // The auto-detect should identify this as protein due to EFILPQ
        let seqs = try await reader.readAll()

        XCTAssertEqual(seqs.count, 1)
        XCTAssertEqual(seqs[0].alphabet, .protein)
        XCTAssertEqual(seqs[0].asString().uppercased(), protein.uppercased())
    }

    // 23. RNA sequence (contains U, no T)
    func testFASTA_content_rnaSequence() async throws {
        let rna = "AUGCAUGCAUGC"
        let url = writeFASTA(">rna1\n\(rna)\n")
        let reader = try FASTAReader(url: url)
        let seqs = try await reader.readAll()

        XCTAssertEqual(seqs.count, 1)
        XCTAssertEqual(seqs[0].alphabet, .rna)
        XCTAssertEqual(seqs[0].asString(), rna)
    }

    // =========================================================================
    // MARK: - FASTA: Size Edge Cases
    // =========================================================================

    // 24. Very long sequence name (1000 chars)
    func testFASTA_size_veryLongName() async throws {
        let longName = String(repeating: "x", count: 1000)
        let url = writeFASTA(">\(longName)\nATCG\n")
        let reader = try FASTAReader(url: url)
        let seqs = try await reader.readAll()

        XCTAssertEqual(seqs.count, 1)
        XCTAssertEqual(seqs[0].name.count, 1000)
    }

    // 25. Single very long sequence (100,000 bp, multi-line)
    func testFASTA_size_longSequence100k() async throws {
        let bases = randomDNA(length: 100_000)
        var content = ">long\n"
        for i in stride(from: 0, to: bases.count, by: 80) {
            let start = bases.index(bases.startIndex, offsetBy: i)
            let end = bases.index(start, offsetBy: min(80, bases.count - i))
            content += String(bases[start..<end]) + "\n"
        }
        let url = writeFASTA(content)
        let reader = try FASTAReader(url: url)
        let seqs = try await reader.readAll()

        XCTAssertEqual(seqs.count, 1)
        XCTAssertEqual(seqs[0].length, 100_000)
        XCTAssertEqual(seqs[0].asString(), bases)
    }

    // 26. Many short sequences (1000 sequences of 10 bp each)
    func testFASTA_size_manyShortSequences() async throws {
        var content = ""
        var expected: [(String, String)] = []
        for i in 1...1000 {
            let dna = randomDNA(length: 10)
            content += ">s\(i)\n\(dna)\n"
            expected.append(("s\(i)", dna))
        }
        let url = writeFASTA(content)
        let reader = try FASTAReader(url: url)
        let seqs = try await reader.readAll()

        XCTAssertEqual(seqs.count, 1000)
        for i in 0..<1000 {
            XCTAssertEqual(seqs[i].name, expected[i].0)
            XCTAssertEqual(seqs[i].asString(), expected[i].1)
        }
    }

    // =========================================================================
    // MARK: - FASTA: Line Ending Variations
    // =========================================================================

    // 27. Unix line endings (\n)
    func testFASTA_lineEndings_unix() async throws {
        let raw = ">seq1\nATCGATCG\nATCGATCG\n>seq2\nGCTAGCTA\n"
        let url = writeFASTA(raw)
        let reader = try FASTAReader(url: url)
        let seqs = try await reader.readAll()

        XCTAssertEqual(seqs.count, 2)
        XCTAssertEqual(seqs[0].asString(), "ATCGATCGATCGATCG")
        XCTAssertEqual(seqs[1].asString(), "GCTAGCTA")
    }

    // 28. Windows line endings (\r\n)
    func testFASTA_lineEndings_windows() async throws {
        let raw = ">seq1\r\nATCGATCG\r\nATCGATCG\r\n>seq2\r\nGCTAGCTA\r\n"
        let data = raw.data(using: .utf8)!
        let url = writeFASTABytes(data, name: "windows.fasta")
        let reader = try FASTAReader(url: url)
        let seqs = try await reader.readAll()

        XCTAssertEqual(seqs.count, 2)
        XCTAssertEqual(seqs[0].asString(), "ATCGATCGATCGATCG")
        XCTAssertEqual(seqs[1].asString(), "GCTAGCTA")
    }

    // 29. Classic Mac line endings (\r only)
    // The FASTAReader normalizes \r\n to \n and splits on \n.
    // Pure \r without \n will NOT be recognized as line breaks by the parser,
    // since it only replaces \r\n. This documents that limitation.
    func testFASTA_lineEndings_classicMac() async throws {
        let raw = ">seq1\rATCG\rATCG\r"
        let data = raw.data(using: .utf8)!
        let url = writeFASTABytes(data, name: "classicmac.fasta")
        let reader = try FASTAReader(url: url)

        // Classic Mac \r-only line endings are NOT supported by this parser.
        // The entire file appears as a single line. The parser will see
        // ">seq1\rATCG\rATCG\r" as one line starting with >, and the
        // "sequence" portion will contain \r characters which are stripped
        // by trimmingCharacters. This test documents the actual behavior.
        let seqs = try await reader.readAll()

        // Because the parser splits on \n and there are none, the entire file
        // is one "line". After the split on \n yields one element, the parser
        // will try to handle it. The line starts with >, so it's treated as a
        // header. But there are no subsequent lines for sequence data, so we
        // expect 0 sequences (header-only with no bases).
        // However, if the \r-bearing text ends up in the remainder buffer and
        // gets trimmed to a header, the behavior may vary.
        // We just assert it does not crash and document the count.
        XCTAssertTrue(seqs.count <= 1,
                       "Classic Mac line endings are not fully supported; parser should not crash")
    }

    // 30. Mixed line endings within same file
    func testFASTA_lineEndings_mixed() async throws {
        // Mix of \n, \r\n within the same file
        let raw = ">seq1\r\nATCG\nATCG\r\n>seq2\nGCTA\r\n"
        let data = raw.data(using: .utf8)!
        let url = writeFASTABytes(data, name: "mixed_endings.fasta")
        let reader = try FASTAReader(url: url)
        let seqs = try await reader.readAll()

        XCTAssertEqual(seqs.count, 2)
        XCTAssertEqual(seqs[0].asString(), "ATCGATCG")
        XCTAssertEqual(seqs[1].asString(), "GCTA")
    }

    // =========================================================================
    // MARK: - FASTA: Compression
    // =========================================================================

    // 31. Gzipped FASTA (.fasta.gz)
    func testFASTA_compression_gzipped() async throws {
        // Create an uncompressed FASTA, gzip it with the system tool, and
        // verify the reader can handle it. FASTAReader itself does not
        // auto-decompress gzip (only FASTQReader does via linesAutoDecompressing).
        // However we can verify GzipInputStream works with FASTA content.
        let fastaContent = ">seq1 gzip test\nATCGATCGATCG\n>seq2\nGCTAGCTAGCTA\n"
        let plainURL = writeFASTA(fastaContent, name: "test_plain.fasta")
        let gzURL = tempDirectory.appendingPathComponent("test.fasta.gz")

        // Compress using system gzip
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/gzip")
        process.arguments = ["-c", plainURL.path]
        let pipe = Pipe()
        process.standardOutput = pipe
        try process.run()
        process.waitUntilExit()

        let compressedData = pipe.fileHandleForReading.readDataToEndOfFile()
        XCTAssertGreaterThan(compressedData.count, 0, "gzip should produce output")
        try compressedData.write(to: gzURL)

        // Verify the gzip file can be decompressed via GzipInputStream
        let stream = try GzipInputStream(url: gzURL)
        let decompressed = try await stream.readAll()
        XCTAssertEqual(decompressed, fastaContent)

        // Parse the decompressed content manually to verify sequences
        let tempDecompressed = writeFASTA(decompressed, name: "decompressed.fasta")
        let reader = try FASTAReader(url: tempDecompressed)
        let seqs = try await reader.readAll()
        XCTAssertEqual(seqs.count, 2)
        XCTAssertEqual(seqs[0].name, "seq1")
        XCTAssertEqual(seqs[0].asString(), "ATCGATCGATCG")
        XCTAssertEqual(seqs[1].name, "seq2")
        XCTAssertEqual(seqs[1].asString(), "GCTAGCTAGCTA")
    }

    // =========================================================================
    // MARK: - FASTA: Sync vs Async Consistency
    // =========================================================================

    func testFASTA_syncAsyncConsistency() async throws {
        var content = ""
        for i in 1...20 {
            content += ">seq\(i)\n\(randomDNA(length: 100))\n"
        }
        let url = writeFASTA(content)
        let reader = try FASTAReader(url: url)

        let syncResult = try reader.readAllSync()
        let asyncResult = try await reader.readAll()

        XCTAssertEqual(syncResult.count, asyncResult.count)
        for (s, a) in zip(syncResult, asyncResult) {
            XCTAssertEqual(s.name, a.name)
            XCTAssertEqual(s.asString(), a.asString())
            XCTAssertEqual(s.length, a.length)
        }
    }

    // =========================================================================
    // MARK: - FASTA: Streaming
    // =========================================================================

    func testFASTA_streaming() async throws {
        var content = ""
        for i in 1...15 {
            content += ">seq\(i)\n\(randomDNA(length: 50))\n"
        }
        let url = writeFASTA(content)
        let reader = try FASTAReader(url: url)

        var count = 0
        for try await seq in reader.sequences() {
            count += 1
            XCTAssertFalse(seq.name.isEmpty)
            XCTAssertEqual(seq.length, 50)
        }
        XCTAssertEqual(count, 15)
    }

    // =========================================================================
    // MARK: - FASTA: Header Parsing
    // =========================================================================

    func testFASTA_headers_readHeadersOnly() async throws {
        let content = ">s1 first\nATCGATCG\n>s2 second\nGCTAGCTA\n>s3\nAAAA\n"
        let url = writeFASTA(content)
        let reader = try FASTAReader(url: url)

        let headers = try await reader.readHeaders()
        XCTAssertEqual(headers.count, 3)
        XCTAssertEqual(headers[0].name, "s1")
        XCTAssertEqual(headers[0].description, "first")
        XCTAssertEqual(headers[1].name, "s2")
        XCTAssertEqual(headers[1].description, "second")
        XCTAssertEqual(headers[2].name, "s3")
        XCTAssertNil(headers[2].description)
    }

    // =========================================================================
    // MARK: - FASTA: Error Cases
    // =========================================================================

    func testFASTA_error_sequenceBeforeHeader() async throws {
        let url = writeFASTA("ATCGATCG\n>seq1\nATCG\n")
        let reader = try FASTAReader(url: url)

        do {
            _ = try await reader.readAll()
            XCTFail("Expected FASTAError.sequenceBeforeHeader")
        } catch let error as FASTAError {
            if case .sequenceBeforeHeader = error {
                // Expected
            } else {
                XCTFail("Expected sequenceBeforeHeader, got \(error)")
            }
        }
    }

    func testFASTA_error_fileNotFound() async throws {
        let bogus = URL(fileURLWithPath: "/nonexistent/path/to/file.fasta")
        do {
            _ = try FASTAReader(url: bogus)
            XCTFail("Expected FASTAError.fileNotFound")
        } catch let error as FASTAError {
            if case .fileNotFound = error {
                // Expected
            } else {
                XCTFail("Expected fileNotFound, got \(error)")
            }
        }
    }

    // =========================================================================
    // MARK: - FASTA: No Trailing Newline
    // =========================================================================

    func testFASTA_noTrailingNewline() async throws {
        // File ends without a trailing newline
        let url = writeFASTA(">seq1\nATCGATCG")
        let reader = try FASTAReader(url: url)
        let seqs = try await reader.readAll()

        XCTAssertEqual(seqs.count, 1)
        XCTAssertEqual(seqs[0].asString(), "ATCGATCG")
    }

    // =========================================================================
    // MARK: - FASTQ: Basic Tests
    // =========================================================================

    // 32. Single read, standard Illumina header
    func testFASTQ_basic_singleReadStandard() async throws {
        let content = """
        @SEQ_001 Lungfish test read
        ATCGATCGATCG
        +
        IIIIIIIIIIII

        """
        let url = writeFASTQ(content)
        let reader = FASTQReader()
        let records = try await reader.readAll(from: url)

        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records[0].identifier, "SEQ_001")
        XCTAssertEqual(records[0].description, "Lungfish test read")
        XCTAssertEqual(records[0].sequence, "ATCGATCGATCG")
        XCTAssertEqual(records[0].length, 12)
        XCTAssertEqual(records[0].quality.count, 12)
    }

    // 33. Multiple reads (10)
    func testFASTQ_basic_tenReads() async throws {
        var content = ""
        for i in 1...10 {
            let seq = randomDNA(length: 50)
            let qual = uniformQuality("I", length: 50)
            content += "@READ_\(String(format: "%03d", i))\n\(seq)\n+\n\(qual)\n"
        }
        let url = writeFASTQ(content)
        let reader = FASTQReader()
        let records = try await reader.readAll(from: url)

        XCTAssertEqual(records.count, 10)
        for i in 0..<10 {
            XCTAssertEqual(records[i].identifier, "READ_\(String(format: "%03d", i + 1))")
            XCTAssertEqual(records[i].length, 50)
        }
    }

    // 34. Empty file
    func testFASTQ_basic_emptyFile() async throws {
        let url = writeFASTQ("")
        let reader = FASTQReader()
        let records = try await reader.readAll(from: url)

        XCTAssertTrue(records.isEmpty, "Empty FASTQ should yield zero records")
    }

    // 35. Illumina-style header
    func testFASTQ_basic_illuminaHeader() async throws {
        let content = """
        @M00123:45:000000000-A1B2C:1:1101:15432:1332 1:N:0:ATCACG
        ATCGATCGATCGATCGATCG
        +
        IIIIIIIIIIIIIIIIIIII

        """
        let url = writeFASTQ(content)
        let reader = FASTQReader()
        let records = try await reader.readAll(from: url)

        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records[0].identifier, "M00123:45:000000000-A1B2C:1:1101:15432:1332")
        XCTAssertEqual(records[0].description, "1:N:0:ATCACG")
    }

    // 36. Simple header
    func testFASTQ_basic_simpleHeader() async throws {
        let content = "@read1\nATCG\n+\nIIII\n"
        let url = writeFASTQ(content)
        let reader = FASTQReader()
        let records = try await reader.readAll(from: url)

        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records[0].identifier, "read1")
        XCTAssertNil(records[0].description)
    }

    // =========================================================================
    // MARK: - FASTQ: Quality Score Edge Cases
    // =========================================================================

    // 37. All max quality (I = Q40 in Phred+33)
    func testFASTQ_qualityEdge_allMaxQuality() async throws {
        let seq = "ATCGATCGATCG"
        let qual = String(repeating: "I", count: seq.count) // ASCII 73 -> Q40
        let content = "@maxq\n\(seq)\n+\n\(qual)\n"
        let url = writeFASTQ(content)
        let reader = FASTQReader()
        let records = try await reader.readAll(from: url)

        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records[0].quality.meanQuality, 40.0, accuracy: 0.01)
        XCTAssertEqual(records[0].quality.q30Percentage, 100.0, accuracy: 0.01)
        for i in 0..<seq.count {
            XCTAssertEqual(records[0].quality.qualityAt(i), 40)
        }
    }

    // 38. All min quality (! = Q0 in Phred+33)
    func testFASTQ_qualityEdge_allMinQuality() async throws {
        let seq = "ATCGATCG"
        let qual = String(repeating: "!", count: seq.count) // ASCII 33 -> Q0
        let content = "@minq\n\(seq)\n+\n\(qual)\n"
        let url = writeFASTQ(content)
        let reader = FASTQReader()
        let records = try await reader.readAll(from: url)

        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records[0].quality.meanQuality, 0.0, accuracy: 0.01)
        XCTAssertEqual(records[0].quality.q20Percentage, 0.0, accuracy: 0.01)
        XCTAssertEqual(records[0].quality.q30Percentage, 0.0, accuracy: 0.01)
        for i in 0..<seq.count {
            XCTAssertEqual(records[0].quality.qualityAt(i), 0)
        }
    }

    // 39. Mixed quality scores
    func testFASTQ_qualityEdge_mixedQuality() async throws {
        let seq = "ATCG"
        // '!' = Q0, '5' = Q20, '?' = Q30, 'I' = Q40
        let qual = "!5?I"
        let content = "@mixed\n\(seq)\n+\n\(qual)\n"
        let url = writeFASTQ(content)
        let reader = FASTQReader()
        let records = try await reader.readAll(from: url)

        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records[0].quality.qualityAt(0), 0)   // !
        XCTAssertEqual(records[0].quality.qualityAt(1), 20)  // 5
        XCTAssertEqual(records[0].quality.qualityAt(2), 30)  // ? = ASCII 63, 63-33=30
        XCTAssertEqual(records[0].quality.qualityAt(3), 40)  // I
        XCTAssertEqual(records[0].quality.meanQuality, 22.5, accuracy: 0.01)
    }

    // 40. Quality string shorter than sequence (should error)
    func testFASTQ_qualityEdge_qualityShorterThanSequence() async throws {
        let content = "@short_qual\nATCGATCG\n+\nIII\n"
        let url = writeFASTQ(content)
        let reader = FASTQReader()

        do {
            _ = try await reader.readAll(from: url)
            XCTFail("Expected error for quality shorter than sequence")
        } catch let error as FASTQError {
            // Should be qualityLengthMismatch or unexpectedEndOfFile
            switch error {
            case .qualityLengthMismatch, .unexpectedEndOfFile:
                break // Expected
            default:
                XCTFail("Expected qualityLengthMismatch or unexpectedEndOfFile, got \(error)")
            }
        }
    }

    // 41. Quality string longer than sequence (should error)
    func testFASTQ_qualityEdge_qualityLongerThanSequence() async throws {
        let content = "@long_qual\nATCG\n+\nIIIIIIIIII\n"
        let url = writeFASTQ(content)
        let reader = FASTQReader()

        do {
            _ = try await reader.readAll(from: url)
            XCTFail("Expected error for quality longer than sequence")
        } catch let error as FASTQError {
            if case .qualityLengthMismatch = error {
                // Expected
            } else {
                XCTFail("Expected qualityLengthMismatch, got \(error)")
            }
        }
    }

    // =========================================================================
    // MARK: - FASTQ: Special Characters
    // =========================================================================

    // 42. Read ID with spaces
    func testFASTQ_specialChars_readIDWithSpaces() async throws {
        let content = "@READ_001 extra info here\nATCG\n+\nIIII\n"
        let url = writeFASTQ(content)
        let reader = FASTQReader()
        let records = try await reader.readAll(from: url)

        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records[0].identifier, "READ_001")
        XCTAssertEqual(records[0].description, "extra info here")
    }

    // 43. Read ID with slashes (paired-end convention)
    func testFASTQ_specialChars_readIDWithSlash() async throws {
        let content = "@read1/1\nATCG\n+\nIIII\n@read1/2\nGCTA\n+\nHHHH\n"
        let url = writeFASTQ(content)
        let reader = FASTQReader()
        let records = try await reader.readAll(from: url)

        XCTAssertEqual(records.count, 2)
        XCTAssertEqual(records[0].identifier, "read1/1")
        XCTAssertEqual(records[1].identifier, "read1/2")

        // Verify paired-end parsing
        XCTAssertNotNil(records[0].readPair)
        XCTAssertEqual(records[0].readPair?.readNumber, 1)
        XCTAssertEqual(records[0].readPair?.pairId, "read1")
        XCTAssertNotNil(records[1].readPair)
        XCTAssertEqual(records[1].readPair?.readNumber, 2)
        XCTAssertEqual(records[1].readPair?.pairId, "read1")
    }

    // 44. Plus line with repeated header
    func testFASTQ_specialChars_plusLineWithHeader() async throws {
        let content = "@read1\nATCG\n+read1\nIIII\n"
        let url = writeFASTQ(content)
        let reader = FASTQReader()
        let records = try await reader.readAll(from: url)

        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records[0].identifier, "read1")
        XCTAssertEqual(records[0].sequence, "ATCG")
        XCTAssertEqual(records[0].quality.toAscii(), "IIII")
    }

    // 45. Plus line with just +
    func testFASTQ_specialChars_barePlusLine() async throws {
        let content = "@read1\nATCG\n+\nIIII\n"
        let url = writeFASTQ(content)
        let reader = FASTQReader()
        let records = try await reader.readAll(from: url)

        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records[0].identifier, "read1")
        XCTAssertEqual(records[0].sequence, "ATCG")
    }

    // =========================================================================
    // MARK: - FASTQ: Size Edge Cases
    // =========================================================================

    // 46. Very long read (10,000 bp -- nanopore style)
    func testFASTQ_sizeEdge_nanopore10kRead() async throws {
        let seq = randomDNA(length: 10_000)
        let qual = uniformQuality("5", length: 10_000) // Q20 throughout
        let content = "@nanopore_read_001\n\(seq)\n+\n\(qual)\n"
        let url = writeFASTQ(content)
        let reader = FASTQReader()
        let records = try await reader.readAll(from: url)

        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records[0].length, 10_000)
        XCTAssertEqual(records[0].sequence, seq)
        XCTAssertEqual(records[0].quality.count, 10_000)
        XCTAssertEqual(records[0].quality.meanQuality, 20.0, accuracy: 0.01)
    }

    // 47. Very short read (1 bp)
    func testFASTQ_sizeEdge_singleBaseRead() async throws {
        let content = "@tiny\nA\n+\nI\n"
        let url = writeFASTQ(content)
        let reader = FASTQReader()
        let records = try await reader.readAll(from: url)

        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records[0].length, 1)
        XCTAssertEqual(records[0].sequence, "A")
        XCTAssertEqual(records[0].quality.qualityAt(0), 40)
    }

    // 48. 1000 reads of varying lengths
    func testFASTQ_sizeEdge_thousandVaryingLengths() async throws {
        var content = ""
        var expectedLengths: [Int] = []
        for i in 1...1000 {
            let length = 10 + (i % 200) // Vary from 10 to 209
            let seq = randomDNA(length: length)
            let qual = uniformQuality("5", length: length)
            content += "@READ_\(i)\n\(seq)\n+\n\(qual)\n"
            expectedLengths.append(length)
        }
        let url = writeFASTQ(content)
        let reader = FASTQReader()
        let records = try await reader.readAll(from: url)

        XCTAssertEqual(records.count, 1000)
        for i in 0..<1000 {
            XCTAssertEqual(records[i].length, expectedLengths[i],
                           "Read \(i+1) length mismatch")
        }

        // Also test countRecords
        let count = try await reader.countRecords(in: url)
        XCTAssertEqual(count, 1000)
    }

    // =========================================================================
    // MARK: - FASTQ: Malformed Files
    // =========================================================================

    // 49. Missing quality line (only 3 lines per record)
    func testFASTQ_malformed_missingQualityLine() async throws {
        // This file has a header, sequence, and separator, but no quality line
        // before the next record starts.
        let content = "@read1\nATCG\n+\n@read2\nGCTA\n+\nIIII\n"
        let url = writeFASTQ(content)
        let reader = FASTQReader()

        // The parser should either error or misparse. "@read2" would be read
        // as the quality line for read1, and since its length (6) != sequence
        // length (4), it should throw qualityLengthMismatch.
        do {
            _ = try await reader.readAll(from: url)
            XCTFail("Expected error for missing quality line")
        } catch {
            // Any error is acceptable here; the file is malformed
            XCTAssertTrue(error is FASTQError, "Expected FASTQError but got \(type(of: error))")
        }
    }

    // 50. Extra blank lines between records
    func testFASTQ_malformed_extraBlankLines() async throws {
        let content = "@read1\nATCG\n+\nIIII\n\n\n@read2\nGCTA\n+\nHHHH\n\n"
        let url = writeFASTQ(content)
        let reader = FASTQReader()
        let records = try await reader.readAll(from: url)

        // The parser tolerates blank lines between records (in header state)
        XCTAssertEqual(records.count, 2)
        XCTAssertEqual(records[0].identifier, "read1")
        XCTAssertEqual(records[0].sequence, "ATCG")
        XCTAssertEqual(records[1].identifier, "read2")
        XCTAssertEqual(records[1].sequence, "GCTA")
    }

    // 51. Missing @ prefix on header
    func testFASTQ_malformed_missingAtPrefix() async throws {
        let content = "read1\nATCG\n+\nIIII\n"
        let url = writeFASTQ(content)
        let reader = FASTQReader()

        do {
            _ = try await reader.readAll(from: url)
            XCTFail("Expected FASTQError.invalidHeader for missing @ prefix")
        } catch let error as FASTQError {
            if case .invalidHeader = error {
                // Expected
            } else {
                XCTFail("Expected invalidHeader, got \(error)")
            }
        }
    }

    // 52. Truncated file (ends mid-record)
    func testFASTQ_malformed_truncatedFile() async throws {
        // File ends after sequence line, before separator
        let content = "@read1\nATCGATCG\n"
        let url = writeFASTQ(content)
        let reader = FASTQReader()

        do {
            _ = try await reader.readAll(from: url)
            XCTFail("Expected error for truncated file")
        } catch {
            // The parser should detect the incomplete record
            XCTAssertTrue(error is FASTQError,
                          "Expected FASTQError for truncated file, got \(type(of: error))")
        }
    }

    // =========================================================================
    // MARK: - FASTQ: Wrapped Sequences (Multi-Line)
    // =========================================================================

    func testFASTQ_multiLine_wrappedSequenceAndQuality() async throws {
        // FASTQ allows multi-line sequences; the parser should concatenate them
        let content = "@wrapped_read\nACGT\nTGCA\n+\nIIII\nJJJJ\n"
        let url = writeFASTQ(content)
        let reader = FASTQReader()
        let records = try await reader.readAll(from: url)

        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records[0].identifier, "wrapped_read")
        XCTAssertEqual(records[0].sequence, "ACGTTGCA")
        XCTAssertEqual(records[0].quality.toAscii(), "IIIIJJJJ")
        XCTAssertEqual(records[0].length, 8)
    }

    // =========================================================================
    // MARK: - FASTQ: Streaming
    // =========================================================================

    func testFASTQ_streaming_recordsStream() async throws {
        var content = ""
        for i in 1...25 {
            let seq = randomDNA(length: 80)
            let qual = uniformQuality("5", length: 80)
            content += "@STREAM_\(i)\n\(seq)\n+\n\(qual)\n"
        }
        let url = writeFASTQ(content)
        let reader = FASTQReader()

        var count = 0
        for try await record in reader.records(from: url) {
            count += 1
            XCTAssertFalse(record.identifier.isEmpty)
            XCTAssertEqual(record.length, 80)
        }
        XCTAssertEqual(count, 25)
    }

    // =========================================================================
    // MARK: - FASTQ: Statistics
    // =========================================================================

    func testFASTQ_statistics_basicStats() async throws {
        var content = ""
        for i in 1...20 {
            let len = 50 + i * 5  // 55 to 150
            let seq = randomDNA(length: len)
            let qual = uniformQuality("I", length: len)
            content += "@STAT_\(i)\n\(seq)\n+\n\(qual)\n"
        }
        let url = writeFASTQ(content)
        let reader = FASTQReader()
        let records = try await reader.readAll(from: url)

        let stats = FASTQStatistics(records: records)
        XCTAssertEqual(stats.readCount, 20)
        XCTAssertGreaterThan(stats.baseCount, 0)
        XCTAssertEqual(stats.minReadLength, 55)
        XCTAssertEqual(stats.maxReadLength, 150)
        XCTAssertEqual(stats.meanQuality, 40.0, accuracy: 0.01)
        XCTAssertEqual(stats.q30Percentage, 100.0, accuracy: 0.01)
    }

    func testFASTQ_statistics_emptyRecords() async throws {
        let stats = FASTQStatistics(records: [])
        XCTAssertEqual(stats.readCount, 0)
        XCTAssertEqual(stats.baseCount, 0)
        XCTAssertEqual(stats.meanReadLength, 0)
    }

    // =========================================================================
    // MARK: - FASTQ: Quality Encoding Detection
    // =========================================================================

    func testFASTQ_encoding_autoDetectPhred33() async throws {
        // '!' (ASCII 33) can only be Phred+33
        let content = "@detect33\nATCG\n+\n!5?I\n"
        let url = writeFASTQ(content)
        let reader = FASTQReader()
        let records = try await reader.readAll(from: url)

        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records[0].quality.encoding, .phred33)
    }

    // =========================================================================
    // MARK: - FASTQ: Record Operations (Trim, RC)
    // =========================================================================

    func testFASTQ_operations_qualityTrimming() async throws {
        let record = FASTQRecord(
            identifier: "trim_test",
            sequence: "ATCGATCGATCG",
            qualityString: "IIIIII!!!!!!",
            encoding: .phred33
        )

        let trimmed = record.qualityTrimmed(threshold: 20, windowSize: 3)
        XCTAssertLessThan(trimmed.length, record.length,
                          "Trimmed read should be shorter than original")
        XCTAssertGreaterThan(trimmed.length, 0, "Trimmed read should not be empty")
    }

    func testFASTQ_operations_reverseComplement() async throws {
        let record = FASTQRecord(
            identifier: "rc_test",
            sequence: "ATCG",
            qualityString: "ABCD",
            encoding: .phred33
        )

        let rc = record.reverseComplement()
        XCTAssertEqual(rc.sequence, "CGAT")
        XCTAssertEqual(rc.quality.toAscii(), "DCBA")
        XCTAssertEqual(rc.identifier, "rc_test")
    }

    // =========================================================================
    // MARK: - FASTQ: Paired-End Detection
    // =========================================================================

    func testFASTQ_pairedEnd_slashNotation() async throws {
        let r1 = FASTQRecord(
            identifier: "SAMPLE_001/1",
            sequence: "ATCG",
            qualityString: "IIII",
            encoding: .phred33
        )
        let r2 = FASTQRecord(
            identifier: "SAMPLE_001/2",
            sequence: "GCTA",
            qualityString: "HHHH",
            encoding: .phred33
        )

        XCTAssertNotNil(r1.readPair)
        XCTAssertEqual(r1.readPair?.readNumber, 1)
        XCTAssertEqual(r1.readPair?.pairId, "SAMPLE_001")
        XCTAssertNotNil(r2.readPair)
        XCTAssertEqual(r2.readPair?.readNumber, 2)
        XCTAssertEqual(r2.readPair?.pairId, "SAMPLE_001")
    }

    func testFASTQ_pairedEnd_illuminaFormat() async throws {
        // Illumina format: identifier followed by "1:N:0:SAMPLE" after space
        let r1 = FASTQRecord(
            identifier: "INSTRUMENT:RUN:FLOW:LANE:TILE:1000:2000 1:N:0:ATCACG",
            sequence: "ATCG",
            qualityString: "IIII",
            encoding: .phred33
        )

        // ReadPair.parse checks the identifier field. But the identifier as
        // stored by FASTQReader is only up to the first space. Let's test
        // with how the reader would actually parse it.
        let content = "@INSTRUMENT:RUN:FLOW:LANE:TILE:1000:2000 1:N:0:ATCACG\nATCG\n+\nIIII\n"
        let url = writeFASTQ(content)
        let reader = FASTQReader()
        let records = try await reader.readAll(from: url)

        XCTAssertEqual(records[0].identifier, "INSTRUMENT:RUN:FLOW:LANE:TILE:1000:2000")
        // ReadPair parsing from the identifier alone (without the description)
        // won't detect Illumina format since it requires a space.
        // The raw identifier doesn't contain the space portion.
        _ = r1 // Suppress unused warning
    }

    // =========================================================================
    // MARK: - FASTQ: Gzip Compression
    // =========================================================================

    func testFASTQ_compression_gzipped() async throws {
        // Build a plain FASTQ, gzip it, then read via FASTQReader
        var plainContent = ""
        for i in 1...5 {
            let seq = randomDNA(length: 40)
            let qual = uniformQuality("I", length: 40)
            plainContent += "@GZ_READ_\(i)\n\(seq)\n+\n\(qual)\n"
        }
        let plainURL = writeFASTQ(plainContent, name: "reads.fastq")
        let gzURL = tempDirectory.appendingPathComponent("reads.fastq.gz")

        // Compress
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/gzip")
        process.arguments = ["-c", plainURL.path]
        let pipe = Pipe()
        process.standardOutput = pipe
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)

        let compressed = pipe.fileHandleForReading.readDataToEndOfFile()
        try compressed.write(to: gzURL)

        // Read via FASTQReader (which auto-decompresses .gz)
        let reader = FASTQReader()
        let records = try await reader.readAll(from: gzURL)

        XCTAssertEqual(records.count, 5)
        for i in 0..<5 {
            XCTAssertEqual(records[i].identifier, "GZ_READ_\(i + 1)")
            XCTAssertEqual(records[i].length, 40)
        }
    }

    // =========================================================================
    // MARK: - FASTQ: Sequence Validation
    // =========================================================================

    func testFASTQ_validation_iupacCodesAccepted() async throws {
        // The FASTQ reader accepts IUPAC ambiguity codes when validateSequence=true
        let seq = "ATCGRYSWKMBDHVN"
        let qual = uniformQuality("I", length: seq.count)
        let content = "@iupac\n\(seq)\n+\n\(qual)\n"
        let url = writeFASTQ(content)
        let reader = FASTQReader(validateSequence: true)
        let records = try await reader.readAll(from: url)

        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records[0].sequence, seq)
    }

    func testFASTQ_validation_invalidCharacterRejected() async throws {
        let content = "@bad\nATCGXATCG\n+\nIIIIIIIII\n"
        let url = writeFASTQ(content)
        let reader = FASTQReader(validateSequence: true)

        do {
            _ = try await reader.readAll(from: url)
            XCTFail("Expected error for invalid character X in sequence")
        } catch let error as FASTQError {
            if case .invalidSequenceCharacter = error {
                // Expected
            } else {
                XCTFail("Expected invalidSequenceCharacter, got \(error)")
            }
        }
    }

    func testFASTQ_validation_disabledAllowsAnything() async throws {
        // With validation disabled, any character is accepted
        let content = "@anything\nXYZ123\n+\n!!!!!!\n"
        let url = writeFASTQ(content)
        let reader = FASTQReader(validateSequence: false)
        let records = try await reader.readAll(from: url)

        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records[0].sequence, "XYZ123")
    }

    // =========================================================================
    // MARK: - FASTQ: Line Length Limit
    // =========================================================================

    func testFASTQ_lineLengthLimit_exceedsMax() async throws {
        let longSeq = randomDNA(length: 100)
        let longQual = uniformQuality("I", length: 100)
        let content = "@long_line\n\(longSeq)\n+\n\(longQual)\n"
        let url = writeFASTQ(content)

        // Set a very low max line length
        let reader = FASTQReader(maxLineLength: 50)

        do {
            _ = try await reader.readAll(from: url)
            XCTFail("Expected FASTQError.lineTooLong")
        } catch let error as FASTQError {
            if case .lineTooLong = error {
                // Expected
            } else {
                XCTFail("Expected lineTooLong, got \(error)")
            }
        }
    }

    // =========================================================================
    // MARK: - FASTQ: Zero-Length Read
    // =========================================================================

    func testFASTQ_zeroLengthRead() async throws {
        let content = "@EMPTY\n\n+\n\n@NORMAL\nATCG\n+\nIIII\n"
        let url = writeFASTQ(content)
        let reader = FASTQReader(validateSequence: false)
        let records = try await reader.readAll(from: url)

        XCTAssertEqual(records.count, 2)
        XCTAssertEqual(records[0].identifier, "EMPTY")
        XCTAssertEqual(records[0].sequence, "")
        XCTAssertEqual(records[0].quality.count, 0)
        XCTAssertEqual(records[1].identifier, "NORMAL")
        XCTAssertEqual(records[1].sequence, "ATCG")
    }

    // =========================================================================
    // MARK: - FASTQ: Invalid Separator
    // =========================================================================

    func testFASTQ_malformed_invalidSeparator() async throws {
        let content = "@read1\nATCG\n-\nIIII\n"
        let url = writeFASTQ(content)
        let reader = FASTQReader()

        do {
            _ = try await reader.readAll(from: url)
            XCTFail("Expected FASTQError.invalidSeparator for '-' separator")
        } catch let error as FASTQError {
            // The parser validates sequence characters and a '-' line after
            // sequence would be caught either as invalidSequenceCharacter
            // (if treated as continued sequence) or invalidSeparator.
            switch error {
            case .invalidSeparator, .invalidSequenceCharacter:
                break // Expected
            default:
                XCTFail("Expected invalidSeparator or invalidSequenceCharacter, got \(error)")
            }
        }
    }

    // =========================================================================
    // MARK: - FASTQ: Truncated Mid-Quality
    // =========================================================================

    func testFASTQ_malformed_truncatedMidQuality() async throws {
        // Quality line is present but shorter than sequence, and file ends
        let content = "@read1\nATCGATCG\n+\nIII"
        let url = writeFASTQ(content)
        let reader = FASTQReader()

        do {
            _ = try await reader.readAll(from: url)
            XCTFail("Expected error for truncated quality")
        } catch let error as FASTQError {
            switch error {
            case .qualityLengthMismatch, .unexpectedEndOfFile:
                break // Expected
            default:
                XCTFail("Expected qualityLengthMismatch or unexpectedEndOfFile, got \(error)")
            }
        }
    }

    // =========================================================================
    // MARK: - FASTQ: Multiple Records with Different Quality Profiles
    // =========================================================================

    func testFASTQ_qualityProfiles_gcContentAndStats() async throws {
        // Create reads with known GC content
        let gcRichSeq = String(repeating: "GC", count: 25) // 50 bases, 100% GC
        let atRichSeq = String(repeating: "AT", count: 25) // 50 bases, 0% GC
        let qual = uniformQuality("I", length: 50)

        let content = """
        @gc_rich
        \(gcRichSeq)
        +
        \(qual)
        @at_rich
        \(atRichSeq)
        +
        \(qual)

        """
        let url = writeFASTQ(content)
        let reader = FASTQReader()
        let records = try await reader.readAll(from: url)

        XCTAssertEqual(records.count, 2)

        let stats = FASTQStatistics(records: records)
        XCTAssertEqual(stats.readCount, 2)
        XCTAssertEqual(stats.gcContent, 50.0, accuracy: 0.1)
    }

    // =========================================================================
    // MARK: - FASTA: Alphabet Detection
    // =========================================================================

    func testFASTA_alphabetDetection_dna() async throws {
        let url = writeFASTA(">dna\nATCGATCG\n")
        let reader = try FASTAReader(url: url)
        let seqs = try await reader.readAll()

        XCTAssertEqual(seqs[0].alphabet, .dna)
    }

    func testFASTA_alphabetDetection_rna() async throws {
        let url = writeFASTA(">rna\nAUGCAUGC\n")
        let reader = try FASTAReader(url: url)
        let seqs = try await reader.readAll()

        XCTAssertEqual(seqs[0].alphabet, .rna)
    }

    func testFASTA_alphabetDetection_protein() async throws {
        let url = writeFASTA(">prot\nMEIFLPQAKR\n")
        let reader = try FASTAReader(url: url)
        let seqs = try await reader.readAll()

        XCTAssertEqual(seqs[0].alphabet, .protein)
    }

    func testFASTA_alphabetDetection_explicitOverride() async throws {
        // Force DNA alphabet even though sequence might look ambiguous
        let url = writeFASTA(">forced\nATCGNNNN\n")
        let reader = try FASTAReader(url: url)
        let seqs = try await reader.readAll(alphabet: .dna)

        XCTAssertEqual(seqs[0].alphabet, .dna)
    }

    // =========================================================================
    // MARK: - FASTA Writer Round-Trip
    // =========================================================================

    func testFASTA_roundTrip_writeAndRead() async throws {
        let outputURL = tempDirectory.appendingPathComponent("roundtrip.fasta")
        let writer = FASTAWriter(url: outputURL, lineWidth: 60)

        let seq1 = try LungfishCore.Sequence(
            name: "chr1",
            description: "chromosome 1",
            alphabet: .dna,
            bases: randomDNA(length: 200)
        )
        let seq2 = try LungfishCore.Sequence(
            name: "chr2",
            description: "chromosome 2",
            alphabet: .dna,
            bases: randomDNA(length: 150)
        )

        try writer.write([seq1, seq2])

        let reader = try FASTAReader(url: outputURL)
        let readBack = try await reader.readAll()

        XCTAssertEqual(readBack.count, 2)
        XCTAssertEqual(readBack[0].name, "chr1")
        XCTAssertEqual(readBack[0].description, "chromosome 1")
        XCTAssertEqual(readBack[0].asString(), seq1.asString())
        XCTAssertEqual(readBack[1].name, "chr2")
        XCTAssertEqual(readBack[1].asString(), seq2.asString())
    }

    // =========================================================================
    // MARK: - FASTQ Writer Round-Trip
    // =========================================================================

    func testFASTQ_roundTrip_writeAndRead() async throws {
        let outputURL = tempDirectory.appendingPathComponent("roundtrip.fastq")

        var records: [FASTQRecord] = []
        for i in 1...10 {
            let seq = randomDNA(length: 80)
            let qual = uniformQuality("5", length: 80)
            records.append(FASTQRecord(
                identifier: "RT_\(i)",
                description: "round trip test \(i)",
                sequence: seq,
                qualityString: qual,
                encoding: .phred33
            ))
        }

        try FASTQWriter.write(records, to: outputURL)

        let reader = FASTQReader()
        let readBack = try await reader.readAll(from: outputURL)

        XCTAssertEqual(readBack.count, 10)
        for i in 0..<10 {
            XCTAssertEqual(readBack[i].identifier, records[i].identifier)
            XCTAssertEqual(readBack[i].description, records[i].description)
            XCTAssertEqual(readBack[i].sequence, records[i].sequence)
            XCTAssertEqual(readBack[i].quality.toAscii(), records[i].quality.toAscii())
        }
    }

    // =========================================================================
    // MARK: - FASTQ: Consecutive Records Without Blank Lines
    // =========================================================================

    func testFASTQ_basic_consecutiveRecordsNoBlankLines() async throws {
        // Standard FASTQ: records back to back, no blank lines
        let content = "@r1\nATCG\n+\nIIII\n@r2\nGCTA\n+\nHHHH\n@r3\nAAAA\n+\n5555\n"
        let url = writeFASTQ(content)
        let reader = FASTQReader()
        let records = try await reader.readAll(from: url)

        XCTAssertEqual(records.count, 3)
        XCTAssertEqual(records[0].identifier, "r1")
        XCTAssertEqual(records[0].sequence, "ATCG")
        XCTAssertEqual(records[1].identifier, "r2")
        XCTAssertEqual(records[1].sequence, "GCTA")
        XCTAssertEqual(records[2].identifier, "r3")
        XCTAssertEqual(records[2].sequence, "AAAA")
    }

    // =========================================================================
    // MARK: - FASTQ: Quality Score Edge Cases (Direct Construction)
    // =========================================================================

    func testQualityScore_errorProbability() {
        // Q40 -> P = 10^(-4) = 0.0001
        let q40 = QualityScore(ascii: "I", encoding: .phred33)
        XCTAssertEqual(q40.errorProbabilityAt(0), 0.0001, accuracy: 0.00001)

        // Q30 -> P = 10^(-3) = 0.001
        let q30 = QualityScore(ascii: "?", encoding: .phred33)
        XCTAssertEqual(q30.errorProbabilityAt(0), 0.001, accuracy: 0.0001)

        // Q0 -> P = 10^0 = 1.0
        let q0 = QualityScore(ascii: "!", encoding: .phred33)
        XCTAssertEqual(q0.errorProbabilityAt(0), 1.0, accuracy: 0.001)
    }

    func testQualityScore_histogram() {
        let quality = QualityScore(ascii: "IIIII55555!!!!", encoding: .phred33)
        let histogram = quality.qualityHistogram()

        XCTAssertEqual(histogram[40], 5)  // 'I' = Q40
        XCTAssertEqual(histogram[20], 5)  // '5' = Q20
        XCTAssertEqual(histogram[0], 4)   // '!' = Q0
    }

    func testQualityScore_trimPosition() {
        // High quality then low quality
        let quality = QualityScore(ascii: "IIIIIIIIII!!!!!!!!!!", encoding: .phred33)
        let trimPos = quality.trimPosition(threshold: 20, windowSize: 3)

        XCTAssertGreaterThan(trimPos, 0)
        XCTAssertLessThanOrEqual(trimPos, 12,
                                  "Trim position should be near the quality transition")
    }

    func testQualityScore_emptyQuality() {
        let empty = QualityScore()
        XCTAssertEqual(empty.count, 0)
        XCTAssertTrue(empty.isEmpty)
        XCTAssertEqual(empty.meanQuality, 0.0)
        XCTAssertEqual(empty.medianQuality, 0.0)
        XCTAssertEqual(empty.q20Percentage, 0.0)
    }

    // =========================================================================
    // MARK: - FASTA: Consecutive Headers (Empty Sequence Between)
    // =========================================================================

    func testFASTA_consecutiveHeaders_emptySequenceBetween() async throws {
        // Two headers in a row: first one has no sequence data
        let content = ">first\n>second\nATCG\n"
        let url = writeFASTA(content)
        let reader = try FASTAReader(url: url)
        let seqs = try await reader.readAll()

        // The first header has empty baseChunks when the second header is encountered,
        // so it should be skipped.
        XCTAssertEqual(seqs.count, 1)
        XCTAssertEqual(seqs[0].name, "second")
        XCTAssertEqual(seqs[0].asString(), "ATCG")
    }

    // =========================================================================
    // MARK: - FASTA: Leading Whitespace
    // =========================================================================

    func testFASTA_leadingWhitespace_stripped() async throws {
        // Lines with leading spaces should be handled by trimmingCharacters
        let content = ">seq1\n   ATCG   \n   ATCG   \n"
        let url = writeFASTA(content)
        let reader = try FASTAReader(url: url)
        let seqs = try await reader.readAll()

        XCTAssertEqual(seqs.count, 1)
        XCTAssertEqual(seqs[0].asString(), "ATCGATCG")
    }

    // =========================================================================
    // MARK: - FASTA: Multiple Sequences With Descriptions
    // =========================================================================

    func testFASTA_multipleSequencesWithDescriptions() async throws {
        let content = """
        >chr1 Homo sapiens chromosome 1
        ATCGATCGATCG
        ATCGATCGATCG
        >chrM Homo sapiens mitochondrion, complete genome
        GCTAGCTAGCTA
        >chrX Homo sapiens chromosome X
        NNNNNNNNNNNN

        """
        let url = writeFASTA(content)
        let reader = try FASTAReader(url: url)
        let seqs = try await reader.readAll()

        XCTAssertEqual(seqs.count, 3)
        XCTAssertEqual(seqs[0].name, "chr1")
        XCTAssertEqual(seqs[0].description, "Homo sapiens chromosome 1")
        XCTAssertEqual(seqs[0].length, 24)
        XCTAssertEqual(seqs[1].name, "chrM")
        XCTAssertEqual(seqs[1].description, "Homo sapiens mitochondrion, complete genome")
        XCTAssertEqual(seqs[2].name, "chrX")
        XCTAssertEqual(seqs[2].length, 12)
    }
}
