// SidebarBackstopRescanThrottle.swift - coalesces activation-driven sidebar rescans
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation

/// Decides whether an activation-driven backstop rescan of the sidebar may run.
///
/// NEW-02: FSEvents occasionally misses external changes (seen with the app
/// backgrounded and several windows open). The sidebar rescans the project
/// when its window becomes key or the app becomes active. Both notifications
/// usually arrive together, so this throttle lets at most one rescan through
/// per `minimumInterval` and never while one is still running.
struct SidebarBackstopRescanThrottle {
    let minimumInterval: Duration
    private(set) var lastFired: ContinuousClock.Instant?
    private(set) var isInFlight = false

    init(minimumInterval: Duration = .seconds(2)) {
        self.minimumInterval = minimumInterval
    }

    /// Returns `true` and records the fire when a rescan may start now.
    mutating func shouldFire(at now: ContinuousClock.Instant) -> Bool {
        guard !isInFlight else { return false }
        if let lastFired, now - lastFired < minimumInterval { return false }
        lastFired = now
        isInFlight = true
        return true
    }

    mutating func finish() {
        isInFlight = false
    }

    mutating func reset() {
        lastFired = nil
        isInFlight = false
    }
}
