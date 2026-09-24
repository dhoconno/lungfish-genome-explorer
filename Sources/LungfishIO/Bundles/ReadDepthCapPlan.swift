// ReadDepthCapPlan.swift - Per-bin subsampling plan that caps displayed read depth
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation

/// Plans a depth-capped read fetch for one window.
///
/// A single uniform `samtools view --subsample` over a mixed-depth window
/// hollows out the shallow parts to keep the deep parts affordable: a 50x
/// flank beside a 5,000x amplicon ends up drawn at under 4x. This plan instead
/// splits the window into bins and gives each bin its own keep fraction,
/// `min(1, cap / max depth in bin)`, so bins at or under the cap keep every
/// read and deeper bins are thinned to about the cap.
///
/// Fractions are quantized DOWN to powers of `sqrt(2)` so the window needs
/// only a handful of distinct `samtools` calls (one per fraction) and the
/// expected displayed depth never exceeds the cap inside a bin. A read belongs
/// to exactly one bin, the one holding its start position (clamped into the
/// window), so reads that span bin boundaries are neither duplicated nor lost.
///
/// Known bound: reads that start in a bin with a higher fraction and extend
/// into a neighbouring, more heavily sampled bin add to that bin's displayed
/// depth for at most one read length past the boundary. For reads shorter than
/// a bin the displayed depth there stays below `cap + neighbouring depth`.
public struct ReadDepthCapPlan: Sendable, Equatable {

    /// One `samtools view` call: every bin sharing a fraction, merged into
    /// maximal contiguous regions.
    public struct FetchGroup: Sendable, Equatable {
        /// Keep fraction for this call. `1` means no `--subsample`.
        public let fraction: Double
        /// 0-based half-open regions, sorted and non-overlapping.
        public let regions: [Range<Int>]
    }

    /// 0-based window start.
    public let windowStart: Int
    /// 0-based exclusive window end.
    public let windowEnd: Int
    /// Width of each bin in bases (the last bin may be shorter).
    public let binSize: Int
    /// The cap the plan was built for, after any transport-budget reduction.
    public let maxDisplayedDepth: Int
    /// Keep fraction per bin, index 0 at `windowStart`.
    public let binFractions: [Double]
    /// Distinct fractions, highest first, with their merged regions.
    public let groups: [FetchGroup]
    /// Sum of per-position depth over the window (all reads).
    public let totalBases: Int
    /// Expected displayed bases after sampling.
    public let expectedDisplayedBases: Double
    /// Maximum per-position depth in the window.
    public let peakDepth: Int

    /// True when at least one bin is thinned.
    public var isSampled: Bool { binFractions.contains { $0 < 1 } }

    /// Index of the bin that owns a read starting at `position`. Positions
    /// before the window (reads overlapping its left edge) belong to bin 0.
    public func binIndex(forReadStart position: Int) -> Int {
        guard !binFractions.isEmpty else { return 0 }
        let offset = max(0, position - windowStart)
        return min(binFractions.count - 1, offset / binSize)
    }

    /// Fraction that owns a read starting at `position`.
    public func fraction(forReadStart position: Int) -> Double {
        guard !binFractions.isEmpty else { return 1 }
        return binFractions[binIndex(forReadStart: position)]
    }

    // MARK: - Construction

    /// Smallest fraction the plan will ever emit, so `samtools` never receives
    /// a zero keep rate.
    public static let minimumFraction: Double = 0.000_001

    /// Bin width for a window: about 1 kb, narrower for short windows (never
    /// under 100 bp), and wider when needed to keep at most `maxBins` bins so
    /// region lists stay short.
    public static func binSize(forSpan span: Int, maxBins: Int = 512) -> Int {
        let span = max(1, span)
        var size = max(100, min(1_000, span / 40))
        if span / size > maxBins {
            size = (span + maxBins - 1) / maxBins
        }
        return size
    }

