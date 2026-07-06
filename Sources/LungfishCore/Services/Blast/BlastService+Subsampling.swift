// BlastService+Subsampling.swift - NCBI BLAST URL API client
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation

// MARK: - Subsampling

extension BlastService {

    /// Subsamples reads for BLAST verification.
    ///
    /// Given a set of read IDs and their sequences, selects a representative
    /// subset according to the specified strategy:
    ///
    /// - `.longestFirst(count:)`: Selects the N longest reads
    /// - `.random(count:)`: Selects N reads at random
    /// - `.mixed(longest:random:)`: Selects the top N longest, then fills
    ///   remaining slots with random reads from the rest
    ///
    /// When fewer reads are available than requested, all reads are returned.
    ///
    /// - Parameters:
    ///   - reads: All available reads as (id, sequence) pairs
    ///   - strategy: The subsampling strategy to use
    ///   - seed: Random seed for reproducibility (defaults to 0)
    /// - Returns: The subsampled reads as (id, sequence) pairs
    public nonisolated func subsampleReads(
        from reads: [(id: String, sequence: String)],
        strategy: SubsampleStrategy,
        seed: UInt64 = 0
    ) -> [(id: String, sequence: String)] {
        guard !reads.isEmpty else { return [] }

        let totalRequested = strategy.totalCount
        guard reads.count > totalRequested else {
            // Fewer reads than requested -- return all
            return reads
        }

        switch strategy {
        case .longestFirst(let count):
            return selectLongest(from: reads, count: count)

        case .random(let count):
            return selectRandom(from: reads, count: count, seed: seed)

        case .mixed(let longest, let random):
            return selectMixed(from: reads, longest: longest, random: random, seed: seed)
        }
    }

    /// Selects the N longest reads.
    private nonisolated func selectLongest(
        from reads: [(id: String, sequence: String)],
        count: Int
    ) -> [(id: String, sequence: String)] {
        let sorted = reads.sorted { $0.sequence.count > $1.sequence.count }
        return Array(sorted.prefix(count))
    }

    /// Selects N reads at random using a seeded generator.
    private nonisolated func selectRandom(
        from reads: [(id: String, sequence: String)],
        count: Int,
        seed: UInt64
    ) -> [(id: String, sequence: String)] {
        var rng = SeededRandomNumberGenerator(seed: seed)
        let shuffled = reads.shuffled(using: &rng)
        return Array(shuffled.prefix(count))
    }

    /// Selects top-N longest + random from the rest.
    private nonisolated func selectMixed(
        from reads: [(id: String, sequence: String)],
        longest: Int,
        random: Int,
        seed: UInt64
    ) -> [(id: String, sequence: String)] {
        let sorted = reads.sorted { $0.sequence.count > $1.sequence.count }
        let longestReads = Array(sorted.prefix(longest))
        let longestIds = Set(longestReads.map(\.id))

        // Remaining reads (excluding the longest-selected ones)
        let remaining = reads.filter { !longestIds.contains($0.id) }

        let randomReads: [(id: String, sequence: String)]
        if remaining.count <= random {
            randomReads = remaining
        } else {
            var rng = SeededRandomNumberGenerator(seed: seed)
            let shuffled = remaining.shuffled(using: &rng)
            randomReads = Array(shuffled.prefix(random))
        }

        return longestReads + randomReads
    }
}
