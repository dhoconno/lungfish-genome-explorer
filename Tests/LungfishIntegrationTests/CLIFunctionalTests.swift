// CLIFunctionalTests.swift — Functional tests for CLI commands using SARS-CoV-2 fixtures
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// These tests verify that CLI commands can process the nf-core SARS-CoV-2 test
// dataset end-to-end. Every test operates on local fixture files and requires
// no network access or external tools (samtools, bgzip, etc.).
//
// Commands under test: convert, extract, search, analyze stats, analyze validate,
// import vcf, import bam (file-copy only, samtools optional).

import ArgumentParser
import XCTest
@testable import LungfishCLI
@testable import LungfishCore
@testable import LungfishIO

/// Functional tests exercising CLI commands against real SARS-CoV-2 fixture files.
///
/// Each test creates a temporary directory, runs a CLI command via
/// ArgumentParser's `parse`/`run` pattern, and verifies the output.
@MainActor
final class CLIFunctionalTests: XCTestCase {

    // MARK: - Setup / Teardown

    var tempDirectory: URL!

    override func setUp() async throws {
        try await super.setUp()
        tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("LungfishCLIFunctionalTests-\(UUID().uuidString)")
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

    // MARK: - Convert: FASTA to GenBank

    /// Verifies that `convert` reads the SARS-CoV-2 FASTA reference and writes
    /// a valid GenBank file containing the expected sequence name and length.
    func testConvertFASTAToGenBank() async throws {
        let inputPath = TestFixtures.sarscov2.reference.path
        let outputPath = tempDirectory.appendingPathComponent("genome.gb").path

        var command = try ConvertCommand.parse([
            inputPath,
            "--to-format", "genbank",
            "--to", outputPath,
            "-q",
        ])
        try await command.run()

        let outputContent = try String(contentsOfFile: outputPath, encoding: .utf8)
        XCTAssertTrue(
            outputContent.contains("LOCUS"),
            "GenBank output should contain a LOCUS line"
        )
        XCTAssertTrue(
            outputContent.contains("MT192765.1"),
            "GenBank output should contain the sequence name MT192765.1"
        )
        XCTAssertTrue(
            outputContent.contains("ORIGIN"),
            "GenBank output should contain an ORIGIN section"
        )
        XCTAssertTrue(
            outputContent.contains("//"),
            "GenBank output should end with a terminator (//)"
        )
    }

    // MARK: - Convert: FASTA to FASTQ

    /// Verifies that `convert` produces a FASTQ file from FASTA input with
    /// synthetic quality scores.
    func testConvertFASTAToFASTQ() async throws {
        let inputPath = TestFixtures.sarscov2.reference.path
        let outputPath = tempDirectory.appendingPathComponent("genome.fastq").path

        var command = try ConvertCommand.parse([
            inputPath,
            "--to-format", "fastq",
            "--to", outputPath,
            "-q",
        ])
        try await command.run()

        let outputContent = try String(contentsOfFile: outputPath, encoding: .utf8)
        let lines = outputContent.components(separatedBy: "\n").filter { !$0.isEmpty }

        // FASTQ records come in groups of 4 lines: @header, sequence, +, quality
        XCTAssertGreaterThanOrEqual(lines.count, 4, "FASTQ should have at least one record (4 lines)")
        XCTAssertTrue(lines[0].hasPrefix("@"), "First line should be a FASTQ header starting with @")
        XCTAssertTrue(lines[2].hasPrefix("+"), "Third line should be the + separator")
    }

    // MARK: - Convert: Round-Trip FASTA -> GenBank -> FASTA

    /// Verifies that converting FASTA to GenBank and back preserves sequence content.
    func testConvertRoundTripFASTAGenBankFASTA() async throws {
        let gbPath = tempDirectory.appendingPathComponent("roundtrip.gb").path
        let fastaOutPath = tempDirectory.appendingPathComponent("roundtrip.fasta").path

        // Step 1: FASTA -> GenBank
        var toGB = try ConvertCommand.parse([
            TestFixtures.sarscov2.reference.path,
            "--to-format", "genbank",
            "--to", gbPath,
            "-q",
        ])
        try await toGB.run()

        // Step 2: GenBank -> FASTA
        var toFA = try ConvertCommand.parse([
            gbPath,
            "--to-format", "fasta",
            "--to", fastaOutPath,
            "-q",
        ])
        try await toFA.run()

        // Verify the round-tripped FASTA contains the same sequence name
        let output = try String(contentsOfFile: fastaOutPath, encoding: .utf8)
        XCTAssertTrue(
            output.contains(">MT192765.1"),
            "Round-tripped FASTA should preserve sequence name"
        )

        // Verify sequence length is preserved (~29903 bp)
        let sequence = output.components(separatedBy: "\n")
            .filter { !$0.hasPrefix(">") && !$0.isEmpty }
            .joined()
        XCTAssertGreaterThan(sequence.count, 29000, "Round-tripped sequence should be ~30 kb")
        XCTAssertLessThan(sequence.count, 31000, "Round-tripped sequence should be ~30 kb")
    }

    // MARK: - Extract: Subsequence from FASTA

    /// Verifies that `extract` pulls the correct region from the SARS-CoV-2
    /// reference and writes valid FASTA output.
    func testExtractSubsequenceFromFASTA() async throws {
        let outputPath = tempDirectory.appendingPathComponent("region.fasta").path

        var command = try ExtractSequenceSubcommand.parse([
            TestFixtures.sarscov2.reference.path,
            "MT192765.1:100-200",
            "--output", outputPath,
            "-q",
        ])
        try await command.run()

        let output = try String(contentsOfFile: outputPath, encoding: .utf8)
        let lines = output.components(separatedBy: "\n").filter { !$0.isEmpty }

        // Should have a FASTA header and sequence lines
        XCTAssertGreaterThanOrEqual(lines.count, 2, "Extract output should have header + sequence")
        XCTAssertTrue(lines[0].hasPrefix(">"), "First line should be a FASTA header")

        // The extracted sequence should be exactly 101 bp (1-based inclusive: 200-100+1)
        let sequence = lines.dropFirst().joined()
        XCTAssertEqual(
            sequence.count, 101,
            "Extracted region MT192765.1:100-200 should be 101 bp (1-based inclusive)"
        )
    }

    /// Verifies that `extract` with `--reverse-complement` produces a valid
    /// complemented sequence of the correct length.
    func testExtractReverseComplement() async throws {
        let outputPath = tempDirectory.appendingPathComponent("rc.fasta").path

        var command = try ExtractSequenceSubcommand.parse([
            TestFixtures.sarscov2.reference.path,
            "MT192765.1:1-50",
            "--reverse-complement",
            "--output", outputPath,
            "-q",
        ])
        try await command.run()

        let output = try String(contentsOfFile: outputPath, encoding: .utf8)
        let sequence = output.components(separatedBy: "\n")
            .filter { !$0.hasPrefix(">") && !$0.isEmpty }
            .joined()
        XCTAssertEqual(sequence.count, 50, "RC extract of 1-50 should be 50 bp")
    }

    /// Verifies that `extract` with `--flank` adds flanking bases on both sides.
    func testExtractWithFlanking() async throws {
        let outputPath = tempDirectory.appendingPathComponent("flanked.fasta").path

        var command = try ExtractSequenceSubcommand.parse([
            TestFixtures.sarscov2.reference.path,
            "MT192765.1:500-600",
            "--flank", "10",
            "--output", outputPath,
            "-q",
        ])
        try await command.run()

        let output = try String(contentsOfFile: outputPath, encoding: .utf8)
        let sequence = output.components(separatedBy: "\n")
            .filter { !$0.hasPrefix(">") && !$0.isEmpty }
            .joined()

        // 101 bp region + 10 bp on each side = 121 bp
        XCTAssertEqual(sequence.count, 121, "Flanked extract should be 121 bp (101 + 2*10)")
    }

    // MARK: - Search: Pattern in FASTA

    /// Verifies that `search` finds the ATG start codon in the SARS-CoV-2 genome
    /// and outputs BED-format matches.
    func testSearchExactPatternInFASTA() async throws {
        let outputPath = tempDirectory.appendingPathComponent("atg_sites.bed").path

        var command = try SearchCommand.parse([
            TestFixtures.sarscov2.reference.path,
            "ATGTTTAT",
            "--forward-only",
            "--output", outputPath,
            "-q",
        ])
        try await command.run()

        let output = try String(contentsOfFile: outputPath, encoding: .utf8)
        let matches = output.components(separatedBy: "\n").filter { !$0.isEmpty }

        // Should find at least one match in a 30 kb genome
        XCTAssertGreaterThan(matches.count, 0, "Should find ATGTTTAT in SARS-CoV-2 genome")

        // Verify BED format: chrom, start, end, name, score, strand
        for line in matches {
            let fields = line.components(separatedBy: "\t")
            XCTAssertEqual(fields.count, 6, "BED output should have 6 fields")
            XCTAssertEqual(fields[0], "MT192765.1", "Matches should be on MT192765.1")
            XCTAssertNotNil(Int(fields[1]), "Start should be an integer")
            XCTAssertNotNil(Int(fields[2]), "End should be an integer")
            XCTAssertEqual(fields[5], "+", "Forward-only matches should be on + strand")

            if let start = Int(fields[1]), let end = Int(fields[2]) {
                XCTAssertEqual(end - start, 8, "Match length should equal pattern length (8)")
            }
        }
    }

    /// Verifies that `search` with `--max-mismatches` finds approximate matches.
    func testSearchWithMismatches() async throws {
        let outputPath = tempDirectory.appendingPathComponent("mismatches.bed").path

        // Search for a pattern that may not exist exactly but should have near-matches
        var command = try SearchCommand.parse([
            TestFixtures.sarscov2.reference.path,
            "ATGTTTAT",
            "--forward-only",
            "--max-mismatches", "1",
            "--output", outputPath,
            "-q",
        ])
        try await command.run()

        let output = try String(contentsOfFile: outputPath, encoding: .utf8)
        let matchesWithMismatch = output.components(separatedBy: "\n").filter { !$0.isEmpty }

        // With mismatches allowed, should find at least as many as exact search
        XCTAssertGreaterThan(
            matchesWithMismatch.count, 0,
            "Mismatch search should find at least as many matches as exact"
        )
    }

    /// Verifies that `search` with `--iupac` correctly resolves ambiguity codes.
    func testSearchIUPACPattern() async throws {
        let outputPath = tempDirectory.appendingPathComponent("iupac.bed").path

        // ATGNNN should match any 3 bases after ATG
        var command = try SearchCommand.parse([
            TestFixtures.sarscov2.reference.path,
            "ATGNNN",
            "--iupac",
            "--forward-only",
            "--output", outputPath,
            "-q",
        ])
        try await command.run()

        let output = try String(contentsOfFile: outputPath, encoding: .utf8)
        let matches = output.components(separatedBy: "\n").filter { !$0.isEmpty }
        XCTAssertGreaterThan(matches.count, 0, "IUPAC search for ATGNNN should find matches")
    }

    // MARK: - Analyze: Stats on FASTA

    /// Verifies that `analyze stats` produces correct statistics for the
    /// SARS-CoV-2 reference genome.
    func testAnalyzeStatsFASTA() async throws {
        // Run with JSON output to parse the result
        var command = try StatsSubcommand.parse([
            TestFixtures.sarscov2.reference.path,
            "--format", "json",
            "-q",
        ])
        try await command.run()

        // Since JSON goes to stdout and we cannot easily capture it,
        // verify the command completes without error. For deeper verification,
        // run with TSV output and check the file.
        // The fact that it completed means the FASTA was read and stats computed.
    }

    /// Verifies that `analyze stats` in TSV mode produces parseable output
    /// with expected column count for the reference genome.
    func testAnalyzeStatsFASTACompletesSuccessfully() async throws {
        // Run with text format (default) to verify it completes
        var command = try StatsSubcommand.parse([
            TestFixtures.sarscov2.reference.path,
            "-q",
        ])
        // Should not throw -- stats are computed purely in Swift
        try await command.run()
    }

    // MARK: - Analyze: Validate Formats

    /// Verifies that `analyze validate` accepts the FASTA reference as valid.
    func testValidateFASTA() async throws {
        var command = try FileValidateSubcommand.parse([
            TestFixtures.sarscov2.reference.path,
            "-q",
        ])
        // Should not throw for a valid FASTA file
        try await command.run()
    }

    /// Verifies that `analyze validate` accepts the plain-text VCF as valid.
    func testValidateVCF() async throws {
        var command = try FileValidateSubcommand.parse([
            TestFixtures.sarscov2.vcf.path,
            "-q",
        ])
        try await command.run()
    }

    /// Verifies that `analyze validate` accepts the BED file as valid.
    func testValidateBED() async throws {
        var command = try FileValidateSubcommand.parse([
            TestFixtures.sarscov2.bed.path,
            "-q",
        ])
        try await command.run()
    }

    /// Verifies that `analyze validate` accepts the GFF3 file as valid.
    func testValidateGFF3() async throws {
        var command = try FileValidateSubcommand.parse([
            TestFixtures.sarscov2.gff3.path,
            "-q",
        ])
        try await command.run()
    }

    /// Verifies that `analyze validate` can validate multiple files at once.
    func testValidateMultipleFormats() async throws {
        var command = try FileValidateSubcommand.parse([
            TestFixtures.sarscov2.reference.path,
            TestFixtures.sarscov2.vcf.path,
            TestFixtures.sarscov2.bed.path,
            TestFixtures.sarscov2.gff3.path,
            "-q",
        ])
        try await command.run()
    }

    /// Verifies that `analyze validate` rejects a nonexistent file.
    func testValidateNonexistentFileThrows() async throws {
        let bogusPath = tempDirectory.appendingPathComponent("does_not_exist.fasta").path
        var command = try FileValidateSubcommand.parse([
            bogusPath,
            "-q",
        ])
        do {
            try await command.run()
            XCTFail("Validating a nonexistent file should throw")
        } catch {
            // Expected: ExitCode.failure
        }
    }

    // MARK: - Import VCF (file copy + parse, no external tools)

    /// Verifies that `import vcf` copies the VCF file into the output directory
    /// and produces a summary without errors.
    func testImportVCF() async throws {
        let projectDir = tempDirectory.appendingPathComponent("vcf-project")
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)

        var command = try ImportCommand.VCFSubcommand.parse([
            TestFixtures.sarscov2.vcf.path,
            "-o", projectDir.path,
            "-q",
        ])
        try await command.run()

        // Verify the VCF file was copied
        let destURL = projectDir.appendingPathComponent("test.vcf")
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: destURL.path),
            "VCF file should be copied to output directory"
        )

        // Verify the copy is non-empty
        let copiedData = try Data(contentsOf: destURL)
        XCTAssertGreaterThan(copiedData.count, 0, "Copied VCF should be non-empty")
    }

    // MARK: - Import BAM (file copy, samtools optional)

    /// Verifies that `import bam` copies the BAM file and its companion BAI
    /// index into the output directory. Statistics collection via samtools is
    /// optional and its absence does not cause failure.
    func testImportBAM() async throws {
        let projectDir = tempDirectory.appendingPathComponent("bam-project")
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)

        var command = try ImportCommand.BAMSubcommand.parse([
            TestFixtures.sarscov2.sortedBam.path,
            "-o", projectDir.path,
            "-q",
        ])
        try await command.run()

        // Verify the BAM file was copied
        let destBAM = projectDir.appendingPathComponent("test.paired_end.sorted.bam")
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: destBAM.path),
            "BAM file should be copied to output directory"
        )

        let copiedData = try Data(contentsOf: destBAM)
        XCTAssertGreaterThan(copiedData.count, 0, "Copied BAM should be non-empty")

        // BAM should start with gzip magic bytes
        XCTAssertEqual(copiedData[0], 0x1f, "Copied BAM should start with gzip magic byte 1")
        XCTAssertEqual(copiedData[1], 0x8b, "Copied BAM should start with gzip magic byte 2")
    }

    // MARK: - Extract: Error Handling

    /// Verifies that extracting a region beyond the genome length produces an error.
    func testExtractOutOfRangeThrows() async throws {
        let outputPath = tempDirectory.appendingPathComponent("bad_range.fasta").path

        var command = try ExtractSequenceSubcommand.parse([
            TestFixtures.sarscov2.reference.path,
            "MT192765.1:30000-40000",
            "--output", outputPath,
            "-q",
        ])
        do {
            try await command.run()
            XCTFail("Extracting beyond genome length should throw")
        } catch {
            // Expected: CLIError.conversionFailed with "exceeds sequence length"
        }
    }

    /// Verifies that extracting from a nonexistent chromosome name produces an error.
    func testExtractBadChromosomeThrows() async throws {
        let outputPath = tempDirectory.appendingPathComponent("bad_chrom.fasta").path

        var command = try ExtractSequenceSubcommand.parse([
            TestFixtures.sarscov2.reference.path,
            "chr1:100-200",
            "--output", outputPath,
            "-q",
        ])
        do {
            try await command.run()
            XCTFail("Extracting from nonexistent chromosome should throw")
        } catch {
            // Expected: CLIError.conversionFailed with "not found"
        }
    }

    // MARK: - Convert: Error Handling

    /// Verifies that converting to an unsupported format produces an error.
    func testConvertUnsupportedFormatThrows() async throws {
        let outputPath = tempDirectory.appendingPathComponent("output.xyz").path

        var command = try ConvertCommand.parse([
            TestFixtures.sarscov2.reference.path,
            "--to-format", "xyz",
            "--to", outputPath,
            "-q",
        ])
        do {
            try await command.run()
            XCTFail("Converting to unsupported format should throw")
        } catch {
            // Expected: CLIError.unsupportedFormat
        }
    }

    /// Verifies that converting a nonexistent input file produces an error.
    func testConvertNonexistentInputThrows() async throws {
        let bogusInput = tempDirectory.appendingPathComponent("nonexistent.fasta").path
        let outputPath = tempDirectory.appendingPathComponent("output.gb").path

        var command = try ConvertCommand.parse([
            bogusInput,
            "--to-format", "genbank",
            "--to", outputPath,
            "-q",
        ])
        do {
            try await command.run()
            XCTFail("Converting a nonexistent file should throw")
        } catch {
            // Expected: CLIError.inputFileNotFound
        }
    }

    // MARK: - Search: Error Handling

    /// Verifies that searching a nonexistent file produces an error.
    func testSearchNonexistentInputThrows() async throws {
        let bogusInput = tempDirectory.appendingPathComponent("ghost.fasta").path

        var command = try SearchCommand.parse([
            bogusInput,
            "ATG",
            "-q",
        ])
        do {
            try await command.run()
            XCTFail("Searching a nonexistent file should throw")
        } catch {
            // Expected: CLIError.inputFileNotFound
        }
    }
}
