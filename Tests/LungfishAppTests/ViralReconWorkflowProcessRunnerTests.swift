// ViralReconWorkflowProcessRunnerTests.swift - The runner behind the Viral Recon and Local Workflow routes
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.9 lane S16 (decision N14, fact ruling F8). The Viral Recon route and the Local Workflow route
// both start `lungfish-cli workflow run` through `ProcessViralReconWorkflowProcessRunner`. These cases run
// the real runner against a shell stand-in for the CLI, so they pin what a user's Cancel does to the
// process and what the runner hands back. Nothing here needs Nextflow or Docker.

import Foundation
import Synchronization
import XCTest
@testable import LungfishApp
import LungfishKit
import LungfishTestSupport
import LungfishWorkflow

/// Records whether each stand-in CLI lookup ran on the main thread. A plain class outside the test
/// case, so the `@Sendable` lookup closure can call it from any thread.
private final class LookupThreadRecorder: Sendable {
    private let calls = Mutex<[Bool]>([])

    func record(isMainThread: Bool) {
        calls.withLock { $0.append(isMainThread) }
    }

    var recorded: [Bool] {
        calls.withLock { $0 }
    }
}

@MainActor
final class ViralReconWorkflowProcessRunnerTests: XCTestCase {
    private var scratch: URL!

    override func setUp() async throws {
        try await super.setUp()
        scratch = try TestTempDirectory.make(prefix: "viral-recon-process-runner")
    }

    override func tearDown() async throws {
        TestTempDirectory.cleanup(scratch)
        try await super.tearDown()
    }

    // MARK: - Locating the CLI

    /// With no executable the runner asks `CLIBinaryLocator`, whose SwiftPM probe runs
    /// `swift build --show-bin-path` and can wait on the build lock another build holds (the 2.12
    /// verify run waited 884 s on it, R6 of M879). The runner is main-actor isolated, so a lookup made
    /// in its own body blocks the main thread. The lookup has to leave the main actor (Phase 2.13
    /// lane 13.11). A lookup that finds no CLI ends the run before any launch.
    func testTheCLILookupLeavesTheMainThread() async throws {
        let lookup = LookupThreadRecorder()
        let runner = ProcessViralReconWorkflowProcessRunner(cliLocator: {
            lookup.record(isMainThread: Thread.isMainThread)
            return nil
        })

        do {
            _ = try await runner.runLungfishCLI(
                arguments: [],
                workingDirectory: scratch,
                outputHandler: nil
            )
            XCTFail("a lookup that finds no CLI must throw")
        } catch LungfishCLIRunner.RunError.cliNotFound {
            // The run ends before any launch.
        }

        XCTAssertEqual(lookup.recorded, [false], "the lookup must run once, and not on the main thread")
    }

    // MARK: - Cancel

    /// A cancel sends the CLI SIGTERM and gives it time to clean up before SIGKILL. The stand-in takes
    /// 0.4 s to write its marker after SIGTERM, as the real CLI takes time to stop Nextflow and record
    /// its run as cancelled. A cancel that follows SIGTERM with SIGKILL at once, as the runner did with
    /// a grace of 0, leaves no marker.
    func testACancelGivesTheCLITimeToCleanUpBeforeItIsKilled() async throws {
        let ready = scratch.appendingPathComponent("ready")
        let marker = scratch.appendingPathComponent("cleaned")
        let cli = try writeCLI(
            """
            trap 'trap "" TERM; sleep 0.4; echo cleaned > "$2"; exit 125' TERM
            : > "$1"
            sleep 30 &
            wait $!
            """
        )
        let runner = ProcessViralReconWorkflowProcessRunner(executableURL: cli)
        let directory = scratch!
        let run = Task {
            try await runner.runLungfishCLI(
                arguments: [ready.path, marker.path],
                workingDirectory: directory,
                outputHandler: nil
            )
        }

        try await waitForFile(ready)
        let cancelStart = Date()
        runner.cancel()
        XCTAssertLessThan(Date().timeIntervalSince(cancelStart), 2, "cancel() only asks for the stop and never waits")
        let result = try await run.value

        XCTAssertTrue(
            FileManager.default.fileExists(atPath: marker.path),
            "the CLI got no time between SIGTERM and SIGKILL to clean up"
        )
        XCTAssertEqual(result.exitCode, 125, "the CLI's own exit code after its cleanup")
    }

