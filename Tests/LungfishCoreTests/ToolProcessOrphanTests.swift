// ToolProcessOrphanTests.swift - Descendants that outlive their root in ToolProcess runs
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import Synchronization
import XCTest
@testable import LungfishCore
import LungfishTestSupport

final class ToolProcessOrphanTests: XCTestCase {
    private typealias Fixtures = ToolProcessFixtures

    /// The wrapper backgrounds a grandchild that keeps writing stdout, then
    /// exits 0. The run must kill the grandchild before it returns and must
    /// not call a run whose output kept changing a success.
    func testOrphanedWriterIsKilledAndTheRunIsNotASuccess() async throws {
        let directory = try makeToolProcessTempDirectory()
        let pidFile = directory.appendingPathComponent("writer.pid")
        let spec = Fixtures.shell(
            "(while true; do echo tick; sleep 0.05; done) & echo $! > \(Fixtures.shellQuote(pidFile.path)); exit 0",
            drainGracePeriod: .milliseconds(300)
        )
        let result = try await ToolProcess.run(spec)
        let writer = try XCTUnwrap(Fixtures.readPID(pidFile))
        defer { Fixtures.killIfAlive(writer) }

        XCTAssertEqual(result.termination, .exited(code: 0))
        XCTAssertFalse(result.isSuccess)
        XCTAssertTrue(result.outputDrainTimedOut)
        XCTAssertNil(result.stop)
        XCTAssertFalse(ProcessTreeTerminator.processExists(pid: writer), "the orphaned writer must be dead when the run returns")
    }

    /// stdout goes straight to a file, so no pipe shows the lingering writer.
    /// The stage's process group does, and the run must wait for it, kill it
    /// when the grace period runs out and report the output incomplete.
    func testOrphanWritingTheStdoutFileIsKilledAndTheRunIsNotASuccess() async throws {
        let directory = try makeToolProcessTempDirectory()
        let pidFile = directory.appendingPathComponent("sleeper.pid")
        let output = directory.appendingPathComponent("out.txt")
        let spec = Fixtures.shell(
            "sleep 30 & echo $! > \(Fixtures.shellQuote(pidFile.path)); echo hi",
            stdout: .file(output),
            drainGracePeriod: .milliseconds(300)
        )
        let clock = ContinuousClock()
        let started = clock.now
        let result = try await ToolProcess.run(spec)
        let sleeper = try XCTUnwrap(Fixtures.readPID(pidFile))
        defer { Fixtures.killIfAlive(sleeper) }

        // Well under the sleeper's 30 s, with room for the parallel unit tier.
        XCTAssertLessThan(started.duration(to: clock.now), .seconds(20))
        XCTAssertFalse(result.isSuccess)
        XCTAssertTrue(result.outputDrainTimedOut)
        XCTAssertEqual(try String(contentsOf: output, encoding: .utf8), "hi\n")
        XCTAssertFalse(ProcessTreeTerminator.processExists(pid: sleeper))
    }

    /// A short-lived background helper that finishes within the grace period
    /// leaves a clean, successful run.
    func testBackgroundHelperThatFinishesInTimeIsASuccess() async throws {
        let directory = try makeToolProcessTempDirectory()
        let output = directory.appendingPathComponent("out.txt")
        let result = try await ToolProcess.run(
            Fixtures.shell("(sleep 0.2; echo late) & echo early", stdout: .file(output), drainGracePeriod: .seconds(5))
        )
        XCTAssertTrue(result.isSuccess)
        XCTAssertFalse(result.outputDrainTimedOut)
        XCTAssertEqual(try String(contentsOf: output, encoding: .utf8), "early\nlate\n")
    }

    func testOnLaunchReceivesThePidBeforeTheRunReturns() async throws {
        final class LaunchLog: Sendable {
            let pids = Mutex<[Int32]>([])
        }
        let log = LaunchLog()
        let result = try await ToolProcess.run(Fixtures.shell("exit 0"), onLaunch: { pid in
            log.pids.withLock { $0.append(pid) }
        })
        XCTAssertEqual(log.pids.withLock { $0 }, [result.pid])
    }

