// DemultiplexChanceFloor.swift - The count a barcode must pass before a demultiplexing run trusts it
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation

/// BIO's chance floor (L5 of the 3.3 tally). A count of reads beats the floor only above the one-sided binomial
/// bound of the count that chance gives, at a tail under one in a million for the whole kit, split over its
/// barcodes. The route owner uses the same bound for the read names it probes.
public enum DemultiplexChanceFloor {
    /// The tail of the floor for a whole kit, one in a million.
    public static let kitTail = 1e-6

    /// The largest count of `trials` reads, each a chance match with `probability`, whose upper tail still reaches
    /// `tail`. A count above it lies above chance at that tail.
    public static func chanceCeiling(trials: Int, probability: Double, tail: Double) -> Int {
        guard trials > 0, probability > 0 else { return 0 }
        guard probability < 1 else { return trials }
        let mean = Double(trials) * probability
        let spread = (mean * (1 - probability)).squareRoot()
        // At the mean the tail is near one half, far above any tail the floor uses.
        var low = max(0, Int(mean.rounded(.down)))
        var high = min(trials, Int((mean + 40 * spread + 60).rounded(.up)))
        if upperTail(trials: trials, probability: probability, from: high) >= tail { return high }
        while high - low > 1 {
            let middle = (low + high) / 2
            if upperTail(trials: trials, probability: probability, from: middle) >= tail {
                low = middle
            } else {
                high = middle
            }
        }
        return low
    }

    /// P(X >= `count`) for X ~ Binomial(`trials`, `probability`), summed from `count` up.
    static func upperTail(trials: Int, probability: Double, from count: Int) -> Double {
        guard count > 0 else { return 1 }
        guard count <= trials else { return 0 }
        let n = Double(trials)
        let k = Double(count)
        var term = exp(
            lgamma(n + 1) - lgamma(k + 1) - lgamma(n - k + 1) + k * log(probability) + (n - k) * log1p(-probability)
        )
        let ratio = probability / (1 - probability)
        var sum = 0.0
        var index = count
        while index <= trials, term > 0 {
            sum += term
            if term < sum * 1e-17, Double(index) > n * probability { break }
            term *= Double(trials - index) / Double(index + 1) * ratio
            index += 1
        }
        return min(1, sum)
    }
}
