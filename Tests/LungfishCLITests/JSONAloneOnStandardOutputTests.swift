// JSONAloneOnStandardOutputTests.swift - convert, translate and extract sequence under --format json
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.10 lane A55 (2.6 row 213), milestone M2. Under `--format json` these three leaves write their
// JSON result on standard output and nothing else. A person's text (the progress and success lines) goes
// to standard error, and the FASTA that `translate` and `extract sequence` would print without `-o` goes
// to standard error as well, so a script can hand standard output to a JSON parser. The text-mode bytes
// are pinned apart, in `FASTATextModePinTests`, and do not move.
//
// Standard output is read as a whole by `JSONSerialization`, which refuses a byte before the object and a
// byte after it, so one parse is the whole check that the JSON is alone.

import Foundation
import XCTest
@testable import LungfishCLI
import LungfishTestSupport

final class JSONAloneOnStandardOutputTests: XCTestCase {
    private var folder: URL!
    private var input: URL!

    override func setUpWithError() throws {
        folder = try TestTempDirectory.make(prefix: "json-alone-stdout")
        let captured = folder!
        addTeardownBlock { TestTempDirectory.cleanup(captured) }
        input = folder.appendingPathComponent("two.fasta")
        try Data(FASTATextModePinTests.inputFASTA.utf8).write(to: input)
    }

    private func jsonObject(_ data: Data, file: StaticString = #filePath, line: UInt = #line) throws -> [String: Any] {
        let object = try JSONSerialization.jsonObject(with: data)
        return try XCTUnwrap(object as? [String: Any], "Standard output holds one JSON object", file: file, line: line)
    }

    // MARK: convert

    func testConvertWritesTheJSONAloneOnStandardOutput() async throws {
        let output = folder.appendingPathComponent("copy.fa")
        let command = try ConvertCommand.parse([input.path, "--to", output.path, "--format", "json", "--no-color"])

        let streams = try await StandardStreamCapture.capture(in: folder) { try await command.run() }

        let json = try jsonObject(streams.standardOutput)
        XCTAssertEqual(json["sequenceCount"] as? Int, 2)
        XCTAssertEqual(json["outputFile"] as? String, output.path)
        XCTAssertEqual(
            streams.standardErrorText,
            "ℹ Converting two.fasta to FASTA...\n✓ Converted 2 sequence(s) to copy.fa\n",
            "The two text lines of text mode go to standard error"
        )
        XCTAssertEqual(try Data(contentsOf: output), Data(FASTATextModePinTests.convertedFASTA.utf8))
    }

    func testConvertQuietWritesTheJSONAloneAndNoText() async throws {
        let output = folder.appendingPathComponent("copy.fa")
        let command = try ConvertCommand.parse([input.path, "--to", output.path, "--format", "json", "--quiet"])

        let streams = try await StandardStreamCapture.capture(in: folder) { try await command.run() }

        XCTAssertEqual(try jsonObject(streams.standardOutput)["sequenceCount"] as? Int, 2)
        XCTAssertEqual(streams.standardErrorText, "")
    }

    // MARK: translate

    func testTranslateWithAFileWritesTheJSONAloneOnStandardOutput() async throws {
        let output = folder.appendingPathComponent("protein.fa")
        let command = try TranslateCommand.parse([
            input.path, "--frame", "1", "-o", output.path, "--format", "json", "--no-color",
        ])

        let streams = try await StandardStreamCapture.capture(in: folder) { try await command.run() }

        let json = try jsonObject(streams.standardOutput)
        XCTAssertEqual(json["translationCount"] as? Int, 2)
        XCTAssertEqual(json["outputFile"] as? String, output.path)
        XCTAssertEqual(
            streams.standardErrorText,
            FASTATextModePinTests.translatingLine + "✓ Wrote 2 translation(s) from 2 sequence(s) to \(output.path)\n"
        )
        XCTAssertEqual(try Data(contentsOf: output), Data(FASTATextModePinTests.translatedFASTA.utf8))
    }

    func testTranslateWithoutAFileKeepsTheFASTAOffStandardOutput() async throws {
        let command = try TranslateCommand.parse([input.path, "--frame", "1", "--format", "json", "--no-color"])

        let streams = try await StandardStreamCapture.capture(in: folder) { try await command.run() }

        let json = try jsonObject(streams.standardOutput)
        XCTAssertEqual(json["translationCount"] as? Int, 2)
        XCTAssertNil(json["outputFile"], "No file was asked for")
        XCTAssertEqual(
            streams.standardErrorText,
            FASTATextModePinTests.translatingLine + FASTATextModePinTests.translatedFASTA,
            "The FASTA reaches standard error with the same bytes, and nothing of it is lost"
        )
    }

    func testTranslateQuietWritesTheJSONAloneAndNoText() async throws {
        let output = folder.appendingPathComponent("protein.fa")
        let command = try TranslateCommand.parse([
            input.path, "--frame", "1", "-o", output.path, "--format", "json", "--quiet",
        ])

        let streams = try await StandardStreamCapture.capture(in: folder) { try await command.run() }

        XCTAssertEqual(try jsonObject(streams.standardOutput)["translationCount"] as? Int, 2)
        XCTAssertEqual(streams.standardErrorText, "")
    }

    // MARK: extract sequence

    func testExtractSequenceWithAFileWritesTheJSONAloneOnStandardOutput() async throws {
        let output = folder.appendingPathComponent("region.fa")
        let command = try ExtractSequenceSubcommand.parse([
            input.path, "seqA:1-90", "-o", output.path, "--format", "json", "--no-color",
        ])

        let streams = try await StandardStreamCapture.capture(in: folder) { try await command.run() }

        let json = try jsonObject(streams.standardOutput)
        XCTAssertEqual(json["length"] as? Int, 90)
        XCTAssertEqual(json["outputFile"] as? String, output.path)
        XCTAssertEqual(
            streams.standardErrorText,
            FASTATextModePinTests.extractingLine + "✓ Extracted 90 bp to \(output.path)\n"
        )
        XCTAssertEqual(try Data(contentsOf: output), Data(FASTATextModePinTests.extractedFASTA.utf8))
    }

    func testExtractSequenceWithoutAFileKeepsTheFASTAOffStandardOutput() async throws {
        let command = try ExtractSequenceSubcommand.parse([input.path, "seqA:1-90", "--format", "json", "--no-color"])

        let streams = try await StandardStreamCapture.capture(in: folder) { try await command.run() }

        let json = try jsonObject(streams.standardOutput)
        XCTAssertEqual(json["length"] as? Int, 90)
        XCTAssertNil(json["outputFile"], "No file was asked for")
        XCTAssertEqual(
            streams.standardErrorText,
            FASTATextModePinTests.extractingLine + FASTATextModePinTests.extractedFASTA,
            "The FASTA reaches standard error with the same bytes, and nothing of it is lost"
        )
    }

    func testExtractSequenceQuietWritesTheJSONAloneAndNoText() async throws {
        let output = folder.appendingPathComponent("region.fa")
        let command = try ExtractSequenceSubcommand.parse([
            input.path, "seqA:1-90", "-o", output.path, "--format", "json", "--quiet",
        ])

        let streams = try await StandardStreamCapture.capture(in: folder) { try await command.run() }

        XCTAssertEqual(try jsonObject(streams.standardOutput)["length"] as? Int, 90)
        XCTAssertEqual(streams.standardErrorText, "")
    }
}
