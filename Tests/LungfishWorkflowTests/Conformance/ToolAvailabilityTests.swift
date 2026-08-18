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
}
