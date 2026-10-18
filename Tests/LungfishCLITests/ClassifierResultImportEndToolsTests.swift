// ClassifierResultImportEndToolsTests.swift - The end of the tools an import started, when it is cancelled
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.12 lane 12.05, finding 2 of its review (SWIFT 3, X14). A cancelled NAO-MGS or NVD import ends the
// processes it started, such as a samtools run, before it records the cancel, so none outlives the command. The
// fixtures of the import tests hold no BAM, so no tool ever ran in them. These cases run `endTools` on a shell that
// stands in for the command and holds a tool of its own, one that ends on SIGTERM and one that ignores it.

import Darwin
import Foundation
import XCTest
@testable import LungfishCLI
import LungfishCore
import LungfishTestSupport

final class ClassifierResultImportEndToolsTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = try TestTempDirectory.make(prefix: "classifier-import-end-tools")
    }

    override func tearDownWithError() throws {
        TestTempDirectory.cleanup(root)
    }

    /// A tool that ends on SIGTERM is gone when `endTools` returns, and the command that started it keeps running.
    func testEndToolsEndsATerminableToolAndLeavesTheCommandRunning() async throws {
        // The shell starts its tool and waits for it, then runs on for a few seconds, as the command writes its record.
        let command = try startShell("sleep 60 & wait; sleep 5")
        defer { stop(command) }
        let reached = await waitUntil(timeout: .seconds(30), pollInterval: .milliseconds(10)) {
            !ProcessTreeTerminator.descendantProcessIDs(of: command.processIdentifier).isEmpty
        }
        XCTAssertTrue(reached, "the command never started its tool")
        let tools = ProcessTreeTerminator.descendantProcessIDs(of: command.processIdentifier)

        await ClassifierResultImportRun.endTools(of: command.processIdentifier)

        let gone = await waitUntil(timeout: .seconds(1), pollInterval: .milliseconds(10)) { Self.allGone(tools) }
        XCTAssertTrue(gone, "the tool ended on SIGTERM")
        XCTAssertTrue(command.isRunning, "the command itself is left running")
    }

    /// A tool that ignores SIGTERM is ended by SIGKILL after half a second, and the call takes about that long.
    func testEndToolsKillsAToolThatIgnoresSIGTERMAfterHalfASecond() async throws {
        // The subshell ignores SIGTERM before it becomes the tool, and ignored signals stay ignored across exec.
        let ready = root.appendingPathComponent("ready")
        let command = try startShell("(trap '' TERM; echo ready > '\(ready.path)'; exec sleep 60) & wait")
        defer { stop(command) }
        let reached = await waitUntil(timeout: .seconds(30), pollInterval: .milliseconds(10)) {
            FileManager.default.fileExists(atPath: ready.path)
                && !ProcessTreeTerminator.descendantProcessIDs(of: command.processIdentifier).isEmpty
        }
        XCTAssertTrue(reached, "the command never started its tool")
        let tools = ProcessTreeTerminator.descendantProcessIDs(of: command.processIdentifier)

        let started = ContinuousClock.now
        await ClassifierResultImportRun.endTools(of: command.processIdentifier)
        let elapsed = ContinuousClock.now - started

        let gone = await waitUntil(timeout: .seconds(1), pollInterval: .milliseconds(10)) { Self.allGone(tools) }
        XCTAssertTrue(gone, "SIGKILL ended the tool that ignored SIGTERM")
        XCTAssertGreaterThan(elapsed, .milliseconds(400), "the tool got its half second to end on SIGTERM")
        XCTAssertLessThan(elapsed, .milliseconds(1500), "the SIGKILL followed the half second")
    }

    // MARK: - The stand-in command

    private func startShell(_ script: String) throws -> Process {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", script]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        return process
    }

    /// Ends the shell and every process it still holds, so a failing case leaves nothing running.
    private func stop(_ command: Process) {
        for pid in ProcessTreeTerminator.descendantProcessIDs(of: command.processIdentifier) {
            kill(pid, SIGKILL)
        }
        if command.isRunning {
            command.terminate()
        }
    }

    private static func allGone(_ pids: [Int32]) -> Bool {
        pids.allSatisfy { !ProcessTreeTerminator.processExists(pid: $0) }
    }
}
