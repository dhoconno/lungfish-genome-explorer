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

    /// Clears the flag and posts `.lungfishDependencyReconciliationDidEnd`.
    ///
    /// Deliberately NOT `.lungfishDependencyReconciliationDidFinish`: that one means "the sheet
    /// is done and the receipt is settled" and is posted by the sheet on dismiss, which can be
    /// much later (or never, if the sheet is torn down by its host). Observers that only need
    /// to know conda is free again must key off `DidEnd`, or they latch.
    func end() {
        guard depth > 0 else { return }
        depth -= 1
        guard depth == 0 else { return }
        isApplying = false
        notificationCenter.post(name: .lungfishDependencyReconciliationDidEnd, object: nil)
    }
}

public extension Notification.Name {
    /// Posted when an Update Tools run begins touching managed environments.
    static let lungfishDependencyReconciliationDidStart = Notification.Name(
        "com.lungfish.dependencyReconciliationDidStart"
    )

    /// Posted when a run stops touching managed environments, whether or not the sheet is still
    /// on screen. Pairs with `DidStart`; use it to re-enable anything gated on conda being free.
    static let lungfishDependencyReconciliationDidEnd = Notification.Name(
        "com.lungfish.dependencyReconciliationDidEnd"
    )
}
