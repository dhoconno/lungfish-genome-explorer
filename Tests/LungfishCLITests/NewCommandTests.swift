// NewCommandTests.swift - Tests for translate, search, extract, and composition commands
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import ArgumentParser
import XCTest
@testable import LungfishCLI
@testable import LungfishCore
@testable import LungfishIO

// MARK: - TranslateCommand Tests

final class TranslateCommandTests: XCTestCase {

    var tempDir: URL!

    override func setUp() async throws {
        try await super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cli_translate_tests_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        if let tempDir = tempDir {
            try? FileManager.default.removeItem(at: tempDir)
        }
        try await super.tearDown()
    }

    /// Verifies that TranslateResult can be encoded to JSON and decoded back.
    func testTranslateResultCodable() throws {
        let result = TranslateResult(
            inputFile: "test.fasta",
            outputFile: "output.fasta",
            sequenceCount: 2,
            translationCount: 12,
            codonTable: "Standard",
            codonTableId: 1,
            frames: ["+1", "+2", "+3", "-1", "-2", "-3"]
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let data = try encoder.encode(result)
        let decoded = try JSONDecoder().decode(TranslateResult.self, from: data)

        XCTAssertEqual(decoded.inputFile, "test.fasta")
        XCTAssertEqual(decoded.outputFile, "output.fasta")
        XCTAssertEqual(decoded.sequenceCount, 2)
        XCTAssertEqual(decoded.translationCount, 12)
        XCTAssertEqual(decoded.codonTable, "Standard")
        XCTAssertEqual(decoded.codonTableId, 1)
        XCTAssertEqual(decoded.frames.count, 6)
    }

    /// Verifies that TranslateResult encodes nil output file correctly.
    func testTranslateResultNilOutput() throws {
        let result = TranslateResult(
            inputFile: "test.fasta",
            outputFile: nil,
            sequenceCount: 1,
            translationCount: 6,
            codonTable: "Standard",
            codonTableId: 1,
            frames: ["+1"]
        )

        let data = try JSONEncoder().encode(result)
        let decoded = try JSONDecoder().decode(TranslateResult.self, from: data)
        XCTAssertNil(decoded.outputFile)
    }

    /// Verifies that translate command writes FASTA output to a file.
    func testTranslateCommandWritesOutput() async throws {
        // Create a test FASTA file with a known coding sequence
        let fastaURL = tempDir.appendingPathComponent("coding.fasta")
        // ATG = M, GAA = E, TTC = F, TAA = * (stop)
        let seq = try Sequence(name: "test_cds", alphabet: .dna, bases: "ATGGAATTCTAA")
        let writer = FASTAWriter(url: fastaURL)
        try writer.write([seq])

        let outputURL = tempDir.appendingPathComponent("protein.fasta")

        // Parse and run command
        var command = try TranslateCommand.parse([
            fastaURL.path,
            "--frame", "1",
            "--output", outputURL.path,
            "-q",
        ])
        try await command.run()

        // Verify output exists and contains translated protein
        let outputContent = try String(contentsOf: outputURL, encoding: .utf8)
        XCTAssertTrue(outputContent.contains(">test_cds_frame+1"))
        // ATG->M, GAA->E, TTC->F, TAA->* (stop as asterisk by default)
        XCTAssertTrue(outputContent.contains("MEF*"))
    }

    /// Verifies that translate command handles the --trim-to-stop flag.
    func testTranslateCommandTrimToStop() async throws {
        let fastaURL = tempDir.appendingPathComponent("trimstop.fasta")
        // ATG=M, GAA=E, TAA=stop, ATG=M (should be trimmed)
        let seq = try Sequence(name: "test", alphabet: .dna, bases: "ATGGAATAAATG")
        let writer = FASTAWriter(url: fastaURL)
        try writer.write([seq])

        let outputURL = tempDir.appendingPathComponent("trimmed.fasta")

        var command = try TranslateCommand.parse([
            fastaURL.path,
            "--frame", "1",
            "--trim-to-stop",
            "--output", outputURL.path,
            "-q",
        ])
        try await command.run()

        let outputContent = try String(contentsOf: outputURL, encoding: .utf8)
        // Should contain ME but NOT the stop codon or subsequent M
        XCTAssertTrue(outputContent.contains("ME"))
        XCTAssertFalse(outputContent.contains("*"))
    }

    /// Verifies that translate command rejects invalid frame numbers.
    func testTranslateCommandInvalidFrame() async throws {
        let fastaURL = tempDir.appendingPathComponent("test.fasta")
        let seq = try Sequence(name: "test", alphabet: .dna, bases: "ATCGATCG")
        let writer = FASTAWriter(url: fastaURL)
        try writer.write([seq])

        var command = try TranslateCommand.parse([
            fastaURL.path,
            "--frame", "7",
            "-q",
        ])

        do {
            try await command.run()
            XCTFail("Expected error for invalid frame")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("Frame must be 1-6"))
        }
    }

