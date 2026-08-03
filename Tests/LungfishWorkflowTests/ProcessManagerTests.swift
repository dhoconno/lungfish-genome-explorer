// ProcessManagerTests.swift - Process lifecycle regression tests
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
import Darwin
@testable import LungfishWorkflow

final class ProcessManagerTests: XCTestCase {

    func testRunAndWaitBuffersPartialOutputLines() async throws {
        let tempDir = try makeTemporaryDirectory()
        let scriptURL = tempDir.appendingPathComponent("partial-lines.sh")
        let script = """
        #!/bin/sh
        printf 'alpha'
        sleep 0.05
        printf ' beta\\n'
        sleep 0.05
        printf 'gamma'
        sleep 0.05
        printf ' delta'
        sleep 0.05
        printf 'warn' >&2
        sleep 0.05
        printf ' ing\\n' >&2
        sleep 0.05
        printf 'tail' >&2
        """
        try script.write(to: scriptURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)

        let result = try await ProcessManager.shared.runAndWait(
            executable: scriptURL,
            arguments: [],
            workingDirectory: tempDir,
            environment: nil
        )

        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(result.stdout, "alpha beta\ngamma delta")
        XCTAssertEqual(result.stderr, "warn ing\ntail")
    }

    func testRunAndWaitDrainsOutputWrittenImmediatelyBeforeExit() async throws {
        let tempDir = try makeTemporaryDirectory()
        let scriptURL = tempDir.appendingPathComponent("exit-output.sh")
        let script = """
        #!/bin/sh
        printf 'stdout-tail'
        printf 'stderr-tail' >&2
        """
        try script.write(to: scriptURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: scriptURL.path
        )

        for iteration in 0..<25 {
            let result = try await ProcessManager.shared.runAndWait(
                executable: scriptURL,
                arguments: [],
                workingDirectory: tempDir,
                environment: nil
            )

            XCTAssertEqual(result.exitCode, 0, "iteration \(iteration)")
            XCTAssertEqual(result.stdout, "stdout-tail", "iteration \(iteration)")
            XCTAssertEqual(result.stderr, "stderr-tail", "iteration \(iteration)")
        }
    }

    func testRunAndWaitDoesNotWaitForBackgroundDescendantHoldingPipesOpen() async throws {
        let tempDir = try makeTemporaryDirectory()
        let scriptURL = tempDir.appendingPathComponent("background-pipe-holder.sh")
        let childPIDFile = tempDir.appendingPathComponent("child.pid")
        let script = """
        #!/bin/sh
        printf 'root-stdout\n'
        (while :; do printf 'child-output'; done) &
        echo $! > "$1"
        printf 'root-stderr' >&2
        """
        try script.write(to: scriptURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: scriptURL.path
        )
        defer {
            if let childPIDText = try? String(contentsOf: childPIDFile, encoding: .utf8),
               let childPID = Int32(
                    childPIDText.trimmingCharacters(in: .whitespacesAndNewlines)
               ) {
                kill(childPID, SIGTERM)
            }
        }

        let start = Date()
        let result = try await ProcessManager.shared.runAndWait(
            executable: scriptURL,
            arguments: [childPIDFile.path],
            workingDirectory: tempDir,
            environment: nil
        )
        let elapsed = Date().timeIntervalSince(start)

        XCTAssertEqual(result.exitCode, 0)
        XCTAssertTrue(result.stdout.hasPrefix("root-stdout\n"))
        XCTAssertEqual(result.stderr, "root-stderr")
        XCTAssertLessThan(elapsed, 1.5)
    }

