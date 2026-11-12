// ToolProcessMemoryStopTests.swift - A tool the Mac stopped for memory says why, with its peak
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import XCTest
@testable import LungfishCore

/// The stand-ins end themselves with SIGKILL or exit 137, as macOS ends a tool when the Mac runs out of memory, so
/// no test grows real memory past the 64 MB one stand-in touches to show its peak.
final class ToolProcessMemoryStopTests: XCTestCase {
    private typealias Fixtures = ToolProcessFixtures
    private let sixteenGB: UInt64 = 16 << 30

    // MARK: - Stand-ins under ToolProcess

    /// A stand-in touches 64 MB and then ends itself with SIGKILL. The words name the tool, the peak `wait4` read
    /// and this Mac's memory.
    func testSIGKILLWithPeakSaysTheMacRanOutOfMemory() async throws {
        let script = "exec python3 -I -c 'import os; b = bytearray(b\"\\x01\") * (64 << 20); os.kill(os.getpid(), 9)'"
        let spec = ToolProcessSpec(
            executableURL: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", script],
            environment: ["PATH": "/opt/homebrew/bin:/usr/local/bin:" + Fixtures.systemPath],
            label: "python3"
        )
        let capture = ToolProcessEndCapture()
        let result = try await ToolProcessObservation.$observer.withValue(capture.observer(forwardingTo: nil)) {
            try await ToolProcess.run(spec)
        }
        XCTAssertEqual(result.termination, .signaled(signal: SIGKILL), result.stderrText)
        let stop = try XCTUnwrap(capture.memoryStop(physicalMemoryBytes: sixteenGB))
        let peak = try XCTUnwrap(stop.peakMemoryBytes)
        XCTAssertGreaterThanOrEqual(peak, 64 << 20)
        XCTAssertEqual(
            stop.reason,
            "python3 stopped before it finished, most likely because the Mac ran out of memory. "
                + "It reached \(MemoryWords.bytes(peak)) at its peak on a Mac with 16 GB."
        )
        XCTAssertEqual(stop.message(), stop.reason + " " + ToolProcessMemoryStop.defaultNextStep)
    }

    /// `kill -KILL $$` in a `/bin/sh` child is the same stop, read from the result and from the capture alike.
    func testSIGKILLOfAShellIsAMemoryStop() async throws {
        let capture = ToolProcessEndCapture()
        let result = try await ToolProcessObservation.$observer.withValue(capture.observer(forwardingTo: nil)) {
            try await ToolProcess.run(Fixtures.shell("kill -KILL $$"))
        }
        XCTAssertEqual(result.termination, .signaled(signal: SIGKILL))
        XCTAssertNil(result.stop)
        let fromResult = try XCTUnwrap(ToolProcessMemoryStop(result: result, physicalMemoryBytes: sixteenGB))
        XCTAssertEqual(
            fromResult.reason,
            "sh stopped before it finished, most likely because the Mac ran out of memory. It ran on a Mac with 16 GB."
        )
        let captured = try XCTUnwrap(capture.memoryStop(physicalMemoryBytes: sixteenGB))
        XCTAssertNotNil(captured.peakMemoryBytes)
        XCTAssertTrue(captured.reason.hasPrefix("sh stopped before it finished"), captured.reason)
    }

    /// A wrapper such as `micromamba run` reports its killed child as exit 137.
    func testExit137IsAMemoryStop() async throws {
        let result = try await ToolProcess.run(Fixtures.shell("exit 137", label: "EsViritu"))
        XCTAssertEqual(result.termination, .exited(code: 137))
        let stop = try XCTUnwrap(ToolProcessMemoryStop(result: result, physicalMemoryBytes: sixteenGB))
        XCTAssertTrue(stop.reason.hasPrefix("EsViritu stopped before it finished, most likely because the Mac ran out"))
        XCTAssertEqual(ToolProcessMemoryStop(tool: "EsViritu", exitCode: 137, physicalMemoryBytes: sixteenGB), stop)
        XCTAssertNil(ToolProcessMemoryStop(tool: "EsViritu", exitCode: 1, physicalMemoryBytes: sixteenGB))
    }

