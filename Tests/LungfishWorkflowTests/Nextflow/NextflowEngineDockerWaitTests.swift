// NextflowEngineDockerWaitTests.swift - The shared Nextflow engine's one wait for the Docker daemon
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.9 lane S9 M1, panel decision N9 and the inventory's E9. Each case runs the wait on a stub
// probe and a `/bin/sh` stand-in for `open`, so no case starts Docker Desktop.

import Foundation
import LungfishTestSupport
@testable import LungfishWorkflow
import XCTest

final class NextflowEngineDockerWaitTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = try TestTempDirectory.make(prefix: "nextflow-engine-docker")
    }

    override func tearDownWithError() throws {
        TestTempDirectory.cleanup(root)
    }

    func testTheStandardWaitIsTaxTriagesTwoSecondPollForNinetySecondsAfterOpen() {
        XCTAssertEqual(
            NextflowDockerWait.standard,
            NextflowDockerWait(
                pollInterval: .seconds(2),
                timeout: .seconds(90),
                openExecutable: URL(fileURLWithPath: "/usr/bin/open"),
                openArguments: ["-g", "-a", "Docker"]
            )
        )
        XCTAssertEqual(NextflowEngineProcess(configuration: .forTests()).dockerWait, .standard)
    }

    func testTheWaitReturnsAtOnceWhenDockerAnswers() async throws {
        let open = try writeOpen(exitStatus: 0)
        let probe = ScriptedDockerProbe(answers: [true])
        let progress = ProgressMessages()

        try await engine(open: open.executable).waitForDocker(probe: probe, progress: progress.report)

        XCTAssertEqual(probe.daemonQueries, 1)
        XCTAssertEqual(progress.all, [])
        XCTAssertFalse(FileManager.default.fileExists(atPath: open.record.path), "Docker Desktop is not started when the daemon answers")
    }

    func testTheWaitStartsDockerDesktopThenReportsItReadyInTaxTriagesWords() async throws {
        let open = try writeOpen(exitStatus: 0)
        let probe = ScriptedDockerProbe(answers: [false, false, true])
        let progress = ProgressMessages()

        try await engine(open: open.executable).waitForDocker(probe: probe, progress: progress.report)

        XCTAssertEqual(
            progress.all,
            [
                "0.01 Docker daemon unavailable. Launching Docker Desktop...",
                "0.02 Docker daemon ready",
                "0.03 Starting the pipeline...",
            ]
        )
        XCTAssertEqual(try String(contentsOf: open.record, encoding: .utf8), "-g\n-a\nDocker\n", "it asks macOS with open -g -a Docker")
        XCTAssertEqual(probe.daemonQueries, 3, "the first ask, then one per poll until the daemon answers")
    }

    /// Lane U64 M2. Row 24 of the owner's check list names the first line, and the bar never moves back (UX 3),
    /// so each line's fraction is at least the one before it.
    func testTheWaitsFirstLineIsRow24sWordsAndItsFractionsNeverMoveBack() async throws {
        let open = try writeOpen(exitStatus: 0)
        let probe = ScriptedDockerProbe(answers: [false, true])
        let progress = ProgressMessages()

        try await engine(open: open.executable).waitForDocker(probe: probe, progress: progress.report)

        XCTAssertEqual(progress.all.first, "0.01 Docker daemon unavailable. Launching Docker Desktop...")
        let fractions = progress.all.compactMap { $0.split(separator: " ").first.flatMap { Double($0) } }
        XCTAssertEqual(fractions.count, progress.all.count, "every line starts with its fraction")
        XCTAssertEqual(fractions, fractions.sorted(), "the bar never moves back")
        XCTAssertEqual(progress.all.last, "0.03 Starting the pipeline...", "the last line replaces Docker daemon ready as a row's detail")
        XCTAssertLessThan(fractions.last ?? 1, 0.05, "below Generating samplesheet..., the next line of a TaxTriage run")
    }

    func testACancelBeforeOpenEndsTheWaitAndNeverStartsDockerDesktop() async throws {
        let open = try writeOpen(exitStatus: 0)
        let probe = ScriptedDockerProbe(answers: [false])
        let engine = engine(open: open.executable)

        let outcome = await Task {
            try await engine.waitForDocker(probe: probe) { _, _ in
                withUnsafeCurrentTask { $0?.cancel() }
            }
        }.result

        guard case .failure(let error) = outcome else {
            return XCTFail("a cancelled wait must throw")
        }
        XCTAssertTrue(error is CancellationError, "\(error)")
        XCTAssertFalse(FileManager.default.fileExists(atPath: open.record.path), "a cancelled wait never starts Docker Desktop")
        XCTAssertEqual(probe.daemonQueries, 1)
    }

    func testACancelWhileTheWaitPollsEndsItAtOnce() async throws {
        let open = try writeOpen(exitStatus: 0)
        let probe = ScriptedDockerProbe(answers: [false])
        let engine = engine(open: open.executable, pollInterval: .seconds(10), timeout: .seconds(90))

        let waiting = Task { try await engine.waitForDocker(probe: probe, progress: nil) }
        let opened = await waitUntil(timeout: .seconds(30)) { FileManager.default.fileExists(atPath: open.record.path) }
        XCTAssertTrue(opened, "the wait never ran open")
        let clock = ContinuousClock()
        let cancelledAt = clock.now
        waiting.cancel()
        let outcome = await waiting.result
        let waited = clock.now - cancelledAt

        guard case .failure(let error) = outcome else {
            return XCTFail("a cancelled wait must throw")
        }
        XCTAssertTrue(error is CancellationError, "E9, the cancel ends the wait instead of a missing prerequisite, \(error)")
        XCTAssertLessThan(waited, .seconds(5), "the cancel ends the 10 s poll at once")
        XCTAssertLessThanOrEqual(probe.daemonQueries, 2, "a cancelled wait stops asking the daemon")
    }

    func testAFailedOpenFailsTheWaitAtOnce() async throws {
        let open = try writeOpen(exitStatus: 1, stderr: "LSOpenURLsWithRole() failed with error -10814")
        let probe = ScriptedDockerProbe(answers: [false])

        do {
            try await engine(open: open.executable, pollInterval: .seconds(10), timeout: .seconds(90))
                .waitForDocker(probe: probe, progress: nil)
            XCTFail("a failed open must fail the wait")
        } catch let error as NextflowEngineError {
            XCTAssertEqual(error, .dockerDesktopNotStarted(detail: "LSOpenURLsWithRole() failed with error -10814"))
            XCTAssertEqual(error.localizedDescription, NextflowEngineError.dockerUnavailableReason, "UX, the words of a wait that runs out")
        }
        XCTAssertEqual(probe.daemonQueries, 1, "N9, no poll after a failed open")
    }

    func testAWaitThatRunsOutFailsWithTaxTriagesWords() async throws {
        let open = try writeOpen(exitStatus: 0)
        let probe = ScriptedDockerProbe(answers: [false])

        do {
            try await engine(open: open.executable, pollInterval: .milliseconds(10), timeout: .milliseconds(50))
                .waitForDocker(probe: probe, progress: nil)
            XCTFail("a wait that runs out must throw")
        } catch let error as NextflowEngineError {
            XCTAssertEqual(error, .dockerUnavailable)
            XCTAssertEqual(
                error.localizedDescription,
                "Docker Desktop is not running or daemon is unreachable. Start Docker Desktop and retry."
            )
        }
        XCTAssertEqual(probe.daemonQueries, 6, "the first ask and one per poll")
    }

    func testAWorkflowWithoutDockerNeverWaits() async throws {
        let probe = ScriptedDockerProbe(answers: [false])

        try await engine(open: root.appendingPathComponent("no-open"), waitsForDocker: false)
            .waitForDocker(probe: probe, progress: nil)

        XCTAssertEqual(probe.daemonQueries, 0, "a host-only workflow never asks the daemon")
    }

    // MARK: - Helpers

    private func engine(
        open: URL,
        pollInterval: Duration = .milliseconds(20),
        timeout: Duration = .seconds(30),
        waitsForDocker: Bool = true
    ) -> NextflowEngineProcess {
        var engine = NextflowEngineProcess(configuration: .forTests(waitsForDocker: waitsForDocker))
        engine.dockerWait = NextflowDockerWait(pollInterval: pollInterval, timeout: timeout, openExecutable: open)
        return engine
    }

    /// A stand-in for `open` that records its arguments, one per line, and exits with `exitStatus`.
    private func writeOpen(exitStatus: Int32, stderr: String = "") throws -> (executable: URL, record: URL) {
        let executable = root.appendingPathComponent("open")
        let record = root.appendingPathComponent("open-arguments")
        let printsError = stderr.isEmpty ? "" : "echo '\(stderr)' >&2"
        try """
        #!/bin/sh
        printf '%s\\n' "$@" > '\(record.path)'
        \(printsError)
        exit \(exitStatus)
        """.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        return (executable, record)
    }
}
