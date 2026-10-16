// JSONAloneOnStandardOutputTests.swift - convert, translate and extract sequence under --format json
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.10 lane A55 (2.6 row 213), milestone M2. Under `--format json` these three leaves write their
// JSON result on standard output and nothing else. A person's text (the progress and success lines) goes
// to standard error, and `translate` and `extract sequence` refuse `--format json` without `-o` with exit
// status 3, so the FASTA always lands in a file the JSON names and a script can hand standard output to a
// JSON parser. The text-mode bytes are pinned apart, in `FASTATextModePinTests`, and do not move.
//
// Standard output is read as a whole by `JSONSerialization`, which refuses a byte before the object and a
// byte after it, so one parse is the whole check that the JSON is alone.
// Since 2.11 (lane A48 M2) `extract sequence` prints CLIEvent lines under `--format json`, as `--bundle` does,
// so its tests decode standard output one line at a time. The refusal without `-o` is A55's and stays.

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

    func testTranslateRefusesFormatJSONWithoutAFile() async throws {
        let command = try TranslateCommand.parse([input.path, "--frame", "1", "--format", "json", "--no-color"])

        var thrown: Error?
        let streams = try await StandardStreamCapture.capture(in: folder) {
            do { try await command.run() } catch { thrown = error }
        }

        let refusal = try XCTUnwrap(thrown as? CLIError, "The command refuses before any work")
        XCTAssertEqual(refusal.exitCode, .inputError)
        XCTAssertTrue((refusal.errorDescription ?? "").contains("-o <file>"))
        XCTAssertEqual(streams.standardOutput, Data(), "Nothing reaches standard output")
        XCTAssertEqual(streams.standardErrorText, "", "The refusal comes before the status line")
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

    private func eventObjects(_ data: Data, file: StaticString = #filePath, line: UInt = #line) throws -> [[String: Any]] {
        try String(decoding: data, as: UTF8.self).split(separator: "\n")
            .map { try jsonObject(Data($0.utf8), file: file, line: line) }
    }

    func testExtractSequenceWithAFileWritesEventLinesAloneOnStandardOutput() async throws {
        let output = folder.appendingPathComponent("region.fa")
        let command = try ExtractSequenceSubcommand.parse([
            input.path, "seqA:1-90", "-o", output.path, "--format", "json", "--no-color",
        ])

        let streams = try await StandardStreamCapture.capture(in: folder) { try await command.run() }

        let events = try eventObjects(streams.standardOutput)
        XCTAssertEqual(events.map { $0["event"] as? String }, ["start", "complete"])
        XCTAssertEqual(events.first?["message"] as? String, "Extracting seqA:1-90 from two.fasta")
        XCTAssertEqual(events.last?["outputs"] as? [String], [output.path])
        XCTAssertEqual(events.last?["message"] as? String, "Extracted 90 bp")
        XCTAssertEqual(
            streams.standardErrorText,
            FASTATextModePinTests.extractingLine + "✓ Extracted 90 bp to \(output.path)\n"
        )
        XCTAssertEqual(try Data(contentsOf: output), Data(FASTATextModePinTests.extractedFASTA.utf8))
    }

    func testExtractSequenceRefusesFormatJSONWithoutAFile() async throws {
        let command = try ExtractSequenceSubcommand.parse([input.path, "seqA:1-90", "--format", "json", "--no-color"])

        var thrown: Error?
        let streams = try await StandardStreamCapture.capture(in: folder) {
            do { try await command.run() } catch { thrown = error }
        }

        let refusal = try XCTUnwrap(thrown as? CLIError, "The command refuses before any work")
        XCTAssertEqual(refusal.exitCode, .inputError)
        XCTAssertTrue((refusal.errorDescription ?? "").contains("-o <file>"))
        XCTAssertEqual(streams.standardOutput, Data(), "Nothing reaches standard output")
        XCTAssertEqual(streams.standardErrorText, "", "The refusal comes before the status line")
    }

    func testExtractSequenceQuietWritesEventLinesAloneAndNoText() async throws {
        let output = folder.appendingPathComponent("region.fa")
        let command = try ExtractSequenceSubcommand.parse([
            input.path, "seqA:1-90", "-o", output.path, "--format", "json", "--quiet",
        ])

        let streams = try await StandardStreamCapture.capture(in: folder) { try await command.run() }

        XCTAssertEqual(try eventObjects(streams.standardOutput).map { $0["event"] as? String }, ["start", "complete"])
        XCTAssertEqual(streams.standardErrorText, "")
    }

    func testExtractSequenceOfAMissingSequenceEndsWithOneFailedLine() async throws {
        let output = folder.appendingPathComponent("region.fa")
        let command = try ExtractSequenceSubcommand.parse([
            input.path, "seqZ:1-10", "-o", output.path, "--format", "json", "--quiet",
        ])
        var thrown: Error?
        let streams = try await StandardStreamCapture.capture(in: folder) {
            do { try await command.run() } catch { thrown = error }
        }

        XCTAssertNotNil(thrown)
        let events = try eventObjects(streams.standardOutput)
        XCTAssertEqual(events.map { $0["event"] as? String }, ["start", "failed"])
        XCTAssertTrue((events.last?["error"] as? String ?? "").contains("seqZ"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
    }

    // MARK: search (a leaf row 213 does not name, found in the A55 review, fix 7)

    func testSearchWithAFileWritesTheJSONAloneOnStandardOutput() async throws {
        let output = folder.appendingPathComponent("sites.bed")
        let command = try SearchCommand.parse([
            input.path, "GGATCC", "-o", output.path, "--format", "json", "--no-color",
        ])

        let streams = try await StandardStreamCapture.capture(in: folder) { try await command.run() }

        let json = try jsonObject(streams.standardOutput)
        let count = try XCTUnwrap(json["matchCount"] as? Int)
        XCTAssertGreaterThan(count, 0)
        XCTAssertEqual(json["sequenceCount"] as? Int, 2)
        XCTAssertEqual(
            streams.standardErrorText,
            "ℹ Searching two.fasta for exact pattern 'GGATCC'...\n"
                + "✓ Found \(count) match(es) across 2 sequence(s), written to \(output.path)\n",
            "The success line goes to standard error, so standard output holds the JSON alone"
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: output.path))
    }
}