    /// A CLI that ignores SIGTERM is killed when the 6 s grace runs out, so the run ends inside the
    /// ten seconds OperationCenter waits before it forces a cancelling row to read Cancelled, and the
    /// CLI is gone. The CLI itself ignores the signal, so the run cannot end early through the drain
    /// path, which stops a child that holds the output once the root has exited. Only the SIGKILL ends it.
    func testACancelKillsACLIThatIgnoresSIGTERMWhenTheGraceRunsOut() async throws {
        let ready = scratch.appendingPathComponent("ready")
        let pidFile = scratch.appendingPathComponent("pid")
        let cli = try writeCLI(
            """
            trap '' TERM
            echo $$ > "$2"
            : > "$1"
            while :; do sleep 1; done
            """
        )
        let runner = ProcessViralReconWorkflowProcessRunner(executableURL: cli)
        let directory = scratch!
        let run = Task {
            try await runner.runLungfishCLI(
                arguments: [ready.path, pidFile.path], workingDirectory: directory, outputHandler: nil
            )
        }
        try await waitForFile(ready)
        let pid = try XCTUnwrap(Int32(String(contentsOf: pidFile, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)))
        let cancelStart = Date()
        runner.cancel()
        _ = try await run.value
        let elapsed = Date().timeIntervalSince(cancelStart)

        XCTAssertGreaterThanOrEqual(elapsed, 5.5, "the CLI was killed before its 6 s grace ran out")
        XCTAssertLessThan(elapsed, 10, "the CLI outlived the ten seconds OperationCenter waits")
        XCTAssertNotEqual(kill(pid, 0), 0, "the CLI still runs after the run returned")
    }

    /// A cancel that comes before the launch starts no process. The run reports the cancelled exit code,
    /// and the route reads the row's state to see that the user cancelled.
    func testACancelBeforeTheLaunchStartsNoProcess() async throws {
        let ran = scratch.appendingPathComponent("ran")
        let cli = try writeCLI(": > \"$1\"")
        let runner = ProcessViralReconWorkflowProcessRunner(executableURL: cli)

        runner.cancel()
        let result = try await runner.runLungfishCLI(arguments: [ran.path], workingDirectory: scratch, outputHandler: nil)

        XCTAssertEqual(result.exitCode, AnalysisRunExitCode.cancelled)
        XCTAssertEqual(result.standardOutput, "")
        XCTAssertEqual(result.standardError, "")
        XCTAssertFalse(FileManager.default.fileExists(atPath: ran.path), "nothing may run after a cancel")
    }

    // MARK: - Result

