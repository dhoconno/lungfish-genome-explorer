// ToolProcessStdinTests.swift - Stdin fed by ToolProcess, from bytes given up front and from the caller while the process runs
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import XCTest
@testable import LungfishCore
import LungfishTestSupport

/// Phase 2.13 lane 13.05. The first tests pin the `.data` feed as it was
/// before caller-fed stdin, so the writer it now shares with `.stream` keeps
/// its behaviour.
final class ToolProcessStdinTests: XCTestCase {
    private typealias Fixtures = ToolProcessFixtures

    /// Far more than a pipe holds, so the feed is still writing when the child exits.
    private static let largeInput = Data(repeating: UInt8(ascii: "x"), count: 4 * 1024 * 1024)

    // MARK: - The .data feed

    /// A child that exits without reading ends the feed. The broken pipe
    /// reaches neither the child's result nor this process as SIGPIPE.
    func testDataFeedEndsWhenTheChildExitsWithoutReading() async throws {
        let result = try await ToolProcess.run(Fixtures.shell("exit 0", stdin: .data(Self.largeInput)))
        XCTAssertEqual(result.termination, .exited(code: 0))
        XCTAssertTrue(result.isSuccess)
    }

    /// A child that reads a few bytes and exits ends the feed the same way,
    /// and what it read is its output.
    func testDataFeedEndsWhenTheChildExitsAfterReadingAFewBytes() throws {
        let result = try ToolProcess.runBlocking(Fixtures.shell("head -c 3", stdin: .data(Self.largeInput)))
        XCTAssertEqual(result.termination, .exited(code: 0))
        XCTAssertEqual(result.stdoutText, "xxx")
        XCTAssertTrue(result.isSuccess)
    }

    /// Every byte reaches a child that reads to end of file, and the feed's
    /// close gives it that end of file.
    func testDataFeedDeliversEveryByteAndThenEndOfFile() async throws {
        let result = try await ToolProcess.run(Fixtures.shell("wc -c", stdin: .data(Self.largeInput)))
        XCTAssertEqual(result.stdoutText.trimmingCharacters(in: .whitespacesAndNewlines), "\(Self.largeInput.count)")
        XCTAssertTrue(result.isSuccess)
    }
}
