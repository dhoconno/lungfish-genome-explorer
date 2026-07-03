// SampleColumnWindow.swift - Display-only cap on instantiated per-sample columns
// Copyright (c) 2025 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation

/// A display-only cap on how many per-sample COLUMNS a matrix/heatmap view
/// instantiates.
///
/// AppKit does not virtualize table columns, so a one-column-per-sample fan-out
/// (50-200+ samples) instantiates that many column and cell views up front. This
/// helper windows the *instantiated* columns while callers keep their FULL logical
/// sample set intact for filter, sort, selection, and — critically — scientific
/// export and annotation-target computation.
///
/// ## Separation contract
///
/// This type answers exactly one question: "given the full ordered sample list,
/// which sample columns should be instantiated right now?" (``windowedSamples(from:)``).
/// It must NEVER be consulted by export, annotation, selection, sort, or filter
/// logic — those always read the caller's full sample set. The window is a
/// display-only slice layered on top.
public struct SampleColumnWindow: Equatable, Sendable {

    /// Default cap on instantiated sample columns.
    public static let defaultLimit = 60

    /// Maximum number of sample columns to instantiate while windowing is active.
    public let limit: Int

    /// When `true`, every sample column is instantiated regardless of ``limit``
    /// (the "Show all" affordance).
    public private(set) var showsAll: Bool

    public init(limit: Int = SampleColumnWindow.defaultLimit, showsAll: Bool = false) {
        self.limit = max(1, limit)
        self.showsAll = showsAll
    }

    /// Reveal every sample column (defeat the cap).
    public mutating func revealAll() {
        showsAll = true
    }

    /// Re-apply the cap after it was revealed.
    public mutating func reset() {
        showsAll = false
    }

    /// Whether the given full sample list would be capped by this window.
    public func caps(_ fullSamples: [String]) -> Bool {
        !showsAll && fullSamples.count > limit
    }

    /// The display-only slice of sample names to instantiate as columns.
    ///
    /// Returns the full list unchanged when "show all" is active or the count is
    /// within the cap; otherwise the leading ``limit`` samples in the caller's
    /// order. This is the ONLY method column-instantiation should call; nothing
    /// else (export/annotation/selection/sort/filter) may consult it.
    public func windowedSamples(from fullSamples: [String]) -> [String] {
        guard caps(fullSamples) else { return fullSamples }
        return Array(fullSamples.prefix(limit))
    }

    /// The count of instantiated columns for the given full sample list.
    public func windowedCount(for fullSamples: [String]) -> Int {
        caps(fullSamples) ? limit : fullSamples.count
    }
}
