// LungfishCLIProcessRunnerTests.swift - The FASTQ operations dialog's runner of lungfish-cli, on CLIProcessLauncher
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.10 lane A41 (S3 with D3 of Phase 2.8, decision C11). The dialog's runner launches each
// invocation through `CLIProcessLauncher`. Each case runs the real runner against a shell stand-in
// for `lungfish-cli`, so it pins what the dialog is told, the argv and working directory the CLI
// gets, and what a cancel does to the process. The stand-in ignores the leaf its argv names, so a
// case picks its leaf by what the leaf's row of `CLIEventContractTable` says. Nothing here needs a
// real tool.

import Foundation
import Synchronization
import XCTest
@testable import LungfishApp
import LungfishKit
import LungfishTestSupport
import LungfishWorkflow

final class LungfishCLIProcessRunnerTests: XCTestCase {
    private var scratch: URL!

    override func setUpWithError() throws {
        scratch = try TestTempDirectory.make(prefix: "lungfish-cli-process-runner")
    }

    override func tearDown() {
        TestTempDirectory.cleanup(scratch)
    }

    // MARK: - The channel the leaf's row names

    /// The stand-in prints one progress event on each stream. Only the stream the leaf's row names
    /// carries events, and standard error carries human text otherwise (2.6 S15).
    private static let oneEventOnEachStream = """
        printf '%s\\n' '{"event":"progress","progress":0.5,"message":"on standard output"}'
        printf '%s\\n' '{"event":"progress","progress":0.25,"message":"on standard error"}' >&2
        """

    func testTheDialogIsToldTheEventsOnStandardOutputWhenTheLeafsRowNamesIt() async throws {
        let told = try await toldMessages(of: try leaf(speakingOn: .standardOutput), script: Self.oneEventOnEachStream)
        XCTAssertEqual(told, ["on standard output"])
    }

    func testTheDialogIsToldTheEventsOnStandardErrorWhenTheLeafsRowNamesIt() async throws {
        let told = try await toldMessages(of: try leaf(speakingOn: .standardError), script: Self.oneEventOnEachStream)
        XCTAssertEqual(told, ["on standard error"])
    }

    func testTheDialogIsToldNoEventOfALeafWhoseRowNamesNone() async throws {
        let told = try await toldMessages(of: try leaf(speakingOn: nil), script: Self.oneEventOnEachStream)
        XCTAssertEqual(told, [])
    }

    /// A failed run reports the CLI's own `failed` event, read on the stream the leaf's row names,
    /// in place of the plain text on standard error.
    func testAFailedRunReportsTheFailedEventOnTheStreamTheRowNames() async throws {
        let message = try await failureMessage(of: try leaf(speakingOn: .standardOutput), script: """
            printf '%s\\n' '{"error":"the stand-in failed","event":"failed"}'
            printf '%s\\n' 'Error: plain text on standard error' >&2
            exit 3
            """)
        XCTAssertEqual(message, "lungfish-cli exited with status 3: the stand-in failed")
    }

    /// A leaf whose row names no events keeps the failure summary of the runner before 2.10, the
    /// lines of standard error.
    func testAFailedRunOfALeafWithNoEventsReportsItsStandardError() async throws {
        let message = try await failureMessage(of: try leaf(speakingOn: nil), script: """
            printf '%s\\n' '[ 50%] Subsampling' >&2
            printf '%s\\n' 'Error: bad input' >&2
            exit 1
            """)
        XCTAssertEqual(message, "lungfish-cli exited with status 1: [ 50%] Subsampling\nError: bad input")
    }

    // MARK: - The argv the row spells

