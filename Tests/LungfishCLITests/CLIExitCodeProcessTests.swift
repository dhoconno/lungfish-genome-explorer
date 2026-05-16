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

        let candidates = [
            repoRoot.appendingPathComponent(".build/debug/lungfish-cli"),
            repoRoot.appendingPathComponent(".build/arm64-apple-macosx/debug/lungfish-cli"),
            repoRoot.appendingPathComponent(".build/x86_64-apple-macosx/debug/lungfish-cli"),
        ]
        return candidates.first { FileManager.default.fileExists(atPath: $0.path) }
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
