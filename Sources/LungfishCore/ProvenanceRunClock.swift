// ProvenanceRunClock.swift - Run times for provenance that a wall-clock step cannot reverse
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation

/// Times one run or step for its provenance record.
///
/// `startedAt` is the wall-clock time when the run began. Every later reading
/// adds the time elapsed on `ContinuousClock`, which never steps back, so
/// `now` is never earlier than `startedAt` and `elapsed` is never negative,
/// even when the wall clock is stepped during the run by an NTP correction,
/// a manual change or a test harness.
///
/// Runs used to stamp their start and end with two `Date()` calls. A 63 ms
/// backward step between them made `ProvenanceRunBuilder.complete` reject a
/// Delete Annotation that had already succeeded, because the end came before
/// the start. Start a clock where the run starts, and take the run's end time
/// and wall time from the clock.
///
/// Only times this process measures go through the clock. A record read back
/// from disk keeps every strict check on its time range and wall time.
public struct ProvenanceRunClock: Sendable {
    /// The wall-clock time when the run began.
    public let startedAt: Date

    private let startInstant: ContinuousClock.Instant
    private let monotonicNow: @Sendable () -> ContinuousClock.Instant

    /// Starts a clock at the current time.
    public init() {
        self.init(source: .current)
    }

    /// Starts a clock now for a run whose start time an injected wall clock
    /// has just read. The run is measured on the monotonic clock from this
    /// moment, so create the clock where the start time is read.
    public init(startedAt: Date) {
        let source = ProvenanceTimeSource.current
        self.startedAt = startedAt
        startInstant = source.monotonicNow()
        monotonicNow = source.monotonicNow
    }

    /// Starts a clock that reads `source`. Tests pass a source whose wall
    /// clock they step.
    package init(source: ProvenanceTimeSource) {
        startedAt = source.wallClockNow()
        startInstant = source.monotonicNow()
        monotonicNow = source.monotonicNow
    }

    /// Seconds since `startedAt` on the monotonic clock. Never negative.
    public var elapsed: TimeInterval {
        let components = startInstant.duration(to: monotonicNow()).components
        return max(0, Double(components.seconds) + Double(components.attoseconds) * 1e-18)
    }

    /// The current time of the run, `startedAt` plus `elapsed`. Never earlier
    /// than `startedAt`.
    public var now: Date {
        startedAt.addingTimeInterval(elapsed)
    }
}

extension ProvenanceRunClock: Equatable {
    /// Two clocks are equal when they started at the same wall-clock time and
    /// the same monotonic instant, so a request that carries one stays Equatable.
    public static func == (lhs: ProvenanceRunClock, rhs: ProvenanceRunClock) -> Bool {
        lhs.startedAt == rhs.startedAt && lhs.startInstant == rhs.startInstant
    }
}

/// Where a ``ProvenanceRunClock`` reads the wall clock and the monotonic clock.
package struct ProvenanceTimeSource: Sendable {
    package let wallClockNow: @Sendable () -> Date
    package let monotonicNow: @Sendable () -> ContinuousClock.Instant

    package init(
        wallClockNow: @escaping @Sendable () -> Date,
        monotonicNow: @escaping @Sendable () -> ContinuousClock.Instant
    ) {
        self.wallClockNow = wallClockNow
        self.monotonicNow = monotonicNow
    }

    /// The system wall clock and `ContinuousClock`.
    package static let system = ProvenanceTimeSource(
        wallClockNow: { Date() },
        monotonicNow: { ContinuousClock.now }
    )

    /// Replaces the source for the current task and the calls it makes, so a
    /// test can step the wall clock in the middle of a run without sleeping.
    @TaskLocal package static var override: ProvenanceTimeSource?

    /// The source every new clock reads, ``system`` unless a test has
    /// overridden it for the current task.
    package static var current: ProvenanceTimeSource {
        override ?? .system
    }
}