    func testTerminateKillsSpawnedProcessTree() async throws {
        let tempDir = try makeTemporaryDirectory()
        let childPIDFile = tempDir.appendingPathComponent("child.pid")
        let scriptURL = tempDir.appendingPathComponent("workflow-root.sh")
        let script = """
        #!/bin/sh
        /bin/sh -c 'trap "" TERM HUP INT; echo $$ > "$LUNGFISH_TEST_CHILD_PID_FILE"; while true; do sleep 1; done' &
        while true; do sleep 1; done
        """
        try script.write(to: scriptURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)

        let priorPIDFile = ProcessInfo.processInfo.environment["LUNGFISH_TEST_CHILD_PID_FILE"]
        setenv("LUNGFISH_TEST_CHILD_PID_FILE", childPIDFile.path, 1)
        defer {
            if let priorPIDFile {
                setenv("LUNGFISH_TEST_CHILD_PID_FILE", priorPIDFile, 1)
            } else {
                unsetenv("LUNGFISH_TEST_CHILD_PID_FILE")
            }
        }

        let handle = try await ProcessManager.shared.spawn(
            executable: scriptURL,
            arguments: [],
            workingDirectory: tempDir,
            environment: nil
        )
        let childPID = try await waitForPIDFile(childPIDFile)
        addTeardownBlock {
            if Self.isProcessRunning(pid: childPID) {
                kill(childPID, SIGKILL)
            }
            await ProcessManager.shared.terminate(id: handle.id)
        }

        XCTAssertTrue(Self.isProcessRunning(pid: childPID))

        await ProcessManager.shared.terminate(id: handle.id)

        let childExited = await Self.waitUntilProcessExits(pid: childPID, timeout: 2.0)
        XCTAssertTrue(childExited, "Terminating a workflow process must terminate descendant tool processes")
    }

    func testRunAndWaitCancellationTerminatesProcessTree() async throws {
        let tempDir = try makeTemporaryDirectory()
        let rootPIDFile = tempDir.appendingPathComponent("root.pid")
        let childPIDFile = tempDir.appendingPathComponent("child.pid")
        let scriptURL = tempDir.appendingPathComponent("workflow-run-and-wait.sh")
        let script = """
        #!/bin/sh
        echo $$ > "$LUNGFISH_TEST_ROOT_PID_FILE"
        /bin/sh -c 'trap "" TERM HUP INT; echo $$ > "$LUNGFISH_TEST_CHILD_PID_FILE"; while true; do sleep 1; done' &
        while true; do sleep 1; done
        """
        try script.write(to: scriptURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)

        let task = Task {
            try await ProcessManager.shared.runAndWait(
                executable: scriptURL,
                arguments: [],
                workingDirectory: tempDir,
                environment: [
                    "LUNGFISH_TEST_ROOT_PID_FILE": rootPIDFile.path,
                    "LUNGFISH_TEST_CHILD_PID_FILE": childPIDFile.path
                ]
            )
        }

        let rootPID = try await waitForPIDFile(rootPIDFile)
        let childPID = try await waitForPIDFile(childPIDFile)
        addTeardownBlock {
            ProcessTreeTerminator.terminate(rootPID: rootPID, gracePeriod: 0)
            ProcessTreeTerminator.terminate(rootPID: childPID, gracePeriod: 0)
        }

        XCTAssertTrue(Self.isProcessRunning(pid: rootPID))
        XCTAssertTrue(Self.isProcessRunning(pid: childPID))

        task.cancel()

        let rootExited = await Self.waitUntilProcessExits(pid: rootPID, timeout: 2.0)
        let childExited = await Self.waitUntilProcessExits(pid: childPID, timeout: 2.0)
        if !rootExited || !childExited {
            ProcessTreeTerminator.terminate(rootPID: rootPID, gracePeriod: 0)
            ProcessTreeTerminator.terminate(rootPID: childPID, gracePeriod: 0)
        }

        XCTAssertTrue(rootExited, "Cancelling runAndWait must terminate the root process")
        XCTAssertTrue(childExited, "Cancelling runAndWait must terminate descendant tool processes")

        do {
            _ = try await task.value
            XCTFail("Expected runAndWait to throw CancellationError")
        } catch is CancellationError {
            // Expected
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ProcessManagerTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: url)
        }
        return url
    }

    private func waitForPIDFile(_ url: URL, timeout: TimeInterval = 5.0) async throws -> Int32 {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let contents = try? String(contentsOf: url, encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines),
               let pid = Int32(contents) {
                return pid
            }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        throw NSError(
            domain: "ProcessManagerTests",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: "Timed out waiting for child PID"]
        )
    }

    private static func waitUntilProcessExits(pid: Int32, timeout: TimeInterval) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if !isProcessRunning(pid: pid) {
                return true
            }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        return !isProcessRunning(pid: pid)
    }

    private static func isProcessRunning(pid: Int32) -> Bool {
        ProcessTreeTerminator.processExists(pid: pid)
    }
}
