// WorkflowRunSIGTERMTests.swift - SIGTERM cancels `workflow run` and the engine's whole tree stops
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import ArgumentParser
import Darwin
import Foundation
import LungfishCore
import LungfishTestSupport
@testable import LungfishCLI
@testable import LungfishWorkflow
import XCTest

/// Phase 2.2 lane 3A (finding R7). The window's Cancel sends SIGTERM to
/// `lungfish-cli workflow run`. Only `import fastq` turned SIGTERM into a
/// cancel, so a cancelled workflow run ended the CLI at once and left
/// Nextflow's JVM running. `workflow run` now cancels its task on SIGTERM, and
/// the engine runner stops the engine's process tree.
final class WorkflowRunSIGTERMTests: XCTestCase {
    private var root: URL!
    private var priorRunner: LocalWorkflowProcessRunning!

    override func setUpWithError() throws {
        root = try TestTempDirectory.make(prefix: "workflow-run-sigterm")
        priorRunner = RunSubcommand.localWorkflowProcessRunner
    }

    override func tearDownWithError() throws {
        RunSubcommand.localWorkflowProcessRunner = priorRunner
        TestTempDirectory.cleanup(root)
    }

    /// A stand-in for the Nextflow launcher. It records its pid, starts a
    /// background child that stands in for the JVM, as `nextflow` starting
    /// `java` would, and waits.
    private func installNextflowLikeEngine() throws -> URL {
        let script = root.appendingPathComponent("fake-nextflow.sh")
        try """
        #!/bin/sh
        echo $$ > "$ENGINE_PID_FILE"
        /bin/sh -c 'echo $$ > "$JAVA_PID_FILE"; exec /bin/sleep 300' &
        wait
        """.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        return script
    }

    private func readPID(_ url: URL) -> Int32? {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        return Int32(text.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private func waitForPID(_ url: URL) async throws -> Int32 {
        var pid: Int32?
        await waitUntil(timeout: .seconds(10), pollInterval: .milliseconds(20)) {
            pid = readPID(url)
            return pid != nil
        }
        return try XCTUnwrap(pid, "no pid in \(url.lastPathComponent)")
    }

    func testSIGTERMCancelsALocalWorkflowRunAndStopsTheEngineTree() async throws {
        let script = try installNextflowLikeEngine()
        let enginePIDFile = root.appendingPathComponent("engine.pid")
        let javaPIDFile = root.appendingPathComponent("java.pid")
        let launch = WorkflowEngineLaunch(
            executableURL: URL(fileURLWithPath: "/bin/sh"),
            argumentPrefix: [script.path],
            environment: [
                "PATH": "/usr/bin:/bin",
                "ENGINE_PID_FILE": enginePIDFile.path,
                "JAVA_PID_FILE": javaPIDFile.path,
            ]
        )
        RunSubcommand.localWorkflowProcessRunner = ProcessLocalWorkflowProcessRunner(
            homeDirectory: root,
            resolveLaunch: { _, _ in launch }
        )

        let workflow = root.appendingPathComponent("main.nf")
        try "// invented fixture; never executed".write(to: workflow, atomically: true, encoding: .utf8)
        let results = root.appendingPathComponent("results", isDirectory: true)
        let bundle = root.appendingPathComponent("attempt.lungfishrun", isDirectory: true)
        let command = try RunSubcommand.parse([
            workflow.path,
            "--results-dir", results.path,
            "--expected-output", results.appendingPathComponent("result.txt").path,
            "--bundle-path", bundle.path,
            "--quiet",
        ])

        let run = Task<(any Error)?, Never> {
            do {
                try await command.run()
                return nil
            } catch {
                return error
            }
        }
        // The engine is running, so the command is listening for SIGTERM.
        let enginePID = try await waitForPID(enginePIDFile)
        let javaPID = try await waitForPID(javaPIDFile)
        XCTAssertTrue(ProcessTreeTerminator.processExists(pid: enginePID))
        XCTAssertTrue(ProcessTreeTerminator.processExists(pid: javaPID))
        defer {
            for pid in [enginePID, javaPID] where ProcessTreeTerminator.processExists(pid: pid) {
                kill(pid, SIGKILL)
            }
        }

        // Sent to this test process. Without the handler it would end it.
        kill(getpid(), SIGTERM)

        let error = await run.value
        let exit = try XCTUnwrap(error as? ExitCode, "\(String(describing: error))")
        XCTAssertEqual(exit.rawValue, CLIExitCode.cancelled.rawValue)
        let stopped = await waitUntil(timeout: .seconds(5)) {
            !ProcessTreeTerminator.processExists(pid: enginePID) && !ProcessTreeTerminator.processExists(pid: javaPID)
        }
        XCTAssertTrue(stopped, "the engine and its JVM child are stopped")
        let manifest = try LocalWorkflowRunBundleStore.read(from: bundle)
        XCTAssertEqual(manifest.executionStatus, .cancelled, "the run bundle records the cancel")
    }
}
