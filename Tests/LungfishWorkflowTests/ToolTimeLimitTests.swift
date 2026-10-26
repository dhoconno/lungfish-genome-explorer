// ToolTimeLimitTests.swift - An analysis tool run has no wall-clock limit unless its caller sets one
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
import os
@testable import LungfishWorkflow
import LungfishCore

/// `docs/contracts/SCOPE-AND-DELIVERY.md`, Tool run time. An analysis tool has no wall-clock limit by default,
/// and a limit is a named option that its caller sets. Each conda test reads the limit through
/// `CondaToolTimeLimit.specProbe`, so no test runs a tool for the length of a limit.
final class ToolTimeLimitTests: XCTestCase {

    // MARK: - CondaManager.runTool

    func testRunToolWithNoTimeoutArgumentGetsNoWallClockLimit() async throws {
        let (manager, sandbox) = try await makeScriptedManager()
        defer { try? FileManager.default.removeItem(at: sandbox) }

        let limits = try await limitsOfLaunches {
            _ = try await manager.runTool(name: "analysis-tool", environment: "analysis-env")
        }

        XCTAssertEqual(limits, [nil], "runTool builds one launch, and with no timeout argument it carries no wall-clock limit")
    }

    func testRunToolWithAStdoutHandlerAndNoTimeoutArgumentGetsNoWallClockLimit() async throws {
        let (manager, sandbox) = try await makeScriptedManager()
        defer { try? FileManager.default.removeItem(at: sandbox) }

        let limits = try await limitsOfLaunches {
            _ = try await manager.runTool(name: "analysis-tool", environment: "analysis-env", stdoutHandler: { _ in })
        }

        XCTAssertEqual(limits, [nil], "the streaming overload has its own default, and it carries no wall-clock limit")
    }

    func testRunToolKeepsTheLimitItsCallerSets() async throws {
        let (manager, sandbox) = try await makeScriptedManager()
        defer { try? FileManager.default.removeItem(at: sandbox) }

        let limits = try await limitsOfLaunches {
            _ = try await manager.runTool(name: "analysis-tool", environment: "analysis-env", timeout: 42)
        }

        XCTAssertEqual(limits, [.seconds(42)], "a caller that sets a limit keeps it")
    }

    // MARK: - Helpers

    /// The wall-clock limit of each launch that `call` makes, in launch order, nil for none.
    private func limitsOfLaunches(_ call: () async throws -> Void) async rethrows -> [Duration?] {
        let limits = OSAllocatedUnfairLock<[Duration?]>(initialState: [])
        try await CondaToolTimeLimit.$specProbe.withValue({ spec in
            limits.withLock { $0.append(spec.timeout) }
        }) { try await call() }
        return limits.withLock { $0 }
    }

    /// A manager whose micromamba is a script that reports a version, and for `run` prints a line and exits 0.
    private func makeScriptedManager() async throws -> (manager: CondaManager, sandbox: URL) {
        let sandbox = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: sandbox, withIntermediateDirectories: true)
        let bundledMicromamba = sandbox.appendingPathComponent("bundled-micromamba")
        let script = """
        #!/bin/sh
        case "$1" in
            --version)
                echo "2.0.5-0"
                exit 0
                ;;
            run)
                echo "ok"
                exit 0
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
        return (manager, sandbox)
    }
}
