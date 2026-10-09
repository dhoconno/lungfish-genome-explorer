// ToolProcessStopTests.swift - Cancellation and timeouts of ToolProcess runs
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import XCTest
@testable import LungfishCore
import LungfishTestSupport

final class ToolProcessStopTests: XCTestCase {
    private typealias Fixtures = ToolProcessFixtures

    // MARK: - Timeouts

    func testWallClockTimeoutTerminatesAndThrowsWithPartialOutput() async throws {
        let clock = ContinuousClock()
        let started = clock.now
        do {
            _ = try await ToolProcess.run(Fixtures.shell("echo begun; sleep 30", timeout: .milliseconds(500)))
            XCTFail("Expected a timeout")
        } catch ToolProcessError.timedOut(let timeout, let results) {
            XCTAssertEqual(timeout, .wallClock(.milliseconds(500)))
            XCTAssertEqual(results.count, 1)
            XCTAssertEqual(results.first?.stdoutText, "begun\n")
            XCTAssertEqual(results.first?.stop, .timedOut(.wallClock(.milliseconds(500))))
            if case .exited(code: 0)? = results.first?.termination {
                XCTFail("A terminated process must not report a clean exit")
            }
        } catch {
            XCTFail("Unexpected error \(error)")
        }
        // Well under the 30 s sleep, with room for the parallel unit tier.
        XCTAssertLessThan(started.duration(to: clock.now), .seconds(20))
    }

    func testIdleTimeoutFiresWhenOutputStops() async throws {
        do {
            _ = try await ToolProcess.run(
                Fixtures.shell("echo begun; sleep 30", timeout: .seconds(60), idleTimeout: .milliseconds(500))
            )
            XCTFail("Expected an idle timeout")
        } catch ToolProcessError.timedOut(let timeout, let results) {
            XCTAssertEqual(timeout, .idle(.milliseconds(500)))
            XCTAssertEqual(results.first?.stdoutText, "begun\n")
        } catch {
            XCTFail("Unexpected error \(error)")
        }
    }

    /// Output every 250 ms keeps a 2 s idle limit from firing during a run
    /// that lasts longer than the limit.
    func testIdleTimeoutIsResetByOutput() async throws {
        let result = try await ToolProcess.run(
            Fixtures.shell(
                "i=0; while [ $i -lt 12 ]; do echo tick >&2; sleep 0.25; i=$((i+1)); done",
                timeout: .seconds(60),
                idleTimeout: .seconds(2)
            )
        )
        XCTAssertTrue(result.isSuccess)
        XCTAssertEqual(result.stderrText.split(separator: "\n").count, 12)
    }

    // MARK: - Cancellation

    /// The root runs a grandchild that ignores SIGTERM, SIGHUP and SIGINT.
    /// Cancelling the calling task must remove both, as
    /// ProcessTreeTerminatorTests' shared harness requires of every runner.
    func testCancellationTerminatesTheWholeTreeIncludingATermIgnoringGrandchild() async throws {
        let directory = try makeToolProcessTempDirectory()
        let rootPIDFile = directory.appendingPathComponent("root.pid")
        let grandchildPIDFile = directory.appendingPathComponent("grandchild.pid")
        let script = """
        echo $$ > \(Fixtures.shellQuote(rootPIDFile.path))
        /bin/sh -c 'trap "" TERM HUP INT; echo $$ > \(grandchildPIDFile.path.replacingOccurrences(of: "'", with: "")); while true; do sleep 1; done' &
        while true; do sleep 1; done
        """
        let spec = Fixtures.shell(script)
        let task = Task { try await ToolProcess.run(spec) }

        let rootPID = await Fixtures.waitForPID(rootPIDFile)
        let grandchildPID = await Fixtures.waitForPID(grandchildPIDFile)
        defer {
            Fixtures.killIfAlive(rootPID)
            Fixtures.killIfAlive(grandchildPID)
        }
        let root = try XCTUnwrap(rootPID)
        let grandchild = try XCTUnwrap(grandchildPID)
        XCTAssertTrue(ProcessTreeTerminator.processExists(pid: grandchild))

        task.cancel()
        let outcome = await task.result

        switch outcome {
        case .success:
            XCTFail("A cancelled run must throw")
        case .failure(ToolProcessError.cancelled(let results)):
            XCTAssertEqual(results.count, 1)
            XCTAssertEqual(results.first?.stop, .cancelled)
            XCTAssertEqual(results.first?.pid, root)
        case .failure(let error):
            XCTFail("Unexpected error \(error)")
        }
        let rootExited = await Fixtures.waitForExit(root)
        let grandchildExited = await Fixtures.waitForExit(grandchild)
        XCTAssertTrue(rootExited, "the root must not survive cancellation")
        XCTAssertTrue(grandchildExited, "a SIGTERM-ignoring grandchild must not survive cancellation")
    }

