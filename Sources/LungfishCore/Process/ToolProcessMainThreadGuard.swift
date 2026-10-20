// ToolProcessMainThreadGuard.swift - The debug app's trap of a blocking ToolProcess call on the main thread
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import Synchronization

/// Traps a blocking ToolProcess call on the main thread of a debug app. Only the app arms it, because XCTest runs a
/// synchronous test method on the main thread (ToolProcessMainQueueMeasureTests), where a wait hangs no window.
///
/// `runBlocking`, both `waitBlocking` calls, `read(upTo:)` and `writeBlocking` call ``check(_:)`` first. A release
/// build compiles every check to nothing (Phase 2.13 lane 13.05, SWIFT ruling on M3, vote V2-3).
package enum ToolProcessMainThreadGuard {
    private struct State {
        var armed = false
        var recorder: (@Sendable (String) -> Void)?
    }
    private static let state = Mutex(State())

    /// Called once by the debug app before its delegate and run loop start.
    package static func arm() {
        #if DEBUG
        state.withLock { $0.armed = true }
        #endif
    }

    /// A test sees the check fire through `recorder` in place of the trap. Nil stops it.
    package static func record(into recorder: (@Sendable (String) -> Void)?) {
        #if DEBUG
        state.withLock { $0.recorder = recorder }
        #endif
    }

    static func check(_ call: String) {
        #if DEBUG
        guard Thread.isMainThread else { return }
        let (armed, recorder) = state.withLock { ($0.armed, $0.recorder) }
        if let recorder {
            recorder(call)
        } else if armed {
            dispatchPrecondition(condition: .notOnQueue(.main))
        }
        #endif
    }
}
