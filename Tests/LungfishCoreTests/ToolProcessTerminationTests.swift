// ToolProcessTerminationTests.swift - Latency, threads and settlement of ToolProcess terminations
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Darwin
import Foundation
import Synchronization
import XCTest
@testable import LungfishCore
import LungfishTestSupport

/// Phase 2.2 lane 6A (R7). A cancellation ends as soon as the process group
/// and tree are gone, parks no thread while it waits, and counts a killed
/// group as settled only once it is really empty.
final class ToolProcessTerminationTests: XCTestCase {
    private typealias Fixtures = ToolProcessFixtures

    private func sleeper(_ seconds: Int, grace: Duration, ignoringTERM: Bool = false) -> ToolProcessSpec {
        var spec = Fixtures.shell(ignoringTERM ? "trap '' TERM; exec sleep \(seconds)" : "exec sleep \(seconds)")
        spec.terminationGracePeriod = grace
        return spec
    }

    /// A process that honours SIGTERM is gone within milliseconds, so the
    /// cancelled run returns long before the 30 second grace runs out. The
    /// long grace keeps the bound clear of the parallel unit tier's load.
    func testCancellingARunThatHonoursSIGTERMReturnsWellBeforeTheGrace() async throws {
        let run = try ToolProcess.start(sleeper(60, grace: .seconds(30)))
        let pid = try XCTUnwrap(run.pid)
        defer { Fixtures.killIfAlive(pid) }
        let running = await waitUntil(timeout: .seconds(30)) { ToolProcessTreeProbe.isRunning(pid) }
        XCTAssertTrue(running)

        let clock = ContinuousClock()
        let cancelledAt = clock.now
        run.cancel()
        do {
            _ = try await run.result()
            XCTFail("Expected a cancellation")
        } catch .cancelled(let results) {
            XCTAssertEqual(results.first?.termination, .signaled(signal: SIGTERM))
        }
        let elapsed = cancelledAt.duration(to: clock.now)
        XCTAssertLessThan(elapsed, .seconds(10), "the run must end once the group is gone, not after the 30 s grace")
    }

    /// Fifty runs that ignore SIGTERM are cancelled together and wait out a
    /// 2 second grace. The waits share one timer, so the process gains no
    /// thread per cancellation.
    func testFiftyConcurrentCancellationsDoNotParkAThreadEach() async throws {
        let count = 50
        var runs: [ToolProcessRun] = []
        for _ in 0..<count {
            runs.append(try ToolProcess.start(sleeper(60, grace: .seconds(2), ignoringTERM: true)))
        }
        let pids = runs.compactMap(\.pid)
        defer { pids.forEach(Fixtures.killIfAlive) }
        XCTAssertEqual(pids.count, count)
        let allRunning = await waitUntil(timeout: .seconds(30)) { pids.allSatisfy(ToolProcessTreeProbe.isRunning) }
        XCTAssertTrue(allRunning)
        try await Task.sleep(for: .milliseconds(300))
        let baseline = try XCTUnwrap(Self.threadCount())

        runs.forEach { $0.cancel() }
        var peak = baseline
        let clock = ContinuousClock()
        let sampleUntil = clock.now.advanced(by: .milliseconds(1500))
        while clock.now < sampleUntil {
            peak = max(peak, Self.threadCount() ?? peak)
            try await Task.sleep(for: .milliseconds(50))
        }
        for run in runs {
            do {
                _ = try await run.result()
                XCTFail("Expected a cancellation")
            } catch .cancelled {}
        }
        XCTAssertLessThan(peak - baseline, 20, "\(count) cancellations grew the thread count from \(baseline) to \(peak)")
        for pid in pids {
            XCTAssertFalse(ToolProcessTreeProbe.isRunning(pid), "a TERM-ignoring process must still be killed at the deadline")
        }
    }

    /// Leftovers that ignore SIGTERM hold stdout open after the root exits.
    /// When the run returns they must already be gone, not merely signalled.
    func testKilledLeftoversAreGoneWhenTheRunReturns() async throws {
        let spec = Fixtures.shell(
            "for i in 1 2 3 4 5 6 7 8 9 10 11 12; do (trap '' TERM; exec sleep 60) & done; echo done",
            drainGracePeriod: .milliseconds(200)
        )
        let result = try await ToolProcess.run(spec)
        let survivors = ToolProcessSpawner.liveGroupMembers(result.pid)
        defer { survivors.forEach { kill($0, SIGKILL) } }
        XCTAssertTrue(result.outputDrainTimedOut)
        XCTAssertEqual(survivors, [], "every leftover of the group must be dead before the run returns")
        XCTAssertFalse(NativeProcessRegistry.shared.isRegistered(processGroupLeader: result.pid))
    }

    /// The live thread count of this process.
    static func threadCount() -> Int? {
        var info = proc_taskinfo()
        let size = Int32(MemoryLayout<proc_taskinfo>.size)
        let read = withUnsafeMutablePointer(to: &info) { proc_pidinfo(getpid(), PROC_PIDTASKINFO, 0, $0, size) }
        return read == size ? Int(info.pti_threadnum) : nil
    }
}
