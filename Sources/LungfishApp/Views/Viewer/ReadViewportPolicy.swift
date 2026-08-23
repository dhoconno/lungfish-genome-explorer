import Foundation

enum ReadViewportPolicy {
    static let coverageThresholdBpPerPx: Double = 2.0
    static let baseThresholdBpPerPx: Double = 0.6

    static func zoomTier(scale: Double) -> ReadTrackRenderer.ZoomTier {
        if scale > coverageThresholdBpPerPx {
            return .coverage
        } else if scale > baseThresholdBpPerPx {
            return .packed
        } else {
            return .base
        }
    }

    static func allowsIndividualReads(scale: Double) -> Bool {
        zoomTier(scale: scale) != .coverage
    }

    // MARK: - Visible-read budget

    /// Maximum individual reads drawn for one fetch window before the viewport
    /// falls back to a uniform sample.
    ///
    /// A ~100 bp microsatellite window at ~600,000x depth returns every read in
    /// the pile, and packing them is `O(reads log rows)` no matter how fast the
    /// allocator is. Beyond this many reads the extra rows are not legible
    /// anyway, so the viewport shows a deterministic sample and says so.
    /// Depth, coverage, and consensus come from separate whole-BAM queries and
    /// are deliberately unaffected.
    static let defaultVisibleReadBudget = 50_000

    /// Absolute ceiling for a "Load all" request, so the escape hatch cannot
    /// stream an unbounded SAM payload into the process.
    static let loadAllReadCeiling = 2_000_000

    /// Fetch size that lets the caller detect overflow: budget + 1 read.
    static func fetchLimit(forBudget budget: Int) -> Int {
        budget >= Int.max ? Int.max : budget + 1
    }

    /// Uniformly samples `reads` down to `budget` entries, deterministically.
    ///
    /// A fixed stride (rather than a random draw) keeps the displayed sample
    /// stable across redraws and identical between runs, which matters because
    /// the user can select reads out of it and expect them to still be there.
    /// Reads are returned in their original relative order.
    static func sampleReads<T>(_ reads: [T], budget: Int) -> [T] {
        guard budget > 0 else { return [] }
        guard reads.count > budget else { return reads }
        var sampled: [T] = []
        sampled.reserveCapacity(budget)
        // Spread `budget` picks evenly across `reads.count` slots. Integer
        // arithmetic avoids float drift accumulating over 600k iterations.
        for index in 0..<budget {
            let source = index * reads.count / budget
            sampled.append(reads[source])
        }
        return sampled
    }
}
