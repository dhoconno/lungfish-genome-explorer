// ConvertEmptyInputTests.swift - convert refuses an input of no bytes or only white space
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.13 lane 13.41 M2 (row M838 CONVERT-EMPTY-INPUT, UX words, QA red first, MD26 reading A). Each
// input is checked alone before any is read. One of no bytes or only white space stops the conversion with
// `No sequences found in <file>.`, the words of the app's own `No sequences found in selected files.`, and
// nothing is published: no output, no record beside it and no hidden `.convert.` stage entry. At the base a
// `.fa` of that kind converted to an empty output that reported 0 sequences, and a `.seq` failed format detection.

import XCTest
import LungfishTestSupport
@testable import LungfishCLI
@testable import LungfishCore
@testable import LungfishWorkflow

final class ConvertEmptyInputTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ConvertEmptyInputTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    func testASeqFileOfNoBytesIsRefused() async throws {
        try await assertSingleInputRefused(name: "empty.seq", text: "")
    }

    func testASeqFileOfOnlyWhiteSpaceIsRefused() async throws {
        try await assertSingleInputRefused(name: "blank.seq", text: " \n\t\n \n")
    }

    func testAFASTAFileOfNoBytesIsRefused() async throws {
        try await assertSingleInputRefused(name: "empty.fa", text: "")
    }

    func testAFASTAFileOfOnlyWhiteSpaceIsRefused() async throws {
        try await assertSingleInputRefused(name: "blank.fa", text: "\n  \r\n\t")
    }

    func testTheFirstEmptyInputOfSeveralStopsTheConversion() async throws {
        let first = root.appendingPathComponent("first.fa")
        try ">a\nACGT\n".write(to: first, atomically: true, encoding: .utf8)
        let empty = root.appendingPathComponent("second.fa")
        try Data().write(to: empty)
        let blank = root.appendingPathComponent("third.fa")
        try "   \n".write(to: blank, atomically: true, encoding: .utf8)
        let output = root.appendingPathComponent("joined.fa")
        let command = try ConvertCommand.parse([first.path, empty.path, blank.path, "--to", output.path, "--quiet"])
        try await assertRefused(command, naming: "second.fa", output: output)
    }

    /// Writes `text` to `name` and checks that converting it alone is refused.
    private func assertSingleInputRefused(
        name: String,
        text: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        let input = root.appendingPathComponent(name)
        try Data(text.utf8).write(to: input)
        let output = root.appendingPathComponent("\(name).out.fa")
        let command = try ConvertCommand.parse([input.path, "--to", output.path, "--quiet"])
        try await assertRefused(command, naming: name, output: output, file: file, line: line)
    }

    /// Runs `command` and checks that it fails with the refusal naming `name` and publishes nothing.
    private func assertRefused(
        _ command: ConvertCommand,
        naming name: String,
        output: URL,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        do {
            try await command.run()
            XCTFail("\(name) must be refused", file: file, line: line)
        } catch let error as CLIError {
            guard case .conversionFailed(let reason) = error else {
                return XCTFail("\(name): expected conversionFailed, got \(error)", file: file, line: line)
            }
            XCTAssertEqual(reason, "No sequences found in \(name).", file: file, line: line)
            XCTAssertEqual(error.exitCode, .failure, "a non-zero exit", file: file, line: line)
            XCTAssertEqual(error.errorDescription, "Conversion failed: No sequences found in \(name).", file: file, line: line)
        } catch {
            XCTFail("\(name): expected a CLIError, got \(error)", file: file, line: line)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path), "\(name) publishes no output", file: file, line: line)
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: ProvenanceRecorder.fileSidecarURL(for: output).path),
            "\(name) writes no record", file: file, line: line
        )
        let stages = try FileManager.default.contentsOfDirectory(atPath: root.path)
            .filter { $0.hasPrefix(".") && $0.contains(".convert.") }
        XCTAssertEqual(stages, [], "\(name) leaves no stage entry", file: file, line: line)
    }
}