    /// Verifies that translate command rejects invalid codon table ID.
    func testTranslateCommandInvalidTable() async throws {
        let fastaURL = tempDir.appendingPathComponent("test.fasta")
        let seq = try Sequence(name: "test", alphabet: .dna, bases: "ATCGATCG")
        let writer = FASTAWriter(url: fastaURL)
        try writer.write([seq])

        var command = try TranslateCommand.parse([
            fastaURL.path,
            "--table", "99",
            "-q",
        ])

        do {
            try await command.run()
            XCTFail("Expected error for invalid table")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("Unknown genetic code table"))
        }
    }

    /// Verifies translate command uses vertebrate mitochondrial code.
    func testTranslateCommandMitoTable() async throws {
        let fastaURL = tempDir.appendingPathComponent("mito.fasta")
        // AGA is Arg in standard code, but Stop (*) in vertebrate mito
        let seq = try Sequence(name: "mito_test", alphabet: .dna, bases: "ATGAGA")
        let writer = FASTAWriter(url: fastaURL)
        try writer.write([seq])

        let outputURL = tempDir.appendingPathComponent("mito_protein.fasta")

        var command = try TranslateCommand.parse([
            fastaURL.path,
            "--frame", "1",
            "--table", "2",
            "--output", outputURL.path,
            "-q",
        ])
        try await command.run()

        let outputContent = try String(contentsOf: outputURL, encoding: .utf8)
        // In vertebrate mito code, AGA -> * (stop)
        XCTAssertTrue(outputContent.contains("M*"))
    }

    /// Verifies that missing input file produces an error.
    func testTranslateCommandMissingInput() async throws {
        var command = try TranslateCommand.parse([
            "/nonexistent/path/missing.fasta",
            "-q",
        ])

        do {
            try await command.run()
            XCTFail("Expected error for missing input")
        } catch let error as CLIError {
            XCTAssertEqual(error.exitCode, .inputError)
        }
    }
}

// MARK: - SearchCommand Tests

final class SearchCommandTests: XCTestCase {

    var tempDir: URL!

    override func setUp() async throws {
        try await super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cli_search_tests_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        if let tempDir = tempDir {
            try? FileManager.default.removeItem(at: tempDir)
        }
        try await super.tearDown()
    }

    /// Verifies that SearchMatch can be encoded and decoded.
    func testSearchMatchCodable() throws {
        let match = SearchMatch(
            chromosome: "chr1",
            start: 100,
            end: 106,
            strand: "+",
            mismatches: 0
        )

        let data = try JSONEncoder().encode(match)
        let decoded = try JSONDecoder().decode(SearchMatch.self, from: data)

        XCTAssertEqual(decoded.chromosome, "chr1")
        XCTAssertEqual(decoded.start, 100)
        XCTAssertEqual(decoded.end, 106)
        XCTAssertEqual(decoded.strand, "+")
        XCTAssertEqual(decoded.mismatches, 0)
    }

