// ProcessManagerTests.swift - Process lifecycle regression tests
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
import Darwin
@testable import LungfishWorkflow

final class ProcessManagerTests: XCTestCase {

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

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ProcessManagerTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: url)
        }
        return url
    }

    private func waitForPIDFile(_ url: URL, timeout: TimeInterval = 2.0) async throws -> Int32 {
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
        guard pid > 0 else { return false }
        if kill(pid, 0) == 0 {
            return true
        }
        return errno != ESRCH
    }
}