    func testStdoutAndStderrToTheSameFileIsRejected() async throws {
        let directory = try makeToolProcessTempDirectory()
        let output = directory.appendingPathComponent("both.txt")
        do {
            _ = try await ToolProcess.run(Fixtures.shell("echo x", stdout: .file(output), stderr: .file(output)))
            XCTFail("Expected invalidSpec")
        } catch ToolProcessError.invalidSpec {
        } catch {
            XCTFail("Unexpected error \(error)")
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
    }

    /// posix_spawn resets SIGPIPE to its default in the child even when the
    /// app ignores it, so `yes` ends on SIGPIPE when `head` exits, as in a
    /// shell, and the pipeline counts as a success.
    func testYesIntoHeadEndsOnSIGPIPEAndSucceedsWhenTheAppIgnoresSIGPIPE() async throws {
        let previous = signal(SIGPIPE, SIG_IGN)
        defer { signal(SIGPIPE, previous) }
        let result = try await ToolProcess.runPipeline(
            [
                ToolProcessSpec(executableURL: URL(fileURLWithPath: "/usr/bin/yes"), environment: [:], label: "yes"),
                ToolProcessSpec(executableURL: URL(fileURLWithPath: "/usr/bin/head"), arguments: ["-n", "1"], environment: [:], label: "head"),
            ],
            timeout: .seconds(30)
        )
        XCTAssertEqual(result.stages[0].termination, .signaled(signal: SIGPIPE))
        XCTAssertEqual(result.stages[1].termination, .exited(code: 0))
        XCTAssertEqual(result.stages[1].stdoutText, "y\n")
        XCTAssertEqual(result.failedStageIndices, [])
        XCTAssertTrue(result.isSuccess)
    }

    func testAFailingStageStopsTheOthersByDefault() async throws {
        let directory = try makeToolProcessTempDirectory()
        let pidFile = directory.appendingPathComponent("first.pid")
        let clock = ContinuousClock()
        let started = clock.now
        let result = try await ToolProcess.runPipeline(
            [
                Fixtures.shell("echo $$ > \(Fixtures.shellQuote(pidFile.path)); while true; do sleep 1; done", label: "endless"),
                Fixtures.shell("sleep 0.2; echo broken >&2; exit 3", label: "failing"),
            ],
            timeout: .seconds(60)
        )
        // Well under the 60 s timeout, with room for the parallel unit tier.
        XCTAssertLessThan(started.duration(to: clock.now), .seconds(30))
        XCTAssertFalse(result.isSuccess)
        XCTAssertEqual(result.failedStageIndices, [1])
        XCTAssertEqual(result.stages[1].termination, .exited(code: 3))
        XCTAssertEqual(result.stages[0].stop, .pipelineStageFailed(stage: 1))
        if let pid = Fixtures.readPID(pidFile) {
            XCTAssertFalse(ProcessTreeTerminator.processExists(pid: pid))
        }
    }

    func testAStageKilledBySIGPIPEFailsWhenTheStageAfterItFailed() {
        func stage(_ termination: ToolProcessTermination) -> ToolProcessResult {
            ToolProcessResult(
                label: "s", pid: 1, termination: termination, stop: nil, stdout: Data(), stderr: Data(),
                stdoutTruncated: false, stderrTruncated: false, outputDrainTimedOut: false, wallTime: .zero
            )
        }
        let excused = ToolPipelineResult(
            stages: [stage(.signaled(signal: SIGPIPE)), stage(.signaled(signal: SIGPIPE)), stage(.exited(code: 0))],
            wallTime: .zero
        )
        XCTAssertEqual(excused.failedStageIndices, [])
        XCTAssertTrue(excused.isSuccess)
        let blamed = ToolPipelineResult(
            stages: [stage(.signaled(signal: SIGPIPE)), stage(.exited(code: 2))],
            wallTime: .zero
        )
        XCTAssertEqual(blamed.failedStageIndices, [0, 1])
        let last = ToolPipelineResult(stages: [stage(.exited(code: 0)), stage(.signaled(signal: SIGPIPE))], wallTime: .zero)
        XCTAssertEqual(last.failedStageIndices, [1])
    }
}