    /// Verifies that PatternSearchResult can be encoded and decoded.
    func testPatternSearchResultCodable() throws {
        let result = PatternSearchResult(
            inputFile: "genome.fasta",
            pattern: "GAATTC",
            patternType: "exact",
            matchCount: 3,
            sequenceCount: 1,
            matches: [
                SearchMatch(chromosome: "chr1", start: 100, end: 106, strand: "+", mismatches: 0),
            ]
        )

        let data = try JSONEncoder().encode(result)
        let decoded = try JSONDecoder().decode(PatternSearchResult.self, from: data)

        XCTAssertEqual(decoded.inputFile, "genome.fasta")
        XCTAssertEqual(decoded.pattern, "GAATTC")
        XCTAssertEqual(decoded.matchCount, 3)
        XCTAssertEqual(decoded.matches.count, 1)
    }

    /// Verifies exact pattern search finds matches and writes BED output.
    func testSearchCommandExactMatch() async throws {
        let fastaURL = tempDir.appendingPathComponent("search_test.fasta")
        // GAATTC at position 6
        let seq = try Sequence(name: "seq1", alphabet: .dna, bases: "ATCGATGAATTCATCG")
        let writer = FASTAWriter(url: fastaURL)
        try writer.write([seq])

        let outputURL = tempDir.appendingPathComponent("matches.bed")

        var command = try SearchCommand.parse([
            fastaURL.path,
            "GAATTC",
            "--forward-only",
            "--output", outputURL.path,
            "-q",
        ])
        try await command.run()

        let output = try String(contentsOf: outputURL, encoding: .utf8)
        let lines = output.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: "\n")
        XCTAssertEqual(lines.count, 1)

