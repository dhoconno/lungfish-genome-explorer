// IlluminaAmpliconPairMergerRunProcessPinTests.swift - The bbmerge spawn of the Illumina amplicon pair merger
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import XCTest
@testable import LungfishWorkflow

/// `IlluminaAmpliconPairMerger.runProcess` runs bbmerge with stdout discarded and stderr written to a file the
/// merger creates, and returns the status and the stderr text (Phase 2.13 lane 13.10 M3 item 2). These pins add
/// to `IlluminaAmpliconPairMergerProcessWaitTests`. They hold at the base, where the spawn was a raw `Process`,
/// and after it runs on `ToolProcess`. The last pin, a task cancel, is the one new behavior of the move and is
/// red at the base, where a cancel left bbmerge running to its end.
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

    /// A task cancel stops the tool and the process it started, and `runProcess` throws `CancellationError`.
    /// This is new with the move to ToolProcess (review 13.10 SWIFT Fix 1). The stand-in writes its own pid and
    /// the pid of a `sleep 120` it leaves running, so the test can see that both are gone. If a process is still
    /// alive after the wait, the test kills it, so a red run at the base ends in seconds and not after 120 s.
    func testACancelStopsTheToolAndItsChildAndThrowsCancellationError() async throws {
        let toolPIDFile = root.appendingPathComponent("tool.pid")
        let childPIDFile = root.appendingPathComponent("child.pid")
        let script = """
        printf '%s' "$$" > '\(toolPIDFile.path)'
        sleep 120 &
        printf '%s' "$!" > '\(childPIDFile.path)'
        wait
        """
        let log = stderrURL
        let task = Task {
            try await IlluminaAmpliconPairMerger.runProcess(
                executableURL: URL(fileURLWithPath: "/bin/sh"),
                arguments: ["-c", script, "sh"],
                stderrURL: log
            )
        }
        var toolPID: Int32?
        var childPID: Int32?
        for _ in 0..<1500 where toolPID == nil || childPID == nil {
            toolPID = toolPID ?? Self.pid(in: toolPIDFile)
            childPID = childPID ?? Self.pid(in: childPIDFile)
            if toolPID == nil || childPID == nil { try await Task.sleep(nanoseconds: 20_000_000) }
        }
        guard let tool = toolPID, let child = childPID else {
            task.cancel()
            XCTFail("the stand-in tool never wrote its pid files")
            return
        }
        task.cancel()
        let toolGone = await Self.waitUntilGone(tool)
        let childGone = await Self.waitUntilGone(child)
        if !toolGone { _ = Darwin.kill(tool, SIGKILL) }
        if !childGone { _ = Darwin.kill(child, SIGKILL) }
        let outcome = await task.result
        XCTAssertTrue(toolGone, "the tool \(tool) still runs after the cancel")
        XCTAssertTrue(childGone, "the tool's child \(child) still runs after the cancel")
        switch outcome {
        case .success:
            XCTFail("a cancelled runProcess finished and did not throw")
        case .failure(let error):
            XCTAssertTrue(error is CancellationError, "a cancel threw \(error) and not CancellationError")
        }
    }

    private static func pid(in file: URL) -> Int32? {
        guard let text = try? String(contentsOf: file, encoding: .utf8) else { return nil }
        return Int32(text.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// Polls for up to 5 seconds until `kill(pid, 0)` says the process no longer exists.
    private static func waitUntilGone(_ pid: Int32) async -> Bool {
        for _ in 0..<250 {
            if Darwin.kill(pid, 0) == -1 && errno == ESRCH { return true }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return false
    }
}
