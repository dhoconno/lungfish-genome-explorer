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