        // BED format: chrom start end name score strand
        let fields = lines[0].split(separator: "\t")
        XCTAssertEqual(fields[0], "seq1")
        XCTAssertEqual(fields[1], "6")     // 0-based start
        XCTAssertEqual(fields[2], "12")    // 0-based end
        XCTAssertEqual(fields[5], "+")
    }

    /// Verifies search with mismatches finds approximate matches.
    func testSearchCommandWithMismatches() async throws {
        let fastaURL = tempDir.appendingPathComponent("mismatch_test.fasta")
        // Exact GAATTC at pos 0, GAATTG (1 mismatch) at pos 8
        let seq = try Sequence(name: "seq1", alphabet: .dna, bases: "GAATTCATGAATTGAT")
        let writer = FASTAWriter(url: fastaURL)
        try writer.write([seq])

        let outputURL = tempDir.appendingPathComponent("mismatches.bed")

        var command = try SearchCommand.parse([
            fastaURL.path,
            "GAATTC",
            "--max-mismatches", "1",
            "--forward-only",
            "--output", outputURL.path,
            "-q",
        ])
        try await command.run()

        let output = try String(contentsOf: outputURL, encoding: .utf8)
        let lines = output.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: "\n")
        XCTAssertEqual(lines.count, 2, "Should find exact + 1-mismatch match")
    }

    /// Verifies IUPAC pattern search.
    func testSearchCommandIUPAC() async throws {
        let fastaURL = tempDir.appendingPathComponent("iupac_test.fasta")
        // TATAAAT and TATATAT should both match TATAWAT (W = A or T)
        let seq = try Sequence(name: "seq1", alphabet: .dna, bases: "TATAAATGGGGTATATAT")
        let writer = FASTAWriter(url: fastaURL)
        try writer.write([seq])

        let outputURL = tempDir.appendingPathComponent("iupac.bed")

        var command = try SearchCommand.parse([
            fastaURL.path,
            "TATAWAT",
            "--iupac",
            "--forward-only",
            "--output", outputURL.path,
            "-q",
        ])
        try await command.run()

        let output = try String(contentsOf: outputURL, encoding: .utf8)
        let lines = output.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: "\n")
        XCTAssertEqual(lines.count, 2, "Should find two IUPAC matches")
    }

    /// Verifies regex pattern search.
    func testSearchCommandRegex() async throws {
        let fastaURL = tempDir.appendingPathComponent("regex_test.fasta")
        let seq = try Sequence(name: "seq1", alphabet: .dna, bases: "ATGATCGATCGATGTAA")
        let writer = FASTAWriter(url: fastaURL)
        try writer.write([seq])

        let outputURL = tempDir.appendingPathComponent("regex.bed")

        // Find ATG...ATG pattern
        var command = try SearchCommand.parse([
            fastaURL.path,
            "ATG.{3,9}ATG",
            "--regex",
            "--forward-only",
            "--output", outputURL.path,
            "-q",
        ])
        try await command.run()

        let output = try String(contentsOf: outputURL, encoding: .utf8)
        let lines = output.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: "\n")
        XCTAssertGreaterThanOrEqual(lines.count, 1, "Should find at least one regex match")
    }

    /// Verifies that empty pattern is rejected.
    func testSearchCommandEmptyPattern() async throws {
        let fastaURL = tempDir.appendingPathComponent("test.fasta")
        let seq = try Sequence(name: "seq1", alphabet: .dna, bases: "ATCGATCG")
        let writer = FASTAWriter(url: fastaURL)
        try writer.write([seq])

        var command = try SearchCommand.parse([
            fastaURL.path,
            "",
            "-q",
        ])

        do {
            try await command.run()
            XCTFail("Expected error for empty pattern")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("empty"))
        }
    }

    /// Verifies that --regex and --iupac cannot be combined.
    func testSearchCommandConflictingFlags() async throws {
        let fastaURL = tempDir.appendingPathComponent("test.fasta")
        let seq = try Sequence(name: "seq1", alphabet: .dna, bases: "ATCGATCG")
        let writer = FASTAWriter(url: fastaURL)
        try writer.write([seq])

        var command = try SearchCommand.parse([
            fastaURL.path,
            "ATCG",
            "--regex",
            "--iupac",
            "-q",
        ])

        do {
            try await command.run()
            XCTFail("Expected error for conflicting flags")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("Cannot use both"))
        }
    }

    /// Verifies reverse complement search finds matches on the minus strand.
    func testSearchCommandBothStrands() async throws {
        let fastaURL = tempDir.appendingPathComponent("strand_test.fasta")
        // GAATTC is a palindrome (EcoRI site) - same on both strands
        // AATTCC at pos 3 on forward, its rc = GGAATT not at pos 3
        // Let's use AAGCTT (HindIII) which is also palindromic
        let seq = try Sequence(name: "seq1", alphabet: .dna, bases: "GGGAAGCTTGGG")
        let writer = FASTAWriter(url: fastaURL)
        try writer.write([seq])

        let outputURL = tempDir.appendingPathComponent("strands.bed")

        // Search for AAGCTT which is palindromic, should match both strands at same position
        var command = try SearchCommand.parse([
            fastaURL.path,
            "AAGCTT",
            "--output", outputURL.path,
            "-q",
        ])
        try await command.run()

        let output = try String(contentsOf: outputURL, encoding: .utf8)
        let lines = output.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: "\n")
        // Palindromic site should match on both strands
        XCTAssertEqual(lines.count, 2, "Palindromic pattern should match on both strands")
    }
}

// MARK: - ExtractCommand Tests

final class ExtractCommandTests: XCTestCase {

    var tempDir: URL!

    override func setUp() async throws {
        try await super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cli_extract_tests_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        if let tempDir = tempDir {
            try? FileManager.default.removeItem(at: tempDir)
        }
        try await super.tearDown()
    }