    func testCancellationBeforeLaunchLaunchesNothing() async throws {
        let directory = try makeToolProcessTempDirectory()
        let marker = directory.appendingPathComponent("ran")
        let spec = Fixtures.shell("touch \(Fixtures.shellQuote(marker.path))")
        let task = Task { () async throws -> ToolProcessResult in
            withUnsafeCurrentTask { $0?.cancel() }
            return try await ToolProcess.run(spec)
        }
        switch await task.result {
        case .failure(ToolProcessError.cancelled(let results)):
            XCTAssertTrue(results.isEmpty)
        default:
            XCTFail("Expected cancelled with no results")
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
    }

    /// The root exits cleanly and only a lingering grandchild's pipe is left.
    /// Cancelling ends the wait at once instead of after the drain grace
    /// period, kills the grandchild and marks the stage stopped.
    func testCancellationAfterACleanExitStopsTheLingeringWriterPromptly() async throws {
        let directory = try makeToolProcessTempDirectory()
        let sleeperPIDFile = directory.appendingPathComponent("sleeper.pid")
        let events = ToolProcessEventLog()
        let spec = Fixtures.shell(
            "sleep 30 & echo $! > \(Fixtures.shellQuote(sleeperPIDFile.path)); echo done",
            drainGracePeriod: .seconds(60)
        )
        let task = Task { try await ToolProcess.run(spec) { events.append($0) } }
        defer { Fixtures.killIfAlive(Fixtures.readPID(sleeperPIDFile)) }

        let printed = await waitUntil(timeout: .seconds(30)) {
            events.lines(.stdout) == ["done"]
        }
        XCTAssertTrue(printed)
        let sleeperPID = await Fixtures.waitForPID(sleeperPIDFile)
        let sleeper = try XCTUnwrap(sleeperPID)
        // The root stays a zombie until the run reaps it, so wait for the
        // exit the run itself observes.
        guard case .started(let rootPID, _)? = events.all.first?.event else {
            return XCTFail("The first event must be started")
        }
        let exited = await waitUntil(timeout: .seconds(30)) {
            if case .exited = ToolProcessSpawner.peekExit(rootPID) { return true }
            return false
        }
        XCTAssertTrue(exited)

        let clock = ContinuousClock()
        let cancelledAt = clock.now
        task.cancel()
        switch await task.result {
        case .failure(ToolProcessError.cancelled(let results)):
            XCTAssertEqual(results.first?.termination, .exited(code: 0))
            XCTAssertEqual(results.first?.stop, .cancelled)
            XCTAssertEqual(results.first?.stdoutText, "done\n")
            XCTAssertEqual(results.first?.outputDrainTimedOut, true)
        default:
            XCTFail("Expected cancelled")
        }
        // Well under the sleeper's 30 s, with room for the parallel unit tier.
        XCTAssertLessThan(cancelledAt.duration(to: clock.now), .seconds(20))
        XCTAssertFalse(ProcessTreeTerminator.processExists(pid: sleeper))
    }
}
