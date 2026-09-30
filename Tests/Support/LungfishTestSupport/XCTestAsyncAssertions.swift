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

/// Waits until `condition` holds or `timeout` passes, polling on the clock.
///
/// Use this instead of a fixed number of `Task.yield()` calls or short sleeps
/// when a test waits for work on another executor. A fixed count finishes in
/// a few milliseconds on an idle machine but can run out before the work does
/// under the parallel unit gate. The poll ends as soon as the condition holds,
/// so a passing test takes no longer than before. The condition runs in the
/// caller's isolation, so it can read main-actor state.
///
/// - Returns: Whether the condition held before the timeout. Callers normally
///   ignore it and let their own assertions report the failure.
@discardableResult
public func waitUntil(
    timeout: Duration = .seconds(5),
    pollInterval: Duration = .milliseconds(10),
    isolation: isolated (any Actor)? = #isolation,
    _ condition: () async throws -> Bool
) async rethrows -> Bool {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while true {
        if try await condition() { return true }
        if clock.now >= deadline { return false }
        try? await Task.sleep(for: pollInterval)
    }
}
