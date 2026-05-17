// CLIExitCodeProcessTests.swift - Subprocess tests for CLIError exit status bridging
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import XCTest
@testable import LungfishCLI

final class CLIExitCodeProcessTests: XCTestCase {
    private var cliBinaryURL: URL? {
        let thisFile = URL(fileURLWithPath: #filePath)
        let repoRoot = thisFile
            .deletingLastPathComponent() // LungfishCLITests/
            .deletingLastPathComponent() // Tests/
            .deletingLastPathComponent() // repo root
        let buildProductsDirectory = Bundle(for: Self.self).bundleURL.deletingLastPathComponent()

        let environmentBinary = ProcessInfo.processInfo.environment["LUNGFISH_CLI_BINARY"]
            .map { URL(fileURLWithPath: $0) }
        let candidates = [
            environmentBinary,
            buildProductsDirectory.appendingPathComponent("lungfish-cli"),
            repoRoot.appendingPathComponent(".build/debug/lungfish-cli"),
            repoRoot.appendingPathComponent(".build/arm64-apple-macosx/debug/lungfish-cli"),
            repoRoot.appendingPathComponent(".build/x86_64-apple-macosx/debug/lungfish-cli"),
        ].compactMap { $0 }
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    func testConvertMissingInputExitsWithInputError() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cli-exit-code-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let missingInput = tempDir.appendingPathComponent("missing.fa")
        let output = tempDir.appendingPathComponent("out.fa")

        let result = try runCLI(["convert", missingInput.path, "--to", output.path])

        XCTAssertEqual(result.exitCode, CLIExitCode.inputError.rawValue)
        XCTAssertEqual(result.stdout, "")
        XCTAssertTrue(result.stderr.contains("Input file not found"))
        assertSingleErrorLine(in: result.stderr, diagnostic: "Input file not found")
    }

    func testConvertUnsupportedOutputFormatExitsWithFormatError() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cli-exit-code-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let input = tempDir.appendingPathComponent("input.fa")
        let output = tempDir.appendingPathComponent("out.unsupported")
        try ">seq1\nACGT\n".write(to: input, atomically: true, encoding: .utf8)

        let result = try runCLI([
            "convert",
            input.path,
            "--to", output.path,
            "--to-format", "unsupported",
        ])

        XCTAssertEqual(result.exitCode, CLIExitCode.formatError.rawValue)
        XCTAssertTrue(result.stderr.contains("Unsupported format"))
        assertSingleErrorLine(in: result.stderr, diagnostic: "Unsupported format")
    }

    func testImportBamMissingInputExitsWithInputError() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cli-exit-code-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let missingInput = tempDir.appendingPathComponent("missing.bam")

        let result = try runCLI(["import", "bam", missingInput.path])

