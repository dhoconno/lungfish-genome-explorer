// CLIFailedRowWordsTests.swift - a failed command's `failed` event holds the refusal's own words
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.11 lane A69 (carry-in row SW11). ArgumentParser's `ValidationError` has no localized text,
// so a command that put `error.localizedDescription` in its `failed` event showed the system's "The
// operation couldn't be completed" in the Operations row, and the app alerts with the event's text.
// Each test throws a refusal from the place its command catches errors and reads the `failed` line the
// command wrote. A site that no input can reach with a `ValidationError` today (its do block calls
// only Workflow and IO services) is pinned by the transcripts under `Tests/Fixtures/cli-events`.

import ArgumentParser
import Foundation
import XCTest
import LungfishTestSupport
@testable import LungfishCLI
@testable import LungfishWorkflow

final class CLIFailedRowWordsTests: XCTestCase {
    /// A refusal's words, such as the ones a command's own checks write.
    private static let refusal = "Give at least two sequences to align."

    private var root: URL!

    override func setUpWithError() throws {
        root = try TestTempDirectory.make(prefix: "cli-failed-row-words")
    }

    override func tearDownWithError() throws {
        TestTempDirectory.cleanup(root)
    }

    // MARK: - Sites that took `error.localizedDescription` (fail at the base)

    /// `align mafft` ends its stream in `AlignCommand.swift`'s catch, with the runtime's error.
    func testAlignMAFFTFailedEventCarriesARefusalsOwnWords() async throws {
        let command = try AlignCommand.MAFFTSubcommand.parse([
            "mafft", root.appendingPathComponent("input.fasta").path,
            "--project", root.appendingPathComponent("Project.lungfish").path,
            "--format", "json",
        ])
        let runtime = AlignCommand.MAFFTSubcommand.Runtime(runMAFFT: { _, _ in
            throw ValidationError(Self.refusal)
        })
        let recorder = LineRecorder()
        do {
            _ = try await command.executeForTesting(runtime: runtime) { recorder.append($0) }
            XCTFail("a refused alignment must end the run")
        } catch let error as ValidationError {
            XCTAssertEqual(error.message, Self.refusal)
        }
        XCTAssertEqual(try Self.failedMessage(in: recorder.lines()), Self.refusal)
    }

    /// `demo fetch` ends a failed install with `DemoFetchReporter.finish`.
    func testDemoFetchFailedEventCarriesARefusalsOwnWords() async throws {
        let scratch = try ImportStreamCapture.Scratch()
        defer { scratch.remove() }
        let reporter = DemoFetchReporter(id: "demo", eventsOn: true, quiet: false, interactive: false)

        let output = try await ImportStreamCapture.capture(in: scratch) {
            try reporter.finish(.failed(ValidationError(Self.refusal)))
        }

        XCTAssertEqual(try Self.failedMessage(in: output.standardOutput), Self.refusal)
        XCTAssertNotNil(output.thrown, "a failed fetch exits with the failure status")
    }

    // MARK: - Sites that unwrapped a `ValidationError` by hand (the words are kept)

    /// `fastq import-ont` throws a usage error from inside the run, after the stream began.
    func testFastqImportONTFailedEventCarriesAUsageErrorsOwnWords() async throws {
        let command = try FastqImportONTSubcommand.parse([
            root.path, "--output", root.appendingPathComponent("out").path,
            "--concurrency", "0", "--format", "json",
        ])
        let recorder = LineRecorder()
        do {
            try await command.execute(emit: { recorder.append($0) })
            XCTFail("a concurrency of 0 must end the run")
        } catch let error as ValidationError {
            XCTAssertEqual(error.message, "Concurrency must be at least 1 (got 0)")
        }
        XCTAssertEqual(try Self.failedMessage(in: recorder.lines()), "Concurrency must be at least 1 (got 0)")
    }

    /// `variants delete` checks its bundle inside the run, so a folder that is no bundle is refused
    /// after the stream began.
    func testVariantsDeleteFailedEventCarriesTheRefusalOfAMissingBundle() async throws {
        let missing = root.appendingPathComponent("no-such.lungfishref", isDirectory: true)
        let command = try VariantsCommand.DeleteSubcommand.parse([missing.path, "--all", "--format", "json"])
        let recorder = LineRecorder()
        do {
            try await command.execute(emit: { recorder.append($0) })
            XCTFail("a missing bundle must refuse the deletion")
        } catch is ValidationError {
        }
        let message = try Self.failedMessage(in: recorder.lines())
        XCTAssertTrue(message.hasPrefix("No reference bundle at "), message)
        XCTAssertTrue(message.hasSuffix("no-such.lungfishref. Pass a .lungfishref folder."), message)
    }

    // MARK: - Helpers

    /// The `error` text of the last `failed` event among the lines.
    private static func failedMessage(in lines: [String]) throws -> String {
        let events = try lines.filter { $0.hasPrefix("{") }.map {
            try XCTUnwrap(try JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any], $0)
        }
        let failed = try XCTUnwrap(events.last { $0["event"] as? String == "failed" }, "no failed event in \(lines)")
        return try XCTUnwrap(failed["error"] as? String, "\(failed)")
    }

    private final class LineRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: [String] = []

        func append(_ line: String) {
            lock.lock()
            defer { lock.unlock() }
            stored.append(line)
        }

        func lines() -> [String] {
            lock.lock()
            defer { lock.unlock() }
            return stored
        }
    }
}
