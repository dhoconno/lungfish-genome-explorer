// DependencyReconciliationActivity.swift - App-wide "conda is busy" flag for tool reconciliation
// Copyright (c) 2025 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation

/// Whether an Update Tools run is currently touching conda environments.
///
/// The reconciler and the Welcome window's required-setup installer both drive `CondaManager`
/// against the same environments. Running them at once is not safe: one can be removing an
/// environment while the other is creating it. This flag lets the other entry points disable
/// their install affordances for the duration rather than discovering the conflict halfway
/// through a solve.
///
/// Notifications are posted alongside the flag for observers that are not SwiftUI views (the
/// Welcome view model is `ObservableObject`, not `@Observable`).
@MainActor
@Observable
final class DependencyReconciliationActivity {
    static let shared = DependencyReconciliationActivity()

    /// True while a reconciliation run is in flight.
    private(set) var isApplying = false

    /// Nesting depth, so overlapping callers cannot clear the flag out from under each other.
    @ObservationIgnored private var depth = 0

    private let notificationCenter: NotificationCenter

    init(notificationCenter: NotificationCenter = .default) {
        self.notificationCenter = notificationCenter
    }

    func begin() {
        depth += 1
        guard depth == 1 else { return }
        isApplying = true
        notificationCenter.post(name: .lungfishDependencyReconciliationDidStart, object: nil)
    }

    /// Clears the flag. Deliberately does NOT post `.lungfishDependencyReconciliationDidFinish`:
    /// that notification means "the sheet is done and the receipt is settled", and the sheet
    /// posts it when the user dismisses. Posting here too would fire it while the results are
    /// still on screen.
    func end() {
        guard depth > 0 else { return }
        depth -= 1
        guard depth == 0 else { return }
        isApplying = false
    }
}

public extension Notification.Name {
    /// Posted when an Update Tools run begins touching managed environments.
    static let lungfishDependencyReconciliationDidStart = Notification.Name(
        "com.lungfish.dependencyReconciliationDidStart"
    )
}