        XCTAssertEqual(result.exitCode, CLIExitCode.inputError.rawValue)
        XCTAssertTrue(combinedOutput(result).contains("Input file not found"))
    }

    func testImportVariantsParseFailureExitsWithFormatError() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cli-exit-code-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let input = tempDir.appendingPathComponent("broken.vcf")
        try "not a vcf\n".write(to: input, atomically: true, encoding: .utf8)

        let result = try runCLI(["import", "vcf", input.path, "--quiet"])

        XCTAssertEqual(result.exitCode, CLIExitCode.formatError.rawValue)
        XCTAssertTrue(combinedOutput(result).contains("Failed to parse VCF"))
    }

    func testImportKraken2MalformedReadableReportExitsWithFormatError() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cli-exit-code-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let kreport = tempDir.appendingPathComponent("broken.kreport")
        let outputDir = tempDir.appendingPathComponent("imports", isDirectory: true)
        try "not a kraken2 report\n".write(to: kreport, atomically: true, encoding: .utf8)

        let result = try runCLI(["import", "kraken2", kreport.path, "--output-dir", outputDir.path])

        XCTAssertEqual(result.exitCode, CLIExitCode.formatError.rawValue)
        XCTAssertTrue(combinedOutput(result).contains("Failed to parse"))
    }

    func testImportKraken2NonUTF8ReportDoesNotEmbedExitCodeDiagnostic() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cli-exit-code-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let kreport = tempDir.appendingPathComponent("non-utf8.kreport")
        try Data([0xff, 0xfe, 0xfd]).write(to: kreport)

        let result = try runCLI(["import", "kraken2", kreport.path])
        let output = combinedOutput(result)

        XCTAssertEqual(result.exitCode, CLIExitCode.formatError.rawValue)
        XCTAssertTrue(output.contains("Cannot read kreport file as text"))
        XCTAssertFalse(output.contains("ArgumentParser.ExitCode"))
    }

    func testImportFastqMissingInputExitsWithInputError() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cli-exit-code-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let missingInput = tempDir.appendingPathComponent("missing.fastq")
        let project = tempDir.appendingPathComponent("Project.lungfish", isDirectory: true)

        let result = try runCLI(["import", "fastq", missingInput.path, "--project", project.path])

        XCTAssertEqual(result.exitCode, CLIExitCode.inputError.rawValue)
        XCTAssertTrue(combinedOutput(result).contains("Input not found"))
    }

    func testAssembleInvalidAssemblerExitsWithInputError() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cli-exit-code-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let reads = tempDir.appendingPathComponent("reads.fastq")
        try "@r1\nACGT\n+\nIIII\n".write(to: reads, atomically: true, encoding: .utf8)

        let result = try runCLI(["assemble", reads.path, "--assembler", "not-an-assembler"])

        XCTAssertEqual(result.exitCode, CLIExitCode.inputError.rawValue)
        XCTAssertTrue(combinedOutput(result).contains("Unknown assembler"))
    }

    func testMapInvalidMapperExitsWithInputError() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cli-exit-code-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let reads = tempDir.appendingPathComponent("reads.fastq")
        let reference = tempDir.appendingPathComponent("reference.fasta")
        try "@r1\nACGT\n+\nIIII\n".write(to: reads, atomically: true, encoding: .utf8)
        try ">ref\nACGT\n".write(to: reference, atomically: true, encoding: .utf8)

        let result = try runCLI([
            "map",
            reads.path,
            "--reference", reference.path,
            "--mapper", "not-a-mapper",
        ])

        XCTAssertEqual(result.exitCode, CLIExitCode.inputError.rawValue)
        XCTAssertTrue(combinedOutput(result).contains("Invalid mapper"))
    }

    func testOrientInvalidWordLengthExitsWithInputError() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cli-exit-code-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let reads = tempDir.appendingPathComponent("reads.fastq")
        let reference = tempDir.appendingPathComponent("reference.fasta")
        try "@r1\nACGT\n+\nIIII\n".write(to: reads, atomically: true, encoding: .utf8)
        try ">ref\nACGT\n".write(to: reference, atomically: true, encoding: .utf8)

        let result = try runCLI([
            "orient",
            reads.path,
            "--reference", reference.path,
            "--word-length", "2",
        ])

        XCTAssertEqual(result.exitCode, CLIExitCode.inputError.rawValue)
        XCTAssertTrue(combinedOutput(result).contains("Word length must be between 3 and 15"))
    }

    func testCzIdSummaryMissingInputExitsWithInputError() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cli-exit-code-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let missingInput = tempDir.appendingPathComponent("missing-tax-report.tsv")

        let result = try runCLI(["cz-id", "summary", missingInput.path])

        XCTAssertEqual(result.exitCode, CLIExitCode.inputError.rawValue)
        XCTAssertTrue(combinedOutput(result).contains("Input not found"))
    }

    func testNvdImportMalformedCSVExitsWithFormatError() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cli-exit-code-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let nvdDir = tempDir.appendingPathComponent("nvd-run", isDirectory: true)
        let labkeyDir = nvdDir.appendingPathComponent("05_labkey_bundling", isDirectory: true)
        try FileManager.default.createDirectory(at: labkeyDir, withIntermediateDirectories: true)
        try "not,a,valid,nvd,csv\n".write(
            to: labkeyDir.appendingPathComponent("sample_blast_concatenated.csv"),
            atomically: true,
            encoding: .utf8
        )

        let outputDir = tempDir.appendingPathComponent("imports", isDirectory: true)
        let result = try runCLI([
            "nvd", "import", nvdDir.path,
            "--output-dir", outputDir.path,
            "--quiet",
        ])

        XCTAssertEqual(result.exitCode, CLIExitCode.formatError.rawValue)
        XCTAssertTrue(combinedOutput(result).contains("Missing required columns"))
    }

    func testTaxTriageMissingInputExitsWithInputError() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cli-exit-code-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let missingInput = tempDir.appendingPathComponent("missing.fastq")
        let outputDir = tempDir.appendingPathComponent("taxtriage", isDirectory: true)

        let result = try runCLI([
            "taxtriage", "run",
            "--input", missingInput.path,
            "--sample", "S1",
            "--output", outputDir.path,
            "--quiet",
        ])

        XCTAssertEqual(result.exitCode, CLIExitCode.inputError.rawValue)
        XCTAssertTrue(combinedOutput(result).contains("Input file not found"))
    }

    func testExtractReadsMissingIdsFileExitsWithInputError() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cli-exit-code-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let source = tempDir.appendingPathComponent("reads.fastq")
        try "@r1\nACGT\n+\nIIII\n".write(to: source, atomically: true, encoding: .utf8)
        let missingIds = tempDir.appendingPathComponent("missing-ids.txt")
        let output = tempDir.appendingPathComponent("extracted.fastq")

        let result = try runCLI([
            "extract", "reads",
            "--by-id",
            "--ids", missingIds.path,
            "--source", source.path,
            "--output", output.path,
            "--quiet",
        ])

        XCTAssertEqual(result.exitCode, CLIExitCode.inputError.rawValue)
        XCTAssertTrue(combinedOutput(result).contains("Read ID file not found"))
    }

    func testEsVirituPairedInputCountExitsWithInputError() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cli-exit-code-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let reads = tempDir.appendingPathComponent("reads.fastq")
        try "@r1\nACGT\n+\nIIII\n".write(to: reads, atomically: true, encoding: .utf8)
        let dbDir = tempDir.appendingPathComponent("esviritu-db", isDirectory: true)
        try FileManager.default.createDirectory(at: dbDir, withIntermediateDirectories: true)
        let outputDir = tempDir.appendingPathComponent("esviritu", isDirectory: true)

        let result = try runCLI([
            "esviritu", "detect",
            "--input", reads.path,
            "--paired",
            "--sample", "S1",
            "--db", dbDir.path,
            "--output", outputDir.path,
            "--quiet",
        ])

        XCTAssertEqual(result.exitCode, CLIExitCode.inputError.rawValue)
        XCTAssertTrue(combinedOutput(result).contains("Paired-end mode requires exactly 2 input files"))
    }

    func testNaoMgsImportMissingInputExitsWithInputError() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cli-exit-code-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let missingInput = tempDir.appendingPathComponent("missing-virus_hits_final.tsv.gz")

        let result = try runCLI([
            "nao-mgs", "import", missingInput.path,
            "--quiet",
        ])

        XCTAssertEqual(result.exitCode, CLIExitCode.inputError.rawValue)
        XCTAssertTrue(combinedOutput(result).contains("Input not found"))
    }

    func testArgumentParserErrorsKeepUsageExitCodeAndFormatting() throws {
        let result = try runCLI(["--bad-option"])

        XCTAssertEqual(result.exitCode, 64)
        XCTAssertEqual(result.stdout, "")
        assertSingleErrorLine(in: result.stderr, diagnostic: "Unknown option '--bad-option'")
        XCTAssertTrue(result.stderr.contains("Usage: lungfish"))
    }

    private func runCLI(_ arguments: [String]) throws -> (exitCode: Int32, stdout: String, stderr: String) {
        let binary = try XCTUnwrap(
            cliBinaryURL,
            "CLI binary not built at expected path - run `swift build --product lungfish-cli` before these process tests"
        )

        let process = Process()
        process.executableURL = binary
        process.arguments = arguments

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        try process.run()
        process.waitUntilExit()

        return (
            exitCode: process.terminationStatus,
            stdout: String(data: stdout.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "",
            stderr: String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        )
    }

    private func assertSingleErrorLine(
        in stderr: String,
        diagnostic: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let errorLines = stderr
            .split(separator: "\n", omittingEmptySubsequences: true)
            .filter { $0.hasPrefix("Error:") }
        XCTAssertEqual(errorLines.count, 1, "Expected exactly one rendered Error: line in stderr:\n\(stderr)", file: file, line: line)
        XCTAssertEqual(
            stderr.nonOverlappingOccurrenceCount(of: diagnostic),
            1,
            "Expected diagnostic to be rendered exactly once in stderr:\n\(stderr)",
            file: file,
            line: line
        )
    }

    private func combinedOutput(_ result: (exitCode: Int32, stdout: String, stderr: String)) -> String {
        result.stdout + result.stderr
    }
}

private extension String {
    func nonOverlappingOccurrenceCount(of needle: String) -> Int {
        guard !needle.isEmpty else { return 0 }

        var count = 0
        var searchStart = startIndex
        while let range = range(of: needle, range: searchStart..<endIndex) {
            count += 1
            searchStart = range.upperBound
        }
        return count
    }
}
