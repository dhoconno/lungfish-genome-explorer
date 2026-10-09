// ToolProcessBlockingTests.swift - runBlocking, its cancellation, and runs while the cooperative pool is saturated
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import Synchronization
import XCTest
@testable import LungfishCore
import LungfishTestSupport

final class ToolProcessBlockingTests: XCTestCase {
    private typealias Fixtures = ToolProcessFixtures

    func testRunBlockingCapturesBothStreamsPastThePipeBuffer() throws {
        let result = try ToolProcess.runBlocking(
            Fixtures.shell("head -c 300000 /dev/zero | tr '\\000' o; head -c 300000 /dev/zero | tr '\\000' e >&2; exit 4")
        )
        XCTAssertEqual(result.termination, .exited(code: 4))
        XCTAssertEqual(result.stdout, Data(repeating: UInt8(ascii: "o"), count: 300_000))
        XCTAssertEqual(result.stderr, Data(repeating: UInt8(ascii: "e"), count: 300_000))
        XCTAssertTrue(result.outputComplete)
    }

    func testCancellationFromAnotherThreadStopsABlockingRunAndItsTree() throws {
        let directory = try makeToolProcessTempDirectory()
        let pidFile = directory.appendingPathComponent("sleeper.pid")
        let cancellation = ToolProcessCancellation()
        DispatchQueue(label: "canceller").async {
            if ToolProcessStreamTests.waitForPID(pidFile) != nil {
                cancellation.cancel()
            }
        }
        let clock = ContinuousClock()
        let started = clock.now
        do {
            _ = try ToolProcess.runBlocking(
                Fixtures.shell("echo begun; sleep 30 & echo $! > \(Fixtures.shellQuote(pidFile.path)); wait"),
                cancellation: cancellation
            )
            XCTFail("Expected a cancellation")
        } catch .cancelled(let results) {
            XCTAssertEqual(results.first?.stdoutText, "begun\n")
            XCTAssertEqual(results.first?.stop, .cancelled)
        }
        // Well under the sleeper's 30 s, with room for the parallel unit tier.
        XCTAssertLessThan(started.duration(to: clock.now), .seconds(20))
        let sleeper = try XCTUnwrap(Fixtures.readPID(pidFile))
        defer { Fixtures.killIfAlive(sleeper) }
        XCTAssertFalse(ProcessTreeTerminator.processExists(pid: sleeper))
        XCTAssertTrue(cancellation.isCancelled)
    }

    func testAnAlreadyCancelledRunLaunchesNothing() throws {
        let cancellation = ToolProcessCancellation()
        cancellation.cancel()
        let launched = ToolProcessTestBox(false)
        do {
            _ = try ToolProcess.runBlocking(
                Fixtures.shell("echo never"),
                cancellation: cancellation,
                onLaunch: { _ in launched.withLock { $0 = true } }
            )
            XCTFail("Expected a cancellation")
        } catch .cancelled(let results) {
            XCTAssertTrue(results.isEmpty)
        }
        XCTAssertFalse(launched.withLock { $0 })
    }

