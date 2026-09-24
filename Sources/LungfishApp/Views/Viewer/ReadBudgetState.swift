// ReadBudgetState.swift - Displayed-depth cap bookkeeping and its banner text
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation

/// What the viewport is actually showing versus what the window contains.
///
/// The read track caps displayed depth (`ReadViewportPolicy.defaultMaxDisplayedDepth`,
/// owner decision D9): regions deeper than the cap are subsampled to about the
/// cap and every other region shows every read. This state carries what the
/// banner needs so a thinned pileup never passes for a complete one.
struct ReadBudgetState: Equatable {

    /// Reads actually held for display.
    var displayedReads: Int

    /// Reads believed to be in the fetch window. Exact when nothing was
    /// sampled. Otherwise it is an estimate, `isEstimated` is true, and the
    /// banner prefixes it with "~".
    var totalReads: Int

    /// Whether `totalReads` is a derived estimate rather than a counted value.
    var isEstimated: Bool

    /// True once the user chose "Load all" for this window, so the banner stops
    /// offering an action it has already performed.
    var loadedAll: Bool

    /// The displayed-depth cap actually applied when some region was thinned,
    /// or nil when every region is shown in full. It can sit below the
    /// configured cap when the transport budget forced it lower.
    var cappedDepth: Int? = nil

    /// Number of alignment tracks merged into the view. Each track is capped
    /// on its own, so with several tracks the banner says "per track".
    var trackCount: Int = 1

    /// True when the fetch hit its transport safety cap before finishing the
    /// window, so even the sample may be incomplete.
    var isTransportTruncated: Bool = false

    /// Whether the view shows fewer reads than the window holds.
    var isSampled: Bool { !loadedAll && (cappedDepth != nil || isTransportTruncated) }

    static let none = ReadBudgetState(
        displayedReads: 0, totalReads: 0, isEstimated: false, loadedAll: false
    )

    /// Banner text stating exactly what is and is not sampled.
    ///
    /// The depth clause is the honesty contract of the cap: only regions above
    /// it are thinned, so the reader is told the rest is complete. The last
    /// clause matters as much, since depth, coverage and consensus come from
    /// separate queries that never see the cap.
    var bannerMessage: String? {
        guard isSampled else { return nil }
        let total = isEstimated ? "~\(totalReads.formatted())" : totalReads.formatted()
        var parts = ["Showing \(displayedReads.formatted()) of \(total) reads"]
        if let cappedDepth {
            let cap = "\(cappedDepth.formatted())x"
            let scope = trackCount > 1 ? " per track" : ""
            parts.append("regions above \(cap) are sampled to about \(cap)\(scope), all other regions show every read")
        }
        if isTransportTruncated {
            parts.append("read safety limit reached, window may be incomplete")
        }
        parts.append("depth, coverage and consensus use all reads")
        return parts.joined(separator: " \u{00B7} ")
    }

    /// Title for the banner's escape hatch.
    static let loadAllActionTitle = "Load all"
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
