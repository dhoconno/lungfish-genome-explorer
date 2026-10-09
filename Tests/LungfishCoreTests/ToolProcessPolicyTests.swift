// ToolProcessPolicyTests.swift - The reasons, grace periods and defaults every ToolProcess adapter shares
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import XCTest
@testable import LungfishCore
import LungfishTestSupport

/// Phase 2.2 lane 5A (R7). The policy that adapters used to restate each in
/// their own words now lives in Core once.
final class ToolProcessPolicyTests: XCTestCase {
    private typealias Fixtures = ToolProcessFixtures

    private func result(drainTimedOut: Bool, readFailed: Bool) -> ToolProcessResult {
        ToolProcessResult(
            label: "minimap2", pid: 1, termination: .exited(code: 0), stop: nil, stdout: Data(), stderr: Data(),
            stdoutTruncated: false, stderrTruncated: false,
            outputDrainTimedOut: drainTimedOut, outputReadFailed: readFailed, wallTime: .zero
        )
    }

    func testIncompleteOutputReasonIsOneStandardSentenceNamingTheLabel() {
        XCTAssertNil(result(drainTimedOut: false, readFailed: false).incompleteOutputReason)
        XCTAssertEqual(
            result(drainTimedOut: true, readFailed: false).incompleteOutputReason,
            "The output of minimap2 is incomplete because a child process kept it open after minimap2 exited, so LGE stopped it."
        )
        XCTAssertEqual(
            result(drainTimedOut: false, readFailed: true).incompleteOutputReason,
            "The output of minimap2 is incomplete because reading it failed."
        )
        // A drain that ran out is named first, because its descendants were stopped.
        XCTAssertEqual(
            result(drainTimedOut: true, readFailed: true).incompleteOutputReason,
            result(drainTimedOut: true, readFailed: false).incompleteOutputReason
        )
    }

    func testDefaultsAreAFiveSecondDrainAndAFourMegabyteStderrTail() {
        let spec = ToolProcessSpec(executableURL: URL(fileURLWithPath: "/bin/echo"), environment: [:])
        XCTAssertEqual(spec.drainGracePeriod, .seconds(5))
        XCTAssertEqual(spec.stderr, .capture(limit: 4 * 1024 * 1024))
        XCTAssertEqual(spec.stdout, .capture())
        XCTAssertEqual(spec.terminationGracePeriod, .milliseconds(500))
    }

    /// The default stderr keeps the tail, where tools print their summaries.
    func testTheDefaultStderrCaptureKeepsTheLastFourMegabytes() async throws {
        let spec = ToolProcessSpec(
            executableURL: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "head -c 5000000 /dev/zero | tr '\\0' 'e' >&2; echo SUMMARY >&2"],
            environment: ["PATH": Fixtures.systemPath]
        )
        let result = try await ToolProcess.run(spec)
        XCTAssertTrue(result.isSuccess)
        XCTAssertTrue(result.stderrTruncated)
        XCTAssertEqual(result.stderr.count, ToolProcessSpec.defaultStderrCaptureLimit)
        XCTAssertTrue(result.stderrText.hasSuffix("eeeSUMMARY\n"))
    }

    /// A descendant that ignores SIGTERM and holds stdout open past the drain
    /// grace is killed after a short fixed grace, not after the spec's
    /// termination grace, which is for a cancellation or a timeout.
    func testLeftoversAreKilledAfterAShortFixedGraceWhateverTheTerminationGrace() async throws {
        let directory = try makeToolProcessTempDirectory()
        let pidFile = directory.appendingPathComponent("stubborn.pid")
        var spec = Fixtures.shell(
            "(trap '' TERM; exec sleep 60) & echo $! > \(Fixtures.shellQuote(pidFile.path)); echo done",
            drainGracePeriod: .milliseconds(300)
        )
        spec.terminationGracePeriod = .seconds(30)
        let clock = ContinuousClock()
        let started = clock.now
        let result = try await ToolProcess.run(spec)
        let elapsed = started.duration(to: clock.now)
        let stubborn = Fixtures.readPID(pidFile)
        defer { Fixtures.killIfAlive(stubborn) }

        // Well under the 30 s grace, with room for the parallel unit tier.
        XCTAssertLessThan(elapsed, .seconds(20), "the 30 second termination grace must not apply to leftovers")
        XCTAssertEqual(result.termination, .exited(code: 0))
        XCTAssertNil(result.stop)
        XCTAssertTrue(result.outputDrainTimedOut)
        XCTAssertNotNil(result.incompleteOutputReason)
        XCTAssertEqual(result.stdoutText, "done\n")
        let leftover = try XCTUnwrap(stubborn)
        // SIGKILL went out before the run returned, so the leftover is gone
        // within moments, long before its 60 second sleep.
        let gone = await Fixtures.waitForExit(leftover)
        XCTAssertTrue(gone, "the leftover ignored SIGTERM and must still be killed")
    }

    /// A cancellation still waits out the spec's termination grace before SIGKILL.
    func testCancellationStillUsesTheSpecTerminationGrace() async throws {
        let directory = try makeToolProcessTempDirectory()
        let pidFile = directory.appendingPathComponent("root.pid")
        var spec = Fixtures.shell("trap '' TERM; echo $$ > \(Fixtures.shellQuote(pidFile.path)); while true; do sleep 0.05; done")
        spec.terminationGracePeriod = .milliseconds(1500)
        let run = try ToolProcess.start(spec)
        _ = await Fixtures.waitForPID(pidFile)
        let clock = ContinuousClock()
        let started = clock.now
        run.cancel()
        do {
            _ = try await run.result()
            XCTFail("Expected a cancellation")
        } catch ToolProcessError.cancelled {
        } catch {
            XCTFail("Unexpected error \(error)")
        }
        XCTAssertGreaterThanOrEqual(started.duration(to: clock.now), .milliseconds(1400))
    }
}
