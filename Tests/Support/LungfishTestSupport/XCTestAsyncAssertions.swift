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
/// The default `timeout` is the duration of ``WaitBudget/standard``. A wait for
/// work that a loaded Mac can stall for long names a longer budget through
/// ``waitUntil(budget:pollInterval:isolation:_:)``.
///
/// - Returns: Whether the condition held before the timeout. Callers normally
///   ignore it and let their own assertions report the failure.
@discardableResult
public func waitUntil(
    timeout: Duration = WaitBudget.standard.duration,
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

/// Waits on a named budget such as ``WaitBudget/lookup``, and is otherwise the
/// same wait as ``waitUntil(timeout:pollInterval:isolation:_:)``.
///
/// - Returns: Whether the condition held before the budget ran out.
@discardableResult
public func waitUntil(
    budget: WaitBudget,
    pollInterval: Duration = .milliseconds(10),
    isolation: isolated (any Actor)? = #isolation,
    _ condition: () async throws -> Bool
) async rethrows -> Bool {
    try await waitUntil(timeout: budget.duration, pollInterval: pollInterval, isolation: isolation, condition)
}

/// A named wait budget for ``waitUntil(budget:pollInterval:isolation:_:)``.
///
/// A wait that names nothing gets ``standard``. A wait for work that a loaded
/// Mac can stall for long names a longer budget such as ``lookup``. The answer
/// to a stalled tier is then to raise that one budget here, and not to edit a
/// literal in every class that waits. A single test raises a budget for itself
/// with ``raised(to:)``, which keeps the name and never shortens the wait.
public struct WaitBudget: Sendable, Hashable {
    /// The name of the budget, as tests and reports spell it.
    public let name: String

    /// How long a wait on this budget keeps checking before it gives up.
    public let duration: Duration

    public init(name: String, duration: Duration) {
        self.name = name
        self.duration = duration
    }

    /// The budget of a wait that names nothing, 5 s. It leaves room for the
    /// parallel unit tier and ends as soon as the condition holds.
    public static let standard = WaitBudget(name: "standard", duration: .seconds(5))

    /// The budget of a provenance lookup and of any other wait for work that a
    /// stalled Mac can hold up, 60 s. Phase 2.10 raised 13 such waits to this
    /// value and landing 23 of Phase 2.12 raised 14 more, one commit for each
    /// stall.
    public static let lookup = WaitBudget(name: "lookup", duration: .seconds(60))

    /// This budget raised to `duration` when that is longer, with the same name.
    public func raised(to duration: Duration) -> WaitBudget {
        WaitBudget(name: name, duration: max(self.duration, duration))
    }

    /// The duration in seconds, for the waits that still take a `TimeInterval`.
    public var seconds: TimeInterval {
        let parts = duration.components
        return TimeInterval(parts.seconds) + TimeInterval(parts.attoseconds) / 1e18
    }

    /// The duration in nanoseconds, for the waits that still take a `UInt64`.
    public var nanoseconds: UInt64 {
        let parts = duration.components
        guard parts.seconds >= 0 else { return 0 }
        return UInt64(parts.seconds) * 1_000_000_000 + UInt64(parts.attoseconds / 1_000_000_000)
    }
}
