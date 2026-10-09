// ProcessManagerTests.swift - Process lifecycle regression tests
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
import Darwin
import LungfishCore
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

    /// A background child that keeps the pipes open after the root exits no
    /// longer leaves runAndWait returning only what was buffered at exit. The
    /// output gets the drain grace period, then the child is stopped and the
    /// run is an error, because the output is incomplete (Phase 2.2 lane 2C
    /// manager ruling). A short grace through the internal knob keeps the
    /// test fast and its timing window tight (lane 5A).
    func testRunAndWaitReportsOutputABackgroundDescendantHeldOpenAsIncomplete() async throws {
        let tempDir = try makeTemporaryDirectory()
        let scriptURL = tempDir.appendingPathComponent("background-pipe-holder.sh")
        let childPIDFile = tempDir.appendingPathComponent("child.pid")
        let script = """
        #!/bin/sh
        printf 'root-stdout\n'
        /bin/sleep 300 &
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
                kill(childPID, SIGKILL)
            }
        }

        let start = Date()
        do {
            _ = try await ProcessManager.shared.runAndWait(
                executable: scriptURL,
                arguments: [childPIDFile.path],
                workingDirectory: tempDir,
                environment: nil,
                drainGracePeriod: .milliseconds(300)
            )
            XCTFail("Output a child held open must not be returned as complete")
        } catch let error as WorkflowError {
            guard case .processError(_, let underlying) = error else {
                return XCTFail("Unexpected workflow error: \(error)")
            }
            XCTAssertTrue(underlying is ProcessOutputIncompleteError, "\(underlying)")
            let message = error.localizedDescription
            XCTAssertTrue(message.contains("The output of background-pipe-holder.sh is incomplete because a child process kept it open after background-pipe-holder.sh exited, so LGE stopped it."), message)
        }
        let elapsed = Date().timeIntervalSince(start)

        // The drain grace period, then the stop of the child's group.
        XCTAssertGreaterThanOrEqual(elapsed, 0.3)
        XCTAssertLessThan(elapsed, 4)
        let childPID = try await waitForPIDFile(childPIDFile)
        let childExited = await Self.waitUntilProcessExits(pid: childPID, timeout: 2.0)
        XCTAssertTrue(childExited, "The child that held the output open is stopped")
    }

    /// Pins the text runAndWait returns, which the tool goldens lock. Every
    /// nonempty line of a stream, split at LF, CR or CRLF, joined with "\n".
    /// Blank lines, a leading blank line and the trailing line break are not
    /// kept, and a line longer than 64 KB is kept whole.
    func testRunAndWaitJoinsNonemptyLinesAndDropsBlankLinesAndTheTrailingNewline() async throws {
        let tempDir = try makeTemporaryDirectory()
        let scriptURL = tempDir.appendingPathComponent("line-joining.sh")
        let script = """
        #!/bin/sh
        printf '\\nfirst\\n\\n\\r\\nsecond\\r\\nthird\\rfourth\\n\\n'
        printf '\\nwarn one\\n\\nwarn two\\n' >&2
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
        XCTAssertEqual(result.stdout, "first\nsecond\nthird\nfourth")
        XCTAssertEqual(result.stderr, "warn one\nwarn two")

        let longLineScript = tempDir.appendingPathComponent("long-line.sh")
        try """
        #!/bin/sh
        head -c 100000 /dev/zero | tr '\\0' 'a'
        printf '\\nend\\n'
        """.write(to: longLineScript, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: longLineScript.path)
        let long = try await ProcessManager.shared.runAndWait(
            executable: longLineScript,
            arguments: [],
            workingDirectory: tempDir,
            environment: nil
        )
        XCTAssertEqual(long.stdout, String(repeating: "a", count: 100_000) + "\nend")
    }

    func testJoinedNonemptyLinesSplitsAsRunAndWaitAlwaysHas() {
        func joined(_ bytes: [UInt8]) -> String {
            ProcessManager.joinedNonemptyLines(Data(bytes))
        }
        XCTAssertEqual(joined([]), "")
        XCTAssertEqual(joined(Array("\n\r\n\r".utf8)), "")
        XCTAssertEqual(joined(Array("a\rb\r\nc\n\nd".utf8)), "a\nb\nc\nd")
        // Each line decodes as UTF-8, with invalid bytes replaced.
        XCTAssertEqual(joined([0xC3, 0xA9, 0x0A, 0xFF, 0x41]), "\u{e9}\n\u{FFFD}A")
    }

    /// The spawn path finishes its streams when a child holds the output
    /// open too long, and reports the clean exit as incomplete through the
    /// exit status, with the reason as the last line of stderr.
    func testSpawnReportsOutputABackgroundDescendantHeldOpenThroughTheExitStatus() async throws {
        let tempDir = try makeTemporaryDirectory()
        let scriptURL = tempDir.appendingPathComponent("spawn-pipe-holder.sh")
        let childPIDFile = tempDir.appendingPathComponent("child.pid")
        try """
        #!/bin/sh
        printf 'root-stdout\n'
        /bin/sleep 300 &
        echo $! > "$1"
        """.write(to: scriptURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)
        defer {
            if let text = try? String(contentsOf: childPIDFile, encoding: .utf8),
               let pid = Int32(text.trimmingCharacters(in: .whitespacesAndNewlines)) {
                kill(pid, SIGKILL)
            }
        }

        let handle = try await ProcessManager.shared.spawn(
            executable: scriptURL,
            arguments: [childPIDFile.path],
            workingDirectory: tempDir,
            environment: nil,
            drainGracePeriod: .milliseconds(300)
        )
        async let stdout = handle.collectStdout()
        async let stderr = handle.collectStderr()
        let exitCode = await handle.waitForExit()
        let (out, err) = await (stdout, stderr)

        XCTAssertEqual(exitCode, ProcessManager.incompleteOutputStatus)
        XCTAssertEqual(out, "root-stdout")
        XCTAssertTrue(err.contains("The output of spawn-pipe-holder.sh is incomplete because a child process kept it open"), err)
        let childPID = try await waitForPIDFile(childPIDFile)
        let childExited = await Self.waitUntilProcessExits(pid: childPID, timeout: 2.0)
        XCTAssertTrue(childExited, "The child that held the output open is stopped")
    }

    /// A grandchild orphaned when its parent exits is no longer in the root's
    /// descendant tree, but it never left the root's process group, so
    /// terminate(id:) still stops it.
    func testTerminateKillsAGrandchildThatKeptItsProcessGroup() async throws {
        let tempDir = try makeTemporaryDirectory()
        let grandchildPIDFile = tempDir.appendingPathComponent("grandchild.pid")
        let scriptURL = tempDir.appendingPathComponent("orphaning-root.sh")
        try """
        #!/bin/sh
        ( /bin/sleep 300 > /dev/null 2>&1 & echo $! > "$1" )
        while true; do sleep 1; done
        """.write(to: scriptURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)

        let handle = try await ProcessManager.shared.spawn(
            executable: scriptURL,
            arguments: [grandchildPIDFile.path],
            workingDirectory: tempDir,
            environment: nil
        )
        let grandchildPID = try await waitForPIDFile(grandchildPIDFile)
        addTeardownBlock {
            if Self.isProcessRunning(pid: grandchildPID) {
                kill(grandchildPID, SIGKILL)
            }
        }
        XCTAssertTrue(Self.isProcessRunning(pid: grandchildPID))
        XCTAssertEqual(getpgid(grandchildPID), handle.pid, "the grandchild stays in the root's group")
        XCTAssertFalse(
            ProcessTreeTerminator.descendantProcessIDs(of: handle.pid).contains(grandchildPID),
            "the grandchild is orphaned, so a tree walk from the root misses it"
        )

        await ProcessManager.shared.terminate(id: handle.id)

        let exited = await Self.waitUntilProcessExits(pid: grandchildPID, timeout: 2.0)
        XCTAssertTrue(exited, "terminate(id:) stops the root's whole process group")
        let exitCode = await handle.waitForExit()
        XCTAssertEqual(exitCode, SIGTERM, "the root ended on the SIGTERM")
        let running = await ProcessManager.shared.isRunning(id: handle.id)
        XCTAssertFalse(running)
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
