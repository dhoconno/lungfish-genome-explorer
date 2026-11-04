// BlastHandClock.swift - A BLAST search clock a test moves by hand
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishCore
import Synchronization

/// A ``BlastSearchClock`` that moves only when a test says so, so no test waits for real.
///
/// By default a sleep holds until ``advance(by:)`` passes its due time. With `advancesBySleeping` a sleep moves the
/// clock itself and returns at once, which runs a whole search schedule in no time and leaves the waits in ``sleeps``.
package final class BlastHandClock: Sendable {
    private struct Sleeper {
        let id: UUID
        let due: Date
        let continuation: CheckedContinuation<Void, any Error>
    }

    private struct State {
        var now: Date
        var sleeps: [TimeInterval] = []
        var sleepers: [Sleeper] = []
    }

    private let state: Mutex<State>
    private let advancesBySleeping: Bool

    /// - Parameters:
    ///   - start: What the clock reads first. The default is a fixed date, so a run reads the same on any day.
    ///   - advancesBySleeping: Whether a sleep moves the clock by itself.
    package init(start: Date = Date(timeIntervalSinceReferenceDate: 800_000_000), advancesBySleeping: Bool = false) {
        self.state = Mutex(State(now: start))
        self.advancesBySleeping = advancesBySleeping
    }

    /// What the clock reads.
    package var now: Date {
        state.withLock { $0.now }
    }

    /// Every wait asked of the clock so far, in seconds and in order.
    package var sleeps: [TimeInterval] {
        state.withLock { $0.sleeps }
    }

    /// How many sleeps are waiting for the clock to pass them.
    package var pendingSleeps: Int {
        state.withLock { $0.sleepers.count }
    }

    /// The clock to hand to the code under test.
    package var clock: BlastSearchClock {
        BlastSearchClock(now: { self.now }, sleep: { try await self.sleep($0) })
    }

    /// Moves the clock on and ends every sleep it has now passed.
    package func advance(by seconds: TimeInterval) {
        let due = state.withLock { state -> [Sleeper] in
            state.now = state.now.addingTimeInterval(seconds)
            let now = state.now
            let due = state.sleepers.filter { $0.due <= now }
            state.sleepers.removeAll { $0.due <= now }
            return due
        }
        for sleeper in due { sleeper.continuation.resume() }
    }

    private func sleep(_ seconds: TimeInterval) async throws {
        try Task.checkCancellation()
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                let endsNow = state.withLock { state -> Bool in
                    state.sleeps.append(seconds)
                    if advancesBySleeping { state.now = state.now.addingTimeInterval(seconds) }
                    if advancesBySleeping || seconds <= 0 { return true }
                    state.sleepers.append(
                        Sleeper(id: id, due: state.now.addingTimeInterval(seconds), continuation: continuation))
                    return false
                }
                if endsNow { continuation.resume() }
            }
        } onCancel: {
            let cancelled = state.withLock { state -> Sleeper? in
                guard let index = state.sleepers.firstIndex(where: { $0.id == id }) else { return nil }
                return state.sleepers.remove(at: index)
            }
            cancelled?.continuation.resume(throwing: CancellationError())
        }
    }
}
