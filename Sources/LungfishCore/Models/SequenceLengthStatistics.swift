// Shared length thresholds for CLI, read bundles and assembly viewers.
import Foundation

public enum SequenceLengthStatistics {
    /// Smallest whole-base count covering at least `percentage` of `totalBases`.
    /// Splitting the multiplication keeps valid Int64 totals exact and overflow-free.
    public static func threshold(totalBases: Int64, percentage: Int) -> Int64 {
        precondition((1...100).contains(percentage))
        guard totalBases > 0 else { return 0 }
        let fraction = Int64(percentage)
        return (totalBases / 100) * fraction + ((totalBases % 100) * fraction + 99) / 100
    }

    /// Nx from a length histogram, without expanding records or overflowing a bin.
    /// Nonpositive lengths/counts do not contribute. `totalBases` is the sum of bases.
    public static func nx(histogram: [Int: Int], totalBases: Int64, percentage: Int = 50) -> Int {
        let target = threshold(totalBases: totalBases, percentage: percentage)
        guard target > 0 else { return 0 }
        var remaining = target
        for length in histogram.keys.sorted(by: >) where length > 0 {
            guard let count = histogram[length], count > 0 else { continue }
            // Compare before multiplying: a large bin may itself cover the threshold.
            if Int64(count) > (remaining - 1) / Int64(length) { return length }
            remaining -= Int64(length) * Int64(count)
        }
        return 0
    }
}
