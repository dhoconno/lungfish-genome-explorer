// AnalyzeValidateStrictTests.swift - `analyze validate --strict` rejects readable but irregular files
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import ArgumentParser
import XCTest
@testable import LungfishCLI

final class AnalyzeValidateStrictTests: XCTestCase {
    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("AnalyzeValidateStrictTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    private func write(_ name: String, _ contents: String) throws -> URL {
        let url = tempDir.appendingPathComponent(name)
        try contents.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    // MARK: - Rules

    func testFastaStrictChecksReportDuplicatesEmptyRecordsAndNonIUPACCharacters() {
        let issues = StrictSequenceFileChecks.fastaIssues(records: [
            (name: "seq1 description", sequence: "ACGTNRYKM"),
            (name: "seq2", sequence: ""),
            (name: "seq1 another", sequence: "ACGT"),
            (name: "prot", sequence: "MKV*"),
            (name: "bad", sequence: "AC GT"),
        ])
        XCTAssertEqual(issues, [
            "Record 2 ('seq2') has an empty sequence",
            "Record 3 repeats the name 'seq1' of record 1",
            "Record 5 ('bad') contains ' ', which is not an IUPAC nucleotide or amino acid code",
        ])
    }

    func testFastqStrictChecksReportDuplicateIdentifiersAndEmptyReads() {
        let issues = StrictSequenceFileChecks.fastqIssues(records: [
            (identifier: "read1 1:N:0", sequence: "ACGT"),
            (identifier: "read2", sequence: ""),
            (identifier: "read1 2:N:0", sequence: "ACGT"),
        ])
        XCTAssertEqual(issues, [
            "Read 2 ('read2') has an empty sequence",
            "Read 3 repeats the identifier 'read1' of read 1",
        ])
    }

    func testVCFStrictChecksReportColumnCountDisagreementsAndRepeatedRecords() {
        let issues = StrictSequenceFileChecks.vcfIssues(lines: [
            "##fileformat=VCFv4.2",
            "#CHROM\tPOS\tID\tREF\tALT\tQUAL\tFILTER\tINFO\tFORMAT\tS1",
            "chr1\t100\t.\tA\tG\t50\tPASS\tDP=10\tGT\t0/1",
            "chr1\t200\t.\tC\tT\t50\tPASS\tDP=10\tGT",
            "chr1\t100\t.\tA\tG\t60\tPASS\tDP=12\tGT\t1/1",
            "",
        ])
        XCTAssertEqual(issues, [
            "Line 4 has 9 columns; the #CHROM header declares 10",
            "Line 5 repeats chr1:100 A>G first seen on line 3",
        ])
    }

    func testIssueListIsCappedWithACount() {
        let records = (1 ... 30).map { _ in (name: "dup", sequence: "ACGT") } // 29 duplicates
        let issues = StrictSequenceFileChecks.fastaIssues(records: records)
        XCTAssertEqual(issues.count, StrictSequenceFileChecks.maxReportedIssues + 1)
        XCTAssertEqual(issues.last, "... and \(29 - StrictSequenceFileChecks.maxReportedIssues) more")
    }

    // MARK: - Command

    func testIrregularFastaPassesPlainValidationAndFailsStrictValidation() async throws {
        let url = try write("dup.fasta", ">seq1\nACGT\n>seq1\nACGT\n")

        let plain = try FileValidateSubcommand.parse([url.path, "--quiet"])
        try await plain.run()

        let strict = try FileValidateSubcommand.parse([url.path, "--strict", "--quiet"])
        do {
            try await strict.run()
            XCTFail("strict validation must reject a FASTA with duplicate record names")
        } catch let code as ExitCode {
            XCTAssertEqual(code, CLIExitCode.formatError.exitCode)
        }
    }

    func testRegularFilesPassStrictValidation() async throws {
        let fasta = try write("ok.fasta", ">seq1 first\nACGTN\n>seq2\nGGCCAA\n")
        let fastq = try write("ok.fastq", "@r1\nACGT\n+\nIIII\n@r2\nACGT\n+\nIIII\n")
        let vcf = try write("ok.vcf", "##fileformat=VCFv4.2\n#CHROM\tPOS\tID\tREF\tALT\tQUAL\tFILTER\tINFO\nchr1\t100\t.\tA\tG\t50\tPASS\tDP=10\n")
        let command = try FileValidateSubcommand.parse([fasta.path, fastq.path, vcf.path, "--strict", "--quiet"])
        try await command.run()
    }

    func testStrictHelpNamesTheExtraChecks() {
        let help = FileValidateSubcommand.helpMessage()
        XCTAssertTrue(help.contains("--strict"))
        XCTAssertTrue(help.contains("readable but irregular"))
        XCTAssertTrue(help.contains("duplicate record names"))
        XCTAssertTrue(help.contains("#CHROM"))
        XCTAssertFalse(help.contains("Enable strict validation"))
    }
}