    /// Keep fraction for a bin whose deepest position is `maxDepth`, quantized
    /// down to `2^(-k/2)` so the expected kept depth is at most `cap`.
    public static func quantizedFraction(maxDepth: Int, cap: Int) -> Double {
        guard cap > 0 else { return minimumFraction }
        guard maxDepth > cap else { return 1 }
        let ratio = Double(maxDepth) / Double(cap)
        // A tiny epsilon keeps exact powers (ratio 2 -> k 2 -> 0.5) exact
        // instead of dropping one extra step to float noise.
        let k = max(1, Int((2 * log2(ratio) - 1e-9).rounded(.up)))
        return max(minimumFraction, pow(2, -Double(k) / 2))
    }

    /// Merges adjacent bins sharing a fraction into contiguous regions, one
    /// group per distinct fraction, highest fraction first.
    public static func groups(
        binFractions: [Double],
        windowStart: Int,
        windowEnd: Int,
        binSize: Int
    ) -> [FetchGroup] {
        var regionsByFraction: [Double: [Range<Int>]] = [:]
        var index = 0
        while index < binFractions.count {
            let fraction = binFractions[index]
            var last = index
            while last + 1 < binFractions.count, binFractions[last + 1] == fraction {
                last += 1
            }
            let lower = windowStart + index * binSize
            let upper = min(windowEnd, windowStart + (last + 1) * binSize)
            if upper > lower {
                regionsByFraction[fraction, default: []].append(lower..<upper)
            }
            index = last + 1
        }
        return regionsByFraction
            .map { FetchGroup(fraction: $0.key, regions: $0.value) }
            .sorted { $0.fraction > $1.fraction }
    }

    /// Builds a plan from per-position depth.
    ///
    /// - Parameters:
    ///   - depth: `(0-based position, depth)` pairs; missing positions are 0.
    ///   - maxDisplayedDepth: The requested cap.
    ///   - maxDisplayedBases: Transport budget in aligned bases. When the
    ///     expected displayed bases exceed it, the cap is lowered until they
    ///     fit, and `maxDisplayedDepth` reports the lowered cap so the banner
    ///     stays truthful.
    public static func make(
        depth: [(position: Int, depth: Int)],
        windowStart: Int,
        windowEnd: Int,
        maxDisplayedDepth: Int,
        maxDisplayedBases: Int = .max,
        binSize: Int? = nil
    ) -> ReadDepthCapPlan {
        let span = max(1, windowEnd - windowStart)
        let size = max(1, binSize ?? Self.binSize(forSpan: span))
        let binCount = max(1, (span + size - 1) / size)
        var binMax = [Int](repeating: 0, count: binCount)
        var binSum = [Int](repeating: 0, count: binCount)
        var total = 0
        var peak = 0
        for point in depth where point.position >= windowStart && point.position < windowEnd {
            let bin = min(binCount - 1, (point.position - windowStart) / size)
            binMax[bin] = max(binMax[bin], point.depth)
            binSum[bin] += point.depth
            total += point.depth
            peak = max(peak, point.depth)
        }

        var cap = max(1, maxDisplayedDepth)
        var fractions: [Double] = []
        var expected = 0.0
        // Each pass lowers the cap by the overshoot ratio; quantization can
        // leave a small overshoot, so allow a few passes before settling.
        for _ in 0..<8 {
            fractions = binMax.map { quantizedFraction(maxDepth: $0, cap: cap) }
            expected = zip(fractions, binSum).reduce(0) { $0 + $1.0 * Double($1.1) }
            guard expected > Double(maxDisplayedBases), cap > 1 else { break }
            let scaled = Int((Double(cap) * Double(maxDisplayedBases) / expected).rounded(.down))
            cap = max(1, min(cap - 1, scaled))
        }

        return ReadDepthCapPlan(
            windowStart: windowStart,
            windowEnd: windowEnd,
            binSize: size,
            maxDisplayedDepth: cap,
            binFractions: fractions,
            groups: groups(binFractions: fractions, windowStart: windowStart, windowEnd: windowEnd, binSize: size),
            totalBases: total,
            expectedDisplayedBases: expected,
            peakDepth: peak
        )
    }
}