    /// Verifies that ExtractResult can be encoded and decoded.
    func testExtractResultCodable() throws {
        let result = ExtractResult(
            inputFile: "genome.fasta",
            outputFile: "region.fasta",
            region: "chr1:100-200",
            chromosome: "chr1",
            start: 99,
            end: 200,
            length: 101,
            reverseComplement: false
        )

        let data = try JSONEncoder().encode(result)
        let decoded = try JSONDecoder().decode(ExtractResult.self, from: data)

        XCTAssertEqual(decoded.inputFile, "genome.fasta")
        XCTAssertEqual(decoded.region, "chr1:100-200")
        XCTAssertEqual(decoded.chromosome, "chr1")
        XCTAssertEqual(decoded.length, 101)
        XCTAssertFalse(decoded.reverseComplement)
    }

    /// Verifies basic region extraction from a single-sequence file.
    func testExtractCommandBasicRegion() async throws {
        let fastaURL = tempDir.appendingPathComponent("genome.fasta")
        let bases = "AAACCCGGGTTTAAACCCGGGTTT"  // 24 bases
        let seq = try Sequence(name: "chr1", alphabet: .dna, bases: bases)
        let writer = FASTAWriter(url: fastaURL)
        try writer.write([seq])

        let outputURL = tempDir.appendingPathComponent("region.fasta")

        // Extract bases 4-9 (1-based inclusive): "CCCGGG"
        var command = try ExtractCommand.parse([
            fastaURL.path,
            "chr1:4-9",
            "--output", outputURL.path,
            "-q",
        ])
        try await command.run()

        let output = try String(contentsOf: outputURL, encoding: .utf8)
        // The extracted sequence should be "CCCGGG" (positions 3-8 in 0-based)
        XCTAssertTrue(output.contains("CCCGGG"))
    }

    /// Verifies extraction with reverse complement.
    func testExtractCommandReverseComplement() async throws {
        let fastaURL = tempDir.appendingPathComponent("rc_test.fasta")
        let seq = try Sequence(name: "seq1", alphabet: .dna, bases: "ATCGATCG")
        let writer = FASTAWriter(url: fastaURL)
        try writer.write([seq])

        let outputURL = tempDir.appendingPathComponent("rc.fasta")

        // Extract all 8 bases and reverse complement
        var command = try ExtractCommand.parse([
            fastaURL.path,
            "seq1:1-8",
            "--reverse-complement",
            "--output", outputURL.path,
            "-q",
        ])
        try await command.run()

        let output = try String(contentsOf: outputURL, encoding: .utf8)
        // RC of ATCGATCG = CGATCGAT
        XCTAssertTrue(output.contains("CGATCGAT"))
    }

    /// Verifies extraction with flanking sequence.
    func testExtractCommandWithFlanking() async throws {
        let fastaURL = tempDir.appendingPathComponent("flank_test.fasta")
        let seq = try Sequence(name: "chr1", alphabet: .dna, bases: "AAACCCGGGTTTAAACCC")
        let writer = FASTAWriter(url: fastaURL)
        try writer.write([seq])

        let outputURL = tempDir.appendingPathComponent("flanked.fasta")

        // Extract bases 7-9 (1-based) = "GGG" with 3 bases flanking = "CCCGGGTTT"
        var command = try ExtractCommand.parse([
            fastaURL.path,
            "chr1:7-9",
            "--flank", "3",
            "--output", outputURL.path,
            "-q",
        ])
        try await command.run()

        let output = try String(contentsOf: outputURL, encoding: .utf8)
        XCTAssertTrue(output.contains("CCCGGGTTT"))
    }

    /// Verifies extraction from a multi-sequence file by name.
    func testExtractCommandMultiSequenceByName() async throws {
        let fastaURL = tempDir.appendingPathComponent("multi.fasta")
        let seq1 = try Sequence(name: "chr1", alphabet: .dna, bases: "AAACCCGGG")
        let seq2 = try Sequence(name: "chr2", alphabet: .dna, bases: "TTTAAACCC")
        let writer = FASTAWriter(url: fastaURL)
        try writer.write([seq1, seq2])

        let outputURL = tempDir.appendingPathComponent("chr2_region.fasta")

        var command = try ExtractCommand.parse([
            fastaURL.path,
            "chr2:1-3",
            "--output", outputURL.path,
            "-q",
        ])
        try await command.run()

        let output = try String(contentsOf: outputURL, encoding: .utf8)
        XCTAssertTrue(output.contains("TTT"))
    }

