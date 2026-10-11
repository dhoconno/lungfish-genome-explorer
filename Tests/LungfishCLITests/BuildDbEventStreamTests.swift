// BuildDbEventStreamTests.swift - The three build-db leaves under --format json
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import ArgumentParser
import XCTest
import LungfishWorkflow
@testable import LungfishCLI

/// The three `build-db` leaves under `--format json`, after lane A7 of Phase 2.7 retired their private
/// progress shape S14 (`docs/formats/cli-events.md`). Standard output holds version 2 event lines only, the
/// human text that text mode prints on standard output goes to standard error line for line, and the run
/// ends with one `complete` line that names the database file. `CLIEventTranscriptCoverageTests` pins the
/// lines themselves.
final class BuildDbEventStreamTests: XCTestCase {
    private typealias Fixture = (ImportStreamCapture.Scratch) throws -> URL

    func testStandardOutputHoldsEventsAndTheHumanTextMovesToStandardError() async throws {
        let leaves: [(leaf: String, database: String, fixture: Fixture)] = [
            ("build-db kraken2", "kraken2.sqlite", BuildDbStreamCapture.kraken2Result),
            ("build-db esviritu", "esviritu.sqlite", BuildDbStreamCapture.esVirituResultWithoutBAMs),
            ("build-db taxtriage", "taxtriage.sqlite", BuildDbStreamCapture.taxTriageResultWithoutBAMs),
        ]
        for (leaf, database, fixture) in leaves {
            let textScratch = try ImportStreamCapture.Scratch()
            defer { textScratch.remove() }
            let text = try await BuildDbStreamCapture.run(leaf, try fixture(textScratch), in: textScratch)
            let jsonScratch = try ImportStreamCapture.Scratch()
            defer { jsonScratch.remove() }
            let result = try fixture(jsonScratch)
            let json = try await BuildDbStreamCapture.run(leaf, result, ["--format", "json"], in: jsonScratch)

            XCTAssertNil(json.thrown, leaf)
            XCTAssertEqual(
                BuildDbStreamCapture.withoutFreedSize(json.standardError),
                BuildDbStreamCapture.withoutFreedSize(text.standardOutput),
                "\(leaf) prints the text of text mode on standard error"
            )
            let events = try decodedEvents(json.standardOutput, leaf: leaf)
            guard case .start? = events.first else {
                XCTFail("\(leaf) does not start with start")
                continue
            }
            let progress = events.compactMap { event -> Double? in
                if case let .progress(fraction, _) = event { return fraction }
                return nil
            }
            XCTAssertFalse(progress.isEmpty, "\(leaf) reports the steps of its database writer")
            XCTAssertTrue(progress.allSatisfy { (0...1).contains($0) }, leaf)
            guard case let .complete(outputs, message)? = events.last else {
                XCTFail("\(leaf) does not complete")
                continue
            }
            XCTAssertEqual(outputs, ["/work/\(result.lastPathComponent)/\(database)"], leaf)
            XCTAssertEqual(message, text.standardOutput.first { $0.hasPrefix("Built database at ") }, leaf)
            XCTAssertTrue(FileManager.default.fileExists(atPath: jsonScratch.resolved(outputs[0]).path), leaf)
        }
    }

    func testAnExistingDatabaseCompletesWithThatDatabase() async throws {
        let scratch = try ImportStreamCapture.Scratch()
        defer { scratch.remove() }
        let result = try BuildDbStreamCapture.kraken2Result(in: scratch)
        _ = try await BuildDbStreamCapture.run("build-db kraken2", result, ["--quiet"], in: scratch)

        let json = try await BuildDbStreamCapture.run("build-db kraken2", result, ["--format", "json"], in: scratch)

        let line = "Database already exists at /work/kraken2/kraken2.sqlite. Use --force to rebuild."
        XCTAssertEqual(json.standardError, [line])
        let events = try decodedEvents(json.standardOutput, leaf: "build-db kraken2")
        XCTAssertEqual(events.count, 2)
        XCTAssertEqual(events.last, .complete(outputs: ["/work/kraken2/kraken2.sqlite"], message: line))
    }

    func testAFailedRunEndsWithItsMessageAndStillThrows() async throws {
        let scratch = try ImportStreamCapture.Scratch()
        defer { scratch.remove() }
        let result = try BuildDbStreamCapture.kraken2Result(in: scratch)
        let noReport = result.appendingPathComponent("no-report", isDirectory: true)
        try FileManager.default.createDirectory(at: noReport, withIntermediateDirectories: true)

        let json = try await BuildDbStreamCapture.run(
            "build-db kraken2", result, ["--sample-dir", noReport.path, "--format", "json"], in: scratch
        )

        XCTAssertTrue(json.thrown is ValidationError, "The command still ends with its error")
        let events = try decodedEvents(json.standardOutput, leaf: "build-db kraken2")
        XCTAssertEqual(
            events.last,
            .failed(message: "Missing classification.kreport in --sample-dir /work/kraken2/no-report", detail: nil)
        )
    }

    /// Every line of standard output as a version 2 event, failing on a line that a reader would skip.
    private func decodedEvents(_ lines: [String], leaf: String) throws -> [CLIEvent] {
        let decoder = CLIEventLineDecoder()
        return try lines.map { line in
            XCTAssertTrue(line.hasPrefix("{"), "\(leaf) prints text that a reader skips: \(line)")
            let envelope = try XCTUnwrap(try decoder.decodeLine(line), "\(leaf): \(line)")
            XCTAssertEqual(envelope.schemaVersion, CLIEventLine.currentSchemaVersion, line)
            return try XCTUnwrap(envelope.event, "\(leaf) prints an event that a reader ignores: \(line)")
        }
    }
}