    /// The CLI runs in the working directory, which the runner creates, with the arguments it is given.
    /// Its exit code and both streams come back whole when they fit, and with no handler nothing counts
    /// as streamed.
    func testTheRunnerReturnsTheExitCodeAndBothStreamsOfACLIRunInTheWorkingDirectory() async throws {
        let cli = try writeCLI(
            """
            : > here
            echo "args: $*"
            echo oops >&2
            exit 3
            """
        )
        let work = scratch.appendingPathComponent("work", isDirectory: true)
        let runner = ProcessViralReconWorkflowProcessRunner(executableURL: cli)

        let result = try await runner.runLungfishCLI(
            arguments: ["workflow", "run"],
            workingDirectory: work,
            outputHandler: nil
        )

        XCTAssertEqual(result.exitCode, 3)
        XCTAssertEqual(result.standardOutput, "args: workflow run\n")
        XCTAssertEqual(result.standardError, "oops\n")
        XCTAssertFalse(result.didStreamOutput)
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: work.appendingPathComponent("here").path),
            "the CLI did not run in the working directory"
        )
    }

    /// Every line reaches the handler, but the result keeps only the last bytes of each stream, so a run
    /// that logs for hours holds a bounded amount. A cut stream starts with a line that says so and then
    /// a whole line, never the fragment the cut left.
    func testTheResultKeepsTheLastBytesOfEachStreamWhileEveryLineIsStreamed() async throws {
        let cli = try writeCLI(
            """
            i=1
            while [ $i -le 300 ]; do
              echo "out line $i"
              echo "err line $i" >&2
              i=$((i + 1))
            done
            """
        )
        let limit = 1000
        let runner = ProcessViralReconWorkflowProcessRunner(executableURL: cli, outputTailLimit: limit)
        let streamed = StreamedLines()

        let result = try await runner.runLungfishCLI(
            arguments: [],
            workingDirectory: scratch,
            outputHandler: { streamed.lines.append($0) }
        )

        XCTAssertEqual(result.exitCode, 0)
        XCTAssertTrue(result.didStreamOutput)
        let expectedOut = (1...300).map { ViralReconWorkflowProcessOutput.standardOutput("out line \($0)") }
        let expectedErr = (1...300).map { ViralReconWorkflowProcessOutput.standardError("err line \($0)") }
        XCTAssertEqual(streamed.lines.filter { $0.isStandardOutput }, expectedOut, "stdout reaches the handler whole and in order")
        XCTAssertEqual(streamed.lines.filter { !$0.isStandardOutput }, expectedErr, "stderr reaches the handler whole and in order")

        let marker = "[Earlier output was left out. Only the last \(limit) bytes were kept.]\n"
        for (text, name) in [(result.standardOutput, "out"), (result.standardError, "err")] {
            XCTAssertTrue(text.hasPrefix(marker), "the \(name) stream does not say it was cut: \(text.prefix(80))")
            XCTAssertLessThan(text.utf8.count, limit + marker.utf8.count, "the \(name) stream is not bounded")
            XCTAssertTrue(text.hasSuffix("\(name) line 300\n"), "the \(name) stream lost its last line")
            XCTAssertTrue(
                text.dropFirst(marker.count).hasPrefix("\(name) line "),
                "the \(name) stream starts with a fragment: \(text.dropFirst(marker.count).prefix(40))"
            )
            XCTAssertFalse(text.contains("\(name) line 1\n"), "the \(name) stream kept its first line")
        }
    }

    /// A CLI that exits cleanly while a child it started still holds the output open was cut short
    /// by the drain grace. The exit code stays the truth about the run. The reason joins standard error,
    /// so the row logs it as a warning line and the user sees that the text may miss its last lines.
    func testACleanExitWhoseOutputAChildKeptOpenKeepsItsExitCodeAndGainsAWarningLine() async throws {
        let cli = try writeCLI(
            """
            echo finished
            sleep 30 &
            exit 0
            """
        )
        let runner = ProcessViralReconWorkflowProcessRunner(executableURL: cli)

        let result = try await runner.runLungfishCLI(arguments: [], workingDirectory: scratch, outputHandler: nil)

        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(result.standardOutput, "finished\n")
        XCTAssertTrue(
            result.standardError.contains("The output of lungfish-cli is incomplete"),
            "standard error was: \(result.standardError)"
        )
        XCTAssertTrue(result.standardError.hasSuffix("\n"))
    }

    /// The Viral Recon route logs the result's text only when no line streamed, so a run that printed a
    /// line never shows the reason that sits in the result. The reason therefore streams too, as the
    /// last line, and the row logs it as a warning line after everything the CLI printed.
    func testACleanExitWhoseOutputAChildKeptOpenStreamsTheReasonAsTheLastLine() async throws {
        let cli = try writeCLI(
            """
            echo finished
            sleep 30 &
            exit 0
            """
        )
        let runner = ProcessViralReconWorkflowProcessRunner(executableURL: cli)
        let streamed = StreamedLines()

        let result = try await runner.runLungfishCLI(
            arguments: [],
            workingDirectory: scratch,
            outputHandler: { streamed.lines.append($0) }
        )

        XCTAssertEqual(result.exitCode, 0)
        XCTAssertTrue(result.didStreamOutput)
        XCTAssertEqual(streamed.lines.first, .standardOutput("finished"))
        guard case .standardError(let reason)? = streamed.lines.last else {
            return XCTFail("the last streamed line was not a standard error line: \(String(describing: streamed.lines.last))")
        }
        XCTAssertTrue(
            reason.hasPrefix("The output of lungfish-cli is incomplete"),
            "the last streamed line was: \(reason)"
        )
    }

    // MARK: - Helpers

    /// A shell script named `lungfish-cli` that runs `body`. Its arguments are the case's `$1`, `$2` and so on.
    private func writeCLI(_ body: String) throws -> URL {
        let url = scratch.appendingPathComponent("lungfish-cli-\(UUID().uuidString)")
        try ("#!/bin/sh\n" + body + "\n").write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }

    private func waitForFile(_ url: URL, timeout: TimeInterval = 30) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if FileManager.default.fileExists(atPath: url.path) { return }
            try await Task.sleep(nanoseconds: 25_000_000)
        }
        XCTFail("Timed out waiting for \(url.path)")
    }
}

/// The lines a run hands its handler, in order. The handler runs on the main actor, so this does too.
@MainActor
private final class StreamedLines {
    var lines: [ViralReconWorkflowProcessOutput] = []
}

private extension ViralReconWorkflowProcessOutput {
    var isStandardOutput: Bool {
        if case .standardOutput = self { return true }
        return false
    }
}
