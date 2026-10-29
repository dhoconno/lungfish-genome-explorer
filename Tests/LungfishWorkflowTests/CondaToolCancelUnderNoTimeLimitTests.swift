// CondaToolCancelUnderNoTimeLimitTests.swift - Cancel stops a conda tool run that has no wall-clock limit
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
@testable import LungfishWorkflow
import LungfishTestSupport

/// Lane TTL3 lifted the fixed limits of the FASTQ operations. Two of them, `fastq deacon-ribo` and
/// `fastq ribodetector`, run through `CondaManager.runTool` with `AnalysisTimeLimit.launchTimeout`, which is
/// `.infinity` when the person set no limit. The cancel test of `CondaManagerTests` runs under a 30 s limit, so this
/// class shows that a run with no limit still stops on Cancel and that the tool ends with it.
final class CondaToolCancelUnderNoTimeLimitTests: XCTestCase {
    private static let toolBudget = WaitBudget(name: "toolStartOrExit", duration: .seconds(30))

    func testCancelStopsAToolRunThatHasNoTimeLimit() async throws {
        let sandbox = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: sandbox, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: sandbox) }
        let readyURL = sandbox.appendingPathComponent("ready")
        let pidURL = sandbox.appendingPathComponent("tool.pid")
        let bundledMicromamba = sandbox.appendingPathComponent("bundled-micromamba")
        let script = """
        #!/bin/sh
        case "$1" in
            --version)
                echo "2.0.5-0"
                exit 0
                ;;
            run)
                echo $$ > '\(pidURL.path)'
                touch '\(readyURL.path)'
                exec sleep 120
                ;;
            *)
                echo "unexpected args: $@" >&2
                exit 1
                ;;
        esac
        """
        try script.write(to: bundledMicromamba, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: bundledMicromamba.path)
        let manager = CondaManager(
            rootPrefix: sandbox.appendingPathComponent("conda"),
            bundledMicromambaProvider: { bundledMicromamba },
            bundledMicromambaVersionProvider: { "2.0.5-0" }
        )
        _ = try await manager.ensureMicromamba()

        XCTAssertEqual(AnalysisTimeLimit.launchTimeout, .infinity, "no command scoped a limit to this run")
        let task = Task {
            try await manager.runTool(
                name: "long-tool",
                environment: "long-env",
                timeout: AnalysisTimeLimit.launchTimeout
            )
        }
        let started = await waitUntil(budget: Self.toolBudget) {
            FileManager.default.fileExists(atPath: readyURL.path)
        }
        XCTAssertTrue(started, "the tool did not start")
        let pidText = try String(contentsOf: pidURL, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        let pid = try XCTUnwrap(Int32(pidText), "Expected a pid in \(pidURL.path)")
        defer { if kill(pid, 0) == 0 { kill(pid, SIGKILL) } }

        let cancelledAt = Date()
        task.cancel()
        let result = await task.result
        let elapsed = Date().timeIntervalSince(cancelledAt)
        guard case .failure(let error) = result else {
            return XCTFail("A run with no time limit did not stop on Cancel")
        }
        XCTAssertTrue(error is CancellationError, "Expected CancellationError, got \(error)")
        XCTAssertLessThan(elapsed, 30, "Cancel waited for the 120 s tool to end by itself")
        let ended = await waitUntil(budget: Self.toolBudget) { kill(pid, 0) != 0 }
        XCTAssertTrue(ended, "The tool kept running after Cancel")
    }
}