    /// The deadlock this API exists to prevent.
    ///
    /// Every thread of the Swift cooperative pool is parked on a semaphore,
    /// as a synchronous reader called from a task would park it. The bridge
    /// the IO readers and the VCF helper used before, a semaphore waiting on
    /// a detached Task that runs ToolProcess, then never finishes, because
    /// the Task never gets a thread. runBlocking and a started stream need
    /// no task, so 64 of them, on 64 GCD threads at once, all finish while
    /// the pool stays saturated. Releasing the pool then lets the old bridge
    /// finish too, which shows it was starved, not broken.
    func testRunBlockingFinishesFromSixtyFourThreadsWhileTheCooperativePoolIsSaturated() throws {
        let width = ProcessInfo.processInfo.activeProcessorCount
        let blockerCount = 2 * width
        let pool = CooperativePoolBlocker()
        for _ in 0..<blockerCount {
            Task.detached { pool.block() }
        }
        var released = false
        defer {
            if !released { pool.release(blockerCount) }
        }
        let deadline = Date().addingTimeInterval(20)
        while pool.entered < width, Date() < deadline {
            usleep(10_000)
        }
        usleep(300_000)
        let parked = pool.entered
        XCTAssertGreaterThanOrEqual(parked, width, "every cooperative thread should be parked")
        XCTAssertLessThan(parked, blockerCount, "some blockers must still be queued, which proves the pool is full")

        // The old bridge, kept here only as the control.
        let oldBridgeDone = DispatchSemaphore(value: 0)
        DispatchQueue(label: "old-bridge").async {
            let outcome = ToolProcessTestBox(false)
            let finished = DispatchSemaphore(value: 0)
            Task.detached {
                let result = try? await ToolProcess.run(Fixtures.shell("printf old"))
                outcome.withLock { $0 = result?.stdoutText == "old" }
                finished.signal()
            }
            finished.wait()
            if outcome.withLock({ $0 }) { oldBridgeDone.signal() }
        }
        XCTAssertEqual(
            oldBridgeDone.wait(timeout: .now() + 3), .timedOut,
            "the Task-based bridge must not finish while the cooperative pool is saturated"
        )

        let directory = try makeToolProcessTempDirectory()
        let runCount = 64
        let succeeded = ToolProcessTestBox(0)
        let failures = ToolProcessTestBox<[String]>([])
        let group = DispatchGroup()
        let clock = ContinuousClock()
        let started = clock.now
        for index in 0..<runCount {
            group.enter()
            DispatchQueue(label: "blocking-caller-\(index)").async {
                defer { group.leave() }
                let expected = "run \(index)"
                do {
                    let text: String
                    switch index % 4 {
                    case 0, 1:
                        let result = try ToolProcess.runBlocking(Fixtures.shell("sleep 1; printf '\(expected)'"))
                        guard result.isSuccess else { throw Failure.notSuccessful }
                        text = result.stdoutText
                    case 2:
                        let file = directory.appendingPathComponent("out-\(index).txt")
                        let result = try ToolProcess.runBlocking(
                            Fixtures.shell("sleep 1; printf '\(expected)'", stdout: .file(file))
                        )
                        guard result.isSuccess else { throw Failure.notSuccessful }
                        text = try String(contentsOf: file, encoding: .utf8)
                    default:
                        let run = try ToolProcess.start(Fixtures.shell("sleep 1; printf '\(expected)'", stdout: .stream))
                        let bytes = ToolProcessStreamTests.readToEnd(run.stdout)
                        guard try run.waitBlocking().isSuccess else { throw Failure.notSuccessful }
                        text = String(decoding: bytes, as: UTF8.self)
                    }
                    if text == expected {
                        succeeded.withLock { $0 += 1 }
                    } else {
                        failures.withLock { $0.append("\(index): \(text)") }
                    }
                } catch {
                    failures.withLock { $0.append("\(index): \(error)") }
                }
            }
        }
        XCTAssertEqual(group.wait(timeout: .now() + 120), .success, "runBlocking hung while the cooperative pool was saturated")
        let elapsed = started.duration(to: clock.now)
        XCTAssertEqual(succeeded.withLock { $0 }, runCount, "failures: \(failures.withLock { $0 })")
        XCTAssertEqual(pool.entered, parked, "the pool stayed saturated for the whole time")
        // 64 runs of 1 s one after another would take 64 s. The bound leaves
        // room for spawning 64 shells under the parallel unit tier.
        XCTAssertLessThan(elapsed, .seconds(30), "the runs went one at a time instead of at once")

        pool.release(blockerCount)
        released = true
        XCTAssertEqual(oldBridgeDone.wait(timeout: .now() + 30), .success, "the old bridge finishes once the pool is released")
    }

    private enum Failure: Error {
        case notSuccessful
    }
}

/// Parks cooperative-pool threads on a semaphore from synchronous code, as
/// a blocking reader called from a task would.
private final class CooperativePoolBlocker: Sendable {
    private let gate = DispatchSemaphore(value: 0)
    private let count = Atomic<Int>(0)

    var entered: Int {
        count.load(ordering: .acquiring)
    }

    func block() {
        count.add(1, ordering: .acquiringAndReleasing)
        gate.wait()
    }

    func release(_ times: Int) {
        for _ in 0..<times {
            gate.signal()
        }
    }
}
