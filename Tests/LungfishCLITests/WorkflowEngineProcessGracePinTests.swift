// WorkflowEngineProcessGracePinTests.swift - Pin of the grace `workflow run` gives Nextflow before KILL
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.9 lane S9, milestone M1, panel decision N6. Every Nextflow engine gets 4 s between TERM and
// KILL, the time Nextflow needs to stop its tasks and finish its own shutdown, which took 1.8 s on a
// real cancel (Q15 R3). `workflow run` launches Nextflow through `WorkflowEngineProcess`, which sets no
// grace, so ToolProcess's 500 ms applies. The case pins that in an `XCTExpectFailure` block, and S9 M3
// gives the route its 4 s and makes it a plain assertion.

import Darwin
import Foundation
import LungfishCore
import LungfishTestSupport
@testable import LungfishCLI
import XCTest

final class WorkflowEngineProcessGracePinTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = try TestTempDirectory.make(prefix: "workflow-engine-grace")
    }

    override func tearDownWithError() throws {
        TestTempDirectory.cleanup(root)
    }

    func testACancelGivesTheNFCoreEngineTheFourSecondGraceBeforeKill() async throws {
        let script = try writeTermTrappingEngine()
        let pidFile = root.appendingPathComponent("engine.pid")
        let signalsFile = root.appendingPathComponent("signals")
        let launchDirectory = root.appendingPathComponent("launch", isDirectory: true)

        let task = Task {
            try await WorkflowEngineProcess.run(
                executableURL: URL(fileURLWithPath: "/bin/sh"),
                arguments: [script.path],
                environment: [
                    "PATH": "/usr/bin:/bin",
                    "ENGINE_PID_FILE": pidFile.path,
                    "SIGNALS_FILE": signalsFile.path,
                ],
                workingDirectory: launchDirectory,
                stdoutFileName: ".nextflow-stdout.log",
                stderrFileName: ".nextflow-stderr.log"
            )
        }
        let pid = try await waitForPID(pidFile)

        let clock = ContinuousClock()
        let cancelledAt = clock.now
        task.cancel()
        let outcome = await task.result
        let waited = clock.now - cancelledAt

        if case .failure(let error) = outcome {
            XCTAssertTrue(error is CancellationError, "\(error)")
        } else {
            XCTFail("a cancelled run must not return a result")
        }
        let stopped = await waitUntil(timeout: .seconds(30)) { !ProcessTreeTerminator.processExists(pid: pid) }
        XCTAssertTrue(stopped, "the engine outlived the cancel")
        if !stopped { kill(pid, SIGKILL) }
        XCTAssertTrue(
            ((try? String(contentsOf: signalsFile, encoding: .utf8)) ?? "").contains("TERM"),
            "the engine gets TERM first"
        )
        XCTExpectFailure(
            "N6. workflow run stops Nextflow with ToolProcess's 500 ms grace, which cuts Nextflow's own shutdown short. S9 M3 gives it the engine's 4 s."
        ) {
            XCTAssertGreaterThanOrEqual(waited, .milliseconds(3500), "the engine has the 4 s grace before KILL")
        }
    }

    /// A stand-in for Nextflow while it shuts down. It records each TERM and keeps running, so only a
    /// KILL ends it, and it gives up after about 60 s so it never outlives a failed case for long.
    private func writeTermTrappingEngine() throws -> URL {
        let script = root.appendingPathComponent("term-trapping-nextflow.sh")
        try """
        #!/bin/sh
        trap 'echo TERM >> "$SIGNALS_FILE"' TERM
        echo $$ > "$ENGINE_PID_FILE"
        tick=0
        while [ "$tick" -lt 600 ]; do
          sleep 0.1
          tick=$((tick + 1))
        done
        exit 124
        """.write(to: script, atomically: true, encoding: .utf8)
        return script
    }

    /// The pid the engine wrote once its trap was set, waiting up to 30 s for the parallel unit tier.
    private func waitForPID(_ url: URL) async throws -> Int32 {
        var pid: Int32?
        await waitUntil(timeout: .seconds(30), pollInterval: .milliseconds(20)) {
            pid = (try? String(contentsOf: url, encoding: .utf8))
                .flatMap { Int32($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
            return pid != nil
        }
        return try XCTUnwrap(pid, "the engine wrote no pid")
    }
}
