// BlastSearchClock.swift - The clock a BLAST search reads and sleeps on
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation

/// The clock a BLAST search reads and sleeps on.
///
/// Every due time of a search is wall clock, read from this and saved in its file. A test in process hands in a clock
/// it moves by hand, and a child process under a stand-in runs on a scaled clock (``BlastStandInState``), so 180 s can
/// be 0.3 s and no real wait in a test grows (ARCH-BLAST-RESILIENCE section 7).
package struct BlastSearchClock: Sendable {
    /// What time it is on this clock.
    package let now: @Sendable () -> Date
    /// Spends this many seconds of this clock's time.
    package let sleep: @Sendable (TimeInterval) async throws -> Void

    package init(
        now: @escaping @Sendable () -> Date,
        sleep: @escaping @Sendable (TimeInterval) async throws -> Void
    ) {
        self.now = now
        self.sleep = sleep
    }

    /// The wall clock and real sleeps, the only clock a release build has.
    package static let system = BlastSearchClock(
        now: { Date() },
        sleep: { try await Task.sleep(for: .seconds($0)) }
    )

    /// A clock that runs `scale` times as fast as `base`, and reads as `base` does at `anchor`.
    package static func scaled(_ scale: Double, anchor: Date, base: BlastSearchClock = .system) -> BlastSearchClock {
        BlastSearchClock(
            now: { anchor.addingTimeInterval(base.now().timeIntervalSince(anchor) * scale) },
            sleep: { try await base.sleep($0 / scale) }
        )
    }

    /// The clock this run's environment names, with `sharedFolder` from ``BlastStandInState/sharedFolder(environment:storageRoot:)``.
    /// With no stand-in, or a stand-in at the wall clock's speed, that is ``system``.
    package init(environment: [String: String], sharedFolder: URL) {
        guard let scale = BlastStandInState(environment: environment)?.timeScale, scale != 1 else {
            self = .system
            return
        }
        self = .scaled(scale, anchor: BlastStandInState.clockAnchor(in: sharedFolder))
    }
}
