// WorkflowEngineProcessCancellationTests.swift - Cancelling `workflow run` stops the engine's whole tree
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Darwin
import Foundation
import LungfishCore
import LungfishTestSupport
@testable import LungfishCLI
@testable import LungfishWorkflow
import XCTest

/// Phase 2.2 lane 2C (finding R7). The two process runners of
/// `lungfish-cli workflow run` launched Nextflow with Foundation's Process and
/// had no cancellation, so a cancelled run left Nextflow's JVM and its task
/// processes running. They now run on ToolProcess, so cancelling the task
/// stops the engine's process group and its descendant tree.
final class WorkflowEngineProcessCancellationTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("workflow-engine-cancel-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
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

    /// A launch that runs `script` through `/bin/sh`. The argument prefix
    /// makes it a non-managed launch, so no managed launcher is repaired.
    private func resolver(for script: URL, environment: [String: String] = [:]) -> WorkflowEngineLaunchResolver {
        let launch = WorkflowEngineLaunch(
            executableURL: URL(fileURLWithPath: "/bin/sh"),
            argumentPrefix: [script.path],
            environment: ["PATH": "/usr/bin:/bin"].merging(environment) { _, new in new }
        )
        return { _, _ in launch }
    }

    private func readPID(_ url: URL) -> Int32? {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        return Int32(text.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// The 30 s waits here and in assertStopped leave room for the parallel
    /// unit tier and return as soon as their condition holds.
    private func waitForPID(_ url: URL, timeout: Duration = .seconds(30)) async throws -> Int32 {
        var pid: Int32?
        await waitUntil(timeout: timeout, pollInterval: .milliseconds(20)) {
            pid = readPID(url)
            return pid != nil
        }
        return try XCTUnwrap(pid, "no pid in \(url.lastPathComponent)")
    }

    private func assertStopped(_ pids: [Int32], file: StaticString = #filePath, line: UInt = #line) async {
        let stopped = await waitUntil(timeout: .seconds(30)) {
            pids.allSatisfy { !ProcessTreeTerminator.processExists(pid: $0) }
        }
        XCTAssertTrue(stopped, "still running: \(pids.filter { ProcessTreeTerminator.processExists(pid: $0) })", file: file, line: line)
        for pid in pids where ProcessTreeTerminator.processExists(pid: pid) {
            kill(pid, SIGKILL)
        }
    }

    func testCancellingTheNFCoreRunnerStopsTheEngineAndItsJVMChild() async throws {
        let script = try installNextflowLikeEngine()
        let enginePIDFile = root.appendingPathComponent("engine.pid")
        let javaPIDFile = root.appendingPathComponent("java.pid")
        let workingDirectory = root.appendingPathComponent("launch", isDirectory: true)
        let runner = ProcessNFCoreWorkflowProcessRunner(homeDirectory: root, resolveLaunch: resolver(for: script))
        let nfCoreLaunch = launch(
            ["run", "main.nf"], in: workingDirectory,
            environment: ["ENGINE_PID_FILE": enginePIDFile.path, "JAVA_PID_FILE": javaPIDFile.path])

        let task = Task {
            try await runner.runNextflow(nfCoreLaunch)
        }
        let enginePID = try await waitForPID(enginePIDFile)
        let javaPID = try await waitForPID(javaPIDFile)
        XCTAssertTrue(ProcessTreeTerminator.processExists(pid: enginePID))
        XCTAssertTrue(ProcessTreeTerminator.processExists(pid: javaPID))

        task.cancel()
        do {
            _ = try await task.value
            XCTFail("a cancelled run must not return a result")
        } catch {
            XCTAssertTrue(error is CancellationError, "\(error)")
        }
        await assertStopped([enginePID, javaPID])
        // The engine's log is synchronized at its final name once the tree is gone, and its stderr sidecar goes.
        let log = try String(contentsOf: nfCoreLaunch.logFile, encoding: .utf8)
        XCTAssertTrue(log.hasPrefix("nextflow_command: /bin/sh "), log)
        XCTAssertTrue(log.contains("\n--- stdout ---\n") && log.contains("\n--- stderr ---\n"), log)
        XCTAssertFalse(FileManager.default.fileExists(atPath: workingDirectory.appendingPathComponent(".lungfish-engine-stderr.txt").path))
    }

    /// A launch of the nf-core runner in `workingDirectory` with its log beside that folder. The profile is not
    /// docker, so no Docker command runs.
    private func launch(_ arguments: [String], in workingDirectory: URL, environment: [String: String] = [:]) -> NFCoreWorkflowLaunch {
        NFCoreWorkflowLaunch(
            arguments: arguments, profile: "local", workingDirectory: workingDirectory,
            workDirectory: workingDirectory.appendingPathComponent("work", isDirectory: true), environment: environment,
            logFile: root.appendingPathComponent("nextflow-\(UUID().uuidString).log"))
    }

    func testCancellingTheLocalRunnerStopsTheEngineAndItsJVMChild() async throws {
        let script = try installNextflowLikeEngine()
        let enginePIDFile = root.appendingPathComponent("engine.pid")
        let javaPIDFile = root.appendingPathComponent("java.pid")
        let workingDirectory = root.appendingPathComponent("launch", isDirectory: true)
        let runner = ProcessLocalWorkflowProcessRunner(
            homeDirectory: root,
            resolveLaunch: resolver(
                for: script,
                environment: ["ENGINE_PID_FILE": enginePIDFile.path, "JAVA_PID_FILE": javaPIDFile.path]
            )
        )

        let task = Task {
            try await runner.runWorkflow(
                executableName: "nextflow",
                arguments: ["run", "main.nf"],
                workingDirectory: workingDirectory
            )
        }
        let enginePID = try await waitForPID(enginePIDFile)
        let javaPID = try await waitForPID(javaPIDFile)

        task.cancel()
        do {
            _ = try await task.value
            XCTFail("a cancelled run must not return a result")
        } catch {
            XCTAssertTrue(error is CancellationError, "\(error)")
        }
        await assertStopped([enginePID, javaPID])
    }

    /// The local runner's logs come back byte for byte as the engine wrote
    /// them, blank lines and the trailing line break included, with the exit
    /// status. The nf-core runner is on NextflowEngineProcess, whose line
    /// streams keep the last 200 lines of each stream and skip blank lines,
    /// so its text holds every other line, each ended by a line break.
    func testRunnersReturnTheEngineLogsWholeAndItsExitStatus() async throws {
        let script = root.appendingPathComponent("chatty-engine.sh")
        try """
        #!/bin/sh
        printf '\\nN E X T F L O W\\n\\nline two\\n'
        printf 'warning\\n\\n' >&2
        exit 3
        """.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        let workingDirectory = root.appendingPathComponent("launch", isDirectory: true)

        let nfCore = try await ProcessNFCoreWorkflowProcessRunner(homeDirectory: root, resolveLaunch: resolver(for: script))
            .runNextflow(launch([], in: workingDirectory))
        XCTAssertEqual(nfCore, NFCoreWorkflowProcessResult(
            exitCode: 3, standardOutput: "N E X T F L O W\nline two\n", standardError: "warning\n"))

        let local = try await ProcessLocalWorkflowProcessRunner(homeDirectory: root, resolveLaunch: resolver(for: script))
            .runWorkflow(executableName: "nextflow", arguments: [], workingDirectory: workingDirectory)
        XCTAssertEqual(local.exitCode, 3)
        XCTAssertEqual(local.standardOutput, "\nN E X T F L O W\n\nline two\n")
        XCTAssertEqual(local.standardError, "warning\n\n")
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: workingDirectory.path)
        XCTAssertEqual(leftovers, [], "the log files are removed")
    }

    /// A process the engine started that is still running after the drain
    /// grace period is stopped, and the run fails, because its logs and
    /// results may be incomplete. The local runner keeps this rule. The nf-core
    /// runner is on NextflowEngineProcess, which returns once the tree is gone.
    func testAProcessStillRunningAfterTheEngineExitsFailsTheRun() async throws {
        let script = root.appendingPathComponent("leaky-engine.sh")
        let childPIDFile = root.appendingPathComponent("child.pid")
        try """
        #!/bin/sh
        /bin/sleep 300 > /dev/null 2>&1 &
        echo $! > "$CHILD_PID_FILE"
        echo done
        """.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        let runner = ProcessLocalWorkflowProcessRunner(
            homeDirectory: root,
            resolveLaunch: resolver(for: script, environment: ["CHILD_PID_FILE": childPIDFile.path])
        )

        let clock = ContinuousClock()
        let start = clock.now
        do {
            _ = try await runner.runWorkflow(
                executableName: "nextflow",
                arguments: [],
                workingDirectory: root.appendingPathComponent("launch", isDirectory: true)
            )
            XCTFail("a run that left a process behind must fail")
        } catch let error as CLIError {
            guard case .workflowFailed(let reason) = error else { return XCTFail("\(error)") }
            XCTAssertTrue(reason.contains("is incomplete because a child process kept it open"), reason)
        }
        XCTAssertGreaterThanOrEqual(start.duration(to: clock.now), WorkflowEngineProcess.drainGracePeriod)
        let childPID = try await waitForPID(childPIDFile)
        await assertStopped([childPID])
    }
}
