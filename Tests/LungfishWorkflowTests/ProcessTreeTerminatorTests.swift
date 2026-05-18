// ProcessTreeTerminatorTests.swift - Recursive process cleanup regression tests
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Darwin
import XCTest
@testable import LungfishWorkflow

final class ProcessTreeTerminatorTests: XCTestCase {
    func testTerminateKillsNestedGrandchildProcess() async throws {
        let tempDir = try makeTemporaryDirectory()
        let rootPIDFile = tempDir.appendingPathComponent("root.pid")
        let childPIDFile = tempDir.appendingPathComponent("child.pid")
        let grandchildPIDFile = tempDir.appendingPathComponent("grandchild.pid")
        let helperScript = tempDir.appendingPathComponent("helper.sh")
        let childScript = tempDir.appendingPathComponent("child.sh")
        let rootScript = tempDir.appendingPathComponent("root.sh")

        try writeExecutable(
            """
            #!/bin/sh
            trap "" TERM HUP INT
            sleep 20
            """,
            to: helperScript
        )
        try writeExecutable(
            """
            #!/bin/sh
            echo $$ > \(shellQuote(childPIDFile.path))
            \(shellQuote(helperScript.path)) &
            echo $! > \(shellQuote(grandchildPIDFile.path))
            wait
            """,
            to: childScript
        )
        try writeExecutable(
            """
            #!/bin/sh
            echo $$ > \(shellQuote(rootPIDFile.path))
            \(shellQuote(childScript.path)) &
            while true; do sleep 1; done
            """,
            to: rootScript
        )

        let process = Process()
        process.executableURL = rootScript
        try process.run()

        let rootPID = try await waitForPIDFile(rootPIDFile)
        let childPID = try await waitForPIDFile(childPIDFile)
        let grandchildPID = try await waitForPIDFile(grandchildPIDFile)
        defer {
            ProcessTreeTerminator.terminate(rootPID: rootPID, gracePeriod: 0)
            ProcessTreeTerminator.terminate(rootPID: childPID, gracePeriod: 0)
            ProcessTreeTerminator.terminate(rootPID: grandchildPID, gracePeriod: 0)
        }

        ProcessTreeTerminator.terminate(rootPID: rootPID, gracePeriod: 0)

        let childExited = await waitUntilProcessExits(pid: childPID, timeout: 2)
        let grandchildExited = await waitUntilProcessExits(pid: grandchildPID, timeout: 2)
        XCTAssertTrue(childExited)
        XCTAssertTrue(grandchildExited)
    }

    func testTerminateStopsTermIgnoringRootBeforeFinalSnapshot() async throws {
        let tempDir = try makeTemporaryDirectory()
        let rootPIDFile = tempDir.appendingPathComponent("root.pid")
        let latePIDFile = tempDir.appendingPathComponent("late.pid")
        let helperScript = tempDir.appendingPathComponent("late-helper.sh")
        let rootScript = tempDir.appendingPathComponent("root.sh")

        try writeExecutable(
            """
            #!/bin/sh
            trap "" TERM HUP INT
            sleep 20
            """,
            to: helperScript
        )
        try writeExecutable(
            """
            #!/bin/sh
            echo $$ > \(shellQuote(rootPIDFile.path))
            trap "" TERM HUP INT
            while true; do
                \(shellQuote(helperScript.path)) &
                echo $! > \(shellQuote(latePIDFile.path))
                sleep 0.05
            done
            """,
            to: rootScript
        )

        let process = Process()
        process.executableURL = rootScript
        try process.run()

        let rootPID = try await waitForPIDFile(rootPIDFile)
        defer {
            ProcessTreeTerminator.terminate(rootPID: rootPID, gracePeriod: 0)
            if let latePID = try? readPID(latePIDFile) {
                ProcessTreeTerminator.terminate(rootPID: latePID, gracePeriod: 0)
            }
        }

        let latePIDBeforeCancel = try await waitForPIDFile(latePIDFile)
        ProcessTreeTerminator.terminate(rootPID: rootPID, gracePeriod: 0)

        let lateChildExited = await waitUntilProcessExits(pid: latePIDBeforeCancel, timeout: 2)
        let rootExited = await waitUntilProcessExits(pid: rootPID, timeout: 2)
        XCTAssertTrue(lateChildExited)
        XCTAssertTrue(rootExited)
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ProcessTreeTerminatorTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: url)
        }
        return url
    }

    private func writeExecutable(_ contents: String, to url: URL) throws {
        try contents.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }

    private func waitForPIDFile(_ url: URL, timeout: TimeInterval = 5) async throws -> Int32 {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let pid = try? readPID(url) {
                return pid
            }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        throw NSError(
            domain: "ProcessTreeTerminatorTests",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: "Timed out waiting for pid file \(url.path)"]
        )
    }

    private func readPID(_ url: URL) throws -> Int32 {
        let contents = try String(contentsOf: url, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return try XCTUnwrap(Int32(contents), "Expected pid in \(url.path)")
    }

    private func waitUntilProcessExits(pid: Int32, timeout: TimeInterval) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if !ProcessTreeTerminator.processExists(pid: pid) {
                return true
            }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        return !ProcessTreeTerminator.processExists(pid: pid)
    }

    private func shellQuote(_ value: String) -> String {
        "'\(value.replacingOccurrences(of: "'", with: "'\\''"))'"
    }
}
