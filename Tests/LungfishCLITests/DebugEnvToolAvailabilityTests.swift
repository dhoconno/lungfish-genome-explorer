// DebugEnvToolAvailabilityTests.swift - The tool check of `lungfish-cli debug env`
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.13 lane 13.11. The check found a tool with `/usr/bin/which` and ran `<tool> --version` on a raw
// Process with no limit. It now searches the PATH string with no process and asks for the version on
// ToolProcess within a timeout. These cases run shell stand-ins. The check blocks its thread, so each
// case runs it off the main thread.

import Foundation
import XCTest
@testable import LungfishCLI

final class DebugEnvToolAvailabilityTests: XCTestCase {
    private var scratch: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("debug-env-tool-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: scratch)
        try super.tearDownWithError()
    }

    @discardableResult
    private func writeTool(_ name: String, body: String, executable: Bool = true) throws -> URL {
        let url = scratch.appendingPathComponent(name)
        try ("#!/bin/sh\n" + body + "\n").write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: executable ? 0o755 : 0o644],
            ofItemAtPath: url.path
        )
        return url
    }

    private func check(
        _ tool: String,
        versionTimeout: Duration = .seconds(30)
    ) async -> (available: Bool, version: String?, path: String?) {
        let searchPath = scratch.path
        return await Task.detached {
            EnvSubcommand.toolAvailability(tool, searchPath: searchPath, versionTimeout: versionTimeout)
        }.value
    }

    func testAToolOnThePathReportsItsPathAndTheFirstLineOfItsVersion() async throws {
        let tool = try writeTool("stubtool", body: "echo 'stubtool 1.2.3'\necho 'a second line'")

        let status = await check("stubtool")

        XCTAssertTrue(status.available)
        XCTAssertEqual(status.version, "stubtool 1.2.3")
        XCTAssertEqual(status.path, tool.path)
    }

    func testAToolThatPrintsItsVersionOnStandardErrorReportsIt() async throws {
        try writeTool("errtool", body: "echo 'errtool 9.9' >&2")

        let status = await check("errtool")

        XCTAssertTrue(status.available)
        XCTAssertEqual(status.version, "errtool 9.9")
    }

    func testAToolThatIsNotOnThePathIsNotAvailable() async {
        let status = await check("missingtool")

        XCTAssertFalse(status.available)
        XCTAssertNil(status.version)
        XCTAssertNil(status.path)
    }

    func testAFileOfTheSameNameWithoutAnExecutePermissionIsNotAvailable() async throws {
        try writeTool("plainfile", body: "echo 'plainfile 1.0'", executable: false)

        let status = await check("plainfile")

        XCTAssertFalse(status.available)
        XCTAssertNil(status.path)
    }

    /// A tool that never answers `--version` is still reported as available, with no version, once the
    /// bound runs out, and its process is gone.
    func testAToolThatNeverAnswersIsAvailableWithNoVersionAndLeavesNoProcess() async throws {
        let pidFile = scratch.appendingPathComponent("hung.pid")
        let tool = try writeTool("hungtool", body: "echo $$ > '\(pidFile.path)'\nexec sleep 3600")
        defer {
            if let text = try? String(contentsOf: pidFile, encoding: .utf8),
               let pid = Int32(text.trimmingCharacters(in: .whitespacesAndNewlines)) {
                kill(pid, SIGKILL)
            }
        }

        let status = await check("hungtool", versionTimeout: .seconds(4))

        XCTAssertTrue(status.available)
        XCTAssertNil(status.version)
        XCTAssertEqual(status.path, tool.path)
        let text = try XCTUnwrap(try? String(contentsOf: pidFile, encoding: .utf8), "the stand-in never started")
        let pid = try XCTUnwrap(Int32(text.trimmingCharacters(in: .whitespacesAndNewlines)))
        XCTAssertEqual(kill(pid, 0), -1, "the stand-in still runs after the timeout")
    }
}
