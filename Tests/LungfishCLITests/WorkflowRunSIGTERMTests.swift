// WorkflowRunSIGTERMTests.swift - SIGTERM cancels `workflow run` and the engine's whole tree stops
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Darwin
import Foundation
import LungfishCore
import LungfishTestSupport
import LungfishWorkflow
import XCTest
@testable import LungfishCLI

/// Phase 2.2 lane 3A (finding R7). The window's Cancel sends SIGTERM to
/// `lungfish-cli workflow run`. Only `import fastq` turned SIGTERM into a
/// cancel, so a cancelled workflow run ended the CLI at once and left
/// Nextflow's JVM running. `workflow run` now cancels its task on SIGTERM, and
/// the engine runner stops the engine's process tree.
///
/// Phase 2.10 lane S30 runs the check on `CLISIGTERMHarness`, so the signal
/// reaches the built `lungfish-cli` and not this test process. The CLI finds
/// the stand-in engine as the managed Nextflow of a conda root of its own, with
/// a home and a storage root of its own, so the run touches nothing real.
final class WorkflowRunSIGTERMTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = try TestTempDirectory.make(prefix: "workflow-run-sigterm")
    }

    override func tearDownWithError() throws {
        TestTempDirectory.cleanup(root)
    }

    /// A stand-in for the managed Nextflow launcher, where the CLI looks for it
    /// under `condaRoot`. It records its pid, starts a background child that
    /// stands in for the JVM, as `nextflow` starting `java` would, and waits.
    private func installNextflowLikeEngine(in condaRoot: URL) throws {
        let script = condaRoot.appendingPathComponent("envs/nextflow/bin/nextflow")
        try FileManager.default.createDirectory(
            at: script.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try """
        #!/bin/sh
        echo $$ > "$ENGINE_PID_FILE"
        /bin/sh -c 'echo $$ > "$JAVA_PID_FILE"; exec /bin/sleep 300' &
        wait
        """.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
    }

    func testSIGTERMCancelsALocalWorkflowRunAndStopsTheEngineTree() async throws {
        let condaRoot = root.appendingPathComponent("conda", isDirectory: true)
        try installNextflowLikeEngine(in: condaRoot)
        let home = root.appendingPathComponent("home", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let enginePIDFile = root.appendingPathComponent("engine.pid")
        let javaPIDFile = root.appendingPathComponent("java.pid")

        let workflow = root.appendingPathComponent("main.nf")
        try "// invented fixture; never executed".write(to: workflow, atomically: true, encoding: .utf8)
        let results = root.appendingPathComponent("results", isDirectory: true)
        let bundle = root.appendingPathComponent("attempt.lungfishrun", isDirectory: true)

        let cli = try CLISIGTERMHarness.launchCLI(
            [
                "workflow", "run", workflow.path,
                "--results-dir", results.path,
                "--expected-output", results.appendingPathComponent("result.txt").path,
                "--bundle-path", bundle.path,
                "--quiet",
            ],
            environment: [
                "LUNGFISH_CONDA_ROOT": condaRoot.path,
                "LUNGFISH_STORAGE_ROOT": root.appendingPathComponent("storage", isDirectory: true).path,
                "LUNGFISH_CONDA_SHARED_PKGS": "0",
                "CFFIXED_USER_HOME": home.path,
                "ENGINE_PID_FILE": enginePIDFile.path,
                "JAVA_PID_FILE": javaPIDFile.path,
            ],
            workingDirectory: root,
            testClass: Self.self
        )
        defer { cli.stop() }

        // The engine and its JVM child run, so the command is listening for SIGTERM.
        guard let enginePID = await CLISIGTERMHarness.waitForProcessID(in: enginePIDFile),
              let javaPID = await CLISIGTERMHarness.waitForProcessID(in: javaPIDFile) else {
            let stop = await CLISIGTERMHarness.cancel(cli)
            return XCTFail("The CLI never started the engine and its JVM child.\(stop.diagnostics)")
        }

        let stop = await CLISIGTERMHarness.assertSIGTERMCancels(cli) {
            try LocalWorkflowRunBundleStore.read(from: bundle).executionStatus.rawValue
        }
        XCTAssertTrue(
            stop.tree.contains(enginePID) && stop.tree.contains(javaPID),
            "the engine and its JVM child belong to the CLI's tree \(stop.tree)"
        )
        XCTAssertTrue(stop.standardError.contains("Workflow cancelled"), stop.diagnostics)
        XCTAssertEqual(CLISIGTERMHarness.cancelledExitStatus, CLIExitCode.cancelled.rawValue)
    }

    /// The harness's own check. Before lane 3A, `workflow run` ended on the
    /// first SIGTERM and left Nextflow's JVM running. A stand-in that does the
    /// same fails each of the three checks, and the harness kills the child it
    /// finds left.
    @MainActor
    func testTheHarnessFailsACommandThatEndsOnSIGTERMAndLeavesItsChild() async throws {
        let childPIDFile = root.appendingPathComponent("child.pid")
        let script = root.appendingPathComponent("ends-on-sigterm.sh")
        try """
        #!/bin/sh
        /bin/sh -c 'echo $$ > "$CHILD_PID_FILE"; exec /bin/sleep 300' &
        wait
        """.write(to: script, atomically: true, encoding: .utf8)
        let run = try CLISIGTERMHarness.launch(
            executableURL: URL(fileURLWithPath: "/bin/sh"),
            arguments: [script.path],
            environment: ["PATH": "/usr/bin:/bin", "CHILD_PID_FILE": childPIDFile.path]
        )
        defer { run.stop() }
        guard let childPID = await CLISIGTERMHarness.waitForProcessID(in: childPIDFile) else {
            return XCTFail("The stand-in never started its child")
        }

        // The child would sleep for 300 s, so a shorter wait for the tree finds it all the same.
        let stop = await CLISIGTERMHarness.cancel(run, timeout: .seconds(5))
        XCTAssertEqual(stop.termination, .signaled(signal: SIGTERM), stop.diagnostics)
        XCTAssertTrue(stop.left.contains(childPID), "the child outlives the command, \(stop.left) out of \(stop.tree)")
        XCTExpectFailure("a command that ends by the signal does not exit 125") {
            CLISIGTERMHarness.assertCancelledExit(stop)
        }
        XCTExpectFailure("a command that ends by the signal writes no cancelled record") {
            CLISIGTERMHarness.assertRecordCancelled { "running" }
        }
        XCTExpectFailure("the child outlives the command") {
            CLISIGTERMHarness.assertNoProcessLeft(stop)
        }
        let killed = await waitUntil(timeout: .seconds(5)) { !ProcessTreeTerminator.processExists(pid: childPID) }
        XCTAssertTrue(killed, "the harness kills a process it finds left")
    }

    /// A command that ignores SIGTERM never exits. The harness reports it as still running,
    /// records its tree as left and kills it, so the test leaves nothing behind.
    @MainActor
    func testTheHarnessKillsTheTreeOfACommandThatIgnoresSIGTERM() async throws {
        let childPIDFile = root.appendingPathComponent("child.pid")
        let script = root.appendingPathComponent("ignores-sigterm.sh")
        try """
        #!/bin/sh
        trap '' TERM
        /bin/sh -c 'echo $$ > "$CHILD_PID_FILE"; exec /bin/sleep 300' &
        wait
        """.write(to: script, atomically: true, encoding: .utf8)
        let run = try CLISIGTERMHarness.launch(
            executableURL: URL(fileURLWithPath: "/bin/sh"),
            arguments: [script.path],
            environment: ["PATH": "/usr/bin:/bin", "CHILD_PID_FILE": childPIDFile.path]
        )
        defer { run.stop() }
        guard let childPID = await CLISIGTERMHarness.waitForProcessID(in: childPIDFile) else {
            return XCTFail("The stand-in never started its child")
        }

        // The command never exits, so a short wait finds that all the same.
        let stop = await CLISIGTERMHarness.cancel(run, timeout: .seconds(2))
        XCTAssertNil(stop.termination, stop.diagnostics)
        XCTAssertTrue(
            stop.left.contains(run.processIdentifier) && stop.left.contains(childPID),
            "the command and its child are left, \(stop.left) out of \(stop.tree)"
        )
        XCTExpectFailure("the tree of a command that ignores SIGTERM is left") {
            CLISIGTERMHarness.assertNoProcessLeft(stop)
        }
        let killed = await waitUntil(timeout: CLISIGTERMHarness.processWait) { !run.isRunning }
        XCTAssertTrue(killed, "the harness kills a command that ignores SIGTERM")
    }
}