    /// Verifies that out-of-range coordinates produce an error.
    func testExtractCommandOutOfRange() async throws {
        let fastaURL = tempDir.appendingPathComponent("short.fasta")
        let seq = try Sequence(name: "seq1", alphabet: .dna, bases: "ATCG")
        let writer = FASTAWriter(url: fastaURL)
        try writer.write([seq])

        var command = try ExtractCommand.parse([
            fastaURL.path,
            "seq1:1-100",
            "-q",
        ])

        do {
            try await command.run()
            XCTFail("Expected error for out-of-range coordinates")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("exceeds sequence length"))
        }
    }

    /// Verifies that requesting a nonexistent sequence name produces an error.
    func testExtractCommandMissingSequence() async throws {
        let fastaURL = tempDir.appendingPathComponent("test.fasta")
        let seq = try Sequence(name: "chr1", alphabet: .dna, bases: "ATCGATCG")
        let writer = FASTAWriter(url: fastaURL)
        try writer.write([seq])

        var command = try ExtractCommand.parse([
            fastaURL.path,
            "chrX:1-4",
            "-q",
        ])

        do {
            try await command.run()
            XCTFail("Expected error for missing sequence")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("not found"))
        }
    }

    /// Verifies that invalid region format produces an error.
    func testExtractCommandInvalidRegion() async throws {
        let fastaURL = tempDir.appendingPathComponent("test.fasta")
        let seq = try Sequence(name: "seq1", alphabet: .dna, bases: "ATCGATCG")
        let writer = FASTAWriter(url: fastaURL)
        try writer.write([seq])

        var command = try ExtractCommand.parse([
            fastaURL.path,
            "invalid_format",
            "-q",
        ])

        do {
            try await command.run()
            XCTFail("Expected error for invalid region format")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("Invalid region format"))
        }
    }
}

// Tests for composition data types removed — types are internal to AnalyzeCommand

// MARK: - Subcommand Registration Tests

final class SubcommandRegistrationTests: XCTestCase {

    /// Verifies that the translate command is registered.
    func testTranslateCommandRegistered() throws {
        let config = LungfishCLI.configuration
        let subcommands = config.subcommands.map { $0.configuration.commandName }
        XCTAssertTrue(subcommands.contains("translate"))
    }

    /// Verifies that the search command is registered.
    func testSearchCommandRegistered() throws {
        let config = LungfishCLI.configuration
        let subcommands = config.subcommands.map { $0.configuration.commandName }
        XCTAssertTrue(subcommands.contains("search"))
    }

    /// Verifies that the extract command is registered.
    func testExtractCommandRegistered() throws {
        let config = LungfishCLI.configuration
        let subcommands = config.subcommands.map { $0.configuration.commandName }
        XCTAssertTrue(subcommands.contains("extract"))
    }

    /// Verifies that the analyze composition subcommand is registered.
    func testCompositionSubcommandRegistered() throws {
        let config = AnalyzeCommand.configuration
        let subcommands = config.subcommands.map { $0.configuration.commandName }
        XCTAssertTrue(subcommands.contains("composition"))
    }

    /// Verifies total subcommand count after additions.
    func testTotalSubcommandCount() throws {
        let config = LungfishCLI.configuration
        // Original 8 + 3 new (translate, search, extract) + conda + blast + esviritu + taxtriage = 15
        XCTAssertEqual(config.subcommands.count, 15)
    }

    /// Verifies analyze subcommand count.
    func testAnalyzeSubcommandCount() throws {
        let config = AnalyzeCommand.configuration
        // stats + composition + validate = 3
        XCTAssertEqual(config.subcommands.count, 3)
    }
}
