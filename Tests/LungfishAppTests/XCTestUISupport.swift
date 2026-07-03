// XCTestUISupport.swift - Shared test helpers for LungfishAppTests
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import XCTest

// MARK: - NSView Traversal

extension NSView {
    /// Returns the first descendant of the given type in a depth-first traversal,
    /// or `self` if it already matches.
    func firstDescendant<T: NSView>(of type: T.Type) -> T? {
        if let typed = self as? T { return typed }
        for subview in subviews {
            if let match = subview.firstDescendant(of: type) { return match }
        }
        return nil
    }
}

// MARK: - Async Polling

/// Polls `condition` every 10 ms until it returns `true` or `timeout` elapses.
///
/// On timeout, fires an `XCTAssertTrue` at the call site so the test fails with a useful line number.
@MainActor
func waitUntilCondition(
    timeout: TimeInterval = 2.0,
    file: StaticString = #filePath,
    line: UInt = #line,
    _ condition: @escaping @MainActor () -> Bool
) async throws {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if condition() { return }
        try await Task.sleep(for: .milliseconds(10))
    }
    XCTAssertTrue(condition(), file: file, line: line)
}
