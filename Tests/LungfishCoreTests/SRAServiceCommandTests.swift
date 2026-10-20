// SRAServiceCommandTests.swift - How SRAService runs an SRA Toolkit command
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.13 lane 13.11. SRAService ran prefetch and fasterq-dump on a raw Process and ended a cancelled
// run's tree with its own /bin/ps walk. It now runs them on ToolProcess. These cases run shell stand-ins
// for the tools and pin what the callers read: the exit code and both streams, a CancellationError after
// a cancel, and no helper process left behind (SWIFT 3).

import Foundation
import XCTest
import LungfishTestSupport
@testable import LungfishCore

final class SRAServiceCommandTests: XCTestCase {
    private var scratch: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        scratch = try TestTempDirectory.make(prefix: "sra-command")
    }

    override func tearDownWithError() throws {
        TestTempDirectory.cleanup(scratch)
        try super.tearDownWithError()
    }

    private func writeTool(_ name: String, body: String) throws -> URL {
        let url = scratch.appendingPathComponent(name)
        try ("#!/bin/sh\n" + body + "\n").write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }

    /// The exit code and both streams come back as the tool wrote them, also for a nonzero exit.
    func testARunReturnsTheExitCodeAndBothStreams() async throws {
        let tool = try writeTool("fake-fasterq-dump", body: "echo \"out:$1\"\necho err-text >&2\nexit 3")

        let result = try await SRAService().runCommand(tool.path, arguments: ["x"])

        XCTAssertEqual(result.exitCode, 3)
        XCTAssertEqual(result.stdout, "out:x\n")
        XCTAssertEqual(result.stderr, "err-text\n")
    }

    /// A cancel ends the tool and the helper it started, and the run throws `CancellationError`.
    /// The tool backgrounds a `sleep` and waits on it, as a launcher script that starts a worker does.
    func testACancelEndsTheHelperTheToolStartedAndThrowsCancellationError() async throws {
        let pidFile = scratch.appendingPathComponent("helper.pid")
        let tool = try writeTool("fake-prefetch", body: "sleep 300 &\necho $! > \"$1\"\nwait")
        let service = SRAService()
        let path = tool.path
        let pidPath = pidFile.path
        let run = Task { try await service.runCommand(path, arguments: [pidPath]) }

        var helper: Int32?
        let started = Date().addingTimeInterval(30)
        while helper == nil, Date() < started {
            if let text = try? String(contentsOf: pidFile, encoding: .utf8),
               let pid = Int32(text.trimmingCharacters(in: .whitespacesAndNewlines)) {
                helper = pid
            } else {
                try await Task.sleep(for: .milliseconds(50))
            }
        }
        let helperPID = try XCTUnwrap(helper, "the tool never started its helper")
        defer { kill(helperPID, SIGKILL) }

        run.cancel()
        do {
            _ = try await run.value
            XCTFail("a cancelled run must throw")
        } catch is CancellationError {
            // The run ends with CancellationError, as callers expect.
        }

        let ended = Date().addingTimeInterval(10)
        while ProcessTreeTerminator.processExists(pid: helperPID), Date() < ended {
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertFalse(ProcessTreeTerminator.processExists(pid: helperPID), "the cancel left the helper running")
    }

    /// A run whose task is already cancelled throws and starts nothing.
    func testARunCancelledBeforeItStartsThrowsAndStartsNothing() async throws {
        let marker = scratch.appendingPathComponent("started")
        let tool = try writeTool("fake-tool", body: "echo started > \"$1\"")
        let service = SRAService()
        let path = tool.path
        let markerPath = marker.path
        let run = Task { () -> Bool in
            withUnsafeCurrentTask { $0?.cancel() }
            do {
                _ = try await service.runCommand(path, arguments: [markerPath])
                return false
            } catch {
                return error is CancellationError
            }
        }

        let threwCancellation = await run.value

        XCTAssertTrue(threwCancellation)
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
    }
}
