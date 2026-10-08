// SteppedTimeSource.swift - A provenance time source whose wall clock a test steps
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishCore
import Synchronization

/// A ``ProvenanceTimeSource`` whose clocks move only when the test moves them.
///
/// ``advance(by:)`` lets time pass on both clocks. ``stepWallClock(by:)``
/// moves the wall clock alone, as an NTP correction or a manual clock change
/// does, and ``stepWallClockAfterNextRead(by:)`` lands that step just after
/// the next wall-clock read, between the start and the end of a run.
package final class SteppedTimeSource: Sendable {
    private struct State {
        var wallClock: Date
        var monotonic: ContinuousClock.Instant
        var stepAfterNextWallClockRead: TimeInterval?
    }

    private let state: Mutex<State>

    package init(startingAt wallClock: Date) {
        state = Mutex(State(wallClock: wallClock, monotonic: ContinuousClock.now, stepAfterNextWallClockRead: nil))
    }

    /// Lets `seconds` pass on the wall clock and the monotonic clock.
    package func advance(by seconds: TimeInterval) {
        state.withLock {
            $0.wallClock = $0.wallClock.addingTimeInterval(seconds)
            $0.monotonic = $0.monotonic.advanced(by: .seconds(seconds))
        }
    }

    /// Moves the wall clock alone by `seconds`, back when negative.
    package func stepWallClock(by seconds: TimeInterval) {
        state.withLock { $0.wallClock = $0.wallClock.addingTimeInterval(seconds) }
    }

    /// Moves the wall clock alone by `seconds` right after the next read of it.
    package func stepWallClockAfterNextRead(by seconds: TimeInterval) {
        state.withLock { $0.stepAfterNextWallClockRead = seconds }
    }

    package var source: ProvenanceTimeSource {
        ProvenanceTimeSource(
            wallClockNow: {
                self.state.withLock { state in
                    let reading = state.wallClock
                    if let step = state.stepAfterNextWallClockRead {
                        state.wallClock = state.wallClock.addingTimeInterval(step)
                        state.stepAfterNextWallClockRead = nil
                    }
                    return reading
                }
            },
            monotonicNow: { self.state.withLock { $0.monotonic } }
        )
    }

    /// Runs `body` with every new ``ProvenanceRunClock`` in the task reading this source.
    package func override<Result>(_ body: () async throws -> Result) async rethrows -> Result {
        try await ProvenanceTimeSource.$override.withValue(source, operation: body)
    }

    /// Runs the synchronous `body` with every new ``ProvenanceRunClock`` reading this source.
    package func override<Result>(_ body: () throws -> Result) rethrows -> Result {
        try ProvenanceTimeSource.$override.withValue(source, operation: body)
    }
}
