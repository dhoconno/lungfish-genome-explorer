// XCTestAsyncAssertions.swift - Async-aware XCTest assertion helpers
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest

/// Asserts that an async expression throws, and hands the thrown error to a handler.
///
/// `XCTAssertThrowsError` predates async/await and cannot await its expression, so
/// async throwing calls need this shim. Several test targets had grown private copies;
/// this is the shared one.
///
/// - Parameters:
///   - expression: The async expression expected to throw.
///   - message: Failure message used when the expression does not throw.
///   - errorHandler: Receives the thrown error for further assertions.
public func XCTAssertThrowsErrorAsync<T>(
    _ expression: @autoclosure () async throws -> T,
    _ message: @autoclosure () -> String = "Expected expression to throw",
    file: StaticString = #filePath,
    line: UInt = #line,
    _ errorHandler: (Error) -> Void = { _ in }
) async {
    do {
        _ = try await expression()
        XCTFail(message(), file: file, line: line)
    } catch {
        errorHandler(error)
    }
}