    /// A SIGKILL that ToolProcess sent itself, here after a time limit, keeps the words of that stop.
    func testOwnStopKeepsItsWords() async throws {
        let spec = Fixtures.shell("trap '' TERM; exec /bin/sleep 30", timeout: .milliseconds(300))
        let capture = ToolProcessEndCapture()
        do {
            _ = try await ToolProcessObservation.$observer.withValue(capture.observer(forwardingTo: nil)) {
                try await ToolProcess.run(spec)
            }
            XCTFail("Expected a timeout")
        } catch let error as ToolProcessError {
            guard case .timedOut(_, let results) = error, let result = results.first else {
                return XCTFail("Unexpected error \(error)")
            }
            XCTAssertEqual(result.termination, .signaled(signal: SIGKILL))
            XCTAssertNotNil(result.stop)
            XCTAssertNil(ToolProcessMemoryStop(result: result, physicalMemoryBytes: sixteenGB))
            XCTAssertNil(capture.memoryStop(physicalMemoryBytes: sixteenGB))
            XCTAssertEqual(error.errorDescription, "'sh' timed out after 0.3 seconds")
        }
    }

    /// SIGPIPE is not a memory stop.
    func testSIGPIPEIsUnchanged() async throws {
        let capture = ToolProcessEndCapture()
        let result = try await ToolProcessObservation.$observer.withValue(capture.observer(forwardingTo: nil)) {
            try await ToolProcess.run(Fixtures.shell("kill -PIPE $$"))
        }
        XCTAssertEqual(result.termination, .signaled(signal: SIGPIPE))
        XCTAssertNil(ToolProcessMemoryStop(result: result, physicalMemoryBytes: sixteenGB))
        XCTAssertNil(capture.memoryStop(physicalMemoryBytes: sixteenGB))
        XCTAssertNil(ToolProcessMemoryStop(tool: "sh", exitCode: 0, physicalMemoryBytes: sixteenGB))
    }

    // MARK: - The capture

    /// The step's provenance observer still gets the one observation, unchanged.
    func testCaptureForwardsTheObservationToTheStepObserver() async throws {
        let delivered = LockedObservations()
        let inner = ToolProcessObserver { delivered.append($0) }
        let capture = ToolProcessEndCapture()
        _ = try await ToolProcessObservation.$observer.withValue(capture.observer(forwardingTo: inner)) {
            try await ToolProcess.run(Fixtures.shell("exit 137"))
        }
        XCTAssertEqual(delivered.all.count, 1)
        XCTAssertEqual(delivered.all.first?.stages.first?.ending, .terminated(.exited(code: 137)))
        XCTAssertNotNil(capture.memoryStop(physicalMemoryBytes: sixteenGB))
    }

    // MARK: - Words

    func testByteWords() {
        XCTAssertEqual(MemoryWords.bytes(64 << 30), "64 GB")
        XCTAssertEqual(MemoryWords.bytes(16 << 30), "16 GB")
        XCTAssertEqual(MemoryWords.bytes((15 << 30) / 2), "7.5 GB")
        XCTAssertEqual(MemoryWords.bytes(8 << 30), "8 GB")
        XCTAssertEqual(MemoryWords.bytes(70 << 20), "70 MB")
        XCTAssertEqual(MemoryWords.bytes(3 << 19), "1.5 MB")
        XCTAssertEqual(MemoryWords.bytes(512), "1 KB")
    }
}

private final class LockedObservations: @unchecked Sendable {
    private let lock = NSLock()
    private var observations: [ToolProcessRunObservation] = []

    func append(_ observation: ToolProcessRunObservation) {
        lock.lock()
        observations.append(observation)
        lock.unlock()
    }

    var all: [ToolProcessRunObservation] {
        lock.lock()
        defer { lock.unlock() }
        return observations
    }
}
