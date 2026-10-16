// ToolProcessSignalsProcessFirstTests.swift - A cancel that signals the process first leaves its cleanup tool alone
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.11 U30 walk, finding W2. The app cancels `lungfish-cli taxtriage run` through ToolProcess, whose
// termination sent SIGTERM to the CLI's group and to every descendant, also each one that started in the
// grace. The CLI stops Nextflow and then runs `docker ps` to find the run's containers, and that `docker ps`
// got SIGTERM and exited 143 (`docker ps exited 143: no output. No container was stopped.` in the walk's
// unified log), so three containers stayed. With `signalsProcessFirst` the process alone gets SIGTERM and a
// tool its SIGTERM handler starts runs to its end, while a process that ignores SIGTERM still ends at the
// grace by SIGKILL.

import Foundation
import XCTest
@testable import LungfishCore

final class ToolProcessSignalsProcessFirstTests: XCTestCase {
    private var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("SignalsProcessFirst-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let folder { try? FileManager.default.removeItem(at: folder) }
    }

    /// The SIGTERM handler's cleanup tool, a `sleep` started after the cancel, runs to its end and
    /// the handler then writes its marker.
    func testCancelLetsTheProcessRunACleanupToolStartedOnSIGTERM() async throws {
        let cleaned = folder.appendingPathComponent("cleaned")
        let outcome = try await cancelOnceReady(
            trap: "/bin/sleep 0.5 && /usr/bin/touch \"$1\"; exit 0",
            processFirst: true,
            grace: .seconds(10),
            marker: cleaned
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: cleaned.path), "the cleanup tool was signalled, \(outcome)")
        XCTAssertLessThan(outcome.elapsed, .seconds(5), "the run waited past its process's own end")
    }

    /// The default termination signals the cleanup tool too, which is how the walk's cancel lost it.
    func testDefaultCancelSignalsACleanupToolStartedOnSIGTERM() async throws {
        let cleaned = folder.appendingPathComponent("cleaned")
        let outcome = try await cancelOnceReady(
            trap: "/bin/sleep 3 && /usr/bin/touch \"$1\"; exit 0",
            processFirst: false,
            grace: .seconds(10),
            marker: cleaned
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: cleaned.path), "the cleanup tool ran to its end, \(outcome)")
    }

    /// A process that ignores SIGTERM still ends at the grace, with its tree.
    func testProcessThatIgnoresSIGTERMEndsAtTheGrace() async throws {
        let outcome = try await cancelOnceReady(
            trap: "",
            processFirst: true,
            grace: .milliseconds(500),
            marker: folder.appendingPathComponent("unused")
        )
        XCTAssertLessThan(outcome.elapsed, .seconds(10), "SIGKILL did not end the run at the grace")
        XCTAssertGreaterThanOrEqual(outcome.elapsed, .milliseconds(400), "the shell ignores SIGTERM, so only the SIGKILL at the 500 ms grace ends it")
    }

    /// Runs `/bin/sh` with `trap` as its SIGTERM action, cancels the run once the shell is ready and
    /// returns how long the run took from the cancel.
    private func cancelOnceReady(
        trap: String,
        processFirst: Bool,
        grace: Duration,
        marker: URL
    ) async throws -> (elapsed: Duration, result: String) {
        let ready = folder.appendingPathComponent("ready-\(UUID().uuidString)")
        let script = "trap '\(trap)' TERM; /usr/bin/touch \"$2\"; while :; do /bin/sleep 0.05; done"
        var spec = ToolProcessSpec(
            executableURL: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", script, "sh", marker.path, ready.path],
            environment: ["PATH": "/usr/bin:/bin"],
            terminationGracePeriod: grace,
            label: "signals-process-first"
        )
        spec.signalsProcessFirst = processFirst
        let launched = spec
        let run = Task { try await ToolProcess.run(launched) }
        let deadline = ContinuousClock.now.advanced(by: .seconds(30))
        while !FileManager.default.fileExists(atPath: ready.path), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: ready.path), "the shell never started")
        let cancelledAt = ContinuousClock.now
        run.cancel()
        let result: String
        do {
            result = String(describing: try await run.value.termination)
        } catch {
            result = String(describing: error)
        }
        return (ContinuousClock.now - cancelledAt, result)
    }
}