    /// The CLI gets the words the row's command spells after `lungfish-cli`, and runs in the plan's
    /// output directory, where `map` writes. A subcommand of two words reaches the CLI as two words,
    /// as the row spells it. The runner before 2.10 passed it as one argument (2.8 D1).
    func testTheCLIGetsTheWordsTheRowSpellsInTheOutputDirectory() async throws {
        let cli = try writeCLI(#"printf '%s\n' "$@" > argv"#)
        let invocations = [
            FASTQCLIInvocation(subcommand: "fastq", arguments: ["reverse-complement", "/tmp/a b.fastq", "-o", "/tmp/out.fastq"]),
            FASTQCLIInvocation(subcommand: "fastq reverse-complement", arguments: ["/tmp/a b.fastq", "-o", "/tmp/out.fastq"]),
        ]
        for invocation in invocations {
            let directory = scratch.appendingPathComponent(UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            _ = try await LungfishCLIProcessRunner(cliURLProvider: { cli }).run(
                invocation: invocation, outputDirectory: directory, progress: { _, _ in }
            )
            let launched = try String(contentsOf: directory.appendingPathComponent("argv"), encoding: .utf8)
                .split(separator: "\n").map(String.init)
            let row = FASTQOperationCLIInvocationBuilder.commandLine(for: invocation)
            XCTAssertEqual(launched, try RecordedCLICommand.arguments(of: row), row)
        }
    }

    // MARK: - Cancel

    /// A cancel of the dialog's task sends the CLI SIGTERM and gives it time to clean up before
    /// SIGKILL. The stand-in takes 0.4 s to write its marker after SIGTERM, as the real CLI takes time
    /// to stop its tools and record the cancel. The runner before 2.10 sent SIGKILL at once.
    func testACancelGivesTheCLITimeToCleanUpBeforeItIsKilled() async throws {
        let ready = scratch.appendingPathComponent("ready")
        let marker = scratch.appendingPathComponent("cleaned")
        let cli = try writeCLI("""
            trap 'trap "" TERM; sleep 0.4; echo cleaned > "\(marker.path)"; exit 125' TERM
            : > "\(ready.path)"
            sleep 30 &
            wait $!
            """)
        let run = startRun(cli, leaf: try leaf(speakingOn: nil))

        await CLISIGTERMHarness.waitForFile(ready)
        run.cancel()
        await assertCancelled(run)

        XCTAssertTrue(
            FileManager.default.fileExists(atPath: marker.path),
            "the CLI got no time between SIGTERM and SIGKILL to clean up"
        )
    }

    /// A CLI that ignores SIGTERM is killed when the 6 s grace runs out, inside the ten seconds
    /// `OperationCenter` waits before it marks a cancelling row cancelled, and the CLI is gone.
    func testACancelKillsACLIThatIgnoresSIGTERMWhenTheGraceRunsOut() async throws {
        let ready = scratch.appendingPathComponent("ready")
        let pidFile = scratch.appendingPathComponent("pid")
        let cli = try writeCLI("""
            trap '' TERM
            echo $$ > "\(pidFile.path)"
            : > "\(ready.path)"
            while :; do sleep 1; done
            """)
        let run = startRun(cli, leaf: try leaf(speakingOn: nil))

        await CLISIGTERMHarness.waitForFile(ready)
        let recordedPID = await CLISIGTERMHarness.waitForProcessID(in: pidFile)
        let pid = try XCTUnwrap(recordedPID)
        let cancelStart = Date()
        run.cancel()
        await assertCancelled(run)
        let elapsed = Date().timeIntervalSince(cancelStart)

        XCTAssertGreaterThanOrEqual(elapsed, 5.5, "the CLI was killed before its 6 s grace ran out")
        XCTAssertLessThan(elapsed, 10, "the CLI outlived the ten seconds OperationCenter waits")
        XCTAssertNotEqual(kill(pid, 0), 0, "the CLI still runs after the run returned")
    }

    /// A cancel of a leaf that keeps SIGTERM's default action, as the dialog's `fastq` leaves do
    /// today, ends the CLI by the signal at once instead of after the 6 s grace, and leaves no
    /// process of its tree. The runner reports a cancel, and nothing claims a `cancelled` record.
    func testACancelOfALeafThatKeepsTheDefaultSIGTERMEndsItAtOnceWithNoProcessLeft() async throws {
        let ready = scratch.appendingPathComponent("ready")
        let pidFile = scratch.appendingPathComponent("pid")
        let cli = try writeCLI("""
            sleep 30 &
            echo $$ > "\(pidFile.path)"
            : > "\(ready.path)"
            wait $!
            """)
        let run = startRun(cli, leaf: try leaf(speakingOn: nil))

        await CLISIGTERMHarness.waitForFile(ready)
        let recordedPID = await CLISIGTERMHarness.waitForProcessID(in: pidFile)
        let tree = CLISIGTERMHarness.processTree(of: try XCTUnwrap(recordedPID))
        XCTAssertGreaterThanOrEqual(tree.count, 2, "the stand-in and its sleep: \(tree)")
        let cancelStart = Date()
        run.cancel()
        await assertCancelled(run)

        XCTAssertLessThan(Date().timeIntervalSince(cancelStart), 4, "the run waited for a grace the CLI does not use")
        await CLISIGTERMHarness.assertNoProcessLeft(tree)
    }

    // MARK: - Output a child kept open

    /// A CLI that exits cleanly while a child it started still holds its output open returns after
    /// the drain grace instead of waiting for the child. The exit code stays the truth about the run,
    /// and the row logs one warning line that says its log may miss the last lines.
    func testACleanExitWhoseOutputAChildKeptOpenReturnsAndLogsAWarning() async throws {
        let cli = try writeCLI("""
            sleep 10 &
            exit 0
            """)
        let logged = Recorded()
        _ = try await LungfishCLIProcessRunner(cliURLProvider: { cli }).run(
            invocation: try invocation(of: try leaf(speakingOn: nil)),
            outputDirectory: scratch,
            logHandler: { level, message in logged.append("\(level.rawValue):\(message)") },
            progress: { _, _ in }
        )

        XCTAssertEqual(logged.lines.count, 1, "logged: \(logged.lines)")
        XCTAssertTrue(
            logged.lines.first?.hasPrefix("warning:The output of lungfish-cli is incomplete") == true,
            "logged: \(logged.lines)"
        )
    }

    // MARK: - Helpers

    /// The words of the first leaf, in path order, whose row prints events on `channel`, or whose
    /// row is `.text` when `channel` is nil.
    private func leaf(speakingOn channel: CLIEventContract.Channel?) throws -> [String] {
        let path = CLIEventContractTable.entries.keys.sorted().first { path in
            switch CLIEventContractTable.entries[path] {
            case .events(_, let rowChannel)?: return rowChannel == channel
            case .text?: return channel == nil
            default: return false
            }
        }
        return try XCTUnwrap(path, "the table has a leaf for \(String(describing: channel))")
            .split(separator: " ").map(String.init)
    }

    private func invocation(of leaf: [String]) throws -> FASTQCLIInvocation {
        let subcommand = try XCTUnwrap(leaf.first)
        return FASTQCLIInvocation(subcommand: subcommand, arguments: Array(leaf.dropFirst()))
    }

    /// The messages the dialog is told by a run of `script` as `leaf`.
    private func toldMessages(of leaf: [String], script: String) async throws -> [String] {
        let cli = try writeCLI(script)
        let told = Recorded()
        _ = try await LungfishCLIProcessRunner(cliURLProvider: { cli }).run(
            invocation: try invocation(of: leaf),
            outputDirectory: scratch,
            progress: { _, message in told.append(message) }
        )
        return told.lines
    }

    /// The error text of a failed run of `script` as `leaf`.
    private func failureMessage(of leaf: [String], script: String) async throws -> String {
        let cli = try writeCLI(script)
        do {
            _ = try await LungfishCLIProcessRunner(cliURLProvider: { cli }).run(
                invocation: try invocation(of: leaf), outputDirectory: scratch, progress: { _, _ in }
            )
        } catch {
            return error.localizedDescription
        }
        XCTFail("a non-zero exit must throw")
        return ""
    }

    private func startRun(_ cli: URL, leaf: [String]) -> Task<FASTQCLIExecutionResult, Error> {
        let directory = scratch!
        let invocation = FASTQCLIInvocation(subcommand: leaf[0], arguments: Array(leaf.dropFirst()))
        return Task {
            try await LungfishCLIProcessRunner(cliURLProvider: { cli }).run(
                invocation: invocation, outputDirectory: directory, progress: { _, _ in }
            )
        }
    }

    private func assertCancelled(
        _ run: Task<FASTQCLIExecutionResult, Error>,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        do {
            _ = try await run.value
            XCTFail("a cancelled run must throw", file: file, line: line)
        } catch LungfishCLIRunner.RunError.cancelled {
        } catch {
            XCTFail("expected RunError.cancelled, got \(error)", file: file, line: line)
        }
    }

    /// A shell script in place of `lungfish-cli` that runs `body`.
    private func writeCLI(_ body: String) throws -> URL {
        let url = scratch.appendingPathComponent("lungfish-cli-\(UUID().uuidString)")
        try ("#!/bin/sh\n" + body + "\n").write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }
}

/// Lines the runner hands a callback, in the order it hands them.
private final class Recorded: Sendable {
    private let storage = Mutex<[String]>([])

    func append(_ line: String) {
        storage.withLock { $0.append(line) }
    }

    var lines: [String] {
        storage.withLock { $0 }
    }
}
