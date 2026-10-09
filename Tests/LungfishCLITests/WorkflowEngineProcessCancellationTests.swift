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

    private func waitForPID(_ url: URL, timeout: Duration = .seconds(10)) async throws -> Int32 {
        var pid: Int32?
        await waitUntil(timeout: timeout, pollInterval: .milliseconds(20)) {
            pid = readPID(url)
            return pid != nil
        }
        return try XCTUnwrap(pid, "no pid in \(url.lastPathComponent)")
    }

    private func assertStopped(_ pids: [Int32], file: StaticString = #filePath, line: UInt = #line) async {
        let stopped = await waitUntil(timeout: .seconds(5)) {
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

        let task = Task {
            try await runner.runNextflow(
                arguments: ["run", "main.nf"],
                workingDirectory: workingDirectory,
                environment: ["ENGINE_PID_FILE": enginePIDFile.path, "JAVA_PID_FILE": javaPIDFile.path]
            )
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
        XCTAssertFalse(FileManager.default.fileExists(atPath: workingDirectory.appendingPathComponent(".nextflow-stdout.log").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: workingDirectory.appendingPathComponent(".nextflow-stderr.log").path))
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

    /// The logs come back byte for byte as the files hold them, blank lines
    /// and the trailing line break included, with the exit status.
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
            .runNextflow(arguments: [], workingDirectory: workingDirectory, environment: [:])
        XCTAssertEqual(nfCore, NFCoreWorkflowProcessResult(
            exitCode: 3, standardOutput: "\nN E X T F L O W\n\nline two\n", standardError: "warning\n\n"))

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
    /// results may be incomplete.
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
        let runner = ProcessNFCoreWorkflowProcessRunner(homeDirectory: root, resolveLaunch: resolver(for: script))

        let clock = ContinuousClock()
        let start = clock.now
        do {
            _ = try await runner.runNextflow(
                arguments: [],
                workingDirectory: root.appendingPathComponent("launch", isDirectory: true),
                environment: ["CHILD_PID_FILE": childPIDFile.path]
            )
            XCTFail("a run that left a process behind must fail")
        } catch let error as CLIError {
            guard case .workflowFailed(let reason) = error else { return XCTFail("\(error)") }
            XCTAssertTrue(reason.contains("may be incomplete because a process it started kept running"), reason)
        }
        XCTAssertGreaterThanOrEqual(start.duration(to: clock.now), WorkflowEngineProcess.drainGracePeriod)
        let childPID = try await waitForPID(childPIDFile)
        await assertStopped([childPID])
    }

    // MARK: - The managed Nextflow

    /// Runs the managed Nextflow on a one-process local workflow whose task
    /// sleeps, cancels the run once the task has started and checks that no
    /// process of the run survives, the JVM included. It needs the managed
    /// Nextflow in the tool root this process resolves (set
    /// LUNGFISH_STORAGE_ROOT to point at it), skips without it, and fails
    /// without it under LUNGFISH_REQUIRE_TOOLS=1.
    func testCancellingAManagedNextflowRunLeavesNoJavaProcess() async throws {
        let managed: WorkflowEngineLaunch
        do {
            managed = try WorkflowEngineLaunch.resolveManaged(
                executableName: "nextflow", homeDirectory: FileManager.default.homeDirectoryForCurrentUser)
        } catch {
            try ToolAvailability.skipOrFail("the managed Nextflow is not installed: \(error.localizedDescription)")
        }
        // Through /usr/bin/env, which execs it, so the run does not repair the
        // managed launcher. The environment is the managed launch's own.
        let launch = WorkflowEngineLaunch(
            executableURL: URL(fileURLWithPath: "/usr/bin/env"),
            argumentPrefix: [managed.executableURL.path],
            environment: managed.environment
        )
        let mainNF = root.appendingPathComponent("main.nf")
        let marker = root.appendingPathComponent("task.pid")
        try """
        params.marker = ''

        process SLEEPER {
            script:
            \"\"\"
            echo \\$\\$ > '${params.marker}'
            sleep 600
            \"\"\"
        }

        workflow {
            SLEEPER()
        }
        """.write(to: mainNF, atomically: true, encoding: .utf8)
        let runner = ProcessNFCoreWorkflowProcessRunner(homeDirectory: root, resolveLaunch: { _, _ in launch })
        let runTag = root.lastPathComponent
        let arguments = [
            "run", mainNF.path,
            "--marker", marker.path,
            "-work-dir", root.appendingPathComponent("work", isDirectory: true).path,
        ]
        let launchDirectory = root.appendingPathComponent("launch", isDirectory: true)

        let task = Task {
            try await runner.runNextflow(
                arguments: arguments,
                workingDirectory: launchDirectory,
                environment: ["NXF_ANSI_LOG": "false"]
            )
        }
        var taskPID: Int32?
        await waitUntil(timeout: .seconds(240), pollInterval: .milliseconds(200)) {
            taskPID = readPID(marker)
            return taskPID != nil
        }
        guard let taskPID else {
            task.cancel()
            let outcome = await task.result
            return XCTFail("the Nextflow task never started: \(outcome)")
        }

        let javaPIDs = try Self.processIDs(commandContaining: runTag).filter { pid in
            Self.command(of: pid).contains("java")
        }
        XCTAssertFalse(javaPIDs.isEmpty, "the run's JVM is found by its script path")
        let tree = Set(javaPIDs + javaPIDs.flatMap { ProcessTreeTerminator.descendantProcessIDs(of: $0) } + [taskPID])
        XCTAssertTrue(tree.contains(taskPID))
        print("Nextflow run \(runTag): JVM \(javaPIDs), JVM tree and task \(tree.sorted())")

        task.cancel()
        do {
            _ = try await task.value
            XCTFail("a cancelled run must not return a result")
        } catch {
            XCTAssertTrue(error is CancellationError, "\(error)")
        }

        await assertStopped(Array(tree))
        let survivors = try Self.processIDs(commandContaining: runTag)
        XCTAssertEqual(survivors, [], "no process of the run survives: \(survivors.map(Self.command(of:)))")
    }

    /// The pids whose command line contains `text`, from `ps`.
    private static func processIDs(commandContaining text: String) throws -> [Int32] {
        let listing = try ProcessRunner.run(URL(fileURLWithPath: "/bin/ps"), ["-axo", "pid=,command="], timeout: 30)
        return listing.stdout.split(separator: "\n").compactMap { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.contains(text), !trimmed.contains("/bin/ps") else { return nil }
            return Int32(trimmed.prefix { $0.isNumber })
        }
    }

    private static func command(of pid: Int32) -> String {
        let listing = try? ProcessRunner.run(URL(fileURLWithPath: "/bin/ps"), ["-o", "command=", "-p", "\(pid)"], timeout: 30)
        return listing?.stdout ?? ""
    }
}
