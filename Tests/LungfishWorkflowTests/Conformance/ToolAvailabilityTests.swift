// ToolAvailabilityTests.swift
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
import LungfishTestSupport

final class ToolAvailabilityTests: XCTestCase {
    func testSkipOrFailSkipsWithoutRequireFlag() throws {
        guard !ToolAvailability.requireTools else { throw XCTSkip("running in require mode") }
        XCTAssertThrowsError(try ToolAvailability.skipOrFail("nope")) { XCTAssertTrue($0 is XCTSkip) }
    }

    func testProcessRunnerCapturesOutput() throws {
        let r = try ProcessRunner.run(URL(fileURLWithPath: "/bin/echo"), ["hello"])
        XCTAssertEqual(r.status, 0); XCTAssertEqual(r.stdout.trimmingCharacters(in: .whitespacesAndNewlines), "hello")
    }

    func testPythonCanImportAnswersFromTheInterpretersExitStatusAndNeverThrows() throws {
        let folder = try TestTempDirectory.make(prefix: "python-probe")
        defer { TestTempDirectory.cleanup(folder) }
        func interpreter(_ body: String) throws -> URL {
            let url = folder.appendingPathComponent(UUID().uuidString)
            try "#!/bin/sh\n\(body)\n".write(to: url, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
            return url
        }
        let imports = try interpreter("exit 0")
        let lacksNumpy = try interpreter("echo 'ModuleNotFoundError: No module named numpy' >&2; exit 1")
        let hangs = try interpreter("exec sleep 20")
        XCTAssertTrue(ToolAvailability.pythonCanImport(["numpy"], interpreter: imports))
        XCTAssertFalse(ToolAvailability.pythonCanImport(["numpy"], interpreter: lacksNumpy))
        XCTAssertFalse(ToolAvailability.pythonCanImport(["numpy"], interpreter: folder.appendingPathComponent("absent")))
        XCTAssertFalse(ToolAvailability.pythonCanImport(["numpy"], interpreter: hangs, timeout: 1))
    }
}
