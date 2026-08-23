// ReadBudgetState.swift - Visible-read budget bookkeeping and its banner text
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation

/// What the viewport is actually showing versus what the window contains.
///
/// The read track has a display budget (`ReadViewportPolicy.defaultVisibleReadBudget`)
/// because an extreme-depth window — a microsatellite every ATC-repeat read maps
/// to, at ~600,000x — returns more reads than can be packed or perceived. When
/// the budget bites, the viewport draws a uniform sample and this state carries
/// the numbers the banner needs so the display never silently lies about how
/// much data is on screen.
struct ReadBudgetState: Equatable {

    /// Reads actually held for display after sampling.
    var displayedReads: Int

    /// Reads believed to be in the fetch window. Exact when the provider
    /// reported a count; otherwise derived from the depth track, in which case
    /// `isEstimated` is true and the banner prefixes it with "~".
    var totalReads: Int

    /// Whether `totalReads` is a derived estimate rather than a counted value.
    var isEstimated: Bool

    /// True once the user chose "Load all" for this window, so the banner stops
    /// offering an action it has already performed.
    var loadedAll: Bool

    /// Whether the sample is smaller than the window's contents.
    var isSampled: Bool { !loadedAll && totalReads > displayedReads }

    static let none = ReadBudgetState(
        displayedReads: 0, totalReads: 0, isEstimated: false, loadedAll: false
    )

    /// Banner text stating exactly what is and is not sampled.
    ///
    /// The second clause is not decoration: depth, coverage, and consensus come
    /// from separate whole-BAM queries that never see the budget, and a user
    /// looking at a sampled pileup needs to know the coverage curve under it is
    /// still complete.
    var bannerMessage: String? {
        guard isSampled else { return nil }
        let total = isEstimated ? "~\(totalReads.formatted())" : totalReads.formatted()
        return "Showing \(displayedReads.formatted()) of \(total) reads in view "
            + "\u{00B7} depth, coverage and consensus use all reads"
    }

    /// Title for the banner's escape hatch.
    static let loadAllActionTitle = "Load all"

    /// Estimates the read count in a window from the depth track, used when no
    /// exact count is available.
    ///
    /// `mean depth x window span / mean read length` is the standard identity;
    /// it is only ever shown with a "~" prefix.
    static func estimateReadCount(
        meanDepth: Double,
        windowSpan: Int,
        meanReadLength: Double
    ) -> Int? {
        guard meanDepth > 0, windowSpan > 0, meanReadLength >= 1 else { return nil }
        let estimate = meanDepth * Double(windowSpan) / meanReadLength
        guard estimate.isFinite, estimate >= 0 else { return nil }
        return Int(estimate.rounded())
    }
}

/// Progress reported by an in-flight read fetch/pack, shown in the loading
/// badge so an extreme-depth window does not look frozen.
enum ReadLoadPhase: Equatable {

    /// Reads are streaming in from the provider. `readsSoFar` is nil when the
    /// provider delivers its result in one shot and cannot report partials.
    case fetching(readsSoFar: Int?)

    /// Reads are in hand and the layout is being packed off the main thread.
    case packing(readCount: Int)

    /// Badge text for this phase. Callers append nothing; this is the full
    /// string, including the cancel hint.
    var badgeMessage: String {
        switch self {
        case .fetching(let readsSoFar):
            if let readsSoFar, readsSoFar > 0 {
                return "Loading mapped reads\u{2026} \(readsSoFar.formatted())"
            }
            return "Loading mapped reads\u{2026}"
        case .packing(let readCount):
            return "Packing \(readCount.formatted()) reads\u{2026}"
        }
    }

    /// Suffix appended to the badge when a cancel affordance is live.
    static let cancelHint = "  (esc to cancel)"
}
