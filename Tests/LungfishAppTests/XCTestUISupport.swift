// XCTestUISupport.swift - Shared test helpers for LungfishAppTests
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import LungfishTestSupport
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
/// It forwards to the shared `waitUntil` of LungfishTestSupport, so its default is the standard
/// budget of that wait. That leaves room for the parallel unit tier, and the poll still returns
/// as soon as the condition holds.
@MainActor
func waitUntilCondition(
    timeout: TimeInterval = WaitBudget.standard.seconds,
    file: StaticString = #filePath,
    line: UInt = #line,
    _ condition: @escaping @MainActor () -> Bool
) async throws {
    let held = await LungfishTestSupport.waitUntil(timeout: .seconds(timeout)) { condition() }
    XCTAssertTrue(held, file: file, line: line)
}
