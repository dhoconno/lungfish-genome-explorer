// WorkflowEngineRealNextflowCancellationTests.swift - Cancelling a managed Nextflow run leaves no JVM
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Darwin
import Foundation
import LungfishCore
import LungfishTestSupport
@testable import LungfishCLI
@testable import LungfishWorkflow
import XCTest

/// Phase 2.2 lane 2C (finding R7), split out by lane 5C. This is the one test of
/// `WorkflowEngineProcessCancellationTests` that needs the real managed
/// Nextflow, so it sits in the tool-conformance selection and the unit tier
/// keeps the fake-script tests.
final class WorkflowEngineRealNextflowCancellationTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("workflow-engine-real-nextflow-cancel-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func readPID(_ url: URL) -> Int32? {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        return Int32(text.trimmingCharacters(in: .whitespacesAndNewlines))
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
