// IlluminaAmpliconPairMergerRunProcessPinTests.swift - The bbmerge spawn of the Illumina amplicon pair merger
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import XCTest
@testable import LungfishWorkflow

/// `IlluminaAmpliconPairMerger.runProcess` runs bbmerge with stdout discarded and stderr written to a file the
/// merger creates, and returns the status and the stderr text (Phase 2.13 lane 13.10 M3 item 2). These pins add
/// to `IlluminaAmpliconPairMergerProcessWaitTests`. They hold at the base, where the spawn was a raw `Process`,
/// and after it runs on `ToolProcess`.
final class IlluminaAmpliconPairMergerRunProcessPinTests: XCTestCase {
    private var root: URL!
    private var stderrURL: URL { root.appendingPathComponent("stderr.log") }

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("lge-merger-pin-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func run(
        _ script: String, arguments: [String] = [], environment: [String: String]? = nil
    ) async throws -> (status: Int32, stderr: String) {
        try await IlluminaAmpliconPairMerger.runProcess(
            executableURL: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", script, "sh"] + arguments,
            stderrURL: stderrURL,
            environment: environment
        )
    }

    func testStdoutIsDiscardedAndStderrIsTheOnlyTextReturned() async throws {
        let result = try await run("echo out; echo err >&2")
        XCTAssertEqual(result.status, 0)
        XCTAssertEqual(result.stderr, "err\n")
        XCTAssertEqual(try String(contentsOf: stderrURL, encoding: .utf8), "err\n")
    }

    func testThreeHundredKilobytesOnStdoutNeverBlockTheChild() async throws {
        let result = try await run("head -c 300000 /dev/zero | tr '\\000' 'o'")
        XCTAssertEqual(result.status, 0)
        XCTAssertEqual(result.stderr, "")
    }

    func testThreeHundredKilobytesOnStderrAreKeptWholeInTheTextAndTheFile() async throws {
        let result = try await run("head -c 300000 /dev/zero | tr '\\000' 'e' >&2")
        XCTAssertEqual(result.status, 0)
        XCTAssertEqual(result.stderr, String(repeating: "e", count: 300_000))
        let size = try FileManager.default.attributesOfItem(atPath: stderrURL.path)[.size] as? Int
        XCTAssertEqual(size, 300_000)
    }

    func testAKillBySignalGivesTheSignalNumberAsTheStatus() async throws {
        let result = try await run("printf 'cut off' >&2; kill -KILL $$")
        XCTAssertEqual(result.status, 9)
        XCTAssertEqual(result.stderr, "cut off")
    }

    func testAStaleStderrFileIsReplacedNotAppendedTo() async throws {
        try Data("stale text from an earlier run\n".utf8).write(to: stderrURL)
        let result = try await run("printf 'new' >&2")
        XCTAssertEqual(result.stderr, "new")
        XCTAssertEqual(try String(contentsOf: stderrURL, encoding: .utf8), "new")
    }

    func testAGivenEnvironmentIsTheWholeEnvironmentAndNilInheritsTheCallers() async throws {
        let given = try await run(
            #"printf 'FOO=%s HOME=%s' "$FOO" "${HOME-unset}" >&2"#, environment: ["FOO": "bar"]
        )
        XCTAssertEqual(given.stderr, "FOO=bar HOME=unset")
        let inherited = try await run(#"printf '%s' "${HOME-unset}" >&2"#)
        XCTAssertEqual(inherited.stderr, ProcessInfo.processInfo.environment["HOME"] ?? "unset")
    }

    func testTheArgumentsReachTheChildInOrderWithoutShellSplitting() async throws {
        let result = try await run(#"printf '%s|' "$@" >&2"#, arguments: ["a b", "c", "--x=1 2"])
        XCTAssertEqual(result.stderr, "a b|c|--x=1 2|")
    }
}
